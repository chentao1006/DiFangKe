package com.ct106.difangke.ui.shared

import android.content.Context
import com.aptabase.Aptabase
import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportManualSelectionEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.db.entity.markManualMetadataEdit
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.FootprintStatus
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.ActivitySuggestion
import com.ct106.difangke.service.GeocodeService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Shared timeline edit operations (iOS parity: TimelineView context menu handlers,
 * FootprintSplitView, FootprintTimeAdjustmentView, TransportSplitView,
 * TransportTimeAdjustmentView, LocationManager.ignoreLocation).
 *
 * All functions are suspend + persist immediately. They re-read the stored row by id,
 * so callers may pass a possibly stale entity snapshot.
 */
object TimelineEditActions {

    /** iOS `max(60, ceil(stayDurationThreshold / 60) * 60)` seconds, in ms. */
    val MIN_FOOTPRINT_DURATION_MS: Long =
        max(60.0, ceil(AppConfig.STAY_DURATION_THRESHOLD / 60.0) * 60.0).toLong() * 1000L

    /** Transport minimum segment length (iOS TransportSplitView.minimumDuration = 60 s). */
    const val MIN_TRANSPORT_SEGMENT_MS: Long = 60_000L

    private const val TWO_DAYS_MS = 172_800_000L

    // ───────────────────────────── Footprints ─────────────────────────────

    /** Adjacent footprint that can merge with [footprint] (previous preferred), or null. */
    suspend fun findFootprintMergePartner(db: AppDatabase, footprint: FootprintEntity): FootprintEntity? {
        val stored = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val all = db.footprintDao().getBetween(
            Date(stored.startTime.time - TWO_DAYS_MS),
            Date(stored.endTime.time + TWO_DAYS_MS)
        ).sortedBy { it.startTime }
        val index = all.indexOfFirst { it.footprintID == stored.footprintID }
        if (index < 0) return null
        all.getOrNull(index - 1)?.let { if (canMergeFootprints(db, it, stored)) return it }
        all.getOrNull(index + 1)?.let { if (canMergeFootprints(db, stored, it)) return it }
        return null
    }

    suspend fun canMergeFootprint(db: AppDatabase, footprint: FootprintEntity): Boolean =
        findFootprintMergePartner(db, footprint) != null

    /** iOS canMergeAdjacentFootprints: same day, neither crosses midnight, no active transport between. */
    suspend fun canMergeFootprints(db: AppDatabase, first: FootprintEntity, second: FootprintEntity): Boolean {
        if (first.status == FootprintStatus.IGNORED || second.status == FootprintStatus.IGNORED) return false
        if (first.footprintID == second.footprintID) return false
        if (!isSameDayFootprint(first) || !isSameDayFootprint(second)) return false
        if (!isSameDay(first.startTime, second.startTime)) return false
        val lower = minOf(first.endTime, second.endTime)
        val upper = maxOf(first.startTime, second.startTime)
        if (!upper.after(lower)) return true
        return db.transportRecordDao().getActiveBetween(lower, upper).isEmpty()
    }

    /** Merge [a] and [b]; the earlier one survives (iOS parity). Returns the merged footprint. */
    suspend fun mergeFootprints(db: AppDatabase, a: FootprintEntity, b: FootprintEntity): FootprintEntity {
        val sa = db.footprintDao().getById(a.footprintID) ?: a
        val sb = db.footprintDao().getById(b.footprintID) ?: b
        val base = if (sa.startTime <= sb.startTime) sa else sb
        val other = if (base === sa) sb else sa
        val start = minOf(base.startTime, other.startTime)
        val end = maxOf(base.endTime, other.endTime)
        val lats = jsonDoubles(base.latitudeJson) + jsonDoubles(other.latitudeJson)
        val lons = jsonDoubles(base.longitudeJson) + jsonDoubles(other.longitudeJson)
        val photos = (jsonStrings(base.photoAssetIDsJson) + jsonStrings(other.photoAssetIDsJson)).distinct()
        val baseAddressEmpty = base.address.isNullOrEmpty()
        val merged = base.copy(
            startTime = start,
            endTime = end,
            date = startOfDay(start),
            allowsAutomaticDurationExtension = true,
            statusValue = FootprintStatus.MANUAL.raw,
            latitudeJson = JSONArray(lats).toString(),
            longitudeJson = JSONArray(lons).toString(),
            reason = if (base.reason.isNullOrEmpty()) other.reason else base.reason,
            address = if (baseAddressEmpty) other.address else base.address,
            isAddressEditedByHand = if (baseAddressEmpty) other.isAddressEditedByHand else base.isAddressEditedByHand,
            placeID = base.placeID ?: other.placeID,
            activityTypeValue = base.activityTypeValue ?: other.activityTypeValue,
            isHighlight = if (base.isHighlight == true) true else other.isHighlight,
            stepCount = optSum(base.stepCount, other.stepCount),
            walkingDistance = optSum(base.walkingDistance, other.walkingDistance),
            floorsAscended = optSum(base.floorsAscended, other.floorsAscended),
            photoAssetIDsJson = JSONArray(photos).toString()
        )
        db.footprintDao().update(merged)
        db.footprintDao().deleteById(other.footprintID)
        track("footprint_adjacent_merged")
        return merged
    }

    /** Convenience: merge with the detected adjacent partner. Returns merged footprint or null. */
    suspend fun mergeAdjacentFootprint(db: AppDatabase, footprint: FootprintEntity): FootprintEntity? {
        val partner = findFootprintMergePartner(db, footprint) ?: return null
        return mergeFootprints(db, footprint, partner)
    }

