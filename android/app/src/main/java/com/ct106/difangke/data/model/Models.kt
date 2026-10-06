package com.ct106.difangke.data.model

import java.util.Date
import java.util.UUID

// ── 足迹状态（对应 iOS FootprintStatus）─────────────────────────
enum class FootprintStatus(val raw: String) {
    CANDIDATE("candidate"),
    CONFIRMED("confirmed"),
    IGNORED("ignored"),
    MANUAL("manual");

    companion object {
        fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: CANDIDATE
    }
}

// ── 交通类型（对应 iOS TransportType）────────────────────────────
enum class TransportType(val raw: String) {
    SLOW("slow"),
    RUNNING("running"),
    BICYCLE("bicycle"),
    EBIKE("ebike"),
    MOTORCYCLE("motorcycle"),
    BUS("bus"),
    CAR("car"),
    SUBWAY("subway"),
    TRAIN("train"),
    AIRPLANE("airplane"),
    SHIP("ship");

    val localizedName: String get() = when (this) {
        SLOW -> "步行"
        RUNNING -> "跑步"
        BICYCLE -> "自行车"
        EBIKE -> "电动车"
        MOTORCYCLE -> "摩托车"
        BUS -> "公交/大巴"
        CAR -> "汽车"
        SUBWAY -> "轨道交通"
        TRAIN -> "火车/高铁"
        AIRPLANE -> "飞机"
        SHIP -> "轮船"
    }

    val icon: String get() = when (this) {
        SLOW -> "directions_walk"
        RUNNING -> "directions_run"
        BICYCLE -> "directions_bike"
        EBIKE -> "electric_moped"
        MOTORCYCLE -> "two_wheeler"
        BUS -> "directions_bus"
        CAR -> "directions_car"
        SUBWAY -> "directions_subway"
        TRAIN -> "train"
        AIRPLANE -> "flight"
        SHIP -> "directions_boat"
    }

    /** iOS `TransportType.category`: 1=foot, 2=cycle, 3=road vehicle, 4=rail/air/sea. */
    val category: Int get() = getCategory(this)

    /** iOS `automaticSpeedRange` (km/h). Ranges deliberately overlap. */
    val automaticSpeedRange: ClosedFloatingPointRange<Double>? get() = when (this) {
        SLOW, RUNNING -> null
        BICYCLE -> 0.0..30.0
        EBIKE -> 3.0..50.0
        MOTORCYCLE -> 20.0..110.0
        BUS -> 15.0..100.0
        CAR -> 15.0..150.0
        SUBWAY -> 25.0..120.0
        TRAIN -> 60.0..350.0
        AIRPLANE -> 180.0..1200.0
        SHIP -> 3.0..60.0
    }

    fun canBeAutomaticallyInferred(speedKmh: Double, maxCategory: Int): Boolean {
        if (category > maxCategory) return false
        return automaticSpeedRange?.contains(speedKmh) == true
    }

    /** Android DetectedActivity codes used as the motion hint (iOS MotionType). */
    object Motion {
        const val IN_VEHICLE = 0
        const val ON_BICYCLE = 1
        const val ON_FOOT = 2
        const val STILL = 3
        const val UNKNOWN = 4
        const val TILTING = 5
        const val WALKING = 7
        const val RUNNING = 8
    }

