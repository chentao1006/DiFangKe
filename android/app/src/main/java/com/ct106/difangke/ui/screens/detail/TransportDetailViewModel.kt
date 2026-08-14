package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.TransportManualSelectionEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import com.aptabase.Aptabase
import java.util.Calendar
import java.util.Date
import java.util.UUID

class TransportDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private val _transport = MutableStateFlow<TransportRecordEntity?>(null)
    val transport: StateFlow<TransportRecordEntity?> = _transport.asStateFlow()

    private val _adjacentTransports = MutableStateFlow<List<TransportRecordEntity>>(emptyList())
    val adjacentTransports: StateFlow<List<TransportRecordEntity>> = _adjacentTransports.asStateFlow()

    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun loadTransport(id: String) {
        viewModelScope.launch {
            val record = db.transportRecordDao().getById(id)
            _transport.value = record
            _adjacentTransports.value = record?.let { current ->
                val calendar = Calendar.getInstance().apply { time = current.startTime }
                calendar.set(Calendar.HOUR_OF_DAY, 0)
                calendar.set(Calendar.MINUTE, 0)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                val dayStart = calendar.time
                calendar.add(Calendar.DAY_OF_YEAR, 1)
                val sameDay = db.transportRecordDao().getForDay(dayStart, calendar.time)
                val index = sameDay.indexOfFirst { it.recordID == current.recordID }
                if (index < 0) return@let emptyList()
                listOfNotNull(
                    sameDay.getOrNull(index - 1),
                    sameDay.getOrNull(index + 1)
                ).filter { candidate ->
                    val lowerBound = minOf(current.endTime.time, candidate.endTime.time)
                    val upperBound = maxOf(current.startTime.time, candidate.startTime.time)
                    upperBound <= lowerBound || db.footprintDao()
                        .getBetween(Date(lowerBound), Date(upperBound))
                        .isEmpty()
                }
            }.orEmpty()
        }
    }

    fun updateTransport(manualType: TransportType?, startLocation: String?, endLocation: String?) {
        Aptabase.instance.trackEvent("transport_edited")
        val current = _transport.value ?: return
        viewModelScope.launch {
            val updated = current.copy(
                manualTypeRaw = manualType?.raw ?: current.manualTypeRaw,
                // Keep the persisted canonical type aligned with the manual
                // override. Timeline merging and preference learning also read
                // typeRaw, matching the iOS editor's behavior.
                typeRaw = manualType?.raw ?: current.typeRaw,
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
            db.transportManualSelectionDao().insert(
                TransportManualSelectionEntity(
                    recordID = current.recordID,
                    startTime = current.startTime,
                    endTime = current.endTime,
                    vehicleType = current.manualTypeRaw ?: current.typeRaw,
                    isDeleted = true
                )
            )
            db.transportRecordDao().delete(current)
            _transport.value = null
        }
    }

    fun adjustTime(newStart: Date, newEnd: Date, onSaved: () -> Unit = {}) {
        val current = _transport.value ?: return
        val start = roundToMinute(newStart)
        val end = roundToMinute(Date(maxOf(newEnd.time, start.time + 60_000L)))
        viewModelScope.launch {
            val durationSeconds = (end.time - start.time).coerceAtLeast(1L) / 1000.0
            val updated = current.copy(
                day = startOfDay(start),
                startTime = start,
                endTime = end,
                averageSpeed = current.distance / durationSeconds,
                // Time boundaries are a manual statement too; keep them from
                // being regenerated into a different segment.
                manualTypeRaw = current.manualTypeRaw ?: current.typeRaw
            )
            db.transportRecordDao().update(updated)
            _transport.value = updated
            Aptabase.instance.trackEvent("transport_time_adjusted")
            onSaved()
        }
    }

    fun splitAt(splitTime: Date, onSplit: () -> Unit = {}) {
        val current = _transport.value ?: return
        val earliest = current.startTime.time + 60_000L
        val latest = current.endTime.time - 60_000L
        if (latest < earliest) return
        val split = roundToMinute(Date(splitTime.time.coerceIn(earliest, latest)))
        if (split.time <= current.startTime.time || split.time >= current.endTime.time) return
        viewModelScope.launch {
            val totalDuration = (current.endTime.time - current.startTime.time).toDouble().coerceAtLeast(1.0)
            val firstRatio = (split.time - current.startTime.time) / totalDuration
            val secondRatio = 1.0 - firstRatio
            val protectedType = current.manualTypeRaw ?: current.typeRaw
            val first = current.copy(
                endTime = split,
                day = startOfDay(current.startTime),
                distance = current.distance * firstRatio,
                averageSpeed = current.averageSpeed,
                stepCount = current.stepCount?.let { (it * firstRatio).toInt() },
                manualTypeRaw = protectedType,
                typeRaw = protectedType
            )
            val second = current.copy(
                recordID = UUID.randomUUID().toString(),
                day = startOfDay(split),
                startTime = split,
                distance = current.distance * secondRatio,
                averageSpeed = current.averageSpeed,
                stepCount = current.stepCount?.let { it - (first.stepCount ?: 0) },
                manualTypeRaw = protectedType,
                typeRaw = protectedType
            )
            db.transportRecordDao().update(first)
            db.transportRecordDao().insert(second)
            _transport.value = first
            _adjacentTransports.value = emptyList()
            Aptabase.instance.trackEvent("transport_split")
            onSplit()
        }
    }

    /**
     * A merged interval is explicitly user-owned.  This mirrors the iOS timeline
     * editor: preserve all geometry and totals, and retain manualTypeRaw so the
     * background timeline builder cannot later split or reclassify it.
     */
    fun mergeWith(other: TransportRecordEntity, onMerged: () -> Unit = {}) {
        val current = _transport.value ?: return
        if (_adjacentTransports.value.none { it.recordID == other.recordID }) return
        viewModelScope.launch {
            val first = if (current.startTime <= other.startTime) current else other
            val second = if (first.recordID == current.recordID) other else current
            val mergedStart = minOf(first.startTime, second.startTime)
            val mergedEnd = maxOf(first.endTime, second.endTime)
            val durationSeconds = (mergedEnd.time - mergedStart.time).coerceAtLeast(1L) / 1000.0
            val selectedType = first.manualTypeRaw ?: second.manualTypeRaw ?: first.typeRaw
            // Keep the record currently on screen as the surviving record. The
            // route remains valid after saving, even when the chosen neighbour
            // started earlier in the day.
            val merged = current.copy(
                startTime = mergedStart,
                endTime = mergedEnd,
                typeRaw = selectedType,
                manualTypeRaw = selectedType,
                startLocation = first.startLocation,
                endLocation = second.endLocation,
                distance = first.distance + second.distance,
                averageSpeed = (first.distance + second.distance) / durationSeconds,
                pointsJson = mergePointsJson(first.pointsJson, second.pointsJson),
                stepCount = listOfNotNull(first.stepCount, second.stepCount).takeIf { it.isNotEmpty() }?.sum()
            )
            db.transportRecordDao().update(merged)
            db.transportRecordDao().delete(other)
            _transport.value = merged
            _adjacentTransports.value = emptyList()
            Aptabase.instance.trackEvent("transport_adjacent_merged")
            onMerged()
        }
    }

    private fun mergePointsJson(first: String, second: String): String {
        return runCatching {
            val merged = org.json.JSONArray()
            listOf(first, second).forEach { raw ->
                val points = org.json.JSONArray(raw)
                for (index in 0 until points.length()) merged.put(points.get(index))
            }
            merged.toString()
        }.getOrElse { first }
    }

    private fun roundToMinute(value: Date): Date = Date(value.time / 60_000L * 60_000L)

    private fun startOfDay(value: Date): Date = Calendar.getInstance().run {
        time = value
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        time
    }
}
