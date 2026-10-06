package com.ct106.difangke.service.tracking

import java.text.Normalizer
import java.util.Locale
import kotlin.math.roundToInt

/** Port of the counting rules in iOS `triggerNotificationSummaryRefresh`. */
object DailyStats {
    private val genericNames = setOf("正在解析位置...", "未知位置", "地点记录", "此处")

    data class PlaceKeyInput(val address: String?, val placeID: String?, val latitude: Double?, val longitude: Double?)

    /** Distinct places: by displayed name, then place ID, then a ~100 m coordinate grid. */
    fun placeCount(footprints: List<PlaceKeyInput>): Int = footprints.map { fp ->
        val name = fp.address?.trim().orEmpty()
        when {
            name.isNotEmpty() && name !in genericNames ->
                "name:" + Normalizer.normalize(name, Normalizer.Form.NFD)
                    .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
            fp.placeID != null -> "place:${fp.placeID}"
            else -> "coordinate:${((fp.latitude ?: 0.0) * 1000).roundToInt()},${((fp.longitude ?: 0.0) * 1000).roundToInt()}"
        }
    }.toSet().size
}
