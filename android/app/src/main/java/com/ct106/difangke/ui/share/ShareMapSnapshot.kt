package com.ct106.difangke.ui.share

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import com.ct106.difangke.AppConfig
import com.ct106.difangke.service.GeocodeService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.tan

/**
 * Web-Mercator projection for a Tencent static map. Tencent maps (and every
 * coordinate stored by the app) are GCJ-02, so no datum shift is needed.
 * Points are returned in output-bitmap pixels.
 */
internal class MercatorProjection(
    val centerLat: Double,
    val centerLon: Double,
    val zoom: Int,
    val logicalWidth: Int,
    val logicalHeight: Int,
    val scale: Int
) {
    private val world = 256.0 * 2.0.pow(zoom)
    private val cx = worldX(centerLon)
    private val cy = worldY(centerLat)

    private fun worldX(lon: Double) = (lon + 180.0) / 360.0 * world
    private fun worldY(lat: Double): Double {
        val clamped = lat.coerceIn(-85.0, 85.0) * PI / 180.0
        return (1.0 - ln(tan(clamped) + 1.0 / cos(clamped)) / PI) / 2.0 * world
    }

    fun point(p: GeoPoint): PointF = PointF(
        ((worldX(p.lon) - cx + logicalWidth / 2.0) * scale).toFloat(),
        ((worldY(p.lat) - cy + logicalHeight / 2.0) * scale).toFloat()
    )

    companion object {
        /** iOS snapshotRegion: bounding box * spanMultiplier, at least minimumSpan degrees. */
        fun fitting(
            points: List<GeoPoint>,
            logicalWidth: Int,
            logicalHeight: Int,
            scale: Int,
            spanMultiplier: Double = 2.2,
            minimumSpan: Double = 0.012
        ): MercatorProjection? {
            if (points.isEmpty()) return null
            val minLat = points.minOf { it.lat }
            val maxLat = points.maxOf { it.lat }
            val minLon = points.minOf { it.lon }
            val maxLon = points.maxOf { it.lon }
            val latDelta = max(minimumSpan, (maxLat - minLat) * spanMultiplier)
            val lonDelta = max(minimumSpan, (maxLon - minLon) * spanMultiplier)
            val centerLat = (minLat + maxLat) / 2
            val centerLon = (minLon + maxLon) / 2
            fun normY(lat: Double): Double {
                val r = lat.coerceIn(-85.0, 85.0) * PI / 180.0
                return (1.0 - ln(tan(r) + 1.0 / cos(r)) / PI) / 2.0
            }
            val dy = max(1e-9, normY(centerLat - latDelta / 2) - normY(centerLat + latDelta / 2))
            val zoomLon = log2(logicalWidth * 360.0 / (256.0 * lonDelta))
            val zoomLat = log2(logicalHeight / (256.0 * dy))
            val zoom = floor(min(zoomLon, zoomLat)).toInt().coerceIn(3, 18)
            return MercatorProjection(centerLat, centerLon, zoom, logicalWidth, logicalHeight, scale)
        }
    }
}

/**
 * Builds map snapshots for share cards: a Tencent static-map base (or a drawn
 * fallback when the static-map service is unavailable) plus iOS-style overlays
 * (route, activity pins with duration badges, heatmap).
 */
internal object ShareMapSnapshotter {
    private const val LOGICAL_W = 600
    private const val LOGICAL_H = 360
    private const val SCALE = 2 // output 1200 x 720, same as iOS snapshot points

    private val baseCache = object : android.util.LruCache<String, Bitmap>(6) {}

