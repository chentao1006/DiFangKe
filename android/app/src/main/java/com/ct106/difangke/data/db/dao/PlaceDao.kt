package com.ct106.difangke.data.db.dao

import androidx.room.*
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface PlaceDao {

    @Query("SELECT * FROM places ORDER BY name ASC")
    fun observeAll(): Flow<List<PlaceEntity>>

    @Query("SELECT * FROM places ORDER BY name ASC")
    suspend fun getAll(): List<PlaceEntity>

    @Query("SELECT * FROM places WHERE placeID = :id LIMIT 1")
    suspend fun getById(id: String): PlaceEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(place: PlaceEntity)

    @Update
    suspend fun update(place: PlaceEntity)

    @Delete
    suspend fun delete(place: PlaceEntity)

    @Query("DELETE FROM places WHERE placeID = :id")
    suspend fun deleteById(id: String)

    @Query("SELECT * FROM places WHERE isUserDefined = 1 AND isIgnored = 0 ORDER BY name ASC")
    suspend fun getUserDefined(): List<PlaceEntity>

    @Query("SELECT * FROM places WHERE isIgnored = 0 AND isUserDefined = 0 ORDER BY name ASC")
    suspend fun getSaved(): List<PlaceEntity>

    @Query("SELECT * FROM places WHERE isIgnored = 1 ORDER BY name ASC")
    suspend fun getIgnored(): List<PlaceEntity>
}

// ── ActivityType DAO ──

@Dao
interface ActivityTypeDao {

    @Query("SELECT * FROM activity_types ORDER BY sortOrder ASC")
    fun observeAll(): Flow<List<ActivityTypeEntity>>

    @Query("SELECT * FROM activity_types ORDER BY sortOrder ASC")
    suspend fun getAll(): List<ActivityTypeEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(type: ActivityTypeEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(types: List<ActivityTypeEntity>)

    @Update
    suspend fun update(type: ActivityTypeEntity)

    @Delete
    suspend fun delete(type: ActivityTypeEntity)

    @Query("SELECT COUNT(*) FROM activity_types")
    suspend fun count(): Int
}
