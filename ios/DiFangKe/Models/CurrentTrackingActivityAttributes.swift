#if canImport(ActivityKit)
import ActivityKit
import Foundation

public enum CurrentTrackingActivityKind: String, Codable, Hashable {
    case footprint
    case transport
}

/// Shared ActivityKit contract for the current recognized footprint or transport.
/// The kind lives in ContentState so one Live Activity can transition in place.
public struct CurrentTrackingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var kind: CurrentTrackingActivityKind
        public var recordID: String
        public var startedAt: Date
        public var title: String
        public var icon: String
        public var colorHex: String?
        public var placeName: String
        public var address: String?
        public var startLocation: String?
        public var distance: Double?
        public var averageSpeed: Double?
        public var latitude: Double
        public var longitude: Double
        public var mapRevision: Int
        public var prefersDarkMap: Bool?
        public var photoRevision: Int
        public var photoCount: Int
        public var photoThumbnailCount: Int
        public var todayPlaceCount: Int?
        public var todayDistance: Double?
        /// Changes at a controlled cadence so an otherwise identical stationary
        /// state is still submitted to ActivityKit for duration re-rendering.
        public var durationUpdateBucket: Int?

        public init(
            kind: CurrentTrackingActivityKind,
            recordID: String,
            startedAt: Date,
            title: String,
            icon: String,
            colorHex: String?,
            placeName: String,
            address: String?,
            startLocation: String?,
            distance: Double?,
            averageSpeed: Double?,
            latitude: Double,
            longitude: Double,
            mapRevision: Int,
            prefersDarkMap: Bool? = nil,
            photoRevision: Int = 0,
            photoCount: Int = 0,
            photoThumbnailCount: Int = 0,
            todayPlaceCount: Int? = nil,
            todayDistance: Double? = nil,
            durationUpdateBucket: Int? = nil
        ) {
            self.kind = kind
            self.recordID = recordID
            self.startedAt = startedAt
            self.title = title
            self.icon = icon
            self.colorHex = colorHex
            self.placeName = placeName
            self.address = address
            self.startLocation = startLocation
            self.distance = distance
            self.averageSpeed = averageSpeed
            self.latitude = latitude
            self.longitude = longitude
            self.mapRevision = mapRevision
            self.prefersDarkMap = prefersDarkMap
            self.photoRevision = photoRevision
            self.photoCount = photoCount
            self.photoThumbnailCount = photoThumbnailCount
            self.todayPlaceCount = todayPlaceCount
            self.todayDistance = todayDistance
            self.durationUpdateBucket = durationUpdateBucket
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
#endif
