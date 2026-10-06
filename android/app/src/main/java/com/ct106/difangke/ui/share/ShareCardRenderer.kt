package com.ct106.difangke.ui.share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import com.ct106.difangke.R
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Draws iOS DFKShareCardView onto a 1080-px wide bitmap with android.graphics.
 * All sizes are iOS points of the 1080-pt canvas (1 pt == 1 px here);
 * font sizes use iOS `fs(x) = x * 1.12`.
 */
internal object ShareCardRenderer {
    const val WIDTH = 1080
    private const val INSET = 68f
    private const val GAP = 84f
    private const val QR_SIDE = 144f
    private const val FOOTER_RESERVE = 220f
    private const val MAX_EXPORT_HEIGHT = 8192f
    private val contentWidth = WIDTH - INSET * 2

    private fun fs(x: Float) = x * 1.12f

    private val medium: Typeface by lazy { Typeface.create("sans-serif-medium", Typeface.NORMAL) }
    private val bold: Typeface = Typeface.DEFAULT_BOLD
    private val regular: Typeface = Typeface.DEFAULT

    private var qrBitmap: Bitmap? = null
    private var logoBitmap: Bitmap? = null

    private class Block(val height: Float, val draw: (Canvas, Float) -> Unit)

    // ── Text helpers ────────────────────────────────────────────────────────

