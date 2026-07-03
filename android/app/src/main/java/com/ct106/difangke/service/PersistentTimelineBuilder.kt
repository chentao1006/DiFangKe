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
        val filteredRawPoints = rawStore.loadLocations(date, filtered = true)
        val unfilteredRawPoints = rawStore.loadLocations(date, filtered = false)
        val points = removeTinyImpossibleJumps(filteredRawPoints.ifEmpty { unfilteredRawPoints })
        val transportPoints = removeTinyImpossibleJumps(unfilteredRawPoints.ifEmpty { filteredRawPoints })

        if (points.isEmpty() && transportPoints.isEmpty()) return@withContext

        db.footprintDao().deleteCandidatesBetween(startOfDay, endOfDay)
        db.footprintDao().deleteStartBoundaryCandidates(startOfDay)
        db.transportRecordDao().deleteAutoForDay(startOfDay, endOfDay)

        // Fetch retained footprints (confirmed, manual, or title-edited) to prevent overlapping candidate generation
        val retainedFps = db.footprintDao().getBetween(startOfDay, endOfDay)

        // 3. 构建时间线
        val queue = mutableListOf<RawLocationStore.RawPoint>()
        val footprints = mutableListOf<FootprintEntity>()
        var lastFp: FootprintEntity? = null
        
        for (point in points) {
            val candidate = processor.processNewLocation(point, queue, isHistorical = true)
            candidate?.let {
                // 增加小量延迟防止高频触发高德 REST 接口频率限制
                kotlinx.coroutines.delay(300)
                
                // 检查是否与保留的足迹重叠
                val overlap = retainedFps.firstOrNull { retained ->
                    it.startTime.before(retained.endTime) && it.endTime.after(retained.startTime)
                }
                if (overlap != null) {
                    lastFp = overlap
                    queue.clear()
                    queue.add(point)
                    return@let
                }

                val entity = createFootprintEntity(it)
                
                // 检查是否合并
                var currentFp = entity
                if (lastFp != null && lastFp!!.statusValue == "candidate" && !lastFp!!.isTitleEditedByHand) {
                    val prevLats = gson.fromJson(lastFp!!.latitudeJson, Array<Double>::class.java).toList()
                    val prevLons = gson.fromJson(lastFp!!.longitudeJson, Array<Double>::class.java).toList()
                    val avgLat = if (prevLats.isNotEmpty()) prevLats.average() else 0.0
                    val avgLon = if (prevLons.isNotEmpty()) prevLons.average() else 0.0

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
                    // 如果 lastFp 非空且不合并（比如 lastFp 是 retained），也要生成交通段
                    if (lastFp != null) {
                        generateTransportSegment(lastFp!!, currentFp, points, preferredAuto, preferredCycling)
                    }
                    lastFp = currentFp
                    footprints.add(currentFp)
                }
                
                queue.clear()
                queue.add(point)
            }
        }

        // 4. 处理最后的残留队列（如果停留超过阈值）
        processor.finalizeCurrentStay(queue)?.let { lastCandidate ->
            // 同样需要检查是否与保留的足迹重叠
            val overlap = retainedFps.firstOrNull { retained ->
                lastCandidate.startTime.before(retained.endTime) && lastCandidate.endTime.after(retained.startTime)
            }
            if (overlap == null) {
                val finalEntity = createFootprintEntity(lastCandidate)
                db.footprintDao().insert(finalEntity)
                lastFp?.let { generateTransportSegment(it, finalEntity, points, preferredAuto, preferredCycling) }
                lastFp = finalEntity
            } else {
                // 如果最后一段也重叠了，直接将 lastFp 指向重叠的足迹，放弃这段候选
                lastFp = overlap
            }
        }

        // --- 足迹的时间范围要限制在0点到次日0点：边界填补 (最后记录到 24:00) ---
        lastFp?.let { last ->
            val isToday = getStartOfDay(Date()) == startOfDay
            if (!isToday) {
                val gapToEnd = (endOfDay.time - last.endTime.time) / 1000L
                if (gapToEnd >= AppConfig.STAY_DURATION_THRESHOLD) {
                    // 直接延长 lastFp 的 endTime，而不是新建一个重复的 footprint
                    val extendedFp = last.copy(endTime = endOfDay)
                    db.footprintDao().update(extendedFp)
                }
            }
        }

        generateMissingTransportSegmentsForFootprints(startOfDay, endOfDay, transportPoints.ifEmpty { points }, preferredAuto, preferredCycling)

        // 5. 合并连续交通段 (iOS Parity: mergeConsecutiveTransports)
        mergeConsecutiveTransports(date, preferredAuto, preferredCycling)

        Log.i(TAG, "Finished rebuilding timeline for $date. Found ${footprints.size} footprints.")
    }

    private fun removeTinyImpossibleJumps(rawPoints: List<RawLocationStore.RawPoint>): List<RawLocationStore.RawPoint> {
        if (rawPoints.isEmpty()) return emptyList()

        val points = mutableListOf(rawPoints[0])
        for (k in 1 until rawPoints.size) {
            val previous = rawPoints[k - 1]
            val current = rawPoints[k]
            val distance = processor.haversineMeters(previous.latitude, previous.longitude, current.latitude, current.longitude)
            val duration = (current.timestamp.time - previous.timestamp.time) / 1000.0
            if (duration > 0 && duration < AppConfig.TINY_STAY_THRESHOLD && (distance / duration) > AppConfig.RIDICULOUS_SPEED_THRESHOLD * 1.5) {
                continue
            }
            points.add(current)
        }
        return points
    }

    private suspend fun generateMissingTransportSegmentsForFootprints(
        startOfDay: Date,
        endOfDay: Date,
        allDayPoints: List<RawLocationStore.RawPoint>,
        preferredAuto: TransportType,
        preferredCycling: TransportType
    ) {
        val allFootprints = db.footprintDao().getBetween(startOfDay, endOfDay).sortedBy { it.startTime }
        if (allFootprints.size < 2) return

        for (i in 0 until allFootprints.size - 1) {
            val previous = allFootprints[i]
            val next = allFootprints[i + 1]
            if (next.startTime <= previous.endTime) continue

            val existingTransport = db.transportRecordDao().getActiveBetween(previous.endTime, next.startTime)
            if (existingTransport.isNotEmpty()) continue

            generateTransportSegment(previous, next, allDayPoints, preferredAuto, preferredCycling)
        }
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
                            distanceMeters = merged.distance,
                            pointCount = try { JSONArray(merged.pointsJson).length() } catch (e: Exception) { 0 },
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
        pts.add(listOf(lat1, lon1, prevFp.endTime.time.toDouble()))
        if (segmentPoints.isNotEmpty()) {
            pts.addAll(segmentPoints.map { listOf(it.latitude, it.longitude, it.timestamp.time.toDouble()) })
        }
        pts.add(listOf(lat2, lon2, newFp.startTime.time.toDouble()))

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
            distanceMeters = totalDist,
            pointCount = pts.size,
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

    /**
     * 检查今日最新的几个足迹，如果同一地点且时间连续，则合并，以旧的足迹为准，保留用户修改
     */
    suspend fun mergeRecentFootprintsForToday() = withContext(Dispatchers.IO) {
        val now = Date()
        val startOfDay = getStartOfDay(now)
        val endOfDay = Calendar.getInstance().apply {
            time = startOfDay
            add(Calendar.DAY_OF_YEAR, 1)
        }.time

        // 获取今天的所有足迹并按开始时间排序
        val todayFps = db.footprintDao().getBetween(startOfDay, endOfDay).sortedBy { it.startTime }
        if (todayFps.size < 2) return@withContext

        // 只检查最近的 5 个足迹
        val recentFps = todayFps.takeLast(5).toMutableList()
        var i = 0
        while (i < recentFps.size - 1) {
            val base = recentFps[i]
            val next = recentFps[i + 1]

            // 检查地点是否一致（基于 PlaceID 或距离）
            var isSamePlace = false
            if (base.placeID != null && base.placeID == next.placeID) {
                isSamePlace = true
            } else {
                val lat1 = gson.fromJson(base.latitudeJson, Array<Double>::class.java).average()
                val lon1 = gson.fromJson(base.longitudeJson, Array<Double>::class.java).average()
                val lat2 = gson.fromJson(next.latitudeJson, Array<Double>::class.java).average()
                val lon2 = gson.fromJson(next.longitudeJson, Array<Double>::class.java).average()
                if (!lat1.isNaN() && !lon1.isNaN() && !lat2.isNaN() && !lon2.isNaN()) {
                    val dist = processor.haversineMeters(lat1, lon1, lat2, lon2)
                    if (dist < AppConfig.MERGE_DISTANCE_THRESHOLD) {
                        isSamePlace = true
                    }
                }
            }

            // 时间检查
            val timeGap = (next.startTime.time - base.endTime.time) / 1000L
            val gapLimit = if (isSamePlace) 3600L else AppConfig.STAY_MERGE_GAP_THRESHOLD.toLong()
            if (timeGap > gapLimit) {
                i++
                continue
            }

            // 检查期间是否有交通记录
            val transportBetween = db.transportRecordDao().getForDay(base.endTime, next.startTime)
            if (transportBetween.isNotEmpty()) {
                i++
                continue
            }

            // 检查它们之间是否有真正的位移（避免因为漂移导致中心点偏移被错误合并）
            val todayDate = Date(base.endTime.time)
            val gapPoints = com.ct106.difangke.data.location.RawLocationStore.getInstance(context).loadLocations(todayDate).filter {
                it.timestamp.time in base.endTime.time..next.startTime.time
            }
            val baseLat = gson.fromJson(base.latitudeJson, Array<Double>::class.java).average()
            val baseLon = gson.fromJson(base.longitudeJson, Array<Double>::class.java).average()
            val nextLat = gson.fromJson(next.latitudeJson, Array<Double>::class.java).average()
            val nextLon = gson.fromJson(next.longitudeJson, Array<Double>::class.java).average()

            var hasRealMovement = false
            if (!baseLat.isNaN() && !baseLon.isNaN() && !nextLat.isNaN() && !nextLon.isNaN()) {
                hasRealMovement = processor.hasSignificantMovement(
                    currentLat = baseLat,
                    currentLon = baseLon,
                    nextLat = nextLat,
                    nextLon = nextLon,
                    points = gapPoints
                )
            }

            // 如果有显著位移，并且距离稍微偏远，则不要合并
            val dist = if (!baseLat.isNaN() && !baseLon.isNaN() && !nextLat.isNaN() && !nextLon.isNaN()) {
                processor.haversineMeters(baseLat, baseLon, nextLat, nextLon)
            } else { 0.0 }

            if (hasRealMovement && dist >= (AppConfig.MERGE_DISTANCE_THRESHOLD / 2)) {
                i++
                continue
            }

            if (isSamePlace) {
                // 执行合并：以 base（旧足迹）为准，延长 endTime，合并坐标，合并照片
                val mergedLats = gson.fromJson(base.latitudeJson, Array<Double>::class.java).toList() +
                        gson.fromJson(next.latitudeJson, Array<Double>::class.java).toList()
                val mergedLons = gson.fromJson(base.longitudeJson, Array<Double>::class.java).toList() +
                        gson.fromJson(next.longitudeJson, Array<Double>::class.java).toList()

                val mergedPhotos = try {
                    val p1 = JSONArray(base.photoAssetIDsJson)
                    val p2 = JSONArray(next.photoAssetIDsJson)
                    val result = JSONArray()
                    val seen = mutableSetOf<String>()
                    for (j in 0 until p1.length()) {
                        val pid = p1.getString(j)
                        if (seen.add(pid)) result.put(pid)
                    }
                    for (j in 0 until p2.length()) {
                        val pid = p2.getString(j)
                        if (seen.add(pid)) result.put(pid)
                    }
                    result.toString()
                } catch (e: Exception) { base.photoAssetIDsJson }

                val mergedFp = base.copy(
                    endTime = maxOf(base.endTime, next.endTime),
                    latitudeJson = gson.toJson(mergedLats),
                    longitudeJson = gson.toJson(mergedLons),
                    photoAssetIDsJson = mergedPhotos,
                    // 如果新的有活动类型而旧的没有，可以继承
                    activityTypeValue = base.activityTypeValue ?: next.activityTypeValue
                )

                db.footprintDao().update(mergedFp)
                db.footprintDao().delete(next)

                recentFps[i] = mergedFp
                recentFps.removeAt(i + 1)
                // i 不递增，继续尝试与下一个合并
            } else {
                i++
            }
        }
    }
}
