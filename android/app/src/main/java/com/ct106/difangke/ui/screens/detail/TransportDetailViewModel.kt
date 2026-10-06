package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.ui.shared.TimelineEditActions
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.Date

/** Transport detail state; every change persists immediately via [TimelineEditActions]. */
class TransportDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _transport = MutableStateFlow<TransportRecordEntity?>(null)
    val transport: StateFlow<TransportRecordEntity?> = _transport.asStateFlow()

    private val _mergePartner = MutableStateFlow<TransportRecordEntity?>(null)
    val mergePartner: StateFlow<TransportRecordEntity?> = _mergePartner.asStateFlow()

    private val _isGone = MutableStateFlow(false)
    val isGone: StateFlow<Boolean> = _isGone.asStateFlow()

    val allPlaces: StateFlow<List<PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private var loadedId: String? = null

    fun loadTransport(id: String) {
        if (loadedId == id && _transport.value != null) return
        loadedId = id
        _isGone.value = false
        viewModelScope.launch {
            val record = db.transportRecordDao().getById(id)
            _transport.value = record
            if (record == null) _isGone.value = true else refresh(record)
        }
    }

    private suspend fun refresh(record: TransportRecordEntity) {
        _mergePartner.value = TimelineEditActions.findTransportMergePartner(db, record)
    }

    private fun edit(block: suspend (TransportRecordEntity) -> TransportRecordEntity?) {
        val current = _transport.value ?: return
        viewModelScope.launch {
            block(current)?.let {
                _transport.value = it
                refresh(it)
            }
        }
    }

    /** iOS saveChoice: type changes save immediately. */
    fun setType(type: TransportType) = edit { TimelineEditActions.setTransportManualType(db, it, type) }

    /** iOS saveLocationOverride: rename start/end; preserves the current type as manual. */
    fun renameEndpoint(isStart: Boolean, name: String) = edit { current ->
        val r = db.transportRecordDao().getById(current.recordID) ?: current
        val updated = r.copy(
            startLocation = if (isStart) name else r.startLocation,
            endLocation = if (!isStart) name else r.endLocation,
            manualTypeRaw = r.manualTypeRaw ?: r.typeRaw
        )
        db.transportRecordDao().update(updated)
        updated
    }

    fun deleteTransport(onDone: () -> Unit = {}) {
        val current = _transport.value ?: return
        viewModelScope.launch {
            TimelineEditActions.deleteTransport(db, current)
            _isGone.value = true
            onDone()
        }
    }

    fun adjustTime(newStart: Date, newEnd: Date, onSaved: () -> Unit = {}) = edit {
        TimelineEditActions.adjustTransportTime(db, getApplication(), it, newStart, newEnd).also { onSaved() }
    }

    fun splitAt(splitTime: Date, onSplit: () -> Unit = {}) = edit {
        TimelineEditActions.splitTransport(db, it, splitTime)?.first.also { onSplit() }
    }

    fun mergeAdjacent(onMerged: () -> Unit = {}) {
        val current = _transport.value ?: return
        val other = _mergePartner.value ?: return
        viewModelScope.launch {
            val merged = TimelineEditActions.mergeTransports(db, current, other)
            loadedId = merged.recordID
            _transport.value = merged
            refresh(merged)
            onMerged()
        }
    }
}
