package com.ct106.difangke.service

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.FloorsClimbedRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.permission.HealthPermission
import java.time.Instant
import java.util.Date

/**
 * Reads only user-authorized Health Connect data.  It deliberately returns
 * null when Health Connect is unavailable or permission has not been granted,
 * so location recording never depends on a health provider being installed.
 */
class HealthConnectService private constructor(context: Context) {
    private val appContext = context.applicationContext

    data class Metrics(val steps: Int, val walkingDistanceMeters: Double, val floorsAscended: Int)

    companion object {
        private const val TAG = "HealthConnectService"
        @Volatile private var instance: HealthConnectService? = null

        fun getInstance(context: Context): HealthConnectService =
            instance ?: synchronized(this) {
                instance ?: HealthConnectService(context).also { instance = it }
            }

        val readPermissions = setOf(
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(DistanceRecord::class),
            HealthPermission.getReadPermission(FloorsClimbedRecord::class)
        )

        fun isAvailable(context: Context): Boolean =
            HealthConnectClient.getSdkStatus(context.applicationContext) == HealthConnectClient.SDK_AVAILABLE
    }

    suspend fun metricsBetween(start: Date, end: Date): Metrics? {
        if (end.time <= start.time) return null
        if (!isAvailable(appContext)) return null
        return runCatching {
            val client = HealthConnectClient.getOrCreate(appContext)
            if (!client.permissionController.getGrantedPermissions().containsAll(readPermissions)) return null
            val response = client.aggregate(
                AggregateRequest(
                    metrics = setOf(
                        StepsRecord.COUNT_TOTAL,
                        DistanceRecord.DISTANCE_TOTAL,
                        FloorsClimbedRecord.FLOORS_CLIMBED_TOTAL
                    ),
                    timeRangeFilter = TimeRangeFilter.between(
                        Instant.ofEpochMilli(start.time),
                        Instant.ofEpochMilli(end.time)
                    )
                )
            )
            Metrics(
                steps = (response[StepsRecord.COUNT_TOTAL] ?: 0L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                walkingDistanceMeters = response[DistanceRecord.DISTANCE_TOTAL]?.inMeters ?: 0.0,
                floorsAscended = (response[FloorsClimbedRecord.FLOORS_CLIMBED_TOTAL] ?: 0.0).toInt()
            )
        }.onFailure { android.util.Log.w(TAG, "Unable to read Health Connect metrics", it) }.getOrNull()
    }
}
