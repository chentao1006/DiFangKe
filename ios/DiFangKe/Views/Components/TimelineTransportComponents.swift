import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import UIKit
import Aptabase

struct TransportRouteAnimationFrame: @unchecked Sendable {
    let coordinate: CLLocationCoordinate2D
    let travelsWest: Bool
    let timeText: String
    let timestamp: Date
    let routeCoordinateIndex: Int
    let highlightedSegments: [TransportLineSegment]
}

struct TransportRouteProgressGeometry: @unchecked Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let edgeIsDashed: [Bool]

    /// MapKit must never receive an invalid or zero-length polyline.  Keep the
    /// cleanup in the shared background playback builder so every playback
    /// surface renders the exact same safe geometry.
    nonisolated static func renderableCoordinates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(coordinates.count)
        for coordinate in coordinates where coordinate.isRenderableMapCoordinate {
            guard result.last?.latitude != coordinate.latitude ||
                    result.last?.longitude != coordinate.longitude else { continue }
            result.append(coordinate)
        }
        return result.count >= 2 ? result : []
    }

    nonisolated static func renderableSegments(
        _ segments: [TransportLineSegment],
        idPrefix: String
    ) -> [TransportLineSegment] {
        segments.enumerated().compactMap { index, segment in
            let coordinates = renderableCoordinates(segment.coordinates)
            guard coordinates.count >= 2 else { return nil }
            return TransportLineSegment(
                id: "\(idPrefix)-\(index)",
                coordinates: coordinates,
                isDashed: segment.isDashed
            )
        }
    }

    nonisolated init(segments: [TransportLineSegment]) {
        var coordinates: [CLLocationCoordinate2D] = []
        var edgeStyles: [Bool] = []
        for segment in segments {
            for coordinate in Self.renderableCoordinates(segment.coordinates) {
                if coordinates.last?.latitude != coordinate.latitude ||
                    coordinates.last?.longitude != coordinate.longitude {
                    if !coordinates.isEmpty {
                        edgeStyles.append(segment.isDashed)
                    }
                    coordinates.append(coordinate)
                }
            }
        }
        self.coordinates = coordinates
        self.edgeIsDashed = edgeStyles
    }

    nonisolated func highlightedSegments(
        through endIndex: Int,
        endingAt finalCoordinate: CLLocationCoordinate2D?,
        idPrefix: String
    ) -> [TransportLineSegment] {
        guard !coordinates.isEmpty else { return [] }
        let boundedEndIndex = min(max(endIndex, 0), coordinates.count - 1)
        var highlightedCoordinates = Array(coordinates[0...boundedEndIndex])
        var highlightedEdgeStyles = Array(edgeIsDashed.prefix(max(highlightedCoordinates.count - 1, 0)))
        if let finalCoordinate,
           highlightedCoordinates.last?.latitude != finalCoordinate.latitude ||
            highlightedCoordinates.last?.longitude != finalCoordinate.longitude {
            highlightedCoordinates.append(finalCoordinate)
            let activeEdgeIndex = min(boundedEndIndex, max(edgeIsDashed.count - 1, 0))
            highlightedEdgeStyles.append(edgeIsDashed.indices.contains(activeEdgeIndex) ? edgeIsDashed[activeEdgeIndex] : false)
        }
        guard highlightedCoordinates.count >= 2,
              highlightedEdgeStyles.count == highlightedCoordinates.count - 1 else { return [] }

        var result: [TransportLineSegment] = []
        var runStart = 0
        var runIsDashed = highlightedEdgeStyles[0]
        for edgeIndex in 1..<highlightedEdgeStyles.count
        where highlightedEdgeStyles[edgeIndex] != runIsDashed {
            result.append(TransportLineSegment(
                id: "\(idPrefix)-\(result.count)",
                coordinates: Array(highlightedCoordinates[runStart...edgeIndex]),
                isDashed: runIsDashed
            ))
            runStart = edgeIndex
            runIsDashed = highlightedEdgeStyles[edgeIndex]
        }
        result.append(TransportLineSegment(
            id: "\(idPrefix)-\(result.count)",
            coordinates: Array(highlightedCoordinates[runStart...highlightedEdgeStyles.count]),
            isDashed: runIsDashed
        ))
        return result
    }
}

struct TransportRouteAnimation: @unchecked Sendable {
    let frames: [TransportRouteAnimationFrame]
    let frameInterval: TimeInterval
    let endPause: TimeInterval

    static let empty = TransportRouteAnimation(frames: [], frameInterval: 0, endPause: 0)

    nonisolated static func make(
        segments: [TransportLineSegment],
        pathPoints: [TransportPathPoint],
        averageSpeed: Double,
        startTime: Date,
        endTime: Date
    ) -> TransportRouteAnimation {
        let progressGeometry = TransportRouteProgressGeometry(segments: segments)
        let coordinates = progressGeometry.coordinates
        guard coordinates.count >= 2 else { return .empty }

        var cumulativeDistances: [Double] = [0]
        var totalDistance = 0.0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            totalDistance += CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            cumulativeDistances.append(totalDistance)
        }
        guard totalDistance.isFinite, totalDistance > 0 else { return .empty }

        let recordedDuration = endTime.timeIntervalSince(startTime)
        let fallbackDuration = averageSpeed.isFinite && averageSpeed > 0
            ? totalDistance / averageSpeed
            : 0
        let timelineDuration = recordedDuration > 0 ? recordedDuration : fallbackDuration
        guard timelineDuration.isFinite, timelineDuration > 0 else { return .empty }
        let timing = timedAnchors(
            pathPoints: pathPoints,
            segments: segments,
            duration: timelineDuration,
            totalDistance: totalDistance,
            averageSpeed: averageSpeed
        )
        let animationDuration = timing.duration
        let anchors = timing.anchors
        let config = AppConfig.shared
        let timeScale = max(config.transportRouteAnimationTimeScale, 1)
        let minimumDuration = max(config.transportRouteAnimationMinDuration, 1)
        let maximumDuration = max(config.transportRouteAnimationMaxDuration, minimumDuration)
        let loopDuration = min(max(animationDuration / timeScale, minimumDuration), maximumDuration)
        let framesPerSecond = max(config.mapRoutePlaybackFrameRate, 1)
        let frameCount = max(2, Int((loopDuration * framesPerSecond).rounded()))
        var frames: [TransportRouteAnimationFrame] = []
        frames.reserveCapacity(frameCount)
        var segmentIndex = 0
        var anchorIndex = 0
        var travelsWest = false
        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm"

        for frameIndex in 0..<frameCount {
            let fraction = Double(frameIndex) / Double(frameCount - 1)
            let targetElapsed = animationDuration * fraction
            while anchorIndex + 1 < anchors.count - 1,
                  anchors[anchorIndex + 1].elapsed < targetElapsed {
                anchorIndex += 1
            }
            let leadingAnchor = anchors[anchorIndex]
            let trailingAnchor = anchors[anchorIndex + 1]
            let anchorDuration = trailingAnchor.elapsed - leadingAnchor.elapsed
            let anchorFraction = anchorDuration > 0
                ? (targetElapsed - leadingAnchor.elapsed) / anchorDuration
                : 0
            let targetDistance = leadingAnchor.distance +
                (trailingAnchor.distance - leadingAnchor.distance) * anchorFraction
            while segmentIndex + 1 < cumulativeDistances.count - 1,
                  cumulativeDistances[segmentIndex + 1] < targetDistance {
                segmentIndex += 1
            }
            let start = coordinates[segmentIndex]
            let end = coordinates[segmentIndex + 1]
            let segmentDistance = cumulativeDistances[segmentIndex + 1] - cumulativeDistances[segmentIndex]
            let segmentFraction = segmentDistance > 0
                ? (targetDistance - cumulativeDistances[segmentIndex]) / segmentDistance
                : 0
            var longitudeDelta = end.longitude - start.longitude
            if longitudeDelta > 180 { longitudeDelta -= 360 }
            if longitudeDelta < -180 { longitudeDelta += 360 }
            if longitudeDelta != 0 { travelsWest = longitudeDelta < 0 }
            let coordinate = CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * segmentFraction,
                longitude: start.longitude + longitudeDelta * segmentFraction
            )
            frames.append(TransportRouteAnimationFrame(
                coordinate: coordinate,
                travelsWest: travelsWest,
                timeText: timeFormatter.string(
                    from: startTime.addingTimeInterval(max(recordedDuration, 0) * fraction)
                ),
                timestamp: startTime.addingTimeInterval(max(recordedDuration, 0) * fraction),
                routeCoordinateIndex: segmentIndex,
                highlightedSegments: progressGeometry.highlightedSegments(
                    through: segmentIndex,
                    endingAt: coordinate,
                    idPrefix: "transport-route-progress-\(frameIndex)"
                )
            ))
        }
        return TransportRouteAnimation(
            frames: frames,
            frameInterval: loopDuration / Double(frameCount),
            endPause: max(config.transportRouteAnimationEndPause, 0)
        )
    }

    nonisolated private static func timedAnchors(
        pathPoints: [TransportPathPoint],
        segments: [TransportLineSegment],
        duration: TimeInterval,
        totalDistance: Double,
        averageSpeed: Double
    ) -> (anchors: [(elapsed: TimeInterval, distance: Double)], duration: TimeInterval) {
        var anchors: [(elapsed: TimeInterval, distance: Double)] = [(0, 0)]
        let validPoints = pathPoints.filter {
            $0.coordinate.latitude.isFinite &&
                $0.coordinate.longitude.isFinite &&
                CLLocationCoordinate2DIsValid($0.coordinate)
        }
        guard validPoints.count >= 2 else {
            return ([(0, 0), (duration, totalDistance)], duration)
        }

        var recordedDistances: [Double] = [0]
        recordedDistances.reserveCapacity(validPoints.count)
        var recordedTotalDistance = 0.0
        for (start, end) in zip(validPoints, validPoints.dropFirst()) {
            recordedTotalDistance += CLLocation(
                latitude: start.coordinate.latitude,
                longitude: start.coordinate.longitude
            ).distance(from: CLLocation(
                latitude: end.coordinate.latitude,
                longitude: end.coordinate.longitude
            ))
            recordedDistances.append(recordedTotalDistance)
        }
        guard recordedTotalDistance.isFinite, recordedTotalDistance > 0 else {
            return ([(0, 0), (duration, totalDistance)], duration)
        }

        // `Transport.lineSegments` uses exactly the same consecutive inferred/
        // recorded edge runs as `validPoints`. Map each run independently so a
        // completed dashed route receives the full time interval of its source
        // gap. A whole-route ratio can squeeze a curved completion into the
        // neighboring solid segments and make the dashed geometry look skipped.
        let displayedDistances = displayedPointDistances(
            validPoints: validPoints,
            recordedDistances: recordedDistances,
            segments: segments,
            totalDistance: totalDistance
        )

        let segmentAverageSpeed = averageSpeed.isFinite && averageSpeed > 0
            ? averageSpeed
            : totalDistance / duration
        var edgeDurations: [TimeInterval] = []
        edgeDurations.reserveCapacity(validPoints.count - 1)
        for index in 0..<(validPoints.count - 1) {
            let start = validPoints[index]
            let end = validPoints[index + 1]
            let displayedEdgeDistance = max(displayedDistances[index + 1] - displayedDistances[index], 0)
            let recordedEdgeDuration = start.timestamp.flatMap { startTime in
                end.timestamp.map { $0.timeIntervalSince(startTime) }
            }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let estimatedEdgeDuration = segmentAverageSpeed.isFinite && segmentAverageSpeed > 0
                ? displayedEdgeDistance / segmentAverageSpeed
                : 0
            let isInferred = Transport.isInferredGap(start, end)
            let edgeDuration: TimeInterval
            if isInferred {
                // Missing/synthetic geometry has no measured point-by-point
                // speed. Traverse it at this transport segment's displayed
                // average speed without later normalizing that duration away.
                edgeDuration = estimatedEdgeDuration
            } else {
                edgeDuration = recordedEdgeDuration ?? estimatedEdgeDuration
            }
            edgeDurations.append(max(edgeDuration, 0))
        }

        let weightedDuration = edgeDurations.reduce(0, +)
        guard weightedDuration.isFinite, weightedDuration > 0 else {
            return ([(0, 0), (duration, totalDistance)], duration)
        }
        var accumulatedDuration = 0.0
        for index in 1..<validPoints.count {
            accumulatedDuration += edgeDurations[index - 1]
            let elapsed = accumulatedDuration
            guard elapsed > anchors.last!.elapsed, elapsed < weightedDuration else { continue }
            anchors.append((elapsed, displayedDistances[index]))
        }
        anchors.append((weightedDuration, totalDistance))
        return (anchors, weightedDuration)
    }

    nonisolated private static func displayedPointDistances(
        validPoints: [TransportPathPoint],
        recordedDistances: [Double],
        segments: [TransportLineSegment],
        totalDistance: Double
    ) -> [Double] {
        struct EdgeRun {
            let startEdge: Int
            let endEdge: Int
            let isDashed: Bool
        }

        let edgeCount = validPoints.count - 1
        var runs: [EdgeRun] = []
        var runStart = 0
        var runIsDashed = Transport.isInferredGap(validPoints[0], validPoints[1])
        if edgeCount > 1 {
            for edge in 1..<edgeCount {
                let isDashed = Transport.isInferredGap(validPoints[edge], validPoints[edge + 1])
                if isDashed != runIsDashed {
                    runs.append(EdgeRun(startEdge: runStart, endEdge: edge, isDashed: runIsDashed))
                    runStart = edge
                    runIsDashed = isDashed
                }
            }
        }
        runs.append(EdgeRun(startEdge: runStart, endEdge: edgeCount, isDashed: runIsDashed))

        guard runs.count == segments.count,
              zip(runs, segments).allSatisfy({ pair in pair.0.isDashed == pair.1.isDashed }) else {
            let recordedTotal = recordedDistances.last ?? 0
            guard recordedTotal > 0 else { return Array(repeating: 0, count: validPoints.count) }
            return recordedDistances.map { totalDistance * $0 / recordedTotal }
        }

        let segmentLengths = segments.map { segment in
            zip(segment.coordinates, segment.coordinates.dropFirst()).reduce(0.0) {
                $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                    .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
            }
        }
        let displayedTotal = segmentLengths.reduce(0, +)
        guard displayedTotal.isFinite, displayedTotal > 0 else {
            let recordedTotal = recordedDistances.last ?? 0
            guard recordedTotal > 0 else { return Array(repeating: 0, count: validPoints.count) }
            return recordedDistances.map { totalDistance * $0 / recordedTotal }
        }

        var result = Array(repeating: 0.0, count: validPoints.count)
        var displayedOffset = 0.0
        for (runIndex, run) in runs.enumerated() {
            let runRecordedStart = recordedDistances[run.startEdge]
            let runRecordedLength = recordedDistances[run.endEdge] - runRecordedStart
            let segmentLength = segmentLengths[runIndex]
            for pointIndex in run.startEdge...run.endEdge {
                let fraction = runRecordedLength > 0
                    ? (recordedDistances[pointIndex] - runRecordedStart) / runRecordedLength
                    : Double(pointIndex - run.startEdge) / Double(max(run.endEdge - run.startEdge, 1))
                result[pointIndex] = displayedOffset + segmentLength * fraction
            }
            displayedOffset += segmentLength
        }

        let scale = totalDistance / displayedTotal
        return result.map { $0 * scale }
    }
}

struct DayRoutePlaybackInput: @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        case stop(
            coordinate: CLLocationCoordinate2D,
            startTime: Date,
            endTime: Date,
            symbolName: String,
            colorHex: String?
        )
        case footprint(
            latitudeData: Data,
            longitudeData: Data,
            startTime: Date,
            endTime: Date,
            symbolName: String,
            colorHex: String?
        )
        case transport(Transport)
    }

    let kind: Kind
    let startTime: Date
    let contextLabel: String?
    let contextDetail: String?

    init(kind: Kind, startTime: Date, contextLabel: String? = nil, contextDetail: String? = nil) {
        self.kind = kind
        self.startTime = startTime
        self.contextLabel = contextLabel
        self.contextDetail = contextDetail
    }
}

