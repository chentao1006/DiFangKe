package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.DailyInsightEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.*

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared

    private val _currentDate = MutableStateFlow(Date())
    val currentDate: StateFlow<Date> = _currentDate.asStateFlow()

    private val _timelineItems = MutableStateFlow<List<TimelineItem>>(emptyList())
    val timelineItems: StateFlow<List<TimelineItem>> = _timelineItems.asStateFlow()

    private val _dailyInsight = MutableStateFlow<DailyInsightEntity?>(null)
    val dailyInsight: StateFlow<DailyInsightEntity?> = _dailyInsight.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    val trackingState = LocationTrackingService.stateFlow

    init {
        loadDataForDate(Date())
    }

    fun setDate(date: Date) {
        _currentDate.value = date
        loadDataForDate(date)
    }

    fun loadDataForDate(date: Date) {
        viewModelScope.launch {
            val cal = Calendar.getInstance().apply {
                time = date
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val startOfDay = cal.time
            cal.add(Calendar.DAY_OF_YEAR, 1)
            val endOfDay = cal.time

            // 1. 获取足迹
            val footprints = db.footprintDao().getBetween(startOfDay, endOfDay)
            
            // 2. 获取交通记录
            val transports = db.transportRecordDao().getForDay(startOfDay, endOfDay)

            // 3. 合并排序
            val items = mutableListOf<TimelineItem>()
            items.addAll(footprints.map { TimelineItem.FootprintItem(it) })
            
            // TODO: 这里需要将 TransportRecord 转换为业务模型 Transport
            // 为了简化先转换为 TransportItem

            items.sortBy { it.startTime }
            _timelineItems.value = items

            // 4. 获取总结
            _dailyInsight.value = db.dailyInsightDao().getForDay(startOfDay, endOfDay)

            // 发起 AI 分析任务
            triggerAiAnalysis(footprints, transports, startOfDay)
        }
    }

    private fun triggerAiAnalysis(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        date: Date
    ) {
        viewModelScope.launch {
            // 对未分析的足迹进行单独分析
            footprints.filter { !it.aiAnalyzed }.forEach { fp ->
                openAI.analyzeFootprint(fp)
            }

            // 如果是今天或强制，生成每日摘要
            openAI.generateDailySummary(date, footprints, transports)
            
            // 重新加载数据刷新 UI
            val cal = Calendar.getInstance().apply {
                time = date
                add(Calendar.DAY_OF_YEAR, 1)
            }
            _dailyInsight.value = db.dailyInsightDao().getForDay(date, cal.time)
        }
    }

    fun refresh() {
        _isRefreshing.value = true
        loadDataForDate(_currentDate.value)
        _isRefreshing.value = false
    }

    fun toggleTracking() {
        val context = getApplication<Application>()
        if (trackingState.value == LocationTrackingService.TrackingState.Idle) {
            LocationTrackingService.start(context)
        } else {
            LocationTrackingService.stop(context)
        }
    }
}
