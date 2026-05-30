package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import com.aptabase.Aptabase

class TransportDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _transport = MutableStateFlow<TransportRecordEntity?>(null)
    val transport: StateFlow<TransportRecordEntity?> = _transport.asStateFlow()

    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun loadTransport(id: String) {
        viewModelScope.launch {
            val record = db.transportRecordDao().getById(id)
            _transport.value = record
        }
    }

    fun updateTransport(manualType: TransportType?, startLocation: String?, endLocation: String?) {
        Aptabase.instance.trackEvent("transport_edited")
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
            db.transportRecordDao().delete(current)
            _transport.value = null
        }
    }
}
