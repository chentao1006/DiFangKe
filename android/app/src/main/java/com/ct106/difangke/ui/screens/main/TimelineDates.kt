package com.ct106.difangke.ui.screens.main

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

internal fun normalizeTimelineDate(date: Date): Date = Calendar.getInstance().apply {
    time = date
    set(Calendar.HOUR_OF_DAY, 0)
    set(Calendar.MINUTE, 0)
    set(Calendar.SECOND, 0)
    set(Calendar.MILLISECOND, 0)
}.time

internal fun isSameDay(d1: Date, d2: Date): Boolean {
    val c1 = Calendar.getInstance().apply { time = d1 }
    val c2 = Calendar.getInstance().apply { time = d2 }
    return c1.get(Calendar.YEAR) == c2.get(Calendar.YEAR) && c1.get(Calendar.DAY_OF_YEAR) == c2.get(Calendar.DAY_OF_YEAR)
}

private fun dayOffset(offset: Int): Date = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, offset) }.time

private fun isRelativeDay(date: Date): Boolean =
    (-2..1).any { isSameDay(date, dayOffset(it)) }

/** iOS timelineDateTitle(for:). */
internal fun timelineDateTitle(date: Date): String {
    return when {
        isSameDay(date, Date()) -> "今天"
        isSameDay(date, dayOffset(-1)) -> "昨天"
        isSameDay(date, dayOffset(1)) -> "明天"
        isSameDay(date, dayOffset(-2)) -> "前天"
        else -> {
            val currentYear = Calendar.getInstance().get(Calendar.YEAR)
            val displayYear = Calendar.getInstance().apply { time = date }.get(Calendar.YEAR)
            if (currentYear == displayYear) SimpleDateFormat("M月d日", Locale.CHINA).format(date)
            else SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date)
        }
    }
}

internal fun weekdayText(date: Date): String = SimpleDateFormat("EEEE", Locale.CHINA).format(date)

/** iOS timelineDateSecondaryTitle(for:): relative days add the date, others the weekday. */
internal fun timelineDateSecondaryTitle(date: Date): String {
    if (!isRelativeDay(date)) return weekdayText(date)
    val sameYear = Calendar.getInstance().get(Calendar.YEAR) == Calendar.getInstance().apply { time = date }.get(Calendar.YEAR)
    val dateText = SimpleDateFormat(if (sameYear) "M月d日" else "yyyy年M月d日", Locale.CHINA).format(date)
    return "$dateText ${weekdayText(date)}"
}

/** iOS formattedTimelineDuration. */
internal fun formattedTimelineDuration(seconds: Long): String {
    val totalMinutes = maxOf(1L, seconds / 60)
    val hours = totalMinutes / 60
    val minutes = totalMinutes % 60
    return if (hours > 0) "$hours 小时 $minutes 分钟" else "$minutes 分钟"
}

/** iOS formattedTimelineDistance. */
internal fun formattedTimelineDistance(meters: Double): String =
    if (meters >= 1_000) String.format(Locale.US, "%.1f 公里", meters / 1_000) else "${Math.round(meters)} 米"
