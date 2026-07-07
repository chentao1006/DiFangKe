package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.DailyInsightEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.FutureTripEntity
import com.ct106.difangke.data.db.entity.FutureTripScheduleMode
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.data.model.representativeLatitude
import com.ct106.difangke.data.model.representativeLongitude
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.service.OpenAIService
import com.ct106.difangke.service.FutureTripReminderWorker
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.ct106.difangke.data.location.RawLocationStore
import com.aptabase.Aptabase

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared
    private val builder = com.ct106.difangke.service.PersistentTimelineBuilder(application)
    private val autoRebuildDatesInFlight = mutableSetOf<Long>()

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

    val availableDates: StateFlow<List<Date>> = combine(
        db.footprintDao().observeAvailableDates(),
        db.futureTripDao().observeAvailableDates()
    ) { footprintDates, tripDates ->
            val dates: MutableSet<Date> = (footprintDates + tripDates).mapNotNull {
                try { sdf.parse(it)?.let { d -> zeroTime(d) } } catch(e: Exception) { null }
            }.toMutableSet()
            
            val today = zeroTime(Date())
            dates.add(today)

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
            db.transportRecordDao().observeForDay(start, end),
            db.futureTripDao().observeForDay(start, end)
        ) { fps, tps, trips ->
            // 足迹的时间范围要限制在0点到次日0点：裁切跨天记录
            val boundedFps = fps.map { fp ->
                val bStart = if (fp.startTime.before(start)) start else fp.startTime
                val bEnd = if (fp.endTime.after(end)) end else fp.endTime
                if (bStart != fp.startTime || bEnd != fp.endTime) {
                    fp.copy(startTime = bStart, endTime = bEnd)
                } else fp
            }
            val boundedTps = tps.map { tp ->
                val bStart = if (tp.startTime.before(start)) start else tp.startTime
                val bEnd = if (tp.endTime.after(end)) end else tp.endTime
                if (bStart != tp.startTime || bEnd != tp.endTime) {
                    tp.copy(startTime = bStart, endTime = bEnd)
                } else tp
            }

            mergeTimelineItems(boundedFps, boundedTps, trips)
        }.flowOn(Dispatchers.Default)
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
    val isTrackingEnabled: StateFlow<Boolean> = DiFangKeApp.instance.preferences.isTrackingEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    private val _lastDataSyncTrigger = MutableStateFlow(Date())
    val lastDataSyncTrigger: StateFlow<Date> = _lastDataSyncTrigger.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    // ── 缓存策略：使用 Map 存储各日期的 StateFlow，避免切换/返回页面时由于 collectAsState(initial=null) 导致的重载闪烁 ─────
    private val timelineCache = mutableMapOf<Long, StateFlow<List<TimelineItem>>>()
    private val trajectoryCache = mutableMapOf<Long, StateFlow<String?>>()
    private val markersCache = mutableMapOf<Long, StateFlow<String?>>()
    private val insightCache = mutableMapOf<Long, StateFlow<DailyInsightEntity?>>()
    
    // 获取指定日期的足迹/交通项流
    fun getTimelineItems(date: Date): Flow<List<TimelineItem>> {
        val dateMs = zeroTime(date).time
        return timelineCache.getOrPut(dateMs) {
            val start = zeroTime(date)
            val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
            combine(
                db.footprintDao().observeBetween(start, end),
                db.transportRecordDao().observeForDay(start, end),
                db.futureTripDao().observeForDay(start, end)
            ) { fps, tps, trips ->
                val visibleFps = fps.filter { it.statusValue != "ignored" }
                
                // 足迹的时间范围要限制在0点到次日0点：裁切跨天记录
                val boundedFps = visibleFps.map { fp ->
                    val bStart = if (fp.startTime.before(start)) start else fp.startTime
                    val bEnd = if (fp.endTime.after(end)) end else fp.endTime
                    if (bStart != fp.startTime || bEnd != fp.endTime) {
                        fp.copy(startTime = bStart, endTime = bEnd)
                    } else fp
                }
                val boundedTps = tps.map { tp ->
                    val bStart = if (tp.startTime.before(start)) start else tp.startTime
                    val bEnd = if (tp.endTime.after(end)) end else tp.endTime
                    if (bStart != tp.startTime || bEnd != tp.endTime) {
                        tp.copy(startTime = bStart, endTime = bEnd)
                    } else tp
                }

                val rawItems = mergeTimelineItems(boundedFps, boundedTps, trips)
                
                alignTransportItems(rawItems, boundedFps)
            }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
        }
    }

    // 获取指定日期的每日洞察
    fun getDailyInsight(date: Date): Flow<DailyInsightEntity?> {
        val dateMs = zeroTime(date).time
        return insightCache.getOrPut(dateMs) {
            val start = zeroTime(date)
            val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
            db.dailyInsightDao().observeForDay(start, end)
                .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
        }
    }

    // 获取指定日期的轨迹 (JSON 字符串)
    fun getDailyTrajectory(date: Date): Flow<String?> {
        val dateMs = zeroTime(date).time
        return trajectoryCache.getOrPut(dateMs) {
            val start = zeroTime(date)
            val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time

            val trajectoryFlow = combine(
                db.footprintDao().observeBetween(start, end),
                db.transportRecordDao().observeForDay(start, end)
            ) { footprints, transports ->
                val sb = java.lang.StringBuilder()
                sb.append("[")
                var first = true

                // 不再将足迹的漂移点加入到轨迹线中，只保留交通线

                transports.forEach { tp ->
                    kotlinx.coroutines.yield()
                    try {
                        val array = org.json.JSONArray(tp.pointsJson)
                        for (i in 0 until array.length()) {
                            val element = array.get(i)
                            if (element is org.json.JSONArray) {
                                val v1 = element.getDouble(0)
                                val v2 = element.getDouble(1)
                                if (!first) sb.append(",")
                                if (Math.abs(v1) > 90.0) sb.append("[$v2,$v1]") else sb.append("[$v1,$v2]")
                                first = false
                            } else if (element is org.json.JSONObject) {
                                val lat = element.optDouble("lat", element.optDouble("latitude", Double.NaN))
                                val lon = element.optDouble("lon", element.optDouble("longitude", Double.NaN))
                                if (!lat.isNaN() && !lon.isNaN()) {
                                    if (!first) sb.append(",")
                                    sb.append("[$lat,$lon]")
                                    first = false
                                }
                            }
                        }
                        // 插入分隔符，防止两段不相关的交通线连成一条直线
                        if (!first) sb.append(",[0.0,0.0]")
                    } catch (e: Exception) {}
                }
                sb.append("]")
                if (first) null else sb.toString()
            }

            // 如果是今天，额外与实时定位合并
            if (isToday(date)) {
                combine(trajectoryFlow, LocationTrackingService.stateFlow) { traj, _ -> traj }
                    .flowOn(Dispatchers.Default)
                    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
            } else {
                trajectoryFlow.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
            }
        }
    }

    // 获取指定日期的标记点 (JSON 字符串)
    fun getDailyMarkers(date: Date): Flow<String?> {
        val dateMs = zeroTime(date).time
        return markersCache.getOrPut(dateMs) {
            val start = zeroTime(date)
            val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time

            combine(
                db.footprintDao().observeBetween(start, end),
                db.activityTypeDao().observeAll()
            ) { footprints, activityTypes ->
                buildFootprintMarkersJson(footprints, activityTypes, start, end)
            }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
        }
    }

    // 获取指定日期的里程
    fun getMileage(date: Date): Flow<Double> {
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        
        val rawMileageFlow = flow {
            val store = RawLocationStore.getInstance(getApplication())
            emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
            
            // 只有今天需要实时刷新
            if (isToday(date)) {
                trackingState.collect {
                    emit(withContext(Dispatchers.IO) { store.calculateTotalDistance(date) })
                }
            }
        }

        return combine(rawMileageFlow, db.footprintDao().observeBetween(start, end)) { rawMileage, footprints ->
            // 如果轨迹点记录的里程非常小（如 < 50米）且存在多个足迹（可能是照片导入的），则通过足迹点估算里程
            if (rawMileage < 50.0 && footprints.size >= 2) {
                var estimatedDist = 0.0
                val sortedFps = footprints.sortedBy { it.startTime }
                val results = FloatArray(1)
                for (i in 0 until sortedFps.size - 1) {
                    android.location.Location.distanceBetween(
                        sortedFps[i].representativeLatitude, sortedFps[i].representativeLongitude,
                        sortedFps[i+1].representativeLatitude, sortedFps[i+1].representativeLongitude,
                        results
                    )
                    estimatedDist += results[0]
                }
                estimatedDist
            } else {
                rawMileage
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
        setupBroadcastReceiver()
    }

    private fun setupBroadcastReceiver() {
        val filter = android.content.IntentFilter("com.ct106.difangke.RAW_LOCATION_DATA_DELETED")
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
                val deletedDateMs = intent?.getLongExtra("date", -1L) ?: -1L
                val singleTs = intent?.getDoubleExtra("deletedTimestamp", -1.0) ?: -1.0
                val multiTs = intent?.getDoubleArrayExtra("deletedTimestamps") ?: DoubleArray(0)
                
                val timestamps = mutableListOf<Double>()
                if (singleTs != -1.0) timestamps.add(singleTs)
                timestamps.addAll(multiTs.toList())
                
                if (deletedDateMs != -1L) {
                    val deletedDate = Date(deletedDateMs)
                    viewModelScope.launch {
                        if (timestamps.isNotEmpty()) {
                            builder.repairAffectedTimeline(timestamps, deletedDate)
                        }
                        if (zeroTime(deletedDate).time == zeroTime(_currentDate.value).time) {
                            // 如果删除的是当前页面的点，触发刷新
                            refresh()
                            _lastDataSyncTrigger.value = Date()
                        }
                    }
                }
            }
        }
        getApplication<Application>().registerReceiver(receiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED)
    }

    private fun observeTrackingPreference() {
        viewModelScope.launch {
            DiFangKeApp.instance.preferences.isTrackingEnabled
                .distinctUntilChanged()
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

    fun setTrackingEnabled(enabled: Boolean) {
        viewModelScope.launch {
            DiFangKeApp.instance.preferences.setTrackingEnabled(enabled)
            if (enabled) {
                val context = getApplication<Application>()
                if (hasLocationPermissions(context)) {
                    LocationTrackingService.start(context)
                }
            } else {
                LocationTrackingService.stop(getApplication())
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

    private var loadDataJob: kotlinx.coroutines.Job? = null

    fun loadDataForDate(date: Date) {
        loadDataJob?.cancel()
        loadDataJob = viewModelScope.launch {
            // 清理旧数据
            _dailyTrajectory.value = null
            _dailyMarkers.value = null

            val startOfDay = zeroTime(date)
            val cal = Calendar.getInstance().apply {
                time = startOfDay
                add(Calendar.DAY_OF_YEAR, 1)
            }
            val endOfDay = cal.time

            withContext(Dispatchers.Default) {
                // 如果是今天，先执行一次近期足迹的合并，确保用户修改不被新的分段覆盖
                if (isToday(date)) {
                    builder.mergeRecentFootprintsForToday()
                }

                // 1. 获取足迹和交通记录 (用于传给 AI)
                val footprints = db.footprintDao().getBetween(startOfDay, endOfDay)
                val transports = db.transportRecordDao().getForDay(startOfDay, endOfDay)

                withContext(Dispatchers.Main) {
                    // 发起 AI 分析任务
                    aiAnalysisJob?.cancel()
                    aiAnalysisJob = triggerAiAnalysis(footprints, transports, startOfDay)
                }
            }
        }
    }

    private var aiAnalysisJob: kotlinx.coroutines.Job? = null

    private fun triggerAiAnalysis(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        date: Date
    ): kotlinx.coroutines.Job {
        return viewModelScope.launch {
            delay(500) // Debounce fast swiping
            if (date.time != zeroTime(_currentDate.value).time) return@launch

            // 对未分析的足迹进行单独分析
            // footprints.filter { !it.aiAnalyzed }.forEach { fp ->
            //     openAI.analyzeFootprint(fp)
            // }

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

    /** 重新生成全天数据（对应 iOS syncDay） */
    fun rebuildTimeline(date: Date) {
        Aptabase.instance.trackEvent("timeline_rebuilt")
        viewModelScope.launch {
            _isRefreshing.value = true
            builder.rebuildDay(date)
            loadDataForDate(date)
            _isRefreshing.value = false
            _lastDataSyncTrigger.value = Date()
        }
    }

    fun ensureTimelineForDate(date: Date) {
        val zeroedDate = zeroTime(date)
        val dateKey = zeroedDate.time
        if (!autoRebuildDatesInFlight.add(dateKey)) return

        viewModelScope.launch {
            try {
                val nextDay = Calendar.getInstance().apply {
                    time = zeroedDate
                    add(Calendar.DAY_OF_YEAR, 1)
                }.time

                val existingFootprints = db.footprintDao().getBetween(zeroedDate, nextDay)
                if (existingFootprints.isNotEmpty()) return@launch

                val rawStore = RawLocationStore.getInstance(getApplication())
                val rawPointCount = withContext(Dispatchers.IO) { rawStore.getTotalPointsCount(zeroedDate) }
                if (rawPointCount <= 0) return@launch

                builder.rebuildDay(zeroedDate)
                loadDataForDate(zeroedDate)
                _lastDataSyncTrigger.value = Date()
            } finally {
                autoRebuildDatesInFlight.remove(dateKey)
            }
        }
    }

    fun toggleTracking() {
        viewModelScope.launch {
            val currentState = DiFangKeApp.instance.preferences.isTrackingEnabled.first()
            setTrackingEnabled(!currentState)
        }
    }

    fun markHasSwiped() {
        viewModelScope.launch {
            DiFangKeApp.instance.preferences.setHasSwiped(true)
        }
    }

    val allFutureTripsForEditor: Flow<List<FutureTripEntity>> = db.futureTripDao().observeAll()
        .map { FutureTripEntity.dayOrdered(it) }
        .flowOn(Dispatchers.Default)

    fun saveFutureTrip(
        editingTrip: FutureTripEntity?,
        place: PlaceEntity,
        date: Date,
        hasArrivalTime: Boolean,
        hour: Int,
        minute: Int,
        insertionAnchorTripID: String?,
        activityTypeValue: String?,
        notes: String?
    ) {
        viewModelScope.launch(Dispatchers.IO) {
            val normalizedDate = normalizedFutureTripDate(date, hasArrivalTime, hour, minute)
            val previousDay = editingTrip?.let { zeroTime(it.arrivalDate) }
            val scheduleMode = if (hasArrivalTime) FutureTripScheduleMode.TIMED else FutureTripScheduleMode.ORDERED
            val trip = editingTrip?.copy(
                placeID = place.placeID,
                placeName = place.name,
                address = place.address,
                notes = notes?.trim()?.takeIf { it.isNotEmpty() },
                latitude = place.latitude,
                longitude = place.longitude,
                arrivalDate = normalizedDate,
                hasArrivalTime = hasArrivalTime,
                scheduleModeValue = scheduleMode.raw,
                activityTypeValue = activityTypeValue,
                isCompleted = false,
                completedAt = null
            ) ?: FutureTripEntity(
                placeID = place.placeID,
                placeName = place.name,
                address = place.address,
                notes = notes?.trim()?.takeIf { it.isNotEmpty() },
                latitude = place.latitude,
                longitude = place.longitude,
                arrivalDate = normalizedDate,
                hasArrivalTime = hasArrivalTime,
                scheduleModeValue = scheduleMode.raw,
                activityTypeValue = activityTypeValue
            )

            db.futureTripDao().insert(trip)
            val day = zeroTime(normalizedDate)
            if (hasArrivalTime) {
                reindexTimedTrip(day, trip)
                FutureTripReminderWorker.schedule(getApplication(), trip.tripID, trip.arrivalDate)
            } else {
                reindexDayTrips(day, trip, insertionAnchorTripID)
                FutureTripReminderWorker.cancel(getApplication(), trip.tripID)
            }
            if (previousDay != null && previousDay.time != day.time) {
                reindexDayTrips(previousDay, null, null)
            }
            _lastDataSyncTrigger.value = Date()
        }
    }

    fun completeFutureTrip(trip: FutureTripEntity) {
        viewModelScope.launch(Dispatchers.IO) {
            db.futureTripDao().update(trip.copy(isCompleted = true, completedAt = Date()))
            FutureTripReminderWorker.cancel(getApplication(), trip.tripID)
            _lastDataSyncTrigger.value = Date()
        }
    }

    fun delayFutureTrip(trip: FutureTripEntity, delayMillis: Long) {
        if (trip.isOrdered) return
        viewModelScope.launch(Dispatchers.IO) {
            val oldDay = zeroTime(trip.arrivalDate)
            val delayed = trip.copy(
                arrivalDate = Date(trip.arrivalDate.time + delayMillis),
                isCompleted = false,
                completedAt = null
            )
            db.futureTripDao().update(delayed)
            reindexTimedTrip(zeroTime(delayed.arrivalDate), delayed)
            FutureTripReminderWorker.schedule(getApplication(), delayed.tripID, delayed.arrivalDate)
            if (oldDay.time != zeroTime(delayed.arrivalDate).time) {
                reindexDayTrips(oldDay, null, null)
            }
            _lastDataSyncTrigger.value = Date()
        }
    }

    fun deleteFutureTrip(trip: FutureTripEntity) {
        viewModelScope.launch(Dispatchers.IO) {
            val day = zeroTime(trip.arrivalDate)
            db.futureTripDao().delete(trip)
            FutureTripReminderWorker.cancel(getApplication(), trip.tripID)
            reindexDayTrips(day, null, null)
            _lastDataSyncTrigger.value = Date()
        }
    }

    private suspend fun reindexDayTrips(day: Date, movingTrip: FutureTripEntity?, insertionAnchorTripID: String?) {
        val end = Calendar.getInstance().apply { time = day; add(Calendar.DAY_OF_YEAR, 1) }.time
        val trips = FutureTripEntity.dayOrdered(db.futureTripDao().getForDay(day, end))
            .filter { movingTrip == null || it.tripID != movingTrip.tripID }
            .toMutableList()
        movingTrip?.let { trip ->
            val targetIndex = when (insertionAnchorTripID) {
                "__first__" -> 0
                null, "__end__" -> trips.size
                else -> trips.indexOfFirst { it.tripID == insertionAnchorTripID }.takeIf { it >= 0 }?.plus(1) ?: trips.size
            }
            trips.add(targetIndex.coerceIn(0, trips.size), trip)
        }
        trips.forEachIndexed { index, trip ->
            if (trip.orderIndex != index + 1) {
                db.futureTripDao().update(trip.copy(orderIndex = index + 1))
            }
        }
    }

    private suspend fun reindexTimedTrip(day: Date, movingTrip: FutureTripEntity) {
        val end = Calendar.getInstance().apply { time = day; add(Calendar.DAY_OF_YEAR, 1) }.time
        val trips = FutureTripEntity.dayOrdered(db.futureTripDao().getForDay(day, end))
            .filter { it.tripID != movingTrip.tripID }
            .toMutableList()
        val sortTimes = futureTripSortTimes(trips, day)
        val targetIndex = trips.indexOfFirst { (sortTimes[it.tripID] ?: it.arrivalDate) > movingTrip.arrivalDate }
            .let { if (it >= 0) it else trips.size }
        trips.add(targetIndex, movingTrip)
        trips.forEachIndexed { index, trip ->
            if (trip.orderIndex != index + 1) {
                db.futureTripDao().update(trip.copy(orderIndex = index + 1))
            }
        }
    }

    private fun normalizedFutureTripDate(date: Date, hasArrivalTime: Boolean, hour: Int, minute: Int): Date {
        return Calendar.getInstance().apply {
            time = date
            if (hasArrivalTime) {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
            } else {
                set(Calendar.HOUR_OF_DAY, 12)
                set(Calendar.MINUTE, 0)
            }
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
    }

    private fun mergeTimelineItems(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        trips: List<FutureTripEntity>
    ): List<TimelineItem> {
        val activeTrips = trips.filter { !it.isCompleted }
        val orderedTrips = FutureTripEntity.dayOrdered(activeTrips)
        val tripSortTimes = futureTripSortTimes(orderedTrips, orderedTrips.firstOrNull()?.arrivalDate ?: Date())
        return (
            footprints.map { TimelineItem.FootprintItem(it) } +
                transports.map { TimelineItem.TransportItem(it) } +
                orderedTrips.map { TimelineItem.FutureTripItem(it) }
            ).sortedByDescending { item ->
                if (item is TimelineItem.FutureTripItem) {
                    tripSortTimes[item.trip.tripID] ?: item.trip.arrivalDate
                } else {
                    item.startTime
                }
            }
    }

    private fun futureTripSortTimes(trips: List<FutureTripEntity>, day: Date): Map<String, Date> {
        val sortTimes = mutableMapOf<String, Date>()
        var anchorTime = Calendar.getInstance().apply {
            time = zeroTime(day)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
        var orderedOffset = 1
        trips.forEach { trip ->
            if (trip.isOrdered) {
                sortTimes[trip.tripID] = Date(anchorTime.time + orderedOffset * 1000L)
                orderedOffset += 1
            } else {
                val effective = trip.effectiveArrivalDate()
                sortTimes[trip.tripID] = effective
                anchorTime = effective
                orderedOffset = 1
            }
        }
        return sortTimes
    }

    private fun alignTransportItems(items: List<TimelineItem>, visibleFps: List<com.ct106.difangke.data.db.entity.FootprintEntity>): List<TimelineItem> {
        val sortedFps = visibleFps.sortedBy { it.startTime }
        
        return items.map { item ->
            if (item is TimelineItem.TransportItem) {
                val transport = item.transport
                
                // 找到时间最接近且衔接的 visible footprint
                // 1. 查找起点足迹 (endTime 接近 transport.startTime)
                val prevFp = sortedFps.lastOrNull { 
                    it.endTime.time <= transport.startTime.time + (AppConfig.SNAP_TIME_BUFFER * 1000).toLong() &&
                    Math.abs(it.endTime.time - transport.startTime.time) < (AppConfig.TRANSPORT_ALIGNMENT_THRESHOLD * 1000).toLong()
                }
                
                // 2. 查找终点足迹 (startTime 接近 transport.endTime)
                val nextFp = sortedFps.firstOrNull { 
                    it.startTime.time >= transport.endTime.time - (AppConfig.SNAP_TIME_BUFFER * 1000).toLong() &&
                    Math.abs(it.startTime.time - transport.endTime.time) < (AppConfig.TRANSPORT_ALIGNMENT_THRESHOLD * 1000).toLong()
                }
                
                if (prevFp != null || nextFp != null) {
                    // 创建一个新的 TransportRecordEntity 副本来应用对齐 (仅用于显示)
                    val aligned = transport.copy(
                        startLocation = prevFp?.address ?: transport.startLocation,
                        endLocation = nextFp?.address ?: transport.endLocation
                    )
                    TimelineItem.TransportItem(aligned)
                } else {
                    item
                }
            } else {
                item
            }
        }
    }

    private fun buildFootprintMarkersJson(
        footprints: List<FootprintEntity>,
        activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
        visibleStart: Date,
        visibleEnd: Date
    ): String? {
        val array = org.json.JSONArray()
        buildFootprintMapMarkers(footprints, activityTypes, visibleStart, visibleEnd).forEach { marker ->
            array.put(
                org.json.JSONObject()
                    .put("lat", marker.latitude)
                    .put("lon", marker.longitude)
                    .put("icon", marker.icon ?: "place")
                    .put("color", marker.colorHex ?: "#00A0AC")
                    .put("duration", marker.durationSeconds)
            )
        }
        return if (array.length() > 0) array.toString() else null
    }
}
