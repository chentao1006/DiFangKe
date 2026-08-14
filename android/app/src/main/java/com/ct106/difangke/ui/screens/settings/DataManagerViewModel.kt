package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.service.PersistentTimelineBuilder
import com.aptabase.Aptabase
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

    private val _rebuildProgress = MutableStateFlow<Pair<Int, Int>?>(null)
    val rebuildProgress: StateFlow<Pair<Int, Int>?> = _rebuildProgress
    private var rebuildJob: kotlinx.coroutines.Job? = null

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
        Aptabase.instance.trackEvent("data_import_started")
        viewModelScope.launch {
            _isProcessing.value = true
            try {
                val json = withContext(Dispatchers.IO) {
                    getApplication<Application>().contentResolver.openInputStream(uri)?.use { 
                        it.bufferedReader().readText()
                    } ?: ""
                }
                val report = backupService.restoreBackup(json)
                _importResult.value = """
                    导入成功！
                    - 足迹: ${report.newFootprints} 新增, ${report.skippedFootprints} 跳过
                    - 交通: ${report.newTransports} 新增, ${report.skippedTransports} 跳过
                    - 重要地点: ${report.newPlacesUser} 新增, ${report.skippedPlacesUser} 跳过
                    - 其他地点: ${report.newPlacesSystem} 新增, ${report.skippedPlacesSystem} 跳过
                    - 活动类型: ${report.newActivityTypes} 新增
                    - 行程计划: ${report.newFutureTrips} 新增, ${report.skippedFutureTrips} 跳过
                """.trimIndent()
            } catch (e: Exception) {
                _importResult.value = "导入失败: ${e.message}"
            } finally {
                _isProcessing.value = false
            }
        }
    }

    fun exportData(uri: android.net.Uri) {
        viewModelScope.launch {
            _isProcessing.value = true
            try {
                val backup = backupService.generateBackup()
                withContext(Dispatchers.IO) {
                    getApplication<Application>().contentResolver.openOutputStream(uri)?.bufferedWriter()?.use { it.write(backup) }
                        ?: error("无法打开导出文件")
                }
                _importResult.value = "备份已导出。"
            } catch (e: Exception) {
                _importResult.value = "导出失败: ${e.message}"
            } finally {
                _isProcessing.value = false
            }
        }
    }

    fun exportRawLogs(uri: android.net.Uri) {
        viewModelScope.launch {
            _isProcessing.value = true
            try {
                withContext(Dispatchers.IO) {
                    val csv = rawStore.exportAllCsv()
                    getApplication<Application>().contentResolver.openOutputStream(uri)?.bufferedWriter()?.use { it.write(csv) }
                        ?: error("无法打开导出文件")
                }
                _importResult.value = "原始轨迹日志已导出。"
            } catch (e: Exception) {
                _importResult.value = "日志导出失败: ${e.message}"
            } finally {
                _isProcessing.value = false
            }
        }
    }

    fun clearImportResult() {
        _importResult.value = null
    }

    fun rebuildAllTimelines() {
        if (rebuildJob?.isActive == true) return
        Aptabase.instance.trackEvent("timeline_rebuilt")
        rebuildJob = viewModelScope.launch {
            val dates = withContext(Dispatchers.IO) { rawStore.getAvailableDates().sorted() }
            if (dates.isEmpty()) {
                _importResult.value = "没有可用于重建的原始轨迹。"
                return@launch
            }
            _isProcessing.value = true
            try {
                val builder = PersistentTimelineBuilder(getApplication())
                dates.forEachIndexed { index, date ->
                    _rebuildProgress.value = (index + 1) to dates.size
                    builder.rebuildDay(date)
                }
                _importResult.value = "已根据 ${dates.size} 天原始轨迹重建时间线；手动修改与已确认记录已保留。"
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                _importResult.value = "重建失败: ${error.message ?: "未知错误"}"
            } finally {
                _rebuildProgress.value = null
                _isProcessing.value = false
            }
        }
    }

    fun cancelRebuildAllTimelines() {
        rebuildJob?.cancel()
        rebuildJob = null
        _rebuildProgress.value = null
        _isProcessing.value = false
    }

    fun clearAllData() {
        Aptabase.instance.trackEvent("data_cleared")
        viewModelScope.launch {
            _isProcessing.value = true
            withContext(Dispatchers.IO) {
                db.footprintDao().deleteAll()
                db.placeDao().deleteAll()
                db.futureTripDao().deleteAll()
                db.transportRecordDao().deleteAll()
                db.transportManualSelectionDao().deleteAll()
                db.dailyInsightDao().deleteAll()
                db.activityTypeDao().deleteAll()
                rawStore.clearAll()
            }
            _isProcessing.value = false
        }
    }
}
