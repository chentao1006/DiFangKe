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
    case running = "running"           // 跑步
    case bicycle = "bicycle"           // 自行车
    case ebike = "ebike"               // 电动车
    case motorcycle = "motorcycle"     // 摩托车
    case bus = "bus"                   // 公交/大巴
    case car = "car"                   // 汽车
    case subway = "subway"             // 轨道交通
    case train = "train"               // 火车/高铁
    case airplane = "airplane"         // 飞机
    
    var icon: String {
        switch self {
        case .slow: return "figure.walk"
        case .running: return "figure.run"
        case .bicycle: return "bicycle"
        case .ebike: return "moped.fill"
        case .motorcycle: return "motorcycle.fill"
        case .bus: return "bus.fill"
        case .car: return "car.fill"
        case .subway: return "tram.fill"
        case .train: return "train.side.front.car"
        case .airplane: return "airplane"
        }
    }
    
    var sfSymbol: String {
        switch self {
        case .slow: return "figure.walk"
        case .running: return "figure.run"
        case .bicycle: return "bicycle"
        case .ebike: return "moped.fill"
        case .motorcycle: return "motorcycle.fill"
        case .bus: return "bus.fill"
        case .car: return "car.fill"
        case .subway: return "tram.fill"
        case .train: return "train.side.front.car"
        case .airplane: return "airplane"
        }
    }
    
    static func from(speed: Double) -> TransportType {
        let kmh = speed * 3.6
        if kmh < 2 { return .slow }      
        if kmh < 3 { return .running }   
        if kmh < 10 { return .bicycle }    
        if kmh < 20 { return .ebike }       
        if kmh < 40 { return .motorcycle }  
        if kmh < 100 { return .car }       
        if kmh < 300 { return .train }     
        return .airplane                   
    }

    
    var localizedName: String {
        switch self {
        case .slow: return "步行"
        case .running: return "跑步"
        case .bicycle: return "自行车"
        case .ebike: return "电动车"
        case .motorcycle: return "摩托车"
        case .bus: return "公交/大巴"
        case .car: return "汽车"
        case .subway: return "轨道交通"
        case .train: return "火车/高铁"
        case .airplane: return "飞机"
        }
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

@Model
final class TransportRecord {
    var recordID: UUID = UUID()
    var day: Date = Date()
    var startTime: Date = Date()
    var endTime: Date = Date()
    var startLocation: String = "起点"
    var endLocation: String = "终点"
    var typeRaw: String = ""
    var distance: Double = 0
    var averageSpeed: Double = 0
    var pointsData: Data = Data()
    var manualTypeRaw: String? = nil
    var statusRaw: String = "active" // active, ignored
    
    init(recordID: UUID = UUID(), day: Date, startTime: Date, endTime: Date, startLocation: String = "起点", endLocation: String = "终点", typeRaw: String, distance: Double, averageSpeed: Double, pointsData: Data, statusRaw: String = "active") {
        self.recordID = recordID
        self.day = day
        self.startTime = startTime
        self.endTime = endTime
        self.startLocation = startLocation
        self.endLocation = endLocation
        self.typeRaw = typeRaw
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.pointsData = pointsData
        self.statusRaw = statusRaw
    }
}
