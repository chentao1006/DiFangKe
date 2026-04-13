package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class AiSettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = AppPreferences(application)
    
    val aiServiceType: StateFlow<String> = prefs.aiServiceType
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "public")
        
    suspend fun getCustomUrl() = prefs.getCustomAiUrl()
    suspend fun getCustomKey() = prefs.getCustomAiKey()
    suspend fun getCustomModel() = prefs.getCustomAiModel()

    fun setAiServiceType(type: String) {
        viewModelScope.launch {
            prefs.setAiServiceType(type)
        }
    }

    fun setCustomConfig(url: String, key: String, model: String) {
        viewModelScope.launch {
            prefs.setCustomAiUrl(url)
            prefs.setCustomAiKey(key)
            prefs.setCustomAiModel(model)
        }
    }

    fun testConnection(callback: (Boolean, String) -> Unit) {
        viewModelScope.launch {
            OpenAIService.shared.testConnection(callback)
        }
    }
}
