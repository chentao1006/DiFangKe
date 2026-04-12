package com.ct106.difangke.data.db.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * 持久化交通记录（对应 iOS TransportRecord @Model）
 */
@Entity(tableName = "transport_records")
data class TransportRecordEntity(
    @PrimaryKey
    val recordID: String = UUID.randomUUID().toString(),
    val day: Date = Date(),
    val startTime: Date = Date(),
    val endTime: Date = Date(),
    val startLocation: String = "起点",
    val endLocation: String = "终点",
    val typeRaw: String = "car",
    val distance: Double = 0.0,
    val averageSpeed: Double = 0.0,
    /** JSON 编码的坐标点列表，格式: [[lat,lon],...] */
    val pointsJson: String = "[]",
    val manualTypeRaw: String? = null,
    /** active 或 ignored */
    val statusRaw: String = "active"
)

/**
 * AI 生成的每日摘要（对应 iOS DailyInsight @Model）
 */
@Entity(tableName = "daily_insights")
data class DailyInsightEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),
    val date: Date? = Date(),
    val content: String? = "",
    val aiGenerated: Boolean = false,
    val dataFingerprint: String? = "",
    val createdAt: Date? = Date()
)
