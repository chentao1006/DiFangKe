import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

class OpenAIService {
    static let shared = OpenAIService()
    
    private var analysisQueue: [Footprint] = []
    private var isProcessingQueue = false
    
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
    
    private var baseUrl: String {
        config?["PUBLIC_SERVICE_URL"] ?? "https://openai.ct106.com/v1"
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
    func analyzeFootprint(_ footprint: Footprint, completion: @escaping (Footprint) -> Void) {
        let locations = footprint.footprintLocations.map { ($0.latitude, $0.longitude) }
        
        analyzeFootprint(
            locations: locations,
            duration: footprint.duration,
            startTime: footprint.startTime,
            endTime: footprint.endTime,
            placeName: footprint.title == "时光里的足迹" ? nil : footprint.title,
            address: nil, // 可以后续扩展读取地址
            isOngoing: false
        ) { title, reason, score in
            DispatchQueue.main.async {
                footprint.title = title
                footprint.reason = reason
                footprint.aiScore = score
                // 此时不再由 AI 决定是否收藏，保持纯用户行为
                completion(footprint)
            }
        }
    }

    /// 将足迹加入分析队列，按序分析，间隔30秒
    func enqueueFootprintsForAnalysis(_ footprints: [Footprint]) {
        DispatchQueue.main.async {
            self.analysisQueue.append(contentsOf: footprints)
            self.processNextInQueue()
        }
    }

    private func processNextInQueue() {
        guard !isProcessingQueue, !analysisQueue.isEmpty else { return }
        
        isProcessingQueue = true
        let footprint = analysisQueue.removeFirst()
        
        analyzeFootprint(footprint) { _ in
            // 分析完成后，等待 30 秒再处理下一个
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                self.isProcessingQueue = false
                self.processNextInQueue()
            }
        }
    }
    
    func analyzeFootprint(locations: [(Double, Double)], 
                          duration: TimeInterval, 
                          startTime: Date, 
                          endTime: Date, 
                          placeName: String? = nil, 
                          placeTags: [String] = [],
                          address: String? = nil,
                          isOngoing: Bool = false, 
                          completion: @escaping (String, String, Float) -> Void) {
        guard let url = URL(string: "\(baseUrl)/chat/completions") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let deviceId = getDeviceId()
        let token = generateToken(deviceId: deviceId)
        
        request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.addValue(token, forHTTPHeaderField: "X-Token")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm"
        let startStr = dateFormatter.string(from: startTime)
        let endStr = dateFormatter.string(from: endTime)
        
        var promptSnippet = ""
        if let name = placeName {
            promptSnippet = "用户正在“\(name)”"
            if !placeTags.isEmpty {
                promptSnippet += "，相关的活动或氛围是：\(placeTags.joined(separator: "、"))"
            }
        } else if !placeTags.isEmpty {
            promptSnippet = "该地点的活动标签为：\(placeTags.joined(separator: "、"))。"
            if let addr = address {
                promptSnippet += " 这里的具体参考地址是：\(addr)。"
            }
        } else {
            promptSnippet = address != nil ? "这里的具体参考地址是：\(address!)。" : "该位置是一个未曾记录的新去处。"
        }
        let statusText = isOngoing ? "（目前正在此地停留中）" : ""
        
        let prompt = """
        用户在某地点停留\(statusText)：
        时间：\(startStr) - \(endStr)
        时长：\(Int(duration / 60))分钟
        地点信息：\(promptSnippet)

        请输出：
        1. 简短标题（10字以内，反映活动或地点特点。**绝对禁止使用“定位中停留”、“位置记录”、“非预设地点”、“具有标签”等死板或技术性词汇**，也不要直接复述地点信息。尽量具体且有生活气息，如“在咖啡馆小憩”或“办公中”）
        2. 精彩程度（0.0 ~ 1.0评分，1.0代表非常有意义或新奇）
        3. 简短原因（20字以内，禁止使用“记录停留”、“位置分析”等描述，应基于地点特点给出一个温馨或有见地的理由）

        返回格式（严格JSON）：
        {
          "title": "标题内容",
          "score": 0.85,
          "reason": "推荐理由"
        }
        """
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a professional life style and travel analyst. You provide concise, warm, and insightful snippets for a personal location diary app. Always respond in raw JSON without any markdown formatting."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.8
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("OpenAI Error: \(error?.localizedDescription ?? "Unknown")")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    
                    // Decode the raw JSON from content string
                    if let contentData = content.data(using: .utf8),
                       let parsedConfig = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                        let title = parsedConfig["title"] as? String ?? (parsedConfig["title"] as? String ?? "新足迹")
                        let reason = parsedConfig["reason"] as? String ?? "未提供详情"
                        let score = (parsedConfig["score"] as? NSNumber)?.floatValue ?? (parsedConfig["aiScore"] as? NSNumber)?.floatValue ?? 0.0
                        completion(title, reason, score)
                    }
                }
            } catch {
                print("Decode error: \(error)")
            }
        }.resume()
    }
    
    func generateTomorrowQuote(completion: @escaping (String, String) -> Void) {
        if let cache = cachedTomorrowQuote, let date = cacheDate, Calendar.current.isDateInToday(date) {
            DispatchQueue.main.async { completion(cache.0, cache.1) }
            return
        }
        
        guard let url = URL(string: "\(baseUrl)/chat/completions") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let deviceId = getDeviceId()
        let token = generateToken(deviceId: deviceId)
        
        request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.addValue(token, forHTTPHeaderField: "X-Token")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a poetic writer and life coach. You provide short, warm Chinese copy for a personal diary and travel app. Always respond in direct JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.9
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
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
        
        guard let url = URL(string: "\(baseUrl)/chat/completions") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let deviceId = getDeviceId()
        let token = generateToken(deviceId: deviceId)
        
        request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.addValue(token, forHTTPHeaderField: "X-Token")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a nostalgic and warm writer. You provide short, sentimental Chinese copy for a personal diary app. Always respond in direct JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.9
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
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
        
        guard let url = URL(string: "\(baseUrl)/chat/completions") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let deviceId = getDeviceId()
        let token = generateToken(deviceId: deviceId)
        
        request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.addValue(token, forHTTPHeaderField: "X-Token")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let footprintList = footprintDescriptions.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let prompt = """
        请根据以下用户今天的足迹列表，写一段极简的晚间回顾文案（20字以内）。
        
        足迹列表：
        \(footprintList)
        
        要求：
        1. 语气温馨、感性且有生活气息。
        2. 像是在对老朋友说话。
        3. 总结这一天的整体氛围或亮点。
        示例：“在漫长的工作后，晚风中那一杯咖啡最是治愈。”
        示例：“穿过熟悉的分叉路口，生活总有新的惊喜。”
        """
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a warm, poetic life companion. You summarize a person's day in a very short, touching sentence. Always respond in plain text Chinese."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.8
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                completion("那些路过的街头巷尾，都藏着今天的独家记忆。")
                return
            }
            
            DispatchQueue.main.async {
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()
    }
}
