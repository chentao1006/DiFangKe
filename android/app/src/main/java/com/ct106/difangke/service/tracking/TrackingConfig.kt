package com.ct106.difangke.service.tracking

/**
 * Live-tracking thresholds mirrored from iOS `Config.plist` / `AppConfig.swift`.
 * Times are seconds unless the name ends in `_MS`; distances are metres;
 * speeds are m/s.
 */
object TrackingConfig {
    // ── Ingest pre-filter (LocationManager.processLocationUpdate) ──
    const val PHYSICAL_MAX_SPEED_THRESHOLD = 600.0
    const val REPORTED_HIGH_SPEED_THRESHOLD = 20.0
    const val RIDICULOUS_JUMP_ACCURACY = 400.0
    const val RIDICULOUS_JUMP_DISTANCE = 1_500.0
    const val RIDICULOUS_CALC_SPEED = 60.0
    const val RIDICULOUS_CALC_SPEED_ACCURACY = 80.0
    const val WEAK_CLUSTER_RETURN_ACCURACY = 100.0
    const val WEAK_CLUSTER_RETURN_DISTANCE = 2_000.0
    const val WEAK_CLUSTER_WINDOW_POINTS = 15
    const val WEAK_CLUSTER_WINDOW = 5 * 60.0
    const val WEAK_CLUSTER_WEAK_ACCURACY = 150.0
    const val WEAK_CLUSTER_RADIUS = 100.0

    // ── FootprintProcessor drift filters ──
    const val MAX_GPS_ACCURACY_FILTER = 300.0
    const val FOOTPRINT_MIN_SAMPLE_INTERVAL = 5.0
    const val LIVE_FIX_MAX_AGE = 60.0
    const val DRIFT_SPEED_MAX_POSSIBLE = 60.0
    const val DRIFT_ACCURACY_THRESHOLD = 65.0
    const val DRIFT_DISTANCE_GAP = 300.0
    const val DRIFT_ACCURACY_DEGRADATION_RATIO = 3.0
    const val DRIFT_ACCURACY_ABSOLUTE_FLOOR = 150.0
    const val DRIFT_DISTANCE_THRESHOLD = 100.0
    const val DRIFT_SPEED_THRESHOLD = 45.0
    const val STAY_DISTANCE_THRESHOLD = 100.0
    const val LIVE_STAY_MIN_DURATION_THRESHOLD = 300.0
    const val STAY_DURATION_THRESHOLD = 300.0
    const val STAY_PERCENTILE = 0.85
    const val STAY_MERGE_GAP_THRESHOLD = 1_800.0
    const val MERGE_DISTANCE_THRESHOLD = 150.0
    const val LIVE_STAY_MERGE_TIME_THRESHOLD = 1_200.0
    const val SAME_PLACE_MERGE_GAP_THRESHOLD = 3_600.0

    // ── Raw persistence throttle ──
    const val RAW_STATIONARY_MAX_ACCURACY = 20.0
    const val RAW_STATIONARY_HEARTBEAT_INTERVAL = 300.0
    const val RAW_STATIONARY_EXACT_DUPLICATE_DISTANCE = 1.0
    const val RAW_STATIONARY_DUPLICATE_DISTANCE = 5.0

    // ── Departure / UI movement ──
    const val STATIONARY_DWELL_SPEED = 1.0
    const val STATIONARY_DWELL_DURATION = 300.0
    const val STATIONARY_DWELL_DISTANCE = 150.0
    const val DEPARTURE_ACCURACY_THRESHOLD = 100.0
    const val DEPARTURE_DISTANCE_THRESHOLD = 150.0
    const val DEPARTURE_HIGH_SPEED_DISTANCE = 500.0
    const val DEPARTURE_LONG_STAY_DURATION = 1_800.0
    const val DEPARTURE_DRIFT_RESISTANT_FLOOR = 300.0
    const val DEPARTURE_DRIFT_RESISTANT_RATIO = 3.0
    const val UI_MOVING_HOLD_DURATION = 120.0
    const val DEPARTURE_BOOST_DURATION = 600.0
    const val FRESH_FIX_MAX_AGE = 30.0

    // ── Stationary low power ──
    const val LOW_POWER_SAMPLE_INTERVAL = 30.0
    const val LOW_POWER_DWELL_DURATION = 600.0
    const val LOW_POWER_DWELL_DISTANCE = 150.0
    const val LOW_POWER_CLUSTER_FRACTION = 0.8
    const val LOW_POWER_STRICT_DWELL_DURATION = 300.0
    const val LOW_POWER_STRICT_DWELL_DISTANCE = 20.0
    const val LOW_POWER_STRICT_CLUSTER_FRACTION = 0.9
    const val LOW_POWER_WINDOW_GRACE_PERIOD = 60.0
    const val LOW_POWER_DEPARTURE_ACCURACY = 60.0
    const val LOW_POWER_DEPARTURE_SPEED = 2.5
    const val LOW_POWER_DEPARTURE_DISTANCE_FLOOR = 20.0
    const val LOW_POWER_DEPARTURE_ACCURACY_RATIO = 1.5
    const val STATIONARY_LOCATION_SAMPLE_INTERVAL = 900.0
    const val MOVING_RECOVERY_GAP_THRESHOLD = 45.0
    const val MOVING_RECOVERY_MIN_INTERVAL = 60.0
    const val PEDOMETER_MIN_MOVING_STEP_DELTA = 3

    /**
     * Android analog of iOS's 25 m / 5 m "departure watch" standard session.
     * Tencent has no distance filter, so a periodic fix is used instead:
     * network-only when a hardware significant-motion sensor can wake us,
     * GPS-allowed otherwise.
     */
    const val LOW_POWER_WATCH_INTERVAL_MS = 60_000L
    const val LOW_POWER_WATCH_GPS_INTERVAL_MS = 30_000L
    const val MOVING_INTERVAL_MS = 5_000L
    const val UNCONFIRMED_STATIONARY_INTERVAL_MS = 10_000L
    const val POWER_SAVING_INTERVAL_MS = 10 * 60_000L

    // ── Timeline sift / merge ──
    const val MOVING_TIMELINE_SIFT_INTERVAL = 120.0
    const val TIMELINE_SIFT_DEBOUNCE_INTERVAL = 900.0
    const val LIVE_MERGE_TASK_DELAY_MS = 3_000L
    const val MERGE_RECENT_FOOTPRINTS_LOOKBACK = 1_800.0
    const val MERGE_RECENT_FOOTPRINTS_MAX = 5

    // ── Notifications / geocode / ongoing title ──
    const val NEW_PLACE_HISTORY_RADIUS = 200.0
    const val GEOCODE_HIGH_SPEED_THRESHOLD = 10.0
    const val GEOCODE_HIGH_SPEED_DISTANCE = 1_000.0
    const val GEOCODE_DISTANCE = 100.0
    const val ONGOING_TITLE_REFRESH_INTERVAL = 3_600.0
    const val ACTIVITY_EXTENSION_ACCURACY_THRESHOLD = 100.0
    const val EDITED_STAY_EXTENSION_LOOKBACK = 5 * 60.0
}
