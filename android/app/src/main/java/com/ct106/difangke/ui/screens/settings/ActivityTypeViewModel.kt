package com.ct106.difangke.ui.screens.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.UUID

class ActivityTypeViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    
    val activities: StateFlow<List<ActivityTypeEntity>> = db.activityTypeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun saveActivity(id: String?, name: String, icon: String, colorHex: String) {
        viewModelScope.launch {
            val entity = ActivityTypeEntity(
                id = id ?: UUID.randomUUID().toString(),
                name = name,
                icon = icon,
                colorHex = colorHex,
                sortOrder = if (id == null) (activities.value.maxOfOrNull { it.sortOrder } ?: -1) + 1 else 0 // Simplified
            )
            if (id == null) {
                db.activityTypeDao().insert(entity)
            } else {
                db.activityTypeDao().update(entity)
            }
        }
    }

    fun deleteActivity(activity: ActivityTypeEntity) {
        viewModelScope.launch {
            db.activityTypeDao().delete(activity)
        }
    }
    
    fun updateOrder(list: List<ActivityTypeEntity>) {
        viewModelScope.launch {
            list.forEachIndexed { index, activity ->
                db.activityTypeDao().update(activity.copy(sortOrder = index))
            }
        }
    }
}
