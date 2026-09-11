import Foundation

class AppConfig {
    static let shared = AppConfig()
    
    private var config: [String: Any] = [:]
    
    private init() {
        loadConfig()
    }
    
    private func loadConfig() {
        var mergedConfig: [String: Any] = [:]
        
        // 1. 优先加载 Config.plist (公开配置)
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
            mergedConfig.merge(dict) { (_, new) in new }
        } else {
            print("⚠️ AppConfig: Failed to load Config.plist")
        }
        
        // 2. 然后加载 Secrets.plist 并覆盖配置 (私密配置，本地开发用)
        if let secretPath = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let secretDict = NSDictionary(contentsOfFile: secretPath) as? [String: Any] {
            mergedConfig.merge(secretDict) { (_, new) in new }
        } else {
            print("⚠️ AppConfig: Secrets.plist not found, using Config.plist only")
        }
        
        self.config = mergedConfig
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
    
    var samePlaceMergeGapThreshold: Double {
        double(forKey: "SAME_PLACE_MERGE_GAP_THRESHOLD")
    }

    var physicalMaxSpeedThreshold: Double {
        double(forKey: "PHYSICAL_MAX_SPEED_THRESHOLD")
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
    
    var photoLinkingMaxDistance: Double {
        double(forKey: "PHOTO_LINKING_MAX_DISTANCE")
    }
    
    var appGroupID: String {
        string(forKey: "APP_GROUP_ID")
    }

    var aptabaseAppKey: String {
        string(forKey: "APTABASE_APP_KEY")
    }

    var pedometerMinMovingStepDelta: Int {
        int(forKey: "PEDOMETER_MIN_MOVING_STEP_DELTA")
    }

    var pedometerStartupLookback: Double {
        double(forKey: "PEDOMETER_STARTUP_LOOKBACK")
    }

    // MARK: - LocationManager tuning

    var maxGPSAccuracyFilter: Double {
        double(forKey: "MAX_GPS_ACCURACY_FILTER")
    }

    var departureBoostDuration: Double {
        double(forKey: "DEPARTURE_BOOST_DURATION")
    }

    var footprintMinSampleInterval: Double {
        double(forKey: "FOOTPRINT_MIN_SAMPLE_INTERVAL")
    }

    var reportedHighSpeedThreshold: Double {
        double(forKey: "REPORTED_HIGH_SPEED_THRESHOLD")
    }

    var driftAccuracyDegradationRatio: Double {
        double(forKey: "DRIFT_ACCURACY_DEGRADATION_RATIO")
    }

    var driftAccuracyAbsoluteFloor: Double {
        double(forKey: "DRIFT_ACCURACY_ABSOLUTE_FLOOR")
    }

    var stationaryDwellDuration: Double {
        double(forKey: "STATIONARY_DWELL_DURATION")
    }

    var stationaryDwellDistance: Double {
        double(forKey: "STATIONARY_DWELL_DISTANCE")
    }

    var stationaryDwellSpeed: Double {
        double(forKey: "STATIONARY_DWELL_SPEED")
    }

    var lowPowerDwellDuration: Double {
        double(forKey: "LOW_POWER_DWELL_DURATION")
    }

    var lowPowerDwellDistance: Double {
        double(forKey: "LOW_POWER_DWELL_DISTANCE")
    }

    var geocodeHighSpeedThreshold: Double {
        double(forKey: "GEOCODE_HIGH_SPEED_THRESHOLD")
    }

    var geocodeThrottleDistanceHighSpeed: Double {
        double(forKey: "GEOCODE_THROTTLE_DISTANCE_HIGH_SPEED")
    }

    var geocodeThrottleDistanceNormal: Double {
        double(forKey: "GEOCODE_THROTTLE_DISTANCE_NORMAL")
    }

    var regionReuseDistanceThreshold: Double {
        double(forKey: "REGION_REUSE_DISTANCE_THRESHOLD")
    }

    var stationaryWakeupRegionRadius: Double {
        double(forKey: "STATIONARY_WAKEUP_REGION_RADIUS")
    }

    var departureHighSpeedDistance: Double {
        double(forKey: "DEPARTURE_HIGH_SPEED_DISTANCE")
    }

    var departureAccuracyThreshold: Double {
        double(forKey: "DEPARTURE_ACCURACY_THRESHOLD")
    }

    var departureDistanceThreshold: Double {
        double(forKey: "DEPARTURE_DISTANCE_THRESHOLD")
    }

    var departureLongStayDuration: Double {
        double(forKey: "DEPARTURE_LONG_STAY_DURATION")
    }

    var departureDriftResistantFloor: Double {
        double(forKey: "DEPARTURE_DRIFT_RESISTANT_FLOOR")
    }

    var departureDriftResistantRatio: Double {
        double(forKey: "DEPARTURE_DRIFT_RESISTANT_RATIO")
    }

    var movingRecoveryGapThreshold: Double {
        double(forKey: "MOVING_RECOVERY_GAP_THRESHOLD")
    }

    var recoveryBoostThrottleInterval: Double {
        double(forKey: "RECOVERY_BOOST_THROTTLE_INTERVAL")
    }

    var stationaryProbeMinDuration: Double {
        double(forKey: "STATIONARY_PROBE_MIN_DURATION")
    }

    var stationaryProbeInterval: Double {
        double(forKey: "STATIONARY_PROBE_INTERVAL")
    }

    var timelineSiftDebounceInterval: Double {
        double(forKey: "TIMELINE_SIFT_DEBOUNCE_INTERVAL")
    }

    var liveMergeTaskDelay: Double {
        double(forKey: "LIVE_MERGE_TASK_DELAY")
    }

    var startTrackingDebounceInterval: Double {
        double(forKey: "START_TRACKING_DEBOUNCE_INTERVAL")
    }

    var mergeRecentFootprintsLookback: Double {
        double(forKey: "MERGE_RECENT_FOOTPRINTS_LOOKBACK")
    }

    var splitClusterRadiusCap: Double {
        double(forKey: "SPLIT_CLUSTER_RADIUS_CAP")
    }

    var splitClusterRadiusRatio: Double {
        double(forKey: "SPLIT_CLUSTER_RADIUS_RATIO")
    }

    var splitClusterMinPoints: Int {
        int(forKey: "SPLIT_CLUSTER_MIN_POINTS")
    }

    var ongoingAIAnalysisInterval: Double {
        double(forKey: "ONGOING_AI_ANALYSIS_INTERVAL")
    }

    var activityExtensionAccuracyThreshold: Double {
        double(forKey: "ACTIVITY_EXTENSION_ACCURACY_THRESHOLD")
    }

    var placeMatchDistanceThreshold: Double {
        double(forKey: "PLACE_MATCH_DISTANCE_THRESHOLD")
    }

    var longTimeNoSeeDays: Int {
        int(forKey: "LONG_TIME_NO_SEE_DAYS")
    }

    var newPlaceMinDuration: Double {
        double(forKey: "NEW_PLACE_MIN_DURATION")
    }

    var longTimeNoSeeMinDuration: Double {
        double(forKey: "LONG_TIME_NO_SEE_MIN_DURATION")
    }

    var pastMemoriesCheckHour: Int {
        int(forKey: "PAST_MEMORIES_CHECK_HOUR")
    }

    // MARK: - TimelineBuilder tuning

    var stationaryDetectionMinPoints: Int {
        int(forKey: "STATIONARY_DETECTION_MIN_POINTS")
    }

    var stationaryDetectionSamplingInterval: Int {
        int(forKey: "STATIONARY_DETECTION_SAMPLING_INTERVAL")
    }

    var stationaryDetectionWindowSize: Int {
        int(forKey: "STATIONARY_DETECTION_WINDOW_SIZE")
    }

    var transportTypeDetectionMinPoints: Int {
        int(forKey: "TRANSPORT_TYPE_DETECTION_MIN_POINTS")
    }

    var transportTypeDetectionSamplingInterval: Int {
        int(forKey: "TRANSPORT_TYPE_DETECTION_SAMPLING_INTERVAL")
    }

    var transportTypeWindowSize: Int {
        int(forKey: "TRANSPORT_TYPE_WINDOW_SIZE")
    }

    var transportTypeWindowMinPoints: Int {
        int(forKey: "TRANSPORT_TYPE_WINDOW_MIN_POINTS")
    }

    var transportFinalizeMinPoints: Int {
        int(forKey: "TRANSPORT_FINALIZE_MIN_POINTS")
    }

    var gapMinDurationThreshold: Double {
        double(forKey: "GAP_MIN_DURATION_THRESHOLD")
    }

    var transportMaxReasonableSpeed: Double {
        double(forKey: "TRANSPORT_MAX_REASONABLE_SPEED")
    }

    var routeSimplifyTier1Duration: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER1_DURATION")
    }