    companion object {
        /**
         * Backward-compatible entry point. Health metrics are optional: with no
         * Health Connect data (null) classification degrades to speed/distance
         * and history only, exactly as iOS does without HealthKit samples.
         */
        fun from(
            speedMs: Double,
            motionType: Int = Motion.UNKNOWN,
            stepCount: Int = 0,
            durationSec: Long = 0,
            distanceMeters: Double = 0.0,
            pointCount: Int = 0,
            observedPointCount: Int? = null,
            preferredAuto: TransportType = CAR,
            preferredCycling: TransportType = BICYCLE,
            preferredTransport: TransportType? = null,
            walkingDistance: Double? = null,
            floorsClimbed: Int? = null
        ): TransportType = classify(
            speedMs = speedMs,
            motionType = motionType,
            stepCount = stepCount,
            walkingDistance = walkingDistance ?: 0.0,
            floorsClimbed = floorsClimbed ?: 0,
            durationSec = durationSec.toDouble(),
            distanceMeters = distanceMeters,
            pointCount = pointCount,
            observedPointCount = observedPointCount,
            preferredAuto = preferredAuto,
            preferredCycling = preferredCycling,
            preferredTransport = preferredTransport
        )

        /** Line-by-line port of iOS `TransportType.from(speed:...)` (Models/Transport.swift). */
        fun classify(
            speedMs: Double,
            motionType: Int = Motion.UNKNOWN,
            stepCount: Int? = 0,
            walkingDistance: Double? = 0.0,
            floorsClimbed: Int? = 0,
            durationSec: Double = 0.0,
            distanceMeters: Double = 0.0,
            pointCount: Int = 0,
            observedPointCount: Int? = null,
            preferredAuto: TransportType = CAR,
            preferredCycling: TransportType = BICYCLE,
            preferredTransport: TransportType? = null
        ): TransportType {
            val steps = stepCount ?: 0
            val walkDist = walkingDistance ?: 0.0
            val floors = floorsClimbed ?: 0
            val duration = durationSec
            val kmh = speedMs * 3.6
            val minutes = maxOf(duration / 60.0, 0.0)
            val estimatedDistance = maxOf(speedMs * duration, 0.0)
            val effectiveDistance = if (distanceMeters > 0) distanceMeters else estimatedDistance
            val stepsPerMinute = if (minutes > 0) steps / minutes else 0.0
            val walkingDistanceRatio = if (estimatedDistance > 0) minOf(1.5, walkDist / estimatedDistance) else 0.0
            val hasStrongOnFootEvidence =
                (walkDist > 250 && walkingDistanceRatio > 0.55) ||
                    (stepsPerMinute > 35 && walkDist > 120) ||
                    (floors >= 2 && walkDist > 80)
            val hasDominantOnFootEvidence =
                (walkDist > 250 && walkingDistanceRatio > 0.75) ||
                    (stepsPerMinute > 65 && walkDist > 180) ||
                    (floors >= 3 && walkDist > 120)
            val hasMeaningfulTrip =
                effectiveDistance >= maxOf(800.0, com.ct106.difangke.AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) &&
                    duration >= 3 * 60
            val hasCorroboratedRunningEvidence =
                motionType == Motion.RUNNING &&
                    stepsPerMinute >= 120 &&
                    walkDist >= maxOf(120.0, minutes * 70) &&
                    walkingDistanceRatio >= 0.45 &&
                    kmh >= 6.5 && kmh <= 25

            // Android ON_FOOT is the generic "walking or running" hint.
            val motion = if (motionType == Motion.ON_FOOT) Motion.WALKING else motionType
            var effectiveMotion = motion
            if (kmh > 15 && motion == Motion.WALKING) effectiveMotion = Motion.UNKNOWN
            if (kmh > 35 && motion == Motion.RUNNING) effectiveMotion = Motion.UNKNOWN
            if (motion == Motion.RUNNING && !hasCorroboratedRunningEvidence) effectiveMotion = Motion.UNKNOWN
            val isUnknownLike = motion == Motion.UNKNOWN || motion == Motion.TILTING
            if (kmh > 45 && (motion == Motion.WALKING || motion == Motion.RUNNING || isUnknownLike)) {
                effectiveMotion = Motion.IN_VEHICLE
            }
            if (kmh > 100 && motion == Motion.ON_BICYCLE) effectiveMotion = Motion.IN_VEHICLE
            if (effectiveMotion == Motion.IN_VEHICLE && hasDominantOnFootEvidence && kmh < 14) {
                effectiveMotion = Motion.WALKING
            }

            var maxAllowedTypeCategory = 4
            if (effectiveDistance < 3000) maxAllowedTypeCategory = 3
            if (effectiveDistance < 500) maxAllowedTypeCategory = 2

            var safePreferredAuto = preferredAuto
            if (maxAllowedTypeCategory < 4 && safePreferredAuto.category >= 4) safePreferredAuto = CAR
            if (maxAllowedTypeCategory < 3 && safePreferredAuto.category >= 3) safePreferredAuto = preferredCycling
            val habitualTransport = preferredTransport?.takeIf {
                it.canBeAutomaticallyInferred(kmh, maxAllowedTypeCategory)
            }

            val longPublicTransitType = inferLongPublicTransitType(
                kmh = kmh,
                distanceMeters = effectiveDistance,
                durationSec = duration,
                pointCount = observedPointCount ?: pointCount
            )
            if (longPublicTransitType != null && !hasStrongOnFootEvidence) return longPublicTransitType

            when (effectiveMotion) {
                Motion.WALKING -> {
                    if (hasDominantOnFootEvidence) return SLOW
                    if (hasMeaningfulTrip) {
                        if (habitualTransport != null) return habitualTransport
                        if (kmh >= 8) return preferredCycling
                    }
                    return SLOW
                }
                Motion.RUNNING -> return RUNNING
                Motion.ON_BICYCLE -> {
                    if (kmh > 55) return safePreferredAuto
                    return preferredCycling
                }
                Motion.IN_VEHICLE -> {
                    if (kmh > 100 && maxAllowedTypeCategory >= 4) return TRAIN
                    if (kmh > 80 && safePreferredAuto == BUS) return CAR
                    if (habitualTransport != null &&
                        habitualTransport.canBeAutomaticallyInferred(kmh, maxAllowedTypeCategory)
                    ) return habitualTransport
                    return safePreferredAuto
                }
            }

            if (hasStrongOnFootEvidence) {
                if (hasDominantOnFootEvidence && stepsPerMinute > 65 && kmh < 14) return SLOW
                if (hasDominantOnFootEvidence && walkingDistanceRatio > 0.75 && kmh < 14) return SLOW
            }
            if (steps > 100 && duration > 0) {
                if (stepsPerMinute > 30 && kmh < 15) return SLOW
            }

            if (kmh < 4.5) {
                if (hasMeaningfulTrip && !hasDominantOnFootEvidence) {
                    return habitualTransport ?: preferredCycling
                }
                if (stepsPerMinute < 5 && steps < 20 && walkDist < 80) {
                    return habitualTransport ?: safePreferredAuto
                }
                return SLOW
            }

            var effectiveKmh = kmh
            if (maxAllowedTypeCategory < 4 && effectiveKmh >= 120.0) effectiveKmh = 119.0
            if (maxAllowedTypeCategory < 3 && effectiveKmh >= 25.0) effectiveKmh = 24.0

            if (effectiveKmh < 12 && hasDominantOnFootEvidence) return SLOW
            if (effectiveKmh < 18 && hasStrongOnFootEvidence && walkingDistanceRatio > 0.45) return preferredCycling
            if (effectiveKmh < 35) {
                if (habitualTransport != null) {
                    val plausible =
                        (habitualTransport.category == 2 && effectiveDistance <= 20_000) ||
                            (habitualTransport.category == 3 && hasMeaningfulTrip) ||
                            (habitualTransport.category == 4 && effectiveDistance >= 10_000)
                    if (plausible) return habitualTransport
                }
                return preferredCycling
            }
            if (habitualTransport != null) return habitualTransport
            if (effectiveKmh < 120) return safePreferredAuto
            if (effectiveKmh < 350) return TRAIN
            return AIRPLANE
        }

        private fun inferLongPublicTransitType(
            kmh: Double,
            distanceMeters: Double,
            durationSec: Double,
            pointCount: Int
        ): TransportType? {
            val isSparseUrbanRailTrip =
                distanceMeters >= 5_000 && distanceMeters <= 30_000 &&
                    durationSec >= 8 * 60 && durationSec <= 90 * 60 &&
                    pointCount in 0..4 &&
                    kmh >= 12 && kmh < 45
            if (isSparseUrbanRailTrip) return SUBWAY

            if (distanceMeters < 10_000.0 || durationSec < 20 * 60) return null

            val segmentCount = maxOf(pointCount - 1, 1)
            val metersPerSegment = distanceMeters / segmentCount
            val isSparseLongTrip = pointCount > 0 && (pointCount <= 4 || metersPerSegment >= 15_000.0)
            val isMixedPublicTransitPace = distanceMeters >= 15_000.0 && kmh >= 8.0 && kmh < 45.0

            if (distanceMeters >= 600_000.0 && (isSparseLongTrip || kmh >= 180.0)) return AIRPLANE
            if (distanceMeters >= 80_000.0 && (isSparseLongTrip || kmh >= 90.0)) return TRAIN
            if (isSparseLongTrip && distanceMeters >= 30_000.0) return SUBWAY
            if (isMixedPublicTransitPace) return if (distanceMeters >= 20_000.0) SUBWAY else BUS
            return null
        }

        fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: CAR

        // 用于合并逻辑的分类
        fun getCategory(type: TransportType): Int = when (type) {
            SLOW, RUNNING -> 1
            BICYCLE, EBIKE -> 2
            MOTORCYCLE, BUS, CAR -> 3
            SUBWAY, TRAIN, AIRPLANE, SHIP -> 4
        }
    }
}

