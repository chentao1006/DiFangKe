package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.*

class DataManagerViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    private val rawStore = RawLocationStore.getInstance(application)
    
    private val backupService = com.ct106.difangke.service.BackupService(application, db)
    
    private val _todayPointsCount = MutableStateFlow(0)
    val todayPointsCount: StateFlow<Int> = _todayPointsCount

    private val _importResult = MutableStateFlow<String?>(null)
    val importResult: StateFlow<String?> = _importResult

    private val _isProcessing = MutableStateFlow(false)
    val isProcessing: StateFlow<Boolean> = _isProcessing

    init {
        refreshTodayPoints()
    }

    fun refreshTodayPoints() {
        viewModelScope.launch {
            val count = withContext(Dispatchers.IO) {
                rawStore.getTotalPointsCount(Date())
            }
            _todayPointsCount.value = count
        }
    }

    fun importData(uri: android.net.Uri) {
        viewModelScope.launch {
            _isProcessing.value = true
            try {
                val json = withContext(Dispatchers.IO) {
                    getApplication<Application>().contentResolver.openInputStream(uri)?.use { 
                        it.bufferedReader().readText()
                    } ?: ""
                }
                val report = backupService.restoreBackup(json)
                _importResult.value = "导入成功！\n新增足迹: ${report.new}, 跳过: ${report.skipped}\n重要地点: ${report.newPlaces}"
            } catch (e: Exception) {
                _importResult.value = "导入失败: ${e.message}"
            } finally {
                _isProcessing.value = false
            }
        }
    }

    fun clearImportResult() {
        _importResult.value = null
    }

    fun clearAllData() {
        viewModelScope.launch {
            _isProcessing.value = true
            withContext(Dispatchers.IO) {
                db.footprintDao().deleteAll()
                db.placeDao().deleteAll()
            }
            _isProcessing.value = false
        }
    }
}
