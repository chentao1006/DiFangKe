package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

class HistoryViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared

    private val _footprints = MutableStateFlow<List<FootprintEntity>>(emptyList())
    
    // 按天分组的足迹
    val groupedFootprints = _footprints.map { list ->
        list.groupBy { fp ->
            val cal = Calendar.getInstance()
            cal.time = fp.startTime
            cal.set(Calendar.HOUR_OF_DAY, 0)
            cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            cal.time
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    init {
        loadAllFootprints()
    }

    fun loadAllFootprints() {
        viewModelScope.launch {
            _isRefreshing.value = true
            _footprints.value = db.footprintDao().getAll()
            _isRefreshing.value = false
        }
    }

    fun deleteFootprint(footprint: FootprintEntity) {
        viewModelScope.launch {
            db.footprintDao().delete(footprint)
            loadAllFootprints()
        }
    }
}
