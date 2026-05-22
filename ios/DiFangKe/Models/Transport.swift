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
    
    static func from(
        speed: Double,
        motionType: MotionType = .unknown,
        stepCount: Int = 0,
        walkingDistance: Double = 0,
        floorsClimbed: Int = 0,
        duration: TimeInterval = 0,
        distanceMeters: Double = 0,
        preferredAutomotive: TransportType = .car,
        preferredCycling: TransportType = .bicycle
    ) -> TransportType {
        let kmh = speed * 3.6
        let minutes = max(duration / 60, 0)
        let estimatedDistance = max(speed * duration, 0)
        let effectiveDistance = distanceMeters > 0 ? distanceMeters : estimatedDistance
        let stepsPerMinute = minutes > 0 ? Double(stepCount) / minutes : 0
        let walkingDistanceRatio = estimatedDistance > 0 ? min(1.5, walkingDistance / estimatedDistance) : 0
        let hasStrongOnFootEvidence =
            (walkingDistance > 250 && walkingDistanceRatio > 0.55) ||
            (stepsPerMinute > 35 && walkingDistance > 120) ||
            (floorsClimbed >= 2 && walkingDistance > 80)
        
        // --- 物理常识铁律：最高速度约束 ---
        var effectiveMotionType = motionType
        if kmh > 15 && motionType == .walking {
            effectiveMotionType = .unknown // 步行不可能超过 15km/h，传感器数据存疑，降级到兜底逻辑
        }
        if kmh > 35 && motionType == .running {
            effectiveMotionType = .unknown // 跑步很难持续超过 35km/h
        }
        if kmh > 45 && (motionType == .walking || motionType == .running || motionType == .unknown) {
            effectiveMotionType = .automotive // 确定是车载
        }
        if kmh > 100 && motionType == .cycling {
            effectiveMotionType = .automotive 
        }
        if effectiveMotionType == .automotive && hasStrongOnFootEvidence && kmh < 22 {
            effectiveMotionType = .walking
        }

        // --- 综合常识铁律：距离与时间的合理性 ---
        var maxAllowedTypeCategory = 4 // 1=Foot, 2=Cycle, 3=Auto, 4=Large
        
        if effectiveDistance < 3000 {
            maxAllowedTypeCategory = 3
        }
        if effectiveDistance < 500 {
            maxAllowedTypeCategory = 2
        }

        var safePreferredAuto = preferredAutomotive
        if maxAllowedTypeCategory < 4 && safePreferredAuto.category >= 4 {
            safePreferredAuto = .car
        }
        if maxAllowedTypeCategory < 3 && safePreferredAuto.category >= 3 {
            safePreferredAuto = preferredCycling
        }

        // 1. 优先使用传感器数据 (Core Motion)
        switch effectiveMotionType {
        case .walking:
            return kmh > 7 ? .running : .slow
        case .running:
            return .running
        case .cycling:
            if kmh > 55 { return safePreferredAuto } 
            return preferredCycling
        case .automotive:
            if kmh > 100 && maxAllowedTypeCategory >= 4 { return .train }
            if kmh > 80 && safePreferredAuto == .bus { return .car } 
            return safePreferredAuto
        default:
            break
        }
        
        // 2. 结合健康数据判定 (HealthKit)
        if hasStrongOnFootEvidence {
            if stepsPerMinute > 140 && kmh < 35 { return .running }
            if stepsPerMinute > 65 && kmh < 18 { return .slow }
            if walkingDistanceRatio > 0.7 && kmh < 15 { return .slow }
        }

        if stepCount > 100 && duration > 0 {
            if stepsPerMinute > 140 && kmh < 35 { return .running }
            if stepsPerMinute > 30 && kmh < 15 { return .slow }
        }
        
        // 3. 速度兜底 (传统逻辑)
        if kmh < 4.5 { 
            // 如果速度极低，但步数也很少（每分钟不到 5 步），说明大概率是在车里堵车，而不是真的在走
            if stepsPerMinute < 5 && stepCount < 20 && walkingDistance < 80 {
                return safePreferredAuto 
            }
            return .slow 
        }

        var effectiveKmh = kmh
        if maxAllowedTypeCategory < 4 && effectiveKmh >= 120.0 { effectiveKmh = 119.0 }
        if maxAllowedTypeCategory < 3 && effectiveKmh >= 25.0 { effectiveKmh = 24.0 }

        if effectiveKmh < 9 && hasStrongOnFootEvidence { return .slow }
        if effectiveKmh < 12 { return .bicycle }
        if effectiveKmh < 22 && hasStrongOnFootEvidence && walkingDistanceRatio > 0.45 { return preferredCycling }
        if effectiveKmh < 25 { return preferredCycling } 
        if effectiveKmh < 120 { return safePreferredAuto }
        if effectiveKmh < 350 { return .train }
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
    
    var category: Int {
        switch self {
        case .slow, .running: return 1
        case .bicycle, .ebike: return 2
        case .motorcycle, .bus, .car: return 3
        case .subway, .train, .airplane, .ship: return 4
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
