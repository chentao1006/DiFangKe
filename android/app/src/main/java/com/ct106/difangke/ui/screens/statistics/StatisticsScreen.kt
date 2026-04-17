package com.ct106.difangke.ui.screens.statistics

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import android.util.Log
import android.os.Bundle
import com.ct106.difangke.ui.theme.DfkAccent
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun StatisticsScreen(
    onBack: () -> Unit,
    viewModel: StatisticsViewModel = viewModel()
) {
    val selectedRange by viewModel.selectedRange.collectAsState()
    val heatmapPoints by viewModel.heatmapPoints.collectAsState()
    val activityRank by viewModel.activityRank.collectAsState()
    val trendData by viewModel.trendData.collectAsState()
    val aiSummary by viewModel.aiSummary.collectAsState()
    val isGeneratingSummary by viewModel.isGeneratingSummary.collectAsState()

    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)

    Scaffold(
        containerColor = bgColor,
        topBar = {
            TopAppBar(
                title = { Text("统计洞察", fontWeight = FontWeight.ExtraBold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = bgColor,
                    scrolledContainerColor = bgColor
                )
            )
        }
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            contentPadding = PaddingValues(bottom = 40.dp)
        ) {
            // 1. Sticky Range Picker
            stickyHeader {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(bgColor.copy(alpha = 0.95f))
                        .padding(vertical = 12.dp, horizontal = 20.dp)
                ) {
                    RangePickerRow(
                        selectedRange = selectedRange,
                        onRangeSelected = { viewModel.setRange(it) }
                    )
                }
            }

            // 2. Content
            item {
                Column(
                    modifier = Modifier.padding(horizontal = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp)
                ) {
                    // AI Summary (iOS Style: Clean text, no card)
                    AiSummarySection(summary = aiSummary, isGenerating = isGeneratingSummary)

                    // Heatmap (Keep as card but matching iOS border radius)
                    HeatmapSection(points = heatmapPoints)

                    // Activity Rank (iOS Style: Progress bars)
                    ActivityRankSection(items = activityRank)

                    // Trend Chart (iOS Style: Area/Line chart)
                    TrendSection(points = trendData, range = selectedRange)
                }
            }
        }
    }
}

@Composable
fun RangePickerRow(
    selectedRange: StatisticsRange,
    onRangeSelected: (StatisticsRange) -> Unit
) {
    var showYearMenu by remember { mutableStateOf(false) }
    val currentYear = Calendar.getInstance().get(Calendar.YEAR)
    val years = (currentYear downTo currentYear - 5).toList()
    val isDark = isSystemInDarkTheme()

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
                    color = if (isSelected) Color.White else if (isDark) Color.Gray else Color.Black.copy(alpha = 0.6f),
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                )
            }
        }
        
        // Year Selector
        val isCustomOrAll = selectedRange is StatisticsRange.CUSTOM_YEAR || selectedRange == StatisticsRange.ALL
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .clip(RoundedCornerShape(10.dp))
                .background(if (isCustomOrAll) DfkAccent else Color.Transparent)
                .clickable { showYearMenu = true },
            contentAlignment = Alignment.Center
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val label = when (val range = selectedRange) {
                    is StatisticsRange.CUSTOM_YEAR -> "${range.year}"
                    StatisticsRange.ALL -> "全部"
                    else -> "年份"
                }
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (isCustomOrAll) Color.White else if (isDark) Color.Gray else Color.Black.copy(alpha = 0.6f),
                    fontWeight = if (isCustomOrAll) FontWeight.Bold else FontWeight.Medium
                )
                Spacer(Modifier.width(2.dp))
                Icon(
                    Icons.Default.KeyboardArrowDown, 
                    null, 
                    Modifier.size(10.dp),
                    tint = if (isCustomOrAll) Color.White else if (isDark) Color.Gray else Color.Black.copy(alpha = 0.6f)
                )
            }
            
            DropdownMenu(expanded = showYearMenu, onDismissRequest = { showYearMenu = false }) {
                DropdownMenuItem(
                    text = { Text("全部时间") },
                    onClick = { onRangeSelected(StatisticsRange.ALL); showYearMenu = false }
                )
                years.forEach { year ->
                    DropdownMenuItem(
                        text = { Text("$year") },
                        onClick = { onRangeSelected(StatisticsRange.CUSTOM_YEAR(year)); showYearMenu = false }
                    )
                }
            }
        }
    }
}

