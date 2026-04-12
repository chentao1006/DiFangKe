import SwiftUI
import SwiftData

@Model
final class ActivityType: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "mappin.and.ellipse"
    var colorHex: String = "#007AFF" // Default blue
    var sortOrder: Int = 0
    var isSystem: Bool = false
    
    init(id: UUID = UUID(), name: String, icon: String, colorHex: String, sortOrder: Int = 0, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isSystem = isSystem
    }
    
    var color: Color {
        Color(hex: colorHex) ?? .blue
    }
    
    // Static presets to be seeded
    static var presets: [ActivityType] {
        [
            ActivityType(name: "居家", icon: "house.fill", colorHex: "#007AFF", sortOrder: 0, isSystem: true),
            ActivityType(name: "工作", icon: "briefcase.fill", colorHex: "#A2845E", sortOrder: 1, isSystem: true),
            ActivityType(name: "旅游", icon: "airplane", colorHex: "#FF9500", sortOrder: 2, isSystem: true),
            ActivityType(name: "睡眠", icon: "moon.stars.fill", colorHex: "#5856D6", sortOrder: 3, isSystem: true),
            ActivityType(name: "美食", icon: "fork.knife", colorHex: "#FF2D55", sortOrder: 4, isSystem: true),
            ActivityType(name: "购物", icon: "bag.fill", colorHex: "#FFCC00", sortOrder: 5, isSystem: true),
            ActivityType(name: "运动", icon: "figure.run", colorHex: "#34C759", sortOrder: 6, isSystem: true),
            ActivityType(name: "娱乐", icon: "gamecontroller.fill", colorHex: "#AF52DE", sortOrder: 7, isSystem: true),
            ActivityType(name: "学习", icon: "book.fill", colorHex: "#32ADE6", sortOrder: 8, isSystem: true),
            ActivityType(name: "医疗", icon: "cross.fill", colorHex: "#FF3B30", sortOrder: 9, isSystem: true)
        ]
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
            a = CGFloat(rgb & 0x000000FF) / 255.0

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
