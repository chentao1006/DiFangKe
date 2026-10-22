package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.Date
import java.util.TimeZone
import java.util.UUID

enum class TripKind(val raw: String) { HISTORICAL("historical"), PLANNED("planned") }
enum class TripState(val raw: String) { DRAFT("draft"), PLANNED("planned"), ACTIVE("active"), HISTORICAL("historical"), CANCELLED("cancelled") }

@Entity(tableName = "trips")
data class TripEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val title: String,
    val notes: String = "",
    val activityTypeValue: String? = null,
    val kindRaw: String = TripKind.HISTORICAL.raw,
    val stateRaw: String = TripState.HISTORICAL.raw,
    val originRaw: String = "manual",
    val plannedStartDay: Date,
    val plannedEndDay: Date,
    val actualStartedAt: Date? = null,
    val actualEndedAt: Date? = null,
    val endReasonRaw: String? = null,
    val homeCityKeyAtCreation: String? = null,
    val titleUserEdited: Boolean = false,
    val datesUserEdited: Boolean = false,
    val citiesUserEdited: Boolean = false,
    val coverTypeRaw: String = "mapSnapshot",
    val coverPhotoIdentifier: String? = null,
    val createdAt: Date = Date(),
    val updatedAt: Date = Date()
) {
    val state: TripState get() = TripState.entries.firstOrNull { it.raw == stateRaw } ?: TripState.HISTORICAL
}

@Entity(tableName = "trip_days")
data class TripDayEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val tripID: String,
    val day: Date,
    val timeZoneIdentifier: String = TimeZone.getDefault().id,
    val orderIndex: Int = 0,
    val notes: String = ""
)

@Entity(tableName = "trip_day_cities")
data class TripDayCityEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val tripDayID: String,
    val countryCode: String = "",
    val countryName: String = "",
    val cityName: String,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val timeZoneIdentifier: String? = null,
    val orderIndex: Int = 0,
    val notes: String = "",
    val isUserEdited: Boolean = true
)

@Entity(tableName = "trip_items")
data class TripItemEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val tripDayID: String,
    val kindRaw: String,
    val orderIndex: Int = 0,
    val stopScopeRaw: String? = null,
    val countryCode: String? = null,
    val countryName: String? = null,
    val cityName: String? = null,
    val placeID: String? = null,
    val placeName: String? = null,
    val address: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val startTime: Date? = null,
    val endTime: Date? = null,
    val activityTypeValue: String? = null,
    val transportTypeRaw: String? = null,
    val lineName: String? = null,
    val startLocationName: String? = null,
    val endLocationName: String? = null,
    val notes: String = "",
    val sourceFootprintID: String? = null,
    val sourceTransportRecordID: String? = null,
    val planStatusRaw: String = "planned"
)

@Entity(tableName = "home_city")
data class HomeCityEntity(
    @PrimaryKey val id: String = "home",
    val countryCode: String = "",
    val countryName: String = "",
    val cityName: String,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val timeZoneIdentifier: String? = null,
    val updatedAt: Date = Date()
)
