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
        
        // Use provided title, or address, or default to generic poetic title
        if let title = title, !title.isEmpty {
            self.title = title
        } else if let address = address, !address.isEmpty {
            self.title = Footprint.generateRandomTitle(for: address)
        } else {
            self.title = "寻迹此处"
        }
        
        // Use setters for computed properties
        self.latitudeArray = footprintLocations.map { $0.latitude }
        self.longitudeArray = footprintLocations.map { $0.longitude }
        self.photoAssetIDs = photoAssetIDs
    }
    
    /// 生成随机但确定（基于 seed 或名称）的、带有“地方客”风格的足迹标题
    static func generateRandomTitle(for locationName: String, seed: Int? = nil) -> String {
        let templates = [
            "在%@停留",
            "在%@驻足",
            "寻迹于%@",
            "在%@的一段时光"
        ]
        
        // Use provided seed (e.g., startTime) or a stable hash of the name to ensure reproducibility
        let stableSeed = seed ?? locationName.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(stableSeed) % templates.count
        let template = templates[index]
        return String(format: template, locationName)
    }
}
