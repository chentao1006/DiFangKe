package com.ct106.difangke.service

import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import java.util.Calendar
import java.util.Date
import kotlin.math.abs
import kotlin.math.min

/**
 * Pure Kotlin port of iOS `ActivityType.getSuggestedActivities` /
 * `ActivityType.getAutoMatchActivity` (ios/DiFangKe/Models/ActivityType.swift).
 *
 * `FootprintEntity.activityTypeValue` stores `ActivityTypeEntity.id`.
 */
object ActivitySuggestion {

    private val poiCategoryMap: Map<String, String> = mapOf(
        "MKPOICategoryRestaurant" to "美食", "MKPOICategoryCafe" to "美食", "MKPOICategoryFoodMarket" to "美食",
        "MKPOICategorySchool" to "学习", "MKPOICategoryUniversity" to "学习", "MKPOICategoryLibrary" to "学习",
        "MKPOICategoryHospital" to "医疗", "MKPOICategoryPharmacy" to "医疗",
        "MKPOICategoryPark" to "运动", "MKPOICategoryFitnessCenter" to "运动",
        "MKPOICategoryMuseum" to "旅游", "MKPOICategoryNationalPark" to "旅游",
        "MKPOICategoryMovieTheater" to "娱乐", "MKPOICategoryAmusementPark" to "娱乐",
        "MKPOICategoryStore" to "购物", "MKPOICategoryMall" to "购物", "MKPOICategoryDepartmentStore" to "购物"
    )

    /** Keyword table, verbatim from iOS. */
    val keywordPatterns: List<Pair<String, List<String>>> = listOf(
        "家庭" to listOf("妈妈", "爸爸", "外婆", "奶奶", "爷爷", "亲戚", "父母", "老家", "儿子", "女儿", "父", "母"),
        "居家" to listOf("家", "居", "屋", "公寓", "住宅", "苑", "府", "园", "里"),
        "工作" to listOf("公司", "工作", "办公", "大厦", "写字楼", "研制", "软件", "厂", "局", "馆", "office"),
        "旅游" to listOf("景点", "景区", "公园", "博物馆", "火车站", "机场", "酒店", "客栈", "游", "trip", "江", "湖", "山", "海", "岛", "古镇", "古村", "古城", "寺", "庙", "塔", "庄园", "庄"),
        "美食" to listOf("餐厅", "餐饮", "饭店", "面馆", "火锅", "咖啡", "饮品", "食堂", "美味", "吃", "food", "eat"),
        "购物" to listOf("商场", "购物", "超市", "中心", "广场", "便利店", "店", "城", "mall", "shop", "百货", "奥莱", "批发", "商业"),
        "运动" to listOf("体育", "健身", "场馆", "跑道", "馆", "羽毛球", "篮球", "游泳", "操场", "gym", "run"),
        "娱乐" to listOf("电影", "KTV", "游戏", "乐园", "影院", "游乐", "网吧", "play"),
        "学习" to listOf("学校", "大学", "中学", "图书馆", "学院", "课堂", "教育", "校区", "study", "learn"),
        "医疗" to listOf("医院", "门诊", "诊所", "药店", "大药房", "卫生院", "hospital", "clinic")
    )

