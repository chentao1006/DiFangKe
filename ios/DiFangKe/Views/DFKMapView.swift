import SwiftUI
import MapKit
import SwiftData
import Photos

struct DFKTransportOverviewPoint: Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let intensity: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct DFKTransportIconPoint: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let type: TransportType
    let travelsWest: Bool
}

/// Review-map transport data, exactly as the review map has always drawn it,
/// but computed in background tasks and only read by the view.
private struct DFKReviewTransportGeometry {
    struct Route {
        let segment: TransportLineSegment
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
    }

    struct Midpoint {
        let coordinate: CLLocationCoordinate2D
        let type: TransportType
        let travelsWest: Bool
    }

    var key: String?
    /// Routes with the same shape drawn once, with their bounds for culling.
    var routes: [Route] = []
    var segments: [TransportLineSegment] = []
    var midpoints: [Midpoint] = []
    /// Real GPS samples fused on the base cell, used when the review does not
    /// supply its own trajectory overview points.
    var fusedPoints: [DFKTransportOverviewPoint] = []

    static func build(key: String, transports: [Transport], baseCell: Double) -> DFKReviewTransportGeometry {
        var geometry = DFKReviewTransportGeometry(key: key)
        var seen: Set<String> = []
        struct Bucket {
            var latitude = 0.0
            var longitude = 0.0
            var count = 0
        }
        var fused: [String: Bucket] = [:]
        for transport in transports {
            let segments = transport.lineSegments
            let transportCoordinates = segments.flatMap(\.coordinates).filter(\.isRenderableMapCoordinate)
            if let midpoint = transportCoordinates.distanceMidpoint {
                geometry.midpoints.append(.init(coordinate: midpoint, type: transport.currentType, travelsWest: transportCoordinates.travelsWest))
            }
            for pathPoint in transport.pathPoints where !pathPoint.isSyntheticPadding && pathPoint.coordinate.isRenderableMapCoordinate {
                let point = pathPoint.coordinate
                let fusedKey = "\(Int((point.longitude / baseCell).rounded())):\(Int((point.latitude / baseCell).rounded()))"
                var bucket = fused[fusedKey, default: Bucket()]
                bucket.latitude += point.latitude
                bucket.longitude += point.longitude
                bucket.count += 1
                fused[fusedKey] = bucket
            }
            for segment in segments {
                let coordinates = segment.coordinates.filter(\.isRenderableMapCoordinate)
                guard coordinates.count >= 2 else { continue }
                let step = max(1, coordinates.count / 24)
                var sampled = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
                if let last = coordinates.last,
                   sampled.last?.latitude != last.latitude || sampled.last?.longitude != last.longitude {
                    sampled.append(last)
                }
                let forward = sampled.map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) }.joined(separator: ";")
                let reverse = sampled.reversed().map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) }.joined(separator: ";")
                guard seen.insert("\(segment.isDashed ? "d" : "s"):\(min(forward, reverse))").inserted else { continue }
                let latitudes = coordinates.map(\.latitude)
                let longitudes = coordinates.map(\.longitude)
                geometry.routes.append(.init(
                    segment: segment,
                    minLatitude: latitudes.min() ?? 0,
                    maxLatitude: latitudes.max() ?? 0,
                    minLongitude: longitudes.min() ?? 0,
                    maxLongitude: longitudes.max() ?? 0
                ))
            }
        }
        geometry.segments = geometry.routes.map(\.segment)
        geometry.fusedPoints = fused.map { key, bucket in
            DFKTransportOverviewPoint(
                id: key,
                latitude: bucket.latitude / Double(bucket.count),
                longitude: bucket.longitude / Double(bucket.count),
                intensity: bucket.count
            )
        }
        return geometry
    }

    /// The visible area grown by 8% on each side.
    static func paddedBounds(_ region: MKCoordinateRegion) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let latitudePadding = region.span.latitudeDelta * 0.08
        let longitudePadding = region.span.longitudeDelta * 0.08
        return (
            region.center.latitude - region.span.latitudeDelta / 2 - latitudePadding,
            region.center.latitude + region.span.latitudeDelta / 2 + latitudePadding,
            region.center.longitude - region.span.longitudeDelta / 2 - longitudePadding,
            region.center.longitude + region.span.longitudeDelta / 2 + longitudePadding
        )
    }

    /// Zoomed out: every route, recorded and inferred, intersecting the screen.
    func visibleSegments(in region: MKCoordinateRegion, includesInferred: Bool) -> [TransportLineSegment] {
        let bounds = Self.paddedBounds(region)
        return routes.filter { route in
            (includesInferred || !route.segment.isDashed) &&
                route.maxLatitude >= bounds.minLatitude && route.minLatitude <= bounds.maxLatitude &&
                route.maxLongitude >= bounds.minLongitude && route.minLongitude <= bounds.maxLongitude
        }.map(\.segment)
    }

    /// The overview's trajectory points: the visible fused points, re-merged
    /// on a grid scaled to the view when zoomed out.
    static func overviewPoints(
        from points: [DFKTransportOverviewPoint],
        in region: MKCoordinateRegion,
        baseCell: Double
    ) -> [DFKTransportOverviewPoint] {
        let bounds = paddedBounds(region)
        let visible = points.filter {
            ($0.latitude >= bounds.minLatitude && $0.latitude <= bounds.maxLatitude) &&
            ($0.longitude >= bounds.minLongitude && $0.longitude <= bounds.maxLongitude)
        }

        let adaptiveCell = max(baseCell, max(region.span.latitudeDelta, region.span.longitudeDelta) / 110)
        guard adaptiveCell > baseCell else { return visible }

        struct Bucket {
            var latitude = 0.0
            var longitude = 0.0
            var intensity = 0
        }
        var buckets: [String: Bucket] = [:]
        for point in visible {
            let x = Int((point.longitude / adaptiveCell).rounded())
            let y = Int((point.latitude / adaptiveCell).rounded())
            let key = "\(x):\(y)"
            var bucket = buckets[key, default: Bucket()]
            bucket.latitude += point.latitude * Double(point.intensity)
            bucket.longitude += point.longitude * Double(point.intensity)
            bucket.intensity += point.intensity
            buckets[key] = bucket
        }
        return buckets.map { key, bucket in
            DFKTransportOverviewPoint(
                id: "adaptive:\(key)",
                latitude: bucket.latitude / Double(bucket.intensity),
                longitude: bucket.longitude / Double(bucket.intensity),
                intensity: bucket.intensity
            )
        }
    }

    /// Transport icons grouped by type on a grid of a seventh of the view,
    /// as before; groups off screen are skipped.
    func iconPoints(in region: MKCoordinateRegion, culls: Bool) -> [DFKTransportIconPoint] {
        let latitudeCell = max(region.span.latitudeDelta / 7, 0.000_01)
        let longitudeCell = max(region.span.longitudeDelta / 7, 0.000_01)

        struct Bucket {
            var latitude = 0.0
            var longitude = 0.0
            var count = 0
            let type: TransportType
            var westwardCount = 0
        }
        var buckets: [String: Bucket] = [:]
        for midpoint in midpoints {
            let x = Int((midpoint.coordinate.longitude / longitudeCell).rounded())
            let y = Int((midpoint.coordinate.latitude / latitudeCell).rounded())
            let key = "\(midpoint.type.rawValue):\(x):\(y)"
            if var bucket = buckets[key] {
                bucket.latitude += midpoint.coordinate.latitude
                bucket.longitude += midpoint.coordinate.longitude
                bucket.count += 1
                if midpoint.travelsWest { bucket.westwardCount += 1 }
                buckets[key] = bucket
            } else {
                buckets[key] = Bucket(
                    latitude: midpoint.coordinate.latitude,
                    longitude: midpoint.coordinate.longitude,
                    count: 1,
                    type: midpoint.type,
                    westwardCount: midpoint.travelsWest ? 1 : 0
                )
            }
        }

        let bounds = Self.paddedBounds(region)
        return buckets.compactMap { key, bucket in
            let coordinate = CLLocationCoordinate2D(
                latitude: bucket.latitude / Double(bucket.count),
                longitude: bucket.longitude / Double(bucket.count)
            )
            if culls {
                guard coordinate.latitude >= bounds.minLatitude, coordinate.latitude <= bounds.maxLatitude,
                      coordinate.longitude >= bounds.minLongitude, coordinate.longitude <= bounds.maxLongitude else { return nil }
            }
            return DFKTransportIconPoint(
                id: key,
                coordinate: coordinate,
                type: bucket.type,
                travelsWest: bucket.westwardCount * 2 > bucket.count
            )
        }
    }
}

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
        memoryCache.totalCostLimit = 32 * 1024 * 1024
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
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: Self.memoryCost(of: diskImage))
            updateAccessDate(for: url)
            scheduleCleanupIfNeeded(force: false)
            return diskImage
        }

        return nil
    }

    func setImage(_ image: UIImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))

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

    func removeAllMemoryImages() {
        memoryCache.removeAllObjects()
    }

    private static func memoryCost(of image: UIImage) -> Int {
        (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
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

func reviewIntegratedPlaceKey(for footprint: Footprint, allPlaces: [Place]) -> String {
    let placeName = footprint.placeID.flatMap { placeID in
        allPlaces.first(where: { $0.placeID == placeID })?.name
    }?.trimmingCharacters(in: .whitespacesAndNewlines)
    let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = [placeName, address]
        .compactMap { $0 }
        .first { !$0.isEmpty }
        .map(normalizedPlaceSearchKey) ?? ""

    if !displayName.isEmpty {
        let country = normalizedPlaceSearchKey(footprint.countryCode ?? footprint.countryName ?? "")
        let city = normalizedPlaceSearchKey(footprint.cityName ?? "")
        return "named:\(country):\(city):\(displayName)"
    }

    let factor = 1_000.0
    let latitude = (footprint.latitude * factor).rounded() / factor
    let longitude = (footprint.longitude * factor).rounded() / factor
    return "coordinate:\(latitude),\(longitude)"
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
    var condensesTransportOverview: Bool = false
    var clustersPlacesByMapScale: Bool = false
    var placeClusterRegion: MKCoordinateRegion? = nil
    var showsUserDefinedPlaceRadii: Bool = true
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var transportOverviewPoints: [DFKTransportOverviewPoint] = []
    var isMiniTimelineMode: Bool = false
    var selectedFootprintID: UUID? = nil
    var selectedFootprintCoordinate: CLLocationCoordinate2D? = nil
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

    struct AggregatedFootprint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let totalDuration: TimeInterval
        let representative: Footprint
        let footprints: [Footprint]
        let placeCount: Int
    }



    var heatmapPoints: [HeatmapPoint] = []

    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    /// Hosts that present sheets from another window (Records) present the
    /// footprint group themselves; otherwise this map presents it.
    var onAggregatedFootprintTap: ((AggregatedFootprint) -> Void)? = nil
    var onPhotoTap: ((PHAsset) -> Void)? = nil
    var onUserLocationTap: (() -> Void)? = nil

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
        condensesTransportOverview: Bool = false,
        clustersPlacesByMapScale: Bool = false,
        placeClusterRegion: MKCoordinateRegion? = nil,
        showsUserDefinedPlaceRadii: Bool = true,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        transportOverviewPoints: [DFKTransportOverviewPoint] = [],
        isMiniTimelineMode: Bool = false,
        selectedFootprintID: UUID? = nil,
        selectedFootprintCoordinate: CLLocationCoordinate2D? = nil,
        selectedTimeCoordinate: CLLocationCoordinate2D? = nil,
        timelineUpdateIdentifier: Int? = nil,
        onMapInteraction: ((MapInteractionType) -> Void)? = nil,
        showsMapControls: Bool = true,
        onTimelineItemTap: ((TimelineItem) -> Void)? = nil,
        onAggregatedFootprintTap: ((AggregatedFootprint) -> Void)? = nil,
        onPhotoTap: ((PHAsset) -> Void)? = nil,
        onUserLocationTap: (() -> Void)? = nil
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
        self.condensesTransportOverview = condensesTransportOverview
        self.clustersPlacesByMapScale = clustersPlacesByMapScale
        self.placeClusterRegion = placeClusterRegion
        self.showsUserDefinedPlaceRadii = showsUserDefinedPlaceRadii
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.transportOverviewPoints = transportOverviewPoints
        self.isMiniTimelineMode = isMiniTimelineMode
        self.selectedFootprintID = selectedFootprintID
        self.selectedFootprintCoordinate = selectedFootprintCoordinate
        self.selectedTimeCoordinate = selectedTimeCoordinate
        self.timelineUpdateIdentifier = timelineUpdateIdentifier
        self.onMapInteraction = onMapInteraction
        self.showsMapControls = showsMapControls
        self.onTimelineItemTap = onTimelineItemTap
        self.onAggregatedFootprintTap = onAggregatedFootprintTap
        self.onPhotoTap = onPhotoTap
        self.onUserLocationTap = onUserLocationTap
    }

    @State private var snapshotImage: UIImage?
    @State private var placeClusterVisibleRegion: MKCoordinateRegion?
    @State private var snapshotTask: Task<Void, Never>?
    @State private var isSnapshotLoading = false
    @State private var snapshotLoadFailed = false
    @State private var lastSnapshotSize: CGSize = .zero
    @State private var lastSnapshotCacheKey: String? = nil

    @State private var selectedAggregatedFootprint: AggregatedFootprint?
    @State private var footprintSelectedFromGroup: Footprint?
    @State private var interactiveMapReady = false
    @State private var interactiveActivationTask: Task<Void, Never>?
    @State private var liveMapPhotoImages: [String: UIImage] = [:]
    @State private var transportOverviewVisibleRegion: MKCoordinateRegion?
    // Review transport data, computed in background tasks and only read here.
    @State private var reviewTransportGeometry = DFKReviewTransportGeometry()
    @State private var reviewVisibleSegments: [TransportLineSegment] = []
    @State private var reviewOverviewPoints: [DFKTransportOverviewPoint] = []
    /// Zoomed in: real paths only. Zoomed out: lines incl. inferred jumps,
    /// plus trajectory points.
    @State private var reviewShowsDetailedPaths = false
    @State private var reviewTransportIcons: [DFKTransportIconPoint] = []
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

    private var currentTopSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

    private var transportItems: [Transport] {
        timelineItems.compactMap { item in
            guard case .transport(let transport) = item,
                  transport.points.filter(\.isRenderableMapCoordinate).count >= 2 else { return nil }
            return transport
        }
    }

    /// The sampled trajectory overview belongs only to Review. The footprint
    /// map must always render its own Transport records and inferred gaps.
    private var usesReviewTransportOverview: Bool {
        condensesTransportOverview && clustersPlacesByMapScale
    }

    private var renderedTransportSegments: [TransportLineSegment] {
        guard usesReviewTransportOverview else { return transportItems.flatMap(\.lineSegments) }
        return reviewTransportGeometry.segments
    }

    private var reviewTransportGeometryKey: String {
        guard usesReviewTransportOverview else { return "off" }
        return "\(timelineItems.count)|\(timelineItems.first?.id ?? "")|\(timelineItems.last?.id ?? "")"
    }

    private var reviewTransportVisibleKey: String {
        guard let region = transportOverviewVisibleRegion ?? placeClusterRegion else { return "\(reviewTransportGeometry.key ?? "")#none" }
        // Review's fused points arrive later than the geometry; refresh then too.
        return String(
            format: "%@#%d#%.5f,%.5f,%.5f,%.5f",
            reviewTransportGeometry.key ?? "",
            transportOverviewPoints.count,
            region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta
        )
    }

    /// Rebuilds the review transport geometry off the main thread whenever
    /// the timeline items change.
    private func refreshReviewTransportGeometry() async {
        let key = reviewTransportGeometryKey
        guard usesReviewTransportOverview else { return }
        let transports = timelineItems.compactMap { item -> Transport? in
            if case .transport(let transport) = item { return transport }
            return nil
        }
        let baseCell = AppConfig.shared.reviewMapTrajectoryBaseCellDegrees
        let geometry = await Task.detached(priority: .userInitiated) {
            DFKReviewTransportGeometry.build(key: key, transports: transports, baseCell: baseCell)
        }.value
        guard !Task.isCancelled else { return }
        reviewTransportGeometry = geometry
    }

    /// Picks the lines, trajectory points and icons for the area on screen,
    /// off the main thread; anything off screen is left out.
    private func refreshReviewVisibleTransport() async {
        guard usesReviewTransportOverview,
              reviewTransportGeometry.key != nil,
              let region = transportOverviewVisibleRegion ?? placeClusterRegion else { return }
        let geometry = reviewTransportGeometry
        let baseCell = AppConfig.shared.reviewMapTrajectoryBaseCellDegrees
        let pathMaxSpan = AppConfig.shared.reviewMapTrajectoryPathMaxSpan
        let isInteractive = isInteractive
        let hasVisibleRegion = transportOverviewVisibleRegion != nil
        let providedOverviewPoints = transportOverviewPoints
        let result = await Task.detached(priority: .userInitiated) {
            let showsDetailedPaths = isInteractive && hasVisibleRegion
                && max(region.span.latitudeDelta, region.span.longitudeDelta) <= pathMaxSpan
            let points = providedOverviewPoints.isEmpty ? geometry.fusedPoints : providedOverviewPoints
            return (
                showsDetailedPaths: showsDetailedPaths,
                segments: geometry.visibleSegments(in: region, includesInferred: !showsDetailedPaths),
                overviewPoints: showsDetailedPaths
                    ? []
                    : DFKReviewTransportGeometry.overviewPoints(from: points, in: region, baseCell: baseCell),
                icons: geometry.iconPoints(in: region, culls: isInteractive && hasVisibleRegion)
            )
        }.value
        guard !Task.isCancelled, geometry.key == reviewTransportGeometry.key else { return }
        reviewShowsDetailedPaths = result.showsDetailedPaths
        reviewVisibleSegments = result.segments
        reviewOverviewPoints = result.overviewPoints
        reviewTransportIcons = result.icons
    }

    private var renderedTransportAnnotationItems: [Transport] {
        guard usesReviewTransportOverview else { return transportItems }
        return Dictionary(grouping: transportItems, by: \.currentType).compactMap { _, items in
            items.max { $0.distance < $1.distance }
        }
    }

    private var fusedTransportPoints: [DFKTransportOverviewPoint] {
        guard usesReviewTransportOverview else { return [] }
        return transportOverviewPoints.isEmpty ? reviewTransportGeometry.fusedPoints : transportOverviewPoints
    }

    private var displayedTransportIconPoints: [DFKTransportIconPoint] {
        reviewTransportIcons
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

    private var placeAggregatedFootprints: [AggregatedFootprint] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalWeight: TimeInterval
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
            if clustersPlacesByMapScale {
                key = reviewIntegratedPlaceKey(for: footprint, allPlaces: allPlaces)
            } else if let placeID = footprint.placeID {
                key = "place:\(placeID.uuidString)"
            } else if !footprint.locationHash.isEmpty {
                key = "hash:\(footprint.locationHash)"
            } else {
                key = String(format: "coord:%.5f,%.5f", footprint.latitude, footprint.longitude)
            }

            if var bucket = buckets[key] {
                bucket.weightedLatitude += footprint.latitude * durationWeight
                bucket.weightedLongitude += footprint.longitude * durationWeight
                bucket.totalWeight += durationWeight
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
                    totalWeight: durationWeight,
                    totalDuration: footprint.duration,
                    representative: footprint,
                    footprints: [footprint]
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let divisor = max(bucket.totalWeight, 1)
            let representative = selectedFootprintID.flatMap { selectedID in
                bucket.footprints.first { $0.footprintID == selectedID }
            } ?? bucket.representative
            return AggregatedFootprint(
                id: key,
                // Detail selection represents this footprint, not the
                // duration-weighted position of every visit at the same place.
                coordinate: selectedFootprintID == representative.footprintID
                    ? (selectedFootprintCoordinate ?? CLLocationCoordinate2D(latitude: representative.latitude, longitude: representative.longitude))
                    : CLLocationCoordinate2D(
                    latitude: bucket.weightedLatitude / divisor,
                    longitude: bucket.weightedLongitude / divisor
                ),
                totalDuration: bucket.totalDuration,
                representative: representative,
                footprints: bucket.footprints.sorted { $0.startTime < $1.startTime },
                placeCount: 1
            )
        }
    }

    private var aggregatedFootprints: [AggregatedFootprint] {
        let places = placeAggregatedFootprints
        guard clustersPlacesByMapScale,
              let region = placeClusterVisibleRegion ?? placeClusterRegion,
              places.count > 1 else {
            return places
        }

        let latitudeCell = max(region.span.latitudeDelta / 7, 0.000_001)
        let longitudeCell = max(region.span.longitudeDelta / 7, 0.000_001)
        let latitudeOrigin = region.center.latitude - region.span.latitudeDelta / 2
        let longitudeOrigin = region.center.longitude - region.span.longitudeDelta / 2
        // Only cells on screen plus a one-cell margin get markers. Off-screen
        // places are invisible anyway; grouping them too made a zoomed-in map
        // build one marker (and one photo) per place for the whole period,
        // which starved the map renderer and the app of memory.
        let visibleCells = -1...7
        var grouped: [String: [AggregatedFootprint]] = [:]
        for place in places {
            let latitudeIndex = Int(floor((place.coordinate.latitude - latitudeOrigin) / latitudeCell))
            let longitudeIndex = Int(floor((place.coordinate.longitude - longitudeOrigin) / longitudeCell))
            guard visibleCells.contains(latitudeIndex), visibleCells.contains(longitudeIndex) else { continue }
            grouped["\(latitudeIndex):\(longitudeIndex)", default: []].append(place)
        }

        return grouped.keys.sorted().compactMap { key in
            guard let members = grouped[key], let first = members.first else { return nil }
            guard members.count > 1 else { return first }
            let totalWeight = members.reduce(0.0) { $0 + max($1.totalDuration, 1) }
            let latitude = members.reduce(0.0) {
                $0 + $1.coordinate.latitude * max($1.totalDuration, 1)
            } / totalWeight
            let longitude = members.reduce(0.0) {
                $0 + $1.coordinate.longitude * max($1.totalDuration, 1)
            } / totalWeight
            let representative = members.max { $0.totalDuration < $1.totalDuration }?.representative ?? first.representative
            return AggregatedFootprint(
                id: "cluster:\(key):\(members.map(\.id).sorted().joined(separator: "|"))",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                totalDuration: members.reduce(0) { $0 + $1.totalDuration },
                representative: representative,
                footprints: members.flatMap(\.footprints).sorted { $0.startTime < $1.startTime },
                placeCount: members.reduce(0) { $0 + $1.placeCount }
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
                                },
                                onUserLocationTap: onUserLocationTap
                            )
                        } else {
                            Map(position: $cameraPosition) {
                                if showsUserDefinedPlaceRadii {
                                    ForEach(userDefinedPlaces) { place in
                                        MapCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
                                            .foregroundStyle(Color.orange.opacity(0.1))
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    }
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
                                    Annotation("", coordinate: entry.coordinate, anchor: .bottom) {
                                        Button {
                                            onPhotoTap?(entry.asset)
                                        } label: {
                                            photoAnnotationContent(for: entry.asset)
                                                .zIndex(100)
                                        }
                                        .buttonStyle(.plain)
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
                            .id(timelineUpdateIdentifier ?? 0)
                            .mapStyle(.standard(elevation: .automatic, emphasis: .muted))
                            .onMapCameraChange(frequency: .onEnd) { context in
                                if usesReviewTransportOverview {
                                    transportOverviewVisibleRegion = context.region
                                }
                                if clustersPlacesByMapScale {
                                    placeClusterVisibleRegion = context.region
                                }
                            }
                            // Handle taps on the map surface itself. Native map
                            // controls are subviews and must keep their own taps
                            // without forwarding them to the host's collapse action.
                            .simultaneousGesture(
                                TapGesture().onEnded { onMapInteraction?(.tap) },
                                including: .gesture
                            )
                            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in onMapInteraction?(.pan) })
                            .simultaneousGesture(MagnificationGesture().onChanged { _ in onMapInteraction?(.zoom) })
                            .mapControls {
                                if showsMapControls {
                                    if showsUserLocation {
                                        MapUserLocationButton()
                                    }
                                    MapCompass()
                                    MapScaleView()
                                }
                            }
                            .safeAreaPadding(.top, currentTopSafeAreaInset)
                        }
                    } else {
                        snapshotContent(for: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .sheet(item: $selectedAggregatedFootprint, onDismiss: {
                guard let footprint = footprintSelectedFromGroup else { return }
                footprintSelectedFromGroup = nil
                onTimelineItemTap?(.footprint(footprint))
            }) { aggregated in
                FootprintGroupSheet(aggregated: aggregated, allPlaces: allPlaces) { footprint in
                    footprintSelectedFromGroup = footprint
                    selectedAggregatedFootprint = nil
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
            .task(id: isInteractive ? nil : "\(snapshotCacheKey(for: geometry.size))#generate:\(allowsGeneratedSnapshot)") {
                guard !isInteractive else { return }
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .onChange(of: colorScheme) { _, _ in
                guard !isInteractive else { return }
                snapshotTask?.cancel()
                snapshotImage = nil
                snapshotLoadFailed = false
                loadSnapshot(for: geometry.size, forceWidgetRefresh: false)
            }
            .task(id: reviewTransportGeometryKey) {
                await refreshReviewTransportGeometry()
            }
            .task(id: reviewTransportVisibleKey) {
                await refreshReviewVisibleTransport()
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
            if let onAggregatedFootprintTap {
                onAggregatedFootprintTap(aggregated)
            } else {
                selectedAggregatedFootprint = aggregated
            }
            return
        }

        guard let footprint = aggregated.footprints.first else { return }
        onTimelineItemTap?(.footprint(footprint))
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

    @ViewBuilder
    private func aggregatedAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        if clustersPlacesByMapScale {
            reviewPlaceAnnotationContent(for: aggregated)
        } else {
            standardFootprintAnnotationContent(for: aggregated)
        }
    }

    @ViewBuilder
    private func reviewPlaceAnnotationContent(for aggregated: AggregatedFootprint) -> some View {
        // Zoomed in to a single place, it is just a footprint: show it the
        // way every footprint map does, with its activity icon.
        if aggregated.placeCount == 1 {
            standardFootprintAnnotationContent(for: aggregated, showsPhoto: false)
        } else {
            DFKReviewPlaceMapMarker(
                placeCount: aggregated.placeCount,
                photoImage: latestPhotoAssetID(for: aggregated).flatMap { liveMapPhotoImages[$0] }
            )
        }
    }

    private func standardFootprintAnnotationContent(for aggregated: AggregatedFootprint, showsPhoto: Bool? = nil) -> some View {
        let fp = aggregated.representative
        let isSelected = aggregated.footprints.contains { $0.footprintID == selectedFootprintID }
        let constantScale: CGFloat = 1.32
        let baseSize: CGFloat = isInteractive ? 25 : 20
        let size = isMiniTimelineMode ? 11 : baseSize * constantScale
        let activity = fp.getActivityType(from: allActivities)
        let activityColor = activity?.color ?? Color.gray
        let iconColor: Color = .white
        let iconName = activity?.icon ?? FootprintIconDefaults.card
        let iconSize: CGFloat = isMiniTimelineMode ? 9 : (activity?.icon == nil ? 18 : 10) * constantScale
        let durationTuple = formatDuration(aggregated.totalDuration)
        let fontSize = isInteractive ? 6.5 * constantScale : 5.5 * constantScale

        let photoImage = (showsPhoto ?? !prefersActivityIcons)
            ? latestPhotoAssetID(for: aggregated).flatMap { liveMapPhotoImages[$0] }
            : nil
        return DFKFootprintMapMarker(
            size: size,
            constantScale: constantScale,
            activityColor: activityColor,
            iconColor: iconColor,
            iconName: iconName,
            iconSize: iconSize,
            photoImage: photoImage,
            durationTuple: isMiniTimelineMode || aggregated.totalDuration < AppConfig.shared.stayDurationThreshold ? nil : durationTuple,
            fontSize: fontSize
        )
        .scaleEffect(isSelected ? 1.5 : 1.0, anchor: .bottom)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: selectedFootprintID)
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
                .scaleEffect(x: transport.lineSegments.flatMap(\.coordinates).filter(\.isRenderableMapCoordinate).travelsWest ? -1 : 1, y: 1)
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

    private func transportOverviewIcon(_ point: DFKTransportIconPoint) -> some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.dfkAccent, lineWidth: 1.5))
            .overlay {
                Image(systemName: point.type.sfSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.dfkAccent)
                    .scaleEffect(x: point.travelsWest ? -1 : 1, y: 1)
            }
    }

    @MapContentBuilder
    private func transportMapContent() -> some MapContent {
        if usesReviewTransportOverview {
            if reviewShowsDetailedPaths {
                ForEach(reviewVisibleSegments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(
                            Color.dfkAccent.opacity(0.68),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                }
            } else {
                ForEach(reviewVisibleSegments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(
                            Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.65),
                            style: StrokeStyle(
                                lineWidth: segment.isDashed ? 1 : 2.5,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: segment.isDashed ? [4, 4] : []
                            )
                        )
                }

                ForEach(reviewOverviewPoints) { point in
                    MapCircle(
                        center: point.coordinate,
                        radius: min(7, 3.5 + log2(Double(max(1, point.intensity))))
                    )
                    .foregroundStyle(Color.dfkAccent.opacity(min(0.72, 0.36 + log2(Double(max(1, point.intensity))) * 0.06)))
                }
            }

            ForEach(displayedTransportIconPoints) { point in
                Annotation("", coordinate: point.coordinate) {
                    transportOverviewIcon(point)
                        .zIndex(5)
                }
            }
        } else {
            ForEach(renderedTransportSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.7),
                        style: StrokeStyle(
                            lineWidth: segment.isDashed ? 1 : (isInteractive ? 3 : 2),
                            lineCap: .round,
                            lineJoin: .round,
                            dash: segment.isDashed ? [4, 4] : []
                        )
                    )
            }

            ForEach(renderedTransportAnnotationItems) { transport in
                let smoothedPoints = transport.lineSegments.flatMap { $0.coordinates }.filter(\.isRenderableMapCoordinate)
                if let coord = smoothedPoints.distanceMidpoint {
                    Annotation("", coordinate: coord) {
                        transportAnnotationContent(for: transport)
                            .zIndex(0)
                    }
                }
            }
        }
    }



    @MapContentBuilder
    private func photoAnnotations() -> some MapContent {
        ForEach(photoAssets, id: \.localIdentifier) { asset in
            if let coord = asset.location?.gcj02.coordinate {
                Annotation("", coordinate: coord, anchor: .bottom) {
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
        let tipHeight: CGFloat = isInteractive ? 10 : 8
        let contentInset: CGFloat = 4
        let contentSize = size - contentInset * 2
        let content = ZStack(alignment: .top) {
            PhotoMapMarkerShape(cornerRadius: cornerRadius, tipHeight: tipHeight)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
                .frame(width: size, height: size + tipHeight)

            ZStack {
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
            .frame(width: contentSize, height: contentSize)
            .clipShape(RoundedRectangle(cornerRadius: max(2, cornerRadius - 2), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: max(2, cornerRadius - 2), style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.8)
            }
            .offset(y: contentInset)
        }
        .overlay {
            PhotoMapMarkerShape(cornerRadius: cornerRadius, tipHeight: tipHeight)
                .stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
                .frame(width: size, height: size + tipHeight)
        }
        .frame(width: size, height: size + tipHeight)
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
        let w = Int(size.width / 10) * 10
        let h = Int(size.height / 10) * 10
        let sizeKey = "\(w)x\(h)"
        let styleKey = colorScheme == .dark ? "dark" : "light"
        let insetKey = "inset:\(Int(topContentInset.rounded())):\(Int(bottomContentInset.rounded()))"
        let overviewKey = "overview:\(transportOverviewPoints.count):\(transportOverviewPoints.reduce(0) { $0 + $1.intensity })"
        let routeStyleKey = usesReviewTransportOverview
            ? "review-routes-share-style-v1:\(reviewTransportGeometry.key ?? "pending"):\(reviewTransportIcons.count)"
            : "standard-transport-routes-dashed-v2"
        if let timelineUpdateIdentifier {
            return [
                FootprintIconDefaults.mapSnapshotVersion,
                sizeKey,
                styleKey,
                insetKey,
                overviewKey,
                routeStyleKey,
                "timeline:\(timelineUpdateIdentifier)",
                showsUserLocation ? "user" : "nouser"
            ].joined(separator: "#")
        }

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
        let placeClusterKey = clustersPlacesByMapScale
            ? aggregatedFootprints.map {
                "\($0.id):\($0.placeCount):\(String(format: "%.4f,%.4f", $0.coordinate.latitude, $0.coordinate.longitude))"
            }.joined(separator: "|")
            : "no-place-clusters"
        let heatmapKey = heatmapPoints.prefix(8).map(\.id).joined(separator: "|")
        let annotationKey = mainAnnotationCoordinate.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "none"
        return [FootprintIconDefaults.mapSnapshotVersion, sizeKey, styleKey, insetKey, overviewKey, routeStyleKey, showsUserDefinedPlaceRadii ? "place-radii" : "no-place-radii", annotationKey, pointKey, footprintKey, transportKey, photoKey, footprintPhotoKey, placeClusterKey, heatmapKey, showsUserLocation ? "user" : "nouser"].joined(separator: "#")
    }

    private func loadSnapshot(for size: CGSize, forceWidgetRefresh: Bool = false) {
        lastSnapshotSize = size

        guard size.width > 1, size.height > 1, hasVisibleContent else {
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = nil
            return
        }

        let cacheKey = snapshotCacheKey(for: size)
        if !forceWidgetRefresh, let cached = DFKMapSnapshotCache.shared.image(for: cacheKey) {
            isSnapshotLoading = false
            snapshotLoadFailed = false
            lastSnapshotCacheKey = cacheKey
            snapshotImage = cached
            return
        }

        guard allowsGeneratedSnapshot else {
            snapshotTask?.cancel()
            isSnapshotLoading = false
            snapshotLoadFailed = false
            snapshotImage = nil
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
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: colorScheme == .dark ? .dark : .light
        )

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
        let themeColor = UIColor(named: "AccentColor") ?? .systemTeal
        let strokeColor = colorScheme == .dark ? UIColor.black : UIColor.white
        let renderedFootprintMarkers: [(coordinate: CLLocationCoordinate2D, image: UIImage)] = aggregatedFootprints.compactMap { aggregated in
            let footprint = aggregated.representative
            let activity = footprint.getActivityType(from: allActivities)
            let constantScale: CGFloat = 1.32
            let size: CGFloat = 20 * constantScale
            let marker: AnyView
            if clustersPlacesByMapScale, aggregated.placeCount > 1 {
                marker = AnyView(DFKReviewPlaceMapMarker(
                    placeCount: aggregated.placeCount,
                    photoImage: latestPhotoAssetID(for: aggregated).flatMap { footprintPhotoImages[$0] }
                ))
            } else {
                marker = AnyView(DFKFootprintMapMarker(
                    size: size,
                    constantScale: constantScale,
                    activityColor: activity?.color ?? .gray,
                    iconColor: .white,
                    iconName: activity?.icon ?? FootprintIconDefaults.card,
                    iconSize: (activity?.icon == nil ? 18 : 10) * constantScale,
                    // A single review place is drawn as its footprint's activity icon.
                    photoImage: prefersActivityIcons || clustersPlacesByMapScale
                        ? nil
                        : latestPhotoAssetID(for: aggregated).flatMap { footprintPhotoImages[$0] },
                    durationTuple: aggregated.totalDuration >= AppConfig.shared.stayDurationThreshold
                        ? formatDuration(aggregated.totalDuration)
                        : nil,
                    fontSize: 5.5 * constantScale
                ))
            }
            let imageRenderer = ImageRenderer(content: marker.environment(\.colorScheme, colorScheme))
            imageRenderer.scale = UIScreen.main.scale
            guard let image = imageRenderer.uiImage else { return nil }
            return (aggregated.coordinate, image)
        }

        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            for place in allPlaces.filter({ showsUserDefinedPlaceRadii && $0.isUserDefined }) {
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

            if usesReviewTransportOverview {
                for segment in renderedTransportSegments {
                    let points = segment.coordinates.map { snapshot.point(for: $0) }
                    guard let first = points.first, points.count >= 2 else { continue }
                    ctx.cgContext.beginPath()
                    ctx.cgContext.move(to: first)
                    for point in points.dropFirst() {
                        ctx.cgContext.addLine(to: point)
                    }
                    ctx.cgContext.setStrokeColor(themeColor.withAlphaComponent(segment.isDashed ? 0.4 : 0.65).cgColor)
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                for fusedPoint in fusedTransportPoints {
                    let point = snapshot.point(for: fusedPoint.coordinate)
                    let diameter = min(5.5, 2.5 + CGFloat(log2(Double(max(1, fusedPoint.intensity)))) * 0.7)
                    let rect = CGRect(
                        x: point.x - diameter / 2,
                        y: point.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    ctx.cgContext.setFillColor(
                        themeColor.withAlphaComponent(min(0.72, 0.34 + CGFloat(log2(Double(max(1, fusedPoint.intensity)))) * 0.06)).cgColor
                    )
                    ctx.cgContext.fillEllipse(in: rect)
                }

                for iconPoint in displayedTransportIconPoints {
                    let point = snapshot.point(for: iconPoint.coordinate)
                    let circleRect = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
                    UIColor.systemBackground.setFill()
                    UIBezierPath(ovalIn: circleRect).fill()
                    themeColor.setStroke()
                    let outline = UIBezierPath(ovalIn: circleRect)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    if let sourceImage = UIImage(systemName: iconPoint.type.sfSymbol) {
                        let iconImage = iconPoint.travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                        drawImageAspectFit(
                            iconImage.withTintColor(themeColor),
                            in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
                        )
                    }
                }
            } else {
                for segment in renderedTransportSegments {
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
                    ctx.cgContext.setLineWidth(segment.isDashed ? 1 : 2.5)
                    ctx.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                    ctx.cgContext.strokePath()
                }
                ctx.cgContext.setLineDash(phase: 0, lengths: [])

                for transport in renderedTransportAnnotationItems where transport.points.count >= 2 {
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

                        if let sourceImage = UIImage(systemName: transport.currentType.sfSymbol) {
                            let iconImage = smoothedPoints.travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                            drawImageAspectFit(iconImage.withTintColor(themeColor), in: CGRect(x: midPoint.x - 4, y: midPoint.y - 4, width: 8, height: 8))
                        }
                    }
                }
            }

            for marker in renderedFootprintMarkers {
                let point = snapshot.point(for: marker.coordinate)
                marker.image.draw(at: CGPoint(
                    x: point.x - marker.image.size.width / 2,
                    y: point.y - marker.image.size.height
                ))
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
                    let tipHeight: CGFloat = 8
                    let rect = CGRect(x: point.x - markerSize / 2, y: point.y - markerSize - tipHeight, width: markerSize, height: markerSize)
                    let markerPath = UIBezierPath.photoMapMarkerPath(in: CGRect(x: rect.minX, y: rect.minY, width: markerSize, height: markerSize + tipHeight), cornerRadius: 6, tipHeight: tipHeight)
                    let contentRect = rect.insetBy(dx: 4, dy: 4)
                    let contentPath = UIBezierPath(roundedRect: contentRect, cornerRadius: 4)

                    if let photoImage = standalonePhotoImages[entry.asset.localIdentifier] {
                        ctx.cgContext.saveGState()
                        ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.20).cgColor)
                        UIColor.systemBackground.setFill()
                        markerPath.fill()
                        ctx.cgContext.restoreGState()

                        ctx.cgContext.saveGState()
                        contentPath.addClip()
                        drawImageAspectFill(photoImage, in: contentRect)
                        ctx.cgContext.restoreGState()

                        UIColor.separator.withAlphaComponent(0.30).setStroke()
                        contentPath.lineWidth = 0.8
                        contentPath.stroke()
                        
                        UIColor.systemBackground.setStroke()
                        markerPath.lineWidth = 1.5
                        markerPath.stroke()
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
        let verticalContentInset = topContentInset + bottomContentInset
        if verticalContentInset > 0, size.height > verticalContentInset {
            let visibleFraction = (size.height - verticalContentInset) / size.height
            let originalLatitudeDelta = region.span.latitudeDelta
            region.span.latitudeDelta = originalLatitudeDelta / visibleFraction
            region.center.latitude += region.span.latitudeDelta
                * ((topContentInset - bottomContentInset) / size.height)
                / 2
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

        let resolvedAssetID = PhotoService.shared.resolvedAssetIdentifier(for: assetID)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [resolvedAssetID], options: nil)
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

        let resolvedAssetID = PhotoService.shared.resolvedAssetIdentifier(for: assetID)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [resolvedAssetID], options: nil)
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

/// Footprints at one place, as a native sheet. The caller dismisses it and
/// opens the selected footprint once the dismissal finishes.
struct FootprintGroupSheet: View {
    let aggregated: DFKMapView.AggregatedFootprint
    let allPlaces: [Place]
    let onFootprintSelected: (Footprint) -> Void
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(aggregated.footprints) { footprint in
                        FootprintCardView(
                            footprint: footprint,
                            allPlaces: allPlaces,
                            showTimeline: false,
                            disableContextMenu: true,
                            showsTimeAsTitle: true
                        ) { selected, _ in
                            onFootprintSelected(selected)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("共 \(aggregated.footprints.count) 条足迹")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
    let onUserLocationTap: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = SafeMKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.annotationReuseIdentifier)

        let controlsStack = UIStackView()
        controlsStack.tag = Self.controlsStackTag
        controlsStack.axis = .vertical
        controlsStack.alignment = .trailing
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        // Custom location button (replaces MKUserTrackingButton so we can intercept taps)
        let locationButton = UIButton(type: .system)
        locationButton.tag = Self.userTrackingButtonTag
        locationButton.setImage(UIImage(systemName: "location.fill"), for: .normal)
        locationButton.tintColor = UIColor.systemBlue
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        locationButton.addTarget(context.coordinator, action: #selector(Coordinator.didTapLocationButton), for: .touchUpInside)
        controlsStack.addArrangedSubview(Self.makeCircularControlContainer(for: locationButton))

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
            controlsStack.topAnchor.constraint(equalTo: mapView.topAnchor, constant: topSafeAreaInset + 16),
            scaleView.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scaleView.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        if let region {
            mapView.region = region
        }

        return mapView
    }

    private var topSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
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
                    lineWidth: segment.isDashed ? 1.4 : 3,
                    dashPattern: segment.isDashed ? [8 as NSNumber, 8 as NSNumber] : nil
                )
                mapView.addOverlay(line)
            }

            let smoothedPoints = transport.lineSegments.flatMap { $0.coordinates }.filter(\.isRenderableMapCoordinate)
            if let midpoint = smoothedPoints.distanceMidpoint {
                mapView.addAnnotation(MapImageAnnotation(
                    coordinate: midpoint,
                    kind: .transport(transport.id.uuidString),
                    image: Coordinator.transportImage(
                        symbolName: transport.currentType.sfSymbol,
                        travelsWest: smoothedPoints.travelsWest
                    )
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
                image: Coordinator.photoImage(),
                centerOffset: Coordinator.photoCenterOffset
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
        static let photoCenterOffset = CGPoint(x: 0, y: -17)

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

        @objc func didTapLocationButton() {
            parent.onUserLocationTap?()
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

        static func transportImage(symbolName: String, travelsWest: Bool) -> UIImage {
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

                if let sourceImage = UIImage(systemName: symbolName) {
                    let iconImage = travelsWest ? sourceImage.withHorizontallyFlippedOrientation() : sourceImage
                    iconImage
                        .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: 5, y: 5, width: 10, height: 10))
                }
            }
        }


        static func photoImage() -> UIImage {
            let bodySize: CGFloat = 28
            let tipHeight: CGFloat = 6
            let size = CGSize(width: bodySize, height: bodySize + tipHeight)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let markerRect = CGRect(origin: .zero, size: size)
                let path = UIBezierPath.photoMapMarkerPath(in: markerRect, cornerRadius: 6, tipHeight: tipHeight)
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.18).cgColor)
                UIColor.systemBackground.setFill()
                path.fill()
                context.cgContext.restoreGState()

                UIColor.systemBackground.setStroke()
                path.lineWidth = 1.2
                path.stroke()

                UIImage(systemName: "photo.fill")?
                    .withTintColor(UIColor(Color.dfkAccent), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 7, y: 7, width: 14, height: 14))
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
    /// Whether the route's destination is west of its origin. Normalize the
    /// longitude delta so routes crossing the antimeridian keep their actual
    /// travel direction.
    var travelsWest: Bool {
        guard let first, let last, count >= 2 else { return false }
        var longitudeDelta = last.longitude - first.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        return longitudeDelta < 0
    }

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

private struct DFKFootprintMapMarker: View {
    let size: CGFloat
    let constantScale: CGFloat
    let activityColor: Color
    let iconColor: Color
    let iconName: String
    let iconSize: CGFloat
    let photoImage: UIImage?
    var centerText: String? = nil
    /// Small second line under `centerText`, such as "个足迹".
    var centerCaption: String? = nil
    let durationTuple: (number: String, unit: String)?
    let fontSize: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            MapPinTeardropShape()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                .frame(width: size, height: size * 1.2)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [activityColor, activityColor.darker(by: 0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size - 5, height: size - 5)
                .offset(y: 2.5)

            if let photoImage {
                Image(uiImage: photoImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - 3, height: size - 3)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(activityColor, lineWidth: 1.5))
                    .offset(y: 1.5)
            } else if let centerText, let centerCaption {
                // Centred in the coloured circle as one two-line block.
                VStack(spacing: 0) {
                    Text(centerText)
                        .font(.system(size: iconSize * 0.8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(centerCaption)
                        .font(.system(size: iconSize * 0.4, weight: .semibold))
                        .lineLimit(1)
                        .opacity(0.9)
                }
                .foregroundStyle(iconColor)
                .frame(width: size - 9, height: size - 5)
                .offset(y: 2.5)
            } else if let centerText {
                Text(centerText)
                    .font(.system(size: iconSize, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: size - 8, height: size - 8)
                    .offset(y: 4)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: size, height: size)
            }

            if let durationTuple {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(durationTuple.number)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    Text(durationTuple.unit)
                        .font(.system(size: fontSize * 0.75, weight: .bold, design: .rounded))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(activityColor.darker(by: 0.30))
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
                .offset(y: size - 6 * constantScale)
            }
        }
        .padding(2 * constantScale)
        .frame(width: size + 4 * constantScale, height: size * 1.2 + 4 * constantScale)
        .contentShape(Rectangle())
    }
}

private struct DFKReviewPlaceMapMarker: View {
    let placeCount: Int
    let photoImage: UIImage?

    var body: some View {
        DFKFootprintMapMarker(
            size: 36,
            constantScale: 1.32,
            activityColor: Color.dfkAccent,
            iconColor: .white,
            iconName: "mappin",
            iconSize: placeCount > 1 ? 15 : 14,
            photoImage: placeCount == 1 ? photoImage : nil,
            centerText: placeCount > 1 ? "\(placeCount)" : nil,
            centerCaption: placeCount > 1 ? "个足迹" : nil,
            durationTuple: nil,
            fontSize: 8
        )
    }
}

struct MapPinTeardropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 && rect.height > 0 else {
            path.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return path
        }

        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        path.addArc(center: center, radius: radius, startAngle: .degrees(140), endAngle: .degrees(40), clockwise: false)
        let bottomY = rect.maxY - 1.5
        path.addLine(to: CGPoint(x: rect.midX + 1.5, y: bottomY))
        path.addArc(center: CGPoint(x: rect.midX, y: bottomY), radius: 1.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct PhotoMapMarkerShape: Shape {
    let cornerRadius: CGFloat
    let tipHeight: CGFloat
    var tipWidth: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 && rect.height > 0 else {
            path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
            return path
        }

        let bodyHeight = max(0, rect.height - tipHeight)
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        let radius = min(cornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        let clampedTipWidth = min(tipWidth, rect.width * 0.5)

        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius), control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY), control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius), control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY), control: CGPoint(x: bodyRect.minX, y: bodyRect.minY))
        path.closeSubpath()

        return path
    }
}

private extension UIBezierPath {
    static func photoMapMarkerPath(in rect: CGRect, cornerRadius: CGFloat, tipHeight: CGFloat, tipWidth: CGFloat = 14) -> UIBezierPath {
        let path = UIBezierPath()
        guard rect.width > 0 && rect.height > 0 else {
            return UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let bodyHeight = max(0, rect.height - tipHeight)
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        let radius = min(cornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        let clampedTipWidth = min(tipWidth, rect.width * 0.5)

        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius), controlPoint: CGPoint(x: bodyRect.maxX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY), controlPoint: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - clampedTipWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius), controlPoint: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY), controlPoint: CGPoint(x: bodyRect.minX, y: bodyRect.minY))
        path.close()

        return path
    }
}

extension Color {
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

private extension View {
    @ViewBuilder
    func mapLocationButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }
}
