package com.ct106.difangke.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.google.gson.Gson
import java.io.File
import java.io.FileOutputStream
import java.util.Calendar
import java.util.Date
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One footprint dot on the widget track. */
data class WidgetDot(val lat: Double, val lon: Double, val color: Int)

/** Snapshot of one day as the widget shows it. */
data class WidgetDayData(
    val dayOffset: Int,
    val dayStartMillis: Long,
    val title: String,
    val placeCount: Int,
    val mileageMeters: Double,
    val latestPlaceName: String?,
    val dots: List<WidgetDot>,
    val polylines: List<List<Pair<Double, Double>>>
) {
    val isEmpty: Boolean get() = dots.isEmpty() && polylines.isEmpty()
    val mileageText: String get() = formatWidgetDistance(mileageMeters)
}

/** Mirrors iOS formatCurrentTodayDistance. */
fun formatWidgetDistance(distance: Double): String {
    val value = max(0.0, distance)
    return if (value < 1_000) String.format("%.0f 米", value)
    else String.format("%.1f 公里", value / 1_000)
}

object WidgetDataLoader {
    private const val DEFAULT_DOT_COLOR = 0xFF00A0AC.toInt()
    private val gson = Gson()

    fun dayStart(offset: Int, now: Long = System.currentTimeMillis()): Long =
        Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            add(Calendar.DAY_OF_YEAR, offset)
        }.timeInMillis

    /** Same title rules as the iOS widget: 今日足迹 / 昨日足迹 / M月d日. */
    fun titleFor(offset: Int, start: Long): String = when (offset) {
        0 -> "今日足迹"
        -1 -> "昨日足迹"
        else -> {
            val c = Calendar.getInstance().apply { timeInMillis = start }
            "${c.get(Calendar.MONTH) + 1}月${c.get(Calendar.DAY_OF_MONTH)}日"
        }
    }

    suspend fun load(context: Context, offset: Int): WidgetDayData {
        val clamped = offset.coerceIn(FootprintWidget.MIN_OFFSET, 0)
        val start = dayStart(clamped)
        val end = Calendar.getInstance().apply {
            timeInMillis = start
            add(Calendar.DAY_OF_YEAR, 1)
        }.timeInMillis
        val title = titleFor(clamped, start)
        val db = (context.applicationContext as? DiFangKeApp)?.database
            ?: DiFangKeApp.instance.database

        return try {
            val footprints = db.footprintDao().getForDay(Date(start), Date(end))
            val transports = db.transportRecordDao().getForDay(Date(start), Date(end))
            val places = db.placeDao().getAll()
            val activities = db.activityTypeDao().getAll()
            val userPlaces = places.filter { it.isUserDefined }.associateBy { it.placeID }

            val coords = footprints.mapNotNull { fp -> centerOf(fp)?.let { fp to it } }

            fun displayName(fp: FootprintEntity): String? {
                fp.placeID?.let { id -> userPlaces[id]?.name?.takeIf { it.isNotBlank() } }?.let { return it }
                val address = fp.address
                if (!address.isNullOrBlank() && address != "null" && address != "[]") return address
                return fp.title?.takeIf { it.isNotBlank() }
            }

            // Unique places: name → placeID → ~100 m grid (iOS daily summary rules).
            val uniqueKeys = coords.map { (fp, c) ->
                displayName(fp)?.let { "n:$it" }
                    ?: fp.placeID?.let { "p:$it" }
                    ?: "g:${(c.first * 1000).roundToInt()}_${(c.second * 1000).roundToInt()}"
            }.toSet()

            val dots = coords.map { (fp, c) ->
                val activity = activities.firstOrNull {
                    it.id == fp.activityTypeValue || it.name == fp.activityTypeValue
                }
                val color = activity?.colorHex?.let {
                    runCatching { android.graphics.Color.parseColor(it) }.getOrNull()
                } ?: DEFAULT_DOT_COLOR
                WidgetDot(c.first, c.second, color)
            }

            val polylines = transports.mapNotNull { t ->
                val pts = parsePoints(t.pointsJson)
                pts.takeIf { it.size >= 2 }
            }

            WidgetDayData(
                dayOffset = clamped,
                dayStartMillis = start,
                title = title,
                placeCount = uniqueKeys.size,
                // Sum of transport distances regardless of manual/auto type.
                mileageMeters = transports.sumOf { max(0.0, it.distance) },
                latestPlaceName = footprints.maxByOrNull { it.startTime.time }?.let { displayName(it) ?: "未知位置" },
                dots = dots,
                polylines = polylines
            )
        } catch (e: Exception) {
            WidgetDayData(clamped, start, title, 0, 0.0, null, emptyList(), emptyList())
        }
    }

    private fun centerOf(fp: FootprintEntity): Pair<Double, Double>? = try {
        val lats = gson.fromJson(fp.latitudeJson, Array<Double>::class.java)?.filter { it.isFinite() } ?: emptyList()
        val lons = gson.fromJson(fp.longitudeJson, Array<Double>::class.java)?.filter { it.isFinite() } ?: emptyList()
        if (lats.isEmpty() || lons.isEmpty()) null else lats.average() to lons.average()
    } catch (e: Exception) {
        null
    }

    private fun parsePoints(json: String): List<Pair<Double, Double>> = try {
        gson.fromJson(json, Array<DoubleArray>::class.java)
            ?.filter { it.size >= 2 && it[0].isFinite() && it[1].isFinite() }
            ?.map { it[0] to it[1] }
            ?: emptyList()
    } catch (e: Exception) {
        emptyList()
    }

    /**
     * Draws the day's track on a transparent bitmap (equirectangular projection fit to
     * bounds), so it reads on both light and dark widget backgrounds. The result is also
     * cached to filesDir/widget for debugging / reuse.
     */
    fun renderTrack(
        context: Context,
        data: WidgetDayData,
        widthPx: Int,
        heightPx: Int,
        isDark: Boolean
    ): Bitmap? {
        if (data.isEmpty || widthPx <= 0 || heightPx <= 0) return null
        val w = widthPx.coerceIn(64, 720)
        val h = heightPx.coerceIn(64, 720)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val density = context.resources.displayMetrics.density.coerceAtLeast(1f)

        val all = data.dots.map { it.lat to it.lon } + data.polylines.flatten()
        var minLat = all.minOf { it.first }
        var maxLat = all.maxOf { it.first }
        var minLon = all.minOf { it.second }
        var maxLon = all.maxOf { it.second }
        val midLat = (minLat + maxLat) / 2
        val lonScale = cos(Math.toRadians(midLat)).coerceAtLeast(0.01)

        // Minimum span ≈ 600 m so a single stay doesn't blow up.
        val minSpanDeg = 0.0055
        if (maxLat - minLat < minSpanDeg) {
            val c = (maxLat + minLat) / 2; minLat = c - minSpanDeg / 2; maxLat = c + minSpanDeg / 2
        }
        if ((maxLon - minLon) * lonScale < minSpanDeg) {
            val c = (maxLon + minLon) / 2
            val half = minSpanDeg / lonScale / 2
            minLon = c - half; maxLon = c + half
        }

        val pad = 18f * density
        val spanX = (maxLon - minLon) * lonScale
        val spanY = maxLat - minLat
        val scale = min((w - 2 * pad) / spanX, (h - 2 * pad) / spanY)
        val offX = (w - spanX * scale) / 2
        val offY = (h - spanY * scale) / 2
        fun project(lat: Double, lon: Double): Pair<Float, Float> {
            val x = offX + (lon - minLon) * lonScale * scale
            val y = offY + (maxLat - lat) * scale
            return x.toFloat() to y.toFloat()
        }

        val lineColor = if (isDark) 0xCC33B3BD.toInt() else 0xCC00A0AC.toInt()
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 3f * density
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = lineColor
        }
        data.polylines.forEach { line ->
            val path = Path()
            line.forEachIndexed { i, (lat, lon) ->
                val (x, y) = project(lat, lon)
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            canvas.drawPath(path, linePaint)
        }

        val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = if (isDark) 0xFF1C1C1E.toInt() else 0xFFFFFFFF.toInt()
        }
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        val r = 6f * density
        data.dots.forEach { dot ->
            val (x, y) = project(dot.lat, dot.lon)
            canvas.drawCircle(x, y, r + 2f * density, ring)
            fill.color = dot.color
            canvas.drawCircle(x, y, r, fill)
        }

        runCatching {
            val dir = File(context.filesDir, "widget").apply { mkdirs() }
            val file = File(dir, "track_${-data.dayOffset}_${if (isDark) "dark" else "light"}_${w}x$h.png")
            dir.listFiles()?.filter { it.name.startsWith("track_${-data.dayOffset}_") && it.name != file.name }
                ?.forEach { it.delete() }
            FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        return bitmap
    }
}