    private fun text(
        value: String,
        size: Float,
        color: Int,
        typeface: Typeface,
        width: Float,
        maxLines: Int = Int.MAX_VALUE,
        minScale: Float = 1f,
        tabular: Boolean = false
    ): StaticLayout {
        val w = max(1, width.toInt())
        fun build(fontSize: Float, ellipsize: Boolean): StaticLayout {
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = fontSize
                this.color = color
                this.typeface = typeface
                if (tabular) fontFeatureSettings = "tnum"
            }
            val builder = StaticLayout.Builder.obtain(value, 0, value.length, paint, w)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setIncludePad(false)
            if (ellipsize && maxLines != Int.MAX_VALUE) {
                builder.setMaxLines(maxLines).setEllipsize(TextUtils.TruncateAt.END)
            }
            return builder.build()
        }
        if (maxLines == Int.MAX_VALUE) return build(size, false)
        var scale = 1f
        while (scale > minScale) {
            val layout = build(size * scale, false)
            if (layout.lineCount <= maxLines) return layout
            scale -= 0.04f
        }
        return build(size * minScale, true)
    }

    private fun StaticLayout.drawAt(canvas: Canvas, x: Float, y: Float) {
        canvas.save()
        canvas.translate(x, y)
        draw(canvas)
        canvas.restore()
    }

    private fun lineWidth(layout: StaticLayout): Float =
        (0 until layout.lineCount).maxOfOrNull { layout.getLineWidth(it) } ?: 0f

    // ── Public ──────────────────────────────────────────────────────────────

    fun render(context: Context, payload: SharePayload, theme: ShareCardTheme): Bitmap {
        if (qrBitmap == null) qrBitmap = BitmapFactory.decodeResource(context.resources, R.drawable.share_qr_code)
        if (logoBitmap == null) logoBitmap = BitmapFactory.decodeResource(context.resources, R.drawable.share_app_logo)

        val header = headerBlock(payload, theme)
        val content = when (payload.kind) {
            ShareCardKind.MOMENT -> momentBlocks(payload, theme)
            ShareCardKind.TIMELINE -> timelineBlocks(payload, theme)
            ShareCardKind.STATS -> statsBlocks(payload, theme)
        }
        val contentHeight = content.sumOf { it.height.toDouble() }.toFloat()
        val measured = INSET + header.height + GAP + contentHeight + INSET + FOOTER_RESERVE
        val locationExtra = if (payload.locationText == null) 0f else 64f
        val minimum = when (payload.kind) {
            ShareCardKind.STATS -> {
                val rows = max(2, payload.placeRankings.size + payload.activityRankings.size)
                max(2060f, 1160f + rows * 130f) + locationExtra
            }
            ShareCardKind.MOMENT -> (if (payload.photos.isNotEmpty()) 1970f else 1440f) + locationExtra
            ShareCardKind.TIMELINE -> 1080f + locationExtra
        }
        val height = ceil(max(minimum, measured)).toInt()
        val exportScale = min(1f, MAX_EXPORT_HEIGHT / height)
        val bitmap = Bitmap.createBitmap(
            max(1, (WIDTH * exportScale).toInt()),
            max(1, (height * exportScale).toInt()),
            Bitmap.Config.ARGB_8888
        )
        val canvas = Canvas(bitmap)
        canvas.scale(exportScale, exportScale)
        val h = height.toFloat()

        canvas.drawColor(theme.background)
        drawMapBackground(canvas, payload, theme, h)
        drawSubtleBackground(canvas, theme, h)

        canvas.save()
        canvas.clipRect(0f, 0f, WIDTH.toFloat(), h - INSET - FOOTER_RESERVE)
        var y = INSET
        header.draw(canvas, y)
        y += header.height + GAP
        content.forEach { block ->
            block.draw(canvas, y)
            y += block.height
        }
        canvas.restore()

        drawFooter(canvas, payload, theme, h)
        drawQrCode(canvas, theme, h)
        return bitmap
    }

    // ── Background ──────────────────────────────────────────────────────────

    private fun drawMapBackground(canvas: Canvas, payload: SharePayload, theme: ShareCardTheme, h: Float) {
        if (payload.kind == ShareCardKind.STATS) return
        val image = payload.backgroundMap?.forTheme(theme)
        val rect = RectF(0f, 0f, WIDTH.toFloat(), h)
        if (image != null) {
            val alpha = when (theme) { ShareCardTheme.JOURNAL -> 0.16; ShareCardTheme.DARK -> 0.30; else -> 0.38 }
            drawImageFill(canvas, image, rect, alpha)
            val overlay = when (theme) { ShareCardTheme.JOURNAL -> 0.68; ShareCardTheme.DARK -> 0.54; else -> 0.42 }
            canvas.drawRect(rect, Paint().apply { color = withAlpha(theme.background, overlay) })
        } else if (payload.coordinates.isNotEmpty()) {
            val alpha = when (theme) { ShareCardTheme.JOURNAL -> 0.10; ShareCardTheme.DARK -> 0.18; else -> 0.22 }
            canvas.saveLayerAlpha(rect, (alpha * 255).toInt())
            drawFallbackMap(canvas, payload.coordinates, theme, rect)
            canvas.restore()
            val overlay = when (theme) { ShareCardTheme.JOURNAL -> 0.72; ShareCardTheme.DARK -> 0.64; else -> 0.52 }
            canvas.drawRect(rect, Paint().apply { color = withAlpha(theme.background, overlay) })
        }
    }

    private fun drawSubtleBackground(canvas: Canvas, theme: ShareCardTheme, h: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val start = withAlpha(theme.accent, if (theme.usesDarkMap) 0.20 else 0.10)
        paint.shader = LinearGradient(WIDTH.toFloat(), 0f, WIDTH / 2f, h / 2f, start, 0, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, WIDTH.toFloat(), h, paint)
        if (theme == ShareCardTheme.JOURNAL) {
            val line = Paint().apply { color = withAlpha(0xFF000000.toInt(), 0.045); strokeWidth = 1f }
            var y = 54f
            while (y < h) { canvas.drawLine(0f, y, WIDTH.toFloat(), y, line); y += 54f }
        }
    }

    private fun drawImageFill(canvas: Canvas, image: Bitmap, rect: RectF, alpha: Double = 1.0) {
        val scale = max(rect.width() / image.width, rect.height() / image.height)
        val srcW = rect.width() / scale
        val srcH = rect.height() / scale
        val left = (image.width - srcW) / 2f
        val top = (image.height - srcH) / 2f
        val src = Rect(left.toInt(), top.toInt(), (left + srcW).toInt(), (top + srcH).toInt())
        canvas.drawBitmap(image, src, rect, Paint(Paint.FILTER_BITMAP_FLAG).apply { this.alpha = (alpha * 255).toInt() })
    }

    /** iOS DFKShareMapFallbackView. */
    private fun drawFallbackMap(canvas: Canvas, coordinates: List<GeoPoint>, theme: ShareCardTheme, rect: RectF) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(rect.left, rect.top, rect.right, rect.bottom,
            withAlpha(theme.accent, 0.20), withAlpha(theme.card, 0.45), Shader.TileMode.CLAMP)
        canvas.drawRect(rect, paint)
        paint.shader = null
        val points = normalizedPoints(coordinates).map { rect.left + it.first * rect.width() to rect.top + it.second * rect.height() }
        if (points.size > 1) {
            val path = Path().apply {
                moveTo(points[0].first, points[0].second)
                points.drop(1).forEach { lineTo(it.first, it.second) }
            }
            canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; strokeWidth = 7f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
                color = withAlpha(theme.accent, 0.45)
            })
        }
        paint.color = theme.accent
        points.forEach { canvas.drawCircle(it.first, it.second, 12f, paint) }
    }

    private fun normalizedPoints(coordinates: List<GeoPoint>): List<Pair<Float, Float>> {
        if (coordinates.isEmpty()) return listOf(0.28f to 0.46f, 0.58f to 0.34f, 0.72f to 0.62f)
        val source = coordinates.filter { it.isRenderable }.ifEmpty { coordinates }
        val minLat = source.minOf { it.lat }; val maxLat = source.maxOf { it.lat }
        val minLon = source.minOf { it.lon }; val maxLon = source.maxOf { it.lon }
        val latSpan = max(maxLat - minLat, 0.0001)
        val lonSpan = max(maxLon - minLon, 0.0001)
        return coordinates.take(40).map {
            (0.10 + (it.lon - minLon) / lonSpan * 0.80).toFloat() to (0.10 + (1 - (it.lat - minLat) / latSpan) * 0.80).toFloat()
        }
    }

    // ── Header ──────────────────────────────────────────────────────────────

    private fun headerBlock(payload: SharePayload, theme: ShareCardTheme): Block {
        val range = text(payload.rangeText, fs(40f), theme.secondary, medium, contentWidth, 1, 0.72f)
        val location = payload.locationText?.let { text(it, fs(34f), theme.secondary, medium, contentWidth, 1, 0.62f) }
        val title = text(payload.title, fs(84f), theme.foreground, bold, contentWidth)
        val spacing = 16f
        val height = range.height + (location?.let { spacing + it.height } ?: 0f) + spacing + title.height
        return Block(height) { canvas, top ->
            var y = top
            range.drawAt(canvas, INSET, y); y += range.height + spacing
            location?.let { it.drawAt(canvas, INSET, y); y += it.height + spacing }
            title.drawAt(canvas, INSET, y)
        }
    }

    // ── Kinds ───────────────────────────────────────────────────────────────

    private fun momentBlocks(payload: SharePayload, theme: ShareCardTheme): List<Block> = listOf(
        mediaBlock(payload, theme, 500f),
        spacer(30f)
    ) + entryBlocks(payload.entries.take(3), theme, isTimeline = false)

    private fun timelineBlocks(payload: SharePayload, theme: ShareCardTheme): List<Block> = listOf(
        mediaBlock(payload, theme, 340f),
        spacer(28f)
    ) + entryBlocks(payload.includedEntries, theme, isTimeline = true)

    private fun statsBlocks(payload: SharePayload, theme: ShareCardTheme): List<Block> = listOf(
        statsMapBlock(payload, theme),
        spacer(30f),
        statsSummaryBlock(payload, theme),
        spacer(30f),
        rankingBlock("最常去的地点", payload.placeRankings, theme, showsIcon = false),
        spacer(30f),
        rankingBlock("最喜欢的活动", payload.activityRankings, theme, showsIcon = true)
    )

    private fun spacer(height: Float) = Block(height) { _, _ -> }

    // ── Media ───────────────────────────────────────────────────────────────

    private fun mediaBlock(payload: SharePayload, theme: ShareCardTheme, height: Float): Block {
        val hasPhoto = payload.photos.isNotEmpty()
        val total = if (hasPhoto) height * 2 + 30f else height
        return Block(total) { canvas, top ->
            val outer = RectF(INSET, top, INSET + contentWidth, top + total)
            val clip = Path().apply { addRoundRect(outer, 28f, 28f, Path.Direction.CW) }
            canvas.save()
            canvas.clipPath(clip)
            if (hasPhoto) {
                drawPhotoStack(canvas, payload.photos, theme, RectF(outer.left, top, outer.right, top + height))
                val mapRect = RectF(outer.left, top + height + 30f, outer.right, top + total)
                canvas.save()
                canvas.clipPath(Path().apply {
                    addRoundRect(mapRect, floatArrayOf(28f, 28f, 28f, 28f, 0f, 0f, 0f, 0f), Path.Direction.CW)
                })
                drawMapLayer(canvas, payload, theme, mapRect)
                canvas.restore()
            } else {
                drawMapLayer(canvas, payload, theme, outer)
            }
            canvas.restore()
            canvas.drawPath(clip, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; strokeWidth = 1f
                color = withAlpha(0xFFFFFFFF.toInt(), if (theme.usesDarkMap) 0.08 else 0.35)
            })
        }
    }

    private fun drawMapLayer(canvas: Canvas, payload: SharePayload, theme: ShareCardTheme, rect: RectF) {
        val image = payload.contentMap?.forTheme(theme) ?: payload.backgroundMap?.forTheme(theme)
        if (image != null) drawImageFill(canvas, image, rect) else drawFallbackMap(canvas, payload.coordinates, theme, rect)
    }

    private val rotations = floatArrayOf(-7f, 4.5f, -3f, 8f, -5.5f, 2f, -8.5f, 6f, -1f, 5f, 7.5f, -4f, 3f, -7.5f, 5.5f, -2f, 8.5f, -6f, 1.5f, 4f)

    /** iOS DFKSharePhotoStackView. */
    private fun drawPhotoStack(canvas: Canvas, photos: List<Bitmap>, theme: ShareCardTheme, rect: RectF) {
        val count = min(photos.size, 20)
        val w = rect.width(); val h = rect.height()
        val cardW = w * when { count <= 2 -> 0.70f; count <= 5 -> 0.56f; count <= 10 -> 0.28f; else -> 0.22f }
        val cardH = h * when { count <= 5 -> 0.76f; count <= 10 -> 0.42f; else -> 0.34f }
        val positions: List<Pair<Float, Float>> = when (count) {
            1 -> listOf(0.5f to 0.5f)
            2 -> listOf(0.37f to 0.57f, 0.65f to 0.43f)
            3 -> listOf(0.30f to 0.62f, 0.60f to 0.38f, 0.70f to 0.67f)
            in 4..5 -> listOf(0.21f to 0.35f, 0.53f to 0.27f, 0.77f to 0.48f, 0.36f to 0.70f, 0.69f to 0.75f)
            else -> listOf(
                0.16f to 0.21f, 0.46f to 0.14f, 0.78f to 0.24f, 0.30f to 0.38f, 0.64f to 0.39f, 0.13f to 0.55f,
                0.49f to 0.56f, 0.85f to 0.58f, 0.26f to 0.75f, 0.70f to 0.78f, 0.11f to 0.32f, 0.59f to 0.20f,
                0.89f to 0.42f, 0.40f to 0.65f, 0.18f to 0.88f, 0.54f to 0.88f, 0.86f to 0.86f, 0.36f to 0.25f,
                0.72f to 0.67f, 0.44f to 0.45f
            )
        }
        photos.take(count).forEachIndexed { index, photo ->
            val aspect = photo.width.toFloat() / max(1, photo.height)
            val (pw, ph) = if (aspect > cardW / cardH) cardW to cardW / aspect else cardH * aspect to cardH
            val safety = max(36f, ph * 0.14f)
            val px = rect.left + w * positions[index].first
            val rawY = rect.top + h * positions[index].second
            val py = min(max(rawY, rect.top + ph / 2 + safety), rect.bottom - ph / 2 - safety)
            canvas.save()
            canvas.rotate(rotations[index % rotations.size], px, py)
            val photoRect = RectF(px - pw / 2, py - ph / 2, px + pw / 2, py + ph / 2)
            canvas.drawRoundRect(photoRect, 24f, 24f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = theme.background
                setShadowLayer(18f, 0f, 12f, withAlpha(0xFF000000.toInt(), if (theme.usesDarkMap) 0.30 else 0.16))
            })
            canvas.save()
            canvas.clipPath(Path().apply { addRoundRect(photoRect, 24f, 24f, Path.Direction.CW) })
            canvas.drawBitmap(photo, null, photoRect, Paint(Paint.FILTER_BITMAP_FLAG))
            canvas.restore()
            canvas.drawRoundRect(photoRect, 24f, 24f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; strokeWidth = 8f
                color = withAlpha(0xFFFFFFFF.toInt(), if (theme.usesDarkMap) 0.16 else 0.72)
            })
            canvas.restore()
        }
    }

    // ── Entries ─────────────────────────────────────────────────────────────

    private fun entryBlocks(entries: List<ShareEntry>, theme: ShareCardTheme, isTimeline: Boolean): List<Block> {
        val markerSide = if (isTimeline) 48f else 36f
        val connector = if (isTimeline) 88f else 66f
        val textX = INSET + markerSide + 20f
        val textWidth = contentWidth - markerSide - 20f
        return entries.flatMap { entry ->
            val blocks = mutableListOf<Block>()
            if (isTimeline && entry.dayDividerText != null) {
                val label = text(entry.dayDividerText, fs(30f), theme.secondary, bold, contentWidth, 1)
                val labelWidth = lineWidth(label)
                blocks += Block(24f + label.height + 8f) { canvas, top ->
                    val y = top + 24f
                    val midY = y + label.height / 2f
                    val lineW = (contentWidth - labelWidth - 32f) / 2f
                    val paint = Paint().apply { color = withAlpha(theme.secondary, 0.28); strokeWidth = 2f }
                    canvas.drawLine(INSET, midY, INSET + lineW, midY, paint)
                    label.drawAt(canvas, INSET + lineW + 16f, y)
                    canvas.drawLine(INSET + lineW + 32f + labelWidth, midY, INSET + contentWidth, midY, paint)
                }
            }
            val time = text(entry.time, fs(if (isTimeline) 36f else 30f), theme.secondary, medium, textWidth, 1, tabular = true)
            val title = text(entry.title, fs(if (isTimeline) 60f else 72f), theme.foreground, medium, textWidth, 2, 0.72f)
            val detail = entry.detail?.takeIf { it.isNotEmpty() }
                ?.let { text(it, fs(if (isTimeline) 42f else 36f), theme.secondary, regular, textWidth, 2, 0.76f) }
            val textHeight = time.height + 8f + title.height + (detail?.let { 8f + it.height } ?: 0f)
            val topPad = if (isTimeline) 16f else 0f
            val rowHeight = topPad + max(textHeight.toFloat(), markerSide + connector) + 20f
            blocks += Block(rowHeight) { canvas, top ->
                val y = top + topPad
                val color = entry.activityColor ?: theme.accent
                val cx = INSET + markerSide / 2f
                canvas.drawCircle(cx, y + markerSide / 2f, markerSide / 2f, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
                ShareIconPainter.draw(canvas, entry.activityIcon ?: "place", cx, y + markerSide / 2f,
                    fs(if (isTimeline) 24f else 18f) * 1.25f, 0xFFFFFFFF.toInt())
                canvas.drawRect(cx - 1.5f, y + markerSide, cx + 1.5f, y + markerSide + connector,
                    Paint().apply { this.color = withAlpha(theme.accent, 0.28) })
                var ty = y
                time.drawAt(canvas, textX, ty); ty += time.height + 8f
                title.drawAt(canvas, textX, ty); ty += title.height
                detail?.let { ty += 8f; it.drawAt(canvas, textX, ty) }
            }
            blocks
        }
    }

    // ── Stats ───────────────────────────────────────────────────────────────

    private fun statsMapBlock(payload: SharePayload, theme: ShareCardTheme): Block = Block(460f) { canvas, top ->
        val rect = RectF(INSET, top, INSET + contentWidth, top + 460f)
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(rect, 26f, 26f, Path.Direction.CW) })
        val image = payload.contentMap?.forTheme(theme)
        if (image != null) drawImageFill(canvas, image, rect) else drawFallbackMap(canvas, payload.coordinates, theme, rect)
        canvas.restore()
    }

    private fun statsSummaryBlock(payload: SharePayload, theme: ShareCardTheme): Block {
        val stats = payload.stats.take(3)
        val columnWidth = contentWidth / max(1, stats.size)
        val values = stats.map { text(it.value, fs(42f), theme.accent, bold, columnWidth, 1, 0.6f) }
        val labels = stats.map { text(it.label, fs(21f), theme.secondary, medium, columnWidth, 1) }
        val inner = (values.maxOfOrNull { it.height } ?: 0) + 5f + (labels.maxOfOrNull { it.height } ?: 0)
        val height = 18f + inner + 18f
        return Block(height) { canvas, top ->
            canvas.drawRoundRect(RectF(INSET, top, INSET + contentWidth, top + height), 22f, 22f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.card })
            stats.indices.forEach { i ->
                val colLeft = INSET + i * columnWidth
                val v = values[i]; val l = labels[i]
                v.drawAt(canvas, colLeft + (columnWidth - lineWidth(v)) / 2f, top + 18f)
                l.drawAt(canvas, colLeft + (columnWidth - lineWidth(l)) / 2f, top + 18f + v.height + 5f)
                if (i < stats.size - 1) {
                    val x = colLeft + columnWidth
                    canvas.drawRect(x, top + height / 2 - 26f, x + 1f, top + height / 2 + 26f,
                        Paint().apply { color = withAlpha(theme.secondary, 0.25) })
                }
            }
        }
    }

    private fun rankingBlock(title: String, entries: List<ShareRankingEntry>, theme: ShareCardTheme, showsIcon: Boolean): Block {
        val inner = contentWidth - 52f
        val heading = text(title, fs(38f), theme.foreground, bold, inner)
        class Row(val index: StaticLayout, val title: StaticLayout, val detail: StaticLayout?, val value: StaticLayout, val entry: ShareRankingEntry) {
            val height: Float get() = max(max(index.height, value.height).toFloat(), this.title.height + (this.detail?.let { 4f + it.height } ?: 0f))
        }
        val rows = entries.take(3).mapIndexed { i, entry ->
            val value = text(entry.value, fs(28f), theme.accent, bold, inner / 2, 1)
            val titleWidth = inner - 34f - 18f - (if (showsIcon) 36f + 18f else 0f) - lineWidth(value) - 12f
            Row(
                text("${i + 1}", fs(30f), theme.accent, bold, 60f, 1),
                text(entry.title, fs(34f), theme.foreground, medium, titleWidth, 1),
                entry.detail?.takeIf { it.isNotEmpty() }?.let { text(it, fs(22f), theme.secondary, regular, titleWidth, 1) },
                value,
                entry
            )
        }
        val height = 26f + heading.height + 16f + rows.sumOf { (24f + it.height).toDouble() }.toFloat() +
            (if (rows.isNotEmpty()) 0f else 0f) + 26f
        return Block(height) { canvas, top ->
            canvas.drawRoundRect(RectF(INSET, top, INSET + contentWidth, top + height), 22f, 22f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.card })
            val left = INSET + 26f
            heading.drawAt(canvas, left, top + 26f)
            var y = top + 26f + heading.height + 16f
            rows.forEach { row ->
                val rowTop = y + 12f
                val mid = rowTop + row.height / 2f
                row.index.drawAt(canvas, left, mid - row.index.height / 2f)
                var x = left + 34f + 18f
                if (showsIcon) {
                    ShareIconPainter.draw(canvas, row.entry.icon, x + 18f, mid, fs(26f) * 1.2f, row.entry.color)
                    x += 36f + 18f
                }
                val textBlock = row.title.height + (row.detail?.let { 4f + it.height } ?: 0f)
                row.title.drawAt(canvas, x, mid - textBlock / 2f)
                row.detail?.drawAt(canvas, x, mid - textBlock / 2f + row.title.height + 4f)
                row.value.drawAt(canvas, INSET + contentWidth - 26f - lineWidth(row.value), mid - row.value.height / 2f)
                y += 24f + row.height
            }
        }
    }

    // ── Footer & QR ─────────────────────────────────────────────────────────

    private fun drawFooter(canvas: Canvas, payload: SharePayload, theme: ShareCardTheme, h: Float) {
        val logoSize = 120f
        val logoTop = h - INSET - logoSize
        logoBitmap?.let { logo ->
            val rect = RectF(INSET, logoTop, INSET + logoSize, logoTop + logoSize)
            val aspect = logo.width.toFloat() / logo.height
            val fitted = if (aspect > 1) RectF(rect.left, rect.centerY() - logoSize / aspect / 2, rect.right, rect.centerY() + logoSize / aspect / 2)
            else RectF(rect.centerX() - logoSize * aspect / 2, rect.top, rect.centerX() + logoSize * aspect / 2, rect.bottom)
            canvas.save()
            canvas.clipPath(Path().apply { addRoundRect(rect, 22f, 22f, Path.Direction.CW) })
            canvas.drawBitmap(logo, null, fitted, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
            canvas.restore()
        }
        val textWidth = contentWidth - logoSize - 24f - 164f
        val name = text(payload.brandName, fs(52f), theme.foreground, medium, textWidth, 1, 0.72f)
        val slogan = text(payload.brandSlogan, fs(38f), theme.secondary, regular, textWidth, 1, 0.72f)
        val block = name.height + 8f + slogan.height
        val top = logoTop + (logoSize - block) / 2f
        val x = INSET + logoSize + 24f
        name.drawAt(canvas, x, top)
        slogan.drawAt(canvas, x, top + name.height + 8f)
    }

    private fun drawQrCode(canvas: Canvas, theme: ShareCardTheme, h: Float) {
        val rect = RectF(WIDTH - INSET - QR_SIDE, h - INSET - QR_SIDE, WIDTH - INSET, h - INSET)
        canvas.drawRoundRect(rect, 16f, 16f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = withAlpha(0xFFFFFFFF.toInt(), 0.98)
            setShadowLayer(10f, 0f, 4f, withAlpha(0xFF000000.toInt(), if (theme.usesDarkMap) 0.24 else 0.10))
        })
        qrBitmap?.let {
            val inner = RectF(rect.left + 9f, rect.top + 9f, rect.right - 9f, rect.bottom - 9f)
            canvas.drawBitmap(it, null, inner, Paint(Paint.FILTER_BITMAP_FLAG))
        }
        canvas.drawRoundRect(rect, 16f, 16f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 1f; color = withAlpha(0xFF000000.toInt(), 0.08)
        })
    }
}
