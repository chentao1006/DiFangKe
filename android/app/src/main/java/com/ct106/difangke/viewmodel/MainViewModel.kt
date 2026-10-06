package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.DailyInsightEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.markManualMetadataEdit
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.data.model.representativeLatitude
import com.ct106.difangke.data.model.representativeLongitude
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.service.OpenAIService
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
    private val midnightRefreshTick = MutableStateFlow(System.currentTimeMillis())

    init {
        viewModelScope.launch {
            while (true) {
                val nextMidnight = Calendar.getInstance().apply {
                    add(Calendar.DAY_OF_YEAR, 1)
                    set(Calendar.HOUR_OF_DAY, 0)
                    set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 500)
                }.timeInMillis
                delay((nextMidnight - System.currentTimeMillis()).coerceAtLeast(1_000L))
                midnightRefreshTick.value = System.currentTimeMillis()
            }
        }
    }

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

    // Raw-only days (no footprint/trip yet) still need to surface as *today*,
    // so the live tracking prompt/current-stay row has somewhere to render
    // before any footprint has been built. A past raw-only day would otherwise
    // show up as a bare, contentless date header in the home timeline, so it's
    // deliberately excluded once it's no longer today.
    private val availableRawDates: Flow<Set<Date>> = LocationTrackingService.stateFlow
        .map {
            withContext(Dispatchers.IO) {
                RawLocationStore.getInstance(getApplication()).getAvailableDates()
            }
        }

    private val _initialTimelineLoadCompleted = MutableStateFlow(false)
    /** iOS shows "正在加载时间轴" until the first date list is known. */
    val initialTimelineLoadCompleted: StateFlow<Boolean> = _initialTimelineLoadCompleted.asStateFlow()

    val availableDates: StateFlow<List<Date>> = combine(
        db.footprintDao().observeAvailableDates(),
        availableRawDates,
        midnightRefreshTick
        ) { footprintDates, rawDates, _ ->
            val dates: MutableSet<Date> = footprintDates.mapNotNull {
                try { sdf.parse(it)?.let { d -> zeroTime(d) } } catch(e: Exception) { null }
            }.toMutableSet()
            val today = zeroTime(Date())
            dates.addAll(rawDates.map(::zeroTime).filter { it == today })

            _initialTimelineLoadCompleted.value = true
            dates.toList().sortedBy { it.time }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    @OptIn(ExperimentalCoroutinesApi::class)
    val timelineItems: StateFlow<List<TimelineItem>> = _currentDate.flatMapLatest { date ->
        val start = zeroTime(date)
        val end = Calendar.getInstance().apply { time = start; add(Calendar.DAY_OF_YEAR, 1) }.time
        combine(
            db.footprintDao().observeBetween(start, end),
            db.transportRecordDao().observeForDay(start, end)
        ) { fps, tps ->
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

            mergeTimelineItems(boundedFps, boundedTps)
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
                db.transportRecordDao().observeForDay(start, end)
            ) { fps, tps ->
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

                val rawItems = mergeTimelineItems(boundedFps, boundedTps)
                
                alignTransportItems(rawItems, boundedFps)
            }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
        }
    }

    /**
     * The iOS home map represents every significant date currently visible in
     * the continuous timeline, rather than only the title date. Keep the same
     * aggregation on Android so scrolling the sheet updates map content live.
     */
    fun getTimelineItemsForDates(dates: Set<Date>): Flow<List<TimelineItem>> {
        val normalizedDates = dates.map(::zeroTime).distinctBy { it.time }.sortedBy { it.time }
        if (normalizedDates.isEmpty()) return flowOf(emptyList())
        return combine(normalizedDates.map(::getTimelineItems)) { days ->
            days.flatMap { it }.sortedBy { it.startTime }
        }
    }

    fun getDailyTrajectoryForDates(dates: Set<Date>): Flow<String?> {
        val normalizedDates = dates.map(::zeroTime).distinctBy { it.time }.sortedBy { it.time }
        if (normalizedDates.isEmpty()) return flowOf(null)
        return combine(normalizedDates.map(::getDailyTrajectory)) { trajectories ->
            val combined = org.json.JSONArray()
            trajectories.filterNotNull().forEach { raw ->
                runCatching { org.json.JSONArray(raw) }.getOrNull()?.let { points ->
                    if (combined.length() > 0 && points.length() > 0) combined.put(org.json.JSONArray().put(0.0).put(0.0))
                    for (index in 0 until points.length()) combined.put(points.get(index))
                }
            }
            combined.takeIf { it.length() > 0 }?.toString()
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
                combine(trajectoryFlow, LocationTrackingService.stateFlow) { traj, _ ->
                    // Re-read today's CSV on each live-state change so the
                    // map advances even while no transport record exists yet.
                    traj ?: rawTrajectoryJson(date)
                }
                    .flowOn(Dispatchers.Default)
                    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
            } else {
                // A raw-only day is reachable from the home timeline too.
                // Before its on-demand rebuild finishes, render its real
                // recorded path instead of presenting an empty map.
                trajectoryFlow.map { it ?: rawTrajectoryJson(date) }
                    .flowOn(Dispatchers.Default)
                    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
            }
        }
    }

    private fun rawTrajectoryJson(date: Date): String? = runCatching {
        val points = RawLocationStore.getInstance(getApplication()).loadLocations(date)
        if (points.isEmpty()) return@runCatching null
        org.json.JSONArray().apply {
            points.forEach { point -> put(org.json.JSONArray().put(point.latitude).put(point.longitude)) }
        }.toString()
    }.getOrNull()

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

            if ((footprints.isNotEmpty() || transports.isNotEmpty()) &&
                DiFangKeApp.instance.preferences.isAiEnabled.first()) {
                val preferences = getApplication<Application>()
                    .getSharedPreferences("daily_summary_ai", Application.MODE_PRIVATE)
                val now = System.currentTimeMillis()
                val lastRequest = preferences.getLong("last_request_at", 0L)
                if (now - lastRequest >= 60 * 60 * 1000L) {
                    preferences.edit().putLong("last_request_at", now).apply()
                    openAI.generateDailySummary(date, footprints, transports, force = true)
                }
            }

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

    fun loadTimelineItemsForRange(start: Date, end: Date, onLoaded: (List<TimelineItem>) -> Unit) {
        viewModelScope.launch(Dispatchers.IO) {
            val items = (
                db.footprintDao().getBetween(start, end).map { TimelineItem.FootprintItem(it) } +
                    db.transportRecordDao().getActiveBetween(start, end).map { TimelineItem.TransportItem(it) }
                ).sortedBy { it.startTime }
            withContext(Dispatchers.Main) { onLoaded(items) }
        }
    }

    private fun mergeTimelineItems(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>
    ): List<TimelineItem> {
        return (
            footprints.map { TimelineItem.FootprintItem(it) } +
                transports.map { TimelineItem.TransportItem(it) }
            ).sortedBy { it.startTime }
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

    // ── Timeline row edit actions (iOS ContinuousTimelineSheet handlers) ─────
    // These mirror the iOS long-press menu and icon pickers so the main
    // timeline can edit records without opening the detail screen.

    /** Long-press "收藏/取消收藏". Metadata edit → markManualMetadataEdit. */
    fun toggleFavorite(footprintID: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val stored = db.footprintDao().getById(footprintID) ?: return@launch
            db.footprintDao().update(
                stored.copy(isHighlight = !(stored.isHighlight ?: false)).markManualMetadataEdit()
            )
            Aptabase.instance.trackEvent("footprint_favorite_toggled")
        }
    }

    /** Row-icon activity picker; null means "无". */
    fun setFootprintActivity(footprintID: String, activityID: String?) {
        viewModelScope.launch(Dispatchers.IO) {
            val stored = db.footprintDao().getById(footprintID) ?: return@launch
            db.footprintDao().update(stored.copy(activityTypeValue = activityID).markManualMetadataEdit())
        }
    }

    /** Row-icon transport menu: pin the user's choice as the manual type. */
    fun setTransportType(recordID: String, type: com.ct106.difangke.data.model.TransportType) {
        viewModelScope.launch(Dispatchers.IO) {
            val stored = db.transportRecordDao().getById(recordID) ?: return@launch
            db.transportRecordDao().update(stored.copy(manualTypeRaw = type.raw, typeRaw = type.raw))
        }
    }

    /** iOS deleteFootprint: moves the stay into the recycle bin (status ignored). */
    fun deleteFootprint(footprintID: String) {
        Aptabase.instance.trackEvent("footprint_deleted")
        viewModelScope.launch(Dispatchers.IO) {
            val stored = db.footprintDao().getById(footprintID) ?: return@launch
            db.footprintDao().update(stored.copy(statusValue = "ignored"))
        }
    }

    /** iOS deleteTransport: delete the record and persist a deletion override. */
    fun deleteTransport(recordID: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val stored = db.transportRecordDao().getById(recordID) ?: return@launch
            db.transportManualSelectionDao().insert(
                com.ct106.difangke.data.db.entity.TransportManualSelectionEntity(
                    recordID = stored.recordID,
                    startTime = stored.startTime,
                    endTime = stored.endTime,
                    vehicleType = stored.manualTypeRaw ?: stored.typeRaw,
                    isDeleted = true
                )
            )
            db.transportRecordDao().delete(stored)
        }
    }

    /** "忽略地点": create/update an ignored place and hide all stays there. */
    fun ignoreFootprintLocation(footprintID: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val current = db.footprintDao().getById(footprintID) ?: return@launch
            val lat = current.representativeLatitude
            val lon = current.representativeLongitude
            if (!lat.isFinite() || !lon.isFinite() || (lat == 0.0 && lon == 0.0)) return@launch
            val existing = current.placeID?.let { db.placeDao().getById(it) }
            val ignoredPlace = existing?.copy(isIgnored = true) ?: PlaceEntity(
                name = current.address?.takeIf { it.isNotBlank() } ?: "已忽略地点",
                latitude = lat,
                longitude = lon,
                radius = 100f,
                address = current.address,
                isIgnored = true,
                isUserDefined = false
            )
            db.placeDao().insert(ignoredPlace)
            val threshold = ignoredPlace.radius + 100f
            val results = FloatArray(1)
            db.footprintDao().getAll().forEach { footprint ->
                val oLat = footprint.representativeLatitude
                val oLon = footprint.representativeLongitude
                if (!oLat.isFinite() || !oLon.isFinite()) return@forEach
                android.location.Location.distanceBetween(lat, lon, oLat, oLon, results)
                if (footprint.placeID == ignoredPlace.placeID || results[0] <= threshold) {
                    db.footprintDao().update(footprint.copy(statusValue = "ignored", placeID = ignoredPlace.placeID))
                }
            }
            Aptabase.instance.trackEvent("footprint_location_ignored")
        }
    }

    data class FootprintMergeCandidate(val first: FootprintEntity, val second: FootprintEntity)
    data class TransportMergeCandidate(val first: TransportRecordEntity, val second: TransportRecordEntity)

    private fun isSameCalendarDay(a: Date, b: Date): Boolean = zeroTime(a).time == zeroTime(b).time

    private fun isSameDayFootprint(fp: FootprintEntity): Boolean =
        isSameCalendarDay(fp.startTime, Date(fp.endTime.time - 1))

    /** iOS adjacentMergeCandidate(for:) — previous first, then next. */
    suspend fun footprintMergeCandidate(footprintID: String): FootprintMergeCandidate? = withContext(Dispatchers.IO) {
        val footprint = db.footprintDao().getById(footprintID) ?: return@withContext null
        val window = 172_800_000L
        val all = db.footprintDao().getBetween(
            Date(footprint.startTime.time - window),
            Date(footprint.endTime.time + window)
        ).filter { it.statusValue != "ignored" }.sortedBy { it.startTime }
        val index = all.indexOfFirst { it.footprintID == footprint.footprintID }
        if (index < 0) return@withContext null
        suspend fun canMerge(first: FootprintEntity, second: FootprintEntity): Boolean {
            if (first.footprintID == second.footprintID) return false
            if (!isSameDayFootprint(first) || !isSameDayFootprint(second)) return false
            if (!isSameCalendarDay(first.startTime, second.startTime)) return false
            val lower = minOf(first.endTime, second.endTime)
            val upper = maxOf(first.startTime, second.startTime)
            if (!upper.after(lower)) return true
            return db.transportRecordDao().getActiveBetween(lower, upper).isEmpty()
        }
        if (index > 0 && canMerge(all[index - 1], footprint)) {
            return@withContext FootprintMergeCandidate(all[index - 1], footprint)
        }
        if (index < all.lastIndex && canMerge(footprint, all[index + 1])) {
            return@withContext FootprintMergeCandidate(footprint, all[index + 1])
        }
        null
    }

    /** iOS adjacentTransportMergeCandidate(for:). */
    suspend fun transportMergeCandidate(recordID: String): TransportMergeCandidate? = withContext(Dispatchers.IO) {
        val record = db.transportRecordDao().getById(recordID) ?: return@withContext null
        val window = 172_800_000L
        val all = db.transportRecordDao().getActiveBetween(
            Date(record.startTime.time - window),
            Date(record.endTime.time + window)
        ).sortedBy { it.startTime }
        val index = all.indexOfFirst { it.recordID == record.recordID }
        if (index < 0) return@withContext null
        suspend fun canMerge(first: TransportRecordEntity, second: TransportRecordEntity): Boolean {
            if (first.recordID == second.recordID) return false
            if (!isSameCalendarDay(first.startTime, second.startTime)) return false
            val lower = minOf(first.endTime, second.endTime)
            val upper = maxOf(first.startTime, second.startTime)
            if (!upper.after(lower)) return true
            return db.footprintDao().getBetween(lower, upper).none {
                it.statusValue != "ignored" && it.endTime.after(lower) && it.startTime.before(upper)
            }
        }
        if (index > 0 && canMerge(all[index - 1], record)) {
            return@withContext TransportMergeCandidate(all[index - 1], record)
        }
        if (index < all.lastIndex && canMerge(record, all[index + 1])) {
            return@withContext TransportMergeCandidate(record, all[index + 1])
        }
        null
    }

    /** iOS mergeAdjacentFootprints: keep the earlier stay, delete the other. */
    fun mergeFootprints(candidate: FootprintMergeCandidate) {
        viewModelScope.launch(Dispatchers.IO) {
            val base = db.footprintDao().getById(candidate.first.footprintID) ?: return@launch
            val other = db.footprintDao().getById(candidate.second.footprintID) ?: return@launch
            fun jsonDoubles(raw: String): List<Double> = runCatching {
                val array = org.json.JSONArray(raw)
                List(array.length()) { array.getDouble(it) }
            }.getOrDefault(emptyList())
            fun jsonStrings(raw: String): List<String> = runCatching {
                val array = org.json.JSONArray(raw)
                List(array.length()) { array.getString(it) }
            }.getOrDefault(emptyList())
            fun <T : Number> sum(a: T?, b: T?, add: (T, T) -> T): T? = when {
                a != null && b != null -> add(a, b)
                else -> a ?: b
            }
            val start = minOf(base.startTime, other.startTime)
            val end = maxOf(base.endTime, other.endTime)
            val baseAddressEmpty = base.address.isNullOrEmpty()
            val merged = base.copy(
                startTime = start,
                endTime = end,
                date = zeroTime(start),
                latitudeJson = org.json.JSONArray(jsonDoubles(base.latitudeJson) + jsonDoubles(other.latitudeJson)).toString(),
                longitudeJson = org.json.JSONArray(jsonDoubles(base.longitudeJson) + jsonDoubles(other.longitudeJson)).toString(),
                reason = if (base.reason.isNullOrEmpty()) other.reason else base.reason,
                address = if (baseAddressEmpty) other.address else base.address,
                isAddressEditedByHand = if (baseAddressEmpty) other.isAddressEditedByHand else base.isAddressEditedByHand,
                placeID = base.placeID ?: other.placeID,
                activityTypeValue = base.activityTypeValue ?: other.activityTypeValue,
                isHighlight = if (base.isHighlight == true) true else other.isHighlight,
                stepCount = sum(base.stepCount, other.stepCount) { a, b -> a + b },
                walkingDistance = sum(base.walkingDistance, other.walkingDistance) { a, b -> a + b },
                floorsAscended = sum(base.floorsAscended, other.floorsAscended) { a, b -> a + b },
                photoAssetIDsJson = org.json.JSONArray(
                    (jsonStrings(base.photoAssetIDsJson) + jsonStrings(other.photoAssetIDsJson)).distinct()
                ).toString(),
                statusValue = "manual",
                allowsAutomaticDurationExtension = true
            )
            db.footprintDao().update(merged)
            db.footprintDao().delete(other)
            Aptabase.instance.trackEvent("footprint_adjacent_merged")
        }
    }

    /** iOS mergeAdjacentTransports: earlier record survives and owns the type. */
    fun mergeTransports(candidate: TransportMergeCandidate) {
        viewModelScope.launch(Dispatchers.IO) {
            val base = db.transportRecordDao().getById(candidate.first.recordID) ?: return@launch
            val other = db.transportRecordDao().getById(candidate.second.recordID) ?: return@launch
            val start = minOf(base.startTime, other.startTime)
            val end = maxOf(base.endTime, other.endTime)
            val distance = base.distance + other.distance
            val durationSec = ((end.time - start.time) / 1000L).coerceAtLeast(0L)
            val speed = if (durationSec > 0) distance / durationSec else 0.0
            val stepCount = when {
                base.stepCount != null && other.stepCount != null -> base.stepCount + other.stepCount
                else -> base.stepCount ?: other.stepCount
            }
            val points = runCatching {
                val mergedPoints = org.json.JSONArray()
                listOf(base.pointsJson, other.pointsJson).forEach { raw ->
                    val array = org.json.JSONArray(raw)
                    for (i in 0 until array.length()) mergedPoints.put(array.get(i))
                }
                mergedPoints
            }.getOrNull()
            val pointCount = points?.length() ?: 0
            val explicitType = base.manualTypeRaw ?: other.manualTypeRaw
            val inferred = com.ct106.difangke.data.model.TransportType.from(
                speedMs = speed,
                stepCount = stepCount ?: 0,
                durationSec = durationSec,
                distanceMeters = distance,
                pointCount = pointCount,
                observedPointCount = pointCount
            ).raw
            val type = explicitType ?: inferred
            val endLocation = other.endLocation.trim().let {
                if (it.isNotEmpty() && it != "终点" && it != "正在获取位置...") other.endLocation else base.endLocation
            }
            val merged = base.copy(
                day = zeroTime(start),
                startTime = start,
                endTime = end,
                distance = distance,
                averageSpeed = speed,
                stepCount = stepCount,
                endLocation = endLocation,
                pointsJson = points?.toString() ?: base.pointsJson,
                typeRaw = type,
                manualTypeRaw = type
            )
            db.transportRecordDao().update(merged)
            db.transportRecordDao().delete(other)
            Aptabase.instance.trackEvent("transport_adjacent_merged")
        }
    }

    /** ActivityType.getSuggestedActivities(includeFallback: false) with place history. */
    suspend fun suggestedActivities(
        footprint: FootprintEntity,
        activities: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
        places: List<PlaceEntity>
    ): List<com.ct106.difangke.data.db.entity.ActivityTypeEntity> = withContext(Dispatchers.IO) {
        val history = footprint.placeID?.let { placeID ->
            db.footprintDao().getAll().filter { it.placeID == placeID }
        } ?: emptyList()
        com.ct106.difangke.service.ActivitySuggestion.getSuggestedActivities(
            footprint = footprint,
            allActivities = activities,
            allPlaces = places,
            history = history,
            includeFallback = false
        )
    }

    private val addressRetryAttempted = Collections.synchronizedSet(mutableSetOf<String>())

    /**
     * iOS retryUnknownFootprintLocationIfNeeded: placeholder addresses get one
     * background reverse-geocode per session; the result is written back unless
     * the user typed the address by hand.
     */
    suspend fun retryUnknownAddress(footprint: FootprintEntity) {
        if (!addressRetryAttempted.add(footprint.footprintID)) return
        val lat = footprint.representativeLatitude
        val lon = footprint.representativeLongitude
        if (!lat.isFinite() || !lon.isFinite() || (lat == 0.0 && lon == 0.0)) return
        val result = runCatching {
            com.ct106.difangke.service.GeocodeService.shared.reverseGeocodeDetails(lat, lon)
        }.getOrNull() ?: return
        val address = result.address?.trim()?.takeIf { it.isNotEmpty() && it !in UNRESOLVED_ADDRESSES } ?: return
        withContext(Dispatchers.IO) {
            val stored = db.footprintDao().getById(footprint.footprintID) ?: return@withContext
            if (stored.isAddressEditedByHand) return@withContext
            if (stored.address?.trim().orEmpty() !in UNRESOLVED_ADDRESSES) return@withContext
            db.footprintDao().update(
                stored.copy(
                    address = address,
                    cityName = stored.cityName ?: result.cityName,
                    countryName = stored.countryName ?: result.countryName,
                    countryCode = stored.countryCode ?: result.countryCode
                )
            )
        }
    }

    suspend fun storedFootprint(footprintID: String): FootprintEntity? =
        withContext(Dispatchers.IO) { db.footprintDao().getById(footprintID) }

    suspend fun storedTransport(recordID: String): TransportRecordEntity? =
        withContext(Dispatchers.IO) { db.transportRecordDao().getById(recordID) }

    /** iOS FootprintSplitView save from the timeline context menu. */
    fun splitFootprint(footprint: FootprintEntity, splitTime: Date, firstActivity: String?, secondActivity: String?) {
        viewModelScope.launch {
            com.ct106.difangke.ui.shared.TimelineEditActions.splitFootprint(
                db, getApplication(), footprint, splitTime, firstActivity, secondActivity
            )
        }
    }

    /** iOS TransportSplitView save from the timeline context menu. */
    fun splitTransport(record: TransportRecordEntity, splitTime: Date) {
        viewModelScope.launch {
            com.ct106.difangke.ui.shared.TimelineEditActions.splitTransport(db, record, splitTime)
        }
    }

    /** iOS "设为重要地点" → AddPlaceSheet: saves the place and links the footprint to it. */
    fun addImportantPlace(footprint: FootprintEntity, name: String, latitude: Double, longitude: Double, radius: Float, address: String?) {
        viewModelScope.launch(Dispatchers.IO) {
            val finalName = name.trim().ifEmpty { footprint.address ?: "未知地点" }
            val place = PlaceEntity(
                name = finalName,
                latitude = latitude,
                longitude = longitude,
                radius = radius,
                address = address,
                isUserDefined = true
            )
            db.placeDao().insert(place)
            com.ct106.difangke.ui.shared.TimelineEditActions.updateFootprintMetadata(db, footprint) {
                it.copy(placeID = place.placeID, address = finalName, isAddressEditedByHand = true)
            }
            Aptabase.instance.trackEvent("place_added")
        }
    }

    companion object {
        /** Placeholder titles iOS treats as "still unresolved". */
        val UNRESOLVED_ADDRESSES = setOf("", "未知位置", "未知地点", "地点记录", "正在解析位置...", "此处")
    }
}