    /** iOS mergeConfirmationMessage. Title: "合并相邻足迹？". */
    fun footprintMergeMessage(a: FootprintEntity, b: FootprintEntity, places: List<PlaceEntity>): String {
        val first = if (a.startTime <= b.startTime) a else b
        val second = if (first === a) b else a
        fun line(fp: FootprintEntity) = "${hm(fp.startTime)}-${hm(fp.endTime)}  ${footprintDisplayTitle(fp, places)}"
        return "将合并：\n${line(first)}\n${line(second)}"
    }

    fun footprintDisplayTitle(fp: FootprintEntity, places: List<PlaceEntity>): String {
        fp.placeID?.let { id -> places.firstOrNull { it.placeID == id && it.isUserDefined }?.let { return it.name } }
        return fp.address?.trim()?.takeIf { it.isNotEmpty() } ?: "未知地点"
    }

    /** Raw points in [start, end] across all touched days, chronological. */
    suspend fun loadRawPoints(context: Context, start: Date, end: Date, filtered: Boolean = true): List<RawLocationStore.RawPoint> =
        withContext(Dispatchers.IO) {
            val store = RawLocationStore.getInstance(context)
            touchedDates(start, end).flatMap { store.loadLocations(it, filtered) }
                .filter { !it.timestamp.before(start) && !it.timestamp.after(end) }
                .sortedBy { it.timestamp }
        }

    /**
     * iOS FootprintSplitView.saveSplit. The original keeps [start, split] with
     * allowsAutomaticDurationExtension=false and [firstActivity]; a new footprint
     * (locationHash "MANUAL_SPLIT", no photos, copies highlight) gets [split, end]
     * with [secondActivity]. Returns (original, new) or null if too short.
     */
    suspend fun splitFootprint(
        db: AppDatabase,
        context: Context,
        footprint: FootprintEntity,
        splitTime: Date,
        firstActivityTypeValue: String? = footprint.activityTypeValue,
        secondActivityTypeValue: String? = footprint.activityTypeValue
    ): Pair<FootprintEntity, FootprintEntity>? {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val total = fp.endTime.time - fp.startTime.time
        if (total < MIN_FOOTPRINT_DURATION_MS * 2) return null
        val bounded = splitTime.time.coerceIn(fp.startTime.time + MIN_FOOTPRINT_DURATION_MS, fp.endTime.time - MIN_FOOTPRINT_DURATION_MS)
        val split = roundedToMinute(Date(bounded))
        val firstEnd = Date(max(split.time, fp.startTime.time + MIN_FOOTPRINT_DURATION_MS))
        val secondStart = Date(min(split.time, fp.endTime.time - MIN_FOOTPRINT_DURATION_MS))
        val ratio = (split.time - fp.startTime.time).toDouble() / max(1L, total).toDouble()
        val raw = loadRawPoints(context, fp.startTime, fp.endTime)
        val firstCoords = coordinatesFor(raw, fp, fp.startTime, firstEnd, 0.0, ratio)
        val secondCoords = coordinatesFor(raw, fp, secondStart, fp.endTime, ratio, 1.0)

        val first = fp.copy(
            allowsAutomaticDurationExtension = false,
            endTime = firstEnd,
            date = startOfDay(fp.startTime),
            statusValue = FootprintStatus.MANUAL.raw,
            activityTypeValue = firstActivityTypeValue,
            latitudeJson = firstCoords?.first ?: fp.latitudeJson,
            longitudeJson = firstCoords?.second ?: fp.longitudeJson,
            locationHash = manualHash(fp.locationHash),
            stepCount = splitInt(fp.stepCount, ratio, false),
            walkingDistance = splitDouble(fp.walkingDistance, ratio, false),
            floorsAscended = splitInt(fp.floorsAscended, ratio, false)
        )
        val second = FootprintEntity(
            footprintID = UUID.randomUUID().toString(),
            date = startOfDay(secondStart),
            startTime = secondStart,
            endTime = fp.endTime,
            latitudeJson = secondCoords?.first ?: first.latitudeJson,
            longitudeJson = secondCoords?.second ?: first.longitudeJson,
            locationHash = "MANUAL_SPLIT",
            title = fp.title,
            reason = fp.reason,
            statusValue = FootprintStatus.MANUAL.raw,
            aiScore = fp.aiScore,
            isHighlight = fp.isHighlight,
            placeID = fp.placeID,
            photoAssetIDsJson = "[]",
            address = fp.address,
            countryCode = fp.countryCode,
            countryName = fp.countryName,
            cityName = fp.cityName,
            isPlaceSuggestionIgnored = fp.isPlaceSuggestionIgnored,
            aiAnalyzed = fp.aiAnalyzed,
            isTitleEditedByHand = fp.isTitleEditedByHand,
            isAddressEditedByHand = fp.isAddressEditedByHand,
            activityTypeValue = secondActivityTypeValue,
            stepCount = splitInt(fp.stepCount, ratio, true),
            walkingDistance = splitDouble(fp.walkingDistance, ratio, true),
            floorsAscended = splitInt(fp.floorsAscended, ratio, true)
        )
        db.footprintDao().update(first)
        db.footprintDao().insert(second)
        track("footprint_split")
        return first to second
    }

    /** Editable range for the time-adjust sheet (iOS setupInitialRange). */
    suspend fun footprintAdjustRange(db: AppDatabase, footprint: FootprintEntity): Pair<Date, Date> {
        val dayStart = startOfDay(footprint.date)
        val dayEnd = Date(addDays(dayStart, 1).time)
        val latestAllowed = Date(min(dayEnd.time, currentMinute().time))
        val prevEnd = db.footprintDao().getPreviousBefore(footprint.footprintID, footprint.startTime)?.endTime ?: dayStart
        val nextStart = db.footprintDao().getNextAfter(footprint.footprintID, footprint.endTime)?.startTime ?: latestAllowed
        var rangeStart = maxOf(prevEnd, dayStart)
        var rangeEnd = minOf(nextStart, latestAllowed)
        if (!rangeEnd.after(rangeStart)) {
            rangeStart = dayStart
            rangeEnd = latestAllowed
        }
        return rangeStart to rangeEnd
    }

