package com.ct106.difangke.service.timeline

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.location.RawLocationStore.RawPoint
import java.util.Date
import kotlin.math.abs
import kotlin.math.max

/** Manual-boundary semantics ported from iOS Models/Footprint.swift. */
object FootprintRules {

    /**
     * Manual stays own their time ranges. A replay within ±300 s at both ends is the
     * same stay (fully suppressed); otherwise the automatic interval is clipped.
     */
    fun automaticStayIntervals(start: Date, end: Date, manuals: List<WFootprint>): List<Pair<Date, Date>> {
        if (end <= start) return emptyList()
        val overlapping = manuals.filter { it.isManual && it.startTime < end && it.endTime > start }
        if (overlapping.any { abs(secs(start, it.startTime)) <= 300 && abs(secs(end, it.endTime)) <= 300 }) return emptyList()
        var intervals = listOf(start to end)
        for (manual in overlapping) {
            intervals = intervals.flatMap { (s, e) ->
                if (!(manual.startTime < e && manual.endTime > s)) return@flatMap listOf(s to e)
                val remaining = mutableListOf<Pair<Date, Date>>()
                if (s < manual.startTime) remaining.add(s to manual.startTime)
                if (manual.endTime < e) remaining.add(manual.endTime to e)
                remaining
            }
        }
        return intervals
    }

    fun automaticStayIntervals(start: Date, end: Date, ws: TimelineWorkspace): List<Pair<Date, Date>> =
        automaticStayIntervals(start, end, ws.footprints.filter { it.isManual && it.startTime < end && it.endTime > start })

    fun removeAutomaticFootprintsOwnedByManual(footprints: List<WFootprint>, ws: TimelineWorkspace): Set<String> {
        val manuals = footprints.filter { it.isManual }
        val removed = mutableSetOf<String>()
        for (fp in footprints) {
            if (fp.isManual || fp.isIgnored || fp.endTime <= fp.startTime) continue
            if (automaticStayIntervals(fp.startTime, fp.endTime, manuals).isNotEmpty()) continue
            removed.add(fp.id)
            ws.deleteFootprint(fp)
        }
        return removed
    }

    fun absorbAdjacentAutomaticContinuations(footprints: List<WFootprint>, transports: List<WTransport>, ws: TimelineWorkspace): Boolean {
        val ordered = footprints.filter { !it.isIgnored }.sortedBy { it.startTime }.toMutableList()
        var changed = false
        var index = 0
        val radius = AppConfig.STAY_DISTANCE_THRESHOLD
        while (index + 1 < ordered.size) {
            val keeper = ordered[index]
            val next = ordered[index + 1]
            val gap = secs(keeper.endTime, next.startTime)
            val samePlace = (keeper.placeID != null && keeper.placeID == next.placeID) ||
                GeoMath.distance(keeper.latitude, keeper.longitude, next.latitude, next.longitude) < radius
            val tripBetween = transports.any { it.statusRaw != "ignored" && it.startTime < next.endTime && it.endTime > keeper.endTime }
            val manualBoundary = ordered.any {
                it.id != keeper.id && it.id != next.id && it.isManual && it.startTime >= keeper.endTime && it.startTime <= next.endTime
            }
            if (!(keeper.isManual && !next.isManual && isSameDay(keeper.startTime, next.startTime) &&
                    gap >= -60 && gap <= 5 * 60 && samePlace && !tripBetween && !manualBoundary)
            ) {
                index += 1
                continue
            }
            keeper.endTime = maxDate(keeper.endTime, next.endTime)
            keeper.appendLocations(next.lats, next.lons)
            keeper.mergePhotos(next.photos)
            keeper.allowsAutomaticDurationExtension = true
            ws.deleteFootprint(next)
            ordered.removeAt(index + 1)
            changed = true
        }
        return changed
    }

    /**
     * iOS Footprint.extendActivityEditedStay. [live] replaces LocationManager state;
     * pass null when no live tracking context is available.
     */
    fun extendActivityEditedStay(
        start: Date, end: Date, lat: Double, lon: Double,
        ws: TimelineWorkspace, live: LiveStayContext?, now: Date
    ): Boolean {
        if (end <= start) return false
        val anchor = live?.anchor
        val activeCurrentStay = isSameDay(end, now) && live != null && !live.uiIsMoving && anchor != null &&
            anchor.timestamp <= start && anchor.distanceTo(lat, lon) < AppConfig.STAY_DISTANCE_THRESHOLD
        val earliestPreviousEnd = if (activeCurrentStay) startOfDay(start) else start.plusSeconds(-5 * 60.0)
        val existing = ws.footprints.filter {
            if (activeCurrentStay) {
                it.isManual && it.startTime <= end && it.endTime >= earliestPreviousEnd && it.endTime < end
            } else {
                it.isManual && it.allowsAutomaticDurationExtension &&
                    it.startTime <= start && it.endTime >= earliestPreviousEnd && it.endTime < end
            }
        }.maxByOrNull { it.startTime } ?: return false
        if (!isSameDay(existing.startTime, end.plusSeconds(-0.001))) return false
        if (!existing.hasLocations) return false
        if (GeoMath.distance(existing.latitude, existing.longitude, lat, lon) >= AppConfig.STAY_DISTANCE_THRESHOLD) return false
        if (activeCurrentStay && anchor != null && anchor.timestamp > existing.endTime) {
            if (!existing.allowsAutomaticDurationExtension || secs(existing.endTime, anchor.timestamp) > 5 * 60) return false
        }
        val extensionStart = existing.endTime
        if (ws.footprints.any { it.id != existing.id && !it.isIgnored && it.startTime < end && it.endTime > extensionStart }) return false
        if (ws.transports.any { it.statusRaw != "ignored" && it.startTime < end && it.endTime > extensionStart }) return false
        existing.endTime = end
        if (activeCurrentStay) existing.allowsAutomaticDurationExtension = true
        return true
    }

