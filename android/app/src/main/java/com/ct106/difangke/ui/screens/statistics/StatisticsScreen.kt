package com.ct106.difangke.ui.screens.statistics

import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.ui.components.FootprintPhotoThumbnail
import com.ct106.difangke.ui.components.getIconForName
import com.ct106.difangke.ui.screens.main.findComponentActivity
import com.ct106.difangke.ui.share.ShareCardRequest
import com.ct106.difangke.ui.share.ShareRankingEntry
import com.ct106.difangke.ui.share.ShareReviewMemory
import com.ct106.difangke.ui.share.ShareStatEntry
import com.ct106.difangke.ui.share.ShareStatsReview
import com.ct106.difangke.ui.theme.DfkAccent
import kotlinx.coroutines.delay
import java.util.Calendar
import java.util.Date
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// ── iOS system colors used by the review page ────────────────────────────

/** iOS systemGroupedBackground: the review page background. */
@Composable
internal fun reviewGroupedBackground(): Color = if (isSystemInDarkTheme()) Color.Black else Color(0xFFF2F2F7)

/** iOS secondarySystemGroupedBackground: cards on the review page. */
@Composable
internal fun reviewGroupedCard(): Color = if (isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color.White

/** iOS systemBackground (Color.dfkBackground): detail page background. */
@Composable
internal fun reviewDetailBackground(): Color = if (isSystemInDarkTheme()) Color.Black else Color.White

/** iOS secondarySystemBackground: cards on detail pages. */
@Composable
internal fun reviewDetailCard(): Color = if (isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color(0xFFF2F2F7)

/** iOS systemGray5: empty heatmap cells / bars. */
@Composable
internal fun reviewEmptyCell(): Color = if (isSystemInDarkTheme()) Color(0xFF2C2C2E) else Color(0xFFE5E5EA)

/** iOS regularMaterial surface over the map. */
@Composable
internal fun reviewMaterial(): Color = if (isSystemInDarkTheme()) Color(0xFF2C2C2E).copy(alpha = 0.88f) else Color.White.copy(alpha = 0.86f)

@Composable
internal fun reviewSecondaryText(): Color = MaterialTheme.colorScheme.onSurfaceVariant

/** SF Symbols used by the review page → Material icons; anything else goes through [getIconForName]. */
internal fun reviewIcon(name: String): ImageVector = when (name) {
    "globe.asia.australia.fill" -> Icons.Default.Public
    "building.2.fill" -> Icons.Default.Apartment
    "mappin.and.ellipse" -> Icons.Default.Place
    "mappin.circle.fill" -> Icons.Default.Place
    "road.lanes" -> Icons.Default.AddRoad
    "point.topleft.down.to.point.bottomright.curvepath",
    "point.bottomleft.forward.to.point.topright.scurvepath" -> Icons.Default.Route
    "sparkles" -> Icons.Default.AutoAwesome
    "flag.fill" -> Icons.Default.Flag
    "hourglass.bottomhalf.filled", "hourglass" -> Icons.Default.HourglassBottom
    "repeat.circle.fill" -> Icons.Default.Repeat
    "clock.fill", "clock" -> Icons.Default.Schedule
    "photo.on.rectangle.angled" -> Icons.Default.PhotoLibrary
    "arrow.uturn.backward.circle.fill" -> Icons.Default.Replay
    "note.text" -> Icons.Default.EditNote
    "star.fill" -> Icons.Default.Star
    "clock.arrow.circlepath" -> Icons.Default.History
    "figure.walk" -> Icons.AutoMirrored.Filled.DirectionsWalk
    "arrow.triangle.branch" -> Icons.Default.CallSplit
    "chart.bar.xaxis" -> Icons.Default.BarChart
    "car.fill" -> Icons.Default.DirectionsCar
    "map.fill" -> Icons.Default.Map
    "square.grid.2x2.fill" -> Icons.Default.GridView
    "list.number" -> Icons.Default.FormatListNumbered
    "timer" -> Icons.Default.Timer
    "chart.pie.fill" -> Icons.Default.PieChart
    "calendar" -> Icons.Default.CalendarMonth
    "ruler" -> Icons.Default.Straighten
    "divide" -> Icons.Default.Calculate
    "arrow.up.right" -> Icons.AutoMirrored.Filled.ShowChart
    "calendar.badge.checkmark" -> Icons.Default.EventAvailable
    "checkmark.circle.fill" -> Icons.Default.CheckCircle
    "circle.grid.3x3.fill" -> Icons.Default.Apps
    "square.grid.3x3.fill" -> Icons.Default.GridOn
    "chart.xyaxis.line" -> Icons.Default.Timeline
    "flame.fill" -> Icons.Default.LocalFireDepartment
    "chart.bar.fill" -> Icons.Default.BarChart
    "photo" -> Icons.Default.Photo
    else -> getIconForName(name)
}

/** iOS StatisticsRange segmented picker with a year menu on its last segment. */
@Composable
fun RangePickerRow(
    selectedRange: StatisticsRange,
    availableYears: List<Int>,
    onRangeSelected: (StatisticsRange) -> Unit
) {
    var showYearMenu by remember { mutableStateOf(false) }
    var activeYear by remember { mutableIntStateOf((selectedRange as? StatisticsRange.CUSTOM_YEAR)?.year ?: Calendar.getInstance().get(Calendar.YEAR)) }
    val isDark = isSystemInDarkTheme()
    val unselectedColor = if (isDark) Color.Gray else Color.Black.copy(alpha = 0.6f)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (isDark) Color.White.copy(alpha = 0.1f) else Color.Black.copy(alpha = 0.05f))
            .padding(3.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically
    ) {
        listOf(
            StatisticsRange.LAST_7_DAYS,
            StatisticsRange.LAST_30_DAYS,
            StatisticsRange.LAST_90_DAYS,
            StatisticsRange.LAST_YEAR
        ).forEach { range ->
            val isSelected = selectedRange == range
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (isSelected) DfkAccent else Color.Transparent)
                    .clickable { onRangeSelected(range) },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    range.label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (isSelected) Color.White else unselectedColor,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                )
            }
        }

        val isCustomYear = selectedRange is StatisticsRange.CUSTOM_YEAR
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .clip(RoundedCornerShape(10.dp))
                .background(if (isCustomYear) DfkAccent else Color.Transparent)
                .clickable {
                    // iOS: the year menu covers the segment only when years exist;
                    // otherwise the segment selects the remembered year directly.
                    if (availableYears.isNotEmpty()) showYearMenu = true
                    else onRangeSelected(StatisticsRange.CUSTOM_YEAR(activeYear))
                },
            contentAlignment = Alignment.Center
        ) {
            Text(
                if (isCustomYear) "$activeYear ▾" else "年份 ▾",
                style = MaterialTheme.typography.labelMedium,
                color = if (isCustomYear) Color.White else unselectedColor,
                fontWeight = if (isCustomYear) FontWeight.Bold else FontWeight.Medium,
                maxLines = 1
            )
            DropdownMenu(expanded = showYearMenu, onDismissRequest = { showYearMenu = false }) {
                availableYears.forEach { year ->
                    DropdownMenuItem(
                        text = { Text("$year") },
                        onClick = {
                            activeYear = year
                            onRangeSelected(StatisticsRange.CUSTOM_YEAR(year))
                            showYearMenu = false
                        }
                    )
                }
            }
        }
    }
}

