package com.ct106.difangke.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.service.LocationTrackingService
import java.text.SimpleDateFormat
import java.util.Locale

private val TIME_FORMAT = SimpleDateFormat("HH:mm", Locale.CHINA)
private val DURATION_FORMAT = { durationSec: Int -> 
    val min = durationSec / 60
    if (min < 60) "${min}分钟" else "${min / 60}小时${min % 60}分"
}

@Composable
fun TimelineLine(isFirst: Boolean, isLast: Boolean, isTransport: Boolean = false) {
    Canvas(modifier = Modifier.width(30.dp).fillMaxHeight()) {
        val strokeWidth = 3.dp.toPx()
        val centerX = size.width / 2
        val lineColor = if (isTransport) Color(0xFF007AFF) else Color(0xFFE5E5EA)
        
        val startY = if (isFirst) size.height / 2 else 0f
        val endY = if (isLast) size.height / 2 else size.height
        
        if (isTransport) {
            drawLine(
                color = lineColor,
                start = Offset(centerX, startY),
                end = Offset(centerX, endY),
                strokeWidth = strokeWidth,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 10f), 0f)
            )
        } else {
            drawLine(
                color = lineColor,
                start = Offset(centerX, startY),
                end = Offset(centerX, endY),
                strokeWidth = strokeWidth
            )
        }
    }
}

@Composable
fun FootprintCardView(
    footprint: FootprintEntity, 
    isFirst: Boolean, 
    isLast: Boolean,
    onClick: () -> Unit = {}
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(IntrinsicSize.Min)
    ) {
        // 左边时间轴连线
        Box(modifier = Modifier.width(40.dp), contentAlignment = Alignment.TopCenter) {
            TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = false)
            
            // 圈圈指示器
            Box(
                modifier = Modifier
                    .padding(top = 28.dp)
                    .size(16.dp)
                    .clip(CircleShape)
                    .background(if (footprint.aiAnalyzed) Color(0xFFFF9500) else Color(0xFF34C759))
            )
        }
        
        // 核心卡片
        Card(
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 8.dp)
                .clickable { onClick() },
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
            elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = footprint.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF1C1C1E)
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "${TIME_FORMAT.format(footprint.startTime)} - ${TIME_FORMAT.format(footprint.endTime)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF8E8E93)
                    )
                }
                
                Spacer(modifier = Modifier.height(4.dp))
                
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Place, 
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = Color(0xFF8E8E93)
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = footprint.address ?: "未解析的位置",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF8E8E93),
                        maxLines = 1
                    )
                }
                
                if (!footprint.reason.isNullOrEmpty()) {
                    Spacer(modifier = Modifier.height(12.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFFF2F2F7))
                            .padding(12.dp)
                    ) {
                        Text(
                            text = "“${footprint.reason}”",
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color(0xFF3A3A3C),
                            fontStyle = androidx.compose.ui.text.font.FontStyle.Italic
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun TransportCardView(transport: TransportRecordEntity, isFirst: Boolean, isLast: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(IntrinsicSize.Min)
    ) {
        // 左边时间轴连线
        Box(modifier = Modifier.width(40.dp), contentAlignment = Alignment.TopCenter) {
            TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = true)
            
            // 圈圈指示器
            Box(
                modifier = Modifier
                    .padding(top = 28.dp)
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(Color.White),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.DirectionsBus, 
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = Color(0xFF007AFF)
                )
            }
        }
        
        // 核心卡片
        Card(
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 8.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = Color.Transparent),
            elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
        ) {
            Column(modifier = Modifier.padding(vertical = 12.dp, horizontal = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "前往 ${transport.endLocation}",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFF007AFF)
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    val durationSec = ((transport.endTime.time - transport.startTime.time) / 1000).toInt()
                    Text(
                        text = DURATION_FORMAT(durationSec),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF8E8E93)
                    )
                }
            }
        }
    }
}