    suspend fun snapshot(
        coordinates: List<GeoPoint>,
        markers: List<ShareMapMarker> = emptyList(),
        routes: List<List<GeoPoint>> = emptyList(),
        heatPoints: List<ShareHeatPoint> = emptyList(),
        drawsPath: Boolean = true,
        drawsOverlays: Boolean = true,
        markerScale: Float = 2.2f
    ): ShareMapImages? = withContext(Dispatchers.Default) {
        val valid = coordinates.filter { it.isRenderable }
        if (valid.isEmpty()) return@withContext null
        val projection = MercatorProjection.fitting(valid, LOGICAL_W, LOGICAL_H, SCALE) ?: return@withContext null
        val key = "${"%.5f".format(projection.centerLat)},${"%.5f".format(projection.centerLon)},${projection.zoom}"
        val base = baseCache.get(key) ?: GeocodeService.shared.staticMap(
            projection.centerLat, projection.centerLon, projection.zoom, LOGICAL_W, LOGICAL_H, SCALE
        )?.also { baseCache.put(key, it) }

        fun compose(dark: Boolean): Bitmap {
            val bitmap = Bitmap.createBitmap(LOGICAL_W * SCALE, LOGICAL_H * SCALE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            if (base != null) {
                val paint = Paint(Paint.FILTER_BITMAP_FLAG)
                if (dark) paint.colorFilter = ColorMatrixColorFilter(darkMapMatrix())
                canvas.drawBitmap(base, null, RectF(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat()), paint)
            } else {
                drawFallbackBase(canvas, bitmap.width, bitmap.height, dark)
            }
            if (drawsOverlays) {
                routes.filter { it.size > 1 }.forEach { drawPath(canvas, projection, it) }
                if (drawsPath && routes.isEmpty() && markers.isEmpty()) drawPath(canvas, projection, valid)
                if (markers.isEmpty()) {
                    if (routes.isEmpty() && heatPoints.isEmpty()) drawEndpointMarkers(canvas, projection, valid)
                } else {
                    drawFootprintMarkers(canvas, projection, markers, markerScale, dark)
                }
            }
            drawHeatmap(canvas, projection, heatPoints)
            return bitmap
        }
        ShareMapImages(light = compose(false), dark = compose(true))
    }

    /** Invert lightness while keeping hue: a usable "dark map" from the light tiles. */
    private fun darkMapMatrix(): ColorMatrix {
        val invert = ColorMatrix(floatArrayOf(
            -1f, 0f, 0f, 0f, 255f,
            0f, -1f, 0f, 0f, 255f,
            0f, 0f, -1f, 0f, 255f,
            0f, 0f, 0f, 1f, 0f
        ))
        // Rotating the hue by 180° after inverting restores the original hues.
        val rotate = ColorMatrix(floatArrayOf(
            -0.574f, 1.430f, 0.144f, 0f, 0f,
            0.426f, 0.430f, 0.144f, 0f, 0f,
            0.426f, 1.430f, -0.856f, 0f, 0f,
            0f, 0f, 0f, 1f, 0f
        ))
        invert.postConcat(rotate)
        val dim = ColorMatrix().apply { setScale(0.82f, 0.85f, 0.9f, 1f) }
        invert.postConcat(dim)
        return invert
    }

    private fun drawFallbackBase(canvas: Canvas, width: Int, height: Int, dark: Boolean) {
        val top = if (dark) 0xFF1E2327.toInt() else 0xFFE9EEE8.toInt()
        val bottom = if (dark) 0xFF15191C.toInt() else 0xFFDDE6E3.toInt()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, width.toFloat(), height.toFloat(), top, bottom, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        paint.shader = null
        paint.color = if (dark) 0x14FFFFFF else 0x14000000
        paint.strokeWidth = 2f
        var x = 0f
        while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), paint); x += 80f }
        var y = 0f
        while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, paint); y += 80f }
    }

    private fun sample(points: List<GeoPoint>, maxCount: Int): List<GeoPoint> {
        if (points.size <= maxCount) return points
        val stride = (points.size - 1).toDouble() / (maxCount - 1)
        return (0 until maxCount).map { points[min(points.size - 1, Math.round(it * stride).toInt())] }
    }

    private fun drawPath(canvas: Canvas, projection: MercatorProjection, coordinates: List<GeoPoint>) {
        if (coordinates.size < 2) return
        val points = sample(coordinates, 240).map(projection::point)
        val path = Path().apply {
            moveTo(points[0].x, points[0].y)
            points.drop(1).forEach { lineTo(it.x, it.y) }
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            strokeWidth = 9f
            color = withAlpha(SHARE_APP_ACCENT, 0.92)
        }
        canvas.drawPath(path, paint)
    }

    private fun drawEndpointMarkers(canvas: Canvas, projection: MercatorProjection, coordinates: List<GeoPoint>) {
        val chosen = if (coordinates.size <= 2) coordinates else listOf(coordinates.first(), coordinates.last())
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        chosen.map(projection::point).forEach { p ->
            paint.color = withAlpha(0xFFFFFFFF.toInt(), 0.95)
            canvas.drawCircle(p.x, p.y, 16f, paint)
            paint.color = SHARE_APP_ACCENT
            canvas.drawCircle(p.x, p.y, 8f, paint)
        }
    }

    private fun drawFootprintMarkers(
        canvas: Canvas,
        projection: MercatorProjection,
        markers: List<ShareMapMarker>,
        scale: Float,
        dark: Boolean
    ) {
        markers.take(12).forEach { marker ->
            val point = projection.point(marker.point)
            val markerSize = 20f * scale
            val radius = markerSize / 2f
            val iconSize = 23f * scale * 0.52f
            val cx = point.x
            val cy = point.y - radius * 1.4f
            val pin = Path().apply {
                arcTo(RectF(cx - radius, cy - radius, cx + radius, cy + radius), 125f, 290f, true)
                lineTo(cx, cy + radius * 1.4f)
                close()
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = marker.color
                setShadowLayer(5f, 0f, 3f, withAlpha(0xFF000000.toInt(), 0.22))
            }
            canvas.drawPath(pin, paint)
            ShareIconPainter.draw(canvas, marker.icon, cx, cy, iconSize, 0xFFFFFFFF.toInt())
            if (marker.durationSeconds >= AppConfig.STAY_DURATION_THRESHOLD) {
                drawDurationBadge(canvas, marker.durationSeconds, marker.color, cx, cy, radius, scale, dark)
            }
        }
    }

    private fun drawDurationBadge(
        canvas: Canvas,
        durationSeconds: Long,
        color: Int,
        cx: Float,
        cy: Float,
        radius: Float,
        scale: Float,
        dark: Boolean
    ) {
        val minutes = maxOf(1L, durationSeconds / 60)
        val text = if (minutes >= 60) {
            val hours = minutes / 60.0
            if (hours >= 10) "${hours.toInt()}小时" else String.format("%.1f小时", hours)
        } else "${minutes}分钟"
        val hsv = FloatArray(3)
        android.graphics.Color.colorToHSV(color, hsv)
        hsv[1] = min(hsv[1] * 1.1f, 1f)
        hsv[2] = max(hsv[2] - 0.30f, 0f)
        val darker = android.graphics.Color.HSVToColor(hsv)
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = darker
            textSize = 6.2f * scale
            typeface = Typeface.DEFAULT_BOLD
        }
        val textWidth = textPaint.measureText(text)
        val fm = textPaint.fontMetrics
        val textHeight = fm.descent - fm.ascent
        val badgeWidth = textWidth + 8f
        val badgeHeight = textHeight + 4f
        val badgeY = cy + radius - badgeHeight / 2f - 6f * scale
        val rect = RectF(cx - badgeWidth / 2f, badgeY, cx + badgeWidth / 2f, badgeY + badgeHeight)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = if (dark) 0xFF1C1C1E.toInt() else 0xFFFFFFFF.toInt() }
        canvas.drawRoundRect(rect, 4f, 4f, fill)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 0.8f * scale
            this.color = color
        }
        canvas.drawRoundRect(rect, 4f, 4f, stroke)
        canvas.drawText(text, cx - textWidth / 2f, badgeY + (badgeHeight - textHeight) / 2f - fm.ascent, textPaint)
    }

    private fun drawHeatmap(canvas: Canvas, projection: MercatorProjection, points: List<ShareHeatPoint>) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        points.forEach { heat ->
            val p = projection.point(heat.point)
            val ratio = (heat.intensity.toDouble() / max(1, heat.maxIntensity)).pow(0.4)
            val base = when {
                ratio < 0.25 -> 0xFFFF9500.toInt()
                ratio < 0.85 -> 0xFFFF3B30.toInt()
                else -> rgb(0.7, 0.0, 0.0)
            }
            val radius = (18 + ratio * 24).toFloat()
            paint.shader = RadialGradient(p.x, p.y, radius, withAlpha(base, 0.48), withAlpha(base, 0.04), Shader.TileMode.CLAMP)
            canvas.drawCircle(p.x, p.y, radius, paint)
        }
        paint.shader = null
    }
}
