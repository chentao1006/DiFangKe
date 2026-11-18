import AVFoundation
import AVKit
import CoreImage
import MapKit
import SwiftUI
import UIKit

enum RouteVideoCameraMode: String, CaseIterable, Identifiable, Sendable {
    case overview
    case follow
    case cinematic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "固定全景"
        case .follow: return "动态跟随"
        case .cinematic: return "分段运镜"
        }
    }
}

enum RouteVideoAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape
    case square

    var id: String { rawValue }
    var title: String {
        switch self {
        case .portrait: return "竖屏 9:16"
        case .landscape: return "横屏 16:9"
        case .square: return "方形 1:1"
        }
    }

    var value: CGFloat {
        switch self {
        case .portrait: return 9.0 / 16.0
        case .landscape: return 16.0 / 9.0
        case .square: return 1
        }
    }
}

enum RouteVideoTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// The option preselected for the app's current appearance.
    static func matching(_ colorScheme: ColorScheme) -> RouteVideoTheme {
        colorScheme == .dark ? .dark : .light
    }

    var resolved: RouteVideoResolvedTheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum RouteVideoResolvedTheme: Sendable, Equatable {
    case light
    case dark
}

struct RouteVideoExportRequest: Sendable {
    let cameraMode: RouteVideoCameraMode
    let aspectRatio: RouteVideoAspectRatio
    let theme: RouteVideoResolvedTheme
}

struct RouteVideoHeader: Sendable {
    let title: String
    let notes: String
}

enum RouteVideoExportSource: @unchecked Sendable {
    case day(
        DayRoutePlayback,
        followsPlayback: Bool,
        videoHeader: RouteVideoHeader? = nil
    )
    case transport(
        TransportRouteAnimation,
        segments: [TransportLineSegment],
        symbolName: String,
        followsPlayback: Bool
    )
}

private extension RouteVideoExportSource {
    var defaultCameraMode: RouteVideoCameraMode {
        switch self {
        case let .day(_, followsPlayback, _), let .transport(_, _, _, followsPlayback):
            return followsPlayback ? .follow : .overview
        }
    }
}

private struct RouteVideoFrame: @unchecked Sendable {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let symbolName: String
    let travelsWest: Bool
    let isStop: Bool
    let activeRouteIndex: Int?
    let stopIndex: Int?
    let activityColorHex: String?
    let timeText: String
    let completedStopCount: Int
    let highlightedSegments: [TransportLineSegment]
    let contextLabel: String?
    let contextDetail: String?
}

private struct RouteVideoInput: @unchecked Sendable {
    let dayPlayback: DayRoutePlayback?
    let segments: [TransportLineSegment]
    let stops: [DayRoutePlaybackStopMarker]
    let routeCoordinates: [[CLLocationCoordinate2D]]
    let frames: [RouteVideoFrame]
    let frameInterval: TimeInterval
    let endPause: TimeInterval
    let videoHeader: RouteVideoHeader?

    static func make(from source: RouteVideoExportSource) async -> RouteVideoInput {
        await Task.detached(priority: .userInitiated) {
            switch source {
            case let .day(playback, _, videoHeader):
                let timeFormatter = DateFormatter()
                timeFormatter.locale = .current
                timeFormatter.timeZone = .current
                timeFormatter.dateFormat = "HH:mm"
                let frames = playback.frames.map { frame in
                    RouteVideoFrame(
                        coordinate: frame.coordinate,
                        timestamp: frame.timestamp,
                        symbolName: frame.symbolName,
                        travelsWest: frame.travelsWest,
                        isStop: frame.isStop,
                        activeRouteIndex: frame.activeRouteIndex,
                        stopIndex: frame.stopIndex,
                        activityColorHex: frame.activityColorHex,
                        timeText: timeFormatter.string(from: frame.timestamp),
                        completedStopCount: frame.completedStopCount,
                        highlightedSegments: []
                        ,contextLabel: frame.contextLabel
                        ,contextDetail: frame.contextDetail
                    )
                }
                return RouteVideoInput(
                    dayPlayback: playback,
                    segments: playback.routeSegments,
                    stops: playback.stopMarkers,
                    routeCoordinates: playback.routeGeometries.map(\.coordinates),
                    frames: frames,
                    frameInterval: playback.frameInterval,
                    endPause: playback.endPause,
                    videoHeader: videoHeader
                )
            case let .transport(animation, segments, symbolName, _):
                let frames = animation.frames.map { frame in
                    RouteVideoFrame(
                        coordinate: frame.coordinate,
                        timestamp: frame.timestamp,
                        symbolName: symbolName,
                        travelsWest: frame.travelsWest,
                        isStop: false,
                        activeRouteIndex: 0,
                        stopIndex: nil,
                        activityColorHex: nil,
                        timeText: frame.timeText,
                        completedStopCount: 0,
                        highlightedSegments: frame.highlightedSegments
                        ,contextLabel: nil
                        ,contextDetail: nil
                    )
                }
                return RouteVideoInput(
                    dayPlayback: nil,
                    segments: segments,
                    stops: [],
                    routeCoordinates: [segments.flatMap(\.coordinates)],
                    frames: frames,
                    frameInterval: animation.frameInterval,
                    endPause: animation.endPause,
                    videoHeader: nil
                )
            }
        }.value
    }

