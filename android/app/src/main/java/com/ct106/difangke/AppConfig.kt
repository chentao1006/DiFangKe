package com.ct106.difangke

/** 对应 iOS 的 Config.plist + AppConfig.swift 所有算法阈值与服务配置集中在此处 */
object AppConfig {

    // ── AI 服务配置 ──────────────────────────────────────────────
    val SERVICE_SECRET = BuildConfig.SERVICE_SECRET
    val PUBLIC_SERVICE_URL = BuildConfig.PUBLIC_SERVICE_URL

    // --- AI 频率限制 ---
    const val AI_LIMIT_PER_MINUTE = 1
    const val AI_LIMIT_PER_HOUR = 30
    const val AI_LIMIT_PER_DAY = 100

    // ── 统计分析 ──────────────────────────────────────────────────
    val APTABASE_APP_KEY = BuildConfig.APTABASE_APP_KEY

    // ── 停留识别参数 ──────────────────────────────────────────────
    /** 停留识别的距离阈值（米）：超过此距离视为离开 */
    const val STAY_DISTANCE_THRESHOLD = 100.0

    /** 两个足迹合并的最大直线距离门槛（米） */
    const val MERGE_DISTANCE_THRESHOLD = 150.0

    /** 两个足迹合并的最大时间间隔（秒） */
    const val STAY_MERGE_GAP_THRESHOLD = 1800.0

    /** 停留识别的最短时间（秒） */
    const val STAY_DURATION_THRESHOLD = 300.0

    /** 交通段最低位移（米） */
    const val TRANSPORT_MIN_DISTANCE_THRESHOLD = 300.0

    /** 交通段最低时长（秒） */
    const val TRANSPORT_MIN_DURATION_THRESHOLD = 300.0

    /** 缺口自动填充阈值（秒） */
    const val GAP_FILLING_THRESHOLD = 300.0

    /** 习惯分析时间窗口（分钟） */
    const val HABIT_TIME_WINDOW_MINUTES = 120

    /** 判定为"习惯地点"所需的历史重复次数 */
    const val HABIT_FREQUENCY_THRESHOLD = 3

    // ── 定位参数 ──────────────────────────────────────────────────
    /** 精度过滤阈值（米），超过此精度的点丢弃 */
    const val MAX_LOCATION_ACCURACY = 300.0

    /** 漂移速度阈值（m/s） */
    const val DRIFT_SPEED_THRESHOLD = 45.0

    /** 漂移精度门槛 */
    const val DRIFT_ACCURACY_THRESHOLD = 65.0

    /** 停留中心判断的 85 百分位阈值 */
    const val STAY_PERCENTILE = 0.85

    // ── 更新配置 ──────────────────────────────────────────────────
    const val UPDATE_CHECK_URL = "https://difang.app/download/update_android.json"
    const val UPDATE_APK_URL = "https://difang.app/download/difangke.apk"

    // ── 通知配置 ──────────────────────────────────────────────────
    const val DEFAULT_NOTIFICATION_HOUR = 21
    const val DEFAULT_NOTIFICATION_MINUTE = 0

    // ── Live tracking specific parameters ──────────────────────────
    const val LIVE_STAY_MERGE_TIME_THRESHOLD = 1200.0 // 20 min
    const val LIVE_STAY_MERGE_DISTANCE_THRESHOLD = 100.0 // 100 m
    const val LIVE_STAY_MIN_DURATION_THRESHOLD = 300.0 // 5 min (iOS parity)

    // ── 交通对齐阈值 ──────────────────────────────────────────────
    /** 交通对齐阈值（秒）：20分钟 */
    const val TRANSPORT_ALIGNMENT_THRESHOLD = 1200.0

    // ── 更多算法微调参数 ──────────────────────────────────────────
    const val MIN_STAY_DURATION_CORRECTION = 60.0
    const val TINY_STAY_THRESHOLD = 5.0
    const val ONGOING_STAY_GRACE_PERIOD = 120.0
    const val SNAP_TIME_BUFFER = 60.0
    const val DUPLICATE_POINT_BUFFER = 1.0
    const val MID_POINT_SAMPLING_OFFSET = 10.0
    const val HABIT_ANALYSIS_LOOKBACK_DAYS = 7

    const val RIDICULOUS_ACCURACY_THRESHOLD = 500.0
    const val RIDICULOUS_DISTANCE_THRESHOLD = 2000.0
    const val RIDICULOUS_SPEED_THRESHOLD = 100.0

