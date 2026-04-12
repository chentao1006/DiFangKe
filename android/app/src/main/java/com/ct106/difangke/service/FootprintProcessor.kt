package com.ct106.difangke.service

import android.location.Location
import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.model.CandidateFootprint
import java.util.Date
import kotlin.math.*

/**
 * 停留点识别算法（完全对应 iOS FootprintProcessor）
 *
 * 核心逻辑：
 * 1. 精度/漂移过滤
 * 2. 滑动窗口内计算停留中心
 * 3. 当检测到离开（距中心 > 阈值）时，分析之前的队列是否满足停留条件
 * 4. 满足时间阈值 + 85百分位距离阈值 → 生成 CandidateFootprint
 */
class FootprintProcessor private constructor() {

    companion object {
        val shared: FootprintProcessor by lazy { FootprintProcessor() }
    }

    // 从 AppConfig 读取阈值
    private val stayRadius get() = AppConfig.STAY_DISTANCE_THRESHOLD
    private val stayDuration get() = AppConfig.STAY_DURATION_THRESHOLD  // seconds
    private val mergeTimeThreshold get() = AppConfig.STAY_MERGE_GAP_THRESHOLD  // seconds
    private val mergeDistance get() = AppConfig.MERGE_DISTANCE_THRESHOLD  // meters

    /**
     * 处理新定位点（对应 iOS processNewLocation）
     * @param location 新位置
     * @param queue 滑动窗口队列（调用方维护，可变）
     * @param isHistorical 是否历史数据处理模式
     * @return 如果识别到停留点，返回 CandidateFootprint；否则 null
     */
    fun processNewLocation(
        location: RawLocationStore.RawPoint,
        queue: MutableList<RawLocationStore.RawPoint>,
        isHistorical: Boolean = false
    ): CandidateFootprint? {

        // 1. 精度过滤
        if (location.accuracy <= 0 || location.accuracy >= AppConfig.MAX_LOCATION_ACCURACY) return null

        // 2. 实时点鲜度过滤
        if (!isHistorical) {
            val ageMs = System.currentTimeMillis() - location.timestamp.time
            if (ageMs > 60_000) return null
        }

        // 3. 漂移过滤
        queue.lastOrNull()?.let { last ->
            val dt = (location.timestamp.time - last.timestamp.time) / 1000.0
            if (dt < 5.0) return null

            val dist = haversineMeters(last.latitude, last.longitude, location.latitude, location.longitude)
            val calcSpeed = if (dt > 0) dist / dt else 0.0

            // A. 物理不可能性
            if (calcSpeed > AppConfig.DRIFT_SPEED_THRESHOLD && location.accuracy > AppConfig.DRIFT_ACCURACY_THRESHOLD) {
                return null
            }

            // B. 精度断崖
            if (dist > 300 && location.accuracy > last.accuracy * 3 && location.accuracy > 150) {
                return null
            }

            // C. 基础漂移
            if (dist > stayRadius && location.speed > 45.0) {
                return null
            }
        }

        // 4. 加入队列
        queue.add(location)

        if (queue.size < 2) return null

        // 5. 计算停留中心（不含最新点）
        val analysisQueue = queue.dropLast(1)
        val (centerLat, centerLon) = calculateCenter(analysisQueue)
        val distToCenter = haversineMeters(centerLat, centerLon, location.latitude, location.longitude)

        // 6. 只有"离开"停留中心时才结算
        if (distToCenter > stayRadius) {
            return detectStayPoint(analysisQueue)
        }
        return null
    }

    /**
     * 分析队列是否满足停留条件（对应 iOS detectStayPoint）
     */
    fun detectStayPoint(locations: List<RawLocationStore.RawPoint>): CandidateFootprint? {
        if (locations.size < 2) return null

        val startTime = locations.first().timestamp
        val endTime = locations.last().timestamp
        val durationSec = (endTime.time - startTime.time) / 1000.0

        if (durationSec < stayDuration) return null

        val (centerLat, centerLon) = calculateCenter(locations)

        // 85百分位距离过滤
        val distances = locations.map {
            haversineMeters(centerLat, centerLon, it.latitude, it.longitude)
        }.sorted()

        val percentileIndex = (distances.size * AppConfig.STAY_PERCENTILE).toInt()
            .coerceAtMost(distances.size - 1)

        if (distances[percentileIndex] > stayRadius) return null

        return CandidateFootprint(
            startTime = startTime,
            endTime = endTime,
            latitude = centerLat,
            longitude = centerLon,
            duration = durationSec.toLong(),
            rawLatitudes = locations.map { it.latitude },
            rawLongitudes = locations.map { it.longitude }
        )
    }

    /** 强制结算当前队列（对应 iOS finalizeCurrentStay） */
    fun finalizeCurrentStay(queue: List<RawLocationStore.RawPoint>): CandidateFootprint? =
        detectStayPoint(queue)

    /**
     * 判断是否应与最近足迹合并（对应 iOS shouldMerge）
     */
    fun shouldMerge(
        lastEndTime: Date,
        lastLat: Double,
        lastLon: Double,
        newCandidate: CandidateFootprint
    ): Boolean {
        val gapSec = (newCandidate.startTime.time - lastEndTime.time) / 1000.0
        if (gapSec >= mergeTimeThreshold) return false
        val dist = haversineMeters(lastLat, lastLon, newCandidate.latitude, newCandidate.longitude)
        return dist < mergeDistance
    }

    fun calculateCenter(points: List<RawLocationStore.RawPoint>): Pair<Double, Double> {
        val avgLat = points.map { it.latitude }.average()
        val avgLon = points.map { it.longitude }.average()
        return Pair(avgLat, avgLon)
    }

    /** Haversine 距离公式（米） */
    fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val R = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2).pow(2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2).pow(2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
