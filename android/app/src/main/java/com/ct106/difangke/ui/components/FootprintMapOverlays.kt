package com.ct106.difangke.ui.components

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.amap.api.maps.AMap
import com.amap.api.maps.model.BitmapDescriptorFactory
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.MarkerOptions
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

data class FootprintMapMarker(
    val latitude: Double,
    val longitude: Double,
    val icon: String?,
    val colorHex: String?,
    val durationSeconds: Long = 0L
)

fun AMap.addFootprintMarkers(markers: List<FootprintMapMarker>) {
    markers
        .filter { it.latitude.isFinite() && it.longitude.isFinite() }
        .forEach { marker ->
            addMarker(
                MarkerOptions()
                    .position(LatLng(marker.latitude, marker.longitude))
                    .anchor(0.5f, 0.5f)
                    .icon(BitmapDescriptorFactory.fromBitmap(createFootprintMarkerBitmap(marker)))
                    .zIndex(100f)
            )
        }
}

fun buildFootprintMapMarkers(
    footprints: List<FootprintEntity>,
    activityTypes: List<ActivityTypeEntity>
): List<FootprintMapMarker> {
    val activityById = activityTypes.associateBy { it.id }
    return footprints.mapNotNull { footprint ->
        val coordinate = footprint.firstCoordinateOrNull() ?: return@mapNotNull null
        val activity = activityById[footprint.activityTypeValue]
        FootprintMapMarker(
            latitude = coordinate.first,
            longitude = coordinate.second,
            icon = activity?.icon ?: "place",
            colorHex = activity?.colorHex ?: "#00A0AC",
            durationSeconds = footprint.duration
        )
    }
}

fun parseFootprintMapMarkers(markersJson: String?): List<FootprintMapMarker> {
    if (markersJson.isNullOrBlank()) return emptyList()
    return runCatching {
        val array = JSONArray(markersJson)
        buildList {
            for (i in 0 until array.length()) {
                when (val item = array.get(i)) {
                    is JSONObject -> {
                        add(
                            FootprintMapMarker(
                                latitude = item.getDouble("lat"),
                                longitude = item.getDouble("lon"),
                                icon = item.optString("icon", "place"),
                                colorHex = item.optString("color", "#00A0AC"),
                                durationSeconds = item.optLong("duration", 0L)
                            )
                        )
                    }
                    is JSONArray -> {
                        if (item.length() >= 2) {
                            add(
                                FootprintMapMarker(
                                    latitude = item.getDouble(0),
                                    longitude = item.getDouble(1),
                                    icon = "place",
                                    colorHex = "#00A0AC"
                                )
                            )
                        }
                    }
                }
            }
        }
    }.getOrDefault(emptyList())
}

private fun FootprintEntity.firstCoordinateOrNull(): Pair<Double, Double>? {
    return runCatching {
        val lats = JSONArray(latitudeJson)
        val lons = JSONArray(longitudeJson)
        if (lats.length() == 0 || lons.length() == 0) null else lats.getDouble(0) to lons.getDouble(0)
    }.getOrNull()
}

private fun createFootprintMarkerBitmap(marker: FootprintMapMarker): Bitmap {
    val baseScale = 1f + 0.45f * ((marker.durationSeconds / 3600.0).coerceIn(0.0, 8.0) / 8.0).toFloat()
    val scale = baseScale * 2f // 放大一倍
    val size = (34f * scale).toInt()
    val stroke = max(2f, 2.5f * scale)
    val bitmap = Bitmap.createBitmap(size + 8, size + 8, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val center = bitmap.width / 2f
    val radius = size / 2f

    val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColor(marker.colorHex, Color.rgb(0, 160, 172))
        style = Paint.Style.FILL
    }
    val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = stroke
    }
    val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = 15f * scale
    }

    canvas.drawCircle(center, center, radius, fillPaint)
    canvas.drawCircle(center, center, radius - stroke / 2f, strokePaint)

    val glyph = mapGlyph(marker.icon)
    val y = center - (iconPaint.descent() + iconPaint.ascent()) / 2f
    canvas.drawText(glyph, center, y, iconPaint)
    return bitmap
}

private fun parseColor(hex: String?, fallback: Int): Int {
    return runCatching {
        if (hex.isNullOrBlank()) fallback else Color.parseColor(hex)
    }.getOrDefault(fallback)
}

private fun mapGlyph(icon: String?): String {
    return when (icon?.lowercase()) {
        "home" -> "家"
        "work", "laptop", "laptop_mac", "calculate", "bank", "home_work", "apartment", "factory" -> "工"
        "restaurant", "eat", "fastfood", "cake" -> "食"
        "shopping_bag", "shopping", "shopping_cart" -> "购"
        "directions_run", "run" -> "跑"
        "directions_walk", "walk", "hiking" -> "步"
        "directions_bike", "cycle" -> "骑"
        "directions_car", "car" -> "车"
        "directions_bus" -> "巴"
        "flight", "airplane_ticket", "plane" -> "飞"
        "train", "tram", "subway" -> "轨"
        "directions_boat", "sailing", "kayaking" -> "船"
        "sports_esports", "theater_comedy", "attractions", "celebration", "emoji_events" -> "玩"
        "menu_book", "school" -> "学"
        "local_hospital", "medical_services" -> "医"
        "bedtime", "nights_stay" -> "眠"
        "local_cafe", "coffee" -> "咖"
        "movie" -> "影"
        "brush", "palette", "camera_alt", "music_note", "piano" -> "艺"
        "park", "stadium", "pool", "landscape", "beach_access" -> "景"
        "local_bar" -> "酒"
        "local_gas_station", "local_parking", "local_shipping" -> "站"
        "church", "temple_buddhist", "museum", "castle" -> "馆"
        else -> "?"
    }
}