struct DayRoutePlaybackFrame: @unchecked Sendable {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let symbolName: String
    let activityColorHex: String?
    let isStop: Bool
    let stopIndex: Int?
    let travelsWest: Bool
    let activeRouteIndex: Int?
    let activeRouteCoordinateIndex: Int
    let completedRouteCount: Int
    let completedStopCount: Int
    let contextLabel: String?
    let contextDetail: String?
}

struct DayRoutePlaybackStopMarker: Identifiable, @unchecked Sendable {
    let id: String
    let stopIndex: Int
    let coordinate: CLLocationCoordinate2D
    let symbolName: String
    let colorHex: String?
    let duration: TimeInterval

}

struct TimelinePlaybackSnapPoint: Identifiable, Sendable {
    let progress: Double
    let label: String
    var id: String { "\(label)-\(progress)" }
}

struct TimelinePlaybackTrackSegment: Identifiable, Sendable {
    let startProgress: Double
    let endProgress: Double
    let colorHex: String?

    var id: String { "\(startProgress)-\(endProgress)-\(colorHex ?? "accent")" }
}

struct DayRoutePlayback: @unchecked Sendable {
    /// Separates MapKit content identities when a date or trip snapshot is
    /// replaced. Reusing `route-0`/`stop-0` for new geometry can make
    /// VectorKit mutate an old overlay in place while it is still rendering.
    let renderIdentity: String
    let frames: [DayRoutePlaybackFrame]
    let routeGeometries: [TransportRouteProgressGeometry]
    let routeSegments: [TransportLineSegment]
    let mapRoutes: BrowseRouteBatch
    let stopMarkers: [DayRoutePlaybackStopMarker]
    let contextBreakpoints: [TimelinePlaybackSnapPoint]
    let trackSegments: [TimelinePlaybackTrackSegment]
    let frameInterval: TimeInterval
    let endPause: TimeInterval

    static let empty = DayRoutePlayback(
        renderIdentity: "empty",
        frames: [],
        routeGeometries: [],
        routeSegments: [],
        mapRoutes: .empty,
        stopMarkers: [],
        contextBreakpoints: [],
        trackSegments: [],
        frameInterval: 0,
        endPause: 0
    )

    nonisolated static func make(inputs: [DayRoutePlaybackInput]) -> DayRoutePlayback {
        let config = AppConfig.shared
        let renderIdentity = UUID().uuidString
        let frameInterval = 1.0 / max(config.mapRoutePlaybackFrameRate, 1)
        var frames: [DayRoutePlaybackFrame] = []
        var routes: [TransportRouteProgressGeometry] = []
        var routeSegments: [TransportLineSegment] = []
        var stopMarkers: [DayRoutePlaybackStopMarker] = []
        var stopCount = 0

        for input in inputs.sorted(by: { $0.startTime < $1.startTime }) {
            guard !Task.isCancelled else { return .empty }
            switch input.kind {
            case let .stop(coordinate, startTime, endTime, symbolName, colorHex):
                guard coordinate.isRenderableMapCoordinate,
                      let playbackStart = stopPlaybackStart(
                        startTime: startTime,
                        endTime: endTime,
                        playedUntil: frames.last?.timestamp,
                        config: config
                      ) else { continue }
                stopMarkers.append(DayRoutePlaybackStopMarker(
                    id: "\(renderIdentity)-stop-\(stopCount)",
                    stopIndex: stopCount,
                    coordinate: coordinate,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    duration: max(endTime.timeIntervalSince(startTime), 0)
                ))
                appendStopFrames(
                    coordinate: coordinate,
                    startTime: playbackStart,
                    endTime: endTime,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    routeCount: routes.count,
                    stopIndex: stopCount,
                    frameInterval: frameInterval,
                    config: config,
                    contextLabel: input.contextLabel,
                    contextDetail: input.contextDetail,
                    frames: &frames
                )
                stopCount += 1

            case let .footprint(latitudeData, longitudeData, startTime, endTime, symbolName, colorHex):
                let latitudes = (try? JSONDecoder().decode([Double].self, from: latitudeData)) ?? []
                let longitudes = (try? JSONDecoder().decode([Double].self, from: longitudeData)) ?? []
                guard !latitudes.isEmpty, latitudes.count == longitudes.count else { continue }
                let coordinate = CLLocationCoordinate2D(
                    latitude: latitudes.reduce(0, +) / Double(latitudes.count),
                    longitude: longitudes.reduce(0, +) / Double(longitudes.count)
                )
                guard coordinate.isRenderableMapCoordinate,
                      let playbackStart = stopPlaybackStart(
                        startTime: startTime,
                        endTime: endTime,
                        playedUntil: frames.last?.timestamp,
                        config: config
                      ) else { continue }
                stopMarkers.append(DayRoutePlaybackStopMarker(
                    id: "\(renderIdentity)-stop-\(stopCount)",
                    stopIndex: stopCount,
                    coordinate: coordinate,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    duration: max(endTime.timeIntervalSince(startTime), 0)
                ))
                appendStopFrames(
                    coordinate: coordinate,
                    startTime: playbackStart,
                    endTime: endTime,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    routeCount: routes.count,
                    stopIndex: stopCount,
                    frameInterval: frameInterval,
                    config: config,
                    contextLabel: input.contextLabel,
                    contextDetail: input.contextDetail,
                    frames: &frames
                )
                stopCount += 1

            case let .transport(transport):
                let routeIndex = routes.count
                let segments = TransportRouteProgressGeometry.renderableSegments(
                    TransportRouteCompletion.cachedSegments(for: transport),
                    idPrefix: "\(renderIdentity)-route-\(routeIndex)"
                )
                let routeGeometry = TransportRouteProgressGeometry(segments: segments)
                let coordinates = routeGeometry.coordinates
                guard coordinates.count >= 2 else { continue }
                let animation = TransportRouteAnimation.make(
                    segments: segments,
                    pathPoints: transport.pathPoints,
                    averageSpeed: transport.averageSpeed,
                    startTime: transport.startTime,
                    endTime: transport.endTime
                )
                guard !animation.frames.isEmpty else { continue }
                routes.append(routeGeometry)
                routeSegments.append(contentsOf: segments)
                // A transport overlapping the previous item resumes where that
                // item ended, so the playback clock never rewinds. Its route
                // geometry is still kept for drawing and completion.
                let playedUntil = frames.last?.timestamp
                for frame in animation.frames {
                    guard !Task.isCancelled else { return .empty }
                    if let playedUntil, frame.timestamp < playedUntil { continue }
                    frames.append(DayRoutePlaybackFrame(
                        coordinate: frame.coordinate,
                        timestamp: frame.timestamp,
                        symbolName: transport.currentType.sfSymbol,
                        activityColorHex: nil,
                        isStop: false,
                        stopIndex: nil,
                        travelsWest: frame.travelsWest,
                        activeRouteIndex: routeIndex,
                        activeRouteCoordinateIndex: min(
                            max(frame.routeCoordinateIndex, 0),
                            coordinates.count - 1
                        ),
                        completedRouteCount: routeIndex,
                        completedStopCount: stopCount,
                        contextLabel: input.contextLabel,
                        contextDetail: input.contextDetail
                    ))
                }
            }
        }

        guard !routes.isEmpty, frames.count >= 2 else { return .empty }
        var contextBreakpoints: [TimelinePlaybackSnapPoint] = []
        var previousContextLabel: String?
        for (index, frame) in frames.enumerated() {
            guard let label = frame.contextLabel, !label.isEmpty,
                  label != previousContextLabel else { continue }
            contextBreakpoints.append(TimelinePlaybackSnapPoint(
                progress: frames.count > 1 ? Double(index) / Double(frames.count - 1) : 0,
                label: label
            ))
            previousContextLabel = label
        }
        var trackSegments: [TimelinePlaybackTrackSegment] = []
        var trackSegmentStartIndex = 0
        var trackSegmentColorHex = frames[0].activityColorHex
        for index in 1..<frames.count where frames[index].activityColorHex != trackSegmentColorHex {
            trackSegments.append(TimelinePlaybackTrackSegment(
                startProgress: Double(trackSegmentStartIndex) / Double(frames.count - 1),
                endProgress: Double(index) / Double(frames.count - 1),
                colorHex: trackSegmentColorHex
            ))
            trackSegmentStartIndex = index
            trackSegmentColorHex = frames[index].activityColorHex
        }
        trackSegments.append(TimelinePlaybackTrackSegment(
            startProgress: Double(trackSegmentStartIndex) / Double(frames.count - 1),
            endProgress: 1,
            colorHex: trackSegmentColorHex
        ))
        return DayRoutePlayback(
            renderIdentity: renderIdentity,
            frames: frames,
            routeGeometries: routes,
            routeSegments: routeSegments,
            mapRoutes: BrowseRouteBatch(routeSegments, coordinates: \.coordinates, dashed: \.isDashed),
            stopMarkers: stopMarkers,
            contextBreakpoints: contextBreakpoints,
            trackSegments: trackSegments,
            frameInterval: frameInterval,
            endPause: max(config.transportRouteAnimationEndPause, 0)
        )
    }

    /// Recorded stops and transports can overlap in time. Frames are appended
    /// item by item, so an overlapping stop must not rewind the playback clock.
    /// Like `TimelineBuilder.resolveTimelineOverlaps`, the stop starts where the
    /// previous item ended and is dropped when only a tiny stay remains.
    nonisolated private static func stopPlaybackStart(
        startTime: Date,
        endTime: Date,
        playedUntil: Date?,
        config: AppConfig
    ) -> Date? {
        guard let playedUntil, playedUntil > startTime else { return startTime }
        guard endTime > playedUntil.addingTimeInterval(config.tinyStayThreshold) else { return nil }
        return playedUntil
    }

    nonisolated private static func appendStopFrames(
        coordinate: CLLocationCoordinate2D,
        startTime: Date,
        endTime: Date,
        symbolName: String,
        colorHex: String?,
        routeCount: Int,
        stopIndex: Int,
        frameInterval: TimeInterval,
        config: AppConfig,
        contextLabel: String?,
        contextDetail: String?,
        frames: inout [DayRoutePlaybackFrame]
    ) {
        let realDuration = max(endTime.timeIntervalSince(startTime), 0)
        let minimumPlaybackDuration = max(config.transportRouteAnimationEndPause, frameInterval)
        let maximumPlaybackDuration = max(config.transportRouteAnimationMinDuration, minimumPlaybackDuration)
        let stayDurationBaseline = max(config.stayDurationThreshold, 1)
        let durationRatio = realDuration / stayDurationBaseline
        let compressedPlaybackDuration = minimumPlaybackDuration * (1 + log1p(durationRatio))
        let stopPlaybackDuration = min(max(compressedPlaybackDuration, minimumPlaybackDuration), maximumPlaybackDuration)
        let stopFrameCount = max(1, Int((stopPlaybackDuration / frameInterval).rounded()))
        for index in 0..<stopFrameCount {
            guard !Task.isCancelled else { return }
            let fraction = stopFrameCount > 1 ? Double(index) / Double(stopFrameCount - 1) : 0
            frames.append(DayRoutePlaybackFrame(
                coordinate: coordinate,
                timestamp: startTime.addingTimeInterval(realDuration * fraction),
                symbolName: symbolName,
                activityColorHex: colorHex,
                isStop: true,
                stopIndex: stopIndex,
                travelsWest: false,
                activeRouteIndex: nil,
                activeRouteCoordinateIndex: 0,
                completedRouteCount: routeCount,
                completedStopCount: stopIndex,
                contextLabel: contextLabel,
                contextDetail: contextDetail
            ))
        }
    }

    nonisolated func highlightedSegments(at frameIndex: Int) -> [TransportLineSegment] {
        guard frames.indices.contains(frameIndex) else { return [] }
        let frame = frames[frameIndex]
        var segments: [TransportLineSegment] = []
        for routeIndex in 0..<min(frame.completedRouteCount, routeGeometries.count) {
            let geometry = routeGeometries[routeIndex]
            segments.append(contentsOf: geometry.highlightedSegments(
                through: geometry.coordinates.count - 1,
                endingAt: nil,
                idPrefix: "\(renderIdentity)-completed-\(routeIndex)"
            ))
        }
        if let routeIndex = frame.activeRouteIndex,
           routeGeometries.indices.contains(routeIndex) {
            let geometry = routeGeometries[routeIndex]
            let route = geometry.coordinates
            let endIndex = min(max(frame.activeRouteCoordinateIndex, 0), route.count - 1)
            segments.append(contentsOf: geometry.highlightedSegments(
                    through: endIndex,
                    endingAt: frame.coordinate,
                    idPrefix: "\(renderIdentity)-active-\(routeIndex)"
            ))
        }
        return segments
    }
}

enum TimelinePlaybackScrubPipeline {
    static func progress(frameIndex: Int, frameCount: Int) -> Double {
        guard frameCount > 1 else { return 0 }
        return Double(frameIndex) / Double(frameCount - 1)
    }

    static func seek(
        to progress: Double,
        frameCount: Int,
        task: inout Task<Void, Never>?,
        apply: @escaping @MainActor (Int) async -> Void
    ) {
        guard frameCount > 1 else { return }
        let boundedProgress = min(max(progress, 0), 1)
        let index = min(
            max(Int((boundedProgress * Double(frameCount - 1)).rounded()), 0),
            frameCount - 1
        )
        task?.cancel()
        task = Task { @MainActor in
            await apply(index)
        }
    }
}

/// Immediate truth for the physical slider gesture. Automatic playback uses
/// this same gate on every surface, instead of waiting for a page-specific
/// SwiftUI state update before it stops committing frames.
final class TimelinePlaybackScrubGate: ObservableObject {
    @Published private(set) var isActive = false

    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
    }
}

struct TimelinePlaybackResolvedFrame: @unchecked Sendable {
    let index: Int
    let frame: DayRoutePlaybackFrame
    let mapRoutes: BrowseRouteBatch
}

enum TimelinePlaybackFramePipeline {
    nonisolated static func resolve(
        playback: DayRoutePlayback,
        index: Int
    ) async -> TimelinePlaybackResolvedFrame? {
        guard playback.frames.indices.contains(index) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> TimelinePlaybackResolvedFrame? in
            guard !Task.isCancelled,
                  playback.frames.indices.contains(index) else { return nil }
            let segments = playback.highlightedSegments(at: index)
            return TimelinePlaybackResolvedFrame(
                index: index,
                frame: playback.frames[index],
                mapRoutes: BrowseRouteBatch(segments, coordinates: \.coordinates, dashed: \.isDashed)
            )
        }.value
    }
}

@MainActor
enum TimelinePlaybackAdvancePipeline {
    static func run(
        frameCount: @escaping @MainActor () -> Int,
        frameInterval: @escaping @MainActor () -> TimeInterval,
        endPause: @escaping @MainActor () -> TimeInterval,
        frameIndex: @escaping @MainActor () -> Int,
        canAdvance: @escaping @MainActor () -> Bool,
        resetLoopState: @escaping @MainActor () -> Void,
        applyFrame: @escaping @MainActor (Int) async -> Void
    ) async {
        guard canAdvance(), frameCount() >= 2 else { return }
        while !Task.isCancelled {
            let currentIndex = frameIndex()
            let currentFrameCount = frameCount()
            guard currentFrameCount >= 2 else { return }
            let isAtEnd = currentIndex == currentFrameCount - 1
            let delay = isAtEnd ? endPause() : frameInterval()
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, canAdvance() else { return }
            let latestFrameCount = frameCount()
            guard latestFrameCount >= 2 else { return }
            if isAtEnd { resetLoopState() }
            let nextIndex = isAtEnd ? 0 : min(currentIndex + 1, latestFrameCount - 1)
            await applyFrame(nextIndex)
        }
    }
}

