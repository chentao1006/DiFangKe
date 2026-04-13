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
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared

    private val _currentDate = MutableStateFlow(Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.time)
    val currentDate: StateFlow<Date> = _currentDate.asStateFlow()

    private val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.CHINA)
    
    val availableDates: StateFlow<List<Date>> = combine(
        db.footprintDao().observeAvailableDates(),
        _currentDate
    ) { dateStrings, current ->
        val dates: MutableList<java.util.Date> = dateStrings.mapNotNull { 
            try { sdf.parse(it) } catch(e: Exception) { null } 
        }.toMutableList()
        
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
        val tomorrow = Calendar.getInstance().apply {
            time = today
            add(Calendar.DAY_OF_YEAR, 1)
        }.time
        
        if (dates.none { it.time == today.time }) dates.add(today)
        if (dates.none { it.time == tomorrow.time }) dates.add(tomorrow)
        if (dates.none { it.time == current.time }) dates.add(current)
        
        dates.sortedBy { it.time }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), listOf(_currentDate.value))

    private val _timelineItems = MutableStateFlow<List<TimelineItem>>(emptyList())
    val timelineItems: StateFlow<List<TimelineItem>> = _timelineItems.asStateFlow()

    private val _dailyInsight = MutableStateFlow<DailyInsightEntity?>(null)
    val dailyInsight: StateFlow<DailyInsightEntity?> = _dailyInsight.asStateFlow()

    private val _totalMileage = MutableStateFlow(0.0)
    val totalMileage: StateFlow<Double> = _totalMileage.asStateFlow()

    private val _totalPoints = MutableStateFlow(0)
    val totalPoints: StateFlow<Int> = _totalPoints.asStateFlow()

    private val _dailyTrajectory = MutableStateFlow<String?>(null)
    val dailyTrajectory: StateFlow<String?> = _dailyTrajectory.asStateFlow()

    private val _dailyMarkers = MutableStateFlow<String?>(null)
    val dailyMarkers: StateFlow<String?> = _dailyMarkers.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    val trackingState = LocationTrackingService.stateFlow
    
    val hasSwiped: Flow<Boolean> = DiFangKeApp.instance.preferences.hasSwiped

    init {
        loadDataForDate(Date())
        observeTrackingPreference()
    }

    private fun observeTrackingPreference() {
        viewModelScope.launch {
            DiFangKeApp.instance.preferences.isTrackingEnabled
                .collectLatest { enabled ->
                    if (enabled) {
                        // 检查权限并启动服务
                        val context = getApplication<Application>()
                        if (hasLocationPermissions(context)) {
                            LocationTrackingService.start(context)
                        }
                    } else {
                        LocationTrackingService.stop(getApplication())
                    }
                }
        }
    }

    private fun hasLocationPermissions(context: android.content.Context): Boolean {
        val fine = androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val background = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_BACKGROUND_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else true
        return fine && background
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
            val items = (footprints.map { TimelineItem.FootprintItem(it) } + 
                                transports.map { TimelineItem.TransportItem(it) })
                                .sortedByDescending { it.startTime }
            _timelineItems.value = items

            // 计算统计数据
            _totalMileage.value = transports.sumOf { it.distance }
            _totalPoints.value = footprints.sumOf { fp ->
                try {
                    val latArray = org.json.JSONArray(fp.latitudeJson)
                    latArray.length()
                } catch (e: Exception) { 0 }
            }

            // 4. 获取总结
            _dailyInsight.value = db.dailyInsightDao().getForDay(startOfDay, endOfDay)

            // 5. 聚合轨迹点
            val allPointsList = mutableListOf<List<Double>>()
            footprints.forEach { fp ->
                try {
                    val lats = org.json.JSONArray(fp.latitudeJson)
                    val lons = org.json.JSONArray(fp.longitudeJson)
                    for (i in 0 until minOf(lats.length(), lons.length())) {
                        allPointsList.add(listOf(lats.getDouble(i), lons.getDouble(i)))
                    }
                } catch (e: Exception) {}
            }
            transports.forEach { tp ->
                try {
                    val pts = org.json.JSONArray(tp.pointsJson)
                    for (i in 0 until pts.length()) {
                        val p = pts.getJSONArray(i)
                        allPointsList.add(listOf(p.getDouble(0), p.getDouble(1)))
                    }
                } catch (e: Exception) {}
            }
            if (allPointsList.isNotEmpty()) {
                val array = org.json.JSONArray()
                allPointsList.forEach { p ->
                    val pArr = org.json.JSONArray().put(p[0]).put(p[1])
                    array.put(pArr)
                }
                _dailyTrajectory.value = array.toString()
            } else {
                _dailyTrajectory.value = null
            }

            // 6. 聚合足迹中心点以便在大/小地图显示标记
            val markersList = mutableListOf<List<Double>>()
            footprints.forEach { fp ->
                try {
                    val lats = org.json.JSONArray(fp.latitudeJson)
                    val lons = org.json.JSONArray(fp.longitudeJson)
                    if (lats.length() > 0 && lons.length() > 0) {
                        markersList.add(listOf(lats.getDouble(0), lons.getDouble(0)))
                    }
                } catch (e: Exception) {}
            }
            if (markersList.isNotEmpty()) {
                val array = org.json.JSONArray()
                markersList.forEach { m ->
                    val mArr = org.json.JSONArray().put(m[0]).put(m[1])
                    array.put(mArr)
                }
                _dailyMarkers.value = array.toString()
            } else {
                _dailyMarkers.value = null
            }

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
        viewModelScope.launch {
            val prefs = DiFangKeApp.instance.preferences
            val currentState = trackingState.value != LocationTrackingService.TrackingState.Idle
            prefs.setTrackingEnabled(!currentState)
        }
    }

    fun markHasSwiped() {
        viewModelScope.launch {
            DiFangKeApp.instance.preferences.setHasSwiped(true)
        }
    }
}
