package com.ct106.difangke.service

import android.content.Context
import android.util.Log
import androidx.room.withTransaction
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.service.timeline.ActivityHabits
import com.ct106.difangke.service.timeline.DayTimelineEngine
import com.ct106.difangke.service.timeline.LiveStayContext
import com.ct106.difangke.service.timeline.RouteCodec
import com.ct106.difangke.service.timeline.TimelineSensors
import com.ct106.difangke.service.timeline.TimelineWorkspace
import com.ct106.difangke.service.timeline.TransportPreferences
import com.ct106.difangke.service.timeline.WFootprint
import com.ct106.difangke.service.timeline.WTransport
import com.ct106.difangke.service.timeline.addDays
import com.ct106.difangke.service.timeline.startOfDay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.Collections
import java.util.Date

/**
 * Room-backed timeline builder (iOS `PersistentTimelineBuilder`).
 *
 * [syncDay] is the iOS incremental pipeline: it loads the day's records into a
 * [TimelineWorkspace], runs the pure [DayTimelineEngine] (repairs existing
 * records, fills only uncovered gaps, post-processes), then persists the diff.
 */
class PersistentTimelineBuilder(private val context: Context) {

    private val db = DiFangKeApp.instance.database
    private val rawStore = RawLocationStore.getInstance(context)
    private val geocoder = GeocodeService.shared

    companion object {
        private const val TAG = "TimelineBuilder"

        /** iOS `syncingDates`: per-day re-entrancy guard. */
        private val syncingDates: MutableSet<Long> = Collections.synchronizedSet(mutableSetOf())

        /** Serializes workspace load → persist so two days never interleave writes. */
        private val persistMutex = Mutex()

        /**
         * Optional live tracking context (anchor / current fix / held stationary
         * stay), set by the tracking service. Used for today's edited-stay continuation.
         */
        @Volatile
        var liveStayContextProvider: (() -> LiveStayContext?)? = null

        /** Optional Health/activity hooks; null → speed-only classification. */
        @Volatile
        var sensors: TimelineSensors = TimelineSensors.None
    }

    // ───────────────────────── public API ─────────────────────────

    /** Backward-compatible name used by existing callers; delegates to [syncDay]. */
    suspend fun rebuildDay(date: Date) {
        syncDay(date)
    }

    /**
     * iOS `syncDay(date:in:runConsolidation:)`. Returns false when skipped because
     * the same day is already syncing (callers that must observe completion should retry).
     */
    suspend fun syncDay(date: Date, runConsolidation: Boolean = true): Boolean = withContext(Dispatchers.IO) {
        val dayStart = startOfDay(date)
        if (!syncingDates.add(dayStart.time)) {
            Log.i(TAG, "skip $dayStart: sync already in progress")
            return@withContext false
        }
        try {
            persistMutex.withLock {
                val ws = loadWorkspace(dayStart)
                val marked = rawStore.loadMarkedLocations(dayStart)
                val engine = DayTimelineEngine(
                    ws = ws,
                    rawPoints = marked.validPoints,
                    driftTimestamps = marked.driftTimestamps,
                    preferences = loadPreferences(dayStart),
                    sensors = sensors,
                    live = runCatching { liveStayContextProvider?.invoke() }.getOrNull(),
                    now = Date(),
                    log = { Log.i(TAG, "$dayStart: $it") }
                )
                engine.syncDay(runConsolidation)
                persist(ws)
            }
            resolveAddresses(dayStart)
            true
        } catch (e: Exception) {
            Log.e(TAG, "syncDay failed for $dayStart", e)
            true
        } finally {
            syncingDates.remove(dayStart.time)
        }
    }

    /**
     * iOS `resetData(for:)`: wipe the day's footprints, transports, insight and
     * deletion overrides, then rebuild from raw points (retrying while another
     * sync of the same day is in flight).
     */
    suspend fun resetAndRebuildDay(date: Date) = withContext(Dispatchers.IO) {
        val dayStart = startOfDay(date)
        val dayEnd = addDays(dayStart, 1)
        persistMutex.withLock {
            db.withTransaction {
                db.footprintDao().deleteIntersecting(dayStart, dayEnd)
                db.transportRecordDao().deleteIntersecting(dayStart, dayEnd)
                db.dailyInsightDao().deleteForDay(dayStart, dayEnd)
                db.transportManualSelectionDao().deleteStartingBetween(dayStart, dayEnd)
            }
        }
        var didSync = syncDay(dayStart)
        var retries = 20
        while (!didSync && retries > 0) {
            delay(300)
            didSync = syncDay(dayStart)
            retries--
        }
    }