@MainActor
enum TimelinePlaybackScrubLifecycle {
    static func update(
        isEditing: Bool,
        gate: TimelinePlaybackScrubGate,
        invalidateAutomaticAdvance: () -> Void,
        cancelCameraWork: () -> Void
    ) {
        gate.setActive(isEditing)
        if isEditing { invalidateAutomaticAdvance() }
        cancelCameraWork()
    }
}

enum TimelinePlaybackMotionPolicy {
    /// Reduce Motion prevents implicit autoplay, but never disables controls
    /// or overrides an explicit request to continue playback.
    static func startsPaused(reduceMotionEnabled: Bool) -> Bool {
        reduceMotionEnabled
    }
}

struct DayRoutePlaybackCameraLayout: Sendable {
    let viewport: CGSize
    let visibleRect: CGRect
}

/// Camera targets shared by the daily and trip playback surfaces. Geometry
/// preparation stays off the main thread; views only animate to the result.
enum DayRoutePlaybackCameraFraming {
    nonisolated static func transportRegion(
        coordinates: [CLLocationCoordinate2D],
        layout: DayRoutePlaybackCameraLayout,
        isFollowing: Bool
    ) -> MKCoordinateRegion? {
        guard let target = FootprintCameraFraming.mapRect(
            coordinates: coordinates,
            viewport: layout.viewport,
            visibleRect: layout.visibleRect
        ).map({ MKCoordinateRegion($0) }) else { return nil }
        let ratio = transportSpanRatio(isFollowing: isFollowing)
        var region = target
        region.span = MKCoordinateSpan(
            latitudeDelta: target.span.latitudeDelta * ratio,
            longitudeDelta: target.span.longitudeDelta * ratio
        )
        return isRenderable(region) ? region : nil
    }

    nonisolated static func stopRegion(
        coordinate: CLLocationCoordinate2D,
        layout: DayRoutePlaybackCameraLayout
    ) -> MKCoordinateRegion? {
        guard let target = FootprintCameraFraming.mapRect(
            coordinates: [coordinate],
            viewport: layout.viewport,
            visibleRect: layout.visibleRect
        ).map({ MKCoordinateRegion($0) }) else { return nil }
        let ratio = AppConfig.shared.dayRoutePlaybackStopCameraSpanRatio
        var region = target
        region.span = MKCoordinateSpan(
            latitudeDelta: target.span.latitudeDelta * ratio,
            longitudeDelta: target.span.longitudeDelta * ratio
        )
        return isRenderable(region) ? region : nil
    }

    /// Map-space variants of the same framing for renderers that draw the map
    /// themselves (route video export). The rect covers the whole viewport and
    /// keeps the framed content centered in `layout.visibleRect`.
    nonisolated static func transportMapRect(
        coordinates: [CLLocationCoordinate2D],
        layout: DayRoutePlaybackCameraLayout,
        isFollowing: Bool
    ) -> MKMapRect? {
        guard let target = FootprintCameraFraming.mapRect(
            coordinates: coordinates,
            viewport: layout.viewport,
            visibleRect: layout.visibleRect
        ) else { return nil }
        return scaled(target, by: transportSpanRatio(isFollowing: isFollowing))
    }

    nonisolated static func stopMapRect(
        coordinate: CLLocationCoordinate2D,
        layout: DayRoutePlaybackCameraLayout
    ) -> MKMapRect? {
        guard let target = FootprintCameraFraming.mapRect(
            coordinates: [coordinate],
            viewport: layout.viewport,
            visibleRect: layout.visibleRect
        ) else { return nil }
        return scaled(target, by: AppConfig.shared.dayRoutePlaybackStopCameraSpanRatio)
    }

    private nonisolated static func transportSpanRatio(isFollowing: Bool) -> Double {
        isFollowing ? AppConfig.shared.dayRoutePlaybackTransportCameraSpanRatio : 1
    }

    private nonisolated static func scaled(_ rect: MKMapRect, by ratio: Double) -> MKMapRect? {
        guard ratio.isFinite, ratio > 0, !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let width = rect.width * ratio
        let height = rect.height * ratio
        return MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    nonisolated static func isRenderable(_ region: MKCoordinateRegion) -> Bool {
        guard region.center.isRenderableMapCoordinate else { return false }
        guard region.span.latitudeDelta.isFinite,
              region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0,
              region.span.longitudeDelta > 0 else { return false }
        return region.span.latitudeDelta <= 180 && region.span.longitudeDelta <= 360
    }
}

enum RouteMapNativeGestureKind: Hashable {
    case pan
    case zoom
    case rotate
}

/// Observes the gesture recognizers already owned by the SwiftUI map's
/// underlying MKMapView. Adding targets does not participate in recognition,
/// so native pan/zoom/rotation keep their original precedence and behavior.
struct RouteMapNativeGestureObserver: UIViewRepresentable {
    let onInteractionChanged: (RouteMapNativeGestureKind, Bool) -> Void
    let onTouchChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInteractionChanged: onInteractionChanged,
            onTouchChanged: onTouchChanged
        )
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onInteractionChanged = onInteractionChanged
        context.coordinator.onTouchChanged = onTouchChanged
        context.coordinator.installIfNeeded(from: view)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.installIfNeeded(from: self)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.installIfNeeded(from: self)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.installIfNeeded(from: self)
        }
    }

    final class Coordinator: NSObject {
        var onInteractionChanged: (RouteMapNativeGestureKind, Bool) -> Void
        var onTouchChanged: (Bool) -> Void
        private weak var installedMapView: MKMapView?
        private var installedRecognizers: [UIGestureRecognizer] = []
        private var activeRecognizerKinds: [ObjectIdentifier: RouteMapNativeGestureKind] = [:]
        private var touchObserver: TouchObserverGestureRecognizer?

        init(
            onInteractionChanged: @escaping (RouteMapNativeGestureKind, Bool) -> Void,
            onTouchChanged: @escaping (Bool) -> Void
        ) {
            self.onInteractionChanged = onInteractionChanged
            self.onTouchChanged = onTouchChanged
        }

        func installIfNeeded(from probe: UIView) {
            guard installedMapView == nil else { return }
            guard let mapView = Self.nearestMapView(to: probe) else { return }
            uninstall()
            installedMapView = mapView
            let touchObserver = TouchObserverGestureRecognizer { [weak self] isTouching in
                self?.onTouchChanged(isTouching)
            }
            touchObserver.cancelsTouchesInView = false
            touchObserver.delaysTouchesBegan = false
            touchObserver.delaysTouchesEnded = false
            mapView.addGestureRecognizer(touchObserver)
            self.touchObserver = touchObserver
            let recognizers = Self.mapGestureRecognizers(in: mapView)
            for recognizer in recognizers where
                recognizer is UIPinchGestureRecognizer ||
                recognizer is UIRotationGestureRecognizer ||
                recognizer is UIPanGestureRecognizer {
                recognizer.addTarget(self, action: #selector(handleMapGesture(_:)))
                installedRecognizers.append(recognizer)
            }
        }

        func uninstall() {
            if let touchObserver {
                touchObserver.view?.removeGestureRecognizer(touchObserver)
            }
            touchObserver = nil
            for recognizer in installedRecognizers {
                recognizer.removeTarget(self, action: #selector(handleMapGesture(_:)))
            }
            installedRecognizers.removeAll()
            activeRecognizerKinds.removeAll()
            installedMapView = nil
        }

        final class TouchObserverGestureRecognizer: UIGestureRecognizer {
            private var activeTouches: Set<ObjectIdentifier> = []
            private let onTouchChanged: (Bool) -> Void

            init(onTouchChanged: @escaping (Bool) -> Void) {
                self.onTouchChanged = onTouchChanged
                super.init(target: nil, action: nil)
            }

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                let wasEmpty = activeTouches.isEmpty
                activeTouches.formUnion(touches.map { ObjectIdentifier($0) })
                if wasEmpty, !activeTouches.isEmpty {
                    onTouchChanged(true)
                }
            }

            override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
                finish(touches)
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
                finish(touches)
            }

            override func reset() {
                if !activeTouches.isEmpty {
                    activeTouches.removeAll()
                    onTouchChanged(false)
                }
                super.reset()
            }

            override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
                false
            }

            override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
                false
            }

            private func finish(_ touches: Set<UITouch>) {
                activeTouches.subtract(touches.map { ObjectIdentifier($0) })
                if activeTouches.isEmpty {
                    onTouchChanged(false)
                    state = .failed
                }
            }
        }

        @objc private func handleMapGesture(_ recognizer: UIGestureRecognizer) {
            let kind: RouteMapNativeGestureKind
            if recognizer is UIPinchGestureRecognizer {
                kind = .zoom
            } else if recognizer is UIRotationGestureRecognizer {
                kind = .rotate
            } else {
                kind = .pan
            }
            switch recognizer.state {
            case .began:
                activeRecognizerKinds[ObjectIdentifier(recognizer)] = kind
                onInteractionChanged(kind, true)
            case .changed:
                let identifier = ObjectIdentifier(recognizer)
                if activeRecognizerKinds[identifier] == nil {
                    activeRecognizerKinds[identifier] = kind
                    onInteractionChanged(kind, true)
                }
            case .ended, .cancelled, .failed:
                activeRecognizerKinds.removeValue(forKey: ObjectIdentifier(recognizer))
                let remainsActive = activeRecognizerKinds.values.contains(kind)
                onInteractionChanged(kind, remainsActive)
            default:
                break
            }
        }

        static func nearestMapView(to probe: UIView) -> MKMapView? {
            var ancestor = probe.superview
            while let container = ancestor {
                let maps = mapViews(in: container)
                if !maps.isEmpty {
                    guard let window = probe.window else { return maps.first }
                    let probeFrame = probe.convert(probe.bounds, to: window)
                    return maps.max { lhs, rhs in
                        let lhsFrame = lhs.convert(lhs.bounds, to: window)
                        let rhsFrame = rhs.convert(rhs.bounds, to: window)
                        let lhsArea = lhsFrame.intersection(probeFrame).area
                        let rhsArea = rhsFrame.intersection(probeFrame).area
                        return lhsArea < rhsArea
                    }
                }
                ancestor = container.superview
            }
            return nil
        }

        private static func mapViews(in view: UIView) -> [MKMapView] {
            var result: [MKMapView] = []
            if let mapView = view as? MKMapView {
                result.append(mapView)
            }
            for subview in view.subviews {
                result.append(contentsOf: mapViews(in: subview))
            }
            return result
        }

        private static func mapGestureRecognizers(in view: UIView) -> [UIGestureRecognizer] {
            var result = view.gestureRecognizers ?? []
            for subview in view.subviews {
                result.append(contentsOf: mapGestureRecognizers(in: subview))
            }
            return result
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(width, 0) * max(height, 0)
    }
}

// MARK: - Shared Playback Controls

private struct TimelineTrackingSlider: UIViewRepresentable {
    @Binding var value: Double
    let axis: Axis
    let trackTint: Color
    let usesSegmentedTrack: Bool
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SliderContainer {
        let container = SliderContainer(axis: axis)
        let slider = container.slider
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = Float(value)
        updateTrackColors(slider)
        // The physical finger is the only scrub truth. Newer UISlider
        // implementations drive dragging without UIControl tracking
        // (`beginTracking` / `isTracking`), so reuse the shared non-blocking
        // touch observer instead of depending on control tracking callbacks.
        let touchObserver = RouteMapNativeGestureObserver.Coordinator.TouchObserverGestureRecognizer { [weak coordinator = context.coordinator] isTouching in
            if isTouching {
                coordinator?.beginEditing()
            } else {
                coordinator?.endEditingIfNeeded()
            }
        }
        touchObserver.cancelsTouchesInView = false
        touchObserver.delaysTouchesBegan = false
        touchObserver.delaysTouchesEnded = false
        slider.addGestureRecognizer(touchObserver)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return container
    }

    func updateUIView(_ container: SliderContainer, context: Context) {
        context.coordinator.parent = self
        container.axis = axis
        let slider = container.slider
        updateTrackColors(slider)
        guard !slider.isTracking, !context.coordinator.isEditing else { return }
        let updatedValue = Float(value)
        if slider.value != updatedValue {
            slider.setValue(updatedValue, animated: false)
        }
    }

    static func dismantleUIView(_ container: SliderContainer, coordinator: Coordinator) {
        coordinator.endEditingIfNeeded()
    }

    private func updateTrackColors(_ slider: UISlider) {
        if usesSegmentedTrack {
            slider.minimumTrackTintColor = .clear
            slider.maximumTrackTintColor = .clear
        } else {
            slider.minimumTrackTintColor = UIColor(trackTint)
            slider.maximumTrackTintColor = UIColor(trackTint)
        }
    }

