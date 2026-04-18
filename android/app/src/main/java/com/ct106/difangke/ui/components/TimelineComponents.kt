package com.ct106.difangke.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import com.google.gson.Gson
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.service.LocationTrackingService
import java.text.SimpleDateFormat
import java.util.Locale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items

private val TIME_FORMAT = SimpleDateFormat("HH:mm", Locale.CHINA)
private val DURATION_FORMAT = { durationSec: Int -> 
    val min = durationSec / 60
    if (min < 60) "${min}分钟" else "${min / 60}小时${min % 60}分"
}

@Composable
fun TimelineLine(isFirst: Boolean, isLast: Boolean, isTransport: Boolean = false) {
    val color = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
    val dashColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.25f)
    
    Canvas(modifier = Modifier.width(30.dp).fillMaxHeight()) {
        val strokeWidth = 1.5.dp.toPx()
        val centerX = size.width / 2
        
        if (isTransport) {
            // 虚线
            drawLine(
                color = dashColor,
                start = Offset(centerX, 0f),
                end = Offset(centerX, size.height),
                strokeWidth = strokeWidth,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 10f), 0f)
            )
        } else {
            // 实线
            drawLine(
                color = color,
                start = Offset(centerX, if (isFirst) size.height / 2 else 0f),
                end = Offset(centerX, if (isLast) size.height / 2 else size.height),
                strokeWidth = strokeWidth
            )
        }
    }
}


