package com.ct106.difangke.ui.screens.detail

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.ui.components.getIconForName
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal val DfkAccent = Color(0xFF00A0AC)
internal val SplitBlue = Color(0xFF007AFF)
internal val SplitGreen = Color(0xFF34C759)

internal fun hmText(date: Date): String = SimpleDateFormat("HH:mm", Locale.CHINA).format(date)

internal fun parseHexColor(hex: String?, fallback: Color = Color.Gray): Color =
    runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(fallback)

internal fun distanceText(meters: Double): String =
    if (meters >= 1000) String.format(Locale.CHINA, "%.1f 公里", meters / 1000) else String.format(Locale.CHINA, "%.0f 米", meters)

/** iOS durationString: "X 小时 Y 分钟" / "X 小时" / "N 分钟". */
internal fun stayDurationText(ms: Long): String {
    val total = (ms / 60_000L).toInt()
    return if (total >= 60) {
        val h = total / 60
        val m = total % 60
        if (m > 0) "$h 小时 $m 分钟" else "$h 小时"
    } else "${maxOf(1, total)} 分钟"
}

private fun dotBitmap(color: Int, diameterPx: Int): Bitmap {
    val bmp = Bitmap.createBitmap(diameterPx, diameterPx, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val r = diameterPx / 2f
    c.drawCircle(r, r, r, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = android.graphics.Color.WHITE })
    c.drawCircle(r, r, r * 0.72f, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
    return bmp
}

/** A polyline segment drawn on [TrackPreviewMap]. */
data class MapSegment(val points: List<LatLng>, val color: Color, val dashed: Boolean = false, val width: Float = 10f)

/** A dot marker drawn on [TrackPreviewMap]. */
data class MapDot(val point: LatLng, val color: Color, val diameterDp: Int = 10)

/**
 * Small Tencent map preview used by time-adjust / split / place sheets.
 * Camera fits all segments + dots (+ marker) whenever the content changes.
 */
@Composable
fun TrackPreviewMap(
    segments: List<MapSegment>,
    modifier: Modifier = Modifier,
    dots: List<MapDot> = emptyList(),
    marker: LatLng? = null,
    markerColor: Color = Color.Red,
    interactive: Boolean = true,
    fitKey: Any? = null
) {
    val isDark = isSystemInDarkTheme()
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    var lastFit by remember { mutableStateOf<Any?>(Unit) }
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
        segments.filter { it.points.size >= 2 }.forEach { s ->
            val opts = PolylineOptions().addAll(s.points).width(s.width).color(s.color.toArgb())
            if (s.dashed) opts.lineType(PolylineOptions.LineType.LINE_TYPE_DOTTEDLINE)
            map.addPolyline(opts)
        }
        val descriptorCache = HashMap<Pair<Int, Int>, com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptor>()
        dots.forEach { d ->
            val px = (d.diameterDp * density).toInt().coerceAtLeast(4)
            val desc = descriptorCache.getOrPut(d.color.toArgb() to px) { BitmapDescriptorFactory.fromBitmap(dotBitmap(d.color.toArgb(), px)) }
            map.addMarker(MarkerOptions(d.point).icon(desc).anchor(0.5f, 0.5f))
        }
        marker?.let {
            val px = (18 * density).toInt()
            map.addMarker(MarkerOptions(it).icon(BitmapDescriptorFactory.fromBitmap(dotBitmap(markerColor.toArgb(), px))).anchor(0.5f, 0.5f).zIndex(10f))
        }
        val all = segments.flatMap { it.points } + dots.map { it.point } + listOfNotNull(marker)
        val key = fitKey ?: all.size
        if (all.isNotEmpty() && lastFit != key) {
            lastFit = key
            if (all.size == 1 || all.all { it.latitude == all[0].latitude && it.longitude == all[0].longitude }) {
                map.moveCamera(CameraUpdateFactory.newLatLngZoom(all[0], 17f))
            } else {
                val b = LatLngBounds.Builder()
                all.forEach { b.include(it) }
                val bounds = b.build()
                view.post {
                    runCatching {
                        map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, (40 * density).toInt()))
                        if (map.cameraPosition.zoom > 18f) map.moveCamera(CameraUpdateFactory.zoomTo(18f))
                    }
                }
            }
        }
    }
}

/** Black capsule badge "N 个原始点" / "加载轨迹点...". */
@Composable
internal fun RawPointBadge(loading: Boolean, count: Int, modifier: Modifier = Modifier) {
    Text(
        if (loading) "加载轨迹点..." else "$count 个原始点",
        color = Color.White,
        fontSize = 12.sp,
        fontWeight = FontWeight.Bold,
        modifier = modifier
            .padding(12.dp)
            .background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 6.dp)
    )
}

