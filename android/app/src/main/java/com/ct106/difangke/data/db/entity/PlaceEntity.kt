package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.UUID

/**
 * 地点实体（对应 iOS Place @Model）
 */
@Entity(tableName = "places")
data class PlaceEntity(
    @PrimaryKey
    val placeID: String = UUID.randomUUID().toString(),
    val name: String = "",
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val radius: Float = 50f,
    val address: String? = null,
    val isIgnored: Boolean = false,
    val isUserDefined: Boolean = true,
    val isPriority: Boolean = false,
    val category: String? = null
)
