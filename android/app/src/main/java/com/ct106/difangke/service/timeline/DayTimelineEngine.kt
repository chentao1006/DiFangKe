package com.ct106.difangke.service.timeline

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.location.RawLocationStore.RawPoint
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.PlaceMatcher
import java.util.Date
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Pure, in-memory port of iOS `PersistentTimelineBuilder.syncDay` and the
 * post-processing passes it runs (TimelineBuilder.swift + LocationManager
 * consolidation). Operates on a [TimelineWorkspace]; the Room layer
 * (PersistentTimelineBuilder) loads the workspace and persists the diff.
 *
 * Incremental: existing records are repaired, only uncovered gaps are rebuilt.
 */
class DayTimelineEngine(
    private val ws: TimelineWorkspace,
    /** Valid (non-drift) chronological raw points for the day. */
    private val rawPoints: List<RawPoint>,
    private val driftTimestamps: Set<Long> = emptySet(),
    private val preferences: TransportPreferences = TransportPreferences(),
    private val sensors: TimelineSensors = TimelineSensors.None,
    private val live: LiveStayContext? = null,
    private val now: Date = Date(),
    private val log: (String) -> Unit = {}
) {
    private val dayStart get() = ws.dayStart
    private val dayEnd get() = ws.dayEnd
    private val places: List<PlaceEntity> get() = ws.places

    private val deletedRanges: List<Pair<Date, Date>> by lazy {
        TransportRules.widenDeletedRanges(ws.deletedSelections, dayStart, dayEnd)
    }

    private fun typeOf(raw: String?): TransportType? = TransportType.entries.firstOrNull { it.raw == raw }

    private fun classify(
        speed: Double, start: Date, end: Date, duration: Double, distance: Double,
        pointCount: Int, observedPointCount: Int?
    ): Pair<TransportType, HealthMetrics> {
        val metrics = sensors.metrics(start, end)
        val motion = sensors.motion(start, end)
        val type = TransportType.classify(
            speedMs = speed, motionType = motion, stepCount = metrics.steps,
            walkingDistance = metrics.walkingDistance, floorsClimbed = metrics.floors,
            durationSec = duration, distanceMeters = distance, pointCount = pointCount,
            observedPointCount = observedPointCount, preferredAuto = preferences.automotive,
            preferredCycling = preferences.cycling, preferredTransport = preferences.road
        )
        return type to metrics
    }

    // ───────────────────────── syncDay ─────────────────────────

    fun syncDay(runConsolidation: Boolean = true) {
        val isToday = isSameDay(dayStart, now)

        normalizeCrossDayFootprints(ws.dayFootprints())

        var allFps = ws.dayFootprints()
        val removed = FootprintRules.removeAutomaticFootprintsOwnedByManual(allFps, ws)
        if (removed.isNotEmpty()) allFps = ws.dayFootprints()

        var allTps = ws.dayTransports()
        val confined = allTps.filter { !it.isManual && !TransportRules.hasMinimumAutomaticTransportSpan(it) }
        if (confined.isNotEmpty()) {
            confined.forEach { ws.deleteTransport(it) }
            allTps = ws.dayTransports()
        }

        if (FootprintRules.absorbAdjacentAutomaticContinuations(allFps, allTps, ws)) allFps = ws.dayFootprints()

        if (repairImpossibleAutomaticTransportTypes(allTps)) allTps = ws.dayTransports()

        if (reopenPrematureAutomaticTransportEnds(allTps, allFps)) {
            allFps = ws.dayFootprints()
            allTps = ws.dayTransports()
        }

        // Rebuild unedited trips that hide a confirmed short stop before a blackout.
        var rebuiltDormantGapTrip = false
        for (record in allTps.filter { !it.isManual }) {
            val evidence = rawPoints.filter { it.timestamp >= record.startTime && it.timestamp <= record.endTime }
            if (TransportRules.dormantGapStay(evidence) == null ||
                TransportRules.overlapsDeletedTransportOverride(record.startTime, record.endTime, deletedRanges)
            ) continue
            ws.deleteTransport(record)
            processPoints(evidence)
            rebuiltDormantGapTrip = true
        }
        if (rebuiltDormantGapTrip) {
            allFps = ws.dayFootprints()
            allTps = ws.dayTransports()
        }

        if (repairAutomaticTransportStartsAfterDormantGap(allTps)) allTps = ws.dayTransports()
        if (repairSparseUrbanRailTypes(allTps)) allTps = ws.dayTransports()

        var sortedRanges = (allFps.map { it.startTime to it.endTime } + allTps.map { it.startTime to it.endTime })
            .sortedBy { it.first }

        repairRoutesContainingDrift(allTps)

        if (isToday && live != null) {
            val anchor = live.anchor
            val observed = live.current ?: rawPoints.lastOrNull()
            if (observed != null) {
                val current = if (live.isHoldingStationaryStay && secs(observed.timestamp, now) >= 30 * 60) {
                    // A held stationary stay keeps "now" as its evidence time.
                    observed.copy(timestamp = now)
                } else observed
                val edited = allFps.filter { it.isManual && it.endTime >= anchor.timestamp }.maxByOrNull { it.endTime }
                if (edited != null && FootprintRules.continueCurrentEditedStay(
                        edited, anchor, current, rawPoints, ws, live.isHoldingStationaryStay, now
                    )
                ) {
                    allFps = ws.dayFootprints()
                    sortedRanges = (allFps.map { it.startTime to it.endTime } + allTps.map { it.startTime to it.endTime })
                        .sortedBy { it.first }
                }
            }
        }
        log("raw=${rawPoints.size}, footprints=${allFps.size}, transports=${allTps.size}")

        // Uncovered gaps.
        val gaps = mutableListOf<Pair<Date, Date>>()
        var currentTime = dayStart
        val latestDataTime = listOfNotNull(rawPoints.lastOrNull()?.timestamp, sortedRanges.lastOrNull()?.second).maxOrNull()
        val upperLimit: Date = if (isToday) now else {
            val latest = latestDataTime ?: return
            minDate(dayEnd, latest)
        }
        for ((start, end) in sortedRanges) {
            if (start > currentTime.plusSeconds(AppConfig.GAP_FILLING_THRESHOLD)) gaps.add(currentTime to start)
            currentTime = maxDate(currentTime, end)
        }
        if (currentTime < upperLimit.plusSeconds(-AppConfig.GAP_FILLING_THRESHOLD)) {
            var trailingGapStart = currentTime
            val trailingTransport = allTps.firstOrNull { it.endTime == currentTime }
            if (trailingTransport != null && !trailingTransport.isManual) {
                // Re-segment a trip whose provisional end was only the previous sync time.
                trailingGapStart = trailingTransport.startTime
                allTps = allTps - trailingTransport
                ws.deleteTransport(trailingTransport)
            }
            gaps.add(trailingGapStart to upperLimit)
        }

        val ignoredFps = ws.ignoredFootprints.filter { it.startTime < dayEnd && it.endTime > dayStart }
        val filteredGaps = gaps.filter { (gs, ge) ->
            val overlapsIgnored = ignoredFps.any { ignored ->
                val os = maxDate(gs, ignored.startTime)
                val oe = minDate(ge, ignored.endTime)
                if (oe > os) {
                    val overlap = secs(os, oe)
                    overlap > 300 || overlap / secs(gs, ge) > 0.5
                } else false
            }
            val isShortEndpointSliver = secs(gs, ge) <= 10 * 60
            val touchesExistingTransport = isShortEndpointSliver && allTps.any { t ->
                abs(secs(t.startTime, ge)) <= 10 * 60 || abs(secs(t.endTime, gs)) <= 10 * 60
            }
            !overlapsIgnored && !touchesExistingTransport &&
                !TransportRules.overlapsDeletedTransportOverride(gs, ge, deletedRanges)
        }
        log("gaps=${gaps.size}, eligible=${filteredGaps.size}")

        for ((gs, ge) in filteredGaps) {
            val gapPoints = rawPoints.filter {
                it.timestamp >= gs && it.timestamp <= ge &&
                    it.accuracy > 0 && it.accuracy <= AppConfig.HABIT_ANALYSIS_ACCURACY_THRESHOLD
            }
            if (gapPoints.size >= 2) processPoints(gapPoints.sortedBy { it.timestamp })
        }

        splitFootprintsByTransports()
        mergeConsecutiveFootprints(AppConfig.MERGE_DISTANCE_THRESHOLD)
        removeDuplicateRouteTransports()
        mergeConsecutiveTransports()
        fillGapsBetweenItems()
        removeDuplicateRouteTransports()
        snapTransportsToFootprints()

        if (runConsolidation) {
            consolidateFootprints()
            syncDay(runConsolidation = false)
            autoFillMissingActivityTypes()
        }
    }

    // ───────────────────────── repairs ─────────────────────────

    /** Slow/running records that cannot be walking (≥1 km and ≥15 km/h, or too few steps). */
    fun repairImpossibleAutomaticTransportTypes(transports: List<WTransport>): Boolean {
        var changed = false
        for (t in transports) {
            if (t.isManual || !(t.typeRaw == TransportType.SLOW.raw || t.typeRaw == TransportType.RUNNING.raw)) continue
            val duration = secs(t.startTime, t.endTime)
            if (duration <= 0 || t.distance < AppConfig.WALKING_SANITY_MIN_DISTANCE) continue
            val kmh = t.distance / duration * 3.6
            val stepCount = t.stepCount ?: 0
            val minutes = duration / 60
            val stepsPerMinute = if (minutes > 0) stepCount / minutes else 0.0
            val impossibleSpeed = kmh >= AppConfig.WALKING_IMPOSSIBLE_SPEED
            val fewSteps = t.stepCount != null && stepsPerMinute < AppConfig.WALKING_MIN_STEPS_PER_MINUTE &&
                stepCount < AppConfig.WALKING_MIN_STEP_COUNT
            if (!(impossibleSpeed || (fewSteps && kmh >= AppConfig.WALKING_SUSPICIOUS_SPEED))) continue
            val inferred = TransportType.classify(
                speedMs = t.distance / duration, stepCount = stepCount, durationSec = duration,
                distanceMeters = t.distance, pointCount = 2, preferredAuto = preferences.automotive,
                preferredCycling = preferences.cycling, preferredTransport = preferences.road
            )
            val corrected = if (inferred == TransportType.SLOW || inferred == TransportType.RUNNING)
                preferences.road ?: preferences.automotive else inferred
            if (corrected == TransportType.SLOW || corrected == TransportType.RUNNING) continue
            t.typeRaw = corrected.raw
            changed = true
        }
        return changed
    }

    fun repairSparseUrbanRailTypes(transports: List<WTransport>): Boolean {
        var changed = false
        val excluded = setOf(TransportType.SUBWAY.raw, TransportType.TRAIN.raw, TransportType.AIRPLANE.raw, TransportType.SLOW.raw, TransportType.RUNNING.raw)
        for (t in transports) {
            if (t.isManual || t.typeRaw in excluded) continue
            val points = t.pointsOrNull ?: continue
            if (points.size < 2) continue
            val observedCount = points.count { !it.isSyntheticPadding }
            if (observedCount > 4) continue
            val duration = secs(t.startTime, t.endTime)
            if (duration <= 0) continue
            val inferred = TransportType.classify(
                speedMs = t.distance / duration, stepCount = t.stepCount ?: 0, durationSec = duration,
                distanceMeters = t.distance, pointCount = points.size, observedPointCount = observedCount
            )
            if (inferred != TransportType.SUBWAY) continue
            t.typeRaw = inferred.raw
            changed = true
        }
        return changed
    }

    /** Rebuild geometry of same-day routes that contain points now marked as drift. */
    fun repairRoutesContainingDrift(transports: List<WTransport>): Boolean {
        if (driftTimestamps.isEmpty()) return false
        var changed = false
        for (t in transports) {
            if (!isSameDay(t.startTime, dayStart) || !isSameDay(t.endTime.plusSeconds(-0.001), dayStart)) continue
            val stored = t.pointsOrNull ?: continue
            if (stored.none { p -> p.timestamp?.let { driftTimestamps.contains(it) } == true }) continue
            val route = rawPoints.filter { it.timestamp >= t.startTime && it.timestamp <= t.endTime }
                .map { RouteCoordinate(it.latitude, it.longitude, it.timestamp.time) }
            t.setPoints(route)
            t.distance = TransportRules.calculatePathDistance(route)
            val duration = secs(t.startTime, t.endTime)
            t.averageSpeed = if (duration > 0) t.distance / duration else 0.0
            changed = true
        }
        return changed
    }

    fun reopenPrematureAutomaticTransportEnds(transports: List<WTransport>, footprints: List<WFootprint>): Boolean {
        var changed = false
        val removedTransportIDs = mutableSetOf<String>()
        val removedFootprintIDs = mutableSetOf<String>()
        val sortedFootprints = footprints.sortedBy { it.startTime }
        for (record in transports) {
            if (record.isManual || record.statusRaw == "ignored" || record.id in removedTransportIDs) continue
            val next = sortedFootprints.firstOrNull {
                it.id !in removedFootprintIDs && !it.isIgnored && it.endTime > record.endTime &&
                    it.startTime <= record.endTime.plusSeconds(AppConfig.GAP_FILLING_THRESHOLD)
            } ?: continue
            if (next.isManual || next.isAddressEditedByHand || next.isHighlight == true || next.photos.isNotEmpty() ||
                !next.reason.isNullOrBlank() || next.allowsAutomaticDurationExtension
            ) continue
            if (!TransportRules.hasTransportSizedMovementAfterPrematureEnd(record.endTime, next.startTime, next.endTime, rawPoints)) continue
            ws.deleteTransport(record)
            removedTransportIDs.add(record.id)
            if (next.startTime <= record.endTime.plusSeconds(1.0)) {
                ws.deleteFootprint(next)
                removedFootprintIDs.add(next.id)
            }
            changed = true
        }
        return changed
    }

    fun repairAutomaticTransportStartsAfterDormantGap(records: List<WTransport>): Boolean {
        var changed = false
        for (record in records) {
            if (record.isManual || record.statusRaw == "ignored") continue
            val decoded = record.pointsOrNull ?: continue
            val observed = decoded.filter { !it.isSyntheticPadding && it.timestamp != null }
            if (observed.size < 2) continue
            val locations = TransportRules.transportRouteEvidence(record)
            val original = rawPoints.filter { it.timestamp >= record.startTime && it.timestamp <= record.endTime }
            val evidence = (if (original.size >= 2) original else locations).toMutableList()
            val anchor = locations.firstOrNull()
            val firstEvidence = evidence.firstOrNull()
            if (anchor != null && firstEvidence != null && anchor.timestamp < firstEvidence.timestamp) evidence.add(0, anchor)
            val observation = TransportRules.transportObservationAfterDormantGap(evidence)
            val repairedStart: Date = if (observation.points.size < evidence.size) {
                observation.inferredStartTime
            } else {
                val firstRaw = original.firstOrNull()
                if (firstRaw != null && secs(record.startTime, firstRaw.timestamp) <= AppConfig.TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION) continue
                TransportRules.automaticTransportStart(record, record.startTime, record.startTime)
            }
            if (!(repairedStart > record.startTime && repairedStart < record.endTime)) continue
            record.startTime = repairedStart
            record.day = dayStart
            val duration = secs(repairedStart, record.endTime)
            if (duration <= 0) continue
            record.averageSpeed = record.distance / duration
            val (type, metrics) = classify(
                record.averageSpeed, repairedStart, record.endTime, duration, record.distance,
                observation.points.size, observation.points.size
            )
            record.stepCount = metrics.steps
            record.typeRaw = type.raw
            changed = true
        }
        return changed
    }

    // ───────────────────────── processPoints ─────────────────────────

    private fun latestMergeableFootprint(candidateEnd: Date): WFootprint? =
        ws.footprints.filter { !it.isIgnored && it.endTime > dayStart && it.endTime <= candidateEnd }
            .maxByOrNull { it.endTime }

    private fun hasTransportOverlap(start: Date, end: Date): Boolean {
        if (end <= start) return false
        return ws.dayTransports().any { it.endTime > start && it.startTime < end }
    }

    private fun shouldExtendExistingFootprint(existing: WFootprint, candidateStart: Date, cLat: Double, cLon: Double, matchedPlace: PlaceEntity?): Boolean {
        if (matchedPlace != null && existing.placeID == matchedPlace.placeID) {
            val timeGap = secs(existing.endTime, candidateStart)
            return timeGap < max(AppConfig.STAY_MERGE_GAP_THRESHOLD, AppConfig.SAME_PLACE_MERGE_GAP_THRESHOLD)
        }
        // FootprintProcessor.shouldMerge
        val timeInterval = secs(existing.endTime, candidateStart)
        if (timeInterval >= AppConfig.STAY_MERGE_GAP_THRESHOLD) return false
        return GeoMath.distance(existing.latitude, existing.longitude, cLat, cLon) < AppConfig.MERGE_DISTANCE_THRESHOLD
    }

    private fun frequentActivity(placeID: String, at: Date): String? = ActivityHabits.frequentActivityTypeValue(
        ws.activityHistory(placeID), at, AppConfig.HABIT_TIME_WINDOW_MINUTES, AppConfig.HABIT_FREQUENCY_THRESHOLD
    )

    private fun locationHashOf(lat: Double, lon: Double) = "$lat,$lon"

    /** Port of iOS PersistentTimelineBuilder.processPoints (TimelineBuilder.swift:3170). */
    fun processPoints(
        points: List<RawPoint>,
        precedingFootprint: WFootprint? = null,
        initialDepartureTime: Date? = null
    ) {
        if (points.size < 2) return

        TransportRules.dormantGapStay(points)?.let { stop ->
            processPoints(points.subList(0, stop.arrivalIndex + 1).toList())
            val observed = points.subList(stop.arrivalIndex, stop.resumeIndex).toList()
            val center = GeoMath.centroid(observed.map { it.latLon })
            val footprint = WFootprint.create(
                startOfDay(stop.start), stop.start, stop.end, observed.map { it.latLon },
                locationHashOf(center.first, center.second)
            )
            PlaceMatcher.getPlaceForCoordinate(center.first, center.second, places)?.let {
                footprint.placeID = it.placeID
                footprint.address = it.name
            }
            val available = FootprintRules.automaticStayIntervals(stop.start, stop.end, ws)
            val ownsInterval = available.size == 1 && available[0].first == stop.start && available[0].second == stop.end
            if (ownsInterval) ws.insertFootprint(footprint)
            processPoints(
                points.subList(stop.resumeIndex, points.size).toList(),
                precedingFootprint = if (ownsInterval) footprint else null,
                initialDepartureTime = stop.end
            )
            return
        }

        val stayThreshold = AppConfig.STAY_DISTANCE_THRESHOLD
        var lastFp: WFootprint? = precedingFootprint
        var i = 0
        while (i < points.size) {
            var j = i + 1
            val clusterPoints = mutableListOf(points[i])
            while (j < points.size) {
                if (points[j].distanceTo(points[i]) < stayThreshold) {
                    clusterPoints.add(points[j])
                    j += 1
                } else {
                    // GPS spike tolerance: a single jump out and back stays in the cluster.
                    if (j + 1 < points.size && points[j + 1].distanceTo(points[i]) < stayThreshold) {
                        j += 1
                        continue
                    }
                    break
                }
            }

            val duration = secs(clusterPoints.first().timestamp, clusterPoints.last().timestamp)
            if (duration >= AppConfig.STAY_DURATION_THRESHOLD) {
                val split = TransportRules.departureTailSplitIndex(points, i, j, clusterPoints)
                val footprintClusterPoints = split?.let { points.subList(i, it).toList() } ?: clusterPoints
                val fpStart = footprintClusterPoints.firstOrNull()
                val fpEnd = footprintClusterPoints.lastOrNull()
                if (fpStart == null || fpEnd == null || secs(fpStart.timestamp, fpEnd.timestamp) < AppConfig.STAY_DURATION_THRESHOLD) {
                    i = split ?: j
                    continue
                }

                val coords = footprintClusterPoints.map { it.latLon }
                val fp = WFootprint.create(
                    dayStart, fpStart.timestamp, fpEnd.timestamp, coords,
                    locationHashOf(coords.first().first, coords.first().second)
                )
                val metrics = sensors.metrics(fp.startTime, fp.endTime)
                fp.stepCount = metrics.steps
                fp.walkingDistance = metrics.walkingDistance
                fp.floorsAscended = metrics.floors

                val loc = clusterPoints.first()
                PlaceMatcher.getPlaceForCoordinate(loc.latitude, loc.longitude, places)?.let { matched ->
                    fp.placeID = matched.placeID
                    fp.address = matched.name
                    fp.activityTypeValue = frequentActivity(matched.placeID, fp.startTime)
                }

                if (FootprintRules.extendActivityEditedStay(fp.startTime, fp.endTime, fp.latitude, fp.longitude, ws, live, now)) {
                    i = split ?: j
                    continue
                }
                val available = FootprintRules.automaticStayIntervals(fp.startTime, fp.endTime, ws)
                if (!(available.size == 1 && available[0].first == fp.startTime && available[0].second == fp.endTime)) {
                    for ((s, e) in available) {
                        val remaining = footprintClusterPoints.filter { it.timestamp >= s && it.timestamp <= e }
                        processPoints(remaining)
                    }
                    i = split ?: j
                    continue
                }

                val matchedPlace = places.firstOrNull { it.placeID == fp.placeID }
                val existing = latestMergeableFootprint(fp.endTime)
                if (existing != null && !existing.isManual &&
                    !hasTransportOverlap(existing.endTime, fp.startTime) &&
                    shouldExtendExistingFootprint(existing, fp.startTime, fp.latitude, fp.longitude, matchedPlace)
                ) {
                    existing.endTime = maxDate(existing.endTime, fp.endTime)
                    existing.date = startOfDay(existing.startTime)
                    existing.appendLocations(fp.lats, fp.lons)
                    if (existing.placeID == null && matchedPlace != null) existing.placeID = matchedPlace.placeID
                    if (existing.activityTypeValue == null && matchedPlace != null) {
                        existing.activityTypeValue = frequentActivity(matchedPlace.placeID, existing.startTime)
                    }
                    if (!existing.isAddressEditedByHand) {
                        if (matchedPlace != null) existing.address = matchedPlace.name
                        else if (existing.address.isNullOrEmpty()) existing.address = fp.address
                    }
                    lastFp = existing
                } else {
                    // iOS live path (handleNewCandidateFootprint): a stay inside an
                    // ignored place is persisted as ignored so gap filling skips it.
                    PlaceMatcher.ignoredPlaceForCoordinate(fp.latitude, fp.longitude, places)?.let { ignored ->
                        fp.status = "ignored"
                        fp.placeID = ignored.placeID
                    }
                    ws.insertFootprint(fp)
                    lastFp = if (fp.isIgnored) lastFp else fp
                }
                i = split ?: j
            } else {
                var k = j
                var transportPoints = mutableListOf(points[i])
                var nextStableCluster: List<RawPoint> = emptyList()
                while (k < points.size) {
                    var m = k + 1
                    val subCluster = mutableListOf(points[k])
                    while (m < points.size) {
                        if (points[m].distanceTo(points[k]) < stayThreshold) {
                            subCluster.add(points[m]); m += 1
                        } else break
                    }
                    if (secs(subCluster.first().timestamp, subCluster.last().timestamp) >= AppConfig.STAY_DURATION_THRESHOLD) {
                        nextStableCluster = subCluster
                        break
                    } else {
                        transportPoints.add(points[k])
                        k += 1
                    }
                }

                val observation = TransportRules.transportObservationAfterDormantGap(transportPoints)
                transportPoints = observation.points.toMutableList()
                if (transportPoints.size >= 2) {
                    val tStart = if (i == 0) (initialDepartureTime ?: observation.inferredStartTime) else observation.inferredStartTime
                    val tEnd = transportPoints.last().timestamp
                    if (TransportRules.overlapsDeletedTransportOverride(tStart, tEnd, deletedRanges)) {
                        i = k
                        continue
                    }
                    val codable = transportPoints.map { RouteCoordinate(it.latitude, it.longitude, it.timestamp.time) }
                    val diameter = GeoMath.maxDiameter(transportPoints.map { it.latLon })

                    val spanEvidence = codable.toMutableList()
                    lastFp?.let {
                        spanEvidence.add(0, RouteCoordinate(it.latitude, it.longitude, it.endTime.time, true, true))
                    }
                    if (nextStableCluster.isNotEmpty()) {
                        val c = GeoMath.centroid(nextStableCluster.map { it.latLon })
                        spanEvidence.add(RouteCoordinate(c.first, c.second, nextStableCluster.first().timestamp.time, true, true))
                    }
                    val hasStableBoundaryEvidence = TransportRules.hasStableBoundaryShortTripEvidence(spanEvidence, secs(tStart, tEnd))
                    if (!(diameter >= AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD || hasStableBoundaryEvidence)) {
                        i = k
                        continue
                    }

                    var startName = "起点"
                    var endName = "终点"
                    val sLoc = transportPoints.first()
                    val eLoc = transportPoints.last()
                    PlaceMatcher.getPlaceForCoordinate(sLoc.latitude, sLoc.longitude, places)?.let { startName = it.name }
                    PlaceMatcher.getPlaceForCoordinate(eLoc.latitude, eLoc.longitude, places)?.let { endName = it.name }

                    val augmented = transportPoints.toMutableList()
                    var hasSyntheticStart = false
                    var hasSyntheticEnd = false
                    lastFp?.let { last ->
                        augmented.add(0, TransportRules.syntheticPoint(last.latitude, last.longitude, last.endTime))
                        hasSyntheticStart = true
                        if (startName == "起点") startName = last.address ?: "起点"
                    }
                    if (k < points.size) augmented.add(points[k])
                    if (nextStableCluster.isNotEmpty()) {
                        val c = GeoMath.centroid(nextStableCluster.map { it.latLon })
                        augmented.add(TransportRules.syntheticPoint(c.first, c.second, nextStableCluster.firstOrNull()?.timestamp ?: tEnd))
                        hasSyntheticEnd = true
                    }

                    val pathDist = TransportRules.calculateDistance(augmented)
                    val tDuration = secs(tStart, tEnd)
                    val avgSpeed = if (tDuration > 0) pathDist / tDuration else 0.0
                    var encoded = augmented.mapIndexed { index, p ->
                        val synthetic = (index == 0 && hasSyntheticStart) || (index == augmented.size - 1 && hasSyntheticEnd)
                        RouteCoordinate(p.latitude, p.longitude, p.timestamp.time, synthetic, synthetic)
                    }
                    if (encoded.isEmpty()) encoded = codable

                    val (type, metrics) = classify(
                        avgSpeed, tStart, tEnd, tDuration, pathDist, augmented.size, encoded.count { !it.isSyntheticPadding }
                    )
                    val tp = WTransport.create(dayStart, tStart, tEnd, startName, endName, type.raw, pathDist, avgSpeed, encoded, metrics.steps)
                    insertAutomaticallyDetectedTransport(tp)
                }
                i = k
            }
        }
    }

    // ───────────────────────── transport insertion & ownership ─────────────────────────

    private fun equivalentTransport(candidate: WTransport): WTransport? {
        val existing = ws.dayTransports()
        val manuals = existing.filter { it.isManual }
        manuals.firstOrNull { TransportRules.isSameAutomaticTrip(it, candidate) }?.let { return it }
        return existing.firstOrNull { record ->
            if (record.isManual) return@firstOrNull false
            val pairStart = minDate(record.startTime, candidate.startTime)
            val pairEnd = maxDate(record.endTime, candidate.endTime)
            if (manuals.any { it.startTime < pairEnd && it.endTime > pairStart }) return@firstOrNull false
            TransportRules.isSameAutomaticTrip(record, candidate)
        }
    }

    fun insertAutomaticallyDetectedTransport(candidate: WTransport) {
        if (!TransportRules.hasMinimumAutomaticTransportSpan(candidate)) return
        val manuals = ws.dayTransports().filter { it.isManual }
        val segments = TransportRules.automaticSegmentsOutsideManualIntervals(candidate, manuals)
        if (segments != null) {
            segments.forEach { insertPreparedAutomaticTransport(it) }
            return
        }
        insertPreparedAutomaticTransport(candidate)
    }

    private fun isPlaceholder(name: String, placeholder: String) =
        name.isEmpty() || name == placeholder || name == "正在获取位置..."

    private fun insertPreparedAutomaticTransport(candidate: WTransport) {
        if (!TransportRules.hasMinimumAutomaticTransportSpan(candidate)) return
        val existing = equivalentTransport(candidate)
        if (existing != null) {
            if (existing.isManual) return
            if (TransportRules.hasBetterObservedRoute(candidate, existing)) {
                existing.pointsJson = candidate.pointsJson
                existing.distance = candidate.distance
                existing.typeRaw = candidate.typeRaw
                existing.stepCount = candidate.stepCount
                if (!isPlaceholder(candidate.startLocation, "起点")) existing.startLocation = candidate.startLocation
                if (!isPlaceholder(candidate.endLocation, "终点")) existing.endLocation = candidate.endLocation
            }
            existing.startTime = minDate(existing.startTime, candidate.startTime)
            existing.endTime = maxDate(existing.endTime, candidate.endTime)
            existing.startTime = TransportRules.automaticTransportStart(existing, existing.startTime, candidate.startTime)
            val duration = secs(existing.startTime, existing.endTime)
            existing.averageSpeed = if (duration > 0) existing.distance / duration else 0.0
            return
        }
        ws.insertTransport(candidate)
    }

    /** iOS preservingAutomaticRoutesOutsideManualIntervals. */
    fun preservingAutomaticRoutesOutsideManualIntervals(records: List<WTransport>): List<WTransport> {
        val manuals = records.filter { it.isManual && it.statusRaw != "ignored" }.sortedBy { it.startTime }
        if (manuals.isEmpty()) return records
        val result = mutableListOf<WTransport>()
        for (record in records) {
            if (record.isManual || record.statusRaw == "ignored") { result.add(record); continue }
            val segments = TransportRules.automaticSegmentsOutsideManualIntervals(record, manuals)
            if (segments == null) { result.add(record); continue }
            if (segments.isEmpty()) { ws.deleteTransport(record); continue }
            segments.drop(1).forEach { ws.insertTransport(it) }
            result.addAll(segments)
        }
        return result.sortedBy { it.startTime }
    }

    fun removeDuplicateRouteTransports() {
        val tps = preservingAutomaticRoutesOutsideManualIntervals(ws.dayTransports())
        if (tps.size < 2) return
        val manuals = tps.filter { it.isManual }
        val parents = IntArray(tps.size) { it }
        fun root(index: Int): Int {
            var c = index
            while (parents[c] != c) c = parents[c]
            return c
        }
        for (a in tps.indices) {
            if (tps[a].isManual) continue
            for (b in (a + 1) until tps.size) {
                if (tps[b].isManual) continue
                val pairStart = minDate(tps[a].startTime, tps[b].startTime)
                val pairEnd = maxDate(tps[a].endTime, tps[b].endTime)
                if (manuals.any { it.startTime < pairEnd && it.endTime > pairStart }) continue
                if (!TransportRules.isSameAutomaticTrip(tps[a], tps[b])) continue
                val ra = root(a); val rb = root(b)
                if (ra != rb) parents[rb] = ra
            }
        }
        val clusters = tps.indices.groupBy { root(it) }.values.map { idx -> idx.map { tps[it] } }
        for (cluster in clusters) {
            if (cluster.size <= 1) continue
            val survivor = cluster.reduce { best, c -> if (TransportRules.hasBetterObservedRoute(c, best)) c else best }
            val startTime = cluster.minOf { it.startTime }
            val endTime = cluster.maxOf { it.endTime }
            survivor.startTime = TransportRules.automaticTransportStart(survivor, startTime, survivor.startTime)
            survivor.endTime = endTime
            val duration = secs(survivor.startTime, endTime)
            survivor.averageSpeed = if (duration > 0) survivor.distance / duration else 0.0
            val earliest = cluster.minByOrNull { it.startTime }
            if (earliest != null && earliest !== survivor && !isPlaceholder(earliest.startLocation, "起点")) survivor.startLocation = earliest.startLocation
            val latest = cluster.maxByOrNull { it.endTime }
            if (latest != null && latest !== survivor && !isPlaceholder(latest.endLocation, "终点")) survivor.endLocation = latest.endLocation
            cluster.filter { it !== survivor }.forEach { ws.deleteTransport(it) }
        }
    }

    fun mergeConsecutiveTransports() {
        restart@ while (true) {
            val tps = ws.dayTransports()
            if (tps.size < 2) return
            for (i in 0 until tps.size - 1) {
                val current = tps[i]
                val next = tps[i + 1]
                val gap = secs(current.endTime, next.startTime)
                val cEnd = current.endTime
                val nStart = next.startTime
                val hasFpBetween = ws.footprints.any { !it.isIgnored && it.startTime >= cEnd && it.startTime < nStart }
                val currentType = typeOf(current.typeRaw) ?: TransportType.SLOW
                val nextType = typeOf(next.typeRaw) ?: TransportType.SLOW
                if (current.isManual || next.isManual) continue
                val isImmediatelyAdjacent = gap >= -60 && gap <= 60
                val isCompatible = currentType.category == nextType.category || (isImmediatelyAdjacent && !hasFpBetween)
                val crossesDeleted = TransportRules.overlapsDeletedTransportOverride(
                    minDate(current.startTime, next.startTime), maxDate(current.endTime, next.endTime), deletedRanges
                )
                if (gap >= -60 && gap <= AppConfig.TRANSPORT_MERGE_GAP_TOLERANCE && !hasFpBetween && isCompatible && !crossesDeleted) {
                    current.endTime = maxDate(current.endTime, next.endTime)
                    current.distance += next.distance
                    val duration = secs(current.startTime, current.endTime)
                    current.averageSpeed = if (duration > 0) current.distance / duration else 0.0
                    val currentPts = current.pointsOrNull
                    val nextPts = next.pointsOrNull
                    val mergedPoints = (currentPts ?: emptyList()) + (nextPts ?: emptyList())
                    if (current.manualTypeRaw == null && next.manualTypeRaw != null) {
                        current.manualTypeRaw = next.manualTypeRaw
                        current.typeRaw = next.typeRaw
                    } else if (current.manualTypeRaw == null) {
                        current.typeRaw = classify(
                            current.averageSpeed, current.startTime, current.endTime, duration, current.distance,
                            mergedPoints.size, mergedPoints.count { !it.isSyntheticPadding }
                        ).first.raw
                    }
                    if (currentPts != null && nextPts != null) current.setPoints(currentPts + nextPts)
                    current.stepCount = (current.stepCount ?: 0) + (next.stepCount ?: 0)
                    if (next.endLocation != "终点" && next.endLocation != "正在获取位置..." && next.endLocation.isNotEmpty()) {
                        current.endLocation = next.endLocation
                    }
                    ws.deleteTransport(next)
                    continue@restart
                }
            }
            return
        }
    }

    // ───────────────────────── gap bridging & snapping ─────────────────────────

    private fun simplifiedLocationName(fp: WFootprint): String {
        if (fp.isAddressEditedByHand && !fp.address.isNullOrEmpty()) return fp.address!!
        fp.placeID?.let { pid -> places.firstOrNull { it.placeID == pid }?.let { return it.name } }
        PlaceMatcher.getPlaceForCoordinate(fp.latitude, fp.longitude, places)?.let { return it.name }
        if (!fp.address.isNullOrEmpty()) return fp.address!!
        return "未知位置"
    }

    private class OccupiedRange(
        val start: Date, val end: Date,
        val startLoc: Pair<Double, Double>, val endLoc: Pair<Double, Double>,
        val startName: String, val endName: String,
        val includesTransport: Boolean
    )

    fun fillGapsBetweenItems() {
        val fps = ws.dayFootprints().toMutableList()
        fps.firstOrNull()?.let { first ->
            ws.footprints.filter { !it.isIgnored && it.endTime <= first.startTime }.maxByOrNull { it.endTime }
                ?.let { fps.add(0, it) }
        }
        fps.lastOrNull()?.let { last ->
            ws.footprints.filter { !it.isIgnored && it.startTime >= last.endTime }.minByOrNull { it.startTime }
                ?.let { fps.add(it) }
        }
        if (fps.size < 2) return
        val tps = ws.dayTransports()

        val ranges = mutableListOf<OccupiedRange>()
        for (f in fps) {
            val name = simplifiedLocationName(f)
            val c = f.latitude to f.longitude
            ranges.add(OccupiedRange(f.startTime, f.endTime, c, c, name, name, false))
        }
        for (t in tps) {
            val decoded = t.pointsOrNull
            val s = decoded?.firstOrNull()?.latLon ?: (0.0 to 0.0)
            val e = decoded?.lastOrNull()?.latLon ?: (0.0 to 0.0)
            ranges.add(OccupiedRange(t.startTime, t.endTime, s, e, t.startLocation, t.endLocation, true))
        }
        ranges.sortBy { it.start }

        val merged = mutableListOf<OccupiedRange>()
        for (r in ranges) {
            val last = merged.lastOrNull()
            if (last != null && r.start <= last.end.plusSeconds(1.0)) {
                val extends = r.end > last.end
                merged[merged.size - 1] = OccupiedRange(
                    last.start, maxDate(last.end, r.end), last.startLoc,
                    if (extends) r.endLoc else last.endLoc, last.startName,
                    if (extends) r.endName else last.endName,
                    last.includesTransport || r.includesTransport
                )
            } else merged.add(r)
        }

        for (i in 0 until merged.size - 1) {
            val current = merged[i]
            val next = merged[i + 1]
            val gapStart = current.end
            val gapEnd = next.start
            if (secs(gapStart, gapEnd) <= 0) continue
            if (TransportRules.overlapsDeletedTransportOverride(gapStart, gapEnd, deletedRanges)) continue
            val straightDist = GeoMath.distance(current.endLoc.first, current.endLoc.second, next.startLoc.first, next.startLoc.second)
            val gapPoints = rawPoints.filter { it.timestamp >= gapStart && it.timestamp <= gapEnd }
            if (gapPoints.isEmpty() && (current.includesTransport || next.includesTransport)) continue

            val pathDist: Double
            val pts: List<RouteCoordinate>
            val actualStart: Date
            val actualEnd: Date
            if (gapPoints.isNotEmpty()) {
                val observation = TransportRules.transportObservationAfterDormantGap(gapPoints)
                val observed = observation.points
                if (observed.isEmpty()) continue
                var route = observed.map { RouteCoordinate(it.latitude, it.longitude, it.timestamp.time) }
                val startCoord = RouteCoordinate(current.endLoc.first, current.endLoc.second, current.end.time, true, !current.includesTransport)
                if (!current.includesTransport) {
                    route = TransportRules.anchoringAutomaticTransportStart(route, startCoord)
                    if (route.firstOrNull()?.isStableStayBoundary != true) route = listOf(startCoord) + route
                } else if (TransportRules.shouldAttachTransportEndpoint(route.firstOrNull(), startCoord)) {
                    route = listOf(startCoord) + route
                }
                val endCoord = RouteCoordinate(next.startLoc.first, next.startLoc.second, next.start.time, true, !next.includesTransport)
                if (TransportRules.shouldAttachTransportEndpoint(route.lastOrNull(), endCoord)) route = route + endCoord
                pathDist = TransportRules.calculatePathDistance(route)
                pts = route
                actualStart = observation.inferredStartTime
                actualEnd = observed.last().timestamp
            } else {
                pathDist = straightDist
                pts = listOf(
                    RouteCoordinate(current.endLoc.first, current.endLoc.second, current.end.time, true, !current.includesTransport),
                    RouteCoordinate(next.startLoc.first, next.startLoc.second, next.start.time, true, !next.includesTransport)
                )
                val estimatedTravelTime = straightDist / max(AppConfig.TRANSPORT_UNOBSERVED_MIN_SPEED, AppConfig.TRANSPORT_DEPARTURE_MINIMUM_SPEED)
                actualStart = maxDate(gapStart, gapEnd.plusSeconds(-estimatedTravelTime))
                actualEnd = gapEnd
            }

            val isLongDistance = pathDist > 50_000
            if (pathDist > AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD &&
                !TransportRules.overlapsDeletedTransportOverride(actualStart, actualEnd, deletedRanges)
            ) {
                val routeDuration = secs(actualStart, actualEnd)
                if (routeDuration <= 0) continue
                val stable = TransportRules.hasStableBoundaryShortTripEvidence(pts, routeDuration)
                if (!(isLongDistance || routeDuration >= AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD || stable)) continue
                val speed = pathDist / routeDuration
                val (type, metrics) = classify(speed, actualStart, actualEnd, routeDuration, pathDist, pts.size, pts.count { !it.isSyntheticPadding })
                val tp = WTransport.create(dayStart, actualStart, actualEnd, current.endName, next.startName, type.raw, pathDist, speed, pts, metrics.steps)
                insertAutomaticallyDetectedTransport(tp)
            }
        }
    }

    private fun repairedTransportRoute(start: Date, end: Date, previous: WFootprint?): List<RawPoint> {
        if (end <= start) return emptyList()
        var route = rawPoints.filter {
            it.timestamp >= start && it.timestamp <= end && it.accuracy > 0 && it.accuracy <= AppConfig.HABIT_ANALYSIS_ACCURACY_THRESHOLD
        }
        if (route.size < 2) return route
        if (previous != null) {
            val exitRadius = min(AppConfig.STAY_DISTANCE_THRESHOLD * 0.4, 80.0)
            val exitIndex = route.indexOfFirst { it.distanceTo(previous.latitude, previous.longitude) >= exitRadius }
            if (exitIndex >= 0) route = route.subList(max(0, exitIndex - 1), route.size)
        }
        return route
    }

    fun snapTransportsToFootprints() {
        val fps = ws.dayFootprints()
        val tps = ws.dayTransports()
        for (tp in tps) {
            if (tp.isManual) continue
            var changed = false
            var decoded = tp.pointsOrNull ?: emptyList()
            var alignedPrev: WFootprint? = null
            var alignedNext: WFootprint? = null

            fps.lastOrNull { it.endTime <= tp.startTime.plusSeconds(AppConfig.SNAP_TIME_BUFFER) }?.let { prevFp ->
                val gap = secs(prevFp.endTime, tp.startTime)
                val crosses = tps.any { it !== tp && it.startTime < tp.startTime && it.endTime > prevFp.endTime }
                if (gap >= 0 && !crosses) {
                    val name = simplifiedLocationName(prevFp)
                    if (name.isNotEmpty() && name != "某地") tp.startLocation = name
                    alignedPrev = prevFp
                    changed = true
                }
            }
            fps.firstOrNull { it.startTime >= tp.endTime.plusSeconds(-AppConfig.SNAP_TIME_BUFFER) }?.let { nextFp ->
                val gap = secs(tp.endTime, nextFp.startTime)
                val crosses = tps.any { it !== tp && it.endTime > tp.endTime && it.startTime < nextFp.startTime }
                if (gap >= 0 && gap < AppConfig.TRANSPORT_ALIGNMENT_THRESHOLD && !crosses) {
                    val name = simplifiedLocationName(nextFp)
                    if (name.isNotEmpty() && name != "某地") tp.endLocation = name
                    alignedNext = nextFp
                    changed = true
                }
            }

            val rawRoute = repairedTransportRoute(tp.startTime, tp.endTime, alignedPrev)
            if (rawRoute.size >= 2) {
                decoded = rawRoute.map { RouteCoordinate(it.latitude, it.longitude, it.timestamp.time) }
                changed = true
            }
            alignedPrev?.let { prev ->
                val c = RouteCoordinate(prev.latitude, prev.longitude, prev.endTime.time, true, true)
                decoded = TransportRules.anchoringAutomaticTransportStart(decoded, c)
                if (decoded.firstOrNull()?.isStableStayBoundary != true) decoded = listOf(c) + decoded
            }
            alignedNext?.let { nxt ->
                val c = RouteCoordinate(nxt.latitude, nxt.longitude, nxt.startTime.time, true, true)
                if (TransportRules.shouldAttachTransportEndpoint(decoded.lastOrNull(), c) && decoded.lastOrNull()?.isStableStayBoundary != true) {
                    decoded = decoded + c
                }
            }
            if (changed) {
                tp.setPoints(decoded)
                tp.distance = TransportRules.calculatePathDistance(decoded)
                val duration = secs(tp.startTime, tp.endTime)
                if (duration > 0) tp.averageSpeed = tp.distance / duration
            }
        }
    }

    // ───────────────────────── footprint post-processing ─────────────────────────

    fun splitFootprintsByTransports() {
        val fps = ws.dayFootprints()
        if (fps.isEmpty()) return
        val transports = ws.dayTransports()
        if (transports.isEmpty()) return
        val minSegment = AppConfig.MIN_KEPT_SEGMENT_DURATION
        for (fp in fps) {
            if (fp.isManual) continue
            val hasUserEdits = fp.isAddressEditedByHand || !fp.reason.isNullOrEmpty() || fp.photos.isNotEmpty() || fp.isHighlight == true
            val overlaps = transports.mapNotNull { t ->
                val s = maxDate(fp.startTime, t.startTime)
                val e = minDate(fp.endTime, t.endTime)
                if (secs(s, e) > 60) s to e else null
            }.sortedBy { it.first }
            if (overlaps.isEmpty()) continue

            val blocked = mutableListOf<Pair<Date, Date>>()
            for (interval in overlaps) {
                val last = blocked.lastOrNull()
                if (last != null && interval.first <= last.second.plusSeconds(60.0)) {
                    blocked[blocked.size - 1] = last.first to maxDate(last.second, interval.second)
                } else blocked.add(interval)
            }
            val segments = mutableListOf<Pair<Date, Date>>()
            var cursor = fp.startTime
            for (b in blocked) {
                if (secs(cursor, b.first) >= minSegment) segments.add(cursor to b.first)
                cursor = maxDate(cursor, b.second)
            }
            if (secs(cursor, fp.endTime) >= minSegment) segments.add(cursor to fp.endTime)

            if (segments.isEmpty()) {
                val fullyCovered = blocked.first().first <= fp.startTime.plusSeconds(60.0) &&
                    blocked.last().second >= fp.endTime.plusSeconds(-60.0)
                if (fullyCovered && !hasUserEdits) ws.deleteFootprint(fp)
                continue
            }
            val baseLats = if (fp.lats.isEmpty()) listOf(fp.latitude) else fp.lats.toList()
            val baseLons = if (fp.lons.isEmpty()) listOf(fp.longitude) else fp.lons.toList()
            segments.forEachIndexed { idx, (s, e) ->
                if (idx == 0) {
                    fp.startTime = s; fp.endTime = e; fp.date = startOfDay(s); fp.locationHash = "SPLIT_BY_TRANSPORT"
                } else {
                    val newFp = WFootprint.create(startOfDay(s), s, e, baseLats.zip(baseLons), "SPLIT_BY_TRANSPORT", fp.status)
                    newFp.placeID = fp.placeID
                    newFp.address = fp.address
                    newFp.isAddressEditedByHand = fp.isAddressEditedByHand
                    newFp.activityTypeValue = fp.activityTypeValue
                    newFp.stepCount = fp.stepCount
                    newFp.walkingDistance = fp.walkingDistance
                    newFp.floorsAscended = fp.floorsAscended
                    ws.insertFootprint(newFp)
                }
            }
        }
    }

    private fun robustDiameter(points: List<RawPoint>): Double {
        if (points.size <= 1) return 0.0
        val c = GeoMath.centroid(points.map { it.latLon })
        val distances = points.map { it.distanceTo(c.first, c.second) }.sorted()
        return distances[(distances.size * 0.90).toInt()] * 2.0
    }

    /** iOS TimelineBuilder.hasSignificantMovement. */
    private fun hasSignificantMovement(f1: WFootprint, f2: WFootprint, points: List<RawPoint>): Boolean {
        if (points.isEmpty()) return false
        if (robustDiameter(points) > AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD * 2.0) return true
        val buffer = AppConfig.STAY_DISTANCE_THRESHOLD * 1.8
        val outliers = points.count { it.distanceTo(f1.latitude, f1.longitude) > buffer && it.distanceTo(f2.latitude, f2.longitude) > buffer }
        return outliers > 2
    }

    fun mergeConsecutiveFootprints(threshold: Double) {
        restart@ while (true) {
            val fps = ws.dayFootprints()
            if (fps.size < 2) return
            val allDayTransports = ws.dayTransports()
            for (i in 0 until fps.size - 1) {
                val current = fps[i]
                val next = fps[i + 1]
                if (!(!current.isManual || current.allowsAutomaticDurationExtension) || next.isManual) continue
                val dist = GeoMath.distance(current.latitude, current.longitude, next.latitude, next.longitude)
                val gap = secs(current.endTime, next.startTime)
                val sameLogicalPlace = current.placeID != null && current.placeID == next.placeID
                val mergeThreshold = if (sameLogicalPlace) max(threshold, AppConfig.SAME_PLACE_MERGE_BONUS_THRESHOLD) else threshold
                val mergeGapLimit = if (sameLogicalPlace) secs(dayStart, dayEnd) else AppConfig.STAY_MERGE_GAP_THRESHOLD
                val currentSameDay = isSameDay(current.startTime, current.endTime.plusSeconds(-0.001))
                val nextSameDay = isSameDay(next.startTime, next.endTime.plusSeconds(-0.001))
                if (!currentSameDay || !nextSameDay || !isSameDay(current.startTime, next.startTime)) continue
                val cEnd = current.endTime
                val nStart = next.startTime
                if (allDayTransports.any { it.endTime > cEnd && it.startTime < nStart }) continue
                if (dist < mergeThreshold && gap < mergeGapLimit) {
                    val gapPoints = rawPoints.filter { it.timestamp >= current.endTime && it.timestamp < next.startTime }
                    val effectivelySame = dist < mergeThreshold
                    if (!effectivelySame && gapPoints.isNotEmpty() && hasSignificantMovement(current, next, gapPoints)) continue
                    val bothHavePhotos = current.photos.isNotEmpty() && next.photos.isNotEmpty()
                    if (bothHavePhotos && dist > AppConfig.STAY_DISTANCE_THRESHOLD) continue
                    current.endTime = maxDate(current.endTime, next.endTime)
                    current.appendLocations(next.lats, next.lons)
                    current.mergePhotos(next.photos)
                    if (current.placeID == null && next.placeID != null) {
                        current.placeID = next.placeID
                        current.address = next.address
                    }
                    current.placeID?.let { pid -> places.firstOrNull { it.placeID == pid }?.let { current.address = it.name } }
                    ws.deleteFootprint(next)
                    continue@restart
                }
            }
            return
        }
    }

    /** iOS LocationManager.consolidateFootprints(targetDate:). */
    fun consolidateFootprints() {
        val mergeTime = AppConfig.LIVE_STAY_MERGE_TIME_THRESHOLD
        val mergeDist = AppConfig.LIVE_STAY_MERGE_DISTANCE_THRESHOLD
        val minKeep = AppConfig.LIVE_STAY_MIN_DURATION_THRESHOLD
        fun inDay() = ws.footprints.filter { !it.isIgnored && it.startTime >= dayStart && it.startTime < dayEnd }.sortedBy { it.startTime }

        val seen = mutableSetOf<String>()
        for (fp in inDay()) {
            if (fp.isUserModified) continue
            if (fp.durationSec < minKeep) { ws.deleteFootprint(fp); continue }
            val key = "${fp.startTime.time}-${fp.endTime.time}-${fp.latitude}-${fp.longitude}"
            if (!seen.add(key)) ws.deleteFootprint(fp)
        }

        val sorted = inDay()
        val working = sorted.toMutableList()
        val allDayTransports = ws.dayTransports()
        var i = 0
        while (i < working.size - 1) {
            val base = working[i]
            val next = working[i + 1]
            val timeGap = secs(base.endTime, next.startTime)
            val dist = GeoMath.distance(base.latitude, base.longitude, next.latitude, next.longitude)
            if (base.isManual || next.isManual) { i++; continue }
            val baseSameDay = isSameDay(base.startTime, base.endTime.plusSeconds(-0.001))
            val nextSameDay = isSameDay(next.startTime, next.endTime.plusSeconds(-0.001))
            if (!baseSameDay || !nextSameDay || !isSameDay(base.startTime, next.startTime)) { i++; continue }
            val bEnd = base.endTime
            val nStart = next.startTime
            if (allDayTransports.any { it.endTime > bEnd && it.startTime < nStart }) { i++; continue }
            if (timeGap <= mergeTime && dist <= mergeDist) {
                base.startTime = minDate(base.startTime, next.startTime)
                base.endTime = maxDate(base.endTime, next.endTime)
                base.date = startOfDay(base.startTime)
                base.appendLocations(next.lats, next.lons)
                base.mergePhotos(next.photos)
                ws.deleteFootprint(next)
                working.removeAt(i + 1)
            } else i++
        }

        for (fp in sorted) {
            if (fp.id in ws.deletedFootprintIDs) continue
            if (fp.placeID == null || fp.locationHash == "TBD") {
                PlaceMatcher.matchedPlaceFor(fp.latitude, fp.longitude, places)?.let { best ->
                    if (fp.placeID != best.placeID) {
                        fp.placeID = best.placeID
                        if (fp.address.isNullOrEmpty()) fp.address = best.name
                    }
                }
            }
            splitLargeFootprintByDistance(fp)
        }
    }

    /** iOS LocationManager.splitLargeFootprintByDistance (AI re-analysis is not ported). */
    fun splitLargeFootprintByDistance(fp: WFootprint) {
        val hasUserEdits = fp.isAddressEditedByHand || !fp.reason.isNullOrEmpty() || fp.photos.isNotEmpty() || fp.isManual
        if (hasUserEdits) return
        val coords = fp.lats.zip(fp.lons)
        if (coords.size <= 15) return
        val radius = min(AppConfig.SPLIT_CLUSTER_RADIUS_CAP, AppConfig.MERGE_DISTANCE_THRESHOLD * AppConfig.SPLIT_CLUSTER_RADIUS_RATIO)
        val clusters = mutableListOf<Triple<Int, Int, Pair<Double, Double>>>()
        var i = 0
        while (i < coords.size) {
            var j = i + 1
            while (j < coords.size && GeoMath.distance(coords[i].first, coords[i].second, coords[j].first, coords[j].second) < radius) j++
            if (j - i >= AppConfig.SPLIT_CLUSTER_MIN_POINTS) {
                clusters.add(Triple(i, j - 1, GeoMath.centroid(coords.subList(i, j))))
            }
            i = j
        }
        if (clusters.size <= 1) return
        val distinct = mutableListOf(clusters[0].first to clusters[0].second)
        var lastCenter = clusters[0].third
        for (k in 1 until clusters.size) {
            val curr = clusters[k]
            if (GeoMath.distance(curr.third.first, curr.third.second, lastCenter.first, lastCenter.second) > AppConfig.MERGE_DISTANCE_THRESHOLD) {
                distinct.add(curr.first to curr.second)
                lastCenter = curr.third
            } else {
                distinct[distinct.size - 1] = distinct.last().first to curr.second
            }
        }
        if (distinct.size <= 1) return
        val totalPoints = coords.size.toDouble()
        val totalDuration = fp.durationSec
        val baseStart = fp.startTime
        val splitRanges = distinct.map { (s, e) ->
            val sTime = baseStart.plusSeconds(totalDuration * (s / totalPoints))
            val eTime = baseStart.plusSeconds(totalDuration * (e / totalPoints))
            Triple(sTime, eTime, coords.subList(s, e + 1).toList())
        }
        if (!splitRanges.all { secs(it.first, it.second) >= AppConfig.STAY_DURATION_THRESHOLD }) return
        splitRanges.forEachIndexed { idx, (s, e, sub) ->
            if (idx == 0) {
                fp.lats = sub.map { it.first }.toMutableList()
                fp.lons = sub.map { it.second }.toMutableList()
                fp.startTime = s; fp.endTime = e; fp.date = startOfDay(s); fp.locationHash = "SPLIT_FIXED"
            } else {
                val newFp = WFootprint.create(startOfDay(s), s, e, sub, "SPLIT_FIXED", fp.status)
                newFp.placeID = fp.placeID
                newFp.address = fp.address
                ws.insertFootprint(newFp)
            }
        }
    }

    /** iOS autoFillMissingActivityTypes (activity part only). */
    fun autoFillMissingActivityTypes(): Int {
        var count = 0
        for (fp in ws.footprints.filter { !it.isIgnored && it.startTime >= dayStart && it.startTime < dayEnd }) {
            if (fp.activityTypeValue != null || fp.isManual) continue
            val pid = fp.placeID ?: continue
            frequentActivity(pid, fp.startTime)?.let { fp.activityTypeValue = it; count++ }
        }
        return count
    }

    /** iOS LocationManager.mergeRecentFootprints: last 5 stays ending within 30 min. */
    fun mergeRecentFootprints(): Boolean {
        val recentCutoff = now.plusSeconds(-30 * 60.0)
        val todayFps = ws.footprints.filter { !it.isIgnored && it.startTime >= dayStart && it.startTime < dayEnd }.sortedBy { it.startTime }
        val recent = todayFps.filter { it.endTime >= recentCutoff }.takeLast(5).toMutableList()
        if (recent.size < 2) return false
        val allDayTransports = ws.dayTransports()
        var didMerge = false
        var i = 0
        while (i < recent.size - 1) {
            val base = recent[i]
            val next = recent[i + 1]
            if (base.isManual || next.isManual) { i++; continue }
            val samePlace = (base.placeID != null && base.placeID == next.placeID) ||
                GeoMath.distance(base.latitude, base.longitude, next.latitude, next.longitude) <= AppConfig.MERGE_DISTANCE_THRESHOLD
            val baseSameDay = isSameDay(base.startTime, base.endTime.plusSeconds(-0.001))
            val nextSameDay = isSameDay(next.startTime, next.endTime.plusSeconds(-0.001))
            if (!baseSameDay || !nextSameDay || !isSameDay(base.startTime, next.startTime)) { i++; continue }
            val bEnd = base.endTime
            val nStart = next.startTime
            if (allDayTransports.any { it.endTime > bEnd && it.startTime < nStart }) { i++; continue }
            if (secs(bEnd, nStart) > AppConfig.STAY_MERGE_GAP_THRESHOLD) { i++; continue }
            if (samePlace) {
                base.endTime = maxDate(base.endTime, next.endTime)
                base.appendLocations(next.lats, next.lons)
                base.mergePhotos(next.photos)
                if (base.activityTypeValue == null) base.activityTypeValue = next.activityTypeValue
                ws.deleteFootprint(next)
                recent.removeAt(i + 1)
                didMerge = true
            } else i++
        }
        return didMerge
    }

    // ───────────────────────── cross-day normalization ─────────────────────────

    fun normalizeCrossDayFootprints(footprints: List<WFootprint>): Boolean {
        var changed = false
        for (fp in footprints) {
            if (fp.endTime <= fp.startTime) continue
            val startDay = startOfDay(fp.startTime)
            val endDay = startOfDay(maxDate(fp.startTime, fp.endTime.plusSeconds(-0.001)))
            if (startDay == endDay) {
                if (fp.date != startDay) { fp.date = startDay; changed = true }
                continue
            }
            splitCrossDayFootprint(fp)
            changed = true
        }
        return changed
    }

    private fun splitCrossDayFootprint(fp: WFootprint) {
        val originalStart = fp.startTime
        val originalEnd = fp.endTime
        val originalCoords = fp.lats.zip(fp.lons)
        val originalPhotos = fp.photos.toList()
        var segmentStart = originalStart
        var segmentIndex = 0
        while (segmentStart < originalEnd) {
            val segmentDay = startOfDay(segmentStart)
            val nextDay = addDays(segmentDay, 1)
            val segmentEnd = minDate(originalEnd, nextDay)
            if (segmentEnd <= segmentStart) break
            val segCoords = proportionalLocations(originalCoords, segmentStart, segmentEnd, originalStart, originalEnd)
            // Photo creation dates are unknown here: like iOS, they stay with the first segment.
            val segPhotos = if (segmentIndex == 0) originalPhotos else emptyList()
            if (segmentEnd == originalEnd) {
                fp.date = segmentDay
                fp.startTime = segmentStart
                fp.endTime = segmentEnd
                fp.lats = segCoords.map { it.first }.toMutableList()
                fp.lons = segCoords.map { it.second }.toMutableList()
                fp.photos = segPhotos.toMutableList()
            } else {
                val seg = WFootprint.create(segmentDay, segmentStart, segmentEnd, segCoords, "${fp.locationHash}_DAY_$segmentIndex", fp.status)
                seg.reason = fp.reason
                seg.isHighlight = fp.isHighlight
                seg.placeID = fp.placeID
                seg.photos = segPhotos.toMutableList()
                seg.address = fp.address
                seg.aiAnalyzed = fp.aiAnalyzed
                seg.isAddressEditedByHand = fp.isAddressEditedByHand
                seg.activityTypeValue = fp.activityTypeValue
                seg.stepCount = fp.stepCount
                seg.walkingDistance = fp.walkingDistance
                seg.floorsAscended = fp.floorsAscended
                ws.insertFootprint(seg)
            }
            segmentIndex++
            segmentStart = segmentEnd
        }
    }

    private fun proportionalLocations(
        locations: List<Pair<Double, Double>>, segmentStart: Date, segmentEnd: Date, originalStart: Date, originalEnd: Date
    ): List<Pair<Double, Double>> {
        if (locations.size <= 1) return locations
        val total = secs(originalStart, originalEnd)
        if (total <= 0) return locations
        val maxIndex = locations.size - 1
        val startRatio = max(0.0, min(1.0, secs(originalStart, segmentStart) / total))
        val endRatio = max(startRatio, min(1.0, secs(originalStart, segmentEnd) / total))
        val lower = max(0, min(maxIndex, kotlin.math.floor(startRatio * maxIndex).toInt()))
        val upper = max(lower, min(maxIndex, kotlin.math.ceil(endRatio * maxIndex).toInt()))
        return locations.subList(lower, upper + 1).toList()
    }
}
