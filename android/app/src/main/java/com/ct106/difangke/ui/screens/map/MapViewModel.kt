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
        loadTodayPath()
    }

    private fun loadTodayPath() {
        viewModelScope.launch {
            val cal = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val startOfToday = cal.time

            // 1. 加载数据库中的已结算足迹
            val footprints = db.footprintDao().getBetween(startOfToday, Date(startOfToday.time + 86400000L))
            val dbPoints = mutableListOf<Pair<Double, Double>>()
            footprints.forEach { fp ->
                val lats = gson.fromJson(fp.latitudeJson, Array<Double>::class.java)
                val lons = gson.fromJson(fp.longitudeJson, Array<Double>::class.java)
                lats.zip(lons).forEach { (lat, lon) ->
                    dbPoints.add(lat to lon)
                }
            }

            // 2. 加载 RawLocationStore 中的原始流水点（包含正在进行中的点）
            val rawPoints = rawStore.loadLocations(startOfToday)
            val trajectoryPoints = rawPoints.map { it.latitude to it.longitude }

            // 3. 合并流水与已存足迹（以流水为主，因为它更完整且包含当前点）
            // 如果流水为空（比如刚装 App），则退而求其次用足迹
            val finalPoints = if (trajectoryPoints.isNotEmpty()) trajectoryPoints else dbPoints
            
            _pathPoints.value = finalPoints.map { it to 0L }
        }
    }
}
