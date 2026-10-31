package com.ct106.difangke.ui.screens.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Place
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.model.FootprintStatus
import com.ct106.difangke.ui.components.FootprintPhotoThumbnail
import com.ct106.difangke.ui.screens.detail.PhotoPagerViewer
import com.ct106.difangke.ui.screens.detail.photoTakenDate
import com.ct106.difangke.ui.screens.history.HistoryFavoritesView
import com.ct106.difangke.ui.share.photoUris
import com.ct106.difangke.ui.share.shareCenter
import com.ct106.difangke.ui.theme.DfkAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

private val weekdaySymbols = listOf("一", "二", "三", "四", "五", "六", "日")

// ── Shared presentation ──────────────────────────────────────────────────

/** iOS NavigationStack sheet with an inline title and a trailing ✕. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReviewDialogScaffold(
    title: String,
    onDismiss: () -> Unit,
    background: Color = reviewDetailBackground(),
    content: @Composable () -> Unit
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = background) {
            Column(Modifier.fillMaxSize()) {
                CenterAlignedTopAppBar(
                    title = { Text(title, fontWeight = FontWeight.Bold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    actions = {
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "关闭") }
                    },
                    colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = background)
                )
                Box(Modifier.fillMaxSize()) { content() }
            }
        }
    }
}

@Composable
private fun ReviewCard(
    modifier: Modifier = Modifier,
    radius: Int = 22,
    padding: Int = 16,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(radius.dp))
            .background(reviewDetailCard())
            .padding(padding.dp),
        content = content
    )
}

@Composable
private fun ReviewCardTitle(title: String, icon: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(reviewIcon(icon), null, tint = DfkAccent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** iOS review*MetricCard. */
@Composable
private fun ReviewMetricCard(title: String, value: String, icon: String, modifier: Modifier = Modifier) {
    ReviewCard(modifier, radius = 18) {
        Icon(reviewIcon(icon), null, tint = DfkAccent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.height(8.dp))
        Text(value, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(8.dp))
        Text(title, fontSize = 12.sp, color = reviewSecondaryText())
    }
}

@Composable
private fun ReviewMetricGrid(cards: List<Triple<String, String, String>>) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        cards.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.height(IntrinsicSize.Max)) {
                row.forEach { (title, value, icon) ->
                    ReviewMetricCard(title, value, icon, Modifier.weight(1f).fillMaxHeight())
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** iOS reviewDetailRow inside reviewDetailListStyle. */
@Composable
private fun ReviewDetailList(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(reviewDetailCard())
            .padding(horizontal = 16.dp),
        content = content
    )
}

@Composable
private fun ReviewDetailRow(icon: String, color: Color, title: String, value: String, subtitle: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(reviewIcon(icon), null, tint = color, modifier = Modifier.width(24.dp).size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
            Text(subtitle, fontSize = 12.sp, color = reviewSecondaryText())
        }
        Text(value, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    }
}

private data class ReviewBarValue(val name: String, val icon: String, val color: Color, val value: Double, val valueText: String)

/** iOS reviewActivityHorizontalBars / reviewTransportHorizontalBars. */
@Composable
private fun ReviewHorizontalBars(title: String, icon: String, values: List<ReviewBarValue>) {
    val ranked = values.sortedWith(compareByDescending<ReviewBarValue> { it.value }.thenBy { it.name })
    val maximum = max(1.0, ranked.firstOrNull()?.value ?: 1.0)
    ReviewCard {
        ReviewCardTitle(title, icon)
        ranked.take(6).forEach { item ->
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(reviewIcon(item.icon), null, tint = item.color, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text(item.name, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(item.valueText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = reviewSecondaryText())
            }
            Spacer(Modifier.height(6.dp))
            BoxWithConstraints(Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)).background(item.color.copy(alpha = 0.14f))) {
                Box(
                    Modifier
                        .width(max(5f, maxWidth.value * (item.value / maximum).toFloat()).dp)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(4.dp))
                        .background(item.color)
                )
            }
        }
    }
}

private data class ReviewHeatmapRow(val name: String, val color: Color, val counts: List<Int>)

/** iOS reviewActivityWeekdayHeatmap / reviewTransportWeekdayHeatmap. */
@Composable
private fun ReviewWeekdayHeatmap(title: String, rows: List<ReviewHeatmapRow>) {
    val maximum = max(1, rows.flatMap { it.counts }.maxOrNull() ?: 1)
    ReviewCard {
        ReviewCardTitle(title, "calendar")
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Spacer(Modifier.width(72.dp))
            weekdaySymbols.forEach { symbol ->
                Text(symbol, fontSize = 11.sp, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        rows.forEach { row ->
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(row.name, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(72.dp))
                row.counts.forEach { count ->
                    val alpha = if (count == 0) 0.08f else 0.20f + 0.80f * count / maximum
                    Box(
                        Modifier
                            .weight(1f)
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(4.dp))
                            .background(row.color.copy(alpha = alpha))
                    )
                }
            }
        }
    }
}

