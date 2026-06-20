package com.ct106.difangke.ui.screens.map

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.FilterListOff
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.amap.api.maps.AMap
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.TextureMapView
import com.amap.api.maps.model.BitmapDescriptorFactory
import com.amap.api.maps.model.CircleOptions
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.LatLngBounds
import com.amap.api.maps.model.MarkerOptions
import com.amap.api.maps.model.PolylineOptions
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStreamWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

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

    var entries by remember { mutableStateOf<List<RawLocationStore.RawPointEntry>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var showOnlySuspicious by remember { mutableStateOf(false) }
    var selectedPoint by remember { mutableStateOf<RawLocationStore.RawPoint?>(null) }
    var isSelecting by remember { mutableStateOf(false) }
    var selectedIndexes by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var isBatchDeleting by remember { mutableStateOf(false) }
    var amapInstance by remember { mutableStateOf<AMap?>(null) }

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
                            writer.write(rawPointsEntryCsv(entries))
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

    val driftCount = remember(entries) { entries.count { it.isDriftPoint } }
    val filteredEntries = remember(entries, showOnlySuspicious) {
        if (!showOnlySuspicious) entries
        else entries.filter { entry -> entry.isDriftPoint || isSuspiciousEntry(entry, entries) }
    }

    LaunchedEffect(date) {
        isLoading = true
        entries = withContext(Dispatchers.IO) { rawStore.loadLocationsWithDriftFlags(date) }
        selectedPoint = null
        selectedIndexes = emptySet()
        isSelecting = false
        isLoading = false
    }

    LaunchedEffect(selectedPoint?.timestamp, showOnlySuspicious, filteredEntries) {
        val selectedTimestamp = selectedPoint?.timestamp ?: return@LaunchedEffect
        val filteredIndex = filteredEntries.indexOfFirst { it.point.timestamp == selectedTimestamp }
        if (filteredIndex >= 0) listState.animateScrollToItem(filteredIndex + 1)
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
                    if (isSelecting) {
                        TextButton(
                            onClick = {
                                selectedIndexes = if (selectedIndexes.size == filteredEntries.size) {
                                    emptySet()
                                } else {
                                    filteredEntries.map { it.originalIndex }.toSet()
                                }
                            },
                            enabled = filteredEntries.isNotEmpty()
                        ) {
                            Text(if (selectedIndexes.size == filteredEntries.size) "取消全选" else "全选")
                        }
                        TextButton(onClick = {
                            isSelecting = false
                            selectedIndexes = emptySet()
                        }) {
                            Text("取消")
                        }
                    } else {
                        IconButton(
                            onClick = {
                                isSelecting = true
                                selectedIndexes = if (showOnlySuspicious) filteredEntries.map { it.originalIndex }.toSet() else emptySet()
                            },
                            enabled = entries.isNotEmpty()
                        ) {
                            Icon(Icons.Default.Checklist, contentDescription = "多选")
                        }
                    }

                    IconButton(
                        onClick = { exportLauncher.launch("DiFangKe_RawPoints_${exportDateFormat.format(date)}.csv") },
                        enabled = entries.isNotEmpty()
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
        Box(modifier = Modifier.padding(padding).fillMaxSize().background(bgColor)) {
            Column(modifier = Modifier.fillMaxSize()) {
                RawPointsMapPreview(
                    entries = entries,
                    filteredEntries = filteredEntries,
                    selectedPoint = selectedPoint,
                    selectedIndexes = selectedIndexes,
                    isDark = isDark,
                    primaryColor = primaryColor,
                    onPointSelected = { selectedPoint = it },
                    onMapReady = { amapInstance = it },
                    onRecenter = {
                        selectedPoint = null
                        val validLatLngs = entries.filter { !it.isDriftPoint }.map { LatLng(it.point.latitude, it.point.longitude) }
                        if (validLatLngs.isNotEmpty()) {
                            val bounds = LatLngBounds.builder().apply { validLatLngs.forEach { include(it) } }.build()
                            scope.launch { amapInstance?.animateCamera(CameraUpdateFactory.newLatLngBounds(bounds, 100)) }
                        }
                    }
                )

                when {
                    isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                    entries.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("该日期暂无轨迹数据", color = Color.Gray)
                    }
                    else -> LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize()
                    ) {
                        item {
                            RawPointsSummaryRow(
                                entriesCount = entries.size,
                                filteredCount = filteredEntries.size,
                                driftCount = driftCount,
                                showOnlySuspicious = showOnlySuspicious,
                                isSelecting = isSelecting,
                                selectedCount = selectedIndexes.size
                            )
                        }

                        itemsIndexed(filteredEntries) { _, entry ->
                            PointRowWithDrift(
                                entry = entry,
                                prevEntry = if (entry.originalIndex > 0) entries.getOrNull(entry.originalIndex - 1) else null,
                                isSelected = selectedPoint?.timestamp == entry.point.timestamp || selectedIndexes.contains(entry.originalIndex),
                                isSelecting = isSelecting,
                                isChecked = selectedIndexes.contains(entry.originalIndex),
                                onClick = {
                                    if (isSelecting) {
                                        selectedIndexes = if (selectedIndexes.contains(entry.originalIndex)) {
                                            selectedIndexes - entry.originalIndex
                                        } else {
                                            selectedIndexes + entry.originalIndex
                                        }
                                    } else {
                                        selectedPoint = entry.point
                                        scope.launch {
                                            amapInstance?.animateCamera(
                                                CameraUpdateFactory.newLatLngZoom(LatLng(entry.point.latitude, entry.point.longitude), 17f)
                                            )
                                        }
                                    }
                                },
                                onDelete = {
                                    if (isSelecting) return@PointRowWithDrift
                                    scope.launch {
                                        withContext(Dispatchers.IO) {
                                            rawStore.deleteLocation(entry.point.timestamp.time / 1000.0, date, context)
                                        }
                                        entries = entries.filter { it.point.timestamp != entry.point.timestamp }
                                        if (selectedPoint?.timestamp == entry.point.timestamp) selectedPoint = null
                                    }
                                }
                            )
                        }
                    }
                }
            }

            if (isSelecting && selectedIndexes.isNotEmpty()) {
                RawPointsBatchDeleteBar(
                    selectedCount = selectedIndexes.size,
                    isDeleting = isBatchDeleting,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
                    onDelete = {
                        scope.launch {
                            isBatchDeleting = true
                            val timestamps = entries
                                .filter { selectedIndexes.contains(it.originalIndex) }
                                .map { it.point.timestamp.time / 1000.0 }
                                .toSet()
                            withContext(Dispatchers.IO) { rawStore.deleteLocations(timestamps, date, context) }
                            entries = entries.filterNot { selectedIndexes.contains(it.originalIndex) }
                            selectedPoint = selectedPoint?.takeIf { point ->
                                timestamps.none { abs(it - point.timestamp.time / 1000.0) <= 0.01 }
                            }
                            selectedIndexes = emptySet()
                            isSelecting = false
                            isBatchDeleting = false
                            Toast.makeText(context, "已删除 ${timestamps.size} 个轨迹点", Toast.LENGTH_SHORT).show()
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun RawPointsMapPreview(
    entries: List<RawLocationStore.RawPointEntry>,
    filteredEntries: List<RawLocationStore.RawPointEntry>,
    selectedPoint: RawLocationStore.RawPoint?,
    selectedIndexes: Set<Int>,
    isDark: Boolean,
    primaryColor: Color,
    onPointSelected: (RawLocationStore.RawPoint) -> Unit,
    onMapReady: (AMap) -> Unit,
    onRecenter: () -> Unit
) {
    val allPlaces by remember { DiFangKeApp.instance.database.placeDao().observeAll() }
        .collectAsState(initial = emptyList())

    Box(modifier = Modifier.fillMaxWidth().height(220.dp)) {
        AndroidView(
            factory = { ctx ->
                TextureMapView(ctx).apply {
                    onCreate(android.os.Bundle())
                    map.uiSettings.isZoomControlsEnabled = false
                    onMapReady(map)
                }
            },
            modifier = Modifier.fillMaxSize()
        ) { view ->
            val map = view.map
            map.mapType = if (isDark) AMap.MAP_TYPE_NIGHT else AMap.MAP_TYPE_NORMAL
            map.setOnMapClickListener { latLng ->
                selectNearestEntry(latLng, filteredEntries, onPointSelected)
            }

            map.clear()
            map.addImportantPlaceCircles(allPlaces)

            if (entries.isNotEmpty()) {
                val validLatLngs = entries.filter { !it.isDriftPoint }.map { LatLng(it.point.latitude, it.point.longitude) }
                if (validLatLngs.isNotEmpty()) {
                    map.addPolyline(PolylineOptions().addAll(validLatLngs).width(10f).color(primaryColor.toArgb()).useGradient(true))
                }

                entries.filter { it.isDriftPoint }.forEach { entry ->
                    map.addCircle(
                        CircleOptions()
                            .center(LatLng(entry.point.latitude, entry.point.longitude))
                            .radius(8.0)
                            .fillColor(Color.Gray.copy(alpha = 0.5f).toArgb())
                            .strokeColor(Color.Gray.copy(alpha = 0.3f).toArgb())
                            .strokeWidth(1f)
                    )
                }

                selectedPoint?.let { point ->
                    map.addMarker(
                        MarkerOptions()
                            .position(LatLng(point.latitude, point.longitude))
                            .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_RED))
                    )
                }

                entries.filter { selectedIndexes.contains(it.originalIndex) }.forEach { entry ->
                    map.addCircle(
                        CircleOptions()
                            .center(LatLng(entry.point.latitude, entry.point.longitude))
                            .radius(10.0)
                            .fillColor(primaryColor.copy(alpha = 0.35f).toArgb())
                            .strokeColor(primaryColor.toArgb())
                            .strokeWidth(2f)
                    )
                }

                if (selectedPoint == null && validLatLngs.isNotEmpty()) {
                    val bounds = LatLngBounds.builder().apply { validLatLngs.forEach { include(it) } }.build()
                    map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, 100))
                }
            }
        }

        IconButton(
            onClick = onRecenter,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp)
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f), RoundedCornerShape(8.dp))
        ) {
            Icon(Icons.Default.FullscreenExit, null)
        }
    }
}

