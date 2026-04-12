package com.ct106.difangke.data.prefs

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.*
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "dfk_prefs")

/**
 * 应用首选项（对应 iOS UserDefaults + @AppStorage）
 * 使用 DataStore Preferences 实现响应式偏好存储
 */
class AppPreferences(private val context: Context) {

    companion object {
        val KEY_IS_FIRST_LAUNCH = booleanPreferencesKey("isFirstLaunch")
        val KEY_HAS_LAUNCHED_BEFORE = booleanPreferencesKey("hasLaunchedBefore")
        val KEY_IS_TRACKING_ENABLED = booleanPreferencesKey("isTrackingEnabled")
        val KEY_IS_AI_ENABLED = booleanPreferencesKey("isAiAssistantEnabled")
        val KEY_AI_SERVICE_TYPE = stringPreferencesKey("aiServiceType")
        val KEY_CUSTOM_AI_URL = stringPreferencesKey("customAiUrl")
        val KEY_CUSTOM_AI_KEY = stringPreferencesKey("customAiKey")
        val KEY_CUSTOM_AI_MODEL = stringPreferencesKey("customAiModel")
        val KEY_IS_DAILY_NOTIFICATION_ENABLED = booleanPreferencesKey("isDailyNotificationEnabled")
        val KEY_IS_HIGHLIGHT_NOTIFICATION_ENABLED = booleanPreferencesKey("isHighlightNotificationEnabled")
        val KEY_NOTIFICATION_HOUR = intPreferencesKey("dailyNotificationHour")
        val KEY_NOTIFICATION_MINUTE = intPreferencesKey("dailyNotificationMinute")
        val KEY_IS_AUTO_PHOTO_LINK_ENABLED = booleanPreferencesKey("isAutoPhotoLinkEnabled")
        val KEY_HAS_SEEDED_DEFAULT_DATA = booleanPreferencesKey("hasSeededDefaultData")
        val KEY_HAS_SWIPED = booleanPreferencesKey("hasSwiped")
        val KEY_IS_GUIDE_DISMISSED = booleanPreferencesKey("isGuideDismissed")
        val KEY_IS_NOTIFICATION_GUIDE_DISMISSED = booleanPreferencesKey("isNotificationGuideDismissed")
        val KEY_LAST_MIDNIGHT_SIFT = longPreferencesKey("lastMidnightSift")
    }

    // ── Flows（响应式读取）──────────────────────────────────────────
    val isTrackingEnabled: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_TRACKING_ENABLED] ?: false
    }
    val isAiEnabled: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_AI_ENABLED] ?: false
    }
    val aiServiceType: Flow<String> = context.dataStore.data.map {
        it[KEY_AI_SERVICE_TYPE] ?: "public"
    }
    val isDailyNotificationEnabled: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_DAILY_NOTIFICATION_ENABLED] ?: true
    }
    val isHighlightNotificationEnabled: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_HIGHLIGHT_NOTIFICATION_ENABLED] ?: true
    }
    val notificationHour: Flow<Int> = context.dataStore.data.map {
        it[KEY_NOTIFICATION_HOUR] ?: 21
    }
    val notificationMinute: Flow<Int> = context.dataStore.data.map {
        it[KEY_NOTIFICATION_MINUTE] ?: 0
    }
    val hasSwiped: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_HAS_SWIPED] ?: false
    }
    val isGuideDismissed: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_GUIDE_DISMISSED] ?: false
    }
    val isNotificationGuideDismissed: Flow<Boolean> = context.dataStore.data.map {
        it[KEY_IS_NOTIFICATION_GUIDE_DISMISSED] ?: false
    }

    // ── Suspend 写入 ──────────────────────────────────────────────
    suspend fun setTrackingEnabled(enabled: Boolean) =
        context.dataStore.edit { it[KEY_IS_TRACKING_ENABLED] = enabled }

    suspend fun setAiEnabled(enabled: Boolean) =
        context.dataStore.edit { it[KEY_IS_AI_ENABLED] = enabled }

    suspend fun setAiServiceType(type: String) =
        context.dataStore.edit { it[KEY_AI_SERVICE_TYPE] = type }

    suspend fun setCustomAiUrl(url: String) =
        context.dataStore.edit { it[KEY_CUSTOM_AI_URL] = url }

    suspend fun setCustomAiKey(key: String) =
        context.dataStore.edit { it[KEY_CUSTOM_AI_KEY] = key }

    suspend fun setCustomAiModel(model: String) =
        context.dataStore.edit { it[KEY_CUSTOM_AI_MODEL] = model }

    suspend fun setDailyNotificationEnabled(enabled: Boolean) =
        context.dataStore.edit { it[KEY_IS_DAILY_NOTIFICATION_ENABLED] = enabled }

    suspend fun setHighlightNotificationEnabled(enabled: Boolean) =
        context.dataStore.edit { it[KEY_IS_HIGHLIGHT_NOTIFICATION_ENABLED] = enabled }

    suspend fun setNotificationTime(hour: Int, minute: Int) =
        context.dataStore.edit {
            it[KEY_NOTIFICATION_HOUR] = hour
            it[KEY_NOTIFICATION_MINUTE] = minute
        }

    suspend fun setHasSeededDefaultData(seeded: Boolean) =
        context.dataStore.edit { it[KEY_HAS_SEEDED_DEFAULT_DATA] = seeded }

    suspend fun setHasSwiped(swiped: Boolean) =
        context.dataStore.edit { it[KEY_HAS_SWIPED] = swiped }

    suspend fun setGuideDismissed(dismissed: Boolean) =
        context.dataStore.edit { it[KEY_IS_GUIDE_DISMISSED] = dismissed }

    suspend fun setNotificationGuideDismissed(dismissed: Boolean) =
        context.dataStore.edit { it[KEY_IS_NOTIFICATION_GUIDE_DISMISSED] = dismissed }

    suspend fun setHasLaunchedBefore(launched: Boolean) =
        context.dataStore.edit { it[KEY_HAS_LAUNCHED_BEFORE] = launched }

    suspend fun setLastMidnightSift(timestamp: Long) =
        context.dataStore.edit { it[KEY_LAST_MIDNIGHT_SIFT] = timestamp }

    // ── 同步读取（首次启动检测，非响应式）────────────────────────────
    suspend fun getHasLaunchedBefore(): Boolean =
        context.dataStore.data.map { it[KEY_HAS_LAUNCHED_BEFORE] ?: false }.let {
            var result = false
            it.collect { v -> result = v; return@collect }
            result
        }

    suspend fun getHasSeededDefaultData(): Boolean =
        context.dataStore.data.map { it[KEY_HAS_SEEDED_DEFAULT_DATA] ?: false }.let {
            var result = false
            it.collect { v -> result = v; return@collect }
            result
        }

    suspend fun getCustomAiUrl(): String =
        context.dataStore.data.map { it[KEY_CUSTOM_AI_URL] ?: "" }.let {
            var result = ""
            it.collect { v -> result = v; return@collect }
            result
        }

    suspend fun getCustomAiKey(): String =
        context.dataStore.data.map { it[KEY_CUSTOM_AI_KEY] ?: "" }.let {
            var result = ""
            it.collect { v -> result = v; return@collect }
            result
        }

    suspend fun getCustomAiModel(): String =
        context.dataStore.data.map { it[KEY_CUSTOM_AI_MODEL] ?: "gpt-3.5-turbo" }.let {
            var result = "gpt-3.5-turbo"
            it.collect { v -> result = v; return@collect }
            result
        }
}