@Composable
private fun ReviewHourAxis(fontSize: Int = 11) {
    Row(Modifier.fillMaxWidth()) {
        listOf("0时", "6时", "12时", "18时", "24时").forEachIndexed { index, label ->
            if (index > 0) Spacer(Modifier.weight(1f))
            Text(label, fontSize = fontSize.sp, color = reviewSecondaryText())
        }
    }
}

/** iOS reviewActivityHourlyRhythms / reviewTransportHourlyRhythms. */
@Composable
private fun ReviewHourlyRhythms(title: String, rows: List<ReviewHeatmapRow>) {
    ReviewCard {
        ReviewCardTitle(title, "clock")
        rows.forEach { row ->
            Spacer(Modifier.height(16.dp))
            val maximum = max(1, row.counts.maxOrNull() ?: 1)
            Text(row.name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth().height(34.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
                row.counts.forEach { value ->
                    val alpha = if (value == 0) 0.08f else 0.30f + 0.70f * value / maximum
                    Box(
                        Modifier
                            .weight(1f)
                            .height(max(3f, 34f * value / maximum).dp)
                            .clip(RoundedCornerShape(50))
                            .background(row.color.copy(alpha = alpha))
                    )
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        ReviewHourAxis()
    }
}

/** Weekday capsule columns with a value label (iOS reviewRhythmWeekdayChart / reviewMileageWeekdayChart / placeWeekdayChart). */
@Composable
private fun ReviewWeekdayColumns(values: List<Double>, labels: List<String>, barHeight: Float, minimumHeight: Float, zeroAlpha: Float = 0.38f) {
    val maximum = values.maxOrNull()?.takeIf { it > 0 } ?: 1.0
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
        values.forEachIndexed { index, value ->
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(labels[index], fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = reviewSecondaryText(), maxLines = 1, softWrap = false)
                val color = when {
                    value == maximum && value > 0 -> DfkAccent
                    value == 0.0 -> DfkAccent.copy(alpha = zeroAlpha)
                    else -> DfkAccent.copy(alpha = 0.38f)
                }
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(max(minimumHeight, (barHeight * value / maximum).toFloat()).dp)
                        .clip(RoundedCornerShape(50))
                        .background(color)
                )
                Text(weekdaySymbols[index], fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

/** iOS placeBarCanvas / reviewMileageDailyChart bars. */
@Composable
private fun ReviewBarCanvas(values: List<Double>, modifier: Modifier, denseThreshold: Int, denseSpacing: Float, spacing: Float, zeroHeight: Float, minimumHeight: Float, zeroColor: Color? = null, secondaryAlpha: Float = 0.38f) {
    Canvas(modifier) {
        if (values.isEmpty() || size.width <= 0f || size.height <= 0f) return@Canvas
        val maximum = max(1.0, values.maxOrNull() ?: 1.0)
        val gap = (if (values.size > denseThreshold) denseSpacing else spacing).dp.toPx()
        val barWidth = max(0.5f, (size.width - gap * (values.size - 1)) / values.size)
        values.forEachIndexed { index, value ->
            val height = if (value == 0.0) zeroHeight.dp.toPx() else max(minimumHeight.dp.toPx(), size.height * (value / maximum).toFloat())
            val color = when {
                value == 0.0 -> zeroColor ?: DfkAccent.copy(alpha = 0.10f)
                value == maximum -> DfkAccent
                else -> DfkAccent.copy(alpha = secondaryAlpha)
            }
            val corner = min(barWidth / 2, 4.dp.toPx())
            drawRoundRect(color, Offset(index * (barWidth + gap), size.height - height), Size(barWidth, height), CornerRadius(corner, corner))
        }
    }
}

// ── Bento details ────────────────────────────────────────────────────────

/** iOS reviewBentoDetailView. */
@Composable
internal fun ReviewBentoDetailDialog(detail: ReviewBentoDetail, snapshot: ReviewSnapshot, onDismiss: () -> Unit) {
    var selectedPlace by remember { mutableStateOf<ReviewPlaceSelection?>(null) }
    var selectedPlaceList by remember { mutableStateOf<ReviewPlaceListSelection?>(null) }

    ReviewDialogScaffold("${snapshot.rangeText} · ${detail.title}", onDismiss) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            Text(snapshot.rangeText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent)
            when (detail) {
                ReviewBentoDetail.ACTIVITY -> ReviewActivityDetail(snapshot)
                ReviewBentoDetail.RHYTHM -> ReviewRhythmDetail(snapshot)
                ReviewBentoDetail.TRANSPORT -> ReviewTransportDetail(snapshot)
                ReviewBentoDetail.REGIONS -> ReviewRegionsDetail(snapshot) { item, scope ->
                    // iOS openReviewRegionItem.
                    val places = snapshot.placeSelections(item.footprintIDs)
                    if (places.isEmpty()) return@ReviewRegionsDetail
                    if (scope == FrequentPlaceRankScope.PLACE) selectedPlace = places.first()
                    else selectedPlaceList = ReviewPlaceListSelection("${scope.label}:${item.id}", item.name, places)
                }
            }
        }
    }
    selectedPlace?.let { ReviewPlaceDialog(it, onDismiss = { selectedPlace = null }) }
    selectedPlaceList?.let { ReviewPlaceListSheet(it, onDismiss = { selectedPlaceList = null }) }
}

@Composable
private fun ReviewActivityDetail(snapshot: ReviewSnapshot) {
    val slices = snapshot.activitySlices
    val total = max(1.0, slices.sumOf { it.duration })
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReviewActivityDonut(slices, total)

        if (slices.isNotEmpty()) {
            ReviewDetailList {
                slices.forEach { slice ->
                    ReviewDetailRow(
                        slice.icon, slice.color, slice.name, formatRankDuration(slice.duration),
                        "占停留时间 ${(slice.duration / total * 100).roundToInt()}%"
                    )
                }
            }
        }

        val visits = snapshot.recognizedFootprintCount
        val totalDuration = slices.sumOf { it.duration }
        val dominantShare = if (totalDuration > 0) ((slices.firstOrNull()?.duration ?: 0.0) / totalDuration * 100).roundToInt() else 0
        val averageDuration = if (visits == 0) 0.0 else totalDuration / visits
        ReviewMetricGrid(listOf(
            Triple("活动类型", "${slices.size}种", "square.grid.2x2.fill"),
            Triple("活动记录", "${visits}次", "list.number"),
            Triple("单次平均", formatRankDuration(averageDuration), "timer"),
            Triple("头部活动占比", "$dominantShare%", "chart.pie.fill")
        ))

        ReviewHorizontalBars("各类型发生次数", "chart.bar.xaxis", slices.map {
            val count = snapshot.activityVisitCount(it.name)
            ReviewBarValue(it.name, it.icon, it.color, count.toDouble(), "${count}次")
        })
        ReviewHorizontalBars("单次平均停留", "hourglass", slices.map {
            val average = it.duration / max(1, snapshot.activityVisitCount(it.name))
            ReviewBarValue(it.name, it.icon, it.color, average, formatRankDuration(average))
        })
        ReviewWeekdayHeatmap("星期 × 活动", slices.take(5).map {
            ReviewHeatmapRow(it.name, it.color, snapshot.activityWeekdayCounts(it.name))
        })
        ReviewHourlyRhythms("活动发生时刻", slices.take(4).map {
            ReviewHeatmapRow(it.name, it.color, snapshot.activityHourlyCounts(it.name))
        })
    }
}

/** iOS reviewActivityDetail donut: arcs with leader lines to labels on both sides. */
@Composable
private fun ReviewActivityDonut(slices: List<ReviewActivitySlice>, total: Double) {
    val measurer = rememberTextMeasurer()
    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(reviewDetailCard()).padding(vertical = 18.dp)) {
        Canvas(Modifier.fillMaxWidth().height(290.dp)) {
            val lineWidth = 24.dp.toPx()
            val center = Offset(size.width / 2, size.height / 2)
            val radius = max(0f, min(size.width * 0.23f, size.height * 0.30f))
            class Label(val slice: ReviewActivitySlice, val angle: Double, var y: Float)
            val left = mutableListOf<Label>()
            val right = mutableListOf<Label>()
            var start = -90.0
            slices.forEach { slice ->
                val sweep = 360 * slice.duration / total
                val middle = Math.toRadians(start + sweep / 2)
                drawArc(
                    slice.color, start.toFloat(), sweep.toFloat(), useCenter = false,
                    topLeft = Offset(center.x - radius, center.y - radius), size = Size(radius * 2, radius * 2),
                    style = Stroke(lineWidth)
                )
                val targetY = center.y + sin(middle).toFloat() * (radius + 34.dp.toPx())
                (if (cos(middle) < 0) left else right).add(Label(slice, middle, targetY))
                start += sweep
            }
            fun arranged(labels: List<Label>): List<Label> {
                if (labels.isEmpty()) return labels
                val result = labels.sortedBy { it.y }
                val minimumY = 18.dp.toPx()
                val maximumY = size.height - 18.dp.toPx()
                val gap = min(28.dp.toPx(), (maximumY - minimumY) / max(1, result.size - 1))
                result[0].y = max(minimumY, result[0].y)
                for (index in 1 until result.size) result[index].y = max(result[index].y, result[index - 1].y + gap)
                val overflow = result.last().y - maximumY
                if (overflow > 0) result.forEach { it.y -= overflow }
                return result
            }
            listOf(true to arranged(left), false to arranged(right)).forEach { (isLeft, labels) ->
                labels.forEach { label ->
                    val direction = if (isLeft) -1f else 1f
                    val lineStart = Offset(
                        center.x + cos(label.angle).toFloat() * (radius + lineWidth / 2),
                        center.y + sin(label.angle).toFloat() * (radius + lineWidth / 2)
                    )
                    val elbow = Offset(center.x + direction * (radius + 32.dp.toPx()), label.y)
                    val percent = (label.slice.duration / total * 100).roundToInt()
                    val layout = measurer.measure(
                        "${label.slice.name} $percent%",
                        TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = label.slice.color),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        constraints = Constraints(maxWidth = (size.width * 0.34f).toInt())
                    )
                    val lineEnd = Offset(
                        if (isLeft) 14.dp.toPx() + layout.size.width else size.width - 14.dp.toPx() - layout.size.width,
                        label.y
                    )
                    val leader = Path().apply { moveTo(lineStart.x, lineStart.y); lineTo(elbow.x, elbow.y); lineTo(lineEnd.x, lineEnd.y) }
                    drawPath(leader, label.slice.color.copy(alpha = 0.8f), style = Stroke(1.dp.toPx()))
                    val textX = if (isLeft) 8.dp.toPx() else size.width - 8.dp.toPx() - layout.size.width
                    drawText(layout, topLeft = Offset(textX, label.y - 3.dp.toPx() - layout.size.height / 2f))
                }
            }
        }
    }
}

@Composable
private fun ReviewTransportDetail(snapshot: ReviewSnapshot) {
    val slices = snapshot.transportSlices
    val total = max(1, slices.sumOf { it.count })
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        if (slices.isNotEmpty()) {
            ReviewDetailList {
                slices.forEach { slice ->
                    ReviewDetailRow(
                        slice.icon, slice.color, slice.name, "${slice.count}次",
                        "占出行次数 ${(slice.count.toDouble() / total * 100).roundToInt()}% · ${formatRankMileage(slice.distance)}"
                    )
                }
            }
        }
        val totalCount = slices.sumOf { it.count }
        val totalDistance = slices.sumOf { it.distance }
        val averageDistance = if (totalCount == 0) 0.0 else totalDistance / totalCount
        val dominantShare = if (totalCount == 0) 0 else ((slices.firstOrNull()?.count ?: 0).toDouble() / totalCount * 100).roundToInt()
        ReviewMetricGrid(listOf(
            Triple("交通方式", "${slices.size}种", "square.grid.2x2.fill"),
            Triple("路程总数", "${totalCount}段", "point.bottomleft.forward.to.point.topright.scurvepath"),
            Triple("单程平均", formatRankMileage(averageDistance), "ruler"),
            Triple("常用方式占比", "$dominantShare%", "chart.pie.fill")
        ))
        ReviewHorizontalBars("使用天数", "calendar", slices.map {
            val days = snapshot.transportActiveDays(it.id)
            ReviewBarValue(it.name, it.icon, it.color, days.toDouble(), "${days}天")
        })
        ReviewHorizontalBars("累计里程", "road.lanes", slices.map {
            ReviewBarValue(it.name, it.icon, it.color, it.distance, formatRankMileage(it.distance))
        })
        ReviewHorizontalBars("平均单程距离", "ruler", slices.map {
            val average = if (it.count == 0) 0.0 else it.distance / it.count
            ReviewBarValue(it.name, it.icon, it.color, average, formatRankMileage(average))
        })
        ReviewWeekdayHeatmap("星期 × 交通方式", slices.take(5).map {
            ReviewHeatmapRow(it.name, it.color, snapshot.transportWeekdayCounts(it.id))
        })
        ReviewHourlyRhythms("交通发生时刻", slices.take(4).map {
            ReviewHeatmapRow(it.name, it.color, snapshot.transportHourlyCounts(it.id))
        })
    }
}

