package com.ct106.difangke.service

import android.content.Context
import android.util.Log
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.util.PhotoLinker
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.*

/**
 * 离线/全量时间线构建器（对应 iOS PersistentTimelineBuilder）
 * 用于根据原始轨迹文件重新生成全天的足迹和交通记录
 */
class PersistentTimelineBuilder(private val context: Context) {

    private val db = DiFangKeApp.instance.database
    private val rawStore = RawLocationStore.getInstance(context)
    private val processor = FootprintProcessor.shared
    private val geocoder = GeocodeService.shared
    private val gson = Gson()

    companion object {
        private const val TAG = "TimelineBuilder"
    }

    /**
     * 重建指定日期的本地时间线（对应 iOS syncDay）
     */
    suspend fun rebuildDay(date: Date) = withContext(Dispatchers.IO) {
        Log.i(TAG, "Rebuilding timeline for $date")
        
        val startOfDay = getStartOfDay(date)
        val endOfDay = Calendar.getInstance().apply {
            time = startOfDay
            add(Calendar.DAY_OF_YEAR, 1)
        }.time

        // 1. 加载轨迹点
        val rawPoints = rawStore.loadLocations(date, filtered = true)
        if (rawPoints.isEmpty()) {
            Log.w(TAG, "No raw points found for $date, skipping.")
            return@withContext
        }

        // --- 核心修复：剔除 GPS 跳点 (Spike) ---
        // 比如 1秒内漂移 100+ 米的噪音
        val points = mutableListOf<RawLocationStore.RawPoint>()
        if (rawPoints.isNotEmpty()) points.add(rawPoints[0])
        for (k in 1 until rawPoints.size) {
            val p1 = rawPoints[k-1]
            val p2 = rawPoints[k]
            val d = processor.haversineMeters(p1.latitude, p1.longitude, p2.latitude, p2.longitude)
            val t = (p2.timestamp.time - p1.timestamp.time) / 1000.0
            // 如果速度超过 150m/s (540km/h) 且时间极短，判定为跳点
            if (t > 0 && t < 5 && (d / t) > 150) {
                continue 
            }
            points.add(p2)
        }
        
        if (points.isEmpty()) return@withContext

        // 2. 清理旧数据（仅限自动生成的，Confirmed 的保留？）
        // iOS 逻辑是全清，因为这是“重新生成”
        db.footprintDao().deleteBetween(startOfDay, endOfDay)
        db.transportRecordDao().deleteForDay(startOfDay, endOfDay)

        // 3. 构建时间线
        val queue = mutableListOf<RawLocationStore.RawPoint>()
        val footprints = mutableListOf<FootprintEntity>()
        var lastFp: FootprintEntity? = null

        for (point in points) {
            val candidate = processor.processNewLocation(point, queue, isHistorical = true)
            candidate?.let {
                // 增加小量延迟防止高频触发高德 REST 接口频率限制
                kotlinx.coroutines.delay(300)
                val entity = createFootprintEntity(it)
                
                // 检查是否合并
                var currentFp = entity
                if (lastFp != null) {
                    val prevLats = gson.fromJson(lastFp!!.latitudeJson, Array<Double>::class.java).toList()
                    val prevLons = gson.fromJson(lastFp!!.longitudeJson, Array<Double>::class.java).toList()
                    val avgLat = prevLats.average()
                    val avgLon = prevLons.average()

                    if (processor.shouldMerge(lastFp!!.endTime, avgLat, avgLon, it)) {
                        currentFp = lastFp!!.copy(
                            endTime = it.endTime,
                            latitudeJson = gson.toJson(prevLats + it.rawLatitudes),
                            longitudeJson = gson.toJson(prevLons + it.rawLongitudes)
                        )
                        // 更新数据库
                        db.footprintDao().update(currentFp)
                        lastFp = currentFp
                    } else {
                        // 保存新的
                        db.footprintDao().insert(currentFp)
                        // 生成交通段
                        generateTransportSegment(lastFp!!, currentFp, points)
                        lastFp = currentFp
                        footprints.add(currentFp)
                    }
                } else {
                    db.footprintDao().insert(currentFp)
                    lastFp = currentFp
                    footprints.add(currentFp)
                }
                
                queue.clear()
                queue.add(point)
            }
        }

        // 4. 处理最后的残留队列（如果停留超过阈值）
        processor.finalizeCurrentStay(queue)?.let { lastCandidate ->
            val finalEntity = createFootprintEntity(lastCandidate)
            db.footprintDao().insert(finalEntity)
            lastFp?.let { generateTransportSegment(it, finalEntity, points) }
        }

        Log.i(TAG, "Finished rebuilding timeline for $date. Found ${footprints.size} footprints.")
    }

