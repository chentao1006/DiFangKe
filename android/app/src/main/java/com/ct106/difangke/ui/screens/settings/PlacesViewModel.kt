package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.service.LocationTrackingService
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlin.math.*

class PlacesViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    
    val allPlaces: StateFlow<List<PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val importantPlaces = allPlaces.map { it.filter { p -> p.isUserDefined } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val currentLocation = LocationTrackingService.stateFlow.map { state ->
        when (state) {
            is LocationTrackingService.TrackingState.Tracking -> state.lat?.let { lat -> state.lon?.let { lon -> Pair(lat, lon) } }
            is LocationTrackingService.TrackingState.OngoingStay -> Pair(state.lat, state.lon)
            else -> null
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val savedPlaces = allPlaces.combine(currentLocation) { places, location ->
        val list = places.filter { p -> !p.isUserDefined && !p.isIgnored }
        if (location != null) {
            list.sortedBy { p ->
                haversine(location.first, location.second, p.latitude, p.longitude)
            }
        } else {
            list
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val ignoredPlaces = allPlaces.map { it.filter { p -> p.isIgnored && !p.isUserDefined } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2).pow(2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2).pow(2)
        val c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    fun deletePlace(place: PlaceEntity) {
        viewModelScope.launch {
            db.placeDao().delete(place)
        }
    }

    fun updatePlace(place: PlaceEntity) {
        viewModelScope.launch {
            db.placeDao().update(place)
        }
    }

    fun savePlace(id: String?, name: String, address: String, lat: Double, lon: Double, radius: Float = 50f) {
        viewModelScope.launch {
            if (id == null) {
                db.placeDao().insert(PlaceEntity(
                    name = name,
                    address = address,
                    latitude = lat,
                    longitude = lon,
                    radius = radius,
                    isUserDefined = true
                ))
            } else {
                val existing = db.placeDao().getById(id)
                if (existing != null) {
                    db.placeDao().update(existing.copy(
                        name = name,
                        address = address,
                        latitude = lat,
                        longitude = lon,
                        radius = radius
                    ))
                }
            }
        }
    }
}