    /**
     * iOS FootprintTimeAdjustmentView.saveAdjustment: sets allowsAutomaticDurationExtension=false,
     * status manual, recomputes coordinates from raw points and trims/extends adjacent transports.
     */
    suspend fun adjustFootprintTime(
        db: AppDatabase,
        context: Context,
        footprint: FootprintEntity,
        newStart: Date,
        newEnd: Date
    ): FootprintEntity? {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val oldStart = fp.startTime
        val oldEnd = fp.endTime
        val latestAllowed = currentMinute()
        val roundedStart = roundedToMinute(newStart)
        val roundedEnd = roundedToMinute(Date(max(newEnd.time, roundedStart.time + MIN_FOOTPRINT_DURATION_MS)))
        val didChangeStart = minuteKey(oldStart) != minuteKey(roundedStart)
        val didChangeEnd = minuteKey(oldEnd) != minuteKey(roundedEnd)
        if (!didChangeStart && !didChangeEnd) return fp
        val start = if (didChangeStart) roundedStart else oldStart
        var end = if (didChangeEnd) Date(max(roundedEnd.time, start.time + MIN_FOOTPRINT_DURATION_MS))
        else Date(max(oldEnd.time, start.time + MIN_FOOTPRINT_DURATION_MS))
        if (end.after(latestAllowed) && latestAllowed.time - start.time >= 60_000L) end = latestAllowed

        val raw = loadRawPoints(context, start, end)
        val updated = fp.copy(
            allowsAutomaticDurationExtension = false,
            startTime = start,
            endTime = end,
            date = startOfDay(start),
            statusValue = FootprintStatus.MANUAL.raw,
            locationHash = manualHash(fp.locationHash),
            latitudeJson = if (raw.isNotEmpty()) JSONArray(raw.map { it.latitude }).toString() else fp.latitudeJson,
            longitudeJson = if (raw.isNotEmpty()) JSONArray(raw.map { it.longitude }).toString() else fp.longitudeJson
        )
        val tDao = db.transportRecordDao()
        if (didChangeStart) {
            tDao.getAdjacentEndingAt(oldStart, Date(oldStart.time - 30 * 60_000L), Date(oldStart.time + 60_000L))?.let {
                tDao.update(refreshTransportMetrics(it.copy(endTime = start, day = startOfDay(it.startTime))))
            }
        }
        if (didChangeEnd) {
            tDao.getAdjacentStartingAt(oldEnd, Date(oldEnd.time - 60_000L), Date(oldEnd.time + 30 * 60_000L))?.let {
                tDao.update(refreshTransportMetrics(it.copy(startTime = end, day = startOfDay(end))))
            }
        }
        db.footprintDao().update(updated)
        track("footprint_time_adjusted")
        return updated
    }

    /** iOS LocationManager.ignoreLocation: mark place ignored and hide its footprints (radius + 100 m). */
    suspend fun ignorePlace(db: AppDatabase, footprint: FootprintEntity): PlaceEntity? {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val coord = representativeCoordinate(fp)
        val existing = fp.placeID?.let { db.placeDao().getById(it) }
        val place = existing?.copy(isIgnored = true) ?: run {
            coord ?: return null
            val address = fp.address
            PlaceEntity(
                name = if (address.isNullOrEmpty()) "已忽略地点" else address,
                latitude = coord.first,
                longitude = coord.second,
                radius = 100f,
                address = address,
                isIgnored = true,
                isUserDefined = false
            )
        }
        db.placeDao().insert(place)
        val center = place.latitude to place.longitude
        val threshold = place.radius + 100.0
        db.footprintDao().getAll().forEach { other ->
            if (other.placeID == place.placeID) {
                db.footprintDao().update(other.copy(statusValue = FootprintStatus.IGNORED.raw))
            } else {
                val c = representativeCoordinate(other) ?: return@forEach
                if (haversine(center.first, center.second, c.first, c.second) <= threshold) {
                    db.footprintDao().update(other.copy(statusValue = FootprintStatus.IGNORED.raw, placeID = place.placeID))
                }
            }
        }
        // Make sure the edited one is hidden even if it had no coordinates.
        db.footprintDao().getById(fp.footprintID)?.let {
            if (it.statusValue != FootprintStatus.IGNORED.raw) db.footprintDao().update(it.copy(statusValue = FootprintStatus.IGNORED.raw, placeID = place.placeID))
        }
        track("footprint_location_ignored")
        return place
    }

    /** Delete to recycle bin (status ignored), iOS deleteFootprint. */
    suspend fun deleteFootprint(db: AppDatabase, footprint: FootprintEntity) {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        db.footprintDao().update(fp.copy(statusValue = FootprintStatus.IGNORED.raw))
        track("footprint_deleted")
    }

    suspend fun toggleHighlight(db: AppDatabase, footprint: FootprintEntity): FootprintEntity {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        return setHighlight(db, fp, fp.isHighlight != true)
    }

    suspend fun setHighlight(db: AppDatabase, footprint: FootprintEntity, highlighted: Boolean): FootprintEntity =
        updateFootprintMetadata(db, footprint) { it.copy(isHighlight = highlighted) }.also {
            if (highlighted) track("footprint_highlighted")
        }

    /** Set (or clear with null) the activity type; marks a manual metadata edit. */
    suspend fun setActivity(db: AppDatabase, footprint: FootprintEntity, activityTypeId: String?): FootprintEntity =
        updateFootprintMetadata(db, footprint) { it.copy(activityTypeValue = activityTypeId) }

