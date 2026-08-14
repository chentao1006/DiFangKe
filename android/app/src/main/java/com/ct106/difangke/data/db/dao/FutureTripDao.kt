package com.ct106.difangke.data.db.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.ct106.difangke.data.db.entity.FutureTripEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface FutureTripDao {
    @Query("SELECT * FROM future_trips ORDER BY arrivalDate ASC, orderIndex ASC, createdAt ASC")
    fun observeAll(): Flow<List<FutureTripEntity>>

    @Query("SELECT * FROM future_trips ORDER BY arrivalDate ASC, orderIndex ASC, createdAt ASC")
    suspend fun getAll(): List<FutureTripEntity>

    @Query("SELECT * FROM future_trips WHERE hasPlanDate = 1 AND arrivalDate >= :start AND arrivalDate < :end ORDER BY orderIndex ASC, arrivalDate ASC, createdAt ASC")
    fun observeForDay(start: Date, end: Date): Flow<List<FutureTripEntity>>

    @Query("SELECT * FROM future_trips WHERE hasPlanDate = 1 AND arrivalDate >= :start AND arrivalDate < :end ORDER BY orderIndex ASC, arrivalDate ASC, createdAt ASC")
    suspend fun getForDay(start: Date, end: Date): List<FutureTripEntity>

    @Query("SELECT * FROM future_trips WHERE tripID = :id LIMIT 1")
    suspend fun getById(id: String): FutureTripEntity?

    @Query("SELECT DISTINCT date(arrivalDate/1000, 'unixepoch', 'localtime') FROM future_trips WHERE hasPlanDate = 1 ORDER BY arrivalDate ASC")
    fun observeAvailableDates(): Flow<List<String>>

    @Query("SELECT * FROM future_trips WHERE hasPlanDate = 0 ORDER BY orderIndex ASC, createdAt ASC")
    fun observeUndated(): Flow<List<FutureTripEntity>>

    @Query("SELECT * FROM future_trips WHERE hasPlanDate = 0 ORDER BY orderIndex ASC, createdAt ASC")
    suspend fun getUndated(): List<FutureTripEntity>

    @Query("SELECT * FROM future_trips WHERE isCompleted = 0 AND (hasPlanDate = 0 OR (arrivalDate >= :dayStart AND arrivalDate < :dayEnd))")
    suspend fun getAutoCompletableForDay(dayStart: Date, dayEnd: Date): List<FutureTripEntity>

    @Query("SELECT * FROM future_trips WHERE hasPlanDate = 1 AND arrivalDate >= :start AND arrivalDate < :end ORDER BY arrivalDate ASC, orderIndex ASC, createdAt ASC")
    suspend fun getForRange(start: Date, end: Date): List<FutureTripEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(trip: FutureTripEntity)

    @Update
    suspend fun update(trip: FutureTripEntity)

    @Delete
    suspend fun delete(trip: FutureTripEntity)

    @Query("DELETE FROM future_trips")
    suspend fun deleteAll()
}
