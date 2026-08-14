package com.ct106.difangke.ui.screens.detail

import android.os.Bundle
import android.util.Log
import androidx.compose.foundation.background
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import java.text.SimpleDateFormat
import java.util.*
import org.json.JSONArray
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransportDetailScreen(
        transportId: String,
        onBack: () -> Unit,
        viewModel: TransportDetailViewModel = viewModel()
) {
    val transport by viewModel.transport.collectAsState()
    val adjacentTransports by viewModel.adjacentTransports.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val isDark = isSystemInDarkTheme()

    var localStartName by remember { mutableStateOf("") }
    var localEndName by remember { mutableStateOf("") }
    var selectedType by remember { mutableStateOf<TransportType?>(null) }
    var showingDeleteAlert by remember { mutableStateOf(false) }
    var showingMoreMenu by remember { mutableStateOf(false) }
    var pendingMerge by remember { mutableStateOf<TransportRecordEntity?>(null) }
    var showingTimeDialog by remember { mutableStateOf(false) }
    var showingSplitDialog by remember { mutableStateOf(false) }

    LaunchedEffect(transportId) { viewModel.loadTransport(transportId) }

    LaunchedEffect(transport) {
        transport?.let {
            localStartName = it.startLocation
            localEndName = it.endLocation
            selectedType = TransportType.from(it.manualTypeRaw ?: it.typeRaw)
        }
    }

    if (transport == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }

    val t = transport!!
    val pathPoints = remember(t.pointsJson) { parseTransportDetailPathPoints(t.pointsJson) }
    val points = remember(pathPoints) { pathPoints.map { it.coordinate } }

    Box(modifier = Modifier.fillMaxSize()) {
        // 1. Full Screen Map Layer
        TransportDetailMapView(
                points = points,
                pathPoints = pathPoints,
                isDark = isDark,
                primaryColor = MaterialTheme.colorScheme.primary.toArgb(),
                startLocation = t.startLocation,
                endLocation = t.endLocation,
                allPlaces = allPlaces
        )

        // 2. Scrim (Optional: Top bar readability)
        Box(
                modifier =
                        Modifier.fillMaxWidth()
                                .height(120.dp)
                                .background(
                                        Brush.verticalGradient(
                                                colors =
                                                        listOf(
                                                                Color.Black.copy(
                                                                        alpha =
                                                                                if (isDark) 0.5f
                                                                                else 0.15f
                                                                ),
                                                                Color.Transparent
                                                        )
                                        )
                                )
        )

        // 3. Top Navigation Bar
        CenterAlignedTopAppBar(
                title = { Text("交通详情", fontWeight = FontWeight.Bold, fontSize = 18.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { showingMoreMenu = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = "更多操作")
                        }
                        DropdownMenu(
                            expanded = showingMoreMenu,
                            onDismissRequest = { showingMoreMenu = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("调整时间") },
                                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                                onClick = {
                                    showingMoreMenu = false
                                    showingTimeDialog = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("拆分交通") },
                                leadingIcon = { Icon(Icons.Default.ContentCut, contentDescription = null) },
                                onClick = {
                                    showingMoreMenu = false
                                    showingSplitDialog = true
                                }
                            )
                            adjacentTransports.sortedBy { it.startTime }.forEach { candidate ->
                                DropdownMenuItem(
                                    text = { Text("合并 ${if (candidate.startTime < t.startTime) "上一段" else "下一段"}交通") },
                                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.CallMerge, contentDescription = null) },
                                    onClick = {
                                        showingMoreMenu = false
                                        pendingMerge = candidate
                                    }
                                )
                            }
                        }
                    }
                    TextButton(
                            onClick = {
                                viewModel.updateTransport(
                                        selectedType,
                                        localStartName,
                                        localEndName
                                )
                                onBack()
                            }
                    ) { Text("保存", fontWeight = FontWeight.Bold) }
                },
                colors =
                        TopAppBarDefaults.centerAlignedTopAppBarColors(
                                containerColor = Color.Transparent,
                                titleContentColor = if (isDark) Color.White else Color.Black,
                                navigationIconContentColor =
                                        if (isDark) Color.White else Color.Black,
                                actionIconContentColor = MaterialTheme.colorScheme.primary
                        )
        )

        // 4. Bottom Info Card
        Column(
                modifier =
                        Modifier.align(Alignment.BottomCenter)
                                .padding(horizontal = 16.dp, vertical = 24.dp)
        ) {
            // Delete Action (Small floating button)
            Surface(
                    onClick = { showingDeleteAlert = true },
                    modifier = Modifier.align(Alignment.End).padding(bottom = 12.dp),
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.9f),
                    tonalElevation = 8.dp
            ) {
                Icon(
                        Icons.Default.Delete,
                        contentDescription = "删除",
                        modifier = Modifier.padding(10.dp).size(20.dp),
                        tint = MaterialTheme.colorScheme.error
                )
            }

            // Main Details Card (Translucent look)
            Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(28.dp),
                    color = (if (isDark) Color(0xFF1C1C1E) else Color.White).copy(alpha = 0.95f),
                    shadowElevation = 12.dp,
                    tonalElevation = 4.dp
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    // Start/End Locations
                    LocationEditSection(
                            startName = localStartName,
                            onStartChange = { localStartName = it },
                            endName = localEndName,
                            onEndChange = { localEndName = it }
                    )

                    HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp).alpha(0.1f))

                    // Bottom info row
                    Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Left: Time & Type
                        Column {
                            val timeFormat = SimpleDateFormat("HH:mm", Locale.CHINA)
                            Text(
                                    text =
                                            "${timeFormat.format(t.startTime)} - ${timeFormat.format(t.endTime)}",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold
                            )
                            Spacer(Modifier.height(4.dp))

                            // Interactive Type Picker
                            TransportTypeChip(
                                    type = selectedType ?: TransportType.CAR,
                                    onSelect = { selectedType = it }
                            )
                        }

                        // Right: Stats
                        Column(horizontalAlignment = Alignment.End) {
                            val dist =
                                    if (t.distance < 1000) "${t.distance.toInt()} 米"
                                    else String.format("%.1f 公里", t.distance / 1000.0)
                            Text(
                                    text = dist,
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.ExtraBold,
                                    color = MaterialTheme.colorScheme.primary,
                                    letterSpacing = (-0.5).sp
                            )
                            Text(
                                    text = String.format("平均速度 %.1f 千米/小时", t.averageSpeed * 3.6),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color.Gray
                            )

                            if ((t.stepCount ?: 0) > 0) {
                                Spacer(Modifier.height(4.dp))
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                            Icons.AutoMirrored.Filled.DirectionsWalk,
                                            null,
                                            Modifier.size(12.dp),
                                            tint = Color(0xFFF2A900)
                                    )
                                    Text(
                                            text = "${t.stepCount} 步",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = Color(0xFFF2A900),
                                            fontWeight = FontWeight.Bold
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showingDeleteAlert) {
        AlertDialog(
                onDismissRequest = { showingDeleteAlert = false },
                title = { Text("删除记录") },
                text = { Text("确定要删除这段交通记录吗？") },
                confirmButton = {
                    TextButton(
                            onClick = {
                                viewModel.deleteTransport()
                                onBack()
                                showingDeleteAlert = false
                            },
                            colors =
                                    ButtonDefaults.textButtonColors(
                                            contentColor = MaterialTheme.colorScheme.error
                                    )
                    ) { Text("删除") }
                },
                dismissButton = {
                    TextButton(onClick = { showingDeleteAlert = false }) { Text("取消") }
                }
        )
    }

    pendingMerge?.let { candidate ->
        val timeFormat = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
        AlertDialog(
            onDismissRequest = { pendingMerge = null },
            title = { Text("合并相邻交通") },
            text = {
                Text(
                    "将合并 ${timeFormat.format(t.startTime)}-${timeFormat.format(t.endTime)} 和 " +
                        "${timeFormat.format(candidate.startTime)}-${timeFormat.format(candidate.endTime)}。合并后会保留为手动编辑，自动重建不会覆盖它。"
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.mergeWith(candidate) { pendingMerge = null }
                }) { Text("合并") }
            },
            dismissButton = { TextButton(onClick = { pendingMerge = null }) { Text("取消") } }
        )
    }

    if (showingTimeDialog) {
        TransportTimeAdjustDialog(
            transport = t,
            adjacent = adjacentTransports,
            onDismiss = { showingTimeDialog = false },
            onSave = { start, end -> viewModel.adjustTime(start, end) { showingTimeDialog = false } }
        )
    }

    if (showingSplitDialog) {
        TransportSplitDialog(
            transport = t,
            onDismiss = { showingSplitDialog = false },
            onSave = { split -> viewModel.splitAt(split) { showingSplitDialog = false } }
        )
    }
}

