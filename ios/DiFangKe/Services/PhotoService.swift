import Photos
import UIKit
import CoreLocation
import SwiftData

private struct PhotoGeocodeResult: Sendable {
    let title: String
    let address: String?
    let countryCode: String?
    let countryName: String?
    let cityName: String?
}

private struct CrossDevicePhotoRecoverySnapshot: Sendable {
    let footprintID: UUID
    let assetIDs: [String]
    let cloudIdentifierByLocalIdentifier: [String: String]
}

private final class PhotoIdentifierResolutionCache: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func resolvedIdentifier(for storedIdentifier: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[storedIdentifier] ?? storedIdentifier
    }

    func merge(_ mappings: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (storedIdentifier, localIdentifier) in mappings
        where storage[storedIdentifier] != localIdentifier {
            storage[storedIdentifier] = localIdentifier
            changed = true
        }
        return changed
    }
}

private final class PhotoGeocodeCache: @unchecked Sendable {
    private var storage: [String: PhotoGeocodeResult] = [:]
    private let lock = NSLock()

    func value(for key: String) -> PhotoGeocodeResult? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: PhotoGeocodeResult, for key: String) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }
}

/// A photo cluster can receive a result from the system geocoder, its timeout,
/// or the network fallback. Only the first result may advance the scan.
private final class PhotoScanClusterCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var hasCompleted = false

    func perform(_ work: () -> Void) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()
        work()
    }
}

/// An import preview contains detached models. Keep their IDs across an
/// unexpected app termination so a legacy edit path can never resurrect one
/// into the timeline on the following launch.
enum PhotoImportDraftRecovery {
    private static let pendingDraftIDsKey = "pendingPhotoImportDraftIDs"

    static func markPending(_ footprints: [Footprint]) {
        UserDefaults.standard.set(footprints.map { $0.footprintID.uuidString }, forKey: pendingDraftIDsKey)
    }

