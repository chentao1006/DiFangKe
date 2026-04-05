import Foundation
import CoreLocation
import SwiftData
import Combine
import SwiftUI
import MapKit
import CloudKit

// MARK: - 位置建议结构体
struct LocationSuggestion: Identifiable {
    let id: UUID
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    var isExistingPlace: Bool
    var placeID: UUID?
}

// MARK: - 原始坐标持久化存储（按天存储至 CSV 文件）
final class RawLocationStore {
    static let shared = RawLocationStore()
    
    private let fileManager = FileManager.default
    private let directoryName = "RawLocations"
    
    private init() {
        createDirectoryIfNeeded()
    }
    
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var baseDirectory: URL {
        documentsDirectory.appendingPathComponent(directoryName)
    }
    
    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }
    
    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "raw_location_device_id") {
            return id
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "raw_location_device_id")
        return id
    }

    private func getFileURL(for date: Date, device: String? = nil) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let baseName = formatter.string(from: date)
        let fileName = device == nil ? "\(baseName).csv" : "\(baseName)-\(device!).csv"
        return baseDirectory.appendingPathComponent(fileName)
    }
    
    /// 保存单个位置点到当日文件
    func saveLocation(_ location: CLLocation) {
        let url = getFileURL(for: location.timestamp)
        let line = "\(location.timestamp.timeIntervalSince1970),\(location.coordinate.latitude),\(location.coordinate.longitude),\(location.horizontalAccuracy),\(location.speed)\n"
        
        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: url.path) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
    
    /// 读取指定日期的所有坐标点
    func loadLocations(for date: Date) -> [CLLocation] {
        let url = getFileURL(for: date)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        
        var locations: [CLLocation] = []
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines where !line.isEmpty {
            let parts = line.components(separatedBy: ",")
            if parts.count >= 3,
               let ts = Double(parts[0]),
               let lat = Double(parts[1]),
               let lon = Double(parts[2]) {
                
                let accuracy = parts.count > 3 ? (Double(parts[3]) ?? 0) : 0
                let speed = parts.count > 4 ? (Double(parts[4]) ?? 0) : 0
                
                let loc = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: 0,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: 0,
                    course: 0,
                    speed: speed,
                    timestamp: Date(timeIntervalSince1970: ts)
                )
                locations.append(loc)
            }
        }
        return locations
    }
    
    /// 获取最近一段的点。如果提供了 since，则至少获取到 since 那个时间点。
    func loadRecentLocations(lookbackHours: Double = 2.0, since: Date? = nil) -> [CLLocation] {
        let now = Date()
        let defaultThreshold = now.addingTimeInterval(-lookbackHours * 3600)
        let threshold = since.map { min($0, defaultThreshold) } ?? defaultThreshold
        
        // 限制回溯至 24 小时内，防止数据量过大导致崩溃
        let finalThreshold = max(threshold, now.addingTimeInterval(-24 * 3600))
        
        let today = loadLocations(for: now)
        var recent = today.filter { $0.timestamp >= finalThreshold }
        
        if finalThreshold < Calendar.current.startOfDay(for: now) {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            let yesterdayLocations = loadLocations(for: yesterday)
            let yesterdayRecent = yesterdayLocations.filter { $0.timestamp >= finalThreshold }
            recent = yesterdayRecent + recent
        }
        
        return recent
    }

    /// 读取指定日期的所有坐标点（包含本设备和其他同步过来的设备）
    func loadAllDevicesLocations(for date: Date) -> [CLLocation] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: date)
        
        guard let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var allPoints: [CLLocation] = []
        let relevantFiles = files.filter { $0.lastPathComponent.hasPrefix(datePrefix) && $0.pathExtension == "csv" }
        
        for fileURL in relevantFiles {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    let parts = line.components(separatedBy: ",")
                    if parts.count >= 3,
                       let ts = Double(parts[0]),
                       let lat = Double(parts[1]),
                       let lon = Double(parts[2]) {
                        
                        let accuracy = parts.count > 3 ? (Double(parts[3]) ?? 0) : 0
                        let speed = parts.count > 4 ? (Double(parts[4]) ?? 0) : 0
                        
                        let loc = CLLocation(
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            altitude: 0,
                            horizontalAccuracy: accuracy,
                            verticalAccuracy: 0,
                            course: 0,
                            speed: speed,
                            timestamp: Date(timeIntervalSince1970: ts)
                        )
                        allPoints.append(loc)
                    }
                }
            }
        }
        
        return allPoints.sorted { $0.timestamp < $1.timestamp }
    }

    // --- CloudKit 手动同步相关 ---

    private let cloudDatabase = CKContainer(identifier: "iCloud.com.ct106.difangke").privateCloudDatabase

    func syncToiCloud() async throws -> Int {
        let localFiles = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        var totalCount = 0

        // 1. 上传本地文件 (带上当前设备 ID)
        for localURL in localFiles {
            let fileName = localURL.lastPathComponent
            // 只要文件名长度正好是 14 位 (例如 2026-04-04.csv)，就视为本地待上传文件
            guard fileName.hasSuffix(".csv") && fileName.count == 14 else { continue }
            
            let dateStr = fileName.replacingOccurrences(of: ".csv", with: "")
            let recordID = CKRecord.ID(recordName: "\(dateStr)-\(deviceID)")
            
            let record = CKRecord(recordType: "RawTrajectory", recordID: recordID)
            record["date"] = dateStr
            record["deviceID"] = deviceID
            record["file"] = CKAsset(fileURL: localURL)
            
            // 使用 CKModifyRecordsOperation 进行覆盖保存
            let modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOp.savePolicy = .allKeys
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                modifyOp.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                cloudDatabase.add(modifyOp)
            }
            totalCount += 1
        }

        // 2. 下载最近 7 天其他设备的文件
        do {
            let calendar = Calendar.current
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            
            // 计算最近 7 天的所有日期字符串
            var dateStrings: [String] = []
            for i in 0..<7 {
                if let date = calendar.date(byAdding: .day, value: -i, to: Date()) {
                    dateStrings.append(formatter.string(from: date))
                }
            }
            
            // 使用 IN 查询，规避 String 不支持范围查询的问题
            let predicate = NSPredicate(format: "date IN %@", dateStrings)
            let query = CKQuery(recordType: "RawTrajectory", predicate: predicate)
            
            let (results, _) = try await cloudDatabase.records(matching: query)
            
            for (_, result) in results {
                if let record = try? result.get() {
                    let remoteDeviceID = record["deviceID"] as? String ?? ""
                    let remoteDate = record["date"] as? String ?? ""
                    
                    // 只有其他设备的数据才下载
                    if remoteDeviceID != deviceID && !remoteDate.isEmpty {
                        if let asset = record["file"] as? CKAsset, let assetURL = asset.fileURL {
                            let localFileName = "\(remoteDate)-\(remoteDeviceID).csv"
                            let localURL = baseDirectory.appendingPathComponent(localFileName)
                            
                            if fileManager.fileExists(atPath: localURL.path) {
                                try? fileManager.removeItem(at: localURL)
                            }
                            try? fileManager.copyItem(at: assetURL, to: localURL)
                            totalCount += 1
                        }
                    }
                }
            }
        } catch let error as CKError where error.code == .unknownItem {
            // 云端还没有 RawTrajectory 表，说明是首次同步，跳过下载即可
        } catch {
            // 其他错误正常抛出
            throw error
        }
        
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "raw_locations_last_sync")
        return totalCount
    }

    var lastSyncDate: Date? {
        let ts = UserDefaults.standard.double(forKey: "raw_locations_last_sync")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }
}

