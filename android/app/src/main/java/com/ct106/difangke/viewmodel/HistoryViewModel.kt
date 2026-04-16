package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import com.ct106.difangke.data.model.DaySummary
import com.ct106.difangke.data.model.TimelineItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.ct106.difangke.data.location.RawLocationStore

class HistoryViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared

    private val _footprints = MutableStateFlow<List<FootprintEntity>>(emptyList())
    
    // 按天分组的足迹
    val groupedFootprints = _footprints.map { list ->
        list.groupBy { fp ->
            val cal = Calendar.getInstance()
            cal.time = fp.startTime
            cal.set(Calendar.HOUR_OF_DAY, 0)
            cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            cal.time
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val _summaries = MutableStateFlow<Map<Date, DaySummary>>(emptyMap())
    val summaries: StateFlow<Map<Date, DaySummary>> = _summaries.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    init {
        refreshData()
    }

    fun refreshData() {
        viewModelScope.launch {
            _isRefreshing.value = true
            val allFootprints = db.footprintDao().getAll()
            _footprints.value = allFootprints
            
            // 计算总结数据 (耗时操作移至 IO 线程)
            withContext(Dispatchers.IO) {
                val grouped = allFootprints.groupBy { fp ->
                    Calendar.getInstance().apply {
                        time = fp.startTime
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }.time
                }
                
                val summaryMap = mutableMapOf<Date, DaySummary>()
                grouped.forEach { (date, fps) ->
                    val endOfDay = Calendar.getInstance().apply { time = date; add(Calendar.DATE, 1) }.time
                    val transports = db.transportRecordDao().getForDay(date, endOfDay)
                    
                    val timelineItems = (fps.map { TimelineItem.FootprintItem(it) } + 
                                       transports.map { TimelineItem.TransportItem(it) })
                                       .sortedByDescending { it.startTime }
                    
                    val store = RawLocationStore.getInstance(getApplication())
                    val totalMileage = store.calculateTotalDistance(date)
                    val totalPoints = store.getTotalPointsCount(date)
                    
                    val icons = timelineItems.take(10).map { item ->
                        DaySummary.TimelineIcon(
                            icon = when(item) {
                                is TimelineItem.FootprintItem -> item.footprint.activityTypeValue ?: "place"
                                is TimelineItem.TransportItem -> "directions_bus"
                            },
                            colorHex = "#00A0AC", // 默认 brand color
                            isTransport = item is TimelineItem.TransportItem,
                            isHighlight = (item as? TimelineItem.FootprintItem)?.footprint?.isHighlight ?: false
                        )
                    }

                    summaryMap[date] = DaySummary(
                        date = date,
                        totalDuration = fps.sumOf { it.duration },
                        footprintCount = fps.size,
                        highlightCount = fps.count { it.isHighlight == true },
                        highlightTitle = fps.firstOrNull { it.isHighlight == true }?.title,
                        hasConfirmed = fps.any { it.aiAnalyzed },
                        hasCandidate = fps.any { !it.aiAnalyzed },
                        timelineIcons = icons,
                        trajectoryCount = totalPoints,
                        mileage = totalMileage
                    )
                }
                _summaries.value = summaryMap
            }
            _isRefreshing.value = false
        }
    }

    fun deleteFootprint(footprint: FootprintEntity) {
        viewModelScope.launch {
            db.footprintDao().delete(footprint)
            refreshData()
        }
    }
}
