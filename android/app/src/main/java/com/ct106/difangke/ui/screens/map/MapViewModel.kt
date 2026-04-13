package com.ct106.difangke.ui.screens.map

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.data.db.entity.FootprintEntity
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
            val dbPoints = mutableListOf<Pair<Double, Double>>()
            footprints.forEach { fp ->
                try {
                    val lats = gson.fromJson(fp.latitudeJson, Array<Double>::class.java)
                    val lons = gson.fromJson(fp.longitudeJson, Array<Double>::class.java)
                    lats.zip(lons).forEach { (lat, lon) ->
                        dbPoints.add(lat to lon)
                    }
                } catch (e: Exception) {}
            }

            // 加载交通轨迹
            val transports = db.transportRecordDao().getForDay(startOfTarget, Date(startOfTarget.time + 86400000L))
            transports.forEach { tp ->
                try {
                    val pts = gson.fromJson(tp.pointsJson, Array<Array<Double>>::class.java)
                    pts.forEach { p ->
                        dbPoints.add(p[0] to p[1])
                    }
                } catch (e: Exception) {}
            }

            // 2. 加载 RawLocationStore 中的原始流水点
            val rawPoints = rawStore.loadLocations(startOfTarget)
            val trajectoryPoints = rawPoints.map { it.latitude to it.longitude }

            // 3. 合并 (如果是今天且有流水点，优先用流水点；否则用数据库聚合点)
            val finalPoints = if (trajectoryPoints.isNotEmpty() && (timestamp == null || isToday(timestamp))) {
                trajectoryPoints
            } else {
                dbPoints
            }
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