    final class SliderContainer: UIView {
        let slider: UISlider
        var axis: Axis {
            didSet {
                guard axis != oldValue else { return }
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        init(axis: Axis) {
            self.axis = axis
            self.slider = UISlider(frame: .zero)
            super.init(frame: .zero)
            addSubview(slider)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: CGSize {
            axis == .vertical
                ? CGSize(width: 32, height: 140)
                : CGSize(width: UIView.noIntrinsicMetric, height: 32)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            slider.transform = .identity
            if axis == .vertical {
                slider.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
                slider.center = CGPoint(x: bounds.midX, y: bounds.midY)
                slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
            } else {
                slider.frame = bounds
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: TimelineTrackingSlider
        private(set) var isEditing = false

        init(parent: TimelineTrackingSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ slider: UISlider) {
            // Touch scrubs are already open here: gesture recognizers receive
            // the touch before the slider does. A change without a touch
            // (e.g. VoiceOver adjustment) is a discrete seek, so wrap it in its
            // own begin/end instead of leaving playback stuck paused.
            if isEditing {
                parent.value = Double(slider.value)
            } else {
                beginEditing()
                parent.value = Double(slider.value)
                endEditingIfNeeded()
            }
        }

        func beginEditing() {
            guard !isEditing else { return }
            isEditing = true
            parent.onEditingChanged(true)
        }

        func endEditingIfNeeded() {
            guard isEditing else { return }
            isEditing = false
            parent.onEditingChanged(false)
        }
    }
}

struct TimelinePlaybackScrubber: View {
    @Binding var progress: Double
    @Binding var isPaused: Bool
    @Binding var isScrubbing: Bool
    var axis: Axis = .horizontal
    var floatingLabel: String? = nil
    var trackTint: Color = .dfkAccent
    var trackSegments: [TimelinePlaybackTrackSegment] = []
    let progressAccessibilityLabel: String
    let resumeAccessibilityLabel: String
    let pauseAccessibilityLabel: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var pausedBeforeScrubbing: Bool?

    private func beginScrubbing() {
        // TimelineTrackingSlider.Coordinator already emits begin exactly once
        // for each physical gesture. Never reject that event based on stale
        // SwiftUI state: map-driven view refreshes may preserve an unfinished
        // snapshot after the UIKit slider has already ended or been rebuilt.
        let wasPaused = isPaused
        // Give the playback owner a synchronous cancellation point before
        // publishing any value from this drag.
        onEditingChanged(true)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pausedBeforeScrubbing = wasPaused
            isPaused = true
            isScrubbing = true
        }
    }

    private func finishScrubbing() {
        // `isScrubbing` is presentation state and can be reset by a scene or
        // layout update.  The captured pause state is the authoritative proof
        // that this drag still needs to be finished.
        guard isScrubbing || pausedBeforeScrubbing != nil else { return }
        let shouldRemainPaused = pausedBeforeScrubbing ?? isPaused
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isScrubbing = false
            isPaused = shouldRemainPaused
            pausedBeforeScrubbing = nil
        }
        onEditingChanged(false)
    }

    private func sliderPosition(progress: Double, size: CGSize) -> CGPoint {
        let inset: CGFloat = 14
        let boundedProgress = min(max(progress, 0), 1)
        if axis == .vertical {
            return CGPoint(
                x: size.width / 2,
                y: inset + (1 - boundedProgress) * max(size.height - inset * 2, 1)
            )
        }
        return CGPoint(
            x: inset + boundedProgress * max(size.width - inset * 2, 1),
            y: size.height / 2
        )
    }

    private func trackColor(for segment: TimelinePlaybackTrackSegment) -> Color {
        segment.colorHex.flatMap { Color(hex: $0) } ?? trackTint
    }

    @ViewBuilder
    private func segmentedTrack(size: CGSize) -> some View {
        let inset: CGFloat = 14
        let thickness: CGFloat = 4
        ZStack(alignment: .topLeading) {
            ForEach(trackSegments) { segment in
                let start = min(max(segment.startProgress, 0), 1)
                let end = min(max(segment.endProgress, start), 1)
                let color = trackColor(for: segment)
                if axis == .vertical {
                    let usableLength = max(size.height - inset * 2, 1)
                    let top = inset + (1 - end) * usableLength
                    let bottom = inset + (1 - start) * usableLength
                    Rectangle()
                        .fill(color)
                        .frame(width: thickness, height: max(bottom - top, 0))
                        .position(x: size.width / 2, y: (top + bottom) / 2)
                } else {
                    let usableLength = max(size.width - inset * 2, 1)
                    let leading = inset + start * usableLength
                    let trailing = inset + end * usableLength
                    Rectangle()
                        .fill(color)
                        .frame(width: max(trailing - leading, 0), height: thickness)
                        .position(x: (leading + trailing) / 2, y: size.height / 2)
                }
            }
        }
        .mask {
            if axis == .vertical {
                Capsule()
                    .frame(width: thickness, height: max(size.height - inset * 2, 1))
                    .position(x: size.width / 2, y: size.height / 2)
            } else {
                Capsule()
                    .frame(width: max(size.width - inset * 2, 1), height: thickness)
                    .position(x: size.width / 2, y: size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private var progressSlider: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !trackSegments.isEmpty {
                    segmentedTrack(size: geometry.size)
                }

                TimelineTrackingSlider(
                    value: $progress,
                    axis: axis,
                    trackTint: trackTint,
                    usesSegmentedTrack: !trackSegments.isEmpty,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            beginScrubbing()
                        } else {
                            finishScrubbing()
                        }
                    }
                )
                .accessibilityLabel(progressAccessibilityLabel)

                if let floatingLabel, !floatingLabel.isEmpty {
                    let thumbPosition = sliderPosition(progress: progress, size: geometry.size)
                    Text(floatingLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .dfkDetailMaterial(in: Capsule())
                        .fixedSize()
                        .position(
                            x: axis == .vertical
                                ? thumbPosition.x - 38
                                : min(max(thumbPosition.x, 30), max(geometry.size.width - 30, 30)),
                            y: axis == .vertical
                                ? min(max(thumbPosition.y, 14), max(geometry.size.height - 14, 14))
                                : thumbPosition.y - 36
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var pauseButton: some View {
        Button {
            isPaused.toggle()
        } label: {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.dfkAccent)
        .accessibilityLabel(isPaused ? resumeAccessibilityLabel : pauseAccessibilityLabel)
    }

    @ViewBuilder
    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 12) {
                    progressSlider
                        .frame(width: 32, height: 140)
                    pauseButton
                }
            } else {
                HStack(spacing: 12) {
                    progressSlider
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    pauseButton
                }
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            finishScrubbing()
        }
    }
}

// MARK: - TransportModalView
struct TransportModalView: View {
    let transport: Transport
    var onUpdate: ((TransportType) -> Void)? = nil
    var onLocationUpdate: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var position: MapCameraPosition = .automatic
    @State private var localManualType: TransportType? = nil
    
    @Environment(LocationManager.self) private var locationManager
    @State private var showingSearchSheet: LocationType? = nil
    @State private var localStartOverride: String? = nil
    @State private var localEndOverride: String? = nil
    @State private var interactiveMapReady = false
    @State private var showingTimeAdjustment = false
    @State private var localStartTime: Date? = nil
    @State private var localEndTime: Date? = nil
    @State private var refreshedTransport: Transport? = nil
    @State private var displayedRouteSegments: [TransportLineSegment] = []
    @State private var routeAnimation = TransportRouteAnimation.empty
    @State private var routeAnimationFrameIndex = 0
    @State private var routeAnimationRevision = 0
    @State private var isRouteAnimationPaused = false
    @State private var routeAnimationWasPlayingBeforeVideoExport = false
    @State private var isRouteAnimationScrubbing = false
    @State private var routeAnimationWasPlayingBeforeMapTouch = false
    @AppStorage("transportRouteAnimationFollowEnabled") private var followsRouteAnimation = false
    @State private var routeCameraViewParameters: RouteCameraViewParameters?
    @State private var isDraggingRouteMap = false
    @State private var isZoomingRouteMap = false
    @State private var isRotatingRouteMap = false
    @State private var isTouchingRouteMap = false
    @State private var routeMapNeedsRecenterAfterInteraction = false
    @State private var isRouteMapRecentering = false
    @State private var editableRouteGaps: [TransportRouteCompletion.Gap] = []
    @State private var routeTapTargets: [RouteTapTarget] = []
    @State private var inferredRoutesRevision = TransportRouteCompletion.revision
    @State private var showingRouteCorrection = false
    @State private var selectedRouteGapIndex = 0
    @State private var visibleRouteRegion: MKCoordinateRegion?

    private struct RouteTapTarget: @unchecked Sendable {
        let gapIndex: Int
        let coordinates: [CLLocationCoordinate2D]
    }

    private struct RouteCameraViewParameters {
        let distance: CLLocationDistance
        let heading: CLLocationDirection
        let pitch: CGFloat

        func distanceMeaningfullyDiffers(from other: RouteCameraViewParameters) -> Bool {
            abs(distance - other.distance) > 0.5
        }

        func orientationMeaningfullyDiffers(from other: RouteCameraViewParameters) -> Bool {
            let rawHeadingDifference = abs(heading - other.heading)
                .truncatingRemainder(dividingBy: 360)
            let headingDifference = min(rawHeadingDifference, 360 - rawHeadingDifference)
            return headingDifference > 0.01 ||
                abs(pitch - other.pitch) > 0.01
        }

        func meaningfullyDiffers(from other: RouteCameraViewParameters) -> Bool {
            distanceMeaningfullyDiffers(from: other) ||
                orientationMeaningfullyDiffers(from: other)
        }
    }

    private struct RouteDisplayKey: Hashable {
        let geometry: ObjectIdentifier
        let type: TransportType
        let revision: Double
    }

    private var displayedTransport: Transport { refreshedTransport ?? transport }
    
    enum LocationType: Identifiable {
        case start, end
        var id: Int { self == .start ? 0 : 1 }
    }
    
    private var currentStartTime: Date { localStartTime ?? displayedTransport.startTime }
    private var currentEndTime: Date { localEndTime ?? displayedTransport.endTime }

    private static func isValidTransportPoint(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite &&
            coordinate.longitude.isFinite &&
            CLLocationCoordinate2DIsValid(coordinate)
    }

    /// First/last valid route points without filtering the whole route.
    private var validStartPoint: CLLocationCoordinate2D? {
        displayedTransport.points.first(where: { Self.isValidTransportPoint($0) })
    }

    private var validEndPoint: CLLocationCoordinate2D? {
        displayedTransport.points.last(where: { Self.isValidTransportPoint($0) })
    }

    // Use the effective type for display
    private var displayType: TransportType {
        localManualType ?? displayedTransport.currentType
    }

    private var currentRouteAnimationFrame: TransportRouteAnimationFrame? {
        guard routeAnimation.frames.indices.contains(routeAnimationFrameIndex) else { return nil }
        return routeAnimation.frames[routeAnimationFrameIndex]
    }

    private var routeAnimationProgress: Binding<Double> {
        Binding(
            get: {
                guard routeAnimation.frames.count >= 2 else { return 0 }
                return Double(routeAnimationFrameIndex) / Double(routeAnimation.frames.count - 1)
            },
            set: { progress in
                guard routeAnimation.frames.count >= 2 else { return }
                let bounded = min(max(progress, 0), 1)
                let frameIndex = Int(
                    (bounded * Double(routeAnimation.frames.count - 1)).rounded()
                )
                setRouteAnimationFrame(frameIndex)
            }
        )
    }

    /// Keep the moving annotation and a following camera in the same render
    /// transaction. Updating them separately lets Map briefly render the new
    /// annotation against the previous camera center, which looks like jitter.
    private func setRouteAnimationFrame(_ frameIndex: Int) {
        guard routeAnimation.frames.indices.contains(frameIndex) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            routeAnimationFrameIndex = frameIndex
            centerCameraOnAnimationFrame(at: frameIndex)
        }
    }

    private func centerCameraOnAnimationFrame(at frameIndex: Int? = nil) {
        guard followsRouteAnimation,
              !isManipulatingRouteMap,
              !routeMapNeedsRecenterAfterInteraction else { return }
        let index = frameIndex ?? routeAnimationFrameIndex
        guard routeAnimation.frames.indices.contains(index) else { return }
        let coordinate = routeAnimation.frames[index].coordinate
        if let camera = routeCameraViewParameters {
            position = .camera(MapCamera(
                centerCoordinate: coordinate,
                distance: camera.distance,
                heading: camera.heading,
                pitch: camera.pitch
            ))
        } else if var region = visibleRouteRegion {
            region.center = coordinate
            position = .region(region)
        }
    }

    private var isManipulatingRouteMap: Bool {
        isTouchingRouteMap || isDraggingRouteMap || isZoomingRouteMap || isRotatingRouteMap
    }

    private func routeMapTouchChanged(isTouching: Bool) {
        guard followsRouteAnimation else { return }
        if isTouching, !isTouchingRouteMap {
            routeAnimationWasPlayingBeforeMapTouch = routeAnimationWasPlayingBeforeMapTouch || !isRouteAnimationPaused
            if routeAnimationWasPlayingBeforeMapTouch {
                isRouteAnimationPaused = true
            }
        }
        isTouchingRouteMap = isTouching
        if isTouching {
            isRouteMapRecentering = false
            routeMapNeedsRecenterAfterInteraction = true
        } else {
            finishRouteMapInteraction()
        }
    }

    private func routeMapNativeInteractionChanged(
        _ kind: RouteMapNativeGestureKind,
        isActive: Bool
    ) {
        guard followsRouteAnimation else { return }
        switch kind {
        case .pan:
            isDraggingRouteMap = isActive
        case .zoom:
            isZoomingRouteMap = isActive
        case .rotate:
            isRotatingRouteMap = isActive
        }
        if isActive {
            isRouteMapRecentering = false
            routeMapNeedsRecenterAfterInteraction = true
        } else {
            finishRouteMapInteraction()
        }
    }

    private func finishRouteMapInteraction() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard routeAnimationWasPlayingBeforeMapTouch,
                  routeMapNeedsRecenterAfterInteraction,
                  !isManipulatingRouteMap,
                  !isRouteMapRecentering else { return }
            isRouteMapRecentering = true
            recenterRouteMapAfterInteraction()
        }
    }

    private func recenterRouteMapAfterInteraction() {
        guard routeAnimation.frames.indices.contains(routeAnimationFrameIndex) else {
            completeRouteMapRecenter()
            return
        }
        let coordinate = routeAnimation.frames[routeAnimationFrameIndex].coordinate
        if let center = visibleRouteRegion?.center,
           isRouteMapCenter(center, at: coordinate) {
            completeRouteMapRecenter()
            return
        }
        withAnimation(accessibilityReduceMotion ? .linear : .easeInOut) {
            if let camera = routeCameraViewParameters {
                position = .camera(MapCamera(
                    centerCoordinate: coordinate,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                ))
            } else if var region = visibleRouteRegion {
                region.center = coordinate
                position = .region(region)
            } else {
                completeRouteMapRecenter()
            }
        }
    }

    private func completeRouteMapRecenterIfNeeded(at center: CLLocationCoordinate2D) {
        guard isRouteMapRecentering,
              routeAnimation.frames.indices.contains(routeAnimationFrameIndex),
              isRouteMapCenter(center, at: routeAnimation.frames[routeAnimationFrameIndex].coordinate) else {
            return
        }
        completeRouteMapRecenter()
    }

    private func completeRouteMapRecenter() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isRouteMapRecentering = false
            routeMapNeedsRecenterAfterInteraction = false
            if routeAnimationWasPlayingBeforeMapTouch {
                isRouteAnimationPaused = false
            }
            routeAnimationWasPlayingBeforeMapTouch = false
        }
    }