@Composable
fun FootprintCardView(
    footprint: FootprintEntity,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    isFirst: Boolean,
    isLast: Boolean,
    showTimeline: Boolean = true,
    onClick: () -> Unit = {}
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = if (isDark) MaterialTheme.colorScheme.onSurface else Color.Black.copy(alpha = 0.8f)
    val subtitleColor = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant else Color.Gray

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .clickable { onClick() },
        shape = RoundedCornerShape(26.dp),
        color = cardColor,
        shadowElevation = 2.dp,
        tonalElevation = 0.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
        ) {
            // 时间轴连线 (在卡片内部)
            if (showTimeline) {
                Box(modifier = Modifier.width(52.dp), contentAlignment = Alignment.TopCenter) {
                    TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = false)
                    
                    // 圈圈指示器
                    Box(
                        modifier = Modifier
                            .padding(top = 22.dp)
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary)
                    )
                }
            } else {
                Spacer(modifier = Modifier.width(16.dp))
            }
            
            // 内容区
            val activityType = activityTypes.find { it.id == footprint.activityTypeValue }
            val iconName = activityType?.icon ?: "place"
            val iconColor = try { 
                if (activityType?.colorHex != null) Color(android.graphics.Color.parseColor(activityType.colorHex))
                else getIconColorForName(iconName)
            } catch (e: Exception) { 
                getIconColorForName(iconName) 
            }

            Box(modifier = Modifier.weight(1f)) {
                // 右上角活动图标 (iOS 风格)
                Icon(
                    imageVector = getIconForName(iconName),
                    contentDescription = null,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 16.dp, end = 20.dp)
                        .size(24.dp),
                    tint = iconColor
                )

                Column(modifier = Modifier.padding(vertical = 18.dp).padding(end = 56.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = footprint.title.ifEmpty { "足迹记录" },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = titleColor,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        if (footprint.isHighlight == true) {
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = Icons.Default.Star,
                                contentDescription = null,
                                tint = Color(0xFFFFCC00),
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                    
                    Spacer(modifier = Modifier.height(2.dp))
                    
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = footprint.address ?: "未解析的位置",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (allPlaces.any { it.placeID == footprint.placeID && it.isUserDefined }) Color(0xFFFF9800) else subtitleColor,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        
                        // Matched place name display removed, address is now colored instead
                    }
                    
                    Spacer(modifier = Modifier.height(6.dp))
                    
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val sdf = SimpleDateFormat("HH:mm", Locale.CHINA)
                        Text(
                            text = "${sdf.format(footprint.startTime)} - ${sdf.format(footprint.endTime)}",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            color = subtitleColor.copy(alpha = 0.6f)
                        )
                        Text(
                            text = " · ",
                            style = MaterialTheme.typography.labelSmall,
                            color = subtitleColor.copy(alpha = 0.3f)
                        )
                        val durationMins = (footprint.endTime.time - footprint.startTime.time) / 60000
                        val durationStr = if (durationMins >= 60) "${durationMins/60}h${durationMins%60}m" else "${durationMins}m"
                        Text(
                            text = durationStr,
                            style = MaterialTheme.typography.labelSmall,
                            color = subtitleColor.copy(alpha = 0.6f)
                        )
                    }

                    if (!footprint.reason.isNullOrEmpty()) {
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            text = footprint.reason,
                            style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.sp),
                            color = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant else Color.Gray.copy(alpha = 0.8f),
                            lineHeight = 16.sp
                        )
                    }
                }

                // 照片缩略图 logic (Correctly in BoxScope)
                val photoIds = remember(footprint.photoAssetIDsJson) {
                    try {
                        com.google.gson.Gson().fromJson(footprint.photoAssetIDsJson, Array<String>::class.java).toList()
                    } catch (e: Exception) {
                        emptyList<String>()
                    }
                }
                
                if (photoIds.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(bottom = 12.dp, end = 12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(Color.LightGray.copy(alpha = 0.3f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Default.Photo, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun TransportCardView(
    transport: TransportRecordEntity, 
    isFirst: Boolean, 
    isLast: Boolean,
    showTimeline: Boolean = true,
    onClick: () -> Unit = {}
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = if (isDark) MaterialTheme.colorScheme.onSurface else Color.Black.copy(alpha = 0.8f)
    val subtitleColor = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant else Color.Gray

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 2.dp)
            .clickable { onClick() },
        shape = RoundedCornerShape(20.dp),
        color = cardColor,
        shadowElevation = 1.dp,
        tonalElevation = 0.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
        ) {
            // 1. 左侧时间轴连线
            if (showTimeline) {
                Box(modifier = Modifier.width(52.dp), contentAlignment = Alignment.TopCenter) {
                    TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = true)
                    
                    // 圈圈指示器
                    Box(
                        modifier = Modifier
                            .padding(top = 16.dp)
                            .size(20.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.1f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = getTransportIcon(transport.manualTypeRaw ?: transport.typeRaw), 
                            contentDescription = null,
                            modifier = Modifier.size(12.dp),
                            tint = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            } else {
                Spacer(modifier = Modifier.width(16.dp))
            }
            
            // 2. 内容区 (iOS A->B 风格布局)
            Row(
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 16.dp)
                    .padding(end = 16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // 起点
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = transport.startLocation,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Bold,
                        color = titleColor,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = TIME_FORMAT.format(transport.startTime),
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        color = subtitleColor
                    )
                }

                // 中间装饰性图标与距离
                Column(
                    modifier = Modifier.width(80.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(
                        imageVector = getTransportIcon(transport.manualTypeRaw ?: transport.typeRaw),
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)
                    )
                    
                    val distanceKm = transport.distance / 1000.0
                    val distanceText = if (distanceKm < 1.0) {
                        "${transport.distance.toInt()}米"
                    } else {
                        String.format("%.1f公里", distanceKm)
                    }
                    Text(
                        text = distanceText,
                        style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp),
                        fontWeight = FontWeight.Bold,
                        color = subtitleColor.copy(alpha = 0.6f)
                    )
                }

                // 终点
                Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.End) {
                    Text(
                        text = transport.endLocation,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Bold,
                        color = titleColor,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.End
                    )
                    Text(
                        text = TIME_FORMAT.format(transport.endTime),
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        color = subtitleColor,
                        textAlign = androidx.compose.ui.text.style.TextAlign.End
                    )
                }
            }
        }
    }
}

