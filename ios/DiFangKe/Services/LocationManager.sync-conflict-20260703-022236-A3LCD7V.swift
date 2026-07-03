import WidgetKit
import Foundation
import CoreLocation
import SwiftData
import Combine
import SwiftUI
import MapKit
import CloudKit
import Photos
import Network

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

struct RawRecordingDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let isCurrentDevice: Bool

    var subtitle: String {
        isCurrentDevice ? "当前设备" : String(id.prefix(8))
    }
}

// MARK: - 原始轨迹点包装（附带漂移标记）
struct RawPointEntry {
    let location: CLLocation
    let isDriftPoint: Bool
    let originalIndex: Int
}

// MARK: - 原始坐标持久化存储（按天存储至 CSV 文件）
final class RawLocationStore {
    static let shared = RawLocationStore()
    
    private let fileManager = FileManager.default
    private let directoryName = "RawLocations"
    private let saveQueue = DispatchQueue(label: "com.ct106.difangke.rawsave", qos: .background)
    private let preferredRecordingDeviceKey = "raw_recording_source_device_id"
    private let knownDeviceNamesKey = "raw_recording_device_names"
    
    private init() {
        createDirectoryIfNeeded()
        rememberKnownDeviceName(currentDeviceName, for: deviceID)
    }
    
    private var documentsDirectory: URL {
        // 彻底回退：直接使用标准 Documents 目录，确保能读到用户已有的存量文件
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    var currentDeviceIdentifier: String {
        deviceID
    }

    private var currentDeviceName: String {
        UIDevice.current.name
    }

    private var isRawTrajectoryICloudSyncEnabled: Bool {
        if UserDefaults.standard.object(forKey: "isRawTrajectoryICloudSyncEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "isRawTrajectoryICloudSyncEnabled")
    }

    func preferredRecordingDeviceID() -> String {
        guard isRawTrajectoryICloudSyncEnabled else { return deviceID }
        if let selected = UserDefaults.standard.string(forKey: preferredRecordingDeviceKey), !selected.isEmpty {
            return selected
        }
        return deviceID
    }

    func setPreferredRecordingDeviceID(_ deviceID: String) {
        UserDefaults.standard.set(deviceID, forKey: preferredRecordingDeviceKey)
    }

    func displayName(forRecordingDeviceID deviceID: String) -> String {
        if deviceID == self.deviceID {
            return currentDeviceName
        }
        return knownDeviceNames()[deviceID] ?? "设备 \(String(deviceID.prefix(8)))"
    }

    func availableRecordingDevices() -> [RawRecordingDeviceOption] {
        rememberKnownDeviceName(currentDeviceName, for: deviceID)

        var deviceIDs: Set<String> = [deviceID, preferredRecordingDeviceID()]
        if let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
            for fileURL in files where fileURL.pathExtension == "csv" {
                if let parsedDeviceID = parseDeviceID(fromFileName: fileURL.lastPathComponent) {
                    deviceIDs.insert(parsedDeviceID)
                }
            }
        }

        return deviceIDs.map { id in
            RawRecordingDeviceOption(
                id: id,
                name: displayName(forRecordingDeviceID: id),
                isCurrentDevice: id == deviceID
            )
        }
        .sorted {
            if $0.isCurrentDevice != $1.isCurrentDevice {
                return $0.isCurrentDevice && !$1.isCurrentDevice
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func availableDatesForPreferredRecordingDevice() -> Set<Date> {
        guard let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var dates = Set<Date>()
        for fileURL in files where fileURL.pathExtension == "csv" {
            let fileName = fileURL.lastPathComponent
            guard let parsedDeviceID = parseDeviceID(fromFileName: fileName), parsedDeviceID == preferredRecordingDeviceID() else {
                continue
            }
            let dateString = String(fileName.prefix(10))
            if let date = formatter.date(from: dateString) {
                dates.insert(Calendar.current.startOfDay(for: date))
            }
        }
        return dates
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
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            let url = self.getFileURL(for: location.timestamp)
            let line = "\(location.timestamp.timeIntervalSince1970),\(location.coordinate.latitude),\(location.coordinate.longitude),\(location.horizontalAccuracy),\(location.speed)\n"
            
            if let data = line.data(using: .utf8) {
                if self.fileManager.fileExists(atPath: url.path) {
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
    }
    
    /// 读取指定日期的所有坐标点
    func loadLocations(for date: Date, filtered: Bool = true) -> [CLLocation] {
        let url = getFileURL(for: date)
        // 核心：移除 .mappedIfSafe，防止读取实时写入的文件时失败
        guard let data = try? Data(contentsOf: url) else { return [] }
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
                        // 新增：物理不可能的速度直接过滤（如 5秒内 3公里 = 600m/s）
                        if calcSpeed > AppConfig.shared.physicalMaxSpeedThreshold { return }
                        
                        let isRidiculous = (accuracy > 400 && dist > 1500) || (calcSpeed > 80.0 && accuracy > 80)
                        if isRidiculous { return } // 跳过该点，不加入列表，且不更新 lastValidPoint
                    }
                }
                
                locations.append(loc)
                lastValidPoint = loc
            }
        }
        return filtered ? RawLocationStore.filterRidiculousSpikes(locations) : locations
    }
    
    /// 获取最近一段的点。如果提供了 since，则至少获取到 since 那个时间点。
    func loadRecentLocations(lookbackHours: Double? = nil, since: Date? = nil) -> [CLLocation] {
        let now = Date()
        let lookback = lookbackHours ?? AppConfig.shared.locationLookbackHours
        let defaultThreshold = now.addingTimeInterval(-lookback * 3600)
        let threshold = since.map { min($0, defaultThreshold) } ?? defaultThreshold
        
        // 限制回溯至最大限制内，防止数据量过大导致崩溃
        let finalThreshold = max(threshold, now.addingTimeInterval(-AppConfig.shared.locationLookbackMaxHours * 3600))
        
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

    /// 读取指定日期的所有坐标点，仅返回当前选定记录设备的轨迹
    func loadAllDevicesLocations(for date: Date, filtered: Bool = true) -> [CLLocation] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: date)
        
        guard let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var allPoints: [CLLocation] = []
        let selectedDeviceID = preferredRecordingDeviceID()
        let relevantFiles = files.filter {
            $0.lastPathComponent.hasPrefix(datePrefix) &&
            $0.pathExtension == "csv" &&
            parseDeviceID(fromFileName: $0.lastPathComponent) == selectedDeviceID
        }
        
        for fileURL in relevantFiles {
            let dayPoints = loadLocations(fromURL: fileURL, filtered: filtered)
            allPoints.append(contentsOf: dayPoints)
        }
        
        // 核心修复：去重。不同设备可能同步了相同的时间点，或者同一设备多次上传。
        // 使用 Dictionary 按时间戳去重，保留精度更高（accuracy 越小越好）的点。
        var uniquePoints: [TimeInterval: CLLocation] = [:]
        for p in allPoints {
            let ts = p.timestamp.timeIntervalSince1970
            if let existing = uniquePoints[ts] {
                if p.horizontalAccuracy < existing.horizontalAccuracy {
                    uniquePoints[ts] = p
                }
            } else {
                uniquePoints[ts] = p
            }
        }
        
        let sorted = uniquePoints.values.sorted { $0.timestamp < $1.timestamp }
        return filtered ? RawLocationStore.filterRidiculousSpikes(sorted) : sorted
    }
    
    private func loadLocations(fromURL url: URL, filtered: Bool = true) -> [CLLocation] {
        guard let data = try? Data(contentsOf: url),
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
                        // 新增：物理不可能的速度直接过滤
                        if calcSpeed > AppConfig.shared.physicalMaxSpeedThreshold { return }
                        
                        let isRidiculous = (accuracy > 400 && dist > 1500) || (calcSpeed > 80.0 && accuracy > 80)
                        if isRidiculous { return }
                    }
                }
                