    private func isRouteMapCenter(
        _ center: CLLocationCoordinate2D,
        at target: CLLocationCoordinate2D
    ) -> Bool {
        CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) < 0.5
    }

    /// Reconstructed sparse routes can know their endpoints and distance
    /// without knowing the real departure time. Never render the resulting
    /// physically impossible quotient as if it were a measured average.
    private var displayAverageSpeedKmh: Double? {
        let speed = Measurement(
            value: displayedTransport.averageSpeed,
            unit: UnitSpeed.metersPerSecond
        ).converted(to: .kilometersPerHour).value
        guard speed.isFinite, speed > 0 else { return nil }
        if let range = displayType.automaticSpeedRange, speed > range.upperBound {
            return nil
        }
        return speed
    }

    private func animatedTransportIcon(travelsWest: Bool, timeText: String) -> some View {
        let tint = BrowseMapSettings.shared.value.color()
        return ZStack(alignment: .top) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(tint, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                Image(systemName: displayType.sfSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .scaleEffect(x: travelsWest ? -1 : 1, y: 1)
            }

            Text(timeText)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(tint, lineWidth: 0.5)
                )
                .offset(y: 25)
        }
        .frame(width: 48, height: 42, alignment: .top)
        .offset(y: 6)
        .accessibilityHidden(true)
    }

    private func routeEndpointIcon(color: Color, systemImage: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            .mapAnnotationLayer(MapAnnotationLayer.routeEndpoint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var routeAnimationControls: some View {
        if routeAnimation.frames.count >= 2 {
            HStack(spacing: 12) {
                Button {
                    followsRouteAnimation.toggle()
                } label: {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(followsRouteAnimation ? Color.white : Color.dfkAccent)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(
                                followsRouteAnimation
                                    ? Color.dfkAccent
                                    : Color.secondary.opacity(0.12)
                            )
                        )
                        .overlay(
                            Circle().stroke(Color.dfkAccent.opacity(followsRouteAnimation ? 0 : 0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(followsRouteAnimation ? "关闭镜头跟随" : "开启镜头跟随")
                .accessibilityValue(followsRouteAnimation ? "已开启" : "已关闭")

                TimelinePlaybackScrubber(
                    progress: routeAnimationProgress,
                    isPaused: $isRouteAnimationPaused,
                    isScrubbing: $isRouteAnimationScrubbing,
                    progressAccessibilityLabel: "路线动画进度",
                    resumeAccessibilityLabel: "继续路线动画",
                    pauseAccessibilityLabel: "暂停路线动画"
                )

                RouteVideoExportButton(
                    source: .transport(
                        routeAnimation,
                        segments: displayedRouteSegments,
                        symbolName: displayType.sfSymbol,
                        followsPlayback: followsRouteAnimation
                    ),
                    accessibilityLabel: "导出路线视频",
                    onPresentationChanged: { isPresented in
                        if isPresented {
                            routeAnimationWasPlayingBeforeVideoExport = !isRouteAnimationPaused
                            isRouteAnimationPaused = true
                        } else if routeAnimationWasPlayingBeforeVideoExport {
                            routeAnimationWasPlayingBeforeVideoExport = false
                            isRouteAnimationPaused = false
                        }
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .dfkDetailMaterial(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(.horizontal, 24)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // 1. Map View
                GeometryReader { geometry in
                    if geometry.size.width > 1 && geometry.size.height > 1 && interactiveMapReady {
                        MapReader { proxy in
                            Map(position: $position) {
                            // Important Places Circles (isUserDefined)
                            ForEach(allPlaces.filter {
                                $0.isUserDefined &&
                                $0.radius.isFinite &&
                                $0.radius > 1 &&
                                $0.coordinate.latitude.isFinite &&
                                $0.coordinate.longitude.isFinite &&
                                CLLocationCoordinate2DIsValid($0.coordinate)
                            }) { place in
                                MapCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
                                    .foregroundStyle(Color(uiColor: UIColor.orange.withAlphaComponent(0.1)))
                                    .stroke(Color(uiColor: UIColor.orange.withAlphaComponent(0.3)), lineWidth: 1)
                            }

                            // Start Marker (Physical Look & Title)
                            if let start = validStartPoint {
                                Annotation("", coordinate: start) {
                                    routeEndpointIcon(color: .green, systemImage: "play.fill")
                                }
                            }
                            
                            // End Marker (Physical Look & Title)
                            if let end = validEndPoint {
                                Annotation("", coordinate: end) {
                                    routeEndpointIcon(color: .blue, systemImage: "stop.fill")
                                }
                            }
                            
                            ForEach(displayedRouteSegments) { segment in
                                MapPolyline(coordinates: segment.coordinates)
                                    .browseStroke(
                                        playbackOpacity: BrowseMapPreferences.untraveledOpacity(dashed: segment.isDashed),
                                        style: StrokeStyle(
                                            lineWidth: segment.isDashed ? 1.5 : 3,
                                            lineCap: .round,
                                            lineJoin: .round,
                                            dash: segment.isDashed ? [5, 5] : []
                                        )
                                    )
                            }

                            if let frame = currentRouteAnimationFrame {
                                ForEach(frame.highlightedSegments) { segment in
                                    MapPolyline(coordinates: segment.coordinates)
                                        .browseStroke(
                                            Color.dfkAccent,
                                            style: StrokeStyle(
                                                lineWidth: segment.isDashed ? 1.5 : 4,
                                                lineCap: .round,
                                                lineJoin: .round,
                                                dash: segment.isDashed ? [5, 5] : []
                                            )
                                        )
                                }
                            }

                            if let frame = currentRouteAnimationFrame {
                                Annotation("", coordinate: frame.coordinate) {
                                    animatedTransportIcon(
                                        travelsWest: frame.travelsWest,
                                        timeText: frame.timeText
                                    )
                                    .mapAnnotationLayer(MapAnnotationLayer.animatedTransport)
                                }
                            }
                            
                            }
                            .browseMapStyle(elevation: .automatic, pointsOfInterest: .excludingAll)
                            .background {
                                RouteMapNativeGestureObserver(
                                    onInteractionChanged: { kind, isActive in
                                        routeMapNativeInteractionChanged(kind, isActive: isActive)
                                    },
                                    onTouchChanged: { isTouching in
                                        routeMapTouchChanged(isTouching: isTouching)
                                    }
                                )
                            }
                            .mapControls {
                                MapUserLocationButton()
                                MapCompass()
                                MapScaleView()
                            }
                            .onMapCameraChange(frequency: .continuous) { context in
                                // Outside follow mode, keep the latest camera ready
                                // for a later follow request. During a follow-mode
                                // gesture, continuously retain the user's new zoom,
                                // heading and pitch so recentering changes only the
                                // target coordinate instead of restoring stale camera
                                // parameters when the gesture ends.
                                let parameters = RouteCameraViewParameters(
                                    distance: context.camera.distance,
                                    heading: context.camera.heading,
                                    pitch: context.camera.pitch
                                )
                                if routeCameraViewParameters?.meaningfullyDiffers(from: parameters) != false {
                                    routeCameraViewParameters = parameters
                                }
                                if !followsRouteAnimation || routeMapNeedsRecenterAfterInteraction {
                                    visibleRouteRegion = context.region
                                }
                                completeRouteMapRecenterIfNeeded(at: context.camera.centerCoordinate)
                            }
                            .onMapCameraChange(frequency: .onEnd) { context in
                                let parameters = RouteCameraViewParameters(
                                    distance: context.camera.distance,
                                    heading: context.camera.heading,
                                    pitch: context.camera.pitch
                                )
                                routeCameraViewParameters = parameters
                                if !followsRouteAnimation || routeMapNeedsRecenterAfterInteraction {
                                    visibleRouteRegion = context.region
                                }
                                completeRouteMapRecenterIfNeeded(at: context.camera.centerCoordinate)
                            }
                            .simultaneousGesture(
                                SpatialTapGesture(coordinateSpace: .local)
                                    .onEnded { value in
                                        guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                                        openRouteCorrectionIfNeeded(
                                            at: coordinate,
                                            mapSize: geometry.size
                                        )
                                    }
                            )
                        }
                    } else {
                        Color.clear
                    }
                }
            }
            .navigationTitle("交通详情")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Bottom Info Summary
                VStack(spacing: 10) {
                    routeAnimationControls

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    showingTimeAdjustment = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(currentStartTime.formatted(.dateTime.hour().minute()) + " - " + currentEndTime.formatted(.dateTime.hour().minute()))
                                            .font(.headline)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Image(systemName: "pencil")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.42))
                                    }
                                }
                                .buttonStyle(.plain)
                                
                                // 交通工具选择器
                                Menu {
                                    ForEach(TransportType.allCases, id: \.self) { type in
                                        Button {
                                            saveChoice(type)
                                        } label: {
                                            Label(type.localizedName, systemImage: type.sfSymbol)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: displayType.sfSymbol)
                                            .foregroundColor(Color.dfkAccent)
                                        Text(displayType.localizedName)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(Color.primary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.primary.opacity(0.5))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                }
                                .tint(.primary)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(distanceString)
                                        .foregroundColor(Color.dfkAccent)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.55)
                                        .allowsTightening(true)
                                    Text(durationString)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.55)
                                        .allowsTightening(true)
                                }
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                                Group {
                                    if let speed = displayAverageSpeedKmh {
                                        Text(String(format: "%.1f 千米/小时", speed))
                                    } else {
                                        Text("速度未知")
                                    }
                                }
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                
                                if let steps = displayedTransport.stepCount, steps > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "figure.walk")
                                        Text("\(steps) 步")
                                        Text("· 来自 Apple 健康")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .dfkDetailMaterial(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: -2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .sheet(item: $showingSearchSheet) { type in
                LocationSearchSheet(
                    locationManager: locationManager,
                    coordinate: type == .start ? displayedTransport.points.first : displayedTransport.points.last,
                    forOngoing: false
                ) { newName in
                    saveLocationOverride(type: type, name: newName)
                }
            }
            .sheet(isPresented: $showingTimeAdjustment) {
                TransportTimeAdjustmentView(transport: displayedTransport) { start, end in
                    localStartTime = start
                    localEndTime = end
                    reloadDisplayedTransport(for: start)
                    onLocationUpdate?()
                }
            }
            .sheet(isPresented: $showingRouteCorrection) {
                if editableRouteGaps.indices.contains(selectedRouteGapIndex) {
                    TransportRouteCorrectionView(
                        transport: displayedTransport.updatingType(displayType),
                        gaps: [editableRouteGaps[selectedRouteGapIndex]],
                        initialGapIndex: 0
                    ) {
                        inferredRoutesRevision = TransportRouteCompletion.revision
                        NotificationCenter.default.post(name: TransportRouteCompletion.didChange, object: nil)
                    }
                }
            }
            .task(id: RouteDisplayKey(geometry: displayedTransport.routeGeometryIdentity, type: displayType, revision: inferredRoutesRevision)) {
                let route = displayedTransport.updatingType(displayType)
                let routeRenderIdentity = "transport-detail-\(route.id.uuidString)-\(inferredRoutesRevision)"
                let prepared = await Task.detached(priority: .userInitiated) {
                    let gaps = TransportRouteCompletion.gaps(for: route)
                    let segments = TransportRouteProgressGeometry.renderableSegments(
                        TransportRouteCompletion.cachedSegments(for: route),
                        idPrefix: routeRenderIdentity
                    )
                    return (
                        segments: segments,
                        animation: TransportRouteAnimation.make(
                            segments: segments,
                            pathPoints: route.pathPoints,
                            averageSpeed: route.averageSpeed,
                            startTime: route.startTime,
                            endTime: route.endTime
                        ),
                        gaps: gaps,
                        tapTargets: gaps.enumerated().map { index, gap in
                            RouteTapTarget(
                                gapIndex: index,
                                coordinates: TransportRouteCompletion.cachedRouteCoordinates(for: gap) ?? [gap.start, gap.end]
                            )
                        }
                    )
                }.value
                guard !Task.isCancelled else { return }
                displayedRouteSegments = prepared.segments
                routeAnimation = prepared.animation
                routeAnimationFrameIndex = accessibilityReduceMotion
                    ? prepared.animation.frames.count / 2
                    : 0
                isRouteAnimationPaused = TimelinePlaybackMotionPolicy.startsPaused(
                    reduceMotionEnabled: accessibilityReduceMotion
                )
                routeAnimationRevision &+= 1
                editableRouteGaps = prepared.gaps
                routeTapTargets = prepared.tapTargets
            }
            .onChange(of: followsRouteAnimation) { _, follows in
                if follows {
                    withAnimation(accessibilityReduceMotion ? .linear : .easeInOut) {
                        centerCameraOnAnimationFrame()
                    }
                } else {
                    if routeAnimationWasPlayingBeforeMapTouch {
                        isRouteAnimationPaused = false
                    }
                    routeAnimationWasPlayingBeforeMapTouch = false
                    isDraggingRouteMap = false
                    isZoomingRouteMap = false
                    isRotatingRouteMap = false
                    isTouchingRouteMap = false
                    isRouteMapRecentering = false
                    routeMapNeedsRecenterAfterInteraction = false
                }
            }
            .task(id: "\(routeAnimationRevision)-\(followsRouteAnimation)-\(accessibilityReduceMotion)-\(isRouteAnimationPaused)-\(isRouteAnimationScrubbing)") {
                guard !isRouteAnimationPaused,
                      !isRouteAnimationScrubbing,
                      routeAnimation.frames.count >= 2,
                      routeAnimation.frameInterval > 0 else { return }
                if followsRouteAnimation && routeMapNeedsRecenterAfterInteraction {
                    routeAnimationWasPlayingBeforeMapTouch = true
                    isRouteAnimationPaused = true
                    finishRouteMapInteraction()
                    return
                }
                await TimelinePlaybackAdvancePipeline.run(
                    frameCount: { routeAnimation.frames.count },
                    frameInterval: { routeAnimation.frameInterval },
                    endPause: { routeAnimation.endPause },
                    frameIndex: { routeAnimationFrameIndex },
                    canAdvance: {
                        !isRouteAnimationPaused &&
                            !isRouteAnimationScrubbing
                    },
                    resetLoopState: {},
                    applyFrame: { index in
                        setRouteAnimationFrame(index)
                    }
                )
            }
            .onChange(of: accessibilityReduceMotion) { _, reducesMotion in
                guard reducesMotion else { return }
                isRouteAnimationPaused = true
                routeAnimationFrameIndex = routeAnimation.frames.count / 2
            }
            // Cache revisions redraw the map without starting another request.
            // Opening or rebuilding the detail view is automatic loading, not a
            // user-requested retry, so it must keep the configured cooldown and
            // persisted failure limit instead of bypassing them.
            .task(id: RouteDisplayKey(geometry: displayedTransport.routeGeometryIdentity, type: displayType, revision: 0)) {
                let route = displayedTransport.updatingType(displayType)
                await TransportRouteCompletion.prepare([route])
            }
            .onReceive(NotificationCenter.default.publisher(for: TransportRouteCompletion.didChange)) { _ in
                inferredRoutesRevision = TransportRouteCompletion.revision
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    interactiveMapReady = true
                }

                // Refresh only persisted metadata. The presented Transport is
                // the timeline-aligned snapshot and can contain synthetic
                // endpoint padding that renders as dashed connectors; replacing
                // it with the raw stored route would lose that geometry.
                reloadPersistedType()
                
                // 默认范围不要变：显式设置 camera 为交通路径的范围，避免被 allPlaces 的 MapCircle 撑开
                let points = transport.points
                Task { @MainActor in
                    let region = await Task.detached(priority: .userInitiated) {
                        points.boundingRegion()
                    }.value
                    // A reload may already have framed the refreshed route.
                    guard refreshedTransport == nil, let region else { return }
                    position = .region(region)
                }

            }
        }
    }

    private func openRouteCorrectionIfNeeded(at coordinate: CLLocationCoordinate2D, mapSize: CGSize) {
        guard let region = visibleRouteRegion, !routeTapTargets.isEmpty, mapSize.width > 0 else { return }
        let targets = routeTapTargets
        Task { @MainActor in
            let gapIndex = await Task.detached(priority: .userInitiated) {
                Self.hitGapIndex(
                    at: coordinate,
                    targets: targets,
                    region: region,
                    mapWidth: mapSize.width
                )
            }.value
            guard let gapIndex else { return }
            selectedRouteGapIndex = gapIndex
            showingRouteCorrection = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    nonisolated private static func hitGapIndex(
        at coordinate: CLLocationCoordinate2D,
        targets: [RouteTapTarget],
        region: MKCoordinateRegion,
        mapWidth: CGFloat
    ) -> Int? {
        let west = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let east = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        let mapPointsPerScreenPoint = abs(east.x - west.x) / max(Double(mapWidth), 1)
        let hitDistance = mapPointsPerScreenPoint * 24
        let tap = MKMapPoint(coordinate)
        var best: (gapIndex: Int, squaredDistance: Double)?

        for target in targets where target.coordinates.count >= 2 {
            let points = target.coordinates.map { MKMapPoint($0) }
            for (start, end) in zip(points, points.dropFirst()) {
                let squaredDistance = squaredDistance(from: tap, toSegmentFrom: start, to: end)
                if best == nil || squaredDistance < best!.squaredDistance {
                    best = (target.gapIndex, squaredDistance)
                }
            }
        }
        guard let best, best.squaredDistance <= hitDistance * hitDistance else { return nil }
        return best.gapIndex
    }

    nonisolated private static func squaredDistance(
        from point: MKMapPoint,
        toSegmentFrom start: MKMapPoint,
        to end: MKMapPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let pointDX = point.x - start.x
            let pointDY = point.y - start.y
            return pointDX * pointDX + pointDY * pointDY
        }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        let projectedX = start.x + projection * dx
        let projectedY = start.y + projection * dy
        let pointDX = point.x - projectedX
        let pointDY = point.y - projectedY
        return pointDX * pointDX + pointDY * pointDY
    }
    
    private func findRecord() -> TransportRecord? {
        let tid = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == tid })
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first
    }
    
    private func saveLocationOverride(type: LocationType, name: String) {
        Aptabase.shared.trackEvent("transport_edited")
        withAnimation(.spring(response: 0.3)) {
            if type == .start {
                localStartOverride = name
            } else {
                localEndOverride = name
            }
        }
        
        if let record = findRecord() {
            if type == .start {
                record.startLocation = name
            } else {
                record.endLocation = name
            }
            
            // Preserve current type
            record.manualTypeRaw = (localManualType ?? transport.manualType ?? transport.type).rawValue
            try? modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
            onLocationUpdate?()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private var distanceString: String {
        if displayedTransport.distance < 1000 {
            return String(format: "%.0f 米", displayedTransport.distance)
        } else {
            return String(format: "%.1f 公里", displayedTransport.distance / 1000.0)
        }
    }

    private func reloadDisplayedTransport(for date: Date) {
        let transportID = transport.id
        Task { @MainActor in
            let transports = await PersistentTimelineBuilder.fetchTimelineTransports(for: date, container: modelContext.container)
            let updated = transports.first { $0.id == transportID }
            guard let updated else { return }
            refreshedTransport = updated
            let points = updated.points
            let region = await Task.detached(priority: .userInitiated) {
                points.boundingRegion()
            }.value
            if let region {
                position = .region(region)
            }
        }
    }

    private func reloadPersistedType() {
        guard let record = findRecord() else { return }
        localManualType = TransportType(rawValue: record.manualTypeRaw ?? record.typeRaw)
    }

    private var durationString: String {
        let minutes = max(1, Int(currentEndTime.timeIntervalSince(currentStartTime) / 60))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return hours > 0 ? "\(hours) 小时 \(remainingMinutes) 分钟" : "\(minutes) 分钟"
    }
    
    private func saveChoice(_ type: TransportType) {
        Aptabase.shared.trackEvent("transport_edited")
        // 1. Update local UI immediately
        withAnimation(.spring(response: 0.3)) {
            localManualType = type
        }
        
        // 2. Find and persist the owning record.
        guard let record = findRecord() else {
            localManualType = displayedTransport.currentType
            return
        }
        record.manualTypeRaw = type.rawValue
        record.typeRaw = type.rawValue

        do {
            try modelContext.save()
        } catch {
            localManualType = displayedTransport.currentType
            return
        }
        CloudSettingsManager.shared.triggerDataSyncPulse()

        // 3. Invalidate every timeline host from the owning detail view;
        // persistence must not depend on an optional presentation callback.
        let day = Calendar.current.startOfDay(for: record.startTime)
        TimelineBuilder.timelineCache.removeValue(forKey: day)
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": day]
        )

        // 4. Let the current host update any extra local state.
        onUpdate?(type)
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

private struct TransportRouteCorrectionOption: Identifiable, @unchecked Sendable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance?
    let expectedTravelTime: TimeInterval?
    let title: String?
}

private struct TransportRouteCorrectionRoutesBox: @unchecked Sendable {
    let routes: [TripPlannedRoute]
}

private struct TransportRouteCorrectionView: View {
    let transport: Transport
    let gaps: [TransportRouteCompletion.Gap]
    let onChange: () -> Void

    private enum EditMode: String, CaseIterable, Identifiable {
        case select
        case remove
        case waypoint

        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "选路线"
            case .remove: return "删绕路"
            case .waypoint: return "加途经点"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedGapIndex = 0
    @State private var editMode: EditMode = .select
    @State private var waypoint: CLLocationCoordinate2D?
    @State private var routeOptions: [TransportRouteCorrectionOption] = []
    @State private var selectedRouteIndex = 0
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var selectedGapHasManualRoute = false
    @State private var selectedGapHasLearnedRoute = false
    @State private var remembersRouteForFuture = true
    @State private var saveError: String?
    @State private var removalStartIndex: Int?
    @State private var removalEndIndex: Int?
    @State private var removalStartCoordinate: CLLocationCoordinate2D?
    @State private var removalEndCoordinate: CLLocationCoordinate2D?
    @State private var removalPreviewCoordinates: [CLLocationCoordinate2D]?
    @State private var removedCoordinates: [CLLocationCoordinate2D] = []

    init(
        transport: Transport,
        gaps: [TransportRouteCompletion.Gap],
        initialGapIndex: Int,
        onChange: @escaping () -> Void
    ) {
        self.transport = transport
        self.gaps = gaps
        self.onChange = onChange
        _selectedGapIndex = State(initialValue: gaps.indices.contains(initialGapIndex) ? initialGapIndex : 0)
    }

    private struct LoadKey: Hashable {
        let gapKey: String
        let waypointKey: String
    }

    private struct RemovalApplication: @unchecked Sendable {
        let start: Int
        let end: Int?
        let preview: [CLLocationCoordinate2D]?
        let removed: [CLLocationCoordinate2D]
    }

    private var selectedGap: TransportRouteCompletion.Gap? {
        gaps.indices.contains(selectedGapIndex) ? gaps[selectedGapIndex] : nil
    }

    private var selectedOption: TransportRouteCorrectionOption? {
        routeOptions.indices.contains(selectedRouteIndex) ? routeOptions[selectedRouteIndex] : nil
    }

    private var previewCoordinates: [CLLocationCoordinate2D]? {
        removalPreviewCoordinates ?? selectedOption?.coordinates
    }

    private var loadKey: LoadKey {
        LoadKey(
            gapKey: selectedGap?.key ?? "none",
            waypointKey: waypoint.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) } ?? "direct"
        )
    }

    private var editorInstructionTitle: String {
        if editMode == .select {
            return "选择一条正确路线"
        } else if editMode == .waypoint {
            return waypoint == nil ? "点击地图添加途经点" : "再次点击可移动途经点"
        }
        if removalStartIndex == nil { return "点击绕路开始的位置" }
        if removalEndIndex == nil { return "再点击绕路结束的位置" }
        return "已删除红色绕路段"
    }

    private var editorInstructionDetail: String {
        if editMode == .select {
            return routeOptions.count > 1
                ? "先选择最接近的方案，再按需要同时删绕路、加途经点。"
                : "地图服务目前只返回了一条路线，可同时使用删除和途经点继续修正。"
        } else if editMode == .waypoint {
            return "路线会经过所选位置重新规划，并保留已经选择的删减区间。"
        }
        if removalEndIndex == nil {
            return "两个切点之间的路线会被移除，并改为直接连接。"
        }
        return "蓝色线是组合后的补充路线；还可继续加途经点，原始轨迹和统计不会改变。"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let gap = selectedGap {
                            Marker("缺口起点", systemImage: "play.fill", coordinate: gap.start)
                                .tint(.green)
                            Marker("缺口终点", systemImage: "stop.fill", coordinate: gap.end)
                                .tint(.blue)
                        }
                        if let waypoint {
                            Annotation("途经点", coordinate: waypoint, anchor: .bottom) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white, Color.orange)
                                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                            }
                        }
                        if let option = selectedOption,
                           let startIndex = removalStartIndex,
                           option.coordinates.indices.contains(startIndex) {
                            Marker("删除起点", systemImage: "1.circle.fill", coordinate: option.coordinates[startIndex])
                                .tint(.orange)
                        }
                        if let option = selectedOption,
                           let endIndex = removalEndIndex,
                           option.coordinates.indices.contains(endIndex) {
                            Marker("删除终点", systemImage: "2.circle.fill", coordinate: option.coordinates[endIndex])
                                .tint(.orange)
                        }
                        if let coordinates = previewCoordinates {
                            MapPolyline(coordinates: coordinates)
                                .browseStroke(
                                    opacity: 0.8,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [7, 6])
                                )
                        }
                        if removedCoordinates.count >= 2 {
                            MapPolyline(coordinates: removedCoordinates)
                                .stroke(
                                    Color.red.opacity(0.6),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [4, 4])
                                )
                        }
                    }
                    .browseMapStyle(elevation: .automatic, pointsOfInterest: .excludingAll)
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { value in
                                guard let coordinate = proxy.convert(value.location, from: .local),
                                      CLLocationCoordinate2DIsValid(coordinate) else { return }
                                handleEditorTap(coordinate)
                            }
                    )
                }
                .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("修正方式", selection: $editMode) {
                        ForEach(EditMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(editorInstructionTitle)
                                .font(.headline)
                            Text(editorInstructionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if editMode == .waypoint, waypoint != nil {
                            Button("移除途经点") { waypoint = nil }
                                .font(.caption.weight(.semibold))
                        } else if editMode == .remove, removalStartIndex != nil {
                            Button("重新选择") { clearRemoval() }
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if waypoint != nil || removalEndCoordinate != nil {
                        HStack(spacing: 8) {
                            if removalEndCoordinate != nil {
                                Label("已删绕路", systemImage: "scissors")
                            }
                            if waypoint != nil {
                                Label("已加途经点", systemImage: "mappin")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.dfkAccent)
                    }

                    Toggle("以后相同路段也使用", isOn: $remembersRouteForFuture)
                        .font(.subheadline.weight(.semibold))
                        .tint(.dfkAccent)

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在规划路线…")
                        }
                        .foregroundStyle(.secondary)
                    } else if routeOptions.count > 1, editMode != .remove {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(routeOptions.indices, id: \.self) { index in
                                    Button {
                                        selectRoute(index)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(routeOptions[index].title ?? "方案 \(index + 1)")
                                                .font(.subheadline.weight(.semibold))
                                            Text(optionSummary(routeOptions[index]))
                                                .font(.caption)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(index == selectedRouteIndex ? Color.dfkAccent : Color.secondary)
                                }
                            }
                        }
                    } else if loadFailed {
                        Text(editMode == .waypoint
                             ? "暂时无法获取可用路线，请移动途经点后重试。"
                             : "暂时无法获取其他路线，可尝试删除绕路或添加途经点。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let option = selectedOption {
                        Text(optionSummary(option))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if selectedGapHasManualRoute || selectedGapHasLearnedRoute {
                            Button("恢复自动补充", role: .destructive) { resetRoute() }
                                .disabled(isSaving)
                        }
                        Spacer()
                        Button("保存修正") { saveRoute() }
                            .buttonStyle(.borderedProminent)
                            .tint(.dfkAccent)
                            .disabled(selectedOption == nil || isLoading || isSaving)
                    }
                }
                .padding(16)
                .dfkDetailMaterial(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .navigationTitle("修正补充路线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .task(id: loadKey) {
                await loadRoutes()
            }
            .alert("无法保存路线", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "请稍后重试。")
            }
        }
    }

    @MainActor
    private func loadRoutes() async {
        guard let gap = selectedGap else { return }
        isLoading = true
        loadFailed = false
        if removalStartCoordinate != nil {
            removalStartIndex = nil
            removalEndIndex = nil
            removalPreviewCoordinates = nil
            removedCoordinates = []
        }
        let existing = await Task.detached(priority: .utility) {
            (
                coordinates: TransportRouteCompletion.cachedRouteCoordinates(for: gap),
                isManual: TransportRouteCompletion.hasManualRoute(for: gap),
                isLearned: TransportRouteCompletion.hasLearnedRoute(for: gap)
            )
        }.value
        guard !Task.isCancelled else { return }
        selectedGapHasManualRoute = existing.isManual
        selectedGapHasLearnedRoute = existing.isLearned

        if waypoint == nil, let coordinates = existing.coordinates {
            routeOptions = [TransportRouteCorrectionOption(
                coordinates: coordinates,
                distance: nil,
                expectedTravelTime: nil,
                title: existing.isManual
                    ? "当前修正路线"
                    : (existing.isLearned ? "常走补充路线" : "当前补充路线")
            )]
            selectedRouteIndex = 0
            await reapplyRemoval(to: coordinates)
            fitMap(to: coordinates)
        } else {
            routeOptions = []
        }

        let firstRoutes = await TencentTripDirections.routes(
            from: gap.start,
            to: waypoint ?? gap.end,
            transportTypeRaw: gap.type.rawValue
        )
        guard !Task.isCancelled else { return }
        if waypoint == nil, existing.coordinates == nil, !firstRoutes.isEmpty {
            let candidates = TransportRouteCorrectionRoutesBox(routes: firstRoutes)
            let cached = await Task.detached(priority: .utility) {
                TransportRouteCompletion.cacheBestAutomaticRoute(
                    from: candidates.routes,
                    for: gap
                )
            }.value
            guard !Task.isCancelled else { return }
            if cached {
                NotificationCenter.default.post(name: TransportRouteCompletion.didChange, object: nil)
                _ = Task { await WidgetDataSyncManager.shared.syncAll() }
            }
        }
        let secondRoutes: [TripPlannedRoute]
        if let waypoint {
            secondRoutes = await TencentTripDirections.routes(
                from: waypoint,
                to: gap.end,
                transportTypeRaw: gap.type.rawValue
            )
        } else {
            secondRoutes = []
        }
        guard !Task.isCancelled else { return }

        let firstBox = TransportRouteCorrectionRoutesBox(routes: firstRoutes)
        let secondBox = TransportRouteCorrectionRoutesBox(routes: secondRoutes)
        let hasWaypoint = waypoint != nil
        let planned = await Task.detached(priority: .userInitiated) {
            Self.makeOptions(first: firstBox.routes, second: secondBox.routes, hasWaypoint: hasWaypoint)
        }.value
        guard !Task.isCancelled else { return }

        if !planned.isEmpty {
            if existing.isManual && waypoint == nil, let current = routeOptions.first {
                routeOptions = [current] + planned.filter { !Self.sameRoute($0.coordinates, current.coordinates) }
            } else {
                routeOptions = planned
            }
            selectedRouteIndex = 0
            if let coordinates = routeOptions.first?.coordinates {
                await reapplyRemoval(to: coordinates)
                fitMap(to: coordinates)
            }
        }
        loadFailed = routeOptions.isEmpty
        isLoading = false
    }

    private func handleEditorTap(_ coordinate: CLLocationCoordinate2D) {
        if editMode == .select { return }
        if editMode == .waypoint {
            waypoint = coordinate
            selectedRouteIndex = 0
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        guard let option = selectedOption, !option.coordinates.isEmpty else { return }
        let coordinates = option.coordinates
        Task { @MainActor in
            let index = await Task.detached(priority: .userInitiated) {
                Self.nearestCoordinateIndex(to: coordinate, in: coordinates)
            }.value
            guard let index else { return }
            if removalStartIndex == nil || removalEndIndex != nil {
                removalStartIndex = index
                removalEndIndex = nil
                removalStartCoordinate = coordinates[index]
                removalEndCoordinate = nil
                removalPreviewCoordinates = nil
                removedCoordinates = []
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            guard let startIndex = removalStartIndex else { return }
            let preview = await Task.detached(priority: .userInitiated) {
                Self.removingRouteSection(coordinates, from: startIndex, to: index)
            }.value
            guard let preview else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            removalStartIndex = preview.lowerIndex
            removalEndIndex = preview.upperIndex
            removalStartCoordinate = coordinates[preview.lowerIndex]
            removalEndCoordinate = coordinates[preview.upperIndex]
            removalPreviewCoordinates = preview.coordinates
            removedCoordinates = preview.removed
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    nonisolated private static func nearestCoordinateIndex(
        to coordinate: CLLocationCoordinate2D,
        in coordinates: [CLLocationCoordinate2D]
    ) -> Int? {
        let target = MKMapPoint(coordinate)
        return coordinates.indices.min { lhs, rhs in
            let lhsPoint = MKMapPoint(coordinates[lhs])
            let rhsPoint = MKMapPoint(coordinates[rhs])
            let lhsDX = lhsPoint.x - target.x
            let lhsDY = lhsPoint.y - target.y
            let rhsDX = rhsPoint.x - target.x
            let rhsDY = rhsPoint.y - target.y
            return lhsDX * lhsDX + lhsDY * lhsDY < rhsDX * rhsDX + rhsDY * rhsDY
        }
    }

    nonisolated private static func removingRouteSection(
        _ coordinates: [CLLocationCoordinate2D],
        from firstIndex: Int,
        to secondIndex: Int
    ) -> (coordinates: [CLLocationCoordinate2D], removed: [CLLocationCoordinate2D], lowerIndex: Int, upperIndex: Int)? {
        let lower = min(firstIndex, secondIndex)
        let upper = max(firstIndex, secondIndex)
        guard coordinates.indices.contains(lower), coordinates.indices.contains(upper), upper - lower >= 2 else {
            return nil
        }
        let kept = Array(coordinates[...lower]) + Array(coordinates[upper...])
        return (kept, Array(coordinates[lower...upper]), lower, upper)
    }

    private func selectRoute(_ index: Int) {
        guard routeOptions.indices.contains(index) else { return }
        selectedRouteIndex = index
        let coordinates = routeOptions[index].coordinates
        Task { @MainActor in
            await reapplyRemoval(to: coordinates)
            fitMap(to: coordinates)
        }
    }

    private func clearRemoval() {
        removalStartIndex = nil
        removalEndIndex = nil
        removalStartCoordinate = nil
        removalEndCoordinate = nil
        removalPreviewCoordinates = nil
        removedCoordinates = []
    }

    @MainActor
    private func reapplyRemoval(to coordinates: [CLLocationCoordinate2D]) async {
        guard let startCoordinate = removalStartCoordinate else {
            removalStartIndex = nil
            removalEndIndex = nil
            removalPreviewCoordinates = nil
            removedCoordinates = []
            return
        }
        let endCoordinate = removalEndCoordinate
        let reapplied = await Task.detached(priority: .userInitiated) {
            guard let startIndex = Self.nearestCoordinateIndex(to: startCoordinate, in: coordinates) else {
                return nil as RemovalApplication?
            }
            guard let endCoordinate,
                  let endIndex = Self.nearestCoordinateIndex(to: endCoordinate, in: coordinates) else {
                return RemovalApplication(start: startIndex, end: nil, preview: nil, removed: [])
            }
            guard let preview = Self.removingRouteSection(coordinates, from: startIndex, to: endIndex) else {
                return RemovalApplication(start: startIndex, end: endIndex, preview: nil, removed: [])
            }
            return RemovalApplication(
                start: preview.lowerIndex,
                end: preview.upperIndex,
                preview: preview.coordinates,
                removed: preview.removed
            )
        }.value
        guard let reapplied else { return }
        removalStartIndex = reapplied.start
        removalEndIndex = reapplied.end
        removalPreviewCoordinates = reapplied.preview
        removedCoordinates = reapplied.removed
    }

    nonisolated private static func makeOptions(
        first: [TripPlannedRoute],
        second: [TripPlannedRoute],
        hasWaypoint: Bool
    ) -> [TransportRouteCorrectionOption] {
        if !hasWaypoint {
            return first.map {
                TransportRouteCorrectionOption(
                    coordinates: $0.coordinates,
                    distance: $0.distance,
                    expectedTravelTime: $0.expectedTravelTime,
                    title: nil
                )
            }
        }
        guard !first.isEmpty, !second.isEmpty else { return [] }
        return first.flatMap { leading in
            second.map { trailing in
                var coordinates = leading.coordinates
                let trailingCoordinates = trailing.coordinates
                coordinates.append(contentsOf: trailingCoordinates.dropFirst())
                return TransportRouteCorrectionOption(
                    coordinates: coordinates,
                    distance: leading.distance + trailing.distance,
                    expectedTravelTime: leading.expectedTravelTime + trailing.expectedTravelTime,
                    title: nil
                )
            }
        }
    }

    nonisolated private static func sameRoute(
        _ lhs: [CLLocationCoordinate2D],
        _ rhs: [CLLocationCoordinate2D]
    ) -> Bool {
        guard let lhsFirst = lhs.first, let lhsLast = lhs.last,
              let rhsFirst = rhs.first, let rhsLast = rhs.last else { return false }
        return lhs.count == rhs.count &&
            lhsFirst.latitude == rhsFirst.latitude &&
            lhsFirst.longitude == rhsFirst.longitude &&
            lhsLast.latitude == rhsLast.latitude &&
            lhsLast.longitude == rhsLast.longitude
    }

    private func optionSummary(_ option: TransportRouteCorrectionOption) -> String {
        guard let distance = option.distance, let duration = option.expectedTravelTime else {
            return "已保存的显示路线"
        }
        let distanceText = distance < 1_000
            ? "\(max(1, Int(distance.rounded())))米"
            : String(format: "%.1f公里", distance / 1_000)
        let minutes = max(1, Int((duration / 60).rounded()))
        return "\(distanceText) · 约\(minutes)分钟"
    }

    private func fitMap(to coordinates: [CLLocationCoordinate2D]) {
        Task { @MainActor in
            let region = await Task.detached(priority: .userInitiated) {
                coordinates.boundingRegion(paddingFactor: 1.45)
            }.value
            guard let region else { return }
            withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) }
        }
    }

    private func saveRoute() {
        guard let gap = selectedGap, let coordinates = previewCoordinates else { return }
        isSaving = true
        let learnsForFuture = remembersRouteForFuture
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                TransportRouteCompletion.saveManualRoute(
                    coordinates,
                    for: gap,
                    learnsForFuture: learnsForFuture
                )
            }.value
            isSaving = false
            guard result.routeSaved else {
                saveError = "路线文件写入失败，原始轨迹没有受到影响。"
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onChange()
            guard result.learnedRouteSaved else {
                selectedGapHasManualRoute = true
                saveError = "本次修正已保存，但常走路线记忆失败，请稍后重试。"
                return
            }
            dismiss()
        }
    }

    private func resetRoute() {
        guard let gap = selectedGap else { return }
        isSaving = true
        Task { @MainActor in
            let reset = await Task.detached(priority: .userInitiated) {
                TransportRouteCompletion.resetManualRoute(for: gap)
            }.value
            guard reset else {
                isSaving = false
                saveError = "无法恢复自动补充，当前修正路线仍然保留。"
                return
            }
            onChange()
            await TransportRouteCompletion.prepare([transport], activelyRequested: true)
            isSaving = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
        }
    }
}

