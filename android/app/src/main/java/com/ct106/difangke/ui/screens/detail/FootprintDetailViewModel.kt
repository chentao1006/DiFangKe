package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

class FootprintDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _footprint = MutableStateFlow<FootprintEntity?>(null)
    val footprint: StateFlow<FootprintEntity?> = _footprint.asStateFlow()

    private val _activityTypes = MutableStateFlow<List<ActivityTypeEntity>>(emptyList())
    val activityTypes: StateFlow<List<ActivityTypeEntity>> = _activityTypes.asStateFlow()

    init {
        viewModelScope.launch {
            db.activityTypeDao().observeAll().collect {
                _activityTypes.value = it
            }
        }
    }

    fun loadFootprint(id: String) {
        viewModelScope.launch {
            _footprint.value = db.footprintDao().getById(id)
        }
    }

    fun updateFootprint(title: String, reason: String, activityTypeValue: String? = null) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = current.copy(
                title = title, 
                reason = reason,
                activityTypeValue = activityTypeValue ?: current.activityTypeValue,
                isTitleEditedByHand = true,
                aiAnalyzed = true
            )
            db.footprintDao().update(updated)
            _footprint.value = updated
        }
    }

    fun deleteFootprint() {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            db.footprintDao().delete(current)
            _footprint.value = null
        }
    }
}

