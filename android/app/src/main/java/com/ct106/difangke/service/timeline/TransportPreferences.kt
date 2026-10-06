package com.ct106.difangke.service.timeline

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import java.util.Date
import kotlin.math.max
import kotlin.math.pow

/** Recency-weighted transport habits (iOS getPreferred*Type, 14-day half-life). */
data class TransportPreferences(
    val automotive: TransportType = TransportType.CAR,
    val cycling: TransportType = TransportType.BICYCLE,
    val road: TransportType? = null
) {
    companion object {
        fun weight(recordStart: Date, reference: Date): Double {
            val daysAgo = max(0.0, (reference.time - recordStart.time) / 86_400_000.0)
            return 0.5.pow(daysAgo / AppConfig.HABIT_DECAY_HALF_LIFE_DAYS)
        }

        /**
         * Excludes only the target day's *unedited* records (manual ones are facts).
         * [records] should be newest-first, already excluding ignored records.
         */
        fun compute(records: List<TransportRecordEntity>, date: Date): TransportPreferences {
            val dayStart = startOfDay(date)
            val dayEnd = addDays(dayStart, 1)
            val eligible = records.filter {
                it.statusRaw != "ignored" &&
                    (it.startTime < dayStart || it.startTime >= dayEnd || it.manualTypeRaw != null)
            }.sortedByDescending { it.startTime }
            fun typeOf(r: TransportRecordEntity) = TransportType.entries.firstOrNull { it.raw == (r.manualTypeRaw ?: r.typeRaw) }

            val recent150 = eligible.take(150)
            val autoCounts = linkedMapOf(TransportType.CAR to 0.0, TransportType.BUS to 0.0, TransportType.MOTORCYCLE to 0.0, TransportType.SUBWAY to 0.0)
            var bike = 0.0
            var ebike = 0.0
            for (r in recent150) {
                val type = typeOf(r) ?: continue
                val w = weight(r.startTime, date)
                if (autoCounts.containsKey(type)) autoCounts[type] = autoCounts[type]!! + w
                if (type == TransportType.BICYCLE) bike += w else if (type == TransportType.EBIKE) ebike += w
            }
            // Swift `max(by:)` returns the last maximal element on ties; with no
            // history all are zero, so fall back to car like iOS's `?? .car` intent.
            val auto = if (autoCounts.values.all { it == 0.0 }) TransportType.CAR
            else autoCounts.entries.maxByOrNull { it.value }!!.key

            val roadCounts = HashMap<TransportType, Double>()
            for (r in eligible.take(300)) {
                val type = typeOf(r) ?: continue
                if (type == TransportType.SLOW || type == TransportType.RUNNING) continue
                roadCounts[type] = (roadCounts[type] ?: 0.0) + weight(r.startTime, date)
            }
            val highest = roadCounts.values.maxOrNull()
            val road = highest?.let { h -> TransportType.entries.firstOrNull { roadCounts[it] == h } }
            return TransportPreferences(auto, if (bike >= ebike) TransportType.BICYCLE else TransportType.EBIKE, road)
        }
    }
}