    /**
     * iOS `rebuildAffectedTimeline`: automatic transports containing a deleted raw
     * point become ignored; then the day is re-synced incrementally.
     * [deletedTimestamps] are epoch seconds.
     */
    suspend fun repairAffectedTimeline(deletedTimestamps: List<Double>, date: Date) = withContext(Dispatchers.IO) {
        if (deletedTimestamps.isEmpty()) return@withContext
        val dayStart = startOfDay(date)
        val dayEnd = addDays(dayStart, 1)
        var anyChanged = false
        persistMutex.withLock {
            for (tp in db.transportRecordDao().getAllIntersecting(dayStart, dayEnd)) {
                if (tp.manualTypeRaw != null) continue
                val hit = deletedTimestamps.any { ts -> (ts * 1000).toLong() in tp.startTime.time..tp.endTime.time }
                if (hit) {
                    db.transportRecordDao().ignoreById(tp.recordID)
                    anyChanged = true
                }
            }
        }
        if (anyChanged) syncDay(dayStart)
    }

    /** iOS `mergeRecentFootprints`: lightweight live merge of today's last stays. */
    suspend fun mergeRecentFootprintsForToday(): Boolean = withContext(Dispatchers.IO) {
        val now = Date()
        val dayStart = startOfDay(now)
        persistMutex.withLock {
            val ws = loadWorkspace(dayStart)
            val engine = DayTimelineEngine(ws, emptyList(), now = now)
            val merged = engine.mergeRecentFootprints()
            if (merged) persist(ws)
            merged
        }
    }

    /** iOS `autoFillMissingActivityTypes(for:)` (activity part). */
    suspend fun autoFillMissingActivityTypes(date: Date): Int = withContext(Dispatchers.IO) {
        val dayStart = startOfDay(date)
        persistMutex.withLock {
            val ws = loadWorkspace(dayStart)
            val count = DayTimelineEngine(ws, emptyList()).autoFillMissingActivityTypes()
            if (count > 0) persist(ws)
            count
        }
    }

    // ───────────────────────── Room I/O ─────────────────────────

    private suspend fun loadWorkspace(dayStart: Date): TimelineWorkspace {
        val dayEnd = addDays(dayStart, 1)
        val fpDao = db.footprintDao()
        val dayFps = fpDao.getBetween(dayStart, dayEnd)
        val loaded = LinkedHashMap<String, FootprintEntity>()
        dayFps.forEach { loaded[it.footprintID] = it }
        // Cross-day neighbours for gap bridging (iOS fillGapsBetweenItems).
        fpDao.getLatestEndingAtOrBefore(dayStart)?.let { loaded.putIfAbsent(it.footprintID, it) }
        fpDao.getEarliestStartingAtOrAfter(dayEnd)?.let { loaded.putIfAbsent(it.footprintID, it) }
        val ignored = fpDao.getIgnoredIntersecting(dayStart, dayEnd)

        val transports = db.transportRecordDao().getNonIgnoredIntersecting(dayStart, dayEnd)
        val tol = com.ct106.difangke.AppConfig.RECONSTRUCTION_BOUNDARY_TOLERANCE.toLong() * 1000
        val deleted = db.transportManualSelectionDao()
            .getDeletedBetween(Date(dayStart.time - tol), Date(dayEnd.time + tol))
            .map { it.startTime to it.endTime }
        val places = db.placeDao().getAll()

        val history = fpDao.getWithPlaceAndActivity()
            .filter { it.footprintID !in loaded }
            .groupBy({ it.placeID!! }, { ActivityHabits.HistoryEntry(it.startTime, it.activityTypeValue!!) })

        return TimelineWorkspace(
            dayStart = dayStart,
            footprints = loaded.values.map { WFootprint.from(it) },
            ignoredFootprints = ignored.map { WFootprint.from(it) },
            transports = transports.map { WTransport.from(it) },
            deletedSelections = deleted,
            places = places,
            externalActivityHistory = history
        )
    }