@Composable
private fun RawPointsSummaryRow(
    entriesCount: Int,
    filteredCount: Int,
    driftCount: Int,
    showOnlySuspicious: Boolean,
    isSelecting: Boolean,
    selectedCount: Int
) {
    Row(
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = if (showOnlySuspicious) "筛选出 ${filteredCount} 个疑似问题点" else "共 ${entriesCount} 个记录点",
            style = MaterialTheme.typography.labelSmall,
            color = if (showOnlySuspicious) MaterialTheme.colorScheme.primary else Color.Gray
        )

        if (isSelecting) {
            Spacer(Modifier.width(8.dp))
            Surface(shape = RoundedCornerShape(4.dp), color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)) {
                Text(
                    "已选 ${selectedCount}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }
        }

        if (driftCount > 0 && !isSelecting) {
            Spacer(Modifier.weight(1f))
            Surface(shape = RoundedCornerShape(4.dp), color = Color.Gray.copy(alpha = 0.12f)) {
                Row(
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Icon(Icons.Default.Warning, contentDescription = null, modifier = Modifier.size(10.dp), tint = Color.Gray)
                    Text(
                        "$driftCount 个漂移点",
                        style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
                        color = Color.Gray
                    )
                }
            }
        }
    }
}

@Composable
private fun RawPointsBatchDeleteBar(
    selectedCount: Int,
    isDeleting: Boolean,
    modifier: Modifier = Modifier,
    onDelete: () -> Unit
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        tonalElevation = 6.dp,
        shadowElevation = 6.dp,
        color = MaterialTheme.colorScheme.surface
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("已选 ${selectedCount} 个点", style = MaterialTheme.typography.bodyMedium)
            Button(
                enabled = !isDeleting,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                onClick = onDelete
            ) {
                if (isDeleting) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onError)
                } else {
                    Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("删除")
                }
            }
        }
    }
}