struct TransportSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transport: Transport
    var onSave: (() -> Void)? = nil

    @State private var splitTime = Date()
    @State private var routePoints: [CodableCoordinate] = []

    private let minimumDuration: TimeInterval = 60

    private var canSplit: Bool {
        transport.endTime.timeIntervalSince(transport.startTime) >= minimumDuration * 2
    }

    private var boundedSplitTime: Date {
        min(
            max(splitTime, transport.startTime.addingTimeInterval(minimumDuration)),
            transport.endTime.addingTimeInterval(-minimumDuration)
        )
    }

    private var splitTimeRange: ClosedRange<TimeInterval> {
        let lowerBound = transport.startTime.addingTimeInterval(minimumDuration).timeIntervalSince1970
        let upperBound = transport.endTime.addingTimeInterval(-minimumDuration).timeIntervalSince1970
        return lowerBound...upperBound
    }

    /// Split result for one slider value, computed off main. The body only
    /// reads this; the map redraws only when `revision` changes.
    private struct SplitPreview: @unchecked Sendable {
        let splitTime: Date
        let firstRoute: [CodableCoordinate]
        let secondRoute: [CodableCoordinate]
        /// Renderable coordinates of each half.
        let firstSegment: [CLLocationCoordinate2D]
        let secondSegment: [CLLocationCoordinate2D]
        let splitCoordinate: CLLocationCoordinate2D?
        let firstDistance: Double
        let secondDistance: Double
        let mapRect: MKMapRect?
        let revision: Int

        var hasPreviewCoordinates: Bool {
            !firstRoute.isEmpty || !secondRoute.isEmpty
        }

        static let empty = SplitPreview(
            splitTime: .distantPast, firstRoute: [], secondRoute: [], firstSegment: [], secondSegment: [],
            splitCoordinate: nil, firstDistance: 0, secondDistance: 0, mapRect: nil, revision: 0
        )
    }

    @State private var routeRevision = 0
    @State private var splitPreview = SplitPreview.empty

    private struct SplitPreviewKey: Equatable {
        let routeRevision: Int
        let splitTime: Date
    }

    nonisolated private static func splitRoutes(points: [CodableCoordinate], startTime: Date, splitTime: Date, endTime: Date) -> (first: [CodableCoordinate], second: [CodableCoordinate]) {
        TransportSplitRouteBuilder.segments(
            points: points,
            startTime: startTime,
            splitTime: splitTime,
            endTime: endTime
        )
    }

    nonisolated private static func makeSplitPreview(points: [CodableCoordinate], startTime: Date, splitTime: Date, endTime: Date, revision: Int) -> SplitPreview {
        let routes = splitRoutes(points: points, startTime: startTime, splitTime: splitTime, endTime: endTime)
        func renderable(_ route: [CodableCoordinate]) -> [CLLocationCoordinate2D] {
            route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }.filter { coordinate in
                coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
            }
        }
        let firstSegment = renderable(routes.first)
        let secondSegment = renderable(routes.second)
        let splitCoordinate = routes.first.last.flatMap { point -> CLLocationCoordinate2D? in
            let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            guard coordinate.latitude.isFinite,
                  coordinate.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return coordinate
        }
        let route = firstSegment + secondSegment
        let mapRect = route.first.map { initial in
            route.dropFirst().reduce(MKMapRect(origin: MKMapPoint(initial), size: MKMapSize(width: 1, height: 1))) { rect, coordinate in
                rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1)))
            }
        }
        return SplitPreview(
            splitTime: splitTime,
            firstRoute: routes.first,
            secondRoute: routes.second,
            firstSegment: firstSegment,
            secondSegment: secondSegment,
            splitCoordinate: splitCoordinate,
            firstDistance: TimelineBuilder.calculatePathDistance(routes.first),
            secondDistance: TimelineBuilder.calculatePathDistance(routes.second),
            mapRect: mapRect,
            revision: revision
        )
    }

    private func refreshSplitPreview() async {
        let points = routePoints
        let startTime = transport.startTime
        let endTime = transport.endTime
        let split = boundedSplitTime
        let revision = splitPreview.revision &+ 1
        let preview = await Task.detached(priority: .userInitiated) {
            Self.makeSplitPreview(points: points, startTime: startTime, splitTime: split, endTime: endTime, revision: revision)
        }.value
        guard !Task.isCancelled else { return }
        splitPreview = preview
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    GeometryReader { proxy in
                        if proxy.size.width > 1 && proxy.size.height > 1 && splitPreview.hasPreviewCoordinates {
                            TransportSplitMapView(
                                firstSegment: splitPreview.firstSegment,
                                secondSegment: splitPreview.secondSegment,
                                splitCoordinate: splitPreview.splitCoordinate,
                                mapRect: splitPreview.mapRect,
                                renderRevision: splitPreview.revision
                            )
                        } else {
                            Color.secondary.opacity(0.05)
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("拆分时间")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(timeText(boundedSplitTime))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                        }

                        if canSplit {
                            Slider(
                                value: Binding(
                                    get: { splitTime.timeIntervalSince1970 },
                                    set: { splitTime = Date(timeIntervalSince1970: $0) }
                                ),
                                in: splitTimeRange,
                                step: 60
                            )
                            .tint(.dfkAccent)
                        } else {
                            Text("交通时长不足 2 分钟，无法拆分")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(timeText(transport.startTime))
                            Spacer()
                            Text(timeText(transport.endTime))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))

                    HStack(spacing: 12) {
                        SplitPreviewTransportCard(title: "前半段", start: transport.startTime, end: boundedSplitTime, distance: splitPreview.firstDistance, color: .green)
                        SplitPreviewTransportCard(title: "后半段", start: boundedSplitTime, end: transport.endTime, distance: splitPreview.secondDistance, color: .blue)
                    }
                }
                .padding(20)
            }
            .navigationTitle("拆分交通")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveSplit() } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon().fontWeight(.bold)
                    }
                    .disabled(!canSplit)
                }
            }
        }
        .onAppear {
            splitTime = roundedToMinute(
                transport.startTime.addingTimeInterval(
                    transport.endTime.timeIntervalSince(transport.startTime) / 2
                )
            )
            loadRoute()
        }
        .task(id: SplitPreviewKey(routeRevision: routeRevision, splitTime: boundedSplitTime)) {
            await refreshSplitPreview()
        }
    }

    private func loadRoute() {
        let fallback = [
            CodableCoordinate(lat: transport.points.first?.latitude ?? 0, lon: transport.points.first?.longitude ?? 0, timestamp: transport.startTime),
            CodableCoordinate(lat: transport.points.last?.latitude ?? 0, lon: transport.points.last?.longitude ?? 0, timestamp: transport.endTime)
        ]
        guard let pointsData = findRecord()?.pointsData else {
            routePoints = fallback
            routeRevision &+= 1
            return
        }
        Task { @MainActor in
            let decoded = await Task.detached(priority: .userInitiated) {
                try? JSONDecoder().decode([CodableCoordinate].self, from: pointsData)
            }.value
            routePoints = decoded ?? fallback
            routeRevision &+= 1
        }
    }

    private func saveSplit() {
        guard canSplit, findRecord() != nil else { return }
        // Persist exactly the same cut shown in the preview. Re-running route
        // interpolation here used to move the endpoints at save time.
        let split = boundedSplitTime
        let points = routePoints
        let startTime = transport.startTime
        let endTime = transport.endTime
        Task { @MainActor in
            let prepared = await Task.detached(priority: .userInitiated) {
                let routes = Self.splitRoutes(points: points, startTime: startTime, splitTime: split, endTime: endTime)
                return SplitSaveRoutes(
                    firstPoints: routes.first,
                    secondPoints: routes.second,
                    firstData: try? JSONEncoder().encode(routes.first),
                    secondData: try? JSONEncoder().encode(routes.second),
                    firstDistance: TimelineBuilder.calculatePathDistance(routes.first),
                    secondDistance: TimelineBuilder.calculatePathDistance(routes.second)
                )
            }.value
            guard let record = findRecord() else { return }
            applySplit(record: record, split: split, routes: prepared)
        }
    }

    private struct SplitSaveRoutes: @unchecked Sendable {
        let firstPoints: [CodableCoordinate]
        let secondPoints: [CodableCoordinate]
        let firstData: Data?
        let secondData: Data?
        let firstDistance: Double
        let secondDistance: Double
    }

    private func applySplit(record: TransportRecord, split: Date, routes: SplitSaveRoutes) {
        let oldEnd = record.endTime
        let oldEndLocation = record.endLocation
        let ratio = split.timeIntervalSince(record.startTime) / max(1, record.endTime.timeIntervalSince(record.startTime))
        let firstPoints = routes.firstPoints
        let secondPoints = routes.secondPoints
        let explicitlySelectedType = record.manualTypeRaw

        record.endTime = split
        record.day = Calendar.current.startOfDay(for: record.startTime)
        record.endLocation = "中途"
        record.pointsData = routes.firstData ?? record.pointsData
        record.distance = routes.firstDistance
        record.averageSpeed = record.distance / max(1, record.endTime.timeIntervalSince(record.startTime))
        record.stepCount = splitMetric(record.stepCount, ratio: ratio, second: false)
        record.typeRaw = explicitlySelectedType ?? inferredSplitType(for: record, points: firstPoints)
        record.manualTypeRaw = record.typeRaw // Keep the user-created split boundary stable during rebuilding.

        let newRecord = TransportRecord(
            day: Calendar.current.startOfDay(for: split),
            startTime: split,
            endTime: oldEnd,
            startLocation: "中途",
            endLocation: oldEndLocation,
            typeRaw: record.typeRaw,
            distance: routes.secondDistance,
            averageSpeed: 0,
            pointsData: routes.secondData ?? Data(),
            stepCount: splitMetric(transport.stepCount, ratio: ratio, second: true)
        )
        newRecord.averageSpeed = newRecord.distance / max(1, oldEnd.timeIntervalSince(split))
        newRecord.typeRaw = explicitlySelectedType ?? inferredSplitType(for: newRecord, points: secondPoints)
        newRecord.manualTypeRaw = newRecord.typeRaw
        modelContext.insert(newRecord)
        try? modelContext.save()
        TimelineBuilder.timelineCache.removeValue(forKey: Calendar.current.startOfDay(for: transport.startTime))
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
        CloudSettingsManager.shared.triggerDataSyncPulse()
        Aptabase.shared.trackEvent("transport_split")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSave?()
        dismiss()
    }

    private func inferredSplitType(for record: TransportRecord, points: [CodableCoordinate]) -> String {
        let observedCount = points.filter { $0.isSyntheticPadding != true && $0.timestamp != nil }.count
        return TransportType.from(
            speed: record.averageSpeed,
            stepCount: record.stepCount ?? 0,
            duration: record.endTime.timeIntervalSince(record.startTime),
            distanceMeters: record.distance,
            pointCount: points.count,
            observedPointCount: observedCount
        ).rawValue
    }

    private func findRecord() -> TransportRecord? {
        let id = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func splitMetric(_ value: Int?, ratio: Double, second: Bool) -> Int? {
        guard let value else { return nil }
        let first = Int((Double(value) * ratio).rounded())
        return second ? max(0, value - first) : first
    }

    private func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct SplitPreviewTransportCard: View {
    let title: String
    let start: Date
    let end: Date
    let distance: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
            Text(distance >= 1000 ? String(format: "%.1f 公里", distance / 1000) : String(format: "%.0f 米", distance))
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35), lineWidth: 1))
    }
}

