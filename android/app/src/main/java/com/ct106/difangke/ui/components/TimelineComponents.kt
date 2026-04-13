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
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.service.LocationTrackingService
import java.text.SimpleDateFormat
import java.util.Locale
import androidx.compose.ui.text.style.TextAlign

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
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary)
            )
        }
        
        // 核心卡片
        ElevatedCard(
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 8.dp)
                .clickable { onClick() },
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.elevatedCardColors(
                containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color.Black else Color.White
            ),
            elevation = CardDefaults.elevatedCardElevation(defaultElevation = 2.dp)
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                // 背景图标 (iOS 风格)
                Icon(
                    imageVector = getActivityIcon(footprint.activityTypeValue),
                    contentDescription = null,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 16.dp, end = 16.dp)
                        .size(24.dp),
                    tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                )

                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = footprint.title.ifEmpty { "足迹记录" },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(4.dp))
                    
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Place, 
                            contentDescription = null,
                            modifier = Modifier.size(10.dp),
                            tint = MaterialTheme.colorScheme.primary.copy(alpha=0.4f)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = footprint.address ?: "未解析的位置",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            maxLines = 1
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(4.dp))
                    
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "${TIME_FORMAT.format(footprint.startTime)} - ${TIME_FORMAT.format(footprint.endTime)}",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        )
                        Text(
                            text = " · ",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)
                        )
                        Text(
                            text = DURATION_FORMAT(footprint.duration.toInt()),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        )
                    }
                    
                    if (!footprint.reason.isNullOrEmpty()) {
                        Spacer(modifier = Modifier.height(14.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.05f))
                                .padding(12.dp)
                        ) {
                            Text(
                                text = "“${footprint.reason}”",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                                fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
                                lineHeight = 22.sp
                            )
                        }
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
                    .background(MaterialTheme.colorScheme.surface),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.DirectionsBus, 
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = MaterialTheme.colorScheme.primary
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
                        color = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    val durationSec = ((transport.endTime.time - transport.startTime.time) / 1000).toInt()
                    Text(
                        text = DURATION_FORMAT(durationSec),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
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
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color.Black else Color.White
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 2.dp)
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
                            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f), CircleShape)
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
                        val displayText = if (durationMins < 60) {
                            "已停留 ${durationMins}分钟"
                        } else {
                            "已停留 ${durationMins / 60}小时${durationMins % 60}分"
                        }
                        Text(displayText, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=0.6f))
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
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable { onNavigateToMap() },
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color.Black else Color.White
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 4.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = summary ?: "当日概览", 
                style = MaterialTheme.typography.titleMedium, 
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(20.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                DayStatItem(value = "$pointCount", label = "轨迹点")
                DayStatSeparator()
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

private fun getActivityIcon(type: String?): androidx.compose.ui.graphics.vector.ImageVector {
    return when(type) {
        "walk" -> Icons.Default.DirectionsWalk
        "run" -> Icons.Default.DirectionsRun
        "cycle" -> Icons.Default.DirectionsBike
        "car" -> Icons.Default.DirectionsCar
        "train" -> Icons.Default.Train
        "plane" -> Icons.Default.AirplanemodeActive
        "eat" -> Icons.Default.Restaurant
        "work" -> Icons.Default.BusinessCenter
        "home" -> Icons.Default.Home
        "shopping" -> Icons.Default.ShoppingCart
        "sightseeing" -> Icons.Default.PhotoCamera
        else -> Icons.AutoMirrored.Filled.Help
    }
}

@Composable
fun DailyInsightView(content: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Icon(
                Icons.Default.AutoAwesome,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.6f),
                modifier = Modifier.size(14.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "今日洞察",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.6f),
                fontWeight = FontWeight.Bold
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = content,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f),
            textAlign = TextAlign.Center,
            fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
            lineHeight = 20.sp
        )
        
        // 装饰性分割线 (极淡)
        Spacer(modifier = Modifier.height(16.dp))
        HorizontalDivider(
            modifier = Modifier.width(40.dp),
            thickness = 1.dp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)
        )
    }
}

@Composable
fun MiniMapView(lat: Double? = null, lon: Double? = null, pointsJson: String? = null, markersJson: String? = null, onClick: () -> Unit) {
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
            
            if (pointsJson != null) {
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
                        val bounds = com.amap.api.maps.model.LatLngBounds.builder().apply {
                            points.forEach { include(it) }
                        }.build()
                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(bounds, 60))
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
    
    val contextTip = remember(trackingState) {
        val calendar = java.util.Calendar.getInstance()
        val hour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
        
        when {
            trackingState is LocationTrackingService.TrackingState.OngoingStay -> {
                val durationMins = (System.currentTimeMillis() - trackingState.since.time) / 60000
                if (durationMins > 480) "要不出去走走？世界那么大，去看看"
                else if (durationMins > 240) "你已经在这里停留好久了，想去探索新地方吗？"
                else null
            }
            hour >= 23 || hour <= 4 -> "夜深了，早点休息"
            hour in 5..8 -> "早安！又是活力满满的一天"
            else -> null
        }
    }

    val infiniteTransition = rememberInfiniteTransition(label = "skeleton")
    val opacity by infiniteTransition.animateFloat(
        initialValue = 0.5f,
        targetValue = 0.9f,
        animationSpec = infiniteRepeatable(
            animation = tween(1500, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "opacity"
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(IntrinsicSize.Min)
            .graphicsLayer { this.alpha = opacity }
    ) {
        Box(modifier = Modifier.width(40.dp), contentAlignment = Alignment.TopCenter) {
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .width(1.5.dp)
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
            )
            
            Box(
                modifier = Modifier
                    .padding(top = 28.dp)
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))
            )
        }

        ElevatedCard(
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 8.dp),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.elevatedCardColors(
                containerColor = if (androidx.compose.foundation.isSystemInDarkTheme()) Color.Black.copy(alpha = 0.5f) else Color.White
            ),
            elevation = CardDefaults.elevatedCardElevation(defaultElevation = 1.dp)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = phrase,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                )
                
                if (contextTip != null) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = contextTip,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                        fontWeight = FontWeight.Bold
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))
                
                // Skeleton bars
                Box(
                    modifier = Modifier
                        .width(140.dp)
                        .height(8.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                )
                
                Spacer(modifier = Modifier.height(8.dp))
                
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .width(60.dp)
                            .height(8.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.03f))
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Box(
                        modifier = Modifier
                            .size(3.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.03f))
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Box(
                        modifier = Modifier
                            .width(40.dp)
                            .height(8.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.03f))
                    )
                }
            }
        }
    }
}