// 辅助函数：根据交通工具类型获取图标
@Composable
private fun getTransportIcon(type: String): ImageVector {
    return when(type.lowercase()) {
        "walk" -> Icons.Default.DirectionsWalk
        "run" -> Icons.Default.DirectionsRun
        "bus" -> Icons.Default.DirectionsBus
        "car" -> Icons.Default.DirectionsCar
        "subway", "train" -> Icons.Default.DirectionsSubway
        else -> Icons.Default.DirectionsBus
    }
}


@Composable
fun RecordingStatusCard(
    trackingState: LocationTrackingService.TrackingState,
    isTracking: Boolean,
    footprintCount: Int,
    mileage: Double = 0.0,
    pointCount: Int = 0,
    summary: String? = null,
    pointsJson: String? = null,
    markersJson: String? = null,
    onNavigateToMap: () -> Unit,
    onRequestPermission: () -> Unit,
    hasLocationPermission: Boolean
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = if (isDark) MaterialTheme.colorScheme.onSurface else Color.Black.copy(alpha = 0.8f)
    val subtitleColor = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant else Color.Gray

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable { onNavigateToMap() },
        shape = RoundedCornerShape(26.dp),
        color = cardColor,
        shadowElevation = 2.dp,
        tonalElevation = 0.dp
    ) {
        Row(modifier = Modifier.fillMaxWidth()) {
            // 1. 左侧时间轴指示器 (在内部)
            Column(
                modifier = Modifier.width(52.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Spacer(modifier = Modifier.height(28.dp))
                
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
                            .background(subtitleColor.copy(alpha = 0.2f), CircleShape)
                    )
                }
                
                // 连接线
                Box(
                    modifier = Modifier
                        .width(1.5.dp)
                        .weight(1f)
                        .background(subtitleColor.copy(alpha = 0.1f))
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
                    Text("请允许后台获取位置信息以记录足迹。", style = MaterialTheme.typography.bodySmall, color = subtitleColor)
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(onClick = onRequestPermission, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(0.dp)) {
                        Text("授权并开启记录")
                    }
                } else {
                    Spacer(modifier = Modifier.height(18.dp))
                    
                    // 标题
                    val displayTitle = when (trackingState) {
                        is LocationTrackingService.TrackingState.Idle -> "定位记录已关闭"
                        is LocationTrackingService.TrackingState.Tracking -> "正在寻找位置..."
                        is LocationTrackingService.TrackingState.OngoingStay -> "正在此处停留"
                    }
                    Text(summary ?: displayTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = titleColor, maxLines = 2)
                    
                    val ongoing = trackingState as? LocationTrackingService.TrackingState.OngoingStay
                    val tracking = trackingState as? LocationTrackingService.TrackingState.Tracking
                    val currentLat = ongoing?.lat ?: tracking?.lat
                    val currentLon = ongoing?.lon ?: tracking?.lon
                    
                    // 地址
                    if (ongoing != null && !ongoing.address.isNullOrEmpty()) {
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(ongoing.address, style = MaterialTheme.typography.bodyMedium, color = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant else Color.DarkGray, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    
                    // 状态与统计行
                    Spacer(modifier = Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (!isTracking) {
                            Text("点击开启或查看说明", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                        } else {
                            if (ongoing != null) {
                                val durationMins = (System.currentTimeMillis() - ongoing.since.time) / 60000
                                val durationStr = if (durationMins < 60) "${durationMins}分钟" else "${durationMins / 60}小时${durationMins % 60}分"
                                Text("已停留 $durationStr", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.6f))
                                Text(" · ", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.3f))
                            }
                            Text("${footprintCount}个足迹 · ${formatDistance(mileage)}", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.6f))
                        }
                    }

                    // 小地图 (如果今天有轨迹，显示轨迹；否则显示当前位置)
                    Spacer(modifier = Modifier.height(12.dp))
                    if (pointsJson != null) {
                        MiniMapView(
                            pointsJson = pointsJson,
                            markersJson = markersJson,
                            onClick = onNavigateToMap
                        )
                    } else if (currentLat != null && currentLon != null) {
                        MiniMapView(
                            lat = currentLat, 
                            lon = currentLon,
                            isCurrentLocation = true,
                            onClick = onNavigateToMap
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun DayStatItem(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
        )
    }
}

@Composable
fun DayStatSeparator() {
    Box(
        modifier = Modifier
            .width(1.dp)
            .height(16.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
    )
}

@Composable
fun DaySummaryCard(
    footprintCount: Int,
    mileage: Double,
    pointCount: Int,
    summary: String?,
    pointsJson: String? = null,
    markersJson: String? = null,
    centerLat: Double? = null,
    centerLon: Double? = null,
    onNavigateToMap: () -> Unit
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = if (isDark) MaterialTheme.colorScheme.onSurface else Color.Black.copy(alpha = 0.8f)

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable { onNavigateToMap() },
        shape = RoundedCornerShape(26.dp),
        color = cardColor,
        shadowElevation = 3.dp,
        tonalElevation = 0.dp
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = summary ?: "当日概览", 
                style = MaterialTheme.typography.titleMedium, 
                fontWeight = FontWeight.Bold,
                color = titleColor,
                maxLines = 2
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(20.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                DayStatItem(value = "$footprintCount", label = "足迹")
                DayStatSeparator()
                DayStatItem(value = formatDistance(mileage), label = "里程数")
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 全天小地图预览 (与 iOS 一致)
            MiniMapView(
                lat = centerLat,
                lon = centerLon,
                pointsJson = pointsJson,
                markersJson = markersJson,
                onClick = onNavigateToMap
            )
        }
    }
}

private fun formatDistance(meters: Double): String {
    return if (meters < 1000) {
        "${meters.toInt()}m"
    } else {
        String.format("%.1fkm", meters / 1000.0)
    }
}

@Composable
fun MiniMapView(lat: Double? = null, lon: Double? = null, pointsJson: String? = null, markersJson: String? = null, isCurrentLocation: Boolean = false, onClick: () -> Unit) {
    val context = LocalContext.current
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clip(RoundedCornerShape(16.dp))
    ) {
        androidx.compose.ui.viewinterop.AndroidView(
            factory = { ctx ->
                com.amap.api.maps.TextureMapView(ctx).apply {
                    onCreate(android.os.Bundle())
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
            amap.mapType = if (isDark) com.amap.api.maps.AMap.MAP_TYPE_NIGHT else com.amap.api.maps.AMap.MAP_TYPE_NORMAL
            
            amap.uiSettings.apply {
                isZoomControlsEnabled = false
                isMyLocationButtonEnabled = false
                isRotateGesturesEnabled = false
                isTiltGesturesEnabled = false
                isScrollGesturesEnabled = false
                isZoomGesturesEnabled = false
            }
            
            amap.clear()
            
            if (isCurrentLocation && lat != null && lon != null) {
                val myLocationStyle = com.amap.api.maps.model.MyLocationStyle()
                myLocationStyle.myLocationType(com.amap.api.maps.model.MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE_NO_CENTER)
                myLocationStyle.showMyLocation(true)
                amap.myLocationStyle = myLocationStyle
                amap.isMyLocationEnabled = true
                val target = com.amap.api.maps.model.LatLng(lat, lon)
                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(target, 16f))
            } else if (pointsJson != null) {
                try {
                    val array = org.json.JSONArray(pointsJson)
                    val points = mutableListOf<com.amap.api.maps.model.LatLng>()
                    for (i in 0 until array.length()) {
                        val p = array.getJSONArray(i)
                        points.add(com.amap.api.maps.model.LatLng(p.getDouble(0), p.getDouble(1)))
                    }
                    if (points.isNotEmpty()) {
                        amap.addPolyline(
                            com.amap.api.maps.model.PolylineOptions().addAll(points).width(12f).color(primaryColor).useGradient(true)
                        )
                        
                        if (points.size == 1) {
                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points[0], 15f))
                        } else {
                            // 监听地图加载完成回调，确保 AMap 获得宽高后再执行 newLatLngBounds
                            amap.setOnMapLoadedListener {
                                try {
                                    val bounds = com.amap.api.maps.model.LatLngBounds.builder().apply {
                                        points.forEach { include(it) }
                                    }.build()
                                    // 增加 padding 比例，适配不同屏幕
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(bounds, 120))
                                    
                                    // 再次确认缩放防止因点太近导致的视野过大
                                    if (amap.cameraPosition.zoom > 15.5f) {
                                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.zoomTo(15.5f))
                                    }
                                } catch (e: Exception) {
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points.first(), 15f))
                                }
                            }
                            // 立即执行一次定位兜底
                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points.first(), 15f))
                        }
                    }
                } catch (e: Exception) {}
            } else if (lat != null && lon != null) {
                val target = com.amap.api.maps.model.LatLng(lat, lon)
                amap.addMarker(com.amap.api.maps.model.MarkerOptions().position(target))
                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(target, 16f))
            }
            
            // 绘制足迹点标记 (实心圆点)
            if (markersJson != null) {
                try {
                    val mArray = org.json.JSONArray(markersJson)
                    for (i in 0 until mArray.length()) {
                        val p = mArray.getJSONArray(i)
                        val pos = com.amap.api.maps.model.LatLng(p.getDouble(0), p.getDouble(1))
                        amap.addCircle(
                            com.amap.api.maps.model.CircleOptions()
                                .center(pos)
                                .radius(30.0) // 约 30 米
                                .fillColor(primaryColor)
                                .strokeColor(androidx.compose.ui.graphics.Color.White.toArgb())
                                .strokeWidth(2f)
                        )
                    }
                } catch (e: Exception) {}
            }
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Transparent)
                .clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null
                ) {
                    onClick()
                }
        )
    }
}

