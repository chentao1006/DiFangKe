import Foundation
import SwiftData
import SwiftUI
import CoreLocation

@Model
final class ActivityType: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "circle.fill"
    var colorHex: String = "#007AFF"
    var sortOrder: Int = 0
    var isSystem: Bool = true
    
    var color: Color {
        Color(hex: colorHex) ?? .blue
    }

    func convertToLite() -> ActivityTypeLite {
        ActivityTypeLite(id: id, name: name, icon: icon, colorHex: colorHex, sortOrder: sortOrder)
    }
    
    // Static presets to be seeded
    static var presets: [ActivityType] {
        [
            ActivityType(name: "居家", icon: "house.fill", colorHex: "#34C759", sortOrder: 0, isSystem: true),
            ActivityType(name: "工作", icon: "briefcase.fill", colorHex: "#FF9500", sortOrder: 1, isSystem: true),
            ActivityType(name: "美食", icon: "fork.knife", colorHex: "#FF3B30", sortOrder: 2, isSystem: true),
            ActivityType(name: "购物", icon: "cart.fill", colorHex: "#AF52DE", sortOrder: 3, isSystem: true),
            ActivityType(name: "运动", icon: "figure.run", colorHex: "#5856D6", sortOrder: 4, isSystem: true),
            ActivityType(name: "旅游", icon: "airplane", colorHex: "#007AFF", sortOrder: 5, isSystem: true),
            ActivityType(name: "医疗", icon: "cross.fill", colorHex: "#FF2D55", sortOrder: 6, isSystem: true),
            ActivityType(name: "睡眠", icon: "bed.double.fill", colorHex: "#5AC8FA", sortOrder: 7, isSystem: true),
            ActivityType(name: "交通", icon: "tram.fill", colorHex: "#8E8E93", sortOrder: 8, isSystem: true)
        ]
    }
    
    init(id: UUID = UUID(), name: String, icon: String, colorHex: String, sortOrder: Int, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isSystem = isSystem
    }
    
    // Suggestion logic for inferring activities
    static func getSuggestedActivities(for footprint: Footprint, allActivities: [ActivityTypeLite], allPlaces: [PlaceLite], history: [FootprintLite] = []) -> [ActivityTypeLite] {
        var suggested: [ActivityTypeLite] = []
        
        // 1. Confident Matches (These can be used for auto-assignment)
        if let autoMatch = getAutoMatchActivity(for: footprint, allActivities: allActivities, allPlaces: allPlaces, history: history) {
            suggested.append(autoMatch)
        }
        
        let hour = Calendar.current.component(.hour, from: footprint.startTime)
        let durationHours = footprint.duration / 3600.0
        let matchedPlace = allPlaces.first { $0.placeID == footprint.placeID }
        let contextText = ((footprint.address ?? "") + (matchedPlace?.name ?? "")).lowercased()
        let weekday = Calendar.current.component(.weekday, from: footprint.startTime)
        let isWeekend = (weekday == 1 || weekday == 7)

        // 2. POI Category Mapping (High precision but not always "certain")
        if let category = matchedPlace?.category {
            let catMap: [String: String] = [
                "MKPOICategoryRestaurant": "美食", "MKPOICategoryCafe": "美食", "MKPOICategoryFoodMarket": "美食",
                "MKPOICategorySchool": "学习", "MKPOICategoryUniversity": "学习", "MKPOICategoryLibrary": "学习",
                "MKPOICategoryHospital": "医疗", "MKPOICategoryPharmacy": "医疗",
                "MKPOICategoryPark": "运动", "MKPOICategoryFitnessCenter": "运动",
                "MKPOICategoryMuseum": "旅游", "MKPOICategoryNationalPark": "旅游",
                "MKPOICategoryMovieTheater": "娱乐", "MKPOICategoryAmusementPark": "娱乐",
                "MKPOICategoryStore": "购物", "MKPOICategoryMall": "购物", "MKPOICategoryDepartmentStore": "购物"
            ]
            if let actName = catMap[category], let a = allActivities.first(where: { $0.name == actName }) {
                if !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
            }
        }
        
        // 3. Keyword Pattern Matching (Standard Aggressive Keywords)
        let patterns: [(String, [String])] = [
            ("家庭", ["妈妈", "爸爸", "外婆", "奶奶", "爷爷", "亲戚", "父母", "老家", "儿子", "女儿", "父", "母"]),
            ("居家", ["家", "居", "屋", "公寓", "住宅", "苑", "府", "园", "里"]),
            ("工作", ["公司", "工作", "办公", "大厦", "写字楼", "研制", "软件", "厂", "局", "馆", "office"]),
            ("旅游", ["景点", "景区", "公园", "博物馆", "火车站", "机场", "酒店", "客栈", "游", "trip", "江", "湖", "山", "海", "岛", "古镇", "古村", "古城", "寺", "庙", "塔", "庄园", "庄"]),
            ("美食", ["餐厅", "餐饮", "饭店", "面馆", "火锅", "咖啡", "饮品", "食堂", "美味", "吃", "food", "eat"]),
            ("购物", ["商场", "购物", "超市", "中心", "广场", "便利店", "店", "城", "mall", "shop", "百货", "奥莱", "批发", "商业"]),
            ("运动", ["体育", "健身", "场馆", "跑道", "馆", "羽毛球", "篮球", "游泳", "操场", "gym", "run"]),
            ("娱乐", ["电影", "KTV", "游戏", "乐园", "影院", "游乐", "网吧", "play"]),
            ("学习", ["学校", "大学", "中学", "图书馆", "学院", "课堂", "教育", "校区", "study", "learn"]),
            ("医疗", ["医院", "门诊", "诊所", "药店", "大药房", "卫生院", "hospital", "clinic"])
        ]
        for (name, keywords) in patterns {
            if keywords.contains(where: { contextText.contains($0) }) {
                if let a = allActivities.first(where: { $0.name == name }), !suggested.contains(where: { $0.id == a.id }) {
                    suggested.append(a)
                }
            }
        }

        // 4. Time-based Heuristics (Lower priority)
        let isStrongMatch = suggested.contains(where: { $0.name == "居家" || $0.name == "工作" })
        if !isStrongMatch {
            if durationHours > 3 && (hour >= 21 || hour <= 4) {
                if let a = allActivities.first(where: { $0.name == "睡眠" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
            }
            if (hour >= 11 && hour <= 13) || (hour >= 18 && hour <= 21) {
                if let a = allActivities.first(where: { $0.name == "美食" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
            }
            if !isWeekend && hour >= 9 && hour <= 17 && durationHours > 1.5 {
                if let a = allActivities.first(where: { $0.name == "工作" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
            }
        }

        // Stable Fallback for remaining slots
        if suggested.count < 5 {
            let existingIds = Set(suggested.map { $0.id })
            let others = allActivities.filter { !existingIds.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }
            for a in others where suggested.count < 5 {
                suggested.append(a)
            }
        }
        
        return Array(suggested.prefix(5))
    }
    
    /// Only returns a match if it is highly certain (e.g. History or User-defined Place)
    static func getAutoMatchActivity(for footprint: Footprint, allActivities: [ActivityTypeLite], allPlaces: [PlaceLite], history: [FootprintLite] = []) -> ActivityTypeLite? {
        // Priority 1: User History (Highest confidence)
        if let pID = footprint.placeID {
            let placeHistory = history.filter { $0.placeID == pID && $0.activityTypeValue != nil }
            if !placeHistory.isEmpty {
                let calendar = Calendar.current
                let targetMinutes = calendar.component(.hour, from: footprint.startTime) * 60 + calendar.component(.minute, from: footprint.startTime)
                let windowMinutes = 120 // 2 hour window
                
                var countsInWindow: [String: Int] = [:]
                var countsTotal: [String: Int] = [:]
                
                for fp in placeHistory {
                    guard let type = fp.activityTypeValue else { continue }
                    countsTotal[type, default: 0] += 1
                    
                    let fpMinutes = calendar.component(.hour, from: fp.startTime) * 60 + calendar.component(.minute, from: fp.startTime)
                    let diff = abs(targetMinutes - fpMinutes)
                    if min(diff, 1440 - diff) <= windowMinutes {
                        countsInWindow[type, default: 0] += 1
                    }
                }
                
                // 1. If we have matches in the same time window, it's very likely the same activity
                if let bestInWindow = countsInWindow.max(by: { $0.value < $1.value }),
                   let a = allActivities.first(where: { $0.id.uuidString == bestInWindow.key }) {
                    return a
                }
                
                // 2. If we have a very frequent activity overall at this place (at least 3 times)
                if let mostFrequent = countsTotal.max(by: { $0.value < $1.value }),
                   mostFrequent.value >= 3,
                   let a = allActivities.first(where: { $0.id.uuidString == mostFrequent.key }) {
                    return a
                }
            }
        }
        
        // Priority 2: User-defined Place Specifics (Very high confidence)
        let matchedPlace = allPlaces.first { $0.placeID == footprint.placeID }
        if let place = matchedPlace, place.isUserDefined {
            let placeName = place.name.lowercased()
            // Very strong keywords for home/work if the user explicitly named the place
            if placeName.contains("家") || placeName.contains("屋") || placeName.contains("公寓") || placeName.contains("住宅") {
                if let a = allActivities.first(where: { $0.name == "居家" }) { return a }
            } else if placeName.contains("公司") || placeName.contains("办公") || placeName.contains("单位") || placeName.contains("大厦") {
                if let a = allActivities.first(where: { $0.name == "工作" }) { return a }
            }
        }
        
        return nil
    }

}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0
        let length = hexSanitized.count
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = 1.0 // Ignore alpha from hex to prevent MapKit zero-alpha crashes
        } else {
            return nil
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
    
    func toHex() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
