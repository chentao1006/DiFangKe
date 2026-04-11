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
    var activityTypeValue: String?
    
    var status: FootprintStatus {
        get { FootprintStatus(rawValue: statusValue) ?? .candidate }
        set { statusValue = newValue.rawValue }
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
         isTitleEditedByHand: Bool = false,
         activityType: ActivityType? = nil,
         activityTypeValue: String? = nil) {
        
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
        self.activityTypeValue = activityTypeValue ?? activityType?.id.uuidString
        
        // Use provided title, or address, or default to generic poetic title
        if let title = title, !title.isEmpty {
            self.title = title
        } else if let address = address, !address.isEmpty {
            self.title = Footprint.generateRandomTitle(for: address, seed: Int(startTime.timeIntervalSince1970))
        } else {
            self.title = Footprint.generateRandomTitle(for: "此处", seed: Int(startTime.timeIntervalSince1970))
        }
        
        // Use setters for computed properties
        self.latitudeArray = footprintLocations.map { $0.latitude }
        self.longitudeArray = footprintLocations.map { $0.longitude }
        self.photoAssetIDs = photoAssetIDs
    }
    
    static let titleTemplates = [
        "在%@停留",
        "在%@驻足",
        "寻迹于%@",
        "在%@的一段时光"
    ]
    
    /// 判断标题是否为系统生成的通用占位符
    static func isGenericTitle(_ title: String) -> Bool {
        let placeholders = ["地点记录", "正在获取位置...", "未知地点", "点位记录", "发现足迹", "寻迹此处", "在某地停留", "此处", "某地", ""]
        if placeholders.contains(title) { return true }
        
        // 核心：检查是否符合随机模板中的“某地”或“此处”
        for word in ["此处", "某地"] {
            for template in titleTemplates {
                if title == String(format: template, word) {
                    return true
                }
            }
        }
        return false
    }

    /// 生成随机但确定（基于 seed 或名称）的、带有“地方客”风格的足迹标题
    static func generateRandomTitle(for locationName: String, seed: Int? = nil) -> String {
        // Use provided seed (e.g., startTime) or a stable hash of the name to ensure reproducibility
        let stableSeed = seed ?? locationName.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(stableSeed) % titleTemplates.count
        let template = titleTemplates[index]
        return String(format: template, locationName)
    }
}
