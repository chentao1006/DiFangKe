package com.ct106.difangke.service.tracking

import android.util.Log
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.service.PlaceMatcher
import com.google.gson.Gson
import java.util.Calendar
import java.util.Date
import java.util.UUID

/**
 * Database side of live footprint handling (iOS `handleNewCandidateFootprint`,
 * `mergeRecentFootprints`, `Footprint.extendActivityEditedStay`,
 * `checkAndSendNewPlaceNotification`).
 */
class LiveFootprintStore(private val db: AppDatabase) {
    private val gson = Gson()

    data class Candidate(
        val startMs: Long,
        val endMs: Long,
        val points: List<TrackingFix>
    ) {
        val center: Pair<Double, Double>
            get() = GeoMath.center(points.map { it.latitude to it.longitude }) ?: (0.0 to 0.0)
    }

    data class Outcome(val created: FootprintEntity?, val changed: Boolean)

    fun summaryOf(fp: FootprintEntity): FootprintSummary {
        val c = centerOf(fp)
        return FootprintSummary(fp.footprintID, fp.startTime.time, fp.endTime.time, c?.first, c?.second, fp.placeID, fp.statusValue)
    }

    fun centerOf(fp: FootprintEntity): Pair<Double, Double>? {
        val lats = parseDoubles(fp.latitudeJson)
        val lons = parseDoubles(fp.longitudeJson)
        if (lats.isEmpty() || lons.isEmpty()) return null
        return lats.average() to lons.average()
    }

    private fun parseDoubles(json: String?): List<Double> =
        runCatching { gson.fromJson(json ?: "[]", Array<Double>::class.java)?.toList() ?: emptyList() }
            .getOrDefault(emptyList())

    private fun parseStrings(json: String?): List<String> =
        runCatching { gson.fromJson(json ?: "[]", Array<String>::class.java)?.toList() ?: emptyList() }
            .getOrDefault(emptyList())

