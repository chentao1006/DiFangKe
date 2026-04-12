import Foundation
import CoreLocation
import SwiftData
import Combine
import SwiftUI
import MapKit
import CloudKit
import Photos

// MARK: - 位置建议结构体
struct LocationSuggestion: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
    var isExistingPlace: Bool = false
    var placeID: UUID?
    var category: String?
    
    static func == (lhs: LocationSuggestion, rhs: LocationSuggestion) -> Bool {
        lhs.id == rhs.id
    }
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
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        
        var locations: [CLLocation] = []
        var lastValidPoint: CLLocation? = nil

        content.enumerateLines { line, _ in
            if line.isEmpty { return }
            let parts = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: true)
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
                
                // --- 补救措施：加载时过滤存量的离谱漂移点 ---
                if let last = lastValidPoint {
                    let dist = loc.distance(from: last)
                    let time = loc.timestamp.timeIntervalSince(last.timestamp)
                    if time > 0 {
                        let calcSpeed = dist / time
                        let isRidiculous = (accuracy > 500 && dist > 2000) || (calcSpeed > 100.0 && accuracy > 100)
                        if isRidiculous { return } // 跳过该点，不加入列表，且不更新 lastValidPoint
                    }
                }
                
                locations.append(loc)
                lastValidPoint = loc
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
            let dayPoints = loadLocations(fromURL: fileURL)
            allPoints.append(contentsOf: dayPoints)
        }
        return allPoints.sorted { $0.timestamp < $1.timestamp }
    }
    
    private func loadLocations(fromURL url: URL) -> [CLLocation] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8) else { return [] }
        
        var locations: [CLLocation] = []
        var lastValidPoint: CLLocation? = nil
        
        content.enumerateLines { line, _ in
            if line.isEmpty { return }
            let parts = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: true)
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
                
                // --- 补救措施：加载时过滤存量的离谱漂移点 ---
                if let last = lastValidPoint {
                    let dist = loc.distance(from: last)
                    let time = loc.timestamp.timeIntervalSince(last.timestamp)
                    if time > 0 {
                        let calcSpeed = dist / time
                        let isRidiculous = (accuracy > 500 && dist > 2000) || (calcSpeed > 100.0 && accuracy > 100)
                        if isRidiculous { return }
                    }
                }
                
                locations.append(loc)
                lastValidPoint = loc
            }
        }
        return locations
    }
    
    /// 高效获取指定日期的总点数（统计行数，不解析对象）
    func getTotalPointsCount(for date: Date) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: date)
        
        guard let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        
        var totalCount = 0
        let relevantFiles = files.filter { $0.lastPathComponent.hasPrefix(datePrefix) && $0.pathExtension == "csv" }
        
        for fileURL in relevantFiles {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                // 统计换行符数量作为行数估算，比完全解析成 CLLocation 快得多
                let count = content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
                totalCount += count
            }
        }
        return totalCount
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
    private var driftDistanceThreshold: CLLocationDistance { AppConfig.shared.stayDistanceThreshold }
    private let driftSpeedThreshold: CLLocationSpeed = 45.0 // m/s，异常飘移速度（约162km/h，兼顾高铁环境）
    
    // 1.3 停留点识别参数
    private var stayRadiusThreshold: Double { AppConfig.shared.stayDistanceThreshold }
    private var stayDurationThreshold: TimeInterval { AppConfig.shared.stayDurationThreshold }
    
    // 1.4 合并参数
    private var mergeTimeThreshold: TimeInterval { AppConfig.shared.stayDurationThreshold }
    private var mergeDistanceThreshold: CLLocationDistance { AppConfig.shared.mergeDistanceThreshold }
    
    /// 处理新定位点，满足停留条件则返回 CandidateFootprint
    func processNewLocation(_ location: CLLocation, queue: inout [CLLocation], isHistorical: Bool = false) -> CandidateFootprint? {
        // 过滤精度过差的点（进一步放宽到 300 米，确保极端环境下也不丢点）
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy < 300 else { return nil }
              
        // 1.2 时间鲜度过滤：如果是实时点，丢弃 1 分钟前的缓存数据或过时数据
        if !isHistorical {
            guard abs(location.timestamp.timeIntervalSinceNow) < 60 else { return nil }
        }
        
        if let lastLoc = queue.last {
            // 时间间隔过滤
            let timeInterval = location.timestamp.timeIntervalSince(lastLoc.timestamp)
            guard timeInterval >= minTimeInterval else { return nil }
            
            // --- 强化漂移过滤 (针对地铁/城市峡谷) ---
            let distance = location.distance(from: lastLoc)
            let calculatedSpeed = distance / timeInterval // m/s
            
            // A: 物理不可能性判断：时速超过 220km/h (约 61m/s) 且精度不佳，判定为漂移数据
            if calculatedSpeed > 60.0 && location.horizontalAccuracy > 65.0 {
                return nil
            }
            
            // B: 精度断崖式下降判断：如果位移很大 (>300m) 且当前精度比上一点差很多 (>3倍且绝对值>150m)，判定为漂移
            if distance > 300 && location.horizontalAccuracy > lastLoc.horizontalAccuracy * 3 && location.horizontalAccuracy > 150 {
                return nil
            }
            
            // C: 基础漂移判断
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
            
            // 核心改变：只有当“离开”了当前的停留中心，才结算并返回之前的足迹。
            // 只要还在停留半径内，就不返回 Candidate，保持“正在进行中”的状态，由 UI 状态卡片负责呈现。
            if distToCenter > stayRadiusThreshold {
                if let candidate = detectStayPoint(in: Array(analysisQueue.dropLast())) {
                    return candidate
                }
            }
        }
        
        return nil
    }
    
    private func detectStayPoint(in locations: [CLLocation]) -> CandidateFootprint? {
        guard locations.count >= 2 else { return nil }
        
        let startTime = locations.first!.timestamp
        let endTime = locations.last!.timestamp
        let duration = endTime.timeIntervalSince(startTime)
        
        guard duration >= stayDurationThreshold else { return nil }
        
        let center = calculateCenter(locations)
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        
        // 核心优化：进一步收紧离群点容忍度（从 3% 降低到 1%），防止长达 500m 以上的慢速位移被吞入长停留中
        let distances = locations.map { $0.distance(from: centerLoc) }.sorted()
        let percentileindex = Int(Double(distances.count) * 0.85)
        if distances[percentileindex] > stayRadiusThreshold {
            return nil
        }
        
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
        
        // 改进：允许时间上的重叠（timeInterval < 0），这通常意味着它是前一个记录的延续或重复
        // 允许的最大空隙依然由 mergeTimeThreshold 决定
        guard timeInterval < mergeTimeThreshold else { return false }
        
        // 检查地点是否一致
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
@MainActor
@Observable
class LocationManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationManager()
    
    private let locationManager = CLLocationManager()
    
    var isAuthorized: Bool = false
    var isAlwaysAuthorized: Bool = false
    var authStatus: CLAuthorizationStatus = .notDetermined
    
    // Deep Linking State
    var deepLinkFootprintID: UUID?
    var deepLinkDate: Date?
    
    var isTracking: Bool = false
    var lastUpdateTime: Date?
    var lastLocation: CLLocation?
    var accuracy: CLLocationAccuracy?
    var currentAddress: String = "正在解析位置..."
    var trackingPoints: [CLLocation] = [] // 用于足迹识别的内存滑动窗口
    var allTodayPoints: [CLLocation] = [] { // 本日流水缓存，从 RawLocationStore 加载
        didSet {
            // 当流水更新时，异步计算缓存坐标系，并进行抽稀以保证 UI 流畅
            let points = allTodayPoints
            Task.detached(priority: .background) {
                let coords = points.map { $0.coordinate }
                let simplified = LocationManager.simplifyCoordinates(coords, tolerance: 0.00005) // 约 5 米精度抽稀
                await MainActor.run {
                    self.allTodayCoordinates = simplified
                }
            }
        }
    }
    var allTodayCoordinates: [CLLocationCoordinate2D] = []
    var todayTotalPointsCount: Int = 0    // 全天流水点数，基于本地文件统计
    var ongoingTitle: String?
    private var lastAIAnalysisTime: Date?
    private var isAnalyzingOngoing = false
    /// 标记上一个分类足迹的截止时间，避免重复识别 (同时满足 3 天全量数据保留)
    private var lastProcessedTimestamp: Date?
    
    /// 缓存有原始轨迹文件的日期，避免频繁遍历文件系统
    var availableRawDates: Set<Date> = []
    
    /// 用于通知 UI 原始轨迹数据已更新（例如多设备同步完成）
    var lastRawDataUpdateTrigger: Date = Date()
    
    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "raw_location_device_id") {
            return id
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "raw_location_device_id")
        return id
    }
    
    // 同步状态属性
    var isSyncingInitialData: Bool = false
    var showSyncInquiry: Bool = false
    var syncStatusMessage: String = ""
    var syncProgress: Double = 0.0
    var isResettingData: Bool = false
    
    // 从 View 同步过来的参数
    var allPlaces: [Place] = []
    var modelContext: ModelContext? {
        didSet {
            if modelContext != nil {
                Task {
                    await loadPointsFromStore() // 获得数据库后，后台加载点并同步最后处理时间
                }
            }
        }
    }
    
    // 正在记录的临时停留状态
    var potentialStopStartLocation: CLLocation?
    
    /// 快速检测云端是否有数据 (通过 KVS)
    func hasExistingCloudData() -> Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.synchronize()
        return kvs.bool(forKey: "hasSeededDefaultData")
    }
    
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
    
    // 习惯匹配参数 (从 Config 加载)
    private var habitTimeWindow: Int { AppConfig.shared.habitTimeWindow }
    private var habitFrequencyThreshold: Int { AppConfig.shared.habitFrequencyThreshold }
    
    private var refreshTimer: AnyCancellable?
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest // 初次启动使用最高精度，确保冷启动位置快速锁定
        self.locationManager.distanceFilter = 5.0 // 初始高频记录 (5米)
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.pausesLocationUpdatesAutomatically = false // 核心修复：禁止自动暂停，防止丢点
        self.locationManager.showsBackgroundLocationIndicator = false
        self.locationManager.activityType = .fitness // 默认为健身/步行模式
        
        // Initialize basic status
        updateAuthStatus()
        loadPotentialStop()
        
        setupTimers()
        
        // Move heavy disk I/O to background to avoid blocking app launch
        Task(priority: .userInitiated) { [weak self] in
            self?.loadTodayTotalPoints()
            await self?.loadPointsFromStore() 
            self?.refreshAvailableRawDates()
        }
        
        // Listen for remote data change signals (from iCloud KVS) to trigger immediate raw data sync
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RemoteDataChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.performRawDataSync()
            }
        }
        
        // Listen for "Live Status" changes to sync ongoing stay duration across devices
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncOngoingStayFromCloud()
            }
        }
    }
    
    /// 遍历原始轨迹存储目录，找出所有有记录的日期并缓存
    func refreshAvailableRawDates() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDir = docs.appendingPathComponent("RawLocations")
        
        guard let files = try? fileManager.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        var dates = Set<Date>()
        for file in files where file.pathExtension == "csv" {
            let name = file.lastPathComponent
            let dateStr = String(name.prefix(10))
            if let date = formatter.date(from: dateStr) {
                dates.insert(Calendar.current.startOfDay(for: date))
            }
        }
        Task { @MainActor in
            self.availableRawDates = dates
        }
    }
    
    private var lastLocationChangeSift: Date = .distantPast
    
    private func setupTimers() {
        // Hourly maintenance and sync
        refreshTimer = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.triggerTimelineSift()
                    self?.checkMidnightSift()
                    await self?.performRawDataSync()
                }
            }
        
        // Initial check on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.checkMidnightSift()
        }
    }
    
    private func checkMidnightSift() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastSift = UserDefaults.standard.object(forKey: "lastMidnightSift") as? Date ?? .distantPast
        
        if lastSift < today {
            // It's a new day, sift yesterday
            siftYesterday()
            UserDefaults.standard.set(Date(), forKey: "lastMidnightSift")
        }
    }
    
    private func triggerTimelineSiftDebounced() {
        // Debounce to max once every 15 mins for location changes
        if abs(lastLocationChangeSift.timeIntervalSinceNow) > 15 * 60 {
            lastLocationChangeSift = Date()
            Task {
                await triggerTimelineSift()
            }
        }
    }
    
    func triggerTimelineSift() async {
        // This is called on triggers: position change, app start, hourly
        // Since TimelineBuilder works on the footprints in DB, we mainly need to ensure 
        // the footprints are consolidated and analyzed.
        let container = modelContext?.container
        guard let container = container else { return }
        let context = ModelContext(container)
        await self.consolidateFootprints(in: context)
    }
    
    private func siftYesterday() {
        let container = modelContext?.container
        Task.detached(priority: .background) { [weak self] in
            guard let self = self, let container = container else { return }
            let context = ModelContext(container)
            // Sifting yesterday involves ensuring the last segment is closed
            // Consolidate handles recent 7 days, so it will cover yesterday.
            await self.consolidateFootprints(in: context)
        }
    }
    
    private func updateAuthStatus() {
        authStatus = locationManager.authorizationStatus
        isAuthorized = (authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse)
        isAlwaysAuthorized = (authStatus == .authorizedAlways)
    }

    var lastUpdateTimeString: String {
        guard let time = lastUpdateTime else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: time)
    }

    var stayDuration: String? {
        guard let startLocation = potentialStopStartLocation else { return nil }
        
        let now = Date()
        let start = startLocation.timestamp
        
        // 核心逻辑：如果本设备正在记录，则通过位移判断是否离开
        if isTracking, let currentLoc = lastLocation {
            let distance = currentLoc.distance(from: startLocation)
            if distance > 300 { return nil }
        }
        
        // 跨设备逻辑：如果该状态来自云端同步，检查其“鲜活度”
        if let status = UserDefaults.standard.dictionary(forKey: "liveStayStatus"),
           let updateTS = status["update"] as? Double,
           let device = status["device"] as? String,
           device != deviceID {
            let updateDate = Date(timeIntervalSince1970: updateTS)
            // 如果远程设备超过 30 分钟未更新状态，我们认为该停留可能已结束或数据断联，不再显示“正在停留”
            if now.timeIntervalSince(updateDate) > 30 * 60 {
                return nil
            }
        }
        
        let duration = now.timeIntervalSince(start)
        let totalMinutes = Int(duration / 60)
        
        // --- 核心调整：根据用户要求，10 分钟以下不算停留，因此不显示正在进行的停留时长 ---
        if totalMinutes < 10 { return nil }
        
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
        let mergeTime: TimeInterval = 20 * 60      // 增加至 20min，更好地容忍数据断断续续
        let mergeDist: CLLocationDistance = 180.0  // 增加至 180m，更好地合并漂移严重的停留点
        let minKeepDuration: TimeInterval = 4 * 60  // 略微降低至 4min

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
            // 保护用户手动编辑过、有备注或有照片的足迹，即使时长很短也不删除
            let hasUserEdits = fp.isTitleEditedByHand || !(fp.reason ?? "").isEmpty || !fp.photoAssetIDs.isEmpty || (fp.isHighlight ?? false)
            if fp.duration < minKeepDuration && !hasUserEdits {
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
            var workingSorted = sorted
            var i = 0
            while i < workingSorted.count - 1 {
                let base = workingSorted[i]
                let next = workingSorted[i+1]

                // 时间间隔：负数表示重叠，视同可合并
                let timeGap = next.startTime.timeIntervalSince(base.endTime)
                let baseLoc = CLLocation(latitude: base.latitude, longitude: base.longitude)
                let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
                let dist = baseLoc.distance(from: nextLoc)

                if timeGap <= mergeTime && dist <= mergeDist {
                    // 合并：取最早 start、最晚 end
                    base.startTime = min(base.startTime, next.startTime)
                    base.endTime = max(base.endTime, next.endTime)
                    base.date = Calendar.current.startOfDay(for: base.startTime)
                    base.duration = base.endTime.timeIntervalSince(base.startTime)
                    
                    var path = base.footprintLocations
                    path.append(contentsOf: next.footprintLocations)
                    base.footprintLocations = path
                    
                    // 合并照片 ID（核心修复：防止照片记录在足迹合并中丢失）
                    if !next.photoAssetIDs.isEmpty {
                        var combined = base.photoAssetIDs
                        for pid in next.photoAssetIDs {
                            if !combined.contains(pid) { combined.append(pid) }
                        }
                        base.photoAssetIDs = combined
                    }
                    
                    context.delete(next)
                    workingSorted.remove(at: i + 1)
                    // i 不递增，继续尝试将后续邻近项合并进来
                } else {
                    i += 1
                }
            }
            
            // ── 第二步：对单条过长/跨度过大的足迹进行“回溯拆分”（针对存量错分数据） ──
            for fp in sorted {
                // 地点自动重校准（自愈逻辑）：仅对未匹配或标记为 TBD 的进行校准，避免性能问题
                // 地点自动重校准（自愈逻辑）：仅对未匹配或标记为 TBD 的进行校准，避免性能问题
                if fp.placeID == nil || fp.locationHash == "TBD" {
                    if let bestPlace = self.matchedPlaceFor(coordinate: CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)) {
                        if fp.placeID != bestPlace.placeID {
                            fp.placeID = bestPlace.placeID
                            if (fp.address ?? "").isEmpty { fp.address = bestPlace.name }
                            if Footprint.isGenericTitle(fp.title) {
                                fp.title = Footprint.generateRandomTitle(for: bestPlace.name, seed: Int(fp.startTime.timeIntervalSince1970))
                            }
                        }
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
        // 安全保护：不自动处理用户手动编辑过、有照片、或者是已确认的足迹，避免干扰用户已有工作
        let hasUserEdits = fp.isTitleEditedByHand || !(fp.reason ?? "").isEmpty || !fp.photoAssetIDs.isEmpty || fp.status == .confirmed
        if hasUserEdits { return }
        
        guard coords.count > 15 else { return } // 略微增加密度要求
        
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
                var splitFootprints: [Footprint] = []
                for (idx, cluster) in distinctClusters.enumerated() {
                    let subCoords = Array(coords[cluster.start...cluster.end])
                    let sTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.start) / totalPoints))
                    let eTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.end) / totalPoints))
                    
                    if idx == 0 {
                        fp.footprintLocations = subCoords
                        fp.startTime = sTime
                        fp.endTime = eTime
                        fp.date = Calendar.current.startOfDay(for: sTime)
                        fp.duration = eTime.timeIntervalSince(sTime)
                        fp.locationHash = "SPLIT_FIXED"
                        splitFootprints.append(fp)
                    } else {
                        let newFp = Footprint(
                            date: Calendar.current.startOfDay(for: sTime),
                            startTime: sTime,
                            endTime: eTime,
                            footprintLocations: subCoords,
                            locationHash: "SPLIT_FIXED",
                            duration: eTime.timeIntervalSince(sTime),
                            title: fp.title,
                            address: nil
                        )
                        context.insert(newFp)
                        splitFootprints.append(newFp)
                    }
                }
                
                // 先统一保存以生成永久 ID
                try? context.save()
                
                // 再执行分析
                for splitFp in splitFootprints {
                    self.analyzeFootprint(splitFp, context: context)
                }
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
        
        // --- 核心改进：预先过滤离谱漂移点，防止污染原始轨迹 CSV ---
        if let last = trackingPoints.last {
            let dist = location.distance(from: last)
            let time = abs(location.timestamp.timeIntervalSince(last.timestamp))
            if time > 0 {
                let calcSpeed = dist / time
                // 地铁/隧道环境常见的离谱漂移：精度骤降 (>500m) 且 瞬间位移巨大 (>2km) 且 速度不合理 (>80m/s)
                let isRidiculous = (location.horizontalAccuracy > 500 && dist > 2000) || (calcSpeed > 80.0 && location.horizontalAccuracy > 100)
                if isRidiculous {
                    print("Detected ridiculous drift, skipping point. Dist: \(dist), Acc: \(location.horizontalAccuracy)")
                    return 
                }
            }
        }
        
        // --- Trigger Sift on location change ---
        triggerTimelineSiftDebounced()
        
        // 0. 智能节能：根据速度和停留状态动态调整定位参数
        let place = matchedPlace
        let speed = location.speed
        
        // 判定是否正在长久停留 (核心修复：50m 门槛太低，室内 GPS 飘移容易突破 50m 导致恢复高精度。
        // 我们将其放宽到 150m，并增加已知地点粘性：如果在已知地点且低速，则提前认为已驻留。)
        let isStationary: Bool = {
            guard let startLoc = potentialStopStartLocation else { return false }
            let duration = Date().timeIntervalSince(startLoc.timestamp)
            let distance = location.distance(from: startLoc)
            
            // A: 通用逻辑 - 5分钟以上且位移在 300m 内 (宽松应对大幅度室内漂移)
            if duration > 300 && distance < 300.0 { return true }
            
            // B: 地点粘性 - 如果在已知地点范围内已超过 1 分钟，且当前速度极低，则提前进入节能
            if let p = place, duration > 60 && distance < Double(p.radius) + 100.0 && speed < 1.0 {
                return true
            }
            
            return false
        }()
        
        if let p = place, p.isIgnored {
            // 已忽略地点：进入强制低功耗
            if manager.desiredAccuracy != kCLLocationAccuracyHundredMeters {
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.distanceFilter = 100.0
                manager.activityType = .other // 切换为非活跃类，促进系统休眠
            }
        } else if isStationary {
            // 普通地点但已停留：进入节能模式，但保持 10m 灵敏度以便触发“起步”
            if manager.desiredAccuracy != kCLLocationAccuracyNearestTenMeters {
                manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                manager.distanceFilter = 10.0 // 从 25m 降至 10m，极大提升起步灵敏度
                manager.activityType = .other
            }
        } else if speed > 25.0 {
            // 超高速移动中 (时速 > 90km/h)：提高位置采样密度，记录更平直的曲线
            if manager.desiredAccuracy != kCLLocationAccuracyBest {
                manager.desiredAccuracy = kCLLocationAccuracyBest // 从 HundredMeters 改为 Best，确保高铁/高速轨迹不丢失
                manager.distanceFilter = 30.0 // 从 100m 降低到 30m，解决高速轨迹严重“拉直线”的问题
                manager.activityType = .automotiveNavigation
            }
        } else if speed > 10.0 {
            // 高速移动中 (时速 > 36km/h)：
            if manager.desiredAccuracy != kCLLocationAccuracyBest {
                manager.desiredAccuracy = kCLLocationAccuracyBest // 统一提升至 Best
                manager.distanceFilter = 15.0 // 从 40m 降低到 15m
                manager.activityType = .automotiveNavigation
            }
        } else {
            // 移动中 (步行、骑行或刚到达)：开启最高频采集
            if manager.desiredAccuracy != kCLLocationAccuracyBest {
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone // 步行模式开启全量采集，确保不漏点
                manager.activityType = .fitness
            }
        }

        // 反地理编码更新地址（高速节流至 1000 米，兼顾体验与能效）
        let geocodeThrottleDist: Double = (speed > 10.0) ? 1000.0 : 100.0 
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
            // 改进：增加地点粘性。如果当前位置依然匹配到与起始点相同的“重要地点”，则不应判定为离开并重置停留时间。
            let startPlace = matchedPlaceFor(coordinate: startLoc.coordinate)
            let currentPlace = matchedPlaceFor(coordinate: location.coordinate)
            
            // 判定是否离开：
            // A: 如果有匹配地点，且地点 ID 变了，判定为离开
            // B: 如果没有匹配地点，且位移超过 150m，且精度尚可，判定为离开（放宽到 150m 减少因室内飘移导致的停留时刻重置）
            let isSamePlace = (startPlace != nil && startPlace?.placeID == currentPlace?.placeID)
            let distance = location.distance(from: startLoc)
            
            if !isSamePlace && distance > 150.0 && location.horizontalAccuracy < 100.0 {
                potentialStopStartLocation = location
                savePotentialStop()
                ongoingTitle = nil
                saveOngoingTitle()
            }
        } else {
            potentialStopStartLocation = location
            savePotentialStop()
            ongoingTitle = nil
            saveOngoingTitle()
        }
        
        // 3. 触发正在持续停留的 AI 分析 (停留 10 分钟后触发第一次，之后每 60 分钟刷新)
        if let start = potentialStopStartLocation?.timestamp {
            let duration = Date().timeIntervalSince(start)
            if duration >= 10 * 60 {
                let isAiEnabled = UserDefaults.standard.bool(forKey: "isAiAssistantEnabled")
                if isAiEnabled && !isAnalyzingOngoing && (ongoingTitle == nil || (lastAIAnalysisTime != nil && Date().timeIntervalSince(lastAIAnalysisTime!) > 60 * 60)) {
                    // 只在有坐标时分析
                    analyzeOngoingStay(at: location)
                }
            }
        }
    }

    @MainActor
    public func resetToday() {
        guard let container = modelContext?.container else { return }
        let date = Date()
        self.isResettingData = true
        
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let targetDate = Calendar.current.startOfDay(for: date)
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: targetDate)!
            
            // 1. 清理
            let fetchDescriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate { 
                    ($0.date >= targetDate && $0.date < nextDay) ||
                    ($0.startTime < nextDay && $0.endTime >= targetDate)
                }
            )
            if let existing = try? context.fetch(fetchDescriptor) {
                for fp in existing {
                    // 仅保护带照片的足迹不被重置清空（视为原始数据）
                    let isProtected = !fp.photoAssetIDs.isEmpty
                    if !isProtected {
                        context.delete(fp)
                    }
                }
            }
            
            let transportDescriptor = FetchDescriptor<TransportManualSelection>(
                predicate: #Predicate { $0.startTime >= targetDate && $0.startTime < nextDay }
            )
            if let existingManuals = try? context.fetch(transportDescriptor) {
                for m in existingManuals { context.delete(m) }
            }
            try? context.save()
            
            // 2. 重新处理原始点
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: date)
            if !rawPoints.isEmpty {
                var tempQueue: [CLLocation] = []
                for loc in rawPoints {
                    if let candidate = FootprintProcessor.shared.processNewLocation(loc, queue: &tempQueue, isHistorical: true) {
                        // 在主线程处理插入逻辑，确保全局状态(potentialStopStartLocation等)同步
                        let end = candidate.endTime
                        await MainActor.run {
                            self.handleNewCandidateFootprint(candidate, isHistorical: true)
                        }
                        tempQueue.removeAll { $0.timestamp <= end }
                    }
                }
            }
            
            await MainActor.run {
                self.isResettingData = false
                self.lastProcessedTimestamp = Calendar.current.startOfDay(for: date)
                Task { await self.loadPointsFromStore() }
                NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
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
        
        // --- 尝试获取该地点历史上的“习惯”活动类型供 AI 参考 ---
        var activityName: String? = nil
        if let pid = place?.placeID, let context = modelContext {
            if let habitValue = self.findFrequentActivityType(for: pid, at: startTs, context: context) {
                let activityFetch = FetchDescriptor<ActivityType>()
                activityName = (try? context.fetch(activityFetch))?.first(where: { $0.id.uuidString == habitValue || $0.name == habitValue })?.name
            }
        }
        
        Task { @MainActor in
            OpenAIService.shared.enqueueOngoingAnalysis(
                locations: [(location.coordinate.latitude, location.coordinate.longitude)],
                duration: duration,
                startTime: startTs,
                endTime: now,
                placeName: place?.address ?? place?.name, // Use original name for title
                address: currentAddress,
                activityName: activityName
            ) { title in
                self.isAnalyzingOngoing = false
                self.ongoingTitle = title
                self.saveOngoingTitle()
                self.triggerNotificationSummaryRefresh()
            }
        }
    }
    
    private func saveOngoingTitle() {
        if let title = ongoingTitle {
            UserDefaults.standard.set(title, forKey: "pending_title")
        } else {
            UserDefaults.standard.removeObject(forKey: "pending_title")
        }
    }
    
    /// 辅助方法：判断特定坐标匹配到的地点
     private func matchedPlaceFor(coordinate: CLLocationCoordinate2D) -> Place? {
         let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
         let validMatches = allPlaces.filter { place in
             if place.isIgnored { return false }
             let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
             let distance = loc.distance(from: placeLocation)
             return distance <= Double(place.radius) + 100.0
         }
         
         // 严格优先级策略：isUserDefined > isPriority > 最近距离
         let sortedMatches = validMatches.sorted { p1, p2 in
             if p1.isUserDefined != p2.isUserDefined {
                 return p1.isUserDefined // True (UserDefined) comes first
             }
             if p1.isPriority != p2.isPriority {
                 return p1.isPriority
             }
             
             let d1 = loc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
             let d2 = loc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
             return d1 < d2
         }
         
         return sortedMatches.first
     }

    /// 核心算法：识别习惯活动 (基于时间窗口或历史频率)
    /// 规则：如果当前时间落在历史某活动的窗口内，则 1 次即可判定；否则需要该地点历史累计 3 次以上
    private func findFrequentActivityType(for placeID: UUID, at time: Date, context: ModelContext) -> String? {
        return LocationManager.resolveFrequentActivityType(
            for: placeID,
            at: time,
            context: context,
            window: habitTimeWindow,
            threshold: habitFrequencyThreshold
        )
    }

    /// 核心算法：识别习惯活动 (静态版本以便于后台任务调用)
    nonisolated private static func resolveFrequentActivityType(
        for placeID: UUID,
        at time: Date,
        context: ModelContext,
        window: Int,
        threshold: Int
    ) -> String? {
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.placeID == placeID && $0.activityTypeValue != nil }
        )
        guard let history = try? context.fetch(descriptor) else { return nil }
        
        let calendar = Calendar.current
        let targetTotal = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
        
        var countsInWindow: [String: Int] = [:]
        var countsTotal: [String: Int] = [:]
        
        for fp in history {
            guard let type = fp.activityTypeValue else { continue }
            countsTotal[type, default: 0] += 1
            
            let fpTotal = calendar.component(.hour, from: fp.startTime) * 60 + calendar.component(.minute, from: fp.startTime)
            let diff = abs(targetTotal - fpTotal)
            if min(diff, 1440 - diff) <= window {
                countsInWindow[type, default: 0] += 1
            }
        }
        
        // 1. 优先判定窗口内的习惯：只要出现过 (1次就够)，就自动判定为该类型
        if let bestInWindow = countsInWindow.sorted(by: { $0.value > $1.value }).first {
            return bestInWindow.key
        }
        
        // 2. 其次判定该地点的整体习惯：如果历史上该地点某种类型出现超过阈值 (默认3次)
        if let bestTotal = countsTotal.sorted(by: { $0.value > $1.value }).first, 
           bestTotal.value >= threshold {
            return bestTotal.key
        }
        
        return nil
    }

    /// 后台扫描缺失活动类型的足迹并根据习惯自动补齐，同时将需要 AI 生成标题的足迹加入队列
    public func autoFillMissingActivityTypes(for date: Date) {
        guard let container = modelContext?.container else { return }
        let window = habitTimeWindow
        let threshold = habitFrequencyThreshold
        
        Task.detached(priority: .background) {
            let context = ModelContext(container)
            // 仅扫描指定日期的足迹
            let startOfDay = Calendar.current.startOfDay(for: date)
            let endOfDay = startOfDay.addingTimeInterval(86400)
            
            let fetchDescriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate<Footprint> { 
                    $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored" 
                }
            )
            
            guard let footprints = try? context.fetch(fetchDescriptor), !footprints.isEmpty else { return }
            
            var activityUpdateCount = 0
            var footprintsToAnalyze: [PersistentIdentifier] = []
            
            for fp in footprints {
                // 1. 自动关联活动类型 (仅补齐缺失的)
                if fp.activityTypeValue == nil {
                    if let pid = fp.placeID {
                        if let type = LocationManager.resolveFrequentActivityType(
                            for: pid,
                            at: fp.startTime,
                            context: context,
                            window: window,
                            threshold: threshold
                        ) {
                            fp.activityTypeValue = type
                            activityUpdateCount += 1
                        }
                    }
                }
                
                // 2. 检查是否需要 AI 辅助生成标题及备注 (跳过已分析过和用户手动编辑过的)
                // 同时也跳过已经确定不需要 AI 的 (aiAnalyzed == true)
                if !fp.aiAnalyzed && !fp.isTitleEditedByHand {
                    footprintsToAnalyze.append(fp.persistentModelID)
                }
            }
            
            if activityUpdateCount > 0 {
                try? context.save()
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                }
            }
            
            // 批量加入 AI 分析队列
            let toAnalyze = footprintsToAnalyze
            if !toAnalyze.isEmpty {
                await MainActor.run {
                    for id in toAnalyze {
                        self.analyzeFootprintByID(id)
                    }
                }
            }
        }
    }

    private func handleNewCandidateFootprint(_ candidate: CandidateFootprint,
                                  isHistorical: Bool = false,
                                  context: ModelContext? = nil) {
        let activeContext = context ?? self.modelContext
        guard let context = activeContext else { return }
        
        // 检查是否需要合并之前的记录
        let targetStart = Calendar.current.startOfDay(for: candidate.startTime)
        let targetEnd = targetStart.addingTimeInterval(86400)
        
        var fetchDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= targetStart && $0.startTime < targetEnd },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = 1
        
        let existingFootprints = try? context.fetch(fetchDescriptor)
        if let last = existingFootprints?.first, FootprintProcessor.shared.shouldMerge(lastFootprint: last, newCandidate: candidate) {
            // 合并逻辑：确保时间范围正确延伸，不重复生成重叠记录
            let oldEndTime = last.endTime
            let oldStartTime = last.startTime
            
            last.endTime = max(last.endTime, candidate.endTime)
            last.startTime = min(last.startTime, candidate.startTime)
            last.date = Calendar.current.startOfDay(for: last.startTime)
            
            // 仅在有明显新轨迹或时间延伸时追加坐标，避免无限堆积重叠坐标
            if last.endTime > oldEndTime || last.startTime < oldStartTime {
                var currentPath = last.footprintLocations
                currentPath.append(contentsOf: candidate.rawLocations.map { $0.coordinate })
                last.footprintLocations = currentPath
            }
            
            // 重新匹配地点（以防合并过程中位置偏移导致匹配变化）
            if let mPlace = self.matchedPlaceFor(coordinate: candidate.centerCoordinate) {
                if last.placeID != mPlace.placeID {
                    last.placeID = mPlace.placeID
                }
            }
            
            if !isHistorical {
                analyzeFootprint(last, context: context)
            }
        } else {
            // 创建新足迹。重要的：日期应归于足迹开始的那一天，而非生成时的这一秒
            let newFootprint = Footprint(
                date: Calendar.current.startOfDay(for: candidate.startTime),
                startTime: candidate.startTime,
                endTime: candidate.endTime,
                footprintLocations: candidate.rawLocations.map { $0.coordinate },
                locationHash: "TBD",
                duration: candidate.duration,
                title: Footprint.generateRandomTitle(for: "此处", seed: Int(candidate.startTime.timeIntervalSince1970)), 
                status: .confirmed,
                address: (isHistorical || currentAddress == "正在解析位置..." || currentAddress == "未知位置") ? nil : currentAddress
            )
            
            if let mPlace = self.matchedPlaceFor(coordinate: candidate.centerCoordinate) {
                let pid = mPlace.placeID
                newFootprint.placeID = pid
                
                // --- 自动关联习惯活动类型 ---
                // 只有同一地点、同一时间段出现过3次以上才关联
                newFootprint.activityTypeValue = self.findFrequentActivityType(for: pid, at: candidate.startTime, context: context)
                
                // Address 优先使用地点名称，解决“标题对地点(地址)不对”的问题
                newFootprint.address = mPlace.name
                
                // Title uses the custom name (User preference: "Title uses name")
                newFootprint.title = Footprint.generateRandomTitle(for: mPlace.name, seed: Int(newFootprint.startTime.timeIntervalSince1970))
                
                // --- 自动补充地点分类 ---
                if mPlace.category == nil {
                    Task { [mPlace] in
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = mPlace.name
                        request.region = MKCoordinateRegion(center: mPlace.coordinate, latitudinalMeters: 200, longitudinalMeters: 200)
                        let search = MKLocalSearch(request: request)
                        if let resp = try? await search.start(), let item = resp.mapItems.first {
                            mPlace.category = item.pointOfInterestCategory?.rawValue
                        }
                    }
                }
                
                // --- 标记忽略地点 ---
                if mPlace.isIgnored {
                    newFootprint.status = .ignored
                }
            }
            
            context.insert(newFootprint)
            try? context.save()
            
            // 核心修复：重置或历史回溯时也要触发分析逻辑，以补全地址和标题
            analyzeFootprint(newFootprint, context: context)
        }
        
        // 处理完一个段后，更新进度
        if isHistorical {
            // 背景处理不直接操作 trackingPoints 镜像，仅记录最后处理时间
            // 实时处理时主线程再同步
        } else if !candidate.rawLocations.isEmpty {
            let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
            trackingPoints.removeAll { $0.timestamp < threeDaysAgo }
            self.lastProcessedTimestamp = candidate.endTime
            
            // 核心修复：一旦生成了新的足迹（无论是交通还是地址），说明之前的状态已断档重新开始
            // 我们将当前的停留起点强制对齐到最新足迹的结束时刻。
            if let lastLoc = candidate.rawLocations.last {
                self.potentialStopStartLocation = lastLoc
                savePotentialStop()
            }
        }
        
        try? context.save()
        triggerNotificationSummaryRefresh()
    }

    func analyzeFootprintByID(_ id: PersistentIdentifier) {
        guard let context = modelContext,
              let footprint = context.model(for: id) as? Footprint else { return }
        analyzeFootprint(footprint, context: context)
    }

    func linkPhotos(to footprint: Footprint, context: ModelContext) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        
        // 如果已经关联过照片，且这些照片在本地是有效的，说明已经稳定，不再重复抓取。
        // 对于多设备同步过来的足迹，其 photoAssetIDs 在本地通常是无效的，此时需要重新触发关联。
        if !footprint.photoAssetIDs.isEmpty && PhotoService.shared.validateAssetIDs(footprint.photoAssetIDs) { 
            return 
        }
        
        // 核心修复：必须有 context 才能访问 persistentModelID 并在主线程恢复，否则说明是 UI Lite 对象
        guard footprint.modelContext != nil else { return }
        
        let id = footprint.persistentModelID
        let startTime = footprint.startTime
        let endTime = footprint.endTime
        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        
        PhotoService.shared.fetchAssets(
            startTime: startTime,
            endTime: endTime,
            near: coordinate,
            maxDistance: 1500 // 放宽关联半径至 1.5km，确保更大概率能根据时间线寻回照片
        ) { assets in
            guard !assets.isEmpty else { return }
            let ids = assets.map { $0.localIdentifier }
            
            // 使用 Task 在主线程执行更新，确保持久化生效且不卡顿
            Task { @MainActor in
                if let fp = context.model(for: id) as? Footprint {
                    fp.photoAssetIDs = ids
                    try? context.save()
                    print("[\(Date())] PhotoLinker: Successfully linked \(ids.count) photos to footprint \(id)")
                }
            }
        }
    }

    private func analyzeFootprint(_ footprint: Footprint, context: ModelContext) {
        if footprint.status == .ignored { return }
        
        // 核心修复：必须是受管理的持久化模型才能进行后续 AI 分析并保存
        guard footprint.modelContext != nil else { return }
        
        // 核心检查：使用显式标识判断是否已分析
        if footprint.aiAnalyzed {
            // 即便 AI 分析过了，也顺便检查下照片，确保重启或漏掉的照片能关联上
            linkPhotos(to: footprint, context: context)
            return
        }
        
        // 关联照片
        linkPhotos(to: footprint, context: context)

        // --- 逻辑重构：立即进行本地 POI 丰富 ---
        // 无论 AI 是否开启，都先尝试通过本地已存地点来校准标题和地址
        if !footprint.isTitleEditedByHand {
            let fpCoord = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            if let matchedPOI = matchedPlaceFor(coordinate: fpCoord) {
                // 1. 优先使用本地已匹配的地点
                let baseName = matchedPOI.name
                if Footprint.isGenericTitle(footprint.title) || !footprint.title.contains(baseName) {
                    footprint.title = Footprint.generateRandomTitle(for: baseName, seed: Int(footprint.startTime.timeIntervalSince1970))
                }
                footprint.address = baseName
            } else if (footprint.address ?? "").isEmpty || footprint.address == "地点记录" || footprint.address == "正在解析位置..." || footprint.address == "此处" {
                // 2. 如果没有匹配地点，且地址是通用的，则尝试反地理编码
                let location = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
                let footprintID = footprint.persistentModelID
                
                geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
                    guard let self = self, let placemark = placemarks?.first else { return }
                    let poiName = placemark.areasOfInterest?.first
                    let name = [poiName, placemark.name, placemark.thoroughfare, placemark.subLocality]
                        .compactMap { $0 }
                        .first ?? "未知位置"
                    
                    Task { @MainActor in
                        // 在主线程重新获取该对象，确保线程安全
                        if let mainContext = self.modelContext?.container.mainContext,
                           let mainFp = mainContext.model(for: footprintID) as? Footprint {
                            mainFp.address = name
                            if !mainFp.isTitleEditedByHand {
                                mainFp.title = Footprint.generateRandomTitle(for: name, seed: Int(mainFp.startTime.timeIntervalSince1970))
                            }
                            try? mainContext.save()
                        }
                    }
                }
            } else if let addr = footprint.address {
                // 3. 兜底逻辑：地址已存在（非通用），确保标题与之对齐
                if Footprint.isGenericTitle(footprint.title) {
                    footprint.title = Footprint.generateRandomTitle(for: addr, seed: Int(footprint.startTime.timeIntervalSince1970))
                }
            }
        }

        let isAiEnabled = UserDefaults.standard.bool(forKey: "isAiAssistantEnabled")
        if !isAiEnabled {
            footprint.aiAnalyzed = true 
            return
        }
        
        // 使用统一队列进行异步分析
        Task { @MainActor in
            openAIService.analyzeFootprint(footprint)
        }
    }

    
    func triggerNotificationSummaryRefresh() {
        guard let context = modelContext else { return }
        
        let targetDate = Calendar.current.startOfDay(for: Date())
        let tomorrowStart = targetDate.addingTimeInterval(86400)
        
        let fetchDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime < tomorrowStart && $0.endTime >= targetDate },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        
        guard let todayFootprints = try? context.fetch(fetchDescriptor) else { return }
        
        // Filter out ignored footprints and include ongoing stay
        let validFootprints = todayFootprints.filter { $0.status != .ignored }
        let footprintCount = validFootprints.count
        let footprintTitles = validFootprints.map { $0.title }
            .filter { !Footprint.isGenericTitle($0) }
        
        let fpsLite = todayFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
        
        // Calculate points and mileage using TimelineBuilder logic
        Task.detached(priority: .background) {
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
            
            let timelineItems = TimelineBuilder.buildTimeline(
                for: targetDate,
                footprints: fpsLite,
                allRawPoints: rawPoints,
                allPlaces: [], 
                overrides: []
            )
            
            let mileage = timelineItems.reduce(0) { sum, item in
                if case .transport(let t) = item { return sum + t.distance }
                return sum
            }
            
            await MainActor.run {
                NotificationManager.shared.refreshDailySummary(
                    footprintCount: footprintCount,
                    footprintTitles: footprintTitles,
                    pointsCount: rawPoints.count,
                    mileage: mileage
                )
            }
        }
    }


    private func savePotentialStop() {
        if let loc = potentialStopStartLocation {
            let ts = loc.timestamp.timeIntervalSince1970
            UserDefaults.standard.set(loc.coordinate.latitude, forKey: "pending_lat")
            UserDefaults.standard.set(loc.coordinate.longitude, forKey: "pending_lng")
            UserDefaults.standard.set(ts, forKey: "pending_time")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pending_time_local_updated")
            
            // 同步至 KVS 以便多设备即时看到“正在停留”状态
            let status: [String: Any] = [
                "lat": loc.coordinate.latitude,
                "lng": loc.coordinate.longitude,
                "start": ts,
                "update": Date().timeIntervalSince1970,
                "device": deviceID
            ]
            UserDefaults.standard.set(status, forKey: "liveStayStatus")
        }
    }

    /// 从云端 KVS 恢复其他设备的实时停留状态
    private func syncOngoingStayFromCloud() {
        guard let status = UserDefaults.standard.dictionary(forKey: "liveStayStatus"),
              let lat = status["lat"] as? Double,
              let lng = status["lng"] as? Double,
              let startTS = status["start"] as? Double,
              let updateTS = status["update"] as? Double,
              let device = status["device"] as? String else { return }
        
        // 只同步来自其他设备的信息
        if device != deviceID {
            let localUpdate = UserDefaults.standard.double(forKey: "pending_time_local_updated")
            // 只有当云端状态比本地已知的更新时间更晚时才进行覆盖
            if updateTS > localUpdate {
                let loc = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50,
                    timestamp: Date(timeIntervalSince1970: startTS)
                )
                
                DispatchQueue.main.async {
                    // 只有当本设备当前没有处于正在记录的活跃状态时，才显示其他设备的活跃状态
                    if !self.isTracking || self.potentialStopStartLocation == nil {
                         self.potentialStopStartLocation = loc
                    }
                }
            }
        }
    }

    private func loadPotentialStop() {
        let lat = UserDefaults.standard.double(forKey: "pending_lat")
        let lng = UserDefaults.standard.double(forKey: "pending_lng")
        let time = UserDefaults.standard.double(forKey: "pending_time")
        if lat != 0 && lng != 0 {
            let timestamp = Date(timeIntervalSince1970: time)
            // 允许恢复 30 天内的状态，不再激进地清除长达数天的“宅家”状态
            if abs(Date().timeIntervalSince(timestamp)) < 30 * 24 * 3600 {
                potentialStopStartLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    altitude: 0,
                    horizontalAccuracy: 50,
                    verticalAccuracy: 50,
                    timestamp: timestamp
                )
                ongoingTitle = UserDefaults.standard.string(forKey: "pending_title")
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
            let count = UserDefaults.standard.integer(forKey: "points_total_count")
            Task { @MainActor in
                self.todayTotalPointsCount = count
            }
        } else {
            Task { @MainActor in
                self.todayTotalPointsCount = 0
            }
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

    func loadPointsFromStore() async {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        
        // 1. 在后台加载数据
        let result = await Task.detached(priority: .userInitiated) {
            // 从本地存储恢复今日点，用于 UI 流水显示 (包含所有同步过来的设备)
            let todayPoints = RawLocationStore.shared.loadAllDevicesLocations(for: today)
            
            // 从本地存储恢复滑动窗口，用于足迹识别。包含昨日 24h 前的点 (跨设备同步)
            let yesterdayPoints = RawLocationStore.shared.loadAllDevicesLocations(for: yesterday)
            let lookbackStart = now.addingTimeInterval(-24 * 3600)
            
            let recent = (yesterdayPoints + todayPoints).filter { $0.timestamp >= lookbackStart }
            
            // 预处理 healing 逻辑
            var healingPotentialStop: CLLocation? = nil
            if let last = recent.last {
                var foundStart = last
                for i in (0..<recent.count).reversed() {
                    let p = recent[i]
                    if p.distance(from: last) < 200.0 {
                        foundStart = p
                    } else {
                        break
                    }
                }
                
                let fileDuration = last.timestamp.timeIntervalSince(foundStart.timestamp)
                // 注意：这里无法直接访问 potentialStopStartLocation，通过返回值带回
                healingPotentialStop = foundStart
                return (todayPoints, recent, healingPotentialStop, fileDuration)
            }
            return (todayPoints, recent, nil, 0.0)
        }.value
        
        let todayPoints = result.0
        let recent = result.1
        let lastLocInFile = recent.last
        
        // 2. 回到主线程更新 UI 状态
        await MainActor.run {
            self.allTodayPoints = todayPoints
            self.todayTotalPointsCount = todayPoints.count
            self.trackingPoints = recent
            
            if let last = lastLocInFile {
                self.lastUpdateTime = last.timestamp
                self.lastLocation = last
                
                // 仅当文件中的停留时长明显长于当前内存中的时长时才执行 healing
                let currentDuration = potentialStopStartLocation.map { last.timestamp.timeIntervalSince($0.timestamp) } ?? 0
                if let healing = result.2, result.3 > currentDuration + 300 {
                    self.potentialStopStartLocation = healing
                    savePotentialStop()
                }
            }
            
            // 重要：模型上下文访问必须在主线程执行，否则会闪退
            if let context = self.modelContext {
                var fetchDescriptor = FetchDescriptor<Footprint>(
                    sortBy: [SortDescriptor(\.endTime, order: .reverse)]
                )
                fetchDescriptor.fetchLimit = 1
                if let lastFp = try? context.fetch(fetchDescriptor).first {
                    self.lastProcessedTimestamp = lastFp.endTime
                }
            }
            
            // 数据加载完成后，后台扫描并补全缺失的活动类型
            self.autoFillMissingActivityTypes(for: today)
        }
    }
    
    /// 简单的点抽稀逻辑 (Douglas-Peucker 简化版或采样)
    nonisolated public static func simplifyCoordinates(_ coords: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2000 else { return coords } // 2000 点以下不抽稀，保证精度
        
        var simplified: [CLLocationCoordinate2D] = []
        simplified.append(coords.first!)
        
        var lastAdded = coords.first!
        for i in 1..<coords.count - 1 {
            let curr = coords[i]
            let dist = abs(curr.latitude - lastAdded.latitude) + abs(curr.longitude - lastAdded.longitude)
            if dist > tolerance {
                simplified.append(curr)
                lastAdded = curr
            }
        }
        
        simplified.append(coords.last!)
        return simplified
    }
    
    /// 补对并持久化历史间隙中的足迹 (Gap Filling -> Persistence)
    /// 该方法会扫描指定日期的所有足迹，并分析现有足迹之间的间隙是否包含符合条件的停留。
    public func backfillGaps(for date: Date) {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = startOfDay.addingTimeInterval(86400)
        
        Task {
            // 1. 获取当天的原始点
            let rawPoints = await Task.detached {
                RawLocationStore.shared.loadAllDevicesLocations(for: date)
            }.value
            
            guard !rawPoints.isEmpty else { return }
            
            // 2. 获取当天现有的足迹 (主线程获取快照)
            let existingRanges = await MainActor.run { () -> [(start: Date, end: Date)] in
                guard let currentContext = self.modelContext else { return [] }
                
                let fetchDescriptor = FetchDescriptor<Footprint>(
                    predicate: #Predicate { $0.startTime < endOfDay && $0.endTime >= startOfDay },
                    sortBy: [SortDescriptor(\.startTime)]
                )
                
                let existing = (try? currentContext.fetch(fetchDescriptor)) ?? []
                return existing.map { ($0.startTime, $0.endTime) }
            }
            
            // 3. 寻找间隙并在后台处理
            var currentTime = startOfDay
            var gapsToInsert: [(start: Date, end: Date, center: CLLocationCoordinate2D, points: [CLLocationCoordinate2D], duration: TimeInterval)] = []
            
            for range in existingRanges {
                if range.start > currentTime.addingTimeInterval(120) {
                    if let gap = identifyGapStay(from: currentTime, to: range.start, rawPoints: rawPoints) {
                        gapsToInsert.append(gap)
                    }
                }
                currentTime = max(currentTime, range.end)
            }
            
            let now = Date()
            let isToday = Calendar.current.isDateInToday(date)
            let dayLimit = isToday ? now : min(endOfDay, now)
            
            // 严格遵循“离场结算制”：如果是今天且是最后一段间隙（直至当前时间），不要持久化生成足迹，由 UI 状态卡片负责呈现。
            if !isToday && dayLimit > currentTime.addingTimeInterval(120) {
                if let gap = identifyGapStay(from: currentTime, to: dayLimit, rawPoints: rawPoints) {
                    gapsToInsert.append(gap)
                }
            }
            
                    // 4. 回到主线程执行持久化
                    if !gapsToInsert.isEmpty {
                        let itemsToInsert = gapsToInsert
                        await MainActor.run {
                            guard let context = self.modelContext else { return }
                            var insertedFootprints: [Footprint] = []
                            for gap in itemsToInsert {
                                let newFp = Footprint(
                                    date: Calendar.current.startOfDay(for: gap.start),
                                    startTime: gap.start,
                                    endTime: gap.end,
                                    footprintLocations: gap.points,
                                    locationHash: "GAP_STAY",
                                    duration: gap.duration
                                )
                                newFp.title = Footprint.generateRandomTitle(for: "某地", seed: Int(gap.start.timeIntervalSince1970))
                                context.insert(newFp)
                                
                                if let mPlace = self.matchedPlaceFor(coordinate: gap.center) {
                                    let pid = mPlace.placeID
                                    newFp.placeID = pid
                                    newFp.address = mPlace.name
                                    newFp.title = Footprint.generateRandomTitle(for: mPlace.name, seed: Int(gap.start.timeIntervalSince1970))
                                    
                                    // --- 自动关联历史习惯 ---
                                    newFp.activityTypeValue = self.findFrequentActivityType(for: pid, at: gap.start, context: context)
                                }
                                insertedFootprints.append(newFp)
                            }
                            // 后刷入数据库以获得正式 ID
                            try? context.save()
                            
                            // 再触发分析
                            for fp in insertedFootprints {
                                self.analyzeFootprint(fp, context: context)
                            }
                        }
                    }
        }
    }
    
    private func identifyGapStay(from start: Date, to end: Date, rawPoints: [CLLocation]) -> (start: Date, end: Date, center: CLLocationCoordinate2D, points: [CLLocationCoordinate2D], duration: TimeInterval)? {
        let gapPoints = TimelineBuilder.extractPoints(from: rawPoints, start: start, end: end)
        guard !gapPoints.isEmpty else { return nil }
        
        let duration = end.timeIntervalSince(start)
        let diameter = calculateMaxDiameter(gapPoints)
        
        if diameter < 150 && duration >= 120 {
            let avgLat = gapPoints.map { $0.coordinate.latitude }.reduce(0, +) / Double(gapPoints.count)
            let avgLon = gapPoints.map { $0.coordinate.longitude }.reduce(0, +) / Double(gapPoints.count)
            let center = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            
            return (start: start, end: end, center: center, points: gapPoints.map { $0.coordinate }, duration: duration)
        }
        return nil
    }
    
    private func calculateMaxDiameter(_ points: [CLLocation]) -> Double {
        guard points.count > 1 else { return 0 }
        
        var minLat = 90.0, maxLat = -90.0
        var minLon = 180.0, maxLon = -180.0
        
        for p in points {
            let c = p.coordinate
            if c.latitude < minLat { minLat = c.latitude }
            if c.latitude > maxLat { maxLat = c.latitude }
            if c.longitude < minLon { minLon = c.longitude }
            if c.longitude > maxLon { maxLon = c.longitude }
        }
        
        let p1 = CLLocation(latitude: minLat, longitude: minLon)
        let p2 = CLLocation(latitude: maxLat, longitude: maxLon)
        return p1.distance(from: p2)
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
    
    /// 重置并重新生成指定日期的足迹数据
    @MainActor
    func resetData(for date: Date) {
        guard let context = modelContext else { return }
        
        isResettingData = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        
        Task {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: date)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            
            // 1. 物理清空当天所有相关记录
            let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime >= startOfDay && $0.startTime < endOfDay
            })
            let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.startTime >= startOfDay && $0.startTime < endOfDay
            })
            let insightDesc = FetchDescriptor<DailyInsight>(predicate: #Predicate { $0.date == startOfDay })
            
            if let fps = try? context.fetch(fpDesc) {
                for fp in fps {
                    // 仅保护带照片的足迹（视为原始数据）
                    let isProtected = !fp.photoAssetIDs.isEmpty
                    if !isProtected {
                        context.delete(fp)
                    }
                }
            }
            if let tps = try? context.fetch(tpDesc) { for tp in tps { context.delete(tp) } }
            if let insights = try? context.fetch(insightDesc) { for i in insights { context.delete(i) } }
            
            try? context.save()
            
            // 2. 调用新引擎重新构建
            await PersistentTimelineBuilder.syncDay(date: date, in: context)
            
            await MainActor.run {
                self.isResettingData = false
                // 显式触动 UI 刷新，重置是用户主动发起的，安全可控
                self.lastRawDataUpdateTrigger = Date()
            }
        }
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
                address: place.name,
                coordinate: place.coordinate,
                isExistingPlace: true,
                placeID: place.placeID,
                category: place.category
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
        
        // 3. 优化分级搜索 (降低 API 并发，提高响应速度与电池效能)
        // A. 系统级基础探测
        async let poisFromPOI = performPOIRequest(at: coordinate, radius: 1000)
        async let poisFromGeneral = performNaturalLanguageSearch(at: coordinate, query: "附近 周边 地点", radius: 1000)
        
        // B. 即时生活圈 & 社交网红 (办公、社交、生活、网红点 - 半径 1.5km)
        async let poisFromLife = performNaturalLanguageSearch(at: coordinate, query: "大厦 写字楼 中心 商务 SOHO CBD 国际中心 塔 咖啡 书店 瑞幸 Luckin 星巴克 喜茶 玩具 潮玩 乐高 POP MART 旗舰店 网红 打卡 拍照 绝美 出片 秘境 停车场 驿站", radius: 1500)
        
        // C. 文体、商业与公共空间 (商场、剧院、体育、公园、游乐场、广场、城市空间 - 半径 2.5km)
        async let poisFromVenuesPublic = performNaturalLanguageSearch(at: coordinate, query: "公园 游乐场 广场 园 林 绿地 湖 岛 湾 滩 漫步道 步道 骑行 体育馆 运动场 网球馆 游泳馆 场馆 剧院 剧场 电影院 影城 影院 音乐厅 艺术中心 展览馆 美术馆 科技馆 商场 购物中心 万象 城 悦 恒隆 苹果 华为", radius: 2500)
        
        // D. 宏大地标、交通、文旅与教育 (枢纽、机场、火车站、景区、地标、大学、医院 - 半径 5km)
        async let poisFromLandmarksLandscale = performNaturalLanguageSearch(at: coordinate, query: "机场 车站 火车站 高铁站 枢纽 总站 码头 港 景区 景点 故居 寺 庙 遗址 古镇 纪念碑 雕像 祠 宫 塔 大学 学院 医院 卫生 局 馆", radius: 5000)
        
        // E. 区域 AOI 定向深挖 (针对反地理编码结果进行精准确认)
        async let poisFromAOITask: [LocationSuggestion] = {
            guard let aois = firstMark?.areasOfInterest, !aois.isEmpty else { return [] }
            var results: [LocationSuggestion] = []
            for aoi in aois {
                let aoiResults = await performNaturalLanguageSearch(at: coordinate, query: aoi, radius: 1500)
                results.append(contentsOf: aoiResults)
            }
            return results
        }()
        
        // F. 基础地址辅助搜索 (街道、具体名称、区县)
        async let poisFromStreet = street != nil ? performNaturalLanguageSearch(at: coordinate, query: street!, radius: 1000) : []
        async let poisFromName = (nameMark != nil && nameMark != street) ? performNaturalLanguageSearch(at: coordinate, query: nameMark!, radius: 1000) : []
        async let poisFromDistrict = subLocality != nil ? performNaturalLanguageSearch(at: coordinate, query: subLocality!, radius: 1500) : []

        // 4. 合并所有结果
        allFound.append(contentsOf: await poisFromPOI)
        allFound.append(contentsOf: await poisFromGeneral)
        allFound.append(contentsOf: await poisFromStreet)
        allFound.append(contentsOf: await poisFromName)
        allFound.append(contentsOf: await poisFromDistrict)
        allFound.append(contentsOf: await poisFromLife)
        allFound.append(contentsOf: await poisFromVenuesPublic)
        allFound.append(contentsOf: await poisFromLandmarksLandscale)
        allFound.append(contentsOf: await poisFromAOITask)
        
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
            LocationSuggestion(
                id: UUID(), 
                name: item.name ?? "未知地点", 
                address: item.placemark.title ?? "", 
                coordinate: item.placemark.coordinate, 
                isExistingPlace: false, 
                placeID: nil,
                category: item.pointOfInterestCategory?.rawValue
            )
        }
    }
    
    private func performNaturalLanguageSearch(at coordinate: CLLocationCoordinate2D, query: String, radius: Double) async -> [LocationSuggestion] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius, longitudinalMeters: radius)
        let search = MKLocalSearch(request: req)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.map { item in
            LocationSuggestion(
                id: UUID(), 
                name: item.name ?? "未知地点", 
                address: item.placemark.title ?? "", 
                coordinate: item.placemark.coordinate, 
                isExistingPlace: false, 
                placeID: nil,
                category: item.pointOfInterestCategory?.rawValue
            )
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
        } else if let fp = footprint, let context = modelContext {
            // 确保足迹已受管理 (针对 GAP_STAY 产生的幻影足迹)
            if fp.modelContext == nil {
                context.insert(fp)
                if fp.locationHash == "GAP_STAY" {
                    fp.locationHash = "MANUAL_STAY"
                }
            }
            
            fp.address = suggestion.name
            fp.placeID = targetPlace.placeID
            // 重新分析足迹内容
            analyzeFootprint(fp, context: context)
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
                isUserDefined: false,
                category: suggestion.category
            )
            newPlace.isPriority = true
            modelContext?.insert(newPlace)
            return newPlace
        }
    }
    
    /// 执行原始轨迹数据的 iCloud 同步
    func performRawDataSync(showOverlay: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: "isICloudSyncEnabled") || showOverlay else { return }
        
        if showOverlay {
            await MainActor.run {
                isSyncingInitialData = true
                syncProgress = 0.0
                syncStatusMessage = "正在连接 iCloud..."
            }
        }
        
        do {
            // 模拟一些进度，因为 syncToiCloud 是黑盒且可能很快
            if showOverlay {
                Task {
                    for i in 1...50 {
                        if !isSyncingInitialData { break }
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        await MainActor.run { syncProgress = Double(i) / 100.0 }
                    }
                }
            }
            
            let count = try await RawLocationStore.shared.syncToiCloud()
            
            if showOverlay {
                await MainActor.run {
                    syncStatusMessage = "正在更新本地数据库..."
                    syncProgress = 0.6
                }
            }
            
            if count > 0 {
                await MainActor.run {
                    self.refreshAvailableRawDates()
                    self.lastRawDataUpdateTrigger = Date()
                }
                await self.loadPointsFromStore()
            }
            
            if showOverlay {
                // 完成最后进度
                for i in 60...100 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await MainActor.run { syncProgress = Double(i) / 100.0 }
                }
                
                await MainActor.run {
                    syncStatusMessage = "同步完成"
                    syncProgress = 1.0
                    // 延迟消失
                    Task {
                        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                        await MainActor.run {
                            isSyncingInitialData = false
                        }
                    }
                }
            }
        } catch {
            print("Raw location sync failed: \(error)")
            if showOverlay {
                await MainActor.run {
                    syncStatusMessage = "同步失败: \(error.localizedDescription)"
                    Task {
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                        await MainActor.run {
                            isSyncingInitialData = false
                        }
                    }
                }
            }
        }
    }
    
    /// 清理云端数据（由同步询问弹窗触发）
    func purgeCloudData() async {
        await MainActor.run {
            isSyncingInitialData = true
            syncProgress = 0.0
            syncStatusMessage = "正在清理云端数据..."
        }
        
        let containerIdentifier = "iCloud.com.ct106.difangke"
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        
        // 进度模拟
        let progressTask = Task {
            for i in 1...90 {
                if !isSyncingInitialData { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
                await MainActor.run { syncProgress = Double(i) / 100.0 }
            }
        }
        
        do {
            try await database.deleteRecordZone(withID: zoneID)
            
            // 清理 KVS
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.removeObject(forKey: "hasSeededDefaultData")
            kvs.synchronize()
            
            if let context = modelContext {
                // 清理可能已经同步下来的本地数据
                let models: [any PersistentModel.Type] = [
                    Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self, DailyInsight.self
                ]
                for model in models {
                    try? context.delete(model: model)
                }
                try? context.save()
            }
            
            progressTask.cancel()
            await MainActor.run {
                syncProgress = 1.0
                syncStatusMessage = "清理完成"
            }
        } catch {
            print("Purge failed: \(error)")
        }
        
        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
        await MainActor.run {
            isSyncingInitialData = false
        }
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
            course: self.course,
            speed: self.speed,
            timestamp: self.timestamp
        )
    }
}
