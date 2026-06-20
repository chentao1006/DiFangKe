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
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.service.LocationTrackingService
import java.text.SimpleDateFormat
import java.util.Locale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items

@Composable
fun Modifier.breathing(isActive: Boolean): Modifier {
    if (!isActive) return this
    
    val infiniteTransition = rememberInfiniteTransition(label = "breathing")
    val opacity by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 0.4f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "opacity"
    )
    
    return this.graphicsLayer(alpha = opacity)
}

private val TIME_FORMAT = SimpleDateFormat("HH:mm", Locale.CHINA)
private val DURATION_FORMAT = { durationSec: Int -> 
    val min = durationSec / 60
    if (min < 60) "${min}分钟" else "${min / 60}小时${min % 60}分"
}

@Composable
fun TimelineLine(isFirst: Boolean, isLast: Boolean, isTransport: Boolean = false) {
    val color = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
    val dashColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.25f)
    
    Canvas(modifier = Modifier.width(54.dp).fillMaxHeight()) {
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
            // 内容区
            val activityType = activityTypes.find { it.id == footprint.activityTypeValue }
            val iconName = activityType?.icon ?: "place"
            val iconColor = try {
                if (activityType?.colorHex != null) Color(android.graphics.Color.parseColor(activityType.colorHex))
                else getIconColorForName(iconName)
            } catch (e: Exception) {
                getIconColorForName(iconName)
            }

            // 时间轴指示器 (在卡片内部)
            Box(modifier = Modifier.width(54.dp), contentAlignment = Alignment.TopCenter) {
                if (showTimeline) {
                    TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = false)
                }

                // 活动图标
                Box(
                    modifier = Modifier
                        .padding(top = 12.dp)
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(cardColor),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = getIconForName(iconName),
                        contentDescription = null,
                        modifier = Modifier.size(24.dp),
                        tint = iconColor
                    )

                    if (footprint.isHighlight == true) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .offset(x = 2.dp, y = 2.dp)
                                .size(12.dp)
                                .clip(CircleShape)
                                .background(Color.White)
                                .padding(1.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Star,
                                contentDescription = null,
                                modifier = Modifier.size(10.dp),
                                tint = Color(0xFFFFCC00)
                            )
                        }
                    }
                }
            }
            
            // 照片缩略图 logic
            val photoIds = remember(footprint.photoAssetIDsJson) {
                try {
                    com.google.gson.Gson().fromJson(footprint.photoAssetIDsJson, Array<String>::class.java).toList()
                } catch (e: Exception) {
                    emptyList<String>()
                }
            }

            Box(modifier = Modifier.weight(1f)) {
                Column(
                    modifier = Modifier
                        .padding(vertical = 14.dp)
                        .padding(end = if (photoIds.isNotEmpty()) 84.dp else 16.dp)
                ) {
                    val matchedPlace = footprint.placeID?.let { placeID ->
                        allPlaces.find { place -> place.placeID == placeID && place.isUserDefined }
                    }
                    val locationText = when {
                        matchedPlace != null -> matchedPlace.name
                        !footprint.address.isNullOrEmpty() && footprint.address != "null" && footprint.address != "[]" -> footprint.address!!
                        else -> "未知位置"
                    }

                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = locationText,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (matchedPlace?.isUserDefined == true) Color(0xFFFF9800) else titleColor,
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
                        val durationStr = when {
                            durationMins < 60 -> "${durationMins}m"
                            durationMins < 1440 -> "${durationMins / 60}h${durationMins % 60}m"
                            else -> "${durationMins / 1440}d${(durationMins % 1440) / 60}h"
                        }
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
                            style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            lineHeight = 18.sp,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }

                if (photoIds.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(top = 12.dp, end = 12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(60.dp)
                                .clip(RoundedCornerShape(10.dp))
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
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity> = emptyList(),
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
            Box(modifier = Modifier.width(54.dp), contentAlignment = Alignment.TopCenter) {
                if (showTimeline) {
                    TimelineLine(isFirst = isFirst, isLast = isLast, isTransport = true)
                }

                // 交通工具图标 (代替原本的小圆点)
                Box(
                    modifier = Modifier
                        .padding(top = 10.dp)
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(cardColor),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = getTransportIcon(transport.manualTypeRaw ?: transport.typeRaw),
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = MaterialTheme.colorScheme.primary
                    )
                }
            }
            
            // 2. 内容区 (极简单行风格)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 12.dp)
                    .padding(end = 16.dp),
                verticalArrangement = Arrangement.Center
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    // 时间范围
                    Text(
                        text = "${TIME_FORMAT.format(transport.startTime)}-${TIME_FORMAT.format(transport.endTime)}",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        color = subtitleColor.copy(alpha = 0.6f)
                    )
                    
                    Text("·", color = subtitleColor.copy(alpha = 0.3f))
                    
                    // 总时长
                    Text(
                        text = DURATION_FORMAT((transport.endTime.time - transport.startTime.time).toInt() / 1000),
                        style = MaterialTheme.typography.labelSmall,
                        color = subtitleColor.copy(alpha = 0.6f)
                    )
                    
                    Text("·", color = subtitleColor.copy(alpha = 0.3f))
                    
                    // 里程
                    val distanceKm = transport.distance / 1000.0
                    val distanceText = if (distanceKm < 1.0) "${transport.distance.toInt()}米" else String.format("%.1f公里", distanceKm)
                    Text(
                        text = distanceText,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary
                    )
                    
                    Text("·", color = subtitleColor.copy(alpha = 0.3f))
                    
                    // 速度
                    Text(
                        text = String.format("%.1fkm/h", transport.averageSpeed * 3.6),
                        style = MaterialTheme.typography.labelSmall,
                        color = subtitleColor.copy(alpha = 0.6f)
                    )
                }
            }
        }
    }
}

