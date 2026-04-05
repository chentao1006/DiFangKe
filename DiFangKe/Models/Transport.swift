import Foundation
import CoreLocation
import SwiftData

@Model
final class TransportManualSelection {
    var recordID: UUID = UUID()
    var startTime: Date = Date()
    var endTime: Date = Date()
    var vehicleType: String = ""
    
    init(recordID: UUID = UUID(), startTime: Date = Date(), endTime: Date = Date(), vehicleType: String = "") {
        self.recordID = recordID
        self.startTime = startTime
        self.endTime = endTime
        self.vehicleType = vehicleType
    }
}

enum TransportType: String, CaseIterable, Codable {
    case superSlow = "superSlow"       // 龟速
    case slow = "slow"                 // 步行
    case bicycle = "bicycle"           // 自行车
    case motorcycle = "motorcycle"     // 摩托车
    case bus = "bus"                   // 公交/大巴
    case car = "car"                   // 汽车
    case train = "train"               // 火车/高铁
    case airplane = "airplane"         // 飞机
    
    var icon: String {
        switch self {
        case .superSlow: return "turtle.fill"
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
        case .superSlow: return "tortoise.fill"
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
        if kmh < 3 { return .superSlow }
        if kmh < 8 { return .slow }
        if kmh < 20 { return .bicycle }
        if kmh < 40 { return .motorcycle }
        if kmh < 70 { return .bus }
        if kmh < 120 { return .car }
        if kmh < 450 { return .train }
        return .airplane
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