// ── 候选足迹（停留点检测输出，内存中使用）────────────────────────
data class CandidateFootprint(
    val startTime: Date,
    val endTime: Date,
    val latitude: Double,
    val longitude: Double,
    val duration: Long,  // seconds
    val rawLatitudes: List<Double>,
    val rawLongitudes: List<Double>
)

// ── 交通段业务模型（对应 iOS Transport struct）───────────────────
data class Transport(
    val id: UUID = UUID.randomUUID(),
    val startTime: Date,
    val endTime: Date,
    val startLocation: String,
    val endLocation: String,
    val type: TransportType,
    val distance: Double,
    val averageSpeed: Double,
    val latitudes: List<Double>,
    val longitudes: List<Double>,
    val manualType: TransportType? = null
) {
    val duration: Long get() = (endTime.time - startTime.time) / 1000L
    val currentType: TransportType get() = manualType ?: type
}

// ── 时间线条目（对应 iOS TimelineItem）───────────────────────────
sealed class TimelineItem {
    data class FootprintItem(val footprint: com.ct106.difangke.data.db.entity.FootprintEntity) : TimelineItem()
    data class TransportItem(val transport: com.ct106.difangke.data.db.entity.TransportRecordEntity) : TimelineItem()

    val startTime: java.util.Date get() = when (this) {
        is FootprintItem -> footprint.startTime
        is TransportItem -> transport.startTime
    }
    val endTime: java.util.Date get() = when (this) {
        is FootprintItem -> footprint.endTime
        is TransportItem -> transport.endTime
    }
    val id: String get() = when (this) {
        is FootprintItem -> "f_${footprint.footprintID}"
        is TransportItem -> "t_${transport.recordID}"
    }
    
