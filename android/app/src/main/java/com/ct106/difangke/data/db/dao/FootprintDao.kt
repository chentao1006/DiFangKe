package com.ct106.difangke.data.db.dao

import androidx.room.*
import com.ct106.difangke.data.db.entity.FootprintEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date

@Dao
interface FootprintDao {

    @Query("SELECT * FROM footprints WHERE statusValue != 'ignored' ORDER BY startTime DESC")
    fun observeAll(): Flow<List<FootprintEntity>>

    @Query("SELECT * FROM footprints WHERE statusValue != 'ignored' ORDER BY startTime DESC")
    suspend fun getAll(): List<FootprintEntity>

    @Query("SELECT * FROM footprints WHERE startTime < :end AND endTime > :start AND statusValue != 'ignored' ORDER BY startTime ASC")
    suspend fun getForDay(start: Date, end: Date): List<FootprintEntity>

    @Query("SELECT * FROM footprints WHERE startTime < :end AND endTime > :start AND statusValue != 'ignored' ORDER BY startTime ASC")
    suspend fun getBetween(start: Date, end: Date): List<FootprintEntity>

    @Query("SELECT * FROM footprints WHERE startTime < :end AND endTime > :start AND statusValue != 'ignored' ORDER BY startTime ASC")
    fun observeBetween(start: Date, end: Date): Flow<List<FootprintEntity>>

    @Query("SELECT * FROM footprints WHERE footprintID = :id LIMIT 1")
    suspend fun getById(id: String): FootprintEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(footprint: FootprintEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(footprints: List<FootprintEntity>)

    @Update
    suspend fun update(footprint: FootprintEntity)

    @Delete
    suspend fun delete(footprint: FootprintEntity)

    @Query("DELETE FROM footprints WHERE footprintID = :id")
    suspend fun deleteById(id: String)

    @Query("SELECT COUNT(*) FROM footprints WHERE statusValue != 'ignored'")
    suspend fun count(): Int

    @Query("SELECT * FROM footprints WHERE startTime >= :start AND startTime < :end AND statusValue = 'ignored' ORDER BY startTime ASC")
    suspend fun getIgnoredBetween(start: Date, end: Date): List<FootprintEntity>

    /** 查找与候选足迹位置/时间相近的已有足迹（用于合并判断） */
    @Query("""
        SELECT * FROM footprints 
        WHERE endTime >= :afterTime 
        AND statusValue != 'ignored'
        ORDER BY endTime DESC 
        LIMIT 1
    """)
    suspend fun getLastFootprintAfter(afterTime: Date): FootprintEntity?
    @Query("SELECT DISTINCT date(startTime/1000, 'unixepoch', 'localtime') FROM footprints WHERE statusValue != 'ignored' ORDER BY startTime ASC")
    fun observeAvailableDates(): Flow<List<String>>

    @Query("SELECT * FROM footprints WHERE placeID = :placeID AND startTime < :currentTime AND statusValue != 'ignored' ORDER BY startTime DESC LIMIT 1")
    suspend fun getLastVisitToPlace(placeID: String, currentTime: Date): FootprintEntity?

    @Query("SELECT * FROM footprints WHERE locationHash = :hash AND startTime < :currentTime AND statusValue != 'ignored' ORDER BY startTime DESC LIMIT 1")
    suspend fun getLastVisitToHash(hash: String, currentTime: Date): FootprintEntity?

    @Query("DELETE FROM footprints")
    suspend fun deleteAll()

    @Query("DELETE FROM footprints WHERE startTime >= :start AND startTime < :end")
    suspend fun deleteBetween(start: Date, end: Date)

    @Query("DELETE FROM footprints WHERE startTime >= :start AND startTime < :end AND statusValue = 'candidate' AND isTitleEditedByHand = 0")
    suspend fun deleteCandidatesBetween(start: Date, end: Date)

    @Query("""
        DELETE FROM footprints 
        WHERE startTime = :start 
        AND endTime > :start 
        AND statusValue = 'candidate'
        AND IFNULL(latitudeJson, '') NOT LIKE '%,%'
        AND IFNULL(longitudeJson, '') NOT LIKE '%,%'
    """)
    suspend fun deleteStartBoundaryCandidates(start: Date)
}