                locations.append(loc)
                lastValidPoint = loc
            }
        }
        return filtered ? RawLocationStore.filterRidiculousSpikes(locations) : locations
    }
    
    /// 从源文件中彻底删除某个点 (匹配时间戳)
    func deleteLocation(at timestamp: Double, for date: Date) {
        saveQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let prefix = formatter.string(from: date)
            
            guard let files = try? self.fileManager.contentsOfDirectory(at: self.baseDirectory, includingPropertiesForKeys: nil) else { return }
            let targetFiles = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "csv" }
            
            for url in targetFiles {
                guard let data = try? Data(contentsOf: url),
                      let content = String(data: data, encoding: .utf8) else { continue }
                
                let lines = content.components(separatedBy: .newlines)
                let originalCount = lines.count
                let filteredLines = lines.filter { line in
                    guard !line.isEmpty else { return false }
                    let parts = line.split(separator: ",")
                    if let ts = Double(parts[0]) {
                        return abs(ts - timestamp) > 0.0001
                    }
                    return true
                }
                
                if filteredLines.count < originalCount - 1 {
                    let newContent = filteredLines.joined(separator: "\n") + "\n"
                    try? newContent.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            
            // 异步回主线程通知更新
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("RawLocationDataDeleted"), object: nil, userInfo: ["date": date])
            }
        }
    }

    /// 从源文件中批量删除多个点 (匹配时间戳)
    func deleteLocations(at timestamps: Set<Double>, for date: Date) {
        saveQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let prefix = formatter.string(from: date)
            
            guard let files = try? self.fileManager.contentsOfDirectory(at: self.baseDirectory, includingPropertiesForKeys: nil) else { return }
            let targetFiles = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "csv" }
            
            for url in targetFiles {
                guard let data = try? Data(contentsOf: url),
                      let content = String(data: data, encoding: .utf8) else { continue }
                
                let lines = content.components(separatedBy: .newlines)
                let originalCount = lines.count
                let filteredLines = lines.filter { line in
                    guard !line.isEmpty else { return false }
                    let parts = line.split(separator: ",")
                    if let ts = Double(parts[0]) {
                        for targetTs in timestamps {
                            if abs(ts - targetTs) < 0.0001 { return false }
                        }
                    }
                    return true
                }
                
                if filteredLines.count < originalCount - 1 {
                    let newContent = filteredLines.joined(separator: "\n") + "\n"
                    try? newContent.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("RawLocationDataDeleted"), object: nil, userInfo: ["date": date])
            }
        }
    }

    /// 核心算法：识别并剔除轨迹中的突发性漂移点（Spike Filter）
    /// 几分钟内跨越数公里又回到附近，属于典型的坐标跳变 (支持连续多点跳转检测)
    static func filterRidiculousSpikes(_ points: [CLLocation]) -> [CLLocation] {
        guard points.count >= 3 else { return points }
        let marked = markDriftPoints(points)
        return marked.filter { !$0.isDriftPoint }.map { $0.location }
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
        let selectedDeviceID = preferredRecordingDeviceID()
        let relevantFiles = files.filter {
            $0.lastPathComponent.hasPrefix(datePrefix) &&
            $0.pathExtension == "csv" &&
            parseDeviceID(fromFileName: $0.lastPathComponent) == selectedDeviceID
        }
        
        for fileURL in relevantFiles {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                // 统计换行符数量作为行数估算，比完全解析成 CLLocation 快得多
                let count = content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
                totalCount += count
            }
        }
        return totalCount
    }

    private func parseDeviceID(fromFileName fileName: String) -> String? {
        guard fileName.hasSuffix(".csv") else { return nil }
        let stem = String(fileName.dropLast(4))
        if stem.count == 10 {
            return deviceID
        }

        guard stem.count > 11 else { return nil }
        let dashIndex = stem.index(stem.startIndex, offsetBy: 10)
        guard stem[dashIndex] == "-" else { return nil }
        return String(stem[stem.index(after: dashIndex)...])
    }

    private func knownDeviceNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: knownDeviceNamesKey) as? [String: String] ?? [:]
    }

    private func rememberKnownDeviceName(_ name: String, for deviceID: String) {
        guard !name.isEmpty, !deviceID.isEmpty else { return }
        var knownNames = knownDeviceNames()
        if knownNames[deviceID] == name { return }
        knownNames[deviceID] = name
        UserDefaults.standard.set(knownNames, forKey: knownDeviceNamesKey)
    }

    // --- CloudKit 手动同步相关 ---

    private let cloudDatabase = CKContainer(identifier: "iCloud.com.ct106.difangke").privateCloudDatabase

    func syncToiCloud(onlyRecent: Bool = true, skipUpload: Bool = false) async throws -> Int {
        let localFiles = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        var totalCount = 0

        let calendar = Calendar.current
        let lookbackDays = AppConfig.shared.cloudSyncLookbackDays
        let cutoffDate = calendar.date(byAdding: .day, value: -lookbackDays, to: Date())! // 默认只同步最近 N 天
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffStr = formatter.string(from: cutoffDate)

        var recordsToSave: [CKRecord] = []

        // 1. 收集本地待上传文件 (带上当前设备 ID)
        if !skipUpload {
            for localURL in localFiles {
                let fileName = localURL.lastPathComponent
                // 只要文件名长度正好是 14 位 (例如 2026-04-04.csv)，就视为本地待上传文件
                guard fileName.hasSuffix(".csv") && fileName.count == 14 else { continue }
                
                let dateStr = fileName.replacingOccurrences(of: ".csv", with: "")
                
                // 如果是增量同步，且文件早于截止日期，则跳过
                if onlyRecent && dateStr < cutoffStr { continue }
                
                let recordID = CKRecord.ID(recordName: "\(dateStr)-\(deviceID)")
                
                let record = CKRecord(recordType: "RawTrajectory", recordID: recordID)
                record["date"] = dateStr
                record["deviceID"] = deviceID
                record["deviceName"] = currentDeviceName
                record["file"] = CKAsset(fileURL: localURL)
                recordsToSave.append(record)
            }
        }
        
        // 批量分段上传 (每 5 个一组，防止 Assets 过大导致请求超时)
        let batchSize = 5
        var uploadIndex = 0
        while uploadIndex < recordsToSave.count {
            let chunk = Array(recordsToSave[uploadIndex..<min(uploadIndex + batchSize, recordsToSave.count)])
            let modifyOp = CKModifyRecordsOperation(recordsToSave: chunk, recordIDsToDelete: nil)
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
            totalCount += chunk.count
            uploadIndex += batchSize
        }

        // 2. 下载其他设备的文件
        do {
            let predicate: NSPredicate
            if onlyRecent {
                let calendar = Calendar.current
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                
                var dateStrings: [String] = []
                for i in 0..<lookbackDays {
                    if let date = calendar.date(byAdding: .day, value: -i, to: Date()) {
                        dateStrings.append(formatter.string(from: date))
                    }
                }
                predicate = NSPredicate(format: "date IN %@", dateStrings)
            } else {
                // Use `date != ""` instead of `value: true` because CloudKit requires `recordName` to be queryable for `value: true`, 
                // but `date` is already marked queryable since the `IN` query works.
                predicate = NSPredicate(format: "date != %@", "")
            }
            
            let query = CKQuery(recordType: "RawTrajectory", predicate: predicate)
            
            var matchResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
            var currentCursor: CKQueryOperation.Cursor?
            
            let (initialResults, initialCursor) = try await cloudDatabase.records(matching: query)
            matchResults.append(contentsOf: initialResults)
            currentCursor = initialCursor
            
            while let cursor = currentCursor {
                let (nextResults, nextCursor) = try await cloudDatabase.records(continuingMatchFrom: cursor)
                matchResults.append(contentsOf: nextResults)
                currentCursor = nextCursor
            }
            
            for (_, result) in matchResults {
                if let record = try? result.get() {
                    let remoteDeviceID = record["deviceID"] as? String ?? ""
                    let remoteDeviceName = record["deviceName"] as? String ?? ""
                    let remoteDate = record["date"] as? String ?? ""
                    
                    // 只有其他设备的数据才下载
                    if remoteDeviceID != deviceID && !remoteDate.isEmpty {
                        if !remoteDeviceName.isEmpty {
                            rememberKnownDeviceName(remoteDeviceName, for: remoteDeviceID)
                        }
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

    // MARK: - 漂移点标记系统
    
    /// 加载带漂移标记的原始轨迹点（用于 RawPointsListView 显示）
    func loadAllDevicesLocationsWithDriftFlags(for date: Date) -> [RawPointEntry] {
        // 加载未过滤的原始点
        let rawPoints = loadAllDevicesLocations(for: date, filtered: false)
        return RawLocationStore.markDriftPoints(rawPoints)
    }
    
    /// 核心算法：标记轨迹中的漂移点（不删除，只打标记）
    /// 检测模式：
    /// 1. 三点回弹检测：A≈C 但 B 远离（用户描述的典型场景）
    /// 2. 物理速度不可能检测
    /// 3. 精度异常 + 大跳变检测
    /// 4. 现有 filterRidiculousSpikes 中的多点跳变集群检测
    static func markDriftPoints(_ points: [CLLocation]) -> [RawPointEntry] {
        guard points.count >= 2 else {
            return points.enumerated().map { RawPointEntry(location: $0.element, isDriftPoint: false, originalIndex: $0.offset) }
        }
        
        var driftFlags = [Bool](repeating: false, count: points.count)
        
        // --- Pass 1: 三点回弹检测（核心新算法）---
        // 对于每个点 B(index=i), 检查 A(i-1) 和 C(i+1)
        // 如果 A≈C (距离较近) 但 B 远离 A 和 C，则 B 是漂移点
        for i in 1..<(points.count - 1) {
            let a = points[i - 1]
            let b = points[i]
            let c = points[i + 1]
            
            let timeAC = abs(c.timestamp.timeIntervalSince(a.timestamp))
            
            // 只在时间窗口较短时触发（30秒内，覆盖用户描述的5秒场景和更多情况）
            guard timeAC < 30 else { continue }
            
            let distAC = a.distance(from: c)
            let distAB = a.distance(from: b)
            let distBC = b.distance(from: c)
            
            // A 和 C 距离很近（< 100m），但 B 跳到了很远（> 80m）
            if distAC < 100 && distAB > 80 && distBC > 80 {
                driftFlags[i] = true
                continue
            }
            
            // 更宽松的变体：A 和 C 距离适中（< 200m），但 B 跳得很远（> 200m）
            if distAC < 200 && distAB > 200 && distBC > 200 {
                driftFlags[i] = true
                continue
            }
            
            // 补充：B 的精度很差且跳变明显
            if b.horizontalAccuracy > 65 && distAC < 150 && distAB > 100 {
                driftFlags[i] = true
                continue
            }
        }
        
        // --- Pass 2: 连续多点回弹检测（如 A,B1,B2,C 中 B1,B2 都是漂移）---
        // 滑动窗口，检查非漂移的邻居
        for i in 1..<(points.count - 1) {
            if driftFlags[i] { continue } // 已经标记的跳过
            
            // 向前找最近的非漂移点
            var prevIdx = i - 1
            while prevIdx >= 0 && driftFlags[prevIdx] { prevIdx -= 1 }
            guard prevIdx >= 0 else { continue }
            
            // 向后找最近的非漂移点
            var nextIdx = i + 1
            while nextIdx < points.count && driftFlags[nextIdx] { nextIdx += 1 }
            guard nextIdx < points.count else { continue }
            
            let prev = points[prevIdx]
            let current = points[i]
            let next = points[nextIdx]
            
            let timePN = abs(next.timestamp.timeIntervalSince(prev.timestamp))
            guard timePN < 60 else { continue }
            
            let distPN = prev.distance(from: next)
            let distPC = prev.distance(from: current)
            let distCN = current.distance(from: next)
            
            // 前后非漂移点很近，但当前点远离
            if distPN < 100 && distPC > 150 && distCN > 150 {
                driftFlags[i] = true
            }
        }
        
        // --- Pass 3: 物理速度不可能 + 精度极差的孤立跳变 ---
        for i in 0..<points.count {
            if driftFlags[i] { continue }
            let current = points[i]
            
            // 3a: 物理不可能的瞬时速度（对比前后邻居）
            if i > 0 && !driftFlags[i - 1] {
                let prev = points[i - 1]
                let dist = current.distance(from: prev)
                let time = max(current.timestamp.timeIntervalSince(prev.timestamp), 0.1)
                let speed = dist / time
                
                if speed > AppConfig.shared.physicalMaxSpeedThreshold {
                    // 检查后面的点是否回弹到 prev 附近
                    if i + 1 < points.count {
                        let next = points[i + 1]
                        let distPrevNext = prev.distance(from: next)
                        if distPrevNext < dist * 0.5 {
                            driftFlags[i] = true
                            continue
                        }
                    }
                }
            }
            
            // 3b: 极差精度 + 大位移
            if current.horizontalAccuracy > 1500 {
                var nearbyGood = false
                let checkRange = max(0, i - 3)...min(points.count - 1, i + 3)
                for j in checkRange where j != i && !driftFlags[j] {
                    if current.distance(from: points[j]) < 500 {
                        nearbyGood = true
                        break
                    }
                }
                if !nearbyGood {
                    driftFlags[i] = true
                }
            }
        }
        
        // --- Pass 4: 使用现有的跳变集群逻辑标记（对应 filterRidiculousSpikes 的大跳变检测）---
        var cleanedIndex = 0 // 跟踪已接受的最后一个点的索引
        for i in 1..<points.count {
            if driftFlags[i] { continue }
            
            let prev = points[cleanedIndex]
            let current = points[i]
            let dist = current.distance(from: prev)
            let time = max(current.timestamp.timeIntervalSince(prev.timestamp), 0.1)
            let speed = dist / time
            
            if speed > 60 || (dist > 800 && speed > 20) || dist > 2000 {
                var foundReturn = false
                let searchLimit = min(i + 15, points.count)
                for j in (i + 1)..<searchLimit {
                    let next = points[j]
                    let tPrevToNext = max(next.timestamp.timeIntervalSince(prev.timestamp), 0.1)
                    let dPrevToNext = next.distance(from: prev)
                    let avgSpeed = dPrevToNext / tPrevToNext
                    
                    if avgSpeed < 42 && dist > 800 && current.distance(from: next) > 800 {
                        // 标记 i 到 j-1 所有点为漂移
                        for k in i..<j {
                            driftFlags[k] = true
                        }
                        foundReturn = true
                        break
                    }
                }
                
                if !foundReturn && current.horizontalAccuracy > 1500 && dist > 2000 {
                    driftFlags[i] = true
                }
            }
            
            if !driftFlags[i] {
                cleanedIndex = i
            }
        }
        
        return points.enumerated().map { index, location in
            RawPointEntry(location: location, isDriftPoint: driftFlags[index], originalIndex: index)
        }
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
    private var driftSpeedThreshold: CLLocationSpeed { AppConfig.shared.driftSpeedThreshold } // m/s，异常飘移速度
    
    // 1.3 停留点识别参数
    private var stayRadiusThreshold: Double { AppConfig.shared.stayDistanceThreshold }
    private var stayDurationThreshold: TimeInterval { AppConfig.shared.stayDurationThreshold }
    
    // 1.4 合并参数
    private var mergeTimeThreshold: TimeInterval { AppConfig.shared.stayMergeGapThreshold }
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
            
            // A: 物理不可能性判断：时速超过阈值 (约 220km/h) 且精度不佳，判定为漂移数据
            if calculatedSpeed > AppConfig.shared.driftSpeedMaxPossible && location.horizontalAccuracy > AppConfig.shared.driftAccuracyThreshold {
                return nil
            }
            
            // B: 精度断崖式下降判断：如果位移很大 且当前精度比上一点差很多 (>3倍且绝对值>150m)，判定为漂移
            if distance > AppConfig.shared.driftDistanceGap && location.horizontalAccuracy > lastLoc.horizontalAccuracy * 3 && location.horizontalAccuracy > 150 {
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

#if !WIDGET_EXTENSION
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
    var deepLinkFutureTripID: UUID?
    var deepLinkDate: Date?
    
    var isTracking: Bool = false
    var lastUpdateTime: Date?
    var lastLocation: CLLocation?
    var accuracy: CLLocationAccuracy?
    var currentAddress: String = "正在解析位置..."
    private var pathMonitor: NWPathMonitor?
    private var lastInterfaceType: NWInterface.InterfaceType?
    
    /// UI 层“是否在移动”的稳定判断（带滞回），用于“今日正在记录”卡片标题等。
    /// 目标：避免走路时因为 speed 抖动/传感器短暂 stationay 而快速切回“正在停留”。
    var uiIsMoving: Bool = false
    private var lastMovingEvidenceTime: Date = .distantPast
    
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
    private var lastNotifiedStayStart: Date?
    private var lastPastMemoriesCheckDate: String? // yyyy-MM-dd
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
    var rebuildProgress: Double = 0
    var isRebuildingAll: Bool = false
    private var rebuildTask: Task<Void, Never>? = nil
    private var liveFootprintMergeTask: Task<Void, Never>? = nil
    
    // 从 View 同步过来的参数
    var allPlaces: [Place] = []
    var modelContext: ModelContext? {
        didSet {
            if modelContext != nil {
                Task {
                    await loadPointsFromStore() // 获得数据库后，后台加载点并同步最后处理时间
                }
                checkLiveActivity()
            }
        }
    }
    
    func checkLiveActivity() {
        guard let location = lastLocation, let context = modelContext else { return }
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            TripLiveActivityManager.shared.updateLiveActivity(location: location, modelContext: context)
        }
#endif
    }
    
    // 正在记录的临时停留状态
    var potentialStopStartLocation: CLLocation?
    private var ongoingPlaceOverrideID: UUID?
    private var ongoingPlaceOverrideAddress: String?
    
    /// 快速检测云端是否有数据 (通过 KVS)
    func hasExistingCloudData() -> Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        return kvs.bool(forKey: "hasSeededDefaultData")
    }
    
    /// 根据当前速度/精度，提供给 UI 呈现不同频率的“呼吸”动画时长
    var pulseDuration: Double {
        if !isTracking { return 4.0 }
        
        let speed = lastLocation?.speed ?? 0
        if speed > 10.0 { // 高速：0.8s
            return 0.8
        } else if speed > 0.5 { // 移动：1.5s
            return 1.5
        } else { // 停留：3.0s (低功耗)
            return 3.0
        }
    }
    
    // 服务引用
    private let footprintProcessor = FootprintProcessor.shared
    private let openAIService = OpenAIService.shared
    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?
    
    // 标签继承距离阈值
    private var tagInheritanceDistance: CLLocationDistance { AppConfig.shared.tagInheritanceDistance }
    
    // 习惯匹配参数 (从 Config 加载)
    private var habitTimeWindow: Int { AppConfig.shared.habitTimeWindow }
    private var habitFrequencyThreshold: Int { AppConfig.shared.habitFrequencyThreshold }
    
    private var refreshTimer: AnyCancellable?
    private var locationWatchdogTimer: AnyCancellable?
    private var lastStationaryProbeTime: Date = .distantPast
    private var lastStartTrackingAt: Date = .distantPast
    private var lastForegroundLocationRequestAt: Date = .distantPast
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest // 初次启动使用最高精度，确保冷启动位置快速锁定
        self.locationManager.distanceFilter = 5.0 // 初始高频记录 (5米)
        if isAuthorized {
            self.locationManager.allowsBackgroundLocationUpdates = true
        }
        self.locationManager.pausesLocationUpdatesAutomatically = false // 核心修复：禁止自动暂停，防止丢点
        self.locationManager.showsBackgroundLocationIndicator = false // 保持静默记录，不显示蓝色状态栏（响应用户反馈）
        self.locationManager.activityType = .fitness // 默认为健身/步行模式
        
        // Initialize basic status
        updateAuthStatus()
        loadPotentialStop()
        
        setupTimers()
        setupSubscribers()
        setupNetworkMonitoring()
        
        // Start visit monitoring only if already authorized to avoid premature prompts
        if isAuthorized {
            locationManager.startMonitoringVisits()
        }
        
        // Move heavy disk I/O to background to avoid blocking app launch
        Task(priority: .userInitiated) { [weak self] in
            self?.loadTodayTotalPoints()
            await self?.loadPointsFromStore() 
            self?.refreshAvailableRawDates()
        }
        
        // 不再根据 RemoteDataChanged 自动触发同步。
        // 同步策略改为：定时 + 手动下拉。
        
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
        
        // Listen for FutureTrip changes to update Live Activities
        NotificationCenter.default.addObserver(
            forName: FutureTrip.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkLiveActivity()
            }
        }
        
        // 核心监测：监听运动状态变化，一旦“动起来”，立即强制提升定位频率，不等 GPS 响应
        HealthManager.shared.$isMoving
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isMoving in
                if isMoving {
                    self?.forceHighAccuracyBoost()
                }
                self?.updateUIMovementState(isMovingEvidence: isMoving, source: "motion:isMoving")
            }
            .store(in: &cancellables)
        // 核心修复：在 init() 里就启动运动传感器 + 健康授权
        // 这样即使 App 从后台被系统唤醒（不走 startTracking），运动状态变化也能触发 boost
        if UserDefaults.standard.bool(forKey: "hasRequestedHealthAuth") {
            HealthManager.shared.startActivityTracking()
        }
    }

    /// 将“移动证据”转成 UI 稳定状态：有移动证据立刻切到 moving；无证据需要保持一段时间才切回 stationary。
    private func updateUIMovementState(isMovingEvidence: Bool, source: String) {
        let now = Date()
        if isMovingEvidence {
            lastMovingEvidenceTime = now
            if !uiIsMoving {
                uiIsMoving = true
                print("[LocationManager] UI moving=true (\(source))")
            }
            return
        }
        
        // 无移动证据：必须连续一段时间都没有证据，才允许切回“停留”，避免抖动
        let holdSeconds: TimeInterval = 120
        if uiIsMoving, now.timeIntervalSince(lastMovingEvidenceTime) > holdSeconds {
            uiIsMoving = false
            print("[LocationManager] UI moving=false (\(source))")
            Task {
                await triggerTimelineSift()
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private func setupSubscribers() {
        NotificationCenter.default.publisher(for: NSNotification.Name("RawLocationDataDeleted"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self, let date = notification.userInfo?["date"] as? Date else { return }
                
                // 如果删除的是今天的点，清空缓存强制重新加载
                if Calendar.current.isDateInToday(date) {
                    Task {
                        await self.loadPointsFromStore()
                    }
                }
                
                // 触动全局 UI 刷新
                self.lastRawDataUpdateTrigger = Date()
            }
            .store(in: &cancellables)
            
        // 监听 CloudKit 云端数据同步事件（SwiftData 底层通过 CoreData 发出此通知）
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            // 节流处理，避免 iCloud 大量拉取时频繁刷新卡死 UI
            .throttle(for: .seconds(3.0), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                print("[LocationManager] ☁️ NSPersistentStoreRemoteChange detected, posting FootprintDataChanged...")
                NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            }
            .store(in: &cancellables)
    }
    
    /// 出门保护期截止时间 —— 在此时间之前 isStationary 强制返回 false
    /// 防止节能逻辑在 GPS/传感器还没稳定时把精度降回低频
    private var departureBoostEndTime: Date = .distantPast
    
    /// 防抖：避免看门狗/系统回调频繁重启定位导致耗电抖动
    private var lastRecoveryBoostTime: Date = .distantPast

    /// 强制激活高精度模式（通常由计步器、运动传感器或网络变化触发，早于 GPS 位移）
    private func forceHighAccuracyBoost() {
        print("🚀 Status change detected! Forcing high accuracy boost...")
        
        // 0. 设置 10 分钟出门保护期，覆盖大多数步行出门的起步阶段，防止过早降频造成直线轨迹
        departureBoostEndTime = Date().addingTimeInterval(10 * 60)
        
        // 1. 确保背景模式配置正确（防止被系统意外重置）
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // 2. 提升精度，但避免长期停留在导航级满额采样导致发热
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        
        // 3. 核心补救：立即请求一次单次精确定位，强制拉高硬件功率
        locationManager.requestLocation()
        
        // 4. 尝试重启持续更新，确保背景任务刷新
        locationManager.stopUpdatingLocation()
        locationManager.startUpdatingLocation()
    }
    
    private func setupNetworkMonitoring() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let currentType = path.availableInterfaces.first?.type
            
            Task { @MainActor in
                // 核心逻辑：如果从 WiFi 切换到蜂窝数据，大概率是出门了
                if self.lastInterfaceType == .wifi && currentType == .cellular {
                    print("🌐 Network switched from WiFi to Cellular! Likely leaving home/office.")
                    self.forceHighAccuracyBoost()
                }
                self.lastInterfaceType = currentType
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        pathMonitor?.start(queue: queue)
    }
    
    /// 遍历原始轨迹存储目录，找出所有有记录的日期并缓存
    func refreshAvailableRawDates() {
        let dates = RawLocationStore.shared.availableDatesForPreferredRecordingDevice()
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

        // Location watchdog: recover stalled updates while moving, and probe long stays
        // so leaving indoor venues does not depend solely on delayed visit/region events.
        locationWatchdogTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.runLocationWatchdog()
            }
        
        // Initial check on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.checkMidnightSift()
        }
    }

    private func runLocationWatchdog() {
        guard isTracking else { return }

        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways else { return }
        guard shouldRunActiveLocationRecovery else { return }

        let now = Date()

        // Intervene when we believe the user is actually moving OR when uiIsMoving is true.
        let motion = HealthManager.shared.currentMotionType
        let isMovingBySensor = HealthManager.shared.isMoving
            || motion == .walking
            || motion == .running
            || motion == .cycling
            || motion == .automotive
            || uiIsMoving // 扩大监测范围：只要 UI 层认为在移动就介入

        guard let last = lastUpdateTime else {
            requestStationaryDepartureProbeIfNeeded(now: now, lastUpdateGap: .infinity)
            return
        }
        let gap = now.timeIntervalSince(last)

        if !isMovingBySensor {
            requestStationaryDepartureProbeIfNeeded(now: now, lastUpdateGap: gap)
            return
        }

        guard gap > 45 else { return } // 移动中 45 秒没点就恢复，避免开头几百米丢失
        
        // Throttle recovery attempts to at most once per minute while moving.
        if now.timeIntervalSince(lastRecoveryBoostTime) < 60 {
            return
        }
        lastRecoveryBoostTime = now

        print("[LocationManager] ⚠️ No location updates for \(Int(gap))s while moving. Restarting updates…")
        ensureSignificantMonitoringActive()
        forceHighAccuracyBoost()
    }

    private func requestStationaryDepartureProbeIfNeeded(now: Date, lastUpdateGap: TimeInterval) {
        guard let stop = potentialStopStartLocation else { return }

        let stationaryDuration = now.timeIntervalSince(stop.timestamp)
        guard stationaryDuration > 10 * 60 else { return }

        // During a confirmed long stay, do a low-frequency active probe. This catches
        // indoor departures where Core Motion, Visit Monitoring, or the region exit
        // callback may be delayed until the user has already moved several hundred meters.
        guard lastUpdateGap > 3 * 60 else { return }
        guard now.timeIntervalSince(lastStationaryProbeTime) > 5 * 60 else { return }
        lastStationaryProbeTime = now

        let gapDescription = lastUpdateGap.isFinite ? "\(Int(lastUpdateGap))s" : "unknown duration"
        print("[LocationManager] 🧭 Long stationary stay has no fresh location for \(gapDescription). Requesting departure probe…")
        ensureSignificantMonitoringActive()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5.0
        locationManager.activityType = .fitness
        locationManager.requestLocation()
        locationManager.startUpdatingLocation()
    }

    private var shouldRunActiveLocationRecovery: Bool {
        let modeRaw = UserDefaults.standard.string(forKey: LocationAccuracyMode.userDefaultsKey) ?? LocationAccuracyMode.automatic.rawValue
        let mode = LocationAccuracyMode(rawValue: modeRaw) ?? .automatic
        return mode != .powerSaving
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

    /// 新定位到达后，专门收敛“当前地点”可能重复生成的足迹。
    /// 不在启动时扫描历史数据，避免首屏已经展示的时间线被异步改写。
    private func scheduleLiveFootprintMerge() {
        liveFootprintMergeTask?.cancel()
        liveFootprintMergeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  let context = self.modelContext,
                  let lastLocation = self.lastLocation,
                  abs(lastLocation.timestamp.timeIntervalSinceNow) < 30 else {
                return
            }

            if self.mergeRecentFootprints(in: context) {
                NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            }
        }
    }
    
    func triggerTimelineSift() async {
        guard let context = modelContext else { return }
        await PersistentTimelineBuilder.syncDay(date: Date(), in: context, runConsolidation: false)
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
    }
    
    private func siftYesterday() {
        /*
        let container = modelContext?.container
        Task.detached(priority: .background) { [weak self] in
            guard let self = self, let container = container else { return }
            let context = ModelContext(container)
            // Sifting yesterday involves ensuring the last segment is closed
            // Consolidate handles recent 7 days, so it will cover yesterday.
            // 用户要求：不要在此处合并
            // await self.consolidateFootprints(in: context)
        }
        */
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
        let now = Date()
        let start: Date
        
        if let localStart = potentialStopStartLocation?.timestamp {
            start = localStart
        } else if let status = UserDefaults.standard.dictionary(forKey: "liveStayStatus"),
                  let ts = status["start"] as? Double {
            start = Date(timeIntervalSince1970: ts)
        } else if let firstPoint = allTodayPoints.first?.timestamp {
            start = firstPoint
        } else {
            return nil
        }

        let duration = now.timeIntervalSince(start)
        return duration.formattedStayDuration
    }

    var matchedPlace: Place? {
        if let overrideID = ongoingPlaceOverrideID,
           let overridePlace = allPlaces.first(where: { $0.placeID == overrideID }) {
            return overridePlace
        }

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

    func clearOngoingStayState() {
        potentialStopStartLocation = nil
        ongoingTitle = nil
        clearOngoingPlaceOverride()
        UserDefaults.standard.removeObject(forKey: "pending_lat")
        UserDefaults.standard.removeObject(forKey: "pending_lng")
        UserDefaults.standard.removeObject(forKey: "pending_time")
        UserDefaults.standard.removeObject(forKey: "pending_title")
    }
    
    // MARK: - 后台保活与自动恢复
    
    /// 确保 Significant Location Monitoring 处于激活状态
    /// 即使 App 被系统终止，该监控也会让系统在用户位置发生显著变化时重新启动 App
    /// 这是 iOS 系统级别的唤醒机制，不依赖 App 是否在运行
    func ensureSignificantMonitoringActive() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways else {
            print("[LocationManager] Cannot start significant monitoring: authorization is \(status.rawValue)")
            return
        }
        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.startMonitoringVisits()
        
        // 确保后台定位配置正确
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        print("[LocationManager] ✅ Significant location monitoring & visit monitoring ensured active.")
    }
    
    /// 请求一次精确定位（用于后台唤醒时让系统知道我们仍需要位置服务）
    func requestSingleLocation() {
        locationManager.requestLocation()
    }
    
    /// 后台恢复时自动回填记录空白（从上一条原始轨迹到现在的间隙）
    /// 当 App 被系统杀死后重新启动时调用，确保不会丢失被杀进程期间的轨迹数据
    func backfillFromLastRecording() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        
        // 检查今日最后一条原始记录的时间
        let todayPoints = RawLocationStore.shared.loadLocations(for: today)
        let lastRecordTime = todayPoints.last?.timestamp ?? today
        let gap = now.timeIntervalSince(lastRecordTime)
        
        // 如果间隙超过 30 分钟，记录一次日志以便调试
        if gap > 30 * 60 {
            print("[LocationManager] ⚠️ Recording gap detected: \(Int(gap/60)) minutes since last point at \(lastRecordTime)")
        }
        
        // 无需手动回填——Significant Location Change 被触发后 didUpdateLocations 会自动写入新点
        // 真正的修复在于确保 Significant Location Monitoring 始终激活
    }
    
    func startTracking() {
        // First check permission and settings
        // Default to true if not explicitly set
        let isEnabled = UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true
        
        guard isEnabled else {
            stopTracking()
            return
        }

        // Prevent automatic system prompt on first launch before user clicks the button
        if locationManager.authorizationStatus == .notDetermined {
            return
        }

        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }

        let now = Date()
        let wasTracking = isTracking
        if wasTracking && now.timeIntervalSince(lastStartTrackingAt) < 30 {
            return
        }
        lastStartTrackingAt = now
        
        // Re-enable updates if they were stopped
        locationManager.startUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        isTracking = true
        
        // Foregrounding can hit this path from onAppear, scenePhase, auth callbacks, and
        // background refresh recovery. Keep the fresh fix, but do not stack requests.
        if !wasTracking || now.timeIntervalSince(lastForegroundLocationRequestAt) > 60 {
            lastForegroundLocationRequestAt = now
            locationManager.requestLocation()
        }
        
        // 启动/回到前台只恢复定位，不重整已保存的时间线。startTracking() 会在
        // 每次启动和 scene active 时调用；在这里清理、合并或回填历史数据会让
        // 首屏先显示旧结果、随后又被异步任务改写。重整仅应由新轨迹处理或用户
        // 主动发起的“重新生成”触发。
    }


    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        HealthManager.shared.stopActivityTracking()
        for region in locationManager.monitoredRegions {
            if region.identifier == "StationaryWakeupRegion" {
                locationManager.stopMonitoring(for: region)
            }
        }
        isTracking = false
        // 清理当前可能的停留状态
        potentialStopStartLocation = nil
        ongoingTitle = nil
        UserDefaults.standard.removeObject(forKey: "pending_lat")
        UserDefaults.standard.removeObject(forKey: "pending_lng")
        UserDefaults.standard.removeObject(forKey: "pending_time")
        clearOngoingPlaceOverride()
    }

    /// 合并数据库中已有的碎片足迹（必须在主线程执行）
    /// 第一步：删除时长 < 5分钟的噪点记录
    /// 第二步：合并间隔 < 30分钟 且 距离 < 200m 的相邻记录
    public func consolidateFootprints(in context: ModelContext, targetDate: Date? = nil) async {
        let mergeTime: TimeInterval = AppConfig.shared.liveStayMergeTimeThreshold
        let mergeDist: CLLocationDistance = AppConfig.shared.liveStayMergeDistanceThreshold
        let minKeepDuration: TimeInterval = AppConfig.shared.liveStayMinDurationThreshold

        let descriptor: FetchDescriptor<Footprint>
        if let target = targetDate {
            let startOfDay = Calendar.current.startOfDay(for: target)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate { $0.statusValue != "ignored" && $0.startTime >= startOfDay && $0.startTime < endOfDay },
                sortBy: [SortDescriptor(\.startTime, order: .forward)]
            )
        } else {
            // 为了性能，自动维护只针对最近 7 天的数据，避免每次全量扫库导致卡顿
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate { $0.statusValue != "ignored" && $0.startTime > sevenDaysAgo },
                sortBy: [SortDescriptor(\.startTime, order: .forward)]
            )
        }
        guard let all = try? context.fetch(descriptor) else { return }

        // ── 第一步：清理噪点（时长 < 5分钟 或 完全重复的记录）──
        var seen = Set<String>()
        for fp in all {
            // 删除时长过短的记录。
            // 用户手动调整时间会将足迹标记为 manual；它同样必须受保护，否则
            // 启动维护会删掉它，随后 gap filling 又会根据原始轨迹重新生成，形成循环。
            let hasUserEdits = fp.isUserModifiedForDailySummary
            guard !hasUserEdits else { continue }

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
            var workingSorted = sorted
            
            // 获取当天的所有交通记录，避免在内层循环中每次查询
            let startOfDay = Calendar.current.startOfDay(for: sorted.first?.startTime ?? Date())
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.startTime < endOfDay && $0.endTime > startOfDay && $0.statusRaw != "ignored"
            })
            let allDayTransports = (try? context.fetch(tpDesc)) ?? []

            var i = 0
            while i < workingSorted.count - 1 {
                let base = workingSorted[i]
                let next = workingSorted[i+1]

                // 自动维护绝不能改写人工确认或编辑过的足迹。它们是用户的
                // 明确时间线边界，合并后会在下次启动的 gap filling 中反复出现。
                guard !base.isUserModifiedForDailySummary,
                      !next.isUserModifiedForDailySummary else {
                    i += 1
                    continue
                }

                // 时间间隔：负数表示重叠，视同可合并
                let timeGap = next.startTime.timeIntervalSince(base.endTime)
                let baseLoc = CLLocation(latitude: base.latitude, longitude: base.longitude)
                let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
                let dist = baseLoc.distance(from: nextLoc)

                // 硬规则：若两段停留之间存在交通记录，则禁止合并，避免“出门回来仍是一条长足迹”。
                let bEnd = base.endTime
                let nStart = next.startTime

                let calendar = Calendar.current
                let baseIsSameDay = calendar.isDate(base.startTime, inSameDayAs: base.endTime.addingTimeInterval(-0.001))
                let nextIsSameDay = calendar.isDate(next.startTime, inSameDayAs: next.endTime.addingTimeInterval(-0.001))
                guard baseIsSameDay, nextIsSameDay, calendar.isDate(base.startTime, inSameDayAs: next.startTime) else {
                    i += 1
                    continue
                }
                
                // 核心修复：避免 SwiftData #Predicate 在 Date 比较时的隐式失败，改为内存中匹配
                let hasTransportBetween = allDayTransports.contains { t in
                    return t.endTime > bEnd && t.startTime < nStart
                }
                
                if hasTransportBetween {
                    i += 1
                    continue
                }

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
        let hasUserEdits = fp.isAddressEditedByHand || !(fp.reason ?? "").isEmpty || !fp.photoAssetIDs.isEmpty || fp.status == .manual
        if hasUserEdits { return }
        
        guard coords.count > 15 else { return } // 略微增加密度要求
        
        var clusters: [(start: Int, end: Int, center: CLLocationCoordinate2D)] = []
        var i = 0
        while i < coords.count {
            var j = i + 1
            while j < coords.count {
                let startLoc = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                let currLoc = CLLocation(latitude: coords[j].latitude, longitude: coords[j].longitude)
                if startLoc.distance(from: currLoc) < min(100.0, AppConfig.shared.mergeDistanceThreshold * 0.8) { // 动态聚类半径
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
                    
                    if currLoc.distance(from: lastLoc) > AppConfig.shared.mergeDistanceThreshold {
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
                let minDuration = AppConfig.shared.stayDurationThreshold
                let splitRanges = distinctClusters.map { cluster -> (start: Date, end: Date, coords: [CLLocationCoordinate2D], duration: TimeInterval) in
                    let subCoords = Array(coords[cluster.start...cluster.end])
                    let sTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.start) / totalPoints))
                    let eTime = baseStart.addingTimeInterval(totalDuration * (Double(cluster.end) / totalPoints))
                    let duration = eTime.timeIntervalSince(sTime)
                    return (sTime, eTime, subCoords, duration)
                }

                // 拆分后的每一段都必须满足最小时长门槛，否则保留原足迹，避免制造 3 分钟碎片。
                guard splitRanges.allSatisfy({ $0.duration >= minDuration }) else {
                    return
                }
                
                // 进行逻辑拆分
                var splitFootprints: [Footprint] = []
                for (idx, segment) in splitRanges.enumerated() {
                    if idx == 0 {
                        fp.footprintLocations = segment.coords
                        fp.startTime = segment.start
                        fp.endTime = segment.end
                        fp.date = Calendar.current.startOfDay(for: segment.start)
                        fp.duration = segment.duration
                        fp.duration = segment.duration
                        fp.locationHash = "SPLIT_FIXED"
                        splitFootprints.append(fp)
                    } else {
                        let newFp = Footprint(
                            date: Calendar.current.startOfDay(for: segment.start),
                            startTime: segment.start,
                            endTime: segment.end,
                            footprintLocations: segment.coords,
                            locationHash: "SPLIT_FIXED",
                            duration: segment.duration,
                            status: fp.status
                        )
                        // Inherit from base
                        newFp.placeID = fp.placeID
                        newFp.address = fp.address
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

    /// 检查今日最新的几个足迹，如果同一地点且时间连续，则合并，以旧的足迹为准，保留用户修改
    @MainActor
    @discardableResult
    public func mergeRecentFootprints(in context: ModelContext) -> Bool {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        let recentCutoff = now.addingTimeInterval(-30 * 60)
        
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        
        guard let todayFps = try? context.fetch(descriptor) else { return false }
        var recentFps = Array(todayFps.filter { $0.endTime >= recentCutoff }.suffix(5))
        guard recentFps.count >= 2 else { return false }
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime < endOfDay && $0.endTime > startOfDay && $0.statusRaw != "ignored"
        })
        let allDayTransports = (try? context.fetch(tpDesc)) ?? []
        
        var didMerge = false
        var i = 0
        while i < recentFps.count - 1 {
            let base = recentFps[i]
            let next = recentFps[i + 1]

            // 与启动时的 consolidateFootprints 保持同一条边界：人工记录
            // 不能由实时合并任务自动删除或延长。
            guard !base.isUserModifiedForDailySummary,
                  !next.isUserModifiedForDailySummary else {
                i += 1
                continue
            }
            
            let bEnd = base.endTime
            let nStart = next.startTime

            let calendar = Calendar.current
            let baseIsSameDay = calendar.isDate(base.startTime, inSameDayAs: base.endTime.addingTimeInterval(-0.001))
            let nextIsSameDay = calendar.isDate(next.startTime, inSameDayAs: next.endTime.addingTimeInterval(-0.001))
            guard baseIsSameDay, nextIsSameDay, calendar.isDate(base.startTime, inSameDayAs: next.startTime) else {
                i += 1
                continue
            }
            
            let hasTransportBetween = allDayTransports.contains { t in
                t.endTime > bEnd && t.startTime < nStart
            }
            
            if hasTransportBetween {
                i += 1
                continue
            }
            
            let timeGap = nStart.timeIntervalSince(bEnd)
            if timeGap > AppConfig.shared.stayMergeGapThreshold {
                i += 1
                continue
            }
            
            var isSamePlace = false
            if let pid = base.placeID, pid == next.placeID {
                isSamePlace = true
            } else {
                let lat1 = base.latitude
                let lon1 = base.longitude
                let lat2 = next.latitude
                let lon2 = next.longitude
                let loc1 = CLLocation(latitude: lat1, longitude: lon1)
                let loc2 = CLLocation(latitude: lat2, longitude: lon2)
                if loc1.distance(from: loc2) < AppConfig.shared.mergeDistanceThreshold {
                    isSamePlace = true
                }
            }
            
            if isSamePlace {
                base.endTime = max(base.endTime, next.endTime)
                base.duration = base.endTime.timeIntervalSince(base.startTime)
                
                var newLocations = base.footprintLocations
                newLocations.append(contentsOf: next.footprintLocations)
                base.footprintLocations = newLocations
                
                var mergedPhotos = base.photoAssetIDs
                for pid in next.photoAssetIDs {
                    if !mergedPhotos.contains(pid) { mergedPhotos.append(pid) }
                }
                base.photoAssetIDs = mergedPhotos
                
                if base.activityTypeValue == nil {
                    base.activityTypeValue = next.activityTypeValue
                }
                
                context.delete(next)
                recentFps.remove(at: i + 1)
                didMerge = true
                // Do not increment i, continue to check next
            } else {
                i += 1
            }
        }
        guard didMerge else { return false }
        try? context.save()
        return true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let rawLocation = locations.last else { return }
        
        // 全局纠正：进入中国境内后，立即将 WGS-84 转换为 GCJ-02
        // 这样后续所有逻辑（足迹存储、地标匹配、UI显示）都统一使用火星坐标系
        let location = rawLocation.gcj02
        
        lastLocation = location
        lastUpdateTime = Date()
        accuracy = location.horizontalAccuracy
        
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            TripLiveActivityManager.shared.updateLiveActivity(location: location, modelContext: self.modelContext)
        }
#endif

        // --- UI 移动状态证据（用于卡片标题稳定显示） ---
        let motion = HealthManager.shared.currentMotionType
        let isMovingBySensor = HealthManager.shared.isMoving
            || motion == .walking
            || motion == .running
            || motion == .cycling
            || motion == .automotive
        let isFreshLocation = abs(location.timestamp.timeIntervalSinceNow) < 30
        let isMovingByGPS = isFreshLocation && location.speed >= 0 && location.speed > 0.5
        updateUIMovementState(isMovingEvidence: (isMovingBySensor || isMovingByGPS), source: "didUpdateLocations")
        
        // --- 核心改进：预先过滤离谱漂移点，防止污染原始轨迹 CSV ---
        if let last = trackingPoints.last {
            let dist = location.distance(from: last)
            let time = abs(location.timestamp.timeIntervalSince(last.timestamp))
            if time > 0 {
                let calcSpeed = dist / time
                
                // 新增：物理不可能的速度直接过滤（如 5秒内 3公里 = 600m/s）
                if calcSpeed > AppConfig.shared.physicalMaxSpeedThreshold {
                    print("Detected impossible jump, skipping point. Speed: \(calcSpeed) m/s")
                    return
                }
                
                // 地铁/隧道环境常见的离谱漂移：精度骤降 (>500m) 且 瞬间位移巨大 (>2km) 且 速度不合理 (>80m/s)
                // 降低判定门槛：只要速度超过 60m/s (216km/h) 且精度不佳，就视为漂移
                let isRidiculous = (location.horizontalAccuracy > 400 && dist > 1500) || (calcSpeed > 60.0 && location.horizontalAccuracy > 80)
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
        let speed = max(0, location.speed)
        
        // 判定是否正在长久停留
        // 我们将其放宽到 150m (从 300m 下调)，并增加已知地点粘性
        let isStationary: Bool = {
            // ✅ 出门保护期：任何 boost 触发后 3 分钟内，强制维持高频模式
            // 防止 GPS/传感器还未稳定时，节能逻辑过早将精度降回低频
            if Date() < departureBoostEndTime {
                return false
            }
            
            // ✅ 核心修复：移动锁定 — 只要 UI 层判定为"正在移动"（带 120 秒滞回），
            // 就强制维持高频记录，绝不降频！这是防止走路时丢点的最关键保护。
            // 实现用户要求："一旦侦测到移动,就要一直详细记,直到停留时间足够生成足迹"
            if uiIsMoving {
                return false
            }
            
            guard let startLoc = potentialStopStartLocation else { return false }
            let duration = Date().timeIntervalSince(startLoc.timestamp)
            let distance = location.distance(from: startLoc)
            
            // C: 运动状态锁（优先级最高）- 如果传感器检测到正在步行/跑步/骑行，
            // 哪怕 GPS 位移没跟上，也要维持高频记录（传感器比 GPS 快）
            let motion = HealthManager.shared.currentMotionType
            if motion == .walking || motion == .running || motion == .cycling || motion == .automotive {
                return false
            }
            
            // A: 通用逻辑 - 5分钟以上且位移在 150m 内 (应对室内漂移)
            if duration > 300 && distance < 150.0 { return true }
            
            // B: 地点粘性 - 如果在已知地点范围内已超过 1 分钟，且当前速度极低，则提前进入节能
            if let p = place, duration > 60 && distance < Double(p.radius) + 80.0 && speed < 1.0 {
                return true
            }
            
            return false
        }()
        
        let modeRaw = UserDefaults.standard.string(forKey: LocationAccuracyMode.userDefaultsKey) ?? LocationAccuracyMode.automatic.rawValue
        let currentMode = LocationAccuracyMode(rawValue: modeRaw) ?? .automatic
        
        if currentMode == .automatic {
            if let p = place, p.isIgnored {
                // 已忽略地点也必须保留较密的原始轨迹，否则从家/公司出门会丢掉开头几百米，只是不生成该地点足迹。
                if manager.desiredAccuracy != kCLLocationAccuracyNearestTenMeters || manager.distanceFilter != 10.0 || manager.activityType != .fitness {
                    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                    manager.distanceFilter = 10.0
                    manager.activityType = .fitness // ⚠️ 不用 .other — iOS 会极度压缩更新频率
                }
                updateRegionMonitoring(isStationary: true)
            } else if isStationary {
                // 真正停留了：进入节能模式
                if manager.desiredAccuracy != kCLLocationAccuracyBest || manager.distanceFilter != 5.0 || manager.activityType != .fitness {
                    manager.desiredAccuracy = kCLLocationAccuracyBest
                    // 停留时仍保持 5m 标准更新，确保步行离开时一开始就有点，而不是几百米后才开始。
                    manager.distanceFilter = 5.0
                    manager.activityType = .fitness // ⚠️ 不用 .other — iOS 会极度压缩更新频率
                }
                updateRegionMonitoring(isStationary: true)
            } else {
                // 自动采集增强：只要在移动（不论是步行、骑行还是开车）
                // 开启增强采样，确保不漏点
                let motion = HealthManager.shared.currentMotionType
                let isMovingBySensor = motion == .walking || motion == .running || motion == .cycling || motion == .automotive
                
                // 高速驾驶也使用 fitness 模式，避免 automotiveNavigation 导致后台被系统强制降频或挂起
                if motion == .automotive || speed > 15.0 {
                    if manager.desiredAccuracy != kCLLocationAccuracyBest || manager.distanceFilter != 10.0 || manager.activityType != .fitness {
                        manager.desiredAccuracy = kCLLocationAccuracyBest
                        manager.distanceFilter = 10.0
                        manager.activityType = .fitness
                    }
                // 只要传感器认为在动，或者速度 > 0.5m/s
                } else if isMovingBySensor || speed > 0.5 {
                    let targetAccuracy = kCLLocationAccuracyBest
                    if manager.desiredAccuracy != targetAccuracy || manager.distanceFilter != kCLDistanceFilterNone || manager.activityType != .fitness {
                        manager.desiredAccuracy = targetAccuracy
                        manager.distanceFilter = kCLDistanceFilterNone
                        manager.activityType = .fitness
                    }
                }
                updateRegionMonitoring(isStationary: false)
            }
        } else {
            // 如果不是自动模式，就仅仅更新唤醒区域，不改变精度（精度在 applyLocationAccuracyMode 中已经设置好）
            updateRegionMonitoring(isStationary: isStationary)
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
                    let name = self?.coarseAutomaticPlaceName(from: placemark) ?? "未知位置"

                    DispatchQueue.main.async {
                        self?.currentAddress = name
                    }
                }
            }
        }
        
        // 1. 永久保存原始点（RawLocationStore 内部已实现异步队列写入，不会阻塞主线程）
        RawLocationStore.shared.saveLocation(location)
        scheduleLiveFootprintMerge()
        // 同步最后位置给小组件
        let sharedDefaults = widgetSharedDefaults()
        sharedDefaults.set(location.coordinate.latitude, forKey: "lastLat")
        sharedDefaults.set(location.coordinate.longitude, forKey: "lastLon")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "lastLocationTime")

        // 提醒小组件更新位置
        Task { await WidgetDataSyncManager.shared.syncTodayOnly() }
        
        // 同步今日地图显示区域给小组件
        self.updateSharedWidgetRegion()
        
        let preferredID = RawLocationStore.shared.preferredRecordingDeviceID()
        let isPrimary = preferredID.isEmpty || preferredID == RawLocationStore.shared.currentDeviceIdentifier
        
        if isPrimary {
            // 2. 更新内存数据并处理足迹分析
            self.updateTodayTotalPoints()
            self.allTodayPoints.append(location)
            
            // 处理候选足迹逻辑
            var unclassifiedQueue = self.trackingPoints.filter {
                $0.timestamp > (self.lastProcessedTimestamp ?? .distantPast) &&
                $0.timestamp < location.timestamp
            }
            if let candidate = self.footprintProcessor.processNewLocation(location, queue: &unclassifiedQueue) {
                self.handleNewCandidateFootprint(candidate)
            }
            self.trackingPoints.append(location)
        
            // 3. 更新当前停留状态用于 UI 显示
            if let startLoc = potentialStopStartLocation {
                // 改进：增加地点粘性。如果当前位置依然匹配到与起始点相同的“重要地点”，则不应判定为离开并重置停留时间。
                let startPlace = matchedPlaceFor(coordinate: startLoc.coordinate)
                let currentPlace = matchedPlaceFor(coordinate: location.coordinate)
                
                // 判定是否离开：
                // A: 如果有匹配地点，且地点 ID 变了，判定为离开
                // B: 如果没有匹配地点，且位移超过 150m，且精度尚可，判定为离开（放宽到 150m 减少因室内飘移导致的停留时刻重置）
                let isSamePlace = (startPlace != nil && startPlace?.placeID == currentPlace?.placeID)
                if hasConfirmedDeparture(from: startLoc, to: location, isSamePlace: isSamePlace, isMovingBySensor: isMovingBySensor) {
                    // 已经离开当前地点，设为空以表示正在移动中
                    potentialStopStartLocation = nil
                    clearOngoingPlaceOverride()
                    savePotentialStop()
                    ongoingTitle = nil
                    saveOngoingTitle()
                }
            } else {
                // 目前没有记录停留起点（正在移动中）
                // 只有当确定没有明显移动证据时（uiIsMoving = false），才将其设为新的停留起点
                if !uiIsMoving {
                    potentialStopStartLocation = location
                    clearOngoingPlaceOverride()
                    savePotentialStop()
                    ongoingTitle = nil
                    saveOngoingTitle()
                }
            }
            
            // 4. 触发正在持续停留的 AI 分析 (停留 10 分钟后触发第一次，之后每 60 分钟刷新)
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
        
        // --- 10 AM 往年今日检查 ---
        checkDailyPastMemories()
    }

    private func hasConfirmedDeparture(
        from startLoc: CLLocation,
        to location: CLLocation,
        isSamePlace: Bool,
        isMovingBySensor: Bool
    ) -> Bool {
        guard !isSamePlace else { return false }
        guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100.0 else { return false }

        let distance = location.distance(from: startLoc)
        guard distance > 150.0 else { return false }

        // 长时间宅家/办公后，启动时常会先收到一个单点 GPS 漂移。没有运动证据时不要仅凭
        // 150m 左右的单点位移清空当前停留，否则首页会短暂或持续显示“正在移动”。
        let stayDuration = Date().timeIntervalSince(startLoc.timestamp)
        if stayDuration > 30 * 60 && !isMovingBySensor {
            let driftResistantThreshold = max(300.0, location.horizontalAccuracy * 3.0)
            return distance > driftResistantThreshold
        }

        return true
    }
    
    private func checkDailyPastMemories() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        
        // 只有在 10 点之后才检查
        guard hour >= 10 else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: now)
        
        // 检查今天是否已经运行过
        let lastCheck = UserDefaults.standard.string(forKey: "lastPastMemoriesCheckDate")
        guard lastCheck != dateString else { return }
        
        // 立即标记为已检查，防止并发 location updates 触发多次
        UserDefaults.standard.set(dateString, forKey: "lastPastMemoriesCheckDate")
        
        // 检查设置是否开启
        guard UserDefaults.standard.bool(forKey: "isPastMemoriesNotificationEnabled") else { return }
        
        Task { @MainActor in
            await sendPastMemoriesNotificationIfAvailable(for: now)
        }
    }
    
    private func sendPastMemoriesNotificationIfAvailable(for date: Date) async {
        guard let context = modelContext else { return }
        let calendar = Calendar.current
        
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let currentYear = calendar.component(.year, from: date)
        
        // 查找往年今日的足迹 (排除今年)
        let descriptor = FetchDescriptor<Footprint>()
        let allFootprints = (try? context.fetch(descriptor)) ?? []
        
        // 过滤往年今日
        let pastFootprints = allFootprints.filter { fp in
            let fpYear = calendar.component(.year, from: fp.startTime)
            let fpMonth = calendar.component(.month, from: fp.startTime)
            let fpDay = calendar.component(.day, from: fp.startTime)
            
            if fp.placeID == nil || (fp.activityTypeValue ?? "").isEmpty {
                return false
            }
            
            return fpYear < currentYear && fpMonth == month && fpDay == day
        }
        
        guard !pastFootprints.isEmpty else { return }
        
        // 排除重要地点 (isPriority = true)
        // 获取所有重要地点的 ID
        let placeDescriptor = FetchDescriptor<Place>(predicate: #Predicate<Place> { $0.isPriority })
        let importantPlaceIDs = Set((try? context.fetch(placeDescriptor))?.map { $0.placeID } ?? [])
        
        let filteredFootprints = pastFootprints.filter { fp in
            if let pid = fp.placeID, importantPlaceIDs.contains(pid) {
                return false
            }
            return true
        }.sorted { $0.startTime < $1.startTime }
        
        guard let highlight = filteredFootprints.first else { return }
        
        let fpYear = calendar.component(.year, from: highlight.startTime)
        let yearsAgo = currentYear - fpYear
        let placeName = highlight.address ?? "某个地方"
        
        let title = "往年今日 · \(yearsAgo)年前"
        let body = "在 \(fpYear) 年的今天，你去了「\(placeName)」。点此重温那段时光。"
        
        NotificationManager.shared.sendHighlightNotification(
            title: title,
            body: body,
            footprintID: nil, // 点开通知只要跳到那一天即可,不用打开足迹详情
            date: highlight.startTime
        )
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
                    context.delete(fp)
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
        if authStatus == .authorizedAlways {
            ensureSignificantMonitoringActive()
            if UserDefaults.standard.object(forKey: "isTrackingEnabled") as? Bool ?? true {
                startTracking()
            }
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        let motion = HealthManager.shared.currentMotionType
        let isMovingBySensor = HealthManager.shared.isMoving
            || motion == .walking
            || motion == .running
            || motion == .cycling
            || motion == .automotive

        print("[LocationManager] ⏸️ Location updates paused by system. isTracking=\(isTracking) moving=\(isMovingBySensor)")
        guard isTracking, isMovingBySensor else { return }
        
        if Date().timeIntervalSince(lastRecoveryBoostTime) < 60 {
            return
        }
        lastRecoveryBoostTime = Date()

        // Best-effort recovery: restart high-accuracy updates and keep Significant Monitoring alive.
        ensureSignificantMonitoringActive()
        forceHighAccuracyBoost()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        print("[LocationManager] ▶️ Location updates resumed by system.")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error.localizedDescription)")
    }
    
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // 核心唤醒逻辑：只要检测到“离开”某个地方，立即拉高精度，不等 GPS 位移
        if visit.departureDate != Date.distantFuture {
            print("🚀 Visit departure detected! Waking up GPS immediately...")
            // 后台唤醒路径：确保运动传感器也重新启动（系统可能已将其暂停）
            HealthManager.shared.stopActivityTracking()
            HealthManager.shared.startActivityTracking()
            forceHighAccuracyBoost()
        }
    }
    
    // MARK: - Region Monitoring for Immediate Wakeup
    
    func applyLocationAccuracyMode() {
        let modeRaw = UserDefaults.standard.string(forKey: LocationAccuracyMode.userDefaultsKey) ?? LocationAccuracyMode.automatic.rawValue
        let mode = LocationAccuracyMode(rawValue: modeRaw) ?? .automatic
        
        switch mode {
        case .automatic:
            // 自动模式下，根据当前状态重新评估
            // 我们通过重置相关状态变量，迫使 runLocationWatchdog 或 updateRegionMonitoring 生效
            // 简单起见，强制触发一次 location update 逻辑
            locationManager.startUpdatingLocation()
        case .high:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.activityType = .fitness
        case .balanced:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10.0
            locationManager.activityType = .fitness
        case .powerSaving:
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 50.0
            locationManager.activityType = .other
        }
        print("[LocationManager] Applied LocationAccuracyMode: \(mode.rawValue)")
    }

    private func updateRegionMonitoring(isStationary: Bool) {
        let identifier = "StationaryWakeupRegion"
        
        if isStationary {
            guard let center = potentialStopStartLocation?.coordinate else { return }
            
            // 检查是否已经存在该区域，并且中心点没有发生大的变化
            if let existingRegion = locationManager.monitoredRegions.first(where: { $0.identifier == identifier }) as? CLCircularRegion {
                let existingLocation = CLLocation(latitude: existingRegion.center.latitude, longitude: existingRegion.center.longitude)
                let newLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if newLocation.distance(from: existingLocation) < 50.0 {
                    return // 已经有一个相近的区域在监控，不需要重新启动
                } else {
                    locationManager.stopMonitoring(for: existingRegion)
                }
            }
            
            // 使用较小半径尽早触发唤醒；标准定位仍是主通道，围栏只是后台兜底。
            // 配合 Visit Monitoring 和 NWPathMonitor，实现三重保险
            let radius: CLLocationDistance = 75.0
            let region = CLCircularRegion(center: center, radius: radius, identifier: identifier)
            region.notifyOnEntry = false
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
        } else {
            // 移动中，清除地理围栏
            if let existingRegion = locationManager.monitoredRegions.first(where: { $0.identifier == identifier }) {
                locationManager.stopMonitoring(for: existingRegion)
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if region.identifier == "StationaryWakeupRegion" {
            print("🚧 Exited stationary region! Waking up GPS immediately...")
            // 统一通过 forceHighAccuracyBoost 处理，确保出门保护期和传感器重启一并执行
            HealthManager.shared.stopActivityTracking()
            HealthManager.shared.startActivityTracking()
            forceHighAccuracyBoost()
            
            // 移除监听（已移动，围栅失效）
            manager.stopMonitoring(for: region)
        }
    }
    
    private func analyzeOngoingStay(at location: CLLocation) {
        guard let startLoc = potentialStopStartLocation else { return }
        let place = matchedPlace
        
        // Set title immediately based on location instead of calling AI
        self.isAnalyzingOngoing = false
        self.ongoingTitle = place?.name ?? currentAddress
        self.saveOngoingTitle()
        self.triggerNotificationSummaryRefresh()
        
        // --- 核心改进：新足迹与久违提醒 ---
        // 如果该停留点的起始时间没有被通知过，则进行新旧地点的判定
        if lastNotifiedStayStart != startLoc.timestamp {
            checkAndSendNewPlaceNotification(at: location, startTime: startLoc.timestamp, place: place)
            lastNotifiedStayStart = startLoc.timestamp
        }
    }
    
    private func checkAndSendNewPlaceNotification(at location: CLLocation, startTime: Date, place: Place?) {
        guard let context = modelContext else { return }
        
        // 判定规则：
        // 1. 新地方：历史上从未在该地点（或周边 200m）有过足迹
        // 2. 很久没来：上一次来是 30 天以前
        
        // 由于 SwiftData Predicate 不支持计算属性 (latitude/longitude)，我们在此使用内存过滤
        // 对于几千条记录，性能是可以接受的
        let descriptor = FetchDescriptor<Footprint>()
        let allFootprints = (try? context.fetch(descriptor)) ?? []
        
        let history = allFootprints.filter { fp in
            // 排除当前及之后的（以防万一）
            if fp.startTime >= startTime { return false }
            
            // 如果有匹配地点，优先按地点 ID 匹配
            if let pid = place?.placeID, fp.placeID == pid {
                return true
            }
            
            // 否则按距离匹配 (200m 范围内视为同一地点)
            let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
            return location.distance(from: fpLoc) < 200
        }.sorted { $0.startTime > $1.startTime }
        
        var isNewPlace = false
        var isLongTimeNoSee = false
        var lastVisitDate: Date? = nil
        var notificationDate = startTime
        
        if let last = history.first {
            lastVisitDate = last.startTime
            notificationDate = last.startTime
            let days = Calendar.current.dateComponents([.day], from: lastVisitDate!, to: startTime).day ?? 0
            if days >= 365 {
                isLongTimeNoSee = true
            }
        } else {
            isNewPlace = true
        }
        
        if isNewPlace || isLongTimeNoSee {
            let placeName = place?.name ?? currentAddress
            let title = isNewPlace ? "发现新地方" : "久违了"
            let body: String
            if isNewPlace {
                body = "你第一次在「\(placeName)」留下足迹，开启一段新回忆吧。"
            } else {
                let days = Calendar.current.dateComponents([.day], from: lastVisitDate!, to: startTime).day ?? 0
                let absenceDuration = formatLongAbsenceDuration(days: days)
                body = "你已经有 \(absenceDuration) 没来「\(placeName)」了，欢迎回来。"
            }
            
            NotificationManager.shared.sendHighlightNotification(
                title: title,
                body: body,
                date: notificationDate
            )
        }
    }

    private func formatLongAbsenceDuration(days: Int) -> String {
        guard days >= 365 else {
            return "\(days) 天"
        }

        let years = days / 365
        let remainingDays = days % 365
        return remainingDays >= 30 ? "\(years) 年多" : "\(years) 年"
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
         
         // 第一波：优先寻找重要地点，匹配门槛放宽至 radius + 150m 以应对 GPS 漂移
         let importantMatches = allPlaces.filter { place in
             guard place.isUserDefined && !place.isIgnored else { return false }
             let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
             let distance = loc.distance(from: placeLocation)
             return distance <= Double(place.radius) + 150.0
         }.sorted { p1, p2 in
             let d1 = loc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
             let d2 = loc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
             return d1 < d2
         }
         
         if let bestImportant = importantMatches.first {
             return bestImportant
         }
         
         // 第二波：普通地点，半径门槛从严 (radius + 50m)
         let otherMatches = allPlaces.filter { place in
             guard !place.isUserDefined && !place.isIgnored else { return false }
             let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
             let distance = loc.distance(from: placeLocation)
             return distance <= Double(place.radius) + 50.0
         }.sorted { p1, p2 in
             // 在普通地点中，依然可以考虑 isPriority 权重
             if p1.isPriority != p2.isPriority { return p1.isPriority }
             let d1 = loc.distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
             let d2 = loc.distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
             return d1 < d2
         }
         
         return otherMatches.first
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

    func suggestFrequentActivityType(for placeID: UUID, at time: Date) -> String? {
        guard let context = modelContext else { return nil }
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
            var footprintsToAnalyze: [UUID] = []
            
            for fp in footprints {
                // 1. 自动关联活动类型 (仅补齐缺失的，且跳过人工修改过的)
                if fp.activityTypeValue == nil && fp.statusValue != "manual" {
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
                if !fp.aiAnalyzed && !fp.isAddressEditedByHand {
                    footprintsToAnalyze.append(fp.footprintID)
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

        // 硬约束：单条足迹不能跨天，限制在 startOfDay...nextDay(0:00) 内。
        let boundedDayStart = Calendar.current.startOfDay(for: candidate.startTime)
        let boundedDayEnd = boundedDayStart.addingTimeInterval(86400)
        let boundedStart = max(candidate.startTime, boundedDayStart)
        let boundedEnd = min(max(candidate.endTime, boundedStart), boundedDayEnd)
        guard boundedEnd > boundedStart else { return }

        let boundedRawLocations = candidate.rawLocations.filter {
            $0.timestamp >= boundedStart && $0.timestamp <= boundedEnd
        }
        let effectiveRawLocations = boundedRawLocations.isEmpty ? candidate.rawLocations : boundedRawLocations
        let effectiveCenterCoordinate = FootprintProcessor.shared.calculateCenter(effectiveRawLocations)
        let boundedCandidate = CandidateFootprint(
            startTime: boundedStart,
            endTime: boundedEnd,
            centerCoordinate: effectiveCenterCoordinate,
            duration: boundedEnd.timeIntervalSince(boundedStart),
            rawLocations: effectiveRawLocations
        )
        
        let matchedPlace = self.matchedPlaceFor(coordinate: boundedCandidate.centerCoordinate)
        let effectivePlace = ongoingPlaceOverrideID.flatMap { overrideID in
            allPlaces.first(where: { $0.placeID == overrideID })
        } ?? matchedPlace

        // 检查是否需要合并之前的记录
        let targetStart = Calendar.current.startOfDay(for: boundedCandidate.startTime)
        let targetEnd = targetStart.addingTimeInterval(86400)
        
        var fetchDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= targetStart && $0.startTime < targetEnd },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = 1
        
        let existingFootprints = try? context.fetch(fetchDescriptor)
        if let last = existingFootprints?.first,
           shouldMergeExistingFootprint(last, with: boundedCandidate, matchedPlace: effectivePlace) {
            // 合并逻辑：确保时间范围正确延伸，不重复生成重叠记录
            let oldEndTime = last.endTime
            let oldStartTime = last.startTime
            
            last.endTime = min(max(last.endTime, boundedCandidate.endTime), targetEnd)
            last.startTime = max(min(last.startTime, boundedCandidate.startTime), targetStart)
            last.date = Calendar.current.startOfDay(for: last.startTime)
            
            // 仅在有明显新轨迹或时间延伸时追加坐标，避免无限堆积重叠坐标
            if last.endTime > oldEndTime || last.startTime < oldStartTime {
                var currentPath = last.footprintLocations
                currentPath.append(contentsOf: boundedCandidate.rawLocations.map { $0.coordinate })
                last.footprintLocations = currentPath
            }
            
            // 重新匹配地点（以防合并过程中位置偏移导致匹配变化）
            if let mPlace = effectivePlace {
                if last.placeID != mPlace.placeID {
                    last.placeID = mPlace.placeID
                }
                if last.isAddressEditedByHand || ongoingPlaceOverrideID == mPlace.placeID || (last.address ?? "").isEmpty {
                    last.address = ongoingPlaceOverrideAddress ?? mPlace.name
                    last.isAddressEditedByHand = last.isAddressEditedByHand || ongoingPlaceOverrideID == mPlace.placeID
                }
            }
            
            if !isHistorical {
                analyzeFootprint(last, context: context)
            }
        } else {
            // 创建新足迹。重要的：日期应归于足迹开始的那一天，而非生成时的这一秒
            let newFootprint = Footprint(
                date: Calendar.current.startOfDay(for: boundedCandidate.startTime),
                startTime: boundedCandidate.startTime,
                endTime: boundedCandidate.endTime,
                footprintLocations: boundedCandidate.rawLocations.map { $0.coordinate },
                locationHash: "TBD",
                duration: boundedCandidate.duration,
                status: .confirmed,
                address: (isHistorical || currentAddress == "正在解析位置..." || currentAddress == "未知位置") ? nil : currentAddress
            )
            
            if let mPlace = effectivePlace {
                let pid = mPlace.placeID
                newFootprint.placeID = pid
                newFootprint.isAddressEditedByHand = ongoingPlaceOverrideID == pid
                
                // --- 自动关联习惯活动类型 ---
                // 只有同一地点、同一时间段出现过3次以上才关联
                newFootprint.activityTypeValue = self.findFrequentActivityType(for: pid, at: boundedCandidate.startTime, context: context)
                
                // Address 优先使用地点名称，解决“标题对地点(地址)不对”的问题
                newFootprint.address = ongoingPlaceOverrideAddress ?? mPlace.name
                
                // Title uses the custom name (User preference: "Title uses name")
                
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
                clearOngoingPlaceOverride()
            }
        }
        
        try? context.save()

        if !isHistorical {
            let syncDate = Calendar.current.startOfDay(for: boundedCandidate.startTime)
            Task { @MainActor in
                await PersistentTimelineBuilder.syncDay(date: syncDate, in: context)
                NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            }
        }

        triggerNotificationSummaryRefresh()
    }

    private func shouldMergeExistingFootprint(_ last: Footprint, with candidate: CandidateFootprint, matchedPlace: Place?) -> Bool {
        if let placeID = matchedPlace?.placeID, last.placeID == placeID {
            let timeGap = candidate.startTime.timeIntervalSince(last.endTime)
            return timeGap < max(AppConfig.shared.liveStayMergeTimeThreshold, AppConfig.shared.samePlaceMergeGapThreshold)
        }
        return FootprintProcessor.shared.shouldMerge(lastFootprint: last, newCandidate: candidate)
    }

    func analyzeFootprintByID(_ id: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
        guard let footprint = try? context.fetch(descriptor).first else { return }
        analyzeFootprint(footprint, context: context)
    }

    func linkPhotos(to footprint: Footprint, context: ModelContext) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        
        // 核心修复：即使照片在本地有效，如果缺失云端元数据（导致无法同步），也必须继续执行以补全元数据。
        if !footprint.photoAssetIDs.isEmpty && PhotoService.shared.validateAssetIDs(footprint.photoAssetIDs) {
            let hasMetadataForAll = footprint.photoAssetIDs.allSatisfy { id in
                footprint.photoMetadata.contains(where: { $0.localIdentifier == id && $0.cloudIdentifier != nil })
            }
            if hasMetadataForAll {
                return 
            }
        }
        
        // 核心修复：必须有 context 才能访问 persistentModelID 并在主线程恢复，否则说明是 UI Lite 对象
        guard footprint.modelContext != nil else { return }
        
        let id = footprint.footprintID
        let startTime = footprint.startTime
        let endTime = footprint.endTime
        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        
        PhotoService.shared.fetchAssets(
            startTime: startTime,
            endTime: endTime,
            near: coordinate,
            maxDistance: AppConfig.shared.photoLinkingMaxDistance
        ) { assets in
            let autoIDs = assets.map { $0.localIdentifier }
            
            Task {
                // 强制触发一次 CloudKit 数据拉取脉冲
                CloudSettingsManager.shared.triggerDataSyncPulse()
                
                // 先在主线程获取当前状态
                let (currentIDs, currentMetadata): ([String], [PhotoMetadata]) = await MainActor.run {
                    let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
                    guard let fp = try? context.fetch(descriptor).first else { return ([], []) }
                    return (fp.photoAssetIDs, fp.photoMetadata)
                }
                
                if currentIDs.isEmpty && autoIDs.isEmpty { return }
                
                var workingIDs = currentIDs
                var workingMetadata = currentMetadata
                var hasChanged = false
                
                // 1. 同步本地 -> 云端 (后台执行)
                let idsMissingCloud = workingIDs.filter { id in
                    !workingMetadata.contains(where: { $0.localIdentifier == id && $0.cloudIdentifier != nil })
                }
                if !idsMissingCloud.isEmpty {
                    let mappings = await PhotoService.shared.getCloudIdentifiers(for: idsMissingCloud)
                    for (localID, cloudID) in mappings {
                        if let idx = workingMetadata.firstIndex(where: { $0.localIdentifier == localID }) {
                            workingMetadata[idx].cloudIdentifier = cloudID
                        } else {
                            workingMetadata.append(PhotoMetadata(localIdentifier: localID, cloudIdentifier: cloudID))
                        }
                        hasChanged = true
                    }
                }
                
                // 2. 同步云端 -> 本地 (后台执行)
                let invalidLocalWithCloud = workingMetadata.filter { meta in
                    meta.cloudIdentifier != nil && !PhotoService.shared.validateAssetIDs([meta.localIdentifier])
                }
                
                if !invalidLocalWithCloud.isEmpty {
                    let cloudIDs = invalidLocalWithCloud.compactMap { $0.cloudIdentifier }
                    let mappings = await PhotoService.shared.getLocalIdentifiers(for: cloudIDs)
                    for (cloudID, localID) in mappings {
                        if let meta = invalidLocalWithCloud.first(where: { $0.cloudIdentifier == cloudID }) {
                            let oldID = meta.localIdentifier
                            if let idx = workingIDs.firstIndex(of: oldID) {
                                workingIDs[idx] = localID
                            } else {
                                workingIDs.append(localID)
                            }
                            if let metaIdx = workingMetadata.firstIndex(where: { $0.localIdentifier == oldID }) {
                                workingMetadata[metaIdx].localIdentifier = localID
                            }
                            hasChanged = true
                            print("[\(Date())] PhotoLinker: Resolved cloud ID \(cloudID) to local ID \(localID)")
                        }
                    }
                }
                
                // 3. 自动关联补充与基于云端 ID 的去重
                var newFoundIDs: [String] = []
                if !autoIDs.isEmpty {
                    // 获取扫描到的照片的云端 ID
                    let autoMappings = await PhotoService.shared.getCloudIdentifiers(for: autoIDs)
                    
                    for (localID, cloudID) in autoMappings {
                        // 检查这个云端 ID 是否已经存在于我们的元数据中（即使本地 ID 不同）
                        if let existingMetaIdx = workingMetadata.firstIndex(where: { $0.cloudIdentifier == cloudID }) {
                            let oldLocalID = workingMetadata[existingMetaIdx].localIdentifier
                            if oldLocalID != localID {
                                // 找到了匹配！将旧的无效 ID 替换为新的有效本地 ID
                                if let idIdx = workingIDs.firstIndex(of: oldLocalID) {
                                    workingIDs[idIdx] = localID
                                }
                                workingMetadata[existingMetaIdx].localIdentifier = localID
                                hasChanged = true
                                print("[\(Date())] PhotoLinker: Scanned photo \(localID) matches existing cloud ID \(cloudID). Updated local reference.")
                            }
                        } else {
                            // 这是一个全新的照片
                            newFoundIDs.append(localID)
                        }
                    }
                }
                
                // 合并剩余的真正新发现的 ID
                if !newFoundIDs.isEmpty {
                    let combinedIDs = NSMutableOrderedSet(array: workingIDs)
                    combinedIDs.addObjects(from: newFoundIDs)
                    let newMergedIDs = combinedIDs.array as? [String] ?? workingIDs
                    
                    if newMergedIDs != workingIDs {
                        workingIDs = newMergedIDs
                        hasChanged = true
                        
                        // 为新发现的 ID 补充元数据
                        let autoMappings = await PhotoService.shared.getCloudIdentifiers(for: newFoundIDs)
                        for (localID, cloudID) in autoMappings {
                            workingMetadata.append(PhotoMetadata(localIdentifier: localID, cloudIdentifier: cloudID))
                        }
                    }
                }
                
                // 3.5 清理仍然无效且没有云端 ID 的残留 ID（可选，增加鲁棒性）
                // 如果一个 ID 既不能在本地找到，又没有云端 ID 记录，且我们已经有了其他有效的扫描结果，可以考虑清理它。
                // 但为了安全，目前先保留，仅靠上面的替换逻辑解决占位符优先问题。
                
                // 4. 回写主线程
                if hasChanged {
                    await MainActor.run {
                        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
                        if let fp = try? context.fetch(descriptor).first {
                            fp.photoAssetIDs = workingIDs
                            fp.photoMetadata = workingMetadata
                            try? context.save()
                            print("[\(Date())] PhotoLinker: Finished CloudID sync and auto-link for \(id)")
                        }
                    }
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
        // 不再调用 AI，仅尝试通过本地已存地点或反地理编码来校准地址
        if !footprint.isAddressEditedByHand {
            let fpCoord = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            if let matchedPOI = matchedPlaceFor(coordinate: fpCoord) {
                // 1. 优先使用本地已匹配的地点
                footprint.address = matchedPOI.name
            } else if (footprint.address ?? "").isEmpty || footprint.address == "地点记录" || footprint.address == "正在解析位置..." || footprint.address == "此处" {
                // 2. 如果没有匹配地点，且地址是通用的，则尝试反地理编码
                let location = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
                let footprintID = footprint.footprintID
                
                geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
                    guard let self = self, let placemark = placemarks?.first else { return }
                    let name = self.coarseAutomaticPlaceName(from: placemark) ?? "未知位置"
                    
                    Task { @MainActor in
                        // 在主线程重新获取该对象，确保线程安全
                        if let mainContext = self.modelContext?.container.mainContext {
                            let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == footprintID })
                            if let mainFp = try? mainContext.fetch(descriptor).first {
                                mainFp.address = name
                                try? mainContext.save()
                            }
                        }
                    }
                }
            }
        }

        footprint.aiAnalyzed = true
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
        let footprintCount = Set(validFootprints.map { fp -> String in
            if let addr = fp.address, !addr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return addr
            }
            return fp.locationHash
        }).count
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.startTime >= targetDate && $0.startTime < tomorrowStart && $0.statusRaw == "active" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        let todayTransports = (try? context.fetch(transportDescriptor)) ?? []
        
        // Calculate points and mileage using TimelineBuilder logic
        Task.detached(priority: .background) {
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
            
            let transportDistance = todayTransports.reduce(0.0) { $0 + ($1.distance > 0 ? $1.distance : 0) }
            var inferredFootprintDistance: Double = 0
            let fpCoords = validFootprints.sorted { $0.startTime < $1.startTime }
            if fpCoords.count >= 2 {
                for i in 0..<fpCoords.count - 1 {
                    let loc1 = CLLocation(latitude: fpCoords[i].latitude, longitude: fpCoords[i].longitude)
                    let loc2 = CLLocation(latitude: fpCoords[i+1].latitude, longitude: fpCoords[i+1].longitude)
                    inferredFootprintDistance += loc1.distance(from: loc2)
                }
            }
            let mileage = max(transportDistance, inferredFootprintDistance)

            let resolvedOverview: String?
            if !validFootprints.isEmpty || !todayTransports.isEmpty {
                resolvedOverview = await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        OpenAIService.shared.currentDailyOverviewSummary(
                            for: targetDate,
                            footprints: validFootprints,
                            transports: todayTransports
                        ) { summary in
                            continuation.resume(returning: summary)
                        }
                    }
                }
            } else {
                resolvedOverview = nil
            }

            await MainActor.run {
                NotificationManager.shared.refreshDailySummary(
                    footprintCount: footprintCount,
                    pointsCount: rawPoints.count,
                    mileage: mileage,
                    overviewSummary: resolvedOverview
                )

                Task { await WidgetDataSyncManager.shared.syncTodayOnly() }
                self.updateSharedWidgetRegion()
            }
        }
    }
    
    /// 同步今日所有点位的包围盒给小组件，避免小组件去读 CSV 导致超时
    private func updateSharedWidgetRegion() {
        let sharedDefaults = widgetSharedDefaults()
        
        let allCoords = self.allTodayPoints.map { $0.coordinate }
        guard !allCoords.isEmpty else { return }
        
        var minLat = allCoords[0].latitude
        var maxLat = allCoords[0].latitude
        var minLon = allCoords[0].longitude
        var maxLon = allCoords[0].longitude
        
        for p in allCoords {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        
        let latDelta = max(0.005, (maxLat - minLat) * 1.4)
        let lonDelta = max(0.005, (maxLon - minLon) * 1.4)
        
        sharedDefaults.set((minLat + maxLat) / 2, forKey: "widgetRegionCenterLat")
        sharedDefaults.set((minLon + maxLon) / 2, forKey: "widgetRegionCenterLon")
        sharedDefaults.set(latDelta, forKey: "widgetRegionLatDelta")
        sharedDefaults.set(lonDelta, forKey: "widgetRegionLonDelta")
    }

    private func widgetSharedDefaults() -> UserDefaults {
#if targetEnvironment(simulator)
        return .standard
#else
        let groupID = AppConfig.shared.appGroupID
        return UserDefaults(suiteName: groupID) ?? .standard
#endif
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
        } else {
            UserDefaults.standard.removeObject(forKey: "pending_lat")
            UserDefaults.standard.removeObject(forKey: "pending_lng")
            UserDefaults.standard.removeObject(forKey: "pending_time")
            UserDefaults.standard.removeObject(forKey: "liveStayStatus")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pending_time_local_updated")
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
                clearOngoingStayState()
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
                    self.uiIsMoving = false
                    self.lastMovingEvidenceTime = .distantPast
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

    @MainActor
    func refreshForRecordingDeviceChange() async {
        TimelineBuilder.timelineCache.removeAll()
        refreshAvailableRawDates()
        await loadPointsFromStore()
        lastRawDataUpdateTrigger = Date()
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
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

    /// 重建所有有轨迹日期的足迹数据
    @MainActor
    func rebuildAllData() {
        guard let context = modelContext else { return }
        let dates = availableRawDates.sorted(by: <)
        guard !dates.isEmpty else { return }
        
        rebuildTask?.cancel()
        isRebuildingAll = true
        rebuildProgress = 0
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        
        rebuildTask = Task {
            let total = Double(dates.count)
            var current = 0.0
            
            for date in dates {
                if Task.isCancelled { break }
                
                let startOfDay = Calendar.current.startOfDay(for: date)
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
                
                // 清理当天缓存
                TimelineBuilder.timelineCache.removeValue(forKey: startOfDay)
                
                // 物理清空当天所有相关记录（保留照片足迹）。必须按时间交集清理，
                // 否则昨天开始、今天结束的跨天足迹会漏删，重建后继续出现在今天。
                let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                    $0.startTime < endOfDay && $0.endTime > startOfDay
                })
                let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                    $0.startTime < endOfDay && $0.endTime > startOfDay
                })
                let insightDesc = FetchDescriptor<DailyInsight>(predicate: #Predicate { $0.date == startOfDay })
                
                if let fps = try? context.fetch(fpDesc) {
                    for fp in fps {
                        if fp.photoAssetIDs.isEmpty { context.delete(fp) }
                    }
                }
                if let tps = try? context.fetch(tpDesc) { for tp in tps { context.delete(tp) } }
                if let insights = try? context.fetch(insightDesc) { for i in insights { context.delete(i) } }
                
                try? context.save()
                
                // 调用新引擎重新构建
                await PersistentTimelineBuilder.syncDay(date: date, in: context)
                
                current += 1
                let p = current / total
                await MainActor.run {
                    self.rebuildProgress = p
                }
            }
            
            await MainActor.run {
                self.isRebuildingAll = false
                self.rebuildProgress = 1.0
                self.lastRawDataUpdateTrigger = Date()
                NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            }
        }
    }
    
    @MainActor
    func cancelRebuild() {
        rebuildTask?.cancel()
        rebuildTask = nil
        isRebuildingAll = false
        rebuildProgress = 0
    }

    /// 计算路径总长度 (所有点之间的距离之和)
    nonisolated public static func calculatePathDistance(_ points: [CLLocation]) -> Double {
        guard points.count >= 2 else { return 0 }
        var distance: Double = 0
        for i in 0..<points.count - 1 {
            distance += points[i].distance(from: points[i+1])
        }
        return distance
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
            
            // 2. 获取当天现有的足迹与交通覆盖区间，避免在交通上再回填一个足迹
            let occupiedRanges = await MainActor.run { () -> [(start: Date, end: Date)] in
                guard let currentContext = self.modelContext else { return [] }
                
                let footprintDescriptor = FetchDescriptor<Footprint>(
                    predicate: #Predicate { $0.startTime < endOfDay && $0.endTime >= startOfDay },
                    sortBy: [SortDescriptor(\.startTime)]
                )
                let transportDescriptor = FetchDescriptor<TransportRecord>(
                    predicate: #Predicate { $0.statusRaw != "ignored" && $0.startTime < endOfDay && $0.endTime >= startOfDay },
                    sortBy: [SortDescriptor(\.startTime)]
                )
                
                let footprintRanges = ((try? currentContext.fetch(footprintDescriptor)) ?? []).map { ($0.startTime, $0.endTime) }
                let transportRanges = ((try? currentContext.fetch(transportDescriptor)) ?? []).map { ($0.startTime, $0.endTime) }
                return (footprintRanges + transportRanges).sorted { $0.start < $1.start }
            }
            
            // 3. 寻找间隙并在后台处理
            var currentTime = startOfDay
            var gapsToInsert: [(start: Date, end: Date, center: CLLocationCoordinate2D, points: [CLLocationCoordinate2D], duration: TimeInterval)] = []
            
            for range in occupiedRanges {
                if range.start > currentTime.addingTimeInterval(120) {
                    if let gap = identifyGapStay(from: currentTime, to: range.start, rawPoints: rawPoints) {
                        gapsToInsert.append(gap)
                    }
                }
                currentTime = max(currentTime, range.end)
            }
            
            let now = Date()
            let isToday = Calendar.current.isDateInToday(date)
            let lastDataTime = rawPoints.last?.timestamp
            let dayLimit: Date
            if isToday {
                dayLimit = now
            } else {
                // 对于历史日期，止于最后一条数据的时间点，不再强行补齐到翌日0点
                dayLimit = lastDataTime.map { min(endOfDay, $0) } ?? currentTime
            }
            
            // 4. 处理最后一个间隙（直至当前时间点）
            if dayLimit > currentTime.addingTimeInterval(AppConfig.shared.ongoingStayGracePeriod) {
                if let gap = identifyGapStay(from: currentTime, to: dayLimit, rawPoints: rawPoints) {
                    // 核心改进：如果最后一段也是停留，尝试将其与上一段 GAP_STAY 合并（如果是同一个地方），避免产生碎片
                    var existingLast: Footprint? = nil
                    await MainActor.run {
                        var descriptor = FetchDescriptor<Footprint>(
                            predicate: #Predicate { $0.locationHash == "GAP_STAY" },
                            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
                        )
                        descriptor.fetchLimit = 1
                        existingLast = (try? self.modelContext?.fetch(descriptor))?.first
                    }
                    
                    if let lastFp = existingLast, 
                       abs(lastFp.endTime.timeIntervalSince(gap.start)) < AppConfig.shared.stayMergeGapThreshold {
                        let lastLoc = CLLocation(latitude: lastFp.latitude, longitude: lastFp.longitude)
                        let gapLoc = CLLocation(latitude: gap.center.latitude, longitude: gap.center.longitude)
                        if lastLoc.distance(from: gapLoc) < AppConfig.shared.stayDistanceThreshold {
                            await MainActor.run {
                                lastFp.endTime = gap.end
                                try? lastFp.modelContext?.save()
                            }
                        } else {
                            gapsToInsert.append(gap)
                        }
                    } else {
                        gapsToInsert.append(gap)
                    }
                }
            }
            
                    // 4. 回到主线程执行持久化
                    if !gapsToInsert.isEmpty {
                        let itemsToInsert = gapsToInsert
                        await MainActor.run {
                            guard let context = self.modelContext else { return }
                            var insertedFootprints: [Footprint] = []
                            let transportDescriptor = FetchDescriptor<TransportRecord>(
                                predicate: #Predicate { $0.statusRaw != "ignored" && $0.startTime < endOfDay && $0.endTime >= startOfDay },
                                sortBy: [SortDescriptor(\.startTime)]
                            )
                            let transportRanges = ((try? context.fetch(transportDescriptor)) ?? []).map { ($0.startTime, $0.endTime) }
                            for gap in itemsToInsert {
                                let overlapsTransport = transportRanges.contains { range in
                                    let overlapStart = max(range.0, gap.start)
                                    let overlapEnd = min(range.1, gap.end)
                                    return overlapEnd.timeIntervalSince(overlapStart) > 60
                                }
                                if overlapsTransport { continue }

                                let matchedPlace = self.matchedPlaceFor(coordinate: gap.center)
                                let candidate = CandidateFootprint(
                                    startTime: gap.start,
                                    endTime: gap.end,
                                    centerCoordinate: gap.center,
                                    duration: gap.duration,
                                    rawLocations: []
                                )
                                let gapEnd = gap.end

                                var previousDescriptor = FetchDescriptor<Footprint>(
                                    predicate: #Predicate {
                                        $0.statusValue != "ignored" && $0.endTime > startOfDay && $0.endTime <= gapEnd
                                    },
                                    sortBy: [SortDescriptor(\.endTime, order: .reverse)]
                                )
                                previousDescriptor.fetchLimit = 1

                                if let lastFp = (try? context.fetch(previousDescriptor))?.first,
                                   !transportRanges.contains(where: { range in
                                       range.1 > lastFp.endTime && range.0 < gap.start
                                   }),
                                   self.shouldMergeExistingFootprint(lastFp, with: candidate, matchedPlace: matchedPlace) {
                                    lastFp.endTime = max(lastFp.endTime, gap.end)

                                    var mergedLocations = lastFp.footprintLocations
                                    mergedLocations.append(contentsOf: gap.points)
                                    lastFp.footprintLocations = mergedLocations

                                    if lastFp.placeID == nil, let matchedPlace {
                                        lastFp.placeID = matchedPlace.placeID
                                    }
                                    if !lastFp.isAddressEditedByHand, let matchedPlace {
                                        lastFp.address = matchedPlace.name
                                    }

                                    insertedFootprints.append(lastFp)
                                    continue
                                }

                                let newFp = Footprint(
                                    date: Calendar.current.startOfDay(for: gap.start),
                                    startTime: gap.start,
                                    endTime: gap.end,
                                    footprintLocations: gap.points,
                                    locationHash: "GAP_STAY",
                                    duration: gap.duration
                                )
                                context.insert(newFp)
                                
                                if let mPlace = matchedPlace {
                                    let pid = mPlace.placeID
                                    newFp.placeID = pid
                                    newFp.address = mPlace.name
                                    
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
                            
                            // 提醒小组件更新历史回填数据
                            Task { await WidgetDataSyncManager.shared.syncTodayOnly() }
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

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        // 清理当天缓存并提前通知页面释放旧模型引用，避免删除后访问失效对象。
        TimelineBuilder.timelineCache.removeValue(forKey: startOfDay)
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataWillReset"),
            object: nil,
            userInfo: ["date": startOfDay]
        )
        
        isResettingData = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        
        Task {
            // 1. 物理清空当天所有相关记录。按时间交集删除，防止跨天旧记录漏删。
            let fpDesc = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime < endOfDay && $0.endTime > startOfDay
            })
            let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.startTime < endOfDay && $0.endTime > startOfDay
            })
            let insightDesc = FetchDescriptor<DailyInsight>(predicate: #Predicate { $0.date == startOfDay })
            
            if let fps = try? context.fetch(fpDesc) {
                for fp in fps {
                    context.delete(fp)
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
                
                // 提醒小组件重置数据
                Task { await WidgetDataSyncManager.shared.syncTodayOnly() }
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
    func selectSuggestion(_ suggestion: LocationSuggestion, forOngoing: Bool, footprint: Footprint? = nil, isDraft: Bool = false) {
        let targetPlace = updateOrCreatePlaceAsPriority(suggestion)
        
        // 如果是“重要地点”（用户定义），展示地址而非名称（因为名称会在标签/标题里展示）
        // 如果是普通的 POI点位，则依然展示名称
        let displayValue = (targetPlace.isUserDefined && !(targetPlace.address ?? "").isEmpty) ? (targetPlace.address ?? suggestion.name) : suggestion.name
        
        if forOngoing {
            self.ongoingPlaceOverrideID = targetPlace.placeID
            self.ongoingPlaceOverrideAddress = displayValue
            self.currentAddress = displayValue
            // 强制重新进行分析以更新 UI
            ongoingTitle = nil
            if let loc = lastLocation ?? potentialStopStartLocation {
                analyzeOngoingStay(at: loc)
            }
        } else if let fp = footprint {
            if !isDraft {
                if let context = modelContext {
                    // 确保足迹已受管理 (针对 GAP_STAY 产生的幻影足迹)
                    if fp.modelContext == nil {
                        context.insert(fp)
                        if fp.locationHash == "GAP_STAY" {
                            fp.locationHash = "MANUAL_STAY"
                        }
                    }
                }
            }
            
            fp.address = suggestion.name
            fp.placeID = targetPlace.placeID
            fp.isAddressEditedByHand = true
            
            if !isDraft {
                if let context = modelContext {
                    // 重新分析足迹内容
                    analyzeFootprint(fp, context: context)
                }
            }
        }
        
        if !isDraft {
            try? modelContext?.save()
        }
    }

    private func clearOngoingPlaceOverride() {
        ongoingPlaceOverrideID = nil
        ongoingPlaceOverrideAddress = nil
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
            allPlaces.append(newPlace)
            return newPlace
        }
    }
    
    /// 执行原始轨迹数据的 iCloud 同步
    func performRawDataSync(showOverlay: Bool = false, onlyRecent: Bool = true, skipUpload: Bool = false) async {
        let isRawTrajectorySyncEnabled = UserDefaults.standard.object(forKey: "isRawTrajectoryICloudSyncEnabled") as? Bool ?? true
        guard isRawTrajectorySyncEnabled else { return }
        
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
            
            let count = try await RawLocationStore.shared.syncToiCloud(onlyRecent: onlyRecent, skipUpload: skipUpload)
            
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

    private func coarseAutomaticPlaceName(from placemark: CLPlacemark) -> String? {
        let candidates = [
            placemark.areasOfInterest?.first,
            placemark.name,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.locality
        ]

        if let preferred = candidates.compactMap({ $0 }).first(where: isCoarseAutomaticPlaceName) {
            return preferred
        }

        return [placemark.locality, placemark.subLocality]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()
            .nilIfEmpty
    }

    private func isCoarseAutomaticPlaceName(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        let finePatterns = [
            #"\d+\s*号"#, #"\d+\s*弄"#, #"\d+\s*室"#, #"\d+\s*层"#, #"\d+\s*楼"#,
            #"[\dA-Za-z一二三四五六七八九十]+号楼"#, #"[\dA-Za-z一二三四五六七八九十]+栋"#,
            #"单元"#, #"门牌"#, #"入口"#, #"出口"#, #"柜台"#, #"摊"#, #"铺"#, #"档口"#,
            #"店$"#, #"分店"#, #"便利店"#, #"超市"#, #"餐厅"#, #"饭店"#, #"咖啡"#, #"奶茶"#,
            #"茶饮"#, #"甜品"#, #"小吃"#, #"烧烤"#, #"火锅"#, #"面馆"#, #"粉店"#, #"酒吧"#,
            #"药房"#, #"药店"#, #"诊所"#, #"理发"#, #"美甲"#, #"洗衣"#, #"快递"#, #"驿站"#
        ]
        if finePatterns.contains(where: { name.range(of: $0, options: .regularExpression) != nil }) {
            return false
        }

        let coarseKeywords = [
            "景区", "景点", "公园", "广场", "博物馆", "美术馆", "图书馆", "体育馆", "展览馆",
            "商场", "购物中心", "中心", "大厦", "大楼", "写字楼", "园区", "科技园", "产业园",
            "大学", "学院", "学校", "医院", "酒店", "机场", "火车站", "高铁站", "地铁站",
            "车站", "码头", "社区", "小区", "花园", "公寓", "住宅", "村", "镇", "街道"
        ]

        return coarseKeywords.contains { name.contains($0) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
        if !coord.requiresMainlandChinaGCJOffset {
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

private extension CLLocationCoordinate2D {
    var requiresMainlandChinaGCJOffset: Bool {
        guard longitude >= 72.004, longitude <= 137.8347,
              latitude >= 0.8293, latitude <= 55.8271 else {
            return false
        }

        return !isInHongKong &&
            !isInMacau &&
            !isInTaiwanMainIsland &&
            !isInTaiwanOutlyingIslands
    }

    private var isInHongKong: Bool {
        latitude >= 22.13 && latitude <= 22.57 &&
            longitude >= 113.80 && longitude <= 114.45
    }

    private var isInMacau: Bool {
        latitude >= 22.03 && latitude <= 22.23 &&
            longitude >= 113.50 && longitude <= 113.65
    }

    private var isInTaiwanMainIsland: Bool {
        latitude >= 21.80 && latitude <= 25.40 &&
            longitude >= 119.30 && longitude <= 122.10
    }

    private var isInTaiwanOutlyingIslands: Bool {
        let isInPenghu = latitude >= 23.10 && latitude <= 23.90 &&
            longitude >= 119.20 && longitude <= 119.90
        let isInKinmen = latitude >= 24.25 && latitude <= 24.60 &&
            longitude >= 118.10 && longitude <= 118.60
        let isInMatsu = latitude >= 25.85 && latitude <= 26.40 &&
            longitude >= 119.85 && longitude <= 120.60
        return isInPenghu || isInKinmen || isInMatsu
    }
}

extension TimeInterval {
    var formattedStayDuration: String {
        let totalMinutes = Int(self / 60)
        
        if totalMinutes >= 1440 {
            let days = totalMinutes / 1440
            let hours = (totalMinutes % 1440) / 60
            
            var components: [String] = ["\(days) 天"]
            if hours > 0 {
                components.append("\(hours) 小时")
            }
            return components.joined(separator: " ")
        } else if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes > 0 {
                return "\(hours) 小时 \(minutes) 分钟"
            } else {
                return "\(hours) 小时"
            }
        } else {
            return "\(max(1, totalMinutes)) 分钟"
        }
    }
}

#if canImport(ActivityKit)
import ActivityKit
import SwiftData

@available(iOS 16.1, *)
class TripLiveActivityManager {
    static let shared = TripLiveActivityManager()
    private var currentActivity: Activity<TripActivityAttributes>?

    func updateLiveActivity(location: CLLocation, modelContext: ModelContext?) {
        guard let context = modelContext else { return }
        
        if currentActivity == nil {
            currentActivity = Activity<TripActivityAttributes>.activities.first
        }
        
        let descriptor = FetchDescriptor<FutureTrip>(sortBy: [SortDescriptor(\.arrivalDate)])
        let trips = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        let calendar = Calendar.current

        if completeArrivedTrips(location: location, trips: trips, context: context, calendar: calendar) {
            FutureTrip.postDidChangeNotification()
        }

        let candidateTrips = FutureTrip.dayOrdered(trips).filter { trip in
            guard !trip.isCompleted else { return false }
            if trip.isOrdered {
                return calendar.isDateInToday(trip.arrivalDate)
            }

            let timeInterval = trip.arrivalDate.timeIntervalSince(now)
            return timeInterval <= 3600
        }

        if let upcomingTrip = candidateTrips.first {
            let tripLocation = CLLocation(latitude: upcomingTrip.latitude, longitude: upcomingTrip.longitude)
            let distance = location.distance(from: tripLocation)
            let mins = upcomingTrip.isOrdered ? 0 : max(0, Int(upcomingTrip.arrivalDate.timeIntervalSince(now) / 60))
            
            let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
            let matchedIcon = allActivities.first(where: { $0.id.uuidString == upcomingTrip.activityTypeValue || $0.name == upcomingTrip.activityTypeValue })?.icon ?? "calendar"
            
            let state = TripActivityAttributes.ContentState(
                currentDistance: distance,
                remainingMinutes: mins,
                placeName: upcomingTrip.placeName,
                arrivalDate: upcomingTrip.arrivalDate,
                latitude: upcomingTrip.latitude,
                longitude: upcomingTrip.longitude,
                icon: matchedIcon,
                hasArrivalTime: upcomingTrip.hasArrivalTime,
                isOrdered: upcomingTrip.isOrdered,
                shouldOfferCompletion: upcomingTrip.shouldOfferCompletion(currentDistance: distance, now: now)
            )
            
            Task {
                await self.ensureTripMapSnapshot(latitude: upcomingTrip.latitude, longitude: upcomingTrip.longitude, tripId: upcomingTrip.id.uuidString)
                let content = ActivityContent(state: state, staleDate: nil)
                
                if let activity = self.currentActivity {
                    if activity.attributes.tripId != upcomingTrip.id.uuidString {
                        await activity.end(nil, dismissalPolicy: .immediate)
                        let attributes = TripActivityAttributes(tripId: upcomingTrip.id.uuidString)
                        self.currentActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
                    } else {
                        await activity.update(content)
                    }
                } else {
                    let attributes = TripActivityAttributes(tripId: upcomingTrip.id.uuidString)
                    do {
                        self.currentActivity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                    } catch {
                        print("Failed to start live activity: \(error)")
                    }
                }
            }
        } else {
            if let activity = currentActivity {
                Task {
                    await activity.end(nil, dismissalPolicy: .default)
                }
                currentActivity = nil
            }
            for activity in Activity<TripActivityAttributes>.activities {
                Task {
                    await activity.end(nil, dismissalPolicy: .default)
                }
            }
        }
    }

    @discardableResult
    private func completeArrivedTrips(location: CLLocation, trips: [FutureTrip], context: ModelContext, calendar: Calendar) -> Bool {
        var didComplete = false

        for trip in trips where !trip.isCompleted && calendar.isDateInToday(trip.arrivalDate) {
            let tripLocation = CLLocation(latitude: trip.latitude, longitude: trip.longitude)
            guard location.distance(from: tripLocation) < 200 else { continue }

            NotificationManager.shared.cancelFutureTripNotification(for: trip.id)
            trip.markCompleted()
            didComplete = true
        }

        if didComplete {
            try? context.save()
        }

        return didComplete
    }
    
    private func ensureTripMapSnapshot(latitude: Double, longitude: Double, tripId: String) async {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ct106.difangke") else { return }
        
        let latStr = String(format: "%.3f", latitude)
        let lonStr = String(format: "%.3f", longitude)
        let hashStr = "\(latStr)_\(lonStr)"
        
        let lightUrl = container.appendingPathComponent("trip_\(tripId)_\(hashStr)_light.png")
        let darkUrl = container.appendingPathComponent("trip_\(tripId)_\(hashStr)_dark.png")
        
        if FileManager.default.fileExists(atPath: lightUrl.path) && FileManager.default.fileExists(atPath: darkUrl.path) {
            return
        }
        
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        options.size = CGSize(width: 400, height: 200)
        options.scale = 2.0
        options.showsBuildings = true
        
        do {
            options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
            let snapshotLight = try await MKMapSnapshotter(options: options).start()
            try snapshotLight.image.pngData()?.write(to: lightUrl)
            
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            let snapshotDark = try await MKMapSnapshotter(options: options).start()
            try snapshotDark.image.pngData()?.write(to: darkUrl)
        } catch {
            print("Failed to generate map snapshot: \(error)")
        }
    }
}
#endif

#endif
