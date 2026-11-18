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
    case current
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: return "跟随当前"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    func resolved(for currentColorScheme: ColorScheme) -> RouteVideoResolvedTheme {
        switch self {
        case .current: return currentColorScheme == .dark ? .dark : .light
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
    let cinematicCameraCenters: [CLLocationCoordinate2D]
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
                    cinematicCameraCenters: cinematicCameraCenters(
                        for: frames,
                        routeCoordinates: playback.routeGeometries.map(\.coordinates),
                        frameInterval: playback.frameInterval
                    ),
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
                    cinematicCameraCenters: cinematicCameraCenters(
                        for: frames,
                        routeCoordinates: [segments.flatMap(\.coordinates)],
                        frameInterval: animation.frameInterval
                    ),
                    frameInterval: animation.frameInterval,
                    endPause: animation.endPause,
                    videoHeader: nil
                )
            }
        }.value
    }

    private nonisolated static func cinematicCameraCenters(
        for frames: [RouteVideoFrame],
        routeCoordinates: [[CLLocationCoordinate2D]],
        frameInterval: TimeInterval
    ) -> [CLLocationCoordinate2D] {
        guard !frames.isEmpty else { return [] }
        var centers = frames.map(\.coordinate)
        for shotRange in cinematicShotRanges(for: frames) {
            let firstFrame = frames[shotRange.lowerBound]
            let coordinates: [CLLocationCoordinate2D]
            if !firstFrame.isStop,
               let routeIndex = firstFrame.activeRouteIndex,
               routeCoordinates.indices.contains(routeIndex) {
                coordinates = routeCoordinates[routeIndex]
            } else {
                coordinates = frames[shotRange].map(\.coordinate)
            }
            let points = coordinates.map(MKMapPoint.init)
            let minX = points.map(\.x).min() ?? points[0].x
            let maxX = points.map(\.x).max() ?? points[0].x
            let minY = points.map(\.y).min() ?? points[0].y
            let maxY = points.map(\.y).max() ?? points[0].y
            let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2).coordinate
            for index in shotRange { centers[index] = center }
        }

        let transitionDuration = max(
            AppConfig.shared.routeVideoExportCinematicTransitionDuration,
            frameInterval
        )
        let transitionFrameCount = max(Int((transitionDuration / max(frameInterval, 1.0 / 30.0)).rounded()), 1)
        let stableCenters = centers
        for boundary in 1..<stableCenters.count
        where stableCenters[boundary - 1].latitude != stableCenters[boundary].latitude ||
              stableCenters[boundary - 1].longitude != stableCenters[boundary].longitude {
            let start = max(0, boundary - transitionFrameCount / 2)
            let end = min(stableCenters.count - 1, boundary + transitionFrameCount / 2)
            guard end > start else { continue }
            let startPoint = MKMapPoint(stableCenters[boundary - 1])
            let endPoint = MKMapPoint(stableCenters[boundary])
            for index in start...end {
                let fraction = Double(index - start) / Double(end - start)
                centers[index] = MKMapPoint(
                    x: startPoint.x + (endPoint.x - startPoint.x) * fraction,
                    y: startPoint.y + (endPoint.y - startPoint.y) * fraction
                ).coordinate
            }
        }
        return centers
    }

    private nonisolated static func cinematicShotRanges(
        for frames: [RouteVideoFrame]
    ) -> [Range<Int>] {
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

    nonisolated func cinematicCameraScales(
        snapshot: MKMapSnapshotter.Snapshot,
        outputSize: CGSize
    ) -> [CGFloat] {
        guard !frames.isEmpty else { return [] }
        let config = AppConfig.shared
        let markerScale = CGFloat(max(config.routeVideoExportMarkerScale, 1))
        let markerCanvas = max(CGFloat(180), (80 * markerScale).rounded(.up))
        let availableWidth = max(outputSize.width - markerCanvas, 1)
        let availableHeight = max(outputSize.height - markerCanvas, 1)
        let paddingMultiplier = CGFloat(1 + 2 * max(config.routeVideoExportCinematicPaddingRatio, 0))
        let ranges = Self.cinematicShotRanges(for: frames)
        var scales = Array(repeating: CGFloat(1), count: frames.count)

        for range in ranges {
            let scale: CGFloat
            if frames[range.lowerBound].isStop {
                scale = CGFloat(max(config.routeVideoExportCinematicStopScale, 1))
            } else {
                let firstFrame = frames[range.lowerBound]
                let coordinates: [CLLocationCoordinate2D]
                if let routeIndex = firstFrame.activeRouteIndex,
                   routeCoordinates.indices.contains(routeIndex) {
                    coordinates = routeCoordinates[routeIndex]
                } else {
                    coordinates = frames[range].map(\.coordinate)
                }
                let points = coordinates.map { snapshot.point(for: $0) }
                let minX = points.map(\.x).min() ?? 0
                let maxX = points.map(\.x).max() ?? minX
                let minY = points.map(\.y).min() ?? 0
                let maxY = points.map(\.y).max() ?? minY
                let shotWidth = max((maxX - minX) * paddingMultiplier, 1)
                let shotHeight = max((maxY - minY) * paddingMultiplier, 1)
                let fittedScale = min(availableWidth / shotWidth, availableHeight / shotHeight)
                scale = min(
                    max(fittedScale, 1),
                    CGFloat(max(config.routeVideoExportCinematicRouteScale, 1))
                )
            }
            for index in range { scales[index] = scale }
        }

        let transitionFrameCount = max(Int((
            max(config.routeVideoExportCinematicTransitionDuration, frameInterval) /
            max(frameInterval, 1.0 / 30.0)
        ).rounded()), 1)
        let stableScales = scales
        for range in ranges.dropFirst() {
            let boundary = range.lowerBound
            let start = max(0, boundary - transitionFrameCount / 2)
            let end = min(stableScales.count - 1, boundary + transitionFrameCount / 2)
            guard end > start else { continue }
            let startScale = stableScales[boundary - 1]
            let endScale = stableScales[boundary]
            for index in start...end {
                let fraction = CGFloat(index - start) / CGFloat(end - start)
                scales[index] = startScale + (endScale - startScale) * fraction
            }
        }
        return scales
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

    private final class Assets: @unchecked Sendable {
        let snapshot: MKMapSnapshotter.Snapshot
        let markerImages: [Int: UIImage]
        let stopMarkerImages: [String: UIImage]
        let cinematicCameraScales: [CGFloat]
        let brandImage: UIImage
        let headerImages: [Int: UIImage]

        init(
            snapshot: MKMapSnapshotter.Snapshot,
            markerImages: [Int: UIImage],
            stopMarkerImages: [String: UIImage],
            cinematicCameraScales: [CGFloat],
            brandImage: UIImage,
            headerImages: [Int: UIImage]
        ) {
            self.snapshot = snapshot
            self.markerImages = markerImages
            self.stopMarkerImages = stopMarkerImages
            self.cinematicCameraScales = cinematicCameraScales
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

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = exportSize(for: request.aspectRatio)
        options.scale = max(AppConfig.shared.routeVideoExportMapSnapshotScale, 1)
        options.mapType = .mutedStandard
        options.showsBuildings = true
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: request.theme == .dark ? .dark : .light
        )
        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
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
        let outputSize = exportSize(for: request.aspectRatio)
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
        let cinematicCameraScales = await Task.detached(priority: .userInitiated) {
            input.cinematicCameraScales(snapshot: snapshot, outputSize: outputSize)
        }.value
        let assets = Assets(
            snapshot: snapshot,
            markerImages: markerImages,
            stopMarkerImages: stopMarkerImages,
            cinematicCameraScales: cinematicCameraScales,
            brandImage: brandImage,
            headerImages: headerImages
        )
        return try await Task.detached(priority: .userInitiated) {
            try encode(input: input, request: request, assets: assets, state: state)
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

    private nonisolated static func encode(
        input: RouteVideoInput,
        request: RouteVideoExportRequest,
        assets: Assets,
        state: RouteVideoExportState
    ) throws -> URL {
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

        for outputIndex in 0..<frameCount {
            if Task.isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            while !writerInput.isReadyForMoreMediaData {
                if Task.isCancelled { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.002)
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
                        highlightedSegments: cachedHighlightedSegments,
                        cameraMode: request.cameraMode,
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
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? RouteVideoExportError.encodingFailed
        }
        return url
    }

    private nonisolated static func renderFrame(
        input: RouteVideoInput,
        assets: Assets,
        highlightedSegments: [TransportLineSegment],
        cameraMode: RouteVideoCameraMode,
        theme: RouteVideoResolvedTheme,
        leadingIndex: Int,
        trailingIndex: Int,
        interpolation: Double,
        size: CGSize
    ) -> UIImage {
        let leading = input.frames[leadingIndex]
        let trailing = input.frames[trailingIndex]
        let coordinate = interpolatedCoordinate(leading.coordinate, trailing.coordinate, interpolation)
        let point = assets.snapshot.point(for: coordinate)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let routeLineScale = CGFloat(max(AppConfig.shared.routeVideoExportRouteLineScale, 1))
            context.setFillColor((theme == .dark ? UIColor.black : UIColor.white).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            let cameraTransform: CGAffineTransform
            let scale: CGFloat
            if cameraMode == .overview {
                scale = 1
                cameraTransform = .identity
            } else {
                let config = AppConfig.shared
                let cameraCoordinate: CLLocationCoordinate2D
                if cameraMode == .cinematic,
                   input.cinematicCameraCenters.indices.contains(leadingIndex),
                   input.cinematicCameraCenters.indices.contains(trailingIndex) {
                    cameraCoordinate = interpolatedCoordinate(
                        input.cinematicCameraCenters[leadingIndex],
                        input.cinematicCameraCenters[trailingIndex],
                        interpolation
                    )
                } else {
                    cameraCoordinate = coordinate
                }
                let cameraPoint = assets.snapshot.point(for: cameraCoordinate)
                let leadingScale: Double
                let trailingScale: Double
                switch cameraMode {
                case .overview:
                    leadingScale = 1
                    trailingScale = 1
                case .follow:
                    leadingScale = leading.isStop
                        ? config.routeVideoExportFollowStopScale
                        : config.routeVideoExportFollowRouteScale
                    trailingScale = trailing.isStop
                        ? config.routeVideoExportFollowStopScale
                        : config.routeVideoExportFollowRouteScale
                case .cinematic:
                    leadingScale = assets.cinematicCameraScales.indices.contains(leadingIndex)
                        ? Double(assets.cinematicCameraScales[leadingIndex])
                        : config.routeVideoExportCinematicRouteScale
                    trailingScale = assets.cinematicCameraScales.indices.contains(trailingIndex)
                        ? Double(assets.cinematicCameraScales[trailingIndex])
                        : config.routeVideoExportCinematicRouteScale
                }
                scale = CGFloat(leadingScale + (trailingScale - leadingScale) * interpolation)
                cameraTransform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cameraPoint.x, y: -cameraPoint.y)
            }
            context.saveGState()
            context.concatenate(cameraTransform)
            assets.snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            context.restoreGState()
            drawSegments(
                input.segments,
                snapshot: assets.snapshot,
                color: UIColor(Color.dfkAccent).withAlphaComponent(0.24),
                isHighlighted: false,
                lineScale: routeLineScale,
                transform: cameraTransform,
                in: context
            )
            drawSegments(
                highlightedSegments,
                snapshot: assets.snapshot,
                color: UIColor(Color.dfkAccent),
                isHighlighted: true,
                lineScale: routeLineScale,
                transform: cameraTransform,
                in: context
            )
            drawStops(
                input.stops,
                count: leading.completedStopCount,
                snapshot: assets.snapshot,
                images: assets.stopMarkerImages,
                transform: cameraTransform
            )
            let markerPoint = point.applying(cameraTransform)
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
        snapshot: MKMapSnapshotter.Snapshot,
        color: UIColor,
        isHighlighted: Bool,
        lineScale: CGFloat,
        transform: CGAffineTransform,
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
            context.move(to: snapshot.point(for: segment.coordinates[0]).applying(transform))
            for coordinate in segment.coordinates.dropFirst() {
                context.addLine(to: snapshot.point(for: coordinate).applying(transform))
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private nonisolated static func drawStops(
        _ stops: [DayRoutePlaybackStopMarker],
        count: Int,
        snapshot: MKMapSnapshotter.Snapshot,
        images: [String: UIImage],
        transform: CGAffineTransform
    ) {
        for stop in stops.prefix(max(count, 0)) {
            let point = snapshot.point(for: stop.coordinate).applying(transform)
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
    @State private var theme: RouteVideoTheme = .current

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
                    Picker("视频主题", selection: $theme) {
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
            theme: theme.resolved(for: colorScheme)
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
