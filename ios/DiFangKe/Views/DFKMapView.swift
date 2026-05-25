import SwiftUI
import MapKit
import SwiftData
import Photos
import UIKit
import CryptoKit

@MainActor
final class DFKMapSnapshotCache {
    static let shared = DFKMapSnapshotCache()
    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        memoryCache.countLimit = 24
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("DFKMapSnapshots", isDirectory: true)
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    private func cacheURL(for key: String) -> URL {
        let data = Data(key.utf8)
        let hash = SHA256.hash(data: data)
        let filename = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(filename + ".png")
    }

    func image(for key: String) -> UIImage? {
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }
        
        let url = cacheURL(for: key)
        if let data = try? Data(contentsOf: url), let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }
        
        return nil
    }

    func setImage(_ image: UIImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString)
        
        let url = cacheURL(for: key)
        Task.detached(priority: .background) {
            if let data = image.pngData() {
                try? data.write(to: url)
            }
        }
    }

    func calculateCacheSize() -> Int64 {
        let files = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var totalSize: Int64 = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        let files = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}

/// DiFangKe 统一地图组件，用于确保全应用地图表现一致
struct DFKMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    var isInteractive: Bool = false
    var rendersLiveMap: Bool = true
    var showsUserLocation: Bool = true
    var points: [CLLocationCoordinate2D] = []
    var mainAnnotationCoordinate: CLLocationCoordinate2D? = nil
    var mainAnnotationTitle: String? = nil
    var timelineItems: [TimelineItem] = []
    var photoAssets: [PHAsset] = []
    var widgetSnapshotOffset: Int? = nil
    var allowsGeneratedSnapshot: Bool = true
    var showsStandalonePhotos: Bool = false
    var prefersActivityIcons: Bool = false

    struct HeatmapPoint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let intensity: Int
        let maxIntensity: Int

        init(coordinate: CLLocationCoordinate2D, intensity: Int, maxIntensity: Int) {
            self.id = String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            self.coordinate = coordinate
            self.intensity = intensity
            self.maxIntensity = maxIntensity
        }
    }

    fileprivate struct AggregatedFootprint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let totalDuration: TimeInterval
        let representative: Footprint
        let footprints: [Footprint]
    }



    var heatmapPoints: [HeatmapPoint] = []

    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    var onPhotoTap: ((PHAsset) -> Void)? = nil

    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]

    init(
        cameraPosition: Binding<MapCameraPosition>,
        rendersLiveMap: Bool = true,
        isInteractive: Bool = false,
        allowsGeneratedSnapshot: Bool = true,
        showsUserLocation: Bool = true,
        points: [CLLocationCoordinate2D] = [],
        mainAnnotationCoordinate: CLLocationCoordinate2D? = nil,
        mainAnnotationTitle: String? = nil,
        timelineItems: [TimelineItem] = [],
        photoAssets: [PHAsset] = [],
        heatmapPoints: [HeatmapPoint] = [],
        showsStandalonePhotos: Bool = false,
        prefersActivityIcons: Bool = false,
        onTimelineItemTap: ((TimelineItem) -> Void)? = nil,
        onPhotoTap: ((PHAsset) -> Void)? = nil
    ) {
        self._cameraPosition = cameraPosition
        self.rendersLiveMap = rendersLiveMap
        self.isInteractive = isInteractive
        self.allowsGeneratedSnapshot = allowsGeneratedSnapshot
        self.showsUserLocation = showsUserLocation
        self.points = points
        self.mainAnnotationCoordinate = mainAnnotationCoordinate
        self.mainAnnotationTitle = mainAnnotationTitle
        self.timelineItems = timelineItems
        self.photoAssets = photoAssets
        self.heatmapPoints = heatmapPoints
        self.showsStandalonePhotos = showsStandalonePhotos
        self.prefersActivityIcons = prefersActivityIcons
        self.onTimelineItemTap = onTimelineItemTap
        self.onPhotoTap = onPhotoTap
    }

    @State private var snapshotImage: UIImage?
    @State private var snapshotTask: Task<Void, Never>?
    @State private var isSnapshotLoading = false
    @State private var snapshotLoadFailed = false
    @State private var lastSnapshotSize: CGSize = .zero

    @State private var isRequestingWidgetSnapshot = false
    @State private var selectedAggregatedFootprint: AggregatedFootprint?

    private var hasVisibleContent: Bool {
        !points.isEmpty ||
        validMainAnnotationCoordinate != nil ||
        !timelineItems.isEmpty ||
        !validPhotoAnnotations.isEmpty ||
        !validHeatmapPoints.isEmpty ||
        showsUserLocation
    }

    private var userDefinedPlaces: [Place] {
        allPlaces.filter {
            $0.isUserDefined &&
            $0.coordinate.isRenderableMapCoordinate &&
            $0.radius.isFinite &&
            $0.radius > 1
        }
    }

    private var transportItems: [Transport] {
        timelineItems.compactMap { item in
            guard case .transport(let transport) = item,
                  transport.points.filter(\.isRenderableMapCoordinate).count >= 2 else { return nil }
            return transport
        }
    }

    private var validMainAnnotationCoordinate: CLLocationCoordinate2D? {
        guard let mainAnnotationCoordinate, mainAnnotationCoordinate.isRenderableMapCoordinate else { return nil }
        return mainAnnotationCoordinate
    }

    private var validAggregatedFootprints: [AggregatedFootprint] {
        aggregatedFootprints.filter { $0.coordinate.isRenderableMapCoordinate }
    }

    private var validPhotoAnnotations: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)] {
        guard showsStandalonePhotos else { return [] }
        return photoAssets.compactMap { asset in
            guard let coord = asset.location?.gcj02.coordinate else { return nil }
            return (asset, coord)
        }
    }

    private var validHeatmapPoints: [HeatmapPoint] {
        heatmapPoints.filter { $0.coordinate.isRenderableMapCoordinate }
    }

    private var interactiveRegion: MKCoordinateRegion? {
        var allCoords = points.filter(\.isRenderableMapCoordinate)
        if let mainAnnotationCoordinate = validMainAnnotationCoordinate {
            allCoords.append(mainAnnotationCoordinate)
        }
        for item in timelineItems {
            switch item {
            case .footprint(let footprint):
                let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
                if coordinate.isRenderableMapCoordinate {
                    allCoords.append(coordinate)
                }
            case .transport(let transport):
                allCoords.append(contentsOf: transport.points.filter(\.isRenderableMapCoordinate))
            }
        }
        allCoords.append(contentsOf: validPhotoAnnotations.map(\.coordinate))
        allCoords.append(contentsOf: validHeatmapPoints.map(\.coordinate))

        if allCoords.isEmpty,
           showsUserLocation,
           let lastLoc = LocationManager.shared.lastLocation?.coordinate,
           lastLoc.isRenderableMapCoordinate {
            allCoords.append(lastLoc)
        }

        return allCoords.boundingRegion(paddingFactor: 1.4)
    }

    private var shouldDrawStandalonePhotosInSnapshot: Bool {
        timelineItems.contains { item in
            guard case .footprint(let footprint) = item else { return false }
            return !footprint.photoAssetIDs.isEmpty
        }
    }

    private func latestPhotoAssetID(for aggregated: AggregatedFootprint) -> String? {
        // 直接从足迹数据中提取，不依赖异步加载的 photoAssets 数组，确保渲染及时
        aggregated.footprints
            .sorted { $0.startTime > $1.startTime }
            .compactMap { $0.photoAssetIDs.first } // 匹配足迹卡片使用的 .first (最新)
            .first
    }

    private func markerSize(for duration: TimeInterval) -> CGFloat {
        let baseSize: CGFloat = isInteractive ? 34 : 28
        return baseSize * calculateScale(for: duration)
    }

    private var aggregatedFootprints: [AggregatedFootprint] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalDuration: TimeInterval
            var representative: Footprint
            var footprints: [Footprint]
        }

        let footprints = timelineItems.compactMap { item -> Footprint? in
            guard case .footprint(let footprint) = item else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            guard coordinate.isRenderableMapCoordinate else { return nil }
            return footprint
        }

        var buckets: [String: Bucket] = [:]
        var orderedKeys: [String] = []

        for footprint in footprints {
            let durationWeight = max(footprint.duration, 1)
            let key: String
            if let placeID = footprint.placeID {
                key = "place:\(placeID.uuidString)"
            } else if !footprint.locationHash.isEmpty {
                key = "hash:\(footprint.locationHash)"
            } else {
                key = String(format: "coord:%.5f,%.5f", footprint.latitude, footprint.longitude)
            }

            if var bucket = buckets[key] {
                bucket.weightedLatitude += footprint.latitude * durationWeight
                bucket.weightedLongitude += footprint.longitude * durationWeight
                bucket.totalDuration += footprint.duration
                bucket.footprints.append(footprint)
                if footprint.duration > bucket.representative.duration {
                    bucket.representative = footprint
                }
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = Bucket(
                    weightedLatitude: footprint.latitude * durationWeight,
                    weightedLongitude: footprint.longitude * durationWeight,
                    totalDuration: footprint.duration,
                    representative: footprint,
                    footprints: [footprint]
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let divisor = max(bucket.totalDuration, 1)
            return AggregatedFootprint(
                id: key,
                coordinate: CLLocationCoordinate2D(
                    latitude: bucket.weightedLatitude / divisor,
                    longitude: bucket.weightedLongitude / divisor
                ),
                totalDuration: bucket.totalDuration,
                representative: bucket.representative,
                footprints: bucket.footprints.sorted { $0.startTime < $1.startTime }
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isValidSize = geometry.size.width > 1 && geometry.size.height > 1

            ZStack {
                Group {
                    if isInteractive && isValidSize && rendersLiveMap {
                        Map(position: $cameraPosition) {
                            ForEach(userDefinedPlaces) { place in
                                MapCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
                                    .foregroundStyle(Color.orange.opacity(0.1))
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            }

                            transportMapContent()

                            ForEach(validAggregatedFootprints) { aggregated in
                                Annotation("", coordinate: aggregated.coordinate) {
                                    aggregatedAnnotationContent(for: aggregated)
                                        .onTapGesture {
                                            handleFootprintTap(for: aggregated)
                                        }
                                }
                            }

                            ForEach(validPhotoAnnotations, id: \.asset.localIdentifier) { entry in
                                Annotation("", coordinate: entry.coordinate) {
                                    photoAnnotationContent(for: entry.asset)
                                        .zIndex(100)
                                }
                            }

                            ForEach(validHeatmapPoints) { point in
                                Annotation("", coordinate: point.coordinate) {
                                    heatmapAnnotationContent(for: point)
                                }
                            }

                            if let coordinate = validMainAnnotationCoordinate {
                                Annotation(mainAnnotationTitle ?? "", coordinate: coordinate) {
                                    Circle()
                                        .fill(Color.dfkAccent)
                                        .frame(width: isInteractive ? 18 : 14, height: isInteractive ? 18 : 14)
                                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                                }
                            }

                            if showsUserLocation {
                                UserAnnotation()
                            }
                        }
                        .mapStyle(.standard(emphasis: .muted))
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                            MapScaleView()
                        }
                    } else {
                        snapshotContent(for: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if let aggregated = selectedAggregatedFootprint {
                    aggregatedModal(for: aggregated)
                        .transition(.opacity)
                }
            }
            .onAppear {
                if !isInteractive {
                    loadSnapshot(for: geometry.size)
                }
            }
            .task(id: snapshotCacheKey(for: geometry.size)) {
                guard !isInteractive else { return }
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .onDisappear {
                snapshotTask?.cancel()
                isSnapshotLoading = false
            }
        }
    }

    private func handleFootprintTap(for aggregated: AggregatedFootprint) {
        if aggregated.footprints.count > 1 {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedAggregatedFootprint = aggregated
            }
            return
        }

        guard let footprint = aggregated.footprints.first else { return }
        onTimelineItemTap?(.footprint(footprint))
    }

    @ViewBuilder
    private func aggregatedModal(for aggregated: AggregatedFootprint) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedAggregatedFootprint = nil
                    }
                }

            AggregatedFootprintListView(
                aggregated: aggregated,
                allPlaces: allPlaces,
                onClose: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedAggregatedFootprint = nil
                    }
                },
                onFootprintSelected: { footprint in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedAggregatedFootprint = nil
                    }
                    DispatchQueue.main.async {
                        onTimelineItemTap?(.footprint(footprint))
                    }
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .zIndex(10)
    }

    @ViewBuilder
    private func snapshotContent(for size: CGSize) -> some View {
        if let snapshotImage {
            Image(uiImage: snapshotImage)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .secondarySystemBackground),
                    Color(uiColor: .tertiarySystemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: hasVisibleContent ? "map" : "map.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.55))

                if !hasVisibleContent {
                    Text("暂无地图数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isSnapshotLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else if snapshotLoadFailed {
                    VStack(spacing: 6) {
                        Text("地图加载失败")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("重试") {
                            triggerSnapshotRetry()
                        }
                        .font(.caption2)
                    }
                } else {
                    Text("地图暂不可用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }

    private func aggregatedAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        let fp = aggregated.representative
        let scale = calculateScale(for: aggregated.totalDuration)
        let size = markerSize(for: aggregated.totalDuration)

        let activity = fp.getActivityType(from: allActivities)
        let activityColor = activity?.color ?? Color.secondary.opacity(0.5)
        let iconName = activity?.icon ?? "questionmark.circle.dashed"
        let iconSize: CGFloat = (activity?.icon == nil ? 22 : 16) * scale

        return ZStack {
            // 根据 prefersActivityIcons 决定显示活动图标还是照片封面
            if !prefersActivityIcons, let latestPhotoAssetID = latestPhotoAssetID(for: aggregated) {
                AssetThumbnailView(assetID: latestPhotoAssetID, showsTime: false)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .stroke(Color(uiColor: .systemBackground), lineWidth: 1.5 * scale)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            } else {
                Circle()
                    .fill(activityColor)
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5 * scale))

                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(Color(uiColor: .systemBackground))
            }
        }
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
    }

    @ViewBuilder
    private func transportAnnotationContent(for transport: Transport) -> some View {
        let transportIcon = ZStack {
            RoundedRectangle(cornerRadius: isInteractive ? 8 : 6)
                .fill(Color.dfkAccent)
                .frame(width: isInteractive ? 28 : 20, height: isInteractive ? 28 : 20)
                .overlay(RoundedRectangle(cornerRadius: isInteractive ? 8 : 6).stroke(Color(uiColor: .systemBackground), lineWidth: 1.2))

            Image(systemName: transport.currentType.sfSymbol)
                .font(.system(size: isInteractive ? 14 : 10, weight: .bold))
                .foregroundColor(Color(uiColor: .systemBackground))
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))

        if let onTimelineItemTap {
            transportIcon
                .onTapGesture {
                    onTimelineItemTap(.transport(transport))
                }
        } else {
            transportIcon
        }
    }

    @MapContentBuilder
    private func transportMapContent() -> some MapContent {
        let backgroundLineWidth: CGFloat = (isInteractive ? 5 : 3) + 2.5
        let foregroundLineWidth: CGFloat = isInteractive ? 5 : 3

        ForEach(transportItems) { transport in
            ForEach(transport.lineSegments) { segment in
                if !segment.isDashed {
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(
                            Color(uiColor: .systemBackground),
                            style: StrokeStyle(
                                lineWidth: backgroundLineWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }

                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color.dfkAccent.opacity(0.7),
                        style: StrokeStyle(
                            lineWidth: segment.isDashed ? (isInteractive ? 2 : 1.2) : foregroundLineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: segment.isDashed ? [5, 5] : []
                        )
                    )
            }

            if let coord = transport.points.distanceMidpoint {
                Annotation("", coordinate: coord) {
                    transportAnnotationContent(for: transport)
                }
            }
        }
    }



    @MapContentBuilder
    private func aggregatedFootprintAnnotations() -> some MapContent {
        ForEach(aggregatedFootprints) { aggregated in
            Annotation("", coordinate: aggregated.coordinate) {
                aggregatedAnnotationContent(for: aggregated)
            }
            .tag(aggregated.id)
        }
    }

    @MapContentBuilder
    private func photoAnnotations() -> some MapContent {
        ForEach(photoAssets, id: \.localIdentifier) { asset in
            if let coord = asset.location?.gcj02.coordinate {
                Annotation("", coordinate: coord) {
                    photoAnnotationContent(for: asset)
                }
            }
        }
    }

    private func heatmapAnnotationContent(for point: HeatmapPoint) -> some View {
        let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
        let ratio = pow(rawRatio, 0.4)
        let color: Color = {
            if point.maxIntensity <= 1 {
                return .orange
            } else if ratio < 0.25 {
                return .orange
            } else if ratio < 0.85 {
                return .red
            } else {
                return .dfkDeepRed
            }
        }()

        let baseSize: CGFloat = isInteractive ? 30 : 14
        let multiplier: CGFloat = isInteractive ? 8 : 3
        let maxSize: CGFloat = isInteractive ? 80 : 30
        let size = CGFloat(max(baseSize, min(maxSize, CGFloat(point.intensity) * multiplier)))

        return Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.7), color.opacity(0.15)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func photoAnnotationContent(for asset: PHAsset) -> some View {
        let content = AssetThumbnailView(assetID: asset.localIdentifier, showsTime: false)
            .frame(width: isInteractive ? 60 : 46, height: isInteractive ? 60 : 46)
            .clipShape(RoundedRectangle(cornerRadius: isInteractive ? 8 : 6))
            .overlay(RoundedRectangle(cornerRadius: isInteractive ? 8 : 6).stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
            .contentShape(Rectangle())

        if let onPhotoTap {
            content
                .onTapGesture {
                    onPhotoTap(asset)
                }
        } else {
            content
        }
    }

    private func snapshotCacheKey(for size: CGSize) -> String {
        let footprintKey = timelineItems.compactMap { item -> String? in
            guard case .footprint(let fp) = item else { return nil }
            let isOngoingStay = fp.locationHash == "ONGOING_STAY"
            let startTs = Int(fp.startTime.timeIntervalSince1970)
            // 正在记录的临时停留会随时间跳动 endTime，避免它触发每次快照重建。
            let endToken = isOngoingStay ? "ongoing" : String(Int(fp.endTime.timeIntervalSince1970))
            return [
                "f",
                fp.footprintID.uuidString,
                String(startTs),
                endToken,
                String(format: "%.4f", fp.latitude),
                String(format: "%.4f", fp.longitude),
                String(fp.photoAssetIDs.count),
                fp.activityTypeValue ?? "nil"
            ].joined(separator: ":")
        }.joined(separator: "|")

        let transportKey = timelineItems.compactMap { item -> String? in
            guard case .transport(let transport) = item else { return nil }
            let pathKey = transport.points.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";")
            return [
                "t",
                transport.id.uuidString,
                String(Int(transport.startTime.timeIntervalSince1970)),
                String(Int(transport.endTime.timeIntervalSince1970)),
                transport.currentType.rawValue,
                pathKey
            ].joined(separator: ":")
        }.joined(separator: "|")

        let pointKey = points.prefix(12).map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: "|")
        let photoKey = photoAssets.prefix(8).map(\.localIdentifier).joined(separator: "|")
        let footprintPhotoKey = aggregatedFootprints.compactMap { aggregated -> String? in
            guard let latestPhotoAssetID = latestPhotoAssetID(for: aggregated) else { return nil }
            return "\(aggregated.id):\(latestPhotoAssetID)"
        }.joined(separator: "|")
        let heatmapKey = heatmapPoints.prefix(8).map(\.id).joined(separator: "|")
        let annotationKey = mainAnnotationCoordinate.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "none"
        let w = Int(size.width / 10) * 10
        let h = Int(size.height / 10) * 10
        let sizeKey = "\(w)x\(h)"
        let styleKey = UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
        return [sizeKey, styleKey, annotationKey, pointKey, footprintKey, transportKey, photoKey, footprintPhotoKey, heatmapKey, showsUserLocation ? "user" : "nouser"].joined(separator: "#")
    }

    private func loadSnapshot(for size: CGSize, forceWidgetRefresh: Bool = false) {
        lastSnapshotSize = size

        guard size.width > 1, size.height > 1, hasVisibleContent else {
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = nil
            return
        }

        guard allowsGeneratedSnapshot else {
            snapshotTask?.cancel()
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = nil
            return
        }

        let cacheKey = snapshotCacheKey(for: size)
        if !forceWidgetRefresh, let cached = DFKMapSnapshotCache.shared.image(for: cacheKey) {
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = cached
            return
        }

        snapshotTask?.cancel()
        isSnapshotLoading = true
        snapshotLoadFailed = false
        // 保留上一帧，避免频繁刷新时出现闪白/占位图跳变。

        snapshotTask = Task { @MainActor in
            guard let image = await buildSnapshotImageWithTimeout(size: size, timeoutSeconds: 12) else {
                if Task.isCancelled { return }
                isSnapshotLoading = false
                snapshotLoadFailed = true
                return
            }
            if Task.isCancelled { return }
            DFKMapSnapshotCache.shared.setImage(image, for: cacheKey)
            snapshotImage = image
            isSnapshotLoading = false
            snapshotLoadFailed = false
        }
    }

    private func triggerSnapshotRetry() {
        snapshotTask?.cancel()
        snapshotImage = nil
        isSnapshotLoading = false
        snapshotLoadFailed = false
        if lastSnapshotSize.width > 1, lastSnapshotSize.height > 1 {
            loadSnapshot(for: lastSnapshotSize, forceWidgetRefresh: true)
        }
    }

    private func buildSnapshotImageWithTimeout(size: CGSize, timeoutSeconds: UInt64) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                await buildSnapshotImage(size: size)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @MainActor
    private func buildSnapshotImage(size: CGSize) async -> UIImage? {
        guard let region = snapshotRegion(for: size) else { return nil }

        let footprintPhotoImages = await loadSnapshotFootprintPhotoImages(targetSide: 88)
        let standalonePhotoImages = await loadStandaloneSnapshotPhotoImages(targetSide: 80)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = UIScreen.main.scale
        options.traitCollection = UITraitCollection.current

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
        let themeColor = UIColor(named: "AccentColor") ?? .systemTeal
        let strokeColor = UITraitCollection.current.userInterfaceStyle == .dark ? UIColor.black : UIColor.white

        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            for place in allPlaces.filter({ $0.isUserDefined }) {
                let center = snapshot.point(for: place.coordinate)
                let metersPerDegreeLongitude = 111_320.0 * max(0.2, cos(place.coordinate.latitude * .pi / 180.0))
                let visibleWidthMeters = max(1, region.span.longitudeDelta * metersPerDegreeLongitude)
                let metersPerPoint = visibleWidthMeters / max(size.width, 1)
                let radius = max(10, CGFloat(Double(place.radius) / max(Double(metersPerPoint), 1)))
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ctx.cgContext.setFillColor(UIColor.orange.withAlphaComponent(0.12).cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(UIColor.orange.withAlphaComponent(0.35).cgColor)
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.strokeEllipse(in: rect)
            }

            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)

            for item in timelineItems {
                guard case .transport(let transport) = item, transport.points.count >= 2 else { continue }

                for segment in transport.lineSegments {
                    let projected = segment.coordinates.map { snapshot.point(for: $0) }
                    guard projected.count >= 2 else { continue }

                    ctx.cgContext.beginPath()
                    ctx.cgContext.move(to: projected[0])
                    for i in 1..<projected.count {
                        ctx.cgContext.addLine(to: projected[i])
                    }
                    ctx.cgContext.setStrokeColor(themeColor.withAlphaComponent(0.65).cgColor)
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1.5 : 4)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                if let midCoord = transport.points.distanceMidpoint {
                    let midPoint = snapshot.point(for: midCoord)
                    let rect = CGRect(x: midPoint.x - 10, y: midPoint.y - 10, width: 20, height: 20)
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
                    themeColor.setFill()
                    path.fill()
                    strokeColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()

                    if let iconImage = UIImage(systemName: transport.currentType.sfSymbol) {
                        drawImageAspectFit(iconImage.withTintColor(strokeColor), in: CGRect(x: midPoint.x - 6, y: midPoint.y - 6, width: 12, height: 12))
                    }
                }
            }

            for aggregated in aggregatedFootprints {
                let fp = aggregated.representative
                let point = snapshot.point(for: aggregated.coordinate)
                let hours = aggregated.totalDuration / 3600.0
                let dotScale: CGFloat = 1.0 + (1.5 - 1.0) * min(1.0, max(0.0, (hours - 0.5) / (12.0 - 0.5)))
                let markerSize = 28 * dotScale
                let rect = CGRect(x: point.x - markerSize / 2, y: point.y - markerSize / 2, width: markerSize, height: markerSize)

                // 快照逻辑同步：若 prefersActivityIcons 为 false 且有照片，则显示封面
                if !prefersActivityIcons, let latestPhotoAssetID = latestPhotoAssetID(for: aggregated),
                   let photoImage = footprintPhotoImages[latestPhotoAssetID] {
                    let clipPath = UIBezierPath(roundedRect: rect, cornerRadius: 8 * dotScale)
                    ctx.cgContext.saveGState()
                    clipPath.addClip()
                    drawImageAspectFill(photoImage, in: rect)
                    ctx.cgContext.restoreGState()

                    ctx.cgContext.setStrokeColor(strokeColor.cgColor)
                    ctx.cgContext.setLineWidth(1.5)
                    ctx.cgContext.addPath(clipPath.cgPath)
                    ctx.cgContext.strokePath()
                } else {
                    let activity = fp.getActivityType(from: allActivities)
                    let activityColor = UIColor(activity?.color ?? Color.secondary.opacity(0.5))
                    let iconName = activity?.icon ?? "questionmark.circle.dashed"

                    ctx.cgContext.setFillColor(activityColor.cgColor)
                    ctx.cgContext.fillEllipse(in: rect)
                    ctx.cgContext.setStrokeColor(strokeColor.cgColor)
                    ctx.cgContext.setLineWidth(1.5)
                    ctx.cgContext.strokeEllipse(in: rect)
                    if let iconImage = UIImage(systemName: iconName) {
                        let iconSize = markerSize * 0.55
                        drawImageAspectFit(iconImage.withTintColor(strokeColor), in: CGRect(x: point.x - iconSize / 2, y: point.y - iconSize / 2, width: iconSize, height: iconSize))
                    }
                }
            }

            for point in heatmapPoints {
                let mapped = snapshot.point(for: point.coordinate)
                let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
                let ratio = pow(rawRatio, 0.4)
                let color: UIColor = {
                    if point.maxIntensity <= 1 {
                        return .orange
                    } else if ratio < 0.25 {
                        return .orange
                    } else if ratio < 0.85 {
                        return .red
                    } else {
                        return UIColor(Color.dfkDeepRed)
                    }
                }()
                let sizeValue = max(14.0, min(30.0, CGFloat(point.intensity) * 3))
                let rect = CGRect(x: mapped.x - sizeValue / 2, y: mapped.y - sizeValue / 2, width: sizeValue, height: sizeValue)
                ctx.cgContext.setFillColor(color.withAlphaComponent(0.28).cgColor)
                ctx.cgContext.fillEllipse(in: rect)
            }

            if shouldDrawStandalonePhotosInSnapshot {
                for entry in validPhotoAnnotations {
                    let point = snapshot.point(for: entry.coordinate)
                    let markerSize: CGFloat = 40 // Standalone photos should be larger to be visible
                    let rect = CGRect(x: point.x - markerSize / 2, y: point.y - markerSize / 2, width: markerSize, height: markerSize)
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)

                    if let photoImage = standalonePhotoImages[entry.asset.localIdentifier] {
                        ctx.cgContext.saveGState()
                        path.addClip()
                        drawImageAspectFill(photoImage, in: rect)
                        ctx.cgContext.restoreGState()
                        
                        strokeColor.setStroke()
                        path.lineWidth = 1.5
                        path.stroke()
                    } else {
                        // If image not loaded, just a dot or skip? Skip for now to keep it clean.
                    }
                }
            }

            if let mainAnnotationCoordinate {
                let point = snapshot.point(for: mainAnnotationCoordinate)
                let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                ctx.cgContext.setFillColor(themeColor.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(strokeColor.cgColor)
                ctx.cgContext.setLineWidth(1.5)
                ctx.cgContext.strokeEllipse(in: rect)
            }
        }
    }

    private func drawImageAspectFill(_ image: UIImage, in rect: CGRect) {
        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        var drawRect = rect

        if imageAspect > rectAspect {
            drawRect.size.width = rect.height * imageAspect
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else {
            drawRect.size.height = rect.width / imageAspect
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        image.draw(in: drawRect)
    }

    private func drawImageAspectFit(_ image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        let aspectWidth = rect.width / imageSize.width
        let aspectHeight = rect.height / imageSize.height
        let aspectRatio = min(aspectWidth, aspectHeight)

        let newSize = CGSize(width: imageSize.width * aspectRatio, height: imageSize.height * aspectRatio)
        let newOrigin = CGPoint(x: rect.origin.x + (rect.width - newSize.width) / 2, y: rect.origin.y + (rect.height - newSize.height) / 2)

        image.draw(in: CGRect(origin: newOrigin, size: newSize))
    }

    private func snapshotRegion(for size: CGSize) -> MKCoordinateRegion? {
        var allCoords = points
        if let mainAnnotationCoordinate {
            allCoords.append(mainAnnotationCoordinate)
        }
        for item in timelineItems {
            switch item {
            case .footprint(let fp):
                allCoords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
            case .transport(let transport):
                allCoords.append(contentsOf: transport.points)
            }
        }
        if shouldDrawStandalonePhotosInSnapshot {
            allCoords.append(contentsOf: photoAssets.compactMap { $0.location?.gcj02.coordinate })
        }
        allCoords.append(contentsOf: heatmapPoints.map(\.coordinate))

        if allCoords.isEmpty, showsUserLocation, let lastLoc = LocationManager.shared.lastLocation?.coordinate {
            allCoords.append(lastLoc)
        }

        guard !allCoords.isEmpty else { return nil }

        var region = allCoords.boundingRegion(paddingFactor: 1.6) ?? MKCoordinateRegion(center: allCoords[0], span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        if size.width > size.height {
            region.span.longitudeDelta *= 1.5
        }
        return region
    }

    private func loadSnapshotFootprintPhotoImages(targetSide: CGFloat) async -> [String: UIImage] {
        let assetIDs = Set(aggregatedFootprints.compactMap { latestPhotoAssetID(for: $0) })
        guard !assetIDs.isEmpty else { return [:] }

        var images: [String: UIImage] = [:]
        for assetID in assetIDs {
            if let image = await loadSnapshotAssetImage(assetID: assetID, targetSize: CGSize(width: targetSide, height: targetSide)) {
                images[assetID] = image
            }
        }
        return images
    }

    private func loadStandaloneSnapshotPhotoImages(targetSide: CGFloat) async -> [String: UIImage] {
        let assetIDs = Set(photoAssets.map(\.localIdentifier))
        guard !assetIDs.isEmpty else { return [:] }

        var images: [String: UIImage] = [:]
        for assetID in assetIDs {
            if let image = await loadSnapshotAssetImage(assetID: assetID, targetSize: CGSize(width: targetSide, height: targetSide)) {
                images[assetID] = image
            }
        }
        return images
    }

    private func loadSnapshotAssetImage(assetID: String, targetSize: CGSize) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func calculateScale(for duration: TimeInterval) -> CGFloat {
        let minutes = duration / 60
        if minutes < 15 { return 0.8 }
        if minutes < 60 { return 1.0 }
        if minutes < 180 { return 1.15 }
        if minutes < 480 { return 1.25 }
        return 1.35
    }
}

private struct AggregatedFootprintListView: View {
    let aggregated: DFKMapView.AggregatedFootprint
    let allPlaces: [Place]
    let onClose: () -> Void
    let onFootprintSelected: (Footprint) -> Void

    private var title: String {
        let representative = aggregated.representative
        if let matchedPlace = allPlaces.first(where: { $0.placeID == representative.placeID && $0.isUserDefined }) {
            return matchedPlace.name
        }
        if let address = representative.address, !address.isEmpty {
            return address
        }
        return "同地点足迹"
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.dfkMainText)
                        .lineLimit(1)
                    Text("共 \(aggregated.footprints.count) 条足迹")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(aggregated.footprints) { footprint in
                        FootprintCardView(
                            footprint: footprint,
                            allPlaces: allPlaces,
                            showTimeline: false,
                            disableContextMenu: true
                        ) { selected, _ in
                            onFootprintSelected(selected)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxHeight: 420)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 12)
        )
    }
}