    const val LOCATION_LOOKBACK_HOURS = 2.0
    const val LOCATION_LOOKBACK_MAX_HOURS = 24.0

    const val DRIFT_SPEED_MAX_POSSIBLE = 60.0
    const val DRIFT_DISTANCE_GAP = 300.0

    const val CLOUD_SYNC_LOOKBACK_DAYS = 7
    const val TAG_INHERITANCE_DISTANCE = 150.0

    const val TIMELINE_OVERLAP_TIME_TOLERANCE = 60.0
    const val TIMELINE_OVERLAP_DISTANCE_TOLERANCE = 200.0

    const val UI_DEBOUNCE_INTERVAL_MS = 400L

    const val GAP_FILLING_MAX_DISTANCE = 300.0
    const val HABIT_ANALYSIS_ACCURACY_THRESHOLD = 300.0
    const val SAME_PLACE_MERGE_BONUS_THRESHOLD = 500.0

    /** 合成交通记录的最大时长（秒）：防止因长时间数据缺失导致交通从半夜开始算（回溯过长） */
    const val MAX_SYNTHESIZED_TRANSPORT_DURATION = 3600.0
    const val TRANSPORT_MAX_GAP_THRESHOLD = 1800.0

    /** 物理不可能的最大速度阈值（m/s）：600 m/s ≈ 2160 km/h */
    const val PHYSICAL_MAX_SPEED_THRESHOLD = 600.0