@Composable
fun AiSummarySection(summary: String?, isGenerating: Boolean) {
    Box(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        if (isGenerating) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 12.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
                Text("正在分析您的足迹数据...", color = Color.Gray, fontSize = 13.sp)
            }
        } else if (summary != null) {
            Text(
                text = summary,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                lineHeight = 22.sp
            )
        }
    }
}

@Composable
fun HeatmapSection(points: List<HeatmapPoint>) {
    val isDark = isSystemInDarkTheme()
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionHeader("热点地区", Icons.Default.Map)
        Spacer(Modifier.height(12.dp))
        
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .height(280.dp)
                .pointerInput(Unit) {
                    // 拦截触摸事件，防止与父级滚动冲突
                    awaitPointerEventScope {
                        while (true) {
                            awaitPointerEvent()
                            // 一旦有触摸，告诉父级不要拦截
                        }
                    }
                },
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                androidx.compose.ui.viewinterop.AndroidView(
                    factory = { ctx ->
                        com.amap.api.maps.TextureMapView(ctx).apply {
                            onCreate(Bundle())
                            onResume()
                            // 在这里处理底层 View 的触摸拦截
                            val amap = this.map
                            setOnTouchListener { v, event ->
                                when (event.action) {
                                    android.view.MotionEvent.ACTION_DOWN,
                                    android.view.MotionEvent.ACTION_MOVE -> {
                                        // 递归向上请求不拦截
                                        var p = v.parent
                                        while (p != null) {
                                            p.requestDisallowInterceptTouchEvent(true)
                                            p = p.parent
                                        }
                                    }
                                    android.view.MotionEvent.ACTION_UP,
                                    android.view.MotionEvent.ACTION_CANCEL -> {
                                        var p = v.parent
                                        while (p != null) {
                                            p.requestDisallowInterceptTouchEvent(false)
                                            p = p.parent
                                        }
                                    }
                                }
                                false
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                ) { view ->
                    val amap = view.map
                    if (amap.mapType != (if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT else com.amap.api.maps.AMap.MAP_TYPE_NORMAL)) {
                        amap.mapType = if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT else com.amap.api.maps.AMap.MAP_TYPE_NORMAL
                    }
                    amap.uiSettings.isZoomControlsEnabled = false
                    // 彻底禁止地图互动，防止滚动冲突
                    amap.uiSettings.setAllGesturesEnabled(false)
                    
                    if (points.isNotEmpty()) {
                        amap.clear()
                        try {
                            val latLngs = points.map { com.amap.api.maps.model.LatLng(it.lat, it.lon) }
                            
                            // 创建一个在屏幕上大小固定的圆形图标
                            val size = (22 * view.context.resources.displayMetrics.density).toInt()
                            val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
                            val canvas = android.graphics.Canvas(bitmap)
                            val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                            
                            // 画圆心
                            paint.color = android.graphics.Color.parseColor("#FF9500")
                            paint.alpha = 140 // 增加透明度
                            canvas.drawCircle(size / 2f, size / 2f, size / 2.2f, paint)
                            
                            // 画外圈投影感
                            paint.style = android.graphics.Paint.Style.STROKE
                            paint.strokeWidth = 3f
                            paint.alpha = 200 // 描边也稍微透明一点
                            canvas.drawCircle(size / 2f, size / 2f, size / 2.2f, paint)
                            
                            val descriptor = com.amap.api.maps.model.BitmapDescriptorFactory.fromBitmap(bitmap)
                            
                            points.forEach { pt ->
                                val markerOptions = com.amap.api.maps.model.MarkerOptions()
                                    .position(com.amap.api.maps.model.LatLng(pt.lat, pt.lon))
                                    .icon(descriptor)
                                    .anchor(0.5f, 0.5f)
                                    .zIndex(1000f)
                                amap.addMarker(markerOptions)
                            }
                            
                            if (latLngs.size == 1) {
                                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(latLngs[0], 13f))
                            } else {
                                val boundsBuilder = com.amap.api.maps.model.LatLngBounds.builder()
                                latLngs.forEach { boundsBuilder.include(it) }
                                try {
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(boundsBuilder.build(), 50))
                                } catch (e: Exception) {
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(latLngs[0], 10f))
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("Heatmap", "Error drawing markers", e)
                        }
                    } else {
                        amap.clear()
                    }
                }
                if (points.isEmpty()) {
                    Box(modifier = Modifier.fillMaxSize().background(Color.Gray.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
                        Text("暂无地点分布数据", fontSize = 13.sp, color = Color.Gray)
                    }
                }
            }
        }
    }
}

