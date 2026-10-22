package com.ct106.difangke.data.db.dao

import androidx.room.*
import com.ct106.difangke.data.db.entity.*
import kotlinx.coroutines.flow.Flow
import java.util.Calendar
import java.util.Date
import java.util.UUID

@Dao
interface TripDao {
    @Query("SELECT * FROM trips ORDER BY plannedStartDay DESC")
    fun observeTrips(): Flow<List<TripEntity>>

    @Query("SELECT * FROM trips") suspend fun getTrips(): List<TripEntity>

    @Query("SELECT * FROM trip_days WHERE tripID = :tripID ORDER BY day, orderIndex")
    fun observeDays(tripID: String): Flow<List<TripDayEntity>>

    @Query("SELECT * FROM trip_days ORDER BY day, orderIndex")
    fun observeAllDays(): Flow<List<TripDayEntity>>
    @Query("SELECT * FROM trip_days") suspend fun getAllDays(): List<TripDayEntity>

    @Query("SELECT * FROM trip_day_cities WHERE tripDayID IN (:dayIDs) ORDER BY orderIndex")
    fun observeCities(dayIDs: List<String>): Flow<List<TripDayCityEntity>>

    @Query("SELECT * FROM trip_day_cities ORDER BY orderIndex")
    fun observeAllCities(): Flow<List<TripDayCityEntity>>
    @Query("SELECT * FROM trip_day_cities") suspend fun getAllCities(): List<TripDayCityEntity>

    @Query("SELECT * FROM trip_items ORDER BY startTime, orderIndex")
    fun observeAllItems(): Flow<List<TripItemEntity>>
    @Query("SELECT * FROM trip_items") suspend fun getAllItems(): List<TripItemEntity>