/**
 * iOS HistoryStatisticsView: the review home — life map hero, memorable
 * moments and the four bento cards. Hosted by the Review tab, which owns the
 * title bar and its share action ([reviewShareRequest]).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun StatisticsContent(
    onFootprintSelected: (FootprintEntity) -> Unit,
    onDateSelected: (Date) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: StatisticsViewModel = viewModel()
) {
    val state by viewModel.state.collectAsState()
    val snapshot = state.snapshot
    val background = reviewGroupedBackground()

    var showingFullMap by remember { mutableStateOf(false) }
    var selectedPlace by remember { mutableStateOf<ReviewPlaceSelection?>(null) }
    var selectedPlaceList by remember { mutableStateOf<ReviewPlaceListSelection?>(null) }
    var selectedBentoDetail by remember { mutableStateOf<ReviewBentoDetail?>(null) }
    var showingAllFavorites by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.onAppear() }
    // iOS onChange(of: selectedRange): dismiss nothing, but every presented
    // page belongs to the applied range, so a rebuild clears them.
    LaunchedEffect(snapshot) {
        showingFullMap = false
        selectedPlace = null
        selectedPlaceList = null
        selectedBentoDetail = null
        showingAllFavorites = false
    }

    LazyColumn(
        modifier = modifier.fillMaxSize().background(background),
        verticalArrangement = Arrangement.spacedBy(22.dp)
    ) {
        stickyHeader {
            Box(
                Modifier
                    .fillMaxWidth()
                    // iOS ReviewNavigationBarBlur: opaque top fading out at the bottom.
                    .background(
                        Brush.verticalGradient(
                            0f to background.copy(alpha = 0.95f),
                            0.68f to background.copy(alpha = 0.95f),
                            1f to background.copy(alpha = 0f)
                        )
                    )
                    .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp)
            ) {
                RangePickerRow(
                    selectedRange = state.selectedRange,
                    availableYears = state.availableYears,
                    onRangeSelected = viewModel::setRange
                )
            }
        }

        if (state.isReady && snapshot != null) {
            item(key = "hero") {
                ReviewHeroSection(
                    snapshot = snapshot,
                    mapData = state.mapData,
                    onOpenMap = { showingFullMap = true }
                )
            }
            item(key = "memories") {
                ReviewMemorableSection(
                    memories = state.memories,
                    pastMemory = snapshot.pastMemory,
                    onMemoryTap = { memory ->
                        when {
                            memory.isFavorite -> showingAllFavorites = true
                            memory.isPastMemory -> onDateSelected(memory.date)
                            else -> snapshot.placeSelection(memory)?.let { selectedPlace = it }
                                ?: onDateSelected(memory.date)
                        }
                    }
                )
            }
            item(key = "bento") {
                ReviewBentoSection(snapshot = snapshot, onOpen = { selectedBentoDetail = it })
            }
        } else {
            item(key = "loading") {
                Box(Modifier.fillMaxWidth().heightIn(min = 420.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = DfkAccent)
                }
            }
        }
        item(key = "bottom") { Spacer(Modifier.height(132.dp)) }
    }

    if (snapshot != null) {
        if (showingFullMap) {
            FullReviewMapDialog(
                title = "${snapshot.rangeText} · ${snapshot.geographyMetric.value}${snapshot.geographyMetric.label}",
                snapshot = snapshot,
                mapData = state.mapData,
                onDismiss = { showingFullMap = false }
            )
        }
        selectedPlace?.let { ReviewPlaceDialog(it, onDismiss = { selectedPlace = null }) }
        selectedPlaceList?.let { ReviewPlaceListSheet(it, onDismiss = { selectedPlaceList = null }) }
        selectedBentoDetail?.let { detail ->
            ReviewBentoDetailDialog(detail = detail, snapshot = snapshot, onDismiss = { selectedBentoDetail = null })
        }
        if (showingAllFavorites) {
            ReviewFavoritesDialog(
                snapshot = snapshot,
                onDismiss = { showingAllFavorites = false },
                onFootprintSelected = { footprint ->
                    showingAllFavorites = false
                    onFootprintSelected(footprint)
                }
            )
        }
    }
}

/** iOS prepareStatsShare: the stats card built from what the review page already computed. */
fun reviewShareRequest(state: ReviewUiState): ShareCardRequest.Stats? {
    val snapshot = state.snapshot ?: return null
    val activityTotal = max(1.0, snapshot.activitySlices.sumOf { it.duration })
    val metric = snapshot.geographyMetric
    val accent = DfkAccent.toArgbInt()
    val review = ShareStatsReview(
        stats = listOf(
            ShareStatEntry(metric.label, metric.value),
            ShareStatEntry("路程", snapshot.distanceText),
            ShareStatEntry("段路程", "${snapshot.transports.size}")
        ),
        memories = state.memories.take(4).map {
            ShareReviewMemory(it.id, it.reason, it.title, it.evidence, it.photoUris.firstOrNull())
        },
        activityRankings = snapshot.activitySlices.take(5).map {
            ShareRankingEntry(
                title = it.name,
                value = formatRankDuration(it.duration),
                icon = it.icon,
                color = it.color.toArgbInt(),
                fraction = it.duration / activityTotal
            )
        },
        rhythmValues = snapshot.activityBuckets,
        rhythmStartText = snapshot.rhythmAxisStartText,
        rhythmEndText = snapshot.rhythmAxisEndText,
        transportRankings = snapshot.transportSlices.take(3).map {
            ShareRankingEntry(
                title = it.name,
                detail = formatRankMileage(it.distance),
                value = "${it.count}次",
                icon = it.icon,
                color = it.color.toArgbInt()
            )
        },
        regionRankings = snapshot.topRegions.take(3).map {
            ShareRankingEntry(title = it.name, value = formatRankDuration(it.duration), icon = "mappin.and.ellipse", color = accent)
        }
    )
    val range = snapshot.range
    val end = if (range is StatisticsRange.CUSTOM_YEAR) {
        Calendar.getInstance().run { clear(); set(range.year + 1, Calendar.JANUARY, 1); time }
    } else {
        Date(snapshot.now.time + 1)
    }
    return ShareCardRequest.Stats(snapshot.rangeText, snapshot.rangeStart, end, review)
}

