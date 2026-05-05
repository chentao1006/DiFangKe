package com.ct106.difangke.data.location

import android.content.Context
import android.location.Location
import android.util.Log
import com.ct106.difangke.AppConfig
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import android.content.Intent
import kotlin.math.*

/**
 * 原始轨迹 CSV 文件存储（对应 iOS RawLocationStore）
 * 每天一个文件，格式：timestamp,lat,lon,accuracy,speed
 * 文件路径：filesDir/RawLocations/yyyy-MM-dd.csv
 */
class RawLocationStore private constructor(context: Context) {

    companion object {
        private const val TAG = "RawLocationStore"
        private const val DIR_NAME = "RawLocations"
        private val DATE_FMT = SimpleDateFormat("yyyy-MM-dd", Locale.US)

        @Volatile
        private var INSTANCE: RawLocationStore? = null

        fun getInstance(context: Context): RawLocationStore =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: RawLocationStore(context.applicationContext).also { INSTANCE = it }
            }
    }

    private val baseDir: File = File(context.filesDir, DIR_NAME).also { it.mkdirs() }

    private fun getFile(date: Date): File =
        File(baseDir, "${DATE_FMT.format(date)}.csv")

    /** 存储单个定位点（通过原始坐标） */
    fun saveRawPoint(lat: Double, lon: Double, accuracy: Double, speed: Double, timeMs: Long) {
        runCatching {
            val file = getFile(Date(timeMs))
            val line = "${timeMs / 1000.0},$lat,$lon,$accuracy,$speed\n"
            file.appendText(line)
        }.onFailure { Log.e(TAG, "saveRawPoint failed", it) }
    }

    /** 存储单个定位点（对应 iOS saveLocation） */
    fun saveLocation(location: Location) {
        saveRawPoint(location.latitude, location.longitude, location.accuracy.toDouble(), location.speed.toDouble(), location.time)
    }

    /** 加载指定日期的所有定位点（对应 iOS loadLocations） */
    fun loadLocations(date: Date, filtered: Boolean = true): List<RawPoint> {
        val file = getFile(date)
        if (!file.exists()) return emptyList()

        val rawList = mutableListOf<RawPoint>()
        file.forEachLine { line ->
            if (line.isBlank()) return@forEachLine
            val parts = line.split(",")
            if (parts.size < 3) return@forEachLine
            runCatching {
                val ts = parts[0].toDouble()
                val lat = parts[1].toDouble()
                val lon = parts[2].toDouble()
                val acc = if (parts.size > 3) parts[3].toDouble() else 0.0
                val spd = if (parts.size > 4) parts[4].toDouble() else 0.0

                rawList.add(RawPoint(
                    timestamp = Date((ts * 1000).toLong()),
                    latitude = lat,
                    longitude = lon,
                    accuracy = acc,
                    speed = spd
                ))
            }
        }
        
        if (!filtered) return rawList
        return filterRidiculousSpikes(rawList)
    }

    /** 过滤离谱漂移点（对应 iOS filterRidiculousSpikes） */
    private fun filterRidiculousSpikes(locations: List<RawPoint>): List<RawPoint> {
        if (locations.size < 3) return locations
        val result = mutableListOf<RawPoint>()
        result.add(locations[0])
        
        for (i in 1 until locations.size - 1) {
            val prev = result.last()
            val curr = locations[i]
            val next = locations[i + 1]
            
            val d1 = haversineMeters(prev.latitude, prev.longitude, curr.latitude, curr.longitude)
            val d2 = haversineMeters(curr.latitude, curr.longitude, next.latitude, next.longitude)
            val gap = haversineMeters(prev.latitude, prev.longitude, next.latitude, next.longitude)
            
            // 跳出 > 1km 且 跳回 > 1km，且起终点差距不大 -> 判定为坐标突跳
            if (d1 > AppConfig.RIDICULOUS_DISTANCE_THRESHOLD / 2 && d2 > AppConfig.RIDICULOUS_DISTANCE_THRESHOLD / 2 && gap < AppConfig.RIDICULOUS_ACCURACY_THRESHOLD) {
                continue
            }
            
            // 基础精度/速度过滤
            if (curr.accuracy > AppConfig.RIDICULOUS_ACCURACY_THRESHOLD && d1 > AppConfig.RIDICULOUS_DISTANCE_THRESHOLD) continue
            
            result.add(curr)
        }
        result.add(locations.last())
        return result
    }

    /** 删除指定时间点的数据（用于手动纠错，对应 iOS deleteLocation） */
    fun deleteLocation(timestamp: Double, date: Date, context: Context) {
        val file = getFile(date)
        if (!file.exists()) return
        
        runCatching {
            val lines = file.readLines()
            val filteredLines = lines.filter { line ->
                if (line.isBlank()) return@filter false
                val parts = line.split(",")
                if (parts.isEmpty()) return@filter false
                val ts = parts[0].toDoubleOrNull() ?: 0.0
                // 允许 10ms 误差
                abs(ts - timestamp) > 0.01
            }
            
            if (filteredLines.size < lines.size) {
                file.writeText(filteredLines.joinToString("\n") + "\n")
                // 发送通知，告知 UI 和核心逻辑刷新
                val intent = Intent("com.ct106.difangke.RAW_LOCATION_DATA_DELETED").apply {
                    putExtra("date", date.time)
                }
                context.sendBroadcast(intent)
            }
        }.onFailure { Log.e(TAG, "deleteLocation failed", it) }
    }

    /** 查找所有有数据的日期（对应 iOS refreshAvailableRawDates） */
    fun getAvailableDates(): Set<Date> {
        val dates = mutableSetOf<Date>()
        baseDir.listFiles()?.filter { it.extension == "csv" }?.forEach { file ->
            runCatching {
                val dateStr = file.nameWithoutExtension.take(10)
                val cal = Calendar.getInstance()
                DATE_FMT.parse(dateStr)?.let {
                    cal.time = it
                    cal.set(Calendar.HOUR_OF_DAY, 0)
                    cal.set(Calendar.MINUTE, 0)
                    cal.set(Calendar.SECOND, 0)
                    cal.set(Calendar.MILLISECOND, 0)
                    dates.add(cal.time)
                }
            }
        }
        return dates
    }

    /** 获取指定日期的总点数（对应 iOS getTotalPointsCount） */
    fun getTotalPointsCount(date: Date): Int {
        val file = getFile(date)
        if (!file.exists()) return 0
        return file.readLines().count { it.isNotBlank() }
    }

    /** 获取最近 lookbackHours 小时的所有点 */
    fun loadRecentLocations(lookbackHours: Double = 2.0): List<RawPoint> {
        val now = Date()
        val threshold = Date(now.time - (lookbackHours * 3600 * 1000).toLong())

        val today = loadLocations(now).filter { it.timestamp >= threshold }
        val cal = Calendar.getInstance()
        cal.time = now
        val startOfToday = cal.apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time

        return if (threshold < startOfToday) {
            val yesterday = Date(now.time - 86400_000L)
            loadLocations(yesterday).filter { it.timestamp >= threshold } + today
        } else {
            today
        }
    }

    /** 计算指定日期的总路程（单位：米） */
    fun calculateTotalDistance(date: Date): Double {
        val locations = loadLocations(date).filter { it.accuracy < 100 } // 过滤精度较差的点以减少噪点
        if (locations.size < 2) return 0.0
        
        var total = 0.0
        for (i in 0 until locations.size - 1) {
            val p1 = locations[i]
            val p2 = locations[i + 1]
            val dist = haversineMeters(p1.latitude, p1.longitude, p2.latitude, p2.longitude)
            // 过滤单点漂移引起的路程暴涨（如果两点间速度超过 150km/h，可能是漂移，除非是飞机）
            val dt = (p2.timestamp.time - p1.timestamp.time) / 1000.0
            if (dt > 0 && dist / dt < AppConfig.DRIFT_SPEED_THRESHOLD) {
                total += dist
            }
        }
        return total
    }

    data class RawPoint(
        val timestamp: Date,
        val latitude: Double,
        val longitude: Double,
        val accuracy: Double,
        val speed: Double
    )

    private fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val R = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = Math.sin(dLat / 2).let { it * it } +
                Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
                Math.sin(dLon / 2).let { it * it }
        return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    }
}
