package com.ct106.difangke.ui.screens.settings

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.datastore.preferences.core.edit
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.LocationTrackingService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import com.ct106.difangke.service.UpdateManager
import com.ct106.difangke.service.UpdateInfo

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = AppPreferences(application)
    private val database = com.ct106.difangke.DiFangKeApp.instance.database
    
    val isTrackingEnabled: StateFlow<Boolean> = prefs.isTrackingEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)
        
    val isAiEnabled: StateFlow<Boolean> = prefs.isAiEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val aiServiceType: StateFlow<String> = prefs.aiServiceType
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "public")

    val isDailyNotificationEnabled: StateFlow<Boolean> = prefs.isDailyNotificationEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)
        
    val isHighlightNotificationEnabled: StateFlow<Boolean> = prefs.isHighlightNotificationEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val notificationHour: StateFlow<Int> = prefs.notificationHour
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 21)
        
    val notificationMinute: StateFlow<Int> = prefs.notificationMinute
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val isAutoPhotoLinkEnabled: StateFlow<Boolean> = prefs.isAutoPhotoLinkEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val importantPlacesCount = database.placeDao().observeAll()
        .map { list: List<com.ct106.difangke.data.db.entity.PlaceEntity> -> list.filter { p -> p.isUserDefined }.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val savedPlacesCount = database.placeDao().observeAll()
        .map { list: List<com.ct106.difangke.data.db.entity.PlaceEntity> -> list.filter { p -> !p.isUserDefined && !p.isIgnored }.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val ignoredPlacesCount = database.placeDao().observeAll()
        .map { list: List<com.ct106.difangke.data.db.entity.PlaceEntity> -> list.filter { p -> p.isIgnored && !p.isUserDefined }.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val activitiesCount = database.activityTypeDao().observeAll()
        .map { list: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity> -> list.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

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

    fun setDailyNotificationEnabled(enabled: Boolean) {
        viewModelScope.launch {
            prefs.setDailyNotificationEnabled(enabled)
            updateNotificationSchedule()
        }
    }

    fun setHighlightNotificationEnabled(enabled: Boolean) {
        viewModelScope.launch {
            prefs.setHighlightNotificationEnabled(enabled)
        }
    }

    fun setNotificationTime(hour: Int, minute: Int) {
        viewModelScope.launch {
            prefs.setNotificationTime(hour, minute)
            updateNotificationSchedule()
        }
    }

    fun setAutoPhotoLinkEnabled(enabled: Boolean) {
        viewModelScope.launch {
            prefs.setAutoPhotoLinkEnabled(enabled)
        }
    }


    private fun updateNotificationSchedule() {
        viewModelScope.launch {
            val enabled = prefs.isDailyNotificationEnabled.first()
            if (enabled) {
                val hour = prefs.notificationHour.first()
                val minute = prefs.notificationMinute.first()
                com.ct106.difangke.service.DailySummaryWorker.schedule(getApplication(), hour, minute)
            } else {
                com.ct106.difangke.service.DailySummaryWorker.cancel(getApplication())
            }
        }
    }

    // ── 自动更新 ──────────────────────────────────────────────────
    private val _updateInfo = MutableStateFlow<UpdateInfo?>(null)
    val updateInfo: StateFlow<UpdateInfo?> = _updateInfo.asStateFlow()

    private val _isCheckingUpdate = MutableStateFlow(false)
    val isCheckingUpdate: StateFlow<Boolean> = _isCheckingUpdate.asStateFlow()

    fun checkUpdate() {
        viewModelScope.launch {
            _isCheckingUpdate.value = true
            android.widget.Toast.makeText(getApplication(), "请求服务器中...", android.widget.Toast.LENGTH_SHORT).show()
            val info = UpdateManager.getInstance(getApplication()).checkUpdate()
            if (info == null) {
                android.widget.Toast.makeText(getApplication(), "无法连接到更新服务器，请检查网络", android.widget.Toast.LENGTH_LONG).show()
            }
            _updateInfo.value = info
            _isCheckingUpdate.value = false
        }
    }

    fun startUpdate(url: String, versionCode: Int) {
        UpdateManager.getInstance(getApplication()).downloadAndInstall(url, versionCode)
    }

    fun clearUpdateInfo() {
        _updateInfo.value = null
    }

    fun isNewVersionAvailable(remoteVersionCode: Int): Boolean {
        return UpdateManager.getInstance(getApplication()).isNewVersionAvailable(remoteVersionCode)
    }
}

