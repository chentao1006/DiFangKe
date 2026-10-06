package com.ct106.difangke.service.timeline

import java.util.Calendar
import java.util.Date
import kotlin.math.abs
import kotlin.math.min

/** Port of iOS `frequentActivityTypeValue` / `resolveFrequentActivityType`. */
object ActivityHabits {
    data class HistoryEntry(val startTime: Date, val activityTypeValue: String)

    /**
     * Prefer the most frequent activity at the same place within ±[windowMinutes]
     * of time-of-day (one occurrence suffices); otherwise the overall most frequent
     * one if it occurred at least [threshold] times.
     */
    fun frequentActivityTypeValue(
        history: List<HistoryEntry>,
        time: Date,
        windowMinutes: Int,
        threshold: Int
    ): String? {
        val cal = Calendar.getInstance()
        fun minutesOfDay(d: Date): Int {
            cal.time = d
            return cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        }
        val target = minutesOfDay(time)
        val window = LinkedHashMap<String, Int>()
        val total = LinkedHashMap<String, Int>()
        for (entry in history) {
            total[entry.activityTypeValue] = (total[entry.activityTypeValue] ?: 0) + 1
            val diff = abs(target - minutesOfDay(entry.startTime))
            if (min(diff, 1440 - diff) <= windowMinutes) {
                window[entry.activityTypeValue] = (window[entry.activityTypeValue] ?: 0) + 1
            }
        }
        window.maxByOrNull { it.value }?.let { return it.key }
        val best = total.maxByOrNull { it.value } ?: return null
        return if (best.value >= threshold) best.key else null
    }
}
