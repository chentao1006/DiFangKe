package com.ct106.difangke.ui.screens.detail

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.ui.components.NearbyPlacePickerSheet
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import com.ct106.difangke.ui.shared.TimelineEditActions
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Full-screen route (NavGraph "transport_detail/{id}") wrapping [TransportDetailContent]. */
@Composable
fun TransportDetailScreen(
        transportId: String,
        onBack: () -> Unit
) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        TransportDetailContent(
                transportId = transportId,
                onDismiss = onBack,
                modifier = Modifier.fillMaxSize().statusBarsPadding(),
                showMap = true
        )
    }
}

/**
 * Reusable transport detail (iOS TransportModalView). Hosted full screen, or inside a
 * ModalBottomSheet over the main map with [showMap] = false. Every edit saves immediately
 * (no "保存"). [onDismiss] is also called once the record is deleted / gone.
 */
@Composable
internal fun TransportDetailContent(
        transportId: String,
        onDismiss: () -> Unit,
        modifier: Modifier = Modifier,
        showMap: Boolean = true,
        viewModel: TransportDetailViewModel = viewModel(key = "transport_detail_$transportId")
) {
    val transport by viewModel.transport.collectAsState()
    val mergePartner by viewModel.mergePartner.collectAsState()
    val isGone by viewModel.isGone.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()

    var showTimeAdjust by remember { mutableStateOf(false) }
    var showSplit by remember { mutableStateOf(false) }
    var showMergeAlert by remember { mutableStateOf(false) }
    var showDeleteAlert by remember { mutableStateOf(false) }
    var endpointPicker by remember { mutableStateOf<Boolean?>(null) } // true = start, false = end

    LaunchedEffect(transportId) { viewModel.loadTransport(transportId) }
    LaunchedEffect(isGone) { if (isGone) onDismiss() }

    val t = transport
    Column(modifier) {
        // ── Toolbar (iOS: inline title "交通详情" + xmark; edit actions in the ⋯ menu) ──
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.width(48.dp))
            Text("交通详情", fontWeight = FontWeight.Bold, fontSize = 17.sp, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            Box {
                var menu by remember { mutableStateOf(false) }
                IconButton(onClick = { menu = true }, enabled = t != null) { Icon(Icons.Default.MoreHoriz, contentDescription = "更多") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("调整时间") }, leadingIcon = { Icon(Icons.Default.Schedule, null) }, onClick = { menu = false; showTimeAdjust = true })
                    DropdownMenuItem(text = { Text("拆分交通") }, leadingIcon = { Icon(Icons.Default.ContentCut, null) }, onClick = { menu = false; showSplit = true })
                    if (mergePartner != null) {
                        DropdownMenuItem(text = { Text("合并相邻交通") }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.CallMerge, null) }, onClick = { menu = false; showMergeAlert = true })
                    }
                    DropdownMenuItem(
                        text = { Text("删除", color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menu = false; showDeleteAlert = true }
                    )
                }
            }
            IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "关闭") }
        }

        if (t == null) {
            Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Column
        }

        val pathPoints = remember(t.pointsJson) { parseTransportDetailPathPoints(t.pointsJson) }
        if (showMap) {
            // iOS: map fills the sheet, summary card floats over it via safeAreaInset(.bottom).
            Box(Modifier.fillMaxWidth().weight(1f)) {
                TransportDetailMapView(
                    points = pathPoints.map { it.coordinate },
                    pathPoints = pathPoints,
                    isDark = isSystemInDarkTheme(),
                    primaryColor = DfkAccent.toArgb(),
                    allPlaces = allPlaces
                )
                TransportSummaryCard(
                    t,
                    onEditTime = { showTimeAdjust = true },
                    onSelectType = viewModel::setType,
                    onEditEndpoint = { endpointPicker = it },
                    modifier = Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp).padding(bottom = 16.dp).navigationBarsPadding()
                )
            }
        } else {
            TransportSummaryCard(
                t,
                onEditTime = { showTimeAdjust = true },
                onSelectType = viewModel::setType,
                onEditEndpoint = { endpointPicker = it },
                modifier = Modifier.padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 16.dp)
            )
        }

        // ── Sheets & dialogs ──
        endpointPicker?.let { isStart ->
            val anchor = if (isStart) pathPoints.firstOrNull() else pathPoints.lastOrNull()
            if (anchor != null) {
                NearbyPlacePickerSheet(
                    latitude = anchor.coordinate.latitude,
                    longitude = anchor.coordinate.longitude,
                    savedPlaces = allPlaces,
                    onDismiss = { endpointPicker = null },
                    onSelect = { endpointPicker = null; viewModel.renameEndpoint(isStart, it.name) }
                )
            } else endpointPicker = null
        }
        if (showTimeAdjust) {
            TransportTimeAdjustSheet(t, onDismiss = { showTimeAdjust = false }) { s, e ->
                viewModel.adjustTime(s, e) { showTimeAdjust = false }
            }
        }
        if (showSplit) {
            TransportSplitSheet(t, onDismiss = { showSplit = false }) { split ->
                viewModel.splitAt(split) { showSplit = false }
            }
        }
        if (showMergeAlert) {
            val partner = mergePartner
            AlertDialog(
                onDismissRequest = { showMergeAlert = false },
                title = { Text("合并相邻交通？") },
                text = { Text(if (partner != null) TimelineEditActions.transportMergeMessage(t, partner) else "合并后会保留较早的交通，并删除另一条相邻交通。") },
                confirmButton = { TextButton(enabled = partner != null, onClick = { showMergeAlert = false; viewModel.mergeAdjacent() }) { Text("合并") } },
                dismissButton = { TextButton(onClick = { showMergeAlert = false }) { Text("取消") } }
            )
        }
        if (showDeleteAlert) {
            AlertDialog(
                onDismissRequest = { showDeleteAlert = false },
                title = { Text("确认删除交通？") },
                text = { Text("删除后，该交通记录将不再出现在时间轴上。") },
                confirmButton = {
                    TextButton(onClick = { showDeleteAlert = false; viewModel.deleteTransport() }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除") }
                },
                dismissButton = { TextButton(onClick = { showDeleteAlert = false }) { Text("取消") } }
            )
        }
    }
}

