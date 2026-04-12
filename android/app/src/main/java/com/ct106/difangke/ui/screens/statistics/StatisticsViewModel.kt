package com.ct106.difangke.ui.screens.statistics

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.model.TransportType
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.*

class StatisticsViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _last7DaysData = MutableStateFlow<List<Float>>(emptyList())
    val last7DaysData: StateFlow<List<Float>> = _last7DaysData.asStateFlow()

    private val _transportDistribution = MutableStateFlow<Map<TransportType, Float>>(emptyMap())
    val transportDistribution: StateFlow<Map<TransportType, Float>> = _transportDistribution.asStateFlow()

    init {
        loadStatistics()
    }

    private fun loadStatistics() {
        viewModelScope.launch {
            val footprints = db.footprintDao().getAll()
            val transports = db.transportRecordDao().observeAll().first()

            // 1. 最近7天的活动时长统计
            val cal = Calendar.getInstance()
            val now = cal.time
            val daysData = mutableListOf<Float>()
            
            for (i in 6 downTo 0) {
                val dayCal = Calendar.getInstance().apply {
                    time = now
                    add(Calendar.DAY_OF_YEAR, -i)
                    set(Calendar.HOUR_OF_DAY, 0)
                    set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }
                val start = dayCal.time
                dayCal.add(Calendar.DAY_OF_YEAR, 1)
                val end = dayCal.time
                
                val durationMs = footprints.filter { it.startTime >= start && it.startTime < end }
                    .sumOf { it.endTime.time - it.startTime.time }
                
                daysData.add(durationMs / (1000f * 3600f)) // 转换为小时
            }
            _last7DaysData.value = daysData

            // 2. 交通方式占比
            val dist = transports.groupBy { TransportType.from(it.typeRaw) }
                .mapValues { (_, records) -> records.sumOf { it.distance }.toFloat() }
            _transportDistribution.value = dist
        }
    }
}