private struct TransportSplitMapView: UIViewRepresentable {
    /// Already filtered to renderable coordinates.
    let firstSegment: [CLLocationCoordinate2D]
    let secondSegment: [CLLocationCoordinate2D]
    let splitCoordinate: CLLocationCoordinate2D?
    let mapRect: MKMapRect?
    /// Changes whenever the preview geometry changes.
    let renderRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = SafeMKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard renderRevision != context.coordinator.renderRevision else { return }
        context.coordinator.renderRevision = renderRevision
        let first = firstSegment
        let second = secondSegment
        let marker = splitCoordinate

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        if first.count >= 2 {
            let overlay = MKPolyline(coordinates: first, count: first.count)
            overlay.title = "first"
            mapView.addOverlay(overlay)
        }
        if second.count >= 2 {
            let overlay = MKPolyline(coordinates: second, count: second.count)
            overlay.title = "second"
            mapView.addOverlay(overlay)
        }
        if let marker {
            let annotation = MKPointAnnotation()
            annotation.coordinate = marker
            annotation.title = "拆分点"
            mapView.addAnnotation(annotation)
        }

        guard let rect = mapRect else { return }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 34, left: 34, bottom: 34, right: 34), animated: context.coordinator.hasRendered)
        context.coordinator.hasRendered = true
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderRevision = -1
        var hasRendered = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = line.title == "first" ? .systemGreen : .systemBlue
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "transport-split-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "scissors")
            view.displayPriority = .required
            return view
        }
    }
}

