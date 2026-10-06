package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.aptabase.Aptabase
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.ActivitySuggestion
import com.ct106.difangke.service.GeocodeService
import com.ct106.difangke.service.PhotoAutoLinker
import com.ct106.difangke.ui.shared.TimelineEditActions
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.util.Date

/**
 * Footprint detail state. Every edit is persisted immediately (iOS parity) through
 * [TimelineEditActions]; there is no explicit "保存".
 */
class FootprintDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    private val prefs = AppPreferences(application)

    private val _footprint = MutableStateFlow<FootprintEntity?>(null)
    val footprint: StateFlow<FootprintEntity?> = _footprint.asStateFlow()

    /** True once the footprint was removed/ignored/merged away — the host should dismiss. */
    private val _isGone = MutableStateFlow(false)
    val isGone: StateFlow<Boolean> = _isGone.asStateFlow()

    val allPlaces: StateFlow<List<PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val activityTypes: StateFlow<List<ActivityTypeEntity>> = db.activityTypeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _placeHistory = MutableStateFlow<List<FootprintEntity>>(emptyList())

    /** iOS getSuggestedActivities(includeFallback: false) for the activity picker. */
    val suggestedActivities: StateFlow<List<ActivityTypeEntity>> =
        combine(_footprint, activityTypes, allPlaces, _placeHistory) { fp, types, places, history ->
            if (fp == null) emptyList()
            else ActivitySuggestion.getSuggestedActivities(fp, types, places, history, includeFallback = false)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _previousFootprint = MutableStateFlow<FootprintEntity?>(null)
    val previousFootprint: StateFlow<FootprintEntity?> = _previousFootprint.asStateFlow()

    private val _nextFootprint = MutableStateFlow<FootprintEntity?>(null)
    val nextFootprint: StateFlow<FootprintEntity?> = _nextFootprint.asStateFlow()

    private val _mergePartner = MutableStateFlow<FootprintEntity?>(null)
    val mergePartner: StateFlow<FootprintEntity?> = _mergePartner.asStateFlow()

    private val _isUpdatingAddress = MutableStateFlow(false)
    val isUpdatingAddress: StateFlow<Boolean> = _isUpdatingAddress.asStateFlow()

    private var loadedId: String? = null
    private var didAutoLink = false

    fun loadFootprint(id: String) {
        if (loadedId == id && _footprint.value != null) return
        loadedId = id
        didAutoLink = false
        _isGone.value = false
        viewModelScope.launch { reload(id) }
    }

    /** Re-read the current footprint from the DB (e.g. after photos were linked externally). */
    fun refresh() {
        val id = loadedId ?: return
        viewModelScope.launch { reload(id) }
    }

    private suspend fun reload(id: String? = loadedId) {
        id ?: return
        val fp = db.footprintDao().getById(id)
        if (fp == null || fp.statusValue == "ignored") {
            _footprint.value = fp
            _isGone.value = true
            return
        }
        _footprint.value = fp
        refreshAdjacent(fp)
        _placeHistory.value = fp.placeID?.let { pid -> db.footprintDao().getAll().filter { it.placeID == pid } }.orEmpty()
        if (fp.address == null) refreshAddress(fp)
    }

    private suspend fun refreshAdjacent(fp: FootprintEntity) {
        _previousFootprint.value = db.footprintDao().getPreviousBefore(fp.footprintID, fp.startTime)
        _nextFootprint.value = db.footprintDao().getNextAfter(fp.footprintID, fp.endTime)
        _mergePartner.value = TimelineEditActions.findFootprintMergePartner(db, fp)
    }

    private suspend fun refreshAddress(fp: FootprintEntity) {
        val coord = TimelineEditActions.representativeCoordinate(fp) ?: return
        _isUpdatingAddress.value = true
        val addr = runCatching { GeocodeService.shared.reverseGeocode(coord.first, coord.second) }.getOrNull()
        _isUpdatingAddress.value = false
        if (!addr.isNullOrEmpty()) {
            val current = db.footprintDao().getById(fp.footprintID) ?: return
            if (current.address == null) {
                val updated = current.copy(address = addr)
                db.footprintDao().update(updated)
                _footprint.value = updated
            }
        }
    }

    /** iOS onAppear: `if isAutoPhotoLinkEnabled { locationManager.linkPhotos(...) }`. */
    fun autoLinkPhotosIfEnabled() {
        val fp = _footprint.value ?: return
        if (didAutoLink) return
        didAutoLink = true
        viewModelScope.launch {
            if (!prefs.isAutoPhotoLinkEnabled.first()) return@launch
            PhotoAutoLinker.linkPhotos(getApplication(), db, fp)?.let { _footprint.value = it }
        }
    }

    private fun edit(block: suspend (FootprintEntity) -> FootprintEntity?) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = block(current)
            if (updated != null) {
                _footprint.value = updated
                refreshAdjacent(updated)
            }
        }
    }

    fun setActivity(activityTypeId: String?) = edit {
        TimelineEditActions.setActivity(db, it, activityTypeId)
    }

    fun setHighlight(isHighlight: Boolean) = edit {
        TimelineEditActions.setHighlight(db, it, isHighlight)
    }

    fun toggleHighlight() = edit { TimelineEditActions.toggleHighlight(db, it) }

    /** iOS saveReason: only when changed; marks AI analysed + manual metadata edit. */
    fun saveReason(text: String) {
        val current = _footprint.value ?: return
        if (text == (current.reason ?: "")) return
        edit { fp ->
            TimelineEditActions.updateFootprintMetadata(db, fp) {
                it.copy(
                    reason = text,
                    aiAnalyzed = true,
                    locationHash = if (it.locationHash == "ONGOING_STAY") "MANUAL_STAY" else it.locationHash
                )
            }.also { Aptabase.instance.trackEvent("footprint_edited") }
        }
    }

    fun selectPlace(result: GeocodeService.SearchResult) = edit { fp ->
        TimelineEditActions.applyPlaceSelection(db, fp, result).also {
            _placeHistory.value = it.placeID?.let { pid -> db.footprintDao().getAll().filter { f -> f.placeID == pid } }.orEmpty()
        }
    }

    fun updatePhotos(uris: List<String>) = edit { fp ->
        TimelineEditActions.updateFootprintMetadata(db, fp) {
            it.copy(photoAssetIDsJson = JSONArray(uris.distinct()).toString())
        }.also { Aptabase.instance.trackEvent("footprint_photos_edited") }
    }

    fun addPhotos(uris: List<String>) {
        val existing = _footprint.value?.let(::footprintPhotoUris).orEmpty()
        val added = uris.filterNot { it in existing }
        if (added.isNotEmpty()) updatePhotos(existing + added)
    }

    fun removePhoto(uri: String) {
        val existing = _footprint.value?.let(::footprintPhotoUris).orEmpty()
        updatePhotos(existing.filterNot { it == uri })
    }

    fun adjustTime(newStart: Date, newEnd: Date, onSaved: () -> Unit = {}) = edit { fp ->
        TimelineEditActions.adjustFootprintTime(db, getApplication(), fp, newStart, newEnd).also { onSaved() }
    }

    fun splitFootprint(splitTime: Date, firstActivity: String?, secondActivity: String?, onSaved: () -> Unit = {}) = edit { fp ->
        TimelineEditActions.splitFootprint(db, getApplication(), fp, splitTime, firstActivity, secondActivity)?.first.also { onSaved() }
    }

    fun mergeAdjacent(onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        val partner = _mergePartner.value ?: return
        viewModelScope.launch {
            val merged = TimelineEditActions.mergeFootprints(db, current, partner)
            loadedId = merged.footprintID
            _footprint.value = merged
            refreshAdjacent(merged)
            onSaved()
        }
    }

    fun deleteFootprint(onDone: () -> Unit = {}) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            TimelineEditActions.deleteFootprint(db, current)
            _isGone.value = true
            onDone()
        }
    }

    fun ignoreLocation(onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            TimelineEditActions.ignorePlace(db, current)
            _isGone.value = true
            onSaved()
        }
    }

    /** iOS AddToFavoriteModal save: create a user-defined place and link the footprint. */
    fun addAsImportantPlace(name: String, latitude: Double, longitude: Double, radius: Float, address: String?, onSaved: () -> Unit = {}) = edit { fp ->
        val finalName = name.trim().ifEmpty { fp.address ?: "未知地点" }
        val place = PlaceEntity(
            name = finalName,
            latitude = latitude,
            longitude = longitude,
            radius = radius,
            address = address,
            isUserDefined = true
        )
        db.placeDao().insert(place)
        TimelineEditActions.updateFootprintMetadata(db, fp) {
            it.copy(placeID = place.placeID, address = finalName, isAddressEditedByHand = true)
        }.also {
            Aptabase.instance.trackEvent("place_added")
            onSaved()
        }
    }
}

fun footprintPhotoUris(footprint: FootprintEntity): List<String> = runCatching {
    val array = JSONArray(footprint.photoAssetIDsJson)
    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
}.getOrDefault(emptyList())