/** Full-screen editor scaffold with ✕ (leading) and ✓ (trailing), iOS NavigationStack sheet style. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorDialogScaffold(
    title: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
    confirmEnabled: Boolean,
    busy: Boolean = false,
    content: @Composable ColumnScope.() -> Unit
) {
    Dialog(onDismissRequest = { if (!busy) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize()) {
                CenterAlignedTopAppBar(
                    title = { Text(title, fontWeight = FontWeight.Bold, fontSize = 17.sp) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss, enabled = !busy) { Icon(Icons.Default.Close, contentDescription = "关闭") }
                    },
                    actions = {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(22.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(12.dp))
                        } else {
                            IconButton(onClick = onConfirm, enabled = confirmEnabled) {
                                Icon(Icons.Default.Check, contentDescription = "确认", tint = if (confirmEnabled) DfkAccent else Color.Gray)
                            }
                        }
                    }
                )
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                    content = content
                )
            }
        }
    }
}

/** Grey rounded card with "调整时间"/"分割点" title + big monospaced value, slider and range labels. */
@Composable
internal fun TimeControlCard(
    label: String,
    value: String,
    leftLabel: String,
    rightLabel: String,
    slider: @Composable () -> Unit
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text(value, fontSize = 22.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
        }
        Box(Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.Center) { slider() }
        Row {
            Text(leftLabel, fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text(rightLabel, fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * iOS StableActivityPickerPopover: 无 / 推荐活动 / 所有活动 / 添加活动类型.
 * [onAdd] null hides the "添加活动类型" row.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityPickerSheet(
    suggested: List<ActivityTypeEntity>,
    all: List<ActivityTypeEntity>,
    selectedId: String?,
    onDismiss: () -> Unit,
    onSelect: (String?) -> Unit,
    onAdd: (() -> Unit)? = null
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            PickerRow("无", Icons.Default.Block, null, selectedId == null) { onSelect(null); onDismiss() }
            if (suggested.isNotEmpty()) {
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                PickerSectionTitle("推荐活动")
                suggested.forEach { t ->
                    PickerRow(t.name, getIconForName(t.icon), parseHexColor(t.colorHex), selectedId == t.id) { onSelect(t.id); onDismiss() }
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 4.dp))
            if (all.isEmpty()) {
                PickerRow("暂无活动类型", Icons.Default.ErrorOutline, null, false) {}
            } else {
                PickerSectionTitle("所有活动")
                all.forEach { t ->
                    PickerRow(t.name, getIconForName(t.icon), parseHexColor(t.colorHex), selectedId == t.id) { onSelect(t.id); onDismiss() }
                }
            }
            if (onAdd != null) {
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                PickerRow("添加活动类型", Icons.Default.Add, null, false) { onDismiss(); onAdd() }
            }
        }
    }
}

@Composable
private fun PickerSectionTitle(title: String) {
    Text(
        title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
    )
}

@Composable
private fun PickerRow(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color?, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, null, tint = tint ?: MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Text(title, modifier = Modifier.weight(1f))
        if (selected) Icon(Icons.Default.Check, null, tint = DfkAccent)
    }
}

/** Compact activity selector used in split preview cards. */
@Composable
internal fun ActivityChipSelector(
    activities: List<ActivityTypeEntity>,
    selectedId: String?,
    onSelect: (String?) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val selected = activities.firstOrNull { it.id == selectedId }
    Box {
        Surface(onClick = { expanded = true }, shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (selected != null) getIconForName(selected.icon) else Icons.Default.HelpOutline,
                    null, Modifier.size(16.dp), tint = selected?.let { parseHexColor(it.colorHex) } ?: Color.Gray
                )
                Spacer(Modifier.width(6.dp))
                Text(selected?.name ?: "选择活动", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Icon(Icons.Default.UnfoldMore, null, Modifier.size(14.dp), tint = Color.Gray)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("无") }, leadingIcon = { Icon(Icons.Default.Block, null) }, onClick = { onSelect(null); expanded = false })
            activities.forEach { t ->
                DropdownMenuItem(
                    text = { Text(t.name) },
                    leadingIcon = { Icon(getIconForName(t.icon), null, tint = parseHexColor(t.colorHex)) },
                    trailingIcon = { if (t.id == selectedId) Icon(Icons.Default.Check, null) },
                    onClick = { onSelect(t.id); expanded = false }
                )
            }
        }
    }
}

/** iOS PhotoFullscreenView: swipeable full-screen viewer. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PhotoPagerViewer(uris: List<String>, initialIndex: Int, onDismiss: () -> Unit) {
    if (uris.isEmpty()) return
    val pager = rememberPagerState(initialPage = initialIndex.coerceIn(0, uris.lastIndex)) { uris.size }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
                val uri = uris[page]
                AndroidView(
                    factory = { ctx ->
                        android.widget.ImageView(ctx).apply { scaleType = android.widget.ImageView.ScaleType.FIT_CENTER }
                    },
                    update = { iv -> runCatching { iv.setImageURI(android.net.Uri.parse(uri)) } },
                    modifier = Modifier.fillMaxSize()
                )
            }
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(16.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape)
            ) { Icon(Icons.Default.Close, contentDescription = "关闭照片", tint = Color.White) }
            if (uris.size > 1) {
                Text(
                    "${pager.currentPage + 1} / ${uris.size}", color = Color.White, fontSize = 13.sp,
                    modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(24.dp)
                )
            }
        }
    }
}
