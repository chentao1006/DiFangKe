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
        // Retired future-trip feature: table kept only for schema compatibility.
        FutureTripEntity::class,
        TripEntity::class,
        TripDayEntity::class,
        TripDayCityEntity::class,
        TripItemEntity::class,
        HomeCityEntity::class
    ],
    version = 12,
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
    /** Retained only for schema compatibility (future trips were removed). */
    abstract fun futureTripDao(): FutureTripDao
    abstract fun tripDao(): TripDao

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

        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `future_trips` ADD COLUMN `hasPlanDate` INTEGER NOT NULL DEFAULT 1")
            }
        }

        private val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `stepCount` INTEGER")
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `walkingDistance` REAL")
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `floorsAscended` INTEGER")
            }
        }

        private val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `countryCode` TEXT")
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `countryName` TEXT")
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `cityName` TEXT")
            }
        }

        /** iOS parity fields for manual-boundary semantics. */
        val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `allowsAutomaticDurationExtension` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `footprints` ADD COLUMN `isAddressEditedByHand` INTEGER NOT NULL DEFAULT 0")
            }
        }

        val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""CREATE TABLE IF NOT EXISTS `trips` (`id` TEXT NOT NULL, `title` TEXT NOT NULL, `notes` TEXT NOT NULL, `kindRaw` TEXT NOT NULL, `stateRaw` TEXT NOT NULL, `originRaw` TEXT NOT NULL, `plannedStartDay` INTEGER NOT NULL, `plannedEndDay` INTEGER NOT NULL, `actualStartedAt` INTEGER, `actualEndedAt` INTEGER, `endReasonRaw` TEXT, `homeCityKeyAtCreation` TEXT, `titleUserEdited` INTEGER NOT NULL, `datesUserEdited` INTEGER NOT NULL, `citiesUserEdited` INTEGER NOT NULL, `coverTypeRaw` TEXT NOT NULL, `coverPhotoIdentifier` TEXT, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`id`))""")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `trip_days` (`id` TEXT NOT NULL, `tripID` TEXT NOT NULL, `day` INTEGER NOT NULL, `timeZoneIdentifier` TEXT NOT NULL, `orderIndex` INTEGER NOT NULL, `notes` TEXT NOT NULL, PRIMARY KEY(`id`))""")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `trip_day_cities` (`id` TEXT NOT NULL, `tripDayID` TEXT NOT NULL, `countryCode` TEXT NOT NULL, `countryName` TEXT NOT NULL, `cityName` TEXT NOT NULL, `latitude` REAL, `longitude` REAL, `timeZoneIdentifier` TEXT, `orderIndex` INTEGER NOT NULL, `notes` TEXT NOT NULL, `isUserEdited` INTEGER NOT NULL, PRIMARY KEY(`id`))""")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `trip_items` (`id` TEXT NOT NULL, `tripDayID` TEXT NOT NULL, `kindRaw` TEXT NOT NULL, `orderIndex` INTEGER NOT NULL, `stopScopeRaw` TEXT, `countryCode` TEXT, `countryName` TEXT, `cityName` TEXT, `placeID` TEXT, `placeName` TEXT, `address` TEXT, `latitude` REAL, `longitude` REAL, `startTime` INTEGER, `endTime` INTEGER, `activityTypeValue` TEXT, `transportTypeRaw` TEXT, `lineName` TEXT, `startLocationName` TEXT, `endLocationName` TEXT, `notes` TEXT NOT NULL, `sourceFootprintID` TEXT, `sourceTransportRecordID` TEXT, `planStatusRaw` TEXT NOT NULL, PRIMARY KEY(`id`))""")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `home_city` (`id` TEXT NOT NULL, `countryCode` TEXT NOT NULL, `countryName` TEXT NOT NULL, `cityName` TEXT NOT NULL, `latitude` REAL, `longitude` REAL, `timeZoneIdentifier` TEXT, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`id`))""")
            }
        }

        val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `trips` ADD COLUMN `activityTypeValue` TEXT")
            }
        }

        /** Stable administrative identity for trip cities; existing rows remain valid with null IDs. */
        val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `trip_day_cities` ADD COLUMN `cityIdentifier` TEXT")
                db.execSQL("ALTER TABLE `trip_items` ADD COLUMN `cityIdentifier` TEXT")
                db.execSQL("ALTER TABLE `home_city` ADD COLUMN `cityIdentifier` TEXT")
            }
        }

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "dfk_v1_stable.db"
                )
                .addMigrations(MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12)
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
