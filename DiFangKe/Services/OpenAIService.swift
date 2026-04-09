import Foundation
import CryptoKit
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

class OpenAIService {
    static let shared = OpenAIService()
    
    private var analysisQueue: [PersistentIdentifier] = []
    private var isProcessingQueue = false
    var modelContainer: ModelContainer?
    
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
    
    private var customAiUrl: String {
        UserDefaults.standard.string(forKey: "customAiUrl") ?? "https://api.openai.com/v1"
    }
    
    private var customAiKey: String {
        UserDefaults.standard.string(forKey: "customAiKey") ?? ""
    }
    
    private var customAiModel: String {
        UserDefaults.standard.string(forKey: "customAiModel") ?? "gpt-4o-mini"
    }
    
    private var currentBaseUrl: String {
        if aiServiceType == "custom" {
            var url = customAiUrl
            if url.hasSuffix("/") { url.removeLast() }
            return url
        }
        return config?["PUBLIC_SERVICE_URL"] ?? "https://openai.ct106.com/v1"
    }
    
    private var currentModel: String {
        if aiServiceType == "custom" {
            return customAiModel
        }
        return "gpt-4o-mini"
    }
    
    private func prepareRequest(endpoint: String, body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: "\(currentBaseUrl)\(endpoint)") else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if aiServiceType == "custom" {
            let key = customAiKey
            if !key.isEmpty {
                request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        } else {
            let deviceId = getDeviceId()
            let token = generateToken(deviceId: deviceId)
            request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.addValue(token, forHTTPHeaderField: "X-Token")
        }
        
        // Inject model
        var updatedBody = body
        updatedBody["model"] = currentModel
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: updatedBody)
        return request
    }
    
    private let tomorrowQuoteKey = "cachedTomorrowQuote"
    private let tomorrowQuoteDateKey = "tomorrowQuoteDate"
    private let pastQuoteKey = "cachedPastQuote"
    private let pastQuoteDateKey = "pastQuoteDate"

    private var cachedTomorrowQuote: (String, String)? {
        get {
            guard let array = UserDefaults.standard.stringArray(forKey: tomorrowQuoteKey), array.count == 2 else { return nil }
            return (array[0], array[1])
        }
        set {
            if let val = newValue { UserDefaults.standard.set([val.0, val.1], forKey: tomorrowQuoteKey) }
        }
    }
    
    private var cacheDate: Date? {
        get { UserDefaults.standard.object(forKey: tomorrowQuoteDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: tomorrowQuoteDateKey) }
    }

    private var cachedPastQuote: (String, String)? {
        get {
            guard let array = UserDefaults.standard.stringArray(forKey: pastQuoteKey), array.count == 2 else { return nil }
            return (array[0], array[1])
        }
        set {
            if let val = newValue { UserDefaults.standard.set([val.0, val.1], forKey: pastQuoteKey) }
        }
    }
    
    private var pastCacheDate: Date? {
        get { UserDefaults.standard.object(forKey: pastQuoteDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: pastQuoteDateKey) }
    }
    
    private func getDeviceId() -> String {
        // Mock device ID retrieval, could use UIDevice.current.identifierForVendor
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        #else
        return "simulate-device-id"
        #endif
    }
    
    private func generateToken(deviceId: String) -> String {
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let input = serviceSecret + deviceId + "\(hour)"
        
        let data = Data(input.utf8)
        let digest = Insecure.MD5.hash(data: data)
        
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    
    // 便捷方法：直接分析 Footprint 对象
    // 注意：此方法现在仅在主线程且 context 有效时使用比较安全
    func analyzeFootprint(_ footprint: Footprint, completion: @escaping (Footprint) -> Void) {
        // 尝试获取 context - 必须在访问 persistentModelID 前检查，否则对临时对象访问 ID 可能崩溃
        guard let context = footprint.modelContext else {
            completion(footprint)
            return
        }

        let locations = footprint.footprintLocations.map { ($0.latitude, $0.longitude) }
        
        // 只使用数据库中的正式名称作为背景，完全避免使用不稳定的标题进行判断
        var explicitPlaceName: String? = nil
        let footprintID = footprint.persistentModelID
        
        if let pid = footprint.placeID {
            let descriptor = FetchDescriptor<Place>(predicate: #Predicate<Place> { $0.placeID == pid })
            explicitPlaceName = (try? context.fetch(descriptor))?.first?.name
        }
        
        // 获取活动名称供 AI 参考
        var activityName: String? = nil
        if let aid = footprint.activityTypeValue {
            let activityFetch = FetchDescriptor<ActivityType>()
            activityName = (try? context.fetch(activityFetch))?.first(where: { $0.id.uuidString == aid || $0.name == aid })?.name
        }
        
        analyzeFootprint(
            locations: locations,
            duration: footprint.duration,
            startTime: footprint.startTime,
            endTime: footprint.endTime,
            placeName: explicitPlaceName,
            address: footprint.address,
            activityName: activityName,
            isOngoing: false
        ) { title, reason, score, success in
            Task { @MainActor in
                // 核心修复：从 ID 重新恢复模型且在主线程操作，避免 capturing self/model across thread boundaries
                guard let fp = context.model(for: footprintID) as? Footprint else {
                    completion(footprint)
                    return
                }
                
                if success {
                    if !fp.isTitleEditedByHand {
                        fp.title = title
                    }
                    fp.reason = reason
                    fp.aiScore = score
                    fp.aiAnalyzed = true
                    try? context.save()
                }
                completion(fp)
            }
        }
    }

    /// 将足迹 ID 加入分析队列，按序分析，间隔30秒
    func enqueueFootprintsForAnalysis(_ identifiers: [PersistentIdentifier]) {
        DispatchQueue.main.async {
            self.analysisQueue.append(contentsOf: identifiers)
            self.processNextInQueue()
        }
    }

    private func processNextInQueue() {
        guard !isProcessingQueue, !analysisQueue.isEmpty, let container = modelContainer else { return }
        
        isProcessingQueue = true
        let identifier = analysisQueue.removeFirst()
        
        // 在后台线程创建新 context 进行分析
        Task.detached(priority: .background) {
            let context = ModelContext(container)
            guard let footprint = context.model(for: identifier) as? Footprint else {
                DispatchQueue.main.async {
                    self.isProcessingQueue = false
                    self.processNextInQueue()
                }
                return
            }
            
            // 执行模型分析
            let locations = footprint.footprintLocations.map { ($0.latitude, $0.longitude) }
            var explicitPlaceName: String? = nil
            if let pid = footprint.placeID {
                let descriptor = FetchDescriptor<Place>(predicate: #Predicate<Place> { $0.placeID == pid })
                explicitPlaceName = (try? context.fetch(descriptor))?.first?.name
            }
            
            // 获取活动名称供 AI 参考
            var activityName: String? = nil
            if let aid = footprint.activityTypeValue {
                let activityFetch = FetchDescriptor<ActivityType>()
                activityName = (try? context.fetch(activityFetch))?.first(where: { $0.id.uuidString == aid || $0.name == aid })?.name
            }
            
            self.analyzeFootprint(
                locations: locations,
                duration: footprint.duration,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                placeName: explicitPlaceName,
                address: footprint.address,
                activityName: activityName,
                isOngoing: false
            ) { title, reason, score, success in
                if success {
                    if !footprint.isTitleEditedByHand {
                        footprint.title = title
                    }
                    footprint.reason = reason
                    footprint.aiScore = score
                    footprint.aiAnalyzed = true
                    try? context.save()
                }
                
                // 分析完成后，等待 30 秒再处理下一个
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    self.isProcessingQueue = false
                    self.processNextInQueue()
                }
            }
        }
    }
    
    private func dateContextString(for date: Date) -> String {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayStr = weekdays[weekday - 1]
        
        let isWeekend = (weekday == 1 || weekday == 7)
        
        let fullDate = date.formatted(.dateTime.year().month().day())
        
        return "公历\(fullDate)，\(weekdayStr)\(isWeekend ? "（周末）" : "")"
    }

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
        let dateContext = dateContextString(for: startTime)
        
        var promptSnippet = ""
        if let name = placeName {
            promptSnippet = "用户正在“\(name)”"
            if let act = activityName {
                promptSnippet += "进行“\(act)”活动。"
            }
        } else {
            promptSnippet = address != nil ? "这里的具体参考地址是：\(address!)。" : "该位置是一个未曾记录的新去处。"
            if let act = activityName {
                promptSnippet += "用户正在这里进行“\(act)”。"
            }
        }

        let statusText = isOngoing ? "（目前正在此地停留中）" : ""
        
        let prompt = """
        用户在某地点停留\(statusText)：
        日期环境：\(dateContext)
        时间：\(startStr) - \(endStr)
        时长：\(Int(duration / 60))分钟
        地点与活动信息：\(promptSnippet)

        请输出：
        1. 简短标题（10字以内，应反映地点名称或具体的活动，如“在咖啡馆停留”、“公司办公”、“超市购物”或“回家”。**绝对禁止使用“定位中停留”、“位置记录”、“非预设地点”等词汇**。禁止使用单纯的感叹或文学化描述，如“时光流逝”。应明确所在的“地方”。）
        2. 精彩程度（0.0 ~ 1.0评分，1.0代表非常有意义或新奇。如果是节假日或有纪念意义的活动，评分可以适当高一点）
        3. 简短原因（20字以内，基于地点特点、日期环境给出一个温馨或有见地的理由）

        返回格式（严格JSON）：
        {
          "title": "标题内容",
          "score": 0.85,
          "reason": "推荐理由"
        }
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "You are a professional life style and travel analyst. You provide concise, warm, and insightful snippets for a personal location diary app. Always respond in direct JSON format without any markdown code blocks."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.8,
            "response_format": ["type": "json_object"]
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            DispatchQueue.main.async { completion(placeName ?? address ?? "地点记录", "分析中...", 0.0, false) }
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("OpenAI Error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion("新足迹", "网络连接异常 (\(error.localizedDescription))", 0.0, false) }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("OpenAI Error: HTTP \(httpResponse.statusCode)")
                let msg = httpResponse.statusCode == 401 ? "认证失败，请检查服务配置" : "服务器繁忙 (错误码 \(httpResponse.statusCode))"
                DispatchQueue.main.async { completion("新足迹", msg, 0.0, false) }
                return
            }
            
            guard let data = data else {
                print("OpenAI Error: No data received")
                DispatchQueue.main.async { completion("新足迹", "未收到有效的分析结果", 0.0, false) }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorJson = json["error"] as? [String: Any], let errorMsg = errorJson["message"] as? String {
                         print("OpenAI API Error: \(errorMsg)")
                         DispatchQueue.main.async { completion("新足迹", "分析服务返回错误：\(errorMsg)", 0.0, false) }
                         return
                    }
                    
                    if let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        
                        // Clean content string of markdown codes if AI adds them (common issue)
                        let cleanContent = content.replacingOccurrences(of: "```json", with: "")
                            .replacingOccurrences(of: "```", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Decode the potentially cleaned JSON from content string
                        if let contentData = cleanContent.data(using: .utf8),
                           let parsedConfig = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                            let title = parsedConfig["title"] as? String ?? "新足迹"
                            let reason = parsedConfig["reason"] as? String ?? "在这个熟悉或陌生的地方留下了一段回忆。"
                            let score = (parsedConfig["score"] as? NSNumber)?.floatValue ?? (parsedConfig["aiScore"] as? NSNumber)?.floatValue ?? 0.0
                            DispatchQueue.main.async { completion(title, reason, score, true) }
                            return
                        }
                    }
                }
                
                print("OpenAI Error: Failed to parse valid content from response")
                DispatchQueue.main.async { completion("新足迹", "解析结果失败", 0.0, false) }
            } catch {
                print("Decode error: \(error)")
                DispatchQueue.main.async { completion("新足迹", "解析结果异常", 0.0, false) }
            }
        }.resume()
    }
    
    func generateTomorrowQuote(completion: @escaping (String, String) -> Void) {
        if let cache = cachedTomorrowQuote, let date = cacheDate, Calendar.current.isDateInToday(date) {
            DispatchQueue.main.async { completion(cache.0, cache.1) }
            return
        }
        
        let prompt = """
        请为个人位置足迹轨迹应用“地方客”的“明天”预告页写一段温馨、治愈或富有哲理的文案。
        
        要求：
        1. 标题（10字以内，如“明天是个未拆的礼物”）
        2. 描述（20字以内，如“愿明天的你，能在平凡中发现惊喜。”）
        3. 文案要能鼓励用户去探索世界、感受生活。
        4. 每次生成的文案要有细微差别，保持新鲜感。

        返回格式（严格JSON）：
        {
          "title": "标题内容",
          "subtitle": "描述内容"
        }
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "You are a poetic writer and life coach. You provide short, warm Chinese copy for a personal diary and travel app. Always respond in direct JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.9
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            DispatchQueue.main.async { completion("明天是个未拆的礼物", "愿明天的你，能在平凡中发现惊喜。") }
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Quote Error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion("明天是个未拆的礼物", "愿明天的你，能在平凡中发现惊喜。") }
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                DispatchQueue.main.async { completion("明天是个未拆的礼物", "愿明天的你，能在平凡中发现惊喜。") }
                return
            }
            
            // Clean content string of markdown codes if AI adds them
            let cleanContent = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let contentData = cleanContent.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
               let title = parsed["title"] as? String,
               let sub = parsed["subtitle"] as? String {
                self?.cachedTomorrowQuote = (title, sub)
                self?.cacheDate = Date()
                DispatchQueue.main.async { completion(title, sub) }
            } else {
                DispatchQueue.main.async { completion("明天是个未拆的礼物", "愿明天的你，能在平凡中发现惊喜。") }
            }
        }.resume()
    }
    
    func generatePastQuote(completion: @escaping (String, String) -> Void) {
        if let cache = cachedPastQuote, let date = pastCacheDate, Calendar.current.isDateInToday(date) {
            DispatchQueue.main.async { completion(cache.0, cache.1) }
            return
        }
        
        let prompt = """
        请为个人位置足迹轨迹应用“地方客”的“远古边界”页（即第一条数据之前的空白页）写一段文案。
        
        背景：用户滚动到了应用记录开始之初的更早一天，那里没有数据。文案表达一种“真希望能早点遇到你”、“如果早点记录就好了”的遗憾与温情。
        
        要求：
        1. 标题（10字以内，如“真希望能早点遇到你”）
        2. 描述（20字以内，如“要是早点遇见，就能记录更多精彩了。”）
        3. 充满感性、怀旧且温馨的色调。
        4. 每次生成的文案要有细微差别。

        返回格式（严格JSON）：
        {
          "title": "标题内容",
          "subtitle": "描述内容"
        }
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "You are a nostalgic and warm writer. You provide short, sentimental Chinese copy for a personal diary app. Always respond in direct JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.9
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            DispatchQueue.main.async { completion("真希望能早点遇到你", "要是早点遇见，就能记录更多精彩了。") }
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Quote Error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion("真希望能早点遇到你", "要是早点遇见，就能记录更多精彩了。") }
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                DispatchQueue.main.async { completion("真希望能早点遇到你", "要是早点遇见，就能记录更多精彩了。") }
                return
            }
            
            let cleanContent = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let contentData = cleanContent.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
               let title = parsed["title"] as? String,
               let sub = parsed["subtitle"] as? String {
                self?.cachedPastQuote = (title, sub)
                self?.pastCacheDate = Date()
                DispatchQueue.main.async { completion(title, sub) }
            } else {
                DispatchQueue.main.async { completion("真希望能早点遇到你", "要是早点遇见，就能记录更多精彩了。") }
            }
        }.resume()
    }
    
    func generateDailySummary(footprintDescriptions: [String], completion: @escaping (String) -> Void) {
        guard !footprintDescriptions.isEmpty else {
            completion("今天过得轻盈而自在。")
            return
        }
        
        let footprintList = footprintDescriptions.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let prompt = """
        请根据以下用户今天的足迹列表，写一段极简的晚间回顾文案（15字以内）。
        
        要求：
        1. 必须结合足迹列表中的具体地点名称或活动内容进行创作，不可仅使用空洞的通用语。
        2. 从列表中挑选 1-2 个最具代表性的地点或瞬时感受。
        3. 语气温馨、感性且有生活气息。
        4. 示例：“在西单的喧嚣之后，北海公园的落日格外温柔。”
        5. 示例：“从写字楼的繁忙到家门口的点点灯火，辛苦了。”
        
        足迹列表：
        \(footprintList)
        """
        
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "You are a warm, poetic life companion. You summarize a person's day in a very short, touching sentence. Always respond in plain text Chinese."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.8
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion("路过的街头，藏着今天的独家记忆。")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Summary Error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion("路过的街头，藏着今天的独家记忆。") }
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                DispatchQueue.main.async { completion("路过的街头，藏着今天的独家记忆。") }
                return
            }
            
            DispatchQueue.main.async {
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()
    }
    
    func generateAndSaveDailySummary(for date: Date, footprints: [Footprint], modelContext: ModelContext) {
        guard !footprints.isEmpty else { return }
        
        let sorted = footprints.sorted { $0.startTime < $1.startTime }
        let descriptions = sorted.compactMap { fp -> String? in
            let title = fp.title.isEmpty ? "点位记录" : fp.title
            if title == "正在获取位置..." || title == "点位记录" { return nil }
            let time = fp.startTime.formatted(.dateTime.hour().minute())
            return "[\(time)] \(title)"
        }
        
        guard !descriptions.isEmpty else { return }
        
        generateDailySummary(footprintDescriptions: descriptions) { summary in
            Task { @MainActor in
                let startOfDay = Calendar.current.startOfDay(for: date)
                let descriptor = FetchDescriptor<DailyInsight>()
                let allSummaries = (try? modelContext.fetch(descriptor)) ?? []
                
                if let existing = allSummaries.first(where: { 
                    guard let d = $0.date else { return false }
                    return Calendar.current.isDate(d, inSameDayAs: startOfDay) 
                }) {
                    existing.content = summary
                    existing.aiGenerated = true
                    try? modelContext.save()
                } else {
                    let newSummary = DailyInsight(date: startOfDay, content: summary, aiGenerated: true)
                    modelContext.insert(newSummary)
                    try? modelContext.save()
                }
            }
        }
    }
    
    func getCustomSummary(prompt: String, completion: @escaping (String?) -> Void) {
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "You are a warm, poetic life companion. You summarize data into a short, touching sentence in Chinese."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion(nil)
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            DispatchQueue.main.async {
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()
    }
    
    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Ping"]
            ],
            "max_tokens": 5
        ]
        
        guard let request = prepareRequest(endpoint: "/chat/completions", body: body) else {
            completion(false, "无效的 URL 配置")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(false, "连接失败: \(error.localizedDescription)") }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    DispatchQueue.main.async { completion(true, "连接成功") }
                } else {
                    let msg = httpResponse.statusCode == 401 ? "认证失败，请检查 API Key" : "服务器返回错误: \(httpResponse.statusCode)"
                    DispatchQueue.main.async { completion(false, msg) }
                }
            } else {
                DispatchQueue.main.async { completion(false, "未知响应") }
            }
        }.resume()
    }
}
