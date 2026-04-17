package com.ct106.difangke.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.*
import android.util.Log
import com.amap.api.location.AMapLocationClient
import com.amap.api.location.AMapLocationClientOption
import com.amap.api.location.AMapLocationListener
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
 * 后台位置追踪前台服务（迁移至高德定位 SDK，以解决中国境内定位偏移和成功率问题）
 */
class LocationTrackingService : Service() {

    companion object {
        private const val TAG = "LocationTrackingService"
        const val ACTION_START = "START_TRACKING"
        const val ACTION_STOP = "STOP_TRACKING"

        val stateFlow = kotlinx.coroutines.flow.MutableStateFlow<TrackingState>(
            TrackingState.Idle
        )
        
        var isHighAccuracyBoostEnabled = false // 保留字段但不再由 UI 控制，改为内部逻辑

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
        data class Tracking(val lat: Double? = null, val lon: Double? = null) : TrackingState()
        data class OngoingStay(
            val since: Date,
            val lat: Double,
            val lon: Double,
            val address: String? = null
        ) : TrackingState()
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()
    private val prefs by lazy { (application as DiFangKeApp).preferences }

    private var locationClient: AMapLocationClient? = null
    private val rawStore by lazy { RawLocationStore.getInstance(applicationContext) }
    private val db by lazy { DiFangKeApp.instance.database }
    private val geocoder by lazy { GeocodeService.shared }
    private val processor = FootprintProcessor.shared

    private val trackingQueue = mutableListOf<RawLocationStore.RawPoint>()
    private var ongoingStayStart: RawLocationStore.RawPoint? = null
    private var ongoingStayAddress: String? = null
    private var isHighAccuracyBoostEnabled = false

    private val locationListener = AMapLocationListener { location ->
        if (location != null && location.errorCode == 0) {
            // 自动调整逻辑：
            // 如果检测到速度 > 0.3m/s (约 1km/h，判定为运动中)
            val speed = location.speed
            val shouldBoost = speed > 0.3
            
            if (shouldBoost != isHighAccuracyBoostEnabled) {
                isHighAccuracyBoostEnabled = shouldBoost
                // 动态调整采样频率
                locationClient?.setLocationOption(AMapLocationClientOption().apply {
                    locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
                    interval = if (shouldBoost) 1000L else 3000L
                    isNeedAddress = true
                    isMockEnable = false
                    isOffset = true
                })
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
            Log.e(TAG, "定位失败: ${location?.errorCode} - ${location?.errorInfo}")
        }
    }

    private fun getShortAddress(location: com.amap.api.location.AMapLocation): String? {
        // 优先顺序：AOI(兴趣区域) > POI(点) > 区+街道
        return when {
            !location.aoiName.isNullOrBlank() -> location.aoiName
            !location.poiName.isNullOrBlank() -> location.poiName
            !location.street.isNullOrBlank() -> "${location.district}${location.street}"
            else -> location.address
        }
    }

    override fun onCreate() {
        super.onCreate()
        try {
            locationClient = AMapLocationClient(applicationContext)
            val option = AMapLocationClientOption().apply {
                locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
                interval = 3000L // 每 3 秒定位一次
                isNeedAddress = true
                isMockEnable = false
                isOffset = true // 自动修正偏移
            }
            locationClient?.setLocationOption(option)
            locationClient?.setLocationListener(locationListener)
        } catch (e: Exception) {
            Log.e(TAG, "初始化高德定位失败", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                Log.d(TAG, "ACTION_START received, starting foreground...")
                val notification = NotificationHelper.buildTrackingNotification(this)
                startForeground(NotificationHelper.TRACKING_NOTIFICATION_ID, notification)
                
                // 开启高德后台定位
                val boost = isHighAccuracyBoostEnabled
                locationClient?.setLocationOption(AMapLocationClientOption().apply {
                    locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
                    interval = if (boost) 1000L else 3000L
                    isNeedAddress = true
                    isMockEnable = false
                    isOffset = true
                })
                locationClient?.enableBackgroundLocation(NotificationHelper.TRACKING_NOTIFICATION_ID, notification)
                locationClient?.startLocation()
                
                stateFlow.value = TrackingState.Tracking()
                Log.i(TAG, "Tracking service successfully started and transitioned to Tracking state")
            }
            ACTION_STOP -> {
                locationClient?.disableBackgroundLocation(true)
                stopForeground(STOP_FOREGROUND_REMOVE)
                
                // 清理持久化的停留状态
                serviceScope.launch {
                    prefs.savePendingStay(null, null, null, null)
                }
                
                stopSelf()
                stateFlow.value = TrackingState.Idle
                Log.i(TAG, "Amap Tracking stopped")
            }
        }
        return START_STICKY
    }

    private suspend fun handleNewLocation(lat: Double, lon: Double, accuracy: Double, speed: Double, time: Date, address: String?) {
        // 0. 存储原始点（用于后续分析和轨迹绘制）
        rawStore.saveRawPoint(lat, lon, accuracy, speed, time.time)

        val point = RawLocationStore.RawPoint(
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
            stateFlow.value = TrackingState.Tracking(lat, lon)
        }
        updateOngoingState(point, address)

        // 3. 候选停留保存
        candidate?.let {
            saveFootprint(it)
            trackingQueue.clear()
            trackingQueue.add(point)
        }
    }

    private fun updateOngoingState(current: RawLocationStore.RawPoint, currentAddress: String?) {
        val queueSize = trackingQueue.size
        // 至少有三个点才能判定停留趋势
        if (queueSize >= 3) {
            val (centerLat, centerLon) = processor.calculateCenter(trackingQueue)
            val distFromCenter = processor.haversineMeters(
                centerLat, centerLon, current.latitude, current.longitude
            )
            
            if (distFromCenter < AppConfig.STAY_DISTANCE_THRESHOLD) {
                // 如果当前已经在 OngoingStay 且中心位移不大，不要重设 start 时间
                if (ongoingStayStart == null) {
                    ongoingStayStart = trackingQueue.first()
                    // 持久化保存
                    serviceScope.launch {
                        prefs.savePendingStay(centerLat, centerLon, ongoingStayStart?.timestamp?.time, currentAddress)
                    }
                } else {
                    // 核心修复：如果已有的停留点距离当前新识别的中心太远，说明用户已经大幅度移动过
                    // 之前的 ongoingStayStart 是陈旧的（可能是重启后恢复的），应以当前窗口为准重设
                    val distFromStart = processor.haversineMeters(
                        ongoingStayStart!!.latitude, ongoingStayStart!!.longitude,
                        centerLat, centerLon
                    )
                    if (distFromStart > AppConfig.STAY_DISTANCE_THRESHOLD * 2.5) {
                        Log.i(TAG, "Restored stay location is too far ($distFromStart m), resetting stay start time.")
                        ongoingStayStart = trackingQueue.first()
                        ongoingStayAddress = null
                        serviceScope.launch {
                            prefs.savePendingStay(centerLat, centerLon, ongoingStayStart?.timestamp?.time, currentAddress)
                        }
                    }
                }
                
                serviceScope.launch {
                    val address = currentAddress ?: geocoder.reverseGeocode(centerLat, centerLon)
                    if (address != null && ongoingStayAddress == null) {
                        ongoingStayAddress = address
                        prefs.savePendingStay(centerLat, centerLon, ongoingStayStart?.timestamp?.time, address)
                    }
                    
                    stateFlow.value = TrackingState.OngoingStay(
                        since = ongoingStayStart!!.timestamp,
                        lat = centerLat,
                        lon = centerLon,
                        address = address ?: ongoingStayAddress
                    )
                    NotificationHelper.updateTrackingNotification(
                        this@LocationTrackingService,
                        (address ?: ongoingStayAddress) ?: "正在停留中"
                    )
                }
            } else {
                // 位移较大，说明正在移动，不是停留态
                if (ongoingStayStart != null) {
                    ongoingStayStart = null
                    ongoingStayAddress = null
                    serviceScope.launch {
                        prefs.savePendingStay(null, null, null, null)
                    }
                }
            }
        }
    }

    private fun loadPersistedStayState() {
        serviceScope.launch {
            val lat = prefs.getPendingStayLat()
            val lon = prefs.getPendingStayLon()
            val time = prefs.getPendingStayStartTime()
            val addr = prefs.getPendingStayAddress()
            
            if (lat != null && lon != null && time != null) {
                // 校验时间是否在 24 小时内（防止跨天且没结算的错误状态）
                if (System.currentTimeMillis() - (time as Long) < 24 * 3600 * 1000) {
                    val recoveredPoint = RawLocationStore.RawPoint(
                        timestamp = Date(time as Long),
                        latitude = lat,
                        longitude = lon,
                        accuracy = 50.0,
                        speed = 0.0
                    )
                    ongoingStayStart = recoveredPoint
                    ongoingStayAddress = addr
                    
                    stateFlow.value = TrackingState.OngoingStay(
                        since = Date(time as Long),
                        lat = lat,
                        lon = lon,
                        address = addr
                    )
                    Log.i(TAG, "Successfully recovered ongoing stay from storage: $addr")
                }
            }
        }
    }

    private suspend fun saveFootprint(candidate: com.ct106.difangke.data.model.CandidateFootprint) {
        // ... (省略逻辑与之前一致，复用之前的逻辑) ...
        // 为了确保代码完整，由于 write_to_file 是覆盖，我需要贴出之前的完整逻辑
        val durationSec = candidate.duration
        if (durationSec < AppConfig.STAY_DURATION_THRESHOLD) return

        val latJson = gson.toJson(candidate.rawLatitudes)
        val lonJson = gson.toJson(candidate.rawLongitudes)

        val recentCutoff = Date(candidate.startTime.time - AppConfig.STAY_MERGE_GAP_THRESHOLD.toLong() * 1000)
        val lastFp = db.footprintDao().getLastFootprintAfter(recentCutoff)

        if (lastFp != null) {
            val existingLats = gson.fromJson(lastFp.latitudeJson, Array<Double>::class.java).toList()
            val existingLons = gson.fromJson(lastFp.longitudeJson, Array<Double>::class.java).toList()
            val avgLat = if (existingLats.isNotEmpty()) existingLats.average() else 0.0
            val avgLon = if (existingLons.isNotEmpty()) existingLons.average() else 0.0

            if (processor.shouldMerge(lastFp.endTime, avgLat, avgLon, candidate)) {
                val merged = lastFp.copy(
                    endTime = candidate.endTime,
                    latitudeJson = gson.toJson(existingLats + candidate.rawLatitudes),
                    longitudeJson = gson.toJson(existingLons + candidate.rawLongitudes)
                )
                db.footprintDao().update(merged)
                return
            }
        }

        val address = geocoder.reverseGeocode(candidate.latitude, candidate.longitude)
        val locationHash = FootprintEntity.generateLocationHash(candidate.latitude, candidate.longitude)
        val places = db.placeDao().getAll()
        val matchedPlace = places.firstOrNull { place ->
            processor.haversineMeters(place.latitude, place.longitude, candidate.latitude, candidate.longitude) <= place.radius + 100.0
        }

        val entity = FootprintEntity(
            footprintID = UUID.randomUUID().toString(),
            date = candidate.startTime,
            startTime = candidate.startTime,
            endTime = candidate.endTime,
            latitudeJson = latJson,
            longitudeJson = lonJson,
            locationHash = locationHash,
            title = if (matchedPlace != null) FootprintTitles.generate(matchedPlace.name, candidate.startTime.time / 1000) else {
                if (address != null) FootprintTitles.generate(address, candidate.startTime.time / 1000)
                else FootprintTitles.generate("此处", candidate.startTime.time / 1000)
            },
            statusValue = "candidate",
            placeID = matchedPlace?.placeID,
            address = address
        )

        // 自动关联照片逻辑
        val photoUris = com.ct106.difangke.util.PhotoLinker.linkPhotosToFootprint(applicationContext, entity)
        val finalEntity = if (photoUris.isNotEmpty()) {
            entity.copy(photoAssetIDsJson = com.ct106.difangke.util.PhotoLinker.mergePhotoIds("[]", photoUris))
        } else entity

        db.footprintDao().insert(finalEntity)
        lastFp?.let { prev ->
            saveTransportSegment(prev, finalEntity)
        }
    }

    private suspend fun saveTransportSegment(prevFp: FootprintEntity, newFp: FootprintEntity) {
        val gapSec = (newFp.startTime.time - prevFp.endTime.time) / 1000.0
        if (gapSec < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD) return

        // 简便起见，这里复用之前的 RawLocationStore 逻辑
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
    }

    override fun onDestroy() {
        super.onDestroy()
        locationClient?.stopLocation()
        locationClient?.onDestroy()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
