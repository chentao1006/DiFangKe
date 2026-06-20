package com.ct106.difangke.ui.components

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathNode
import androidx.compose.ui.graphics.vector.VectorGroup
import androidx.compose.ui.graphics.vector.VectorPath
import com.amap.api.maps.AMap
import com.amap.api.maps.model.BitmapDescriptorFactory
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.MarkerOptions
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.AppConfig
import org.json.JSONArray
import org.json.JSONObject
import java.util.Date
import java.util.Locale
import kotlin.math.max

data class FootprintMapMarker(
    val latitude: Double,
    val longitude: Double,
    val icon: String?,
    val colorHex: String?,
    val durationSeconds: Long = 0L
)

fun AMap.addFootprintMarkers(markers: List<FootprintMapMarker>, isDark: Boolean = false) {
    markers
        .filter { it.latitude.isFinite() && it.longitude.isFinite() }
        .forEach { marker ->
            val bitmap = createFootprintMarkerBitmap(marker, isDark)
            
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
    activityTypes: List<ActivityTypeEntity>,
    visibleStart: Date? = null,
    visibleEnd: Date? = null
): List<FootprintMapMarker> {
    val activityById = activityTypes.associateBy { it.id }
    data class Bucket(
        var weightedLatitude: Double,
        var weightedLongitude: Double,
        var totalDurationSeconds: Long,
        var representative: FootprintEntity
    )

    val buckets = linkedMapOf<String, Bucket>()
    footprints.forEach { footprint ->
        val coordinate = footprint.firstCoordinateOrNull() ?: return@forEach
        val visibleDuration = footprint.visibleDurationSeconds(visibleStart, visibleEnd)
        if (visibleDuration <= 0L) return@forEach
        val durationWeight = max(visibleDuration, 1L)
        val key = footprint.mapAggregationKey(coordinate)
        val bucket = buckets[key]
        if (bucket == null) {
            buckets[key] = Bucket(
                weightedLatitude = coordinate.first * durationWeight,
                weightedLongitude = coordinate.second * durationWeight,
                totalDurationSeconds = visibleDuration,
                representative = footprint
            )
        } else {
            bucket.weightedLatitude += coordinate.first * durationWeight
            bucket.weightedLongitude += coordinate.second * durationWeight
            bucket.totalDurationSeconds += visibleDuration
            if (visibleDuration > bucket.representative.visibleDurationSeconds(visibleStart, visibleEnd)) {
                bucket.representative = footprint
            }
        }
    }

    return buckets.values.map { bucket ->
        val divisor = max(bucket.totalDurationSeconds, 1L).toDouble()
        val activity = activityById[bucket.representative.activityTypeValue]
        FootprintMapMarker(
            latitude = bucket.weightedLatitude / divisor,
            longitude = bucket.weightedLongitude / divisor,
            icon = activity?.icon ?: "place",
            colorHex = activity?.colorHex ?: "#00A0AC",
            durationSeconds = bucket.totalDurationSeconds
        )
    }
}

private fun FootprintEntity.visibleDurationSeconds(visibleStart: Date?, visibleEnd: Date?): Long {
    val clippedStart = visibleStart?.let { maxOf(startTime.time, it.time) } ?: startTime.time
    val clippedEnd = visibleEnd?.let { minOf(endTime.time, it.time) } ?: endTime.time
    return max(0L, (clippedEnd - clippedStart) / 1000L)
}

fun parseFootprintMapMarkers(markersJson: String?): List<FootprintMapMarker> {
    if (markersJson.isNullOrBlank()) return emptyList()
    return runCatching {
        val array = JSONArray(markersJson)
        val parsed = buildList {
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
        aggregateParsedMarkers(parsed)
    }.getOrDefault(emptyList())
}

private fun FootprintEntity.mapAggregationKey(coordinate: Pair<Double, Double>): String {
    return when {
        !placeID.isNullOrBlank() -> "place:$placeID"
        locationHash.isNotBlank() -> "hash:$locationHash"
        else -> String.format(Locale.US, "coord:%.5f,%.5f", coordinate.first, coordinate.second)
    }
}

private fun aggregateParsedMarkers(markers: List<FootprintMapMarker>): List<FootprintMapMarker> {
    data class Bucket(
        var latitude: Double,
        var longitude: Double,
        var totalDurationSeconds: Long,
        var representative: FootprintMapMarker
    )

    val buckets = linkedMapOf<String, Bucket>()
    markers.forEach { marker ->
        if (!marker.latitude.isFinite() || !marker.longitude.isFinite()) return@forEach
        val key = String.format(Locale.US, "coord:%.5f,%.5f", marker.latitude, marker.longitude)
        val bucket = buckets[key]
        if (bucket == null) {
            buckets[key] = Bucket(
                latitude = marker.latitude,
                longitude = marker.longitude,
                totalDurationSeconds = marker.durationSeconds,
                representative = marker
            )
        } else {
            bucket.totalDurationSeconds += marker.durationSeconds
            if (marker.durationSeconds > bucket.representative.durationSeconds) {
                bucket.representative = marker
            }
        }
    }

    return buckets.values.map { bucket ->
        bucket.representative.copy(durationSeconds = bucket.totalDurationSeconds)
    }
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

private fun createFootprintMarkerBitmap(marker: FootprintMapMarker, isDark: Boolean): Bitmap {
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
        color = if (isDark) Color.rgb(8, 8, 10) else Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = stroke
        pathEffect = cornerEffect
    }
    val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColor(marker.colorHex, Color.rgb(0, 160, 172)) // 活动色
        style = Paint.Style.STROKE
        strokeWidth = 2.4f * scale
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    val path = Path()
    val rectF = RectF(center - radius, pinTopCenterY - radius, center + radius, pinTopCenterY + radius)
    path.arcTo(rectF, 125f, 290f)
    path.lineTo(center, pinTopCenterY + radius * 1.4f)
    path.close()

    canvas.drawPath(path, fillPaint)
    canvas.drawPath(path, strokePaint)
    
    // 圆形白色底
    val whiteCirclePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = if (isDark) Color.rgb(28, 28, 30) else Color.WHITE
        style = Paint.Style.FILL
    }
    canvas.drawCircle(center, pinTopCenterY, radius * 0.8f, whiteCirclePaint)

    drawActivityIcon(canvas, marker.icon, center, pinTopCenterY, radius * 0.95f, iconPaint)

    if (marker.durationSeconds >= AppConfig.STAY_DURATION_THRESHOLD.toLong()) {
    val durationTuple = formatDurationMinimal(marker.durationSeconds)
    val numberText = durationTuple.first
    val unitText = durationTuple.second

    // 加深颜色：HSV 降低亮度 0.3
    val baseColor = parseColor(marker.colorHex, Color.rgb(0, 160, 172))
    val durationTextColor = run {
        val hsv = FloatArray(3)
        Color.colorToHSV(baseColor, hsv)
        if (isDark) {
            hsv[1] = (hsv[1] * 0.85f).coerceIn(0f, 1f)
            hsv[2] = (hsv[2] + 0.28f).coerceIn(0f, 1f)
        } else {
            hsv[2] = maxOf(0f, hsv[2] - 0.30f)
        }
        Color.HSVToColor(hsv)
    }

    val numberPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = durationTextColor
        textAlign = Paint.Align.LEFT
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = 6f * scale
    }
    val unitPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = durationTextColor
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
        color = if (isDark) Color.argb(235, 28, 28, 30) else Color.argb(240, 255, 255, 255)
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

private fun drawActivityIcon(canvas: Canvas, icon: String?, cx: Float, cy: Float, size: Float, paint: Paint) {
    drawImageVectorIcon(canvas, getIconForName(icon), cx, cy, size, paint.color)
}

private fun drawImageVectorIcon(canvas: Canvas, imageVector: ImageVector, cx: Float, cy: Float, size: Float, color: Int) {
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.FILL
    }

    val scaleX = size / imageVector.viewportWidth
    val scaleY = size / imageVector.viewportHeight
    canvas.save()
    canvas.translate(cx - size / 2f, cy - size / 2f)
    canvas.scale(scaleX, scaleY)
    drawVectorGroup(canvas, imageVector.root, paint)
    canvas.restore()
}

private fun drawVectorGroup(canvas: Canvas, group: VectorGroup, paint: Paint) {
    canvas.save()
    canvas.translate(group.translationX, group.translationY)
    if (group.rotation != 0f) {
        canvas.rotate(group.rotation, group.pivotX, group.pivotY)
    }
    if (group.scaleX != 1f || group.scaleY != 1f) {
        canvas.scale(group.scaleX, group.scaleY, group.pivotX, group.pivotY)
    }
    if (group.clipPathData.isNotEmpty()) {
        canvas.clipPath(pathFromNodes(group.clipPathData))
    }
    group.forEach { node ->
        when (node) {
            is VectorGroup -> drawVectorGroup(canvas, node, paint)
            is VectorPath -> drawVectorPath(canvas, node, paint)
        }
    }
    canvas.restore()
}

private fun drawVectorPath(canvas: Canvas, vectorPath: VectorPath, paint: Paint) {
    val path = pathFromNodes(vectorPath.pathData).apply {
        fillType = if (vectorPath.pathFillType == PathFillType.EvenOdd) Path.FillType.EVEN_ODD else Path.FillType.WINDING
    }
    val previousAlpha = paint.alpha
    paint.alpha = (previousAlpha * vectorPath.fillAlpha).toInt().coerceIn(0, 255)
    canvas.drawPath(path, paint)
    paint.alpha = previousAlpha
}

private fun pathFromNodes(nodes: List<PathNode>): Path {
    val path = Path()
    var currentX = 0f
    var currentY = 0f
    var startX = 0f
    var startY = 0f
    var lastCubicControlX: Float? = null
    var lastCubicControlY: Float? = null
    var lastQuadControlX: Float? = null
    var lastQuadControlY: Float? = null

    fun clearControls() {
        lastCubicControlX = null
        lastCubicControlY = null
        lastQuadControlX = null
        lastQuadControlY = null
    }

    nodes.forEach { node ->
        when (node) {
            PathNode.Close -> {
                path.close()
                currentX = startX
                currentY = startY
                clearControls()
            }
            is PathNode.MoveTo -> {
                path.moveTo(node.x, node.y)
                currentX = node.x
                currentY = node.y
                startX = currentX
                startY = currentY
                clearControls()
            }
            is PathNode.RelativeMoveTo -> {
                currentX += node.dx
                currentY += node.dy
                path.moveTo(currentX, currentY)
                startX = currentX
                startY = currentY
                clearControls()
            }
            is PathNode.LineTo -> {
                path.lineTo(node.x, node.y)
                currentX = node.x
                currentY = node.y
                clearControls()
            }
            is PathNode.RelativeLineTo -> {
                currentX += node.dx
                currentY += node.dy
                path.lineTo(currentX, currentY)
                clearControls()
            }
            is PathNode.HorizontalTo -> {
                currentX = node.x
                path.lineTo(currentX, currentY)
                clearControls()
            }
            is PathNode.RelativeHorizontalTo -> {
                currentX += node.dx
                path.lineTo(currentX, currentY)
                clearControls()
            }
            is PathNode.VerticalTo -> {
                currentY = node.y
                path.lineTo(currentX, currentY)
                clearControls()
            }
            is PathNode.RelativeVerticalTo -> {
                currentY += node.dy
                path.lineTo(currentX, currentY)
                clearControls()
            }
            is PathNode.CurveTo -> {
                path.cubicTo(node.x1, node.y1, node.x2, node.y2, node.x3, node.y3)
                lastCubicControlX = node.x2
                lastCubicControlY = node.y2
                lastQuadControlX = null
                lastQuadControlY = null
                currentX = node.x3
                currentY = node.y3
            }
            is PathNode.RelativeCurveTo -> {
                val x1 = currentX + node.dx1
                val y1 = currentY + node.dy1
                val x2 = currentX + node.dx2
                val y2 = currentY + node.dy2
                val x3 = currentX + node.dx3
                val y3 = currentY + node.dy3
                path.cubicTo(x1, y1, x2, y2, x3, y3)
                lastCubicControlX = x2
                lastCubicControlY = y2
                lastQuadControlX = null
                lastQuadControlY = null
                currentX = x3
                currentY = y3
            }
            is PathNode.ReflectiveCurveTo -> {
                val x1 = lastCubicControlX?.let { 2f * currentX - it } ?: currentX
                val y1 = lastCubicControlY?.let { 2f * currentY - it } ?: currentY
                path.cubicTo(x1, y1, node.x1, node.y1, node.x2, node.y2)
                lastCubicControlX = node.x1
                lastCubicControlY = node.y1
                lastQuadControlX = null
                lastQuadControlY = null
                currentX = node.x2
                currentY = node.y2
            }
            is PathNode.RelativeReflectiveCurveTo -> {
                val x1 = lastCubicControlX?.let { 2f * currentX - it } ?: currentX
                val y1 = lastCubicControlY?.let { 2f * currentY - it } ?: currentY
                val x2 = currentX + node.dx1
                val y2 = currentY + node.dy1
                val x3 = currentX + node.dx2
                val y3 = currentY + node.dy2
                path.cubicTo(x1, y1, x2, y2, x3, y3)
                lastCubicControlX = x2
                lastCubicControlY = y2
                lastQuadControlX = null
                lastQuadControlY = null
                currentX = x3
                currentY = y3
            }
            is PathNode.QuadTo -> {
                path.quadTo(node.x1, node.y1, node.x2, node.y2)
                lastQuadControlX = node.x1
                lastQuadControlY = node.y1
                lastCubicControlX = null
                lastCubicControlY = null
                currentX = node.x2
                currentY = node.y2
            }
            is PathNode.RelativeQuadTo -> {
                val x1 = currentX + node.dx1
                val y1 = currentY + node.dy1
                val x2 = currentX + node.dx2
                val y2 = currentY + node.dy2
                path.quadTo(x1, y1, x2, y2)
                lastQuadControlX = x1
                lastQuadControlY = y1
                lastCubicControlX = null
                lastCubicControlY = null
                currentX = x2
                currentY = y2
            }
            is PathNode.ReflectiveQuadTo -> {
                val x1 = lastQuadControlX?.let { 2f * currentX - it } ?: currentX
                val y1 = lastQuadControlY?.let { 2f * currentY - it } ?: currentY
                path.quadTo(x1, y1, node.x, node.y)
                lastQuadControlX = x1
                lastQuadControlY = y1
                lastCubicControlX = null
                lastCubicControlY = null
                currentX = node.x
                currentY = node.y
            }
            is PathNode.RelativeReflectiveQuadTo -> {
                val x1 = lastQuadControlX?.let { 2f * currentX - it } ?: currentX
                val y1 = lastQuadControlY?.let { 2f * currentY - it } ?: currentY
                currentX += node.dx
                currentY += node.dy
                path.quadTo(x1, y1, currentX, currentY)
                lastQuadControlX = x1
                lastQuadControlY = y1
                lastCubicControlX = null
                lastCubicControlY = null
            }
            is PathNode.ArcTo -> {
                path.lineTo(node.arcStartX, node.arcStartY)
                currentX = node.arcStartX
                currentY = node.arcStartY
                clearControls()
            }
            is PathNode.RelativeArcTo -> {
                currentX += node.arcStartDx
                currentY += node.arcStartDy
                path.lineTo(currentX, currentY)
                clearControls()
            }
        }
    }
    return path
}

