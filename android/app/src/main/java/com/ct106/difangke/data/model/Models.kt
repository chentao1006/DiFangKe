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

    companion object {
        fun from(
            speedMs: Double,
            motionType: Int = 4, // 对应 Android DetectedActivity 类型 (4 = UNKNOWN)
            stepCount: Int = 0,
            durationSec: Long = 0,
            distanceMeters: Double = 0.0,
            pointCount: Int = 0,
            preferredAuto: TransportType = CAR,
            preferredCycling: TransportType = BICYCLE
        ): TransportType {
            val kmh = speedMs * 3.6
            val effectiveDistance = if (distanceMeters > 0) distanceMeters else (speedMs * durationSec)
            
            // --- 物理常识铁律：最高速度约束 ---
            var effectiveMotion = motionType
            // 步行不可能超过 15km/h (约 4.2m/s)
            if (kmh > 15.0 && motionType == 7 /* WALKING */) effectiveMotion = 4 /* UNKNOWN */
            // 跑步不可能超过 35km/h
            if (kmh > 35.0 && motionType == 8 /* RUNNING */) effectiveMotion = 4 /* UNKNOWN */
            // 确定车载速度 (45km/h 以上，甚至未知状态也判定为车载)
            if (kmh > 45.0 && (motionType == 7 || motionType == 8 || motionType == 4)) effectiveMotion = 0 /* IN_VEHICLE */

            // --- 综合常识铁律：距离与时间的合理性 ---
            var maxAllowedTypeCategory = 4 // 默认允许所有 (4=Train/Airplane/Ship)
            
            // 不到 3 公里，不可能是轨交、火车、飞机（强制降级为汽车）
            if (effectiveDistance < 3000) {
                maxAllowedTypeCategory = 3
            }
            // 不到 500 米，不可能是汽车（强制降级为自行车或以下，排除短途高漂移）
            if (effectiveDistance < 500) {
                maxAllowedTypeCategory = 2 
            }

            var safePreferredAuto = preferredAuto
            if (maxAllowedTypeCategory < 4 && getCategory(safePreferredAuto) >= 4) {
                safePreferredAuto = CAR
            }
            if (maxAllowedTypeCategory < 3 && getCategory(safePreferredAuto) >= 3) {
                safePreferredAuto = preferredCycling
            }

            inferLongPublicTransitType(
                kmh = kmh,
                distanceMeters = effectiveDistance,
                durationSec = durationSec,
                pointCount = pointCount
            )?.let { return it }

            // 1. 优先使用传感器数据 (Google Play Services Activity Recognition)
            when (effectiveMotion) {
                7 /* WALKING */ -> return if (kmh > 7.0) RUNNING else SLOW
                8 /* RUNNING */ -> return RUNNING
                1 /* ON_BICYCLE */ -> return if (kmh > 55.0) safePreferredAuto else preferredCycling
                0 /* IN_VEHICLE */ -> {
                    if (kmh > 100.0 && maxAllowedTypeCategory >= 4) return TRAIN
                    if (kmh > 80.0 && safePreferredAuto == BUS) return CAR
                    return safePreferredAuto
                }
            }

            // 2. 结合步数判定
            if (stepCount > 100 && durationSec > 0) {
                val stepsPerMin = stepCount / (durationSec / 60.0)
                if (stepsPerMin > 140 && kmh < 35.0) return RUNNING
                if (stepsPerMin > 30 && kmh < 15.0) return SLOW
            }

            // 3. 速度兜底 (及堵车判定)
            if (kmh < 4.5) {
                val stepsPerMin = if (durationSec > 0L) stepCount / (durationSec / 60.0) else 0.0
                // 如果速度极低但步数很少，判定为车载堵车
                if (stepsPerMin < 5.0 && stepCount < 20) return safePreferredAuto
                return SLOW
            }
            
            var effectiveKmh = kmh
            if (maxAllowedTypeCategory < 4 && effectiveKmh >= 120.0) effectiveKmh = 119.0 // 强行拉回汽车区间
            if (maxAllowedTypeCategory < 3 && effectiveKmh >= 25.0) effectiveKmh = 24.0 // 强行拉回自行车区间

            return when {
                effectiveKmh < 12.0 -> BICYCLE
                effectiveKmh < 25.0 -> preferredCycling
                effectiveKmh < 120.0 -> safePreferredAuto
                effectiveKmh < 350.0 -> TRAIN
                else -> AIRPLANE
            }
        }

        private fun inferLongPublicTransitType(
            kmh: Double,
            distanceMeters: Double,
            durationSec: Long,
            pointCount: Int
        ): TransportType? {
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
