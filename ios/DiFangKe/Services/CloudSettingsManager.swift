import Foundation
import Combine

class CloudSettingsManager: ObservableObject {
    static let shared = CloudSettingsManager()
    
    private var cancellables = Set<AnyCancellable>()
    private var periodicSyncCancellable: AnyCancellable?
    private let kvs = NSUbiquitousKeyValueStore.default
    private let periodicSyncInterval: TimeInterval = 600
    
    private let syncedKeys = [
        "isAiAssistantEnabled",
        "aiServiceType",
        "isICloudSyncEnabled",
        "isAutoPhotoLinkEnabled",
        "hasSeenPhotoPermissionGuide",
        "raw_recording_source_device_id",
        "dataSyncPulse",
        "customAiUrl",
        "customAiKey",
        "customAiModel",
        "liveStayStatus",
        "hasSeededDefaultData"
    ]
    
    private init() {
        // 当云端数据变化时，同步到本地
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .sink { [weak self] notification in
                self?.handleExternalChange(notification)
            }
            .store(in: &cancellables)

        // 初始同步仅在真机且 iCloud 可用时执行；模拟器/未登录账号不强求。
        if shouldUseCloudServices {
            kvs.synchronize()
        }
    }
    
    /// 开始监听本地变化并同步到云端
    func startSyncing() {
        guard shouldUseCloudServices else {
            print("[CloudSettings] iCloud unavailable or disabled; skipping cloud sync startup.")
            periodicSyncCancellable?.cancel()
            periodicSyncCancellable = nil
            return
        }

        if periodicSyncCancellable != nil {
            return
        }

        print("[CloudSettings] Starting sync...")
        _ = syncFromCloudNow()

        // 改为定时同步，避免每次本地设置波动都触发云端写入。
        periodicSyncCancellable?.cancel()
        periodicSyncCancellable = Timer.publish(every: periodicSyncInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.syncAllLocalToCloud()
            }
    }

    @discardableResult
    func syncFromCloudNow() -> Set<String> {
        guard shouldUseCloudServices else { return [] }

        var changedKeys = Set<String>()
        var notificationChanged = false

        for key in syncedKeys {
            if let cloudValue = kvs.object(forKey: key) {
                let localValue = UserDefaults.standard.object(forKey: key)
                if !isEqual(cloudValue, localValue) {
                    let localValueDescription = localValue ?? "nil"
                    print("[CloudSettings] Key '\(key)' updated from cloud: \(localValueDescription) -> \(cloudValue)")
                    UserDefaults.standard.set(cloudValue, forKey: key)
                    changedKeys.insert(key)
                    if key.contains("Notification") {
                        notificationChanged = true
                    }
                }
            }
        }

        if notificationChanged {
            NotificationManager.shared.refreshSettings()
        }

        return changedKeys
    }

    /// 用户手动触发：立即将本地设置推送到云端。
    func manualSyncNow() {
        syncAllLocalToCloud()
    }
    
    private func syncAllLocalToCloud() {
        for key in syncedKeys {
            syncLocalToCloud(key: key)
        }
    }
    
    private func syncLocalToCloud(key: String) {
        let localValue = UserDefaults.standard.object(forKey: key)
        let cloudValue = kvs.object(forKey: key)
        
        if let localValue = localValue, !isEqual(localValue, cloudValue) {
            print("[CloudSettings] Syncing local key '\(key)' to cloud: \(cloudValue ?? "nil") -> \(localValue)")
            kvs.set(localValue, forKey: key)
        }
    }
    
    private func handleExternalChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              reason == NSUbiquitousKeyValueStoreServerChange || reason == NSUbiquitousKeyValueStoreInitialSyncChange else {
            return
        }
        
        guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        
        print("[CloudSettings] External change detected for keys: \(changedKeys)")
        
        for key in changedKeys where syncedKeys.contains(key) {
            if let newValue = kvs.object(forKey: key) {
                let localValue = UserDefaults.standard.object(forKey: key)
                if !isEqual(newValue, localValue) {
                    print("[CloudSettings] Externally updating local key '\(key)': \(localValue ?? "nil") -> \(newValue)")
                    UserDefaults.standard.set(newValue, forKey: key)
                    
                    // 如果是通知相关的设置，同步更新通知计划
                    if key.contains("Notification") {
                        NotificationManager.shared.refreshSettings()
                    }
                    
                    // 如果收到数据同步脉冲，通知 UI 可能需要刷新
                    if key == "dataSyncPulse" {
                        NotificationCenter.default.post(name: NSNotification.Name("RemoteDataChanged"), object: nil)
                    }
                }
            }
        }
    }
    
    /// 当重要数据（如地点、活动类型）变更时，触发一个云端脉冲，通过 KVS 几乎瞬间通知其他设备数据已变
    func triggerDataSyncPulse() {
        // 按新策略：不再自动触发脉冲，避免导致远端立即同步风暴。
    }

    /// 手动触发数据同步脉冲（用于下拉刷新等用户主动操作）。
    func triggerDataSyncPulseManual() {
        let now = Date().timeIntervalSince1970
        print("[CloudSettings] Triggering data sync pulse: \(now)")
        UserDefaults.standard.set(now, forKey: "dataSyncPulse")
        // Set it in KVS to notify other devices
        kvs.set(now, forKey: "dataSyncPulse")
        
        // Also post locally so the current device can perform immediate raw data sync if needed
        NotificationCenter.default.post(name: NSNotification.Name("RemoteDataChanged"), object: nil)
    }
    
    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }

        if let aObj = a as? NSObject, let bObj = b as? NSObject {
            return aObj.isEqual(bObj)
        }
        
        // Handle numbers correctly (Int, Double, Bool can sometimes be cross-cast as NSNumber)
        if let aNum = a as? NSNumber, let bNum = b as? NSNumber {
            return aNum.isEqual(to: bNum)
        }
        
        if let aStr = a as? String, let bStr = b as? String { return aStr == bStr }
        
        return false
    }

    private var shouldUseCloudServices: Bool {
#if targetEnvironment(simulator)
        return false
#else
        let isICloudSyncEnabled = UserDefaults.standard.object(forKey: "isICloudSyncEnabled") as? Bool ?? true
        return isICloudSyncEnabled && FileManager.default.ubiquityIdentityToken != nil
#endif
    }
}
