import Foundation
import SwiftData
import CoreLocation

// We use Enum to represent Footprint status
enum FootprintStatus: String, Codable {
    case candidate
    case confirmed
    case ignored
    case manual // 人工修改或添加
}

// 照片元数据，用于跨设备找回照片（Cloud Identifier 方案）
struct PhotoMetadata: Codable, Equatable {
    var localIdentifier: String
    var cloudIdentifier: String?
}

@Model
final class Footprint {
    var footprintID: UUID = UUID()
    var date: Date = Date()
    var startTime: Date = Date()
    var endTime: Date = Date()
    
    var latitudeData: Data = Data()
    var longitudeData: Data = Data()
    
    var locationHash: String = ""
    // Computed property for duration ensures synchronization with startTime and endTime
    // Marking as non-stored to avoid data drift
    var duration: TimeInterval {
        get { max(0, endTime.timeIntervalSince(startTime)) }
        set { /* No-op: duration is derived from start/end times */ }
    }
    var reason: String?
    var statusValue: String = "candidate"
    var aiScore: Float = 0.0
    var placeID: UUID?
    
    var photoAssetIDsData: Data = Data()
    var photoMetadataData: Data = Data() // 存储云端同步元数据
    var address: String?
    
    var isHighlight: Bool?
    var isPlaceSuggestionIgnored: Bool = false
    var aiAnalyzed: Bool = false
    var isAddressEditedByHand: Bool = false
    var activityTypeValue: String?
    
    // Health metrics
    var stepCount: Int?
    var walkingDistance: Double?
    var floorsAscended: Int?
    
    var status: FootprintStatus {
        get { FootprintStatus(rawValue: statusValue) ?? .candidate }
        set { statusValue = newValue.rawValue }
    }

    var isUserModifiedForDailySummary: Bool {
        if status == .manual || status == .confirmed {
            return true
        }

        if isAddressEditedByHand || isHighlight == true || !photoAssetIDs.isEmpty {
            return true
        }

        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return false
    }
    
    func getActivityType(from allActivities: [ActivityType]) -> ActivityType? {
        guard let val = activityTypeValue else { return nil }
        return allActivities.first { $0.id.uuidString == val || $0.name == val }
    }
    
    // Computed property to reconstruct CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D] {
        zip(latitudeArray, longitudeArray).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
    }
    
    var latitude: Double {
        guard !latitudeArray.isEmpty else { return 0 }
        return latitudeArray.reduce(0, +) / Double(latitudeArray.count)
    }
    
    var longitude: Double {
        guard !longitudeArray.isEmpty else { return 0 }
        return longitudeArray.reduce(0, +) / Double(longitudeArray.count)
    }
    
    @Transient private var _cachedLatitudes: [Double]?
    @Transient private var _cachedLongitudes: [Double]?
    @Transient private var _cachedPhotoIDs: [String]?
 
    var latitudeArray: [Double] {
        get { 
            if let cached = _cachedLatitudes { return cached }
            let decoded = (try? JSONDecoder().decode([Double].self, from: latitudeData)) ?? []
            _cachedLatitudes = decoded
            return decoded
        }
        set { 
            _cachedLatitudes = newValue
            latitudeData = (try? JSONEncoder().encode(newValue)) ?? Data() 
        }
    }
 
    var longitudeArray: [Double] {
        get { 
            if let cached = _cachedLongitudes { return cached }
            let decoded = (try? JSONDecoder().decode([Double].self, from: longitudeData)) ?? []
            _cachedLongitudes = decoded
            return decoded
        }
        set { 
            _cachedLongitudes = newValue
            longitudeData = (try? JSONEncoder().encode(newValue)) ?? Data() 
        }
    }
 
    @Transient private var _cachedPhotoMetadata: [PhotoMetadata]?
 
     var photoAssetIDs: [String] {
         get { 
             if let cached = _cachedPhotoIDs { return cached }
             let decoded = (try? JSONDecoder().decode([String].self, from: photoAssetIDsData)) ?? []
             _cachedPhotoIDs = decoded
             return decoded
         }
         set { 
             _cachedPhotoIDs = newValue
             photoAssetIDsData = (try? JSONEncoder().encode(newValue)) ?? Data() 
         }
     }
  
    var photoMetadata: [PhotoMetadata] {
        get {
            if let cached = _cachedPhotoMetadata { return cached }
            let decoded = (try? JSONDecoder().decode([PhotoMetadata].self, from: photoMetadataData)) ?? []
            _cachedPhotoMetadata = decoded
            return decoded
        }
        set {
            _cachedPhotoMetadata = newValue
            photoMetadataData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
 
    
    var footprintLocations: [CLLocationCoordinate2D] {
        get {
            zip(latitudeArray, longitudeArray).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
        }
        set {
            self.latitudeArray = newValue.map { $0.latitude }
            self.longitudeArray = newValue.map { $0.longitude }
        }
    }
    
    init(footprintID: UUID = UUID(),
         date: Date,
         startTime: Date,
         endTime: Date,
         footprintLocations: [CLLocationCoordinate2D],
         locationHash: String,
         duration: TimeInterval,
         reason: String? = nil,
         status: FootprintStatus = .candidate,
         aiScore: Float = 0.0,
         isHighlight: Bool? = nil,
         placeID: UUID? = nil,
         photoAssetIDs: [String] = [],
         address: String? = nil,
         isPlaceSuggestionIgnored: Bool = false,
         aiAnalyzed: Bool = false,
         isAddressEditedByHand: Bool = false,
         activityType: ActivityType? = nil,
         activityTypeValue: String? = nil,
         stepCount: Int? = nil,
         walkingDistance: Double? = nil,
         floorsAscended: Int? = nil) {
        
        self.footprintID = footprintID
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.locationHash = locationHash
        self.duration = duration
        self.reason = reason
        self.statusValue = status.rawValue
        self.aiScore = aiScore
        self.isHighlight = isHighlight
        self.placeID = placeID
        self.address = address
        self.isPlaceSuggestionIgnored = isPlaceSuggestionIgnored
        self.aiAnalyzed = aiAnalyzed
        self.isAddressEditedByHand = isAddressEditedByHand
        self.activityTypeValue = activityTypeValue ?? activityType?.id.uuidString
        self.stepCount = stepCount
        self.walkingDistance = walkingDistance
        self.floorsAscended = floorsAscended
        
        // Use setters for computed properties
        self.latitudeArray = footprintLocations.map { $0.latitude }
        self.longitudeArray = footprintLocations.map { $0.longitude }
        self.photoAssetIDs = photoAssetIDs
    }
}
