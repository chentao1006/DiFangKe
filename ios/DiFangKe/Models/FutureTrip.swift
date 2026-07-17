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
    /// Whether this plan is assigned to a calendar day. Kept true by default so
    /// previously saved plans retain their existing dated behaviour.
    var hasPlanDate: Bool = true
    var hasArrivalTime: Bool = false
    var scheduleModeValue: String = FutureTripScheduleMode.timed.rawValue
    var orderIndex: Int = 0
    var activityTypeValue: String?
    var createdAt: Date = Date()
    var isCompleted: Bool = false
    var completedAt: Date?

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    var scheduleMode: FutureTripScheduleMode {
        get { FutureTripScheduleMode(rawValue: scheduleModeValue) ?? .timed }
        set { scheduleModeValue = newValue.rawValue }
    }

    var isOrdered: Bool {
        scheduleMode == .ordered
    }

    init(
        id: UUID = UUID(),
        placeID: UUID? = nil,
        placeName: String,
        address: String? = nil,
        notes: String? = nil,
        coordinate: CLLocationCoordinate2D,
        arrivalDate: Date,
        hasPlanDate: Bool = true,
        hasArrivalTime: Bool,
        scheduleMode: FutureTripScheduleMode = .timed,
        orderIndex: Int = 0,
        activityTypeValue: String? = nil,
        createdAt: Date = Date(),
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.placeID = placeID
        self.placeName = placeName
        self.address = address
        self.notes = notes
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.arrivalDate = arrivalDate
        self.hasPlanDate = hasPlanDate
        self.hasArrivalTime = hasArrivalTime
        self.scheduleModeValue = scheduleMode.rawValue
        self.orderIndex = orderIndex
        self.activityTypeValue = activityTypeValue
        self.createdAt = createdAt
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    func shouldOfferCompletion(currentDistance: CLLocationDistance?, now: Date = Date()) -> Bool {
        guard !isOrdered else { return false }
        guard let currentDistance, currentDistance >= Self.completionDistanceThreshold else { return false }

        if hasArrivalTime {
            return now.timeIntervalSince(arrivalDate) >= Self.timedCompletionGrace
        }

        let calendar = Calendar.current
        let arrivalDay = calendar.startOfDay(for: arrivalDate)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: arrivalDay) ?? arrivalDay.addingTimeInterval(Self.untimedCompletionGrace)
        return now >= nextDay
    }

    func effectiveArrivalDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        if hasArrivalTime {
            return arrivalDate
        } else {
            let startOfDay = calendar.startOfDay(for: arrivalDate)
            return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: startOfDay) ?? arrivalDate.addingTimeInterval(24 * 3600 - 1)
        }
    }

    func markCompleted(at date: Date = Date()) {
        isCompleted = true
        completedAt = date
    }

    static let completionDistanceThreshold: CLLocationDistance = 500
    static let timedCompletionGrace: TimeInterval = 6 * 3600
    static let untimedCompletionGrace: TimeInterval = 24 * 3600

    static func dayOrdered(_ trips: [FutureTrip]) -> [FutureTrip] {
        let hasExplicitOrder = trips.contains { $0.orderIndex > 0 }
        return trips.sorted { lhs, rhs in
            if lhs.hasPlanDate != rhs.hasPlanDate {
                return lhs.hasPlanDate
            }

            if hasExplicitOrder {
                let leftOrder = lhs.orderIndex > 0 ? lhs.orderIndex : Int.max
                let rightOrder = rhs.orderIndex > 0 ? rhs.orderIndex : Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
            }

            if lhs.arrivalDate != rhs.arrivalDate {
                return lhs.arrivalDate < rhs.arrivalDate
            }

            return lhs.createdAt < rhs.createdAt
        }
    }

    static func loadLegacyTrips() -> [LegacyFutureTrip] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([LegacyFutureTrip].self, from: data)) ?? []
    }

    static func postDidChangeNotification() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum FutureTripScheduleMode: String, Codable, CaseIterable, Identifiable {
    case timed
    case ordered

    var id: String { rawValue }
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

#if canImport(ActivityKit)
import ActivityKit

public struct TripActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var currentDistance: Double // in meters
        public var remainingMinutes: Int
        public var placeName: String
        public var arrivalDate: Date
        public var latitude: Double
        public var longitude: Double
        public var icon: String
        public var hasArrivalTime: Bool
        public var isOrdered: Bool
        public var shouldOfferCompletion: Bool
        
        public init(currentDistance: Double, remainingMinutes: Int, placeName: String, arrivalDate: Date, latitude: Double, longitude: Double, icon: String, hasArrivalTime: Bool, isOrdered: Bool, shouldOfferCompletion: Bool) {
            self.currentDistance = currentDistance
            self.remainingMinutes = remainingMinutes
            self.placeName = placeName
            self.arrivalDate = arrivalDate
            self.latitude = latitude
            self.longitude = longitude
            self.icon = icon
            self.hasArrivalTime = hasArrivalTime
            self.isOrdered = isOrdered
            self.shouldOfferCompletion = shouldOfferCompletion
        }
    }
    
    public var tripId: String
    
    public init(tripId: String) {
        self.tripId = tripId
    }
}
#endif