    /// Consecutive frames on the same route or at the same stop form one
    /// camera shot, matching the in-app playback's per-route/per-stop framing.
    nonisolated static func shotRanges(for frames: [RouteVideoFrame]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var shotStart = 0
        while shotStart < frames.count {
            var shotEnd = shotStart + 1
            while shotEnd < frames.count,
                  frames[shotEnd].isStop == frames[shotStart].isStop,
                  frames[shotEnd].activeRouteIndex == frames[shotStart].activeRouteIndex,
                  frames[shotEnd].stopIndex == frames[shotStart].stopIndex {
                shotEnd += 1
            }
            ranges.append(shotStart..<shotEnd)
            shotStart = shotEnd
        }
        return ranges
    }
}

/// A video camera in Web Mercator map points. Rendering projects every map
/// layer, route and marker through the same camera, so zoom is not limited by
/// the resolution of a single overview snapshot.
private struct RouteVideoCamera: @unchecked Sendable {
    var center: MKMapPoint
    var mapPointsPerPixel: Double

    func visibleRect(in size: CGSize) -> MKMapRect {
        let width = Double(size.width) * mapPointsPerPixel
        let height = Double(size.height) * mapPointsPerPixel
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    func project(_ point: MKMapPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - center.x) / mapPointsPerPixel + Double(size.width) / 2,
            y: (point.y - center.y) / mapPointsPerPixel + Double(size.height) / 2
        )
    }

    func project(_ rect: MKMapRect, in size: CGSize) -> CGRect {
        let origin = project(rect.origin, in: size)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width / mapPointsPerPixel,
            height: rect.height / mapPointsPerPixel
        )
    }

    /// Centers move linearly; zoom changes geometrically so a street-level
    /// stop and a city-wide route blend at a perceptually even pace.
    static func interpolated(_ start: RouteVideoCamera, _ end: RouteVideoCamera, _ fraction: Double) -> RouteVideoCamera {
        let startZoom = log(start.mapPointsPerPixel)
        let endZoom = log(end.mapPointsPerPixel)
        return RouteVideoCamera(
            center: MKMapPoint(
                x: start.center.x + (end.center.x - start.center.x) * fraction,
                y: start.center.y + (end.center.y - start.center.y) * fraction
            ),
            mapPointsPerPixel: exp(startZoom + (endZoom - startZoom) * fraction)
        )
    }
}

private struct RouteVideoCameraShot: @unchecked Sendable {
    let mapPointsPerPixel: Double
    /// Area this shot's own camera visits, rendered at the shot's zoom.
    let snapshotRect: MKMapRect
}

private struct RouteVideoCameraPlan: @unchecked Sendable {
    let cameras: [RouteVideoCamera]
    let shots: [RouteVideoCameraShot]
    let shotIndexByFrame: [Int]

    /// Follow and cinematic modes reuse the in-app playback framing: each
    /// route is fitted (and, when following, tightened by the configured span
    /// ratio around the moving marker) and each stop gets the street-level
    /// stop framing. Neighbouring shots blend over the configured transition.
    nonisolated static func make(
        input: RouteVideoInput,
        mode: RouteVideoCameraMode,
        layout: DayRoutePlaybackCameraLayout,
        overview: RouteVideoCamera
    ) -> RouteVideoCameraPlan {
        let frames = input.frames
        guard mode != .overview, !frames.isEmpty else {
            return RouteVideoCameraPlan(
                cameras: Array(repeating: overview, count: frames.count),
                shots: [],
                shotIndexByFrame: []
            )
        }
        let size = layout.viewport
        let ranges = RouteVideoInput.shotRanges(for: frames)
        var shotIndexByFrame = Array(repeating: 0, count: frames.count)
        // Place a followed marker at the middle of the visible area.
        let followOffsetX = Double(size.width / 2 - layout.visibleRect.midX)
        let followOffsetY = Double(size.height / 2 - layout.visibleRect.midY)

        struct Framing {
            let mapPointsPerPixel: Double
            let fixedCenter: MKMapPoint?
        }
        var framings: [Framing] = []
        for (shotIndex, range) in ranges.enumerated() {
            for index in range { shotIndexByFrame[index] = shotIndex }
            let first = frames[range.lowerBound]
            let rect: MKMapRect?
            if first.isStop {
                rect = DayRoutePlaybackCameraFraming.stopMapRect(coordinate: first.coordinate, layout: layout)
            } else {
                let coordinates: [CLLocationCoordinate2D]
                if let routeIndex = first.activeRouteIndex,
                   input.routeCoordinates.indices.contains(routeIndex),
                   input.routeCoordinates[routeIndex].count >= 2 {
                    coordinates = input.routeCoordinates[routeIndex]
                } else {
                    coordinates = frames[range].map(\.coordinate)
                }
                rect = DayRoutePlaybackCameraFraming.transportMapRect(
                    coordinates: coordinates,
                    layout: layout,
                    isFollowing: mode == .follow
                )
            }
            guard let rect, rect.width > 0, size.width > 0 else {
                framings.append(framings.last ?? Framing(
                    mapPointsPerPixel: overview.mapPointsPerPixel,
                    fixedCenter: overview.center
                ))
                continue
            }
            framings.append(Framing(
                mapPointsPerPixel: rect.width / Double(size.width),
                fixedCenter: (first.isStop || mode == .cinematic)
                    ? MKMapPoint(x: rect.midX, y: rect.midY)
                    : nil
            ))
        }

        func camera(shot: Int, frame: Int) -> RouteVideoCamera {
            let framing = framings[shot]
            if let center = framing.fixedCenter {
                return RouteVideoCamera(center: center, mapPointsPerPixel: framing.mapPointsPerPixel)
            }
            let marker = MKMapPoint(frames[frame].coordinate)
            return RouteVideoCamera(
                center: MKMapPoint(
                    x: marker.x + followOffsetX * framing.mapPointsPerPixel,
                    y: marker.y + followOffsetY * framing.mapPointsPerPixel
                ),
                mapPointsPerPixel: framing.mapPointsPerPixel
            )
        }

        var cameras = frames.indices.map { camera(shot: shotIndexByFrame[$0], frame: $0) }
        let shots = ranges.enumerated().map { shotIndex, range -> RouteVideoCameraShot in
            var rect = MKMapRect.null
            for index in range {
                rect = rect.union(camera(shot: shotIndex, frame: index).visibleRect(in: size))
            }
            return RouteVideoCameraShot(
                mapPointsPerPixel: framings[shotIndex].mapPointsPerPixel,
                snapshotRect: rect
            )
        }

        let frameInterval = max(input.frameInterval, 1.0 / 30.0)
        let transitionFrameCount = max(Int((
            max(AppConfig.shared.routeVideoExportCinematicTransitionDuration, input.frameInterval) / frameInterval
        ).rounded()), 1)
        for shotIndex in ranges.indices.dropFirst() {
            let previous = ranges[shotIndex - 1]
            let current = ranges[shotIndex]
            // Keep each blend inside the two shots it joins, so consecutive
            // transitions never overlap and the camera path stays continuous.
            let start = max(current.lowerBound - transitionFrameCount / 2, previous.lowerBound + previous.count / 2)
            let end = min(current.lowerBound + transitionFrameCount / 2, current.lowerBound + (current.count - 1) / 2)
            guard end > start else { continue }
            for index in start...end {
                let fraction = Double(index - start) / Double(end - start)
                let eased = fraction * fraction * (3 - 2 * fraction)
                cameras[index] = .interpolated(
                    camera(shot: shotIndex - 1, frame: index),
                    camera(shot: shotIndex, frame: index),
                    eased
                )
            }
        }
        return RouteVideoCameraPlan(cameras: cameras, shots: shots, shotIndexByFrame: shotIndexByFrame)
    }
}

