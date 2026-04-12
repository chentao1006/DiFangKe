package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

class FootprintDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _footprint = MutableStateFlow<FootprintEntity?>(null)
    val footprint: StateFlow<FootprintEntity?> = _footprint.asStateFlow()

    fun loadFootprint(id: String) {
        viewModelScope.launch {
            _footprint.value = db.footprintDao().getById(id)
        }
    }

    fun updateFootprint(title: String, reason: String) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = current.copy(title = title, reason = reason)
            db.footprintDao().update(updated)
            _footprint.value = updated
        }
    }
}
