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
        case footprint(PersistentIdentifier)
        case dailySummary(Date, [PersistentIdentifier], Bool)
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
    private var footprintTaskSet = Set<PersistentIdentifier>()
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
    
    private var config: [String: String]? {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: .mutableContainersAndLeaves, format: nil) as? [String: String] else {
            return nil
        }
        return plist
    }
    
    private var serviceSecret: String {
        config?["SERVICE_SECRET"] ?? ""
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
            guard let base = config?["PUBLIC_SERVICE_URL"], !base.isEmpty else {
                self.lastError = "Config.plist 缺失 PUBLIC_SERVICE_URL"
                return nil
            }
            guard let secret = config?["SERVICE_SECRET"], !secret.isEmpty else {
                self.lastError = "Config.plist 缺失 SERVICE_SECRET"
                return nil
            }
            
            urlString = base.hasSuffix("/") ? "\(base)\(endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint)" : "\(base)\(endpoint)"
            apiKey = secret
            model = "gpt-3.5-turbo"
        }
        
        guard let url = URL(string: urlString) else {
            self.lastError = "无效的请求地址: \(urlString)"
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
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
    
    func enqueueFootprintsForAnalysis(_ identifiers: [PersistentIdentifier]) {
        // 批量加入，减少重复计算
        let newIds = identifiers.filter { !footprintTaskSet.contains($0) }
        guard !newIds.isEmpty else { return }
        
        for id in newIds {
            footprintTaskSet.insert(id)
            self.taskQueue.append(.footprint(id))
        }
        self.processQueue()
    }

    func enqueueDailySummary(for date: Date, footprints: [Footprint], force: Bool = false) {
        let startOfDate = Calendar.current.startOfDay(for: date)
        if !force && dailySummaryDateSet.contains(startOfDate) { return }
        
        // 离线获取 ID，避免主线程持有对象
        let ids = footprints.map { $0.persistentModelID }
        
        dailySummaryDateSet.insert(startOfDate)
        self.taskQueue.append(.dailySummary(startOfDate, ids, force))
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
    func analyzeFootprint(_ footprint: Footprint) {
        if footprint.aiAnalyzed { return }
        self.enqueueFootprintsForAnalysis([footprint.persistentModelID])
    }
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
            case .footprint(let identifier):
                await self.processFootprintTask(identifier: identifier, context: context)
                // 任务处理完后，不一定要从 Set 移除，因为 footprint 本身有 aiAnalyzed 标记
            case .dailySummary(let date, let ids, let force):
                await self.processDailySummaryTask(date: date, ids: ids, context: context, force: force)
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

    private func processFootprintTask(identifier: PersistentIdentifier, context: ModelContext) async {
        guard let footprint = context.model(for: identifier) as? Footprint, !footprint.aiAnalyzed else { return }
        
        let locations = footprint.footprintLocations.map { ($0.latitude, $0.longitude) }
        var explicitPlaceName: String? = nil
        if let pid = footprint.placeID {
            let placeDescriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.placeID == pid })
            explicitPlaceName = (try? context.fetch(placeDescriptor))?.first?.name
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(String, String, Float, Bool), Never>) in
            self.analyzeFootprint(
                locations: locations,
                duration: footprint.duration,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                placeName: explicitPlaceName,
                address: footprint.address,
                activityName: footprint.getActivityType(from: [])?.name
            ) { title, reason, score, success in
                continuation.resume(returning: (title, reason, score, success))
            }
        }
        
        if result.3 {
            footprint.title = result.0
            footprint.reason = result.1
            footprint.aiScore = result.2
            footprint.aiAnalyzed = true
            try? context.save()
            
            if result.2 >= 0.7 {
                NotificationManager.shared.sendHighlightNotification(title: result.0, body: result.1)
            }
        }
    }
    
    private func processDailySummaryTask(date: Date, ids: [PersistentIdentifier], context: ModelContext, force: Bool = false) async {
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

        var footprintsUnderlying: [Footprint] = []
        for id in ids {
            if let fp = context.model(for: id) as? Footprint { footprintsUnderlying.append(fp) }
        }
        guard !footprintsUnderlying.isEmpty else { return }
        
        // 获取所有活动类型以便解析名称
        let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
        
        let sorted = footprintsUnderlying.sorted { $0.startTime < $1.startTime }
        var deduplicated: [String] = []
        var lastDescription: String? = nil
        
        for fp in sorted {
            let title = fp.title.isEmpty ? "点位记录" : fp.title
            if title == "正在获取位置..." || title == "点位记录" || title == "在某地停留" { continue }
            
            // 解析活动类型名称
            let activityName = fp.getActivityType(from: allActivities)?.name
            let description = activityName != nil ? "\(title)(\(activityName!))" : title
            
            if description == lastDescription { continue }
            
            deduplicated.append("[\(fp.startTime.formatted(.dateTime.hour().minute()))] \(description)")
            lastDescription = description
        }
        
        guard !deduplicated.isEmpty else { return }
        
        // 核心改动：比较本次数据的 Fingerprint 与数据库中已有的记录
        // 如果内容完全一致，即便 force 为 true 也可以跳过 AI 生成，从而避免因修改备注（不参与摘要）导致的频繁刷新
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
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            self.analyzeFootprint(
                locations: data.0,
                duration: data.1,
                startTime: data.2,
                endTime: data.3,
                placeName: data.4,
                address: data.5,
                activityName: data.6,
                isOngoing: true
            ) { title, _, _, success in
                continuation.resume(returning: success ? title : (data.4 ?? data.5 ?? "地点记录"))
            }
        }
        let calls = self.ongoingCompletions
        self.ongoingCompletions.removeAll()
        calls.forEach { $0(result) }
    }

    // MARK: - Core AI Logic (Legacy Callback Style for Internal Use)
    
    func analyzeFootprint(locations: [(Double, Double)], 
                          duration: TimeInterval, 
                          startTime: Date, 
                          endTime: Date, 
                          placeName: String? = nil,
                          address: String? = nil,
                          activityName: String? = nil,
                          isOngoing: Bool = false, 
                          completion: @escaping (String, String, Float, Bool) -> Void) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm"
        let startStr = dateFormatter.string(from: startTime)
        let endStr = dateFormatter.string(from: endTime)
        
        let weekdayStr = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: startTime) - 1]
        let dateContext = "公历\(startTime.formatted(.dateTime.year().month().day()))，\(weekdayStr)"
        
        var promptSnippet = ""
        if let name = placeName {
            promptSnippet = "用户正在“\(name)”"
            if let act = activityName { promptSnippet += "进行“\(act)”活动。" }
        } else {
            promptSnippet = address != nil ? "这里的具体参考地址是：\(address!)。" : "该位置是一个未曾记录的新去处。"
            if let act = activityName { promptSnippet += "用户正在这里进行“\(act)”。" }
        }

        let prompt = """
        用户在某地点停留：
        日期环境：\(dateContext)
        时间：\(startStr) - \(endStr)
        时长：\(Int(duration / 60))分钟
        地点与活动信息：\(promptSnippet)

        请根据以上信息进行分析并输出：
        1. 简短标题：10字以内，反映地点内涵或活动属性，严禁使用“地点记录”、“停留”、“发现足迹”等通用废话。
        2. 精彩程度：0.0 ~ 1.0。
        3. 足迹备注：20字以内，要求富有生活气息、温情且具有洞察力。
           【注意】：即便信息极少（如长时间居家），也要尝试从时间段、居家氛围提取美感或描述一种宁静感，绝对禁止出现“缺乏描述”、“没有详情”、“具体活动不明”等生硬死板的表述。

        返回格式（严格JSON）：
        { "title": "...", "score": 0.85, "reason": "..." }
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "你是一位拥有敏锐洞察力的生活美学专家，擅长从平凡的日常足迹中捕捉闪光点。你的回应必须是直接的 JSON 格式，文字风格温暖、精炼且富有感染力。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.85,
            "response_format": ["type": "json_object"]
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion(placeName ?? address ?? "地点记录", "无法发起请求", 0.0, false)
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                if let error = error {
                    self.lastError = "网络请求失败: \(error.localizedDescription)"
                    completion("地点记录", "网络请求失败", 0.0, false)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    let statusMsg = "HTTP \(httpResponse.statusCode)"
                    self.lastError = "AI 服务响应异常: \(statusMsg)"
                    completion("地点记录", statusMsg, 0.0, false)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                    self.lastError = "解析 AI 返回数据失败"
                    completion("地点记录", "解析失败", 0.0, false)
                    return
                }
                
                let clean = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let contentData = clean.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                    let t = parsed["title"] as? String ?? "新足迹"
                    let r = parsed["reason"] as? String ?? ""
                    let s = (parsed["score"] as? NSNumber)?.floatValue ?? 0.0
                    completion(t, r, s, true)
                } else {
                    completion("地点记录", "解析 JSON 失败", 0.0, false)
                }
            }
        }.resume()
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
