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
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.ct106.difangke.data.location.RawLocationStore

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
    
    private fun zeroTime(date: Date): Date {
        val cal = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return cal.time
    }

    val availableDates: StateFlow<List<Date>> = db.footprintDao().observeAvailableDates()
        .map { dateStrings ->
            val dates: MutableSet<Date> = dateStrings.mapNotNull { 
                try { sdf.parse(it)?.let { d -> zeroTime(d) } } catch(e: Exception) { null } 
            }.toMutableSet()
            
            val today = zeroTime(Date())
            val tomorrow = Calendar.getInstance().apply {
                time = today
                add(Calendar.DAY_OF_YEAR, 1)
            }.time.let { zeroTime(it) }
            
            dates.add(today)
            dates.add(tomorrow)

            // 核心修复：始终保证有一个历史前的页，用于引导
            val earliestBase = dates.minByOrNull { it.time } ?: today
            val beforeEarliest = Calendar.getInstance().apply {
                time = earliestBase
                add(Calendar.DAY_OF_YEAR, -1)
            }.time.let { zeroTime(it) }
            
            dates.add(beforeEarliest)

            dates.toList().sortedBy { it.time }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), listOf(zeroTime(Calendar.getInstance().time)))

    @OptIn(ExperimentalCoroutinesApi::class)
    val timelineItems: StateFlow<List<TimelineItem>> = _currentDate.flatMapLatest { date ->
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        combine(
            db.footprintDao().observeBetween(start, end),
            db.transportRecordDao().observeForDay(start, end)
        ) { fps, tps ->
            (fps.map { TimelineItem.FootprintItem(it) } + tps.map { TimelineItem.TransportItem(it) })
                .sortedByDescending { it.startTime }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    @OptIn(ExperimentalCoroutinesApi::class)
    val dailyInsight: StateFlow<DailyInsightEntity?> = _currentDate.flatMapLatest { date ->
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        db.dailyInsightDao().observeForDay(start, end)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    @OptIn(ExperimentalCoroutinesApi::class)
    val totalMileage: StateFlow<Double> = _currentDate.flatMapLatest { date ->
        flow {
            val store = RawLocationStore.getInstance(getApplication())
            emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
            
            val isToday = zeroTime(Date()).time == zeroTime(date).time
            if (isToday) {
                LocationTrackingService.stateFlow.collect {
                    emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
                }
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0.0)

    @OptIn(ExperimentalCoroutinesApi::class)
    val totalPoints: StateFlow<Int> = _currentDate.flatMapLatest { date ->
        flow {
            val store = RawLocationStore.getInstance(getApplication())
            emit(withContext(Dispatchers.IO) { store.getTotalPointsCount(date) })
            
            val isToday = zeroTime(Date()).time == zeroTime(date).time
            if (isToday) {
                LocationTrackingService.stateFlow.collect {
                    emit(withContext(Dispatchers.IO) { store.getTotalPointsCount(date) })
                }
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val activityTypes: StateFlow<List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>> = db.activityTypeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _dailyTrajectory = MutableStateFlow<String?>(null)
    val dailyTrajectory: StateFlow<String?> = _dailyTrajectory.asStateFlow()

    private val _dailyMarkers = MutableStateFlow<String?>(null)
    val dailyMarkers: StateFlow<String?> = _dailyMarkers.asStateFlow()

    val trackingState = LocationTrackingService.stateFlow

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()
    
    // 获取指定日期的足迹/交通项流
    fun getTimelineItems(date: Date): Flow<List<TimelineItem>> {
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        return combine(
            db.footprintDao().observeBetween(start, end),
            db.transportRecordDao().observeForDay(start, end)
        ) { fps, tps ->
            (fps.map { TimelineItem.FootprintItem(it) } + tps.map { TimelineItem.TransportItem(it) })
                .sortedByDescending { it.startTime }
        }
    }

    // 获取指定日期的每日洞察
    fun getDailyInsight(date: Date): Flow<DailyInsightEntity?> {
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        return db.dailyInsightDao().observeForDay(start, end)
    }

    // 获取指定日期的轨迹 (JSON 字符串)
    fun getDailyTrajectory(date: Date): Flow<String?> {
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time

        val trajectoryFlow = combine(
            db.footprintDao().observeBetween(start, end),
            db.transportRecordDao().observeForDay(start, end)
        ) { footprints, transports ->
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
                    val array = org.json.JSONArray(tp.pointsJson)
                    for (i in 0 until array.length()) {
                        val element = array.get(i)
                        if (element is org.json.JSONArray) {
                            val v1 = element.getDouble(0)
                            val v2 = element.getDouble(1)
                            if (Math.abs(v1) > 90.0) allPointsList.add(listOf(v2, v1)) else allPointsList.add(listOf(v1, v2))
                        } else if (element is org.json.JSONObject) {
                            val lat = element.optDouble("lat", element.optDouble("latitude", Double.NaN))
                            val lon = element.optDouble("lon", element.optDouble("longitude", Double.NaN))
                            if (!lat.isNaN() && !lon.isNaN()) allPointsList.add(listOf(lat, lon))
                        }
                    }
                } catch (e: Exception) {}
            }
            if (allPointsList.isNotEmpty()) {
                val array = org.json.JSONArray()
                allPointsList.forEach { p ->
                    val pArr = org.json.JSONArray().put(p[0]).put(p[1])
                    array.put(pArr)
                }
                array.toString()
            } else null
        }

        // 如果是今天，额外与实时定位合并
        return if (isToday(date)) {
            combine(trajectoryFlow, LocationTrackingService.stateFlow) { traj, _ -> traj }
        } else {
            trajectoryFlow
        }
    }

    // 获取指定日期的标记点 (JSON 字符串)
    fun getDailyMarkers(date: Date): Flow<String?> {
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time

        return db.footprintDao().observeBetween(start, end).map { footprints ->
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
                array.toString()
            } else null
        }
    }

    // 获取指定日期的里程
    fun getMileage(date: Date): Flow<Double> {
        return flow {
            val store = RawLocationStore.getInstance(getApplication())
            emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
            
            // 只有今天需要实时刷新
            if (isToday(date)) {
                trackingState.collect {
                    emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
                }
            }
        }
    }

    // 获取指定日期的点数
    fun getPointsCount(date: Date): Flow<Int> {
        return flow {
            val store = RawLocationStore.getInstance(getApplication())
            emit(withContext(Dispatchers.IO) { store.getTotalPointsCount(date) })
            
            if (isToday(date)) {
                trackingState.collect {
                    emit(withContext(Dispatchers.IO) { store.getTotalPointsCount(date) })
                }
            }
        }
    }

    private fun isToday(date: Date): Boolean {
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
        return zeroTime(date).time == today.time
    }

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
        val zeroed = zeroTime(date)
        if (_currentDate.value.time != zeroed.time) {
            _currentDate.value = zeroed
            loadDataForDate(zeroed)
        }
    }

    fun loadDataForDate(date: Date) {
        viewModelScope.launch {
            // 清理旧数据
            _dailyTrajectory.value = null
            _dailyMarkers.value = null

            val startOfDay = zeroTime(date)
            val cal = Calendar.getInstance().apply {
                time = startOfDay
                add(Calendar.DAY_OF_YEAR, 1)
            }
            val endOfDay = cal.time

            // 1. 获取足迹
            val footprints = db.footprintDao().getBetween(startOfDay, endOfDay)
            
            // 2. 获取交通记录
            val transports = db.transportRecordDao().getForDay(startOfDay, endOfDay)

            // 不需要手动计算统计数据，Flow 自动处理

            // 不需要手动更新 DailyInsight，Flow 自动处理

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
                    val array = org.json.JSONArray(tp.pointsJson)
                    for (i in 0 until array.length()) {
                        val element = array.get(i)
                        if (element is org.json.JSONArray) {
                            val v1 = element.getDouble(0)
                            val v2 = element.getDouble(1)
                            if (Math.abs(v1) > 90.0) allPointsList.add(listOf(v2, v1)) else allPointsList.add(listOf(v1, v2))
                        } else if (element is org.json.JSONObject) {
                            val lat = element.optDouble("lat", element.optDouble("latitude", Double.NaN))
                            val lon = element.optDouble("lon", element.optDouble("longitude", Double.NaN))
                            if (!lat.isNaN() && !lon.isNaN()) allPointsList.add(listOf(lat, lon))
                        }
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
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isRefreshing.value = true
            loadDataForDate(_currentDate.value)
            _isRefreshing.value = false
        }
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
