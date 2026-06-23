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
    private let maxDiskCacheSizeBytes: Int64 = 200 * 1024 * 1024
    private let maxFileAge: TimeInterval = 30 * 24 * 60 * 60
    private let maxUnusedAge: TimeInterval = 14 * 24 * 60 * 60
    private let cleanupInterval: TimeInterval = 12 * 60 * 60
    private let ioQueue = DispatchQueue(label: "com.difangke.mapSnapshotCache", qos: .utility)

    private init() {
        memoryCache.countLimit = 24
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("DFKMapSnapshots", isDirectory: true)
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        scheduleCleanupIfNeeded(force: false)
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
            updateAccessDate(for: url)
            scheduleCleanupIfNeeded(force: false)
            return diskImage
        }

        return nil
    }

    func setImage(_ image: UIImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

        let url = cacheURL(for: key)
        ioQueue.async {
            if let data = image.pngData() {
                try? data.write(to: url)
                Self.setDates(for: url, accessDate: Date(), modificationDate: Date())
            }
        }
        scheduleCleanupIfNeeded(force: false)
    }

    func removeImage(for key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        let url = cacheURL(for: key)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
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
        UserDefaults.standard.removeObject(forKey: Self.lastCleanupKey)
    }

    private func updateAccessDate(for url: URL) {
        ioQueue.async {
            Self.setDates(for: url, accessDate: Date(), modificationDate: nil)
        }
    }

    private func scheduleCleanupIfNeeded(force: Bool) {
        let now = Date()
        let defaults = UserDefaults.standard
        if !force,
           let lastCleanup = defaults.object(forKey: Self.lastCleanupKey) as? Date,
           now.timeIntervalSince(lastCleanup) < cleanupInterval {
            return
        }

        defaults.set(now, forKey: Self.lastCleanupKey)
        ioQueue.async { [cacheDirectory, maxFileAge, maxUnusedAge, maxDiskCacheSizeBytes] in
            let fileManager = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
            let files = (try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )) ?? []

            struct CacheEntry {
                let url: URL
                let size: Int64
                let modificationDate: Date
                let accessDate: Date
            }

            let entries: [CacheEntry] = files.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else {
                    return nil
                }

                let modificationDate = values.contentModificationDate ?? .distantPast
                let accessDate = values.contentAccessDate ?? modificationDate
                let size = Int64(values.fileSize ?? 0)
                return CacheEntry(url: url, size: size, modificationDate: modificationDate, accessDate: accessDate)
            }

            let expirationDate = now.addingTimeInterval(-maxFileAge)
            let unusedDeadline = now.addingTimeInterval(-maxUnusedAge)

            var retainedEntries: [CacheEntry] = []
            for entry in entries {
                if entry.modificationDate < expirationDate || entry.accessDate < unusedDeadline {
                    try? fileManager.removeItem(at: entry.url)
                } else {
                    retainedEntries.append(entry)
                }
            }

            var totalSize = retainedEntries.reduce(Int64(0)) { $0 + $1.size }
            if totalSize <= maxDiskCacheSizeBytes {
                return
            }

            for entry in retainedEntries.sorted(by: { $0.accessDate < $1.accessDate }) {
                try? fileManager.removeItem(at: entry.url)
                totalSize -= entry.size
                if totalSize <= maxDiskCacheSizeBytes {
                    break
                }
            }
        }
    }

    private static let lastCleanupKey = "dfk.mapSnapshotCache.lastCleanup"

    nonisolated private static func setDates(
        for url: URL,
        accessDate: Date?,
        modificationDate: Date?
    ) {
        var mutableURL = url
        var values = URLResourceValues()
        if let accessDate = accessDate {
            values.contentAccessDate = accessDate
        }
        if let modificationDate = modificationDate {
            values.contentModificationDate = modificationDate
        }
        try? mutableURL.setResourceValues(values)
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
    var isMiniTimelineMode: Bool = false
    var selectedTimeCoordinate: CLLocationCoordinate2D? = nil
    var timelineUpdateIdentifier: Int? = nil
    var onMapInteraction: ((MapInteractionType) -> Void)? = nil
    var showsMapControls: Bool = true

    enum MapInteractionType {
        case tap
        case pan
        case zoom
    }

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
        isMiniTimelineMode: Bool = false,
        selectedTimeCoordinate: CLLocationCoordinate2D? = nil,
        timelineUpdateIdentifier: Int? = nil,
        onMapInteraction: ((MapInteractionType) -> Void)? = nil,
        showsMapControls: Bool = true,
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
        self.isMiniTimelineMode = isMiniTimelineMode
        self.selectedTimeCoordinate = selectedTimeCoordinate
        self.timelineUpdateIdentifier = timelineUpdateIdentifier
        self.onMapInteraction = onMapInteraction
        self.showsMapControls = showsMapControls
        self.onTimelineItemTap = onTimelineItemTap
        self.onPhotoTap = onPhotoTap
    }

    @State private var snapshotImage: UIImage?
    @State private var snapshotTask: Task<Void, Never>?
    @State private var isSnapshotLoading = false
    @State private var snapshotLoadFailed = false
    @State private var lastSnapshotSize: CGSize = .zero
    @State private var lastSnapshotCacheKey: String? = nil

    @State private var isRequestingWidgetSnapshot = false
    @State private var selectedAggregatedFootprint: AggregatedFootprint?
    @State private var interactiveMapReady = false
    @State private var interactiveActivationTask: Task<Void, Never>?
    @State private var liveMapPhotoImages: [String: UIImage] = [:]
    @Environment(\.colorScheme) private var colorScheme

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
        if let selectedTimeCoordinate, selectedTimeCoordinate.isRenderableMapCoordinate {
            allCoords.append(selectedTimeCoordinate)
        }

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

    private var liveMapPhotoAssetIDs: [String] {
        let footprintIDs = aggregatedFootprints.compactMap { latestPhotoAssetID(for: $0) }
        let standaloneIDs = validPhotoAnnotations.map { $0.asset.localIdentifier }
        return Array(Set(footprintIDs + standaloneIDs)).sorted()
    }

    private var liveMapPhotoAssetCacheKey: String {
        liveMapPhotoAssetIDs.joined(separator: "|")
    }

    private func latestPhotoAssetID(for aggregated: AggregatedFootprint) -> String? {
        // 直接从足迹数据中提取，不依赖异步加载的 photoAssets 数组，确保渲染及时
        aggregated.footprints
            .sorted { $0.startTime > $1.startTime }
            .compactMap { $0.photoAssetIDs.first } // 匹配足迹卡片使用的 .first (最新)
            .first
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
                    if isInteractive && isValidSize && rendersLiveMap && interactiveMapReady {
                        if isMiniTimelineMode {
                            StableInteractiveMapView(
                                region: interactiveRegion,
                                showsUserLocation: showsUserLocation,
                                userDefinedPlaces: userDefinedPlaces,
                                transportItems: transportItems,
                                aggregatedFootprints: validAggregatedFootprints,
                                photoAnnotations: validPhotoAnnotations,
                                heatmapPoints: validHeatmapPoints,
                                mainAnnotationCoordinate: validMainAnnotationCoordinate,
                                selectedTimeCoordinate: selectedTimeCoordinate,
                                allActivities: allActivities,
                                colorScheme: colorScheme,
                                onFootprintTap: handleFootprintTap(for:),
                                onTransportTap: { transport in
                                    onTimelineItemTap?(.transport(transport))
                                },
                                onPhotoTap: { asset in
                                    onPhotoTap?(asset)
                                }
                            )
                        } else {
                            Map(position: $cameraPosition) {
                                ForEach(userDefinedPlaces) { place in
                                    MapCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
                                        .foregroundStyle(Color.orange.opacity(0.1))
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                }

                                transportMapContent()

                                ForEach(validAggregatedFootprints) { aggregated in
                                    Annotation("", coordinate: aggregated.coordinate, anchor: .bottom) {
                                        aggregatedAnnotationContent(for: aggregated)
                                            .zIndex(10)
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

                                if let coordinate = selectedTimeCoordinate, coordinate.isRenderableMapCoordinate {
                                    Annotation("", coordinate: coordinate) {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 16, height: 16)
                                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                    }
                                }

                                if showsUserLocation {
                                    UserAnnotation()
                                }
                            }
                            .mapStyle(.standard(elevation: .automatic, emphasis: .muted, pointsOfInterest: .excludingAll))
                            .simultaneousGesture(TapGesture().onEnded { onMapInteraction?(.tap) })
                            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in onMapInteraction?(.pan) })
                            .simultaneousGesture(MagnificationGesture().onChanged { _ in onMapInteraction?(.zoom) })
                            .mapControls {
                                if showsMapControls {
                                    MapUserLocationButton()
                                    MapCompass()
                                    MapScaleView()
                                }
                            }
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
                guard isInteractive else { return }
                interactiveActivationTask?.cancel()
                interactiveMapReady = false
                interactiveActivationTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if Task.isCancelled { return }
                    interactiveMapReady = true
                }
            }
            .task(id: snapshotCacheKey(for: geometry.size)) {
                guard !isInteractive else { return }
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .task(id: liveMapPhotoAssetCacheKey) {
                guard isInteractive else { return }
                await loadLiveMapPhotoImages()
            }
            .onDisappear {
                interactiveActivationTask?.cancel()
                interactiveMapReady = false
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
                } else if isSnapshotLoading || (isInteractive && !interactiveMapReady) {
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
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                }
            }
        }
        .clipped()
    }

    private func formatDuration(_ duration: TimeInterval) -> (number: String, unit: String) {
        let totalMinutes = Int(duration / 60)
        if totalMinutes < 60 {
            return ("\(max(1, totalMinutes))", "分钟")
        }
        let hours = Double(totalMinutes) / 60.0
        if hours >= 10.0 {
            return ("\(Int(round(hours)))", "小时")
        }
        let formatted = String(format: "%g", (hours * 10).rounded() / 10)
        return (formatted, "小时")
    }

    private func aggregatedAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        let fp = aggregated.representative
        let scale: CGFloat = 1.32
        let baseSize: CGFloat = isInteractive ? 25 : 20
        let size = isMiniTimelineMode ? 11 : baseSize * scale
        let activity = fp.getActivityType(from: allActivities)
        let activityColor = activity?.color ?? Color.gray
        let iconColor: Color = colorScheme == .dark ? .black : .white
        let iconName = activity?.icon ?? FootprintIconDefaults.card
        let iconSize: CGFloat = isMiniTimelineMode ? 9 : (activity?.icon == nil ? 18 : 13) * scale
        let durationTuple = formatDuration(aggregated.totalDuration)
        let fontSize = isInteractive ? 6.5 * scale : 5.5 * scale

        return ZStack(alignment: .top) {
            MapPinTeardropShape()
                .fill(activityColor)
                .frame(width: size, height: size * 1.2)

            // 根据 prefersActivityIcons 决定显示活动图标还是照片封面
            if !prefersActivityIcons, let latestPhotoAssetID = latestPhotoAssetID(for: aggregated) {
                let photoSize = size * 0.82
                if let image = liveMapPhotoImages[latestPhotoAssetID] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: photoSize, height: photoSize)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(iconColor.opacity(0.75), lineWidth: 1))
                        .offset(y: size * 0.07)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(iconColor)
                        .frame(width: size, height: size)
                }
            } else {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(iconColor)
                    .frame(width: size, height: size)
            }

            if !isMiniTimelineMode && aggregated.totalDuration >= AppConfig.shared.stayDurationThreshold {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(durationTuple.number)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    Text(durationTuple.unit)
                        .font(.system(size: fontSize * 0.75, weight: .bold, design: .rounded))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundColor(activityColor.darker(by: 0.30))
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(activityColor, lineWidth: 0.5)
                )
                .offset(y: size - 10 * scale)
            }
        }
        .padding(2 * scale)
        .frame(width: size + 4 * scale, height: size * 1.2 + 4 * scale)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func transportAnnotationContent(for transport: Transport) -> some View {
        let size: CGFloat = isMiniTimelineMode ? 7 : (isInteractive ? 18 : 14)
        let iconSize: CGFloat = isMiniTimelineMode ? 4 : (isInteractive ? 9 : 7)
        
        let transportIcon = ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.dfkAccent, lineWidth: 1.2))

            Image(systemName: transport.currentType.sfSymbol)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundColor(Color.dfkAccent)
        }
        .contentShape(Circle())

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
        let foregroundLineWidth: CGFloat = isInteractive ? 3 : 2
        let dashedOpacity: Double = 0.4
        let dashedLineWidth: CGFloat = isInteractive ? 1.5 : 1.1

        ForEach(transportItems) { transport in
            ForEach(transport.lineSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color.dfkAccent.opacity(segment.isDashed ? dashedOpacity : 0.7),
                        style: StrokeStyle(
                            lineWidth: segment.isDashed ? dashedLineWidth : foregroundLineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: segment.isDashed ? [5, 5] : []
                        )
                    )
            }

            let smoothedPoints = transport.lineSegments.flatMap { $0.coordinates }.filter(\.isRenderableMapCoordinate)
            if let coord = smoothedPoints.distanceMidpoint {
                Annotation("", coordinate: coord) {
                    transportAnnotationContent(for: transport)
                        .zIndex(0)
                }
            }
        }
    }



    @MapContentBuilder
    private func aggregatedFootprintAnnotations() -> some MapContent {
        ForEach(aggregatedFootprints) { aggregated in
            Annotation("", coordinate: aggregated.coordinate, anchor: .bottom) {
                aggregatedAnnotationContent(for: aggregated)
                    .zIndex(10)
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
        let size: CGFloat = isInteractive ? 60 : 46
        let cornerRadius: CGFloat = isInteractive ? 8 : 6
        let content = ZStack {
            Color(uiColor: .systemGray6)
            if let image = liveMapPhotoImages[asset.localIdentifier] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundColor(Color(uiColor: .systemGray))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
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
        let styleKey = colorScheme == .dark ? "dark" : "light"
        return [FootprintIconDefaults.mapSnapshotVersion, sizeKey, styleKey, annotationKey, pointKey, footprintKey, transportKey, photoKey, footprintPhotoKey, heatmapKey, showsUserLocation ? "user" : "nouser"].joined(separator: "#")
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

        let oldKey = lastSnapshotCacheKey
        snapshotTask = Task { @MainActor in
            guard let image = await buildSnapshotImageWithTimeout(size: size, timeoutSeconds: 12) else {
                if Task.isCancelled { return }
                isSnapshotLoading = false
                snapshotLoadFailed = true
                return
            }
            if Task.isCancelled { return }
            // 写入新缓存前删除旧版本
            if let oldKey, oldKey != cacheKey {
                DFKMapSnapshotCache.shared.removeImage(for: oldKey)
            }
            DFKMapSnapshotCache.shared.setImage(image, for: cacheKey)
            lastSnapshotCacheKey = cacheKey
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
        let strokeColor = colorScheme == .dark ? UIColor.black : UIColor.white

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

            // Pass 1: Draw all transport lines (bottom layer)
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
                    ctx.cgContext.setStrokeColor(
                        themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor
                    )
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1.1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])
            }

            // Pass 2: Draw all transport icons (middle layer)
            for item in timelineItems {
                guard case .transport(let transport) = item, transport.points.count >= 2 else { continue }

                let smoothedPoints = transport.lineSegments.flatMap { $0.coordinates }.filter(\.isRenderableMapCoordinate)
                if let midCoord = smoothedPoints.distanceMidpoint {
                    let midPoint = snapshot.point(for: midCoord)
                    let rect = CGRect(x: midPoint.x - 7, y: midPoint.y - 7, width: 14, height: 14)
                    let path = UIBezierPath(ovalIn: rect)
                    UIColor.systemBackground.setFill()
                    path.fill()
                    themeColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()

                    if let iconImage = UIImage(systemName: transport.currentType.sfSymbol) {
                        drawImageAspectFit(iconImage.withTintColor(themeColor), in: CGRect(x: midPoint.x - 4, y: midPoint.y - 4, width: 8, height: 8))
                    }
                }
            }

            for aggregated in aggregatedFootprints {
                let fp = aggregated.representative
                let point = snapshot.point(for: aggregated.coordinate)
                let scale: CGFloat = 1.32
                let markerSize = 20 * scale
                let iconSize = 23 * scale * 0.52
                let radius = markerSize / 2
                let center = CGPoint(x: point.x, y: point.y - radius * 1.4)
                let activity = fp.getActivityType(from: allActivities)
                let activityColor = UIColor(activity?.color ?? Color.gray)
                let iconColor: UIColor = colorScheme == .dark ? .black : .white

                let pinPath = CGMutablePath()
                pinPath.addArc(center: center, radius: radius, startAngle: 125 * .pi / 180, endAngle: 55 * .pi / 180, clockwise: false)
                pinPath.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.4))
                pinPath.closeSubpath()

                ctx.cgContext.setFillColor(activityColor.cgColor)
                ctx.cgContext.addPath(pinPath)
                ctx.cgContext.fillPath()
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: markerSize, height: markerSize)
                let contentRect = rect.insetBy(dx: markerSize * 0.14, dy: markerSize * 0.14)

                // 快照逻辑同步：若 prefersActivityIcons 为 false 且有照片，则显示封面
                if !prefersActivityIcons, let latestPhotoAssetID = latestPhotoAssetID(for: aggregated),
                   let photoImage = footprintPhotoImages[latestPhotoAssetID] {
                    let clipPath = UIBezierPath(ovalIn: contentRect)
                    ctx.cgContext.saveGState()
                    clipPath.addClip()
                    drawImageAspectFill(photoImage, in: contentRect)
                    ctx.cgContext.restoreGState()
                    iconColor.setStroke()
                    clipPath.lineWidth = 1
                    clipPath.stroke()
                } else {
                    let iconName = activity?.icon ?? FootprintIconDefaults.card
                    if let iconImage = UIImage(systemName: iconName) {
                        drawImageAspectFit(iconImage.withTintColor(iconColor), in: CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize))
                    }
                }

                if aggregated.totalDuration >= AppConfig.shared.stayDurationThreshold {
                    let durationTuple = formatDuration(aggregated.totalDuration)
                    let numberFont = UIFont.systemFont(ofSize: 5.5 * scale, weight: .bold)
                    let unitFont = UIFont.systemFont(ofSize: 5.5 * scale * 0.75, weight: .bold)
                    let darkerActivityColor: UIColor = {
                        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        activityColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                        return UIColor(hue: h, saturation: min(s * 1.1, 1), brightness: max(b - 0.30, 0), alpha: a)
                    }()
                    let attrStr = NSMutableAttributedString(
                        string: durationTuple.number,
                        attributes: [.font: numberFont, .foregroundColor: darkerActivityColor]
                    )
                    attrStr.append(NSAttributedString(
                        string: durationTuple.unit,
                        attributes: [.font: unitFont, .foregroundColor: darkerActivityColor]
                    ))
                    let textSize = attrStr.size()
                    let bannerWidth = textSize.width + 4
                    let bannerHeight = textSize.height + 2
                    let bannerY = center.y + radius - bannerHeight / 2 - 6 * scale
                    let bannerRect = CGRect(x: center.x - bannerWidth / 2, y: bannerY, width: bannerWidth, height: bannerHeight)
                    let bannerPath = UIBezierPath(roundedRect: bannerRect, cornerRadius: 3)
                    UIColor.systemBackground.setFill()
                    bannerPath.fill()
                    activityColor.setStroke()
                    bannerPath.lineWidth = 0.5 * scale
                    bannerPath.stroke()
                    attrStr.draw(in: CGRect(
                        x: center.x - textSize.width / 2,
                        y: bannerY + (bannerHeight - textSize.height) / 2,
                        width: textSize.width,
                        height: textSize.height
                    ))
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

    @MainActor
    private func loadLiveMapPhotoImages() async {
        let assetIDs = liveMapPhotoAssetIDs
        guard !assetIDs.isEmpty else {
            liveMapPhotoImages = [:]
            return
        }

        let neededIDs = assetIDs.filter { liveMapPhotoImages[$0] == nil }
        if !neededIDs.isEmpty {
            var loadedImages: [String: UIImage] = [:]
            for assetID in neededIDs {
                if Task.isCancelled { return }
                if let image = await loadLiveMapAssetImage(assetID: assetID, targetSize: CGSize(width: 120, height: 120)) {
                    loadedImages[assetID] = image
                }
            }
            if !loadedImages.isEmpty {
                liveMapPhotoImages.merge(loadedImages, uniquingKeysWith: { _, latest in latest })
            }
        }

        let visibleIDs = Set(assetIDs)
        liveMapPhotoImages = liveMapPhotoImages.filter { visibleIDs.contains($0.key) }
    }

    private func loadLiveMapAssetImage(assetID: String, targetSize: CGSize) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            func resumeOnce(with image: UIImage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                resumeOnce(with: image)
            }
        }
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
    let selectedTimeCoordinate: CLLocationCoordinate2D?
    let allActivities: [ActivityType]
    let colorScheme: ColorScheme
    let onFootprintTap: (DFKMapView.AggregatedFootprint) -> Void
    let onTransportTap: (Transport) -> Void
    let onPhotoTap: (PHAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = SafeMKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
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

        if let region {
            mapView.region = region
        }

        return mapView
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.overlayStyles.removeAll()
        coordinator.footprintsByID.removeAll()
        coordinator.transportsByID.removeAll()
        coordinator.photosByID.removeAll()

        mapView.delegate = nil

        let overlays = mapView.overlays
        let annotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak mapView] in
            guard let mapView else { return }
            mapView.removeOverlays(overlays)
            mapView.removeAnnotations(annotations)
        }
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
            let segments = transport.lineSegments
            guard !segments.isEmpty else { continue }

            for segment in segments {
                let line = MKPolyline(coordinates: segment.coordinates, count: segment.coordinates.count)
                context.coordinator.overlayStyles[ObjectIdentifier(line)] = OverlayStyle(
                    strokeColor: UIColor(Color.dfkAccent).withAlphaComponent(segment.isDashed ? 0.4 : 0.8),
                    fillColor: nil,
                    lineWidth: segment.isDashed ? 1.6 : 3,
                    dashPattern: segment.isDashed ? [8 as NSNumber, 8 as NSNumber] : nil
                )
                mapView.addOverlay(line)
            }

            let smoothedPoints = transport.lineSegments.flatMap { $0.coordinates }.filter(\.isRenderableMapCoordinate)
            if let midpoint = smoothedPoints.distanceMidpoint {
                mapView.addAnnotation(MapImageAnnotation(
                    coordinate: midpoint,
                    kind: .transport(transport.id.uuidString),
                    image: Coordinator.transportImage(symbolName: transport.currentType.sfSymbol)
                ))
            }
        }

        for aggregated in aggregatedFootprints {
            let activity = aggregated.representative.getActivityType(from: allActivities)
            let iconColor: UIColor = colorScheme == .dark ? .black : .white
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: aggregated.coordinate,
                kind: .footprint(aggregated.id),
                image: Coordinator.footprintImage(
                    symbolName: activity?.icon ?? FootprintIconDefaults.card,
                    color: UIColor(activity?.color ?? Color.secondary.opacity(0.5)),
                    iconColor: iconColor
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

        if let selectedTimeCoordinate, selectedTimeCoordinate.isRenderableMapCoordinate {
            mapView.addAnnotation(MapImageAnnotation(
                coordinate: selectedTimeCoordinate,
                kind: .selectedTime,
                image: Coordinator.selectedTimeImage()
            ))
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let annotationReuseIdentifier = "StableInteractiveMapAnnotation"

        var parent: StableInteractiveMapView
        var overlayStyles: [ObjectIdentifier: OverlayStyle] = [:]
        var footprintsByID: [String: DFKMapView.AggregatedFootprint] = [:]
        var transportsByID: [String: Transport] = [:]
        var photosByID: [String: PHAsset] = [:]
        
        var lastUpdateIdentifier: Int? = -1
        var lastSelectedCoordinateStr: String = ""

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
            
            // zPriority only controls annotation decluttering. Use the view layer
            // itself to enforce the visual stack: transport < footprint < photo.
            switch annotation.kind {
            case .transport:
                view.zPriority = .min
                view.displayPriority = .defaultLow
                view.layer.zPosition = 0
            case .footprint:
                view.zPriority = .max
                view.displayPriority = .required
                view.layer.zPosition = 10
            case .photo, .heatmap, .main, .selectedTime:
                view.zPriority = .max
                view.displayPriority = .required
                view.layer.zPosition = 20
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
            case .heatmap, .main, .selectedTime:
                break
            }
        }

        static func footprintImage(symbolName: String, color: UIColor, iconColor: UIColor) -> UIImage {
            let size = CGSize(width: 24, height: 24)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                color.setFill()
                context.cgContext.fillEllipse(in: rect)

                let iconSize = CGSize(width: 28 * 0.55, height: 28 * 0.55)
                let iconOrigin = CGPoint(x: (size.width - iconSize.width) / 2, y: (size.height - iconSize.height) / 2)
                UIImage(systemName: symbolName)?
                    .withTintColor(iconColor, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(origin: iconOrigin, size: iconSize))
            }
        }

        static func transportImage(symbolName: String) -> UIImage {
            let size = CGSize(width: 20, height: 20)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath(ovalIn: rect)
                UIColor.systemBackground.setFill()
                path.fill()
                UIColor(Color.dfkAccent).setStroke()
                path.lineWidth = 1.2
                path.stroke()

                UIImage(systemName: symbolName)?
                    .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
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

        static func selectedTimeImage() -> UIImage {
            let size = CGSize(width: 14, height: 14)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                UIColor.systemRed.setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemBackground.setStroke()
                context.cgContext.setLineWidth(2)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            }
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
        case selectedTime
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

private struct MapPinTeardropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 && rect.height > 0 else {
            path.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return path
        }

        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        path.addArc(center: center, radius: radius, startAngle: .degrees(125), endAngle: .degrees(55), clockwise: false)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

fileprivate extension Color {
    func darker(by percentage: CGFloat = 0.15) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return self
        }
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(max(b - percentage, 0.0)), opacity: Double(a))
    }

}
