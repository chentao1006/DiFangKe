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

    @Query("SELECT * FROM footprints WHERE date(startTime/1000, 'unixepoch', 'localtime') = date(:dayMs/1000, 'unixepoch', 'localtime') AND statusValue != 'ignored' ORDER BY startTime ASC")
    suspend fun getForDay(dayMs: Long): List<FootprintEntity>

    @Query("SELECT * FROM footprints WHERE startTime >= :start AND startTime < :end AND statusValue != 'ignored' ORDER BY startTime ASC")
    suspend fun getBetween(start: Date, end: Date): List<FootprintEntity>

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
}
