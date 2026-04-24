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

    private val _matchedPlace = MutableStateFlow<com.ct106.difangke.data.db.entity.PlaceEntity?>(null)
    val matchedPlace: StateFlow<com.ct106.difangke.data.db.entity.PlaceEntity?> = _matchedPlace.asStateFlow()

    private val _activityTypes = MutableStateFlow<List<ActivityTypeEntity>>(emptyList())
    val activityTypes: StateFlow<List<ActivityTypeEntity>> = _activityTypes.asStateFlow()

    private val _nearbyPOIs = MutableStateFlow<List<com.ct106.difangke.service.GeocodeService.SearchResult>>(emptyList())
    val nearbyPOIs: StateFlow<List<com.ct106.difangke.service.GeocodeService.SearchResult>> = _nearbyPOIs.asStateFlow()

    private val geocodeService = com.ct106.difangke.service.GeocodeService.shared

    init {
        viewModelScope.launch {
            db.activityTypeDao().observeAll().collect {
                _activityTypes.value = it
            }
        }
    }

    fun loadFootprint(id: String) {
        viewModelScope.launch {
            val fp = db.footprintDao().getById(id)
            _footprint.value = fp
            
            val allPlaces = db.placeDao().getAll()
            _matchedPlace.value = allPlaces.find { place ->
                (place.placeID == fp?.placeID && place.isUserDefined) ||
                (place.isUserDefined && (
                    place.name.trim() == (fp?.address ?: "").trim() ||
                    (place.address?.trim() ?: "") == (fp?.address ?: "").trim()
                ))
            }

            // 加载周边 POI
            if (fp != null) {
                try {
                    val lats = org.json.JSONArray(fp.latitudeJson)
                    val lons = org.json.JSONArray(fp.longitudeJson)
                    if (lats.length() > 0 && lons.length() > 0) {
                        val lat = lats.getDouble(0)
                        val lon = lons.getDouble(0)
                        
                        val amapPois = geocodeService.getNearbyPOIs(lat, lon)
                        
                        // 加载已保存地点
                        val allSaved = db.placeDao().getAll()
                        val nearbySaved = allSaved.filter { 
                             val results = FloatArray(1)
                             android.location.Location.distanceBetween(lat, lon, it.latitude, it.longitude, results)
                             results[0] < 500 // 500米以内视为“附近”
                        }.map {
                            com.ct106.difangke.service.GeocodeService.SearchResult(
                                name = it.name,
                                address = it.address ?: "已保存地点",
                                latitude = it.latitude,
                                longitude = it.longitude,
                                isSavedPlace = true
                            )
                        }
                        
                        // 合并列表，已保存地点优先
                        _nearbyPOIs.value = (nearbySaved + amapPois).distinctBy { it.name }

                        // 如果地址缺失，自动反查
                        if (fp.address.isNullOrEmpty()) {
                            val addr = geocodeService.reverseGeocode(lat, lon)
                            if (!addr.isNullOrEmpty()) {
                                val updated = fp.copy(address = addr)
                                db.footprintDao().update(updated)
                                _footprint.value = updated
                            }
                        }
                    }
                } catch (e: Exception) {
                    _nearbyPOIs.value = emptyList()
                }
            }
        }
    }

    fun searchPOI(keyword: String) {
        if (keyword.isBlank()) {
             // 如果关键字为空，还原为初始状态列表
             val id = _footprint.value?.footprintID ?: return
             loadFootprint(id)
             return
        }
        
        val fp = _footprint.value ?: return
        viewModelScope.launch {
            try {
                val lats = org.json.JSONArray(fp.latitudeJson)
                val lons = org.json.JSONArray(fp.longitudeJson)
                if (lats.length() > 0 && lons.length() > 0) {
                    val lat = lats.getDouble(0)
                    val lon = lons.getDouble(0)
                    _nearbyPOIs.value = geocodeService.searchNearby(keyword, lat, lon)
                }
            } catch (e: Exception) {
                _nearbyPOIs.value = emptyList()
            }
        }
    }

    fun updateFootprint(title: String, reason: String, address: String, activityTypeValue: String? = null, isHighlight: Boolean = false) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = current.copy(
                title = title, 
                reason = reason,
                address = address.ifBlank { null },
                activityTypeValue = activityTypeValue ?: current.activityTypeValue,
                isHighlight = isHighlight,
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