// MARK: - 候选足迹结构体（停留点识别输出）
struct CandidateFootprint {
    let startTime: Date
    let endTime: Date
    let centerCoordinate: CLLocationCoordinate2D
    let duration: TimeInterval
    let rawLocations: [CLLocation]
}

// MARK: - 足迹处理器（去噪 + 停留点识别 + 合并判断）
final class FootprintProcessor {
    static let shared = FootprintProcessor()
    
    // 1.2 去噪参数
    private let minAccuracy: CLLocationAccuracy = 100.0   // 精度过滤
    private let minTimeInterval: TimeInterval = 5.0       // 时间间隔过滤
    private let driftDistanceThreshold: CLLocationDistance = 200.0
    private let driftSpeedThreshold: CLLocationSpeed = 45.0 // m/s，异常飘移速度（约162km/h，兼顾高铁环境）
    
    // 1.3 停留点识别参数
    private let stayRadiusThreshold: CLLocationDistance = 100.0  // 半径 < 100m（适配大型商场与室内漂移）
    private let stayDurationThreshold: TimeInterval = 7 * 60     // 持续 >= 7 分钟（捕捉买咖啡等微足迹）
    
    // 1.4 合并参数（更严格：避免跨度过大的地点合并）
    private let mergeTimeThreshold: TimeInterval = 15 * 60       // 间隔 < 15 分钟
    private let mergeDistanceThreshold: CLLocationDistance = 100.0 // 降低到 100m
    
    /// 处理新定位点，满足停留条件则返回 CandidateFootprint
    func processNewLocation(_ location: CLLocation, queue: inout [CLLocation]) -> CandidateFootprint? {
        // 过滤精度过差的点（室内环境放宽到 200 米，确保不再丢点）
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy < 200 else { return nil }
              
        // 1.2 时间鲜度过滤：丢弃 1 分钟前的缓存数据或过时数据
        guard abs(location.timestamp.timeIntervalSinceNow) < 60 else { return nil }
        
        if let lastLoc = queue.last {
            // 时间间隔过滤
            let timeInterval = location.timestamp.timeIntervalSince(lastLoc.timestamp)
            guard timeInterval >= minTimeInterval else { return nil }
            
            // 漂移过滤：大位移 + 高速
            let distance = location.distance(from: lastLoc)
            if distance > driftDistanceThreshold && location.speed > driftSpeedThreshold {
                return nil
            }
        }
        
        // 1. 先将点压入队列，保证轨迹不间断
        queue.append(location)
        
        // 2. 深度防御：我们克隆一份快照来分析，绝对不让分析逻辑改变原队列
        let analysisQueue = Array(queue)
        
        if analysisQueue.count > 1 {
            let center = calculateCenter(Array(analysisQueue.dropLast()))
            let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let distToCenter = location.distance(from: centerLoc)
            
            if distToCenter > stayRadiusThreshold {
                if let candidate = detectStayPoint(in: Array(analysisQueue.dropLast())) {
                    return candidate
                }
            }
        }
        
        return detectStayPoint(in: analysisQueue)
    }
    
    private func detectStayPoint(in locations: [CLLocation]) -> CandidateFootprint? {
        guard locations.count >= 2 else { return nil }
        
        let startTime = locations.first!.timestamp
        let endTime = locations.last!.timestamp
        let duration = endTime.timeIntervalSince(startTime)
        
        guard duration >= stayDurationThreshold else { return nil }
        
        let center = calculateCenter(locations)
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = locations.map { $0.distance(from: centerLoc) }.max() ?? 0
        
        guard maxDistance < stayRadiusThreshold else { return nil }
        
        return CandidateFootprint(
            startTime: startTime,
            endTime: endTime,
            centerCoordinate: center,
            duration: duration,
            rawLocations: locations
        )
    }
    
    func calculateCenter(_ locations: [CLLocation]) -> CLLocationCoordinate2D {
        let avgLat = locations.map { $0.coordinate.latitude }.reduce(0, +) / Double(locations.count)
        let avgLon = locations.map { $0.coordinate.longitude }.reduce(0, +) / Double(locations.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }
    
    /// 判断新候选足迹是否应与最近已有足迹合并
    func shouldMerge(lastFootprint: Footprint, newCandidate: CandidateFootprint) -> Bool {
        let timeInterval = newCandidate.startTime.timeIntervalSince(lastFootprint.endTime)
        guard timeInterval >= 0, timeInterval < mergeTimeThreshold else { return false }
        
        let lastLoc = CLLocation(latitude: lastFootprint.latitude, longitude: lastFootprint.longitude)
        let newLoc = CLLocation(latitude: newCandidate.centerCoordinate.latitude,
                                longitude: newCandidate.centerCoordinate.longitude)
        let distance = lastLoc.distance(from: newLoc)
        
        return distance < mergeDistanceThreshold
    }
    
    func finalizeCurrentStay(queue: inout [CLLocation]) -> CandidateFootprint? {
        return detectStayPoint(in: queue)
    }
}

// MARK: - LocationManager
@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    
    var isAuthorized: Bool = false
    var isAlwaysAuthorized: Bool = false
    var authStatus: CLAuthorizationStatus = .notDetermined
    
    var isTracking: Bool = false
    var lastUpdateTime: Date?
    var lastLocation: CLLocation?
    var accuracy: CLLocationAccuracy?
    var currentAddress: String = "正在解析位置..."
    var trackingPoints: [CLLocation] = [] // 用于足迹识别的内存滑动窗口
    var allTodayPoints: [CLLocation] = [] // 本日流水缓存，从 RawLocationStore 加载
    var todayTotalPointsCount: Int = 0    // 全天流水点数，基于本地文件统计
    var ongoingTitle: String?
    private var lastAIAnalysisTime: Date?
    private var isAnalyzingOngoing = false
    /// 标记上一个分类足迹的截止时间，避免重复识别 (同时满足 3 天全量数据保留)
    private var lastProcessedTimestamp: Date?
    