    private suspend fun createFootprintEntity(candidate: com.ct106.difangke.data.model.CandidateFootprint): FootprintEntity {
        val address = geocoder.reverseGeocode(candidate.latitude, candidate.longitude)
        val locationHash = FootprintEntity.generateLocationHash(candidate.latitude, candidate.longitude)
        
        // 尝试匹配已知地点
        val matchedPlace = db.placeDao().getAll().firstOrNull { place ->
            processor.haversineMeters(place.latitude, place.longitude, candidate.latitude, candidate.longitude) <= place.radius + 100.0
        }

        val entity = FootprintEntity(
            footprintID = UUID.randomUUID().toString(),
            date = getStartOfDay(candidate.startTime),
            startTime = candidate.startTime,
            endTime = candidate.endTime,
            latitudeJson = gson.toJson(candidate.rawLatitudes),
            longitudeJson = gson.toJson(candidate.rawLongitudes),
            locationHash = locationHash,
            title = "",
            statusValue = "candidate",
            placeID = matchedPlace?.placeID,
            address = if (matchedPlace?.isUserDefined == true) matchedPlace.name else address
        )

        // 自动关联照片
        val photoUris = PhotoLinker.linkPhotosToFootprint(context, entity)
        return if (photoUris.isNotEmpty()) {
            entity.copy(photoAssetIDsJson = PhotoLinker.mergePhotoIds("[]", photoUris))
        } else entity
    }

    private suspend fun generateTransportSegment(
        prevFp: FootprintEntity, 
        newFp: FootprintEntity,
        allDayPoints: List<RawLocationStore.RawPoint>
    ) {
        val gapSec = (newFp.startTime.time - prevFp.endTime.time) / 1000.0
        if (gapSec < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD) return

        val segmentPoints = allDayPoints.filter { it.timestamp >= prevFp.endTime && it.timestamp <= newFp.startTime }
        
        val totalDist: Double
        val avgSpeed: Double
        val pointsJson: String

        // 计算起终点中心（由于 FootprintEntity 存的是 JSON，需要解析）
        val lat1 = gson.fromJson(prevFp.latitudeJson, Array<Double>::class.java).average()
        val lon1 = gson.fromJson(prevFp.longitudeJson, Array<Double>::class.java).average()
        val lat2 = gson.fromJson(newFp.latitudeJson, Array<Double>::class.java).average()
        val lon2 = gson.fromJson(newFp.longitudeJson, Array<Double>::class.java).average()

        val pts = mutableListOf<List<Double>>()
        pts.add(listOf(lat1, lon1))
        if (segmentPoints.isNotEmpty()) {
            pts.addAll(segmentPoints.map { listOf(it.latitude, it.longitude) })
        }
        pts.add(listOf(lat2, lon2))

        totalDist = pts.zipWithNext { a, b ->
            processor.haversineMeters(a[0], a[1], b[0], b[1])
        }.sum()

        if (segmentPoints.isEmpty()) {
            if (totalDist > 200.0 && gapSec > 120.0) {
                avgSpeed = totalDist / gapSec
                pointsJson = gson.toJson(pts)
            } else return
        } else {
            if (totalDist < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return
            avgSpeed = totalDist / gapSec
            pointsJson = gson.toJson(pts)
        }

        val record = TransportRecordEntity(
            recordID = UUID.randomUUID().toString(),
            day = getStartOfDay(prevFp.endTime),
            startTime = prevFp.endTime,
            endTime = newFp.startTime,
            startLocation = prevFp.address ?: "未知位置",
            endLocation = newFp.address ?: "未知位置",
            typeRaw = TransportType.fromSpeed(avgSpeed).raw,
            distance = totalDist,
            averageSpeed = avgSpeed,
            pointsJson = pointsJson,
            statusRaw = "active"
        )
        db.transportRecordDao().insert(record)
    }

    private fun getStartOfDay(date: Date): Date {
        val cal = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return cal.time
    }
}