/** iOS TransportModalView bottom summary: time (tap to adjust) + type menu | distance, duration, speed, steps. */
@Composable
private fun TransportSummaryCard(
        t: TransportRecordEntity,
        onEditTime: () -> Unit,
        onSelectType: (TransportType) -> Unit,
        onEditEndpoint: (isStart: Boolean) -> Unit,
        modifier: Modifier = Modifier
) {
    val type = TransportType.from(t.manualTypeRaw ?: t.typeRaw)
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
        shadowElevation = 10.dp
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Endpoints (iOS saveLocationOverride via the place search sheet).
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                EndpointRow(t.startLocation, "起点", Color(0xFF34C759)) { onEditEndpoint(true) }
                EndpointRow(t.endLocation, "终点", Color(0xFF007AFF)) { onEditEndpoint(false) }
            }
            HorizontalDivider(color = secondary.copy(alpha = 0.12f))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(
                        Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onEditTime),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("${hmText(t.startTime)} - ${hmText(t.endTime)}", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        Spacer(Modifier.width(6.dp))
                        Icon(Icons.Default.Edit, "调整交通时间", Modifier.size(12.dp), tint = secondary.copy(alpha = 0.42f))
                    }
                    TransportTypeMenu(type, onSelectType)
                }
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(transportDistanceText(t.distance), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = DfkAccent)
                        Text(transportDurationText(t), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = secondary)
                    }
                    Text(
                        displayAverageSpeedKmh(t, type)?.let { String.format(Locale.CHINA, "%.1f 千米/小时", it) } ?: "速度未知",
                        fontSize = 15.sp,
                        color = secondary,
                        maxLines = 1
                    )
                    t.stepCount?.takeIf { it > 0 }?.let { steps ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, Modifier.size(13.dp), tint = Color(0xFFFF9500))
                            Text("$steps 步", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFFFF9500))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EndpointRow(name: String, placeholder: String, dot: Color, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(12.dp))
        Text(
            name.trim().ifEmpty { placeholder },
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = if (name.isBlank()) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        Icon(Icons.Default.Edit, "修改$placeholder", Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.42f))
    }
}

/** iOS type Menu: capsule with accent icon, bold name and up/down chevron; picking saves immediately. */
@Composable
private fun TransportTypeMenu(type: TransportType, onSelect: (TransportType) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Surface(onClick = { expanded = true }, shape = CircleShape, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.1f)) {
            Row(
                Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(getTransportIcon(type), null, Modifier.size(16.dp), tint = DfkAccent)
                Text(type.localizedName, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
                Icon(Icons.Default.UnfoldMore, null, Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            TransportType.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.localizedName) },
                    leadingIcon = { Icon(getTransportIcon(option), null, Modifier.size(18.dp)) },
                    trailingIcon = if (option == type) ({ Icon(Icons.Default.Check, null, Modifier.size(18.dp)) }) else null,
                    onClick = { expanded = false; if (option != type) onSelect(option) }
                )
            }
        }
    }
}

