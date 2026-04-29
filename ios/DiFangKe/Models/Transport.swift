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
    case ship = "ship"                 // 轮船
    
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
        case .ship: return "ferry.fill"
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
        case .ship: return "ferry.fill"
        }
    }
    
    static func from(speed: Double, motionType: MotionType = .unknown, stepCount: Int = 0, duration: TimeInterval = 0, preferredAutomotive: TransportType = .car, preferredCycling: TransportType = .bicycle) -> TransportType {
        let kmh = speed * 3.6
        
        // --- 物理常识铁律：最高速度约束 ---
        var effectiveMotionType = motionType
        if kmh > 15 && motionType == .walking {
            effectiveMotionType = .unknown // 步行不可能超过 15km/h，传感器数据存疑，降级到兜底逻辑
        }
        if kmh > 35 && motionType == .running {
            effectiveMotionType = .unknown // 跑步很难持续超过 35km/h
        }
        if kmh > 45 && (motionType == .walking || motionType == .running) {
            effectiveMotionType = .automotive // 确定是车载
        }
        if kmh > 100 && motionType == .cycling {
            effectiveMotionType = .automotive 
        }

        // 1. 优先使用传感器数据 (Core Motion)
        switch effectiveMotionType {
        case .walking:
            return kmh > 7 ? .running : .slow
        case .running:
            return .running
        case .cycling:
            if kmh > 55 { return preferredAutomotive } 
            return preferredCycling
        case .automotive:
            if kmh > 100 { return .train }
            if kmh > 80 && preferredAutomotive == .bus { return .car } 
            return preferredAutomotive
        default:
            break
        }
        
        // 2. 结合步数判定 (HealthKit)
        if stepCount > 100 && duration > 0 {
            let stepsPerMinute = Double(stepCount) / (duration / 60)
            if stepsPerMinute > 140 && kmh < 35 { return .running }
            if stepsPerMinute > 30 && kmh < 15 { return .slow }
        }
        
        // 3. 速度兜底 (传统逻辑)
        if kmh < 4.5 { 
            // 如果速度极低，但步数也很少（每分钟不到 5 步），说明大概率是在车里堵车，而不是真的在走
            let stepsPerMin = duration > 0 ? Double(stepCount) / (duration / 60) : 0
            if stepsPerMin < 5 && stepCount < 20 {
                return preferredAutomotive 
            }
            return .slow 
        }
        if kmh < 12 { return .bicycle }
        if kmh < 25 { return preferredCycling } 
        if kmh < 120 { return preferredAutomotive }
        if kmh < 350 { return .train }
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
        case .ship: return "轮船"
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
    var stepCount: Int? = nil
    
    init(id: UUID = UUID(), startTime: Date, endTime: Date, startLocation: String, endLocation: String, type: TransportType, distance: Double, averageSpeed: Double, points: [CLLocationCoordinate2D], manualType: TransportType? = nil, stepCount: Int? = nil) {
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
        self.stepCount = stepCount
    }
    
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    var currentType: TransportType {
        manualType ?? type
    }
    
    func updatingStart(_ location: String) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: location, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: manualType, stepCount: stepCount)
    }
    
    func updatingEnd(_ location: String) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: location, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: manualType, stepCount: stepCount)
    }
    
    func updatingType(_ newType: TransportType) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: newType, stepCount: stepCount)
    }

    func updatingTimes(start: Date, end: Date) -> Transport {
        Transport(id: id, startTime: start, endTime: end, startLocation: startLocation, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, manualType: manualType, stepCount: stepCount)
    }

    func updatingPoints(_ newPoints: [CLLocationCoordinate2D]) -> Transport {
        var newDistance: Double = 0
        if newPoints.count >= 2 {
            for i in 0..<newPoints.count - 1 {
                let p1 = CLLocation(latitude: newPoints[i].latitude, longitude: newPoints[i].longitude)
                let p2 = CLLocation(latitude: newPoints[i+1].latitude, longitude: newPoints[i+1].longitude)
                newDistance += p1.distance(from: p2)
            }
        }
        let duration = endTime.timeIntervalSince(startTime)
        let newSpeed = duration > 0 ? newDistance / duration : 0
        
        return Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: endLocation, type: type, distance: newDistance, averageSpeed: newSpeed, points: newPoints, manualType: manualType, stepCount: stepCount)
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
    var stepCount: Int? = nil
    
    init(recordID: UUID = UUID(), day: Date, startTime: Date, endTime: Date, startLocation: String = "起点", endLocation: String = "终点", typeRaw: String, distance: Double, averageSpeed: Double, pointsData: Data, statusRaw: String = "active", stepCount: Int? = nil) {
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
        self.stepCount = stepCount
    }
}