@Composable
private fun TransportSplitDialog(
    transport: TransportRecordEntity,
    onDismiss: () -> Unit,
    onSave: (Date) -> Unit
) {
    val formatter = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
    val minutes = ((transport.endTime.time - transport.startTime.time) / 60_000L).toInt()
    val canSplit = minutes >= 2
    var splitMinute by remember(transport.recordID) {
        mutableFloatStateOf((minutes / 2).coerceIn(1, maxOf(1, minutes - 1)).toFloat())
    }
    val split = Date(transport.startTime.time + splitMinute.toLong() * 60_000L)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("拆分交通") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (!canSplit) {
                    Text("这段交通太短，无法拆分。")
                } else {
                    Text("拆分点 ${formatter.format(split)}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Slider(
                        value = splitMinute,
                        onValueChange = { splitMinute = it.coerceIn(1f, (minutes - 1).toFloat()) },
                        valueRange = 1f..(minutes - 1).toFloat(),
                        steps = maxOf(0, minutes - 3)
                    )
                }
            }
        },
        confirmButton = { TextButton(enabled = canSplit, onClick = { onSave(split) }) { Text("拆分") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
private fun TransportTimeAdjustDialog(
    transport: TransportRecordEntity,
    adjacent: List<TransportRecordEntity>,
    onDismiss: () -> Unit,
    onSave: (Date, Date) -> Unit
) {
    val formatter = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
    val dayStart = remember(transport.startTime) {
        Calendar.getInstance().apply {
            time = transport.startTime
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
    }
    val dayEnd = remember(dayStart) { Date(dayStart.time + 24 * 60 * 60_000L) }
    val previousEnd = adjacent.filter { it.endTime <= transport.startTime }.maxByOrNull { it.endTime.time }?.endTime
    val nextStart = adjacent.filter { it.startTime >= transport.endTime }.minByOrNull { it.startTime.time }?.startTime
    val rangeStart = maxOf(dayStart.time, previousEnd?.time ?: dayStart.time)
    val rangeEnd = minOf(dayEnd.time, nextStart?.time ?: dayEnd.time)
    val totalMinutes = maxOf(1, ((rangeEnd - rangeStart) / 60_000L).toInt())
    var startMinute by remember(transport.recordID, rangeStart) {
        mutableFloatStateOf(((transport.startTime.time - rangeStart) / 60_000L).coerceIn(0L, (totalMinutes - 1).toLong()).toFloat())
    }
    var endMinute by remember(transport.recordID, rangeStart) {
        mutableFloatStateOf(((transport.endTime.time - rangeStart) / 60_000L).coerceIn(1L, totalMinutes.toLong()).toFloat())
    }
    if (endMinute <= startMinute) endMinute = startMinute + 1
    val start = Date(rangeStart + startMinute.toLong() * 60_000L)
    val end = Date(rangeStart + endMinute.toLong() * 60_000L)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("调整交通时间") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("可调整范围 ${formatter.format(Date(rangeStart))}-${formatter.format(Date(rangeEnd))}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("${formatter.format(start)} - ${formatter.format(end)}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("开始", style = MaterialTheme.typography.labelMedium)
                Slider(value = startMinute, onValueChange = { startMinute = it.coerceIn(0f, endMinute - 1f) }, valueRange = 0f..totalMinutes.toFloat(), steps = maxOf(0, totalMinutes - 1))
                Text("结束", style = MaterialTheme.typography.labelMedium)
                Slider(value = endMinute, onValueChange = { endMinute = it.coerceIn(startMinute + 1f, totalMinutes.toFloat()) }, valueRange = 0f..totalMinutes.toFloat(), steps = maxOf(0, totalMinutes - 1))
            }
        },
        confirmButton = { TextButton(onClick = { onSave(start, end) }) { Text("保存") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
fun LocationEditSection(
        startName: String,
        onStartChange: (String) -> Unit,
        endName: String,
        onEndChange: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        // Start
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF34C759)))
            Spacer(Modifier.width(12.dp))
            TextField(
                    value = startName,
                    onValueChange = onStartChange,
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    placeholder = { Text("起点位置") },
                    colors = textFieldColors(),
                    textStyle =
                            MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                    singleLine = true
            )
        }

        // Vertical path dotted line (Simulation)
        Box(
                Modifier.padding(start = 3.dp)
                        .width(1.dp)
                        .height(8.dp)
                        .background(Color.Gray.copy(alpha = 0.3f))
        )

        // End
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF007AFF)))
            Spacer(Modifier.width(12.dp))
            TextField(
                    value = endName,
                    onValueChange = onEndChange,
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    placeholder = { Text("终点位置") },
                    colors = textFieldColors(),
                    textStyle =
                            MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                    singleLine = true
            )
        }
    }
}

