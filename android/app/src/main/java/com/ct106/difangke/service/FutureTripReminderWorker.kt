package com.ct106.difangke.service

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.ct106.difangke.DiFangKeApp
import kotlinx.coroutines.flow.first
import java.util.Date
import java.util.concurrent.TimeUnit

class FutureTripReminderWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "FutureTripReminder"
        private const val KEY_TRIP_ID = "trip_id"
        private const val KEY_KIND = "kind"

        private fun workName(tripID: String, kind: String) = "future_trip_reminder_${tripID}_$kind"

        fun schedule(context: Context, tripID: String, arrivalDate: Date, hasArrivalTime: Boolean) {
            cancel(context, tripID)
            val calendar = java.util.Calendar.getInstance()
            val candidates = if (hasArrivalTime) {
                listOf("pre" to Date(arrivalDate.time - TimeUnit.HOURS.toMillis(1)), "at" to arrivalDate)
            } else {
                calendar.time = arrivalDate
                val midnight = (calendar.clone() as java.util.Calendar).apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
                }.time
                val nineAM = (calendar.clone() as java.util.Calendar).apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 9); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
                }.time
                listOf("day_start" to midnight, "morning" to nineAM)
            }
            candidates.filter { (_, date) -> date.after(Date()) }.forEach { (kind, date) ->
                enqueue(context, tripID, kind, date)
            }
        }

        private fun enqueue(context: Context, tripID: String, kind: String, notificationDate: Date) {
            val delayMillis = notificationDate.time - System.currentTimeMillis()
            if (delayMillis <= 0L) {
                return
            }

            val request = OneTimeWorkRequestBuilder<FutureTripReminderWorker>()
                .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
                .setInputData(workDataOf(KEY_TRIP_ID to tripID, KEY_KIND to kind))
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                workName(tripID, kind),
                ExistingWorkPolicy.REPLACE,
                request
            )
            Log.i(TAG, "Scheduled $kind reminder for $tripID in ${delayMillis / 1000}s")
        }

        fun cancel(context: Context, tripID: String) {
            listOf("pre", "at", "day_start", "morning").forEach { kind ->
                WorkManager.getInstance(context).cancelUniqueWork(workName(tripID, kind))
            }
        }

        suspend fun rescheduleAll(context: Context) {
            val app = DiFangKeApp.instance
            val enabled = app.preferences.isFutureTripNotificationEnabled.first()
            app.database.futureTripDao().getAll().forEach { trip ->
                cancel(context, trip.tripID)
                if (enabled && !trip.isCompleted && trip.hasPlanDate) {
                    schedule(context, trip.tripID, trip.arrivalDate, trip.hasArrivalTime)
                }
            }
        }
    }

    override suspend fun doWork(): Result {
        val tripID = inputData.getString(KEY_TRIP_ID) ?: return Result.success()
        val kind = inputData.getString(KEY_KIND) ?: return Result.success()
        return try {
            val trip = DiFangKeApp.instance.database.futureTripDao().getById(tripID)
                ?: return Result.success()
            if (trip.isCompleted || !trip.hasPlanDate) return Result.success()

            val body = when (kind) {
                "at" -> "您计划的时间已到，地点：${trip.placeName}。"
                "pre" -> "您计划在 ${java.text.SimpleDateFormat("HH:mm", java.util.Locale.CHINA).format(trip.arrivalDate)} 到达 ${trip.placeName}，还有 1 小时。"
                else -> "您计划在今天到达 ${trip.placeName}。"
            }

            NotificationHelper.sendFutureTripReminder(
                context = context,
                tripID = trip.tripID,
                title = "行程提醒",
                body = body
            )
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send future trip reminder", e)
            Result.failure()
        }
    }
}
