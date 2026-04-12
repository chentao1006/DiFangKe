package com.ct106.difangke.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.location.*
import android.os.*
import android.util.Log
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.data.model.TransportType
import com.google.gson.Gson
import kotlinx.coroutines.*
import java.util.*

/**
 * 后台位置追踪前台服务（对应 iOS LocationManager 的后台追踪部分）
 *
 * 使用 Android LocationManager（无需 Google Play Services）
 * 在中国设备上通用性更佳
 */
class LocationTrackingService : Service() {

    companion object {
        private const val TAG = "LocationTrackingService"
        const val ACTION_START = "START_TRACKING"
        const val ACTION_STOP = "STOP_TRACKING"

        // SharedFlow 用于跨组件广播实时状态
        val stateFlow = kotlinx.coroutines.flow.MutableStateFlow<TrackingState>(
            TrackingState.Idle
        )

        fun start(context: Context) {
            val intent = Intent(context, LocationTrackingService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, LocationTrackingService::class.java).apply {
                    action = ACTION_STOP
                }
            )
        }
    }

    sealed class TrackingState {
        object Idle : TrackingState()
        object Tracking : TrackingState()
        data class OngoingStay(
            val since: Date,
            val lat: Double,
            val lon: Double,
            val address: String? = null
        ) : TrackingState()
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()

    private lateinit var locationManager: LocationManager
    private val rawStore by lazy { RawLocationStore.getInstance(applicationContext) }
    private val db by lazy { DiFangKeApp.instance.database }
    private val geocoder by lazy { GeocodeService.shared }
    private val processor = FootprintProcessor.shared

    // 滑动窗口队列（对应 iOS trackingPoints）
    private val trackingQueue = mutableListOf<RawLocationStore.RawPoint>()

    // 当前停留开始时间 + 位置（对应 iOS potentialStopStartLocation）
    private var ongoingStayStart: RawLocationStore.RawPoint? = null

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            serviceScope.launch { handleNewLocation(location) }
        }

        override fun onProviderDisabled(provider: String) {
            Log.w(TAG, "Provider disabled: $provider")
        }

        override fun onProviderEnabled(provider: String) {
            Log.i(TAG, "Provider enabled: $provider")
        }
    }

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForeground(NotificationHelper.TRACKING_NOTIFICATION_ID,
                    NotificationHelper.buildTrackingNotification(this))
                startLocationUpdates()
                stateFlow.value = TrackingState.Tracking
                Log.i(TAG, "Tracking started")
            }
            ACTION_STOP -> {
                stopLocationUpdates()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                stateFlow.value = TrackingState.Idle
                Log.i(TAG, "Tracking stopped")
            }
        }
        return START_STICKY
    }

    @Suppress("MissingPermission")
    private fun startLocationUpdates() {
        // 优先 GPS，次选网络定位
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        providers.forEach { provider ->
            if (locationManager.isProviderEnabled(provider)) {
                try {
                    locationManager.requestLocationUpdates(
                        provider,
                        5_000L,      // 最少间隔 5 秒
                        5f,          // 最少位移 5 米
                        locationListener,
                        Looper.getMainLooper()
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "Cannot register $provider", e)
                }
            }
        }
    }

    private fun stopLocationUpdates() {
        locationManager.removeUpdates(locationListener)
        // 强制结算当前停留
        serviceScope.launch {
            processor.finalizeCurrentStay(trackingQueue)?.let { candidate ->
                saveFootprint(candidate)
            }
        }
    }

    private suspend fun handleNewLocation(location: Location) {
        val point = RawLocationStore.RawPoint(
            timestamp = Date(location.time),
            latitude = location.latitude,
            longitude = location.longitude,
            accuracy = location.accuracy.toDouble(),
            speed = location.speed.toDouble()
        )

        // 1. 存储原始点
        rawStore.saveLocation(location)

        // 2. 运行停留识别算法
        val candidate = processor.processNewLocation(point, trackingQueue)

        // 3. 更新正在进行的停留状态
        updateOngoingState(point)

        // 4. 如果识别到候选停留
        candidate?.let {
            saveFootprint(it)
            trackingQueue.clear()
            trackingQueue.add(point)  // 保留触发离开的那个点
        }
    }

    private fun updateOngoingState(current: RawLocationStore.RawPoint) {
        val queueSize = trackingQueue.size
        if (queueSize > 3) {
            val (centerLat, centerLon) = processor.calculateCenter(trackingQueue)
            val distFromCenter = processor.haversineMeters(
                centerLat, centerLon, current.latitude, current.longitude
            )
            if (distFromCenter < AppConfig.STAY_DISTANCE_THRESHOLD) {
                if (ongoingStayStart == null) {
                    ongoingStayStart = trackingQueue.first()
                    serviceScope.launch {
                        val address = geocoder.reverseGeocode(centerLat, centerLon)
                        stateFlow.value = TrackingState.OngoingStay(
                            since = ongoingStayStart!!.timestamp,
                            lat = centerLat,
                            lon = centerLon,
                            address = address
                        )
                        NotificationHelper.updateTrackingNotification(
                            this@LocationTrackingService,
                            address ?: "正在停留中"
                        )
                    }
                }
            } else {
                ongoingStayStart = null
            }
        }
    }

    private suspend fun saveFootprint(candidate: com.ct106.difangke.data.model.CandidateFootprint) {
        val durationSec = candidate.duration

        // 最短停留时长
        if (durationSec < AppConfig.STAY_DURATION_THRESHOLD) return

        val latJson = gson.toJson(candidate.rawLatitudes)
        val lonJson = gson.toJson(candidate.rawLongitudes)

        // 检查是否可以合并到最近的足迹
        val recentCutoff = Date(candidate.startTime.time - AppConfig.STAY_MERGE_GAP_THRESHOLD.toLong() * 1000)
        val lastFp = db.footprintDao().getLastFootprintAfter(recentCutoff)

        if (lastFp != null) {
            val existingLats = gson.fromJson(lastFp.latitudeJson, Array<Double>::class.java)
                .toList()
            val existingLons = gson.fromJson(lastFp.longitudeJson, Array<Double>::class.java)
                .toList()
            val avgLat = if (existingLats.isNotEmpty()) existingLats.average() else 0.0
            val avgLon = if (existingLons.isNotEmpty()) existingLons.average() else 0.0

            val shouldMerge = processor.shouldMerge(
                lastFp.endTime, avgLat, avgLon, candidate
            )

            if (shouldMerge) {
                // 合并：延伸 endTime
                val merged = lastFp.copy(
                    endTime = candidate.endTime,
                    latitudeJson = gson.toJson(existingLats + candidate.rawLatitudes),
                    longitudeJson = gson.toJson(existingLons + candidate.rawLongitudes)
                )
                db.footprintDao().update(merged)
                return
            }
        }

        // 尝试逆地理编码获取地址
        val address = geocoder.reverseGeocode(candidate.latitude, candidate.longitude)

        // 生成标题
        val title = if (address != null) {
            FootprintTitles.generate(address, candidate.startTime.time / 1000)
        } else {
            FootprintTitles.generate("此处", candidate.startTime.time / 1000)
        }

        // 计算位置哈希
        val locationHash = FootprintEntity.generateLocationHash(candidate.latitude, candidate.longitude)

        // 查找匹配的已保存地点
        val places = db.placeDao().getAll()
        val matchedPlace = places.firstOrNull { place ->
            processor.haversineMeters(
                place.latitude, place.longitude, candidate.latitude, candidate.longitude
            ) <= place.radius + 100.0
        }

        val newTitle = if (matchedPlace != null) {
            FootprintTitles.generate(matchedPlace.name, candidate.startTime.time / 1000)
        } else title

        val entity = FootprintEntity(
            footprintID = UUID.randomUUID().toString(),
            date = candidate.startTime,
            startTime = candidate.startTime,
            endTime = candidate.endTime,
            latitudeJson = latJson,
            longitudeJson = lonJson,
            locationHash = locationHash,
            title = newTitle,
            statusValue = "candidate",
            placeID = matchedPlace?.placeID,
            address = address
        )

        db.footprintDao().insert(entity)
        Log.i(TAG, "✅ 新足迹保存: $newTitle (${durationSec}秒)")

        // 保存期间的交通段（与前一个足迹之间的间隔）
        lastFp?.let { prev ->
            saveTransportSegment(prev, entity)
        }
    }

    private suspend fun saveTransportSegment(
        prevFp: FootprintEntity,
        newFp: FootprintEntity
    ) {
        val gapSec = (newFp.startTime.time - prevFp.endTime.time) / 1000.0
        if (gapSec < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD) return

        // 从原始轨迹中获取该时间段的点
        val rawPoints = rawStore.loadRecentLocations(lookbackHours = 4.0)
            .filter { it.timestamp >= prevFp.endTime && it.timestamp <= newFp.startTime }

        if (rawPoints.isEmpty()) return

        val totalDist = rawPoints.zipWithNext { a, b ->
            processor.haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
        }.sum()

        if (totalDist < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return

        val avgSpeed = totalDist / gapSec
        val transportType = TransportType.fromSpeed(avgSpeed)

        val pointsJson = gson.toJson(rawPoints.map { listOf(it.latitude, it.longitude) })

        val record = TransportRecordEntity(
            recordID = UUID.randomUUID().toString(),
            day = prevFp.endTime,
            startTime = prevFp.endTime,
            endTime = newFp.startTime,
            startLocation = prevFp.address ?: prevFp.title,
            endLocation = newFp.address ?: newFp.title,
            typeRaw = transportType.raw,
            distance = totalDist,
            averageSpeed = avgSpeed,
            pointsJson = pointsJson,
            statusRaw = "active"
        )

        db.transportRecordDao().insert(record)
        Log.i(TAG, "🚗 交通段保存: ${transportType.localizedName} ${totalDist.toInt()}m")
    }

    override fun onDestroy() {
        super.onDestroy()
        stopLocationUpdates()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