@Composable
fun RecordingStatusCard(
    trackingState: LocationTrackingService.TrackingState,
    isTracking: Boolean,
    footprintCount: Int,
    onNavigateToMap: () -> Unit,
    onRequestPermission: () -> Unit,
    hasLocationPermission: Boolean
) {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable { onNavigateToMap() },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Row(modifier = Modifier.fillMaxWidth()) {
            // 1. 左侧时间轴指示器 (iOS 风格)
            Column(
                modifier = Modifier.width(40.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Spacer(modifier = Modifier.height(22.dp))
                
                // 呼吸效果圆点
                if (isTracking) {
                    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
                    val scale by infiniteTransition.animateFloat(
                        initialValue = 1.0f,
                        targetValue = 2.5f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(1200, easing = LinearEasing),
                            repeatMode = RepeatMode.Restart
                        ),
                        label = "scale"
                    )
                    val alpha by infiniteTransition.animateFloat(
                        initialValue = 0.4f,
                        targetValue = 0.0f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(1200, easing = LinearEasing),
                            repeatMode = RepeatMode.Restart
                        ),
                        label = "alpha"
                    )
                    
                    val pulseColor = MaterialTheme.colorScheme.primary
                    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(24.dp)) {
                        Canvas(modifier = Modifier.size(24.dp)) {
                            drawCircle(
                                color = pulseColor.copy(alpha = alpha),
                                radius = 4.dp.toPx() * scale,
                                style = Stroke(width = 2.dp.toPx())
                            )
                        }
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .background(pulseColor, CircleShape)
                        )
                    }
                } else {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .background(MaterialTheme.colorScheme.error, CircleShape)
                    )
                }
                
                // 连接线
                Box(
                    modifier = Modifier
                        .width(1.5.dp)
                        .weight(1f)
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                )
            }
            
            // 2. 右侧内容区
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(end = 16.dp, bottom = 16.dp)
            ) {
                if (!hasLocationPermission) {
                    Spacer(modifier = Modifier.height(18.dp))
                    Text("需要定位权限", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                    Spacer(modifier = Modifier.height(4.dp))
                    Text("请允许后台获取位置信息以记录足迹。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(onClick = onRequestPermission, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(0.dp)) {
                        Text("授权并开启记录")
                    }
                } else {
                    Spacer(modifier = Modifier.height(16.dp))
                    
                    // 标题
                    val displayTitle = when (trackingState) {
                        is LocationTrackingService.TrackingState.Idle -> "定位记录已关闭"
                        is LocationTrackingService.TrackingState.Tracking -> "正在寻找位置..."
                        is LocationTrackingService.TrackingState.OngoingStay -> "正在此处停留"
                    }
                    Text(displayTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
                    
                    val ongoing = trackingState as? LocationTrackingService.TrackingState.OngoingStay
                    val tracking = trackingState as? LocationTrackingService.TrackingState.Tracking
                    val currentLat = ongoing?.lat ?: tracking?.lat
                    val currentLon = ongoing?.lon ?: tracking?.lon
                    
                    // 地址
                    if (ongoing != null && !ongoing.address.isNullOrEmpty()) {
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(ongoing.address, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                    }
                    
                    // 持续时间/状态
                    Spacer(modifier = Modifier.height(4.dp))
                    if (!isTracking) {
                        Text("点击开启或查看说明", style = MaterialTheme.typography.bodySmall, color = Color.Gray, fontWeight = FontWeight.Bold)
                    } else if (ongoing != null) {
                        val durationMins = (System.currentTimeMillis() - ongoing.since.time) / 60000
                        Text("已停留 $durationMins 分钟", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.6f))
                    } else {
                        Text("今日共发现 $footprintCount 个足迹", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.6f))
                    }

                    // 小地图
                    if (currentLat != null && currentLon != null) {
                        Spacer(modifier = Modifier.height(12.dp))
                        MiniMapView(
                            lat = currentLat, 
                            lon = currentLon,
                            onClick = onNavigateToMap
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun DaySummaryCard(
    footprintCount: Int,
    onNavigateToMap: () -> Unit
) {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable { onNavigateToMap() },
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("全天总结", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
            Spacer(modifier = Modifier.height(8.dp))
            Text("共发现 $footprintCount 个足迹碎片", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onNavigateToMap,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.secondaryContainer, contentColor = MaterialTheme.colorScheme.onSecondaryContainer)
            ) {
                Text("查看历史地图轨迹")
            }
        }
    }
}

@Composable
fun AISummaryCard(content: String) {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.AutoAwesome,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "AI 每日回顾",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.Bold
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = "“$content”",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
                fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
                lineHeight = 24.sp
            )
        }
    }
}

@Composable
fun MiniMapView(lat: Double, lon: Double, onClick: () -> Unit) {
    val context = LocalContext.current
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    
    // 极简且稳健的生命周期管理
    Box(
        modifier = androidx.compose.ui.Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(16.dp))
    ) {
        androidx.compose.ui.viewinterop.AndroidView(
            factory = { ctx ->
                com.amap.api.maps.TextureMapView(ctx).apply {
                    onCreate(android.os.Bundle())
                    onResume() // 创建即恢复，确保可见性
                }
            },
            modifier = androidx.compose.ui.Modifier.fillMaxSize(),
            onRelease = { view ->
                view.onPause()
                view.onDestroy()
            }
        ) { view ->
            val amap = view.map
            
            // 每次更新时重置视野，确保不会因为 View 复用导致位置错乱
            amap.mapType = if (isDark) {
                com.amap.api.maps.AMap.MAP_TYPE_NIGHT 
            } else {
                com.amap.api.maps.AMap.MAP_TYPE_NORMAL
            }

            amap.uiSettings.apply {
                isZoomControlsEnabled = false
                isMyLocationButtonEnabled = false
                isRotateGesturesEnabled = false
                isTiltGesturesEnabled = false
                isScrollGesturesEnabled = false
                isZoomGesturesEnabled = false
            }
            
            val style = com.amap.api.maps.model.MyLocationStyle()
            style.myLocationType(com.amap.api.maps.model.MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE_NO_CENTER)
            style.showMyLocation(true)
            amap.myLocationStyle = style
            amap.isMyLocationEnabled = true
            
            val target = com.amap.api.maps.model.LatLng(lat, lon)
            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(target, 16f))

            // 绘制当日所有轨迹流水（使用主题色）
            val rawStore = com.ct106.difangke.data.location.RawLocationStore.getInstance(context)
            val allTodayPoints = rawStore.loadLocations(java.util.Date())
            if (allTodayPoints.isNotEmpty()) {
                amap.clear()
                val latLngs = allTodayPoints.map { com.amap.api.maps.model.LatLng(it.latitude, it.longitude) }
                amap.addPolyline(
                    com.amap.api.maps.model.PolylineOptions()
                        .addAll(latLngs)
                        .width(10f)
                        .color(primaryColor) // 使用 Material 3 主题色
                )
            }
        }

        // 核心修复：添加一层透明遮罩专门拦截点击事件
        // 这样可以避开高德地图原生 View 对触摸事件的各种拦截，确保 100% 响应
        androidx.compose.foundation.layout.Box(
            modifier = androidx.compose.ui.Modifier
                .fillMaxSize()
                .background(androidx.compose.ui.graphics.Color.Transparent)
                .clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null // 移除点击水波纹，让地图点击更纯净
                ) {
                    onClick()
                }
        )
    }
}