private fun Color.toArgbInt(): Int = android.graphics.Color.argb(
    (alpha * 255).toInt(), (red * 255).toInt(), (green * 255).toInt(), (blue * 255).toInt()
)

// ── Hero ─────────────────────────────────────────────────────────────────

@Composable
private fun ReviewHeroSection(
    snapshot: ReviewSnapshot,
    mapData: ReviewSnapshot.MapData?,
    onOpenMap: () -> Unit
) {
    val shape = RoundedCornerShape(26.dp)
    BoxWithConstraints(
        Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(shape)
            .border(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f), shape)
            .clickable(onClick = onOpenMap)
    ) {
        // iOS: a golden-ratio map with 72 pt reserved below for the metrics bar.
        val height = maxWidth / 1.618f + 72.dp
        Box(Modifier.fillMaxWidth().height(height)) {
            ReviewMapView(
                footprints = snapshot.footprints,
                places = snapshot.places,
                routes = mapData?.routes.orEmpty(),
                overviewPoints = mapData?.overviewPoints.orEmpty(),
                bounds = mapData?.bounds,
                interactive = false,
                revision = snapshot.revision,
                modifier = Modifier.fillMaxSize(),
                topContentPadding = 32.dp,
                bottomContentPadding = 76.dp
            )

            val barShape = RoundedCornerShape(22.dp)
            Row(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(12.dp)
                    .fillMaxWidth()
                    .clip(barShape)
                    .background(reviewMaterial())
                    .border(0.5.dp, Color.White.copy(alpha = 0.42f), barShape)
                    .padding(horizontal = 8.dp, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val metric = snapshot.geographyMetric
                ReviewMetric(metric.icon, metric.value, metric.label, Modifier.weight(1f))
                VerticalDivider(Modifier.height(36.dp))
                ReviewMetric("road.lanes", snapshot.distanceText, "", Modifier.weight(1f))
                VerticalDivider(Modifier.height(36.dp))
                ReviewMetric(
                    "point.topleft.down.to.point.bottomright.curvepath",
                    "${snapshot.transports.size}",
                    "段路程",
                    Modifier.weight(1f)
                )
            }

            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(14.dp)
                    .clip(CircleShape)
                    .background(reviewMaterial())
                    .clickable(onClick = onOpenMap)
                    .padding(11.dp)
            ) {
                Icon(
                    Icons.Default.OpenInFull,
                    contentDescription = "打开完整生活地图",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
private fun ReviewMetric(icon: String, value: String, label: String, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(reviewIcon(icon), contentDescription = null, tint = DfkAccent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(7.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false)
            if (label.isNotEmpty()) {
                Spacer(Modifier.width(2.dp))
                Text(label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false,
                    modifier = Modifier.padding(bottom = 1.dp))
            }
        }
    }
}

// ── Memorable ────────────────────────────────────────────────────────────

@Composable
private fun ReviewMemorableSection(
    memories: List<ReviewMemory>,
    pastMemory: ReviewMemory?,
    onMemoryTap: (ReviewMemory) -> Unit
) {
    val featured = memories.firstOrNull { !it.isFavorite }
    val compact = memories.filter { it.isFavorite } + listOfNotNull(pastMemory) +
        memories.filter { it.id != featured?.id && !it.isFavorite }

    if (featured == null && compact.isEmpty()) {
        Column(
            Modifier
                .padding(horizontal = 16.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(24.dp))
                .background(reviewDetailCard())
                .padding(vertical = 34.dp, horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(Icons.Default.AutoAwesome, null, tint = reviewSecondaryText(), modifier = Modifier.size(40.dp))
            Spacer(Modifier.height(12.dp))
            Text("还没有特别突出的片段", fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(
                "停留、照片和新的经历积累后，会在这里自然出现",
                fontSize = 14.sp,
                color = reviewSecondaryText(),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
        }
        return
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        featured?.let {
            ReviewMemoryLargeCard(it, onClick = { onMemoryTap(it) }, modifier = Modifier.padding(horizontal = 16.dp))
        }
        if (compact.isNotEmpty()) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(compact, key = { it.id }) { memory ->
                    ReviewMemoryCompactCard(memory, onClick = { onMemoryTap(memory) })
                }
            }
        }
    }
}

@Composable
private fun ReviewMemoryLargeCard(memory: ReviewMemory, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .height(248.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(reviewGroupedCard())
            .clickable(onClick = onClick),
        contentAlignment = Alignment.BottomStart
    ) {
        if (memory.photoUris.size > 1) {
            ReviewMemoryPhotoCarousel(memory.photoUris, Modifier.fillMaxSize())
        } else {
            ReviewMemoryArtwork(memory, isLarge = true, modifier = Modifier.fillMaxSize())
        }
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(
                    0f to Color.Transparent,
                    0.5f to Color.Black.copy(alpha = 0.12f),
                    1f to Color.Black.copy(alpha = 0.78f)
                )
            )
        )
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            val shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.28f), Offset(0f, 2f), 5f)
            Text(memory.reason, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent, maxLines = 1,
                overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(shadow = shadow))
            Text(memory.title, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1,
                overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(shadow = shadow))
            Text(memory.evidence, fontSize = 15.sp, color = Color.White.copy(alpha = 0.82f), maxLines = 1,
                overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(shadow = shadow))
        }
    }
}

