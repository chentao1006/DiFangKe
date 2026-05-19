import Foundation
import HealthKit
import CoreMotion
import Combine

class HealthManager: ObservableObject {
    static let shared = HealthManager()
    
    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    
    @Published var isAuthorized = false
    @Published var currentActivity: String = "未知"
    @Published var isMoving = false
    @Published var currentMotionType: MotionType = .stationary
    
    
    
    private init() {
    }
    
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        
        // Request Motion authorization implicitly by starting updates or checking availability
        // For HealthKit:
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .flightsClimbed)!
        ]
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            // Trigger a dummy activity update to prompt for motion permission if not already granted
            if CMMotionActivityManager.isActivityAvailable() {
                self.activityManager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in }
            }
            
            DispatchQueue.main.async {
                self.isAuthorized = success
                completion(success)
            }
        }
    }
    
    // MARK: - Core Motion (Real-time Context)
    
    func startActivityTracking() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        
        // 1. 运动状态监控 (提供基础分类)
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            
            if activity.walking {
                self.currentActivity = "步行"
                self.currentMotionType = .walking
            } else if activity.running {
                self.currentActivity = "跑步"
                self.currentMotionType = .running
            } else if activity.cycling {
                self.currentActivity = "骑行"
                self.currentMotionType = .cycling
            } else if activity.automotive {
                self.currentActivity = "车载"
                self.currentMotionType = .automotive
            } else if activity.stationary {
                self.currentActivity = "停留"
                self.currentMotionType = .stationary
            } else {
                self.currentActivity = "未知"
                self.currentMotionType = .unknown
            }
            
            self.isMoving = !activity.stationary && !activity.unknown
        }
        
        // 2. 计步器监控 (提供极速运动反馈)
        // 只要步数在增加，就强制标记为 isMoving，这对于解决刚出门时的“漏记”至关重要
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date().addingTimeInterval(-30)) { [weak self] data, error in // 从 30 秒前开始，避免重启时丢失步数状态
                guard let self = self, let data = data, error == nil else { return }
                if data.numberOfSteps.intValue > 0 {
                    DispatchQueue.main.async {
                        // 如果计步器有增加，且当前不是车载模式，则强制激活移动状态
                        if self.currentMotionType != .automotive {
                            self.isMoving = true
                            if self.currentMotionType == .stationary || self.currentMotionType == .unknown {
                                self.currentMotionType = .walking
                            }
                        }
                    }
                }
            }
        }
    }
    
    func stopActivityTracking() {
        activityManager.stopActivityUpdates()
        pedometer.stopUpdates()
    }
    
    // MARK: - Historical Data
    
    /// Queries historical motion activities for a given period and returns the most frequent one.
    func queryMostFrequentActivity(from start: Date, to end: Date) async -> MotionType {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unknown }
        
        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                guard let activities = activities, error == nil else {
                    continuation.resume(returning: .unknown)
                    return
                }
                
                var counts: [MotionType: TimeInterval] = [:]
                
                for i in 0..<activities.count {
                    let activity = activities[i]
                    let nextTime = (i + 1 < activities.count) ? activities[i+1].startDate : end
                    let duration = nextTime.timeIntervalSince(activity.startDate)
                    
                    let type: MotionType
                    if activity.automotive { type = .automotive }
                    else if activity.cycling { type = .cycling }
                    else if activity.running { type = .running }
                    else if activity.walking { type = .walking }
                    else if activity.stationary { type = .stationary }
                    else { type = .unknown }
                    
                    counts[type, default: 0] += duration
                }
                
                // Exclude unknown and stationary to find the active transport type
                let activeCounts = counts.filter { $0.key != .unknown && $0.key != .stationary }
                if let top = activeCounts.max(by: { $0.value < $1.value }) {
                    continuation.resume(returning: top.key)
                } else if let topStationary = counts.max(by: { $0.value < $1.value }) {
                    continuation.resume(returning: topStationary.key)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }
    
    func fetchMetrics(from start: Date, to end: Date) async -> (steps: Int, distance: Double, floors: Int) {
        guard HKHealthStore.isHealthDataAvailable() else { return (0, 0, 0) }
        
        let steps = await queryQuantity(type: .stepCount, from: start, to: end)
        let distance = await queryQuantity(type: .distanceWalkingRunning, from: start, to: end)
        let floors = await queryQuantity(type: .flightsClimbed, from: start, to: end)
        
        return (Int(steps), distance, Int(floors))
    }
    
    private func queryQuantity(type identifier: HKQuantityTypeIdentifier, from start: Date, to end: Date) async -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return 0 }
        
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
                let sumValue: Double
                if let sum = result?.sumQuantity() {
                    let unit: HKUnit
                    switch identifier {
                    case .stepCount, .flightsClimbed: unit = .count()
                    case .distanceWalkingRunning: unit = .meter()
                    default: unit = .count()
                    }
                    sumValue = sum.doubleValue(for: unit)
                } else {
                    sumValue = 0
                }
                continuation.resume(returning: sumValue)
            }
            healthStore.execute(query)
        }
    }
}
