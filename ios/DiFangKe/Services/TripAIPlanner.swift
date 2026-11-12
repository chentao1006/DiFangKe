import Foundation
import CoreLocation
import Observation

// MARK: - Itinerary snapshot

/// Flat value copies of the editor's draft rows, taken on the main actor
/// without any grouping or sorting. `TripAIItinerarySnapshot.make` turns them
/// into the per-day structure off the main actor.
struct TripAIItineraryRows: Sendable {
    struct Day: Sendable {
        let id: UUID
        let day: Date
        /// Date shown for the day in the editor; nil when the plan has no dates.
        let displayDate: Date?
    }

    struct Item: Sendable {
        let id: UUID
        let tripDayID: UUID
        let kindRaw: String
        let orderIndex: Int
        let placeName: String?
        let address: String?
        let cityName: String?
        let latitude: Double?
        let longitude: Double?
        let transportTypeRaw: String?
        let startTime: Date?
        let notes: String
        let planStatusRaw: String
    }

    struct City: Sendable {
        let tripDayID: UUID
        let orderIndex: Int
        let name: String
        let countryName: String
        let latitude: Double?
        let longitude: Double?
    }

    let tripID: UUID
    let title: String
    let notes: String
    let activityName: String?
    let homeCityName: String?
    let homeLatitude: Double?
    let homeLongitude: Double?
    let isActive: Bool
    /// Days in the order the editor shows them.
    let days: [Day]
    let items: [Item]
    let cities: [City]
}

/// Plain value copy of the itinerary being edited. It is taken from the
/// editor's draft context on the main actor and everything derived from it
/// (prompt, diff, preview) is computed off the main actor.
struct TripAIItinerarySnapshot: Sendable {
    struct Stop: Sendable {
        let itemID: UUID
        let name: String
        let address: String?
        let cityName: String?
        let latitude: Double?
        let longitude: Double?
        let transportTypeRaw: String?
        /// Minutes after local midnight; nil when no arrival time is planned.
        let arrivalMinutes: Int?
        let notes: String
        let isCompleted: Bool
    }

    struct City: Sendable {
        let name: String
        let countryName: String
        let latitude: Double?
        let longitude: Double?
    }

    struct Day: Sendable {
        let dayID: UUID
        let date: Date?
        let cities: [City]
        let stops: [Stop]
    }

    let tripID: UUID
    let title: String
    let notes: String
    let activityName: String?
    /// Where the trip starts and finally returns to.
    let homeCity: City?
    let isActive: Bool
    let days: [Day]

    static func make(from rows: TripAIItineraryRows) -> TripAIItinerarySnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let stopKind = TripItemKind.stop.rawValue
        let itemsByDay = Dictionary(grouping: rows.items.filter { $0.kindRaw == stopKind }, by: \.tripDayID)
        let citiesByDay = Dictionary(grouping: rows.cities, by: \.tripDayID)
        let days = rows.days.map { day -> Day in
            let dayStart = calendar.startOfDay(for: day.day)
            let stops = (itemsByDay[day.id] ?? [])
                .sorted { $0.orderIndex < $1.orderIndex }
                .map { item -> Stop in
                    // A planned stop stored at midnight is the legacy "no time" value.
                    let arrival = item.startTime.flatMap { time -> Int? in
                        guard time != dayStart else { return nil }
                        let components = calendar.dateComponents([.hour, .minute], from: time)
                        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
                    }
                    return Stop(
                        itemID: item.id,
                        name: item.placeName ?? item.address ?? item.cityName ?? "地点",
                        address: item.address,
                        cityName: item.cityName,
                        latitude: item.latitude,
                        longitude: item.longitude,
                        transportTypeRaw: item.transportTypeRaw,
                        arrivalMinutes: arrival,
                        notes: item.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                        isCompleted: item.planStatusRaw == "completed"
                    )
                }
            let cities = (citiesByDay[day.id] ?? [])
                .sorted { $0.orderIndex < $1.orderIndex }
                .map { City(name: $0.name, countryName: $0.countryName, latitude: $0.latitude, longitude: $0.longitude) }
            return Day(dayID: day.id, date: day.displayDate, cities: cities, stops: stops)
        }
        return TripAIItinerarySnapshot(
            tripID: rows.tripID,
            title: rows.title,
            notes: rows.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            activityName: rows.activityName,
            homeCity: rows.homeCityName.flatMap { name in
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : City(
                    name: name,
                    countryName: "",
                    latitude: rows.homeLatitude,
                    longitude: rows.homeLongitude
                )
            },
            isActive: rows.isActive,
            days: days
        )
    }
}

// MARK: - Conversation persistence

struct TripAIChatMessage: Codable, Identifiable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: UUID
    var role: Role
    /// Text shown in the conversation. For answers this excludes the JSON block.
    var text: String
    /// Structured itinerary change attached to an answer, as returned by the model.
    var planJSON: String?
    /// Short stop references used in the itinerary the answer was based on.
    var stopRefs: [String: UUID]?
    var createdAt: Date
    var appliedAt: Date?
    /// The answer was stopped by the user before it finished.
    var isInterrupted: Bool
    /// What applying actually changed, frozen at that moment. Optional so
    /// conversation files written before this field keep decoding.
    var appliedChanges: [TripAIPlanChange]?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        planJSON: String? = nil,
        stopRefs: [String: UUID]? = nil,
        createdAt: Date = Date(),
        appliedAt: Date? = nil,
        isInterrupted: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.planJSON = planJSON
        self.stopRefs = stopRefs
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.isInterrupted = isInterrupted
    }
}

/// One file per trip. Version 1 of this format; later fields must be optional
/// so files written by earlier builds keep decoding.
struct TripAIConversation: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var tripID: UUID
    var messages: [TripAIChatMessage]
    var updatedAt: Date
}

/// Conversations are kept as standalone JSON files outside every SwiftData
/// store, so this feature never changes the footprint or trip schemas.
actor TripAIConversationStore {
    static let shared = TripAIConversationStore()

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("TripAIConversations", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func fileURL(for tripID: UUID) -> URL {
        directory.appendingPathComponent("\(tripID.uuidString).json")
    }

    func load(tripID: UUID) -> TripAIConversation? {
        guard let data = try? Data(contentsOf: fileURL(for: tripID)) else { return nil }
        return try? decoder.decode(TripAIConversation.self, from: data)
    }

    func save(_ conversation: TripAIConversation) {
        let url = fileURL(for: conversation.tripID)
        if conversation.messages.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(conversation)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("⚠️ TripAIConversationStore: failed to save conversation \(conversation.tripID): \(error)")
        }
    }

    /// Clears the applied state of answers whose changes were discarded.
    func markUnapplied(tripID: UUID, messageIDs: Set<UUID>) {
        guard var conversation = load(tripID: tripID) else { return }
        var changed = false
        for index in conversation.messages.indices where messageIDs.contains(conversation.messages[index].id) {
            conversation.messages[index].appliedAt = nil
            conversation.messages[index].appliedChanges = nil
            changed = true
        }
        guard changed else { return }
        conversation.updatedAt = Date()
        save(conversation)
    }

    func remove(tripIDs: Set<UUID>) {
        for tripID in tripIDs {
            try? FileManager.default.removeItem(at: fileURL(for: tripID))
        }
    }
}