    /** Generic metadata edit: applies [transform] to the stored row, then markManualMetadataEdit() and persists. */
    suspend fun updateFootprintMetadata(
        db: AppDatabase,
        footprint: FootprintEntity,
        transform: (FootprintEntity) -> FootprintEntity
    ): FootprintEntity {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val updated = transform(fp).markManualMetadataEdit()
        db.footprintDao().update(updated)
        track(null)
        return updated
    }

    /**
     * iOS LocationManager.selectSuggestion(forOngoing: false, footprint:): mark the chosen place as
     * priority (create an automatic Place if needed), write address/placeID/isAddressEditedByHand,
     * re-match a non-manual activity from the new place's history, then markManualMetadataEdit().
     */
    suspend fun applyPlaceSelection(db: AppDatabase, footprint: FootprintEntity, suggestion: GeocodeService.SearchResult): FootprintEntity {
        val fp = db.footprintDao().getById(footprint.footprintID) ?: footprint
        val place = updateOrCreatePlaceAsPriority(db, suggestion)
        val shouldRematch = fp.activityTypeValue == null || fp.status != FootprintStatus.MANUAL
        var updated = fp.copy(
            address = suggestion.name,
            placeID = place.placeID,
            isAddressEditedByHand = true,
            locationHash = manualHash(fp.locationHash)
        )
        if (shouldRematch) {
            val history = db.footprintDao().getAll().filter { it.placeID == place.placeID && it.footprintID != fp.footprintID }
            val types = db.activityTypeDao().getAll()
            // History-only match (iOS resolveFrequentActivityType) — no place-name rule.
            updated = updated.copy(
                activityTypeValue = ActivitySuggestion.getAutoMatchActivity(updated, types, emptyList(), history)?.id
            )
        }
        updated = updated.markManualMetadataEdit()
        db.footprintDao().update(updated)
        track("footprint_edited")
        return updated
    }

    private suspend fun updateOrCreatePlaceAsPriority(db: AppDatabase, suggestion: GeocodeService.SearchResult): PlaceEntity {
        val all = db.placeDao().getAll()
        all.filter { it.isPriority && haversine(it.latitude, it.longitude, suggestion.latitude, suggestion.longitude) < 200 }
            .forEach { db.placeDao().update(it.copy(isPriority = false)) }
        val existing = suggestion.placeID?.let { id -> all.firstOrNull { it.placeID == id } }
            ?: all.firstOrNull { it.name == suggestion.name }
        val place = existing?.copy(isPriority = true) ?: PlaceEntity(
            name = suggestion.name,
            latitude = suggestion.latitude,
            longitude = suggestion.longitude,
            radius = 100f,
            address = suggestion.address,
            isUserDefined = false,
            isPriority = true
        )
        db.placeDao().insert(place)
        return place
    }

    // ───────────────────────────── Transports ─────────────────────────────

    suspend fun findTransportMergePartner(db: AppDatabase, record: TransportRecordEntity): TransportRecordEntity? {
        val stored = db.transportRecordDao().getById(record.recordID) ?: record
        val all = db.transportRecordDao().getActiveBetween(
            Date(stored.startTime.time - TWO_DAYS_MS),
            Date(stored.endTime.time + TWO_DAYS_MS)
        ).sortedBy { it.startTime }
        val index = all.indexOfFirst { it.recordID == stored.recordID }
        if (index < 0) return null
        all.getOrNull(index - 1)?.let { if (canMergeTransports(db, it, stored)) return it }
        all.getOrNull(index + 1)?.let { if (canMergeTransports(db, stored, it)) return it }
        return null
    }

    suspend fun canMergeTransport(db: AppDatabase, record: TransportRecordEntity): Boolean =
        findTransportMergePartner(db, record) != null

    suspend fun canMergeTransports(db: AppDatabase, first: TransportRecordEntity, second: TransportRecordEntity): Boolean {
        if (first.statusRaw == "ignored" || second.statusRaw == "ignored") return false
        if (first.recordID == second.recordID) return false
        if (!isSameDay(first.startTime, second.startTime)) return false
        val lower = minOf(first.endTime, second.endTime)
        val upper = maxOf(first.startTime, second.startTime)
        if (!upper.after(lower)) return true
        return db.footprintDao().getBetween(lower, upper).isEmpty()
    }

    /** iOS mergeAdjacentTransports: earlier record survives; manualTypeRaw pinned. */
    suspend fun mergeTransports(db: AppDatabase, a: TransportRecordEntity, b: TransportRecordEntity): TransportRecordEntity {
        val sa = db.transportRecordDao().getById(a.recordID) ?: a
        val sb = db.transportRecordDao().getById(b.recordID) ?: b
        val base = if (sa.startTime <= sb.startTime) sa else sb
        val other = if (base === sa) sb else sa
        val start = minOf(base.startTime, other.startTime)
        val end = maxOf(base.endTime, other.endTime)
        val distance = base.distance + other.distance
        val durationSec = max(0L, (end.time - start.time) / 1000L)
        val avg = if (durationSec > 0) distance / durationSec else 0.0
        val steps = optSum(base.stepCount, other.stepCount)
        val explicit = base.manualTypeRaw ?: other.manualTypeRaw
        val otherEnd = other.endLocation.trim()
        val endLocation = if (otherEnd.isNotEmpty() && otherEnd != "终点" && otherEnd != "正在获取位置...") other.endLocation else base.endLocation
        val points = parseRoutePoints(base.pointsJson) + parseRoutePoints(other.pointsJson)
        val observed = points.count { it.timestamp != null }
        val inferred = TransportType.from(
            speedMs = avg,
            stepCount = steps ?: 0,
            durationSec = durationSec,
            distanceMeters = distance,
            pointCount = points.size,
            observedPointCount = observed
        ).raw
        val type = explicit ?: inferred
        val merged = base.copy(
            day = startOfDay(start),
            startTime = start,
            endTime = end,
            distance = distance,
            averageSpeed = avg,
            stepCount = steps,
            endLocation = endLocation,
            pointsJson = encodeRoutePoints(points),
            typeRaw = type,
            manualTypeRaw = type
        )
        db.transportRecordDao().update(merged)
        db.transportRecordDao().delete(other)
        track("transport_adjacent_merged")
        return merged
    }

