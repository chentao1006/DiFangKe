package com.ct106.difangke.service.tracking

import java.util.Calendar
import java.util.TimeZone

/** Minimal view of a footprint used by the pure live-merge rules. */
data class FootprintSummary(
    val id: String,
    val startMs: Long,
    val endMs: Long,
    val latitude: Double?,
    val longitude: Double?,
    val placeID: String?,
    val status: String
)

data class TimeSpan(val startMs: Long, val endMs: Long)

/** Pure rules behind live footprint merging and new-place notifications. */
object LiveFootprintRules {

    /**
     * iOS `mergeRecentFootprints`: among today's non-ignored footprints, take
     * the last 5 ending within 30 min of now and fold same-place neighbours.
     *
     * @return list of (keeperID, absorbedID) in application order
     */
    fun planRecentMerges(
        todayFootprints: List<FootprintSummary>,
        transports: List<TimeSpan>,
        nowMs: Long,
        timeZone: TimeZone = TimeZone.getDefault()
    ): List<Pair<String, String>> {
        val cutoff = nowMs - (TrackingConfig.MERGE_RECENT_FOOTPRINTS_LOOKBACK * 1000).toLong()
        val recent = todayFootprints
            .filter { it.status != "ignored" }
            .sortedBy { it.startMs }
            .filter { it.endMs >= cutoff }
            .takeLast(TrackingConfig.MERGE_RECENT_FOOTPRINTS_MAX)
            .toMutableList()
        if (recent.size < 2) return emptyList()

        val merges = mutableListOf<Pair<String, String>>()
        var i = 0
        while (i < recent.size - 1) {
            val base = recent[i]
            val next = recent[i + 1]
            if (base.status == "manual" || next.status == "manual") { i++; continue }
            val sameDay = sameDay(base.startMs, base.endMs - 1, timeZone) &&
                sameDay(next.startMs, next.endMs - 1, timeZone) &&
                sameDay(base.startMs, next.startMs, timeZone)
            if (!sameDay) { i++; continue }
            if (transports.any { it.endMs > base.endMs && it.startMs < next.startMs }) { i++; continue }
            val gap = (next.startMs - base.endMs) / 1000.0
            if (gap > TrackingConfig.STAY_MERGE_GAP_THRESHOLD) { i++; continue }
            val samePlace = (base.placeID != null && base.placeID == next.placeID) ||
                (base.latitude != null && base.longitude != null && next.latitude != null && next.longitude != null &&
                    GeoMath.distance(base.latitude, base.longitude, next.latitude, next.longitude) <=
                    TrackingConfig.MERGE_DISTANCE_THRESHOLD)
            if (samePlace) {
                merges += base.id to next.id
                recent[i] = base.copy(endMs = maxOf(base.endMs, next.endMs))
                recent.removeAt(i + 1)
            } else {
                i++
            }
        }
        return merges
    }

    /**
     * iOS `checkAndSendNewPlaceNotification`: a place is new when no earlier
     * footprint shares its place ID or lies within 200 m.
     */
    fun isFirstVisit(
        history: List<FootprintSummary>,
        startMs: Long,
        latitude: Double,
        longitude: Double,
        placeID: String?,
        excludeID: String? = null
    ): Boolean = history.none { fp ->
        if (fp.id == excludeID || fp.startMs >= startMs) return@none false
        if (placeID != null && fp.placeID == placeID) return@none true
        val lat = fp.latitude ?: return@none false
        val lon = fp.longitude ?: return@none false
        GeoMath.distance(latitude, longitude, lat, lon) < TrackingConfig.NEW_PLACE_HISTORY_RADIUS
    }

    /**
     * The ignored footprint an ignored-place candidate should extend instead of
     * inserting a new hidden row: the latest ignored row of the day, matched with
     * the same rule as visible footprints ([shouldMergeCandidate], keyed by the
     * ignored place ID), and never bridging over a visible stay recorded after it.
     */
    fun ignoredFootprintToExtend(
        ignoredFootprints: List<FootprintSummary>,
        visibleFootprints: List<FootprintSummary>,
        candidateStartMs: Long,
        candidateLat: Double,
        candidateLon: Double,
        ignoredPlaceID: String?
    ): FootprintSummary? {
        val last = ignoredFootprints.maxByOrNull { it.startMs } ?: return null
        if (visibleFootprints.any { it.startMs >= last.endMs && it.startMs < candidateStartMs }) return null
        return last.takeIf { shouldMergeCandidate(it, candidateStartMs, candidateLat, candidateLon, ignoredPlaceID) }
    }

