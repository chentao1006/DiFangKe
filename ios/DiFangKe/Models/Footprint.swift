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
    // Canonical hierarchy from reverse geocoding. Keep these separate from
    // display address/place name so statistics never infer geography from POI text.
    var countryCode: String?
    var countryName: String?
    var cityName: String?
    
    var isHighlight: Bool?
    var isPlaceSuggestionIgnored: Bool = false
    var aiAnalyzed: Bool = false
    var isAddressEditedByHand: Bool = false
    var activityTypeValue: String?
    var allowsAutomaticDurationExtension: Bool = false
    
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
    
    func setManualActivityType(_ value: String?) {
        // Changing an activity does not establish a manually fixed end time.
        // Existing manual splits/time edits remain fixed, including legacy data.
        if status != .manual { allowsAutomaticDurationExtension = true }
        activityTypeValue = value
        status = .manual
    }

    /// Extend only a continuous, observed stay. Never cross a transport or a
    /// separately persisted stay (especially either side of a manual split).
    static func extendActivityEditedStay(start: Date, end: Date, coordinate: CLLocationCoordinate2D,
                                        context: ModelContext) -> Bool {
        guard end > start else { return false }
        // Successive GPS batches do not share a timestamp. Allow a short
        // sampling gap while still checking every intervening persisted boundary.
        let earliestPreviousEnd = start.addingTimeInterval(-60)
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.statusValue == "manual" && $0.allowsAutomaticDurationExtension &&
            $0.startTime <= start && $0.endTime >= earliestPreviousEnd && $0.endTime < end
        }, sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        guard let existing = (try? context.fetch(descriptor))?.first,
              Calendar.current.isDate(existing.startTime, inSameDayAs: end.addingTimeInterval(-0.001)),
              !existing.footprintLocations.isEmpty,
              CLLocation(latitude: existing.latitude, longitude: existing.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < AppConfig.shared.stayDistanceThreshold else { return false }
        let extensionStart = existing.endTime
        let ownID = existing.footprintID
        let otherStays = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.footprintID != ownID && $0.startTime < end && $0.endTime > extensionStart
        })
        let transports = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime < end && $0.endTime > extensionStart
        })
        guard let stays = try? context.fetch(otherStays), stays.isEmpty,
              let trips = try? context.fetch(transports), trips.isEmpty else { return false }
        existing.endTime = end
        return true
    }

    @discardableResult
    static func removeAutomaticFootprintsOwnedByManual(_ footprints: [Footprint], context: ModelContext) -> Set<UUID> {
        let manuals = footprints.filter { $0.status == .manual }
        var removed = Set<UUID>()
        for footprint in footprints where footprint.status != .manual && footprint.status != .ignored && footprint.endTime > footprint.startTime {
            guard Footprint.automaticStayIntervals(start: footprint.startTime, end: footprint.endTime, manuals: manuals).isEmpty else { continue }
            // Preserve the manual record verbatim, including intentionally cleared fields.
            removed.insert(footprint.footprintID)
            context.delete(footprint)
        }
        return removed
    }

    /// Manual edits own their time ranges, independently of the selected activity.
    /// A replay with near-identical endpoints is the same stay, including a short
    /// departure tail; adjacent visits and explicit split records remain separate.
    static func automaticStayIntervals(start: Date, end: Date, manuals: [Footprint]) -> [(start: Date, end: Date)] {
        guard end > start else { return [] }
        let overlapping = manuals.filter {
            $0.status == .manual && $0.startTime < end && $0.endTime > start
        }
        if overlapping.contains(where: {
            abs($0.startTime.timeIntervalSince(start)) <= 300 &&
            abs($0.endTime.timeIntervalSince(end)) <= 300
        }) { return [] }

        var intervals = [(start: start, end: end)]
        for manual in overlapping {
            intervals = intervals.flatMap { interval -> [(start: Date, end: Date)] in
                guard manual.startTime < interval.end, manual.endTime > interval.start else { return [interval] }
                var remaining: [(start: Date, end: Date)] = []
                if interval.start < manual.startTime { remaining.append((interval.start, manual.startTime)) }
                if manual.endTime < interval.end { remaining.append((manual.endTime, interval.end)) }
                return remaining
            }
        }
        return intervals
    }

    static func automaticStayIntervals(start: Date, end: Date, context: ModelContext) -> [(start: Date, end: Date)] {
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.statusValue == "manual" && $0.startTime < end && $0.endTime > start
        })
        // Fail closed: a failed fetch must not produce an unprotected duplicate.
        guard let manuals = try? context.fetch(descriptor) else { return [] }
        return automaticStayIntervals(start: start, end: end, manuals: manuals)
    }

    func updateActivityType(to newValue: String?, in context: ModelContext) {
        let target: Footprint
        let myID = self.footprintID
        let selfDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.footprintID == myID }
        )
        if let stored = (try? context.fetch(selfDescriptor))?.first {
            target = stored
        } else {
            target = self
            if target.modelContext == nil {
                context.insert(target)
            }
        }

        // 自动把当天相同地点且无活动类型的足迹都改成同样活动。用户选择“无”时只改当前足迹，
        // 并标记为 manual，避免后台习惯识别再次补回活动类型。
        let currentAddress = self.address ?? ""
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: self.startTime)
        if let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) {
            let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime >= startOfDay && $0.startTime < endOfDay
            })
            
            if let footprints = try? context.fetch(descriptor) {
                for fp in footprints {
                    if fp.footprintID == myID {
                        // 实际在 ModelContext 中被管理的“自己”
                        fp.setManualActivityType(newValue)
                    } else if newValue != nil, fp.status != .manual, fp.status != .ignored,
                              !currentAddress.isEmpty, fp.activityTypeValue == nil, fp.address == currentAddress {
                        // 自动更新同地点且无活动类型的其他足迹
                        fp.activityTypeValue = newValue
                    }
                }
            }
        }
        
        // 最后修改自己的值，防止 UI 绑定的（可能是未被 Context 管理的快照对象）未能及时刷新
        target.setManualActivityType(newValue)
        self.activityTypeValue = newValue
        self.status = .manual
        self.allowsAutomaticDurationExtension = target.allowsAutomaticDurationExtension
    }
}