    @Query("SELECT * FROM home_city WHERE id = 'home' LIMIT 1")
    fun observeHomeCity(): Flow<HomeCityEntity?>
    @Query("SELECT * FROM home_city WHERE id = 'home' LIMIT 1") suspend fun getHomeCity(): HomeCityEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertTrip(trip: TripEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertDay(day: TripDayEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertCity(city: TripDayCityEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertItem(item: TripItemEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertHomeCity(city: HomeCityEntity)
    @Query("DELETE FROM home_city") suspend fun deleteHomeCity()

    @Query("SELECT * FROM trips WHERE originRaw = 'automatic' AND titleUserEdited = 0 AND datesUserEdited = 0 AND citiesUserEdited = 0")
    suspend fun getReplaceableAutomaticTrips(): List<TripEntity>
    @Query("UPDATE trips SET stateRaw = 'historical', kindRaw = 'historical' WHERE originRaw = 'automatic' AND stateRaw = 'draft'")
    suspend fun finalizeLegacyAutomaticDrafts()
    @Query("DELETE FROM trip_items WHERE tripDayID IN (SELECT id FROM trip_days WHERE tripID = :tripID)")
    suspend fun deleteItemsForTrip(tripID: String)
    @Query("DELETE FROM trip_day_cities WHERE tripDayID IN (SELECT id FROM trip_days WHERE tripID = :tripID)")
    suspend fun deleteCitiesForTrip(tripID: String)
    @Query("DELETE FROM trip_days WHERE tripID = :tripID") suspend fun deleteDaysForTrip(tripID: String)
    @Query("DELETE FROM trips WHERE id = :tripID") suspend fun deleteTrip(tripID: String)
    @Delete suspend fun deleteDay(day: TripDayEntity)
    @Delete suspend fun deleteCity(city: TripDayCityEntity)
    @Delete suspend fun deleteItem(item: TripItemEntity)

    @Transaction
    suspend fun deleteTrips(tripIDs: Set<String>) {
        tripIDs.forEach { tripID ->
            deleteItemsForTrip(tripID)
            deleteCitiesForTrip(tripID)
            deleteDaysForTrip(tripID)
            deleteTrip(tripID)
        }
    }

    @Transaction
    suspend fun mergeTrips(tripIDs: Set<String>) {
        val selected = getTrips().filter { it.id in tripIDs }.sortedBy { it.plannedStartDay }
        val target = selected.firstOrNull() ?: return
        if (selected.size < 2) return
        val sourceIDs = selected.drop(1).map { it.id }.toSet()
        val allDays = getAllDays().toMutableList()
        val allCities = getAllCities().toMutableList()
        val allItems = getAllItems().toMutableList()
        val targetDays = allDays.filter { it.tripID == target.id }.toMutableList()

        fun dayKey(date: Date): Long = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        fun cityKey(city: TripDayCityEntity) = "${city.countryCode}|${city.cityName}".lowercase()
        fun itemKey(item: TripItemEntity): String = when {
            item.sourceFootprintID != null -> "f:${item.sourceFootprintID}"
            item.sourceTransportRecordID != null -> "t:${item.sourceTransportRecordID}"
            else -> "${item.kindRaw}|${item.startTime?.time ?: 0}|${item.placeName.orEmpty()}|${item.lineName.orEmpty()}"
        }
        val cityKeysByDay = targetDays.associate { day ->
            day.id to allCities.filter { it.tripDayID == day.id }.map(::cityKey).toMutableSet()
        }.toMutableMap()
        val itemKeysByDay = targetDays.associate { day ->
            day.id to allItems.filter { it.tripDayID == day.id }.map(::itemKey).toMutableSet()
        }.toMutableMap()
        fun mergedText(first: String, second: String): String {
            val value = second.trim()
            return when {
                value.isEmpty() || first.contains(value) -> first
                first.isBlank() -> value
                else -> "$first\n\n$value"
            }
        }

        selected.drop(1).forEach { source ->
            allDays.filter { it.tripID == source.id }.forEach { sourceDay ->
                val existing = targetDays.firstOrNull { dayKey(it.day) == dayKey(sourceDay.day) }
                if (existing == null) {
                    val moved = sourceDay.copy(tripID = target.id)
                    upsertDay(moved)
                    targetDays += moved
                    cityKeysByDay[moved.id] = allCities.filter { it.tripDayID == moved.id }.map(::cityKey).toMutableSet()
                    itemKeysByDay[moved.id] = allItems.filter { it.tripDayID == moved.id }.map(::itemKey).toMutableSet()
                } else {
                    val updatedDay = existing.copy(notes = mergedText(existing.notes, sourceDay.notes))
                    upsertDay(updatedDay)
                    targetDays[targetDays.indexOf(existing)] = updatedDay
                    val cityKeys = cityKeysByDay.getOrPut(existing.id) { mutableSetOf() }
                    allCities.filter { it.tripDayID == sourceDay.id }.forEach { city ->
                        if (cityKeys.add(cityKey(city))) upsertCity(city.copy(tripDayID = existing.id))
                        else deleteCity(city)
                    }
                    val itemKeys = itemKeysByDay.getOrPut(existing.id) { mutableSetOf() }
                    allItems.filter { it.tripDayID == sourceDay.id }.forEach { item ->
                        if (itemKeys.add(itemKey(item))) upsertItem(item.copy(tripDayID = existing.id))
                        else deleteItem(item)
                    }
                    deleteDay(sourceDay)
                }
            }
            deleteTrip(source.id)
        }

        fun joined(values: List<String>, separator: String) = values.map(String::trim).filter(String::isNotEmpty).distinct().joinToString(separator)
        val start = selected.minOf { it.plannedStartDay }
        val end = selected.maxOf { it.plannedEndDay }
        val today = dayKey(Date())
        val state = when {
            end.time < today -> TripState.HISTORICAL
            start.time <= today -> TripState.ACTIVE
            else -> TripState.PLANNED
        }
        val cursor = Calendar.getInstance().apply { timeInMillis = dayKey(start) }
        val finalDay = dayKey(end)
        while (cursor.timeInMillis <= finalDay) {
            val cursorTime = cursor.timeInMillis
            if (targetDays.none { dayKey(it.day) == cursorTime }) {
                val day = TripDayEntity(tripID = target.id, day = Date(cursorTime), orderIndex = targetDays.size)
                upsertDay(day)
                targetDays += day
            }
            cursor.add(Calendar.DAY_OF_YEAR, 1)
        }
        upsertTrip(target.copy(
            title = joined(selected.map { it.title }, " · "),
            notes = joined(selected.map { it.notes }, "\n\n"),
            activityTypeValue = selected.mapNotNull { it.activityTypeValue }.firstOrNull(),
            kindRaw = if (state == TripState.PLANNED) TripKind.PLANNED.raw else TripKind.HISTORICAL.raw,
            stateRaw = state.raw,
            originRaw = if (selected.any { it.originRaw == "manual" }) "manual" else "automatic",
            plannedStartDay = start,
            plannedEndDay = end,
            actualStartedAt = selected.mapNotNull { it.actualStartedAt }.minOrNull() ?: if (state == TripState.ACTIVE) start else null,
            actualEndedAt = selected.mapNotNull { it.actualEndedAt }.maxOrNull(),
            titleUserEdited = selected.any { it.titleUserEdited },
            datesUserEdited = true,
            citiesUserEdited = selected.any { it.citiesUserEdited },
            updatedAt = Date()
        ))
        targetDays.sortedBy { it.day }.forEachIndexed { index, day -> upsertDay(day.copy(orderIndex = index)) }
        val mergedCities = getAllCities()
        val mergedItems = getAllItems()
        targetDays.forEach { day ->
            mergedCities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                .forEachIndexed { index, city -> upsertCity(city.copy(orderIndex = index)) }
            mergedItems.filter { it.tripDayID == day.id }
                .sortedWith(compareBy<TripItemEntity> { it.startTime }.thenBy { it.orderIndex })
                .forEachIndexed { index, item -> upsertItem(item.copy(orderIndex = index)) }
        }
        sourceIDs.forEach { sourceID ->
            deleteItemsForTrip(sourceID)
            deleteCitiesForTrip(sourceID)
            deleteDaysForTrip(sourceID)
        }
    }

    @Transaction
    suspend fun splitTrip(tripID: String, secondStartDay: Date) {
        fun dayTime(date: Date): Long = Calendar.getInstance().apply {
            time = date
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val trip = getTrips().firstOrNull { it.id == tripID } ?: return
        val splitTime = dayTime(secondStartDay)
        val days = getAllDays().filter { it.tripID == tripID }.sortedBy { it.day }
        val firstDays = days.filter { dayTime(it.day) < splitTime }
        val secondDays = days.filter { dayTime(it.day) >= splitTime }
        if (firstDays.isEmpty() || secondDays.isEmpty()) return

        val allCities = getAllCities()
        val allItems = getAllItems()
        val newTripID = UUID.randomUUID().toString()
        fun segmentTitle(segmentDays: List<TripDayEntity>): String {
            if (trip.titleUserEdited) return trip.title
            return segmentDays.sortedBy { it.day }.flatMap { day ->
                allCities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
            }.map { it.cityName.trim() }.filter { it.isNotEmpty() }.distinct()
                .joinToString("、").ifEmpty { trip.title }
        }
        fun segmentItems(segmentDays: List<TripDayEntity>): List<TripItemEntity> {
            val dayIDs = segmentDays.map { it.id }.toSet()
            return allItems.filter { it.tripDayID in dayIDs }
        }
        fun derivedState(start: Date, end: Date): TripState {
            val today = dayTime(Date())
            return when {
                dayTime(end) < today -> TripState.HISTORICAL
                dayTime(start) <= today -> TripState.ACTIVE
                else -> TripState.PLANNED
            }
        }

        val firstEnd = Calendar.getInstance().apply {
            timeInMillis = splitTime
            add(Calendar.DAY_OF_YEAR, -1)
        }.time
        val firstItems = segmentItems(firstDays)
        val secondItems = segmentItems(secondDays)
        val firstState = derivedState(trip.plannedStartDay, firstEnd)
        val secondState = derivedState(Date(splitTime), trip.plannedEndDay)

        upsertTrip(trip.copy(
            title = segmentTitle(firstDays),
            originRaw = "manual",
            plannedEndDay = firstEnd,
            actualEndedAt = firstItems.mapNotNull { it.endTime ?: it.startTime }.maxOrNull()
                ?: trip.actualEndedAt?.takeIf { it.time < splitTime },
            endReasonRaw = null,
            kindRaw = if (firstState == TripState.PLANNED) TripKind.PLANNED.raw else TripKind.HISTORICAL.raw,
            stateRaw = firstState.raw,
            datesUserEdited = true,
            updatedAt = Date()
        ))
        upsertTrip(trip.copy(
            id = newTripID,
            title = segmentTitle(secondDays),
            originRaw = "manual",
            plannedStartDay = Date(splitTime),
            actualStartedAt = secondItems.mapNotNull { it.startTime }.minOrNull()
                ?: trip.actualStartedAt?.takeIf { it.time >= splitTime },
            kindRaw = if (secondState == TripState.PLANNED) TripKind.PLANNED.raw else TripKind.HISTORICAL.raw,
            stateRaw = secondState.raw,
            datesUserEdited = true,
            createdAt = Date(),
            updatedAt = Date()
        ))
        firstDays.forEachIndexed { index, day -> upsertDay(day.copy(orderIndex = index)) }
        secondDays.forEachIndexed { index, day -> upsertDay(day.copy(tripID = newTripID, orderIndex = index)) }
    }

    @Transaction
    suspend fun deleteReplaceableAutomaticTrips() {
        getReplaceableAutomaticTrips().forEach { trip ->
            deleteItemsForTrip(trip.id)
            deleteCitiesForTrip(trip.id)
            deleteDaysForTrip(trip.id)
            deleteTrip(trip.id)
        }
    }
}
