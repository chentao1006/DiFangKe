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
import com.ct106.difangke.AppConfig
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
            val bitmap = createFootprintMarkerBitmap(marker)
            
            // Calculate anchor based on uniform size
            val scale = 2.9f
            val size = (34f * scale).toInt()
            val bitmapHeight = (size * 1.4f).toInt() + 8
            val radius = size / 2f
            val pinTopCenterY = radius + 4f
            val pinBottomY = pinTopCenterY + radius * 1.4f
            val anchorV = pinBottomY / bitmapHeight.toFloat()
            
            addMarker(
                MarkerOptions()
                    .position(LatLng(marker.latitude, marker.longitude))
                    .anchor(0.5f, anchorV)
                    .icon(BitmapDescriptorFactory.fromBitmap(bitmap))
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

private fun formatDurationMinimal(durationSeconds: Long): Pair<String, String> {
    val totalMinutes = (durationSeconds / 60).toInt()
    if (totalMinutes < 60) {
        return Pair("${max(1, totalMinutes)}", "分钟")
    }
    val hours = totalMinutes / 60.0
    if (hours >= 10.0) {
        return Pair("${Math.round(hours)}", "小时")
    }
    val formatted = Math.round(hours * 10) / 10.0
    val formattedStr = if (formatted % 1.0 == 0.0) "${formatted.toInt()}" else "$formatted"
    return Pair(formattedStr, "小时")
}

private fun createFootprintMarkerBitmap(marker: FootprintMapMarker): Bitmap {
    val scale = 2.9f // 统一大小, 缩小一点
    val size = (34f * scale).toInt()
    val stroke = max(2f, 2.5f * scale)
    val bitmap = Bitmap.createBitmap(size + 8, (size * 1.4f).toInt() + 8, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val center = bitmap.width / 2f
    val radius = size / 2f
    val pinTopCenterY = radius + 4f

    val cornerEffect = android.graphics.CornerPathEffect(size * 0.05f)

    val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColor(marker.colorHex, Color.rgb(0, 160, 172))
        style = Paint.Style.FILL
        pathEffect = cornerEffect
    }
    val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = stroke
        pathEffect = cornerEffect
    }
    val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColor(marker.colorHex, Color.rgb(0, 160, 172)) // 活动色
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = 14f * scale
    }

    val path = android.graphics.Path()
    val rectF = android.graphics.RectF(center - radius, pinTopCenterY - radius, center + radius, pinTopCenterY + radius)
    path.arcTo(rectF, 125f, 290f)
    path.lineTo(center, pinTopCenterY + radius * 1.4f)
    path.close()

    canvas.drawPath(path, fillPaint)
    canvas.drawPath(path, strokePaint)
    
    // 圆形白色底
    val whiteCirclePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    canvas.drawCircle(center, pinTopCenterY, radius * 0.8f, whiteCirclePaint)

    val glyph = mapGlyph(marker.icon)
    val y = pinTopCenterY - (iconPaint.descent() + iconPaint.ascent()) / 2f
    canvas.drawText(glyph, center, y, iconPaint)

    if (marker.durationSeconds >= AppConfig.STAY_DURATION_THRESHOLD.toLong()) {
    val durationTuple = formatDurationMinimal(marker.durationSeconds)
    val numberText = durationTuple.first
    val unitText = durationTuple.second

    // 加深颜色：HSV 降低亮度 0.3
    val baseColor = parseColor(marker.colorHex, Color.rgb(0, 160, 172))
    val darkerColor = run {
        val hsv = FloatArray(3)
        Color.colorToHSV(baseColor, hsv)
        hsv[2] = maxOf(0f, hsv[2] - 0.30f)
        Color.HSVToColor(hsv)
    }

    val numberPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = darkerColor
        textAlign = Paint.Align.LEFT
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = 6f * scale
    }
    val unitPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = darkerColor
        textAlign = Paint.Align.LEFT
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = 6f * scale * 0.75f
    }
    val numberWidth = numberPaint.measureText(numberText)
    val unitWidth = unitPaint.measureText(unitText)
    val textWidth = numberWidth + unitWidth
    
    val bannerWidth = textWidth + 4f * scale // 稍微增加一点内边距
    val bannerHeight = 8f * scale
    val bannerY = pinTopCenterY + radius - bannerHeight / 2f - 6f * scale
    
    val bannerRect = android.graphics.RectF(
        center - bannerWidth / 2f,
        bannerY,
        center + bannerWidth / 2f,
        bannerY + bannerHeight
    )
    val bannerBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(240, 255, 255, 255)
        style = Paint.Style.FILL
    }
    canvas.drawRoundRect(bannerRect, 3f * scale, 3f * scale, bannerBgPaint)

    val bannerStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColor(marker.colorHex, Color.rgb(0, 160, 172))
        style = Paint.Style.STROKE
        strokeWidth = 0.5f * scale
    }
    canvas.drawRoundRect(bannerRect, 3f * scale, 3f * scale, bannerStrokePaint)
    
    val textY = bannerY + bannerHeight / 2f - (numberPaint.descent() + numberPaint.ascent()) / 2f
    val startX = center - textWidth / 2f
    canvas.drawText(numberText, startX, textY, numberPaint)
    canvas.drawText(unitText, startX + numberWidth, textY, unitPaint)
    } // end duration threshold check

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