@Composable
private fun getTransportIcon(typeRaw: String): ImageVector {
    val type = com.ct106.difangke.data.model.TransportType.from(typeRaw)
    return when(type) {
        com.ct106.difangke.data.model.TransportType.SLOW -> Icons.AutoMirrored.Filled.DirectionsWalk
        com.ct106.difangke.data.model.TransportType.RUNNING -> Icons.AutoMirrored.Filled.DirectionsRun
        com.ct106.difangke.data.model.TransportType.BICYCLE -> Icons.AutoMirrored.Filled.DirectionsBike
        com.ct106.difangke.data.model.TransportType.EBIKE -> Icons.Default.ElectricMoped
        com.ct106.difangke.data.model.TransportType.MOTORCYCLE -> Icons.Default.TwoWheeler
        com.ct106.difangke.data.model.TransportType.BUS -> Icons.Default.DirectionsBus
        com.ct106.difangke.data.model.TransportType.CAR -> Icons.Default.DirectionsCar
        com.ct106.difangke.data.model.TransportType.SUBWAY -> Icons.Default.DirectionsSubway
        com.ct106.difangke.data.model.TransportType.TRAIN -> Icons.Default.Train
        com.ct106.difangke.data.model.TransportType.AIRPLANE -> Icons.Default.Flight
        com.ct106.difangke.data.model.TransportType.SHIP -> Icons.Default.DirectionsBoat
        else -> Icons.Default.DirectionsBus
    }
}