@Composable
private fun ReviewMemoryCompactCard(memory: ReviewMemory, onClick: () -> Unit) {
    Column(
        Modifier
            .width(176.dp)
            .height(212.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(reviewGroupedCard())
            .clickable(onClick = onClick)
    ) {
        ReviewMemoryArtwork(memory, isLarge = false, modifier = Modifier.fillMaxWidth().height(116.dp))
        Column(
            Modifier.padding(horizontal = 12.dp, vertical = 10.dp).height(76.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            Text(memory.reason, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            Text(memory.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(memory.evidence, fontSize = 12.sp, color = reviewSecondaryText(), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** iOS reviewMemoryArtwork: the earliest photo, or a tinted symbol when the memory has none. */
@Composable
private fun ReviewMemoryArtwork(memory: ReviewMemory, isLarge: Boolean, modifier: Modifier = Modifier) {
    val photo = memory.photoUris.firstOrNull()
    if (photo != null) {
        FootprintPhotoThumbnail(photo, modifier, memory.title)
        return
    }
    val primary = when {
        memory.isFavorite -> Color(0xFFFF9500)
        memory.isPastMemory -> Color(0xFF5856D6)
        else -> DfkAccent
    }
    val secondary = when {
        memory.isFavorite -> Color(0xFFFF2D55)
        memory.isPastMemory -> Color(0xFFAF52DE)
        else -> Color(0xFF007AFF)
    }
    Box(
        modifier.background(Brush.linearGradient(listOf(primary.copy(alpha = 0.34f), secondary.copy(alpha = 0.16f)))),
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier
                .offset(x = if (isLarge) 120.dp else 54.dp, y = if (isLarge) (-74).dp else (-34).dp)
                .size(if (isLarge) 180.dp else 92.dp)
                .clip(CircleShape)
                .background(secondary.copy(alpha = 0.1f))
        )
        Box(Modifier.size(if (isLarge) 82.dp else 56.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.24f)))
        Icon(reviewIcon(memory.icon), null, tint = primary, modifier = Modifier.size(if (isLarge) 38.dp else 28.dp))
    }
}

/** iOS ReviewMemoryPhotoCarousel: oldest photo first, advancing while the app is active. */
@Composable
private fun ReviewMemoryPhotoCarousel(photoUris: List<String>, modifier: Modifier = Modifier) {
    val pager = rememberPagerState { photoUris.size }
    val context = LocalContext.current
    var isActive by remember { mutableStateOf(true) }
    val activity = remember(context) { context.findComponentActivity() }
    DisposableEffect(activity) {
        val observer = LifecycleEventObserver { _, _ ->
            isActive = activity?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) != false
        }
        activity?.lifecycle?.addObserver(observer)
        onDispose { activity?.lifecycle?.removeObserver(observer) }
    }
    LaunchedEffect(isActive, photoUris) {
        if (!isActive || photoUris.size <= 1) return@LaunchedEffect
        val interval = (max(1.0, AppConfig.REVIEW_MEMORY_CAROUSEL_INTERVAL) * 1000).toLong()
        while (true) {
            delay(interval)
            pager.animateScrollToPage(
                (pager.currentPage + 1) % photoUris.size,
                animationSpec = tween((AppConfig.REVIEW_MEMORY_CAROUSEL_ANIMATION_DURATION * 1000).toInt())
            )
        }
    }
    HorizontalPager(state = pager, modifier = modifier, userScrollEnabled = true) { page ->
        FootprintPhotoThumbnail(photoUris[page], Modifier.fillMaxSize())
    }
}

// ── Bento ────────────────────────────────────────────────────────────────

@Composable
private fun ReviewBentoSection(snapshot: ReviewSnapshot, onOpen: (ReviewBentoDetail) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.height(IntrinsicSize.Max)) {
            ReviewBentoCard("时间花在哪", Icons.Default.Schedule, Modifier.weight(1f).fillMaxHeight(), { onOpen(ReviewBentoDetail.ACTIVITY) }) {
                ReviewActivityCompositionContent(snapshot)
            }
            ReviewBentoCard("出行节奏", Icons.Default.BarChart, Modifier.weight(1f).fillMaxHeight(), { onOpen(ReviewBentoDetail.RHYTHM) }) {
                ReviewRhythmCardContent(snapshot)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.height(IntrinsicSize.Max)) {
            ReviewBentoCard("最常用交通", Icons.Default.DirectionsCar, Modifier.weight(1f).fillMaxHeight(), { onOpen(ReviewBentoDetail.TRANSPORT) }) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    snapshot.transportSlices.take(3).forEach { slice ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(reviewIcon(slice.icon), null, tint = slice.color, modifier = Modifier.width(18.dp).size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(slice.name, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text("${slice.count}次", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = reviewSecondaryText(), maxLines = 1)
                        }
                    }
                }
            }
            ReviewBentoCard("最常停留的区域", Icons.Default.Map, Modifier.weight(1f).fillMaxHeight(), { onOpen(ReviewBentoDetail.REGIONS) }) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    snapshot.topRegions.take(3).forEach { region ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(region.name, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Spacer(Modifier.width(6.dp))
                            Text(formatRankDuration(region.duration), fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                color = reviewSecondaryText(), maxLines = 1)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReviewBentoCard(
    title: String,
    icon: ImageVector,
    modifier: Modifier,
    onClick: () -> Unit,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier
            .heightIn(min = 154.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(reviewGroupedCard())
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f))
            Spacer(Modifier.width(8.dp))
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        content()
    }
}

@Composable
private fun ReviewActivityCompositionContent(snapshot: ReviewSnapshot) {
    val slices = snapshot.activitySlices
    val total = max(1.0, slices.sumOf { it.duration })
    BoxWithConstraints(Modifier.fillMaxWidth().height(116.dp)) {
        val chartSide = min(116.dp.value, max(56.dp.value, maxWidth.value * 0.36f)).dp
        val lineWidth = min(14f, max(8f, chartSide.value * 0.14f)).dp
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Canvas(Modifier.size(chartSide)) {
                val stroke = lineWidth.toPx()
                val diameter = size.minDimension - stroke
                var start = -90f
                slices.take(5).forEach { slice ->
                    val sweep = (360 * slice.duration / total).toFloat()
                    drawArc(
                        color = slice.color,
                        startAngle = start,
                        sweepAngle = sweep,
                        useCenter = false,
                        topLeft = Offset((size.width - diameter) / 2, (size.height - diameter) / 2),
                        size = Size(diameter, diameter),
                        style = Stroke(width = stroke)
                    )
                    start += sweep
                }
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                slices.take(3).forEach { slice ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(Modifier.padding(top = 4.dp).size(7.dp).clip(CircleShape).background(slice.color))
                        Spacer(Modifier.width(5.dp))
                        Column {
                            Text(slice.name, fontSize = 12.sp)
                            Text(formatRankDuration(slice.duration), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                                color = reviewSecondaryText(), maxLines = 1)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReviewRhythmCardContent(snapshot: ReviewSnapshot) {
    val mileage = snapshot.mileage
    val values = mileage.dailyValues.map { it.distance.toLong().toInt() }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // iOS reviewRhythmCardHeatmapHeight.
        val height = min(164f, max(92f, (sqrt(max(1, values.size).toDouble()) * 8.5).toFloat())).dp
        ReviewDailyHeatmap(values, Modifier.fillMaxWidth().height(height))
        Text("日均 ${formatRankMileage(mileage.dailyAverage)}", fontSize = 12.sp, fontWeight = FontWeight.Bold,
            color = reviewSecondaryText(), maxLines = 1)
    }
}

/** iOS ReviewDailyFootprintHeatmap. */
@Composable
internal fun ReviewDailyHeatmap(values: List<Int>, modifier: Modifier = Modifier, preferredColumnCount: Int? = null) {
    val emptyColor = reviewEmptyCell()
    Canvas(modifier) {
        if (values.isEmpty() || size.width <= 0f || size.height <= 0f) return@Canvas
        val spacing = (if (values.size > 100) 1.5f else 3f).dp.toPx()
        val aspectRatio = size.width / size.height
        val automaticColumnCount = max(1, ceil(sqrt(values.size * aspectRatio.toDouble())).toInt())
        val columnCount = min(values.size, max(1, preferredColumnCount ?: automaticColumnCount))
        val rowCount = max(1, ceil(values.size / columnCount.toDouble()).toInt())
        val cellSide = max(
            1f,
            min(
                (size.width - spacing * (columnCount - 1)) / columnCount,
                (size.height - spacing * (rowCount - 1)) / rowCount
            )
        )
        val gridWidth = cellSide * columnCount + spacing * (columnCount - 1)
        val horizontalOffset = max(0f, (size.width - gridWidth) / 2)
        val maximum = max(1, values.maxOrNull() ?: 1)
        val corner = min(3.dp.toPx(), cellSide * 0.22f)
        values.forEachIndexed { index, value ->
            val row = index / columnCount
            val column = index % columnCount
            drawRoundRect(
                color = if (value == 0) emptyColor else DfkAccent.copy(alpha = 0.22f + 0.78f * value / maximum),
                topLeft = Offset(horizontalOffset + column * (cellSide + spacing), row * (cellSide + spacing)),
                size = Size(cellSide, cellSide),
                cornerRadius = CornerRadius(corner, corner)
            )
        }
    }
}
