package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.Calendar
import java.util.Date
import java.util.UUID

@Entity(tableName = "future_trips")
data class FutureTripEntity(
    @PrimaryKey
    val tripID: String = UUID.randomUUID().toString(),
    val placeID: String? = null,
    val placeName: String = "",
    val address: String? = null,
    val notes: String? = null,
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val arrivalDate: Date = Date(),
    val hasArrivalTime: Boolean = false,
    val scheduleModeValue: String = FutureTripScheduleMode.TIMED.raw,
    val orderIndex: Int = 0,
    val activityTypeValue: String? = null,
    val createdAt: Date = Date(),
    val isCompleted: Boolean = false,
    val completedAt: Date? = null
) {
    val scheduleMode: FutureTripScheduleMode
        get() = FutureTripScheduleMode.from(scheduleModeValue)

    val isOrdered: Boolean
        get() = scheduleMode == FutureTripScheduleMode.ORDERED

    fun effectiveArrivalDate(): Date {
        if (hasArrivalTime) return arrivalDate
        return Calendar.getInstance().apply {
            time = arrivalDate
            set(Calendar.HOUR_OF_DAY, 23)
            set(Calendar.MINUTE, 59)
            set(Calendar.SECOND, 59)
            set(Calendar.MILLISECOND, 999)
        }.time
    }

    companion object {
        fun dayOrdered(trips: List<FutureTripEntity>): List<FutureTripEntity> {
            val hasExplicitOrder = trips.any { it.orderIndex > 0 }
            return trips.sortedWith(
                compareBy<FutureTripEntity> {
                    if (hasExplicitOrder) {
                        if (it.orderIndex > 0) it.orderIndex else Int.MAX_VALUE
                    } else {
                        0
                    }
                }.thenBy { it.arrivalDate }
                    .thenBy { it.createdAt }
            )
        }
    }
}

enum class FutureTripScheduleMode(val raw: String) {
    TIMED("timed"),
    ORDERED("ordered");

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: TIMED
    }
}