/** CSV 导出（带 is_drift 列） */
private fun rawPointsEntryCsv(entries: List<RawLocationStore.RawPointEntry>): String {
    val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).apply {
        timeZone = TimeZone.getDefault()
    }
    return buildString {
        appendLine("timestamp_iso,timestamp_unix,latitude,longitude,accuracy,speed,is_drift")
        entries.forEach { entry ->
            val point = entry.point
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
            append(',')
            append(if (entry.isDriftPoint) "1" else "0")
            appendLine()
        }
    }
}

private fun selectNearestEntry(
    tappedLatLng: LatLng,
    candidates: List<RawLocationStore.RawPointEntry>,
    onPointSelected: (RawLocationStore.RawPoint) -> Unit
) {
    val closest = candidates.minByOrNull { entry ->
        haversineMeters(tappedLatLng.latitude, tappedLatLng.longitude, entry.point.latitude, entry.point.longitude)
    } ?: return

    val distance = haversineMeters(
        tappedLatLng.latitude,
        tappedLatLng.longitude,
        closest.point.latitude,
        closest.point.longitude
    )

    if (distance < 1000.0) onPointSelected(closest.point)
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun PointRowWithDrift(
    entry: RawLocationStore.RawPointEntry,
    prevEntry: RawLocationStore.RawPointEntry?,
    isSelected: Boolean,
    isSelecting: Boolean = false,
    isChecked: Boolean = false,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val isDrift = entry.isDriftPoint
    val point = entry.point
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
            .combinedClickable(onClick = onClick, onLongClick = {})
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .alpha(if (isDrift) 0.65f else 1f)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (isSelecting) {
                Checkbox(checked = isChecked, onCheckedChange = null)
                Spacer(Modifier.width(8.dp))
            }
            Surface(
                shape = RoundedCornerShape(4.dp),
                color = if (isDrift) Color.Gray.copy(alpha = 0.1f) else MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Text(
                        "#${entry.originalIndex + 1}",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        color = if (isDrift) Color.Gray else MaterialTheme.colorScheme.primary,
                        textDecoration = if (isDrift) TextDecoration.LineThrough else TextDecoration.None
                    )
                    if (isDrift) {
                        Icon(Icons.Default.Warning, contentDescription = "漂移点", modifier = Modifier.size(8.dp), tint = Color.Gray)
                    }
                }
            }

            Spacer(Modifier.width(8.dp))

            Text(
                SimpleDateFormat("HH:mm:ss", Locale.CHINA).format(point.timestamp),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = if (isDrift) Color.Gray else Color.Unspecified,
                textDecoration = if (isDrift) TextDecoration.LineThrough else TextDecoration.None
            )

            Spacer(Modifier.weight(1f))

            if (prevEntry != null) {
                val prevPoint = prevEntry.point
                val dist = haversineMeters(prevPoint.latitude, prevPoint.longitude, point.latitude, point.longitude)
                Text(
                    formatDistance(dist),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (isDrift) Color.Gray.copy(alpha = 0.6f) else if (dist > 1000) Color.Red else Color.Gray,
                    textDecoration = if (isDrift) TextDecoration.LineThrough else TextDecoration.None
                )
            }
        }

        Spacer(Modifier.height(4.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                String.format(Locale.US, "%.6f, %.6f", point.latitude, point.longitude),
                style = MaterialTheme.typography.labelSmall,
                color = if (isDrift) Color.Gray.copy(alpha = 0.5f) else Color.Gray,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                textDecoration = if (isDrift) TextDecoration.LineThrough else TextDecoration.None,
                modifier = Modifier.weight(1f)
            )

            if (isDrift) {
                Surface(
                    shape = RoundedCornerShape(3.dp),
                    color = Color.Gray.copy(alpha = 0.5f),
                    modifier = Modifier.padding(end = 6.dp)
                ) {
                    Text(
                        "漂移",
                        style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp),
                        color = Color.White,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp)
                    )
                }
            }

            Icon(Icons.Default.MyLocation, null, modifier = Modifier.size(10.dp), tint = if (isDrift) Color.Gray.copy(alpha = 0.5f) else Color.Gray)
            Spacer(Modifier.width(2.dp))
            Text(
                "${point.accuracy.toInt()}m",
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
                color = if (isDrift) Color.Gray.copy(alpha = 0.5f) else if (point.accuracy > 100) Color(0xFFFF9800) else Color.Gray
            )
        }
    }
}

private fun formatDistance(d: Double): String {
    return if (d < 1000) "+${d.toInt()}m" else String.format(Locale.US, "+%.2fkm", d / 1000.0)
}

/** 判定可疑点（漂移点以外的其他异常） */
private fun isSuspiciousEntry(entry: RawLocationStore.RawPointEntry, allEntries: List<RawLocationStore.RawPointEntry>): Boolean {
    val point = entry.point
    val index = entry.originalIndex

    if (point.accuracy > 500) return true
    if (index > 0) {
        val prev = allEntries.getOrNull(index - 1)?.point ?: return false
        val dist = haversineMeters(prev.latitude, prev.longitude, point.latitude, point.longitude)
        val time = max(0.1, (point.timestamp.time - prev.timestamp.time) / 1000.0)
        val speed = dist / time
        if (speed > 70.0) return true
        if (dist > 2000 && point.accuracy > 200) return true
    }
    return false
}

private fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val earthRadius = 6371000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = sin(dLat / 2).let { it * it } +
        cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
        sin(dLon / 2).let { it * it }
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
}