private fun transportDistanceText(meters: Double): String =
    if (meters < 1000) String.format(Locale.CHINA, "%.0f 米", meters) else String.format(Locale.CHINA, "%.1f 公里", meters / 1000.0)

/** iOS durationString: at least 1 minute. */
private fun transportDurationText(t: TransportRecordEntity): String {
    val minutes = maxOf(1L, (t.endTime.time - t.startTime.time) / 60_000L)
    return if (minutes >= 60) "${minutes / 60} 小时 ${minutes % 60} 分钟" else "$minutes 分钟"
}

/** iOS displayAverageSpeedKmh: hide non-finite / impossible-for-type averages (sparse reconstructed routes). */
private fun displayAverageSpeedKmh(t: TransportRecordEntity, type: TransportType): Double? {
    val kmh = t.averageSpeed * 3.6
    if (!kmh.isFinite() || kmh <= 0) return null
    val range = type.automaticSpeedRange
    if (range != null && kmh > range.endInclusive) return null
    return kmh
}

@Composable
fun TransportDetailMapView(
        points: List<com.tencent.tencentmap.mapsdk.maps.model.LatLng>,
        isDark: Boolean,
        primaryColor: Int,
        pathPoints: List<TransportDetailPathPoint> = emptyList(),
        startLocation: String? = null,
        endLocation: String? = null,
        allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity> = emptyList()
) {
    AndroidView(
            factory = { ctx ->
                com.tencent.tencentmap.mapsdk.maps.TextureMapView(ctx).apply {
                    onResume()
                }
            },
            modifier = Modifier.fillMaxSize(),
            onRelease = { view ->
                view.onPause()
                view.onDestroy()
            }
    ) { view ->
        val amap = view.map
        amap.mapType =
                if (isDark) com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_DARK
                else com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_NORMAL

        amap.uiSettings.apply {
            isZoomControlsEnabled = false
            isMyLocationButtonEnabled = false
            isRotateGesturesEnabled = false
            isTiltGesturesEnabled = false
        }

        amap.clear()
        amap.addImportantPlaceCircles(allPlaces)
        if (points.isNotEmpty()) {
            val segments =
                    if (pathPoints.size >= 2) {
                        pathPoints.zipWithNext { previous, current ->
                            val isDashed =
                                    previous.timestamp != null &&
                                            current.timestamp != null &&
                                            kotlin.math.abs(
                                                    current.timestamp - previous.timestamp
                                            ) > 5 * 60 * 1000L
                            listOf(previous.coordinate, current.coordinate) to isDashed
                        }
                    } else {
                        listOf(points to false)
                    }

            segments.forEach { (segment, isDashed) ->
                // iOS: accent stroke, 0.7 opacity solid / 0.4 opacity dashed for >5 min gaps.
                val alpha = if (isDashed) 0x66 else 0xB3
                val options =
                        com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions()
                                .addAll(segment)
                                .width(if (isDashed) 6f else 12f)
                                .color((primaryColor and 0x00FFFFFF) or (alpha shl 24))
                if (isDashed) options.lineType(com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions.LineType.LINE_TYPE_DOTTEDLINE)
                amap.addPolyline(options)
            }

            // Start Marker
            amap.addMarker(
                    com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions()
                            .position(points.first())
                            .anchor(0.5f, 0.5f)
                            .icon(
                                    com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory.defaultMarker(
                                            com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
                                                    .HUE_GREEN
                                    )
                            )
            )

            // End Marker (iOS: blue stop marker)
            if (points.size > 1) {
                amap.addMarker(
                        com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions()
                                .position(points.last())
                                .anchor(0.5f, 0.5f)
                                .icon(
                                        com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
                                                .defaultMarker(
                                                        com.tencent.tencentmap.mapsdk.maps.model
                                                                .BitmapDescriptorFactory.HUE_AZURE
                                                )
                                )
                )
            }

            // Camera - Jump immediately
            amap.moveCamera(
                    com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngZoom(points.first(), 15f)
            )

            // Camera - Bounds fit
            if (points.size > 1) {
                amap.addOnMapLoadedCallback {
                    try {
                        val builder = com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds.Builder()
                        points.forEach { builder.include(it) }
                        amap.animateCamera(
                                com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngBounds(
                                        builder.build(),
                                        250
                                )
                        )
                    } catch (e: Exception) {
                        Log.e("TransportDetail", "Bounds fit failed", e)
                    }
                }
            }

            // 重要地点名称通过腾讯 Marker 的标题展示。
            if (startLocation != null && points.isNotEmpty()) {
                val matched = allPlaces.find { it.isUserDefined && it.name == startLocation }
                if (matched != null) {
                    amap.addMarker(com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions().position(points.first()).title(startLocation))
                }
            }
            if (endLocation != null && points.size > 1) {
                val matched = allPlaces.find { it.isUserDefined && it.name == endLocation }
                if (matched != null) {
                    amap.addMarker(com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions().position(points.last()).title(endLocation))
                }
            }
        }
    }
}

