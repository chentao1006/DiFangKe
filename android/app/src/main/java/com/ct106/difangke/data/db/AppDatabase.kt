package com.ct106.difangke.data.db

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.ct106.difangke.data.db.dao.*
import com.ct106.difangke.data.db.entity.*
import java.util.Date

/**
 * Room 数据库（对应 iOS SwiftData ModelContainer）
 * 保持与 iOS 版功能等价
 */
@Database(
    entities = [
        FootprintEntity::class,
        PlaceEntity::class,
        ActivityTypeEntity::class,
        TransportRecordEntity::class,
        DailyInsightEntity::class,
        TransportManualSelectionEntity::class,
        FutureTripEntity::class
    ],
    version = 5,
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
    abstract fun futureTripDao(): FutureTripDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS `future_trips` (
                        `tripID` TEXT NOT NULL,
                        `placeID` TEXT,
                        `placeName` TEXT NOT NULL,
                        `address` TEXT,
                        `notes` TEXT,
                        `latitude` REAL NOT NULL,
                        `longitude` REAL NOT NULL,
                        `arrivalDate` INTEGER NOT NULL,
                        `hasArrivalTime` INTEGER NOT NULL,
                        `scheduleModeValue` TEXT NOT NULL,
                        `orderIndex` INTEGER NOT NULL,
                        `activityTypeValue` TEXT,
                        `createdAt` INTEGER NOT NULL,
                        `isCompleted` INTEGER NOT NULL,
                        `completedAt` INTEGER,
                        PRIMARY KEY(`tripID`)
                    )
                    """.trimIndent()
                )
            }
        }

        /**
         * 修复 footprints.title 列的 nullability 不匹配问题。
         * 旧数据库中 title 为 TEXT NOT NULL，而实体定义为 String?（可为 null）。
         * SQLite 不支持直接 ALTER COLUMN，因此采用"重建表"策略。
         */
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // 1. 将旧表重命名为临时表
                db.execSQL("ALTER TABLE `footprints` RENAME TO `footprints_old`")

                // 2. 以正确的 schema 创建新表（title TEXT，不带 NOT NULL）
                db.execSQL("""
                    CREATE TABLE `footprints` (
                        `footprintID` TEXT NOT NULL,
                        `date` INTEGER NOT NULL,
                        `startTime` INTEGER NOT NULL,
                        `endTime` INTEGER NOT NULL,
                        `latitudeJson` TEXT NOT NULL,
                        `longitudeJson` TEXT NOT NULL,
                        `locationHash` TEXT NOT NULL,
                        `title` TEXT,
                        `reason` TEXT,
                        `statusValue` TEXT NOT NULL,
                        `aiScore` REAL NOT NULL,
                        `placeID` TEXT,
                        `address` TEXT,
                        `isHighlight` INTEGER,
                        `isPlaceSuggestionIgnored` INTEGER NOT NULL,
                        `aiAnalyzed` INTEGER NOT NULL,
                        `isTitleEditedByHand` INTEGER NOT NULL,
                        `activityTypeValue` TEXT,
                        `photoAssetIDsJson` TEXT NOT NULL,
                        PRIMARY KEY(`footprintID`)
                    )
                """.trimIndent())

                // 3. 将旧数据复制到新表
                db.execSQL("""
                    INSERT INTO `footprints` (
                        `footprintID`, `date`, `startTime`, `endTime`,
                        `latitudeJson`, `longitudeJson`, `locationHash`,
                        `title`, `reason`, `statusValue`, `aiScore`,
                        `placeID`, `address`, `isHighlight`,
                        `isPlaceSuggestionIgnored`, `aiAnalyzed`,
                        `isTitleEditedByHand`, `activityTypeValue`,
                        `photoAssetIDsJson`
                    )
                    SELECT
                        `footprintID`, `date`, `startTime`, `endTime`,
                        `latitudeJson`, `longitudeJson`, `locationHash`,
                        `title`, `reason`, `statusValue`, `aiScore`,
                        `placeID`, `address`, `isHighlight`,
                        `isPlaceSuggestionIgnored`, `aiAnalyzed`,
                        `isTitleEditedByHand`, `activityTypeValue`,
                        `photoAssetIDsJson`
                    FROM `footprints_old`
                """.trimIndent())

                // 4. 删除旧表
                db.execSQL("DROP TABLE `footprints_old`")
            }
        }

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "dfk_v1_stable.db"
                )
                .addMigrations(MIGRATION_3_4, MIGRATION_4_5)
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