@Composable
fun ActivityRankSection(items: List<ActivityRankItem>) {
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionHeader("活动排行", Icons.Default.ShowChart)
        Spacer(Modifier.height(16.dp))
        
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f))
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp)) {
                if (items.isEmpty()) {
                    Text("暂无活动记录", modifier = Modifier.padding(20.dp), color = Color.LightGray)
                } else {
                    val maxCount = items.maxByOrNull { it.count }?.count ?: 1
                    items.take(6).forEach { item ->
                        ActivityRankRow(item, maxCount)
                    }
                }
            }
        }
    }
}

@Composable
fun ActivityRankRow(item: ActivityRankItem, maxCount: Int) {
    val color = try { Color(android.graphics.Color.parseColor(item.colorHex)) } catch (e: Exception) { DfkAccent }
    
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Icon + Name
        Row(modifier = Modifier.width(90.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = com.ct106.difangke.ui.components.getIconForName(item.icon),
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = color
            )
            Spacer(Modifier.width(10.dp))
            Text(item.name, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
        }
        
        // Progress Bar
        Box(modifier = Modifier.weight(1f).height(12.dp).clip(RoundedCornerShape(6.dp)).background(Color.Gray.copy(alpha = 0.1f))) {
            val ratio = item.count.toFloat() / maxCount.toFloat()
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .fillMaxWidth(ratio)
                    .clip(RoundedCornerShape(6.dp))
                    .background(Brush.horizontalGradient(listOf(color.copy(alpha = 0.7f), color)))
            )
        }
    }
}

@Composable
fun TrendSection(points: List<TrendPoint>, range: StatisticsRange) {
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionHeader("活跃趋势", Icons.Default.Timeline)
        Spacer(Modifier.height(16.dp))
        
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f))
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
                if (points.isEmpty()) {
                    Box(modifier = Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) {
                        Text("数据加载中...", color = Color.Gray, fontSize = 13.sp)
                    }
                } else {
                    SmoothLineChart(points = points)
                    
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "数据说明：综合了您的出行频率、活动地点和照片等",
                        fontSize = 10.sp,
                        color = Color.Gray.copy(alpha = 0.6f)
                    )
                }
            }
        }
    }
}

@Composable
fun SmoothLineChart(points: List<TrendPoint>) {
    val maxScore = points.maxOfOrNull { it.score }?.toFloat()?.coerceAtLeast(1f) ?: 100f
    
    Canvas(modifier = Modifier.fillMaxWidth().height(180.dp).padding(horizontal = 8.dp)) {
        val width = size.width
        val height = size.height
        val spacing = width / (points.size - 1).coerceAtLeast(1).toFloat()
        
        val path = Path()
        val areaPath = Path()
        
        points.forEachIndexed { index, point ->
            val x = index.toFloat() * spacing
            val y = height - (point.score.toFloat() / maxScore) * height
            
            if (index == 0) {
                path.moveTo(x, y)
                areaPath.moveTo(x, height)
                areaPath.lineTo(x, y)
            } else {
                val prevX = (index - 1).toFloat() * spacing
                val prevY = height - (points[index - 1].score.toFloat() / maxScore) * height
                val midX = (prevX + x) / 2f
                
                path.cubicTo(midX, prevY, midX, y, x, y)
                areaPath.cubicTo(midX, prevY, midX, y, x, y)
            }
            
            if (index == points.size - 1) {
                areaPath.lineTo(x, height)
                areaPath.close()
            }
        }
        
        // Draw Area
        drawPath(
            path = areaPath,
            brush = Brush.verticalGradient(
                colors = listOf(DfkAccent.copy(alpha = 0.3f), Color.Transparent)
            )
        )
        
        // Draw Line
        drawPath(
            path = path,
            color = DfkAccent,
            style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
    }
}

@Composable
fun SectionHeader(title: String, icon: ImageVector) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, modifier = Modifier.size(16.dp), tint = DfkAccent)
        Spacer(Modifier.width(8.dp))
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