    private fun dayBounds(ms: Long): Pair<Date, Date> {
        val cal = Calendar.getInstance().apply {
            timeInMillis = ms
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val start = cal.time
        cal.add(Calendar.DAY_OF_YEAR, 1)
        return start to cal.time
    }

    /** iOS `mergeRecentFootprints(in:)`. Returns true when anything merged. */
    suspend fun mergeRecentFootprints(nowMs: Long = System.currentTimeMillis()): Boolean {
        val (dayStart, dayEnd) = dayBounds(nowMs)
        val today = db.footprintDao().getForDay(dayStart, dayEnd).filter { it.startTime >= dayStart }
        val byID = today.associateBy { it.footprintID }.toMutableMap()
        val transports = db.transportRecordDao().getForDay(dayStart, dayEnd)
            .map { TimeSpan(it.startTime.time, it.endTime.time) }
        val plan = LiveFootprintRules.planRecentMerges(today.map(::summaryOf), transports, nowMs)
        if (plan.isEmpty()) return false
        for ((keeperID, absorbedID) in plan) {
            val base = byID[keeperID] ?: continue
            val next = byID[absorbedID] ?: continue
            val photos = (parseStrings(base.photoAssetIDsJson) + parseStrings(next.photoAssetIDsJson)).distinct()
            val merged = base.copy(
                endTime = maxOf(base.endTime, next.endTime),
                latitudeJson = gson.toJson(parseDoubles(base.latitudeJson) + parseDoubles(next.latitudeJson)),
                longitudeJson = gson.toJson(parseDoubles(base.longitudeJson) + parseDoubles(next.longitudeJson)),
                photoAssetIDsJson = gson.toJson(photos),
                activityTypeValue = base.activityTypeValue ?: next.activityTypeValue
            )
            db.footprintDao().update(merged)
            db.footprintDao().delete(next)
            byID[keeperID] = merged
            byID.remove(absorbedID)
        }
        Log.i(TAG, "Live merge folded ${plan.size} footprint(s)")
        return true
    }

    /**
     * iOS `Footprint.extendActivityEditedStay`: an activity/metadata-edited
     * manual stay keeps growing while the user is still there.
     */
    suspend fun extendActivityEditedStay(startMs: Long, endMs: Long, lat: Double, lon: Double): Boolean {
        if (endMs <= startMs) return false
        val earliestPreviousEnd = startMs - (TrackingConfig.EDITED_STAY_EXTENSION_LOOKBACK * 1000).toLong()
        val (dayStart, dayEnd) = dayBounds(endMs - 1)
        val dayFootprints = db.footprintDao().getForDay(dayStart, dayEnd)
        val existing = dayFootprints
            .filter {
                it.statusValue == "manual" && it.allowsAutomaticDurationExtension &&
                    it.startTime.time <= startMs && it.endTime.time >= earliestPreviousEnd && it.endTime.time < endMs
            }
            .maxByOrNull { it.startTime }
            ?: return false
        if (!LiveFootprintRules.sameDay(existing.startTime.time, endMs - 1)) return false
        val center = centerOf(existing) ?: return false
        if (GeoMath.distance(center.first, center.second, lat, lon) >= TrackingConfig.STAY_DISTANCE_THRESHOLD) return false
        val extensionStart = existing.endTime.time
        val blockedByStay = dayFootprints.any {
            it.footprintID != existing.footprintID && it.startTime.time < endMs && it.endTime.time > extensionStart
        }
        val blockedByTrip = db.transportRecordDao().getActiveBetween(Date(extensionStart), Date(endMs)).isNotEmpty()
        if (blockedByStay || blockedByTrip) return false
        db.footprintDao().update(existing.copy(endTime = Date(endMs)))
        return true
    }

    /**
     * iOS `handleNewCandidateFootprint`: clamp to day, extend an edited stay,
     * clip around manual stays, merge into the latest compatible footprint or
     * create a new one (status ignored for an ignored place).
     */
    suspend fun saveCandidate(
        candidate: Candidate,
        overridePlaceID: String?,
        overrideName: String?,
        currentAddress: String?,
        resolveAddress: suspend (Double, Double) -> String?
    ): Outcome {
        val bounded = LiveFootprintRules.clampToStartDay(candidate.startMs, candidate.endMs) ?: return Outcome(null, false)
        val boundedPoints = candidate.points.filter { it.timeMs in bounded.startMs..bounded.endMs }
            .ifEmpty { candidate.points }
        val c = Candidate(bounded.startMs, bounded.endMs, boundedPoints)
        val (lat, lon) = c.center

        if (extendActivityEditedStay(c.startMs, c.endMs, lat, lon)) return Outcome(null, true)

        val (dayStart, dayEnd) = dayBounds(c.startMs)
        val dayFootprints = db.footprintDao().getForDay(dayStart, dayEnd)
        val manual = dayFootprints.filter { it.statusValue == "manual" }
            .map { TimeSpan(it.startTime.time, it.endTime.time) }
        val pieces = LiveFootprintRules.automaticIntervals(c.startMs, c.endMs, manual)
        if (pieces.size != 1 || pieces[0] != TimeSpan(c.startMs, c.endMs)) {
            var created: FootprintEntity? = null
            var changed = false
            for (piece in pieces) {
                if ((piece.endMs - piece.startMs) / 1000.0 < TrackingConfig.STAY_DURATION_THRESHOLD) continue
                val pts = c.points.filter { it.timeMs in piece.startMs..piece.endMs }
                if (pts.isEmpty()) continue
                val r = saveCandidate(Candidate(piece.startMs, piece.endMs, pts), overridePlaceID, overrideName, currentAddress, resolveAddress)
                created = created ?: r.created
                changed = changed || r.changed
            }
            return Outcome(created, changed)
        }

        val places = db.placeDao().getAll()
        val ignored = PlaceMatcher.ignoredPlaceForCoordinate(lat, lon, places)
        val matched: PlaceEntity? = overridePlaceID?.let { id -> places.firstOrNull { it.placeID == id && !it.isIgnored } }
            ?: PlaceMatcher.bestPlaceForCoordinate(lat, lon, places)

        val todays = dayFootprints.filter { it.startTime >= dayStart }
        val last = todays.maxByOrNull { it.startTime }
        if (last != null && LiveFootprintRules.shouldMergeCandidate(summaryOf(last), c.startMs, lat, lon, matched?.placeID)) {
            db.footprintDao().update(extend(last, c, matched, overridePlaceID, overrideName, dayStart, dayEnd))
            return Outcome(null, true)
        }

        // An ongoing stay at an ignored place keeps extending its own hidden
        // row (ignored rows are excluded from getForDay, so `last` never sees it).
        if (ignored != null) {
            val ignoredRows = db.footprintDao().getIgnoredBetween(dayStart, dayEnd)
            val target = LiveFootprintRules.ignoredFootprintToExtend(
                ignoredRows.map(::summaryOf), todays.map(::summaryOf), c.startMs, lat, lon, matched?.placeID ?: ignored.placeID
            )?.let { s -> ignoredRows.firstOrNull { it.footprintID == s.id } }
            if (target != null) {
                db.footprintDao().update(extend(target, c, null, null, null, dayStart, dayEnd))
                return Outcome(null, true)
            }
        }

        val address = when {
            matched != null -> overrideName ?: matched.name
            !currentAddress.isNullOrBlank() -> currentAddress
            else -> resolveAddress(lat, lon)
        }
        val entity = FootprintEntity(
            footprintID = UUID.randomUUID().toString(),
            date = dayStart,
            startTime = Date(c.startMs),
            endTime = Date(c.endMs),
            latitudeJson = gson.toJson(c.points.map { it.latitude }),
            longitudeJson = gson.toJson(c.points.map { it.longitude }),
            locationHash = FootprintEntity.generateLocationHash(lat, lon),
            title = FootprintTitles.generate(address ?: "此处", c.startMs / 1000),
            statusValue = if (ignored != null) "ignored" else "candidate",
            placeID = matched?.placeID ?: ignored?.placeID,
            address = address,
            activityTypeValue = matched?.let { frequentActivityType(it.placeID, c.startMs) },
            isAddressEditedByHand = matched != null && overridePlaceID == matched.placeID
        )
        db.footprintDao().insert(entity)
        return Outcome(entity.takeIf { ignored == null }, true)
    }

    /** Grow [last] to cover [c] (iOS merge into existing footprint). */
    private fun extend(
        last: FootprintEntity,
        c: Candidate,
        matched: PlaceEntity?,
        overridePlaceID: String?,
        overrideName: String?,
        dayStart: Date,
        dayEnd: Date
    ): FootprintEntity {
        val newEnd = minOf(maxOf(last.endTime.time, c.endMs), dayEnd.time)
        val newStart = maxOf(minOf(last.startTime.time, c.startMs), dayStart.time)
        val grew = newEnd > last.endTime.time || newStart < last.startTime.time
        // Only append samples outside the already-covered interval so a
        // repeatedly refreshed ongoing stay does not duplicate coordinates.
        val fresh = c.points.filter { it.timeMs > last.endTime.time || it.timeMs < last.startTime.time }
        var updated = last.copy(
            startTime = Date(newStart),
            endTime = Date(newEnd),
            date = dayBounds(newStart).first,
            latitudeJson = if (grew) gson.toJson(parseDoubles(last.latitudeJson) + fresh.map { it.latitude }) else last.latitudeJson,
            longitudeJson = if (grew) gson.toJson(parseDoubles(last.longitudeJson) + fresh.map { it.longitude }) else last.longitudeJson
        )
        if (matched != null) {
            val isOverride = overridePlaceID == matched.placeID
            updated = updated.copy(placeID = matched.placeID)
            if (last.isAddressEditedByHand || isOverride || last.address.isNullOrEmpty()) {
                updated = updated.copy(
                    address = overrideName ?: matched.name,
                    isAddressEditedByHand = last.isAddressEditedByHand || isOverride
                )
            }
        }
        return updated
    }

    /**
     * iOS `resolveFrequentActivityType`: same place, ±120 min time-of-day, at
     * least 3 occurrences; otherwise the overall most common with ≥3.
     */
    private suspend fun frequentActivityType(placeID: String, startMs: Long): String? {
        val history = db.footprintDao().getAll()
            .filter { it.placeID == placeID && !it.activityTypeValue.isNullOrBlank() && it.statusValue != "ignored" }
        if (history.isEmpty()) return null
        val minuteOfDay = { ms: Long ->
            Calendar.getInstance().apply { timeInMillis = ms }.let { it.get(Calendar.HOUR_OF_DAY) * 60 + it.get(Calendar.MINUTE) }
        }
        val target = minuteOfDay(startMs)
        fun best(list: List<FootprintEntity>) = list.groupingBy { it.activityTypeValue!! }.eachCount()
            .filter { it.value >= 3 }.maxByOrNull { it.value }?.key
        val nearTime = history.filter {
            val diff = kotlin.math.abs(minuteOfDay(it.startTime.time) - target)
            minOf(diff, 1440 - diff) <= 120
        }
        return best(nearTime) ?: best(history)
    }

    /** iOS new-place rule: no earlier footprint with the same place ID or within 200 m. */
    suspend fun isFirstVisit(footprint: FootprintEntity): Boolean {
        val center = centerOf(footprint) ?: return false
        val history = db.footprintDao().getAll()
            .filter { it.startTime < footprint.startTime && it.footprintID != footprint.footprintID }
            .map(::summaryOf)
        return LiveFootprintRules.isFirstVisit(
            history, footprint.startTime.time, center.first, center.second, footprint.placeID, footprint.footprintID
        )
    }

    companion object {
        private const val TAG = "LiveFootprintStore"
    }
}