@Composable
fun PlaceholderFootprintCard(trackingState: LocationTrackingService.TrackingState) {
    val phrases = listOf(
        "今日份回忆正在后台悄悄酝酿...",
        "正在捕捉第一段时光足迹...",
        "别急，这一天的故事正在落笔...",
        "时光正在被系统悉心收纳...",
        "正在为您打磨今日的轨迹线...",
        "第一段记忆正在慢慢发酵..."
    )
    val phrase by remember { mutableStateOf(phrases.random()) }
    val calendar = java.util.Calendar.getInstance()
    val hour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
    val speed = when (trackingState) {
        is LocationTrackingService.TrackingState.Tracking -> trackingState.speed
        is LocationTrackingService.TrackingState.OngoingStay -> trackingState.speed
        else -> 0.0
    }
    
    val contextTip = when {
        // 1. 移动状态提示
        speed * 3.6 > 20 -> "正在飞驰中，注意安全"
        
        // 2. 时间维度提示
        hour >= 23 || hour <= 4 -> "夜深了，早点休息"
        hour in 5..8 -> "早安！又是活力满满的一天"
        
        // 3. 深度停留提示
        trackingState is LocationTrackingService.TrackingState.OngoingStay -> {
            val durationHours = (System.currentTimeMillis() - trackingState.since.time) / 3600000.0
            if (durationHours > 48) "要不出去走走？世界那么大，去看看"
            else if (durationHours > 15) "你已经在这里停留好久了，想去探索新地方吗？"
            else null
        }
        else -> null
    }

    val infiniteTransition = rememberInfiniteTransition(label = "skeleton")
    val opacity by infiniteTransition.animateFloat(
        initialValue = 0.5f, targetValue = 0.9f,
        animationSpec = infiniteRepeatable(animation = tween(1500), repeatMode = RepeatMode.Reverse), label = "opacity"
    )

    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = if (isDark) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.3f)
    val subtitleColor = if (isDark) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f) else Color.Gray.copy(alpha = 0.4f)

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .graphicsLayer { this.alpha = opacity },
        shape = RoundedCornerShape(26.dp),
        color = cardColor,
        shadowElevation = 1.dp,
        tonalElevation = 0.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
        ) {
            Box(modifier = Modifier.width(52.dp), contentAlignment = Alignment.TopCenter) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(1.5.dp)
                        .background(subtitleColor.copy(alpha = 0.1f))
                )
                
                Box(
                    modifier = Modifier
                        .padding(top = 28.dp)
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(subtitleColor.copy(alpha = 0.2f))
                )
            }

            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = phrase,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = titleColor
                )
                
                if (contextTip != null) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = contextTip,
                        style = MaterialTheme.typography.labelSmall,
                        color = subtitleColor,
                        fontWeight = FontWeight.Bold
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))
                
                // Skeleton bars
                Box(modifier = Modifier.width(140.dp).height(8.dp).clip(RoundedCornerShape(4.dp)).background(subtitleColor.copy(alpha = 0.1f)))
                Spacer(modifier = Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.width(60.dp).height(8.dp).clip(RoundedCornerShape(4.dp)).background(subtitleColor.copy(alpha = 0.05f)))
                    Spacer(modifier = Modifier.width(6.dp))
                    Box(modifier = Modifier.size(3.dp).clip(CircleShape).background(subtitleColor.copy(alpha = 0.05f)))
                    Spacer(modifier = Modifier.width(6.dp))
                    Box(modifier = Modifier.width(40.dp).height(8.dp).clip(RoundedCornerShape(4.dp)).background(subtitleColor.copy(alpha = 0.05f)))
                }
            }
        }
    }
}

