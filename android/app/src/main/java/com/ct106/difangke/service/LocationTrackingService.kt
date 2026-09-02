package com.ct106.difangke.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.*
import android.util.Log
import com.tencent.map.geolocation.TencentLocation
import com.tencent.map.geolocation.TencentLocationListener
import com.tencent.map.geolocation.TencentLocationManager
import com.tencent.map.geolocation.TencentLocationRequest
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.data.model.TransportType
import com.google.gson.Gson
import java.util.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first

/** 后台位置追踪前台服务（迁移至高德定位 SDK，以解决中国境内定位偏移和成功率问题） */
class LocationTrackingService : Service() {

        companion object {
                private const val TAG = "LocationTrackingService"
                const val ACTION_START = "START_TRACKING"
                const val ACTION_STOP = "STOP_TRACKING"
                const val ACTION_SET_ONGOING_PLACE = "SET_ONGOING_PLACE"
                private const val EXTRA_ONGOING_PLACE_ID = "ongoing_place_id"
                private const val EXTRA_ONGOING_PLACE_NAME = "ongoing_place_name"

                val stateFlow =
                        kotlinx.coroutines.flow.MutableStateFlow<TrackingState>(TrackingState.Idle)

                var isHighAccuracyBoostEnabled = false // 保留字段但不再由 UI 控制，改为内部逻辑

                fun start(context: Context) {
                        val intent =
                                Intent(context, LocationTrackingService::class.java).apply {
                                        action = ACTION_START
                                }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                context.startForegroundService(intent)
                        } else {
                                context.startService(intent)
                        }
                }

                fun stop(context: Context) {
                        // Go through ACTION_STOP so the service clears its
                        // persisted active-stay state before stopping. A direct
                        // stopService() bypasses that cleanup and could revive
                        // an old stay when tracking is enabled again.
                        val intent = Intent(context, LocationTrackingService::class.java).apply {
                                action = ACTION_STOP
                        }
                        runCatching { context.startService(intent) }
                                .onFailure { context.stopService(intent) }
                        stateFlow.value = TrackingState.Idle
                }

