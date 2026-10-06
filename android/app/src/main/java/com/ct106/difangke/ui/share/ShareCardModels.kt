package com.ct106.difangke.ui.share

import android.graphics.Bitmap
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.service.GeocodeService
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID

/** iOS DFKShareCardTheme. Colors are ARGB ints so the renderer can use android.graphics directly. */
enum class ShareCardTheme(val title: String) {
    LIGHT("浅色"),
    DARK("深色"),
    JOURNAL("手账");

    val background: Int get() = when (this) {
        LIGHT -> rgb(0.97, 0.97, 0.95)
        DARK -> rgb(0.07, 0.08, 0.09)
        JOURNAL -> rgb(0.98, 0.95, 0.88)
    }
    val foreground: Int get() = if (this == DARK) 0xFFFFFFFF.toInt() else rgb(0.12, 0.12, 0.11)
    val secondary: Int get() = if (this == DARK) withAlpha(0xFFFFFFFF.toInt(), 0.68) else rgb(0.36, 0.36, 0.34)
    val card: Int get() = when (this) {
        DARK -> withAlpha(0xFFFFFFFF.toInt(), 0.09)
        JOURNAL -> withAlpha(0xFFFFFFFF.toInt(), 0.58)
        LIGHT -> withAlpha(0xFFFFFFFF.toInt(), 0.72)
    }
    val accent: Int get() = when (this) {
        LIGHT -> SHARE_APP_ACCENT
        DARK -> rgb(0.55, 0.78, 1.0)
        JOURNAL -> rgb(0.66, 0.42, 0.24)
    }
    val usesDarkMap: Boolean get() = this == DARK
}

internal const val SHARE_APP_ACCENT: Int = 0xFF00A0AC.toInt()

internal fun rgb(r: Double, g: Double, b: Double): Int =
    android.graphics.Color.rgb((r * 255).toInt(), (g * 255).toInt(), (b * 255).toInt())

internal fun withAlpha(color: Int, alpha: Double): Int {
    val a = (android.graphics.Color.alpha(color) * alpha).toInt().coerceIn(0, 255)
    return (color and 0x00FFFFFF) or (a shl 24)
}

enum class ShareCardKind { MOMENT, TIMELINE, STATS }

data class GeoPoint(val lat: Double, val lon: Double) {
    val isRenderable: Boolean get() = kotlin.math.abs(lat) > 0.000001 && kotlin.math.abs(lon) > 0.000001 &&
        lat in -90.0..90.0 && lon in -180.0..180.0
}

data class ShareEntry(
    val id: String = UUID.randomUUID().toString(),
    val time: String,
    val title: String,
    val detail: String? = null,
    val tag: String? = null,
    val activityIcon: String? = null,
    val activityColor: Int? = null,
    val coordinate: GeoPoint? = null,
    val count: Int = 1,
    val isIncluded: Boolean = true,
    val dayDividerText: String? = null,
    val footprintIDs: List<String> = emptyList()
)

data class ShareStatEntry(val label: String, val value: String, val detail: String? = null)

data class ShareRankingEntry(
    val title: String,
    val detail: String? = null,
    val value: String,
    val icon: String,
    val color: Int
)

/** A footprint pin drawn on the map snapshot (iOS DFKShareMapSnapshotMarker). */
data class ShareMapMarker(
    val point: GeoPoint,
    val icon: String,
    val color: Int,
    val durationSeconds: Long,
    val footprintID: String? = null
)

data class ShareHeatPoint(val point: GeoPoint, val intensity: Int, val maxIntensity: Int)

/** Light and dark variants of one map snapshot. */
data class ShareMapImages(val light: Bitmap?, val dark: Bitmap?) {
    fun forTheme(theme: ShareCardTheme): Bitmap? = if (theme.usesDarkMap) dark ?: light else light ?: dark
}

/** iOS DFKShareCardPayload (without the future-plan kind, which Android retired). */
data class SharePayload(
    val kind: ShareCardKind,
    val title: String,
    val subtitle: String,
    val rangeText: String,
    val locationText: String? = null,
    val photos: List<Bitmap> = emptyList(),
    val contentMap: ShareMapImages? = null,
    val backgroundMap: ShareMapImages? = null,
    val coordinates: List<GeoPoint> = emptyList(),
    val mapMarkers: List<ShareMapMarker> = emptyList(),
    val mapRoutes: List<List<GeoPoint>> = emptyList(),
    val mapTransports: List<TransportRecordEntity> = emptyList(),
    val markerScale: Float = 1.5f,
    val entries: List<ShareEntry> = emptyList(),
    val stats: List<ShareStatEntry> = emptyList(),
    val placeRankings: List<ShareRankingEntry> = emptyList(),
    val activityRankings: List<ShareRankingEntry> = emptyList(),
    val brandName: String = "地方客",
    val brandSlogan: String = "走过的地方，就是你的生活",
    val version: String = UUID.randomUUID().toString()
) {
    val includedEntries: List<ShareEntry> get() = entries.filter { it.isIncluded }
}

