package com.ct106.difangke.ui.screens.statistics

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.util.*
import kotlin.math.roundToInt

sealed class StatisticsRange(val label: String, val days: Int?) {
    object LAST_7_DAYS : StatisticsRange("7天", 7)
    object LAST_30_DAYS : StatisticsRange("30天", 30)
    object LAST_90_DAYS : StatisticsRange("90天", 90)
    object LAST_YEAR : StatisticsRange("1年", 365)
    class CUSTOM_YEAR(val year: Int) : StatisticsRange("$year", null)
    object ALL : StatisticsRange("全部", null)

    companion object {
        fun values(): List<StatisticsRange> = listOf(LAST_7_DAYS, LAST_30_DAYS, LAST_90_DAYS, LAST_YEAR, ALL)
    }
}

data class HeatmapPoint(val lat: Double, val lon: Double, val count: Int)
data class ActivityRankItem(val name: String, val count: Int, val colorHex: String, val icon: String)
data class TrendPoint(val date: Date, val score: Double)

class StatisticsViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    
    private val _selectedRange = MutableStateFlow<StatisticsRange>(StatisticsRange.LAST_30_DAYS)
    val selectedRange: StateFlow<StatisticsRange> = _selectedRange.asStateFlow()

    private val _heatmapPoints = MutableStateFlow<List<HeatmapPoint>>(emptyList())
    val heatmapPoints: StateFlow<List<HeatmapPoint>> = _heatmapPoints.asStateFlow()

    private val _activityRank = MutableStateFlow<List<ActivityRankItem>>(emptyList())
    val activityRank: StateFlow<List<ActivityRankItem>> = _activityRank.asStateFlow()

    private val _trendData = MutableStateFlow<List<TrendPoint>>(emptyList())
    val trendData: StateFlow<List<TrendPoint>> = _trendData.asStateFlow()

    private val _aiSummary = MutableStateFlow<String?>(null)
    val aiSummary: StateFlow<String?> = _aiSummary.asStateFlow()

    private val _isGeneratingSummary = MutableStateFlow(false)
    val isGeneratingSummary: StateFlow<Boolean> = _isGeneratingSummary.asStateFlow()

    init {
        selectedRange.onEach { refreshData() }.launchIn(viewModelScope)
    }

    fun setRange(range: StatisticsRange) {
        _selectedRange.value = range
    }

    private fun refreshData() {
        viewModelScope.launch {
            val range = _selectedRange.value
            val now = Calendar.getInstance().time
            
            val allFootprints = db.footprintDao().getAll().filter { it.statusValue != "ignored" }
            val cutoffDate = range.days?.let {
                val cal = Calendar.getInstance()
                cal.time = now
                cal.add(Calendar.DAY_OF_YEAR, -it)
                cal.time
            }

            val filteredFootprints = when (range) {
                is StatisticsRange.CUSTOM_YEAR -> {
                    allFootprints.filter { fp ->
                        val cal = Calendar.getInstance().apply { time = fp.startTime }
                        cal.get(Calendar.YEAR) == range.year
                    }
                }
                else -> {
                    if (cutoffDate != null) {
                        allFootprints.filter { it.startTime >= cutoffDate }
                    } else {
                        allFootprints
                    }
                }
            }

            val activityTypes = db.activityTypeDao().getAll()
            val transportRecords = db.transportRecordDao().getAllSync().filter { it.statusRaw != "ignored" }
            val filteredTransports = when (range) {
                is StatisticsRange.CUSTOM_YEAR -> {
                    transportRecords.filter { t ->
                        val cal = Calendar.getInstance().apply { time = t.startTime }
                        cal.get(Calendar.YEAR) == range.year
                    }
                }
                else -> {
                    if (cutoffDate != null) {
                        transportRecords.filter { it.startTime >= cutoffDate }
                    } else {
                        transportRecords
                    }
                }
            }

            // 1. Heatmap Calculation
            _heatmapPoints.value = calculateHeatmap(filteredFootprints)

            // 2. Activity Rank
            _activityRank.value = calculateActivityRank(filteredFootprints, filteredTransports, activityTypes)

            // 3. Trend Data
            _trendData.value = calculateTrend(filteredFootprints, range.days ?: 90)

            // 4. AI Summary
            checkAiSummaryCacheOrGenerate(filteredFootprints, range)
        }
    }

    private fun checkAiSummaryCacheOrGenerate(footprints: List<FootprintEntity>, range: StatisticsRange) {
        val sp = getApplication<Application>().getSharedPreferences("statistics_ai_cache", Context.MODE_PRIVATE)
        val cacheKey = range.label
        val cachedText = sp.getString("${cacheKey}_text", null)
        val cachedTime = sp.getLong("${cacheKey}_time", 0L)

        if (cachedText != null && cachedTime > 0L) {
            val expiration = getExpirationFor(range)
            if (System.currentTimeMillis() - cachedTime < expiration) {
                _aiSummary.value = cachedText
                return
            }
        }

        generateAiSummary(footprints, range)
    }

    private fun getExpirationFor(range: StatisticsRange): Long {
        val hour = 3600 * 1000L
        val day = 24 * hour
        return when (range) {
            StatisticsRange.LAST_7_DAYS -> 1 * day
            StatisticsRange.LAST_30_DAYS -> 3 * day
            StatisticsRange.LAST_90_DAYS -> 7 * day
            is StatisticsRange.CUSTOM_YEAR -> 30 * day
            StatisticsRange.LAST_YEAR -> 30 * day
            StatisticsRange.ALL -> 90 * day
            else -> 1 * day
        }
    }

    private fun generateAiSummary(footprints: List<FootprintEntity>, range: StatisticsRange) {
        viewModelScope.launch {
            val isAiEnabled = DiFangKeApp.instance.preferences.isAiEnabled.first()
            if (!isAiEnabled || footprints.isEmpty()) {
                _aiSummary.value = null
                return@launch
            }

            _isGeneratingSummary.value = true
            _aiSummary.value = null

            val rankData = calculateActivityRank(footprints, emptyList(), emptyList())
                .take(3).joinToString(", ") { "${it.name}(${it.count}次)" }
            
            val totalDurationHours = footprints.sumOf { it.endTime.time - it.startTime.time }.toDouble() / 3600000.0
            
            val prompt = """
                请作为一位睿智的生活观察者，对用户在过去“${range.label}”的足迹数据进行一次有深度且清晰的总结。
                
                数据概览：
                - 记录密度：${footprints.size}个生活片段，累计活跃时长约${totalDurationHours.toInt()}小时
                - 活动重心：$rankData
                
                要求：
                1. 语气：客观睿智、理感平衡。不要过于文艺或晦涩。
                2. 洞察：总结出这段时间潜藏的“生活逻辑”或“情感底色”。
                3. 篇幅：80字左右。
            """.trimIndent()

            val summary = OpenAIService.shared.getCustomSummary(prompt)
            val finalized = summary ?: "这段时间，你的生活步调稳健而有序。"
            _aiSummary.value = finalized
            _isGeneratingSummary.value = false

            // Cache it
            val sp = getApplication<Application>().getSharedPreferences("statistics_ai_cache", Context.MODE_PRIVATE)
            sp.edit()
                .putString("${range.label}_text", finalized)
                .putLong("${range.label}_time", System.currentTimeMillis())
                .apply()
        }
    }

    private fun calculateHeatmap(footprints: List<FootprintEntity>): List<HeatmapPoint> {
        val groups = mutableMapOf<String, Int>()
        val factor = 1000.0 // 提高采样精度
        
        footprints.forEach { fp ->
            try {
                val lats = JSONArray(fp.latitudeJson)
                val lons = JSONArray(fp.longitudeJson)
                val len = minOf(lats.length(), lons.length())
                
                // 采集所有坐标点，而非仅第一个
                for (i in 0 until len) {
                    val latRaw = lats.getDouble(i)
                    val lonRaw = lons.getDouble(i)
                    
                    // 聚合点以提高性能和视觉效果
                    val lat = (latRaw * factor).roundToInt() / factor
                    val lon = (lonRaw * factor).roundToInt() / factor
                    val key = "$lat,$lon"
                    groups[key] = (groups[key] ?: 0) + 1
                }
            } catch (e: Exception) {}
        }

        return groups.map { (key, count) ->
            val parts = key.split(",")
            HeatmapPoint(parts[0].toDouble(), parts[1].toDouble(), count)
        }.sortedByDescending { it.count }.take(500)
    }

    private fun calculateActivityRank(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        activityTypes: List<ActivityTypeEntity>
    ): List<ActivityRankItem> {
        val counts = mutableMapOf<String, Int>()
        
        footprints.forEach { fp ->
            val type = activityTypes.find { it.id == fp.activityTypeValue }?.name ?: "自定义"
            counts[type] = (counts[type] ?: 0) + 1
        }
        
        transports.forEach { t ->
            val type = when(t.typeRaw) {
                "slow" -> "步行"
                "running" -> "跑步"
                "bicycle" -> "骑行"
                "car" -> "自驾"
                "bus" -> "公交"
                "subway" -> "地铁"
                "train" -> "火车"
                "airplane" -> "飞行"
                else -> "交通"
            }
            counts[type] = (counts[type] ?: 0) + 1
        }

        return counts.map { (name, count) ->
            val act = activityTypes.find { it.name == name }
            ActivityRankItem(
                name = name,
                count = count,
                colorHex = act?.colorHex ?: "#8E8E93",
                icon = act?.icon ?: "mappin"
            )
        }.sortedByDescending { it.count }
    }

    private fun calculateTrend(footprints: List<FootprintEntity>, daysInScope: Int): List<TrendPoint> {
        val now = Calendar.getInstance()
        now.set(Calendar.HOUR_OF_DAY, 0)
        now.set(Calendar.MINUTE, 0)
        now.set(Calendar.SECOND, 0)
        now.set(Calendar.MILLISECOND, 0)
        
        val groupedMap = footprints.groupBy { 
            val cal = Calendar.getInstance()
            cal.time = it.startTime
            cal.set(Calendar.HOUR_OF_DAY, 0)
            cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            cal.time.time
        }

        val result = mutableListOf<TrendPoint>()
        for (i in (daysInScope - 1) downTo 0) {
            val cal = Calendar.getInstance()
            cal.time = now.time
            cal.add(Calendar.DAY_OF_YEAR, -i)
            val d = cal.time
            val dayFootprints = groupedMap[d.time] ?: emptyList()
            
            val uniqueTypes = dayFootprints.map { it.activityTypeValue }.distinct().size
            val score = dayFootprints.size * 10.0 + uniqueTypes * 15.0
            result.add(TrendPoint(d, score))
        }
        return result
    }
}