    var routeSimplifyTier1Tolerance: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER1_TOLERANCE")
    }

    var routeSimplifyTier2Duration: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER2_DURATION")
    }

    var routeSimplifyTier2Tolerance: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER2_TOLERANCE")
    }

    var routeSimplifyTier3Duration: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER3_DURATION")
    }

    var routeSimplifyTier3Tolerance: Double {
        double(forKey: "ROUTE_SIMPLIFY_TIER3_TOLERANCE")
    }

    var routeSimplifyDefaultTolerance: Double {
        double(forKey: "ROUTE_SIMPLIFY_DEFAULT_TOLERANCE")
    }

    var gapFillReconnectDistance: Double {
        double(forKey: "GAP_FILL_RECONNECT_DISTANCE")
    }

    var pathLoopDisplacementThreshold: Double {
        double(forKey: "PATH_LOOP_DISPLACEMENT_THRESHOLD")
    }

    var pathLoopRatioThreshold: Double {
        double(forKey: "PATH_LOOP_RATIO_THRESHOLD")
    }

    var pathLoopDistanceThreshold: Double {
        double(forKey: "PATH_LOOP_DISTANCE_THRESHOLD")
    }

    var transportShortHighSpeedDuration: Double {
        double(forKey: "TRANSPORT_SHORT_HIGH_SPEED_DURATION")
    }

    var transportShortHighSpeedSpeed: Double {
        double(forKey: "TRANSPORT_SHORT_HIGH_SPEED_SPEED")
    }

    var transportMergeTimeGap: Double {
        double(forKey: "TRANSPORT_MERGE_TIME_GAP")
    }

    var transportMergeDistance: Double {
        double(forKey: "TRANSPORT_MERGE_DISTANCE")
    }

    var habitDecayHalfLifeDays: Double {
        double(forKey: "HABIT_DECAY_HALF_LIFE_DAYS")
    }

    var walkingSanityMinDistance: Double {
        double(forKey: "WALKING_SANITY_MIN_DISTANCE")
    }

    var walkingImpossibleSpeed: Double {
        double(forKey: "WALKING_IMPOSSIBLE_SPEED")
    }

    var walkingMinStepsPerMinute: Double {
        double(forKey: "WALKING_MIN_STEPS_PER_MINUTE")
    }

    var walkingMinStepCount: Int {
        int(forKey: "WALKING_MIN_STEP_COUNT")
    }

    var walkingSuspiciousSpeed: Double {
        double(forKey: "WALKING_SUSPICIOUS_SPEED")
    }

    var reconstructionBoundaryTolerance: Double {
        double(forKey: "RECONSTRUCTION_BOUNDARY_TOLERANCE")
    }

    var overlapMinDuration: Double {
        double(forKey: "OVERLAP_MIN_DURATION")
    }

    var overlapMinRatio: Double {
        double(forKey: "OVERLAP_MIN_RATIO")
    }

    var gapSliverThreshold: Double {
        double(forKey: "GAP_SLIVER_THRESHOLD")
    }

    var fullDayCoverageGapThreshold: Double {
        double(forKey: "FULL_DAY_COVERAGE_GAP_THRESHOLD")
    }

    var transportAdjacencyTolerance: Double {
        double(forKey: "TRANSPORT_ADJACENCY_TOLERANCE")
    }

    var transportMergeGapTolerance: Double {
        double(forKey: "TRANSPORT_MERGE_GAP_TOLERANCE")
    }

    var shortGapThreshold: Double {
        double(forKey: "SHORT_GAP_THRESHOLD")
    }

    var minKeptSegmentDuration: Double {
        double(forKey: "MIN_KEPT_SEGMENT_DURATION")
    }

    var transportOverlapRatioThreshold: Double {
        double(forKey: "TRANSPORT_OVERLAP_RATIO_THRESHOLD")
    }

    var transportMatchTimeTolerance: Double {
        double(forKey: "TRANSPORT_MATCH_TIME_TOLERANCE")
    }

    var roundTripIntervalGap: Double {
        double(forKey: "ROUND_TRIP_INTERVAL_GAP")
    }

    var roundTripMinLegLength: Double {
        double(forKey: "ROUND_TRIP_MIN_LEG_LENGTH")
    }

    var roundTripEndpointTolerance: Double {
        double(forKey: "ROUND_TRIP_ENDPOINT_TOLERANCE")
    }

    var routeCoverageMinRatio: Double {
        double(forKey: "ROUTE_COVERAGE_MIN_RATIO")
    }

    var routeCoverageHighRatio: Double {
        double(forKey: "ROUTE_COVERAGE_HIGH_RATIO")
    }

    var tailClusterMinPoints: Int {
        int(forKey: "TAIL_CLUSTER_MIN_POINTS")
    }

    var maxTailDuration: Double {
        double(forKey: "MAX_TAIL_DURATION")
    }

    // MARK: - Other services tuning

    var cloudPeriodicSyncInterval: Double {
        double(forKey: "CLOUD_PERIODIC_SYNC_INTERVAL")
    }

    var widgetInferredRouteDistanceThreshold: Double {
        double(forKey: "WIDGET_INFERRED_ROUTE_DISTANCE_THRESHOLD")
    }

    var widgetTodaySyncMinInterval: Double {
        double(forKey: "WIDGET_TODAY_SYNC_MIN_INTERVAL")
    }

    var widgetHistorySyncMinInterval: Double {
        double(forKey: "WIDGET_HISTORY_SYNC_MIN_INTERVAL")
    }

    var dedupSameNameDistanceThreshold: Double {
        double(forKey: "DEDUP_SAME_NAME_DISTANCE_THRESHOLD")
    }

    var dedupTransportTimeTolerance: Double {
        double(forKey: "DEDUP_TRANSPORT_TIME_TOLERANCE")
    }
}