    // 从 View 同步过来的参数
    var allPlaces: [Place] = []
    var modelContext: ModelContext? {
        didSet {
            if modelContext != nil {
                loadPointsFromStore() // 获得数据库后，重新加载点并同步最后处理时间
            }
        }
    }
    
    // 正在记录的临时停留状态
    var potentialStopStartLocation: CLLocation?
    
    /// 根据当前精度/省电模式，提供给 UI 呈现不同频率的“呼吸”动画时长
    var pulseDuration: Double {
        if !isTracking { return 4.0 }
        let acc = locationManager.desiredAccuracy
        if acc < 20.0 { // 10m - 高频
            return 0.8
        } else if locationManager.activityType == .automotiveNavigation { // 高速巡航
            return 1.8
        } else { // 100m - 低功耗
            return 3.5
        }
    }
    
    // 服务引用
    private let footprintProcessor = FootprintProcessor.shared
    private let openAIService = OpenAIService.shared
    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?
    
    // 标签继承距离阈值：150米
    private let tagInheritanceDistance: CLLocationDistance = 150.0
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters // 恢复平衡精度
        self.locationManager.distanceFilter = 20.0 // 恢复常规频率
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.pausesLocationUpdatesAutomatically = true // 允许自动暂停以省电
        self.locationManager.showsBackgroundLocationIndicator = false
        self.locationManager.activityType = .other
        
