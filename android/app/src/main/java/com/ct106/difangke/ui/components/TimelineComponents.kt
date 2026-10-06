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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
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
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import com.tencent.tencentmap.mapsdk.maps.model.MyLocationStyle
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions

/** Displays a stored MediaStore/document URI without adding a second image-loading stack. */
@Composable
fun FootprintPhotoThumbnail(
    uri: String,
    modifier: Modifier = Modifier,
    contentDescription: String? = null
) {
    AndroidView(
        factory = { context ->
            android.widget.ImageView(context).apply {
                scaleType = android.widget.ImageView.ScaleType.CENTER_CROP
                setImageURI(runCatching { android.net.Uri.parse(uri) }.getOrNull())
                this.contentDescription = contentDescription
            }
        },
        update = { imageView ->
            imageView.setImageURI(runCatching { android.net.Uri.parse(uri) }.getOrNull())
            imageView.contentDescription = contentDescription
        },
        modifier = modifier
    )
}

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

private fun distanceMeters(first: LatLng, second: LatLng): Float {
    val result = FloatArray(1)
    android.location.Location.distanceBetween(
        first.latitude,
        first.longitude,
        second.latitude,
        second.longitude,
        result
    )
    return result[0]
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
                            FootprintPhotoThumbnail(
                                uri = photoIds.first(),
                                modifier = Modifier.fillMaxSize(),
                                contentDescription = "足迹照片"
                            )
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
        else -> Unit
    }
}

/** Public accessor for the timeline transport glyph (main timeline rows and map). */
@Composable
fun timelineTransportIcon(typeRaw: String): ImageVector = getTransportIcon(typeRaw)
