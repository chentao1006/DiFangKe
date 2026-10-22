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

// MARK: - Current trip domain

enum TripKind: String, Codable, CaseIterable {
    case historical
    case planned
}

enum TripState: String, Codable, CaseIterable {
    case draft
    case planned
    case active
    case historical
    case cancelled
}

enum TripOrigin: String, Codable {
    case manual
    case automatic
}

enum TripEndReason: String, Codable {
    case manual
    case returnedHome
    case corrected
}

enum TripItemKind: String, Codable, Sendable {
    case stop
    case transport
}

enum TripStopScope: String, Codable {
    case city
    case place
}

/// A trip is a document layered over the timeline. Planned content never becomes
/// a Footprint or TransportRecord merely because the trip is started.
@Model
final class Trip {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var activityTypeValue: String?
    var kindRaw: String = TripKind.historical.rawValue
    var stateRaw: String = TripState.historical.rawValue
    var originRaw: String = TripOrigin.manual.rawValue
    var plannedStartDay: Date = Date()
    var plannedEndDay: Date = Date()
    var actualStartedAt: Date?
    var actualEndedAt: Date?
    var endReasonRaw: String?
    var homeCityKeyAtCreation: String?
    var titleUserEdited: Bool = false
    var datesUserEdited: Bool = false
    var citiesUserEdited: Bool = false
    var coverTypeRaw: String = "mapSnapshot"
    var coverPhotoIdentifier: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var kind: TripKind {
        get { TripKind(rawValue: kindRaw) ?? .historical }
        set { kindRaw = newValue.rawValue }
    }

    var state: TripState {
        get { TripState(rawValue: stateRaw) ?? .historical }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        kind: TripKind,
        state: TripState,
        origin: TripOrigin = .manual,
        plannedStartDay: Date,
        plannedEndDay: Date
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.kindRaw = kind.rawValue
        self.stateRaw = state.rawValue
        self.originRaw = origin.rawValue
        self.plannedStartDay = plannedStartDay
        self.plannedEndDay = plannedEndDay
        self.titleUserEdited = true
    }
}

@Model
final class TripDay {
    var id: UUID = UUID()
    var tripID: UUID = UUID()
    var day: Date = Date()
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var orderIndex: Int = 0
    var notes: String = ""

    init(id: UUID = UUID(), tripID: UUID, day: Date, timeZoneIdentifier: String = TimeZone.current.identifier, orderIndex: Int = 0, notes: String = "") {
        self.id = id
        self.tripID = tripID
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.orderIndex = orderIndex
        self.notes = notes
    }
}

@Model
final class TripDayCity {
    var id: UUID = UUID()
    var tripDayID: UUID = UUID()
    var countryCode: String = ""
    var countryName: String = ""
    var cityName: String = ""
    var latitude: Double?
    var longitude: Double?
    var timeZoneIdentifier: String?
    var orderIndex: Int = 0
    var notes: String = ""
    var isUserEdited: Bool = false

    init(id: UUID = UUID(), tripDayID: UUID, countryCode: String = "", countryName: String = "", cityName: String, latitude: Double? = nil, longitude: Double? = nil, timeZoneIdentifier: String? = nil, orderIndex: Int = 0, notes: String = "", isUserEdited: Bool = true) {
        self.id = id
        self.tripDayID = tripDayID
        self.countryCode = countryCode
        self.countryName = countryName
        self.cityName = cityName
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.orderIndex = orderIndex
        self.notes = notes
        self.isUserEdited = isUserEdited
    }
}

@Model
final class TripItem {
    var id: UUID = UUID()
    var tripDayID: UUID = UUID()
    var kindRaw: String = TripItemKind.stop.rawValue
    var orderIndex: Int = 0
    var stopScopeRaw: String?
    var countryCode: String?
    var countryName: String?
    var cityName: String?
    var placeID: UUID?
    var placeName: String?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var startTime: Date?
    var endTime: Date?
    var activityTypeValue: String?
    var transportTypeRaw: String?
    var lineName: String?
    var startLocationName: String?
    var endLocationName: String?
    var notes: String = ""
    var sourceFootprintID: UUID?
    var sourceTransportRecordID: UUID?
    var planStatusRaw: String = "planned"
    @Transient var actualPhotoAssetIDs: [String] = []

    init(id: UUID = UUID(), tripDayID: UUID, kind: TripItemKind, orderIndex: Int = 0) {
        self.id = id
        self.tripDayID = tripDayID
        self.kindRaw = kind.rawValue
        self.orderIndex = orderIndex
    }
}

/// Single-row user setting. The city is selected manually; it is never inferred.
@Model
final class HomeCity {
    var id: UUID = UUID()
    var countryCode: String = ""
    var countryName: String = ""
    var cityName: String = ""
    var latitude: Double?
    var longitude: Double?
    var timeZoneIdentifier: String?
    var updatedAt: Date = Date()

    init(cityName: String, countryCode: String = "", countryName: String = "") {
        self.cityName = cityName
        self.countryCode = countryCode
        self.countryName = countryName
    }
}
