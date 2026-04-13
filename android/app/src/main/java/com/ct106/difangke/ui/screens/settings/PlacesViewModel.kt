package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.PlaceEntity
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class PlacesViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    
    val allPlaces: StateFlow<List<PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val importantPlaces = allPlaces.map { it.filter { p -> p.isUserDefined } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val savedPlaces = allPlaces.map { it.filter { p -> !p.isUserDefined && !p.isIgnored } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val ignoredPlaces = allPlaces.map { it.filter { p -> p.isIgnored && !p.isUserDefined } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

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
