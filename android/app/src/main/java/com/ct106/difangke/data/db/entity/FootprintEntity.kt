package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.ct106.difangke.data.model.FootprintStatus
import java.util.Date
import java.util.UUID

/**
 * 足迹实体（对应 iOS Footprint @Model）
 * 坐标序列以 JSON 格式存储，对应 iOS 的 latitudeData/longitudeData
 */
@Entity(tableName = "footprints")
data class FootprintEntity(
    @PrimaryKey
    val footprintID: String = UUID.randomUUID().toString(),  // UUID 转字符串存储
    val date: Date = Date(),
    val startTime: Date = Date(),
    val endTime: Date = Date(),
    /** JSON 编码的纬度数组，对应 iOS latitudeData */
    val latitudeJson: String = "[]",
    /** JSON 编码的经度数组，对应 iOS longitudeData */
    val longitudeJson: String = "[]",
    val locationHash: String = "",
    val title: String? = null,
    val reason: String? = null,
    val statusValue: String = "candidate",
    val aiScore: Float = 0f,
    val placeID: String? = null,
    val address: String? = null,
    /** Canonical reverse-geocoded hierarchy; never derive statistics from POI text. */
    val countryCode: String? = null,
    val countryName: String? = null,
    val cityName: String? = null,
    val isHighlight: Boolean? = null,
    val isPlaceSuggestionIgnored: Boolean = false,
    val aiAnalyzed: Boolean = false,
    val isTitleEditedByHand: Boolean = false,
    val activityTypeValue: String? = null,
    /** JSON 编码的照片 ID 数组 */
    val photoAssetIDsJson: String = "[]",
    /** Health Connect 聚合的停留期间指标；未授权或无数据时保持为空。 */
    val stepCount: Int? = null,
    val walkingDistance: Double? = null,
    val floorsAscended: Int? = null
) {
    val status: FootprintStatus get() = FootprintStatus.from(statusValue)

    val duration: Long get() = maxOf(0L, (endTime.time - startTime.time) / 1000L)

    companion object {
        fun generateLocationHash(lat: Double, lon: Double): String {
            val latInt = (lat * 1000).toInt()
            val lonInt = (lon * 1000).toInt()
            return "${latInt}_${lonInt}"
        }
    }
}
