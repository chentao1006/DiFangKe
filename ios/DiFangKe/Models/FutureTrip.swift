import CoreLocation
import Foundation
import SwiftData

@Model
final class FutureTrip {
    static let storageKey = "futureTrips.v1"
    static let migrationCompletedKey = "futureTrips.v1.migratedToSwiftData"
    static let didChangeNotification = Notification.Name("FutureTripsChanged")

    var id: UUID = UUID()
    var placeID: UUID?
    var placeName: String = ""
    var address: String?
    var notes: String?
    var latitude: Double = 0
    var longitude: Double = 0
    var arrivalDate: Date = Date()
    var hasArrivalTime: Bool = false
    var activityTypeValue: String?
    var createdAt: Date = Date()

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    init(
        id: UUID = UUID(),
        placeID: UUID? = nil,
        placeName: String,
        address: String? = nil,
        notes: String? = nil,
        coordinate: CLLocationCoordinate2D,
        arrivalDate: Date,
        hasArrivalTime: Bool,
        activityTypeValue: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.placeID = placeID
        self.placeName = placeName
        self.address = address
        self.notes = notes
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.arrivalDate = arrivalDate
        self.hasArrivalTime = hasArrivalTime
        self.activityTypeValue = activityTypeValue
        self.createdAt = createdAt
    }

    static func loadLegacyTrips() -> [LegacyFutureTrip] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([LegacyFutureTrip].self, from: data)) ?? []
    }

    static func postDidChangeNotification() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

struct LegacyFutureTrip: Codable {
    var id: UUID
    var placeName: String
    var address: String?
    var notes: String?
    var latitude: Double
    var longitude: Double
    var arrivalDate: Date
    var hasArrivalTime: Bool
    var activityTypeValue: String?
    var createdAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