private struct StableInteractiveMapView: UIViewRepresentable {
    private static let controlsStackTag = 9000
    private static let userTrackingButtonTag = 9001
    private static let compassButtonTag = 9002
    private static let scaleViewTag = 9003

    let region: MKCoordinateRegion?
    let showsUserLocation: Bool
    let userDefinedPlaces: [Place]
    let transportItems: [Transport]
    let aggregatedFootprints: [DFKMapView.AggregatedFootprint]
    let photoAnnotations: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)]
    let heatmapPoints: [DFKMapView.HeatmapPoint]
    let mainAnnotationCoordinate: CLLocationCoordinate2D?
    let allActivities: [ActivityType]
    let onFootprintTap: (DFKMapView.AggregatedFootprint) -> Void
    let onTransportTap: (Transport) -> Void
    let onPhotoTap: (PHAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.annotationReuseIdentifier)

        let controlsStack = UIStackView()
        controlsStack.tag = Self.controlsStackTag
        controlsStack.axis = .vertical
        controlsStack.alignment = .trailing
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let trackingButton = MKUserTrackingButton(mapView: mapView)
        trackingButton.tag = Self.userTrackingButtonTag
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.addArrangedSubview(Self.makeCircularControlContainer(for: trackingButton))

        let compassButton = MKCompassButton(mapView: mapView)
        compassButton.tag = Self.compassButtonTag
        compassButton.compassVisibility = .adaptive
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.addArrangedSubview(Self.makeCircularControlContainer(for: compassButton))

        mapView.addSubview(controlsStack)

        let scaleView = MKScaleView(mapView: mapView)
        scaleView.tag = Self.scaleViewTag
        scaleView.scaleVisibility = .adaptive
        scaleView.legendAlignment = .trailing
        scaleView.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(scaleView)

        NSLayoutConstraint.activate([
            controlsStack.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controlsStack.topAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 16),
            scaleView.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scaleView.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        return mapView
    }

    private static func makeCircularControlContainer(for control: UIView) -> UIView {
        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blurView.clipsToBounds = true
        blurView.layer.cornerRadius = 22
        blurView.layer.cornerCurve = .continuous
        blurView.layer.borderWidth = 0.5
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        blurView.translatesAutoresizingMaskIntoConstraints = false

        blurView.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            blurView.widthAnchor.constraint(equalToConstant: 44),
            blurView.heightAnchor.constraint(equalToConstant: 44),
            control.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
            control.widthAnchor.constraint(lessThanOrEqualTo: blurView.contentView.widthAnchor),
            control.heightAnchor.constraint(lessThanOrEqualTo: blurView.contentView.heightAnchor)
        ])

        return blurView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.showsUserLocation = showsUserLocation
        if let trackingButton = mapView.viewWithTag(Self.userTrackingButtonTag) as? MKUserTrackingButton {
            trackingButton.isHidden = !showsUserLocation
        }
        if let controlsStack = mapView.viewWithTag(Self.controlsStackTag) as? UIStackView {
            controlsStack.isHidden = !showsUserLocation
        }
        if let scaleView = mapView.viewWithTag(Self.scaleViewTag) as? MKScaleView {
            scaleView.isHidden = !showsUserLocation
        }

        if let region, context.coordinator.shouldApply(region: region, to: mapView.region) {
            mapView.setRegion(region, animated: false)
        }

        context.coordinator.overlayStyles.removeAll()
        context.coordinator.footprintsByID = Dictionary(uniqueKeysWithValues: aggregatedFootprints.map { ($0.id, $0) })
        context.coordinator.transportsByID = Dictionary(uniqueKeysWithValues: transportItems.map { ($0.id.uuidString, $0) })
        context.coordinator.photosByID = Dictionary(uniqueKeysWithValues: photoAnnotations.map { ($0.asset.localIdentifier, $0.asset) })

        let removableAnnotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        mapView.removeAnnotations(removableAnnotations)
        mapView.removeOverlays(mapView.overlays)

        for place in userDefinedPlaces {
            let circle = MKCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
            context.coordinator.overlayStyles[ObjectIdentifier(circle)] = OverlayStyle(
                strokeColor: UIColor.orange.withAlphaComponent(0.35),
                fillColor: UIColor.orange.withAlphaComponent(0.12),
                lineWidth: 1
            )
            mapView.addOverlay(circle)
        }

        for transport in transportItems {
            let segments = Self.transportLineSegments(for: transport)
            guard !segments.isEmpty else { continue }

            for segment in segments {
                let border = MKPolyline(coordinates: segment.coordinates, count: segment.coordinates.count)
                context.coordinator.overlayStyles[ObjectIdentifier(border)] = OverlayStyle(
                    strokeColor: UIColor.systemBackground,
                    fillColor: nil,
                    lineWidth: 7.5,
                    dashPattern: segment.isDashed ? [8 as NSNumber, 8 as NSNumber] : nil
                )
                mapView.addOverlay(border)

                let line = MKPolyline(coordinates: segment.coordinates, count: segment.coordinates.count)
                context.coordinator.overlayStyles[ObjectIdentifier(line)] = OverlayStyle(
                    strokeColor: UIColor(Color.dfkAccent),
                    fillColor: nil,
                    lineWidth: 5,
                    dashPattern: segment.isDashed ? [8 as NSNumber, 8 as NSNumber] : nil
                )
                mapView.addOverlay(line)
            }

            let validPoints = transport.points.filter(\.isRenderableMapCoordinate)
            if let midpoint = validPoints.distanceMidpoint {
                mapView.addAnnotation(MapImageAnnotation(
                    coordinate: midpoint,
                    kind: .transport(transport.id.uuidString),
                    image: Coordinator.transportImage(symbolName: transport.currentType.sfSymbol)
                ))
            }
        }

        for aggregated in aggregatedFootprints {
            let activity = aggregated.representative.getActivityType(from: allActivities)
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: aggregated.coordinate,
                kind: .footprint(aggregated.id),
                image: Coordinator.footprintImage(
                    symbolName: activity?.icon ?? "questionmark.circle.dashed",
                    color: UIColor(activity?.color ?? Color.secondary.opacity(0.5)),
                    duration: aggregated.totalDuration
                )
            ))
        }

        for entry in photoAnnotations {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: entry.coordinate,
                kind: .photo(entry.asset.localIdentifier),
                image: Coordinator.photoImage()
            ))
        }

        for point in heatmapPoints {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: point.coordinate,
                kind: .heatmap(point.id),
                image: Coordinator.heatmapImage(point: point)
            ))
        }

        if let mainAnnotationCoordinate {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: mainAnnotationCoordinate,
                kind: .main,
                image: Coordinator.mainMarkerImage()
            ))
        }
    }

    private struct LineSegment {
        let coordinates: [CLLocationCoordinate2D]
        let isDashed: Bool
    }

    private static func transportLineSegments(for transport: Transport) -> [LineSegment] {
        let validPoints = transport.pathPoints.filter { $0.coordinate.isRenderableMapCoordinate }
        guard validPoints.count >= 2 else { return [] }

        return (0..<(validPoints.count - 1)).map { index in
            let current = validPoints[index]
            let next = validPoints[index + 1]
            let isDashed: Bool
            if let currentTime = current.timestamp, let nextTime = next.timestamp {
                isDashed = abs(nextTime.timeIntervalSince(currentTime)) > 5 * 60
            } else {
                isDashed = false
            }
            return LineSegment(coordinates: [current.coordinate, next.coordinate], isDashed: isDashed)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let annotationReuseIdentifier = "StableInteractiveMapAnnotation"

        var parent: StableInteractiveMapView
        var overlayStyles: [ObjectIdentifier: OverlayStyle] = [:]
        var footprintsByID: [String: DFKMapView.AggregatedFootprint] = [:]
        var transportsByID: [String: Transport] = [:]
        var photosByID: [String: PHAsset] = [:]

        init(_ parent: StableInteractiveMapView) {
            self.parent = parent
        }

        func shouldApply(region: MKCoordinateRegion, to current: MKCoordinateRegion) -> Bool {
            let latDiff = abs(region.center.latitude - current.center.latitude)
            let lonDiff = abs(region.center.longitude - current.center.longitude)
            let latDeltaDiff = abs(region.span.latitudeDelta - current.span.latitudeDelta)
            let lonDeltaDiff = abs(region.span.longitudeDelta - current.span.longitudeDelta)
            return latDiff > 0.0001 || lonDiff > 0.0001 || latDeltaDiff > 0.0001 || lonDeltaDiff > 0.0001
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let style = overlayStyles[ObjectIdentifier(overlay)]

            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = style?.strokeColor ?? UIColor.orange.withAlphaComponent(0.35)
                renderer.fillColor = style?.fillColor
                renderer.lineWidth = style?.lineWidth ?? 1
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = style?.strokeColor ?? UIColor(Color.dfkAccent)
                renderer.lineWidth = style?.lineWidth ?? 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                renderer.lineDashPattern = style?.dashPattern
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? MapImageAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.annotationReuseIdentifier, for: annotation)
            view.annotation = annotation
            view.image = annotation.image
            view.canShowCallout = false
            view.centerOffset = annotation.centerOffset
            
            // Ensure photos are on the top layer
            if case .photo = annotation.kind {
                view.zPriority = .max
                view.displayPriority = .required
            } else {
                view.zPriority = .min
                view.displayPriority = .defaultLow
            }
            
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer {
                if let annotation = view.annotation {
                    mapView.deselectAnnotation(annotation, animated: false)
                }
            }

            guard let annotation = view.annotation as? MapImageAnnotation else { return }

            switch annotation.kind {
            case .footprint(let id):
                if let footprint = footprintsByID[id] {
                    parent.onFootprintTap(footprint)
                }
            case .transport(let id):
                if let transport = transportsByID[id] {
                    parent.onTransportTap(transport)
                }
            case .photo(let id):
                if let asset = photosByID[id] {
                    parent.onPhotoTap(asset)
                }
            case .heatmap, .main:
                break
            }
        }

        static func footprintImage(symbolName: String, color: UIColor, duration: TimeInterval) -> UIImage {
            let scale = annotationScale(for: duration)
            let size = CGSize(width: 28 * scale, height: 28 * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                color.setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemBackground.setStroke()
                context.cgContext.setLineWidth(1.5 * scale)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.75 * scale, dy: 0.75 * scale))

                let iconSize = CGSize(width: size.width * 0.55, height: size.height * 0.55)
                let iconOrigin = CGPoint(x: (size.width - iconSize.width) / 2, y: (size.height - iconSize.height) / 2)
                UIImage(systemName: symbolName)?
                    .withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(origin: iconOrigin, size: iconSize))
            }
        }

        static func transportImage(symbolName: String) -> UIImage {
            let size = CGSize(width: 20, height: 20)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                UIColor(Color.dfkAccent).setFill()
                path.fill()
                UIColor.systemBackground.setStroke()
                path.lineWidth = 1.2
                path.stroke()

                UIImage(systemName: symbolName)?
                    .withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 5, y: 5, width: 10, height: 10))
            }
        }

        static func photoImage() -> UIImage {
            let size = CGSize(width: 24, height: 24)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                UIColor.white.setFill()
                path.fill()
                UIColor.systemGray2.setStroke()
                path.lineWidth = 1.2
                path.stroke()

                UIImage(systemName: "photo.fill")?
                    .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 5, y: 5, width: 14, height: 14))
            }
        }

        static func mainMarkerImage() -> UIImage {
            let size = CGSize(width: 14, height: 14)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                UIColor(Color.dfkAccent).setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemBackground.setStroke()
                context.cgContext.setLineWidth(1.5)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            }
        }

        static func heatmapImage(point: DFKMapView.HeatmapPoint) -> UIImage {
            let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
            let ratio = pow(rawRatio, 0.4)
            let color: UIColor = {
                if point.maxIntensity <= 1 {
                    return .orange
                } else if ratio < 0.25 {
                    return .orange
                } else if ratio < 0.85 {
                    return .red
                } else {
                    return UIColor(Color.dfkDeepRed)
                }
            }()
            let sizeValue = max(14.0, min(30.0, CGFloat(point.intensity) * 3))
            let size = CGSize(width: sizeValue, height: sizeValue)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                context.cgContext.setFillColor(color.withAlphaComponent(0.45).cgColor)
                context.cgContext.fillEllipse(in: rect)
            }
        }

        static func annotationScale(for duration: TimeInterval) -> CGFloat {
            let minutes = duration / 60
            if minutes < 15 { return 0.8 }
            if minutes < 60 { return 1.0 }
            if minutes < 180 { return 1.15 }
            if minutes < 480 { return 1.25 }
            return 1.35
        }
    }
}