                /** Assign the active stay to a user-selected place without waiting for a new GPS sample. */
                fun setOngoingPlace(context: Context, placeID: String?, placeName: String) {
                        val intent = Intent(context, LocationTrackingService::class.java).apply {
                                action = ACTION_SET_ONGOING_PLACE
                                placeID?.let { putExtra(EXTRA_ONGOING_PLACE_ID, it) }
                                putExtra(EXTRA_ONGOING_PLACE_NAME, placeName)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                context.startForegroundService(intent)
                        } else {
                                context.startService(intent)
                        }
                }
        }

        sealed class TrackingState {
                object Idle : TrackingState()
                data class Tracking(
                        val lat: Double? = null,
                        val lon: Double? = null,
                        val speed: Double = 0.0
                ) : TrackingState()
                data class OngoingStay(
                        val since: Date,
                        val lat: Double,
                        val lon: Double,
                        val address: String? = null,
                        val speed: Double = 0.0
                ) : TrackingState()
        }

        private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val gson = Gson()
        private val prefs by lazy { (application as DiFangKeApp).preferences }

        private var locationClient: TencentLocationManager? = null
        private val rawStore by lazy { RawLocationStore.getInstance(applicationContext) }
        private val db by lazy { DiFangKeApp.instance.database }
        private val geocoder by lazy { GeocodeService.shared }
        private val processor = FootprintProcessor.shared

        private val trackingQueue = mutableListOf<RawLocationStore.RawPoint>()
        private var ongoingStayStart: RawLocationStore.RawPoint? = null
        private var ongoingStayAddress: String? = null
        private var ongoingFootprintID: String? = null
        private var ongoingPlaceOverrideID: String? = null
        private var ongoingPlaceOverrideName: String? = null
        private var hasAttemptedPersistedStayRestore = false
        private var lastNotificationText: String? = null
        private var lastNotifiedStayStart: Long? = null
        private var currentIntervalTier = -1 // -1: initial, 0: stationary, 1: moving, 2: fast
        private var currentAccuracyMode = "automatic"
        private var hasAcquiredFirstLocation = false
        private var initialLocationAcquisitionTimedOut = false
        private var initialLocationFallbackJob: Job? = null
        private var timelineSiftJob: Job? = null
        private var lastTimelineSiftAt = 0L
        private val ongoingStayMaxPointGapMs =
                (AppConfig.TRANSPORT_MAX_GAP_THRESHOLD * 1000).toLong()

        private var wasVpnOrProxyActive: Boolean? = null

        /**
         * Match iOS LocationManager.triggerTimelineSiftDebounced: raw points are
         * persisted immediately, then the durable timeline is rebuilt at most
         * once per 15 minutes. Without this, Android only creates footprints
         * after a manual rebuild or opening a historical raw-only day.
         */
        private fun scheduleTimelineSift() {
                val now = System.currentTimeMillis()
                if (timelineSiftJob?.isActive == true || now - lastTimelineSiftAt < 15 * 60_000L) {
                        return
                }
                lastTimelineSiftAt = now
                timelineSiftJob = serviceScope.launch {
                        runCatching {
                                PersistentTimelineBuilder(applicationContext).rebuildDay(Date())
                        }.onFailure { error ->
                                Log.e(TAG, "Automatic timeline rebuild failed", error)
                        }
                }
        }

        private fun isVpnOrProxyActive(): Boolean {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                val activeNetwork = cm?.activeNetwork ?: return false
                val capabilities = cm.getNetworkCapabilities(activeNetwork) ?: return false

                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                        return true
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val proxyInfo = cm.defaultProxy
                        if (proxyInfo != null) {
                                if (!proxyInfo.host.isNullOrEmpty() || proxyInfo.pacFileUrl != null
                                ) {
                                        return true
                                }
                        }
                }

                val host = System.getProperty("http.proxyHost")
                val port = System.getProperty("http.proxyPort")
                if (!host.isNullOrEmpty() && !port.isNullOrEmpty()) {
                        return true
                }

                return false
        }

        private fun getBestLocationMode(): Int {
                return if (isVpnOrProxyActive() && hasAcquiredFirstLocation) {
                        Log.i(
                                TAG,
                                "检测到 VPN 或代理处于激活状态，且已获取过首次定位，使用 Device_Sensors 模式（仅 GPS）定位以防止定位漂移"
                        )
                        TencentLocationRequest.ONLY_GPS_MODE
                } else {
                        if (currentAccuracyMode == "powerSaving") {
                                TencentLocationRequest.ONLY_NETWORK_MODE
                        } else {
                                TencentLocationRequest.HIGH_ACCURACY_MODE
                        }
                }
        }

        private fun updateLocationClientOption(tier: Int) {
                // TencentLocationManager creates a Handler internally and
                // therefore must only be touched from a thread with the main
                // Looper. Preference collection runs on serviceScope (IO),
                // which previously made selecting a stay able to crash the
                // whole process with "looper is null".
                if (Looper.myLooper() != Looper.getMainLooper()) {
                        Handler(Looper.getMainLooper()).post {
                                updateLocationClientOption(tier)
                        }
                        return
                }
                // 在同一地点持续使用 GPS 会让定位芯片无法休眠。静止时只保留低功耗的网络
                // 定位作离开检测；一旦速度表明正在移动，下面的分级策略会立即恢复精确定位。
                val useLowPowerStationaryMode =
                        hasAcquiredFirstLocation &&
                                tier <= 0 &&
                                currentAccuracyMode in setOf("automatic", "powerSaving")
                val useLowPowerInitialFallback =
                        !hasAcquiredFirstLocation && initialLocationAcquisitionTimedOut
                val useLowPowerMode = useLowPowerStationaryMode || useLowPowerInitialFallback
                val newInterval =
                        if (!hasAcquiredFirstLocation && !initialLocationAcquisitionTimedOut) {
                                2000L // 首次定位成功前，保持高频重试（2秒），防止冷启动失败后等待太久
                        } else if (useLowPowerInitialFallback) {
                                10 * 60_000L // 室内首次定位失败后不持续拉起 GPS
                        } else {
                                when (currentAccuracyMode) {
                                        "high" -> 5000L
                                        "balanced" -> 15000L
                                        "powerSaving" -> 10 * 60_000L
                                        else -> {
                                                when (tier) {
                                                        // 自动模式仍使用高精度定位源，但降低采样密度；
                                                        // 检测到移动后会马上从静止网络定位切回这里。
                                                        2 -> 12_000L // 高速：12 秒
                                                        1 -> 20_000L // 正常移动：20 秒
                                                        else -> 10 * 60_000L // 停留：10 分钟
                                                }
                                        }
                                }
                        }
                val locationMode =
                        if (useLowPowerMode) {
                                TencentLocationRequest.ONLY_NETWORK_MODE
                        } else {
                                getBestLocationMode()
                        }
                locationClient?.removeUpdates(locationListener)
                locationClient?.requestLocationUpdates(
                        TencentLocationRequest.create()
                                .setLocMode(locationMode)
                                .setInterval(newInterval)
                                .setRequestLevel(TencentLocationRequest.REQUEST_LEVEL_GEO)
                                .setAllowGPS(!useLowPowerMode)
                                .setAllowCache(useLowPowerMode),
                        locationListener
                )
                Log.d(
                        TAG,
                        "Location option updated: interval=$newInterval ms, mode=$locationMode, lowPower=$useLowPowerMode"
                )
        }

        private fun scheduleInitialLocationFallback() {
                if (hasAcquiredFirstLocation || initialLocationFallbackJob != null) return
                initialLocationFallbackJob = serviceScope.launch {
                        delay(2 * 60_000L)
                        if (!hasAcquiredFirstLocation) {
                                initialLocationAcquisitionTimedOut = true
                                Log.w(TAG, "Initial location timed out; switching to low-power network location")
                                updateLocationClientOption(0)
                        }
                }
        }

        private val locationListener = object : TencentLocationListener {
            override fun onStatusUpdate(name: String?, status: Int, desc: String?) = Unit

            override fun onLocationChanged(location: TencentLocation?, errorCode: Int, errorInfo: String?) {
                val currentVpnOrProxy = isVpnOrProxyActive()
                val networkStateChanged = wasVpnOrProxyActive != currentVpnOrProxy
                if (networkStateChanged) {
                        wasVpnOrProxyActive = currentVpnOrProxy
                        Log.i(TAG, "VPN 或代理状态变更检测到: $currentVpnOrProxy，重新应用定位选项")
                }

                if (location != null && errorCode == TencentLocation.ERROR_OK) {
                        if (!hasAcquiredFirstLocation) {
                                hasAcquiredFirstLocation = true
                                initialLocationFallbackJob?.cancel()
                                initialLocationFallbackJob = null
                                Log.i(TAG, "首次定位成功，恢复正常采样频率")
                                val tier = if (currentIntervalTier == -1) 0 else currentIntervalTier
                                updateLocationClientOption(tier)
                        }

                        val speed = location.speed
                        // 根据速度调整采样频率以节省耗电
                        // 0: 停留 (<0.5m/s), 1: 正常运动 (0.5~10m/s), 2: 高速 (10m/s以上)
                        val newTier =
                                when {
                                        speed > 10.0 -> 2
                                        speed > 0.5 -> 1
                                        else -> 0
                                }

                        if (newTier != currentIntervalTier || networkStateChanged) {
                                currentIntervalTier = newTier
                                updateLocationClientOption(newTier)
                                Log.d(
                                        TAG,
                                        "Interval adjusted to tier $newTier, networkStateChanged=$networkStateChanged, speed=$speed m/s"
                                )
                        }

                        serviceScope.launch {
                                handleNewLocation(
                                        location.latitude,
                                        location.longitude,
                                        location.accuracy.toDouble(),
                                        location.speed.toDouble(),
                                        Date(location.time),
                        getShortAddress(location) // 优化：提取短地址
                                )
                        }
                } else {
                        Log.e(
                                TAG,
                                "定位失败: $errorCode - $errorInfo (VPN/代理: $currentVpnOrProxy)"
                        )
                        // 如果是因为开启 VPN/代理 导致高精度定位失败，可在下一次尝试强制重置一次选项
                        if (networkStateChanged) {
                                val tier = if (currentIntervalTier == -1) 0 else currentIntervalTier
                                updateLocationClientOption(tier)
                        }
                }
            }
        }

        private fun getShortAddress(location: TencentLocation): String? {
                return geocoder.coarseAutomaticPlaceName(
                        listOf(
                                location.poiList?.firstOrNull()?.name,
                                location.name,
                                listOfNotNull(location.district, location.street)
                                        .joinToString("")
                        )
                )
        }

        override fun onCreate() {
                super.onCreate()
                loadPersistedStayState()

                serviceScope.launch {
                        prefs.locationAccuracyMode.collect { mode ->
                                currentAccuracyMode = mode
                                if (stateFlow.value !is TrackingState.Idle) {
                                        val tier =
                                                if (currentIntervalTier == -1) 0
                                                else currentIntervalTier
                                        updateLocationClientOption(tier)
                                }
                        }
                }

                try {
                        locationClient = TencentLocationManager.getInstance(applicationContext).also {
                                it.setCoordinateType(TencentLocationManager.COORDINATE_TYPE_GCJ02)
                                it.setMockEnable(false)
                        }
                        wasVpnOrProxyActive = isVpnOrProxyActive()
                        updateLocationClientOption(0)
                } catch (e: Exception) {
                        Log.e(TAG, "初始化高德定位失败", e)
                }
        }

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
                when (intent?.action ?: ACTION_START) {
                        ACTION_START -> {
                                Log.d(TAG, "ACTION_START received, starting foreground...")
                                val notification =
                                        NotificationHelper.buildTrackingNotification(this)
                                startForeground(
                                        NotificationHelper.TRACKING_NOTIFICATION_ID,
                                        notification
                                )

                                // 腾讯定位复用应用自身的前台服务通知
                                wasVpnOrProxyActive = isVpnOrProxyActive()
                                scheduleInitialLocationFallback()
                                val tier = if (currentIntervalTier == -1) 0 else currentIntervalTier
                                updateLocationClientOption(tier)
                                locationClient?.enableForegroundLocation(
                                        NotificationHelper.TRACKING_NOTIFICATION_ID,
                                        notification
                                )
                                // A fast DataStore restore may already have
                                // published an active stay before this start
                                // command runs. Do not replace it with a blank
                                // moving state during cold launch.
                                if (stateFlow.value !is TrackingState.OngoingStay) {
                                        stateFlow.value = TrackingState.Tracking()
                                }
                                // A process restart can leave already-persisted raw points
                                // without their corresponding footprint until another GPS
                                // callback arrives. Reconcile them on service recovery too.
                                scheduleTimelineSift()
                                Log.i(
                                        TAG,
                                        "Tracking service successfully started and transitioned to Tracking state"
                                )
                        }
                        ACTION_STOP -> {
                                initialLocationFallbackJob?.cancel()
                                initialLocationFallbackJob = null
                                locationClient?.disableForegroundLocation(true)
                                stopForeground(STOP_FOREGROUND_REMOVE)

                                // 清理持久化的停留状态
                                serviceScope.launch {
                                        prefs.savePendingStay(null, null, null, null)
                                        prefs.setPendingStayPlaceOverride(null)
                                }

                                stopSelf()
                                stateFlow.value = TrackingState.Idle
                                locationClient?.removeUpdates(locationListener)
                                Log.i(TAG, "Tencent Tracking stopped")
                                return START_NOT_STICKY
                        }
                        ACTION_SET_ONGOING_PLACE -> {
                                val placeID = intent?.getStringExtra(EXTRA_ONGOING_PLACE_ID)
                                val placeName = intent?.getStringExtra(EXTRA_ONGOING_PLACE_NAME)
                                if (!placeName.isNullOrBlank()) {
                                        applyOngoingPlaceOverride(placeID, placeName)
                                }
                        }
                }
                return START_STICKY
        }

        private fun applyOngoingPlaceOverride(placeID: String?, placeName: String) {
                ongoingPlaceOverrideID = placeID
                ongoingPlaceOverrideName = placeName
                ongoingStayAddress = placeName

                val state = stateFlow.value as? TrackingState.OngoingStay
                if (state != null) {
                        stateFlow.value = state.copy(address = placeName)
                        serviceScope.launch {
                                prefs.savePendingStay(state.lat, state.lon, state.since.time, placeName)
                                prefs.setPendingStayPlaceOverride(placeID)
                                val footprint = ongoingFootprintID?.let { db.footprintDao().getById(it) }
                                if (footprint != null) {
                                        db.footprintDao().update(
                                                footprint.copy(
                                                        placeID = placeID,
                                                        address = placeName,
                                                        title = FootprintTitles.generate(placeName, footprint.startTime.time / 1000),
                                                        // This is an explicit user location choice. Preserve it
                                                        // through subsequent automatic timeline rebuilds.
                                                        isTitleEditedByHand = true,
                                                        statusValue = "manual"
                                                )
                                        )
                                }
                        }
                }
        }

        private fun clearOngoingPlaceOverride() {
                ongoingPlaceOverrideID = null
                ongoingPlaceOverrideName = null
                serviceScope.launch { prefs.setPendingStayPlaceOverride(null) }
        }

        private suspend fun handleNewLocation(
                lat: Double,
                lon: Double,
                accuracy: Double,
                speed: Double,
                time: Date,
                address: String?
        ) {
                // 0. 存储原始点（用于后续分析和轨迹绘制）
                rawStore.saveRawPoint(lat, lon, accuracy, speed, time.time)
                // RawLocationStore writes synchronously, so the builder observes this
                // point and can persist its resulting footprint immediately after the
                // same debounce used by iOS.
                scheduleTimelineSift()

                val point =
                        RawLocationStore.RawPoint(
                                timestamp = time,
                                latitude = lat,
                                longitude = lon,
                                accuracy = accuracy,
                                speed = speed
                        )

                // 1. 初始化恢复逻辑（如果是重启后第一次收到点）
                if (ongoingStayStart == null) {
                        loadPersistedStayState()
                }

                // 2. 识别停留算法
                val candidate = processor.processNewLocation(point, trackingQueue)

                // 3. 更新当前显示状态
                if (ongoingStayStart == null) {
                        stateFlow.value = TrackingState.Tracking(lat, lon, speed)
                }
                updateOngoingState(point, address)

                // 与 iOS 保持一致：抵达当天计划或未定日期计划的地点后自动完成。
                // 只在服务收到真实定位点时执行，避免 UI 打开地图时误触发状态变化。

                // 3. 候选停留保存
                candidate?.let {
                        saveFootprint(it)
                        trackingQueue.clear()
                        trackingQueue.add(point)
                }
        }

        private suspend fun completeArrivedFutureTrips(lat: Double, lon: Double, time: Date) {
                val calendar = Calendar.getInstance().apply { this.time = time }
                val dayStart = calendar.apply {
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                }.time
                val dayEnd = Calendar.getInstance().apply {
                        this.time = dayStart
                        add(Calendar.DAY_OF_YEAR, 1)
                }.time
                val arrived = db.futureTripDao().getAutoCompletableForDay(dayStart, dayEnd)
                        .filter { trip ->
                                trip.latitude.isFinite() && trip.longitude.isFinite() &&
                                        trip.latitude != 0.0 && trip.longitude != 0.0 &&
                                        processor.haversineMeters(lat, lon, trip.latitude, trip.longitude) < 200.0
                        }
                arrived.forEach { trip ->
                        db.futureTripDao().update(trip.copy(isCompleted = true, completedAt = time))
                        FutureTripReminderWorker.cancel(applicationContext, trip.tripID)
                        Log.i(TAG, "Auto-completed future trip ${trip.tripID} after arrival")
                }
        }

        private suspend fun updateOngoingState(
                current: RawLocationStore.RawPoint,
                currentAddress: String?
        ) {
                val queueSize = trackingQueue.size
                // 至少有三个点才能判定停留趋势
                if (queueSize >= 3) {
                        val (centerLat, centerLon) = processor.calculateCenter(trackingQueue)
                        val distFromCenter =
                                processor.haversineMeters(
                                        centerLat,
                                        centerLon,
                                        current.latitude,
                                        current.longitude
                                )

                        if (distFromCenter < AppConfig.STAY_DISTANCE_THRESHOLD) {
                                // 如果当前已经在 OngoingStay 且中心位移不大，不要重设 start 时间
                                if (ongoingStayStart == null) {
                                        // A user-selected place belongs only to the prior
                                        // active stay. Never carry it into a new stop.
                                        clearOngoingPlaceOverride()
                                        ongoingStayStart =
                                                resolveOngoingStayStart(
                                                        centerLat,
                                                        centerLon,
                                                        trackingQueue.first(),
                                                        current
                                                )
                                        // 持久化保存
                                        serviceScope.launch {
                                                prefs.savePendingStay(
                                                        centerLat,
                                                        centerLon,
                                                        ongoingStayStart?.timestamp?.time,
                                                        currentAddress
                                                )
                                        }
                                } else {
                                        val earliestStayPoint =
                                                resolveOngoingStayStart(
                                                        centerLat,
                                                        centerLon,
                                                        ongoingStayStart!!,
                                                        current
                                                )
                                        if (earliestStayPoint.timestamp.before(
                                                        ongoingStayStart!!.timestamp
                                                )
                                        ) {
                                                ongoingStayStart = earliestStayPoint
                                                serviceScope.launch {
                                                        prefs.savePendingStay(
                                                                centerLat,
                                                                centerLon,
                                                                ongoingStayStart?.timestamp?.time,
                                                                currentAddress ?: ongoingStayAddress
                                                        )
                                                }
                                        }

                                        // 核心修复：如果已有的停留点距离当前新识别的中心太远，说明用户已经大幅度移动过
                                        // 之前的 ongoingStayStart 是陈旧的（可能是重启后恢复的），应以当前窗口为准重设
                                        val distFromStart =
                                                processor.haversineMeters(
                                                        ongoingStayStart!!.latitude,
                                                        ongoingStayStart!!.longitude,
                                                        centerLat,
                                                        centerLon
                                                )
                                        if (distFromStart > AppConfig.STAY_DISTANCE_THRESHOLD * 2.5
                                        ) {
                                                Log.i(
                                                        TAG,
                                                        "Restored stay location is too far ($distFromStart m), resetting stay start time."
                                                )
                                                ongoingStayStart =
                                                        resolveOngoingStayStart(
                                                                centerLat,
                                                                centerLon,
                                                                trackingQueue.first(),
                                                                current
                                                        )
                                                clearOngoingPlaceOverride()
                                                ongoingStayAddress = null
                                                serviceScope.launch {
                                                        prefs.savePendingStay(
                                                                centerLat,
                                                                centerLon,
                                                                ongoingStayStart?.timestamp?.time,
                                                                currentAddress
                                                        )
                                                }
                                        }
                                }

                                serviceScope.launch {
                                        val address =
                                                currentAddress
                                                        ?: geocoder.reverseGeocode(
                                                                centerLat,
                                                                centerLon
                                                        )
                                        if (address != null && ongoingStayAddress == null) {
                                                ongoingStayAddress = address
                                                prefs.savePendingStay(
                                                        centerLat,
                                                        centerLon,
                                                        ongoingStayStart?.timestamp?.time,
                                                        address
                                                )
                                        }

                                        val displayAddress = ongoingPlaceOverrideName ?: address ?: ongoingStayAddress
                                        stateFlow.value =
                                                TrackingState.OngoingStay(
                                                        since = ongoingStayStart!!.timestamp,
                                                        lat = centerLat,
                                                        lon = centerLon,
                                                        address = displayAddress,
                                                        speed = current.speed
                                                )

                                        upsertOngoingFootprint(
                                                centerLat,
                                                centerLon,
                                                current,
                                                displayAddress
                                        )

                                        val stayStart = ongoingStayStart!!.timestamp.time
                                        if (lastNotifiedStayStart != stayStart) {
                                                checkAndSendNewPlaceNotification(
                                                        centerLat,
                                                        centerLon,
                                                        stayStart,
                                                        address ?: ongoingStayAddress,
                                                        ongoingFootprintID
                                                )
                                                lastNotifiedStayStart = stayStart
                                        }

                                        val notifText = (address ?: ongoingStayAddress) ?: "正在停留中"
                                        if (notifText != lastNotificationText) {
                                                lastNotificationText = notifText
                                                NotificationHelper.updateTrackingNotification(
                                                        this@LocationTrackingService,
                                                        notifText
                                                )
                                        }
                                }
                        } else {
                                // 位移较大，说明正在移动，不是停留态
                                if (ongoingStayStart != null) {
                                        ongoingStayStart = null
                                        ongoingStayAddress = null
                                        ongoingFootprintID = null
                                        clearOngoingPlaceOverride()
                                        serviceScope.launch {
                                                prefs.savePendingStay(null, null, null, null)
                                        }
                                }
                        }
                }
        }

        private suspend fun resolveOngoingStayStart(
                centerLat: Double,
                centerLon: Double,
                fallback: RawLocationStore.RawPoint,
                current: RawLocationStore.RawPoint
        ): RawLocationStore.RawPoint {
                val lowerBound =
                        maxOf(
                                getStartOfDay(current.timestamp).time,
                                latestFootprintEndBefore(current.timestamp, centerLat, centerLon)
                                        ?.time
                                        ?: Long.MIN_VALUE
                        )
                val points =
                        rawStore.loadRecentLocations(AppConfig.LOCATION_LOOKBACK_MAX_HOURS)
                                .asSequence()
                                .filter { it.timestamp.time in lowerBound..current.timestamp.time }
                                .filter {
                                        it.accuracy > 0 &&
                                                it.accuracy < AppConfig.MAX_LOCATION_ACCURACY
                                }
                                .toList()

                if (points.isEmpty()) return fallback

                var earliest: RawLocationStore.RawPoint? = null
                var previousLaterPoint: RawLocationStore.RawPoint? = null
                for (point in points.asReversed()) {
                        val laterPoint = previousLaterPoint
                        if (laterPoint != null &&
                                        laterPoint.timestamp.time - point.timestamp.time >
                                                ongoingStayMaxPointGapMs
                        ) {
                                break
                        }

                        val distance =
                                processor.haversineMeters(
                                        centerLat,
                                        centerLon,
                                        point.latitude,
                                        point.longitude
                                )
                        if (distance <= AppConfig.STAY_DISTANCE_THRESHOLD) {
                                earliest = point
                                previousLaterPoint = point
                        } else if (earliest != null) {
                                break
                        }
                }

                val boundedFallback =
                        if (fallback.timestamp.time < lowerBound) current else fallback
                return listOfNotNull(earliest, boundedFallback).minByOrNull { it.timestamp.time }
                        ?: boundedFallback
        }

        private suspend fun latestFootprintEndBefore(
                current: Date,
                centerLat: Double,
                centerLon: Double
        ): Date? {
                val dayStart = getStartOfDay(current)
                return db.footprintDao()
                        .getBetween(dayStart, current)
                        .filter { footprint ->
                                val lats =
                                        gson.fromJson(
                                                        footprint.latitudeJson,
                                                        Array<Double>::class.java
                                                )
                                                .toList()
                                val lons =
                                        gson.fromJson(
                                                        footprint.longitudeJson,
                                                        Array<Double>::class.java
                                                )
                                                .toList()
                                if (lats.isEmpty() || lons.isEmpty()) return@filter false
                                val lat = lats.average()
                                val lon = lons.average()
                                processor.haversineMeters(lat, lon, centerLat, centerLon) <=
                                        AppConfig.LIVE_STAY_MERGE_DISTANCE_THRESHOLD
                        }
                        .maxByOrNull { it.endTime.time }
                        ?.endTime
        }

        private suspend fun upsertOngoingFootprint(
                centerLat: Double,
                centerLon: Double,
                current: RawLocationStore.RawPoint,
                address: String?
        ) {
                val start = ongoingStayStart ?: return
                val durationSec = (current.timestamp.time - start.timestamp.time) / 1000.0
                if (durationSec < AppConfig.STAY_DURATION_THRESHOLD) return

                val rawPoints =
                        rawStore.loadRecentLocations(AppConfig.LOCATION_LOOKBACK_MAX_HOURS)
                                .filter {
                                        it.timestamp >= start.timestamp &&
                                                it.timestamp <= current.timestamp
                                }
                                .filter {
                                        it.accuracy > 0 &&
                                                it.accuracy < AppConfig.MAX_LOCATION_ACCURACY
                                }
                                .filter {
                                        processor.haversineMeters(
                                                centerLat,
                                                centerLon,
                                                it.latitude,
                                                it.longitude
                                        ) <= AppConfig.STAY_DISTANCE_THRESHOLD
                                }
                                .dropWhile { it.timestamp.before(start.timestamp) }
                                .ifEmpty { listOf(start, current) }

                val latJson = gson.toJson(rawPoints.map { it.latitude })
                val lonJson = gson.toJson(rawPoints.map { it.longitude })
                val locationHash = FootprintEntity.generateLocationHash(centerLat, centerLon)
                val places = db.placeDao().getAll()
                if (PlaceMatcher.ignoredPlaceForCoordinate(centerLat, centerLon, places, processor) != null) {
                        ongoingFootprintID = null
                        return
                }
                val matchedPlace = ongoingPlaceOverrideID?.let { overrideID ->
                        places.firstOrNull { it.placeID == overrideID && !it.isIgnored }
                } ?: PlaceMatcher.bestPlaceForCoordinate(centerLat, centerLon, places, processor)
                val geocode = if (ongoingPlaceOverrideName == null && address == null) {
                        geocoder.reverseGeocodeDetails(centerLat, centerLon)
                } else null
                val resolvedAddress = ongoingPlaceOverrideName ?: address ?: geocode?.address

                val existing =
                        ongoingFootprintID?.let { db.footprintDao().getById(it) }
                                ?: findExistingOngoingFootprint(
                                        start.timestamp,
                                        current.timestamp,
                                        centerLat,
                                        centerLon
                                )

                if (existing != null) {
                        ongoingFootprintID = existing.footprintID
                        val keepManualLocation = existing.isTitleEditedByHand
                        val updated =
                                existing.copy(
                                        endTime = maxOf(existing.endTime, current.timestamp),
                                        latitudeJson = latJson,
                                        longitudeJson = lonJson,
                                        locationHash = locationHash,
                                        placeID =
                                                if (keepManualLocation) existing.placeID
                                                else matchedPlace?.placeID ?: existing.placeID,
                                        address =
                                                if (keepManualLocation) existing.address
                                                else resolvedAddress ?: existing.address,
                                        countryCode = existing.countryCode ?: geocode?.countryCode,
                                        countryName = existing.countryName ?: geocode?.countryName,
                                        cityName = existing.cityName ?: geocode?.cityName
                                )
                        db.footprintDao().update(updated)
                        return
                }

                val entity =
                        FootprintEntity(
                                footprintID = UUID.randomUUID().toString(),
                                date = getStartOfDay(start.timestamp),
                                startTime = start.timestamp,
                                endTime = current.timestamp,
                                latitudeJson = latJson,
                                longitudeJson = lonJson,
                                locationHash = locationHash,
                                title =
                                        if (matchedPlace != null) {
                                                FootprintTitles.generate(
                                                        matchedPlace.name,
                                                        start.timestamp.time / 1000
                                                )
                                        } else if (resolvedAddress != null) {
                                                FootprintTitles.generate(
                                                        resolvedAddress,
                                                        start.timestamp.time / 1000
                                                )
                                        } else {
                                                FootprintTitles.generate(
                                                        "此处",
                                                        start.timestamp.time / 1000
                                                )
                                        },
                                statusValue = "candidate",
                                placeID = matchedPlace?.placeID,
                                address = resolvedAddress,
                                countryCode = geocode?.countryCode,
                                countryName = geocode?.countryName,
                                cityName = geocode?.cityName
                        )

                db.footprintDao().insert(entity)
                ongoingFootprintID = entity.footprintID
        }

        private suspend fun findExistingOngoingFootprint(
                start: Date,
                end: Date,
                centerLat: Double,
                centerLon: Double
        ): FootprintEntity? {
                val dayStart = getStartOfDay(start)
                val dayEnd = Date(dayStart.time + 86_400_000L)
                return db.footprintDao()
                        .getBetween(dayStart, dayEnd)
                        .filter {
                                it.endTime >=
                                        Date(
                                                start.time -
                                                        AppConfig.LIVE_STAY_MERGE_TIME_THRESHOLD
                                                                .toLong() * 1000
                                        ) && it.startTime <= end
                        }
                        .firstOrNull { footprint ->
                                val lats =
                                        gson.fromJson(
                                                        footprint.latitudeJson,
                                                        Array<Double>::class.java
                                                )
                                                .toList()
                                val lons =
                                        gson.fromJson(
                                                        footprint.longitudeJson,
                                                        Array<Double>::class.java
                                                )
                                                .toList()
                                if (lats.isEmpty() || lons.isEmpty()) return@firstOrNull false
                                val lat = lats.average()
                                val lon = lons.average()
                                processor.haversineMeters(lat, lon, centerLat, centerLon) <=
                                        AppConfig.LIVE_STAY_MERGE_DISTANCE_THRESHOLD
                        }
        }

        private fun checkAndSendNewPlaceNotification(
                lat: Double,
                lon: Double,
                startTime: Long,
                address: String?,
                footprintID: String?
        ) {
                serviceScope.launch {
                        val isEnabled = prefs.isHighlightNotificationEnabled.first()
                        if (!isEnabled) return@launch

                        val startTimeDate = Date(startTime)
                        val places = db.placeDao().getAll()
                        val matchedPlace =
                                PlaceMatcher.bestPlaceForCoordinate(lat, lon, places, processor)

                        var lastVisit: FootprintEntity? = null
                        var isNewPlace = false

                        if (matchedPlace != null) {
                                lastVisit =
                                        db.footprintDao()
                                                .getLastVisitToPlace(
                                                        matchedPlace.placeID,
                                                        startTimeDate
                                                )
                                if (lastVisit == null) isNewPlace = true
                        } else {
                                val hash = FootprintEntity.generateLocationHash(lat, lon)
                                lastVisit =
                                        db.footprintDao().getLastVisitToHash(hash, startTimeDate)
                                if (lastVisit == null) isNewPlace = true
                        }

                        var isLongTimeNoSee = false
                        if (lastVisit != null) {
                                val diffDays =
                                        (startTime - lastVisit.startTime.time) /
                                                (1000 * 60 * 60 * 24)
                                if (diffDays >= 30) {
                                        isLongTimeNoSee = true
                                }
                        }

                        if (isNewPlace || isLongTimeNoSee) {
                                val title = if (isNewPlace) "发现新地方" else "久违了"
                                val placeName = matchedPlace?.name ?: address ?: "这个位置"
                                val body =
                                        if (isNewPlace) {
                                                "你第一次在「$placeName」留下足迹，开启一段新回忆吧。"
                                        } else {
                                                val diffDays =
                                                        (startTime - lastVisit!!.startTime.time) /
                                                                (1000 * 60 * 60 * 24)
                                                "你已经有 $diffDays 天没来「$placeName」了，欢迎回来。"
                                        }

                                NotificationHelper.sendHighlightNotification(
                                        this@LocationTrackingService,
                                        title,
                                        body,
                                        startTime.hashCode(),
                                        timestamp = startTime,
                                        footprintId = footprintID
                                )
                        }
                }
        }

        private fun loadPersistedStayState() {
                if (hasAttemptedPersistedStayRestore) return
                hasAttemptedPersistedStayRestore = true
                serviceScope.launch {
                        val lat = prefs.getPendingStayLat()
                        val lon = prefs.getPendingStayLon()
                        val time = prefs.getPendingStayStartTime()
                        val addr = prefs.getPendingStayAddress()
                        val placeOverrideID = prefs.getPendingStayPlaceOverride()

                        if (lat != null && lon != null && time != null) {
                                // 校验时间是否在 24 小时内（防止跨天且没结算的错误状态）
                                if (System.currentTimeMillis() - (time as Long) <
                                                AppConfig.LOCATION_LOOKBACK_MAX_HOURS * 3600 * 1000
                                ) {
                                        val recoveredPoint =
                                                RawLocationStore.RawPoint(
                                                        timestamp = Date(time as Long),
                                                        latitude = lat,
                                                        longitude = lon,
                                                        accuracy = 50.0,
                                                        speed = 0.0
                                                )
                                        val overridePlace = placeOverrideID?.let { db.placeDao().getById(it) }
                                            ?.takeIf { !it.isIgnored }
                                        if (placeOverrideID != null && overridePlace == null) {
                                                prefs.setPendingStayPlaceOverride(null)
                                        }
                                        ongoingStayStart = recoveredPoint
                                        ongoingStayAddress = overridePlace?.name ?: addr
                                        ongoingPlaceOverrideID = overridePlace?.placeID
                                        ongoingPlaceOverrideName = overridePlace?.name

                                        stateFlow.value =
                                                TrackingState.OngoingStay(
                                                        since = Date(time as Long),
                                                        lat = lat,
                                                        lon = lon,
                                                        address = ongoingStayAddress,
                                                        speed = 0.0
                                                )
                                        Log.i(
                                                TAG,
                                                "Successfully recovered ongoing stay from storage: $ongoingStayAddress"
                                        )
                                }
                        }
                }
        }

        private suspend fun saveFootprint(
                candidate: com.ct106.difangke.data.model.CandidateFootprint
        ) {
                // ... (省略逻辑与之前一致，复用之前的逻辑) ...
                // 为了确保代码完整，由于 write_to_file 是覆盖，我需要贴出之前的完整逻辑
                val durationSec = candidate.duration
                if (durationSec < AppConfig.STAY_DURATION_THRESHOLD) return

                val latJson = gson.toJson(candidate.rawLatitudes)
                val lonJson = gson.toJson(candidate.rawLongitudes)

                val recentCutoff =
                        Date(
                                candidate.startTime.time -
                                        AppConfig.LIVE_STAY_MERGE_TIME_THRESHOLD.toLong() * 1000
                        )
                val lastFp = db.footprintDao().getLastFootprintAfter(recentCutoff)

                if (lastFp != null) {
                        val existingLats =
                                gson.fromJson(lastFp.latitudeJson, Array<Double>::class.java)
                                        .toList()
                        val existingLons =
                                gson.fromJson(lastFp.longitudeJson, Array<Double>::class.java)
                                        .toList()
                        val avgLat = if (existingLats.isNotEmpty()) existingLats.average() else 0.0
                        val avgLon = if (existingLons.isNotEmpty()) existingLons.average() else 0.0

                        if (processor.shouldMerge(lastFp.endTime, avgLat, avgLon, candidate)) {
                                // Filter candidate points to only include those newer than lastFp's
                                // endTime to
                                // avoid duplication
                                // Because lastFp might be the ongoing footprint which already
                                // contains points up to
                                // its own endTime
                                val newPointsCutoff = lastFp.endTime.time
                                val newLats = mutableListOf<Double>()
                                val newLons = mutableListOf<Double>()

                                // We don't have timestamps for individual candidate points easily
                                // here,
                                // but we know candidate covers [startTime, endTime].
                                // If lastFp is the ongoing footprint, lastFp.endTime is very close
                                // to
                                // candidate.endTime.
                                // A safer way is to just fetch the raw points from DB for the
                                // merged range,
                                // or just overwrite if it's the identical ongoing footprint.
                                // Since this is tricky without timestamps, let's just use the fact
                                // that if
                                // lastFp.endTime >= candidate.endTime, we don't need to append.
                                if (lastFp.footprintID == ongoingFootprintID) {
                                        // It's the ongoing footprint! The candidate represents the
                                        // EXACT same stay.
                                        // We can just use candidate's points directly (or keep
                                        // lastFp's points if they
                                        // are richer).
                                        // Actually, candidate points are from memory queue,
                                        // existing points are from
                                        // DB. Let's just use the longer one.
                                        val merged =
                                                lastFp.copy(
                                                        endTime = candidate.endTime,
                                                        latitudeJson =
                                                                if (candidate.rawLatitudes.size >
                                                                                existingLats.size
                                                                )
                                                                        gson.toJson(
                                                                                candidate
                                                                                        .rawLatitudes
                                                                        )
                                                                else lastFp.latitudeJson,
                                                        longitudeJson =
                                                                if (candidate.rawLongitudes.size >
                                                                                existingLons.size
                                                                )
                                                                        gson.toJson(
                                                                                candidate
                                                                                        .rawLongitudes
                                                                        )
                                                                else lastFp.longitudeJson
                                                )
                                        db.footprintDao().update(merged)
                                        ongoingFootprintID = null // clear it
                                        return
                                }

                                val merged =
                                        lastFp.copy(
                                                endTime = candidate.endTime,
                                                latitudeJson =
                                                        gson.toJson(
                                                                existingLats +
                                                                        candidate.rawLatitudes
                                                        ),
                                                longitudeJson =
                                                        gson.toJson(
                                                                existingLons +
                                                                        candidate.rawLongitudes
                                                        )
                                        )
                                db.footprintDao().update(merged)
                                return
                        }
                }

                val geocode = geocoder.reverseGeocodeDetails(candidate.latitude, candidate.longitude)
                val address = geocode?.address
                val locationHash =
                        FootprintEntity.generateLocationHash(
                                candidate.latitude,
                                candidate.longitude
                        )
                val places = db.placeDao().getAll()
                if (PlaceMatcher.ignoredPlaceForCoordinate(candidate.latitude, candidate.longitude, places, processor) != null) {
                        ongoingFootprintID = null
                        return
                }
                val matchedPlace =
                        PlaceMatcher.bestPlaceForCoordinate(
                                candidate.latitude,
                                candidate.longitude,
                                places,
                                processor
                        )

                val finalId = ongoingFootprintID ?: UUID.randomUUID().toString()
                val entity =
                        FootprintEntity(
                                footprintID = finalId,
                                date = candidate.startTime,
                                startTime = candidate.startTime,
                                endTime = candidate.endTime,
                                latitudeJson = latJson,
                                longitudeJson = lonJson,
                                locationHash = locationHash,
                                title =
                                        if (matchedPlace != null)
                                                FootprintTitles.generate(
                                                        matchedPlace.name,
                                                        candidate.startTime.time / 1000
                                                )
                                        else {
                                                if (address != null)
                                                        FootprintTitles.generate(
                                                                address,
                                                                candidate.startTime.time / 1000
                                                        )
                                                else
                                                        FootprintTitles.generate(
                                                                "此处",
                                                                candidate.startTime.time / 1000
                                                        )
                                        },
                                statusValue = "candidate",
                                placeID = matchedPlace?.placeID,
                                address = address,
                                countryCode = geocode?.countryCode,
                                countryName = geocode?.countryName,
                                cityName = geocode?.cityName
                        )

                db.footprintDao().insert(entity)
                ongoingFootprintID = null // clear ongoing state after finalizing

                lastFp?.let { prev -> saveTransportSegment(prev, entity) }
        }

        private suspend fun saveTransportSegment(prevFp: FootprintEntity, newFp: FootprintEntity) {
                val gapSec = (newFp.startTime.time - prevFp.endTime.time) / 1000.0
                if (gapSec < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD) return

                var rawPoints =
                        rawStore.loadRecentLocations(
                                        lookbackHours = AppConfig.LOCATION_LOOKBACK_HOURS * 2
                                ) // 稍微多拿点点
                                .filter {
                                        it.timestamp >= prevFp.endTime &&
                                                it.timestamp <= newFp.startTime
                                }

                if (rawPoints.isEmpty() && gapSec > 14400) {
                        rawPoints =
                                rawStore.loadRecentLocations(
                                                lookbackHours =
                                                        AppConfig.LOCATION_LOOKBACK_MAX_HOURS / 3
                                        ) // 1/3 of max
                                        .filter {
                                                it.timestamp >= prevFp.endTime &&
                                                        it.timestamp <= newFp.startTime
                                        }
                }

                val totalDist: Double
                val avgSpeed: Double
                val pointsJson: String

                val prevLats =
                        gson.fromJson(prevFp.latitudeJson, Array<Double>::class.java).toList()
                val prevLons =
                        gson.fromJson(prevFp.longitudeJson, Array<Double>::class.java).toList()
                val newLats = gson.fromJson(newFp.latitudeJson, Array<Double>::class.java).toList()
                val newLons = gson.fromJson(newFp.longitudeJson, Array<Double>::class.java).toList()

                val lat1 = if (prevLats.isNotEmpty()) prevLats.average() else 0.0
                val lon1 = if (prevLons.isNotEmpty()) prevLons.average() else 0.0
                val lat2 = if (newLats.isNotEmpty()) newLats.average() else 0.0
                val lon2 = if (newLons.isNotEmpty()) newLons.average() else 0.0

                val pts = mutableListOf<List<Double>>()
                if (lat1 != 0.0) pts.add(listOf(lat1, lon1, prevFp.endTime.time.toDouble()))
                if (rawPoints.isNotEmpty()) {
                        pts.addAll(
                                rawPoints.map {
                                        listOf(
                                                it.latitude,
                                                it.longitude,
                                                it.timestamp.time.toDouble()
                                        )
                                }
                        )
                }
                if (lat2 != 0.0) pts.add(listOf(lat2, lon2, newFp.startTime.time.toDouble()))

                totalDist =
                        pts
                                .zipWithNext { a, b ->
                                        processor.haversineMeters(a[0], a[1], b[0], b[1])
                                }
                                .sum()

                if (rawPoints.isEmpty()) {
                        if (totalDist > 200.0 &&
                                        gapSec > AppConfig.LIVE_STAY_MIN_DURATION_THRESHOLD / 2
                        ) {
                                avgSpeed = totalDist / gapSec
                                pointsJson = gson.toJson(pts)
                        } else {
                                return
                        }
                } else {
                        if (totalDist < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return
                        avgSpeed = totalDist / gapSec
                        pointsJson = gson.toJson(pts)
                }

                val transportType =
                        TransportType.from(
                                speedMs = avgSpeed,
                                durationSec = gapSec.toLong(),
                                distanceMeters = totalDist,
                                pointCount = pts.size,
                                preferredTransport = getPreferredTransportType(getStartOfDay(prevFp.endTime))
                        )
                val record =
                        TransportRecordEntity(
                                recordID = UUID.randomUUID().toString(),
                                day = getStartOfDay(prevFp.endTime),
                                startTime = prevFp.endTime,
                                endTime = newFp.startTime,
                                startLocation =
                                        if (!prevFp.address.isNullOrEmpty() &&
                                                        !FootprintTitles.isGeneric(prevFp.address!!)
                                        )
                                                prevFp.address!!
                                        else FootprintTitles.extractLocation(prevFp.title ?: ""),
                                endLocation =
                                        if (!newFp.address.isNullOrEmpty() &&
                                                        !FootprintTitles.isGeneric(newFp.address!!)
                                        )
                                                newFp.address!!
                                        else FootprintTitles.extractLocation(newFp.title ?: ""),
                                typeRaw = transportType.raw,
                                distance = totalDist,
                                averageSpeed = avgSpeed,
                                pointsJson = pointsJson,
                                statusRaw = "active"
                        )
                db.transportRecordDao().insert(record)
        }

        private suspend fun getPreferredTransportType(excludingDate: Date): TransportType? {
                val recent = db.transportRecordDao().getRecentExcluding(excludingDate, 300)
                val counts = mutableMapOf<TransportType, Int>()
                for (record in recent) {
                        val type = TransportType.from(record.manualTypeRaw ?: record.typeRaw)
                        if (TransportType.getCategory(type) > 1) {
                                counts[type] = (counts[type] ?: 0) + 1
                        }
                }
                val highestCount = counts.values.maxOrNull() ?: return null
                return TransportType.entries.firstOrNull { counts[it] == highestCount }
        }

        private fun getStartOfDay(date: Date): Date {
                val cal =
                        Calendar.getInstance().apply {
                                time = date
                                set(Calendar.HOUR_OF_DAY, 0)
                                set(Calendar.MINUTE, 0)
                                set(Calendar.SECOND, 0)
                                set(Calendar.MILLISECOND, 0)
                        }
                return cal.time
        }

        override fun onDestroy() {
                initialLocationFallbackJob?.cancel()
                initialLocationFallbackJob = null
                locationClient?.disableForegroundLocation(true)
                locationClient?.removeUpdates(locationListener)
                locationClient = null
                serviceScope.cancel()
                stateFlow.value = TrackingState.Idle
                super.onDestroy()
        }

        override fun onBind(intent: Intent?): IBinder? = null
}
