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
    AIRPLANE("airplane");

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
    }

    companion object {
        fun fromSpeed(speedMs: Double): TransportType {
            val kmh = speedMs * 3.6
            return when {
                kmh < 2 -> SLOW
                kmh < 3 -> RUNNING
                kmh < 10 -> BICYCLE
                kmh < 20 -> EBIKE
                kmh < 40 -> MOTORCYCLE
                kmh < 100 -> CAR
                kmh < 300 -> TRAIN
                else -> AIRPLANE
            }
        }

        fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: CAR
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
    data class TransportItem(val transport: Transport) : TimelineItem()

    val startTime: Date get() = when (this) {
        is FootprintItem -> footprint.startTime
        is TransportItem -> transport.startTime
    }
    val endTime: Date get() = when (this) {
        is FootprintItem -> footprint.endTime
        is TransportItem -> transport.endTime
    }
    val id: String get() = when (this) {
        is FootprintItem -> footprint.footprintID.toString()
        is TransportItem -> transport.id.toString()
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
    ActivityTypePreset("旅游", "flight", "#FF9500", 2),
    ActivityTypePreset("睡眠", "bedtime", "#5856D6", 3),
    ActivityTypePreset("美食", "restaurant", "#FF2D55", 4),
    ActivityTypePreset("购物", "shopping_bag", "#FFCC00", 5),
    ActivityTypePreset("运动", "directions_run", "#34C759", 6),
    ActivityTypePreset("娱乐", "sports_esports", "#AF52DE", 7),
    ActivityTypePreset("学习", "menu_book", "#32ADE6", 8),
    ActivityTypePreset("医疗", "local_hospital", "#FF3B30", 9)
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
    val templates = listOf(
        "在%s停留",
        "在%s驻足",
        "寻迹于%s",
        "漫步于%s",
        "徘徊在%s",
        "身处%s",
        "栖息于%s",
        "在%s的一段时光"
    )

    fun generate(locationName: String, seed: Long): String {
        val index = Math.abs(seed.toInt()) % templates.size
        return String.format(templates[index], locationName)
    }

    fun isGeneric(title: String): Boolean {
        val generics = setOf("地点记录", "正在获取位置...", "未知地点", "点位记录", "发现足迹", "寻迹此处", "在某地停留", "此处", "某地", "")
        if (title in generics) return true
        for (w in listOf("此处", "某地")) {
            for (t in templates) {
                if (title == String.format(t, w)) return true
            }
        }
        return false
    }
}