    // ── iOS Config.plist parity (auto-ported; keep values identical to iOS) ──
    const val ACTIVITY_EXTENSION_ACCURACY_THRESHOLD = 100.0
    const val AUTOMATIC_STATIONARY_WATCH_ACCURACY = 25.0
    const val AUTOMATIC_STATIONARY_WATCH_DISTANCE_FILTER = 5.0
    const val CLOUD_PERIODIC_SYNC_INTERVAL = 600.0
    const val DEDUP_SAME_NAME_DISTANCE_THRESHOLD = 50.0
    const val DEDUP_TRANSPORT_TIME_TOLERANCE = 300.0
    const val DEPARTURE_ACCURACY_THRESHOLD = 100.0
    const val DEPARTURE_BOOST_DURATION = 600.0
    const val DEPARTURE_DISTANCE_THRESHOLD = 150.0
    const val DEPARTURE_DRIFT_RESISTANT_FLOOR = 300.0
    const val DEPARTURE_DRIFT_RESISTANT_RATIO = 3.0
    const val DEPARTURE_HIGH_SPEED_DISTANCE = 500.0
    const val DEPARTURE_LONG_STAY_DURATION = 1800.0
    const val DORMANT_STAY_CLUSTER_RADIUS = 50.0
    const val DORMANT_STAY_MAX_ACCURACY = 100.0
    const val DORMANT_STAY_MAX_GAP_DURATION = 3600.0
    const val DORMANT_STAY_MAX_OUTLIERS = 2
    const val DORMANT_STAY_MIN_OBSERVED_DURATION = 90.0
    const val DRIFT_ACCURACY_ABSOLUTE_FLOOR = 150.0
    const val DRIFT_ACCURACY_DEGRADATION_RATIO = 3.0
    const val DRIFT_RATIO_THRESHOLD = 2.5
    const val FOOTPRINT_MIN_SAMPLE_INTERVAL = 5.0
    const val FULL_DAY_COVERAGE_GAP_THRESHOLD = 82800.0
    const val GAP_FILL_RECONNECT_DISTANCE = 150.0
    const val GAP_MIN_DURATION_THRESHOLD = 60.0
    const val GAP_SLIVER_THRESHOLD = 600.0
    const val GEOCODE_HIGH_SPEED_THRESHOLD = 10.0
    const val GEOCODE_THROTTLE_DISTANCE_HIGH_SPEED = 1000.0
    const val GEOCODE_THROTTLE_DISTANCE_NORMAL = 100.0
    const val HABIT_DECAY_HALF_LIFE_DAYS = 14.0
    const val LIVE_MERGE_TASK_DELAY = 3.0
    const val LONG_TIME_NO_SEE_DAYS = 180
    const val LONG_TIME_NO_SEE_MIN_DURATION = 600.0
    const val LOW_POWER_CLUSTER_FRACTION = 0.8
    const val LOW_POWER_DEPARTURE_ACCURACY = 60.0
    const val LOW_POWER_DEPARTURE_ACCURACY_RATIO = 1.5
    const val LOW_POWER_DEPARTURE_DISTANCE_FLOOR = 20.0
    const val LOW_POWER_DEPARTURE_SPEED = 2.5
    const val LOW_POWER_DWELL_DISTANCE = 150.0
    const val LOW_POWER_DWELL_DURATION = 600.0
    const val LOW_POWER_SAMPLE_INTERVAL = 30.0
    const val LOW_POWER_STRICT_CLUSTER_FRACTION = 0.9
    const val LOW_POWER_STRICT_DWELL_DISTANCE = 20.0
    const val LOW_POWER_STRICT_DWELL_DURATION = 300.0
    const val LOW_POWER_WINDOW_GRACE_PERIOD = 60.0
    const val MAX_GPS_ACCURACY_FILTER = 300.0
    const val MAX_TAIL_DURATION = 300.0
    const val MERGE_RECENT_FOOTPRINTS_LOOKBACK = 1800.0
    const val MIN_KEPT_SEGMENT_DURATION = 60.0
    const val MOVING_RECOVERY_GAP_THRESHOLD = 45.0
    const val MOVING_TIMELINE_SIFT_INTERVAL = 120.0
    const val NEW_PLACE_MIN_DURATION = 3600.0
    const val ONGOING_AI_ANALYSIS_INTERVAL = 3600.0
    const val OVERLAP_MIN_DURATION = 300.0
    const val OVERLAP_MIN_RATIO = 0.3
    const val PAST_MEMORIES_CHECK_HOUR = 10
    const val PATH_LOOP_DISPLACEMENT_THRESHOLD = 500.0
    const val PATH_LOOP_DISTANCE_THRESHOLD = 1000.0
    const val PATH_LOOP_RATIO_THRESHOLD = 10.0
    const val PEDOMETER_MIN_MOVING_STEP_DELTA = 3
    const val PEDOMETER_STARTUP_LOOKBACK = 30.0
    const val PHOTO_LINKING_MAX_DISTANCE = 1500.0
    const val PLACE_MATCH_DISTANCE_THRESHOLD = 200.0
    const val RAW_STATIONARY_DUPLICATE_DISTANCE = 5.0
    const val RAW_STATIONARY_EXACT_DUPLICATE_DISTANCE = 1.0
    const val RAW_STATIONARY_HEARTBEAT_INTERVAL = 300.0
    const val RAW_STATIONARY_MAX_ACCURACY = 20.0
    const val RECONSTRUCTION_BOUNDARY_TOLERANCE = 600.0
    const val RECOVERY_BOOST_THROTTLE_INTERVAL = 60.0
    const val REGION_REUSE_DISTANCE_THRESHOLD = 50.0
    const val REPORTED_HIGH_SPEED_THRESHOLD = 20.0
    const val RIDICULOUS_TRANSPORT_SPEED_THRESHOLD = 350.0
    const val ROUND_TRIP_ENDPOINT_TOLERANCE = 150.0
    const val ROUND_TRIP_INTERVAL_GAP = 120.0
    const val ROUND_TRIP_MIN_LEG_LENGTH = 300.0
    const val ROUTE_COVERAGE_HIGH_RATIO = 0.85
    const val ROUTE_COVERAGE_MIN_RATIO = 0.7
    const val ROUTE_SIMPLIFY_DEFAULT_TOLERANCE = 250.0
    const val ROUTE_SIMPLIFY_TIER1_DURATION = 10800.0
    const val ROUTE_SIMPLIFY_TIER1_TOLERANCE = 1500.0
    const val ROUTE_SIMPLIFY_TIER2_DURATION = 3600.0
    const val ROUTE_SIMPLIFY_TIER2_TOLERANCE = 1000.0
    const val ROUTE_SIMPLIFY_TIER3_DURATION = 900.0
    const val ROUTE_SIMPLIFY_TIER3_TOLERANCE = 500.0
    const val SAME_PLACE_MERGE_GAP_THRESHOLD = 3600.0
    const val SHORT_GAP_THRESHOLD = 120.0
    const val SPEED_THRESHOLD_STATIONARY = 0.5
    const val SPLIT_CLUSTER_MIN_POINTS = 4
    const val SPLIT_CLUSTER_RADIUS_CAP = 100.0
    const val SPLIT_CLUSTER_RADIUS_RATIO = 0.8
    const val START_TRACKING_DEBOUNCE_INTERVAL = 30.0
    const val STATIONARY_DETECTION_DURATION_THRESHOLD = 480.0
    const val STATIONARY_DETECTION_MAX_DIAMETER = 400.0
    const val STATIONARY_DETECTION_MIN_POINTS = 8
    const val STATIONARY_DETECTION_SAMPLING_INTERVAL = 5
    const val STATIONARY_DETECTION_WINDOW_SIZE = 20
    const val STATIONARY_DIAMETER_THRESHOLD = 200.0
    const val STATIONARY_DWELL_DISTANCE = 150.0
    const val STATIONARY_DWELL_DURATION = 300.0
    const val STATIONARY_DWELL_SPEED = 1.0
    const val STATIONARY_LOCATION_SAMPLE_INTERVAL = 900.0
    const val STATIONARY_PROBE_INTERVAL = 900.0
    const val STATIONARY_PROBE_MIN_DURATION = 600.0
    const val STATIONARY_WAKEUP_REGION_RADIUS = 200.0
    const val STAY_EXIT_DISTANCE_THRESHOLD = 250.0
    const val SYNC_THROTTLE_INTERVAL = 30.0
    const val TAIL_CLUSTER_MIN_POINTS = 3
    const val TIMELINE_SIFT_DEBOUNCE_INTERVAL = 900.0
    const val TRANSPORT_ADJACENCY_TOLERANCE = 60.0
    const val TRANSPORT_DEPARTURE_BACKFILL_FRACTION = 0.5
    const val TRANSPORT_DEPARTURE_MAXIMUM_BACKFILL_DURATION = 120.0
    const val TRANSPORT_DEPARTURE_MINIMUM_SPEED = 0.5
    const val TRANSPORT_DEPARTURE_SPEED_SAMPLE_DURATION = 120.0
    const val TRANSPORT_DETECTION_SEGMENT_DURATION = 60.0
    const val TRANSPORT_FINALIZE_MIN_DISTANCE = 150.0
    const val TRANSPORT_FINALIZE_MIN_POINTS = 3
    const val TRANSPORT_GAP_BREAK_THRESHOLD = 600.0
    const val TRANSPORT_MATCH_TIME_TOLERANCE = 1200.0
    const val TRANSPORT_MAX_REASONABLE_SPEED = 42.0
    const val TRANSPORT_MERGE_DISTANCE = 180.0
    const val TRANSPORT_MERGE_GAP_TOLERANCE = 900.0
    const val TRANSPORT_MERGE_TIME_GAP = 600.0
    const val TRANSPORT_OVERLAP_RATIO_THRESHOLD = 0.8
    const val TRANSPORT_SHORT_HIGH_SPEED_DURATION = 60.0
    const val TRANSPORT_SHORT_HIGH_SPEED_SPEED = 3.0
    const val TRANSPORT_SPEED_SANITY_CHECK_DURATION = 120.0
    const val TRANSPORT_TYPE_CHANGE_DURATION_THRESHOLD = 180.0
    const val TRANSPORT_TYPE_DETECTION_MIN_POINTS = 8
    const val TRANSPORT_TYPE_DETECTION_SAMPLING_INTERVAL = 3
    const val TRANSPORT_TYPE_WINDOW_MIN_POINTS = 6
    const val TRANSPORT_TYPE_WINDOW_SIZE = 10
    const val TRANSPORT_UNOBSERVED_MIN_SPEED = 5.0
    const val UI_DEBOUNCE_INTERVAL_NS = 400000000L
    const val UI_MOVING_HOLD_DURATION = 120.0
    const val WALKING_IMPOSSIBLE_SPEED = 15.0
    const val WALKING_MIN_STEPS_PER_MINUTE = 12.0
    const val WALKING_MIN_STEP_COUNT = 40
    const val WALKING_SANITY_MIN_DISTANCE = 1000.0
    const val WALKING_SUSPICIOUS_SPEED = 3.0
    const val WIDGET_HISTORY_SYNC_MIN_INTERVAL = 1200.0
    const val WIDGET_INFERRED_ROUTE_DISTANCE_THRESHOLD = 500.0
    const val WIDGET_TODAY_SYNC_MIN_INTERVAL = 90.0
}