@Composable
fun TimelineRow(
    item: com.ct106.difangke.data.model.TimelineItem,
    isFirst: Boolean,
    isLast: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity> = emptyList(),
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity> = emptyList(),
    showTimeline: Boolean = true,
    onClick: () -> Unit
) {
    when (item) {
        is com.ct106.difangke.data.model.TimelineItem.FootprintItem -> {
            FootprintCardView(
                footprint = item.footprint,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                isFirst = isFirst,
                isLast = isLast,
                showTimeline = showTimeline,
                onClick = onClick
            )
        }
        is com.ct106.difangke.data.model.TimelineItem.TransportItem -> {
            TransportCardView(
                transport = item.transport,
                isFirst = isFirst,
                isLast = isLast,
                showTimeline = showTimeline,
                onClick = onClick
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CalendarSelectionDialog(
    currentDate: java.util.Date,
    availableDates: List<java.util.Date>,
    onDateSelected: (java.util.Date) -> Unit,
    onDismiss: () -> Unit,
    onOpenFullPicker: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("选择日期", fontWeight = FontWeight.Bold) },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                val cal = java.util.Calendar.getInstance()
                val today = cal.apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0)
                    set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0)
                    set(java.util.Calendar.MILLISECOND, 0)
                }.time

                // 最近 14 天的快速选择 (由于 UI 限制，仅展示有数据的日期)
                val displayDates = availableDates.sortedByDescending { it.time }.take(14)
                
                LazyVerticalGrid(
                    columns = GridCells.Fixed(4),
                    modifier = Modifier.heightIn(max = 200.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(displayDates) { date ->
                        val isSelected = date.time == currentDate.time
                        val sdf = SimpleDateFormat("M/d", Locale.CHINA)
                        
                        Box(
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(12.dp))
                                .background(if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                                .clickable { onDateSelected(date) },
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                sdf.format(date),
                                style = MaterialTheme.typography.labelMedium,
                                color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurface,
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
                            )
                        }
                    }
                }
                
                Spacer(modifier = Modifier.height(16.dp))
                
                TextButton(
                    onClick = onOpenFullPicker,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.CalendarMonth, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("打开完整日历")
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}
