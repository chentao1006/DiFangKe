package com.ct106.difangke.ui.screens.main

import android.content.Context
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.NearbyPlacePickerSheet
import com.ct106.difangke.ui.theme.DfkAccent
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal fun requestConfirmArrival(context: Context) {
    LocationTrackingService.requestConfirmArrival(context)
}

/** iOS "确认已到达？" alert. */
@Composable
internal fun ArrivalConfirmationDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("确认已到达？") },
        text = { Text("将结束当前移动，并开始记录停留。") },
        confirmButton = { TextButton(onClick = onConfirm) { Text("确认到达") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Float {
    val r = FloatArray(1)
    android.location.Location.distanceBetween(lat1, lon1, lat2, lon2, r)
    return r[0]
}

/**
 * iOS CurrentStayTimelineCard: ticking clock, breathing marker (1.4×),
 * "正在<地点>停留" with a dotted, tappable place name, or moving status with
 * the "已到达" button.
 */
@Composable
internal fun CurrentStayTimelineRow(
    trackingState: LocationTrackingService.TrackingState,
    places: List<PlaceEntity>,
    onRequestArrival: () -> Unit
) {
    val context = LocalContext.current
    val ongoing = trackingState as? LocationTrackingService.TrackingState.OngoingStay
    val tracking = trackingState as? LocationTrackingService.TrackingState.Tracking
    var showPlacePicker by remember { mutableStateOf(false) }
    var nowMillis by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMillis = System.currentTimeMillis()
            delay(1_000L)
        }
    }

    val speedKmh = ((ongoing?.speed ?: tracking?.speed ?: 0.0).coerceAtLeast(0.0)) * 3.6
    val isMoving = ongoing == null
    val userPlaces = places.filter { it.isUserDefined && !it.isIgnored }
    val placeName = remember(ongoing, places) {
        if (ongoing == null) "此处" else {
            val matched = userPlaces
                .filter { distanceMeters(ongoing.lat, ongoing.lon, it.latitude, it.longitude) <= maxOf(it.radius, 30f) }
                .minByOrNull { distanceMeters(ongoing.lat, ongoing.lon, it.latitude, it.longitude) }
            val address = ongoing.address?.trim().orEmpty()
            matched?.name ?: if (address.isEmpty() || address == "正在解析位置..." || address == "未知位置") "此处" else address
        }
    }
    val title = when {
        !isMoving -> "正在${placeName}停留"
        speedKmh > 90 -> "正在高速移动"
        speedKmh > 30 -> "正在快速移动"
        speedKmh > 5 -> "正在持续移动"
        else -> "正在移动"
    }
    val detail = if (ongoing != null) {
        "已 ${formattedTimelineDuration((nowMillis - ongoing.since.time).coerceAtLeast(0L) / 1000)}"
    } else {
        String.format(Locale.CHINA, "当前速度 %.1f 千米/小时", speedKmh)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 92.dp)
            .height(IntrinsicSize.Min)
            .padding(horizontal = 16.dp)
    ) {
        Text(
            SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(nowMillis)),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.width(TimelineLayout.timeColumnWidth).padding(top = 24.dp)
        )
        Spacer(Modifier.width(TimelineLayout.markerSpacing))
        Column(
            Modifier.width(TimelineLayout.markerSize).fillMaxHeight(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(Modifier.width(2.dp).height(20.dp).background(timelineLineColor()))
            BreathingMarker(speedMs = speedKmh / 3.6, modifier = Modifier.size(TimelineLayout.markerSize).scale(1.4f))
            Box(Modifier.width(2.dp).weight(1f).background(timelineLineColor()))
        }
        Spacer(Modifier.width(TimelineLayout.markerSpacing))
        Column(
            modifier = Modifier.weight(1f).padding(vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (ongoing != null) {
                val underline = MaterialTheme.colorScheme.onSurface
                Row(
                    modifier = Modifier.clickable { showPlacePicker = true },
                    verticalAlignment = Alignment.Bottom
                ) {
                    Text("正在", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(
                        placeName,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.drawBehind {
                            val y = size.height - 1.dp.toPx()
                            drawLine(
                                color = underline,
                                start = Offset(0f, y),
                                end = Offset(size.width, y),
                                strokeWidth = 1.dp.toPx(),
                                cap = StrokeCap.Round,
                                pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.1f, 3.dp.toPx()))
                            )
                        }
                    )
                    Text("停留", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                }
            } else {
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (isMoving) {
                OutlinedButton(onClick = onRequestArrival) { Text("已到达") }
            }
        }
    }

    if (showPlacePicker && ongoing != null) {
        NearbyPlacePickerSheet(
            latitude = ongoing.lat,
            longitude = ongoing.lon,
            savedPlaces = places,
            onDismiss = { showPlacePicker = false },
            onSelect = { place ->
                showPlacePicker = false
                LocationTrackingService.setOngoingPlace(context, place.placeID, place.name)
            }
        )
    }
}

/** iOS CurrentTimelineBreathingMarker; pulse is faster while moving. */
@Composable
private fun BreathingMarker(speedMs: Double, modifier: Modifier) {
    val duration = when {
        speedMs > 10.0 -> 800
        speedMs > 0.5 -> 1500
        else -> 3000
    }
    val transition = rememberInfiniteTransition(label = "current_marker")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(duration, easing = LinearEasing), RepeatMode.Restart),
        label = "current_marker_progress"
    )
    Canvas(modifier) {
        val center = Offset(size.width / 2, size.height / 2)
        drawCircle(
            color = DfkAccent.copy(alpha = (1f - progress) * 0.4f),
            radius = 4.dp.toPx() * (1f + progress * 2.5f),
            center = center,
            style = Stroke(width = 3.dp.toPx())
        )
        drawCircle(color = DfkAccent, radius = 5.dp.toPx(), center = center)
    }
}

/** iOS ImportantPlaceGuide (A6). */
@Composable
internal fun ImportantPlaceGuide(onAdd: () -> Unit, onDismiss: () -> Unit) {
    val orange = Color(0xFFFF9500)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp + TimelineLayout.timeColumnWidth, end = 16.dp, bottom = 14.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(orange.copy(alpha = 0.06f))
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(orange.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Default.AddLocationAlt, null, tint = orange, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("添加重要地点", fontSize = 14.sp, fontWeight = FontWeight.Bold)
            Text("更智能地归纳停留轨迹", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
            "立即添加",
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = orange,
            modifier = Modifier.clickable(onClick = onAdd)
        )
        Box(
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.1f))
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Default.Close, contentDescription = "关闭", modifier = Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