@Composable
private fun ReviewRhythmDetail(snapshot: ReviewSnapshot) {
    val mileage = snapshot.mileage
    val emptyColor = reviewEmptyCell()
    val screenWidth = LocalConfiguration.current.screenWidthDp
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("从每日里程、星期、时刻、趋势和连续性观察这段时间的出行节奏。", fontSize = 15.sp, color = reviewSecondaryText())

        // iOS reviewMileageDailyHeatmap with its balanced column count and capped cell size.
        ReviewCard {
            ReviewCardTitle("每日里程热度", "square.grid.3x3.fill")
            Spacer(Modifier.height(14.dp))
            val values = mileage.dailyValues.map { it.distance.roundToInt() }
            val columnCount = if (values.isEmpty()) 1 else min(values.size, max(7, ceil(sqrt(values.size * 1.15)).toInt()))
            val spacing = if (values.size > 100) 1.5f else 3f
            val rowCount = if (values.isEmpty()) 0 else ceil(values.size / columnCount.toDouble()).toInt()
            val availableWidth = max(1f, min(screenWidth - 72f, 700f))
            val cellSide = min(18f, max(1f, (availableWidth - spacing * (columnCount - 1)) / columnCount))
            val height = if (values.isEmpty()) 0f else rowCount * cellSide + max(0, rowCount - 1) * spacing
            ReviewDailyHeatmap(values, Modifier.fillMaxWidth().height(height.dp), preferredColumnCount = columnCount)
        }

        ReviewMetricGrid(listOf(
            Triple("总里程", formatRankMileage(mileage.total), "road.lanes"),
            Triple("日均里程", formatRankMileage(mileage.dailyAverage), "divide"),
            Triple("单日最高", formatRankMileage(mileage.peakDay?.distance ?: 0.0), "arrow.up.right"),
            Triple("有里程记录", "${mileage.activeDayCount}天", "calendar.badge.checkmark")
        ))

        ReviewCard {
            ReviewCardTitle("每日里程", "chart.bar.xaxis")
            Spacer(Modifier.height(14.dp))
            ReviewBarCanvas(
                mileage.dailyValues.map { it.distance }, Modifier.fillMaxWidth().height(110.dp),
                denseThreshold = 100, denseSpacing = 0.5f, spacing = 3f, zeroHeight = 5f, minimumHeight = 5f,
                zeroColor = emptyColor, secondaryAlpha = 0.42f
            )
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth()) {
                Text(mileage.dailyValues.firstOrNull()?.date?.let(::reviewMonthDay).orEmpty(), fontSize = 12.sp, color = reviewSecondaryText())
                Spacer(Modifier.weight(1f))
                mileage.peakDay?.let {
                    Text("最高：${reviewMonthDay(it.date)} · ${formatRankMileage(it.distance)}", fontSize = 12.sp, color = reviewSecondaryText())
                }
                Spacer(Modifier.weight(1f))
                Text(mileage.dailyValues.lastOrNull()?.date?.let(::reviewMonthDay).orEmpty(), fontSize = 12.sp, color = reviewSecondaryText())
            }
        }

        ReviewCard {
            val values = mileage.weekdayAverages
            val peak = values.indices.maxByOrNull { values[it] }
            Row(verticalAlignment = Alignment.CenterVertically) {
                ReviewCardTitle("星期平均里程", "calendar", Modifier.weight(1f))
                if (peak != null && values[peak] > 0) {
                    Text("周${weekdaySymbols[peak]}最多", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent)
                }
            }
            Spacer(Modifier.height(14.dp))
            ReviewWeekdayColumns(values, values.map(::formatRankMileage), barHeight = 92f, minimumHeight = 8f)
        }

        Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("足迹活跃分析", fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text("以下按足迹次数与活跃天数统计，不代表里程。", fontSize = 12.sp, color = reviewSecondaryText())
        }

        ReviewMetricGrid(listOf(
            Triple("每周平均", snapshot.rhythmWeeklyAverageText, "calendar"),
            Triple("活跃天", "${snapshot.rhythmActiveDayCount}天", "checkmark.circle.fill"),
            Triple("活跃天比例", "${snapshot.rhythmActiveDayRate}%", "circle.grid.3x3.fill"),
            Triple("活跃日平均", snapshot.rhythmActiveDayAverageText, "figure.walk")
        ))

        ReviewCard {
            ReviewCardTitle("周期走势", "chart.xyaxis.line")
            Spacer(Modifier.height(6.dp))
            val values = snapshot.activityBuckets
            val maximum = max(1, values.maxOrNull() ?: 1)
            Row(Modifier.fillMaxWidth().height(150.dp), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
                values.forEach { value ->
                    val color = if (value == maximum) DfkAccent else DfkAccent.copy(alpha = if (value == 0) 0.12f else 0.34f)
                    Box(Modifier.weight(1f).height(max(6f, 68f * value / maximum).dp).clip(RoundedCornerShape(50)).background(color))
                }
            }
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth()) {
                Text(snapshot.rhythmAxisStartText, fontSize = 12.sp, color = reviewSecondaryText())
                Spacer(Modifier.weight(1f))
                Text(snapshot.rhythmAxisEndText, fontSize = 12.sp, color = reviewSecondaryText())
            }
        }

        ReviewCard {
            ReviewCardTitle("星期节奏", "calendar")
            Spacer(Modifier.height(14.dp))
            val averages = snapshot.rhythmWeekdayAverages
            ReviewWeekdayColumns(averages, averages.map(::reviewCompactNumber), barHeight = 92f, minimumHeight = 8f)
        }

        ReviewCard {
            ReviewCardTitle("一天中的节奏", "clock")
            Spacer(Modifier.height(14.dp))
            val values = snapshot.rhythmHourlyCounts
            val maximum = max(1, values.maxOrNull() ?: 1)
            Row(Modifier.fillMaxWidth().height(110.dp), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
                values.forEach { value ->
                    val color = if (value == maximum) DfkAccent else DfkAccent.copy(alpha = if (value == 0) 0.10f else 0.38f)
                    Box(Modifier.weight(1f).height(max(5f, 110f * value / maximum).dp).clip(RoundedCornerShape(50)).background(color))
                }
            }
            Spacer(Modifier.height(14.dp))
            ReviewHourAxis(fontSize = 12)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.height(IntrinsicSize.Max)) {
            ReviewMetricCard("最长连续活跃", "${snapshot.rhythmLongestStreak}天", "flame.fill", Modifier.weight(1f).fillMaxHeight())
            ReviewMetricCard("最高单日", "${snapshot.rhythmPeakCount}次", "arrow.up.right", Modifier.weight(1f).fillMaxHeight())
        }
    }
}

