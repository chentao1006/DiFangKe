package com.ct106.difangke.data.db

import android.content.Context
import androidx.room.*
import com.ct106.difangke.data.db.dao.*
import com.ct106.difangke.data.db.entity.*
import java.util.Date

/**
 * Room 数据库（对应 iOS SwiftData ModelContainer）
 * 包含 6 个实体，保持与 iOS 版功能等价
 */
@Database(
    entities = [
        FootprintEntity::class,
        PlaceEntity::class,
        ActivityTypeEntity::class,
        TransportRecordEntity::class,
        DailyInsightEntity::class,
        TransportManualSelectionEntity::class
    ],
    version = 3,
    exportSchema = false
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {

    abstract fun footprintDao(): FootprintDao
    abstract fun placeDao(): PlaceDao
    abstract fun activityTypeDao(): ActivityTypeDao
    abstract fun transportRecordDao(): TransportRecordDao
    abstract fun dailyInsightDao(): DailyInsightDao
    abstract fun transportManualSelectionDao(): TransportManualSelectionDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "dfk_v1_stable.db"
                )
                .fallbackToDestructiveMigration()
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}

/** Room TypeConverters：处理 Date 类型 */
class Converters {
    @TypeConverter
    fun fromTimestamp(value: Long?): Date? = value?.let { Date(it) }

    @TypeConverter
    fun toTimestamp(date: Date?): Long? = date?.time
}