data class TransportDetailPathPoint(
        val coordinate: com.tencent.tencentmap.mapsdk.maps.model.LatLng,
        val timestamp: Long? = null
)

private fun parseTransportDetailPathPoints(pointsJson: String): List<TransportDetailPathPoint> {
    val list = mutableListOf<TransportDetailPathPoint>()
    try {
        if (pointsJson.isEmpty() || pointsJson == "[]") return emptyList()

        val array = JSONArray(pointsJson)
        for (i in 0 until array.length()) {
            val element = array.get(i)

            if (element is JSONArray) {
                // Format: [[lat, lon], ...]
                val lat = element.getDouble(0)
                val lon = element.getDouble(1)
                val timestamp =
                        if (element.length() >= 3)
                                normalizeTransportTimestampMillis(element.optDouble(2, 0.0))
                        else null
                // Heuristic: swap if lat is likely lon (China specific or range check)
                if (Math.abs(lat) > 90.0) {
                    list.add(
                            TransportDetailPathPoint(
                                    com.tencent.tencentmap.mapsdk.maps.model.LatLng(lon, lat),
                                    timestamp
                            )
                    )
                } else {
                    list.add(
                            TransportDetailPathPoint(
                                    com.tencent.tencentmap.mapsdk.maps.model.LatLng(lat, lon),
                                    timestamp
                            )
                    )
                }
            } else if (element is JSONObject) {
                // Format: [{"lat": 1.0, "lon": 2.0}, ...] or [{"latitude": 1.0, "longitude": 2.0},
                // ...]
                val lat = element.optDouble("lat", element.optDouble("latitude", Double.NaN))
                val lon = element.optDouble("lon", element.optDouble("longitude", Double.NaN))
                val timestamp =
                        normalizeTransportTimestampMillis(element.optDouble("timestamp", 0.0))
                if (!lat.isNaN() && !lon.isNaN()) {
                    list.add(
                            TransportDetailPathPoint(
                                    com.tencent.tencentmap.mapsdk.maps.model.LatLng(lat, lon),
                                    timestamp
                            )
                    )
                }
            }
        }
    } catch (e: Exception) {
        Log.e("TransportDetail", "Critical: Failed to parse pointsJson. Input: $pointsJson", e)
    }
    return list
}

private fun normalizeTransportTimestampMillis(raw: Double): Long? {
    if (raw <= 0.0) return null
    return if (raw < 10_000_000_000.0) (raw * 1000).toLong() else raw.toLong()
}

@Composable
private fun getTransportIcon(type: TransportType) =
        when (type) {
            TransportType.SLOW -> Icons.AutoMirrored.Filled.DirectionsWalk
            TransportType.RUNNING -> Icons.AutoMirrored.Filled.DirectionsRun
            TransportType.BICYCLE -> Icons.AutoMirrored.Filled.DirectionsBike
            TransportType.EBIKE -> Icons.Default.ElectricMoped
            TransportType.MOTORCYCLE -> Icons.Default.TwoWheeler
            TransportType.BUS -> Icons.Default.DirectionsBus
            TransportType.CAR -> Icons.Default.DirectionsCar
            TransportType.SUBWAY -> Icons.Default.DirectionsSubway
            TransportType.TRAIN -> Icons.Default.Train
            TransportType.AIRPLANE -> Icons.Default.Flight
            TransportType.SHIP -> Icons.Default.DirectionsBoat
        }
