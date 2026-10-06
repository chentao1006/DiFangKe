package com.ct106.difangke.service.timeline

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.location.RawLocationStore.RawPoint
import java.util.Date
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Pure transport rules ported from iOS PersistentTimelineBuilder / TimelineBuilder. */
object TransportRules {

    data class DormantGapStay(val arrivalIndex: Int, val resumeIndex: Int, val start: Date, val end: Date)
    data class TransportObservation(val points: List<RawPoint>, val inferredStartTime: Date)

    fun calculateDistance(points: List<RawPoint>): Double = GeoMath.pathDistance(points.map { it.latLon })
    fun calculatePathDistance(points: List<RouteCoordinate>): Double = GeoMath.pathDistance(points.map { it.latLon })

    /** Synthetic CLLocation(horizontalAccuracy: 0) equivalent. */
    fun syntheticPoint(lat: Double, lon: Double, time: Date) = RawPoint(time, lat, lon, 0.0, -1.0)

    // ── dormant gap stay (iOS dormantGapStay) ──
    fun dormantGapStay(points: List<RawPoint>): DormantGapStay? {
        if (points.size < 5) return null
        for (resume in 2 until points.size - 1) {
            val last = points[resume - 1]
            val next = points[resume]
            val silence = secs(last.timestamp, next.timestamp)
            if (silence < AppConfig.TRANSPORT_GAP_BREAK_THRESHOLD ||
                silence > AppConfig.DORMANT_STAY_MAX_GAP_DURATION ||
                last.accuracy <= 0 || last.accuracy > AppConfig.DORMANT_STAY_MAX_ACCURACY ||
                next.distanceTo(last) < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD
            ) continue

            var arrival = resume - 1
            var scan = arrival - 1
            var outliers = 0
            while (scan >= 0 && secs(points[scan].timestamp, last.timestamp) <= AppConfig.STAY_DURATION_THRESHOLD) {
                val point = points[scan]
                if (point.accuracy > 0 && point.accuracy <= AppConfig.DORMANT_STAY_MAX_ACCURACY &&
                    point.distanceTo(last) < AppConfig.DORMANT_STAY_CLUSTER_RADIUS
                ) {
                    arrival = scan
                } else {
                    outliers += 1
                    if (outliers > AppConfig.DORMANT_STAY_MAX_OUTLIERS) break
                }
                scan -= 1
            }
            val observed = secs(points[arrival].timestamp, last.timestamp)
            if (observed < AppConfig.DORMANT_STAY_MIN_OBSERVED_DURATION || arrival <= 0) continue
            if (points.subList(0, arrival).none { it.distanceTo(last) >= AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD }) continue
            val end = last.timestamp.plusSeconds(AppConfig.STAY_DURATION_THRESHOLD)
            if (end >= next.timestamp || secs(points[arrival].timestamp, end) < AppConfig.STAY_DURATION_THRESHOLD) continue
            return DormantGapStay(arrival, resume, points[arrival].timestamp, end)
        }
        return null
    }

