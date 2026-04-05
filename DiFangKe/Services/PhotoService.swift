import Photos
import UIKit
import CoreLocation
import SwiftData

class PhotoService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoService()
    
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    var modelContext: ModelContext? {
        didSet {
            if let context = modelContext {
                // 只有在用户已经授权或明确拒绝过（即非未决定状态）时才自动同步，避免启动即弹窗请求权限
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
        
        // 只有在已授权状态下，才注册监听器
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
    
    // PHPhotoLibraryChangeObserver
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 系统相册发生变化时，检查是否有照片被删除
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard (status == .authorized || status == .limited),
              let container = modelContext?.container else { return }
        
        Task.detached(priority: .background) {
            await self.syncDeletedPhotos(in: container)
        }
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
            
            // Photo fetching is already background friendly
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
                
                if changed {
                    try? context.save()
                }
            }
        } catch {
            print("Failed to sync deleted photos: \(error)")
        }
    }
    
    /// 获取一段时间内且在一定范围内的照片
    func fetchAssets(startTime: Date, endTime: Date, near location: CLLocationCoordinate2D? = nil, maxDistance: CLLocationDistance = 500, completion: @escaping ([PHAsset]) -> Void) {
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
        var assets: [PHAsset] = []
        
        result.enumerateObjects { asset, _, _ in
            if let nearLocation = location, let assetLocation = asset.location {
                let dist = CLLocation(latitude: nearLocation.latitude, longitude: nearLocation.longitude)
                    .distance(from: assetLocation)
                if dist <= maxDistance {
                    assets.append(asset)
                }
            } else {
                assets.append(asset)
            }
        }
        
        DispatchQueue.main.async {
            completion(assets)
        }
    }
    
    func loadImage(for assetID: String, targetSize: CGSize, completion: @escaping (UIImage?, Bool, PHAuthorizationStatus) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async {
                completion(nil, true, status)
            }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = assets.firstObject else {
                DispatchQueue.main.async {
                    // Only remove if status is Full Access. 
                    // For Limited access, an empty result might just mean it's not in the selection.
                    let exists = (status == .limited)
                    completion(nil, exists, status)
                }
                return
            }
            
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
                DispatchQueue.main.async {
                    completion(image, true, status)
                }
            }
        }
    }
    
    
    /// 自动扫描指定日期范围内的照片并根据时空聚类生成足迹候选
    func autoScanFootprints(from startDate: Date, to endDate: Date, allPlaces: [Place], excludedAssetIDs: Set<String>, onProgress: ((Int, Int) -> Void)? = nil, completion: @escaping ([Footprint]) -> Void) {
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
        
        // 聚类逻辑
        var clusters: [[PHAsset]] = []
        var currentCluster: [PHAsset] = []
        
        let maxDistance: CLLocationDistance = 300 // 收紧至 300米，确保是同一个地点
        let maxTimeInterval: TimeInterval = 14400 // 扩大至 4小时，允许照片拍摄间隔较久
        
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
        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }
        
        // 3. 将耗时操作移动到后台执行
        guard let container = self.modelContext?.container else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var finalFootprints: [Footprint] = []
            let bgContext = ModelContext(container)
            let group = DispatchGroup()
            let geocoder = CLGeocoder()
            
            // 为了防止 Hammer 系统的 Geocoder 服务导致卡死，我们只对照片最多的前 20 个足迹进行详细解析
            let sortedClusters = clusters.sorted(by: { $0.count > $1.count })
            let prioritizedClusters = Array(sortedClusters.prefix(20))
            let otherClusters = sortedClusters.count > 20 ? Array(sortedClusters.suffix(from: 20)) : []
            
            var processedPhotosCount = 0
            let totalPhotosCount = assetsWithLocation.count
            
            let incrementProgress = { (count: Int) in
                processedPhotosCount += count
                DispatchQueue.main.async {
                    onProgress?(processedPhotosCount, totalPhotosCount)
                }
            }
            
            // 处理重要足迹（带解析）
            for cluster in prioritizedClusters {
                group.enter()
                guard let first = cluster.first, let last = cluster.last,
                      let rawLoc = first.location else { 
                    incrementProgress(cluster.count)
                    group.leave()
                    continue 
                }
                
                // 修正坐标偏移：将 WGS84 转换为 GCJ02
                let firstLoc = rawLoc.gcj02
                let lastLoc = (cluster.last?.location ?? rawLoc).gcj02
                
                // 使用中点进行地点匹配，比仅用第一个点更稳健
                let centerLat = (firstLoc.coordinate.latitude + lastLoc.coordinate.latitude) / 2.0
                let centerLon = (firstLoc.coordinate.longitude + lastLoc.coordinate.longitude) / 2.0
                let centerLoc = CLLocation(latitude: centerLat, longitude: centerLon)
                
                let startTime = first.creationDate ?? Date()
                let endTime = last.creationDate ?? Date()
                let duration = endTime.timeIntervalSince(startTime)
                let coords = cluster.compactMap { $0.location?.gcj02.coordinate }
                let hash = "\(Int(centerLat * 10000))\(Int(centerLon * 10000))"
                
                // 1. 优先匹配已有的重要地点 (放宽匹配范围以适配照片 GPS 精度)
                var title = "发现足迹"
                var matchedPlaceID: UUID? = nil
                
                let matches = allPlaces.filter { place in
                    let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                    return centerLoc.distance(from: placeLoc) <= Double(place.radius) + 120.0
                }
                
                // --- 优先判断忽略逻辑 ---
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
                    matchedPlaceID = bestMatch.placeID
                } else {
                    // 二次兜底检查：即使没有在 120m 内匹配到精准地点，如果 250m 内有“已忽略”地点，也应倾向于忽略
                    let ignoredNearby = allPlaces.first { place in
                        place.isIgnored && centerLoc.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) < 250.0
                    }
                    if ignoredNearby != nil {
                        incrementProgress(cluster.count)
                        group.leave()
                        continue
                    }
                }
                
                // --- 自动带入历史标签 ---
                let tagsToApply = TagService.shared.findHistoricalTags(for: firstLoc.coordinate.latitude, longitude: firstLoc.coordinate.longitude, targetDate: startTime, in: bgContext)
                
                if matchedPlaceID == nil {
                    // 串行执行地名反查
                    geocoder.reverseGeocodeLocation(firstLoc) { placemarks, error in
                        if let pm = placemarks?.first {
                            let pmName = pm.name ?? ""
                            // 即使坐标没匹配上，如果反查出的地名/地址和已忽略地点的名称或地址匹配（模糊匹配），也过滤掉
                            let isAddressIgnored = allPlaces.contains { p in
                                p.isIgnored && (p.name == pmName || p.address == pmName || (p.address?.contains(pmName) == true))
                            }
                            
                            if isAddressIgnored {
                                incrementProgress(cluster.count)
                                group.leave()
                                return
                            }
                            
                            if !pmName.isEmpty {
                                title = pmName
                            } else if let area = pm.subLocality {
                                title = "\(area) 附近"
                            }
                        }
                        
                        let fp = Footprint(
                            date: Calendar.current.startOfDay(for: startTime),
                            startTime: startTime,
                            endTime: endTime,
                            footprintLocations: coords,
                            locationHash: hash,
                            duration: duration,
                            title: title,
                            status: .confirmed,
                            placeID: matchedPlaceID,
                            photoAssetIDs: cluster.map { $0.localIdentifier },
                            tags: tagsToApply
                        )
                        // CLGeocoder completion usually runs on main thread, but finalFootprints must be thread-safe
                        DispatchQueue.main.async {
                            finalFootprints.append(fp)
                            incrementProgress(cluster.count)
                            group.leave()
                        }
                    }
                    // 给 Geocoder 一点喘息时间（0.2秒间隔）
                    Thread.sleep(forTimeInterval: 0.2)
                } else {
                    let fp = Footprint(
                        date: Calendar.current.startOfDay(for: startTime),
                        startTime: startTime,
                        endTime: endTime,
                        footprintLocations: coords,
                        locationHash: hash,
                        duration: duration,
                        title: title,
                        status: .confirmed,
                        placeID: matchedPlaceID,
                        photoAssetIDs: cluster.map { $0.localIdentifier },
                        tags: tagsToApply
                    )
                    DispatchQueue.main.async {
                        finalFootprints.append(fp)
                        incrementProgress(cluster.count)
                        group.leave()
                    }
                }
            }
            
            // 处理剩余足迹（不解析，直接生成）
            for cluster in otherClusters {
                group.enter()
                guard let first = cluster.first, let last = cluster.last,
                      let rawLoc = first.location else { 
                    incrementProgress(cluster.count)
                    group.leave()
                    continue 
                }
                
                // 修正坐标偏移并计算中心点
                let firstLoc = rawLoc.gcj02
                let lastLoc = (cluster.last?.location ?? rawLoc).gcj02
                let centerLat = (firstLoc.coordinate.latitude + lastLoc.coordinate.latitude) / 2.0
                let centerLon = (firstLoc.coordinate.longitude + lastLoc.coordinate.longitude) / 2.0
                let centerLoc = CLLocation(latitude: centerLat, longitude: centerLon)
                
                let startTime = first.creationDate ?? Date()
                let endTime = last.creationDate ?? Date()
                let coords = cluster.compactMap { $0.location?.gcj02.coordinate }
                let hash = "\(Int(centerLat * 10000))\(Int(centerLon * 10000))"
                
                // 仅做位置匹配 (放宽匹配范围)
                var title = "发现足迹"
                var matchedPlaceID: UUID? = nil
                
                let matches = allPlaces.filter { place in
                    let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                    return centerLoc.distance(from: placeLoc) <= Double(place.radius) + 120.0
                }
                
                // --- 优先判断忽略逻辑 ---
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
                    matchedPlaceID = bestMatch.placeID
                } else {
                    // 二次兜底检查：250m 内若有已忽略地点则忽略
                    let ignoredNearby = allPlaces.first { place in
                        place.isIgnored && centerLoc.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) < 250.0
                    }
                    if ignoredNearby != nil {
                        incrementProgress(cluster.count)
                        group.leave()
                        continue
                    }
                }
                
                // --- 自动带入历史标签 ---
                let tagsForBatch = TagService.shared.findHistoricalTags(for: firstLoc.coordinate.latitude, longitude: firstLoc.coordinate.longitude, targetDate: startTime, in: bgContext)
                
                let fp = Footprint(
                    date: Calendar.current.startOfDay(for: startTime),
                    startTime: startTime,
                    endTime: endTime,
                    footprintLocations: coords,
                    locationHash: hash,
                    duration: endTime.timeIntervalSince(startTime),
                    title: title,
                    status: .confirmed,
                    placeID: matchedPlaceID,
                    photoAssetIDs: cluster.map { $0.localIdentifier },
                    tags: tagsForBatch
                )
                DispatchQueue.main.async {
                    finalFootprints.append(fp)
                    incrementProgress(cluster.count)
                    group.leave()
                }
            }
            
            // 完成后返回主线程
            group.notify(queue: .main) {
                let sorted = finalFootprints.sorted(by: { $0.startTime < $1.startTime })
                completion(sorted)
            }
        }
    }
}