    val latitude: Double get() = when (this) {
        is FootprintItem -> footprint.representativeLatitude
        is TransportItem -> transport.startLatitude
    }
    
    val longitude: Double get() = when (this) {
        is FootprintItem -> footprint.representativeLongitude
        is TransportItem -> transport.startLongitude
    }
}

// ── 活动类型预设（对应 iOS ActivityType.presets）─────────────────
data class ActivityTypePreset(
    val name: String,
    val icon: String,
    val colorHex: String,
    val sortOrder: Int,
    val isSystem: Boolean = true
)

val DEFAULT_ACTIVITY_PRESETS = listOf(
    ActivityTypePreset("居家", "home", "#007AFF", 0),
    ActivityTypePreset("工作", "work", "#A2845E", 1),
    ActivityTypePreset("旅游", "airplane_ticket", "#FF9500", 2),
    ActivityTypePreset("睡眠", "bedtime", "#5856D6", 3),
    ActivityTypePreset("美食", "restaurant", "#FF2D55", 4),
    ActivityTypePreset("购物", "shopping_bag", "#FFCC00", 5),
    ActivityTypePreset("运动", "directions_run", "#34C759", 6),
    ActivityTypePreset("娱乐", "sports_esports", "#AF52DE", 7),
    ActivityTypePreset("学习", "menu_book", "#32ADE6", 8),
    ActivityTypePreset("医疗", "medical_services", "#FF3B30", 9)
)

// ── 位置建议（对应 iOS LocationSuggestion）───────────────────────
data class LocationSuggestion(
    val id: UUID = UUID.randomUUID(),
    val name: String,
    val address: String,
    val latitude: Double,
    val longitude: Double,
    val isExistingPlace: Boolean = false,
    val placeID: UUID? = null,
    val category: String? = null
)

