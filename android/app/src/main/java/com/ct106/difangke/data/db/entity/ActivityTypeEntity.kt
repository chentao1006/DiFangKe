package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.UUID

/**
 * 活动类型实体（对应 iOS ActivityType @Model）
 */
@Entity(tableName = "activity_types")
data class ActivityTypeEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val icon: String = "place",
    val colorHex: String = "#007AFF",
    val sortOrder: Int = 0,
    val isSystem: Boolean = false
)

/**
 * 交通手动选择实体（对应 iOS TransportManualSelection @Model）
 */
@Entity(tableName = "transport_manual_selections")
data class TransportManualSelectionEntity(
    @PrimaryKey
    val recordID: String = UUID.randomUUID().toString(),
    val startTime: java.util.Date = java.util.Date(),
    val endTime: java.util.Date = java.util.Date(),
    val vehicleType: String = "",
    val isDeleted: Boolean = false,
    val startLocationOverride: String? = null,
    val endLocationOverride: String? = null
)
