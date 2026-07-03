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
        pointCount: Int = 0,
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

        let longPublicTransitType = inferLongPublicTransitType(
            kmh: kmh,
            distanceMeters: effectiveDistance,
            duration: duration,
            pointCount: pointCount
        )
        if let longPublicTransitType, !hasStrongOnFootEvidence {
            return longPublicTransitType
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

    private static func inferLongPublicTransitType(
        kmh: Double,
        distanceMeters: Double,
        duration: TimeInterval,
        pointCount: Int
    ) -> TransportType? {
        guard distanceMeters >= 10_000, duration >= 20 * 60 else { return nil }

        let segmentCount = max(pointCount - 1, 1)
        let metersPerSegment = distanceMeters / Double(segmentCount)
        let isSparseLongTrip = pointCount > 0 && (pointCount <= 4 || metersPerSegment >= 15_000)
        let isMixedPublicTransitPace = distanceMeters >= 15_000 && kmh >= 8 && kmh < 45

        if distanceMeters >= 600_000 && (isSparseLongTrip || kmh >= 180) {
            return .airplane
        }
        if distanceMeters >= 80_000 && (isSparseLongTrip || kmh >= 90) {
            return .train
        }
        if isSparseLongTrip && distanceMeters >= 30_000 {
            return .subway
        }
        if isMixedPublicTransitPace {
            return distanceMeters >= 20_000 ? .subway : .bus
        }
        return nil
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
    let pathPoints: [TransportPathPoint]
    var manualType: TransportType? = nil
    var stepCount: Int? = nil
    
    init(id: UUID = UUID(), startTime: Date, endTime: Date, startLocation: String, endLocation: String, type: TransportType, distance: Double, averageSpeed: Double, points: [CLLocationCoordinate2D], pathPoints: [TransportPathPoint]? = nil, manualType: TransportType? = nil, stepCount: Int? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startLocation = startLocation
        self.endLocation = endLocation
        self.type = type
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.points = points
        self.pathPoints = pathPoints ?? points.map { TransportPathPoint(coordinate: $0, timestamp: nil) }
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
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: location, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, pathPoints: pathPoints, manualType: manualType, stepCount: stepCount)
    }
    
    func updatingEnd(_ location: String) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: location, type: type, distance: distance, averageSpeed: averageSpeed, points: points, pathPoints: pathPoints, manualType: manualType, stepCount: stepCount)
    }
    
    func updatingType(_ newType: TransportType) -> Transport {
        Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, pathPoints: pathPoints, manualType: newType, stepCount: stepCount)
    }

    func updatingTimes(start: Date, end: Date) -> Transport {
        Transport(id: id, startTime: start, endTime: end, startLocation: startLocation, endLocation: endLocation, type: type, distance: distance, averageSpeed: averageSpeed, points: points, pathPoints: pathPoints, manualType: manualType, stepCount: stepCount)
    }

    func updatingPoints(_ newPoints: [CLLocationCoordinate2D], newPathPoints: [TransportPathPoint]? = nil) -> Transport {
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
        
        return Transport(id: id, startTime: startTime, endTime: endTime, startLocation: startLocation, endLocation: endLocation, type: type, distance: newDistance, averageSpeed: newSpeed, points: newPoints, pathPoints: newPathPoints ?? pathPoints, manualType: manualType, stepCount: stepCount)
    }
}

struct TransportPathPoint {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date?
    var isSyntheticPadding: Bool = false
}

struct TransportLineSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let isDashed: Bool
}

