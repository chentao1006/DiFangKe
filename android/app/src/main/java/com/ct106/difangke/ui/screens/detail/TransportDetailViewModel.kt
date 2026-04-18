package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

class TransportDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _transport = MutableStateFlow<TransportRecordEntity?>(null)
    val transport: StateFlow<TransportRecordEntity?> = _transport.asStateFlow()

    fun loadTransport(id: String) {
        viewModelScope.launch {
            val record = db.transportRecordDao().getById(id)
            _transport.value = record
        }
    }

    fun updateTransport(manualType: TransportType?, startLocation: String?, endLocation: String?) {
        val current = _transport.value ?: return
        viewModelScope.launch {
            val updated = current.copy(
                manualTypeRaw = manualType?.raw ?: current.manualTypeRaw,
                startLocation = startLocation ?: current.startLocation,
                endLocation = endLocation ?: current.endLocation
            )
            db.transportRecordDao().update(updated)
            _transport.value = updated
        }
    }

    fun deleteTransport() {
        val current = _transport.value ?: return
        viewModelScope.launch {
            db.transportRecordDao().ignoreById(current.recordID)
            _transport.value = null
        }
    }
}
