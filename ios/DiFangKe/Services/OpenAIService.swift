import Foundation
import CryptoKit
import SwiftData
import Observation
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class OpenAIService {
    static let shared = OpenAIService()
    
    private init() {
#if !WIDGET_EXTENSION
        NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuotesIfDayChanged()
            }
        }
#endif
    }
    
    private func refreshQuotesIfDayChanged() {
        // 如果发现缓存的日期不是今天了，说明已经跨天
        if let date = cacheDate, !Calendar.current.isDateInToday(date) {
            // 直接重新进入队列获取最新的明天寄语
            self.taskQueue.append(.tomorrowQuote)
            self.processQueue()
        }
        
        if let date = pastCacheDate, !Calendar.current.isDateInToday(date) {
            self.taskQueue.append(.pastQuote)
            self.processQueue()
        }
    }
    
    enum AITask {
        case dailySummary(Date, [UUID], [UUID], Bool)
        case tomorrowQuote
        case pastQuote
        case notificationSummary([String])
        case ongoing(([(Double, Double)], TimeInterval, Date, Date, String?, String?, String?))
    }
    
    // 用于保存异步队列完成后的回调
    private var tomorrowQuoteCompletions: [(String, String) -> Void] = []
    private var pastQuoteCompletions: [(String, String) -> Void] = []
    private var notificationSummaryCompletions: [(String) -> Void] = []
    private var ongoingCompletions: [(String) -> Void] = []
    
    // 快速查找集合，避免线性搜索导致卡顿
    private var dailySummaryDateSet = Set<Date>()
    
    var taskQueue: [AITask] = []
    var isProcessing = false
    var lastError: String? = nil
    var lastAiResponse: String? = nil
    var currentlyProcessingDate: Date? = nil
    private var lastRequestTime: Date = .distantPast
    private var cooldownRetryTask: Task<Void, Never>?
    
    private var isNetworkRequestingCount = 0
    var isNetworkRequesting: Bool = false
    
    private func updateNetworkRequesting(_ requesting: Bool) {
        if requesting {
            isNetworkRequestingCount += 1
        } else {
            isNetworkRequestingCount = max(0, isNetworkRequestingCount - 1)
        }
        self.isNetworkRequesting = isNetworkRequestingCount > 0
    }
    
    var modelContainer: ModelContainer?
    
    var queueCount: Int {
        taskQueue.count + (isProcessing ? 1 : 0)
    }
    
    private var config: AppConfig {
        AppConfig.shared
    }
    
    private var serviceSecret: String {
        config.serviceSecret
    }
    
    // MARK: - New Dynamic Settings
    
    private var aiServiceType: String {
        UserDefaults.standard.string(forKey: "aiServiceType") ?? "public"
    }
    
    private var customApiUrl: String {
        UserDefaults.standard.string(forKey: "customAiUrl") ?? ""
    }
    
    private var customApiKey: String {
        UserDefaults.standard.string(forKey: "customAiKey") ?? ""
    }
    
    private var customModelName: String {
        UserDefaults.standard.string(forKey: "customAiModel") ?? "gpt-3.5-turbo"
    }
    
    private var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
    
    private func generateToken(deviceId: String) -> String {
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let input = serviceSecret + deviceId + "\(hour)"
        let digest = Insecure.MD5.hash(data: input.data(using: .utf8) ?? Data())
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    private func prepareRequest(endpoint: String, body: [String: Any]) -> URLRequest? {
        let urlString: String
        let apiKey: String
        let model: String
        
        if aiServiceType == "custom" {
            let base = customApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                self.lastError = "自定义 API 地址未设置"
                return nil
            }
            if customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lastError = "自定义 API KEY 未设置"
                return nil
            }
            urlString = base.hasSuffix("/") ? "\(base)\(endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint)" : "\(base)\(endpoint)"
            apiKey = customApiKey
            model = customModelName
        } else {
            // 严格读取 Config.plist，不使用任何硬编码兜底
            guard let base = config.publicServiceUrl.isEmpty ? nil : config.publicServiceUrl else {
                self.lastError = "Config.plist 缺失 PUBLIC_SERVICE_URL"
                return nil
            }
            guard !config.serviceSecret.isEmpty else {
                self.lastError = "Config.plist 缺失 SERVICE_SECRET"
                return nil
            }
            
            urlString = base.hasSuffix("/") ? "\(base)\(endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint)" : "\(base)\(endpoint)"
            apiKey = generateToken(deviceId: deviceId)
            model = "gpt-3.5-turbo"
        }
        
        guard let url = URL(string: urlString) else {
            self.lastError = "无效的请求地址: \(urlString)"
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if aiServiceType == "public" {
            request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.addValue(apiKey, forHTTPHeaderField: "X-Token")
        } else {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        var bodyWithModel = body
        if bodyWithModel["model"] == nil {
            bodyWithModel["model"] = model
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyWithModel)
        return request
    }

    // MARK: - Task Cache (Persistent)
    private var cachedTomorrowQuote: (String, String)? {
        get {
            guard let title = UserDefaults.standard.string(forKey: "cachedTomorrowQuoteTitle"),
                  let sub = UserDefaults.standard.string(forKey: "cachedTomorrowQuoteSub") else { return nil }
            return (title, sub)
        }
        set {
            UserDefaults.standard.set(newValue?.0, forKey: "cachedTomorrowQuoteTitle")
            UserDefaults.standard.set(newValue?.1, forKey: "cachedTomorrowQuoteSub")
        }
    }
    
    private var cacheDate: Date? {
        get { UserDefaults.standard.object(forKey: "cacheDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "cacheDate") }
    }
    
    private var cachedPastQuote: (String, String)? {
        get {
            guard let title = UserDefaults.standard.string(forKey: "cachedPastQuoteTitle"),
                  let sub = UserDefaults.standard.string(forKey: "cachedPastQuoteSub") else { return nil }
            return (title, sub)
        }
        set {
            UserDefaults.standard.set(newValue?.0, forKey: "cachedPastQuoteTitle")
            UserDefaults.standard.set(newValue?.1, forKey: "cachedPastQuoteSub")
        }
    }
    
    private var pastCacheDate: Date? {
        get { UserDefaults.standard.object(forKey: "pastCacheDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "pastCacheDate") }
    }

    // MARK: - Queue Management
    

    func enqueueDailySummary(for date: Date, footprints: [Footprint], transports: [TransportRecord] = [], force: Bool = false) {
        let startOfDate = Calendar.current.startOfDay(for: date)
        let summaryFootprints = footprints.filter { $0.isUserModifiedForDailySummary }

        guard !summaryFootprints.isEmpty else {
            dailySummaryDateSet.remove(startOfDate)
            return
        }
        
        // 如果不是强制刷新，且已经在队列中或已处理过，则跳过
        if !force && dailySummaryDateSet.contains(startOfDate) { return }
        
        // 移除队列中已有的同日期任务（如果有）
        taskQueue.removeAll { task in
            if case .dailySummary(let d, _, _, _) = task {
                return Calendar.current.isDate(d, inSameDayAs: startOfDate)
            }
            return false
        }
        
        let fpIds = summaryFootprints.map { $0.footprintID }
        let tpIds = transports.map { $0.recordID }
        
        dailySummaryDateSet.insert(startOfDate)
        
        let newTask = AITask.dailySummary(startOfDate, fpIds, tpIds, force)
        if force {
            // 强制刷新：插队到最前面
            self.taskQueue.insert(newTask, at: 0)
        } else {
            self.taskQueue.append(newTask)
        }
        
        self.processQueue()
    }
    
    func enqueueTomorrowQuote(completion: @escaping (String, String) -> Void) {
        // 优先检查持久化缓存，确保持续可用
        if let cache = cachedTomorrowQuote, let date = cacheDate, Calendar.current.isDateInToday(date) {
            completion(cache.0, cache.1)
            return
        }
        
        self.tomorrowQuoteCompletions.append(completion)
        if !self.taskQueue.contains(where: { if case .tomorrowQuote = $0 { return true }; return false }) {
            self.taskQueue.append(.tomorrowQuote)
        }
        self.processQueue()
    }
    
    func enqueuePastQuote(completion: @escaping (String, String) -> Void) {
        // 优先检查持久化缓存
        if let cache = cachedPastQuote, let date = pastCacheDate, Calendar.current.isDateInToday(date) {
            completion(cache.0, cache.1)
            return
        }
        
        self.pastQuoteCompletions.append(completion)
        if !self.taskQueue.contains(where: { if case .pastQuote = $0 { return true }; return false }) {
            self.taskQueue.append(.pastQuote)
        }
        self.processQueue()
    }
    
    func enqueueNotificationSummary(footprintTitles: [String], completion: @escaping (String) -> Void) {
        self.notificationSummaryCompletions.append(completion)
        self.taskQueue.append(.notificationSummary(footprintTitles))
        self.processQueue()
    }
    
    func enqueueOngoingAnalysis(locations: [(Double, Double)], duration: TimeInterval, startTime: Date, endTime: Date, placeName: String?, address: String?, activityName: String?, completion: @escaping (String) -> Void) {
        self.ongoingCompletions.append(completion)
        self.taskQueue.append(.ongoing((locations, duration, startTime, endTime, placeName, address, activityName)))
        self.processQueue()
    }

    // 频率控制：公共服务限制更严格，间隔更长；自定义服务允许更频繁的请求以适应不同需求
    private var currentInterval: TimeInterval {
        return aiServiceType == "custom" ? 5 : 60
    }

    private func processQueue() {
        guard !isProcessing, !taskQueue.isEmpty, let container = modelContainer else { return }
        
        let now = Date()
        let interval = currentInterval
        
        // 检查下一个任务是否是强制任务
        var nextTaskIsForced = false
        if case .dailySummary(_, _, _, let force) = taskQueue.first {
            nextTaskIsForced = force
        }
        
        let timeSinceLast = now.timeIntervalSince(lastRequestTime)
        // 强制任务允许更短的间隔（1秒），普通任务遵循配置间隔
        let requiredInterval = nextTaskIsForced ? 1.0 : interval
        
        if timeSinceLast < requiredInterval {
            // 即使在冷却中，只要队列有任务，也显示正在请求状态
            self.isNetworkRequesting = true
            
            // 还在冷却中，取消之前的重试任务并重新预约
            cooldownRetryTask?.cancel()
            let delay = requiredInterval - timeSinceLast
            cooldownRetryTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.processQueue()
            }
            return
        }
        
        isProcessing = true
        let nextTask = taskQueue.removeFirst()
        
        Task {
            let context = ModelContext(container)
            self.updateNetworkRequesting(true)
            self.lastRequestTime = Date()
            
            switch nextTask {
            case .dailySummary(let date, let fpIds, let tpIds, let force):
                await self.processDailySummaryTask(date: date, fpIds: fpIds, tpIds: tpIds, context: context, force: force)
            case .tomorrowQuote:
                await self.processTomorrowQuoteTask()
            case .pastQuote:
                await self.processPastQuoteTask()
            case .notificationSummary(let titles):
                await self.processNotificationSummaryTask(titles: titles)
            case .ongoing(let data):
                await self.processOngoingTask(data: data)
            }
            
            self.updateNetworkRequesting(false)
            self.isProcessing = false
            
            // 任务完成后，尝试处理下一个
            self.processQueue()
        }
    }
    
    // MARK: - Task Handlers (Async)

    
    private struct DailySummaryProfile {
        let lines: [String]
        let fingerprint: String
        let fallbackSummary: String
    }
    
    private func processDailySummaryTask(date: Date, fpIds: [UUID], tpIds: [UUID], context: ModelContext, force: Bool = false) async {
        let startOfDate = Calendar.current.startOfDay(for: date)
        self.currentlyProcessingDate = startOfDate
        defer { self.currentlyProcessingDate = nil }
        
        // 提前预加载已有的 Insight 以便比对 Fingerprint
        let descriptor = FetchDescriptor<DailyInsight>(predicate: #Predicate { 
            $0.date == startOfDate 
        })
        let existing = (try? context.fetch(descriptor))?.first
        let existingContent = existing?.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaningfulExistingContent = !(existingContent?.isEmpty ?? true)

        guard let profile = buildDailySummaryProfile(fpIds: fpIds, tpIds: tpIds, context: context) else { return }
        
        let currentFingerprint = profile.fingerprint
        
        // 只有在内容完全一致时才复用旧摘要
        if !force, existing?.aiGenerated == true, existing?.dataFingerprint == currentFingerprint, hasMeaningfulExistingContent {
            dailySummaryDateSet.remove(startOfDate)
            return
        }
        
        let summaryResult = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.generateDailySummary(date: startOfDate, footprintDescriptions: profile.lines) { res in
                continuation.resume(returning: res)
            }
        }
        let finalizedSummary = dailySummaryCleanedSummary(summaryResult) ?? profile.fallbackSummary
        
        if let existing = existing {
            existing.content = finalizedSummary
            existing.aiGenerated = true
            existing.dataFingerprint = currentFingerprint
        } else {
            let newSummary = DailyInsight(date: startOfDate, content: finalizedSummary, aiGenerated: true)
            newSummary.dataFingerprint = currentFingerprint
            context.insert(newSummary)
        }
        try? context.save()
        
        dailySummaryDateSet.remove(startOfDate)
    }

    private func buildDailySummaryProfile(fpIds: [UUID], tpIds: [UUID], context: ModelContext) -> DailySummaryProfile? {
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
        
        var lines: [String] = []
        
        var events: [(Date, String)] = []
        var uniquePlaceKeys: Set<String> = []
        var totalTransportDistance: Double = 0
        var footprintCoordsByTime: [(Date, CLLocationCoordinate2D)] = []
        
        for id in fpIds {
            let fpDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
            if let fp = (try? context.fetch(fpDescriptor))?.first {
                guard fp.isUserModifiedForDailySummary else { continue }
                let factLine = dailySummaryFactLine(for: fp, places: allPlaces, activities: allActivities)
                if !factLine.isEmpty {
                    events.append((fp.startTime, factLine))
                }

                uniquePlaceKeys.insert(dailySummaryPlaceKey(for: fp, places: allPlaces))
                footprintCoordsByTime.append((fp.startTime, CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)))
            }
        }
        
        for id in tpIds {
            let tpDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
            if let tp = (try? context.fetch(tpDescriptor))?.first {
                let factLine = dailySummaryTransportLine(for: tp)
                if !factLine.isEmpty {
                    events.append((tp.startTime, factLine))
                }
                if tp.distance > 0 {
                    totalTransportDistance += tp.distance
                }
            }
        }
        
        // 按时间排序
        events.sort { $0.0 < $1.0 }
        
        for (index, event) in events.enumerated() {
            lines.append("\(index + 1). \(event.1)")
        }

        let inferredFootprintDistance = dailySummaryInferredDistance(from: footprintCoordsByTime)
        let totalDistanceEvidence = max(totalTransportDistance, inferredFootprintDistance)

        if totalDistanceEvidence > 0 {
            lines.append("\(lines.count + 1). 当日里程：\(dailySummaryDistanceText(totalDistanceEvidence))")
        }
        lines.append("\(lines.count + 1). 地点变化：\(dailySummaryPlaceJudgement(uniquePlaceCount: uniquePlaceKeys.count, distanceMeters: totalDistanceEvidence))")
        
        guard !lines.isEmpty else { return nil }
        
        let fallbackSummary = dailySummaryFallbackSummary(
            footprintCount: events.count,
            totalDistance: totalDistanceEvidence,
            placeJudgement: dailySummaryPlaceJudgement(uniquePlaceCount: uniquePlaceKeys.count, distanceMeters: totalDistanceEvidence)
        )
        return DailySummaryProfile(
            lines: lines,
            fingerprint: lines.joined(separator: "\n"),
            fallbackSummary: fallbackSummary
        )
    }

    private func dailySummaryFactLine(for footprint: Footprint, places: [Place], activities: [ActivityType]) -> String {
        let start = footprint.startTime.formatted(.dateTime.hour().minute())
        let end = footprint.endTime.formatted(.dateTime.hour().minute())
        var parts: [String] = ["\(start)-\(end)"]

        let placeName = dailySummaryPreferredPlaceName(for: footprint, places: places)
        if !placeName.isEmpty {
            parts.append(placeName)
        }
        
        if let activity = footprint.getActivityType(from: activities) {
            let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                parts.append("活动：\(name)")
            }
        }
        
        if let reason = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            parts.append("备注：\(reason)")
        }
        
        if footprint.isHighlight == true {
            parts.append("重点")
        }
        
        return parts.joined(separator: "｜")
    }

    private func dailySummaryPreferredPlaceName(for footprint: Footprint, places: [Place]) -> String {
        let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if footprint.isAddressEditedByHand && !address.isEmpty {
            return address
        }

        if let place = places.first(where: { $0.placeID == footprint.placeID }) {
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        return address
    }

    private func dailySummaryTransportLine(for transport: TransportRecord) -> String {
        let start = transport.startTime.formatted(.dateTime.hour().minute())
        let end = transport.endTime.formatted(.dateTime.hour().minute())
        let type = transport.manualTypeRaw ?? transport.typeRaw
        let typeName = TransportType(rawValue: type)?.localizedName ?? "交通"
        
        var parts: [String] = ["\(start)-\(end)", "移动（\(typeName)）"]
        
        if transport.startLocation != "起点" || transport.endLocation != "终点" {
            parts.append("\(transport.startLocation) ➔ \(transport.endLocation)")
        }
        
        if transport.distance > 0 {
            let distStr = transport.distance > 1000 ? String(format: "%.1fkm", transport.distance / 1000) : "\(Int(transport.distance))m"
            parts.append("距离：\(distStr)")
        }
        
        return parts.joined(separator: "｜")
    }

    private func dailySummaryFallbackSummary(footprintCount: Int, totalDistance: Double, placeJudgement: String) -> String {
        let base: String
        switch footprintCount {
        case 1:
            base = "今天没去别的地方"
        case 2...3:
            base = "今天去过几个地方"
        case 4...:
            base = "今天去过的地方还不少"
        default:
            base = "又是平凡的一天"
        }

        if totalDistance > 0 {
            return "\(base)，里程约\(dailySummaryDistanceText(totalDistance))，\(placeJudgement)"
        }
        return "\(base)，\(placeJudgement)"
    }

    private func dailySummaryDistanceText(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded()))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func dailySummaryPlaceJudgement(uniquePlaceCount: Int, distanceMeters: Double) -> String {
        if distanceMeters >= 50_000 {
            return "地点变化比较明显"
        }
        switch uniquePlaceCount {
        case 0...1:
            return "地点变化不大"
        case 2...3:
            return "地点有一定变化"
        default:
            return "地点变化比较明显"
        }
    }

    private func dailySummaryPlaceKey(for footprint: Footprint, places: [Place]) -> String {
        let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if footprint.isAddressEditedByHand && !address.isEmpty {
            return "addr:\(address)"
        }

        if let placeID = footprint.placeID {
            return "pid:\(placeID.uuidString)"
        }

        if !address.isEmpty {
            return "addr:\(address)"
        }

        // 无 placeID/地址时回退到坐标网格，确保照片导入的跨城点能体现“地点变化”。
        return String(format: "grid:%.2f,%.2f", footprint.latitude, footprint.longitude)
    }

    private func dailySummaryInferredDistance(from timedCoords: [(Date, CLLocationCoordinate2D)]) -> Double {
        let sorted = timedCoords.sorted { $0.0 < $1.0 }
        guard sorted.count >= 2 else { return 0 }

        var total: Double = 0
        for index in 1..<sorted.count {
            let prev = CLLocation(latitude: sorted[index - 1].1.latitude, longitude: sorted[index - 1].1.longitude)
            let cur = CLLocation(latitude: sorted[index].1.latitude, longitude: sorted[index].1.longitude)
            total += prev.distance(from: cur)
        }
        return total
    }

    private func dailySummaryCleanedSummary(_ summary: String?) -> String? {
        guard var summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return nil
        }

        let forbiddenPhrases = ["未提及", "未出现", "没有提及", "没有出现", "未说明", "未写明", "未提到"]
        if forbiddenPhrases.contains(where: { summary.contains($0) }) {
            for phrase in forbiddenPhrases {
                summary = summary.replacingOccurrences(of: phrase, with: "")
            }
        }

        summary = summary
            .replacingOccurrences(of: "，，", with: "，")
            .replacingOccurrences(of: "、、", with: "、")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。；：、 "))

        return summary.isEmpty ? nil : summary
    }

    private func processTomorrowQuoteTask() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(String, String), Never>) in
            self.generateTomorrowQuote { title, sub in
                continuation.resume(returning: (title, sub))
            }
        }
        let calls = self.tomorrowQuoteCompletions
        self.tomorrowQuoteCompletions.removeAll()
        calls.forEach { $0(result.0, result.1) }
    }
    
    private func processPastQuoteTask() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(String, String), Never>) in
            self.generatePastQuote { title, sub in
                continuation.resume(returning: (title, sub))
            }
        }
        let calls = self.pastQuoteCompletions
        self.pastQuoteCompletions.removeAll()
        calls.forEach { $0(result.0, result.1) }
    }
    
    private func processNotificationSummaryTask(titles: [String]) async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.generateDailySummary(date: Date(), footprintDescriptions: titles) { res in
                continuation.resume(returning: res)
            }
        }
        let calls = self.notificationSummaryCompletions
        self.notificationSummaryCompletions.removeAll()
        calls.forEach { $0(result ?? "平凡的一天") }
    }
    
    private func processOngoingTask(data: ([(Double, Double)], TimeInterval, Date, Date, String?, String?, String?)) async {
        let result = data.4 ?? data.5 ?? ""
        let calls = self.ongoingCompletions
        self.ongoingCompletions.removeAll()
        calls.forEach { $0(result) }
    }

    
    func generateDailySummary(date: Date, footprintDescriptions: [String], completion: @escaping (String?) -> Void) {
        guard !footprintDescriptions.isEmpty else { completion("平凡的一天"); return }
        
        let dateStr = date.formatted(.dateTime.year().month().day())
        let list = footprintDescriptions.joined(separator: "\n")
        let prompt = """
        今天是 \(dateStr)。下面是当天足迹的事实片段，请你先自己归纳出一天的主线和状态，再用一句话总结今天。
        要求：
        1. 只输出一句中文。
        2. 不要逐条复述，不要写时间线，不要把片段照搬成流水账。
        3. 只做归纳，不要输出标签名、编号、括号说明或字段名，也不要照搬片段里的表达。
        4. 只写能从片段直接推出的客观内容，不要补写感受、氛围、节奏、心情或状态判断。
        5. 语气自然一点，像日常顺口说的话，但不要像通报、监控记录或工作汇报。
        6. 如果当天有多次交通出行但地点变化不大，可以概括为“出门走走”或“多次往返”。
        7. 如果信息零散，就总结整体状态，不要编造细节。
        8. 尽量控制在 15 字以内。
        9. 可以优先吸收“当日里程”和“地点变化”这两条信息，不要机械复述。
        10. 输出前先做一致性校验：结论必须和里程、地点线索一致，不能互相矛盾。
        11. 若片段体现明显的远距离或跨区域移动，结论应体现范围扩大与跨区域特征，避免收缩性描述。
        12. 活动范围判断要以明确事实优先：里程数和地点词 > 模糊描述；有冲突时按更强证据下结论。

        事实片段：
        \(list)
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "你是一位只做事实概括的中文助手。输出前先做事实一致性校验：结论必须与里程和地点线索一致，禁止出现与证据相反的收缩性结论。输出要自然、口语化，不要虚构，不要抒情，不要修辞，不要使用报表口吻、监控口吻或生硬表达，也不要补写感受、氛围、节奏、心情或状态判断。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            // lastError is already set in prepareRequest
            completion(nil); return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                if let error = error {
                    self.lastError = "总结失败: \(error.localizedDescription)"
                    completion(nil); return
                }
                
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    self.lastError = "总结失败: HTTP \(httpResponse.statusCode)"
                    completion(nil); return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                    self.lastError = "解析总结内容失败"
                    completion(nil); return
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastAiResponse = trimmed
                completion(trimmed.isEmpty ? nil : trimmed)
            }
        }.resume()
    }
    
    func generateTomorrowQuote(completion: @escaping (String, String) -> Void) {
        if let cache = cachedTomorrowQuote, let date = cacheDate, Calendar.current.isDateInToday(date) {
            completion(cache.0, cache.1); return
        }
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "Generate a warm quote for tomorrow in JSON: {\"title\":\"...\",\"subtitle\":\"...\"}"],
                ["role": "user", "content": "帮我写一段对明天的寄语"]
            ],
            "temperature": 0.9
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion("明天见", "期待新的一天"); return
        }
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            Task { @MainActor in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                    completion("明天见", "期待新的一天"); return
                }
                let clean = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = clean.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let result = (p["title"] as? String ?? "明天见", p["subtitle"] as? String ?? "期待新的一天")
                    self.cachedTomorrowQuote = result
                    self.cacheDate = Date()
                    completion(result.0, result.1)
                } else {
                    completion("明天见", "期待新的一天")
                }
            }
        }.resume()
    }
    
    func generatePastQuote(completion: @escaping (String, String) -> Void) {
        if let cache = cachedPastQuote, let date = pastCacheDate, Calendar.current.isDateInToday(date) {
            completion(cache.0, cache.1); return
        }
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "Generate a nostalgic quote for missing history in JSON: {\"title\":\"...\",\"subtitle\":\"...\"}"],
                ["role": "user", "content": "写一段关于没能早点记录足迹的遗憾文案"]
            ],
            "temperature": 0.9
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion("往事如烟", "如果能早点遇见就好了"); return
        }
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            Task { @MainActor in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                    completion("往事如烟", "如果能早点遇见就好了"); return
                }
                let clean = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = clean.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let result = (p["title"] as? String ?? "往事如烟", p["subtitle"] as? String ?? "如果能早点记录就好了")
                    self.cachedPastQuote = result
                    self.pastCacheDate = Date()
                    completion(result.0, result.1)
                } else {
                    completion("往事如烟", "如果能早点记录就好了")
                }
            }
        }.resume()
    }

    func getCustomSummary(prompt: String, completion: @escaping (String?) -> Void) {
        let body: [String: Any] = ["messages": [["role": "user", "content": prompt]], "temperature": 0.7]
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else { completion(nil); return }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            Task { @MainActor in
                guard let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let c = j["choices"] as? [[String: Any]], let content = (c.first?["message"] as? [String: Any])?["content"] as? String else {
                    completion(nil); return
                }
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()
    }
    
    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let body: [String: Any] = ["messages": [["role": "user", "content": "Ping"]], "max_tokens": 5]
        guard let req = prepareRequest(endpoint: "/chat/completions", body: body) else { completion(false, "URL无效"); return }
        URLSession.shared.dataTask(with: req) { data, response, _ in
            Task { @MainActor in
                if let res = response as? HTTPURLResponse, (200...299).contains(res.statusCode) {
                    completion(true, "连接成功")
                } else {
                    completion(false, "连接失败")
                }
            }
        }.resume()
    }
}