@Composable
private fun ReviewRegionsDetail(snapshot: ReviewSnapshot, onOpen: (FrequentPlaceItem, FrequentPlaceRankScope) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
        FrequentPlaceRankScope.entries.forEach { scope ->
            val items = snapshot.frequentPlaces(scope)
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(scope.label, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                if (items.isEmpty()) {
                    ReviewCard(radius = 18) { Text("暂无数据", color = reviewSecondaryText()) }
                } else {
                    ReviewDetailList {
                        items.forEachIndexed { index, item ->
                            Row(
                                Modifier.fillMaxWidth().clickable { onOpen(item, scope) }.padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    "${index + 1}", fontSize = 15.sp, fontWeight = FontWeight.Bold,
                                    color = if (index < 3) DfkAccent else reviewSecondaryText(),
                                    modifier = Modifier.width(24.dp)
                                )
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(item.name, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                                    if (item.address.isNotEmpty() && item.address != item.name) {
                                        Text(item.address, fontSize = 12.sp, color = reviewSecondaryText(), maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                                Spacer(Modifier.width(12.dp))
                                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(formatRankDuration(item.duration), fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                                    Text("${item.count}次", fontSize = 12.sp, color = reviewSecondaryText())
                                }
                                Spacer(Modifier.width(12.dp))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = reviewSecondaryText().copy(alpha = 0.5f), modifier = Modifier.size(16.dp))
                            }
                            if (index < items.lastIndex) HorizontalDivider()
                        }
                    }
                }
            }
        }
    }
}

