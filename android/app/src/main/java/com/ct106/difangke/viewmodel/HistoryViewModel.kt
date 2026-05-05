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
    private val builder = com.ct106.difangke.service.PersistentTimelineBuilder(application)

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

    private val _activityTypes = MutableStateFlow<List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>>(emptyList())
    val activityTypes: StateFlow<List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>> = _activityTypes.asStateFlow()

    private val _allPlaces = MutableStateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>>(emptyList())
    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = _allPlaces.asStateFlow()

    val favoriteFootprints = _footprints.map { list ->
        list.filter { it.isHighlight == true }.sortedByDescending { it.startTime }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _lastDataSyncTrigger = MutableStateFlow(Date())
    val lastDataSyncTrigger: StateFlow<Date> = _lastDataSyncTrigger.asStateFlow()

    init {
        refreshData()
    }

    fun refreshData() {
        viewModelScope.launch {
            _isRefreshing.value = true
            val allFootprints = db.footprintDao().getAll()
            val allActivityTypes = db.activityTypeDao().getAll()
            val allPlaces = db.placeDao().getAll()
            
            _footprints.value = allFootprints
            _activityTypes.value = allActivityTypes
            _allPlaces.value = allPlaces
            
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
                    
                    val icons = buildTimelineIcons(timelineItems, allActivityTypes)

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

    fun rebuildTimeline(date: Date) {
        viewModelScope.launch {
            _isRefreshing.value = true
            builder.rebuildDay(date)
            refreshData()
            _isRefreshing.value = false
            _lastDataSyncTrigger.value = Date()
        }
    }

    private fun buildTimelineIcons(
        items: List<TimelineItem>,
        activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>
    ): List<DaySummary.TimelineIcon> {
        val ordered = mutableListOf<DaySummary.TimelineIcon>()
        val positions = mutableMapOf<String, Int>()
        val activityTypeById = activityTypes.associateBy { it.id }

        items
            .sortedBy { it.startTime }
            .forEach { item ->
                val isTransport = item is TimelineItem.TransportItem
                val isHighlight = (item as? TimelineItem.FootprintItem)?.footprint?.isHighlight ?: false
                val icon = when (item) {
                    is TimelineItem.FootprintItem -> {
                        activityTypeById[item.footprint.activityTypeValue]?.icon ?: "place"
                    }
                    is TimelineItem.TransportItem -> "directions_bus"
                }
                val colorHex = when (item) {
                    is TimelineItem.FootprintItem -> {
                        activityTypeById[item.footprint.activityTypeValue]?.colorHex ?: "#00A0AC"
                    }
                    is TimelineItem.TransportItem -> "#8E8E93"
                }
                val key = "$icon|$isTransport"
                val existingIndex = positions[key]

                if (existingIndex == null) {
                    positions[key] = ordered.size
                    ordered += DaySummary.TimelineIcon(
                        icon = icon,
                        colorHex = colorHex,
                        isTransport = isTransport,
                        isHighlight = isHighlight
                    )
                } else if (isHighlight && !ordered[existingIndex].isHighlight) {
                    ordered[existingIndex] = ordered[existingIndex].copy(isHighlight = true)
                }
            }

        return ordered.take(10)
    }
}
