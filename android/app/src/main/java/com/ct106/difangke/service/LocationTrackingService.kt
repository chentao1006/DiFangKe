package com.ct106.difangke.service

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.ServiceCompat
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.tracking.DailyStats
import com.ct106.difangke.service.tracking.DepartureDetector
import com.ct106.difangke.service.tracking.GeoMath
import com.ct106.difangke.service.tracking.GeocodeThrottle
import com.ct106.difangke.service.tracking.LiveFootprintRules
import com.ct106.difangke.service.tracking.LiveFootprintStore
import com.ct106.difangke.service.tracking.LiveIngestFilter
import com.ct106.difangke.service.tracking.MotionSensorMonitor
import com.ct106.difangke.service.tracking.MovementHysteresis
import com.ct106.difangke.service.tracking.RawSaveThrottle
import com.ct106.difangke.service.tracking.SiftDebouncer
import com.ct106.difangke.service.tracking.StationaryAnchorDetector
import com.ct106.difangke.service.tracking.TrackingConfig
import com.ct106.difangke.service.tracking.TrackingFix
import com.tencent.map.geolocation.TencentLocation
import com.tencent.map.geolocation.TencentLocationListener
import com.tencent.map.geolocation.TencentLocationManager
import com.tencent.map.geolocation.TencentLocationRequest
import java.util.Calendar
import java.util.Date
import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 后台位置追踪前台服务（腾讯定位 SDK）。
 *
 * The live pipeline ports iOS `LocationManager.processLocationUpdate`:
 * drift pre-filter → movement evidence + UI hysteresis → stationary
 * low-power / departure watch → throttled raw persistence → debounced
 * timeline sift → live candidate footprints, merging and notifications.
 */
class LocationTrackingService : Service() {

        companion object {
                private const val TAG = "LocationTrackingService"
                const val ACTION_START = "START_TRACKING"
                const val ACTION_STOP = "STOP_TRACKING"
                const val ACTION_SET_ONGOING_PLACE = "SET_ONGOING_PLACE"
                const val ACTION_CONFIRM_ARRIVAL = "CONFIRM_ARRIVAL"
                private const val EXTRA_ONGOING_PLACE_ID = "ongoing_place_id"
                private const val EXTRA_ONGOING_PLACE_NAME = "ongoing_place_name"

                val stateFlow = MutableStateFlow<TrackingState>(TrackingState.Idle)

                private val liveStatusState = MutableStateFlow(LiveTrackingStatus())

                /** Live Activity-equivalent state for UI (moving/staying, start times, power mode). */
                val liveStatusFlow: StateFlow<LiveTrackingStatus> = liveStatusState.asStateFlow()

                @Volatile private var activeInstance: LocationTrackingService? = null

                @Deprecated("Movement is now derived internally (iOS parity); kept for source compatibility.")
                var isHighAccuracyBoostEnabled = false

                fun start(context: Context) {
                        val intent = Intent(context, LocationTrackingService::class.java).apply {
                                action = ACTION_START
                        }
                        runCatching {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        context.startForegroundService(intent)
                                } else {
                                        context.startService(intent)
                                }
                        }.onFailure { Log.e(TAG, "Unable to start tracking service", it) }
                }

                fun stop(context: Context) {
                        // Go through ACTION_STOP so the service clears its persisted
                        // active-stay state before stopping.
                        val intent = Intent(context, LocationTrackingService::class.java).apply {
                                action = ACTION_STOP
                        }
                        runCatching { context.startService(intent) }
                                .onFailure { context.stopService(intent) }
                        stateFlow.value = TrackingState.Idle
                        liveStatusState.value = LiveTrackingStatus()
                }

