package com.ct106.difangke.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

/**
 * Public entry point for refreshing the「今日足迹」home-screen widget.
 *
 * Call [requestUpdate] after anything that changes the timeline (new / edited / deleted
 * footprints or transports). Calls are debounced and are a no-op when no widget is placed.
 */
object FootprintWidgetUpdater {
    private const val PERIODIC_WORK_NAME = "footprint_widget_refresh"
    private const val DEBOUNCE_MS = 1_500L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile private var pending: Job? = null

    /** Debounced, fire-and-forget refresh of every placed widget. */
    @JvmStatic
    fun requestUpdate(context: Context) {
        val app = context.applicationContext
        synchronized(this) {
            pending?.cancel()
            pending = scope.launch {
                delay(DEBOUNCE_MS)
                runCatching { updateNow(app) }
            }
        }
    }

    /** Re-loads data for every placed widget immediately. */
    suspend fun updateNow(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        val ids = manager.getGlanceIds(FootprintWidget::class.java)
        if (ids.isEmpty()) return
        val widget = FootprintWidget()
        val now = System.currentTimeMillis()
        ids.forEach { id ->
            // Bumping the tick re-runs the data load even while a Glance session is alive.
            updateAppWidgetState(context, id) { it[FootprintWidget.KEY_REFRESH_TICK] = now }
            widget.update(context, id)
        }
    }

    /** Schedules the 15-minute periodic refresh (only meaningful when a widget exists). */
    fun schedulePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<FootprintWidgetRefreshWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            PERIODIC_WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
    }

    fun cancelPeriodic(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(PERIODIC_WORK_NAME)
    }

    /** Called from Application.onCreate: keep the periodic work only while widgets are placed. */
    fun ensureScheduled(context: Context) {
        val app = context.applicationContext
        scope.launch {
            runCatching {
                val ids = GlanceAppWidgetManager(app).getGlanceIds(FootprintWidget::class.java)
                if (ids.isNotEmpty()) schedulePeriodic(app) else cancelPeriodic(app)
            }
        }
    }
}

class FootprintWidgetRefreshWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        return try {
            FootprintWidgetUpdater.updateNow(applicationContext)
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}
