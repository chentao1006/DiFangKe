import Foundation
import SwiftData

@Model
final class DailyInsight {
    var id: UUID = UUID()
    var date: Date? = Date()
    var content: String? = ""
    var aiGenerated: Bool? = false
    var dataFingerprint: String? = ""
    var createdAt: Date? = Date()
    
    init(date: Date, content: String = "", aiGenerated: Bool = false) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.content = content
        self.aiGenerated = aiGenerated
        self.createdAt = Date()
    }
}
