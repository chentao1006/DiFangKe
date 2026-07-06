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
import java.util.Date
import java.util.concurrent.TimeUnit

class FutureTripReminderWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "FutureTripReminder"
        private const val KEY_TRIP_ID = "trip_id"

        private fun workName(tripID: String) = "future_trip_reminder_$tripID"

        fun schedule(context: Context, tripID: String, arrivalDate: Date) {
            val delayMillis = arrivalDate.time - System.currentTimeMillis()
            if (delayMillis <= 0L) {
                cancel(context, tripID)
                return
            }

            val request = OneTimeWorkRequestBuilder<FutureTripReminderWorker>()
                .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
                .setInputData(workDataOf(KEY_TRIP_ID to tripID))
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                workName(tripID),
                ExistingWorkPolicy.REPLACE,
                request
            )
            Log.i(TAG, "Scheduled reminder for $tripID in ${delayMillis / 1000}s")
        }

        fun cancel(context: Context, tripID: String) {
            WorkManager.getInstance(context).cancelUniqueWork(workName(tripID))
        }
    }

    override suspend fun doWork(): Result {
        val tripID = inputData.getString(KEY_TRIP_ID) ?: return Result.success()
        return try {
            val trip = DiFangKeApp.instance.database.futureTripDao().getById(tripID)
                ?: return Result.success()
            if (trip.isCompleted || trip.isOrdered) return Result.success()

            NotificationHelper.sendFutureTripReminder(
                context = context,
                tripID = trip.tripID,
                title = "计划到达",
                body = trip.placeName
            )
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send future trip reminder", e)
            Result.failure()
        }
    }
}
