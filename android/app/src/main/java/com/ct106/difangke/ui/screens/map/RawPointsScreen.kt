package com.ct106.difangke.ui.screens.map

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
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
import android.widget.Toast
import com.amap.api.maps.AMap
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.TextureMapView
import com.amap.api.maps.model.*
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStreamWriter
import java.text.SimpleDateFormat
import java.util.*
import kotlin.math.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RawPointsScreen(
    date: Date,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val rawStore = remember { RawLocationStore.getInstance(context) }
    val allPlaces by remember { DiFangKeApp.instance.database.placeDao().observeAll() }
        .collectAsState(initial = emptyList())
    
    var points by remember { mutableStateOf<List<RawLocationStore.RawPoint>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var showOnlySuspicious by remember { mutableStateOf(false) }
    var selectedPoint by remember { mutableStateOf<RawLocationStore.RawPoint?>(null) }
    val exportDateFormat = remember { SimpleDateFormat("yyyy-MM-dd", Locale.US) }
    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/csv")
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.openOutputStream(uri)?.use { output ->
                        OutputStreamWriter(output, Charsets.UTF_8).use { writer ->
                            writer.write(rawPointsCsv(points))
                        }
                    } ?: error("无法打开导出文件")
                }
            }
            Toast.makeText(
                context,
                if (result.isSuccess) "轨迹点已导出" else "导出失败：${result.exceptionOrNull()?.localizedMessage ?: "未知错误"}",
                Toast.LENGTH_SHORT
            ).show()
        }
    }
    
    val filteredPoints = remember(points, showOnlySuspicious) {
        if (!showOnlySuspicious) points.mapIndexed { index, p -> index to p }
        else points.mapIndexed { index, p -> index to p }.filter { (index, p) -> isSuspicious(index, p, points) }
    }

    var amapInstance by remember { mutableStateOf<AMap?>(null) }

    LaunchedEffect(date) {
        isLoading = true
        points = withContext(Dispatchers.IO) {
            rawStore.loadLocations(date, filtered = false)
        }
        isLoading = false
    }

    LaunchedEffect(selectedPoint?.timestamp, showOnlySuspicious, filteredPoints) {
        val selectedTimestamp = selectedPoint?.timestamp ?: return@LaunchedEffect
        val filteredIndex = filteredPoints.indexOfFirst { (_, point) -> point.timestamp == selectedTimestamp }
        if (filteredIndex >= 0) {
            listState.animateScrollToItem(filteredIndex + 1)
        }
    }

    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)
    val primaryColor = MaterialTheme.colorScheme.primary

    Scaffold(
        topBar = {
            TopAppBar(
                title = { 
                    Column {
                        Text("原始轨迹点", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                        Text(SimpleDateFormat("M月d日", Locale.CHINA).format(date), style = MaterialTheme.typography.labelSmall, color = Color.Gray)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            exportLauncher.launch("DiFangKe_RawPoints_${exportDateFormat.format(date)}.csv")
                        },
                        enabled = points.isNotEmpty()
                    ) {
                        Icon(Icons.Default.FileDownload, contentDescription = "导出当天轨迹点")
                    }
                    IconButton(onClick = { showOnlySuspicious = !showOnlySuspicious }) {
                        Icon(
                            imageVector = if (showOnlySuspicious) Icons.Default.FilterList else Icons.Default.FilterListOff,
                            contentDescription = "过滤",
                            tint = if (showOnlySuspicious) MaterialTheme.colorScheme.primary else LocalContentColor.current
                        )
                    }
                }
            )
        }
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize().background(bgColor)) {
            // 地图预览 (固定)
            Box(modifier = Modifier.fillMaxWidth().height(220.dp)) {
                AndroidView(
                    factory = { ctx ->
                        TextureMapView(ctx).apply {
                            onCreate(android.os.Bundle())
                            val map = this.map
                            map.uiSettings.isZoomControlsEnabled = false
                            amapInstance = map
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                ) { view ->
                    val map = view.map
                    map.mapType = if (isDark) AMap.MAP_TYPE_NIGHT else AMap.MAP_TYPE_NORMAL
                    map.setOnMapClickListener { latLng ->
                        selectNearestPoint(
                            tappedLatLng = latLng,
                            candidates = filteredPoints,
                            onPointSelected = { point -> selectedPoint = point }
                        )
                    }
                    
                    map.clear()
                    map.addImportantPlaceCircles(allPlaces)

                    // 只有在点加载完成后更新
                    if (points.isNotEmpty()) {
                        val latLngs = points.map { LatLng(it.latitude, it.longitude) }
                        map.addPolyline(
                            PolylineOptions().addAll(latLngs).width(10f).color(primaryColor.toArgb()).useGradient(true)
                        )
                        
                        selectedPoint?.let { p ->
                            map.addMarker(MarkerOptions().position(LatLng(p.latitude, p.longitude)).icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_RED)))
                        }

                        // 如果是初次加载或切换过滤，自动缩放
                        if (selectedPoint == null) {
                            val bounds = LatLngBounds.builder().apply { latLngs.forEach { include(it) } }.build()
                            map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, 100))
                        }
                    }
                }
                
                // 恢复全景按钮
                IconButton(
                    onClick = {
                        selectedPoint = null
                        val latLngs = points.map { LatLng(it.latitude, it.longitude) }
                        if (latLngs.isNotEmpty()) {
                            val bounds = LatLngBounds.builder().apply { latLngs.forEach { include(it) } }.build()
                            scope.launch { amapInstance?.animateCamera(CameraUpdateFactory.newLatLngBounds(bounds, 100)) }
                        }
                    },
                    modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).background(MaterialTheme.colorScheme.surface.copy(alpha=0.7f), RoundedCornerShape(8.dp))
                ) {
                    Icon(Icons.Default.FullscreenExit, null)
                }
            }

            if (isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (points.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("该日期暂无轨迹数据", color = Color.Gray)
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize()
                ) {
                    item {
                        Text(
                            text = if (showOnlySuspicious) "筛选出 ${filteredPoints.size} 个疑似问题点" else "共 ${points.size} 个记录点",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (showOnlySuspicious) MaterialTheme.colorScheme.primary else Color.Gray,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                    
                    itemsIndexed(filteredPoints) { _, (originalIndex, point) ->
                        PointRow(
                            index = originalIndex,
                            point = point,
                            prevPoint = if (originalIndex > 0) points[originalIndex - 1] else null,
                            isSelected = selectedPoint?.timestamp == point.timestamp,
                            onClick = {
                                selectedPoint = point
                                scope.launch {
                                    amapInstance?.animateCamera(CameraUpdateFactory.newLatLngZoom(LatLng(point.latitude, point.longitude), 17f))
                                }
                            },
                            onDelete = {
                                scope.launch {
                                    withContext(Dispatchers.IO) {
                                        rawStore.deleteLocation(point.timestamp.time / 1000.0, date, context)
                                    }
                                    points = points.filter { it.timestamp != point.timestamp }
                                    if (selectedPoint?.timestamp == point.timestamp) selectedPoint = null
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

private fun rawPointsCsv(points: List<RawLocationStore.RawPoint>): String {
    val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).apply {
        timeZone = TimeZone.getDefault()
    }
    return buildString {
        appendLine("timestamp_iso,timestamp_unix,latitude,longitude,accuracy,speed")
        points.forEach { point ->
            append(isoFormatter.format(point.timestamp))
            append(',')
            append(String.format(Locale.US, "%.3f", point.timestamp.time / 1000.0))
            append(',')
            append(String.format(Locale.US, "%.8f", point.latitude))
            append(',')
            append(String.format(Locale.US, "%.8f", point.longitude))
            append(',')
            append(String.format(Locale.US, "%.2f", point.accuracy))
            append(',')
            append(String.format(Locale.US, "%.2f", point.speed))
            appendLine()
        }
    }
}

private fun selectNearestPoint(
    tappedLatLng: LatLng,
    candidates: List<Pair<Int, RawLocationStore.RawPoint>>,
    onPointSelected: (RawLocationStore.RawPoint) -> Unit
) {
    val closest = candidates.minByOrNull { (_, point) ->
        haversineMeters(tappedLatLng.latitude, tappedLatLng.longitude, point.latitude, point.longitude)
    } ?: return

    val distance = haversineMeters(
        tappedLatLng.latitude,
        tappedLatLng.longitude,
        closest.second.latitude,
        closest.second.longitude
    )

    if (distance < 1000.0) {
        onPointSelected(closest.second)
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun PointRow(
    index: Int,
    point: RawLocationStore.RawPoint,
    prevPoint: RawLocationStore.RawPoint?,
    isSelected: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val cardBg = if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.1f) else Color.Transparent
    
    val dismissState = rememberSwipeToDismissBoxState()
    
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.EndToStart) {
            onDelete()
            dismissState.reset()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (isDark) Color.Black else Color.White)
            .background(cardBg)
            .combinedClickable(
                onClick = onClick,
                onLongClick = { /* 可以加长按删除 */ }
            )
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Surface(
                shape = RoundedCornerShape(4.dp),
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
            ) {
                Text(
                    "#${index + 1}",
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            
            Spacer(Modifier.width(8.dp))
            
            Text(
                SimpleDateFormat("HH:mm:ss", Locale.CHINA).format(point.timestamp),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold
            )
            
            Spacer(Modifier.weight(1f))
            
            if (prevPoint != null) {
                val dist = haversineMeters(prevPoint.latitude, prevPoint.longitude, point.latitude, point.longitude)
                Text(
                    formatDistance(dist),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (dist > 1000) Color.Red else Color.Gray
                )
            }
        }
        
        Spacer(Modifier.height(4.dp))
        
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                String.format("%.6f, %.6f", point.latitude, point.longitude),
                style = MaterialTheme.typography.labelSmall,
                color = Color.Gray,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                modifier = Modifier.weight(1f)
            )
            
            Icon(Icons.Default.MyLocation, null, modifier = Modifier.size(10.dp), tint = Color.Gray)
            Spacer(Modifier.width(2.dp))
            Text(
                "${point.accuracy.toInt()}m",
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
                color = if (point.accuracy > 100) Color(0xFFFF9800) else Color.Gray
            )
        }
    }
}

private fun formatDistance(d: Double): String {
    return if (d < 1000) "+${d.toInt()}m"
    else String.format("+%.2fkm", d / 1000.0)
}

private fun isSuspicious(index: Int, point: RawLocationStore.RawPoint, allPoints: List<RawLocationStore.RawPoint>): Boolean {
    if (point.accuracy > 500) return true
    if (index > 0) {
        val prev = allPoints[index - 1]
        val dist = haversineMeters(prev.latitude, prev.longitude, point.latitude, point.longitude)
        val time = max(0.1, (point.timestamp.time - prev.timestamp.time) / 1000.0)
        val speed = dist / time
        if (speed > 70.0) return true // > 250km/h
        if (dist > 2000 && point.accuracy > 200) return true
    }
    return false
}

private fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val R = 6371000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = sin(dLat / 2).let { it * it } +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
            sin(dLon / 2).let { it * it }
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}
