import Foundation
import CryptoKit
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class OpenAIService {
    static let shared = OpenAIService()
    
    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuotesIfDayChanged()
            }
        }
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
    
    private var isNetworkRequestingCount = 0
    var isNetworkRequesting: Bool = false {
        didSet {
            // Allow listening for changes if needed
        }
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
        if !force && dailySummaryDateSet.contains(startOfDate) { return }
        
        // 使用 UUID，避免 PersistentIdentifier 跨线程/跨 Context 的各种坑
        let fpIds = footprints.map { $0.footprintID }
        let tpIds = transports.map { $0.recordID }
        
        dailySummaryDateSet.insert(startOfDate)
        self.taskQueue.append(.dailySummary(startOfDate, fpIds, tpIds, force))
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

    // 便捷方法
    private var currentInterval: TimeInterval {
        return aiServiceType == "custom" ? 15 : 60
    }

    private func processQueue() {
        guard !isProcessing, !taskQueue.isEmpty, let container = modelContainer else { return }
        
        isProcessing = true
        let nextTask = taskQueue.removeFirst()
        
        // 当任务移出队列时，从快速查找集合中移除（以便未来可以再次排队，如果需要的话，比如失败重试）
        // 这里的逻辑可以根据需求调整：如果分析过了就不再加入，那么不移除；如果要允许重复排队，则移除。
        // 目前我们的 processTask 内部有 aiAnalyzed 检查，所以这里移不移除都行。
        // 为了严格防止重复排队，我们只在任务“完成”且“未过”时才保留在 Set 中？ 
        // 实际上，目前的设计是 enqueue 时查重。
        
        let interval = currentInterval
        
        Task {
            let context = ModelContext(container)
            self.isNetworkRequesting = true
            
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
            
            self.isNetworkRequesting = false
            
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            
            self.isProcessing = false
            self.processQueue()
        }
    }
    
    // MARK: - Task Handlers (Async)

    
    private func processDailySummaryTask(date: Date, fpIds: [UUID], tpIds: [UUID], context: ModelContext, force: Bool = false) async {
        let startOfDate = Calendar.current.startOfDay(for: date)
        
        // 提前预加载已有的 Insight 以便比对 Fingerprint
        let descriptor = FetchDescriptor<DailyInsight>()
        let existing = (try? context.fetch(descriptor))?.first(where: { 
            guard let d = $0.date else { return false }
            return Calendar.current.isDate(d, inSameDayAs: startOfDate) 
        })

        // 只有非强制模式下才检查是否已存在（常规自动生成）
        if !force {
            if existing?.aiGenerated == true {
                dailySummaryDateSet.remove(startOfDate)
                return 
            }
        }

        struct SimpleItem {
            let time: Date
            let description: String
        }
        var rawItems: [SimpleItem] = []

        // 1. 处理足迹
        for id in fpIds {
            let fpDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
            if let fp = (try? context.fetch(fpDescriptor))?.first {
                let displayName = fp.address ?? "点位记录"
                
                let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
                let activityName = fp.getActivityType(from: allActivities)?.name
                var description = activityName != nil ? "\(displayName)(\(activityName!))" : displayName
                
                // 强调已收藏/高亮足迹
                if fp.isHighlight == true {
                    description = "【重点收藏】\(description)"
                }
                
                rawItems.append(SimpleItem(time: fp.startTime, description: description))
            }
        }

        // 2. 处理交通
        for id in tpIds {
            let tpDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
            if let tp = (try? context.fetch(tpDescriptor))?.first {
                if tp.statusRaw == "ignored" { continue }
                let type = TransportType(rawValue: tp.typeRaw)?.localizedName ?? tp.typeRaw
                let description = "通过\(type)从\(tp.startLocation)前往\(tp.endLocation)"
                rawItems.append(SimpleItem(time: tp.startTime, description: description))
            }
        }
        
        guard !rawItems.isEmpty else { return }
        
        let sortedItems = rawItems.sorted { $0.time < $1.time }
        var deduplicated: [String] = []
        var lastDesc: String? = nil
        
        for item in sortedItems {
            if item.description == lastDesc { continue }
            deduplicated.append("[\(item.time.formatted(.dateTime.hour().minute()))] \(item.description)")
            lastDesc = item.description
        }
        
        guard !deduplicated.isEmpty else { return }
        
        // 核心改动：比较本次数据的 Fingerprint 与数据库中已有的记录
        let currentFingerprint = deduplicated.joined(separator: "\n")
        if force && existing?.dataFingerprint == currentFingerprint {
            dailySummaryDateSet.remove(startOfDate)
            return
        }

        let summaryResult = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.generateDailySummary(date: startOfDate, footprintDescriptions: deduplicated) { res in
                continuation.resume(returning: res)
            }
        }
        
        guard let summary = summaryResult else { 
            dailySummaryDateSet.remove(startOfDate)
            return 
        }
        
        if let existing = existing {
            existing.content = summary
            existing.aiGenerated = true
            existing.dataFingerprint = currentFingerprint
        } else {
            let newSummary = DailyInsight(date: startOfDate, content: summary, aiGenerated: true)
            newSummary.dataFingerprint = currentFingerprint
            context.insert(newSummary)
        }
        try? context.save()
        
        dailySummaryDateSet.remove(startOfDate)
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
        calls.forEach { $0(result ?? "今天过得很有意义。") }
    }
    
    private func processOngoingTask(data: ([(Double, Double)], TimeInterval, Date, Date, String?, String?, String?)) async {
        let result = data.4 ?? data.5 ?? ""
        let calls = self.ongoingCompletions
        self.ongoingCompletions.removeAll()
        calls.forEach { $0(result) }
    }

    
    func generateDailySummary(date: Date, footprintDescriptions: [String], completion: @escaping (String?) -> Void) {
        guard !footprintDescriptions.isEmpty else { completion("今天过得轻盈而自在。"); return }
        
        let dateStr = date.formatted(.dateTime.year().month().day())
        let list = footprintDescriptions.joined(separator: "\n")
        let prompt = "今天是 \(dateStr)。请根据以下足迹编写一段极简晚间回顾（15字以内）。要求：作为一位善于发现生活之美的观察者，语气温润且富有洞察力，将碎片化的记录串联成有温度的文字，绝对不要使用生硬的模板：\n\(list)"
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "你是一位文字优美、情感细腻的散文作家。请用中文回答，保持简洁、深远且充满创意的风格，避免重复和套路。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.85
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
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
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
