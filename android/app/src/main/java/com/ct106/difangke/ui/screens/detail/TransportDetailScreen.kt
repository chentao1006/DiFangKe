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
    val allPlaces by viewModel.allPlaces.collectAsState()
    val isDark = isSystemInDarkTheme()

    var localStartName by remember { mutableStateOf("") }
    var localEndName by remember { mutableStateOf("") }
    var selectedType by remember { mutableStateOf<TransportType?>(null) }
    var showingDeleteAlert by remember { mutableStateOf(false) }

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
        points: List<com.amap.api.maps.model.LatLng>,
        isDark: Boolean,
        primaryColor: Int,
        pathPoints: List<TransportDetailPathPoint> = emptyList(),
        startLocation: String? = null,
        endLocation: String? = null,
        allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity> = emptyList()
) {
    AndroidView(
            factory = { ctx ->
                com.amap.api.maps.TextureMapView(ctx).apply {
                    onCreate(Bundle())
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
                if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT
                else com.amap.api.maps.AMap.MAP_TYPE_NORMAL

        amap.uiSettings.apply {
            isZoomControlsEnabled = false
            isMyLocationButtonEnabled = false
            isRotateGesturesEnabled = false
            isTiltGesturesEnabled = false
            setLogoBottomMargin(-100) // Hide logo if possible or move it out
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
                        com.amap.api.maps.model.PolylineOptions()
                                .addAll(segment)
                                .width(18f)
                                .color(primaryColor)
                                .lineJoinType(
                                        com.amap.api.maps.model.PolylineOptions.LineJoinType
                                                .LineJoinRound
                                )
                                .useGradient(!isDashed)
                if (isDashed) {
                    options.setDottedLine(true)
                }
                amap.addPolyline(options)
            }

            // Start Marker
            amap.addMarker(
                    com.amap.api.maps.model.MarkerOptions()
                            .position(points.first())
                            .anchor(0.5f, 0.5f)
                            .icon(
                                    com.amap.api.maps.model.BitmapDescriptorFactory.defaultMarker(
                                            com.amap.api.maps.model.BitmapDescriptorFactory
                                                    .HUE_GREEN
                                    )
                            )
            )

            // End Marker
            if (points.size > 1) {
                amap.addMarker(
                        com.amap.api.maps.model.MarkerOptions()
                                .position(points.last())
                                .anchor(0.5f, 0.5f)
                                .icon(
                                        com.amap.api.maps.model.BitmapDescriptorFactory
                                                .defaultMarker(
                                                        com.amap.api.maps.model
                                                                .BitmapDescriptorFactory.HUE_RED
                                                )
                                )
                )
            }

            // Camera - Jump immediately
            amap.moveCamera(
                    com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points.first(), 15f)
            )

            // Camera - Bounds fit
            if (points.size > 1) {
                amap.setOnMapLoadedListener {
                    try {
                        val builder = com.amap.api.maps.model.LatLngBounds.Builder()
                        points.forEach { builder.include(it) }
                        amap.animateCamera(
                                com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(
                                        builder.build(),
                                        250
                                )
                        )
                    } catch (e: Exception) {
                        Log.e("TransportDetail", "Bounds fit failed", e)
                    }
                }
            }

            // 重要地点文字标识 (Orange Text Labels)
            val orangeColor = 0xFFFF9800.toInt()
            if (startLocation != null && points.isNotEmpty()) {
                val matched = allPlaces.find { it.isUserDefined && it.name == startLocation }
                if (matched != null) {
                    amap.addText(
                            com.amap.api.maps.model.TextOptions()
                                    .position(points.first())
                                    .text(startLocation)
                                    .fontColor(orangeColor)
                                    .fontSize(34)
                                    .align(
                                            com.amap.api.maps.model.Text.ALIGN_CENTER_HORIZONTAL,
                                            com.amap.api.maps.model.Text.ALIGN_BOTTOM
                                    )
                    )
                }
            }
            if (endLocation != null && points.size > 1) {
                val matched = allPlaces.find { it.isUserDefined && it.name == endLocation }
                if (matched != null) {
                    amap.addText(
                            com.amap.api.maps.model.TextOptions()
                                    .position(points.last())
                                    .text(endLocation)
                                    .fontColor(orangeColor)
                                    .fontSize(34)
                                    .align(
                                            com.amap.api.maps.model.Text.ALIGN_CENTER_HORIZONTAL,
                                            com.amap.api.maps.model.Text.ALIGN_BOTTOM
                                    )
                    )
                }
            }
        }
    }
}

data class TransportDetailPathPoint(
        val coordinate: com.amap.api.maps.model.LatLng,
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
                                    com.amap.api.maps.model.LatLng(lon, lat),
                                    timestamp
                            )
                    )
                } else {
                    list.add(
                            TransportDetailPathPoint(
                                    com.amap.api.maps.model.LatLng(lat, lon),
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
                                    com.amap.api.maps.model.LatLng(lat, lon),
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