// ── 每日摘要（对应 iOS DaySummary）───────────────────────────────
data class DaySummary(
    val date: Date,
    val totalDuration: Long,  // seconds
    val footprintCount: Int,
    val highlightCount: Int,
    val highlightTitle: String?,
    val hasConfirmed: Boolean,
    val hasCandidate: Boolean,
    val timelineIcons: List<TimelineIcon>,
    val timelineSegments: List<TimelineSegment> = emptyList(),
    val trajectoryCount: Int,
    val mileage: Double,
    var photoCount: Int = 0
) {
    data class TimelineIcon(
        val icon: String,
        val colorHex: String,
        val isTransport: Boolean,
        val isHighlight: Boolean
    )

    data class TimelineSegment(
        val id: String,
        val startTime: Date,
        val endTime: Date,
        val colorHex: String,
        val isTransport: Boolean,
        val isCurrent: Boolean
    )

    val activityLevel: Float get() {
        val maxSeconds = 8 * 3600L
        return (totalDuration.toFloat() / maxSeconds).coerceAtMost(1f)
    }
}

// ── 足迹标题生成（对应 iOS Footprint.titleTemplates）──────────────
object FootprintTitles {
    private val templates = listOf(
        "在 %s 停留",
        "位于 %s",
        "在此处停留",
        "探索 %s"
    )

    fun generate(locationName: String, seed: Long): String {
        return locationName
    }

    fun isGeneric(title: String): Boolean {
        val generics = setOf("地点记录", "正在获取位置...", "未知地点", "点位记录", "发现足迹", "在某地停留", "此处", "某地", "")
        if (title in generics) return true
        for (w in listOf("此处", "某地")) {
            for (t in templates) {
                if (title == String.format(t, w)) return true
            }
        }
        return false
    }

    fun extractLocation(title: String): String {
        return title.trim().ifEmpty { "未知位置" }
    }
}

// ── 扩展属性：用于简化数据库实体的坐标访问 ───────────────────────
val com.ct106.difangke.data.db.entity.FootprintEntity.representativeLatitude: Double get() {
    return extractFirstDoubleOrZero(latitudeJson)
}

val com.ct106.difangke.data.db.entity.FootprintEntity.representativeLongitude: Double get() {
    return extractFirstDoubleOrZero(longitudeJson)
}

private fun extractFirstDoubleOrZero(jsonArrayStr: String): Double {
    try {
        if (jsonArrayStr.length < 3) return 0.0
        val firstComma = jsonArrayStr.indexOf(',')
        val endIndex = if (firstComma != -1) firstComma else jsonArrayStr.indexOf(']')
        if (endIndex <= 1) return 0.0
        return jsonArrayStr.substring(1, endIndex).trim().toDouble()
    } catch (e: Exception) { return 0.0 }
}

val com.ct106.difangke.data.db.entity.TransportRecordEntity.startLatitude: Double get() {
    return extractFirstDoubleFromNested(pointsJson, 0)
}

val com.ct106.difangke.data.db.entity.TransportRecordEntity.startLongitude: Double get() {
    return extractFirstDoubleFromNested(pointsJson, 1)
}

private fun extractFirstDoubleFromNested(pointsJson: String, index: Int): Double {
    try {
        if (pointsJson.length < 5) return 0.0
        val startNested = pointsJson.indexOf('[', 1)
        if (startNested == -1) {
            val startObj = pointsJson.indexOf('{', 1)
            if (startObj != -1) {
                // simple fallback if it's object array
                val arr = org.json.JSONArray(pointsJson)
                if (arr.length() > 0) {
                    val obj = arr.getJSONObject(0)
                    if (index == 0) return obj.optDouble("lat", obj.optDouble("latitude", 0.0))
                    else return obj.optDouble("lon", obj.optDouble("longitude", 0.0))
                }
            }
            return 0.0
        }
        val endNested = pointsJson.indexOf(']', startNested)
        if (endNested == -1) return 0.0
        val pairStr = pointsJson.substring(startNested + 1, endNested)
        val parts = pairStr.split(',')
        if (parts.size > index) return parts[index].trim().toDouble()
    } catch (e: Exception) {}
    return 0.0
}
