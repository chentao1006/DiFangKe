package com.ct106.difangke.data.location

import android.content.Context
import android.location.Location
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

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
    fun loadLocations(date: Date): List<RawPoint> {
        val file = getFile(date)
        if (!file.exists()) return emptyList()

        val result = mutableListOf<RawPoint>()
        var lastValid: RawPoint? = null

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

                val point = RawPoint(
                    timestamp = Date((ts * 1000).toLong()),
                    latitude = lat,
                    longitude = lon,
                    accuracy = acc,
                    speed = spd
                )

                // 过滤离谱漂移点（对应 iOS 的补救措施）
                val prev = lastValid
                if (prev != null) {
                    val dt = (point.timestamp.time - prev.timestamp.time) / 1000.0
                    if (dt > 0) {
                        val dist = haversineMeters(prev.latitude, prev.longitude, lat, lon)
                        val calcSpeed = dist / dt
                        val isRidiculous = (acc > 500 && dist > 2000) ||
                                (calcSpeed > 100.0 && acc > 100)
                        if (isRidiculous) return@runCatching
                    }
                }

                result.add(point)
                lastValid = point
            }
        }
        return result
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
            if (dt > 0 && dist / dt < 45.0) { // 约 160km/h
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
