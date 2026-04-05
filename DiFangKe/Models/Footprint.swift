import Foundation
import SwiftData
import CoreLocation

// We use Enum to represent Footprint status
enum FootprintStatus: String, Codable {
    case candidate
    case confirmed
    case ignored
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
    var duration: TimeInterval = 0
    var title: String = ""
    var reason: String?
    var statusValue: String = "candidate"
    var aiScore: Float = 0.0
    var placeID: UUID?
    
    var photoAssetIDsData: Data = Data()
    var tagsData: Data = Data()
    var address: String?
    
    var isHighlight: Bool?
    var isPlaceSuggestionIgnored: Bool = false
    var aiAnalyzed: Bool = false
    var isTitleEditedByHand: Bool = false
    
    var status: FootprintStatus {
        get { FootprintStatus(rawValue: statusValue) ?? .candidate }
        set { statusValue = newValue.rawValue }
    }
    
    // Computed property to reconstruct CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D] {
        zip(latitudeArray, longitudeArray).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
    }
    
    var latitude: Double {
        latitudeArray.first ?? 0
    }
    
    var longitude: Double {
        longitudeArray.first ?? 0
    }
    
    var latitudeArray: [Double] {
        get { (try? JSONDecoder().decode([Double].self, from: latitudeData)) ?? [] }
        set { latitudeData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var longitudeArray: [Double] {
        get { (try? JSONDecoder().decode([Double].self, from: longitudeData)) ?? [] }
        set { longitudeData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var photoAssetIDs: [String] {
        get { (try? JSONDecoder().decode([String].self, from: photoAssetIDsData)) ?? [] }
        set { photoAssetIDsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var tags: [String] {
        get { (try? JSONDecoder().decode([String].self, from: tagsData)) ?? [] }
        set { tagsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
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
         title: String? = nil,
         reason: String? = nil,
         status: FootprintStatus = .candidate,
         aiScore: Float = 0.0,
         isHighlight: Bool? = nil,
         placeID: UUID? = nil,
         photoAssetIDs: [String] = [],
         tags: [String] = [],
         address: String? = nil,
         isPlaceSuggestionIgnored: Bool = false,
         aiAnalyzed: Bool = false,
         isTitleEditedByHand: Bool = false) {
        
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
        self.isTitleEditedByHand = isTitleEditedByHand
        
        // Use provided title, or address, or default to "新足迹"
        if let title = title, !title.isEmpty {
            self.title = title
        } else if let address = address, !address.isEmpty {
            self.title = address
        } else {
            self.title = "地点记录"
        }
        
        // Use setters for computed properties
        self.latitudeArray = footprintLocations.map { $0.latitude }
        self.longitudeArray = footprintLocations.map { $0.longitude }
        self.photoAssetIDs = photoAssetIDs
        self.tags = tags
    }
}