enum RouteVideoExportError: LocalizedError {
    case noFrames
    case mapUnavailable
    case writerUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "没有可导出的路线动画。"
        case .mapUnavailable: return "暂时无法生成地图，请稍后重试。"
        case .writerUnavailable: return "无法创建视频文件。"
        case .encodingFailed: return "视频生成失败，请确认设备有足够的可用空间。"
        }
    }
}

@MainActor
final class RouteVideoExportState: ObservableObject {
    @Published var isExporting = false
    @Published var progress = 0.0
    @Published var status = "正在准备路线…"
    @Published var outputURL: URL?
    @Published var errorMessage: String?
    var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isExporting = false
    }

    func cleanup() {
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}

enum RouteVideoExporter {
    private struct MarkerVisualKey: Hashable {
        let symbolName: String
        let timeText: String
        let colorHex: String?
        let isStop: Bool
        let travelsWest: Bool
    }

    private struct HeaderVisualKey: Hashable {
        let day: String?
        let detail: String?
    }

    /// One rendered map image and the exact map-point rect it covers.
    private final class SnapshotLayer: @unchecked Sendable {
        let image: UIImage
        let rect: MKMapRect
        let mapPointsPerPixel: Double

        init(image: UIImage, rect: MKMapRect) {
            self.image = image
            self.rect = rect
            self.mapPointsPerPixel = rect.width / max(Double(image.size.width), 1)
        }
    }

    private final class Assets: @unchecked Sendable {
        let overviewLayer: SnapshotLayer
        let markerImages: [Int: UIImage]
        let stopMarkerImages: [String: UIImage]
        let brandImage: UIImage
        let headerImages: [Int: UIImage]

        init(
            overviewLayer: SnapshotLayer,
            markerImages: [Int: UIImage],
            stopMarkerImages: [String: UIImage],
            brandImage: UIImage,
            headerImages: [Int: UIImage]
        ) {
            self.overviewLayer = overviewLayer
            self.markerImages = markerImages
            self.stopMarkerImages = stopMarkerImages
            self.brandImage = brandImage
            self.headerImages = headerImages
        }
    }