// ── Place ────────────────────────────────────────────────────────────────

/** Photos with their taken dates, newest first (iOS ContinuousTimelinePhotoThumbnail picks the latest). */
@Composable
private fun rememberPhotoDates(uris: List<String>): Map<String, Date?> {
    val context = LocalContext.current
    var result by remember(uris) { mutableStateOf<Map<String, Date?>>(emptyMap()) }
    LaunchedEffect(uris) {
        result = withContext(Dispatchers.IO) { uris.associateWith { photoTakenDate(context, it) } }
    }
    return result
}

private val photoDateFormatter = ThreadLocal.withInitial { SimpleDateFormat("yyyy/M/d", Locale.SIMPLIFIED_CHINESE) }
private val visitTimeFormatter = ThreadLocal.withInitial { SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE) }
private val fullDateFormatter = ThreadLocal.withInitial { SimpleDateFormat("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE) }

/** iOS ReviewPlaceView placeDurationText. */
private fun placeDurationText(duration: Double): String {
    val minutes = max(1, (duration / 60).toInt())
    if (minutes < 60) return "${minutes}分钟"
    val hours = minutes / 60
    val remainingMinutes = minutes % 60
    if (hours < 24) return if (remainingMinutes == 0) "${hours}小时" else "${hours}小时${remainingMinutes}分"
    val days = hours / 24
    val remainingHours = hours % 24
    return if (remainingHours == 0) "${days}天" else "${days}天${remainingHours}小时"
}

/** iOS ReviewPlaceView. */
@Composable
internal fun ReviewPlaceDialog(selection: ReviewPlaceSelection, onDismiss: () -> Unit) {
    val photoDates = rememberPhotoDates(selection.photoUris)
    val heroPhoto = selection.photoUris.maxByOrNull { photoDates[it]?.time ?: Long.MIN_VALUE }
    var viewerIndex by remember { mutableStateOf<Int?>(null) }
    val totalDuration = selection.visits.sumOf { it.duration }.toDouble()
    val representative = selection.visits.maxWithOrNull(compareBy<FootprintEntity> { it.photoUris().size }.thenBy { it.duration })
    val geographyText = representative?.let { footprint ->
        listOfNotNull(footprint.countryName?.trim(), footprint.cityName?.trim()).filter { it.isNotEmpty() }
            .takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }
    val isTablet = LocalConfiguration.current.smallestScreenWidthDp >= 600

    ReviewDialogScaffold("${selection.rangeText} · ${selection.title}", onDismiss) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            if (heroPhoto != null) {
                FootprintPhotoThumbnail(
                    heroPhoto,
                    Modifier
                        .fillMaxWidth()
                        .height(if (isTablet) 340.dp else 280.dp)
                        .clickable { viewerIndex = selection.photoUris.indexOf(heroPhoto).coerceAtLeast(0) },
                    selection.title
                )
            }

            Column(
                Modifier.padding(horizontal = 18.dp).padding(top = if (heroPhoto == null) 28.dp else 0.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp)
            ) {
                Text(selection.title, fontSize = 34.sp, fontWeight = FontWeight.Bold, lineHeight = 40.sp)
                geographyText?.let { Text(it, fontSize = 15.sp, color = reviewSecondaryText()) }
                Text(selection.rangeText, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = DfkAccent)
            }

            Row(Modifier.padding(horizontal = 18.dp).height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                listOf(
                    "${selection.visits.size}" to "次到访",
                    placeDurationText(totalDuration) to "累计停留",
                    "${selection.photoUris.size}" to "张照片"
                ).forEach { (value, label) ->
                    ReviewCard(Modifier.weight(1f).fillMaxHeight(), radius = 18, padding = 14) {
                        Text(value, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(4.dp))
                        Text(label, fontSize = 12.sp, color = reviewSecondaryText())
                    }
                }
            }

            ReviewPlaceMap(selection)

            if (selection.photoUris.isNotEmpty()) {
                Column(Modifier.padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("这里的照片", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    selection.photoUris.chunked(3).forEachIndexed { rowIndex, row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            row.forEachIndexed { columnIndex, uri ->
                                Box(
                                    Modifier
                                        .weight(1f)
                                        .aspectRatio(1f)
                                        .clip(RoundedCornerShape(10.dp))
                                        .clickable { viewerIndex = rowIndex * 3 + columnIndex }
                                ) {
                                    FootprintPhotoThumbnail(uri, Modifier.fillMaxSize())
                                    photoDates[uri]?.let { date ->
                                        Text(
                                            photoDateFormatter.get()!!.format(date),
                                            fontSize = 10.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = Color.White,
                                            modifier = Modifier
                                                .align(Alignment.BottomStart)
                                                .padding(5.dp)
                                                .background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(5.dp))
                                                .padding(horizontal = 4.dp, vertical = 1.dp)
                                        )
                                    }
                                }
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }

            Column(Modifier.padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("到访规律", fontSize = 22.sp, fontWeight = FontWeight.Bold)

                ReviewCard {
                    ReviewCardTitle("星期偏好", "calendar")
                    Spacer(Modifier.height(14.dp))
                    val counts = IntArray(7).also { values -> selection.visits.forEach { values[mondayFirstIndex(it.startTime)] += 1 } }
                    Box(Modifier.height(112.dp), contentAlignment = Alignment.BottomCenter) {
                        ReviewWeekdayColumns(counts.map { it.toDouble() }, counts.map { "$it" }, barHeight = 72f, minimumHeight = 7f, zeroAlpha = 0.10f)
                    }
                }

                ReviewCard {
                    ReviewCardTitle("到访时刻", "clock")
                    Spacer(Modifier.height(14.dp))
                    val counts = IntArray(24).also { values -> selection.visits.forEach { values[hourOf(it.startTime)] += 1 } }
                    ReviewBarCanvas(counts.map { it.toDouble() }, Modifier.fillMaxWidth().height(92.dp),
                        denseThreshold = 60, denseSpacing = 1f, spacing = 2.5f, zeroHeight = 4f, minimumHeight = 6f)
                    Spacer(Modifier.height(14.dp))
                    ReviewHourAxis(fontSize = 12)
                }

                ReviewCard {
                    val visits = selection.visits.sortedBy { it.startTime }
                    val values = visits.map { max(0L, it.duration).toDouble() }
                    val average = if (values.isEmpty()) 0.0 else values.sum() / values.size
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ReviewCardTitle("停留时长变化", "chart.bar.fill", Modifier.weight(1f))
                        Text("平均 ${placeDurationText(average)}", fontSize = 12.sp, color = reviewSecondaryText())
                    }
                    Spacer(Modifier.height(14.dp))
                    ReviewBarCanvas(values, Modifier.fillMaxWidth().height(104.dp),
                        denseThreshold = 60, denseSpacing = 1f, spacing = 2.5f, zeroHeight = 4f, minimumHeight = 6f)
                    if (visits.isNotEmpty()) {
                        Spacer(Modifier.height(14.dp))
                        Row(Modifier.fillMaxWidth()) {
                            Text(fullDateFormatter.get()!!.format(visits.first().startTime), fontSize = 12.sp, color = reviewSecondaryText())
                            Spacer(Modifier.weight(1f))
                            Text(fullDateFormatter.get()!!.format(visits.last().startTime), fontSize = 12.sp, color = reviewSecondaryText())
                        }
                    }
                }
            }

            Column(Modifier.padding(horizontal = 18.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("到访记录", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                selection.visits.forEach { footprint -> ReviewVisitRow(footprint) }
            }
        }
    }

    viewerIndex?.let { index -> PhotoPagerViewer(selection.photoUris, index) { viewerIndex = null } }
}

/** iOS ReviewPlaceView map: a static 170 pt map around the place. */
@Composable
private fun ReviewPlaceMap(selection: ReviewPlaceSelection) {
    val visits = selection.visits
    val center = visits.firstNotNullOfOrNull { visit ->
        visit.shareCenter()?.takeIf { it.isRenderable }
    } ?: return
    // iOS centers a 0.012° span on the place.
    val bounds = ReviewMapBounds(center.lat - 0.0038, center.lat + 0.0038, center.lon - 0.0038, center.lon + 0.0038)
    ReviewMapView(
        footprints = visits,
        places = emptyList(),
        routes = emptyList(),
        overviewPoints = emptyList(),
        bounds = bounds,
        interactive = false,
        revision = selection.id,
        modifier = Modifier.padding(horizontal = 18.dp).fillMaxWidth().height(170.dp).clip(RoundedCornerShape(22.dp))
    )
}

@Composable
private fun ReviewVisitRow(footprint: FootprintEntity) {
    val time = visitTimeFormatter.get()!!
    ReviewCard(radius = 18, padding = 14) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(reviewMonthDay(footprint.startTime), fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
            Text("${time.format(footprint.startTime)}–${time.format(footprint.endTime)}", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("停留 ${placeDurationText(footprint.duration.toDouble())}", fontSize = 15.sp, color = reviewSecondaryText())
            Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
            val photoCount = footprint.photoUris().size
            if (photoCount > 0) {
                Icon(Icons.Default.Photo, null, tint = reviewSecondaryText(), modifier = Modifier.size(13.dp))
                Spacer(Modifier.width(4.dp))
                Text("${photoCount}张照片", fontSize = 12.sp, color = reviewSecondaryText(), maxLines = 1)
            }
        }
        footprint.reason?.trim()?.takeIf { it.isNotEmpty() }?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, fontSize = 15.sp, color = reviewSecondaryText(), maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

// ── Place lists ──────────────────────────────────────────────────────────

/** iOS ReviewPlaceListSheet / ReviewMapPlaceClusterSheet (medium/large detents). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReviewPlaceListSheet(selection: ReviewPlaceListSelection, onDismiss: () -> Unit) {
    var selectedPlace by remember { mutableStateOf<ReviewPlaceSelection?>(null) }
    val rangeText = selection.places.firstOrNull()?.rangeText
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
            Text(
                listOfNotNull(rangeText, selection.title).joinToString(" · "),
                fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.Center).padding(horizontal = 56.dp)
            )
            IconButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterEnd)) {
                Icon(Icons.Default.Close, contentDescription = "关闭")
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            items(selection.places, key = { it.id }) { place ->
                ReviewPlaceListRow(place, onClick = { selectedPlace = place })
                HorizontalDivider(Modifier.padding(start = 86.dp))
            }
        }
    }
    selectedPlace?.let { ReviewPlaceDialog(it, onDismiss = { selectedPlace = null }) }
}

@Composable
private fun ReviewPlaceListRow(place: ReviewPlaceSelection, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        val photo = place.photoUris.firstOrNull()
        if (photo != null) {
            FootprintPhotoThumbnail(photo, Modifier.size(54.dp).clip(RoundedCornerShape(10.dp)))
        } else {
            Box(Modifier.size(54.dp), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Place, null, tint = DfkAccent, modifier = Modifier.size(28.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(place.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("${place.visits.size}次到访", fontSize = 12.sp, color = reviewSecondaryText())
                if (place.photoUris.isNotEmpty()) Text("${place.photoUris.size}张照片", fontSize = 12.sp, color = reviewSecondaryText())
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = reviewSecondaryText().copy(alpha = 0.5f), modifier = Modifier.size(16.dp))
    }
}

// ── Full map ─────────────────────────────────────────────────────────────

/** iOS FullReviewMapView. */
@Composable
internal fun FullReviewMapDialog(
    title: String,
    snapshot: ReviewSnapshot,
    mapData: ReviewSnapshot.MapData?,
    onDismiss: () -> Unit
) {
    var selectedPlace by remember { mutableStateOf<ReviewPlaceSelection?>(null) }
    var selectedCluster by remember { mutableStateOf<ReviewPlaceListSelection?>(null) }
    ReviewDialogScaffold(title, onDismiss) {
        ReviewMapView(
            footprints = snapshot.footprints,
            places = snapshot.places,
            routes = mapData?.routes.orEmpty(),
            overviewPoints = mapData?.overviewPoints.orEmpty(),
            bounds = mapData?.bounds,
            interactive = true,
            revision = snapshot.revision,
            modifier = Modifier.fillMaxSize(),
            showsUserLocation = true,
            onFootprintsTap = { footprints ->
                if (footprints.size == 1) {
                    val footprint = footprints.first()
                    selectedPlace = snapshot.mapPlaceSelection("review-place-${footprint.footprintID}", footprints)
                } else {
                    val places = snapshot.mapPlaceSelections(footprints)
                    if (places.size > 1) {
                        selectedCluster = ReviewPlaceListSelection("cluster:${places.joinToString("|") { it.id }}", "附近地点", places)
                    } else {
                        selectedPlace = places.firstOrNull()
                    }
                }
            }
        )
    }
    selectedPlace?.let { ReviewPlaceDialog(it, onDismiss = { selectedPlace = null }) }
    selectedCluster?.let { ReviewPlaceListSheet(it, onDismiss = { selectedCluster = null }) }
}

// ── Favorites ────────────────────────────────────────────────────────────

/** iOS HistoryFavoritesView(includedFootprintIDs:) for the applied range. */
@Composable
internal fun ReviewFavoritesDialog(
    snapshot: ReviewSnapshot,
    onDismiss: () -> Unit,
    onFootprintSelected: (FootprintEntity) -> Unit
) {
    val favorites = remember(snapshot) {
        snapshot.footprints.filter { it.isHighlight == true && it.status != FootprintStatus.IGNORED }
            .sortedByDescending { it.startTime }
    }
    ReviewDialogScaffold("${snapshot.rangeText} · 收藏足迹", onDismiss, background = MaterialTheme.colorScheme.background) {
        HistoryFavoritesView(
            favorites = favorites,
            activityTypes = snapshot.activityTypes,
            allPlaces = snapshot.places,
            onNavigateToDetail = { id -> favorites.firstOrNull { it.footprintID == id }?.let(onFootprintSelected) }
        )
    }
}
