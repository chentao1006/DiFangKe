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
import org.json.JSONArray
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

        // 1. 获取已有的记录，保护手动/已确认的数据不被覆盖
        val existingFps = db.footprintDao().getBetween(startOfDay, endOfDay)
        val existingTps = db.transportRecordDao().getForDay(startOfDay, endOfDay)
        
        // 计算偏好（排除目标日期，保证稳定性）
        val preferredAuto = getPreferredAutomotiveType(startOfDay)
        val preferredCycling = getPreferredCyclingType(startOfDay)

        // 2. 加载轨迹点
        val rawPoints = rawStore.loadLocations(date, filtered = true)

        // --- 核心修复：剔除 GPS 跳点 (Spike) ---
        // 比如 1秒内漂移 100+ 米的噪音
        val points = mutableListOf<RawLocationStore.RawPoint>()
        if (rawPoints.isNotEmpty()) points.add(rawPoints[0])
        for (k in 1 until rawPoints.size) {
            val p1 = rawPoints[k-1]
            val p2 = rawPoints[k]
            val d = processor.haversineMeters(p1.latitude, p1.longitude, p2.latitude, p2.longitude)
            val t = (p2.timestamp.time - p1.timestamp.time) / 1000.0
            // 如果速度超过阈值 (约 540km/h) 且时间极短，判定为跳点
            if (t > 0 && t < AppConfig.TINY_STAY_THRESHOLD && (d / t) > AppConfig.RIDICULOUS_SPEED_THRESHOLD * 1.5) {
                continue 
            }
            points.add(p2)
        }
        
        if (points.isEmpty()) return@withContext

        // 3. 清理自动生成的旧数据（保留 Confirmed 和 Manual 记录）
        // iOS 逻辑：仅重整非人工干预的部分
        db.footprintDao().deleteCandidatesBetween(startOfDay, endOfDay)
        db.footprintDao().deleteStartBoundaryCandidates(startOfDay)
        db.transportRecordDao().deleteAutoForDay(startOfDay, endOfDay)

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
                        generateTransportSegment(lastFp!!, currentFp, points, preferredAuto, preferredCycling)
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
            lastFp?.let { generateTransportSegment(it, finalEntity, points, preferredAuto, preferredCycling) }
            lastFp = finalEntity
        }

        // --- 足迹的时间范围要限制在0点到次日0点：边界填补 (最后记录到 24:00) ---
        lastFp?.let { last ->
            val isToday = getStartOfDay(Date()) == startOfDay
            if (!isToday) {
                val gapToEnd = (endOfDay.time - last.endTime.time) / 1000L
                if (gapToEnd >= AppConfig.STAY_DURATION_THRESHOLD) {
                    val entity = FootprintEntity(
                        footprintID = UUID.randomUUID().toString(),
                        date = startOfDay,
                        startTime = last.endTime,
                        endTime = endOfDay,
                        latitudeJson = last.latitudeJson,
                        longitudeJson = last.longitudeJson,
                        locationHash = last.locationHash,
                        title = "",
                        statusValue = "candidate",
                        address = last.address,
                        placeID = last.placeID
                    )
                    db.footprintDao().insert(entity)
                }
            }
        }

        // 5. 合并连续交通段 (iOS Parity: mergeConsecutiveTransports)
        mergeConsecutiveTransports(date, preferredAuto, preferredCycling)

        Log.i(TAG, "Finished rebuilding timeline for $date. Found ${footprints.size} footprints.")
    }

    private suspend fun mergeConsecutiveTransports(date: Date, preferredAuto: TransportType, preferredCycling: TransportType) {
        val startOfDay = getStartOfDay(date)
        val endOfDay = Calendar.getInstance().apply { time = startOfDay; add(Calendar.DAY_OF_YEAR, 1) }.time
        
        var allTps = db.transportRecordDao().getForDay(startOfDay, endOfDay).sortedBy { it.startTime }
        if (allTps.size < 2) return

        var i = 0
        while (i < allTps.size - 1) {
            val current = allTps[i]
            val next = allTps[i + 1]

            // 检查中间是否有足迹
            val footprintsBetween = db.footprintDao().getBetween(current.endTime, next.startTime)
            if (footprintsBetween.isNotEmpty()) {
                i++
                continue
            }

            val gap = (next.startTime.time - current.endTime.time) / 1000L
            
            val currentType = TransportType.from(current.manualTypeRaw ?: current.typeRaw)
            val nextType = TransportType.from(next.manualTypeRaw ?: next.typeRaw)

            // --- 铁律保护：如果其中任一段是手动设置的，且两段类型不同，严禁自动合并 ---
            if ((current.manualTypeRaw != null || next.manualTypeRaw != null) && current.typeRaw != next.typeRaw) {
                i++
                continue
            }

            val isCompatible = TransportType.getCategory(currentType) == TransportType.getCategory(nextType)

            // 如果间隔小于 15 分钟且类型兼容，则合并
            if (gap >= -60 && gap <= 900 && isCompatible) {
                val combinedPoints = try {
                    val p1 = JSONArray(current.pointsJson)
                    val p2 = JSONArray(next.pointsJson)
                    val result = JSONArray()
                    for (j in 0 until p1.length()) result.put(p1.get(j))
                    for (j in 0 until p2.length()) result.put(p2.get(j))
                    result.toString()
                } catch (e: Exception) { current.pointsJson }

                val merged = current.copy(
                    endTime = next.endTime,
                    endLocation = next.endLocation,
                    distance = current.distance + next.distance,
                    pointsJson = combinedPoints,
                    typeRaw = if (current.manualTypeRaw != null) current.manualTypeRaw!! else if (next.manualTypeRaw != null) next.manualTypeRaw!! else current.typeRaw
                )
                
                // 重新计算平均速度和类型
                val duration = (merged.endTime.time - merged.startTime.time) / 1000L
                if (duration > 0) {
                    val newAvgSpeed = merged.distance / duration
                    val newType = if (merged.manualTypeRaw != null) {
                        TransportType.from(merged.manualTypeRaw!!)
                    } else {
                        TransportType.from(
                            speedMs = newAvgSpeed,
                            durationSec = duration,
                            preferredAuto = preferredAuto,
                            preferredCycling = preferredCycling
                        )
                    }
                    val finalMerged = merged.copy(averageSpeed = newAvgSpeed, typeRaw = newType.raw)
                    
                    db.transportRecordDao().update(finalMerged)
                    db.transportRecordDao().delete(next)
                    
                    // 重新加载并继续检查
                    allTps = db.transportRecordDao().getForDay(startOfDay, endOfDay).sortedBy { it.startTime }
                    // 不增加 i，继续检查合并后的段落与下一个
                } else {
                    i++
                }
            } else {
                i++
            }
        }
    }

    private suspend fun createFootprintEntity(candidate: com.ct106.difangke.data.model.CandidateFootprint): FootprintEntity {
        val address = geocoder.reverseGeocode(candidate.latitude, candidate.longitude)
        val locationHash = FootprintEntity.generateLocationHash(candidate.latitude, candidate.longitude)
        
        // 尝试匹配已知地点
        val matchedPlace = PlaceMatcher.bestPlaceForCoordinate(
            latitude = candidate.latitude,
            longitude = candidate.longitude,
            places = db.placeDao().getAll(),
            processor = processor
        )

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
        allDayPoints: List<RawLocationStore.RawPoint>,
        preferredAuto: TransportType,
        preferredCycling: TransportType
    ) {
        val gapSec = (newFp.startTime.time - prevFp.endTime.time) / 1000L
        if (gapSec < AppConfig.TRANSPORT_MIN_DURATION_THRESHOLD) return

        val segmentPoints = allDayPoints.filter { it.timestamp >= prevFp.endTime && it.timestamp <= newFp.startTime }
        
        val totalDist: Double
        val avgSpeed: Double
        val pointsJson: String

        // 计算起终点中心
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
            if (totalDist > 200.0 && gapSec > AppConfig.STAY_DURATION_THRESHOLD / 2) {
                avgSpeed = totalDist / gapSec
                pointsJson = gson.toJson(pts)
            } else return
        } else {
            if (totalDist < AppConfig.TRANSPORT_MIN_DISTANCE_THRESHOLD) return
            avgSpeed = totalDist / gapSec
            pointsJson = gson.toJson(pts)
        }

        // 识别交通类型 (集成传感器和偏好)
        // 这里的 motionType 可以从 RawPoints 的平均值或最高频值获取，目前先传默认
        val determinedType = TransportType.from(
            speedMs = avgSpeed,
            durationSec = gapSec,
            preferredAuto = preferredAuto,
            preferredCycling = preferredCycling
        )

        val record = TransportRecordEntity(
            recordID = UUID.randomUUID().toString(),
            day = getStartOfDay(prevFp.endTime),
            startTime = prevFp.endTime,
            endTime = newFp.startTime,
            startLocation = prevFp.address ?: "未知位置",
            endLocation = newFp.address ?: "未知位置",
            typeRaw = determinedType.raw,
            distance = totalDist,
            averageSpeed = avgSpeed,
            pointsJson = pointsJson,
            statusRaw = "active"
        )
        db.transportRecordDao().insert(record)
    }

    private suspend fun getPreferredAutomotiveType(excludingDate: Date): TransportType {
        val recent = db.transportRecordDao().getRecentExcluding(excludingDate, 150)
        
        val counts = mutableMapOf(
            TransportType.CAR to 0,
            TransportType.BUS to 0,
            TransportType.MOTORCYCLE to 0,
            TransportType.SUBWAY to 0
        )
        
        for (record in recent) {
            val typeStr = record.manualTypeRaw ?: record.typeRaw
            val type = TransportType.from(typeStr)
            if (counts.containsKey(type)) {
                counts[type] = counts[type]!! + 1
            }
        }
        
        return counts.maxByOrNull { it.value }?.key ?: TransportType.CAR
    }

    private suspend fun getPreferredCyclingType(excludingDate: Date): TransportType {
        val recent = db.transportRecordDao().getRecentExcluding(excludingDate, 150)
        val bikeCount = recent.count { it.typeRaw == TransportType.BICYCLE.raw || it.manualTypeRaw == TransportType.BICYCLE.raw }
        val ebikeCount = recent.count { it.typeRaw == TransportType.EBIKE.raw || it.manualTypeRaw == TransportType.EBIKE.raw }
        
        return if (bikeCount >= ebikeCount) TransportType.BICYCLE else TransportType.EBIKE
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