    suspend fun mergeAdjacentTransport(db: AppDatabase, record: TransportRecordEntity): TransportRecordEntity? {
        val partner = findTransportMergePartner(db, record) ?: return null
        return mergeTransports(db, record, partner)
    }

    /** iOS transportMergeConfirmationMessage. Title: "合并相邻交通？". */
    fun transportMergeMessage(a: TransportRecordEntity, b: TransportRecordEntity): String {
        val first = if (a.startTime <= b.startTime) a else b
        val second = if (first === a) b else a
        fun loc(s: String) = s.trim().ifEmpty { "未知地点" }
        fun line(r: TransportRecordEntity): String {
            val type = TransportType.entries.firstOrNull { it.raw == (r.manualTypeRaw ?: r.typeRaw) }?.localizedName ?: "交通"
            return "${hm(r.startTime)}-${hm(r.endTime)}  $type · ${loc(r.startLocation)} → ${loc(r.endLocation)}"
        }
        return "将合并：\n${line(first)}\n${line(second)}"
    }

    /** A route point decoded from TransportRecordEntity.pointsJson ([lat, lon, tsMillis] or {lat,lon,timestamp}). */
    data class RoutePoint(val lat: Double, val lon: Double, val timestamp: Long?)

    fun parseRoutePoints(json: String): List<RoutePoint> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).mapNotNull { i ->
            when (val e = arr.get(i)) {
                is JSONArray -> {
                    var lat = e.optDouble(0, Double.NaN)
                    var lon = e.optDouble(1, Double.NaN)
                    if (abs(lat) > 90.0) { val t = lat; lat = lon; lon = t }
                    val ts = if (e.length() >= 3) normalizeTs(e.optDouble(2, 0.0)) else null
                    if (lat.isNaN() || lon.isNaN()) null else RoutePoint(lat, lon, ts)
                }
                is JSONObject -> {
                    val lat = e.optDouble("lat", e.optDouble("latitude", Double.NaN))
                    val lon = e.optDouble("lon", e.optDouble("longitude", Double.NaN))
                    val ts = normalizeTs(e.optDouble("timestamp", 0.0))
                    if (lat.isNaN() || lon.isNaN()) null else RoutePoint(lat, lon, ts)
                }
                else -> null
            }
        }
    }.getOrDefault(emptyList())

    fun encodeRoutePoints(points: List<RoutePoint>): String {
        val arr = JSONArray()
        points.forEach { p ->
            val e = JSONArray().put(p.lat).put(p.lon)
            if (p.timestamp != null) e.put(p.timestamp.toDouble())
            arr.put(e)
        }
        return arr.toString()
    }

    fun pathDistance(points: List<RoutePoint>): Double =
        points.zipWithNext { a, b -> haversine(a.lat, a.lon, b.lat, b.lon) }.sum()

    /** Port of iOS TransportSplitRouteBuilder.segments. */
    fun splitRoutes(points: List<RoutePoint>, startTime: Date, splitTime: Date, endTime: Date): Pair<List<RoutePoint>, List<RoutePoint>> {
        if (points.isEmpty()) return emptyList<RoutePoint>() to emptyList()
        if (points.size == 1) return points to points
        val duration = max(1L, endTime.time - startTime.time).toDouble()
        val splitRatio = ((splitTime.time - startTime.time) / duration).coerceIn(0.0, 1.0)
        val split = splitTime.time
        val exact = points.indexOfFirst { it.timestamp == split }
        if (exact >= 0) return points.subList(0, exact + 1) to points.subList(exact, points.size)
        val prev = points.indices.lastOrNull { points[it].timestamp?.let { t -> t < split } == true }
        val next = points.indices.firstOrNull { points[it].timestamp?.let { t -> t > split } == true }
        if (prev != null && next != null && prev < next) {
            val pt = points[prev].timestamp!!
            val nt = points[next].timestamp!!
            val span = (nt - pt).toDouble()
            val r = if (span > 0) (split - pt) / span else 0.0
            val cut = RoutePoint(
                points[prev].lat + (points[next].lat - points[prev].lat) * r,
                points[prev].lon + (points[next].lon - points[prev].lon) * r,
                split
            )
            val insertion = min(next, max(prev + 1, prev + ((next - prev) * r).roundToInt()))
            return (points.subList(0, insertion) + cut) to (listOf(cut) + points.subList(insertion, points.size))
        }
        val cutIndex = ((points.size - 1) * splitRatio).roundToInt().coerceIn(0, points.size - 1)
        return points.subList(0, cutIndex + 1) to points.subList(cutIndex, points.size)
    }

    fun canSplitTransport(record: TransportRecordEntity): Boolean =
        record.endTime.time - record.startTime.time >= MIN_TRANSPORT_SEGMENT_MS * 2

    /**
     * iOS TransportSplitView.saveSplit. Cuts pointsJson at [splitTime], recomputes distance/speed per half,
     * endpoints "中途", per-half type inferred unless the user had picked one; pins manualTypeRaw on both.
     * Returns (first, second) or null when the transport is shorter than 2 minutes.
     */
    suspend fun splitTransport(db: AppDatabase, record: TransportRecordEntity, splitTime: Date): Pair<TransportRecordEntity, TransportRecordEntity>? {
        val r = db.transportRecordDao().getById(record.recordID) ?: record
        if (!canSplitTransport(r)) return null
        val split = Date(splitTime.time.coerceIn(r.startTime.time + MIN_TRANSPORT_SEGMENT_MS, r.endTime.time - MIN_TRANSPORT_SEGMENT_MS))
        val ratio = (split.time - r.startTime.time).toDouble() / max(1L, r.endTime.time - r.startTime.time)
        val points = parseRoutePoints(r.pointsJson).ifEmpty { emptyList() }
        val (firstPts, secondPts) = splitRoutes(points, r.startTime, split, r.endTime)
        val explicit = r.manualTypeRaw
        val firstDist = pathDistance(firstPts)
        val secondDist = pathDistance(secondPts)
        val firstSteps = splitInt(r.stepCount, ratio, false)
        val secondSteps = splitInt(r.stepCount, ratio, true)
        var first = r.copy(
            endTime = split,
            day = startOfDay(r.startTime),
            endLocation = "中途",
            pointsJson = encodeRoutePoints(firstPts),
            distance = firstDist,
            averageSpeed = firstDist / max(1.0, (split.time - r.startTime.time) / 1000.0),
            stepCount = firstSteps
        )
        first = first.copy(typeRaw = explicit ?: inferType(first, firstPts)).let { it.copy(manualTypeRaw = it.typeRaw) }
        var second = TransportRecordEntity(
            recordID = UUID.randomUUID().toString(),
            day = startOfDay(split),
            startTime = split,
            endTime = r.endTime,
            startLocation = "中途",
            endLocation = r.endLocation,
            typeRaw = first.typeRaw,
            distance = secondDist,
            averageSpeed = secondDist / max(1.0, (r.endTime.time - split.time) / 1000.0),
            pointsJson = encodeRoutePoints(secondPts),
            statusRaw = "active",
            stepCount = secondSteps
        )
        second = second.copy(typeRaw = explicit ?: inferType(second, secondPts)).let { it.copy(manualTypeRaw = it.typeRaw) }
        db.transportRecordDao().update(first)
        db.transportRecordDao().insert(second)
        track("transport_split")
        return first to second
    }

    /** Editable range for the transport time-adjust sheet (iOS setupInitialRange + editableRange*). */
    suspend fun transportAdjustRange(db: AppDatabase, record: TransportRecordEntity): Pair<Date, Date> {
        val dayStart = startOfDay(record.startTime)
        val dayEnd = addDays(dayStart, 1)
        val latestAllowed = minOf(dayEnd, currentMinute())
        val threshold = (AppConfig.TRANSPORT_ALIGNMENT_THRESHOLD * 1000).toLong()
        val prev = nearestPreviousItem(db, record, record.startTime, threshold)
        var rangeStart = if (prev == null) {
            maxOf(previousItemEnd(db, record, dayStart), dayStart)
        } else {
            maxOf(dayStart, maxOf(Date(prev.startTime.time + minimumDuration(prev)), Date(record.startTime.time - threshold)))
        }
        val next = nearestNextItem(db, record, record.endTime, threshold)
        var rangeEnd = if (next == null) {
            minOf(nextItemStart(db, record, dayEnd), dayEnd)
        } else {
            minOf(dayEnd, minOf(Date(next.endTime.time - minimumDuration(next)), Date(record.endTime.time + threshold)))
        }
        rangeEnd = minOf(rangeEnd, latestAllowed)
        if (rangeEnd.time - rangeStart.time < MIN_TRANSPORT_SEGMENT_MS) {
            rangeStart = dayStart
            rangeEnd = latestAllowed
        }
        return rangeStart to rangeEnd
    }

    /**
     * iOS TransportTimeAdjustmentView.saveAdjustment: new bounds, route rebuilt from raw points,
     * adjacent connected items (within alignment threshold) follow the new boundary.
     */
    suspend fun adjustTransportTime(
        db: AppDatabase,
        context: Context,
        record: TransportRecordEntity,
        newStart: Date,
        newEnd: Date
    ): TransportRecordEntity {
        val r = db.transportRecordDao().getById(record.recordID) ?: record
        val start = roundedToMinute(newStart)
        val end = roundedToMinute(Date(max(newEnd.time, start.time + MIN_TRANSPORT_SEGMENT_MS)))
        val oldStart = r.startTime
        val oldEnd = r.endTime
        val raw = loadRawPoints(context, start, end, filtered = false)
        val route = raw.map { RoutePoint(it.latitude, it.longitude, it.timestamp.time) }
        val distance = if (route.isNotEmpty()) pathDistance(route) else r.distance
        val durationSec = (end.time - start.time) / 1000.0
        val updated = r.copy(
            startTime = start,
            endTime = end,
            day = startOfDay(start),
            manualTypeRaw = r.manualTypeRaw ?: r.typeRaw,
            pointsJson = if (route.isNotEmpty()) encodeRoutePoints(route) else r.pointsJson,
            distance = distance,
            averageSpeed = if (durationSec > 0) distance / durationSec else 0.0
        )
        val threshold = (AppConfig.TRANSPORT_ALIGNMENT_THRESHOLD * 1000).toLong()
        if (minuteKey(oldStart) != minuteKey(start)) {
            nearestPreviousItem(db, r, oldStart, threshold)?.let { item ->
                if (start.time > item.startTime.time + minimumDuration(item)) {
                    when (item) {
                        is AdjacentItem.Footprint -> db.footprintDao().update(item.fp.copy(endTime = start, statusValue = FootprintStatus.MANUAL.raw))
                        is AdjacentItem.Transport -> db.transportRecordDao().update(
                            refreshTransportMetrics(item.tr.copy(endTime = start, manualTypeRaw = item.tr.manualTypeRaw ?: item.tr.typeRaw))
                        )
                    }
                }
            }
        }
        if (minuteKey(oldEnd) != minuteKey(end)) {
            nearestNextItem(db, r, oldEnd, threshold)?.let { item ->
                if (item.endTime.time > end.time + minimumDuration(item)) {
                    when (item) {
                        is AdjacentItem.Footprint -> db.footprintDao().update(
                            item.fp.copy(startTime = end, date = startOfDay(end), statusValue = FootprintStatus.MANUAL.raw)
                        )
                        is AdjacentItem.Transport -> db.transportRecordDao().update(
                            refreshTransportMetrics(item.tr.copy(startTime = end, day = startOfDay(end), manualTypeRaw = item.tr.manualTypeRaw ?: item.tr.typeRaw))
                        )
                    }
                }
            }
        }
        db.transportRecordDao().update(updated)
        track("transport_time_adjusted")
        return updated
    }

    /** iOS deleteTransport: deletion override + remove the record. */
    suspend fun deleteTransport(db: AppDatabase, record: TransportRecordEntity) {
        val r = db.transportRecordDao().getById(record.recordID) ?: record
        db.transportManualSelectionDao().insert(
            TransportManualSelectionEntity(
                recordID = r.recordID,
                startTime = r.startTime,
                endTime = r.endTime,
                vehicleType = r.manualTypeRaw ?: r.typeRaw,
                isDeleted = true
            )
        )
        db.transportRecordDao().delete(r)
        track("transport_deleted")
    }

    /** iOS updateTransport(type:): writes manualTypeRaw and typeRaw. */
    suspend fun setTransportManualType(db: AppDatabase, record: TransportRecordEntity, type: TransportType): TransportRecordEntity {
        val r = db.transportRecordDao().getById(record.recordID) ?: record
        val updated = r.copy(manualTypeRaw = type.raw, typeRaw = type.raw)
        db.transportRecordDao().update(updated)
        track("transport_edited")
        return updated
    }

    // ───────────────────────────── Helpers ─────────────────────────────

    private sealed class AdjacentItem {
        abstract val startTime: Date
        abstract val endTime: Date
        data class Footprint(val fp: FootprintEntity) : AdjacentItem() {
            override val startTime get() = fp.startTime
            override val endTime get() = fp.endTime
        }
        data class Transport(val tr: TransportRecordEntity) : AdjacentItem() {
            override val startTime get() = tr.startTime
            override val endTime get() = tr.endTime
        }
    }

    private fun minimumDuration(item: AdjacentItem): Long = when (item) {
        is AdjacentItem.Footprint -> MIN_FOOTPRINT_DURATION_MS
        is AdjacentItem.Transport -> MIN_TRANSPORT_SEGMENT_MS
    }

    private suspend fun nearestPreviousItem(db: AppDatabase, self: TransportRecordEntity, date: Date, thresholdMs: Long): AdjacentItem? {
        val lower = Date(date.time - thresholdMs)
        val transports = db.transportRecordDao().getActiveBetween(Date(lower.time - 2 * TWO_DAYS_MS), date)
            .filter { it.recordID != self.recordID && !it.endTime.before(lower) && !it.endTime.after(date) }
            .maxByOrNull { it.endTime }?.let { AdjacentItem.Transport(it) }
        val footprints = db.footprintDao().getBetween(Date(lower.time - 2 * TWO_DAYS_MS), Date(date.time + 1))
            .filter { !it.endTime.before(lower) && !it.endTime.after(date) }
            .maxByOrNull { it.endTime }?.let { AdjacentItem.Footprint(it) }
        return listOfNotNull(transports, footprints).maxByOrNull { it.endTime }
    }

    private suspend fun nearestNextItem(db: AppDatabase, self: TransportRecordEntity, date: Date, thresholdMs: Long): AdjacentItem? {
        val upper = Date(date.time + thresholdMs)
        val transports = db.transportRecordDao().getActiveBetween(date, Date(upper.time + 2 * TWO_DAYS_MS))
            .filter { it.recordID != self.recordID && !it.startTime.before(date) && !it.startTime.after(upper) }
            .minByOrNull { it.startTime }?.let { AdjacentItem.Transport(it) }
        val footprints = db.footprintDao().getBetween(Date(date.time - 1), Date(upper.time + 2 * TWO_DAYS_MS))
            .filter { !it.startTime.before(date) && !it.startTime.after(upper) }
            .minByOrNull { it.startTime }?.let { AdjacentItem.Footprint(it) }
        return listOfNotNull(transports, footprints).minByOrNull { it.startTime }
    }

    private suspend fun previousItemEnd(db: AppDatabase, self: TransportRecordEntity, fallback: Date): Date {
        val start = self.startTime
        val t = db.transportRecordDao().getActiveBetween(fallback, start)
            .filter { it.recordID != self.recordID && !it.endTime.after(start) }.maxOfOrNull { it.endTime }
        val f = db.footprintDao().getBetween(fallback, start).filter { !it.endTime.after(start) }.maxOfOrNull { it.endTime }
        return listOfNotNull(t, f, fallback).maxOrNull() ?: fallback
    }

    private suspend fun nextItemStart(db: AppDatabase, self: TransportRecordEntity, fallback: Date): Date {
        val end = self.endTime
        val t = db.transportRecordDao().getActiveBetween(end, fallback)
            .filter { it.recordID != self.recordID && !it.startTime.before(end) }.minOfOrNull { it.startTime }
        val f = db.footprintDao().getBetween(end, fallback).filter { !it.startTime.before(end) }.minOfOrNull { it.startTime }
        return listOfNotNull(t, f, fallback).minOrNull() ?: fallback
    }

    private fun inferType(record: TransportRecordEntity, points: List<RoutePoint>): String {
        val durationSec = max(0L, (record.endTime.time - record.startTime.time) / 1000L)
        return TransportType.from(
            speedMs = record.averageSpeed,
            stepCount = record.stepCount ?: 0,
            durationSec = durationSec,
            distanceMeters = record.distance,
            pointCount = points.size,
            observedPointCount = points.count { it.timestamp != null }
        ).raw
    }

    /** iOS refreshTransportMetrics: clip route to the new bounds; empty interval → ignored. */
    fun refreshTransportMetrics(record: TransportRecordEntity): TransportRecordEntity {
        if (!record.endTime.after(record.startTime)) return record.copy(statusRaw = "ignored")
        var r = record
        val pts = parseRoutePoints(record.pointsJson)
        val filtered = pts.filter { p -> p.timestamp == null || (p.timestamp >= record.startTime.time && p.timestamp <= record.endTime.time) }
        if (filtered.isNotEmpty()) {
            r = r.copy(pointsJson = encodeRoutePoints(filtered), distance = pathDistance(filtered))
        }
        val duration = (r.endTime.time - r.startTime.time) / 1000.0
        return if (duration > 0) r.copy(averageSpeed = r.distance / duration) else r
    }

    private fun coordinatesFor(
        raw: List<RawLocationStore.RawPoint>,
        fp: FootprintEntity,
        start: Date,
        end: Date,
        fallbackStartRatio: Double,
        fallbackEndRatio: Double
    ): Pair<String, String>? {
        val inRange = raw.filter { !it.timestamp.before(start) && !it.timestamp.after(end) }
        if (inRange.isNotEmpty()) {
            return JSONArray(inRange.map { it.latitude }).toString() to JSONArray(inRange.map { it.longitude }).toString()
        }
        val lats = jsonDoubles(fp.latitudeJson)
        val lons = jsonDoubles(fp.longitudeJson)
        val count = min(lats.size, lons.size)
        if (count == 0) return null
        val last = count - 1
        val s = (last * fallbackStartRatio).roundToInt().coerceIn(0, last)
        val e = (last * fallbackEndRatio).roundToInt().coerceIn(s, last)
        return JSONArray(lats.subList(s, e + 1)).toString() to JSONArray(lons.subList(s, e + 1)).toString()
    }

    private fun manualHash(hash: String) =
        if (hash == "ONGOING_STAY" || hash.startsWith("GAP_STAY")) "MANUAL_STAY" else hash

    fun representativeCoordinate(fp: FootprintEntity): Pair<Double, Double>? {
        val lats = jsonDoubles(fp.latitudeJson).filter(Double::isFinite)
        val lons = jsonDoubles(fp.longitudeJson).filter(Double::isFinite)
        if (lats.isEmpty() || lons.isEmpty()) return null
        return lats.average() to lons.average()
    }

    fun jsonDoubles(json: String): List<Double> = runCatching {
        val a = JSONArray(json)
        (0 until a.length()).map { a.getDouble(it) }
    }.getOrDefault(emptyList())

    fun jsonStrings(json: String): List<String> = runCatching {
        val a = JSONArray(json)
        (0 until a.length()).mapNotNull { a.optString(it).takeIf(String::isNotBlank) }
    }.getOrDefault(emptyList())

    fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private fun normalizeTs(raw: Double): Long? {
        if (raw <= 0.0) return null
        return if (raw < 10_000_000_000.0) (raw * 1000).toLong() else raw.toLong()
    }

    private fun optSum(a: Int?, b: Int?): Int? = if (a == null && b == null) null else (a ?: 0) + (b ?: 0)
    private fun optSum(a: Double?, b: Double?): Double? = if (a == null && b == null) null else (a ?: 0.0) + (b ?: 0.0)

    private fun splitInt(value: Int?, ratio: Double, second: Boolean): Int? {
        value ?: return null
        val first = (value * ratio).roundToInt()
        return if (second) max(0, value - first) else first
    }

    private fun splitDouble(value: Double?, ratio: Double, second: Boolean): Double? {
        value ?: return null
        val first = value * ratio
        return if (second) max(0.0, value - first) else first
    }

    fun startOfDay(date: Date): Date = Calendar.getInstance().apply {
        time = date
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.time

    private fun addDays(date: Date, days: Int): Date = Calendar.getInstance().apply { time = date; add(Calendar.DATE, days) }.time

    fun isSameDay(a: Date, b: Date): Boolean = startOfDay(a) == startOfDay(b)

    private fun isSameDayFootprint(fp: FootprintEntity) = isSameDay(fp.startTime, Date(fp.endTime.time - 1))

    fun touchedDates(start: Date, end: Date): List<Date> {
        val result = mutableListOf<Date>()
        var cursor = startOfDay(start)
        val last = startOfDay(Date(max(start.time, end.time - 1)))
        while (!cursor.after(last)) {
            result += cursor
            cursor = addDays(cursor, 1)
        }
        return result
    }

    fun roundedToMinute(date: Date): Date = Date((date.time / 60_000.0).roundToLong() * 60_000L)
    fun currentMinute(): Date = Date(System.currentTimeMillis() / 60_000L * 60_000L)
    private fun minuteKey(date: Date): Long = (date.time / 60_000.0).roundToLong()
    private fun hm(date: Date): String = SimpleDateFormat("HH:mm", Locale.getDefault()).format(date)

    /** Analytics + home widget refresh after every persisted edit. */
    private fun track(event: String?) {
        if (event != null) runCatching { Aptabase.instance.trackEvent(event) }
        runCatching {
            com.ct106.difangke.widget.FootprintWidgetUpdater.requestUpdate(com.ct106.difangke.DiFangKeApp.instance)
        }
    }
}