        // Initialize stored properties
        updateAuthStatus()
        loadPotentialStop()
        loadTodayTotalPoints()
        loadPointsFromStore() // 从本地文件恢复内存队列，防止因杀死进程导致的记录丢失
    }
    
    private func updateAuthStatus() {
        authStatus = locationManager.authorizationStatus
        isAuthorized = (authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse)
        isAlwaysAuthorized = (authStatus == .authorizedAlways)
    }

    var lastUpdateTimeString: String {
        lastUpdateTime?.formatted(date: .omitted, time: .shortened) ?? "--:--"
    }

    var stayDuration: String? {
        guard let start = potentialStopStartLocation?.timestamp else { return nil }
        let duration = Date().timeIntervalSince(start)
        let totalMinutes = Int(duration / 60)
        if totalMinutes < 1 { return nil }
        
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes > 0 {
                return "\(hours) 小时 \(minutes) 分钟"
            } else {
                return "\(hours) 小时"
            }
        } else {
            return "\(totalMinutes) 分钟"
        }
    }

    var matchedPlace: Place? {
        guard let currentGcj = lastLocation ?? potentialStopStartLocation else { return nil }
        
        // 1. 找出所有在范围内的地点
        let validMatches = allPlaces.filter { place in
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = currentGcj.distance(from: placeLocation)
            return distance <= Double(place.radius) + 100.0
        }
        
        // 优先返回用户标记为“优先识别”的地点
        if let priorityMatch = validMatches.first(where: { $0.isPriority }) {
            return priorityMatch
        }
        
        // 2. 从符合条件的地点中，选出距离圆心最近的那一个
        return validMatches.min { p1, p2 in
            let d1 = currentGcj.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
            let d2 = currentGcj.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
            return d1 < d2
        }
    }

    func requestPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func forceRefreshOngoingAnalysis() {
        guard isTracking, let loc = lastLocation else { return }
        ongoingTitle = nil
        analyzeOngoingStay(at: loc)
    }
    
    func startTracking() {
        // First check permission and settings
        // Default to true if not explicitly set
        let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
        
        let isFirstLaunch = UserDefaults.standard.bool(forKey: "isFirstLaunch") || UserDefaults.standard.object(forKey: "isFirstLaunch") == nil
        
        guard isEnabled || isFirstLaunch else {
            stopTracking()
            return
        }

        locationManager.requestAlwaysAuthorization()
        
        // Re-enable updates if they were stopped
        locationManager.startUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        isTracking = true
        
        // On app open, force a fresh high-accuracy location fix
        locationManager.requestLocation() // This will trigger a one-time precise update
        
        // 后台异步执行维护任务，避免卡启动画面
        let container = modelContext?.container
        Task.detached(priority: .background) { [weak self] in
            guard let self = self, let container = container else { return }
            let context = ModelContext(container)
            await self.consolidateFootprints(in: context)
            
            // If it's evening, trigger notification summary refresh
            Task { @MainActor in
                let hour = Calendar.current.component(.hour, from: Date())
                if hour >= 18 {
                    self.triggerNotificationSummaryRefresh()
                }
            }
        }
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        isTracking = false
        // 清理当前可能的停留状态
        potentialStopStartLocation = nil
        ongoingTitle = nil
        UserDefaults.standard.removeObject(forKey: "pending_lat")
        UserDefaults.standard.removeObject(forKey: "pending_lng")
        UserDefaults.standard.removeObject(forKey: "pending_time")
    }

    /// 合并数据库中已有的碎片足迹（必须在主线程执行）
    /// 第一步：删除时长 < 5分钟的噪点记录
    /// 第二步：合并间隔 < 30分钟 且 距离 < 200m 的相邻记录
    public func consolidateFootprints(in context: ModelContext) async {
        let mergeTime: TimeInterval = 30 * 60
        let mergeDist: CLLocationDistance = 200.0  // 统一阈值为 200m
        let minKeepDuration: TimeInterval = 5 * 60  // 小于5分钟视为噪点

        // 为了性能，自动维护只针对最近 7 天的数据，避免每次全量扫库导致卡顿
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.statusValue != "ignored" && $0.startTime > sevenDaysAgo },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        guard let all = try? context.fetch(descriptor) else { return }

        // ── 第一步：清理噪点（时长 < 5分钟 或 完全重复的记录）──
        var seen = Set<String>()
        for fp in all {
            // 删除时长过短的记录
            if fp.duration < minKeepDuration {
                context.delete(fp)
                continue
            }
            // 删除完全重复的记录（相同 startTime + endTime + 坐标）
            let key = "\(fp.startTime.timeIntervalSince1970)-\(fp.endTime.timeIntervalSince1970)-\(fp.latitude)-\(fp.longitude)"
            if seen.contains(key) {
                context.delete(fp)
            } else {
                seen.insert(key)
            }
        }
        try? context.save()

        // ── 第二步：重新 fetch 清理后的记录，做合并 ──
        guard let cleaned = try? context.fetch(descriptor) else { return }

        let grouped = Dictionary(grouping: cleaned) { fp -> Date in
            Calendar.current.startOfDay(for: fp.startTime)
        }

        for (_, dayFootprints) in grouped {
            let sorted = dayFootprints.sorted { $0.startTime < $1.startTime }
            // ── 第一步：逻辑合并（相邻且近） ──
            var i = 0
            while i < sorted.count - 1 {
                let base = sorted[i]
                let next = sorted[i + 1]

                // 时间间隔：负数表示重叠，视同可合并
                let timeGap = next.startTime.timeIntervalSince(base.endTime)
                let baseLoc = CLLocation(latitude: base.latitude, longitude: base.longitude)
                let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
                let dist = baseLoc.distance(from: nextLoc)

                if timeGap <= mergeTime && dist <= mergeDist {
                    // 合并：取最早 start、最晚 end
                    base.startTime = min(base.startTime, next.startTime)
                    base.endTime = max(base.endTime, next.endTime)
                    base.duration = base.endTime.timeIntervalSince(base.startTime)
                    var path = base.footprintLocations
                    path.append(contentsOf: next.footprintLocations)
                    base.footprintLocations = path
                    context.delete(next)
                    // i 不递增，继续尝试将后续邻近项合并进来
                } else {
                    i += 1
                }
            }
            
            // ── 第二步：对单条过长/跨度过大的足迹进行“回溯拆分”（针对存量错分数据） ──
            for fp in sorted {
                // 地点自动重校准（自愈逻辑）：仅对未匹配或标记为 TBD 的进行校准，避免性能问题
                if fp.placeID == nil || fp.locationHash == "TBD" {
                    let bestPlace = allPlaces.filter { place in
                        let pLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                        let fLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                        return fLoc.distance(from: pLoc) <= Double(place.radius) + 100.0
                    }.min { p1, p2 in
                        let fLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                        let d1 = fLoc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
                        let d2 = fLoc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
                        return d1 < d2
                    }
                    
                    if fp.placeID != bestPlace?.placeID {
                        fp.placeID = bestPlace?.placeID
                        if let bp = bestPlace, (fp.address ?? "").isEmpty { fp.address = bp.address }
                    }
                }
                
                splitLargeFootprintByDistance(fp, in: context)
            }
        }

        try? context.save()
    }

    /// 针对已经合并成一整个 Footprint 的轨迹，尝试进行聚类拆分
    public func splitLargeFootprintByDistance(_ fp: Footprint, in context: ModelContext) {
        let coords = fp.footprintLocations
        // 核心：基于位置聚类寻找多个“停留点”
        guard coords.count > 10 else { return }
        
        var clusters: [(start: Int, end: Int, center: CLLocationCoordinate2D)] = []
        var i = 0
        while i < coords.count {
            var j = i + 1
            while j < coords.count {
                let startLoc = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                let currLoc = CLLocation(latitude: coords[j].latitude, longitude: coords[j].longitude)
                if startLoc.distance(from: currLoc) < 100.0 { // 100m 聚类半径
                    j += 1
                } else {
                    break
                }
            }
            // 如果某区域连续聚集了 4 个点以上，判定为一个独立停留点
            if (j - i) >= 4 {
                let segment = Array(coords[i..<j])
                let lat = segment.map { $0.latitude }.reduce(0, +) / Double(segment.count)
                let lon = segment.map { $0.longitude }.reduce(0, +) / Double(segment.count)
                clusters.append((i, j - 1, CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            }
            i = j
        }
        
        // 如果发现了多个在地理上相互疏离（距离 > 120m）的聚类
        if clusters.count > 1 {
            var distinctClusters: [(start: Int, end: Int)] = []
            if let first = clusters.first {
                distinctClusters.append((first.start, first.end))
                var lastCenter = first.center
                
                for k in 1..<clusters.count {
                    let curr = clusters[k]
                    let lastLoc = CLLocation(latitude: lastCenter.latitude, longitude: lastCenter.longitude)
                    let currLoc = CLLocation(latitude: curr.center.latitude, longitude: curr.center.longitude)
                    
                    if currLoc.distance(from: lastLoc) > 120.0 {
                        distinctClusters.append((curr.start, curr.end))
                        lastCenter = curr.center
                    } else {
                        // 距离很近，扩展现有的段
                        let lastIdx = distinctClusters.count - 1
                        distinctClusters[lastIdx].end = curr.end
                    }
                }
            }
            
            if distinctClusters.count > 1 {
                let totalPoints = Double(coords.count)
                let totalDuration = fp.duration
                let baseStart = fp.startTime
                
                // 进行逻辑拆分
                for (idx, cluster) in distinctClusters.enumerated() {
                    let subCoords = Array(coords[cluster.start...cluster.end])
                    // 估算时间段
                    let sTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.start) / totalPoints))
                    let eTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.end) / totalPoints))
                    
                    if idx == 0 {
                        fp.footprintLocations = subCoords
                        fp.startTime = sTime
                        fp.endTime = eTime
                        fp.duration = eTime.timeIntervalSince(sTime)
                        fp.locationHash = "SPLIT_FIXED"
                        self.analyzeFootprint(fp)
                    } else {
                        let newFp = Footprint(
                            date: fp.date,
                            startTime: sTime,
                            endTime: eTime,
                            footprintLocations: subCoords,
                            locationHash: "SPLIT_FIXED",
                            duration: eTime.timeIntervalSince(sTime),
                            title: "[自动修复] " + fp.title,
                            address: nil
                        )
                        context.insert(newFp)
                        // 将 ID 传回主线程进行分析，避免跨线程访问 Model
                        let fid = newFp.persistentModelID
                        Task { @MainActor in
                            self.analyzeFootprintByID(fid)
                        }
                    }
                }
                try? context.save()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let rawLocation = locations.last else { return }
        
        // 全局纠正：进入中国境内后，立即将 WGS-84 转换为 GCJ-02
        // 这样后续所有逻辑（足迹存储、地标匹配、UI显示）都统一使用火星坐标系
        let location = rawLocation.gcj02
        
        lastLocation = location
        lastUpdateTime = Date()
        accuracy = location.horizontalAccuracy
        
        // 0. 智能节能：根据速度和停留状态动态调整定位参数
        let place = matchedPlace
        let speed = location.speed
        
        // 判定是否正在长久停留 (非忽略地点也会进入低功耗，但门槛稍高)
        let isStationary = potentialStopStartLocation.map { Date().timeIntervalSince($0.timestamp) > 300 && location.distance(from: $0) < 50.0 } ?? false
        
        if let p = place, p.isIgnored {
            // 已忽略地点：进入强制低功耗
            if manager.desiredAccuracy != kCLLocationAccuracyHundredMeters {
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.distanceFilter = 100.0
            }
        } else if isStationary {
            // 普通地点但已停留：进入节能模式
            if manager.desiredAccuracy != kCLLocationAccuracyHundredMeters {
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.distanceFilter = 50.0
            }
        } else if speed > 10.0 {
            // 高速移动中 (时速 > 36km/h)：中等精度，因为高速下 10 米和 100 米对轨迹影响不大但非常省电
            if manager.desiredAccuracy != kCLLocationAccuracyHundredMeters {
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.distanceFilter = 100.0
                manager.activityType = .automotiveNavigation
            }
        } else {
            // 步行或骑行记录：恢复高精度录入
            if manager.desiredAccuracy != kCLLocationAccuracyNearestTenMeters {
                manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                manager.distanceFilter = 20.0
                manager.activityType = .fitness
            }
        }

        // 反地理编码更新地址（节流：如果是高速移动或已经在停留，降低反向地理编码频率）
        let geocodeThrottleDist: Double = (speed > 10.0) ? 500.0 : 100.0 
        let shouldGeocode = lastGeocodedLocation.map {
            location.distance(from: $0) > geocodeThrottleDist
        } ?? true
        
        if shouldGeocode {
            lastGeocodedLocation = location
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
                if let placemark = placemarks?.first {
                    // 优先获取兴趣点（如：某某商场、某某公园）
                    let poiName = placemark.areasOfInterest?.first
                    let name = [poiName, placemark.name, placemark.thoroughfare, placemark.subLocality]
                        .compactMap { $0 }
                        .first ?? "未知位置"
                    
                    DispatchQueue.main.async {
                        self?.currentAddress = name
                    }
                }
            }
        }
        
        // 1. 永久保存原始点，并存入内存缓存
        RawLocationStore.shared.saveLocation(location)
        updateTodayTotalPoints()
        allTodayPoints.append(location)
        trackingPoints.append(location)
        
        // 2. 处理候选足迹逻辑
        // 为满足“保留 3 天数据”且“不重复识别”，我们从总流水中提取“未分类”段交给处理器
        var unclassifiedQueue = trackingPoints.filter { $0.timestamp > (lastProcessedTimestamp ?? .distantPast) }
        if let candidate = footprintProcessor.processNewLocation(location, queue: &unclassifiedQueue) {
            handleNewCandidateFootprint(candidate)
        }
        
        // 3. 更新当前停留状态用于 UI 显示
        if let startLoc = potentialStopStartLocation {
            // 如果新位置偏差过大（>100m），并且精度尚可（<100m），判定为离开（防止 GPS 启动冷开始的漂移误判）
            let distance = location.distance(from: startLoc)
            if distance > 100.0 && location.horizontalAccuracy < 100.0 {
                potentialStopStartLocation = location
                savePotentialStop()
            }
        } else {
            potentialStopStartLocation = location
            savePotentialStop()
            ongoingTitle = nil
        }
        
        // 3. 触发正在持续停留的 AI 分析 (停留 5 分钟后触发第一次，之后每 60 分钟刷新)
        if let start = potentialStopStartLocation?.timestamp {
            let duration = Date().timeIntervalSince(start)
            if duration >= 5 * 60 {
                let isAiEnabled = UserDefaults.standard.bool(forKey: "isAiAssistantEnabled")
                if isAiEnabled && !isAnalyzingOngoing && (ongoingTitle == nil || (lastAIAnalysisTime != nil && Date().timeIntervalSince(lastAIAnalysisTime!) > 60 * 60)) {
                    // 只在有坐标时分析
                    analyzeOngoingStay(at: location)
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthStatus()
        print("Location authorization changed: \(authStatus.rawValue)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error.localizedDescription)")
    }
    
    private func analyzeOngoingStay(at location: CLLocation) {
        let now = Date()
        guard let startTs = potentialStopStartLocation?.timestamp else { return }
        let duration = now.timeIntervalSince(startTs)
        
        lastAIAnalysisTime = now
        
        let place = matchedPlace
        isAnalyzingOngoing = true
        openAIService.analyzeFootprint(
            locations: [(location.coordinate.latitude, location.coordinate.longitude)],
            duration: duration,
            startTime: startTs,
            endTime: now,
            placeName: place?.name,
            placeTags: [], 
            allAvailableTags: getAllAvailableTags(),
            address: currentAddress,
            isOngoing: true
        ) { [weak self] title, _, _, _, success in
            DispatchQueue.main.async {
                self?.isAnalyzingOngoing = false
                if success {
                    self?.ongoingTitle = title
                }
            }
        }
    }

    private func handleNewCandidateFootprint(_ candidate: CandidateFootprint) {
        guard let context = modelContext else { return }
        
        // 检查是否需要合并之前的记录
        // 注意：#Predicate 不支持 Calendar.startOfDay，改用预计算的日期区间
        // 重要：使用足迹开始的时间来计算合并区间（支持跨天合并）
        let targetStart = Calendar.current.startOfDay(for: candidate.startTime)
        let targetEnd = targetStart.addingTimeInterval(86400)
        
        var fetchDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.date >= targetStart && $0.date < targetEnd },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = 1
        
        let existingFootprints = try? context.fetch(fetchDescriptor)
        let lastFootprint = existingFootprints?.first
        
        if let last = lastFootprint, footprintProcessor.shouldMerge(lastFootprint: last, newCandidate: candidate) {
            // 合并逻辑：延伸结束时间，追加路径点
            last.endTime = candidate.endTime
            last.duration = last.endTime.timeIntervalSince(last.startTime)
            var currentPath = last.footprintLocations
            currentPath.append(contentsOf: candidate.rawLocations.map { $0.coordinate })
            last.footprintLocations = currentPath
            
            // Re-match place in case it changed during merger (always pick the closest)
            let mPlace = self.matchedPlace
            if last.placeID != mPlace?.placeID {
                last.placeID = mPlace?.placeID
            }
            
            analyzeFootprint(last)
        } else {
            // 创建新足迹。重要的：日期应归于足迹开始的那一天，而非生成时的这一秒
            let newFootprint = Footprint(
                date: Calendar.current.startOfDay(for: candidate.startTime),
                startTime: candidate.startTime,
                endTime: candidate.endTime,
                footprintLocations: candidate.rawLocations.map { $0.coordinate },
                locationHash: "TBD",
                duration: candidate.duration,
                title: "正在分析足迹...",
                status: .confirmed,
                address: currentAddress
            )
            
            if let mPlace = self.matchedPlace {
                newFootprint.placeID = mPlace.placeID
                if newFootprint.address == nil { newFootprint.address = mPlace.address }
                
                // --- 标记忽略地点 ---
                if mPlace.isIgnored {
                    newFootprint.status = .ignored
                }
            }
            
            // --- 自动带入历史标签 ---
            // 如果这个地点不是“重要地点”，或者即使是，我们也根据在该位置的历史打标记录自动带入标签
            let historicalTags = findHistoricalTags(for: newFootprint.latitude, longitude: newFootprint.longitude, in: context)
            if !historicalTags.isEmpty {
                newFootprint.tags = historicalTags
            }
            
            context.insert(newFootprint)
            analyzeFootprint(newFootprint)
        }
        
        // 处理完一个段后，为了防止同一个位置被重复识别为足迹，同时重置“未归类流水”的锚点
        if !candidate.rawLocations.isEmpty {
            // --- 只删 3 天之前的过期流水数据 ---
            let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
            trackingPoints.removeAll { $0.timestamp < threeDaysAgo }
            
            // 重要：为了防止同一个位置被重复识别为足迹，同时重置“未归类流水”的锚点
            // 但物理上不删除这些数据（已在上述逻辑中体现）
            self.lastProcessedTimestamp = candidate.endTime
        }
        
        try? context.save()
    }

    func analyzeFootprintByID(_ id: PersistentIdentifier) {
        guard let context = modelContext,
              let footprint = context.model(for: id) as? Footprint else { return }
        analyzeFootprint(footprint)
    }

    private func analyzeFootprint(_ footprint: Footprint) {
        if footprint.status == .ignored { return }
        
        // 核心检查：使用显式标识判断是否已分析
        if footprint.aiAnalyzed {
            return
        }

        let isAiEnabled = UserDefaults.standard.bool(forKey: "isAiAssistantEnabled")
        if !isAiEnabled {
            // 如果 AI 关闭，且用户没手动改过，设置一个默认标题
            if !footprint.isTitleEditedByHand {
                footprint.title = matchedPlace?.name ?? footprint.address ?? "记录于此"
            }
            return
        }
        
        let locations = footprint.footprintLocations.map { ($0.latitude, $0.longitude) }
        
        // 提前获取必要信息，避免在闭包中直接访问 Model 可能导致的问题（虽然当前闭包是在主线程）
        let fpLat = footprint.latitude
        let fpLon = footprint.longitude
        let fpDuration = footprint.duration
        let fpStart = footprint.startTime
        let fpEnd = footprint.endTime
        let fpTags = footprint.tags
        let fpAddress = footprint.address

        // 匹配已知地点，给 AI 提供背景信息 (应用「最近优先」原则)
        let mPlace = allPlaces.filter { place in
            let pLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let fLoc = CLLocation(latitude: fpLat, longitude: fpLon)
            return fLoc.distance(from: pLoc) <= Double(place.radius) + 100.0
        }.min { p1, p2 in
            let fLoc = CLLocation(latitude: fpLat, longitude: fpLon)
            let d1 = fLoc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
            let d2 = fLoc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
            return d1 < d2
        }
        
        openAIService.analyzeFootprint(
            locations: locations,
            duration: fpDuration,
            startTime: fpStart,
            endTime: fpEnd,
            placeName: mPlace?.name,
            placeTags: fpTags,
            allAvailableTags: getAllAvailableTags(),
            address: fpAddress
        ) { title, reason, tags, score, success in
            DispatchQueue.main.async {
                if success {
                    if !footprint.isTitleEditedByHand {
                        footprint.title = title
                    }
                    footprint.reason = reason
                    footprint.aiScore = score
                    footprint.aiAnalyzed = true
                    
                    // 直接应用 AI 建议的标签（AI 已被要求只从现有池中选择）
                    footprint.tags = tags
                    
                    try? footprint.modelContext?.save()
                    
                    // 如果判定为“精彩”足迹（0.7 分以上），仅发送通知，不再自动收藏
                    if score >= 0.7 {
                        NotificationManager.shared.sendHighlightNotification(
                            title: title,
                            body: reason
                        )
                    }
                }
                
                // If it's evening, refresh the daily summary push notification content
                let hour = Calendar.current.component(.hour, from: Date())
                if hour >= 18 {
                    self.triggerNotificationSummaryRefresh()
                }
            }
        }
    }
    
    func triggerNotificationSummaryRefresh() {
        guard let context = modelContext else { return }
        
        let todayStart = Calendar.current.startOfDay(for: Date())
        let tomorrowStart = todayStart.addingTimeInterval(86400)
        
        let fetchDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.date >= todayStart && $0.date < tomorrowStart && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        
        if let todayFootprints = try? context.fetch(fetchDescriptor) {
            NotificationManager.shared.refreshDailySummary(with: todayFootprints)
        }
    }

    /// 寻找物理距离相近的地点最近一次使用的标签
    private func findHistoricalTags(for lat: Double, longitude lon: Double, in context: ModelContext) -> [String] {
        let center = CLLocation(latitude: lat, longitude: lon)
        
        // 1. 获取所有带标签的足迹 (按时间倒序)
        // 注意：SwiftData 暂不支持在 Predicate 中直接计算距离，所以先取最近的 N 条在内存过滤
        var descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { fp in
                fp.tags.count > 0 
            },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 100 // 检查最近的100个带标签足迹即可
        
        guard let recentTagged = try? context.fetch(descriptor) else { return [] }
        
        // 2. 找到距离最近且满足阈值的第一个记录（即该地点的最近一次打标）
        for fp in recentTagged {
            let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
            if fpLoc.distance(from: center) <= tagInheritanceDistance {
                return fp.tags
            }
        }
        
        return []
    }

    private func savePotentialStop() {
        if let loc = potentialStopStartLocation {
            UserDefaults.standard.set(loc.coordinate.latitude, forKey: "pending_lat")
            UserDefaults.standard.set(loc.coordinate.longitude, forKey: "pending_lng")
            UserDefaults.standard.set(loc.timestamp.timeIntervalSince1970, forKey: "pending_time")
        }
    }

    private func loadPotentialStop() {
        let lat = UserDefaults.standard.double(forKey: "pending_lat")
        let lng = UserDefaults.standard.double(forKey: "pending_lng")
        let time = UserDefaults.standard.double(forKey: "pending_time")
        if lat != 0 && lng != 0 {
            let timestamp = Date(timeIntervalSince1970: time)
            // 只接受 48 小时内且不是未来时间的状态，支持跨周末或超长宅家状态
            if abs(Date().timeIntervalSince(timestamp)) < 48 * 3600 {
                potentialStopStartLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    altitude: 0,
                    horizontalAccuracy: 50,
                    verticalAccuracy: 50,
                    timestamp: timestamp
                )
            } else {
                // 清理过时状态
                UserDefaults.standard.removeObject(forKey: "pending_lat")
                UserDefaults.standard.removeObject(forKey: "pending_lng")
                UserDefaults.standard.removeObject(forKey: "pending_time")
            }
        }
    }
    
    // --- 今日总计持久化 ---
    private func loadTodayTotalPoints() {
        let lastDate = UserDefaults.standard.string(forKey: "points_total_date") ?? ""
        let today = Date().formatted(date: .numeric, time: .omitted)
        if lastDate == today {
            todayTotalPointsCount = UserDefaults.standard.integer(forKey: "points_total_count")
        } else {
            todayTotalPointsCount = 0
            UserDefaults.standard.set(today, forKey: "points_total_date")
            UserDefaults.standard.set(0, forKey: "points_total_count")
        }
    }
    
    private func updateTodayTotalPoints() {
        let lastDate = UserDefaults.standard.string(forKey: "points_total_date") ?? ""
        let today = Date().formatted(date: .numeric, time: .omitted)
        
        if lastDate != today {
            todayTotalPointsCount = 1
            UserDefaults.standard.set(today, forKey: "points_total_date")
        } else {
            todayTotalPointsCount += 1
        }
        UserDefaults.standard.set(todayTotalPointsCount, forKey: "points_total_count")
    }

    func loadPointsFromStore() {
        // 从本地存储恢复今日点，用于 UI 流水显示
        let todayPoints = RawLocationStore.shared.loadLocations(for: Date())
        self.allTodayPoints = todayPoints
        self.todayTotalPointsCount = todayPoints.count
        
        // 从本地存储恢复滑动窗口，用于足迹识别。强制回溯至 24 小时前，以确保发现并恢复超长夜间停留。
        let now = Date()
        let startBound = now.addingTimeInterval(-24 * 3600)
        // 核心修正：无论当前有没有停留，回溯范围都至少应覆盖 24 小时，以便自愈逻辑能向前追溯到更早的起始点
        let lookbackStart = startBound 
        let recent = RawLocationStore.shared.loadRecentLocations(lookbackHours: 24.0, since: lookbackStart)
        self.trackingPoints = recent
        
        if let last = recent.last {
            self.lastUpdateTime = last.timestamp
            self.lastLocation = last
            
            // --- 停留自动恢复 (Self-Healing) ---
            // 我们从 recent 点位中自后向前寻找最近的一个连续停留段，回溯出更真实的起始点。
            var foundStart = last
            for i in (0..<recent.count).reversed() {
                let p = recent[i]
                if p.distance(from: last) < 200.0 { // 放宽到 200m 以应对更大范围的停留点偏差（如果是家/写字楼）
                    foundStart = p
                } else {
                    break
                }
            }
            
            let fileDuration = last.timestamp.timeIntervalSince(foundStart.timestamp)
            let currentDuration = potentialStopStartLocation.map { last.timestamp.timeIntervalSince($0.timestamp) } ?? 0
            
            // 如果文件里发现的连续停留时间明显长于当前内存中的停留时间，则以文件为准
            if fileDuration > currentDuration + 300 {
                self.potentialStopStartLocation = foundStart
                savePotentialStop()
            }
        }

        // 重要：重新设置 lastProcessedTimestamp 为最近的一个足迹截止时间
        // 这将防止重新加载的旧数据被二次识别生成重复足迹 (此处仅为补丁逻辑)
        if let context = modelContext {
            var fetchDescriptor = FetchDescriptor<Footprint>(
                sortBy: [SortDescriptor(\.endTime, order: .reverse)]
            )
            fetchDescriptor.fetchLimit = 1
            if let lastFp = try? context.fetch(fetchDescriptor).first {
                self.lastProcessedTimestamp = lastFp.endTime
            }
        }
    }

    // MARK: - Ignore Location Logic
    
    func ignoreLocation(for footprint: Footprint) {
        guard let context = modelContext else { return }
        
        // 1. 查找或创建地点
        let place: Place
        if let existingPlaceID = footprint.placeID,
           let existingPlace = allPlaces.first(where: { $0.placeID == existingPlaceID }) {
            place = existingPlace
        } else {
            // 创建一个新地点
            // 当用户忽略地点时，我们应该以“地址”作为地点的标识，而不应混入特定单次足迹的“标题”。
            // 比如足迹标题可能是“在星巴克喝咖啡”，但忽略该地点应该是针对这个坐标/地址，后续所有该地的记录都应被忽略。
            let name = (footprint.address ?? "未命名地点").isEmpty ? "已忽略地点" : (footprint.address ?? "已忽略地点")
            place = Place(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
                radius: 100, // 默认 100m 忽略半径
                address: footprint.address,
                isUserDefined: false
            )
            place.isIgnored = true
            context.insert(place)
        }
        
        // 2. 标记为忽略
        place.isIgnored = true
        
        // 3. 立即将该地点及其周边的足迹全部忽略
        let placeID = place.placeID
        let center = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let threshold = Double(place.radius) + 100.0
        
        let descriptor = FetchDescriptor<Footprint>()
        if let all = try? context.fetch(descriptor) {
            for fp in all {
                if fp.placeID == placeID {
                    fp.status = .ignored
                } else {
                    let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                    if fpLoc.distance(from: center) <= threshold {
                        fp.status = .ignored
                        fp.placeID = placeID
                    }
                }
            }
        }
        
        try? context.save()
    }
    
    // --- 附近地点建议逻辑 ---
    
    /// 获取当前坐标附近的建议地点（包含已保存地点和 POI）
    func fetchNearbySuggestions(at coordinate: CLLocationCoordinate2D) async -> [LocationSuggestion] {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var allFound: [LocationSuggestion] = []
        
        // 1. 获取已保存的附近地点 (1.5km内)
        let saved = allPlaces.compactMap { place -> (LocationSuggestion, Double)? in
            let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let dist = center.distance(from: loc)
            guard dist < 1500 else { return nil }
            return (LocationSuggestion(
                id: UUID(),
                name: place.name,
                address: place.address ?? "",
                coordinate: place.coordinate,
                isExistingPlace: true,
                placeID: place.placeID
            ), dist)
        }
        allFound.append(contentsOf: saved.map { $0.0 })
        
        // 2. 先进行反地理编码，获取当前所在的街道、区域和地标潜力名
        let geocoder = CLGeocoder()
        let placemarks = try? await geocoder.reverseGeocodeLocation(center)
        let firstMark = placemarks?.first
        
        let street = firstMark?.thoroughfare
        let subLocality = firstMark?.subLocality
        let nameMark = firstMark?.name
        
        // 3. 并行执行多项搜索以提高效率并增加多样性
        // A. 系统原生兴趣点 (最准确的“附近有什么”，不依赖关键词)
        async let poisFromPOI = performPOIRequest(at: coordinate, radius: 1500)
        async let poisFromGeneral = performNaturalLanguageSearch(at: coordinate, query: "附近 周边 地点", radius: 1000)
        
        // B. 基于街道和区域的搜索 (找回不带通用分类词的写字楼、住宅楼或小商铺)
        async let poisFromStreet = street != nil ? performNaturalLanguageSearch(at: coordinate, query: street!, radius: 1000) : []
        async let poisFromName = (nameMark != nil && nameMark != street) ? performNaturalLanguageSearch(at: coordinate, query: nameMark!, radius: 1000) : []
        async let poisFromDistrict = subLocality != nil ? performNaturalLanguageSearch(at: coordinate, query: subLocality!, radius: 1500) : []
        
        // C. 重点设施搜索 (针对用户高频率打卡的非通用词地点)
        async let poisFromOffice = performNaturalLanguageSearch(at: coordinate, query: "大厦 写字楼 中心 广场 工业区 软件园", radius: 1500)
        async let poisFromLife = performNaturalLanguageSearch(at: coordinate, query: "公园 景点 馆 商场 社区 小区 酒店 旅馆 医院 学校", radius: 2000)
        
        // 4. 合并所有结果
        allFound.append(contentsOf: await poisFromPOI)
        allFound.append(contentsOf: await poisFromGeneral)
        allFound.append(contentsOf: await poisFromStreet)
        allFound.append(contentsOf: await poisFromName)
        allFound.append(contentsOf: await poisFromDistrict)
        allFound.append(contentsOf: await poisFromOffice)
        allFound.append(contentsOf: await poisFromLife)
        
        // 补充反向地理编码自身带有的 AOI (直接对应的地标)
        if let aois = firstMark?.areasOfInterest {
            for aoi in aois {
                allFound.append(LocationSuggestion(
                    id: UUID(),
                    name: aoi,
                    address: (firstMark?.thoroughfare ?? firstMark?.subLocality) ?? "",
                    coordinate: coordinate,
                    isExistingPlace: false,
                    placeID: nil
                ))
            }
        }
        
        // 5. 兜底添加当前位置的具体地名/门牌号
        if let name = firstMark?.name, !name.isEmpty, !allFound.contains(where: { $0.name == name }) {
            allFound.append(LocationSuggestion(
                id: UUID(),
                name: name,
                address: firstMark?.thoroughfare ?? firstMark?.subLocality ?? "",
                coordinate: coordinate,
                isExistingPlace: false,
                placeID: nil
            ))
        }
        

        
        // 4. 排序与去重 (保留 10-15 个)
        var seenNames = Set<String>()
        var unique: [LocationSuggestion] = []
        
        // 按距离排序 (计算到中心的距离)
        let sortedAll = allFound.sorted { s1, s2 in
            let d1 = center.distance(from: CLLocation(latitude: s1.coordinate.latitude, longitude: s1.coordinate.longitude))
            let d2 = center.distance(from: CLLocation(latitude: s2.coordinate.latitude, longitude: s2.coordinate.longitude))
            return d1 < d2
        }
        
        for s in sortedAll {
            if !seenNames.contains(s.name) {
                seenNames.insert(s.name)
                unique.append(s)
            }
            if unique.count >= 25 { break } // 增加到 25 个，方便用户从更多结果中选择
        }
        
        return unique
    }
    
    private func performPOIRequest(at coordinate: CLLocationCoordinate2D, radius: Double) async -> [LocationSuggestion] {
        let req = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        let search = MKLocalSearch(request: req)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.map { item in
            LocationSuggestion(id: UUID(), name: item.name ?? "未知地点", address: item.placemark.title ?? "", coordinate: item.placemark.coordinate, isExistingPlace: false, placeID: nil)
        }
    }
    
    private func performNaturalLanguageSearch(at coordinate: CLLocationCoordinate2D, query: String, radius: Double) async -> [LocationSuggestion] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius, longitudinalMeters: radius)
        let search = MKLocalSearch(request: req)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.map { item in
            LocationSuggestion(id: UUID(), name: item.name ?? "未知地点", address: item.placemark.title ?? "", coordinate: item.placemark.coordinate, isExistingPlace: false, placeID: nil)
        }
    }
    
    /// 用户选择建议地点后的处理
    func selectSuggestion(_ suggestion: LocationSuggestion, forOngoing: Bool, footprint: Footprint? = nil) {
        let targetPlace = updateOrCreatePlaceAsPriority(suggestion)
        
        // 如果是“重要地点”（用户定义），展示地址而非名称（因为名称会在标签/标题里展示）
        // 如果是普通的 POI点位，则依然展示名称
        let displayValue = (targetPlace.isUserDefined && !(targetPlace.address ?? "").isEmpty) ? (targetPlace.address ?? suggestion.name) : suggestion.name
        
        if forOngoing {
            self.currentAddress = displayValue
            // 强制重新进行分析以更新 UI
            ongoingTitle = nil
            if let loc = lastLocation ?? potentialStopStartLocation {
                analyzeOngoingStay(at: loc)
            }
        } else if let fp = footprint {
            fp.address = displayValue
            fp.placeID = targetPlace.placeID
            // 重新分析足迹内容
            analyzeFootprint(fp)
        }
        
        try? modelContext?.save()
    }
    
    @discardableResult
    private func updateOrCreatePlaceAsPriority(_ suggestion: LocationSuggestion) -> Place {
        // 先重置该区域其他地点的优先状态
        let center = CLLocation(latitude: suggestion.coordinate.latitude, longitude: suggestion.coordinate.longitude)
        for p in allPlaces {
            let pLoc = CLLocation(latitude: p.latitude, longitude: p.longitude)
            if pLoc.distance(from: center) < 200 {
                p.isPriority = false
            }
        }
        
        if let pid = suggestion.placeID, let existing = allPlaces.first(where: { $0.placeID == pid }) {
            existing.isPriority = true
            return existing
        } else if let existing = allPlaces.first(where: { $0.name == suggestion.name }) {
            existing.isPriority = true
            return existing
        } else {
            let newPlace = Place(
                name: suggestion.name,
                coordinate: suggestion.coordinate,
                radius: 100,
                address: suggestion.address,
                isUserDefined: false // 修正行为不应自动创建“重要地点”，以免干扰管理列表
            )
            newPlace.isPriority = true
            modelContext?.insert(newPlace)
            return newPlace
        }
    }
    
    private func getAllAvailableTags() -> [String] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<PlaceTag>()
        if let tags = try? context.fetch(descriptor) {
            return tags.map { $0.name }
        }
        return []
    }
}

// MARK: - 坐标系转换扩展 (WGS-84 -> GCJ-02)
extension CLLocation {
    var gcj02: CLLocation {
        let a = 6378245.0
        let ee = 0.00669342162296594323
        
        func transformLat(_ x: Double, _ y: Double) -> Double {
            var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
            ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
            ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
            ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
            return ret
        }
        
        func transformLon(_ x: Double, _ y: Double) -> Double {
            var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
            ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
            ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
            ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
            return ret
        }

        let coord = self.coordinate
        if coord.longitude < 72.004 || coord.longitude > 137.8347 || coord.latitude < 0.8293 || coord.latitude > 55.8271 {
            return self
        }
        
        var dLat = transformLat(coord.longitude - 105.0, coord.latitude - 35.0)
        var dLon = transformLon(coord.longitude - 105.0, coord.latitude - 35.0)
        let radLat = coord.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: coord.latitude + dLat, longitude: coord.longitude + dLon),
            altitude: self.altitude,
            horizontalAccuracy: self.horizontalAccuracy,
            verticalAccuracy: self.verticalAccuracy,
            timestamp: self.timestamp
        )
    }
}