    static func export(
        source: RouteVideoExportSource,
        request: RouteVideoExportRequest,
        state: RouteVideoExportState
    ) async throws -> URL {
        let input = await RouteVideoInput.make(from: source)
        guard input.frames.count >= 2 else { throw RouteVideoExportError.noFrames }
        let coordinates = input.segments.flatMap(\.coordinates)
        let config = AppConfig.shared
        let paddingRatio = request.cameraMode == .overview
            ? config.routeVideoExportOverviewPaddingRatio
            : config.routeVideoExportRegionPaddingRatio
        guard let region = region(for: coordinates, paddingRatio: paddingRatio) else {
            throw RouteVideoExportError.noFrames
        }
        await MainActor.run {
            state.progress = 0.03
            state.status = "正在生成地图…"
        }

        let outputSize = exportSize(for: request.aspectRatio)
        let overviewOptions = snapshotOptions(theme: request.theme)
        overviewOptions.region = region
        overviewOptions.size = outputSize
        overviewOptions.scale = max(config.routeVideoExportMapSnapshotScale, 1)
        let overviewLayer: SnapshotLayer
        do {
            overviewLayer = try await snapshotLayer(options: overviewOptions, calibrationRect: mapRect(for: region))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RouteVideoExportError.mapUnavailable
        }
        try Task.checkCancellation()
        let markerImages = await MainActor.run {
            var result: [Int: UIImage] = [:]
            var cache: [MarkerVisualKey: UIImage] = [:]
            let markerScale = CGFloat(max(AppConfig.shared.routeVideoExportMarkerScale, 1))
            // The shared stop marker already applies its own 1.5x display
            // scale. Size the transparent bitmap from the export scale so its
            // teardrop, shadow and time badge are never clipped.
            let canvasSize = max(CGFloat(180), (80 * markerScale).rounded(.up))
            for (index, frame) in input.frames.enumerated() {
                let key = MarkerVisualKey(
                    symbolName: frame.symbolName,
                    timeText: frame.timeText,
                    colorHex: frame.activityColorHex,
                    isStop: frame.isStop,
                    travelsWest: frame.travelsWest
                )
                if let image = cache[key] {
                    result[index] = image
                    continue
                }
                let overlay = DFKMapPlaybackOverlay(
                    coordinate: frame.coordinate,
                    symbolName: frame.symbolName,
                    timeText: frame.timeText,
                    markerColor: frame.activityColorHex.flatMap { Color(hex: $0) } ?? .dfkAccent,
                    isStop: frame.isStop,
                    isMarkerHidden: false,
                    travelsWest: frame.travelsWest,
                    highlightedSegments: [],
                    stopMarkers: [],
                    revealedStopCount: 0
                )
                let renderer = ImageRenderer(
                    content: DFKMapPlaybackMarker(playbackOverlay: overlay)
                        .environment(\.colorScheme, request.theme == .dark ? .dark : .light)
                        .scaleEffect(markerScale)
                        .frame(width: canvasSize, height: canvasSize)
                )
                renderer.proposedSize = ProposedViewSize(width: canvasSize, height: canvasSize)
                renderer.scale = 2
                if let image = renderer.uiImage {
                    cache[key] = image
                    result[index] = image
                }
            }
            return result
        }
        let stopMarkerImages = await MainActor.run {
            var result: [String: UIImage] = [:]
            let markerScale = CGFloat(max(AppConfig.shared.routeVideoExportMarkerScale, 1))
            let canvasSize = max(CGFloat(180), (80 * markerScale).rounded(.up))
            for marker in input.stops {
                let constantScale: CGFloat = 1.32
                let size: CGFloat = 25 * constantScale
                let usesLargeMissingActivitySymbol = marker.symbolName == FootprintIconDefaults.card
                let iconSize: CGFloat = (usesLargeMissingActivitySymbol ? 18 : 10) * constantScale
                let totalMinutes = Int(marker.duration / 60)
                let durationTuple: (number: String, unit: String)
                if totalMinutes < 60 {
                    durationTuple = ("\(max(1, totalMinutes))", "分钟")
                } else {
                    let hours = Double(totalMinutes) / 60
                    durationTuple = hours >= 10
                        ? ("\(Int(round(hours)))", "小时")
                        : (String(format: "%g", (hours * 10).rounded() / 10), "小时")
                }
                let view = DFKFootprintMapMarker(
                    size: size,
                    constantScale: constantScale,
                    activityColor: marker.colorHex.flatMap { Color(hex: $0) } ?? .gray,
                    iconColor: .white,
                    iconName: marker.symbolName,
                    iconSize: iconSize,
                    photoImage: nil,
                    durationTuple: marker.duration >= AppConfig.shared.stayDurationThreshold ? durationTuple : nil,
                    fontSize: 6.5 * constantScale
                )
                .environment(\.colorScheme, request.theme == .dark ? .dark : .light)
                .scaleEffect(markerScale, anchor: .bottom)
                .frame(width: canvasSize, height: canvasSize, alignment: .bottom)
                let renderer = ImageRenderer(content: view)
                renderer.proposedSize = ProposedViewSize(width: canvasSize, height: canvasSize)
                renderer.scale = 2
                if let image = renderer.uiImage { result[marker.id] = image }
            }
            return result
        }
        let brandImage = await MainActor.run {
            let scale = outputSize.width / 1080
            let view = DFKShareBrandIdentity(
                brandName: "地方客",
                brandSlogan: "走过的地方，就是你的生活",
                logoSize: 90 * scale,
                logoCornerRadius: 21 * scale,
                nameFont: .system(size: 39 * scale, weight: .semibold),
                sloganFont: .system(size: 30 * scale),
                foreground: .primary,
                secondary: .secondary,
                spacing: 30 * scale,
                textSpacing: 3 * scale
            )
            .padding(.horizontal, 24 * scale)
            .padding(.vertical, 18 * scale)
            .background(
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(0.82))
            )
            .environment(\.colorScheme, request.theme == .dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return renderer.uiImage ?? UIImage()
        }
        let headerImages = await MainActor.run {
            guard let header = input.videoHeader else { return [Int: UIImage]() }
            var cache: [HeaderVisualKey: UIImage] = [:]
            var result: [Int: UIImage] = [:]
            let horizontalPadding = max(outputSize.width / 30, 16)
            let contentWidth = outputSize.width - horizontalPadding * 2
            for (index, frame) in input.frames.enumerated() {
                let key = HeaderVisualKey(day: frame.contextLabel, detail: frame.contextDetail)
                if let image = cache[key] {
                    result[index] = image
                    continue
                }
                let view = RouteVideoTripHeaderView(
                    title: header.title,
                    tripNotes: header.notes,
                    dayText: frame.contextLabel,
                    detailText: frame.contextDetail
                )
                .frame(width: contentWidth, alignment: .leading)
                .environment(\.colorScheme, request.theme == .dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
                renderer.scale = 1
                if let image = renderer.uiImage {
                    cache[key] = image
                    result[index] = image
                }
            }
            return result
        }
        let cameraLayout = cameraLayout(
            size: outputSize,
            headerHeight: headerImages.values.map(\.size.height).max() ?? 0,
            brandHeight: brandImage.size.height
        )
        let overviewCamera = RouteVideoCamera(
            center: MKMapPoint(x: overviewLayer.rect.midX, y: overviewLayer.rect.midY),
            mapPointsPerPixel: max(
                overviewLayer.rect.width / Double(outputSize.width),
                overviewLayer.rect.height / Double(outputSize.height)
            )
        )
        let cameraMode = request.cameraMode
        let plan = await Task.detached(priority: .userInitiated) {
            RouteVideoCameraPlan.make(
                input: input,
                mode: cameraMode,
                layout: cameraLayout,
                overview: overviewCamera
            )
        }.value
        let assets = Assets(
            overviewLayer: overviewLayer,
            markerImages: markerImages,
            stopMarkerImages: stopMarkerImages,
            brandImage: brandImage,
            headerImages: headerImages
        )
        return try await Task.detached(priority: .userInitiated) {
            try await encode(input: input, request: request, assets: assets, plan: plan, state: state)
        }.value
    }

    private nonisolated static func exportSize(for aspectRatio: RouteVideoAspectRatio) -> CGSize {
        let config = AppConfig.shared
        let shortEdge = CGFloat(max(config.routeVideoExportWidth, 1))
        let longEdge = CGFloat(max(config.routeVideoExportHeight, 1))
        switch aspectRatio {
        case .portrait: return CGSize(width: shortEdge, height: longEdge)
        case .landscape: return CGSize(width: longEdge, height: shortEdge)
        case .square: return CGSize(width: shortEdge, height: shortEdge)
        }
    }

    private nonisolated static func region(
        for coordinates: [CLLocationCoordinate2D],
        paddingRatio: Double
    ) -> MKCoordinateRegion? {
        let valid = coordinates.filter { $0.isRenderableMapCoordinate }
        guard let first = valid.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
        for coordinate in valid.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        let minimumPadding: Double = 2_000
        let paddingRatio = max(paddingRatio, 0)
        return MKCoordinateRegion(rect.insetBy(
            dx: -max(rect.width * paddingRatio, minimumPadding),
            dy: -max(rect.height * paddingRatio, minimumPadding)
        ))
    }


    private nonisolated static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// The video counterpart of the in-app playback layout: the framed route or
    /// stop stays clear of the trip header and the brand badge.
    private nonisolated static func cameraLayout(
        size: CGSize,
        headerHeight: CGFloat,
        brandHeight: CGFloat
    ) -> DayRoutePlaybackCameraLayout {
        let horizontalInset = size.width * 0.08
        let headerBottom = headerHeight > 0 ? max(size.width / 30, 16) + headerHeight : 0
        let topInset = max(size.height * 0.10, headerBottom)
        let bottomInset = max(size.height * 0.10, brandHeight + max(size.width / 45, 12))
        let visibleHeight = max(size.height - topInset - bottomInset, size.height * 0.25)
        return DayRoutePlaybackCameraLayout(
            viewport: size,
            visibleRect: CGRect(
                x: horizontalInset,
                y: topInset,
                width: size.width - horizontalInset * 2,
                height: visibleHeight
            )
        )
    }

    private nonisolated static func snapshotOptions(theme: RouteVideoResolvedTheme) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapType = .mutedStandard
        options.showsBuildings = true
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: theme == .dark ? .dark : .light
        )
        return options
    }

    /// Measures the rect the snapshotter actually rendered (it may adjust the
    /// requested area to the image aspect) from two known map points.
    private nonisolated static func snapshotLayer(
        options: MKMapSnapshotter.Options,
        calibrationRect: MKMapRect
    ) async throws -> SnapshotLayer {
        let snapshot = try await MKMapSnapshotter(options: options).start()
        let first = MKMapPoint(x: calibrationRect.minX, y: calibrationRect.minY)
        let second = MKMapPoint(x: calibrationRect.maxX, y: calibrationRect.maxY)
        let firstPoint = snapshot.point(for: first.coordinate)
        let secondPoint = snapshot.point(for: second.coordinate)
        let dx = Double(secondPoint.x - firstPoint.x)
        let dy = Double(secondPoint.y - firstPoint.y)
        guard dx > 0, dy > 0 else { throw RouteVideoExportError.mapUnavailable }
        let xScale = (second.x - first.x) / dx
        let yScale = (second.y - first.y) / dy
        let imageSize = snapshot.image.size
        return SnapshotLayer(
            image: snapshot.image,
            rect: MKMapRect(
                x: first.x - Double(firstPoint.x) * xScale,
                y: first.y - Double(firstPoint.y) * yScale,
                width: Double(imageSize.width) * xScale,
                height: Double(imageSize.height) * yScale
            )
        )
    }

    /// A shot's own map, rendered at the zoom its camera uses, so street-level
    /// stops and short walks stay sharp instead of magnifying the overview.
    private nonisolated static func shotLayer(
        _ shot: RouteVideoCameraShot,
        theme: RouteVideoResolvedTheme
    ) async throws -> SnapshotLayer {
        let rect = shot.snapshotRect
        guard !rect.isNull, rect.width > 0, rect.height > 0, shot.mapPointsPerPixel > 0 else {
            throw RouteVideoExportError.mapUnavailable
        }
        var size = CGSize(
            width: rect.width / shot.mapPointsPerPixel,
            height: rect.height / shot.mapPointsPerPixel
        )
        let maxEdge = CGFloat(max(AppConfig.shared.routeVideoExportShotSnapshotMaxEdge, 1))
        let longestEdge = max(size.width, size.height)
        if longestEdge > maxEdge {
            size = CGSize(width: size.width * maxEdge / longestEdge, height: size.height * maxEdge / longestEdge)
        }
        let options = snapshotOptions(theme: theme)
        options.mapRect = rect
        options.size = CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))
        options.scale = 1
        return try await snapshotLayer(options: options, calibrationRect: rect)
    }

    private nonisolated static func encode(
        input: RouteVideoInput,
        request: RouteVideoExportRequest,
        assets: Assets,
        plan: RouteVideoCameraPlan,
        state: RouteVideoExportState
    ) async throws -> URL {
        let config = AppConfig.shared
        let size = exportSize(for: request.aspectRatio)
        let fps = max(config.routeVideoExportFrameRate, 1)
        let sourceDuration = Double(input.frames.count - 1) * max(input.frameInterval, 1.0 / 30.0)
        let frameCount = max(2, Int(((sourceDuration + input.endPause) * Double(fps)).rounded(.up)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("difangke-route-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw RouteVideoExportError.writerUnavailable
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(config.routeVideoExportBitRate, 1),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(writerInput) else { throw RouteVideoExportError.writerUnavailable }
        writer.add(writerInput)
        guard writer.startWriting() else { throw writer.error ?? RouteVideoExportError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [
            .workingColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        var cachedLeadingIndex = -1
        var cachedHighlightedSegments: [TransportLineSegment] = []
        // Only the current shot and its neighbours can be on screen (a
        // transition joins two adjacent shots), so at most three shot maps
        // are kept in memory at once.
        var shotLayers: [Int: SnapshotLayer] = [:]
        var unavailableShots = Set<Int>()

        for outputIndex in 0..<frameCount {
            if Task.isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            let videoTime = min(Double(outputIndex) / Double(fps), sourceDuration)
            let sourcePosition = videoTime / max(input.frameInterval, 1.0 / 30.0)
            let leadingIndex = min(Int(sourcePosition), input.frames.count - 1)
            let trailingIndex = min(leadingIndex + 1, input.frames.count - 1)
            let interpolation = min(max(sourcePosition - Double(leadingIndex), 0), 1)
            if cachedLeadingIndex != leadingIndex {
                cachedLeadingIndex = leadingIndex
                cachedHighlightedSegments = input.dayPlayback?.highlightedSegments(at: leadingIndex)
                    ?? input.frames[leadingIndex].highlightedSegments
            }
            if plan.shotIndexByFrame.indices.contains(leadingIndex) {
                let shotIndex = plan.shotIndexByFrame[leadingIndex]
                let needed = max(0, shotIndex - 1)...min(plan.shots.count - 1, shotIndex + 1)
                for key in shotLayers.keys where !needed.contains(key) {
                    shotLayers[key] = nil
                }
                for key in needed where shotLayers[key] == nil && !unavailableShots.contains(key) {
                    if let layer = try? await shotLayer(plan.shots[key], theme: request.theme) {
                        shotLayers[key] = layer
                    } else {
                        // The overview layer still covers this shot.
                        unavailableShots.insert(key)
                    }
                }
            }
            let camera = RouteVideoCamera.interpolated(
                plan.cameras[leadingIndex],
                plan.cameras[trailingIndex],
                interpolation
            )
            let layers = [assets.overviewLayer] + shotLayers.values
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw RouteVideoExportError.encodingFailed
            }
            let presentationTime = CMTime(value: CMTimeValue(outputIndex), timescale: CMTimeScale(fps))
            let appended = autoreleasepool { () -> Bool in
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pixelBuffer,
                      let image = renderFrame(
                        input: input,
                        assets: assets,
                        layers: layers,
                        camera: camera,
                        highlightedSegments: cachedHighlightedSegments,
                        theme: request.theme,
                        leadingIndex: leadingIndex,
                        trailingIndex: trailingIndex,
                        interpolation: interpolation,
                        size: size
                      ).cgImage else { return false }
                ciContext.render(
                    CIImage(cgImage: image),
                    to: pixelBuffer,
                    bounds: CGRect(origin: .zero, size: size),
                    colorSpace: colorSpace
                )
                return adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            }
            guard appended else {
                writer.cancelWriting()
                throw writer.error ?? RouteVideoExportError.encodingFailed
            }
            if outputIndex % fps == 0 { ciContext.clearCaches() }
            if outputIndex % 15 == 0 {
                let progress = 0.08 + 0.9 * Double(outputIndex) / Double(frameCount)
                Task { @MainActor in
                    state.progress = progress
                    state.status = "正在生成视频 \(Int(progress * 100))%"
                }
            }
        }
        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? RouteVideoExportError.encodingFailed
        }
        return url
    }

    private nonisolated static func renderFrame(
        input: RouteVideoInput,
        assets: Assets,
        layers: [SnapshotLayer],
        camera: RouteVideoCamera,
        highlightedSegments: [TransportLineSegment],
        theme: RouteVideoResolvedTheme,
        leadingIndex: Int,
        trailingIndex: Int,
        interpolation: Double,
        size: CGSize
    ) -> UIImage {
        let leading = input.frames[leadingIndex]
        let trailing = input.frames[trailingIndex]
        let coordinate = interpolatedCoordinate(leading.coordinate, trailing.coordinate, interpolation)
        let project: (CLLocationCoordinate2D) -> CGPoint = {
            camera.project(MKMapPoint($0), in: size)
        }
        // Draw coarse maps first and sharper ones over them, like map tiles.
        // A map rendered for a much closer zoom is skipped while the camera
        // is far out, so street-level labels never appear as a tiny patch.
        let maxDownscale = max(AppConfig.shared.routeVideoExportShotSnapshotMaxDownscale, 1)
        let visibleRect = camera.visibleRect(in: size)
        let drawnLayers = layers.filter { layer in
            layer === assets.overviewLayer ||
                (layer.rect.intersects(visibleRect) &&
                 layer.mapPointsPerPixel * maxDownscale >= camera.mapPointsPerPixel)
        }.sorted { $0.mapPointsPerPixel > $1.mapPointsPerPixel }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let routeLineScale = CGFloat(max(AppConfig.shared.routeVideoExportRouteLineScale, 1))
            context.setFillColor((theme == .dark ? UIColor.black : UIColor.white).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            for layer in drawnLayers {
                layer.image.draw(in: camera.project(layer.rect, in: size))
            }
            drawSegments(
                input.segments,
                project: project,
                color: UIColor(Color.dfkAccent).withAlphaComponent(0.24),
                isHighlighted: false,
                lineScale: routeLineScale,
                in: context
            )
            drawSegments(
                highlightedSegments,
                project: project,
                color: UIColor(Color.dfkAccent),
                isHighlighted: true,
                lineScale: routeLineScale,
                in: context
            )
            drawStops(
                input.stops,
                count: leading.completedStopCount,
                images: assets.stopMarkerImages,
                project: project
            )
            let markerPoint = project(coordinate)
            if let marker = assets.markerImages[leadingIndex] {
                let markerSize = marker.size
                marker.draw(at: CGPoint(
                    x: markerPoint.x - markerSize.width / 2,
                    y: markerPoint.y - markerSize.height / 2 - (leading.isStop ? 18 : 0)
                ))
            }
            let brandPadding = max(size.width / 45, 12)
            assets.brandImage.draw(at: CGPoint(
                x: size.width - assets.brandImage.size.width - brandPadding,
                y: size.height - assets.brandImage.size.height - brandPadding
            ))
            if let headerImage = assets.headerImages[leadingIndex] {
                let headerPadding = max(size.width / 30, 16)
                headerImage.draw(at: CGPoint(x: headerPadding, y: headerPadding))
            }
        }
    }

    private nonisolated static func interpolatedCoordinate(
        _ start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D,
        _ fraction: Double
    ) -> CLLocationCoordinate2D {
        var longitudeDelta = end.longitude - start.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + longitudeDelta * fraction
        )
    }

    private nonisolated static func drawSegments(
        _ segments: [TransportLineSegment],
        project: (CLLocationCoordinate2D) -> CGPoint,
        color: UIColor,
        isHighlighted: Bool,
        lineScale: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for segment in segments where segment.coordinates.count >= 2 {
            let baseWidth: CGFloat = segment.isDashed
                ? (isHighlighted ? 1.5 : 1.3)
                : (isHighlighted ? 4 : 3)
            context.setLineWidth(baseWidth * lineScale)
            context.setLineDash(
                phase: 0,
                lengths: segment.isDashed ? [5 * lineScale, 5 * lineScale] : []
            )
            context.beginPath()
            context.move(to: project(segment.coordinates[0]))
            for coordinate in segment.coordinates.dropFirst() {
                context.addLine(to: project(coordinate))
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private nonisolated static func drawStops(
        _ stops: [DayRoutePlaybackStopMarker],
        count: Int,
        images: [String: UIImage],
        project: (CLLocationCoordinate2D) -> CGPoint
    ) {
        for stop in stops.prefix(max(count, 0)) {
            let point = project(stop.coordinate)
            guard let image = images[stop.id] else { continue }
            image.draw(at: CGPoint(
                x: point.x - image.size.width / 2,
                y: point.y - image.size.height
            ))
        }
    }

}
private struct RouteVideoTripHeaderView: View {
    let title: String
    let tripNotes: String
    let dayText: String?
    let detailText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(1)
            if !tripNotes.isEmpty {
                Text(tripNotes)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let dayText, !dayText.isEmpty {
                Text(dayText)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 2)
            }
            if let detailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(0.82))
        )
    }
}

struct RouteVideoExportPresentation: Identifiable {
    let id = UUID()
    let source: RouteVideoExportSource
}

extension View {
    func routeVideoExportSheet(
        item: Binding<RouteVideoExportPresentation?>,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { presentation in
            RouteVideoExportOptionsView(source: presentation.source)
                .background(.regularMaterial, ignoresSafeAreaEdges: .all)
                .presentationDetents([.large])
                .presentationBackground(.clear)
                .presentationBackgroundInteraction(.enabled)
        }
    }
}

struct RouteVideoExportButton: View {
    let source: RouteVideoExportSource
    let accessibilityLabel: String
    var onRequest: ((RouteVideoExportSource) -> Void)? = nil
    var onPresentationChanged: ((Bool) -> Void)? = nil

    @State private var presentation: RouteVideoExportPresentation?

    var body: some View {
        Button {
            onPresentationChanged?(true)
            if let onRequest {
                onRequest(source)
            } else {
                presentation = RouteVideoExportPresentation(source: source)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Color.dfkAccent)
        .accessibilityLabel(accessibilityLabel)
        .routeVideoExportSheet(item: $presentation) {
            onPresentationChanged?(false)
        }
    }
}

struct RouteVideoExportOptionsView: View {
    let source: RouteVideoExportSource

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var state = RouteVideoExportState()
    @State private var cameraMode: RouteVideoCameraMode
    @State private var aspectRatio: RouteVideoAspectRatio = .portrait
    /// nil until the user picks one; the current appearance is preselected.
    @State private var selectedTheme: RouteVideoTheme?

    private var theme: RouteVideoTheme {
        selectedTheme ?? .matching(colorScheme)
    }

    init(source: RouteVideoExportSource) {
        self.source = source
        _cameraMode = State(initialValue: source.defaultCameraMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("镜头") {
                    Picker("镜头方式", selection: $cameraMode) {
                        ForEach(RouteVideoCameraMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(state.isExporting)
                }

                Section("画幅") {
                    Picker("视频比例", selection: $aspectRatio) {
                        ForEach(RouteVideoAspectRatio.allCases) { ratio in
                            Text(ratio.title).tag(ratio)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.isExporting)
                }

                Section("主题") {
                    Picker("视频主题", selection: Binding(
                        get: { theme },
                        set: { selectedTheme = $0 }
                    )) {
                        ForEach(RouteVideoTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.isExporting)
                }

                Section {
                    if state.isExporting {
                        ProgressView(value: state.progress) {
                            Text(state.status)
                        }
                        Button("取消生成", role: .cancel) { state.cancel() }
                    } else {
                        Button {
                            beginExport()
                        } label: {
                            Text("生成视频")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .dfkPrimaryActionButtonStyle()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .navigationTitle("导出路线视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        state.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            // Match the existing share-card flow: the activity sheet is
            // presented from inside this card, keeping the card between the
            // system sheet and the timeline/navigation underneath it.
            .sheet(isPresented: Binding(
                get: { state.outputURL != nil },
                set: { if !$0 { state.cleanup() } }
            )) {
                if let outputURL = state.outputURL {
                    RouteVideoPreviewView(url: outputURL, aspectRatio: aspectRatio)
                        .presentationDetents([.large])
                        .presentationBackground(.clear)
                }
            }
            .alert("无法导出视频", isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(state.errorMessage ?? "未知错误")
            }
        }
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .interactiveDismissDisabled(state.isExporting)
        .onDisappear { state.cancel() }
    }

    private func beginExport() {
        state.isExporting = true
        state.progress = 0
        state.status = "正在准备路线…"
        let request = RouteVideoExportRequest(
            cameraMode: cameraMode,
            aspectRatio: aspectRatio,
            theme: theme.resolved
        )
        state.task = Task {
            do {
                let url = try await RouteVideoExporter.export(
                    source: source,
                    request: request,
                    state: state
                )
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    throw CancellationError()
                }
                state.outputURL = url
                state.isExporting = false
                state.task = nil
            } catch is CancellationError {
                state.isExporting = false
                state.task = nil
            } catch {
                state.isExporting = false
                state.task = nil
                state.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RouteVideoPreviewView: View {
    let url: URL
    let aspectRatio: RouteVideoAspectRatio

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var showingShareSheet = false

    init(url: URL, aspectRatio: RouteVideoAspectRatio) {
        self.url = url
        self.aspectRatio = aspectRatio
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color(uiColor: .systemBackground)
                    VideoPlayer(player: player)
                        .aspectRatio(aspectRatio.value, contentMode: .fit)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    player.pause()
                    showingShareSheet = true
                } label: {
                    Label("分享视频", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .dfkPrimaryActionButtonStyle()
                .padding(16)
                .background(.bar)
            }
            .navigationTitle("视频预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.pause()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ActivityView(activityItems: [url])
            }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .onReceive(NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
    }
}
