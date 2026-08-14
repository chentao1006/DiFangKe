package com.ct106.difangke.service

import android.content.Context
import android.util.Log
import androidx.work.*
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.prefs.AppPreferences
import kotlinx.coroutines.flow.first
import java.util.*
import java.util.concurrent.TimeUnit

/**
 * 往年今日提醒 Worker
 * 每天上午 10 点触发，扫描往年同月同日的足迹。
 */
class PastMemoriesWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "PastMemoriesWorker"
        private const val WORK_NAME = "past_memories_notification"

        /**
         * 安排每日 10 点的通知任务
         */
        fun schedule(context: Context) {
            val now = Calendar.getInstance()
            val target = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 10)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            
            // 如果目标时间已过，推迟到明天
            if (target.before(now)) {
                target.add(Calendar.DAY_OF_YEAR, 1)
            }
            
            val initialDelay = target.timeInMillis - now.timeInMillis
            
            val request = PeriodicWorkRequestBuilder<PastMemoriesWorker>(
                24, TimeUnit.HOURS
            )
                .setInitialDelay(initialDelay, TimeUnit.MILLISECONDS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiresBatteryNotLow(true)
                        .build()
                )
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
            Log.i(TAG, "Scheduled past memories check at 10:00 AM (delay: ${initialDelay / 1000}s)")
        }

        /**
         * 取消任务
         */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            Log.i(TAG, "Cancelled past memories notifications")
        }
    }

    override suspend fun doWork(): Result {
        return try {
            val prefs = AppPreferences(context)
            val isEnabled = prefs.isPastMemoriesNotificationEnabled.first()
            if (!isEnabled) return Result.success()

            val db = DiFangKeApp.instance.database
            val now = Calendar.getInstance()
            val currentMonth = now.get(Calendar.MONTH)
            val currentDay = now.get(Calendar.DAY_OF_MONTH)
            val currentYear = now.get(Calendar.YEAR)

            // 获取所有足迹（排除今年，匹配月日）
            val allFootprints = db.footprintDao().getAll()
            val pastFootprints = allFootprints.filter { fp ->
                // Android keeps deleted footprints in the recycle bin. They
                // must not reappear as a "past memory" notification.
                if (fp.statusValue == "ignored") return@filter false
                val cal = Calendar.getInstance().apply { time = fp.startTime }
                val fpYear = cal.get(Calendar.YEAR)
                val fpMonth = cal.get(Calendar.MONTH)
                val fpDay = cal.get(Calendar.DAY_OF_MONTH)
                
                if (fp.placeID.isNullOrEmpty() || fp.activityTypeValue.isNullOrEmpty()) {
                    return@filter false
                }
                
                fpYear < currentYear && fpMonth == currentMonth && fpDay == currentDay
            }

            if (pastFootprints.isEmpty()) return Result.success()

            // 排除重要地点 (isPriority = true)
            val importantPlaceIDs = db.placeDao().getAll()
                .filter { it.isPriority }
                .map { it.placeID }
                .toSet()

            val filtered = pastFootprints.filter { fp ->
                fp.placeID == null || !importantPlaceIDs.contains(fp.placeID)
            }.sortedBy { it.startTime }

            if (filtered.isEmpty()) return Result.success()

            val highlight = filtered.first()
            val cal = Calendar.getInstance().apply { time = highlight.startTime }
            val fpYear = cal.get(Calendar.YEAR)
            val yearsAgo = currentYear - fpYear
            val placeName = (highlight.title ?: "").ifEmpty { highlight.address ?: "某个地方" }

            NotificationHelper.sendHighlightNotification(
                context,
                "往年今日 · ${yearsAgo}年前",
                "在 ${fpYear} 年的今天，你去了「$placeName」。点此重温那段时光。",
                highlight.startTime.time.hashCode(),
                highlight.startTime.time,
                null // 点开通知只要跳到那一天即可,不用打开足迹详情
            )

            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to check past memories", e)
            Result.failure()
        }
    }
}