// ── Shared formatting helpers (iOS DFKShareCardFactory statics) ──────────────

internal object ShareFormat {
    private val zh = Locale.SIMPLIFIED_CHINESE

    fun dateText(date: Date): String = SimpleDateFormat("yyyy年M月d日 EEEE", zh).format(date)

    fun dayDivider(date: Date): String = SimpleDateFormat("M月d日 EEEE", zh).format(date)

    fun time(date: Date): String = SimpleDateFormat("HH:mm", zh).format(date)

    fun timeRange(start: Date, end: Date): String = "${time(start)} - ${time(end)}"

    fun rangeText(start: Date, end: Date): String {
        val s = startOfDay(start)
        val e = startOfDay(end)
        return if (s == e) dateText(s) else "${dateText(s)} - ${dateText(e)}"
    }

    fun startAndAccumulatedDuration(start: Date, durationSeconds: Double): String {
        val totalMinutes = maxOf(1, (durationSeconds / 60).toInt())
        val durationText = when {
            totalMinutes >= 1440 -> "${totalMinutes / 1440}天"
            totalMinutes >= 60 -> "${totalMinutes / 60}小时"
            else -> "${totalMinutes}分钟"
        }
        return "${time(start)} · $durationText"
    }

    fun mileage(meters: Double): String =
        if (meters >= 1000) "${Math.round(meters / 1000)}公里" else "${Math.round(meters)}米"

    fun displayPlace(footprint: FootprintEntity): String {
        val text = footprint.address?.trim().orEmpty()
        return text.ifEmpty { "一个生活现场" }
    }

    fun startOfDay(date: Date): Date = Calendar.getInstance().run {
        time = date
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        time
    }

    fun addDays(date: Date, days: Int): Date = Calendar.getInstance().run {
        time = date; add(Calendar.DAY_OF_YEAR, days); time
    }

    /** iOS DFKShareCardFactory.locationText: "国家·城市、城市 / 国家·城市". */
    fun locationText(footprints: List<FootprintEntity>): String? {
        val locations = linkedMapOf<String, MutableList<String>>()
        footprints.sortedBy { it.startTime }.forEach { footprint ->
            val stored = footprint.countryName?.trim()?.takeIf { it.isNotEmpty() }
            val country = stored ?: GeocodeService.countryDisplayName(footprint.countryCode) ?: return@forEach
            val city = footprint.cityName?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
            val cities = locations.getOrPut(country) { mutableListOf() }
            if (city !in cities) cities += city
        }
        if (locations.isEmpty()) return null
        return locations.entries.joinToString(" / ") { (country, cities) -> "$country·${cities.joinToString("、")}" }
    }
}

// ── Coordinate parsing ───────────────────────────────────────────────────────

internal fun FootprintEntity.sharePoints(): List<GeoPoint> = runCatching {
    val lats = JSONArray(latitudeJson)
    val lons = JSONArray(longitudeJson)
    (0 until minOf(lats.length(), lons.length())).map { GeoPoint(lats.getDouble(it), lons.getDouble(it)) }
}.getOrDefault(emptyList())

/** iOS Footprint.latitude/longitude: mean of the stored samples. */
internal fun FootprintEntity.shareCenter(): GeoPoint? {
    val points = sharePoints()
    if (points.isEmpty()) return null
    return GeoPoint(points.sumOf { it.lat } / points.size, points.sumOf { it.lon } / points.size)
}

internal fun TransportRecordEntity.sharePoints(): List<GeoPoint> = runCatching {
    val array = JSONArray(pointsJson)
    (0 until array.length()).mapNotNull { index ->
        when (val item = array.get(index)) {
            is JSONArray -> if (item.length() >= 2) GeoPoint(item.getDouble(0), item.getDouble(1)) else null
            is JSONObject -> {
                val lat = item.optDouble("lat", item.optDouble("latitude", Double.NaN))
                val lon = item.optDouble("lon", item.optDouble("longitude", item.optDouble("lng", Double.NaN)))
                if (lat.isNaN() || lon.isNaN()) null else GeoPoint(lat, lon)
            }
            else -> null
        }
    }
}.getOrDefault(emptyList())

internal fun FootprintEntity.photoUris(): List<String> = runCatching {
    val array = JSONArray(photoAssetIDsJson)
    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
}.getOrDefault(emptyList())

internal fun parseHexColor(hex: String?): Int? = hex?.let {
    runCatching { android.graphics.Color.parseColor(if (it.startsWith("#")) it else "#$it") }.getOrNull()
}

internal fun distanceMeters(a: GeoPoint, b: GeoPoint): Double {
    val result = FloatArray(1)
    android.location.Location.distanceBetween(a.lat, a.lon, b.lat, b.lon, result)
    return result[0].toDouble()
}
