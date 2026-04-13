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
 * 每日足迹汇总通知 Worker
 * 在用户设定的时间触发，获取当天足迹统计并发送通知。
 */
class DailySummaryWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "DailySummaryWorker"
        private const val WORK_NAME = "daily_summary_notification"

        /**
         * 根据用户设置的时间，安排每日通知任务
         */
        fun schedule(context: Context, hour: Int, minute: Int) {
            val now = Calendar.getInstance()
            val target = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            
            // 如果目标时间已过，推迟到明天
            if (target.before(now)) {
                target.add(Calendar.DAY_OF_YEAR, 1)
            }
            
            val initialDelay = target.timeInMillis - now.timeInMillis
            
            val request = PeriodicWorkRequestBuilder<DailySummaryWorker>(
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
            Log.i(TAG, "Scheduled daily summary at $hour:$minute (delay: ${initialDelay / 1000}s)")
        }

        /**
         * 取消每日通知任务
         */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            Log.i(TAG, "Cancelled daily summary notifications")
        }
    }

    override suspend fun doWork(): Result {
        return try {
            val prefs = AppPreferences(context)
            val isEnabled = prefs.isDailyNotificationEnabled.first()
            if (!isEnabled) return Result.success()

            val db = DiFangKeApp.instance.database
            val calendar = Calendar.getInstance()
            val todayStart = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }.time
            val todayEnd = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 23)
                set(Calendar.MINUTE, 59)
                set(Calendar.SECOND, 59)
            }.time

            val todayFootprints = db.footprintDao().getAll()
                .filter { it.statusValue != "ignored" }
                .filter { it.startTime >= todayStart && it.startTime <= todayEnd }

            if (todayFootprints.isEmpty()) {
                NotificationHelper.sendDailySummary(
                    context,
                    "今日足迹",
                    "今天还没有记录到足迹，明天继续探索吧 🌟"
                )
                return Result.success()
            }

            val footprintCount = todayFootprints.size
            val totalDurationMin = todayFootprints.sumOf { 
                (it.endTime.time - it.startTime.time) 
            } / 60000

            val isAiEnabled = prefs.isAiEnabled.first()
            
            if (isAiEnabled) {
                // 尝试用 AI 生成摘要
                val prompt = """
                    请用一句话（30字以内）总结用户今日的生活：今天去了${footprintCount}个地方，总共停留了${totalDurationMin}分钟。
                    要求：温暖、有洞察力、不要太文艺。直接给出总结，不要前缀。
                """.trimIndent()
                val aiSummary = OpenAIService.shared.getCustomSummary(prompt)
                NotificationHelper.sendDailySummary(
                    context,
                    "今日足迹 · $footprintCount 个瞬间",
                    aiSummary ?: "今天造访了 $footprintCount 个地方，累计停留 ${totalDurationMin} 分钟 ✨"
                )
            } else {
                NotificationHelper.sendDailySummary(
                    context,
                    "今日足迹 · $footprintCount 个瞬间",
                    "今天造访了 $footprintCount 个地方，累计停留 ${totalDurationMin} 分钟 ✨"
                )
            }

            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to generate daily summary", e)
            Result.failure()
        }
    }
}
