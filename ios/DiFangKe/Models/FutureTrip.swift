import Foundation
import SwiftData

/// Legacy persistence model for the removed trip-plan ("未来行程") feature.
///
/// The feature and all of its UI, reminders and Live Activities are gone, but
/// this entity must remain registered in the SwiftData schema
/// (`DiFangKeApp.initializeModelContainer`, `DiFangKeSchemaV2`) so that existing
/// local and CloudKit-mirrored stores keep opening without a migration. Do not
/// change the class name or any stored property: either would alter the store
/// schema and risk a failed container load on launch.
@Model
final class FutureTrip {
    var id: UUID = UUID()
    var placeID: UUID?
    var placeName: String = ""
    var address: String?
    var notes: String?
    var latitude: Double = 0
    var longitude: Double = 0
    var arrivalDate: Date = Date()
    var hasPlanDate: Bool = true
    var hasArrivalTime: Bool = false
    var scheduleModeValue: String = "timed"
    var orderIndex: Int = 0
    var activityTypeValue: String?
    var createdAt: Date = Date()
    var isCompleted: Bool = false
    var completedAt: Date?

    init() {}
}