extension Transport {
    var lineSegments: [TransportLineSegment] {
        let validPoints = pathPoints.filter {
            $0.coordinate.latitude.isFinite &&
            $0.coordinate.longitude.isFinite &&
            CLLocationCoordinate2DIsValid($0.coordinate)
        }
        guard validPoints.count >= 2 else { return [] }

        var segments: [TransportLineSegment] = []
        var currentChunk: [CLLocationCoordinate2D] = [validPoints[0].coordinate]
        var isCurrentlyDashed: Bool? = nil

        for i in 0..<(validPoints.count - 1) {
            let current = validPoints[i]
            let next = validPoints[i + 1]
            let isDashed: Bool
            
            if current.isSyntheticPadding || next.isSyntheticPadding {
                isDashed = true
            } else if let currentTime = current.timestamp, let nextTime = next.timestamp {
                isDashed = abs(nextTime.timeIntervalSince(currentTime)) > 3 * 60
            } else {
                isDashed = false
            }

            if isCurrentlyDashed == nil {
                isCurrentlyDashed = isDashed
            }

            if isCurrentlyDashed == isDashed {
                currentChunk.append(next.coordinate)
            } else {
                segments.append(TransportLineSegment(
                    id: "\(id.uuidString)-\(segments.count)",
                    coordinates: currentChunk.smoothed(),
                    isDashed: isCurrentlyDashed!
                ))
                currentChunk = [current.coordinate, next.coordinate]
                isCurrentlyDashed = isDashed
            }
        }

        if let dashed = isCurrentlyDashed, currentChunk.count >= 2 {
            segments.append(TransportLineSegment(
                id: "\(id.uuidString)-\(segments.count)",
                coordinates: currentChunk.smoothed(),
                isDashed: dashed
            ))
        }

        // 优化虚线绘制：使用三次贝塞尔曲线使虚线顺着前后实线的切线方向自然延伸
        for i in 0..<segments.count {
            if segments[i].isDashed && segments[i].coordinates.count == 2 {
                let p0 = segments[i].coordinates[0]
                let p3 = segments[i].coordinates[1]
                
                var p0TangentPrev: CLLocationCoordinate2D? = nil
                if i > 0 && !segments[i-1].isDashed {
                    let prevSolid = segments[i-1].coordinates
                    if prevSolid.count >= 10 {
                        p0TangentPrev = prevSolid[prevSolid.count - 1 - Swift.min(prevSolid.count - 1, 10)]
                    } else if prevSolid.count >= 2 {
                        p0TangentPrev = prevSolid.first!
                    }
                }
                
                var p3TangentNext: CLLocationCoordinate2D? = nil
                if i < segments.count - 1 && !segments[i+1].isDashed {
                    let nextSolid = segments[i+1].coordinates
                    if nextSolid.count >= 10 {
                        p3TangentNext = nextSolid[Swift.min(nextSolid.count - 1, 10)]
                    } else if nextSolid.count >= 2 {
                        p3TangentNext = nextSolid.last!
                    }
                }
                
                let dLat0 = p0TangentPrev != nil ? p0.latitude - p0TangentPrev!.latitude : 0
                let dLon0 = p0TangentPrev != nil ? p0.longitude - p0TangentPrev!.longitude : 0
                let dLat3 = p3TangentNext != nil ? p3TangentNext!.latitude - p3.latitude : 0
                let dLon3 = p3TangentNext != nil ? p3TangentNext!.longitude - p3.longitude : 0
                
                let distLat = p3.latitude - p0.latitude
                let distLon = p3.longitude - p0.longitude
                let dist = sqrt(distLat*distLat + distLon*distLon)
                
                let len0 = sqrt(dLat0*dLat0 + dLon0*dLon0)
                let len3 = sqrt(dLat3*dLat3 + dLon3*dLon3)
                
                // 限制最大控制点距离，避免长距离虚线弯曲或打结太夸张 (0.005 约等于 500 米，大于 2 公里时限制弯曲)
                let maxTangent = 0.005
                let tLen0 = Swift.min(dist * 0.35, maxTangent)
                let tLen3 = Swift.min(dist * 0.35, maxTangent)
                let tLenFallback = Swift.min(dist * 0.3, maxTangent)
                
                let scale0 = len0 > 0 ? tLen0 / len0 : 0
                let scale3 = len3 > 0 ? tLen3 / len3 : 0
                let fallbackScale = dist > 0 ? tLenFallback / dist : 0
                
                let c1 = CLLocationCoordinate2D(
                    latitude: p0.latitude + (len0 > 0 ? dLat0 * scale0 : distLat * fallbackScale),
                    longitude: p0.longitude + (len0 > 0 ? dLon0 * scale0 : distLon * fallbackScale)
                )
                let c2 = CLLocationCoordinate2D(
                    latitude: p3.latitude - (len3 > 0 ? dLat3 * scale3 : distLat * fallbackScale),
                    longitude: p3.longitude - (len3 > 0 ? dLon3 * scale3 : distLon * fallbackScale)
                )
                
                var bezierPoints: [CLLocationCoordinate2D] = []
                let steps = 20
                for j in 0...steps {
                    let t = Double(j) / Double(steps)
                    let u = 1.0 - t
                    let u2 = u * u
                    let u3 = u2 * u
                    let t2 = t * t
                    let t3 = t2 * t
                    
                    let lat = u3 * p0.latitude + 3.0 * u2 * t * c1.latitude + 3.0 * u * t2 * c2.latitude + t3 * p3.latitude
                    let lon = u3 * p0.longitude + 3.0 * u2 * t * c1.longitude + 3.0 * u * t2 * c2.longitude + t3 * p3.longitude
                    bezierPoints.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
                
                segments[i] = TransportLineSegment(id: segments[i].id, coordinates: bezierPoints, isDashed: true)
            }
        }

        return segments
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// 使用 Catmull-Rom 插值算法结合滑动平均滤波，不严格贴合原始坐标，画出抗漂移的优雅曲线
    func smoothed(granularity: Int = 10) -> [CLLocationCoordinate2D] {
        guard count >= 3 else { return self }
        
        var result: [CLLocationCoordinate2D] = []
        
        // 1. 预处理：过滤掉过近的点，避免局部坐标堆叠导致的插值乱缠
        var filtered: [CLLocationCoordinate2D] = [self[0]]
        for i in 1..<count {
            let p1 = filtered.last!
            let p2 = self[i]
            let dist = sqrt(pow(p2.latitude - p1.latitude, 2) + pow(p2.longitude - p1.longitude, 2))
            if dist > 0.00004 { // 约 4-5 米，剔除小范围原地漂移
                filtered.append(p2)
            }
        }
        
        // 确保最后一个点被包含
        if let last = self.last {
            let p1 = filtered.last!
            let dist = sqrt(pow(last.latitude - p1.latitude, 2) + pow(last.longitude - p1.longitude, 2))
            if dist > 0 {
                filtered.append(last)
            }
        }
        
        guard filtered.count >= 3 else { return self }

        // 2. 核心：移动平均滤波（滑动窗口）。
        // 这一步打破了“严格通过原始坐标”的限制，把左右横跳的漂移点强制往中心路径拉扯。
        var averaged: [CLLocationCoordinate2D] = []
        let windowSize = 5
        let halfWindow = windowSize / 2
        
        for i in 0..<filtered.count {
            if i == 0 || i == filtered.count - 1 {
                // 首尾两端不漂移，作为锚点固定
                averaged.append(filtered[i])
                continue
            }
            var sumLat = 0.0
            var sumLng = 0.0
            var validCount = 0.0
            
            let start = Swift.max(0, i - halfWindow)
            let end = Swift.min(filtered.count - 1, i + halfWindow)
            
            for j in start...end {
                sumLat += filtered[j].latitude
                sumLng += filtered[j].longitude
                validCount += 1
            }
            averaged.append(CLLocationCoordinate2D(latitude: sumLat / validCount, longitude: sumLng / validCount))
        }

        // 3. Catmull-Rom 样条插值：让已经被拉直的路线呈现出优雅的曲线感
        for i in 0..<averaged.count - 1 {
            let p0 = averaged[Swift.max(i - 1, 0)]
            let p1 = averaged[i]
            let p2 = averaged[i + 1]
            let p3 = averaged[Swift.min(i + 2, averaged.count - 1)]
            
            for t in 0..<granularity {
                let s = Double(t) / Double(granularity)
                let lat = catmullRom(p0.latitude, p1.latitude, p2.latitude, p3.latitude, t: s)
                let lon = catmullRom(p0.longitude, p1.longitude, p2.longitude, p3.longitude, t: s)
                result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        result.append(averaged.last!)
        return result
    }
    
    private func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
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
