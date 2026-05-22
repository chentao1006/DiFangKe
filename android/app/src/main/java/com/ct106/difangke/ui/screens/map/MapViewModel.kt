package com.ct106.difangke.ui.screens.map

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import com.google.gson.Gson
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.*

class MapViewModel(application: Application) : AndroidViewModel(application) {
    private val rawStore = RawLocationStore.getInstance(application)
    private val db = DiFangKeApp.instance.database
    private val gson = Gson()

    private val _pathPoints = MutableStateFlow<List<Pair<Pair<Double, Double>, Long>>>(emptyList())
    val pathPoints: StateFlow<List<Pair<Double, Double>>> = _pathPoints.map { list ->
        list.map { it.first }
    }.stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

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
            val footprints = db.footprintDao().getBetween(startOfTarget, Date(startOfTarget.time + 86400000L))
            _footprintMarkers.value = buildFootprintMapMarkers(footprints, db.activityTypeDao().getAll())
            val dbPoints = mutableListOf<Pair<Double, Double>>()
            // 不再将足迹漂移点加入轨迹，只保留交通线

            // 加载交通轨迹
            val transports = db.transportRecordDao().getForDay(startOfTarget, Date(startOfTarget.time + 86400000L))
            transports.forEach { tp ->
                try {
                    val pts = gson.fromJson(tp.pointsJson, Array<Array<Double>>::class.java)
                    pts.forEach { p ->
                        dbPoints.add(p[0] to p[1])
                    }
                    // 插入分隔符，防止不同的交通记录被连成一条直线
                    dbPoints.add(Double.NaN to Double.NaN)
                } catch (e: Exception) {}
            }

            // 不再使用 rawPoints 的全部流水，避免今天产生大量原地的“毛线团”漂移线
            // 统一使用 dbPoints（仅含提取出的有效交通段）
            val finalPoints = dbPoints
            _pathPoints.value = finalPoints.map { it to 0L }
        }
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