private struct OverlayStyle {
    let strokeColor: UIColor
    let fillColor: UIColor?
    let lineWidth: CGFloat
    var dashPattern: [NSNumber]? = nil
}

private final class MapImageAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case footprint(String)
        case transport(String)
        case photo(String)
        case heatmap(String)
        case main
    }

    let kind: Kind
    dynamic var coordinate: CLLocationCoordinate2D
    let image: UIImage
    let centerOffset: CGPoint

    init(coordinate: CLLocationCoordinate2D, kind: Kind, image: UIImage, centerOffset: CGPoint = .zero) {
        self.coordinate = coordinate
        self.kind = kind
        self.image = image
        self.centerOffset = centerOffset
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// 计算包含所有坐标点的最佳矩形区域
    func boundingRegion(paddingFactor: Double = 1.3) -> MKCoordinateRegion? {
        guard !isEmpty else { return nil }
        
        var minLat = self[0].latitude
        var maxLat = self[0].latitude
        var minLon = self[0].longitude
        var maxLon = self[0].longitude
        
        for p in self {
            minLat = Swift.min(minLat, p.latitude)
            maxLat = Swift.max(maxLat, p.latitude)
            minLon = Swift.min(minLon, p.longitude)
            maxLon = Swift.max(maxLon, p.longitude)
        }
        
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        
        // 计算跨度并增加外边距
        let latDelta = (maxLat - minLat) * paddingFactor
        let lonDelta = (maxLon - minLon) * paddingFactor
        
        // 确保跨度不为0 (比如只有一个点的情况)
        let finalLatDelta = Swift.max(latDelta, 0.005) // 约 500m
        let finalLonDelta = Swift.max(lonDelta, 0.005)
        
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: finalLatDelta, longitudeDelta: finalLonDelta)
        )
    }
    
    /// 计算基于地理距离的中点，确保图标在路径的长度中点
    var distanceMidpoint: CLLocationCoordinate2D? {
        guard count >= 2 else { return first }
        
        // 1. 计算总距离和各段累计距离
        var totalDistance: Double = 0
        var segmentDistances: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDistance += d
            segmentDistances.append(totalDistance)
        }
        
        if totalDistance == 0 { return self[count / 2] }
        
        // 2. 找到距离上的中点
        let midDistance = totalDistance / 2
        
        for i in 0..<count-1 {
            if midDistance >= segmentDistances[i] && midDistance <= segmentDistances[i+1] {
                // 在这一段内进行插值
                let distInSegment = midDistance - segmentDistances[i]
                let segmentTotalDist = segmentDistances[i+1] - segmentDistances[i]
                let fraction = segmentTotalDist > 0 ? distInSegment / segmentTotalDist : 0
                
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * fraction,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * fraction
                )
            }
        }
        return self[count / 2]
    }
    
    /// 寻找给定坐标点在该数组中距离最近的元素索引
    func indexOfClosestPoint(to target: CLLocationCoordinate2D) -> Int {
        var minDistanceSq = Double.infinity
        var index = 0
        for (i, p) in enumerated() {
            let dLat = p.latitude - target.latitude
            let dLon = p.longitude - target.longitude
            let distSq = dLat * dLat + dLon * dLon
            if distSq < minDistanceSq {
                minDistanceSq = distSq
                index = i
            }
        }
        return index
    }
    
    /// 从当前轨迹中截取从 start 点到 end 点对应的子路段
    func subpath(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard count >= 2 else { return [] }
        let startIndex = self.indexOfClosestPoint(to: start)
        let endIndex = self.indexOfClosestPoint(to: end)
        
        let lower = Swift.min(startIndex, endIndex)
        let upper = Swift.max(startIndex, endIndex)
        
        guard upper - lower >= 1 else { return [] }
        return Array(self[lower...upper])
    }
}


extension CLLocationCoordinate2D {
    var isRenderableMapCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(self)
    }
}