    // ── departure inference after a dormant gap (iOS transportObservationAfterDormantGap) ──
    fun transportObservationAfterDormantGap(points: List<RawPoint>): TransportObservation {
        val first = points.minByOrNull { it.timestamp.time } ?: return TransportObservation(emptyList(), Date(Long.MIN_VALUE / 2))
        if (points.size < 2) return TransportObservation(listOf(first), first.timestamp)
        val ordered = points.sortedBy { it.timestamp.time }
        val anchor = ordered[0]
        for (index in 1 until ordered.size) {
            val gap = secs(ordered[index - 1].timestamp, ordered[index].timestamp)
            if (gap <= AppConfig.TRANSPORT_GAP_BREAK_THRESHOLD) continue
            val dormantPrefix = ordered.subList(0, index).all { it.distanceTo(anchor) < AppConfig.STAY_DISTANCE_THRESHOLD }
            val gapSpeed = ordered[index].distanceTo(ordered[index - 1]) / gap
            val prefixDuration = secs(anchor.timestamp, ordered[index - 1].timestamp)
            val shortDepartureTail = prefixDuration <= AppConfig.TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION
            if (!(dormantPrefix || (shortDepartureTail && gapSpeed < AppConfig.TRANSPORT_DEPARTURE_MINIMUM_SPEED))) continue

            val movementPoints = ordered.subList(index, ordered.size).toList()
            val detectedMovementTime = movementPoints[0].timestamp
            val sampleEnd = detectedMovementTime.plusSeconds(AppConfig.TRANSPORT_DEPARTURE_SPEED_SAMPLE_DURATION)
            val speedSamples = movementPoints.filter { it.timestamp <= sampleEnd }
            val sampleDuration = secs(detectedMovementTime, speedSamples.lastOrNull()?.timestamp ?: detectedMovementTime)
            val calculatedSpeed = if (sampleDuration > 0 && speedSamples.size >= 2) calculateDistance(speedSamples) / sampleDuration else 0.0
            val reportedSpeed = speedSamples.map { it.speed }.filter { it >= 0 }.maxOrNull() ?: 0.0
            val measuredSpeed = max(calculatedSpeed, reportedSpeed)
            if (measuredSpeed < AppConfig.TRANSPORT_DEPARTURE_MINIMUM_SPEED) {
                return TransportObservation(movementPoints, detectedMovementTime)
            }
            val locationUncertainty = max(0.0, movementPoints[0].accuracy) + max(0.0, ordered[index - 1].accuracy)
            val distanceAtDetection = max(0.0, movementPoints[0].distanceTo(ordered[index - 1]) - locationUncertainty)
            val backfillDuration = min(
                distanceAtDetection / measuredSpeed * AppConfig.TRANSPORT_DEPARTURE_BACKFILL_FRACTION,
                AppConfig.TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION
            )
            val inferredStart = maxDate(ordered[index - 1].timestamp, detectedMovementTime.plusSeconds(-backfillDuration))
            return TransportObservation(movementPoints, inferredStart)
        }
        return TransportObservation(ordered, ordered[0].timestamp)
    }

    // ── departure tail (iOS departureTailSplitIndex) ──
    fun departureTailSplitIndex(points: List<RawPoint>, clusterStartIndex: Int, clusterEndIndex: Int, clusterPoints: List<RawPoint>): Int? {
        if (clusterEndIndex >= points.size || clusterEndIndex - clusterStartIndex < 3) return null
        val clusterEnd = clusterPoints.lastOrNull() ?: return null
        val earliestTailTime = clusterEnd.timestamp.plusSeconds(-AppConfig.MAX_TAIL_DURATION)
        var splitIndex = clusterStartIndex
        while (splitIndex < clusterEndIndex && points[splitIndex].timestamp < earliestTailTime) splitIndex += 1
        val stableDuration = secs(points[clusterStartIndex].timestamp, points[splitIndex].timestamp)
        if (stableDuration < AppConfig.STAY_DURATION_THRESHOLD) return null
        return splitIndex
    }