    /** iOS Footprint.continueCurrentEditedStay. */
    fun continueCurrentEditedStay(
        manual: WFootprint, anchor: RawPoint, current: RawPoint, rawPoints: List<RawPoint>,
        ws: TimelineWorkspace, holdingStationaryStay: Boolean, now: Date
    ): Boolean {
        if (!(manual.isManual && isSameDay(manual.endTime, now) && anchor.timestamp <= manual.endTime &&
                current.timestamp >= manual.endTime && manual.hasLocations)
        ) return false
        val cLat = manual.latitude; val cLon = manual.longitude
        val radius = AppConfig.STAY_DISTANCE_THRESHOLD
        if (anchor.distanceTo(cLat, cLon) >= radius || current.distanceTo(cLat, cLon) >= radius) return false

        val allStays = ws.footprints.toList()
        val allTransports = ws.transports.toList()
        val ownID = manual.id
        if (allStays.any {
                it.id != ownID && it.isManual && it.startTime >= manual.endTime.plusSeconds(-5 * 60.0) &&
                    it.startTime <= current.timestamp
            }) return false
        if (allStays.any {
                it.id != ownID && it.isManual && abs(secs(manual.startTime, it.endTime)) <= 5 * 60 &&
                    GeoMath.distance(cLat, cLon, it.latitude, it.longitude) < radius
            }) return false

        var changed = false
        val continuation = rawPoints.filter {
            it.timestamp >= manual.endTime && it.timestamp <= current.timestamp &&
                it.accuracy > 0 && it.accuracy < AppConfig.HABIT_ANALYSIS_ACCURACY_THRESHOLD
        }
        val nearbyCount = continuation.count { it.distanceTo(cLat, cLon) < radius }
        val observedContinuation = continuation.size >= 2 && nearbyCount * 5 >= continuation.size * 4 &&
            continuation.all { it.distanceTo(cLat, cLon) < max(500.0, radius * 2) }
        val successorGap = max(5 * 60.0, secs(manual.endTime, current.timestamp))
        val adjacentAutomaticStay = allStays.any {
            it.id != ownID && !it.isManual && !it.isIgnored &&
                it.startTime >= manual.endTime.plusSeconds(-60.0) &&
                it.startTime <= manual.endTime.plusSeconds(successorGap) &&
                GeoMath.distance(cLat, cLon, it.latitude, it.longitude) < radius
        }
        if (!(observedContinuation || adjacentAutomaticStay || (holdingStationaryStay && manual.allowsAutomaticDurationExtension))) return false

        val absorbed = mutableSetOf<String>()
        while (true) {
            val next = allStays.filter {
                it.id != ownID && it.id !in absorbed && !it.isManual && !it.isIgnored &&
                    it.startTime >= manual.endTime.plusSeconds(-60.0) &&
                    it.startTime <= manual.endTime.plusSeconds(successorGap)
            }.minByOrNull { it.startTime } ?: break
            val ok = next.endTime <= minDate(now, current.timestamp.plusSeconds(60.0)) &&
                GeoMath.distance(cLat, cLon, next.latitude, next.longitude) < radius &&
                allStays.none {
                    it.id != ownID && it.id != next.id && it.id !in absorbed && !it.isIgnored &&
                        it.startTime < next.startTime && it.endTime > manual.endTime
                } &&
                allTransports.none { it.statusRaw != "ignored" && it.startTime < next.endTime && it.endTime > manual.endTime }
            if (!ok) break
            manual.endTime = maxDate(manual.endTime, next.endTime)
            manual.appendLocations(next.lats, next.lons)
            manual.mergePhotos(next.photos)
            absorbed.add(next.id)
            ws.deleteFootprint(next)
            changed = true
        }

        fun freeUntil(t: Date) =
            allStays.none { it.id != ownID && it.id !in absorbed && !it.isIgnored && it.startTime < t && it.endTime > manual.endTime } &&
                allTransports.none { it.statusRaw != "ignored" && it.startTime < t && it.endTime > manual.endTime }

        val latest = continuation.lastOrNull { it.distanceTo(cLat, cLon) < radius }?.timestamp
        if (latest == null) {
            val wasExtendable = manual.allowsAutomaticDurationExtension
            manual.allowsAutomaticDurationExtension = true
            if (holdingStationaryStay && freeUntil(now) && now > manual.endTime) {
                manual.endTime = now
                changed = true
            }
            return changed || !wasExtendable
        }
        val remainingStay = allStays.any {
            it.id != ownID && it.id !in absorbed && !it.isIgnored && it.startTime < latest && it.endTime > manual.endTime
        }
        if (remainingStay) return changed
        if (latest > manual.endTime && allTransports.none {
                it.statusRaw != "ignored" && it.startTime < latest && it.endTime > manual.endTime
            }) {
            manual.endTime = latest
            changed = true
        }
        if (holdingStationaryStay && manual.allowsAutomaticDurationExtension && freeUntil(now) && now > manual.endTime) {
            manual.endTime = now
            changed = true
        }
        val wasExtendable = manual.allowsAutomaticDurationExtension
        manual.allowsAutomaticDurationExtension = true
        return changed || !wasExtendable
    }
}