// MARK: - Structured plan

enum TripAIFieldUpdate<Value: Sendable & Equatable>: Sendable, Equatable {
    case keep
    case clear
    case set(Value)
}

/// The itinerary change exactly as the model described it, still using refs.
struct TripAIPlan: Sendable {
    struct Entry: Sendable {
        let ref: String?
        let name: String?
        let city: String?
        let transport: TripAIFieldUpdate<String>
        let arrivalMinutes: TripAIFieldUpdate<Int>
        let notes: TripAIFieldUpdate<String>
    }

    struct Day: Sendable {
        let dayNumber: Int
        let entries: [Entry]
    }

    let days: [Day]
    /// Days whose place list could not be read in full; they stay unchanged
    /// rather than being taken as "keep nothing".
    var unreadableDays: [Int] = []
}

/// A plan bound to the current itinerary: refs are replaced by item IDs and
/// day numbers by day IDs. This is what the editor applies.
struct TripAIResolvedPlan: Sendable {
    struct Entry: Sendable {
        /// nil for a new place, which must be found through place search.
        let existingItemID: UUID?
        let name: String
        let cityName: String?
        let transport: TripAIFieldUpdate<String>
        let arrivalMinutes: TripAIFieldUpdate<Int>
        let notes: TripAIFieldUpdate<String>
    }

    struct Day: Sendable {
        let dayID: UUID
        let dayNumber: Int
        let entries: [Entry]
    }

    let days: [Day]
    /// Existing stops the plan drops. Completed stops are never included.
    let removedItemIDs: Set<UUID>
}

struct TripAIPlanChange: Sendable, Identifiable, Codable, Equatable {
    enum Kind: String, Sendable, Codable {
        case add
        case remove
        case move
        case reorder
        case transport
        case time
        case notes
        /// A new place that could not be found and was not added.
        case skipped

        var symbol: String {
            switch self {
            case .add: return "plus.circle.fill"
            case .remove: return "minus.circle.fill"
            case .skipped: return "exclamationmark.circle.fill"
            case .move: return "arrow.right.circle.fill"
            case .reorder: return "arrow.up.arrow.down.circle.fill"
            case .transport: return "car.circle.fill"
            case .time: return "clock.fill"
            case .notes: return "text.bubble.fill"
            }
        }
    }

    let id: Int
    let kind: Kind
    let text: String
    /// For `.add`: the place name the AI gave, and the day it goes to.
    var placeName: String?
    var dayNumber: Int?
    /// For `.remove`: the stop that would be deleted.
    var itemID: UUID?
}

struct TripAIPlanPreview: Sendable {
    let plan: TripAIResolvedPlan
    let changes: [TripAIPlanChange]
    let warnings: [String]
    /// Number of new places; when every one of them is not found and nothing
    /// else changes, applying leaves the itinerary as it was.
    let addedPlaceCount: Int

    var hasChanges: Bool { !changes.isEmpty }
    var onlyAddsPlaces: Bool { addedPlaceCount == changes.count }
}

struct TripAIApplyOutcome {
    /// New places that could not be found and were skipped.
    var unresolvedNames: [String] = []
    /// Name the AI gave → name of the place actually added from map search.
    var addedNames: [String: String] = [:]
    /// Name the AI gave → existing stop it turned out to be; not added again.
    var existingNames: [String: String] = [:]
    /// Existing stops a "new" place turned out to be, kept instead of removed.
    var keptItemIDs: Set<UUID> = []
    /// Parts of the plan that were not taken over as given, for example a
    /// walking leg far longer than walking allows.
    var adjustmentNotes: [String] = []
    /// nil when the change could not be saved.
    var errorMessage: String?
    /// Restores the itinerary as it was before this application.
    var undo: (@MainActor () -> Bool)?
}

// MARK: - Prompt, parsing and preview (pure, run off the main actor)

enum TripAIPlanner {
    static let defaultPrompt = "帮我优化这个行程"

    /// Quick prompts shown under an empty conversation; the default prompt is
    /// already in the input field, so it is not repeated here.
    static let suggestions = [
        "节奏放慢一点，别太累",
        "推荐几个值得去的地方",
        "调整顺序，少走回头路",
        "交通方式怎么安排更省时"
    ]

    struct Request: Sendable {
        let messages: [[String: String]]
        let stopRefs: [String: UUID]
    }

    // MARK: Prompt