    // ── short trip with stable stay boundaries ──
    fun hasStableBoundaryShortTripEvidence(points: List<RouteCoordinate>, duration: Double): Boolean {
        if (!(duration > 0 && duration < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD)) return false
        val valid = points.filter { it.isValid }
        val boundaries = valid.filter { it.isStableStayBoundary }.sortedBy { it.timestamp ?: Long.MIN_VALUE }
        if (boundaries.size < 2) return false
        val start = boundaries.first(); val end = boundaries.last()
        if (GeoMath.distance(start.lat, start.lon, end.lat, end.lon) < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return false

        val observed = valid.filter { !it.isSyntheticPadding && it.timestamp != null }.sortedBy { it.timestamp!! }
        if (observed.size < 3) return false
        for (index in 1 until observed.size) {
            val gap = (observed[index].timestamp!! - observed[index - 1].timestamp!!) / 1000.0
            if (!(gap > 0 && gap <= AppConfig.TRANSPORT_DEPARTURE_SPEED_SAMPLE_DURATION)) return false
        }
        val first = observed.first(); val last = observed.last()
        val minimumVisibleMiddle = max(25.0, AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD - 2 * AppConfig.STAY_DISTANCE_THRESHOLD)
        val d = { a: RouteCoordinate, b: RouteCoordinate -> GeoMath.distance(a.lat, a.lon, b.lat, b.lon) }
        return d(first, last) >= minimumVisibleMiddle && d(first, start) < d(first, end) && d(last, end) < d(last, start)
    }

    fun hasMinimumAutomaticTransportSpan(record: WTransport): Boolean {
        if (record.distance < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return false
        val decoded = record.pointsOrNull ?: return true
        val valid = decoded.filter { it.isValid }
        val observed = valid.filter { !it.isSyntheticPadding }
        val evidence = if (observed.isEmpty()) valid else observed
        if (evidence.size < 2) return false
        if (GeoMath.maxDiameter(evidence.map { it.latLon }) >= AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return true
        return hasStableBoundaryShortTripEvidence(valid, secs(record.startTime, record.endTime))
    }

    // ── observed route helpers ──
    fun observedRoutePoints(record: WTransport): List<RouteCoordinate> =
        record.points.filter { !it.isSyntheticPadding && it.timestamp != null && it.isValid }.sortedBy { it.timestamp!! }

    /** Returns (start, end) millis when end > start. */
    private fun observedTimeRange(points: List<RouteCoordinate>): Pair<Long, Long>? {
        val s = points.firstOrNull()?.timestamp ?: return null
        val e = points.lastOrNull()?.timestamp ?: return null
        return if (e > s) s to e else null
    }

    fun hasBetterObservedRoute(candidate: WTransport, existing: WTransport): Boolean {
        val candidatePoints = observedRoutePoints(candidate)
        val existingPoints = observedRoutePoints(existing)
        val candidateRange = observedTimeRange(candidatePoints)
        val existingRange = observedTimeRange(existingPoints)
        if (candidateRange != null && existingRange != null) {
            val cd = candidateRange.second - candidateRange.first
            val ed = existingRange.second - existingRange.first
            if (cd != ed) return cd > ed
            val cDist = calculatePathDistance(candidatePoints)
            val eDist = calculatePathDistance(existingPoints)
            if (cDist != eDist) return cDist > eDist
        } else if ((candidateRange != null) != (existingRange != null)) {
            return candidateRange != null
        }
        if (candidatePoints.size != existingPoints.size) return candidatePoints.size > existingPoints.size
        return candidate.distance > existing.distance
    }

    fun isSameAutomaticTrip(first: WTransport, second: WTransport): Boolean {
        val overlap: Double
        val shorterDuration: Double
        val firstRange = if (!first.isManual && !second.isManual) observedTimeRange(observedRoutePoints(first)) else null
        val secondRange = if (firstRange != null) observedTimeRange(observedRoutePoints(second)) else null
        if (firstRange != null && secondRange != null) {
            overlap = max(0.0, (min(firstRange.second, secondRange.second) - max(firstRange.first, secondRange.first)) / 1000.0)
            shorterDuration = min(firstRange.second - firstRange.first, secondRange.second - secondRange.first) / 1000.0
        } else {
            overlap = max(0.0, secs(maxDate(first.startTime, second.startTime), minDate(first.endTime, second.endTime)))
            shorterDuration = min(secs(first.startTime, first.endTime), secs(second.startTime, second.endTime))
        }
        if (shorterDuration > 0 && overlap / shorterDuration >= 0.8) return true
        if (first.isManual || second.isManual) return false

        val startDiff = abs(secs(second.startTime, first.startTime))
        val endDiff = abs(secs(second.endTime, first.endTime))
        val intervalGap = when {
            first.endTime <= second.startTime -> secs(first.endTime, second.startTime)
            second.endTime <= first.startTime -> secs(second.endTime, first.startTime)
            else -> 0.0
        }
        if (startDiff > 20 * 60 || endDiff > 20 * 60 || first.distance <= 0 || second.distance <= 0) return false
        val firstPoints = first.pointsOrNull ?: return false
        val secondPoints = second.pointsOrNull ?: return false
        if (firstPoints.size < 2 || secondPoints.size < 2) return false

        val firstRoute = firstPoints.map { it.latLon }
        val secondRoute = secondPoints.map { it.latLon }
        val fS = firstRoute.first(); val fE = firstRoute.last()
        val sS = secondRoute.first(); val sE = secondRoute.last()
        val d = { a: Pair<Double, Double>, b: Pair<Double, Double> -> GeoMath.distance(a.first, a.second, b.first, b.second) }

        if (overlap == 0.0) {
            val firstDX = fE.second - fS.second
            val firstDY = fE.first - fS.first
            val secondDX = sE.second - sS.second
            val secondDY = sE.first - sS.first
            val longitudeScale = cos(fS.first * Math.PI / 180)
            val directionDot = firstDX * secondDX * longitudeScale * longitudeScale + firstDY * secondDY
            if (directionDot < 0) return false
        }

        if (intervalGap <= 120 && d(fS, fE) >= 300 && d(sS, sE) >= 300 && d(fS, sS) <= 150 && d(fE, sE) <= 150) return true

        fun distanceToRoute(point: Pair<Double, Double>, route: List<Pair<Double, Double>>): Double {
            if (route.size < 2) return Double.MAX_VALUE
            var best = Double.MAX_VALUE
            for (index in 0 until route.size - 1) {
                val start = route[index]; val end = route[index + 1]
                val dx = end.second - start.second
                val dy = end.first - start.first
                val lengthSquared = dx * dx + dy * dy
                val ratio = if (lengthSquared == 0.0) 0.0 else
                    max(0.0, min(1.0, ((point.second - start.second) * dx + (point.first - start.first) * dy) / lengthSquared))
                val projected = (start.first + (end.first - start.first) * ratio) to (start.second + (end.second - start.second) * ratio)
                best = min(best, d(point, projected))
            }
            return best
        }

        val tolerance = max(300.0, min(first.distance, second.distance) * 0.15)
        fun routeCoverage(route: List<Pair<Double, Double>>, other: List<Pair<Double, Double>>): Double =
            route.count { distanceToRoute(it, other) <= tolerance }.toDouble() / route.size

        val forward = routeCoverage(firstRoute, secondRoute)
        val reverse = routeCoverage(secondRoute, firstRoute)
        if (min(forward, reverse) >= 0.7) return true
        return intervalGap <= 10 * 60 && max(forward, reverse) >= 0.85
    }

    /** iOS transportRouteEvidence: observed points plus earliest synthetic anchor before them. */
    fun transportRouteEvidence(record: WTransport): List<RawPoint> {
        val decoded = record.points
        val evidence = observedRoutePoints(record).map { syntheticPoint(it.lat, it.lon, Date(it.timestamp!!)) }.toMutableList()
        val first = evidence.firstOrNull()
        val anchor = decoded.filter { it.isSyntheticPadding && it.timestamp != null }.minByOrNull { it.timestamp!! }
        if (first != null && anchor != null && anchor.timestamp!! < first.timestamp.time && anchor.isValid) {
            evidence.add(0, syntheticPoint(anchor.lat, anchor.lon, Date(anchor.timestamp)))
        }
        return evidence
    }

    fun automaticTransportStart(record: WTransport, proposedStart: Date, trustedStart: Date): Date {
        val locations = transportRouteEvidence(record)
        val observation = transportObservationAfterDormantGap(locations)
        if (observation.points.size < locations.size) return maxDate(proposedStart, observation.inferredStartTime)
        val first = locations.firstOrNull()
        if (first != null && secs(proposedStart, first.timestamp) > AppConfig.TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION) {
            if (trustedStart <= first.timestamp &&
                secs(trustedStart, first.timestamp) <= AppConfig.TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION
            ) return maxDate(proposedStart, trustedStart)
            return first.timestamp
        }
        return proposedStart
    }

    fun hasTransportSizedMovementAfterPrematureEnd(
        recordEnd: Date, footprintStart: Date, footprintEnd: Date, rawPoints: List<RawPoint>
    ): Boolean {
        val windowEnd = if (footprintStart > recordEnd) footprintStart
        else minDate(footprintEnd, footprintStart.plusSeconds(AppConfig.STAY_DURATION_THRESHOLD))
        if (windowEnd <= recordEnd) return false
        val evidence = rawPoints.filter {
            it.timestamp > recordEnd && it.timestamp <= windowEnd &&
                it.accuracy > 0 && it.accuracy <= AppConfig.HABIT_ANALYSIS_ACCURACY_THRESHOLD
        }
        if (evidence.size < 2) return false
        return GeoMath.maxDiameter(evidence.map { it.latLon }) >= AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD
    }

    fun shouldAttachTransportEndpoint(pathEndpoint: RouteCoordinate?, footprint: RouteCoordinate): Boolean {
        if (pathEndpoint == null) return true
        val threshold = min(AppConfig.STAY_DISTANCE_THRESHOLD, 120.0)
        return GeoMath.distance(pathEndpoint.lat, pathEndpoint.lon, footprint.lat, footprint.lon) <= threshold
    }

    fun anchoringAutomaticTransportStart(points: List<RouteCoordinate>, footprint: RouteCoordinate): List<RouteCoordinate> {
        val first = points.firstOrNull() ?: return listOf(footprint)
        if (first.lat == footprint.lat && first.lon == footprint.lon) return points
        return listOf(footprint) + points
    }

    // ── deleted transport overrides ──
    /** iOS fetchDeletedTransportRanges: widen each deletion by ±10 min. */
    fun widenDeletedRanges(raw: List<Pair<Date, Date>>, dayStart: Date, dayEnd: Date): List<Pair<Date, Date>> {
        val tol = AppConfig.RECONSTRUCTION_BOUNDARY_TOLERANCE
        val searchStart = dayStart.plusSeconds(-tol)
        val searchEnd = dayEnd.plusSeconds(tol)
        return raw.filter { it.first < searchEnd && it.second > searchStart }
            .map { it.first.plusSeconds(-tol) to it.second.plusSeconds(tol) }
    }

    fun overlapsDeletedTransportOverride(start: Date, end: Date, deletedRanges: List<Pair<Date, Date>>): Boolean {
        if (end <= start) return false
        val candidateDuration = secs(start, end)
        return deletedRanges.any { (rs, re) ->
            val overlapStart = maxDate(start, rs)
            val overlapEnd = minDate(end, re)
            if (overlapEnd <= overlapStart) return@any false
            val overlapDuration = secs(overlapStart, overlapEnd)
            overlapDuration > AppConfig.OVERLAP_MIN_DURATION && overlapDuration >= candidateDuration * AppConfig.OVERLAP_MIN_RATIO
        }
    }

    // ── manual transport ownership (iOS automaticSegmentsOutsideManualIntervals) ──
    /**
     * Returns null when no split is needed, an empty list when manual records own
     * the whole interval, otherwise clipped pieces. Piece 0 reuses (mutates) [record].
     */
    fun automaticSegmentsOutsideManualIntervals(record: WTransport, manuals: List<WTransport>): List<WTransport>? {
        var intervals = listOf(record.startTime to record.endTime)
        for (manual in manuals) {
            intervals = intervals.flatMap { (s, e) ->
                if (!(manual.startTime < e && manual.endTime > s)) return@flatMap listOf(s to e)
                val remaining = mutableListOf<Pair<Date, Date>>()
                if (manual.startTime > s) remaining.add(s to manual.startTime)
                if (manual.endTime < e) remaining.add(manual.endTime to e)
                remaining
            }
        }
        if (intervals.size == 1 && intervals[0].first == record.startTime && intervals[0].second == record.endTime) return null
        if (intervals.isEmpty()) return emptyList()

        val decoded = record.points.filter { it.isValid }
        if (decoded.isEmpty()) return emptyList()
        val routeDuration = max(1.0, secs(record.startTime, record.endTime))
        val denominator = max(1, decoded.size - 1)
        val timedPoints = decoded.mapIndexed { index, p ->
            if (p.timestamp != null) p else p.copy(
                timestamp = record.startTime.plusSeconds(routeDuration * index / denominator).time,
                isSyntheticPadding = true
            )
        }.sortedBy { it.timestamp!! }

        fun boundaryPoint(time: Date): RouteCoordinate {
            timedPoints.firstOrNull { it.timestamp == time.time }?.let { return it }
            val before = timedPoints.lastOrNull { it.timestamp!! < time.time }
            val after = timedPoints.firstOrNull { it.timestamp!! > time.time }
            if (before != null && after != null) {
                val span = (after.timestamp!! - before.timestamp!!).toDouble()
                val ratio = if (span > 0) (time.time - before.timestamp) / span else 0.0
                return RouteCoordinate(
                    before.lat + (after.lat - before.lat) * ratio,
                    before.lon + (after.lon - before.lon) * ratio,
                    time.time, isSyntheticPadding = true
                )
            }
            val nearest = before ?: after ?: timedPoints[0]
            return RouteCoordinate(nearest.lat, nearest.lon, time.time, isSyntheticPadding = true)
        }

        val parts = intervals.map { (s, e) ->
            val part = timedPoints.filter { it.timestamp!! >= s.time && it.timestamp <= e.time }.toMutableList()
            if (part.firstOrNull()?.timestamp != s.time) part.add(0, boundaryPoint(s))
            if (part.lastOrNull()?.timestamp != e.time) part.add(boundaryPoint(e))
            part.toList()
        }
        val originalStart = record.startTime
        val originalEnd = record.endTime
        val originalStartLocation = record.startLocation
        val originalEndLocation = record.endLocation
        val originalTypeRaw = record.typeRaw
        val originalStepCount = record.stepCount
        val originalDuration = max(1.0, secs(originalStart, originalEnd))
        return intervals.indices.map { index ->
            val (s, e) = intervals[index]
            val distance = calculatePathDistance(parts[index])
            val stepCount = originalStepCount?.let { (it * secs(s, e) / originalDuration).roundToInt() }
            val startLocation = if (s == originalStart) originalStartLocation else "起点"
            val endLocation = if (e == originalEnd) originalEndLocation else "终点"
            val speed = distance / max(1.0, secs(s, e))
            if (index == 0) {
                record.day = startOfDay(s)
                record.startTime = s
                record.endTime = e
                record.startLocation = startLocation
                record.endLocation = endLocation
                record.distance = distance
                record.averageSpeed = speed
                record.setPoints(parts[index])
                record.stepCount = stepCount
                record
            } else {
                WTransport.create(startOfDay(s), s, e, startLocation, endLocation, originalTypeRaw, distance, speed, parts[index], stepCount)
            }
        }
    }

    /** Port of iOS TransportSplitRouteBuilder.segments (for UI-driven splits). */
    fun splitRoute(points: List<RouteCoordinate>, startTime: Date, splitTime: Date, endTime: Date): Pair<List<RouteCoordinate>, List<RouteCoordinate>> {
        if (points.isEmpty()) return emptyList<RouteCoordinate>() to emptyList()
        if (points.size == 1) return points to points
        val duration = max(1.0, secs(startTime, endTime))
        val splitRatio = min(1.0, max(0.0, secs(startTime, splitTime) / duration))
        val exactIndex = points.indexOfFirst { it.timestamp == splitTime.time }
        if (exactIndex >= 0) return points.subList(0, exactIndex + 1) to points.subList(exactIndex, points.size)
        val previousIndex = points.indices.lastOrNull { points[it].timestamp?.let { t -> t < splitTime.time } == true }
        val nextIndex = points.indices.firstOrNull { points[it].timestamp?.let { t -> t > splitTime.time } == true }
        if (previousIndex != null && nextIndex != null && previousIndex < nextIndex) {
            val previousTime = points[previousIndex].timestamp!!
            val nextTime = points[nextIndex].timestamp!!
            val span = (nextTime - previousTime).toDouble()
            val ratio = if (span > 0) (splitTime.time - previousTime) / span else 0.0
            val cut = RouteCoordinate(
                points[previousIndex].lat + (points[nextIndex].lat - points[previousIndex].lat) * ratio,
                points[previousIndex].lon + (points[nextIndex].lon - points[previousIndex].lon) * ratio,
                splitTime.time, isSyntheticPadding = true
            )
            val insertionIndex = min(nextIndex, max(previousIndex + 1, previousIndex + ((nextIndex - previousIndex) * ratio).roundToInt()))
            return (points.subList(0, insertionIndex) + cut) to (listOf(cut) + points.subList(insertionIndex, points.size))
        }
        val cutIndex = min(max(0, ((points.size - 1) * splitRatio).roundToInt()), points.size - 1)
        return points.subList(0, cutIndex + 1) to points.subList(cutIndex, points.size)
    }
}
