import Foundation
import Combine

class CloudSettingsManager: ObservableObject {
    static let shared = CloudSettingsManager()
    
    private var cancellables = Set<AnyCancellable>()
    private let kvs = NSUbiquitousKeyValueStore.default
    
    private let syncedKeys = [
        "isAiAssistantEnabled",
        "aiServiceType",
        "isICloudSyncEnabled",
        "isAutoPhotoLinkEnabled",
        "dailyNotificationHour",
        "dailyNotificationMinute",
        "isDailyNotificationEnabled",
        "isHighlightNotificationEnabled",
        "isNotificationGuideDismissed",
        "hasSeenPhotoPermissionGuide",
        "isTrackingEnabled",
        "dataSyncPulse",
        "customAiUrl",
        "customAiKey",
        "customAiModel"
    ]
    
    private init() {
        // 当云端数据变化时，同步到本地
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .sink { [weak self] notification in
                self?.handleExternalChange(notification)
            }
            .store(in: &cancellables)
        
        // 初始同步
        kvs.synchronize()
    }
    
    /// 开始监听本地变化并同步到云端
    func startSyncing() {
        print("[CloudSettings] Starting sync...")
        var notificationChanged = false
        // 第一次运行，确保本地有最新的云端数据
        for key in syncedKeys {
            if let cloudValue = kvs.object(forKey: key) {
                let localValue = UserDefaults.standard.object(forKey: key)
                if !isEqual(cloudValue, localValue) {
                    print("[CloudSettings] Key '\(key)' updated from cloud: \(localValue ?? "nil") -> \(cloudValue)")
                    UserDefaults.standard.set(cloudValue, forKey: key)
                    if key.contains("Notification") {
                        notificationChanged = true
                    }
                }
            }
        }
        
        if notificationChanged {
            NotificationManager.shared.refreshSettings()
        }
        
        // 监听本地变化并同步到云端 (合并为一个发布者，更高效)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAllLocalToCloud()
            }
            .store(in: &cancellables)
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
            kvs.synchronize()
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
        let now = Date().timeIntervalSince1970
        print("[CloudSettings] Triggering data sync pulse: \(now)")
        UserDefaults.standard.set(now, forKey: "dataSyncPulse")
        // 注意：kvs 也要设，这样本地 syncLocalToCloud 也会被触发一次双保险
    }
    
    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }
        
        // Handle numbers correctly (Int, Double, Bool can sometimes be cross-cast as NSNumber)
        if let aNum = a as? NSNumber, let bNum = b as? NSNumber {
            return aNum.isEqual(to: bNum)
        }
        
        if let aStr = a as? String, let bStr = b as? String { return aStr == bStr }
        
        return false
    }
}
