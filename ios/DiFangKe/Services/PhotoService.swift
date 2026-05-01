import Photos
import UIKit
import CoreLocation
import SwiftData

class PhotoService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoService()
    
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isScanCancelled = false
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
        checkStatus()
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
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
                completion(status == .authorized || status == .limited)
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
        
        let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        return result.count > 0
    }
    
    func syncDeletedPhotos(in container: ModelContainer) async {
        let context = ModelContext(container)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        
        let descriptor = FetchDescriptor<Footprint>()
        do {
            let allFootprints = try context.fetch(descriptor)
            let footprintsWithPhotos = allFootprints.filter { !$0.photoAssetIDs.isEmpty }
            if footprintsWithPhotos.isEmpty { return }
            
            let allAssetIDs = Array(Set(footprintsWithPhotos.flatMap { $0.photoAssetIDs }))
            let result = PHAsset.fetchAssets(withLocalIdentifiers: allAssetIDs, options: nil)
            var existingIDs = Set<String>()
            result.enumerateObjects { asset, _, _ in
                existingIDs.insert(asset.localIdentifier)
            }
            let deletedIDs = Set(allAssetIDs).subtracting(existingIDs)

            if !deletedIDs.isEmpty {
                var changed = false
                for footprint in footprintsWithPhotos {
                    let originalCount = footprint.photoAssetIDs.count
                    var ids = footprint.photoAssetIDs
                    ids.removeAll { deletedIDs.contains($0) }
                    if originalCount != ids.count {
                        footprint.photoAssetIDs = ids
                        changed = true
                    }
                }
                if changed { try? context.save() }
            }
        } catch {
            print("Failed to sync deleted photos: \(error)")
        }
    }
    
    func fetchCount(startTime: Date, endTime: Date) -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 0 }
        
        let options = PHFetchOptions()
        let bufferStart = startTime.addingTimeInterval(-60)
        let bufferEnd = endTime.addingTimeInterval(60)
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
        let bufferStart = startTime.addingTimeInterval(-60)
        let bufferEnd = endTime.addingTimeInterval(60)
        options.predicate = NSPredicate(format: "creationDate > %@ AND creationDate < %@", bufferStart as NSDate, bufferEnd as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        
        let result = PHAsset.fetchAssets(with: .image, options: options)
        DispatchQueue.global(qos: .userInitiated).async {
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                if let nearLocation = location, let assetLocation = asset.location {
                    let dist = CLLocation(latitude: nearLocation.latitude, longitude: nearLocation.longitude)
                        .distance(from: assetLocation)
                    if dist <= maxDistance { assets.append(asset) }
                } else {
                    assets.append(asset)
                }
            }
            DispatchQueue.main.async { completion(assets) }
        }
    }
    
    func loadImage(for assetID: String, targetSize: CGSize, completion: @escaping (UIImage?, Bool, PHAuthorizationStatus) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async { completion(nil, true, status) }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = assets.firstObject else {
                DispatchQueue.main.async {
                    let exists = (status == .limited)
                    completion(nil, exists, status)
                }
                return
            }
            
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
                DispatchQueue.main.async { completion(image, true, status) }
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
        result.enumerateObjects { asset, _, _ in
            if asset.location != nil && !excludedAssetIDs.contains(asset.localIdentifier) {
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
            var geocodeCache: [String: (String, String?)] = [:]
            let group = DispatchGroup()
            let geocoder = CLGeocoder()
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

                func createAndAdd(t: String, a: String?, pID: UUID?) {
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
                    if let autoMatch = ActivityType.getAutoMatchActivity(for: fp, allActivities: allActivities, allPlaces: allPlaces, history: history) {
                        fp.activityTypeValue = autoMatch.id.uuidString
                    }
                    scanResult.append(fp)
                    incrementProgress(captureClusterCount)
                    group.leave()
                }
                
                if matchedPlaceID == nil {
                    if let cached = geocodeCache[cacheKey] {
                        createAndAdd(t: cached.0, a: cached.1, pID: nil)
                    } else {
                        var isFinished = false
                        let timeoutItem = DispatchWorkItem {
                            if !isFinished {
                                isFinished = true
                                incrementProgress(captureClusterCount)
                                group.leave()
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutItem)

                        geocoder.reverseGeocodeLocation(firstLoc) { placemarks, error in
                            if isFinished { return }
                            isFinished = true
                            timeoutItem.cancel()
                            var resolvedTitle = ""
                            var resolvedAddress: String? = nil
                            if let pm = placemarks?.first {
                                let pmName = pm.name ?? ""
                                let pmThorough = pm.thoroughfare ?? ""
                                if allPlaces.contains(where: { p in p.isIgnored && (p.name == pmName || p.address == pmName || (p.address?.contains(pmName) == true)) }) {
                                    incrementProgress(captureClusterCount)
                                    group.leave()
                                    return
                                }
                                if !pmName.isEmpty { resolvedTitle = pmName }
                                else if let pmSub = pm.subLocality, !pmSub.isEmpty { resolvedTitle = "\(pmSub) 附近" }
                                resolvedAddress = (pmThorough.isEmpty || pmName == pmThorough) ? pmName : "\(pmThorough) \(pmName)"
                                geocodeCache[cacheKey] = (resolvedTitle, resolvedAddress)
                            }
                            createAndAdd(t: resolvedTitle, a: resolvedAddress, pID: nil)
                        }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                } else {
                    createAndAdd(t: captureTitle, a: address, pID: matchedPlaceID)
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