@Composable
fun textFieldColors() =
        TextFieldDefaults.colors(
                focusedContainerColor = Color.Transparent,
                unfocusedContainerColor = Color.Transparent,
                disabledContainerColor = Color.Transparent,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                cursorColor = MaterialTheme.colorScheme.primary
        )

@Composable
fun TransportTypeChip(type: TransportType, onSelect: (TransportType) -> Unit) {
    var expanded by remember { mutableStateOf(false) }

    Box {
        Surface(
                onClick = { expanded = true },
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                shape = RoundedCornerShape(12.dp)
        ) {
            Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                        imageVector = getTransportIcon(type),
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.primary
                )
                Text(
                        text = type.localizedName,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.Bold
                )
                Icon(
                        Icons.Default.KeyboardArrowDown,
                        null,
                        Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.primary
                )
            }
        }

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            TransportType.entries.forEach { t ->
                DropdownMenuItem(
                        text = { Text(t.localizedName) },
                        onClick = {
                            onSelect(t)
                            expanded = false
                        },
                        leadingIcon = {
                            Icon(getTransportIcon(t), null, modifier = Modifier.size(18.dp))
                        }
                )
            }
        }
    }
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
                val options =
                        com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions()
                                .addAll(segment)
                                .width(18f)
                                .color(primaryColor)
                                .gradient(!isDashed)
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

            // End Marker
            if (points.size > 1) {
                amap.addMarker(
                        com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions()
                                .position(points.last())
                                .anchor(0.5f, 0.5f)
                                .icon(
                                        com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
                                                .defaultMarker(
                                                        com.tencent.tencentmap.mapsdk.maps.model
                                                                .BitmapDescriptorFactory.HUE_RED
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