    private suspend fun loadPreferences(dayStart: Date): TransportPreferences {
        val history = db.transportRecordDao().getPreferenceHistory(dayStart, addDays(dayStart, 1), 300)
        return TransportPreferences.compute(history, dayStart)
    }

    /** Writes only what changed (insert / update / delete), in one transaction. */
    private suspend fun persist(ws: TimelineWorkspace) {
        val fpDao = db.footprintDao()
        val tpDao = db.transportRecordDao()
        db.withTransaction {
            for (id in ws.deletedFootprintIDs) fpDao.deleteById(id)
            for (id in ws.deletedTransportIDs) tpDao.deleteById(id)
            for (fp in ws.footprints) {
                val entity = fp.toEntity()
                if (fp.original == null) fpDao.insert(entity)
                else if (entity != fp.original) fpDao.update(entity)
            }
            for (tp in ws.transports) {
                val entity = tp.toEntity()
                if (tp.original == null) tpDao.insert(entity)
                else if (entity != tp.original) tpDao.update(entity)
            }
        }
    }

    // ───────────────────────── address resolution ─────────────────────────

    private fun needsAddress(address: String?) =
        address.isNullOrEmpty() || address == "未知地点" || address == "正在获取位置..."

    /** iOS `resolveAddresses(for:)`, throttled to protect the geocoder quota. */
    private suspend fun resolveAddresses(dayStart: Date) {
        val dayEnd = addDays(dayStart, 1)
        val fps = db.footprintDao().getBetween(dayStart, dayEnd)
            .filter { needsAddress(it.address) && !it.isAddressEditedByHand }
        for (fp in fps) {
            val lat = WFootprint.from(fp).latitude
            val lon = WFootprint.from(fp).longitude
            val details = runCatching { geocoder.reverseGeocodeDetails(lat, lon) }.getOrNull()
            if (details?.address?.isNotEmpty() == true) {
                val latest = db.footprintDao().getById(fp.footprintID) ?: continue
                if (!needsAddress(latest.address) || latest.isAddressEditedByHand) continue
                db.footprintDao().update(
                    latest.copy(
                        address = details.address,
                        countryCode = latest.countryCode ?: details.countryCode,
                        countryName = latest.countryName ?: details.countryName,
                        cityName = latest.cityName ?: details.cityName
                    )
                )
            }
            delay(300)
        }

        val tps = db.transportRecordDao().getNonIgnoredIntersecting(dayStart, dayEnd).filter {
            it.startLocation == "起点" || it.endLocation == "终点" ||
                it.startLocation == "正在获取位置..." || it.endLocation == "正在获取位置..."
        }
        for (tp in tps) {
            val points = RouteCodec.decode(tp.pointsJson)
            var updated: TransportRecordEntity = tp
            if (tp.startLocation == "起点" || tp.startLocation == "正在获取位置...") {
                points.firstOrNull()?.let { first ->
                    runCatching { geocoder.reverseGeocode(first.lat, first.lon) }.getOrNull()
                        ?.takeIf { it.isNotEmpty() }?.let { updated = updated.copy(startLocation = it) }
                }
                delay(300)
            }
            if (tp.endLocation == "终点" || tp.endLocation == "正在获取位置...") {
                points.lastOrNull()?.let { last ->
                    runCatching { geocoder.reverseGeocode(last.lat, last.lon) }.getOrNull()
                        ?.takeIf { it.isNotEmpty() }?.let { updated = updated.copy(endLocation = it) }
                }
                delay(300)
            }
            if (updated != tp) {
                val latest = db.transportRecordDao().getById(tp.recordID) ?: continue
                db.transportRecordDao().update(
                    latest.copy(
                        startLocation = if (latest.startLocation == tp.startLocation) updated.startLocation else latest.startLocation,
                        endLocation = if (latest.endLocation == tp.endLocation) updated.endLocation else latest.endLocation
                    )
                )
            }
        }
    }
}
