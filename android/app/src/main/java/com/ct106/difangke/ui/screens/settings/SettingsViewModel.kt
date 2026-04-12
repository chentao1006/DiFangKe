package com.ct106.difangke.ui.screens.settings

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.LocationTrackingService
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = AppPreferences(application)
    
    val isTrackingEnabled: StateFlow<Boolean> = prefs.isTrackingEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)
        
    val isAiEnabled: StateFlow<Boolean> = prefs.isAiEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    // TODO: Add more state flows for AI URL, Key, etc.

    fun setTrackingEnabled(enabled: Boolean) {
        viewModelScope.launch {
            prefs.setTrackingEnabled(enabled)
            if (enabled) {
                LocationTrackingService.start(getApplication())
            } else {
                LocationTrackingService.stop(getApplication())
            }
        }
    }

    fun setAiEnabled(enabled: Boolean) {
        viewModelScope.launch {
            prefs.setAiEnabled(enabled)
        }
    }
}