    static func makeRequest(
        snapshot: TripAIItinerarySnapshot,
        history: [TripAIChatMessage],
        userText: String,
        historyLimit: Int,
        now: Date
    ) -> Request {
        var refs: [String: UUID] = [:]
        var refByItemID: [UUID: String] = [:]
        var counter = 0
        for day in snapshot.days {
            for stop in day.stops {
                counter += 1
                let ref = "S\(counter)"
                refs[ref] = stop.itemID
                refByItemID[stop.itemID] = ref
            }
        }

        let itinerary = itineraryJSON(snapshot: snapshot, refByItemID: refByItemID)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(dayCount: snapshot.days.count)],
            ["role": "system", "content": "今天是\(dateFormatter.string(from: now))。下面是用户当前的行程（JSON）。每次对话都以这份最新行程为准：用户已经应用的调整都已体现在其中，没有体现的就是没有应用。之前回答中的 ref 编号可能已经变化。不要在回答里描述调整是否已被应用，应用由用户在 App 里操作。\n\(itinerary)"]
        ]

        let recent = historyLimit > 0 ? Array(history.suffix(historyLimit)) : []
        for message in recent {
            switch message.role {
            case .user:
                messages.append(["role": "user", "content": message.text])
            case .assistant:
                // Only what the assistant actually said: status notes added
                // here get imitated in new answers as if they were true.
                let content = message.text
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                messages.append(["role": "assistant", "content": content])
            }
        }
        messages.append(["role": "user", "content": userText])
        return Request(messages: messages, stopRefs: refs)
    }

    private static func systemPrompt(dayCount: Int) -> String {
        let transportOptions = TransportType.allCases
            .map { "\($0.rawValue)（\($0.localizedName)）" }
            .joined(separator: "、")
        let config = AppConfig.shared
        let distanceRule = "步行或跑步只用于 \(kmText(config.tripAIWalkingMaxKm)) 公里以内，自行车或电动车只用于 \(kmText(config.tripAICyclingMaxKm)) 公里以内，更远一律用汽车、公交、轨道交通、火车/高铁或飞机等。"
        let dayShape = dayCount > 1
            ? "这是一趟 \(dayCount) 天的行程：第 1 天从常居地出发，中间每晚都在目的地住宿过夜，只有第 \(dayCount) 天结束时才返回常居地。绝不能在第 1 天到第 \(dayCount - 1) 天安排返回常居地，也不能让用户第二天再从常居地重新出发。"
            : "这是一趟 1 天的行程：从常居地出发，当天结束时返回常居地，不需要住宿。"
        return """
        你是一位经验丰富、讲究常识的旅行规划师，正在帮助用户完善 App 里的一份行程计划。

        行程常识（必须遵守，违背常识的安排一律不要给出）：
        1. \(dayShape)
        2. 出发与返程：第 1 天第一个地点的上一站是常居地（homeCity），它的 fromPrevKm 是与常居地的距离；之后每天第一个地点的上一站是前一天的最后一个地点（通常就是住处）。returnKm 是最后一个地点回到常居地的距离，只在最后一天考虑返程时间。返回常居地只在正文里说明，不要作为地点写进安排。没有 homeCity 时不要猜测出发地。
        3. 住宿：酒店、民宿、客栈等住处是过夜的地方。入住当天把它安排为当天的最后一站，到达时间在下午或傍晚（一般 14:00 之后）；次日从住处出发，退房在上午（一般 12:00 前）。连住多晚的同一住处只出现一次，放在第一晚，之后几天不必重复添加。不要安排上午入住、下午就离开，也不要建议当天往返却又订了住宿。
        4. 时间安排：到达时间要和上一站的距离、交通方式、在上一站停留的时长相符；景点在开放时间内参观，留出午餐和晚餐时间；每天的地点数量和移动距离要适中，不要把一天塞满。
        5. 交通方式必须与实际距离相符：\(distanceRule)新增地点时，也要按它与上一站的实际距离选择交通方式。
        6. 只推荐真实存在、能在地图上搜到的具体地点，每个安排只写一个地点，使用常用的中文全称；不要只写城市或区县名，也不要写“A 或 B”这样的备选，不要虚构。

        回答方式：
        1. 先理解用户的偏好和要求；信息不足时可以做出合理假设并简单说明，不要反复追问。
        2. 结合每天的城市、地点顺序、与上一站的距离（fromPrevKm）、交通方式、到达时间和备注，从顺路程度、节奏与体力、开放时间、交通衔接、季节天气等角度给出具体、可执行的建议。
        3. 用自然的中文作答，简洁具体，说明理由。可以使用 Markdown 让内容更清晰：小标题（##）、有序或无序列表、加粗；手机屏幕较窄，尽量不用表格，不要输出除下面 json 以外的代码块。
        4. 如果建议需要修改行程（增删地点、调整顺序、换到别的天、修改交通方式、到达时间或备注），在回答的最后附上一个 ```json 代码块描述修改后的安排；如果只是回答问题或用户还在讨论、不需要改动，就不要输出代码块。正文和代码块中的安排必须一致。
        5. 代码块之后不要再写任何内容，正文里也不要提及 JSON、代码块或 ref 编号，用地点名称来描述。

        代码块格式：
        {"days":[{"day":1,"stops":[{"ref":"S1"},{"ref":"S2","transport":"car","arrival":"14:00"},{"name":"地点全称","city":"所在城市","transport":"slow","arrival":"16:30","notes":"简短备注"}]}]}

        代码块规则：
        - days 只列出需要改动的天，未列出的天保持不变。行程共 \(dayCount) 天，day 只能是 1 到 \(dayCount)。
        - 每个列出的天必须按新的先后顺序给出当天要保留的全部地点；该天原有但没有列出的地点会被删除。
        - 行程里已经有的地点（包括名称写法不同但实际是同一处的地点）只能用 ref 引用，绝不能再用 name 新增一次；保留、调整顺序或移到另一天都用 ref。要把现有地点移到另一天，只需在目标那天列出它的 ref。
        - 新增地点不写 ref，必须写 name 和 city。
        - transport 表示从上一站（第 1 天第一个地点则为常居地）前往该地点的交通方式，只能是：\(transportOptions)；要清除写 null，不改就省略。
        - arrival 是 24 小时制 "HH:mm" 的到达时间，要清除写 null，不改就省略。
        - notes 是该地点的备注，只写一句简短实用的提示（例如开放时间、预约或必看点），详细说明放在正文里；要清除写 ""，不改就省略。
        - completed 为 true 的地点用户已经去过，必须保留在原来那天，不要删除或移动。
        - 常居地不是地点，不要把“返回常居地”或常居地城市写进 stops。
        """
    }

    private static func itineraryJSON(snapshot: TripAIItinerarySnapshot, refByItemID: [UUID: String]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "M月d日 EEEE"

        // The first stop is reached from the home city, as in the editor's
        // route rows, so its distance is measured from there.
        let homeLocation: CLLocation? = snapshot.homeCity.flatMap { home in
            guard let latitude = home.latitude, let longitude = home.longitude else { return nil }
            return CLLocation(latitude: latitude, longitude: longitude)
        }
        var previousCoordinate = homeLocation
        var days: [[String: Any]] = []
        for (index, day) in snapshot.days.enumerated() {
            var stops: [[String: Any]] = []
            for stop in day.stops {
                var value: [String: Any] = [
                    "ref": refByItemID[stop.itemID] ?? "",
                    "name": stop.name
                ]
                if let city = stop.cityName, !city.isEmpty { value["city"] = city }
                if let address = stop.address, !address.isEmpty, address != stop.name { value["address"] = address }
                if let transport = stop.transportTypeRaw, !transport.isEmpty { value["transport"] = transport }
                if let minutes = stop.arrivalMinutes { value["arrival"] = timeText(minutes) }
                if !stop.notes.isEmpty { value["notes"] = stop.notes }
                if stop.isCompleted { value["completed"] = true }
                if let latitude = stop.latitude, let longitude = stop.longitude {
                    let location = CLLocation(latitude: latitude, longitude: longitude)
                    if let previousCoordinate {
                        value["fromPrevKm"] = (location.distance(from: previousCoordinate) / 100).rounded() / 10
                    }
                    previousCoordinate = location
                }
                stops.append(value)
            }
            var dayValue: [String: Any] = [
                "day": index + 1,
                "cities": day.cities.map(\.name),
                "stops": stops
            ]
            if let date = day.date { dayValue["date"] = dateFormatter.string(from: date) }
            days.append(dayValue)
        }

        var root: [String: Any] = [
            "title": snapshot.title,
            "dayCount": snapshot.days.count,
            "status": snapshot.isActive ? "进行中" : "计划中",
            "days": days
        ]
        if !snapshot.notes.isEmpty { root["notes"] = snapshot.notes }
        if let activity = snapshot.activityName, !activity.isEmpty { root["tripType"] = activity }
        if let home = snapshot.homeCity {
            root["homeCity"] = home.name
            if let homeLocation, let lastStop = previousCoordinate, lastStop !== homeLocation {
                root["returnKm"] = (lastStop.distance(from: homeLocation) / 100).rounded() / 10
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func kmText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: Streaming text

    private static let planFencePattern = try! NSRegularExpression(
        pattern: "```[ \\t]*(?:json)?[ \\t]*\\r?\\n?[ \\t]*\\{[\\s]*\"days\"",
        options: [.caseInsensitive]
    )
    private static let barePlanPattern = try! NSRegularExpression(pattern: "\\{[\\s]*\"days\"")
    /// A fence still arriving at the end of a streamed answer (```, ```js, ```json …).
    private static let pendingFencePattern = try! NSRegularExpression(
        pattern: "`{1,3}(?:[ \\t]*j(?:s(?:o(?:n)?)?)?)?[ \\t]*\\r?\\n?[ \\t]*(?:\\{[\\s]*(?:\"(?:d(?:a(?:y(?:s)?)?)?)?)?)?\\z",
        options: [.caseInsensitive]
    )

    /// Where the structured plan starts: a ```json fence holding the plan, or
    /// a bare plan object for models that skip the fence. Other code blocks
    /// are part of the Markdown answer.
    private static func planStart(in raw: String) -> (range: Range<String.Index>, isFence: Bool)? {
        let whole = NSRange(raw.startIndex..., in: raw)
        let fence = planFencePattern.firstMatch(in: raw, range: whole).flatMap { Range($0.range, in: raw) }
        let bare = barePlanPattern.firstMatch(in: raw, range: whole).flatMap { Range($0.range, in: raw) }
        switch (fence, bare) {
        case let (fence?, bare?): return fence.lowerBound <= bare.lowerBound ? (fence, true) : (bare, false)
        case let (fence?, nil): return (fence, true)
        case let (nil, bare?): return (bare, false)
        case (nil, nil): return nil
        }
    }

    /// Answer text without the trailing plan. While streaming, a fence that
    /// may be the start of the plan is held back until it is clear.
    static func displayText(from raw: String, isStreaming: Bool = false) -> String {
        var text = raw
        if let start = planStart(in: raw) {
            text = dropPlanAnnouncement(String(raw[..<start.range.lowerBound]))
        } else if isStreaming,
                  let pending = pendingFencePattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(pending.range, in: raw),
                  !isInsideOpenCodeBlock(raw[..<range.lowerBound]) {
            text = String(raw[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes trailing lines such as "优化后的 JSON 代码块：" that only
    /// introduce the plan, which is shown as a change card instead.
    private static func dropPlanAnnouncement(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if line.isEmpty || lowered.contains("json") || line.contains("代码块") || line.contains("结构化") {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// True when an odd number of fences precede, i.e. a Markdown code block is open.
    private static func isInsideOpenCodeBlock(_ text: Substring) -> Bool {
        text.components(separatedBy: "```").count % 2 == 0
    }

    static func isComposingPlan(_ raw: String) -> Bool {
        planStart(in: raw) != nil
    }

    /// Splits a finished answer into display text and the JSON plan, if any.
    static func finalize(raw: String) -> (text: String, planJSON: String?) {
        let text = displayText(from: raw)
        guard let start = planStart(in: raw),
              let open = raw[start.range].firstIndex(of: "{") else { return (text, nil) }
        var body = raw[open...]
        if let closing = body.range(of: "```") { body = body[..<closing.lowerBound] }
        if let close = body.lastIndex(of: "}") {
            let json = String(body[...close])
            if parsePlan(json) != nil { return (text, json) }
        }
        return (text, nil)
    }

    // MARK: Plan parsing

    private static let stopListKeys = ["stops", "places", "items", "spots", "locations"]

    static func parsePlan(_ json: String) -> TripAIPlan? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDays = root["days"] as? [[String: Any]] else { return nil }
        var seenDays = Set<Int>()
        var days: [TripAIPlan.Day] = []
        var unreadableDays: [Int] = []
        for rawDay in rawDays {
            guard let dayNumber = intValue(rawDay["day"]), seenDays.insert(dayNumber).inserted else { continue }
            // A listed day replaces that day's places, so only a list read in
            // full may change it. Anything unreadable leaves the day as it is.
            guard let rawStops = stopListKeys.lazy.compactMap({ rawDay[$0] as? [Any] }).first else {
                unreadableDays.append(dayNumber)
                continue
            }
            let entries = rawStops.compactMap(parseEntry)
            guard entries.count == rawStops.count else {
                unreadableDays.append(dayNumber)
                continue
            }
            days.append(TripAIPlan.Day(dayNumber: dayNumber, entries: entries))
        }
        guard !days.isEmpty || !unreadableDays.isEmpty else { return nil }
        return TripAIPlan(days: days, unreadableDays: unreadableDays)
    }

    private static let refPattern = try! NSRegularExpression(pattern: "^[Ss]\\d+$")

    private static func parseEntry(_ raw: Any) -> TripAIPlan.Entry? {
        // A bare string is either a ref ("S3") or a place name.
        if let text = trimmed(raw as? String) {
            let isRef = refPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            return TripAIPlan.Entry(
                ref: isRef ? text.uppercased() : nil,
                name: isRef ? nil : text,
                city: nil,
                transport: .keep,
                arrivalMinutes: .keep,
                notes: .keep
            )
        }
        guard let value = raw as? [String: Any] else { return nil }
        let ref = (trimmed(value["ref"] as? String) ?? trimmed(value["id"] as? String))?.uppercased()
        let name = trimmed(value["name"] as? String) ?? trimmed(value["place"] as? String) ?? trimmed(value["title"] as? String)
        guard ref != nil || name != nil else { return nil }

        let transport: TripAIFieldUpdate<String>
        switch field(value["transport"]) {
        case .missing, .other: transport = .keep
        case .null: transport = .clear
        case .text(let raw):
            if let type = transportType(from: raw) {
                transport = .set(type.rawValue)
            } else {
                transport = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .keep
            }
        }

        let arrival: TripAIFieldUpdate<Int>
        switch field(value["arrival"]) {
        case .missing, .other: arrival = .keep
        case .null: arrival = .clear
        case .text(let raw):
            if let minutes = minutes(from: raw) {
                arrival = .set(minutes)
            } else {
                arrival = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .keep
            }
        }

        let notes: TripAIFieldUpdate<String>
        switch field(value["notes"]) {
        case .missing, .other: notes = .keep
        case .null: notes = .clear
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            notes = text.isEmpty ? .clear : .set(text)
        }

        return TripAIPlan.Entry(
            ref: ref,
            name: name,
            city: trimmed(value["city"] as? String),
            transport: transport,
            arrivalMinutes: arrival,
            notes: notes
        )
    }

    /// Distinguishes an omitted key (keep) from an explicit null (clear).
    private enum RawField {
        case missing
        case null
        case text(String)
        case other
    }

    private static func field(_ value: Any?) -> RawField {
        guard let value else { return .missing }
        if value is NSNull { return .null }
        if let text = value as? String { return .text(text) }
        return .other
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        // "2", "第2天", "Day 2"
        if let text = value as? String { return Int(text.filter(\.isASCII).filter(\.isNumber)) }
        return nil
    }

    private static func transportType(from raw: String) -> TransportType? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = TransportType(rawValue: value.lowercased()) { return type }
        return TransportType.allCases.first { $0.localizedName == value }
    }

    private static func minutes(from raw: String) -> Int? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
            .split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// What applying actually did: new places carry the name found on the
    /// map, places that were not found and adjusted legs are listed as such.
    static func appliedChanges(
        preview: TripAIPlanPreview,
        unresolvedNames: [String],
        addedNames: [String: String],
        existingNames: [String: String],
        keptItemIDs: Set<UUID>,
        adjustmentNotes: [String]
    ) -> [TripAIPlanChange] {
        var result: [(TripAIPlanChange.Kind, String)] = []
        let unresolved = Set(unresolvedNames)
        for change in preview.changes {
            // A stop the plan meant to replace with "itself" was kept.
            if change.kind == .remove, let itemID = change.itemID, keptItemIDs.contains(itemID) { continue }
            guard change.kind == .add, let name = change.placeName else {
                result.append((change.kind, change.text))
                continue
            }
            if let existing = existingNames[name] {
                result.append((.skipped, "「\(name)」就是行程里已有的「\(existing)」，没有重复添加"))
            } else if unresolved.contains(name) {
                result.append((.skipped, "地图上没有找到「\(name)」，未添加"))
            } else if let actual = addedNames[name],
                      normalizedPlaceSearchKey(actual) != normalizedPlaceSearchKey(name) {
                result.append((.add, change.text.replacingOccurrences(of: "「\(name)」", with: "「\(actual)」（按「\(name)」查找）")))
            } else {
                result.append((.add, change.text))
            }
        }
        result += adjustmentNotes.map { (.skipped, $0) }
        return result.enumerated().map { TripAIPlanChange(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    // MARK: Place names

    private static let homeReturnPrefixes = ["返回", "回到", "返程", "回家"]

    /// Whether a planned "place" is really the trip back to the home city.
    static func isHomeReturn(_ name: String, home: String?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if homeReturnPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        guard let home, !home.isEmpty else { return false }
        let homeStem = home.hasSuffix("市") ? String(home.dropLast()) : home
        let nameStem = trimmed.hasSuffix("市") ? String(trimmed.dropLast()) : trimmed
        return nameStem == homeStem
    }

    /// Generic endings that do not change which place is meant.
    private static let genericPlaceSuffixes = ["风景名胜区", "旅游度假区", "风景区", "旅游区", "度假区", "景区", "景点"]

    /// The distinctive part of a place name: no parenthetical, no generic ending.
    static func placeNameCore(_ name: String) -> String {
        var core = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = core.firstIndex(where: { $0 == "(" || $0 == "（" }), paren != core.startIndex {
            core = String(core[..<paren])
        }
        var trimmed = true
        while trimmed {
            trimmed = false
            for suffix in genericPlaceSuffixes where core.count > suffix.count && core.hasSuffix(suffix) {
                core.removeLast(suffix.count)
                trimmed = true
            }
        }
        return core.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether two names refer to the same place: equal once generic endings
    /// are removed, or one contains the other and the shorter one is long
    /// enough to be distinctive.
    static func placeNamesMatch(_ first: String, _ second: String) -> Bool {
        let firstCore = placeNameCore(first)
        let secondCore = placeNameCore(second)
        let firstKey = normalizedPlaceSearchKey(firstCore)
        let secondKey = normalizedPlaceSearchKey(secondCore)
        guard !firstKey.isEmpty, !secondKey.isEmpty else { return false }
        if firstKey == secondKey { return true }
        let minimumLength = AppConfig.shared.tripAIPlaceNameMinContainedLength
        guard minimumLength > 0, min(firstCore.count, secondCore.count) >= minimumLength else { return false }
        return firstKey.contains(secondKey) || secondKey.contains(firstKey)
    }

    // MARK: Preview

    /// Binds a plan to the current itinerary and lists what applying it changes.
    static func preview(
        planJSON: String,
        stopRefs: [String: UUID],
        snapshot: TripAIItinerarySnapshot
    ) -> TripAIPlanPreview? {
        guard let plan = parsePlan(planJSON) else { return nil }

        struct Located {
            let stop: TripAIItinerarySnapshot.Stop
            let dayNumber: Int
        }
        var located: [UUID: Located] = [:]
        for (index, day) in snapshot.days.enumerated() {
            for stop in day.stops { located[stop.itemID] = Located(stop: stop, dayNumber: index + 1) }
        }

        var warnings: [String] = []
        var ignoredDays: [Int] = []
        var missingRefCount = 0
        var referenced = Set<UUID>()
        var resolvedDays: [TripAIResolvedPlan.Day] = []

        // A place the plan names that is already in the trip is that stop,
        // not a new one: it keeps or moves the stop, or is dropped when the
        // plan already lists the stop by ref.
        let explicitlyReferenced = Set(plan.days.flatMap(\.entries).compactMap { $0.ref.flatMap { stopRefs[$0] } })
        let existingStops = snapshot.days.flatMap(\.stops)

        for planDay in plan.days.sorted(by: { $0.dayNumber < $1.dayNumber }) {
            guard (1...max(1, snapshot.days.count)).contains(planDay.dayNumber), !snapshot.days.isEmpty else {
                ignoredDays.append(planDay.dayNumber)
                continue
            }
            let day = snapshot.days[planDay.dayNumber - 1]
            var entries: [TripAIResolvedPlan.Entry] = []
            for entry in planDay.entries {
                var itemID: UUID?
                if let ref = entry.ref {
                    guard let id = stopRefs[ref], located[id] != nil else {
                        missingRefCount += 1
                        continue
                    }
                    itemID = id
                } else if let name = entry.name,
                          let existing = existingStops.first(where: { placeNamesMatch(name, $0.name) }) {
                    guard !referenced.contains(existing.itemID),
                          !explicitlyReferenced.contains(existing.itemID) else { continue }
                    itemID = existing.itemID
                }
                if let itemID {
                    guard referenced.insert(itemID).inserted, let current = located[itemID] else { continue }
                    entries.append(TripAIResolvedPlan.Entry(
                        existingItemID: itemID,
                        name: current.stop.name,
                        cityName: current.stop.cityName,
                        transport: entry.transport,
                        arrivalMinutes: entry.arrivalMinutes,
                        notes: entry.notes
                    ))
                } else if let name = entry.name {
                    // Going home is the end of the trip, not a place to visit.
                    if isHomeReturn(name, home: snapshot.homeCity?.name) { continue }
                    entries.append(TripAIResolvedPlan.Entry(
                        existingItemID: nil,
                        name: name,
                        cityName: entry.city ?? day.cities.last?.name,
                        transport: entry.transport,
                        arrivalMinutes: entry.arrivalMinutes,
                        notes: entry.notes
                    ))
                }
            }
            resolvedDays.append(TripAIResolvedPlan.Day(dayID: day.dayID, dayNumber: planDay.dayNumber, entries: entries))
        }

        let listedDayNumbers = Set(resolvedDays.map(\.dayNumber))
        var removed: [(stop: TripAIItinerarySnapshot.Stop, dayNumber: Int)] = []
        for (index, day) in snapshot.days.enumerated() where listedDayNumbers.contains(index + 1) {
            for stop in day.stops where !referenced.contains(stop.itemID) && !stop.isCompleted {
                removed.append((stop, index + 1))
            }
        }

        var changes: [(TripAIPlanChange.Kind, String, String?, Int?, UUID?)] = []
        for day in resolvedDays {
            let currentOrder = snapshot.days[day.dayNumber - 1].stops.map(\.itemID)
            let stayingInPlanOrder = day.entries.compactMap(\.existingItemID).filter { currentOrder.contains($0) }
            let stayingInCurrentOrder = currentOrder.filter { stayingInPlanOrder.contains($0) }
            if stayingInPlanOrder != stayingInCurrentOrder {
                changes.append((.reorder, "第\(day.dayNumber)天调整地点顺序", nil, nil, nil))
            }
            for entry in day.entries {
                guard let itemID = entry.existingItemID, let current = located[itemID] else {
                    var text = "第\(day.dayNumber)天新增「\(entry.name)」"
                    if case .set(let raw) = entry.transport, let type = TransportType(rawValue: raw) {
                        text += " · \(type.localizedName)前往"
                    }
                    if case .set(let minutes) = entry.arrivalMinutes { text += " · \(timeText(minutes))到达" }
                    changes.append((.add, text, entry.name, day.dayNumber, nil))
                    continue
                }
                let name = current.stop.name
                if current.dayNumber != day.dayNumber {
                    changes.append((.move, "「\(name)」从第\(current.dayNumber)天移到第\(day.dayNumber)天", nil, nil, nil))
                }
                switch entry.transport {
                case .set(let raw) where raw != current.stop.transportTypeRaw:
                    let typeName = TransportType(rawValue: raw)?.localizedName ?? raw
                    changes.append((.transport, "前往「\(name)」改为\(typeName)", nil, nil, nil))
                case .clear where current.stop.transportTypeRaw?.isEmpty == false:
                    changes.append((.transport, "取消前往「\(name)」的交通方式", nil, nil, nil))
                default: break
                }
                switch entry.arrivalMinutes {
                case .set(let minutes) where minutes != current.stop.arrivalMinutes:
                    changes.append((.time, "「\(name)」到达时间改为 \(timeText(minutes))", nil, nil, nil))
                case .clear where current.stop.arrivalMinutes != nil:
                    changes.append((.time, "取消「\(name)」的到达时间", nil, nil, nil))
                default: break
                }
                switch entry.notes {
                case .set(let text) where text != current.stop.notes:
                    changes.append((.notes, current.stop.notes.isEmpty ? "为「\(name)」添加备注" : "更新「\(name)」的备注", nil, nil, nil))
                case .clear where !current.stop.notes.isEmpty:
                    changes.append((.notes, "清除「\(name)」的备注", nil, nil, nil))
                default: break
                }
            }
        }
        for entry in removed {
            changes.append((.remove, "从第\(entry.dayNumber)天删除「\(entry.stop.name)」", nil, nil, entry.stop.itemID))
        }

        if !plan.unreadableDays.isEmpty {
            let list = plan.unreadableDays.sorted().map { "第\($0)天" }.joined(separator: "、")
            warnings.append("\(list)的安排没能识别，保持不变。")
        }
        if !ignoredDays.isEmpty {
            let list = ignoredDays.map { "第\($0)天" }.joined(separator: "、")
            warnings.append("\(list)超出行程天数，相关安排不会应用。")
        }
        if missingRefCount > 0 {
            warnings.append("有 \(missingRefCount) 个地点已不在当前行程中，相关安排不会应用。")
        }

        return TripAIPlanPreview(
            plan: TripAIResolvedPlan(days: resolvedDays, removedItemIDs: Set(removed.map(\.stop.itemID))),
            changes: changes.enumerated().map {
                TripAIPlanChange(
                    id: $0.offset,
                    kind: $0.element.0,
                    text: $0.element.1,
                    placeName: $0.element.2,
                    dayNumber: $0.element.3,
                    itemID: $0.element.4
                )
            },
            warnings: warnings,
            addedPlaceCount: changes.filter { $0.0 == .add }.count
        )
    }
}

// MARK: - Markdown

/// One rendered block of an answer. Parsed off the main actor; the view only
/// lays the blocks out.
struct TripAIMarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable {
        case heading(level: Int)
        case paragraph
        case bullet(depth: Int)
        case ordered(marker: String, depth: Int)
        case quote
        case code
        case divider
        case table(rows: [[AttributedString]], hasHeader: Bool)
    }

    let id: Int
    let kind: Kind
    let content: AttributedString
    /// Space above this block; list items sit closer together than paragraphs.
    let spacingBefore: Double
}

enum TripAIMarkdown {
    private static let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+?)\\s*#*$")
    private static let orderedPattern = try! NSRegularExpression(
        pattern: "^(\\d{1,3})(?:[.)]\\s+|[.)](?=[^\\d\\s])|、\\s*)(.+)$"
    )
    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func blocks(from text: String) -> [TripAIMarkdownBlock] {
        var parsed: [(TripAIMarkdownBlock.Kind, AttributedString)] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var tableRows: [[String]] = []
        var tableHasHeader = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            parsed.append((.paragraph, inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            parsed.append((.quote, inline(quote.joined(separator: "\n"))))
            quote = []
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            parsed.append((.table(rows: tableRows.map { $0.map(inline) }, hasHeader: tableHasHeader), AttributedString()))
            tableRows = []
            tableHasHeader = false
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    parsed.append((.code, AttributedString(lines.joined(separator: "\n"))))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushQuote()
                let cells = tableCells(trimmed)
                if cells.allSatisfy(isTableSeparator) {
                    if tableRows.count == 1 { tableHasHeader = true }
                } else {
                    tableRows.append(cells)
                }
                continue
            }
            flushTable()
            if let heading = match(headingPattern, in: trimmed) {
                flushAll()
                parsed.append((.heading(level: heading[0].count), inline(heading[1])))
                continue
            }
            if isDivider(trimmed) {
                flushAll()
                parsed.append((.divider, AttributedString()))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            let depth = indentDepth(rawLine)
            if let item = bulletText(trimmed) {
                flushParagraph()
                parsed.append((.bullet(depth: depth), inline(item)))
                continue
            }
            if let ordered = match(orderedPattern, in: trimmed) {
                flushParagraph()
                parsed.append((.ordered(marker: "\(ordered[0]).", depth: depth), inline(ordered[1])))
                continue
            }
            paragraph.append(trimmed)
        }
        if let lines = code, !lines.isEmpty {
            // An unclosed block while the answer is still streaming.
            parsed.append((.code, AttributedString(lines.joined(separator: "\n"))))
        }
        flushAll()

        var blocks: [TripAIMarkdownBlock] = []
        for (index, entry) in parsed.enumerated() {
            let spacing: Double
            if index == 0 {
                spacing = 0
            } else {
                switch (parsed[index - 1].0, entry.0) {
                case (_, .heading): spacing = 16
                case (.bullet, .bullet), (.bullet, .ordered), (.ordered, .ordered), (.ordered, .bullet): spacing = 6
                case (.heading, _): spacing = 6
                default: spacing = 10
                }
            }
            blocks.append(TripAIMarkdownBlock(id: index, kind: entry.0, content: entry.1, spacingBefore: spacing))
        }
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: inlineOptions)) ?? AttributedString(text)
    }

    private static func match(_ pattern: NSRegularExpression, in text: String) -> [String]? {
        guard let result = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              result.numberOfRanges >= 3,
              let first = Range(result.range(at: 1), in: text),
              let second = Range(result.range(at: 2), in: text) else { return nil }
        return [String(text[first]), String(text[second])]
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• ", "· "] where line.hasPrefix(marker) {
            var item = String(line.dropFirst(marker.count))
            for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) {
                item = (box == "[ ] " ? "☐ " : "☑︎ ") + item.dropFirst(box.count)
            }
            return item
        }
        return nil
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func indentDepth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return min(3, width / 2)
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }
}

// MARK: - Session

/// State of one trip's planning conversation while the sheet is open.
@MainActor
@Observable
final class TripAIPlannerSession {
    let tripID: UUID
    private(set) var messages: [TripAIChatMessage] = []
    private(set) var isLoaded = false
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    /// Markdown blocks of `streamingText`.
    private(set) var streamingBlocks: [TripAIMarkdownBlock] = []
    /// Markdown blocks of each finished answer, keyed by message ID.
    private(set) var renderedBlocks: [UUID: [TripAIMarkdownBlock]] = [:]
    private(set) var isComposingPlan = false
    private(set) var errorMessage: String?
    private(set) var previews: [UUID: TripAIPlanPreview] = [:]
    private(set) var applyingMessageID: UUID?
    private(set) var undoableMessageID: UUID?
    private(set) var applyNotices: [UUID: String] = [:]
    /// Increases on every successful application; drives success feedback.
    private(set) var appliedCount = 0

    @ObservationIgnored private let rowsProvider: @MainActor () -> TripAIItineraryRows
    /// Applies a plan to the editor's draft; receives the answer's message ID.
    @ObservationIgnored private let applier: @MainActor (UUID, TripAIResolvedPlan) async -> TripAIApplyOutcome
    @ObservationIgnored private var undoAction: (@MainActor () -> Bool)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        tripID: UUID,
        rowsProvider: @escaping @MainActor () -> TripAIItineraryRows,
        applier: @escaping @MainActor (UUID, TripAIResolvedPlan) async -> TripAIApplyOutcome
    ) {
        self.tripID = tripID
        self.rowsProvider = rowsProvider
        self.applier = applier
    }

    var canRetry: Bool {
        !isStreaming && errorMessage != nil && messages.last?.role == .user
    }

    func load() {
        guard loadTask == nil else { return }
        let tripID = tripID
        loadTask = Task { [weak self] in
            let conversation = await TripAIConversationStore.shared.load(tripID: tripID)
            guard let self else { return }
            // A message sent before loading finished stays after the stored history.
            self.messages = (conversation?.messages ?? []) + self.messages
            self.isLoaded = true
            self.refreshPreviews()
            await self.renderStoredAnswers()
        }
    }

    private func renderStoredAnswers() async {
        let answers = messages.filter { $0.role == .assistant && renderedBlocks[$0.id] == nil }
        guard !answers.isEmpty else { return }
        let rendered = await Task.detached(priority: .userInitiated) { () -> [UUID: [TripAIMarkdownBlock]] in
            var result: [UUID: [TripAIMarkdownBlock]] = [:]
            for message in answers { result[message.id] = TripAIMarkdown.blocks(from: message.text) }
            return result
        }.value
        renderedBlocks.merge(rendered) { current, _ in current }
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming, applyingMessageID == nil else { return }
        messages.append(TripAIChatMessage(role: .user, text: prompt))
        persist()
        startStreaming()
    }

    func retry() {
        guard canRetry else { return }
        startStreaming()
    }

    func stop() {
        streamTask?.cancel()
    }

    func clearConversation() {
        guard !isStreaming, applyingMessageID == nil else { return }
        messages = []
        previews = [:]
        renderedBlocks = [:]
        applyNotices = [:]
        undoableMessageID = nil
        undoAction = nil
        errorMessage = nil
        persist()
    }

    private func startStreaming() {
        guard let userMessage = messages.last, userMessage.role == .user else { return }
        let history = Array(messages.dropLast())
        let rows = rowsProvider()
        let config = AppConfig.shared
        let historyLimit = config.tripAIHistoryMessageLimit
        let temperature = config.tripAITemperature
        let timeout = config.tripAIRequestTimeout
        let refreshInterval = config.tripAIStreamRefreshInterval

        errorMessage = nil
        isStreaming = true
        streamingText = ""
        streamingBlocks = []
        isComposingPlan = false

        streamTask = Task { [weak self] in
            let request = await Task.detached(priority: .userInitiated) {
                TripAIPlanner.makeRequest(
                    snapshot: TripAIItinerarySnapshot.make(from: rows),
                    history: history,
                    userText: userMessage.text,
                    historyLimit: historyLimit,
                    now: Date()
                )
            }.value
            guard let self, !Task.isCancelled else {
                self?.finishStreaming(raw: nil, stopRefs: [:], error: nil, interrupted: true)
                return
            }
            let stream = OpenAIService.shared.streamChatCompletion(
                messages: request.messages,
                temperature: temperature,
                timeout: timeout
            )
            let consumer = Task.detached(priority: .userInitiated) { [weak self] () async throws -> String in
                var raw = ""
                var lastRefresh = Date.distantPast
                for try await delta in stream {
                    raw += delta
                    let now = Date()
                    if now.timeIntervalSince(lastRefresh) >= refreshInterval {
                        lastRefresh = now
                        let display = TripAIPlanner.displayText(from: raw, isStreaming: true)
                        let composing = TripAIPlanner.isComposingPlan(raw)
                        let blocks = TripAIMarkdown.blocks(from: display)
                        await self?.updateStreaming(text: display, blocks: blocks, composingPlan: composing)
                    }
                }
                return raw
            }
            do {
                let raw = try await withTaskCancellationHandler {
                    try await consumer.value
                } onCancel: {
                    consumer.cancel()
                }
                self.finishStreaming(raw: raw, stopRefs: request.stopRefs, error: nil, interrupted: false)
            } catch {
                let interrupted = Task.isCancelled
                    || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                self.finishStreaming(raw: nil, stopRefs: request.stopRefs, error: interrupted ? nil : error, interrupted: interrupted)
            }
        }
    }

    private func updateStreaming(text: String, blocks: [TripAIMarkdownBlock], composingPlan: Bool) {
        guard isStreaming else { return }
        if streamingText != text {
            streamingText = text
            streamingBlocks = blocks
        }
        if isComposingPlan != composingPlan { isComposingPlan = composingPlan }
    }

    private func finishStreaming(raw: String?, stopRefs: [String: UUID], error: Error?, interrupted: Bool) {
        streamTask = nil
        if let raw {
            Task { [weak self] in
                let result = await Task.detached { () -> (text: String, planJSON: String?, blocks: [TripAIMarkdownBlock]) in
                    let finalized = TripAIPlanner.finalize(raw: raw)
                    let text = finalized.text.isEmpty && finalized.planJSON != nil
                        ? "我按你的要求整理了一版行程调整，可以看看下面的改动。"
                        : finalized.text
                    return (text, finalized.planJSON, TripAIMarkdown.blocks(from: text))
                }.value
                guard let self else { return }
                if result.text.isEmpty && result.planJSON == nil {
                    self.errorMessage = OpenAIService.ChatStreamError.emptyResponse.localizedDescription
                } else {
                    let message = TripAIChatMessage(
                        role: .assistant,
                        text: result.text,
                        planJSON: result.planJSON,
                        stopRefs: result.planJSON == nil ? nil : stopRefs
                    )
                    self.renderedBlocks[message.id] = result.blocks
                    self.messages.append(message)
                    self.persist()
                }
                self.resetStreamingState()
                self.refreshPreviews()
            }
            return
        }
        if interrupted {
            let partial = streamingText
            if partial.isEmpty {
                errorMessage = "已停止生成。"
            } else {
                let message = TripAIChatMessage(role: .assistant, text: partial, isInterrupted: true)
                renderedBlocks[message.id] = streamingBlocks
                messages.append(message)
                persist()
            }
        } else if let error {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? ((error as? URLError)?.code == .timedOut ? "AI 响应超时，请稍后再试。" : "网络连接失败，请检查网络后重试。")
        }
        resetStreamingState()
    }

    private func resetStreamingState() {
        isStreaming = false
        streamingText = ""
        streamingBlocks = []
        isComposingPlan = false
    }

    // MARK: Previews

    /// Recomputes every plan's diff against the itinerary as it is now.
    func refreshPreviews() {
        let messages = messages
        let rows = rowsProvider()
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { () -> [UUID: TripAIPlanPreview] in
                // An applied answer shows what was applied, frozen at that time.
                let planned = messages.filter { $0.planJSON != nil && $0.appliedAt == nil }
                guard !planned.isEmpty else { return [:] }
                let snapshot = TripAIItinerarySnapshot.make(from: rows)
                var result: [UUID: TripAIPlanPreview] = [:]
                for message in planned {
                    guard let json = message.planJSON,
                          let preview = TripAIPlanner.preview(planJSON: json, stopRefs: message.stopRefs ?? [:], snapshot: snapshot) else { continue }
                    result[message.id] = preview
                }
                return result
            }.value
            guard !Task.isCancelled, let self else { return }
            self.previews = computed
        }
    }

    // MARK: Apply

    func apply(_ messageID: UUID) {
        guard applyingMessageID == nil, !isStreaming,
              let preview = previews[messageID], preview.hasChanges else { return }
        applyingMessageID = messageID
        applyNotices[messageID] = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.applier(messageID, preview.plan)
            if let errorMessage = outcome.errorMessage {
                self.applyingMessageID = nil
                self.applyNotices[messageID] = errorMessage
                self.refreshPreviews()
                return
            }
            if preview.onlyAddsPlaces, outcome.unresolvedNames.count >= preview.addedPlaceCount {
                self.applyingMessageID = nil
                self.applyNotices[messageID] = "没有在地图上找到「\(outcome.unresolvedNames.joined(separator: "」「"))」，行程没有变化。可以换个说法再问问。"
                self.refreshPreviews()
                return
            }
            let unresolved = outcome.unresolvedNames
            let addedNames = outcome.addedNames
            let notes = outcome.adjustmentNotes
            let existingNames = outcome.existingNames
            let keptItemIDs = outcome.keptItemIDs
            let applied = await Task.detached {
                TripAIPlanner.appliedChanges(
                    preview: preview,
                    unresolvedNames: unresolved,
                    addedNames: addedNames,
                    existingNames: existingNames,
                    keptItemIDs: keptItemIDs,
                    adjustmentNotes: notes
                )
            }.value
            self.applyingMessageID = nil
            if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                self.messages[index].appliedAt = Date()
                self.messages[index].appliedChanges = applied
            }
            self.appliedCount += 1
            self.undoableMessageID = outcome.undo == nil ? nil : messageID
            self.undoAction = outcome.undo
            self.persist()
            self.refreshPreviews()
        }
    }

    func undo(_ messageID: UUID) {
        guard undoableMessageID == messageID, applyingMessageID == nil, let undoAction else { return }
        if undoAction() {
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].appliedAt = nil
                messages[index].appliedChanges = nil
            }
            applyNotices[messageID] = nil
            persist()
        } else {
            applyNotices[messageID] = "撤销没有成功，请稍后再试。"
        }
        undoableMessageID = nil
        self.undoAction = nil
        refreshPreviews()
    }

    // MARK: Persistence

    private func persist() {
        let conversation = TripAIConversation(
            version: TripAIConversation.currentVersion,
            tripID: tripID,
            messages: messages,
            updatedAt: Date()
        )
        let previous = persistTask
        persistTask = Task {
            await previous?.value
            await TripAIConversationStore.shared.save(conversation)
        }
    }

    func cancelAll() {
        streamTask?.cancel()
        previewTask?.cancel()
    }
}

extension TripAIPlannerSession: Identifiable {
    nonisolated var id: UUID { tripID }
}
