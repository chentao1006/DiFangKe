import Foundation

class AppConfig {
    static let shared = AppConfig()
    
    private var config: [String: Any] = [:]
    
    private init() {
        loadConfig()
    }
    
    private func loadConfig() {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            print("⚠️ AppConfig: Failed to load Config.plist")
            return
        }
        self.config = dict
    }
    
    func string(forKey key: String) -> String {
        return config[key] as? String ?? ""
    }
    
    func double(forKey key: String) -> Double {
        if let val = config[key] as? Double {
            return val
        }
        if let val = config[key] as? Float {
            return Double(val)
        }
        return 0.0
    }
    
    func int(forKey key: String) -> Int {
        return config[key] as? Int ?? 0
    }
    
    func uint64(forKey key: String) -> UInt64 {
        if let val = config[key] as? NSNumber {
            return val.uint64Value
        }
        return 0
    }
    
    // --- 算法专用便捷访问属性 ---
    
    var stayDistanceThreshold: Double {
        double(forKey: "STAY_DISTANCE_THRESHOLD")
    }
    
    var mergeDistanceThreshold: Double {
        double(forKey: "MERGE_DISTANCE_THRESHOLD")
    }
    
    var stayMergeGapThreshold: Double {
        double(forKey: "STAY_MERGE_GAP_THRESHOLD")
    }
    
    var stayDurationThreshold: Double {
        double(forKey: "STAY_DURATION_THRESHOLD")
    }
    
    var transportMinDistanceThreshold: Double {
        double(forKey: "TRANSPORT_MIN_DISTANCE_THRESHOLD")
    }
    
    var transportMinDurationThreshold: Double {
        double(forKey: "TRANSPORT_MIN_DURATION_THRESHOLD")
    }
    
    var gapFillingThreshold: Double {
        double(forKey: "GAP_FILLING_THRESHOLD")
    }
    
    var serviceSecret: String {
        string(forKey: "SERVICE_SECRET")
    }
    
    var publicServiceUrl: String {
        string(forKey: "PUBLIC_SERVICE_URL")
    }
    
    var habitTimeWindow: Int {
        int(forKey: "HABIT_TIME_WINDOW_MINUTES")
    }
    
    var habitFrequencyThreshold: Int {
        int(forKey: "HABIT_FREQUENCY_THRESHOLD")
    }
    
    // --- Live tracking specific parameters ---
    var liveStayMergeTimeThreshold: Double {
        double(forKey: "LIVE_STAY_MERGE_TIME_THRESHOLD")
    }
    
    var liveStayMergeDistanceThreshold: Double {
        double(forKey: "LIVE_STAY_MERGE_DISTANCE_THRESHOLD")
    }
    
    var liveStayMinDurationThreshold: Double {
        double(forKey: "LIVE_STAY_MIN_DURATION_THRESHOLD")
    }

    var transportAlignmentThreshold: Double {
        double(forKey: "TRANSPORT_ALIGNMENT_THRESHOLD")
    }

    // --- 更多算法微调参数 ---
    var minStayDurationCorrection: Double {
        double(forKey: "MIN_STAY_DURATION_CORRECTION")
    }
    
    var tinyStayThreshold: Double {
        double(forKey: "TINY_STAY_THRESHOLD")
    }
    
    var ongoingStayGracePeriod: Double {
        double(forKey: "ONGOING_STAY_GRACE_PERIOD")
    }
    
    var snapTimeBuffer: Double {
        double(forKey: "SNAP_TIME_BUFFER")
    }
    
    var duplicatePointBuffer: Double {
        double(forKey: "DUPLICATE_POINT_BUFFER")
    }
    
    var midPointSamplingOffset: Double {
        double(forKey: "MID_POINT_SAMPLING_OFFSET")
    }
    
    var habitAnalysisLookbackDays: Int {
        int(forKey: "HABIT_ANALYSIS_LOOKBACK_DAYS")
    }

    var ridiculousAccuracyThreshold: Double {
        double(forKey: "RIDICULOUS_ACCURACY_THRESHOLD")
    }

    var ridiculousDistanceThreshold: Double {
        double(forKey: "RIDICULOUS_DISTANCE_THRESHOLD")
    }

    var ridiculousSpeedThreshold: Double {
        double(forKey: "RIDICULOUS_SPEED_THRESHOLD")
    }

    var locationLookbackHours: Double {
        double(forKey: "LOCATION_LOOKBACK_HOURS")
    }

    var locationLookbackMaxHours: Double {
        double(forKey: "LOCATION_LOOKBACK_MAX_HOURS")
    }

    var driftSpeedThreshold: Double {
        double(forKey: "DRIFT_SPEED_THRESHOLD")
    }

    var driftSpeedMaxPossible: Double {
        double(forKey: "DRIFT_SPEED_MAX_POSSIBLE")
    }

    var driftAccuracyThreshold: Double {
        double(forKey: "DRIFT_ACCURACY_THRESHOLD")
    }

    var driftDistanceGap: Double {
        double(forKey: "DRIFT_DISTANCE_GAP")
    }

    var cloudSyncLookbackDays: Int {
        int(forKey: "CLOUD_SYNC_LOOKBACK_DAYS")
    }
    
    var tagInheritanceDistance: Double {
        double(forKey: "TAG_INHERITANCE_DISTANCE")
    }

    var timelineOverlapTimeTolerance: Double {
        double(forKey: "TIMELINE_OVERLAP_TIME_TOLERANCE")
    }
    
    var timelineOverlapDistanceTolerance: Double {
        double(forKey: "TIMELINE_OVERLAP_DISTANCE_TOLERANCE")
    }

    var uiDebounceIntervalNS: UInt64 {
        uint64(forKey: "UI_DEBOUNCE_INTERVAL_NS")
    }

    var gapFillingMaxDistance: Double {
        double(forKey: "GAP_FILLING_MAX_DISTANCE")
    }
    
    var habitAnalysisAccuracyThreshold: Double {
        double(forKey: "HABIT_ANALYSIS_ACCURACY_THRESHOLD")
    }
    
    var samePlaceMergeBonusThreshold: Double {
        double(forKey: "SAME_PLACE_MERGE_BONUS_THRESHOLD")
    }
    
    var physicalMaxSpeedThreshold: Double {
        let val = double(forKey: "PHYSICAL_MAX_SPEED_THRESHOLD")
        return val > 0 ? val : 600.0 // Default to user's example 600 m/s (3km/5s)
    }

    var stationaryDiameterThreshold: Double {
        double(forKey: "STATIONARY_DIAMETER_THRESHOLD")
    }

    var stayExitDistanceThreshold: Double {
        double(forKey: "STAY_EXIT_DISTANCE_THRESHOLD")
    }

    var stationaryDetectionMaxDiameter: Double {
        double(forKey: "STATIONARY_DETECTION_MAX_DIAMETER")
    }

    var stationaryDetectionDurationThreshold: Double {
        double(forKey: "STATIONARY_DETECTION_DURATION_THRESHOLD")
    }

    var transportFinalizeMinDistance: Double {
        double(forKey: "TRANSPORT_FINALIZE_MIN_DISTANCE")
    }

    var speedThresholdStationary: Double {
        double(forKey: "SPEED_THRESHOLD_STATIONARY")
    }

    var transportGapBreakThreshold: Double {
        double(forKey: "TRANSPORT_GAP_BREAK_THRESHOLD")
    }

    var driftRatioThreshold: Double {
        double(forKey: "DRIFT_RATIO_THRESHOLD")
    }

    var transportDetectionSegmentDuration: Double {
        double(forKey: "TRANSPORT_DETECTION_SEGMENT_DURATION")
    }

    var transportTypeChangeDurationThreshold: Double {
        double(forKey: "TRANSPORT_TYPE_CHANGE_DURATION_THRESHOLD")
    }
}
