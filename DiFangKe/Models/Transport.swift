import Foundation
import CoreLocation
import SwiftData

@Model
final class TransportManualSelection {
    var recordID: UUID = UUID()
    var startTime: Date = Date()
    var endTime: Date = Date()
    var vehicleType: String = ""
    var isDeleted: Bool = false
    var startLocationOverride: String?
    var endLocationOverride: String?
    
    init(recordID: UUID = UUID(), startTime: Date = Date(), endTime: Date = Date(), vehicleType: String = "", isDeleted: Bool = false, startLocationOverride: String? = nil, endLocationOverride: String? = nil) {
        self.recordID = recordID
        self.startTime = startTime
        self.endTime = endTime
        self.vehicleType = vehicleType
        self.isDeleted = isDeleted
        self.startLocationOverride = startLocationOverride
        self.endLocationOverride = endLocationOverride
    }
}

enum TransportType: String, CaseIterable, Codable {
    case slow = "slow"                 // 步行
    case bicycle = "bicycle"           // 自行车
    case motorcycle = "motorcycle"     // 摩托车
    case bus = "bus"                   // 公交/大巴
    case car = "car"                   // 汽车
    case train = "train"               // 火车/高铁
    case airplane = "airplane"         // 飞机
    
    var icon: String {
        switch self {
        case .slow: return "figure.walk"
        case .bicycle: return "bicycle"
        case .motorcycle: return "moped.fill"
        case .bus: return "bus.fill"
        case .car: return "car.fill"
        case .train: return "train.side.front.car"
        case .airplane: return "airplane"
        }
    }
    
    var sfSymbol: String {
        switch self {
        case .slow: return "figure.walk"
        case .bicycle: return "bicycle"
        case .motorcycle: return "moped.fill"
        case .bus: return "bus.fill"
        case .car: return "car.fill"
        case .train: return "train.side.front.car"
        case .airplane: return "airplane"
        }
    }
    
    static func from(speed: Double) -> TransportType {
        let kmh = speed * 3.6
        if kmh < 6.5 { return .slow }      // < 6.5 km/h: 步行
        if kmh < 12 { return .bicycle }    // 6.5 - 12 km/h: 自行车
        if kmh < 120 { return .car }       // 12 - 120 km/h: 汽车
        if kmh < 450 { return .train }     // 120 - 450 km/h: 火车/高铁
        return .airplane                   // > 450 km/h: 飞机
    }
}

struct Transport: Identifiable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let startLocation: String
    let endLocation: String
    let type: TransportType
    let distance: Double // in meters
    let averageSpeed: Double // in m/s
    let points: [CLLocationCoordinate2D]
    var manualType: TransportType? = nil
    
    init(id: UUID = UUID(), startTime: Date, endTime: Date, startLocation: String, endLocation: String, type: TransportType, distance: Double, averageSpeed: Double, points: [CLLocationCoordinate2D], manualType: TransportType? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startLocation = startLocation
        self.endLocation = endLocation
        self.type = type
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.points = points
        self.manualType = manualType
    }
    
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    var currentType: TransportType {
        manualType ?? type
    }
    
    func updatingStart(_ location: String) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: location, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: manualType)
    }
    
    func updatingEnd(_ location: String) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: location, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: manualType)
    }
    
    func updatingType(_ newType: TransportType) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: newType)
    }
}
