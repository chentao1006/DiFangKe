import Photos
import UIKit
import CoreLocation
import SwiftData

class PhotoService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoService()
    
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    var modelContext: ModelContext? {
        didSet {
            if modelContext != nil {
                // 只有在用户已经授权或明确拒绝过（即非未决定状态）时才自动同步，避免启动即弹窗请求权限
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status != .notDetermined {
                    syncDeletedPhotos()
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
    
    // PHPhotoLibraryChangeObserver
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 系统相册发生变化时，检查是否有照片被删除
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        
        DispatchQueue.global(qos: .background).async {
            self.syncDeletedPhotos()
        }
    }
    
    func syncDeletedPhotos() {
        Task { @MainActor in
            guard let context = modelContext else { return }
            
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
            
            let descriptor = FetchDescriptor<Footprint>()
            
            do {
                let allFootprints = try context.fetch(descriptor)
                let footprintsWithPhotos = allFootprints.filter { !$0.photoAssetIDs.isEmpty }
                if footprintsWithPhotos.isEmpty { return }
                
                let allAssetIDs = Array(Set(footprintsWithPhotos.flatMap { $0.photoAssetIDs }))
                
                let deletedIDs = await Task.detached(priority: .background) {
                    let result = PHAsset.fetchAssets(withLocalIdentifiers: allAssetIDs, options: nil)
                    var existingIDs = Set<String>()
                    result.enumerateObjects { asset, _, _ in
                        existingIDs.insert(asset.localIdentifier)
                    }
                    return Set(allAssetIDs).subtracting(existingIDs)
                }.value

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
}