    /**
     * Suggested activities, ordered by confidence. With [includeFallback] the list
     * is filled up to 5 by sortOrder and truncated to 5 (iOS parity).
     */
    fun getSuggestedActivities(
        footprint: FootprintEntity,
        allActivities: List<ActivityTypeEntity>,
        allPlaces: List<PlaceEntity>,
        history: List<FootprintEntity> = emptyList(),
        includeFallback: Boolean = true
    ): List<ActivityTypeEntity> {
        val suggested = mutableListOf<ActivityTypeEntity>()
        fun addIfNew(a: ActivityTypeEntity?) {
            if (a != null && suggested.none { it.id == a.id }) suggested.add(a)
        }
        fun byName(name: String) = allActivities.firstOrNull { it.name == name }

        // 1. Confident match
        getAutoMatchActivity(footprint, allActivities, allPlaces, history)?.let { suggested.add(it) }

        val cal = Calendar.getInstance().apply { time = footprint.startTime }
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        val durationHours = footprint.duration / 3600.0
        val matchedPlace = allPlaces.firstOrNull { it.placeID == footprint.placeID }
        val contextText = ((footprint.address ?: "") + (matchedPlace?.name ?: "")).lowercase()
        val weekday = cal.get(Calendar.DAY_OF_WEEK)
        val isWeekend = weekday == Calendar.SUNDAY || weekday == Calendar.SATURDAY

        // 2. POI category mapping
        matchedPlace?.category?.let { category ->
            poiCategoryMap[category]?.let { addIfNew(byName(it)) }
        }

        // 3. Keyword pattern matching (note: iOS lowercases context but not keywords)
        for ((name, keywords) in keywordPatterns) {
            if (keywords.any { contextText.contains(it) }) addIfNew(byName(name))
        }

        // 4. Time-based heuristics
        val isStrongMatch = suggested.any { it.name == "居家" || it.name == "工作" }
        if (!isStrongMatch) {
            if (durationHours > 3 && (hour >= 21 || hour <= 4)) addIfNew(byName("睡眠"))
            if ((hour in 11..13) || (hour in 18..21)) addIfNew(byName("美食"))
            if (!isWeekend && hour in 9..17 && durationHours > 1.5) addIfNew(byName("工作"))
        }

        if (includeFallback && suggested.size < 5) {
            val existing = suggested.map { it.id }.toSet()
            allActivities.filter { it.id !in existing }.sortedBy { it.sortOrder }.forEach {
                if (suggested.size < 5) suggested.add(it)
            }
        }
        return if (includeFallback) suggested.take(5) else suggested
    }

    /** Only returns a match if it is highly certain (place history or user-defined place name). */
    fun getAutoMatchActivity(
        footprint: FootprintEntity,
        allActivities: List<ActivityTypeEntity>,
        allPlaces: List<PlaceEntity>,
        history: List<FootprintEntity> = emptyList()
    ): ActivityTypeEntity? {
        val pID = footprint.placeID
        if (pID != null) {
            val placeHistory = history.filter {
                it.placeID == pID && it.activityTypeValue != null && it.footprintID != footprint.footprintID
            }
            if (placeHistory.isNotEmpty()) {
                val targetMinutes = minutesOfDay(footprint.startTime)
                val windowMinutes = 120
                val countsInWindow = linkedMapOf<String, Int>()
                val countsTotal = linkedMapOf<String, Int>()
                for (fp in placeHistory) {
                    val type = fp.activityTypeValue ?: continue
                    countsTotal[type] = (countsTotal[type] ?: 0) + 1
                    val diff = abs(targetMinutes - minutesOfDay(fp.startTime))
                    if (min(diff, 1440 - diff) <= windowMinutes) {
                        countsInWindow[type] = (countsInWindow[type] ?: 0) + 1
                    }
                }
                countsInWindow.maxByOrNull { it.value }?.let { best ->
                    allActivities.firstOrNull { it.id == best.key }?.let { return it }
                }
                countsTotal.maxByOrNull { it.value }?.let { best ->
                    if (best.value >= 3) {
                        allActivities.firstOrNull { it.id == best.key }?.let { return it }
                    }
                }
            }
        }

        val place = allPlaces.firstOrNull { it.placeID == footprint.placeID }
        if (place != null && place.isUserDefined) {
            val placeName = place.name.lowercase()
            if (placeName.contains("家") || placeName.contains("屋") || placeName.contains("公寓") || placeName.contains("住宅")) {
                allActivities.firstOrNull { it.name == "居家" }?.let { return it }
            } else if (placeName.contains("公司") || placeName.contains("办公") || placeName.contains("单位") || placeName.contains("大厦")) {
                allActivities.firstOrNull { it.name == "工作" }?.let { return it }
            }
        }
        return null
    }

    private fun minutesOfDay(date: Date): Int {
        val c = Calendar.getInstance().apply { time = date }
        return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
    }
}
