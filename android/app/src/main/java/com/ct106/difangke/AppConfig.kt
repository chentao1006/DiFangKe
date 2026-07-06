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

    // ── 高德地图 REST API ─────────────────────────────────────────
    val AMAP_REST_KEY = BuildConfig.AMAP_REST_KEY
    const val AMAP_GEOCODE_URL = "https://restapi.amap.com/v3/geocode/regeo"

    // ── 统计分析 ──────────────────────────────────────────────────
    val APTABASE_APP_KEY = BuildConfig.APTABASE_APP_KEY

    // ── 停留识别参数 ──────────────────────────────────────────────
    /** 停留识别的距离阈值（米）：超过此距离视为离开 */
    const val STAY_DISTANCE_THRESHOLD = 100.0

    /** 两个足迹合并的最大直线距离门槛（米） */
    const val MERGE_DISTANCE_THRESHOLD = 100.0

    /** 两个足迹合并的最大时间间隔（秒） */
    const val STAY_MERGE_GAP_THRESHOLD = 300.0

    /** 停留识别的最短时间（秒） */
    const val STAY_DURATION_THRESHOLD = 300.0

    /** 交通段最低位移（米） */
    const val TRANSPORT_MIN_DISTANCE_THRESHOLD = 120.0

    /** 交通段最低时长（秒） */
    const val TRANSPORT_MIN_DURATION_THRESHOLD = 180.0

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
    const val LIVE_STAY_MIN_DURATION_THRESHOLD = 240.0 // 4 min

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
}
