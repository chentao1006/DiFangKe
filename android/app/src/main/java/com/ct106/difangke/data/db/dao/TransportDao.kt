package com.ct106.difangke.data.db.dao

import androidx.room.*
import com.ct106.difangke.data.db.entity.DailyInsightEntity
import com.ct106.difangke.data.db.entity.TransportManualSelectionEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface TransportRecordDao {

    @Query("SELECT * FROM transport_records WHERE startTime < :end AND endTime > :start AND statusRaw = 'active' ORDER BY startTime ASC")
    suspend fun getForDay(start: Date, end: Date): List<TransportRecordEntity>

    @Query("SELECT * FROM transport_records WHERE startTime < :end AND endTime > :start AND statusRaw = 'active' ORDER BY startTime ASC")
    fun observeForDay(start: Date, end: Date): Flow<List<TransportRecordEntity>>

    @Query("SELECT * FROM transport_records ORDER BY startTime DESC")
    fun observeAll(): Flow<List<TransportRecordEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(record: TransportRecordEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(records: List<TransportRecordEntity>)

    @Update
    suspend fun update(record: TransportRecordEntity)

    @Delete
    suspend fun delete(record: TransportRecordEntity)

    @Query("DELETE FROM transport_records WHERE startTime >= :start AND startTime < :end")
    suspend fun deleteForDay(start: Date, end: Date)

    @Query("DELETE FROM transport_records WHERE startTime >= :start AND startTime < :end AND manualTypeRaw IS NULL")
    suspend fun deleteAutoForDay(start: Date, end: Date)

    @Query("SELECT * FROM transport_records WHERE recordID = :id LIMIT 1")
    suspend fun getById(id: String): TransportRecordEntity?

    @Query("SELECT * FROM transport_records WHERE statusRaw = 'active' AND endTime > :start AND startTime < :end ORDER BY startTime ASC")
    suspend fun getActiveBetween(start: Date, end: Date): List<TransportRecordEntity>

    @Query("SELECT * FROM transport_records WHERE statusRaw = 'active' AND startTime < :date AND endTime >= :lower AND endTime <= :upper ORDER BY endTime DESC LIMIT 1")
    suspend fun getAdjacentEndingAt(date: Date, lower: Date, upper: Date): TransportRecordEntity?

    @Query("SELECT * FROM transport_records WHERE statusRaw = 'active' AND endTime > :date AND startTime >= :lower AND startTime <= :upper ORDER BY startTime ASC LIMIT 1")
    suspend fun getAdjacentStartingAt(date: Date, lower: Date, upper: Date): TransportRecordEntity?

    @Query("SELECT * FROM transport_records ORDER BY startTime DESC")
    suspend fun getAllSync(): List<TransportRecordEntity>

    @Query("SELECT * FROM transport_records WHERE day != :excludingDate AND statusRaw = 'active' ORDER BY startTime DESC LIMIT :limit")
    suspend fun getRecentExcluding(excludingDate: Date, limit: Int): List<TransportRecordEntity>

    @Query("UPDATE transport_records SET statusRaw = 'ignored' WHERE recordID = :id")
    suspend fun ignoreById(id: String)
}

@Dao
interface DailyInsightDao {

    @Query("SELECT * FROM daily_insights ORDER BY date DESC")
    fun observeAll(): Flow<List<DailyInsightEntity>>

    @Query("SELECT * FROM daily_insights WHERE date >= :start AND date < :end LIMIT 1")
    suspend fun getForDay(start: Date, end: Date): DailyInsightEntity?

    @Query("SELECT * FROM daily_insights WHERE date >= :start AND date < :end LIMIT 1")
    fun observeForDay(start: Date, end: Date): Flow<DailyInsightEntity?>

    @Query("SELECT * FROM daily_insights")
    suspend fun getAll(): List<DailyInsightEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(insight: DailyInsightEntity)

    @Update
    suspend fun update(insight: DailyInsightEntity)

    @Query("DELETE FROM daily_insights")
    suspend fun deleteAll()
}

@Dao
interface TransportManualSelectionDao {

    @Query("SELECT * FROM transport_manual_selections WHERE isDeleted = 0 ORDER BY startTime ASC")
    fun observeAll(): Flow<List<TransportManualSelectionEntity>>

    @Query("SELECT * FROM transport_manual_selections WHERE isDeleted = 1 AND startTime < :end AND endTime > :start ORDER BY startTime ASC")
    suspend fun getDeletedBetween(start: Date, end: Date): List<TransportManualSelectionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(selection: TransportManualSelectionEntity)

    @Update
    suspend fun update(selection: TransportManualSelectionEntity)
}
