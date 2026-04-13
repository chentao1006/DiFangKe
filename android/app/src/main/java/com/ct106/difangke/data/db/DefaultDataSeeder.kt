package com.ct106.difangke.data.db

import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.model.DEFAULT_ACTIVITY_PRESETS
import java.util.UUID

object DefaultDataSeeder {
    suspend fun seedIfNeeded(db: AppDatabase, prefs: com.ct106.difangke.data.prefs.AppPreferences) {
        if (!prefs.getHasSeededDefaultData()) {
            val activityDao = db.activityTypeDao()
            if (activityDao.count() == 0) {
                val entities = DEFAULT_ACTIVITY_PRESETS.map { preset ->
                    ActivityTypeEntity(
                        id = UUID.randomUUID().toString(),
                        name = preset.name,
                        icon = preset.icon,
                        colorHex = preset.colorHex,
                        sortOrder = preset.sortOrder,
                        isSystem = true
                    )
                }
                activityDao.insertAll(entities)
            }
            prefs.setHasSeededDefaultData(true)
        }
    }
}
