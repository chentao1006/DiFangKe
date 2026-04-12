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
    
    /// 获取一段时间内的照片总数 (高性能)
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
    
    /// 获取一段时间内且在一定范围内的照片
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
        
        // 1. 先进行高效的基础查询
        let result = PHAsset.fetchAssets(with: .image, options: options)
        
        // 2. 在后台进行耗时的 enumerate 和地理过滤
        DispatchQueue.global(qos: .userInitiated).async {
            var assets: [PHAsset] = []
            
            result.enumerateObjects { asset, _, _ in
                if let nearLocation = location, let assetLocation = asset.location {
                    let dist = CLLocation(latitude: nearLocation.latitude, longitude: nearLocation.longitude)
                        .distance(from: assetLocation)
                    // 适当放宽距离限制，特别是照片地理位置精度可能不如轨迹点的情况下
                    if dist <= maxDistance {
                        assets.append(asset)
                    }
                } else {
                    assets.append(asset)
                }
            }
            
            // 3. 返回主线程
            DispatchQueue.main.async {
                completion(assets)
            }
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
    func autoScanFootprints(from startDate: Date, to endDate: Date, allPlaces: [Place], excludedAssetIDs: Set<String>, existingFootprints: [(Date, Date, Double, Double)] = [], onProgress: ((Int, Int) -> Void)? = nil, completion: @escaping ([Footprint]) -> Void) {
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
        
        let maxDistance: CLLocationDistance = 500 // 放宽至 500米，确保更大范围内的照片能聚合到一起
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
        DispatchQueue.global(qos: .userInitiated).async {
            let sortedClusters = clusters.sorted(by: { $0.count > $1.count })
            // 缓存地理位置解析结果，避免同地点重复解析
            var geocodeCache: [String: (String, String?)] = [:]
            
            var finalFootprints: [Footprint] = []
            let group = DispatchGroup()
            let geocoder = CLGeocoder()
            
            var processedPhotosCount = 0
            let totalPhotosCount = assetsWithLocation.count
            
            let incrementProgress = { (count: Int) in
                processedPhotosCount += count
                DispatchQueue.main.async {
                    onProgress?(processedPhotosCount, totalPhotosCount)
                }
            }
            
            // 处理足迹（带解析与缓存）
            for cluster in sortedClusters {
                if self.isScanCancelled { break }
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
                
                // 缓存键：保留三位小数约 110米精度，足够复用地名
                let cacheKey = String(format: "%.3f,%.3f", centerLat, centerLon)
                
                // 1. 优先匹配已有的重要地点
                var title = "此处"
                var address: String? = nil
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
                    address = bestMatch.address
                    matchedPlaceID = bestMatch.placeID
                } else {
                    // 二次兜底检查
                    let ignoredNearby = allPlaces.first { place in
                        place.isIgnored && centerLoc.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) < 250.0
                    }
                    if ignoredNearby != nil {
                        incrementProgress(cluster.count)
                        group.leave()
                        continue
                    }
                }
                
                // 捕获循环中的常量数据，用于闭包调用
                let captureStartTime = startTime
                let captureEndTime = endTime
                let captureCoords = coords
                let captureHash = hash
                let captureDuration = duration
                let captureClusterIDs = cluster.map { $0.localIdentifier }
                let captureClusterCount = cluster.count

                // 统一的足迹创建与结果添加函数
                func createAndAdd(t: String, a: String?, pID: UUID?) {
                    Task { @MainActor in
                        let fp = Footprint(
                            date: Calendar.current.startOfDay(for: captureStartTime),
                            startTime: captureStartTime,
                            endTime: captureEndTime,
                            footprintLocations: captureCoords,
                            locationHash: captureHash,
                            duration: captureDuration,
                            title: Footprint.generateRandomTitle(for: t, seed: Int(captureStartTime.timeIntervalSince1970)),
                            status: .candidate,
                            placeID: pID,
                            photoAssetIDs: captureClusterIDs,
                            address: a
                        )
                        finalFootprints.append(fp)
                        incrementProgress(captureClusterCount)
                        group.leave()
                    }
                }
                
                // 如果没有匹配到地点，尝试从缓存获取或地理反查
                if matchedPlaceID == nil {
                    if let cached = geocodeCache[cacheKey] {
                        createAndAdd(t: cached.0, a: cached.1, pID: nil)
                    } else {
                        // 串行执行地名反查
                        geocoder.reverseGeocodeLocation(firstLoc) { placemarks, error in
                            var resolvedTitle = "此处"
                            var resolvedAddress: String? = nil
                            
                            if let pm = placemarks?.first {
                                let pmName = pm.name ?? ""
                                let pmSub = pm.subLocality ?? ""
                                let pmThorough = pm.thoroughfare ?? ""
                                
                                // 模糊忽略逻辑
                                let isAddressIgnored = allPlaces.contains { p in
                                    p.isIgnored && (p.name == pmName || p.address == pmName || (p.address?.contains(pmName) == true))
                                }
                                
                                if isAddressIgnored {
                                    incrementProgress(captureClusterCount)
                                    group.leave()
                                    return
                                }
                                
                                if !pmName.isEmpty {
                                    resolvedTitle = pmName
                                } else if !pmSub.isEmpty {
                                    resolvedTitle = "\(pmSub) 附近"
                                }
                                
                                if !pmThorough.isEmpty && pmName != pmThorough {
                                    resolvedAddress = "\(pmThorough) \(pmName)"
                                } else {
                                    resolvedAddress = pmName
                                }
                                
                                geocodeCache[cacheKey] = (resolvedTitle, resolvedAddress)
                            }
                            createAndAdd(t: resolvedTitle, a: resolvedAddress, pID: nil)
                        }
                        // 给 Geocoder 一点喘息时间
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                } else {
                    createAndAdd(t: title, a: address, pID: matchedPlaceID)
                }
            }
            
            // 完成后返回主线程
            group.notify(queue: .main) {
                Task { @MainActor in
                    // 过滤掉与已有足迹在时间和空间上高度重叠的候选
                    let filtered = finalFootprints.filter { candidate in
                        !existingFootprints.contains { existing in
                            let exStart = existing.0
                            let exEnd = existing.1
                            let exLat = existing.2
                            let exLon = existing.3
                            
                            // 1. 时间重叠判定 (包含、相交、被包含) 
                            // 使用标准区间重叠判定：max(start1, start2) < min(end1, end2)
                            // 且加入 5 分钟的容差，处理拍摄时间与足迹时间的微小偏差
                            let timeOverlap = max(candidate.startTime, exStart) < min(candidate.endTime, exEnd) ||
                                             abs(candidate.startTime.timeIntervalSince(exStart)) < 300
                            
                            // 2. 空间距离判定 (300米内视为同一地点，适配照片 GPS 的精度偏差)
                            let candidateLoc = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                            let existingLoc = CLLocation(latitude: exLat, longitude: exLon)
                            let distance = candidateLoc.distance(from: existingLoc)
                            let spaceMatch = distance < 300
                            
                            return timeOverlap && spaceMatch
                        }
                    }
                    
                    let sorted = filtered.sorted(by: { $0.startTime < $1.startTime })
                    completion(sorted)
                }
            }
        }
    }
}