    static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingDraftIDsKey)
    }

    static func discardPending(in context: ModelContext) {
        let ids = Set((UserDefaults.standard.stringArray(forKey: pendingDraftIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return }
        defer { clearPending() }

        let descriptor = FetchDescriptor<Footprint>()
        guard let staleDrafts = try? context.fetch(descriptor).filter({ ids.contains($0.footprintID) }) else { return }
        guard !staleDrafts.isEmpty else { return }
        for draft in staleDrafts {
            context.delete(draft)
        }
        try? context.save()
    }
}

class PhotoService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoService()
    private let displayableAssetIDsCache = NSCache<NSString, NSArray>()
    private let identifierResolutionCache = PhotoIdentifierResolutionCache()
    private var crossDevicePhotoRecoveryTask: Task<Void, Never>?
    
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isScanCancelled = false
    @Published private(set) var identifierResolutionRevision = 0
    var modelContext: ModelContext? {
        didSet {
            if let context = modelContext {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status != .notDetermined {
                    let container = context.container
                    Task.detached(priority: .background) {
                        await self.syncDeletedPhotos(in: container)
                    }
                }
            }
        }
    }
    
    override init() {
        super.init()
        displayableAssetIDsCache.countLimit = 64
        checkStatus()
    }

    func clearTransientCaches() {
        displayableAssetIDsCache.removeAllObjects()
    }
    
    deinit {
        crossDevicePhotoRecoveryTask?.cancel()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    private func scheduleCrossDevicePhotoRecovery() {
        guard let container = modelContext?.container else { return }
        crossDevicePhotoRecoveryTask?.cancel()
        crossDevicePhotoRecoveryTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.recoverCrossDevicePhotoIdentifiers(in: container)
        }
    }
    
    func checkStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            PHPhotoLibrary.shared().register(self)
        }
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
                let granted = status == .authorized || status == .limited
                if granted {
                    PHPhotoLibrary.shared().register(self)
                    self.scheduleCrossDevicePhotoRecovery()
                }
                completion(granted)
            }
        }
    }

    func getEarliestAssetDate() -> Date? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        return assets.firstObject?.creationDate
    }
    
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        displayableAssetIDsCache.removeAllObjects()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard (status == .authorized || status == .limited),
              let container = modelContext?.container else { return }
        
        Task.detached(priority: .background) {
            await self.syncDeletedPhotos(in: container)
        }
    }
    
    func validateAssetIDs(_ assetIDs: [String]) -> Bool {
        if assetIDs.isEmpty { return true }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        
        let resolvedAssetIDs = assetIDs.map(resolvedAssetIdentifier(for:))
        let result = PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssetIDs, options: nil)
        return result.count == assetIDs.count
    }

    func resolvedAssetIdentifier(for storedIdentifier: String) -> String {
        identifierResolutionCache.resolvedIdentifier(for: storedIdentifier)
    }

    /// Records device-local resolutions without changing identifiers persisted
    /// in the shared footprint store. PHAsset local identifiers are not stable
    /// across devices and must never be written back as a sync repair.
    func cacheResolvedAssetIdentifiers(_ mappings: [String: String]) {
        guard identifierResolutionCache.merge(mappings) else { return }
        displayableAssetIDsCache.removeAllObjects()
        Task { @MainActor in
            identifierResolutionRevision &+= 1
        }
    }
    
    func syncDeletedPhotos(in container: ModelContainer) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        await recoverCrossDevicePhotoIdentifiers(in: container)
        // Do not delete identifiers that Photos cannot resolve locally. They
        // may belong to another device and remain necessary for cloud-ID
        // recovery when the corresponding iCloud photo becomes available.
    }

    private func recoverCrossDevicePhotoIdentifiers(in container: ModelContainer) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let snapshots: [CrossDevicePhotoRecoverySnapshot] = {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Footprint>()
            guard let footprints = try? context.fetch(descriptor) else { return [] }
            return footprints.compactMap { footprint in
                let assetIDs = footprint.photoAssetIDs
                guard !assetIDs.isEmpty else { return nil }
                let cloudByLocal = Dictionary(
                    footprint.photoMetadata.compactMap { metadata -> (String, String)? in
                        guard let cloudIdentifier = metadata.cloudIdentifier else { return nil }
                        return (metadata.localIdentifier, cloudIdentifier)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                return CrossDevicePhotoRecoverySnapshot(
                    footprintID: footprint.footprintID,
                    assetIDs: assetIDs,
                    cloudIdentifierByLocalIdentifier: cloudByLocal
                )
            }
        }()
        guard !snapshots.isEmpty, !Task.isCancelled else { return }

        let allStoredLocalIDs = Array(Set(snapshots.flatMap(\.assetIDs)))
        let locallyAvailableAssets = PHAsset.fetchAssets(withLocalIdentifiers: allStoredLocalIDs, options: nil)
        var locallyAvailableIDs = Set<String>()
        locallyAvailableAssets.enumerateObjects { asset, _, _ in
            locallyAvailableIDs.insert(asset.localIdentifier)
        }

        let localIDsMissingCloudIdentifier = Set(snapshots.flatMap { snapshot in
            snapshot.assetIDs.filter { localIdentifier in
                locallyAvailableIDs.contains(localIdentifier)
                    && snapshot.cloudIdentifierByLocalIdentifier[localIdentifier] == nil
            }
        })
        let cloudIdentifierByLocalIdentifier = await getCloudIdentifiers(
            for: Array(localIDsMissingCloudIdentifier)
        )

        let unresolvedCloudIDs = Set(snapshots.flatMap { snapshot in
            snapshot.cloudIdentifierByLocalIdentifier.compactMap { localIdentifier, cloudIdentifier in
                locallyAvailableIDs.contains(localIdentifier) ? nil : cloudIdentifier
            }
        })
        let localIdentifierByCloudIdentifier = await getLocalIdentifiers(for: Array(unresolvedCloudIDs))
        guard (!cloudIdentifierByLocalIdentifier.isEmpty || !localIdentifierByCloudIdentifier.isEmpty),
              !Task.isCancelled else { return }

        var resolvedIdentifierByStoredIdentifier: [String: String] = [:]
        for snapshot in snapshots {
            for (storedIdentifier, cloudIdentifier) in snapshot.cloudIdentifierByLocalIdentifier {
                if let localIdentifier = localIdentifierByCloudIdentifier[cloudIdentifier] {
                    resolvedIdentifierByStoredIdentifier[storedIdentifier] = localIdentifier
                }
            }
        }
        let resolutionChanged = identifierResolutionCache.merge(resolvedIdentifierByStoredIdentifier)
        if resolutionChanged {
            displayableAssetIDsCache.removeAllObjects()
        }

        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.footprintID, $0) })
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Footprint>()
        guard let footprints = try? context.fetch(descriptor) else { return }
        var changed = false

        for footprint in footprints {
            guard let snapshot = snapshotsByID[footprint.footprintID] else { continue }
            var metadata = footprint.photoMetadata
            var footprintChanged = false

            for localIdentifier in snapshot.assetIDs {
                guard let cloudIdentifier = cloudIdentifierByLocalIdentifier[localIdentifier],
                      !metadata.contains(where: {
                          $0.localIdentifier == localIdentifier && $0.cloudIdentifier == cloudIdentifier
                      }) else { continue }

                if let index = metadata.firstIndex(where: { $0.localIdentifier == localIdentifier }) {
                    metadata[index].cloudIdentifier = cloudIdentifier
                } else {
                    metadata.append(
                        PhotoMetadata(localIdentifier: localIdentifier, cloudIdentifier: cloudIdentifier)
                    )
                }
                footprintChanged = true
            }

            guard footprintChanged else { continue }
            footprint.photoMetadata = metadata
            changed = true
        }

        if changed {
            do {
                try context.save()
            } catch {
                print("Failed to enrich cross-device photo identifiers: \(error)")
            }
        }
        let didChangeStoredMetadata = changed
        if didChangeStoredMetadata || resolutionChanged {
            await MainActor.run {
                if resolutionChanged {
                    self.identifierResolutionRevision &+= 1
                }
                if didChangeStoredMetadata {
                    NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                }
            }
        }
    }
    
    func fetchCount(startTime: Date, endTime: Date) -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 0 }
        
        let options = PHFetchOptions()
        let bufferStart = startTime.addingTimeInterval(-300) // 增加到 5 分钟缓冲
        let bufferEnd = endTime.addingTimeInterval(300)
        let predicate = NSPredicate(format: "creationDate > %@ AND creationDate < %@", bufferStart as NSDate, bufferEnd as NSDate)
        options.predicate = predicate
        return PHAsset.fetchAssets(with: .image, options: options).count
    }
    
    func fetchAssets(startTime: Date, endTime: Date, near location: CLLocationCoordinate2D? = nil, maxDistance: CLLocationDistance = 1000, completion: @escaping ([PHAsset]) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            completion([])
            return
        }

        let options = PHFetchOptions()
        let bufferStart = startTime.addingTimeInterval(-Self.linkingTimeBuffer)
        let bufferEnd = endTime.addingTimeInterval(Self.linkingTimeBuffer)
        options.predicate = NSPredicate(format: "creationDate > %@ AND creationDate < %@", bufferStart as NSDate, bufferEnd as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        
        let result = PHAsset.fetchAssets(with: .image, options: options)
        DispatchQueue.global(qos: .userInitiated).async {
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                if Self.asset(asset, belongsToStayFrom: startTime, to: endTime, near: location, maxDistance: maxDistance) {
                    assets.append(asset)
                }
            }
            DispatchQueue.main.async { completion(assets) }
        }
    }

    /// A footprint's representative photo: the most recently taken one.
    /// `photoAssetIDs` is in insertion order (auto-linking appends oldest
    /// first, manual additions go last), so it can't be read off either end.
    func latestAsset(among assetIDs: [String]) -> PHAsset? {
        guard !assetIDs.isEmpty else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        let resolvedAssetIDs = assetIDs.map(resolvedAssetIdentifier(for:))
        return PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssetIDs, options: options).firstObject
    }

    /// A review card starts with the earliest photo so the memory reads in
    /// chronological order. Timeline thumbnails continue to use latestAsset.
    func earliestAsset(among assetIDs: [String]) -> PHAsset? {
        guard !assetIDs.isEmpty else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = 1
        let resolvedAssetIDs = assetIDs.map(resolvedAssetIdentifier(for:))
        return PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssetIDs, options: options).firstObject
    }

    func assetIDsOldestFirst(_ assetIDs: [String]) -> [String] {
        let resolvedAssetIDs = assetIDs.map(resolvedAssetIdentifier(for:))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssetIDs, options: nil)
        var creationDates: [String: Date] = [:]
        assets.enumerateObjects { asset, _, _ in
            creationDates[asset.localIdentifier] = asset.creationDate
        }
        return resolvedAssetIDs.sorted {
            switch (creationDates[$0], creationDates[$1]) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return $0 < $1
            }
        }
    }

    /// IDs that Photos can resolve on this device, de-duplicated and ordered
    /// newest first. Stored cross-device IDs remain untouched in the model.
    func displayableAssetIDs(_ assetIDs: [String]) -> [String] {
        guard !assetIDs.isEmpty else { return [] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let resolvedAssetIDs = assetIDs.map(resolvedAssetIdentifier(for:))
        let cacheKey = resolvedAssetIDs.joined(separator: "\u{1F}") as NSString
        if let cached = displayableAssetIDsCache.object(forKey: cacheKey) as? [String] {
            return cached
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssetIDs, options: nil)
        var creationDates: [String: Date] = [:]
        var availableAssetIDs = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            availableAssetIDs.insert(asset.localIdentifier)
            creationDates[asset.localIdentifier] = asset.creationDate
        }

        var displayedIdentifiers = Set<String>()
        let result = resolvedAssetIDs
            .filter { availableAssetIDs.contains($0) && displayedIdentifiers.insert($0).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsDate = creationDates[lhs.element]
                let rhsDate = creationDates[rhs.element]
                switch (lhsDate, rhsDate) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
        displayableAssetIDsCache.setObject(result as NSArray, forKey: cacheKey)
        return result
    }

    /// Resolves stored identifiers first, then uses the same time-and-location
    /// rule as automatic photo linking to recover old records whose Photos
    /// local identifiers changed before cloud identifier metadata was stored.
    /// This is display-only recovery and never rewrites the footprint store.
    func displayableAssetIDs(for footprint: Footprint) async -> [String] {
        let storedAssetIDs = footprint.photoAssetIDs
        let resolvedAssetIDs = displayableAssetIDs(storedAssetIDs)
        guard resolvedAssetIDs.count < Set(storedAssetIDs).count else { return resolvedAssetIDs }

        let matchedAssets: [PHAsset] = await withCheckedContinuation { continuation in
            fetchAssets(
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                near: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            ) { assets in
                continuation.resume(returning: assets)
            }
        }
        var seenIdentifiers = Set<String>()
        return (resolvedAssetIDs + matchedAssets.map(\.localIdentifier))
            .filter { seenIdentifiers.insert($0).inserted }
    }

    /// Photos taken this long before/after a stay still belong to it.
    private static let linkingTimeBuffer: TimeInterval = 60

    /// The single rule for whether a photo belongs to a stay: used to link
    /// photos to footprints and to keep such photos out of photo import.
    /// Screenshots and photos without a location were not taken there, so
    /// they are never matched automatically (users can still add them).
    static func asset(_ asset: PHAsset, belongsToStayFrom startTime: Date, to endTime: Date, near location: CLLocationCoordinate2D?, maxDistance: CLLocationDistance) -> Bool {
        guard !asset.mediaSubtypes.contains(.photoScreenshot),
              let assetLocation = asset.location,
              let creationDate = asset.creationDate,
              creationDate > startTime.addingTimeInterval(-linkingTimeBuffer),
              creationDate < endTime.addingTimeInterval(linkingTimeBuffer) else { return false }
        guard let location else { return true }
        let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
            .distance(from: assetLocation)
        return distance <= maxDistance
    }

    /// 获取本地 ID 对应的云端 ID 映射（异步后台执行）
    func getCloudIdentifiers(for localIDs: [String]) async -> [String: String] {
        guard !localIDs.isEmpty else { return [:] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }
        
        return await Task.detached(priority: .userInitiated) {
            let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIDs)
            var result: [String: String] = [:]
            for (localID, mapping) in mappings {
                if case .success(let cloudID) = mapping {
                    result[localID] = cloudID.stringValue
                }
            }
            return result
        }.value
    }
    
    /// 获取云端 ID 对应的本地 ID 映射（异步后台执行）
    func getLocalIdentifiers(for cloudIDs: [String]) async -> [String: String] {
        guard !cloudIDs.isEmpty else { return [:] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }
        
        return await Task.detached(priority: .userInitiated) {
            let cloudIdentifiers = cloudIDs.map { PHCloudIdentifier(stringValue: $0) }
            let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIdentifiers)
            
            var result: [String: String] = [:]
            for (cloudID, mapping) in mappings {
                if case .success(let localID) = mapping {
                    result[cloudID.stringValue] = localID
                }
            }
            return result
        }.value
    }
    
    @discardableResult
    func loadImage(for assetID: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill, progressHandler: ((Double) -> Void)? = nil, completion: @escaping (UIImage?, Bool, PHAuthorizationStatus, Bool) -> Void) -> PHImageRequestID? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async { completion(nil, true, status, false) }
            return nil
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = true
        
        let resolvedAssetID = resolvedAssetIdentifier(for: assetID)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [resolvedAssetID], options: fetchOptions)

        guard let asset = assets.firstObject else {
            DispatchQueue.main.async {
                let exists = (status == .limited)
                completion(nil, exists, status, false)
            }
            return nil
        }
        
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                progressHandler?(progress)
            }
        }
        
        return PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                completion(image, true, status, isDegraded)
            }
        }
    }

    /// 自动扫描指定日期范围内的照片并根据时空聚类生成足迹候选
    func autoScanFootprints(from startDate: Date, to endDate: Date, allPlaces: [PlaceLite], allActivities: [ActivityTypeLite], excludedAssetIDs: Set<String>, history: [FootprintLite] = [], onProgress: ((Int, Int) -> Void)? = nil, completion: @escaping ([Footprint]) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            completion([])
            return
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", startDate as NSDate, endDate as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assetsWithLocation: [PHAsset] = []
        let linkingMaxDistance = AppConfig.shared.photoLinkingMaxDistance
        result.enumerateObjects { asset, _, _ in
            guard asset.location != nil, !excludedAssetIDs.contains(asset.localIdentifier) else { return }
            // A photo the linker would attach to an existing footprint already
            // has one, even if that footprint hasn't been linked yet.
            let belongsToExistingFootprint = history.contains { footprint in
                Self.asset(
                    asset,
                    belongsToStayFrom: footprint.startTime,
                    to: footprint.endTime,
                    near: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
                    maxDistance: linkingMaxDistance
                )
            }
            if !belongsToExistingFootprint {
                assetsWithLocation.append(asset)
            }
        }
        
        if assetsWithLocation.isEmpty {
            completion([])
            return
        }
        
        var clusters: [[PHAsset]] = []
        var currentCluster: [PHAsset] = []
        let maxDistance: CLLocationDistance = 500
        let maxTimeInterval: TimeInterval = 14400
        
        for asset in assetsWithLocation {
            if let lastAsset = currentCluster.last {
                let distance = asset.location!.distance(from: lastAsset.location!)
                let time = asset.creationDate!.timeIntervalSince(lastAsset.creationDate!)
                if distance < maxDistance && time < maxTimeInterval {
                    currentCluster.append(asset)
                } else {
                    clusters.append(currentCluster)
                    currentCluster = [asset]
                }
            } else {
                currentCluster = [asset]
            }
        }
        if !currentCluster.isEmpty { clusters.append(currentCluster) }
        
        class ScanResult {
            var footprints: [Footprint] = []
            let lock = NSLock()
            func append(_ fp: Footprint) {
                lock.lock()
                footprints.append(fp)
                lock.unlock()
            }
        }
        let scanResult = ScanResult()
        
        DispatchQueue.global(qos: .userInitiated).async {
            let sortedClusters = clusters.sorted(by: { $0.count > $1.count })
            let geocodeCache = PhotoGeocodeCache()
            let group = DispatchGroup()
            var processedPhotosCount = 0
            let totalPhotosCount = assetsWithLocation.count
            
            let incrementProgress = { (count: Int) in
                DispatchQueue.main.async {
                    processedPhotosCount += count
                    onProgress?(processedPhotosCount, totalPhotosCount)
                }
            }
            
            for cluster in sortedClusters {
                if self.isScanCancelled { break }
                group.enter()
                guard let first = cluster.first, let last = cluster.last, let rawLoc = first.location else { 
                    incrementProgress(cluster.count)
                    group.leave()
                    continue 
                }
                
                let firstLoc = rawLoc.gcj02
                let lastLoc = (cluster.last?.location ?? rawLoc).gcj02
                let centerLat = (firstLoc.coordinate.latitude + lastLoc.coordinate.latitude) / 2.0
                let centerLon = (firstLoc.coordinate.longitude + lastLoc.coordinate.longitude) / 2.0
                let centerLoc = CLLocation(latitude: centerLat, longitude: centerLon)
                let startTime = first.creationDate ?? Date()
                let endTime = last.creationDate ?? Date()
                let duration = endTime.timeIntervalSince(startTime)
                let coords = cluster.compactMap { $0.location?.gcj02.coordinate }
                let hash = "\(Int(centerLat * 10000))\(Int(centerLon * 10000))"
                let cacheKey = String(format: "%.3f,%.3f", centerLat, centerLon)
                
                var title = ""
                var address: String? = nil
                var matchedPlaceID: UUID? = nil
                
                let matches = allPlaces.filter { place in
                    let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                    return centerLoc.distance(from: placeLoc) <= Double(place.radius) + 120.0
                }
                
                if matches.contains(where: { $0.isIgnored }) {
                    incrementProgress(cluster.count)
                    group.leave()
                    continue
                }
                
                if let bestMatch = matches.min(by: { p1, p2 in
                    let d1 = centerLoc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
                    let d2 = centerLoc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
                    return d1 < d2
                }) {
                    title = bestMatch.name
                    address = bestMatch.address
                    matchedPlaceID = bestMatch.placeID
                } else {
                    let ignoredNearby = allPlaces.first { place in
                        place.isIgnored && centerLoc.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) < 250.0
                    }
                    if ignoredNearby != nil {
                        incrementProgress(cluster.count)
                        group.leave()
                        continue
                    }
                }
                
                let captureStartTime = startTime
                let captureEndTime = endTime
                let captureCoords = coords
                let captureHash = hash
                let captureDuration = duration
                let captureClusterIDs = cluster.map { $0.localIdentifier }
                let captureClusterCount = cluster.count
                let captureTitle = title
                let captureAddress = address
                let captureMatchedPlaceID = matchedPlaceID
                let clusterCompletion = PhotoScanClusterCompletion()

                func createAndAdd(
                    t: String,
                    a: String?,
                    pID: UUID?,
                    countryCode: String? = nil,
                    countryName: String? = nil,
                    cityName: String? = nil
                ) {
                    clusterCompletion.perform {
                        let fp = Footprint(
                            date: Calendar.current.startOfDay(for: captureStartTime),
                            startTime: captureStartTime,
                            endTime: captureEndTime,
                            footprintLocations: captureCoords,
                            locationHash: captureHash,
                            duration: captureDuration,
                            status: .candidate,
                            placeID: pID,
                            photoAssetIDs: captureClusterIDs,
                            address: t.isEmpty ? a : t
                        )
                        fp.countryCode = countryCode
                        fp.countryName = countryName?.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? countryName
                        fp.cityName = cityName?.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? cityName
                        if let autoMatch = ActivityType.getAutoMatchActivity(for: fp, allActivities: allActivities, allPlaces: allPlaces, history: history) {
                            fp.activityTypeValue = autoMatch.id.uuidString
                        }
                        scanResult.append(fp)
                        incrementProgress(captureClusterCount)
                        group.leave()
                    }
                }

                // Address enrichment must never be allowed to block importing
                // the photos. Retain a matched place's own name/address if the
                // reverse geocoder or the fallback service does not respond.
                let fallbackItem = DispatchWorkItem {
                    createAndAdd(t: captureTitle, a: captureAddress, pID: captureMatchedPlaceID)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: fallbackItem)

                if captureMatchedPlaceID == nil {
                    if let cached = geocodeCache.value(for: cacheKey) {
                        createAndAdd(
                            t: cached.title,
                            a: cached.address,
                            pID: nil,
                            countryCode: cached.countryCode,
                            countryName: cached.countryName,
                            cityName: cached.cityName
                        )
                    } else {
                        let geocoder = CLGeocoder()
                        geocoder.reverseGeocodeLocation(firstLoc) { [geocoder] placemarks, _ in
                            // Capturing geocoder keeps it alive until this handler fires;
                            // CLGeocoder cancels the in-flight request if it deallocates first.
                            _ = geocoder
                            var resolvedTitle = ""
                            var resolvedAddress: String? = nil
                            if let pm = placemarks?.first {
                                let pmName = pm.name ?? ""
                                let pmThorough = pm.thoroughfare ?? ""
                                if allPlaces.contains(where: { p in p.isIgnored && (p.name == pmName || p.address == pmName || (p.address?.contains(pmName) == true)) }) {
                                    clusterCompletion.perform {
                                        incrementProgress(captureClusterCount)
                                        group.leave()
                                    }
                                    return
                                }
                                if !pmName.isEmpty { resolvedTitle = pmName }
                                else if let pmSub = pm.subLocality, !pmSub.isEmpty { resolvedTitle = "\(pmSub) 附近" }
                                resolvedAddress = (pmThorough.isEmpty || pmName == pmThorough) ? pmName : "\(pmThorough) \(pmName)"
                                if !resolvedTitle.isEmpty || !(resolvedAddress ?? "").isEmpty {
                                    let countryCode = pm.isoCountryCode
                                    let countryName = countryCode.flatMap {
                                        Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: $0)
                                    } ?? pm.country
                                    let cityName = pm.locality ?? pm.subAdministrativeArea ?? pm.administrativeArea
                                    let result = PhotoGeocodeResult(
                                        title: resolvedTitle,
                                        address: resolvedAddress,
                                        countryCode: countryCode,
                                        countryName: countryName,
                                        cityName: cityName
                                    )
                                    geocodeCache.set(result, for: cacheKey)
                                    createAndAdd(
                                        t: result.title,
                                        a: result.address,
                                        pID: nil,
                                        countryCode: result.countryCode,
                                        countryName: result.countryName,
                                        cityName: result.cityName
                                    )
                                } else {
                                    Task {
                                        let fallback = await OpenStreetMapGeocoder.shared.lookup(coordinate: firstLoc.coordinate)
                                        let fallbackTitle = fallback?.placeName ?? ""
                                        let fallbackAddress = fallback?.address
                                        let result = PhotoGeocodeResult(title: fallbackTitle, address: fallbackAddress, countryCode: fallback?.countryCode, countryName: fallback?.countryName, cityName: fallback?.cityName)
                                        geocodeCache.set(result, for: cacheKey)
                                        createAndAdd(t: result.title, a: result.address, pID: nil, countryCode: result.countryCode, countryName: result.countryName, cityName: result.cityName)
                                    }
                                }
                            } else {
                                // Photos imported outside Apple Maps coverage use
                                // the same OpenStreetMap fallback as map picking.
                                Task {
                                    let fallback = await OpenStreetMapGeocoder.shared.lookup(coordinate: firstLoc.coordinate)
                                    let fallbackTitle = fallback?.placeName ?? ""
                                    let fallbackAddress = fallback?.address
                                    let result = PhotoGeocodeResult(title: fallbackTitle, address: fallbackAddress, countryCode: fallback?.countryCode, countryName: fallback?.countryName, cityName: fallback?.cityName)
                                    geocodeCache.set(result, for: cacheKey)
                                    createAndAdd(t: result.title, a: result.address, pID: nil, countryCode: result.countryCode, countryName: result.countryName, cityName: result.cityName)
                                }
                            }
                        }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                } else {
                    // A manually matched place already has a display name, but
                    // still needs the same country/city fields as every other
                    // imported footprint. Do not defer that work to Statistics.
                    let geocoder = CLGeocoder()
                    geocoder.reverseGeocodeLocation(firstLoc) { [geocoder] placemarks, _ in
                        // Capturing geocoder keeps it alive until this handler fires;
                        // CLGeocoder cancels the in-flight request if it deallocates first.
                        _ = geocoder
                        if let placemark = placemarks?.first {
                            let countryCode = placemark.isoCountryCode
                            let countryName = countryCode.flatMap {
                                Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: $0)
                            } ?? placemark.country
                            let cityName = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
                            createAndAdd(
                                t: captureTitle,
                                a: captureAddress,
                                pID: captureMatchedPlaceID,
                                countryCode: countryCode,
                                countryName: countryName,
                                cityName: cityName
                            )
                        } else {
                            Task {
                                let hierarchy = await OpenStreetMapGeocoder.shared.lookupInternationalHierarchy(coordinate: firstLoc.coordinate)
                                createAndAdd(
                                    t: captureTitle,
                                    a: captureAddress,
                                    pID: captureMatchedPlaceID,
                                    countryCode: hierarchy?.countryCode,
                                    countryName: hierarchy?.countryName,
                                    cityName: hierarchy?.cityName
                                )
                            }
                        }
                    }
                }
            }
            
            group.notify(queue: .main) {
                let filtered = scanResult.footprints.filter { candidate in
                    !history.contains { existing in
                        let timeOverlap = max(candidate.startTime, existing.startTime) < min(candidate.endTime, existing.endTime) || abs(candidate.startTime.timeIntervalSince(existing.startTime)) < 300
                        let distance = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude).distance(from: CLLocation(latitude: existing.latitude, longitude: existing.longitude))
                        return timeOverlap && distance < 300
                    }
                }
                completion(filtered.sorted(by: { $0.startTime < $1.startTime }))
            }
        }
    }
}
