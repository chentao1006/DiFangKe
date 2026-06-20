package com.ct106.difangke.ui.screens.map

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.*

data class MapPathPoint(
    val latitude: Double,
    val longitude: Double,
    val timestamp: Long? = null
) {
    val isSeparator: Boolean
        get() = latitude.isNaN() || longitude.isNaN()
}

class MapViewModel(application: Application) : AndroidViewModel(application) {
    private val rawStore = RawLocationStore.getInstance(application)
    private val db = DiFangKeApp.instance.database

    private val _pathPoints = MutableStateFlow<List<MapPathPoint>>(emptyList())
    val pathPoints: StateFlow<List<MapPathPoint>> = _pathPoints.asStateFlow()

    private val _footprintMarkers = MutableStateFlow<List<FootprintMapMarker>>(emptyList())
    val footprintMarkers: StateFlow<List<FootprintMapMarker>> = _footprintMarkers.asStateFlow()

    val allPlaces = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    init {
        // 初始加载由 Screen 的 LaunchedEffect 触发，或者默认加载今天
    }

    fun loadPathForDate(timestamp: Long?) {
        viewModelScope.launch {
            val cal = Calendar.getInstance().apply {
                if (timestamp != null) {
                    timeInMillis = timestamp
                }
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val startOfTarget = cal.time

            // 1. 加载数据库中的已结算足迹
            val endOfTarget = Date(startOfTarget.time + 86400000L)
            val footprints = db.footprintDao().getBetween(startOfTarget, endOfTarget)
            _footprintMarkers.value = buildFootprintMapMarkers(
                footprints = footprints,
                activityTypes = db.activityTypeDao().getAll(),
                visibleStart = startOfTarget,
                visibleEnd = endOfTarget
            )
            val dbPoints = mutableListOf<MapPathPoint>()
            // 不再将足迹漂移点加入轨迹，只保留交通线

            // 加载交通轨迹
            val transports = db.transportRecordDao().getForDay(startOfTarget, endOfTarget)
            transports.forEach { tp ->
                dbPoints.addAll(parseTransportPathPoints(tp.pointsJson))
                // 插入分隔符，防止不同的交通记录被连成一条直线
                dbPoints.add(MapPathPoint(Double.NaN, Double.NaN))
            }

            // 不再使用 rawPoints 的全部流水，避免今天产生大量原地的“毛线团”漂移线
            // 统一使用 dbPoints（仅含提取出的有效交通段）
            _pathPoints.value = dbPoints
        }
    }

    private fun parseTransportPathPoints(pointsJson: String): List<MapPathPoint> {
        return try {
            val array = org.json.JSONArray(pointsJson)
            buildList {
                for (i in 0 until array.length()) {
                    val element = array.get(i)
                    when (element) {
                        is org.json.JSONArray -> {
                            val lat = element.getDouble(0)
                            val lon = element.getDouble(1)
                            val timestamp = if (element.length() >= 3) normalizeTimestampMillis(element.optDouble(2, 0.0)) else null
                            add(MapPathPoint(lat, lon, timestamp))
                        }
                        is org.json.JSONObject -> {
                            val lat = element.optDouble("lat", element.optDouble("latitude", Double.NaN))
                            val lon = element.optDouble("lon", element.optDouble("longitude", Double.NaN))
                            val timestamp = normalizeTimestampMillis(element.optDouble("timestamp", 0.0))
                            if (!lat.isNaN() && !lon.isNaN()) {
                                add(MapPathPoint(lat, lon, timestamp))
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun normalizeTimestampMillis(raw: Double): Long? {
        if (raw <= 0.0) return null
        return if (raw < 10_000_000_000.0) (raw * 1000).toLong() else raw.toLong()
    }

    private fun isToday(timestamp: Long): Boolean {
        val cal = Calendar.getInstance()
        val today = cal.apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        cal.timeInMillis = timestamp
        val target = cal.apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        return today == target
    }
}