                /** Assign the active stay to a user-selected place without waiting for a new GPS sample. */
                fun setOngoingPlace(context: Context, placeID: String?, placeName: String) {
                        val instance = activeInstance
                        if (instance != null) {
                                instance.applyOngoingPlaceOverride(placeID, placeName)
                                return
                        }
                        val intent = Intent(context, LocationTrackingService::class.java).apply {
                                action = ACTION_SET_ONGOING_PLACE
                                placeID?.let { putExtra(EXTRA_ONGOING_PLACE_ID, it) }
                                putExtra(EXTRA_ONGOING_PLACE_NAME, placeName)
                        }
                        runCatching {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        context.startForegroundService(intent)
                                } else {
                                        context.startService(intent)
                                }
                        }
                }

                /**
                 * iOS `confirmArrival()` ("我已到达"): closes the live trip at the
                 * latest known coordinate, starts a stay now, persists the
                 * boundary sample and runs a fresh timeline sift.
                 *
                 * @return false when tracking is not running or the user is not
                 *   currently moving (there is already a stay).
                 */
                suspend fun confirmArrival(): Boolean =
                        activeInstance?.confirmArrivalInternal() ?: false

                /** Fire-and-forget variant for non-coroutine callers (e.g. widgets). */
                fun requestConfirmArrival(context: Context) {
                        val instance = activeInstance ?: return
                        instance.serviceScope.launch { instance.confirmArrivalInternal() }
                }
        }

        sealed class TrackingState {
                object Idle : TrackingState()
                data class Tracking(
                        val lat: Double? = null,
                        val lon: Double? = null,
                        val speed: Double = 0.0,
                        /** Stable (120 s hysteresis) moving state; prefer this over `speed` in UI. */
                        val isMoving: Boolean = false,
                        /** When the current trip started, if known. */
                        val movingSince: Date? = null
                ) : TrackingState()
                data class OngoingStay(
                        val since: Date,
                        val lat: Double,
                        val lon: Double,
                        val address: String? = null,
                        val speed: Double = 0.0
                ) : TrackingState()
        }

        /** Snapshot of the live tracking state (Android analog of the iOS Live Activity content). */
        data class LiveTrackingStatus(
                val isTracking: Boolean = false,
                /** iOS `isCurrentlyMoving`: moving and no stay anchor. */
                val isMoving: Boolean = false,
                val stayStart: Date? = null,
                val stayLat: Double? = null,
                val stayLon: Double? = null,
                val placeName: String? = null,
                val movingSince: Date? = null,
                val transportTypeRaw: String? = null,
                val lastFixTime: Date? = null,
                val isStationaryLowPower: Boolean = false,
                val todayPlaceCount: Int = 0,
                val todayMileageMeters: Double = 0.0
        ) {
                /** "我已到达" is offered only while moving (iOS guard). */
                val canConfirmArrival: Boolean get() = isTracking && stayStart == null
        }

        private enum class LocationProfile { INITIAL, INITIAL_FALLBACK, MOVING, CONTINUOUS, LOW_POWER_WATCH, POWER_SAVING, HIGH, BALANCED }

        val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val prefs by lazy { (application as DiFangKeApp).preferences }
        private val rawStore by lazy { RawLocationStore.getInstance(applicationContext) }
        private val db by lazy { DiFangKeApp.instance.database }
        private val geocoder by lazy { GeocodeService.shared }
        private val processor = FootprintProcessor.shared
        private val footprintStore by lazy { LiveFootprintStore(db) }
        private val mainHandler = Handler(Looper.getMainLooper())

        private var locationClient: TencentLocationManager? = null
        private val stateMutex = Mutex()
        private val siftMutex = Mutex()
        private val fixChannel = Channel<Pair<TrackingFix, String?>>(Channel.UNLIMITED)

        // ── Live state (guarded by stateMutex) ──
        private val trackingPoints = ArrayList<TrackingFix>()
        private var lastProcessedMs = Long.MIN_VALUE
        private var lastLocation: TrackingFix? = null
        private var lastFreshUpdateMs: Long? = null
        private var potentialStop: TrackingFix? = null
        private var stayAddress: String? = null
        private var currentAddress: String? = null
        private var ongoingPlaceOverrideID: String? = null
        private var ongoingPlaceOverrideName: String? = null
        private var movingSinceMs: Long? = null
        private var lastOngoingUpsertMs = Long.MIN_VALUE
        private var lastOngoingTitleRefreshMs = Long.MIN_VALUE
        private val notifiedFootprintIDs = HashSet<String>()

        private val hysteresis = MovementHysteresis()
        private val anchorDetector = StationaryAnchorDetector()
        private val rawThrottle = RawSaveThrottle()
        private val siftDebouncer = SiftDebouncer()
        private val geocodeThrottle = GeocodeThrottle()

        // ── Power management ──
        @Volatile private var isLowPower = false
        private var lowPowerAnchor: TrackingFix? = null
        @Volatile private var departureBoostEndMs = 0L
        private var lastStationaryProbeMs = 0L
        private var lastRecoveryBoostMs = 0L
        private var startTrackingAtMs = 0L
        @Volatile private var isTrackingActive = false
        @Volatile private var currentAccuracyMode = "automatic"
        @Volatile private var hasAcquiredFirstLocation = false
        @Volatile private var initialLocationAcquisitionTimedOut = false
        @Volatile private var appliedProfileKey: String? = null
        private var wasVpnOrProxyActive: Boolean? = null
        private var lastWasWifi: Boolean? = null

        // ── Jobs ──
        private var initialLocationFallbackJob: Job? = null
        private var watchdogJob: Job? = null
        private var liveMergeJob: Job? = null
        private var hasAttemptedPersistedStayRestore = false
        @Volatile private var cachedPlaces: List<PlaceEntity> = emptyList()
        @Volatile private var liveNotificationEnabled = true
        private var lastNotificationKey: String? = null

        private val motion by lazy {
                MotionSensorMonitor(
                        this,
                        onMovingEvidence = { serviceScope.launch { onMotionMovingEvidence() } },
                        onSignificantMotion = { serviceScope.launch { onSignificantMotion() } }
                )
        }

        // ────────────────────────────────────────────────────────────
        // Location client
        // ────────────────────────────────────────────────────────────

        private fun isVpnOrProxyActive(): Boolean {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                val activeNetwork = cm?.activeNetwork ?: return false
                val capabilities = cm.getNetworkCapabilities(activeNetwork) ?: return false
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return true
                val proxyInfo = cm.defaultProxy
                if (proxyInfo != null && (!proxyInfo.host.isNullOrEmpty() || proxyInfo.pacFileUrl != null)) return true
                val host = System.getProperty("http.proxyHost")
                val port = System.getProperty("http.proxyPort")
                return !host.isNullOrEmpty() && !port.isNullOrEmpty()
        }

        /** VPN/proxy makes network positioning drift; use GPS only once a first fix exists. */
        private fun preciseLocationMode(): Int =
                if (isVpnOrProxyActive() && hasAcquiredFirstLocation) TencentLocationRequest.ONLY_GPS_MODE
                else TencentLocationRequest.HIGH_ACCURACY_MODE

        private fun desiredProfile(): LocationProfile = when {
                !hasAcquiredFirstLocation && !initialLocationAcquisitionTimedOut -> LocationProfile.INITIAL
                !hasAcquiredFirstLocation -> LocationProfile.INITIAL_FALLBACK
                currentAccuracyMode == "high" -> LocationProfile.HIGH
                currentAccuracyMode == "balanced" -> LocationProfile.BALANCED
                currentAccuracyMode == "powerSaving" -> LocationProfile.POWER_SAVING
                isLowPower -> LocationProfile.LOW_POWER_WATCH
                hysteresis.isMoving || System.currentTimeMillis() < departureBoostEndMs -> LocationProfile.MOVING
                else -> LocationProfile.CONTINUOUS
        }

        /**
         * Applies the location request for the current profile. Tencent's
         * manager creates a Handler internally, so this always runs on main.
         */
        private fun applyLocationProfile(force: Boolean = false) {
                if (Looper.myLooper() != Looper.getMainLooper()) {
                        mainHandler.post { applyLocationProfile(force) }
                        return
                }
                val client = locationClient ?: return
                if (!isTrackingActive) return
                val profile = desiredProfile()
                val (mode, interval, allowGps) = when (profile) {
                        LocationProfile.INITIAL -> Triple(TencentLocationRequest.HIGH_ACCURACY_MODE, 2_000L, true)
                        LocationProfile.INITIAL_FALLBACK -> Triple(TencentLocationRequest.ONLY_NETWORK_MODE, TrackingConfig.POWER_SAVING_INTERVAL_MS, false)
                        LocationProfile.HIGH -> Triple(preciseLocationMode(), 5_000L, true)
                        LocationProfile.BALANCED -> Triple(preciseLocationMode(), 15_000L, true)
                        LocationProfile.POWER_SAVING -> Triple(TencentLocationRequest.ONLY_NETWORK_MODE, TrackingConfig.POWER_SAVING_INTERVAL_MS, false)
                        LocationProfile.MOVING -> Triple(preciseLocationMode(), TrackingConfig.MOVING_INTERVAL_MS, true)
                        LocationProfile.CONTINUOUS -> Triple(preciseLocationMode(), TrackingConfig.UNCONFIRMED_STATIONARY_INTERVAL_MS, true)
                        LocationProfile.LOW_POWER_WATCH ->
                                // With a hardware significant-motion wake-up the watch can stay
                                // network-only; otherwise keep a sparse GPS-allowed watch.
                                if (motion.hasSignificantMotionSensor && !(isVpnOrProxyActive())) {
                                        Triple(TencentLocationRequest.ONLY_NETWORK_MODE, TrackingConfig.LOW_POWER_WATCH_INTERVAL_MS, false)
                                } else {
                                        Triple(preciseLocationMode(), TrackingConfig.LOW_POWER_WATCH_GPS_INTERVAL_MS, true)
                                }
                }
                val key = "$profile/$mode/$interval/$allowGps"
                if (!force && key == appliedProfileKey) return
                appliedProfileKey = key
                client.removeUpdates(locationListener)
                client.requestLocationUpdates(
                        TencentLocationRequest.create()
                                .setLocMode(mode)
                                .setInterval(interval)
                                .setRequestLevel(TencentLocationRequest.REQUEST_LEVEL_GEO)
                                .setAllowGPS(allowGps)
                                .setAllowCache(!allowGps),
                        locationListener,
                        Looper.getMainLooper()
                )
                Log.d(TAG, "Location profile $key")
        }

        private fun scheduleInitialLocationFallback() {
                if (hasAcquiredFirstLocation || initialLocationFallbackJob != null) return
                initialLocationFallbackJob = serviceScope.launch {
                        delay(2 * 60_000L)
                        if (!hasAcquiredFirstLocation) {
                                initialLocationAcquisitionTimedOut = true
                                Log.w(TAG, "Initial location timed out; switching to low-power network location")
                                applyLocationProfile()
                        }
                }
        }

        private val locationListener = object : TencentLocationListener {
                override fun onStatusUpdate(name: String?, status: Int, desc: String?) = Unit

                override fun onLocationChanged(location: TencentLocation?, errorCode: Int, errorInfo: String?) {
                        val vpn = isVpnOrProxyActive()
                        val networkStateChanged = wasVpnOrProxyActive != vpn
                        if (networkStateChanged) wasVpnOrProxyActive = vpn

                        if (location != null && errorCode == TencentLocation.ERROR_OK) {
                                if (!hasAcquiredFirstLocation) {
                                        hasAcquiredFirstLocation = true
                                        initialLocationFallbackJob?.cancel()
                                        initialLocationFallbackJob = null
                                        applyLocationProfile()
                                } else if (networkStateChanged) {
                                        applyLocationProfile(force = true)
                                }
                                val fix = TrackingFix(
                                        timeMs = location.time,
                                        latitude = location.latitude,
                                        longitude = location.longitude,
                                        accuracy = location.accuracy.toDouble(),
                                        speed = location.speed.toDouble()
                                )
                                fixChannel.trySend(fix to getShortAddress(location))
                        } else {
                                Log.e(TAG, "定位失败: $errorCode - $errorInfo (VPN/代理: $vpn)")
                                if (networkStateChanged) applyLocationProfile(force = true)
                        }
                }
        }

        /** One-shot listener for the stationary departure probe. */
        private val probeListener = object : TencentLocationListener {
                override fun onStatusUpdate(name: String?, status: Int, desc: String?) = Unit
                override fun onLocationChanged(location: TencentLocation?, errorCode: Int, errorInfo: String?) {
                        if (location == null || errorCode != TencentLocation.ERROR_OK) return
                        fixChannel.trySend(
                                TrackingFix(location.time, location.latitude, location.longitude,
                                        location.accuracy.toDouble(), location.speed.toDouble()) to getShortAddress(location)
                        )
                }
        }

        private fun getShortAddress(location: TencentLocation): String? =
                geocoder.coarseAutomaticPlaceName(
                        listOf(
                                location.poiList?.firstOrNull()?.name,
                                location.name,
                                listOfNotNull(location.district, location.street).joinToString("")
                        )
                )

        // ────────────────────────────────────────────────────────────
        // Lifecycle
        // ────────────────────────────────────────────────────────────

        override fun onCreate() {
                super.onCreate()
                activeInstance = this
                NotificationHelper.cleanupLegacyChannels(this)
                loadPersistedStayState()

                serviceScope.launch {
                        prefs.locationAccuracyMode.collect { mode ->
                                val changed = mode != currentAccuracyMode
                                currentAccuracyMode = mode
                                if (changed && mode != "automatic" && isLowPower) {
                                        stateMutex.withLock { exitLowPower() }
                                }
                                applyLocationProfile()
                        }
                }
                serviceScope.launch {
                        prefs.isLiveNotificationEnabled.collect { enabled ->
                                liveNotificationEnabled = enabled
                                lastNotificationKey = null
                                publishNotification()
                        }
                }
                serviceScope.launch {
                        db.placeDao().observeAll().collect { cachedPlaces = it }
                }
                serviceScope.launch {
                        for ((fix, address) in fixChannel) {
                                runCatching { stateMutex.withLock { processFix(fix, address) } }
                                        .onFailure { Log.e(TAG, "Failed to process location", it) }
                        }
                }

                try {
                        locationClient = TencentLocationManager.getInstance(applicationContext).also {
                                it.setCoordinateType(TencentLocationManager.COORDINATE_TYPE_GCJ02)
                                it.setMockEnable(false)
                        }
                        wasVpnOrProxyActive = isVpnOrProxyActive()
                } catch (e: Exception) {
                        Log.e(TAG, "初始化腾讯定位失败", e)
                }
                registerNetworkCallback()
        }

        private fun startForegroundSafely(): Boolean {
                val notification = NotificationHelper.buildTrackingNotification(this)
                return try {
                        ServiceCompat.startForeground(
                                this,
                                NotificationHelper.TRACKING_NOTIFICATION_ID,
                                notification,
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                                        ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
                        )
                        true
                } catch (e: Exception) {
                        // Missing location permission (API 34+) or a background start restriction.
                        Log.e(TAG, "Unable to enter foreground", e)
                        false
                }
        }

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
                val action = intent?.action ?: ACTION_START
                if (action == ACTION_STOP) {
                        stopTracking()
                        return START_NOT_STICKY
                }
                if (!startForegroundSafely()) {
                        stopSelf()
                        return START_NOT_STICKY
                }
                when (action) {
                        ACTION_START -> startTracking()
                        ACTION_SET_ONGOING_PLACE -> {
                                if (!isTrackingActive) startTracking()
                                val placeID = intent?.getStringExtra(EXTRA_ONGOING_PLACE_ID)
                                val placeName = intent?.getStringExtra(EXTRA_ONGOING_PLACE_NAME)
                                if (!placeName.isNullOrBlank()) applyOngoingPlaceOverride(placeID, placeName)
                        }
                        ACTION_CONFIRM_ARRIVAL -> {
                                if (!isTrackingActive) startTracking()
                                serviceScope.launch { confirmArrivalInternal() }
                        }
                }
                return START_STICKY
        }

        private fun startTracking() {
                val wasActive = isTrackingActive
                isTrackingActive = true
                if (!wasActive) startTrackingAtMs = System.currentTimeMillis()
                wasVpnOrProxyActive = isVpnOrProxyActive()
                scheduleInitialLocationFallback()
                appliedProfileKey = null
                applyLocationProfile()
                runCatching {
                        locationClient?.enableForegroundLocation(
                                NotificationHelper.TRACKING_NOTIFICATION_ID,
                                NotificationHelper.buildTrackingNotification(this)
                        )
                }
                motion.start()
                startWatchdog()
                if (stateFlow.value !is TrackingState.OngoingStay) {
                        stateFlow.value = TrackingState.Tracking()
                }
                serviceScope.launch {
                        refreshTodayStats()
                        publishState()
                        // A process restart can leave persisted raw points without
                        // their footprint; reconcile on service recovery too.
                        if (siftDebouncer.shouldSift(false, System.currentTimeMillis())) runSift()
                }
                Log.i(TAG, "Tracking started")
        }

        private fun stopTracking() {
                isTrackingActive = false
                initialLocationFallbackJob?.cancel()
                initialLocationFallbackJob = null
                watchdogJob?.cancel()
                motion.stop()
                runCatching { locationClient?.disableForegroundLocation(true) }
                locationClient?.removeUpdates(locationListener)
                appliedProfileKey = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                // Clear the persisted stay before stopSelf(): onDestroy cancels
                // serviceScope, so a launched clear could be dropped and a restart
                // within 24 h would resurrect the old stay with its old start time.
                runBlocking(NonCancellable + Dispatchers.IO) {
                        prefs.savePendingStay(null, null, null, null)
                        prefs.setPendingStayPlaceOverride(null)
                }
                stateFlow.value = TrackingState.Idle
                liveStatusState.value = LiveTrackingStatus()
                stopSelf()
                Log.i(TAG, "Tracking stopped")
        }

        override fun onDestroy() {
                isTrackingActive = false
                if (activeInstance === this) activeInstance = null
                initialLocationFallbackJob?.cancel()
                watchdogJob?.cancel()
                motion.stop()
                unregisterNetworkCallback()
                runCatching { locationClient?.disableForegroundLocation(true) }
                locationClient?.removeUpdates(locationListener)
                locationClient?.removeUpdates(probeListener)
                locationClient = null
                fixChannel.close()
                serviceScope.cancel()
                stateFlow.value = TrackingState.Idle
                liveStatusState.value = LiveTrackingStatus()
                super.onDestroy()
        }

        override fun onBind(intent: Intent?): IBinder? = null

        // ────────────────────────────────────────────────────────────
        // Core pipeline (iOS processLocationUpdate)
        // ────────────────────────────────────────────────────────────

        private suspend fun processFix(fix: TrackingFix, tencentAddress: String?) {
                if (fix.accuracy < 0 || !fix.latitude.isFinite() || !fix.longitude.isFinite()) return
                if (fix.latitude == 0.0 && fix.longitude == 0.0) return
                val now = System.currentTimeMillis()
                val isFresh = abs(fix.timeMs - now) < TrackingConfig.FRESH_FIX_MAX_AGE * 1000
                if (potentialStop == null && !hasAttemptedPersistedStayRestore) loadPersistedStayState()

                // Drift pre-filter: impossible jumps never reach the raw CSV.
                if (!LiveIngestFilter.shouldAccept(fix, trackingPoints)) {
                        Log.d(TAG, "Skipping drift fix acc=${fix.accuracy}")
                        return
                }

                val previousLocation = lastLocation
                if (previousLocation == null || fix.timeMs >= previousLocation.timeMs) lastLocation = fix
                if (isFresh) lastFreshUpdateMs = now

                val isMovingBySensor = motion.isMovingBySensor
                // Step-counter "stationary" is only trusted to veto noisy GPS
                // speed while a stay anchor exists; in a vehicle there are no
                // steps, and Android has no automotive classification.
                val motionStationaryGate = potentialStop != null && motion.saysStationary(now)
                val anchorRef = lowPowerAnchor ?: potentialStop
                val evidenceSpeed = evidenceSpeed(fix, previousLocation)
                val evidence = DepartureDetector.evaluate(
                        fix, anchorRef, evidenceSpeed, isFresh, isLowPower, motionStationaryGate
                )
                updateUIMovementState(isMovingBySensor || evidence.isMovingByGps, now)

                // Automatic power management (iOS stationaryAnchor / low-power watch).
                if (currentAccuracyMode == "automatic" && hasAcquiredFirstLocation) {
                        // Without a step counter (sensor missing or ACTIVITY_RECOGNITION
                        // denied) there is no stationary classification; then the broad
                        // 10-min/150 m cluster alone confirms the stay so noisy indoor
                        // GPS cannot keep the receiver on indefinitely.
                        val hasClassification = motion.hasMotionClassification
                        val anchor = if (isFresh) anchorDetector.anchorFor(
                                fix,
                                hasMotionClassification = true,
                                motionSaysStationary = if (hasClassification) motion.saysStationary(now) else true,
                                isMovingBySensor = isMovingBySensor
                        ) else null
                        when {
                                isLowPower && (isMovingBySensor || evidence.hasStrongGpsDeparture || evidence.hasLowPowerGpsDeparture) ->
                                        forceHighAccuracyBoost("gps-departure")
                                anchor != null -> {
                                        lowPowerAnchor = anchor
                                        enterStationaryLowPower()
                                }
                                isLowPower -> Unit
                                else -> applyLocationProfile()
                        }
                }

                // Reverse geocode throttle (1000 m above 10 m/s, else 100 m).
                if (!tencentAddress.isNullOrBlank()) {
                        currentAddress = tencentAddress
                } else if (isFresh && geocodeThrottle.shouldGeocode(fix)) {
                        serviceScope.launch {
                                geocoder.reverseGeocode(fix.latitude, fix.longitude)
                                        ?.takeIf { it.isNotBlank() }
                                        ?.let { currentAddress = it }
                        }
                }

                // Throttled raw persistence.
                val decision = rawThrottle.evaluate(
                        fix,
                        RawSaveThrottle.Context(
                                isLowPower = isLowPower,
                                lowPowerAnchor = lowPowerAnchor,
                                isMovingBySensor = isMovingBySensor,
                                hasLowPowerDepartureEvidence = evidence.hasLowPowerGpsDeparture,
                                hasPromptDepartureEvidence = evidence.hasPromptLowPowerDeparture
                        )
                )
                if (decision.shouldSave) {
                        rawThrottle.commit(fix, decision.isDelayedBatchSample)
                        rawStore.saveRawPoint(fix.latitude, fix.longitude, fix.accuracy, fix.speed, fix.timeMs)
                        // RawLocationStore writes synchronously: the sift sees this point.
                        val moving = isMovingBySensor || evidence.isMovingByGps || evidence.hasLowPowerGpsDeparture
                        if (siftDebouncer.shouldSift(moving, now)) serviceScope.launch { runSift() }
                        scheduleLiveFootprintMerge()
                }

                if (decision.shouldSave && !decision.isDelayedBatchSample) {
                        // Live candidate detection on the unprocessed tail.
                        val queueFixes = trackingPoints.filter { it.timeMs > lastProcessedMs && it.timeMs < fix.timeMs }
                        val queue = queueFixes.map { it.toRawPoint() }.toMutableList()
                        processor.processNewLocation(fix.toRawPoint(), queue)?.let { candidate ->
                                val points = queueFixes.filter {
                                        it.timeMs in candidate.startTime.time..candidate.endTime.time
                                }
                                handleCandidate(candidate.startTime.time, candidate.endTime.time, points)
                        }
                        trackingPoints.add(fix)
                        trimTrackingPoints(now)

                        val stop = potentialStop
                        if (stop != null) {
                                val startPlace = matchedPlaceLive(stop.latitude, stop.longitude)
                                val currentPlace = matchedPlaceLive(fix.latitude, fix.longitude)
                                val isSamePlace = startPlace != null && startPlace.placeID == currentPlace?.placeID
                                if (DepartureDetector.hasConfirmedDeparture(stop, fix, isSamePlace, isMovingBySensor, now)) {
                                        transitionToMovingAfterConfirmedDeparture("location")
                                }
                        } else if (!hysteresis.isMoving) {
                                setPotentialStop(fix)
                        }
                }

                // Keep an activity-edited current stay growing while still here.
                val stop = potentialStop
                if (isFresh && !hysteresis.isMoving && stop != null &&
                        fix.accuracy > 0 && fix.accuracy < TrackingConfig.ACTIVITY_EXTENSION_ACCURACY_THRESHOLD
                ) {
                        footprintStore.extendActivityEditedStay(maxOf(stop.timeMs, fix.timeMs - 1), fix.timeMs, fix.latitude, fix.longitude)
                }

                if (isFresh) {
                        upsertOngoingStayIfDue(now, force = false)
                        refreshOngoingTitleIfDue(now)
                }
                publishState()
        }

        /** Network fixes carry no speed; derive one from displacement in the low-power watch. */
        private fun evidenceSpeed(fix: TrackingFix, previous: TrackingFix?): Double {
                if (fix.speed > 0) return fix.speed
                if (!isLowPower || previous == null) return fix.speed
                val dt = fix.secondsSince(previous)
                if (dt <= 0 || fix.accuracy <= 0 || fix.accuracy > TrackingConfig.DEPARTURE_ACCURACY_THRESHOLD) return fix.speed
                return fix.distanceTo(previous) / dt
        }

        private fun trimTrackingPoints(now: Long) {
                val cutoff = now - 3L * 86_400_000L
                trackingPoints.removeAll { it.timeMs < cutoff }
                if (trackingPoints.size > 5_000) trackingPoints.subList(0, trackingPoints.size - 5_000).clear()
        }

        /** iOS `updateUIMovementState`. */
        private suspend fun updateUIMovementState(isMovingEvidence: Boolean, now: Long) {
                when (hysteresis.update(isMovingEvidence, now)) {
                        MovementHysteresis.Transition.BECAME_MOVING -> {
                                if (movingSinceMs == null) movingSinceMs = now
                                applyLocationProfile()
                                publishState()
                        }
                        MovementHysteresis.Transition.BECAME_STATIONARY -> {
                                val last = lastLocation
                                if (potentialStop == null && last != null) setPotentialStop(last)
                                applyLocationProfile()
                                publishState()
                                serviceScope.launch { runSift() }
                        }
                        MovementHysteresis.Transition.NONE -> Unit
                }
        }

        private fun setPotentialStop(fix: TrackingFix) {
                potentialStop = fix
                movingSinceMs = null
                stayAddress = null
                lastOngoingUpsertMs = Long.MIN_VALUE
                lastOngoingTitleRefreshMs = Long.MIN_VALUE
                clearOngoingPlaceOverride()
                persistStay()
        }

        /** iOS `transitionToMovingAfterConfirmedDeparture`: the single exit path from a stay. */
        private suspend fun transitionToMovingAfterConfirmedDeparture(source: String) {
                if (potentialStop == null) return
                Log.i(TAG, "Departure confirmed ($source)")
                potentialStop = null
                stayAddress = null
                movingSinceMs = System.currentTimeMillis()
                clearOngoingPlaceOverride()
                persistStay()
                updateUIMovementState(true, System.currentTimeMillis())
                lastNotificationKey = null
                publishState()
        }

        private fun persistStay() {
                val stop = potentialStop
                val address = stayAddress
                serviceScope.launch {
                        // Don't resurrect a stay that stopTracking() just cleared.
                        if (!isTrackingActive) return@launch
                        if (stop == null) prefs.savePendingStay(null, null, null, null)
                        else prefs.savePendingStay(stop.latitude, stop.longitude, stop.timeMs, address)
                }
        }

        // ────────────────────────────────────────────────────────────
        // Low power / departure watch
        // ────────────────────────────────────────────────────────────

        /** iOS `enterAutomaticStationaryLowPower`. */
        private suspend fun enterStationaryLowPower() {
                if (currentAccuracyMode != "automatic" || isLowPower) return
                isLowPower = true
                lastStationaryProbeMs = System.currentTimeMillis()
                motion.armSignificantMotion()
                applyLocationProfile()
                // Persist the observed stay before the sparse watch takes over.
                val anchor = lowPowerAnchor
                if (anchor != null) {
                        processor.confirmedStationaryCandidate(
                                anchorDetector.samples.map { it.toRawPoint() }, anchor.latitude, anchor.longitude
                        )?.let { candidate ->
                                val stop = potentialStop
                                val start = if (stop != null && stop.distanceTo(anchor) < TrackingConfig.STAY_DISTANCE_THRESHOLD)
                                        minOf(stop.timeMs, candidate.startTime.time) else candidate.startTime.time
                                val pts = anchorDetector.samples.filter { it.distanceTo(anchor) < TrackingConfig.STAY_DISTANCE_THRESHOLD }
                                saveCandidate(start, candidate.endTime.time, pts)
                        }
                }
                Log.i(TAG, "Confirmed long stay; low-power departure watch active")
                publishState()
        }

        private fun exitLowPower() {
                isLowPower = false
                anchorDetector.reset()
                lowPowerAnchor = null
                motion.disarmSignificantMotion()
        }

        /** iOS `forceHighAccuracyBoost`. */
        private fun forceHighAccuracyBoost(source: String) {
                if (!isTrackingActive) return
                if (currentAccuracyMode == "powerSaving") {
                        applyLocationProfile()
                        return
                }
                Log.i(TAG, "High accuracy boost ($source)")
                exitLowPower()
                departureBoostEndMs = System.currentTimeMillis() + (TrackingConfig.DEPARTURE_BOOST_DURATION * 1000).toLong()
                applyLocationProfile(force = true)
        }

        private suspend fun onMotionMovingEvidence() = stateMutex.withLock {
                if (isLowPower) forceHighAccuracyBoost("steps")
                updateUIMovementState(true, System.currentTimeMillis())
        }

        private suspend fun onSignificantMotion() = stateMutex.withLock {
                if (isLowPower) forceHighAccuracyBoost("significant-motion")
        }

        private fun startWatchdog() {
                if (watchdogJob?.isActive == true) return
                watchdogJob = serviceScope.launch {
                        var ticks = 0
                        while (isActive) {
                                delay(60_000L)
                                ticks++
                                runCatching { stateMutex.withLock { runLocationWatchdog() } }
                                motion.refresh()
                                if (ticks % 60 == 0) runSift()
                        }
                }
        }

        /** iOS `runLocationWatchdog` + stationary departure probe. */
        private fun runLocationWatchdog() {
                if (!isTrackingActive || currentAccuracyMode == "powerSaving") return
                val now = System.currentTimeMillis()
                val shouldRecoverMoving = motion.isMovingBySensor ||
                        (!isLowPower && hysteresis.isMoving && hysteresis.hasRecentEvidence(now))
                val last = lastFreshUpdateMs
                val gapMs = when {
                        last != null -> now - last
                        shouldRecoverMoving -> now - startTrackingAtMs
                        else -> { requestStationaryProbeIfNeeded(now); return }
                }
                if (!shouldRecoverMoving) {
                        requestStationaryProbeIfNeeded(now)
                        return
                }
                if (gapMs <= TrackingConfig.MOVING_RECOVERY_GAP_THRESHOLD * 1000) return
                if (now - lastRecoveryBoostMs < TrackingConfig.MOVING_RECOVERY_MIN_INTERVAL * 1000) return
                lastRecoveryBoostMs = now
                Log.w(TAG, "No location for ${gapMs / 1000}s while moving; restarting updates")
                forceHighAccuracyBoost("watchdog")
        }

        private fun requestStationaryProbeIfNeeded(now: Long) {
                if (currentAccuracyMode != "automatic" || !isLowPower) return
                if (now - lastStationaryProbeMs < TrackingConfig.STATIONARY_LOCATION_SAMPLE_INTERVAL * 1000) return
                lastStationaryProbeMs = now
                motion.armSignificantMotion()
                mainHandler.post {
                        runCatching {
                                locationClient?.requestSingleFreshLocation(
                                        TencentLocationRequest.create()
                                                .setLocMode(preciseLocationMode())
                                                .setRequestLevel(TencentLocationRequest.REQUEST_LEVEL_GEO)
                                                .setAllowGPS(true),
                                        probeListener,
                                        Looper.getMainLooper()
                                )
                        }
                }
                Log.i(TAG, "Stationary departure probe")
        }

        private var networkCallback: ConnectivityManager.NetworkCallback? = null

        /** iOS NWPathMonitor: Wi-Fi → cellular usually means leaving. */
        private fun registerNetworkCallback() {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
                val callback = object : ConnectivityManager.NetworkCallback() {
                        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                                val isWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                                val isCellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                                val previous = lastWasWifi
                                lastWasWifi = isWifi
                                if (previous == true && !isWifi && isCellular) {
                                        serviceScope.launch {
                                                stateMutex.withLock {
                                                        if (!isLowPower || motion.isMovingBySensor) {
                                                                forceHighAccuracyBoost("wifi-to-cellular")
                                                        }
                                                }
                                        }
                                }
                        }
                }
                runCatching { cm.registerDefaultNetworkCallback(callback) }
                        .onSuccess { networkCallback = callback }
        }

        private fun unregisterNetworkCallback() {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
                networkCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                networkCallback = null
        }

        // ────────────────────────────────────────────────────────────
        // Footprints
        // ────────────────────────────────────────────────────────────

        /** Processor candidate (emitted on leaving a stay) → iOS handleNewCandidateFootprint + finish. */
        private suspend fun handleCandidate(startMs: Long, endMs: Long, points: List<TrackingFix>) {
                saveCandidate(startMs, endMs, points)
                lastProcessedMs = endMs
                serviceScope.launch { runSift() }
        }

        private suspend fun saveCandidate(startMs: Long, endMs: Long, points: List<TrackingFix>) {
                if (points.isEmpty()) return
                val outcome = runCatching {
                        footprintStore.saveCandidate(
                                LiveFootprintStore.Candidate(startMs, endMs, points),
                                overridePlaceID = ongoingPlaceOverrideID,
                                overrideName = ongoingPlaceOverrideName,
                                currentAddress = currentAddress,
                                resolveAddress = { lat, lon -> geocoder.reverseGeocode(lat, lon) }
                        )
                }.onFailure { Log.e(TAG, "Saving live footprint failed", it) }.getOrNull() ?: return
                outcome.created?.let { created ->
                        if (notifiedFootprintIDs.add(created.footprintID)) {
                                serviceScope.launch { checkAndSendNewPlaceNotification(created.footprintID) }
                        }
                }
        }

        /**
         * Keeps the current stay persisted (Android keeps a live footprint so
         * the timeline/new-place notification don't wait for the next sift).
         */
        private suspend fun upsertOngoingStayIfDue(now: Long, force: Boolean) {
                val stop = potentialStop ?: return
                if (hysteresis.isMoving) return
                if (!force && lastOngoingUpsertMs != Long.MIN_VALUE && now - lastOngoingUpsertMs < 60_000L) return
                val lower = maxOf(startOfDay(now), now - 24L * 3_600_000L)
                val recent = rawStore.loadRecentLocations(24.0)
                        .asSequence()
                        .map { TrackingFix.from(it) }
                        .filter { it.timeMs >= lower && it.accuracy > 0 && it.accuracy < TrackingConfig.MAX_GPS_ACCURACY_FILTER }
                        .toList()
                val start = LiveFootprintRules.earliestContiguousStayStart(
                        recent, stop.latitude, stop.longitude, TrackingConfig.STAY_DISTANCE_THRESHOLD,
                        (TrackingConfig.STAY_MERGE_GAP_THRESHOLD * 1000).toLong(), lower
                )?.timeMs?.let { minOf(it, stop.timeMs) } ?: stop.timeMs
                val end = lastLocation?.timeMs ?: now
                if ((end - start) / 1000.0 < TrackingConfig.STAY_DURATION_THRESHOLD) return
                lastOngoingUpsertMs = now
                val points = recent.filter {
                        it.timeMs in start..end && it.distanceTo(stop) <= TrackingConfig.STAY_DISTANCE_THRESHOLD
                }.ifEmpty { listOf(stop.copy(timeMs = start), stop.copy(timeMs = end)) }
                saveCandidate(start, end, points)
        }

        /** iOS analyzeOngoingStay: after 1 h the live title becomes place name / current address. */
        private fun refreshOngoingTitleIfDue(now: Long) {
                val stop = potentialStop ?: return
                if (hysteresis.isMoving || now - stop.timeMs < 3_600_000L) return
                if (stayAddress != null && lastOngoingTitleRefreshMs != Long.MIN_VALUE &&
                        now - lastOngoingTitleRefreshMs < TrackingConfig.ONGOING_TITLE_REFRESH_INTERVAL * 1000
                ) return
                lastOngoingTitleRefreshMs = now
                val title = matchedPlaceLive(stop.latitude, stop.longitude)?.name ?: currentAddress
                if (!title.isNullOrBlank() && title != stayAddress) {
                        stayAddress = title
                        persistStay()
                }
        }

        private fun scheduleLiveFootprintMerge() {
                liveMergeJob?.cancel()
                liveMergeJob = serviceScope.launch {
                        delay(TrackingConfig.LIVE_MERGE_TASK_DELAY_MS)
                        val last = lastLocation ?: return@launch
                        if (abs(last.timeMs - System.currentTimeMillis()) >= TrackingConfig.FRESH_FIX_MAX_AGE * 1000) return@launch
                        runCatching { footprintStore.mergeRecentFootprints() }
                                .onFailure { Log.e(TAG, "Live merge failed", it) }
                                .onSuccess { merged ->
                                        if (merged) com.ct106.difangke.widget.FootprintWidgetUpdater.requestUpdate(applicationContext)
                                }
                }
        }

        private suspend fun checkAndSendNewPlaceNotification(footprintID: String) {
                if (!prefs.isHighlightNotificationEnabled.first()) return
                val footprint = db.footprintDao().getById(footprintID) ?: return
                if (footprint.statusValue == "ignored") return
                if (!footprintStore.isFirstVisit(footprint)) return
                val placeName = footprint.placeID?.let { id -> cachedPlaces.firstOrNull { it.placeID == id }?.name }
                        ?: footprint.address?.takeIf { it.isNotBlank() }
                        ?: currentAddress
                        ?: "这个位置"
                NotificationHelper.sendNewPlaceNotification(this, placeName, footprint.footprintID, footprint.startTime.time)
        }

        /** iOS live `matchedPlace`: radius + 100 m, priority places first, then nearest. */
        private fun matchedPlaceLive(lat: Double, lon: Double): PlaceEntity? {
                ongoingPlaceOverrideID?.let { id -> cachedPlaces.firstOrNull { it.placeID == id } }?.let { return it }
                val matches = cachedPlaces.filter {
                        it.latitude.isFinite() && it.longitude.isFinite() &&
                                GeoMath.distance(it.latitude, it.longitude, lat, lon) <= it.radius + 100.0
                }
                return matches.firstOrNull { it.isPriority }
                        ?: matches.minByOrNull { GeoMath.distance(it.latitude, it.longitude, lat, lon) }
        }

        // ────────────────────────────────────────────────────────────
        // Arrival / place override
        // ────────────────────────────────────────────────────────────

        suspend fun confirmArrivalInternal(): Boolean {
                val ok = stateMutex.withLock {
                        if (!isTrackingActive || potentialStop != null) return@withLock false
                        val observed = lastLocation ?: return@withLock false
                        val now = System.currentTimeMillis()
                        val arrival = observed.copy(timeMs = now, speed = 0.0)
                        lastLocation = arrival
                        lastFreshUpdateMs = now
                        hysteresis.forceStationary()
                        setPotentialStop(arrival)
                        lastNotificationKey = null
                        rawThrottle.commit(arrival, false)
                        trackingPoints.add(arrival)
                        rawStore.saveRawPoint(arrival.latitude, arrival.longitude, arrival.accuracy, 0.0, now)
                        applyLocationProfile()
                        publishState()
                        true
                }
                if (ok) runSift()
                return ok
        }

        fun applyOngoingPlaceOverride(placeID: String?, placeName: String) {
                serviceScope.launch {
                        stateMutex.withLock {
                                ongoingPlaceOverrideID = placeID
                                ongoingPlaceOverrideName = placeName
                                stayAddress = placeName
                                val stop = potentialStop ?: return@withLock
                                prefs.savePendingStay(stop.latitude, stop.longitude, stop.timeMs, placeName)
                                prefs.setPendingStayPlaceOverride(placeID)
                                val dayStart = Date(startOfDay(stop.timeMs))
                                val footprint = db.footprintDao().getForDay(dayStart, Date(dayStart.time + 86_400_000L))
                                        .filter { it.endTime.time >= stop.timeMs - 60_000L }
                                        .filter { fp ->
                                                footprintStore.centerOf(fp)?.let {
                                                        GeoMath.distance(it.first, it.second, stop.latitude, stop.longitude) <=
                                                                TrackingConfig.MERGE_DISTANCE_THRESHOLD
                                                } ?: false
                                        }
                                        .maxByOrNull { it.startTime }
                                if (footprint != null) {
                                        db.footprintDao().update(
                                                footprint.copy(
                                                        placeID = placeID,
                                                        address = placeName,
                                                        title = FootprintTitles.generate(placeName, footprint.startTime.time / 1000),
                                                        isTitleEditedByHand = true,
                                                        isAddressEditedByHand = true,
                                                        statusValue = "manual",
                                                        // Picking a place only changes place fields: a stay whose
                                                        // times the user already set by hand stays pinned.
                                                        allowsAutomaticDurationExtension =
                                                                if (footprint.statusValue == "manual") footprint.allowsAutomaticDurationExtension
                                                                else true
                                                )
                                        )
                                }
                                publishState()
                        }
                }
        }

        private fun clearOngoingPlaceOverride() {
                if (ongoingPlaceOverrideID == null && ongoingPlaceOverrideName == null) return
                ongoingPlaceOverrideID = null
                ongoingPlaceOverrideName = null
                serviceScope.launch { prefs.setPendingStayPlaceOverride(null) }
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
                        if (lat == null || lon == null || time == null) return@launch
                        if (System.currentTimeMillis() - time >= 24L * 3_600_000L) return@launch
                        val overridePlace = placeOverrideID?.let { db.placeDao().getById(it) }?.takeIf { !it.isIgnored }
                        if (placeOverrideID != null && overridePlace == null) prefs.setPendingStayPlaceOverride(null)
                        stateMutex.withLock {
                                if (potentialStop != null || hysteresis.isMoving) return@withLock
                                potentialStop = TrackingFix(time, lat, lon, 50.0, 0.0)
                                stayAddress = overridePlace?.name ?: addr
                                ongoingPlaceOverrideID = overridePlace?.placeID
                                ongoingPlaceOverrideName = overridePlace?.name
                                publishState()
                        }
                        Log.i(TAG, "Recovered ongoing stay: $stayAddress")
                }
        }

        // ────────────────────────────────────────────────────────────
        // Sift, stats, publication
        // ────────────────────────────────────────────────────────────

        /**
         * iOS `triggerTimelineSift`: concurrent callers serialise, so a caller
         * that needs a post-arrival pass always gets one.
         */
        private suspend fun runSift() {
                siftMutex.withLock {
                        runCatching { PersistentTimelineBuilder(applicationContext).rebuildDay(Date()) }
                                .onFailure { Log.e(TAG, "Automatic timeline rebuild failed", it) }
                        refreshTodayStats()
                }
                com.ct106.difangke.widget.FootprintWidgetUpdater.requestUpdate(applicationContext)
                stateMutex.withLock { publishState() }
        }

        @Volatile private var todayPlaceCount = 0
        @Volatile private var todayMileage = 0.0
        @Volatile private var currentTransportTypeRaw: String? = null
        @Volatile private var currentTransportStartMs: Long? = null

        private suspend fun refreshTodayStats() {
                runCatching {
                        val now = System.currentTimeMillis()
                        val dayStart = Date(startOfDay(now))
                        val dayEnd = Date(dayStart.time + 86_400_000L)
                        val footprints = db.footprintDao().getForDay(dayStart, dayEnd)
                        todayPlaceCount = DailyStats.placeCount(footprints.map {
                                val c = footprintStore.centerOf(it)
                                DailyStats.PlaceKeyInput(it.address, it.placeID, c?.first, c?.second)
                        })
                        val transports = db.transportRecordDao().getForDay(dayStart, dayEnd)
                        todayMileage = transports.sumOf { maxOf(0.0, it.distance) }
                        val current = transports.lastOrNull { it.endTime.time >= now - 10 * 60_000L }
                        currentTransportTypeRaw = current?.let { it.manualTypeRaw ?: it.typeRaw }
                        currentTransportStartMs = current?.startTime?.time
                }.onFailure { Log.w(TAG, "Unable to refresh today stats", it) }
        }

        private fun displayPlaceName(): String? {
                val stop = potentialStop ?: return null
                return ongoingPlaceOverrideName
                        ?: matchedPlaceLive(stop.latitude, stop.longitude)?.takeIf { !it.isIgnored }?.name
                        ?: stayAddress
                        ?: currentAddress
        }

        private fun publishState() {
                if (!isTrackingActive) return
                val stop = potentialStop
                val last = lastLocation
                val isMoving = hysteresis.isMoving && stop == null
                val transportRaw = if (isMoving) currentTransportTypeRaw else null
                val movingSince = if (isMoving) (currentTransportStartMs ?: movingSinceMs) else null
                val placeName = displayPlaceName()
                stateFlow.value = if (stop != null) {
                        TrackingState.OngoingStay(
                                since = Date(stop.timeMs),
                                lat = stop.latitude,
                                lon = stop.longitude,
                                address = placeName,
                                speed = maxOf(0.0, last?.speed ?: 0.0)
                        )
                } else {
                        TrackingState.Tracking(
                                lat = last?.latitude,
                                lon = last?.longitude,
                                speed = maxOf(0.0, last?.speed ?: 0.0),
                                isMoving = isMoving,
                                movingSince = movingSince?.let { Date(it) }
                        )
                }
                liveStatusState.value = LiveTrackingStatus(
                        isTracking = true,
                        isMoving = isMoving,
                        stayStart = stop?.let { Date(it.timeMs) },
                        stayLat = stop?.latitude,
                        stayLon = stop?.longitude,
                        placeName = placeName,
                        movingSince = movingSince?.let { Date(it) },
                        transportTypeRaw = transportRaw,
                        lastFixTime = last?.let { Date(it.timeMs) },
                        isStationaryLowPower = isLowPower,
                        todayPlaceCount = todayPlaceCount,
                        todayMileageMeters = todayMileage
                )
                publishNotification()
        }

        private fun publishNotification() {
                if (!isTrackingActive) return
                val status = liveStatusState.value
                val notification = if (liveNotificationEnabled) {
                        val live = NotificationHelper.LiveStatus(
                                isMoving = status.isMoving,
                                sinceMs = (status.stayStart ?: status.movingSince)?.time,
                                placeName = status.placeName,
                                transportTypeName = status.transportTypeRaw?.let { TransportType.from(it).localizedName },
                                todayPlaceCount = status.todayPlaceCount,
                                todayMileageMeters = status.todayMileageMeters,
                                isLowPower = status.isStationaryLowPower
                        )
                        val key = live.toString()
                        if (key == lastNotificationKey) return
                        lastNotificationKey = key
                        NotificationHelper.buildLiveTrackingNotification(this, live, arrivalPendingIntent())
                } else {
                        if (lastNotificationKey == "plain") return
                        lastNotificationKey = "plain"
                        NotificationHelper.buildTrackingNotification(this)
                }
                NotificationHelper.postTrackingNotification(this, notification)
        }

        private fun arrivalPendingIntent(): PendingIntent {
                val intent = Intent(this, LocationTrackingService::class.java).apply { action = ACTION_CONFIRM_ARRIVAL }
                return PendingIntent.getService(
                        this, 7_001, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
        }

        private fun startOfDay(ms: Long): Long = Calendar.getInstance().apply {
                timeInMillis = ms
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
        }.timeInMillis
}