    /** iOS `shouldMergeExistingFootprint` for a new live candidate. */
    fun shouldMergeCandidate(
        last: FootprintSummary,
        candidateStartMs: Long,
        candidateLat: Double,
        candidateLon: Double,
        matchedPlaceID: String?
    ): Boolean {
        if (last.status == "manual") return false
        val gap = (candidateStartMs - last.endMs) / 1000.0
        if (matchedPlaceID != null && last.placeID == matchedPlaceID) {
            return gap < maxOf(TrackingConfig.LIVE_STAY_MERGE_TIME_THRESHOLD, TrackingConfig.SAME_PLACE_MERGE_GAP_THRESHOLD)
        }
        if (gap >= TrackingConfig.STAY_MERGE_GAP_THRESHOLD) return false
        val lat = last.latitude ?: return false
        val lon = last.longitude ?: return false
        return GeoMath.distance(lat, lon, candidateLat, candidateLon) < TrackingConfig.MERGE_DISTANCE_THRESHOLD
    }

    /**
     * Simplified iOS `Footprint.automaticStayIntervals`: manual footprints own
     * their interval; a candidate is clipped around them. Pieces shorter than
     * the stay threshold are dropped by the caller.
     */
    fun automaticIntervals(startMs: Long, endMs: Long, manual: List<TimeSpan>): List<TimeSpan> {
        var pieces = listOf(TimeSpan(startMs, endMs))
        for (m in manual.sortedBy { it.startMs }) {
            pieces = pieces.flatMap { p ->
                if (m.endMs <= p.startMs || m.startMs >= p.endMs) listOf(p)
                else listOfNotNull(
                    TimeSpan(p.startMs, m.startMs).takeIf { it.endMs > it.startMs },
                    TimeSpan(m.endMs, p.endMs).takeIf { it.endMs > it.startMs }
                )
            }
        }
        return pieces
    }

    /** Clamp an interval to the calendar day of its start (footprints never cross midnight). */
    fun clampToStartDay(startMs: Long, endMs: Long, timeZone: TimeZone = TimeZone.getDefault()): TimeSpan? {
        val cal = Calendar.getInstance(timeZone).apply {
            timeInMillis = startMs
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val dayStart = cal.timeInMillis
        cal.add(Calendar.DAY_OF_YEAR, 1)
        val dayEnd = cal.timeInMillis
        val s = maxOf(startMs, dayStart)
        val e = minOf(maxOf(endMs, s), dayEnd)
        return if (e > s) TimeSpan(s, e) else null
    }

    fun sameDay(a: Long, b: Long, timeZone: TimeZone = TimeZone.getDefault()): Boolean {
        val ca = Calendar.getInstance(timeZone).apply { timeInMillis = a }
        val cb = Calendar.getInstance(timeZone).apply { timeInMillis = b }
        return ca.get(Calendar.YEAR) == cb.get(Calendar.YEAR) &&
            ca.get(Calendar.DAY_OF_YEAR) == cb.get(Calendar.DAY_OF_YEAR)
    }

    /**
     * Earliest sample of the contiguous run (walking backwards from the newest
     * sample) that stays within [radius] of the stay centre, tolerating sample
     * gaps up to [maxGapMs]. Used to backfill the real arrival time of a stay
     * that was only recognised after the UI moving hold expired.
     */
    fun earliestContiguousStayStart(
        points: List<TrackingFix>,
        centerLat: Double,
        centerLon: Double,
        radius: Double,
        maxGapMs: Long,
        lowerBoundMs: Long
    ): TrackingFix? {
        var earliest: TrackingFix? = null
        var later: TrackingFix? = null
        for (p in points.filter { it.timeMs >= lowerBoundMs }.sortedBy { it.timeMs }.asReversed()) {
            if (later != null && later.timeMs - p.timeMs > maxGapMs) break
            if (p.distanceTo(centerLat, centerLon) <= radius) {
                earliest = p
                later = p
            } else if (earliest != null) {
                break
            }
        }
        return earliest
    }
}