@Composable
fun RecordingStatusCard(
    trackingState: LocationTrackingService.TrackingState,
    isTracking: Boolean,
    isTrackingEnabled: Boolean,
    footprintCount: Int,
    mileage: Double = 0.0,
    pointCount: Int = 0,
    pointsJson: String? = null,
    markersJson: String? = null,
    footprintMarkers: List<FootprintMapMarker> = emptyList(),
    allPlaces: List<PlaceEntity> = emptyList(),
    onNavigateToMap: () -> Unit,
    onEnableTracking: () -> Unit,
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
                modifier = Modifier.width(54.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Spacer(modifier = Modifier.height(28.dp))
                
                // 呼吸效果圆点
                if (isTracking) {
                    val speed = when (trackingState) {
                        is LocationTrackingService.TrackingState.Tracking -> trackingState.speed
                        is LocationTrackingService.TrackingState.OngoingStay -> trackingState.speed
                        else -> 0.0
                    }
                    val animDuration = when {
                        speed > 10.0 -> 800  // 高速移动：0.8s (对应 Tier 2)
                        speed > 0.5 -> 1500  // 正常移动：1.5s (对应 Tier 1)
                        else -> 3000         // 停留：3s (对应 Tier 0)
                    }

                    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
                    val scale by infiniteTransition.animateFloat(
                        initialValue = 1.0f,
                        targetValue = 2.5f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(animDuration, easing = LinearEasing),
                            repeatMode = RepeatMode.Restart
                        ),
                        label = "scale"
                    )
                    val alpha by infiniteTransition.animateFloat(
                        initialValue = 0.4f,
                        targetValue = 0.0f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(animDuration, easing = LinearEasing),
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
                    val displayTitle = if (!isTrackingEnabled) {
                        "定位记录已关闭"
                    } else when (trackingState) {
                        is LocationTrackingService.TrackingState.Idle -> "定位记录已关闭"
                        is LocationTrackingService.TrackingState.Tracking -> "正在寻找位置..."
                        is LocationTrackingService.TrackingState.OngoingStay -> "正在此处停留"
                    }
                    Text(displayTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = titleColor, maxLines = 2)
                    
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
                            TextButton(
                                onClick = onEnableTracking,
                                contentPadding = PaddingValues(0.dp)
                            ) {
                                Text(
                                    "点击开启位置记录",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color(0xFFFF9500),
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        } else {
                            if (ongoing != null) {
                                val durationMins = (System.currentTimeMillis() - ongoing.since.time) / 60000
                                val durationStr = when {
                                    durationMins < 60 -> "${durationMins}分钟"
                                    durationMins < 1440 -> "${durationMins / 60}小时${durationMins % 60}分"
                                    else -> "${durationMins / 1440}天${(durationMins % 1440) / 60}小时"
                                }
                                Text("已停留 $durationStr", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.6f))
                                Text(" · ", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.3f))
                            }
                            Text("${footprintCount}个足迹 · ${formatDistance(mileage)}", style = MaterialTheme.typography.bodySmall, color = subtitleColor.copy(alpha=0.6f))
                        }
                    }

                    // 小地图：只有真实轨迹或定位成功后才显示，避免地图 SDK 默认中心显示成北京。
                    val hasCurrentLocation = currentLat.isRenderableCoordinate() && currentLon.isRenderableCoordinate()
                    val hasTrajectory = pointsJson.hasRenderableMapPoints()
                    val hasFootprintMarkers = footprintMarkers.isNotEmpty() || parseFootprintMapMarkers(markersJson).isNotEmpty()
                    if (hasTrajectory || hasFootprintMarkers || (isTracking && hasCurrentLocation)) {
                        Spacer(modifier = Modifier.height(12.dp))
                    }
                    if (hasTrajectory || hasFootprintMarkers) {
                        MiniMapView(
                            lat = currentLat,
                            lon = currentLon,
                            pointsJson = pointsJson,
                            markersJson = markersJson,
                            footprintMarkers = footprintMarkers,
                            allPlaces = allPlaces,
                            onClick = onNavigateToMap
                        )
                    } else if (isTracking && hasCurrentLocation) {
                        MiniMapView(
                            lat = currentLat, 
                            lon = currentLon,
                            isCurrentLocation = true,
                            allPlaces = allPlaces,
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
    allPlaces: List<PlaceEntity> = emptyList(),
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
        Row(modifier = Modifier.fillMaxWidth()) {
            // 左侧指示器
            Column(
                modifier = Modifier.width(54.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Spacer(modifier = Modifier.height(18.dp))
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = null,
                    modifier = Modifier.size(26.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
            }

            // 右侧内容
            Column(modifier = Modifier.padding(vertical = 20.dp, horizontal = 0.dp).padding(end = 20.dp)) {
                val isGenerating = summary == "正在生成概览..."
                Text(
                    text = summary ?: "当日概览", 
                    style = MaterialTheme.typography.titleMedium, 
                    fontWeight = FontWeight.Bold,
                    color = titleColor,
                    maxLines = 2,
                    modifier = Modifier.breathing(isActive = isGenerating)
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
                
                // 全天小地图预览：有轨迹或有效中心点才显示。
                if (pointsJson.hasRenderableMapPoints() || (centerLat.isRenderableCoordinate() && centerLon.isRenderableCoordinate())) {
                    MiniMapView(
                        lat = centerLat,
                        lon = centerLon,
                        pointsJson = pointsJson,
                        markersJson = markersJson,
                        allPlaces = allPlaces,
                        onClick = onNavigateToMap
                    )
                }
            }
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
fun MiniMapView(
    lat: Double? = null,
    lon: Double? = null,
    pointsJson: String? = null,
    markersJson: String? = null,
    footprintMarkers: List<FootprintMapMarker> = emptyList(),
    isCurrentLocation: Boolean = false,
    allPlaces: List<PlaceEntity> = emptyList(),
    onClick: () -> Unit
) {
    val mapMarkers = remember(footprintMarkers, markersJson) {
        footprintMarkers.ifEmpty { parseFootprintMapMarkers(markersJson) }
    }
    val hasCurrentLocation = isCurrentLocation && lat.isRenderableCoordinate() && lon.isRenderableCoordinate()
    val hasTrajectory = pointsJson.hasRenderableMapPoints()
    val hasCenter = lat.isRenderableCoordinate() && lon.isRenderableCoordinate()
    val hasFootprintMarkers = mapMarkers.any { it.latitude.isRenderableCoordinate() && it.longitude.isRenderableCoordinate() }
    if (!hasCurrentLocation && !hasTrajectory && !hasCenter && !hasFootprintMarkers) return

    val context = LocalContext.current
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    var hasCentred by remember { mutableStateOf(false) }
    
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
            amap.addImportantPlaceCircles(allPlaces)
            val markerPoints = mapMarkers
                .filter { it.latitude.isRenderableCoordinate() && it.longitude.isRenderableCoordinate() }
                .map { com.amap.api.maps.model.LatLng(it.latitude, it.longitude) }
            
            var handledCentering = false
            
            if (isCurrentLocation && lat != null && lon != null) {
                val myLocationStyle = com.amap.api.maps.model.MyLocationStyle()
                myLocationStyle.myLocationType(com.amap.api.maps.model.MyLocationStyle.LOCATION_TYPE_LOCATION_ROTATE_NO_CENTER)
                myLocationStyle.showMyLocation(true)
                amap.myLocationStyle = myLocationStyle
                amap.isMyLocationEnabled = true
                val target = com.amap.api.maps.model.LatLng(lat, lon)
                if (!hasCentred) {
                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(target, 13.5f))
                    hasCentred = true
                }
                handledCentering = true
            }
            
            if (!handledCentering && pointsJson != null) {
                try {
                    val array = org.json.JSONArray(pointsJson)
                    val validPoints = mutableListOf<com.amap.api.maps.model.LatLng>()
                    class SegmentInfo(val points: MutableList<com.amap.api.maps.model.LatLng> = mutableListOf(), var connectToNextWithDash: Boolean = false)
                    val segmentsInfo = mutableListOf<SegmentInfo>()
                    var currentSegment = SegmentInfo()

                    for (i in 0 until array.length()) {
                        val p = array.getJSONArray(i)
                        val lat = p.getDouble(0)
                        val lon = p.getDouble(1)
                        if (lat == 0.0 && lon == 0.0) {
                            if (currentSegment.points.isNotEmpty()) {
                                currentSegment.connectToNextWithDash = true
                                segmentsInfo.add(currentSegment)
                                currentSegment = SegmentInfo()
                            }
                        } else {
                            val ll = com.amap.api.maps.model.LatLng(lat, lon)
                            currentSegment.points.add(ll)
                            validPoints.add(ll)
                        }
                    }
                    if (currentSegment.points.isNotEmpty()) {
                        segmentsInfo.add(currentSegment)
                    }

                    val processedSegments = segmentsInfo.map { segmentInfo ->
                        val segment = segmentInfo.points
                        val splineLatLngs = mutableListOf<com.amap.api.maps.model.LatLng>()
                        
                        if (segment.size > 1) {
                            val filtered = mutableListOf<com.amap.api.maps.model.LatLng>()
                            filtered.add(segment.first())
                            for (i in 1 until segment.size - 1) {
                                val prev = filtered.last()
                                val curr = segment[i]
                                val dist = com.amap.api.maps.AMapUtils.calculateLineDistance(prev, curr)
                                if (dist > 4f) {
                                    filtered.add(curr)
                                }
                            }
                            if (segment.size > 2) {
                                filtered.add(segment.last())
                            } else if (segment.size == 2) {
                                filtered.add(segment[1])
                            }

                            val averagedLatLngs = mutableListOf<com.amap.api.maps.model.LatLng>()
                            val windowSize = 5
                            val halfWindow = windowSize / 2
                            for (i in filtered.indices) {
                                if (i == 0 || i == filtered.size - 1) {
                                    averagedLatLngs.add(filtered[i])
                                    continue
                                }
                                var sumLat = 0.0; var sumLng = 0.0; var count = 0
                                val start = maxOf(0, i - halfWindow)
                                val end = minOf(filtered.size - 1, i + halfWindow)
                                for (j in start..end) {
                                    sumLat += filtered[j].latitude
                                    sumLng += filtered[j].longitude
                                    count++
                                }
                                averagedLatLngs.add(com.amap.api.maps.model.LatLng(sumLat / count, sumLng / count))
                            }

                            if (averagedLatLngs.size >= 3) {
                                val granularity = 10
                                for (i in 0 until averagedLatLngs.size - 1) {
                                    val p0 = averagedLatLngs[maxOf(i - 1, 0)]
                                    val p1 = averagedLatLngs[i]
                                    val p2 = averagedLatLngs[i + 1]
                                    val p3 = averagedLatLngs[minOf(i + 2, averagedLatLngs.size - 1)]
                                    for (tStep in 0 until granularity) {
                                        val t = tStep.toDouble() / granularity.toDouble()
                                        val t2 = t * t; val t3 = t2 * t
                                        val lat = 0.5 * ((2.0 * p1.latitude) + (-p0.latitude + p2.latitude) * t + (2.0 * p0.latitude - 5.0 * p1.latitude + 4.0 * p2.latitude - p3.latitude) * t2 + (-p0.latitude + 3.0 * p1.latitude - 3.0 * p2.latitude + p3.latitude) * t3)
                                        val lon = 0.5 * ((2.0 * p1.longitude) + (-p0.longitude + p2.longitude) * t + (2.0 * p0.longitude - 5.0 * p1.longitude + 4.0 * p2.longitude - p3.longitude) * t2 + (-p0.longitude + 3.0 * p1.longitude - 3.0 * p2.longitude + p3.longitude) * t3)
                                        splineLatLngs.add(com.amap.api.maps.model.LatLng(lat, lon))
                                    }
                                }
                                splineLatLngs.add(averagedLatLngs.last())
                            } else {
                                splineLatLngs.addAll(averagedLatLngs)
                            }
                        }
                        Pair(segmentInfo, splineLatLngs)
                    }

                    if (validPoints.isNotEmpty()) {
                        processedSegments.forEach { (_, splined) ->
                            if (splined.isNotEmpty()) {
                                val options = com.amap.api.maps.model.PolylineOptions().addAll(splined).width(12f).color(primaryColor).useGradient(true)
                                    .lineJoinType(com.amap.api.maps.model.PolylineOptions.LineJoinType.LineJoinRound)
                                    .lineCapType(com.amap.api.maps.model.PolylineOptions.LineCapType.LineCapRound)
                                amap.addPolyline(options)
                            }
                        }

                        for (i in 0 until processedSegments.size - 1) {
                            val (segA, splinedA) = processedSegments[i]
                            val (_, splinedB) = processedSegments[i + 1]
                            
                            if (segA.connectToNextWithDash && splinedA.isNotEmpty() && splinedB.isNotEmpty()) {
                                val p0 = splinedA.last()
                                val p3 = splinedB.first()
                                
                                val p0TangentPrev = if (splinedA.size >= 10) splinedA[splinedA.size - 1 - minOf(splinedA.size - 1, 10)] else if (splinedA.size >= 2) splinedA.first() else null
                                val p3TangentNext = if (splinedB.size >= 10) splinedB[minOf(splinedB.size - 1, 10)] else if (splinedB.size >= 2) splinedB.last() else null
                                
                                val dLat0 = if (p0TangentPrev != null) p0.latitude - p0TangentPrev.latitude else 0.0
                                val dLon0 = if (p0TangentPrev != null) p0.longitude - p0TangentPrev.longitude else 0.0
                                val dLat3 = if (p3TangentNext != null) p3TangentNext.latitude - p3.latitude else 0.0
                                val dLon3 = if (p3TangentNext != null) p3TangentNext.longitude - p3.longitude else 0.0
                                
                                val distLat = p3.latitude - p0.latitude
                                val distLon = p3.longitude - p0.longitude
                                val dist = Math.sqrt(distLat*distLat + distLon*distLon)
                                
                                val len0 = Math.sqrt(dLat0*dLat0 + dLon0*dLon0)
                                val len3 = Math.sqrt(dLat3*dLat3 + dLon3*dLon3)
                                
                                val maxTangent = 0.005
                                val tLen0 = minOf(dist * 0.35, maxTangent)
                                val tLen3 = minOf(dist * 0.35, maxTangent)
                                val tLenFallback = minOf(dist * 0.3, maxTangent)
                                val scale0 = if (len0 > 0) tLen0 / len0 else 0.0
                                val scale3 = if (len3 > 0) tLen3 / len3 else 0.0
                                val fallbackScale = if (dist > 0) tLenFallback / dist else 0.0
                                
                                val c1 = com.amap.api.maps.model.LatLng(
                                    p0.latitude + (if(len0 > 0) dLat0 * scale0 else distLat * fallbackScale),
                                    p0.longitude + (if(len0 > 0) dLon0 * scale0 else distLon * fallbackScale)
                                )
                                val c2 = com.amap.api.maps.model.LatLng(
                                    p3.latitude - (if(len3 > 0) dLat3 * scale3 else distLat * fallbackScale),
                                    p3.longitude - (if(len3 > 0) dLon3 * scale3 else distLon * fallbackScale)
                                )
                                
                                val bezierPoints = mutableListOf<com.amap.api.maps.model.LatLng>()
                                val steps = 20
                                for (j in 0..steps) {
                                    val t = j.toDouble() / steps.toDouble()
                                    val u = 1.0 - t
                                    val u2 = u * u
                                    val u3 = u2 * u
                                    val t2 = t * t
                                    val t3 = t2 * t
                                    val lat = u3 * p0.latitude + 3.0 * u2 * t * c1.latitude + 3.0 * u * t2 * c2.latitude + t3 * p3.latitude
                                    val lon = u3 * p0.longitude + 3.0 * u2 * t * c1.longitude + 3.0 * u * t2 * c2.longitude + t3 * p3.longitude
                                    bezierPoints.add(com.amap.api.maps.model.LatLng(lat, lon))
                                }
                                
                                val dashedOptions = com.amap.api.maps.model.PolylineOptions().addAll(bezierPoints).width(12f).color(primaryColor).setDottedLine(true)
                                amap.addPolyline(dashedOptions)
                            }
                        }

                        val cameraPoints = validPoints + markerPoints
                        if (cameraPoints.size == 1) {
                            if (!hasCentred) {
                                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(cameraPoints[0], 13.5f))
                                hasCentred = true
                            }
                        } else {
                            val bounds = com.amap.api.maps.model.LatLngBounds.builder().apply {
                                cameraPoints.forEach { include(it) }
                            }.build()
                            val centerLat = (bounds.northeast.latitude + bounds.southwest.latitude) / 2
                            val centerLon = (bounds.northeast.longitude + bounds.southwest.longitude) / 2
                            val center = com.amap.api.maps.model.LatLng(centerLat, centerLon)
                            
                            val distance = com.amap.api.maps.AMapUtils.calculateLineDistance(bounds.southwest, bounds.northeast)
                            
                            if (!hasCentred) {
                                val doBounds = {
                                    val paddingPx = (30 * view.context.resources.displayMetrics.density).toInt()
                                    try {
                                        if (distance < 500f) {
                                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(center, 13.5f))
                                        } else {
                                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(bounds, paddingPx))
                                            if (amap.cameraPosition.zoom > 16f) {
                                                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.zoomTo(16f))
                                            }
                                        }
                                    } catch (e: Exception) {
                                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(center, 13.5f))
                                    }
                                }

                                if (view.width > 0 && view.height > 0) {
                                    doBounds()
                                } else {
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(center, 12f))
                                    amap.setOnMapLoadedListener { doBounds() }
                                }
                                hasCentred = true
                            }
                        }
                        handledCentering = true
                    }
                } catch (e: Exception) {}
            }

            if (!handledCentering && markerPoints.isNotEmpty()) {
                if (markerPoints.size == 1) {
                    if (!hasCentred) {
                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(markerPoints[0], 13.5f))
                        hasCentred = true
                    }
                } else {
                    val bounds = com.amap.api.maps.model.LatLngBounds.builder().apply {
                        markerPoints.forEach { include(it) }
                    }.build()
                    if (!hasCentred) {
                        val doBounds = {
                            val paddingPx = (30 * view.context.resources.displayMetrics.density).toInt()
                            try {
                                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(bounds, paddingPx))
                                if (amap.cameraPosition.zoom > 16f) {
                                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.zoomTo(16f))
                                }
                            } catch (e: Exception) {
                                val centerLat = (bounds.northeast.latitude + bounds.southwest.latitude) / 2
                                val centerLon = (bounds.northeast.longitude + bounds.southwest.longitude) / 2
                                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(com.amap.api.maps.model.LatLng(centerLat, centerLon), 13.5f))
                            }
                        }

                        if (view.width > 0 && view.height > 0) {
                            doBounds()
                        } else {
                            val centerLat = (bounds.northeast.latitude + bounds.southwest.latitude) / 2
                            val centerLon = (bounds.northeast.longitude + bounds.southwest.longitude) / 2
                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(com.amap.api.maps.model.LatLng(centerLat, centerLon), 12f))
                            amap.setOnMapLoadedListener { doBounds() }
                        }
                        hasCentred = true
                    }
                }
                handledCentering = true
            }
            
            val fallbackLat = lat
            val fallbackLon = lon
            if (!handledCentering && fallbackLat.isRenderableCoordinate() && fallbackLon.isRenderableCoordinate()) {
                val target = com.amap.api.maps.model.LatLng(fallbackLat!!, fallbackLon!!)
                amap.addMarker(com.amap.api.maps.model.MarkerOptions().position(target))
                if (!hasCentred) {
                    amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(target, 13.5f))
                    hasCentred = true
                }
            }

            // 绘制足迹点标记 (实心圆点)
            if (mapMarkers.isNotEmpty()) {
                amap.addFootprintMarkers(mapMarkers, isDark = isDark)
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

private fun Double?.isRenderableCoordinate(): Boolean {
    val value = this ?: return false
    return value.isFinite() && value != 0.0
}

private fun String?.hasRenderableMapPoints(): Boolean {
    if (isNullOrBlank() || this == "[]") return false
    return runCatching {
        val array = org.json.JSONArray(this)
        for (i in 0 until array.length()) {
            val point = array.optJSONArray(i) ?: continue
            val lat = point.optDouble(0, Double.NaN)
            val lon = point.optDouble(1, Double.NaN)
            if (lat.isFinite() && lon.isFinite() && lat != 0.0 && lon != 0.0) {
                return@runCatching true
            }
        }
        false
    }.getOrDefault(false)
}

@Composable
fun PlaceholderFootprintCard(trackingState: LocationTrackingService.TrackingState) {
    val phrases = listOf(
        "新的足迹正在记录...",
        "新的足迹即将生成...",
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
                allPlaces = allPlaces,
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