private struct TransportTimeAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transport: Transport
    let onSave: (Date, Date) -> Void

    @State private var rangeStart = Date()
    @State private var rangeEnd = Date()
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @State private var rawPointIndex = RawPointTimeIndex.empty
    @State private var isLoadingRawPoints = true
    @State private var hasInitializedRange = false
    @State private var isRegenerating = false

    private let minimumDuration: TimeInterval = 60

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Raw points indexed off main when loaded. Drag updates then select the
    /// draft range by binary search over sorted timestamps instead of
    /// filtering every point on each slider change.
    private struct RawPointTimeIndex: Sendable {
        /// Chronological timestamps of all raw points.
        let timestamps: [Date]
        /// Renderable coordinates, in the same order as their points.
        let validCoordinates: [CLLocationCoordinate2D]
        /// `validPrefixCounts[i]` = renderable points among the first `i`.
        let validPrefixCounts: [Int]

        static let empty = RawPointTimeIndex(timestamps: [], validCoordinates: [], validPrefixCounts: [0])

        init(timestamps: [Date], validCoordinates: [CLLocationCoordinate2D], validPrefixCounts: [Int]) {
            self.timestamps = timestamps
            self.validCoordinates = validCoordinates
            self.validPrefixCounts = validPrefixCounts
        }

        init(points: [CLLocation]) {
            var timestamps: [Date] = []
            var validCoordinates: [CLLocationCoordinate2D] = []
            var validPrefixCounts: [Int] = [0]
            timestamps.reserveCapacity(points.count)
            validPrefixCounts.reserveCapacity(points.count + 1)
            for point in points {
                timestamps.append(point.timestamp)
                let coordinate = point.coordinate
                if coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate) {
                    validCoordinates.append(coordinate)
                }
                validPrefixCounts.append(validCoordinates.count)
            }
            self.init(timestamps: timestamps, validCoordinates: validCoordinates, validPrefixCounts: validPrefixCounts)
        }

        /// Indices of points with `start <= timestamp <= end`.
        func range(from start: Date, to end: Date) -> Range<Int> {
            var low = 0
            var high = timestamps.count
            while low < high {
                let mid = (low + high) / 2
                if timestamps[mid] < start { low = mid + 1 } else { high = mid }
            }
            let lower = low
            high = timestamps.count
            while low < high {
                let mid = (low + high) / 2
                if timestamps[mid] <= end { low = mid + 1 } else { high = mid }
            }
            return lower..<max(lower, low)
        }
    }

    private var selectedRange: Range<Int> {
        rawPointIndex.range(from: draftStart, to: draftEnd)
    }

    private var selectedPointCount: Int {
        selectedRange.count
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        let range = selectedRange
        let lower = rawPointIndex.validPrefixCounts[range.lowerBound]
        let upper = rawPointIndex.validPrefixCounts[range.upperBound]
        return Array(rawPointIndex.validCoordinates[lower..<upper])
    }

    private var canSave: Bool {
        hasInitializedRange && !isLoadingRawPoints && !isRegenerating &&
            draftEnd.timeIntervalSince(draftStart) >= minimumDuration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    GeometryReader { proxy in
                        let coordinates = selectedCoordinates
                        if proxy.size.width > 1 && proxy.size.height > 1 && !coordinates.isEmpty {
                            FootprintTimeAdjustmentMapView(coordinates: coordinates, dotDiameter: 14)
                                .frame(minWidth: 1, minHeight: 1)
                        } else {
                            Color.secondary.opacity(0.05)
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .bottomLeading) {
                        Text(isLoadingRawPoints ? "加载轨迹点..." : "\(selectedPointCount) 个原始点")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                            .padding(12)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("调整时间")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(timeText(hasInitializedRange ? draftStart : transport.startTime))-\(timeText(hasInitializedRange ? draftEnd : transport.endTime))")
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundColor(.dfkMainText)
                        }

                        if hasInitializedRange {
                            FootprintTimeRangeSlider(
                                rangeStart: rangeStart,
                                rangeEnd: rangeEnd,
                                start: $draftStart,
                                end: $draftEnd
                            )
                            .frame(height: 34)
                        } else {
                            Color.clear.frame(height: 34)
                        }

                        HStack {
                            Text(timeText(hasInitializedRange ? rangeStart : transport.startTime))
                            Spacer()
                            Text(timeText(hasInitializedRange ? rangeEnd : transport.endTime))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))
                }
                .padding(20)
            }
            .navigationTitle("调整时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                    .disabled(isRegenerating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAdjustment() } label: {
                        if isRegenerating {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark").dfkToolbarConfirmIcon().fontWeight(.bold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            setupInitialRange()
            loadRawPoints()
        }
        .interactiveDismissDisabled(isRegenerating)
    }

    private func setupInitialRange() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: transport.startTime)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        let latestAllowedTime = min(dayEnd, currentMinute())
        rangeStart = editableRangeStart(dayStart: dayStart)
        rangeEnd = min(editableRangeEnd(dayEnd: dayEnd), latestAllowedTime)
        if rangeEnd.timeIntervalSince(rangeStart) < minimumDuration {
            rangeStart = dayStart
            rangeEnd = latestAllowedTime
        }
        draftStart = min(max(transport.startTime, rangeStart), rangeEnd.addingTimeInterval(-minimumDuration))
        draftEnd = max(min(transport.endTime, rangeEnd), draftStart.addingTimeInterval(minimumDuration))
        hasInitializedRange = true
    }

    private func currentMinute() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    }

    /// A connected neighbor can donate up to the alignment threshold to this
    /// transport, while retaining its own minimum valid duration.  This lets a
    /// user correct a slightly too-short inferred trip instead of only shrinking it.
    private func editableRangeStart(dayStart: Date) -> Date {
        let threshold = AppConfig.shared.transportAlignmentThreshold
        guard let previous = nearestPreviousItem(near: transport.startTime, threshold: threshold) else {
            return max(previousItemEnd(defaultingTo: dayStart), dayStart)
        }
        let earliestByNeighbor = previous.startTime.addingTimeInterval(minimumDuration(for: previous))
        let earliestByThreshold = transport.startTime.addingTimeInterval(-threshold)
        return max(dayStart, max(earliestByNeighbor, earliestByThreshold))
    }

    private func editableRangeEnd(dayEnd: Date) -> Date {
        let threshold = AppConfig.shared.transportAlignmentThreshold
        guard let next = nearestNextItem(near: transport.endTime, threshold: threshold) else {
            return min(nextItemStart(defaultingTo: dayEnd), dayEnd)
        }
        let latestByNeighbor = next.endTime.addingTimeInterval(-minimumDuration(for: next))
        let latestByThreshold = transport.endTime.addingTimeInterval(threshold)
        return min(dayEnd, min(latestByNeighbor, latestByThreshold))
    }

    private func loadRawPoints() {
        isLoadingRawPoints = true
        let dates = touchedDates(start: rangeStart, end: rangeEnd)
        Task {
            let points = await Task.detached {
                let chronological = dates.flatMap {
                    RawLocationStore.shared.loadAllDevicesLocations(for: $0, filtered: false)
                }.sorted { $0.timestamp < $1.timestamp }
                return RawPointTimeIndex(points: RawLocationStore.filterRidiculousSpikes(chronological))
            }.value
            await MainActor.run {
                rawPointIndex = points
                isLoadingRawPoints = false
            }
        }
    }

    private func previousItemEnd(defaultingTo fallback: Date) -> Date {
        let id = transport.id
        let transportStart = transport.startTime
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.endTime <= transportStart && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.endTime <= transportStart && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        return [
            (try? modelContext.fetch(transportDescriptor).first?.endTime),
            (try? modelContext.fetch(footprintDescriptor).first?.endTime),
            fallback
        ].compactMap { $0 }.max() ?? fallback
    }

    private func nextItemStart(defaultingTo fallback: Date) -> Date {
        let id = transport.id
        let transportEnd = transport.endTime
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.startTime >= transportEnd && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= transportEnd && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        return [
            (try? modelContext.fetch(transportDescriptor).first?.startTime),
            (try? modelContext.fetch(footprintDescriptor).first?.startTime),
            fallback
        ].compactMap { $0 }.min() ?? fallback
    }

    private func saveAdjustment() {
        guard let record = findRecord() else { dismiss(); return }
        let start = roundedToMinute(draftStart)
        let end = roundedToMinute(max(draftEnd, start.addingTimeInterval(minimumDuration)))
        guard !isLoadingRawPoints else { return }
        let oldStart = record.startTime
        let oldEnd = record.endTime
        record.updateTimeRangePreservingRoute(start: start, end: end)
        // Time boundaries are user-authored facts too.  Mark this record as
        // manual so periodic automatic consolidation cannot replace the
        // adjusted interval with a newly inferred one.
        record.manualTypeRaw = record.manualTypeRaw ?? transport.manualType?.rawValue ?? transport.type.rawValue
        let adjacentDates = adjustAdjacentItems(
            oldStart: oldStart,
            oldEnd: oldEnd,
            newStart: start,
            newEnd: end,
            didChangeStart: minuteKey(oldStart) != minuteKey(start),
            didChangeEnd: minuteKey(oldEnd) != minuteKey(end)
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            isRegenerating = false
            return
        }
        isRegenerating = true
        let affectedDates = touchedDates(start: oldStart, end: oldEnd)
            .union(touchedDates(start: start, end: end))
            .union(adjacentDates)
        invalidateCaches(oldStart: oldStart, oldEnd: oldEnd, newStart: start, newEnd: end, additionalDates: adjacentDates)
        Task { @MainActor in
            // Re-run one non-destructive reconstruction pass after the edited
            // boundaries and route have been committed. A full reset would
            // delete this manual edit and other user-authored records.
            for date in affectedDates.sorted() {
                var didSync = await PersistentTimelineBuilder.syncDay(
                    date: date, in: modelContext, runConsolidation: false
                )
                var retriesRemaining = 20
                while !didSync && retriesRemaining > 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    didSync = await PersistentTimelineBuilder.syncDay(
                        date: date, in: modelContext, runConsolidation: false
                    )
                    retriesRemaining -= 1
                }
                TimelineBuilder.timelineCache.removeValue(forKey: date)
            }
            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            onSave(start, end)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isRegenerating = false
            dismiss()
        }
    }

    private func findRecord() -> TransportRecord? {
        let id = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Keep a connected timeline connected when the edited transport originally
    /// touched its neighboring item (within the configured 20-minute threshold).
    /// Items separated by a larger gap are intentionally left untouched.
    private func adjustAdjacentItems(
        oldStart: Date,
        oldEnd: Date,
        newStart: Date,
        newEnd: Date,
        didChangeStart: Bool,
        didChangeEnd: Bool
    ) -> Set<Date> {
        var affectedDates: Set<Date> = []
        let threshold = AppConfig.shared.transportAlignmentThreshold

        if didChangeStart, let previous = nearestPreviousItem(near: oldStart, threshold: threshold) {
            affectedDates.formUnion(updateEnd(of: previous, to: newStart))
        }
        if didChangeEnd, let next = nearestNextItem(near: oldEnd, threshold: threshold) {
            affectedDates.formUnion(updateStart(of: next, to: newEnd))
        }
        return affectedDates
    }

    private enum AdjacentItem {
        case footprint(Footprint)
        case transport(TransportRecord)

        var startTime: Date {
            switch self {
            case .footprint(let record): record.startTime
            case .transport(let record): record.startTime
            }
        }

        var endTime: Date {
            switch self {
            case .footprint(let record): record.endTime
            case .transport(let record): record.endTime
            }
        }
    }

    private func nearestPreviousItem(near date: Date, threshold: TimeInterval) -> AdjacentItem? {
        let id = transport.id
        let lower = date.addingTimeInterval(-threshold)
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.endTime >= lower && $0.endTime <= date && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.endTime >= lower && $0.endTime <= date && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let candidates = [
            (try? modelContext.fetch(transportDescriptor).first).map(AdjacentItem.transport),
            (try? modelContext.fetch(footprintDescriptor).first).map(AdjacentItem.footprint)
        ].compactMap { $0 }
        return candidates.max { $0.endTime < $1.endTime }
    }

    private func nearestNextItem(near date: Date, threshold: TimeInterval) -> AdjacentItem? {
        let id = transport.id
        let upper = date.addingTimeInterval(threshold)
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.startTime >= date && $0.startTime <= upper && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= date && $0.startTime <= upper && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let candidates = [
            (try? modelContext.fetch(transportDescriptor).first).map(AdjacentItem.transport),
            (try? modelContext.fetch(footprintDescriptor).first).map(AdjacentItem.footprint)
        ].compactMap { $0 }
        return candidates.min { $0.startTime < $1.startTime }
    }

    private func updateEnd(of item: AdjacentItem, to end: Date) -> Set<Date> {
        guard end > item.startTime.addingTimeInterval(minimumDuration(for: item)) else { return [] }
        let oldEnd = item.endTime
        switch item {
        case .footprint(let record):
            record.endTime = end
            record.status = .manual
        case .transport(let record):
            record.updateTimeRangePreservingRoute(start: record.startTime, end: end)
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
        }
        return touchedDates(start: min(oldEnd, end), end: max(oldEnd, end))
    }

    private func updateStart(of item: AdjacentItem, to start: Date) -> Set<Date> {
        guard item.endTime > start.addingTimeInterval(minimumDuration(for: item)) else { return [] }
        let oldStart = item.startTime
        switch item {
        case .footprint(let record):
            record.startTime = start
            record.date = Calendar.current.startOfDay(for: start)
            record.status = .manual
        case .transport(let record):
            record.updateTimeRangePreservingRoute(start: start, end: record.endTime)
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
        }
        return touchedDates(start: min(oldStart, start), end: max(oldStart, start))
    }

    private func minimumDuration(for item: AdjacentItem) -> TimeInterval {
        switch item {
        case .footprint:
            max(60, ceil(AppConfig.shared.stayDurationThreshold / 60) * 60)
        case .transport:
            minimumDuration
        }
    }

    private func invalidateCaches(oldStart: Date, oldEnd: Date, newStart: Date, newEnd: Date, additionalDates: Set<Date>) {
        for date in touchedDates(start: oldStart, end: oldEnd)
            .union(touchedDates(start: newStart, end: newEnd))
            .union(additionalDates) {
            TimelineBuilder.timelineCache.removeValue(forKey: date)
        }
    }

    private func touchedDates(start: Date, end: Date) -> Set<Date> {
        let calendar = Calendar.current
        var dates: Set<Date> = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end.addingTimeInterval(-0.001)))
        while cursor <= last {
            dates.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    private func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded())
    }

    private func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}
