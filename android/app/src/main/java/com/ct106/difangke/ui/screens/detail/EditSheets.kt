package com.ct106.difangke.ui.screens.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.service.GeocodeService
import com.ct106.difangke.ui.shared.TimelineEditActions
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.CircleOptions
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import java.util.Date
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

private fun minuteFloor(ms: Long) = ms / 60_000L * 60_000L

/**
 * Shared time-range editor (iOS FootprintTimeAdjustmentView / TransportTimeAdjustmentView):
 * 300 dp map of raw points within the draft range, "调整时间" HH:mm-HH:mm, range slider.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeAdjustEditor(
    initialStart: Date,
    initialEnd: Date,
    loadRange: suspend () -> Pair<Date, Date>,
    minDurationMs: Long,
    dotDiameterDp: Int,
    unfilteredRaw: Boolean,
    onDismiss: () -> Unit,
    onSave: (Date, Date) -> Unit
) {
    val context = LocalContext.current
    var range by remember { mutableStateOf<Pair<Date, Date>?>(null) }
    var raw by remember { mutableStateOf<List<RawLocationStore.RawPoint>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var draft by remember { mutableStateOf(initialStart.time.toFloat()..initialEnd.time.toFloat()) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val r = loadRange()
        range = r
        val ds = min(max(initialStart.time, r.first.time), r.second.time - minDurationMs)
        val de = max(min(initialEnd.time, r.second.time), ds + minDurationMs)
        draft = ds.toFloat()..de.toFloat()
        raw = TimelineEditActions.loadRawPoints(context, r.first, r.second, filtered = !unfilteredRaw)
        loading = false
    }

    val r = range
    val start = Date(draft.start.toLong())
    val end = Date(draft.endInclusive.toLong())
    val selected = raw.filter { !it.timestamp.before(start) && !it.timestamp.after(end) }
    val canSave = r != null && !loading && !busy && end.time - start.time >= minDurationMs

    EditorDialogScaffold(
        title = "调整时间",
        onDismiss = onDismiss,
        onConfirm = { busy = true; onSave(start, end) },
        confirmEnabled = canSave,
        busy = busy
    ) {
        Box(Modifier.fillMaxWidth().height(300.dp).clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))) {
            val pts = selected.map { LatLng(it.latitude, it.longitude) }
            if (pts.isNotEmpty()) {
                TrackPreviewMap(
                    segments = listOf(MapSegment(pts, DfkAccent.copy(alpha = 0.6f), width = 6f)),
                    dots = pts.map { MapDot(it, DfkAccent, dotDiameterDp) },
                    modifier = Modifier.fillMaxSize(),
                    fitKey = pts.size
                )
            }
            RawPointBadge(loading, selected.size, Modifier.align(Alignment.BottomStart))
        }
        TimeControlCard(
            label = "调整时间",
            value = "${hmText(start)}-${hmText(end)}",
            leftLabel = hmText(r?.first ?: initialStart),
            rightLabel = hmText(r?.second ?: initialEnd)
        ) {
            if (r != null) {
                val lo = r.first.time.toFloat()
                val hi = max(r.second.time, r.first.time + 60_000L).toFloat()
                RangeSlider(
                    value = draft,
                    onValueChange = { v ->
                        val s = minuteFloor(v.start.roundToLong())
                        val e = minuteFloor(v.endInclusive.roundToLong())
                        if (e - s >= 60_000L) draft = s.toFloat()..e.toFloat()
                    },
                    valueRange = lo..hi,
                    colors = SliderDefaults.colors(thumbColor = DfkAccent, activeTrackColor = DfkAccent)
                )
            }
        }
    }
}

@Composable
fun FootprintTimeAdjustSheet(footprint: FootprintEntity, onDismiss: () -> Unit, onSave: (Date, Date) -> Unit) {
    TimeAdjustEditor(
        initialStart = footprint.startTime,
        initialEnd = footprint.endTime,
        loadRange = { TimelineEditActions.footprintAdjustRange(DiFangKeApp.instance.database, footprint) },
        minDurationMs = TimelineEditActions.MIN_FOOTPRINT_DURATION_MS,
        dotDiameterDp = 10,
        unfilteredRaw = false,
        onDismiss = onDismiss,
        onSave = onSave
    )
}

@Composable
fun TransportTimeAdjustSheet(transport: TransportRecordEntity, onDismiss: () -> Unit, onSave: (Date, Date) -> Unit) {
    TimeAdjustEditor(
        initialStart = transport.startTime,
        initialEnd = transport.endTime,
        loadRange = { TimelineEditActions.transportAdjustRange(DiFangKeApp.instance.database, transport) },
        minDurationMs = TimelineEditActions.MIN_TRANSPORT_SEGMENT_MS,
        dotDiameterDp = 14,
        unfilteredRaw = true,
        onDismiss = onDismiss,
        onSave = onSave
    )
}

/** iOS FootprintSplitView: "分割点" slider, map with both segments, "新足迹"/"原足迹" cards with activity pickers. */
@Composable
fun FootprintSplitSheet(
    footprint: FootprintEntity,
    activities: List<ActivityTypeEntity>,
    onDismiss: () -> Unit,
    onSave: (split: Date, firstActivity: String?, secondActivity: String?) -> Unit
) {
    val context = LocalContext.current
    val minMs = TimelineEditActions.MIN_FOOTPRINT_DURATION_MS
    val startMs = footprint.startTime.time
    val endMs = footprint.endTime.time
    val canSplit = endMs - startMs >= minMs * 2
    var splitMs by remember { mutableLongStateOf(TimelineEditActions.roundedToMinute(Date(startMs + (endMs - startMs) / 2)).time) }
    var raw by remember { mutableStateOf<List<RawLocationStore.RawPoint>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var firstActivity by remember { mutableStateOf(footprint.activityTypeValue) }
    var secondActivity by remember { mutableStateOf(footprint.activityTypeValue) }
    LaunchedEffect(footprint.footprintID) {
        raw = TimelineEditActions.loadRawPoints(context, footprint.startTime, footprint.endTime)
        loading = false
    }
    val bounded = if (canSplit) splitMs.coerceIn(startMs + minMs, endMs - minMs) else startMs + (endMs - startMs) / 2
    val stored = remember(footprint.footprintID) {
        val lats = TimelineEditActions.jsonDoubles(footprint.latitudeJson)
        val lons = TimelineEditActions.jsonDoubles(footprint.longitudeJson)
        (0 until min(lats.size, lons.size)).map { LatLng(lats[it], lons[it]) }
    }
    val ratio = (bounded - startMs).toDouble() / max(1L, endMs - startMs)
    fun segment(from: Long, to: Long, r0: Double, r1: Double): List<LatLng> {
        val inRange = raw.filter { it.timestamp.time in from..to }.map { LatLng(it.latitude, it.longitude) }
        if (inRange.isNotEmpty()) return inRange
        if (stored.isEmpty()) return emptyList()
        val last = stored.lastIndex
        val s = (last * r0).toInt().coerceIn(0, last)
        val e = (last * r1).toInt().coerceIn(s, last)
        return stored.subList(s, e + 1)
    }
    val first = segment(startMs, bounded, 0.0, ratio)
    val second = segment(bounded, endMs, ratio, 1.0)
    val splitPoint = raw.minByOrNull { kotlin.math.abs(it.timestamp.time - bounded) }?.let { LatLng(it.latitude, it.longitude) }
        ?: first.lastOrNull()
    val title = footprint.address?.trim()?.takeIf { it.isNotEmpty() } ?: "未知地点"

    EditorDialogScaffold(
        title = "拆分足迹",
        onDismiss = onDismiss,
        onConfirm = { onSave(Date(bounded), firstActivity, secondActivity) },
        confirmEnabled = canSplit
    ) {
        Box(Modifier.fillMaxWidth().height(300.dp).clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))) {
            TrackPreviewMap(
                segments = listOf(MapSegment(first, SplitGreen, width = 8f), MapSegment(second, SplitBlue, width = 8f)),
                dots = first.map { MapDot(it, SplitGreen, 8) } + second.map { MapDot(it, SplitBlue, 8) },
                marker = splitPoint,
                markerColor = Color(0xFFFF9500),
                modifier = Modifier.fillMaxSize(),
                fitKey = stored.size + raw.size
            )
            RawPointBadge(loading, raw.count { it.timestamp.time in startMs..endMs }, Modifier.align(Alignment.BottomStart))
        }
        TimeControlCard("分割点", hmText(Date(bounded)), hmText(footprint.startTime), hmText(footprint.endTime)) {
            if (canSplit) {
                Slider(
                    value = bounded.toFloat(),
                    onValueChange = { splitMs = minuteFloor(it.roundToLong()) },
                    valueRange = (startMs + minMs).toFloat()..(endMs - minMs).toFloat(),
                    colors = SliderDefaults.colors(thumbColor = DfkAccent, activeTrackColor = DfkAccent)
                )
            } else {
                Text("足迹时长过短，无法拆分", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SplitPreviewFootprintCard("新足迹", title, SplitBlue, Date(bounded), footprint.endTime, activities, secondActivity) { secondActivity = it }
        SplitPreviewFootprintCard("原足迹", title, SplitGreen, footprint.startTime, Date(bounded), activities, firstActivity) { firstActivity = it }
    }
}

@Composable
private fun SplitPreviewFootprintCard(
    segmentTitle: String,
    title: String,
    color: Color,
    start: Date,
    end: Date,
    activities: List<ActivityTypeEntity>,
    activityId: String?,
    onActivity: (String?) -> Unit
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(color.copy(alpha = 0.08f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(14.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(segmentTitle, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = color)
        Text(title, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("${hmText(start)}–${hmText(end)} · ${stayDurationText(end.time - start.time)}", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            ActivityChipSelector(activities, activityId, onActivity)
        }
    }
}

/** iOS TransportSplitView: map with both halves, "拆分时间" slider, 前半段/后半段 preview cards. */
@Composable
fun TransportSplitSheet(transport: TransportRecordEntity, onDismiss: () -> Unit, onSave: (Date) -> Unit) {
    val startMs = transport.startTime.time
    val endMs = transport.endTime.time
    val minMs = TimelineEditActions.MIN_TRANSPORT_SEGMENT_MS
    val canSplit = TimelineEditActions.canSplitTransport(transport)
    var splitMs by remember { mutableLongStateOf(TimelineEditActions.roundedToMinute(Date(startMs + (endMs - startMs) / 2)).time) }
    val points = remember(transport.pointsJson) { TimelineEditActions.parseRoutePoints(transport.pointsJson) }
    val bounded = if (canSplit) splitMs.coerceIn(startMs + minMs, endMs - minMs) else startMs
    val (firstRoute, secondRoute) = remember(points, bounded) {
        TimelineEditActions.splitRoutes(points, transport.startTime, Date(bounded), transport.endTime)
    }
    fun ll(p: List<TimelineEditActions.RoutePoint>) = p.map { LatLng(it.lat, it.lon) }
    EditorDialogScaffold("拆分交通", onDismiss, { onSave(Date(bounded)) }, canSplit) {
        Box(Modifier.fillMaxWidth().height(260.dp).clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))) {
            if (points.isNotEmpty()) {
                TrackPreviewMap(
                    segments = listOf(MapSegment(ll(firstRoute), SplitGreen, width = 10f), MapSegment(ll(secondRoute), SplitBlue, width = 10f)),
                    marker = firstRoute.lastOrNull()?.let { LatLng(it.lat, it.lon) },
                    markerColor = Color(0xFFFF9500),
                    modifier = Modifier.fillMaxSize(),
                    fitKey = points.size
                )
            }
        }
        TimeControlCard("拆分时间", hmText(Date(bounded)), hmText(transport.startTime), hmText(transport.endTime)) {
            if (canSplit) {
                Slider(
                    value = bounded.toFloat(),
                    onValueChange = { splitMs = minuteFloor(it.roundToLong()) },
                    valueRange = (startMs + minMs).toFloat()..(endMs - minMs).toFloat(),
                    colors = SliderDefaults.colors(thumbColor = DfkAccent, activeTrackColor = DfkAccent)
                )
            } else {
                Text("交通时长不足 2 分钟，无法拆分", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SplitPreviewTransportCard("前半段", transport.startTime, Date(bounded), TimelineEditActions.pathDistance(firstRoute), SplitGreen, Modifier.weight(1f))
            SplitPreviewTransportCard("后半段", Date(bounded), transport.endTime, TimelineEditActions.pathDistance(secondRoute), SplitBlue, Modifier.weight(1f))
        }
    }
}

@Composable
private fun SplitPreviewTransportCard(title: String, start: Date, end: Date, distance: Double, color: Color, modifier: Modifier) {
    Column(
        modifier.clip(RoundedCornerShape(14.dp)).background(color.copy(alpha = 0.08f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(14.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = color)
        Text("${hmText(start)}–${hmText(end)}", fontSize = 12.sp)
        Text(distanceText(distance), fontWeight = FontWeight.Bold, fontSize = 17.sp)
    }
}

/** Map with an orange marker + radius circle; camera span = radius × 6 (iOS MiniMapView). */
@Composable
fun PlaceRadiusMap(latitude: Double, longitude: Double, radius: Float, modifier: Modifier = Modifier, interactive: Boolean = false, onCameraCenter: ((Double, Double) -> Unit)? = null) {
    val isDark = isSystemInDarkTheme()
    var lastRadius by remember { mutableStateOf(-1f) }
    var lastCenter by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    AndroidView(
        factory = { ctx -> TextureMapView(ctx).apply { onResume() } },
        modifier = modifier,
        onRelease = { it.onPause(); it.onDestroy() }
    ) { view ->
        val map = view.map
        map.mapType = if (isDark) TencentMap.MAP_TYPE_DARK else TencentMap.MAP_TYPE_NORMAL
        map.uiSettings.apply {
            isZoomControlsEnabled = false
            isMyLocationButtonEnabled = false
            isRotateGesturesEnabled = false
            isTiltGesturesEnabled = false
            isScrollGesturesEnabled = interactive
            isZoomGesturesEnabled = interactive
        }
        map.clear()
        val center = LatLng(latitude, longitude)
        val orange = Color(0xFFFF9500)
        map.addCircle(
            CircleOptions().center(center).radius(radius.toDouble())
                .fillColor(orange.copy(alpha = 0.15f).toArgb()).strokeColor(orange.copy(alpha = 0.6f).toArgb()).strokeWidth(3f)
        )
        if (onCameraCenter == null) map.addMarker(MarkerOptions(center))
        val newCenter = latitude to longitude
        if (lastRadius != radius || (onCameraCenter == null && lastCenter != newCenter) || lastCenter == null) {
            val span = radius * 6.0
            val zoom = (log2(40_075_016.0 * kotlin.math.cos(Math.toRadians(latitude)) / span) - 0.5).toFloat().coerceIn(3f, 19f)
            map.moveCamera(CameraUpdateFactory.newLatLngZoom(center, zoom))
            lastRadius = radius
            lastCenter = newCenter
        }
        if (onCameraCenter != null) {
            map.setOnCameraChangeListener(object : TencentMap.OnCameraChangeListener {
                override fun onCameraChange(p0: com.tencent.tencentmap.mapsdk.maps.model.CameraPosition?) {}
                override fun onCameraChangeFinished(p0: com.tencent.tencentmap.mapsdk.maps.model.CameraPosition?) {
                    p0?.target?.let {
                        lastCenter = it.latitude to it.longitude
                        onCameraCenter(it.latitude, it.longitude)
                    }
                }
            })
        }
    }
}

/** iOS AddToFavoriteModal ("添加重要地点"). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AddImportantPlaceSheet(
    footprint: FootprintEntity,
    onDismiss: () -> Unit,
    onSave: (name: String, lat: Double, lon: Double, radius: Float, address: String?) -> Unit
) {
    val coord = remember(footprint.footprintID) { TimelineEditActions.representativeCoordinate(footprint) }
    var name by remember { mutableStateOf(footprint.address ?: "") }
    var radius by remember { mutableFloatStateOf(80f) }
    var address by remember { mutableStateOf("正在解析地址...") }
    LaunchedEffect(coord) {
        coord ?: return@LaunchedEffect
        address = runCatching { GeocodeService.shared.reverseGeocode(coord.first, coord.second) }.getOrNull() ?: ""
    }
    EditorDialogScaffold("添加重要地点", onDismiss, {
        coord?.let { onSave(name, it.first, it.second, radius, address.takeIf { a -> a.isNotBlank() && a != "正在解析地址..." }) }
    }, coord != null) {
        SectionLabel("位置预览")
        if (coord != null) {
            PlaceRadiusMap(coord.first, coord.second, radius, Modifier.fillMaxWidth().height(180.dp).clip(RoundedCornerShape(12.dp)))
        }
        Text(address, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        SectionLabel("地点名称")
        OutlinedTextField(name, { name = it }, placeholder = { Text("输入地点名称") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        SectionLabel("快速预设")
        PlacePresetChips(name) { name = it }
        SectionLabel("感知半径")
        RadiusSliderRow(radius) { radius = it }
        Text("进入该范围内时自动识别为此地点", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun SectionLabel(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Orange capsule presets 家 / 公司 / 学校. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PlacePresetChips(current: String, onPick: (String) -> Unit) {
    val orange = Color(0xFFFF9500)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("家", "公司", "学校").forEach { type ->
            val selected = current.trim() == type
            Surface(onClick = { onPick(type) }, shape = RoundedCornerShape(50), color = if (selected) orange else orange.copy(alpha = 0.1f)) {
                Text(type, color = if (selected) Color.White else orange, fontWeight = FontWeight.Bold, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
            }
        }
    }
}

@Composable
fun RadiusSliderRow(radius: Float, range: ClosedFloatingPointRange<Float> = 30f..300f, onChange: (Float) -> Unit) {
    val orange = Color(0xFFFF9500)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("${radius.toInt()} 米", color = orange, modifier = Modifier.widthIn(min = 56.dp))
        Slider(
            value = radius,
            onValueChange = { onChange((it / 10f).roundToLong() * 10f) },
            valueRange = range,
            colors = SliderDefaults.colors(thumbColor = orange, activeTrackColor = orange),
            modifier = Modifier.weight(1f)
        )
    }
}
