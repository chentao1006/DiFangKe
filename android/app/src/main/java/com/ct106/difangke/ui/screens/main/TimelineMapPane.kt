package com.ct106.difangke.ui.screens.main

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.outlined.MyLocation
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.FootprintCardView
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import com.ct106.difangke.viewmodel.MainViewModel
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Date

/** What the user picked on the timeline or the map (iOS selectedFootprint/selectedTransport). */
sealed class TimelineSelection {
    data class Footprint(val id: String) : TimelineSelection()
    data class Transport(val id: String) : TimelineSelection()
}

/**
 * The full-screen map canvas (iOS ContinuousTimelineView.mapContent).
 * Shows every item on the visible timeline dates, or only the selected item
 * (enlarged marker / its own route) while a detail sheet is open.
 */
@Composable
internal fun TimelineMapPane(
    modifier: Modifier,
    selectedDate: Date,
    visibleDates: Set<Date>,
    selection: TimelineSelection?,
    viewModel: MainViewModel,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    sheetHeight: Dp,
    bottomPaddingPx: Int,
    onUserPan: () -> Unit,
    onSelect: (TimelineSelection) -> Unit
) {
    val context = LocalContext.current
    val mapDates = remember(selectedDate, visibleDates) {
        (visibleDates + selectedDate).map { normalizeTimelineDate(it) }.toSet()
    }
    val items by remember(mapDates) { viewModel.getTimelineItemsForDates(mapDates) }.collectAsState(initial = emptyList())
    val dailyPoints by remember(mapDates) { viewModel.getDailyTrajectoryForDates(mapDates) }.collectAsState(initial = null)
    val trackingState by viewModel.trackingState.collectAsState()
    var followUserRequest by remember { mutableIntStateOf(0) }
    var isFollowingUser by remember { mutableStateOf(false) }
    var groupedMarker by remember { mutableStateOf<FootprintMapMarker?>(null) }
    val isDark = isSystemInDarkTheme()

    val userLocation = when (val state = trackingState) {
        is LocationTrackingService.TrackingState.Tracking ->
            if (state.lat != null && state.lon != null) LatLng(state.lat, state.lon) else null
        is LocationTrackingService.TrackingState.OngoingStay -> LatLng(state.lat, state.lon)
        LocationTrackingService.TrackingState.Idle -> null
    }?.takeIf { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 }

    val footprints = remember(items) { items.filterIsInstance<TimelineItem.FootprintItem>().map { it.footprint } }
    val transports = remember(items) { items.filterIsInstance<TimelineItem.TransportItem>() }

    val overlays = remember(items, dailyPoints, activityTypes, allPlaces, selection) {
        when (selection) {
            is TimelineSelection.Footprint -> {
                val fp = footprints.filter { it.footprintID == selection.id }
                TimelineMapOverlays(
                    markers = buildFootprintMapMarkers(fp, activityTypes).map { it.copy(scale = 1.5f) },
                    routes = emptyList(),
                    places = allPlaces
                )
            }
            is TimelineSelection.Transport -> {
                val tp = transports.filter { it.transport.recordID == selection.id }
                TimelineMapOverlays(
                    markers = buildTransportMapMarkers(tp).map { it.copy(scale = 1.5f) },
                    routes = tp.map { it.transport.pointsJson },
                    places = allPlaces
                )
            }
            null -> TimelineMapOverlays(
                markers = buildFootprintMapMarkers(footprints, activityTypes) + buildTransportMapMarkers(transports),
                routes = listOfNotNull(dailyPoints),
                places = allPlaces
            )
        }
    }

    // B4: load the latest photo of each pin as a small bitmap.
    val photoUris = remember(overlays) { overlays.markers.mapNotNull { it.photoUri }.distinct() }
    var photoBitmaps by remember { mutableStateOf<Map<String, Bitmap>>(emptyMap()) }
    LaunchedEffect(photoUris) {
        val missing = photoUris.filter { it !in photoBitmaps }
        if (missing.isEmpty()) return@LaunchedEffect
        val loaded = withContext(Dispatchers.IO) {
            missing.mapNotNull { uri -> loadPinThumbnail(context, uri)?.let { uri to it } }.toMap()
        }
        if (loaded.isNotEmpty()) photoBitmaps = photoBitmaps + loaded
    }

    // B2: frame all items on the visible dates; when an item is selected,
    // frame only that item. Returning from a selection keeps the camera.
    var previousSelection by remember { mutableStateOf<TimelineSelection?>(null) }
    val baseKey = remember(mapDates, items.size) {
        "dates:" + mapDates.map { it.time }.sorted().joinToString(",") + ":" + items.size
    }
    val cameraFit = remember(baseKey, selection, overlays) {
        val wasSelected = previousSelection != null && selection == null
        val fit = when (selection) {
            null -> TimelineCameraFit(
                key = baseKey,
                points = footprints.mapNotNull { fp ->
                    fp.coordinate()
                } + transports.flatMap { routePoints(it.transport.pointsJson) },
                singlePointZoom = 14f,
                skipMove = wasSelected
            )
            is TimelineSelection.Footprint -> TimelineCameraFit(
                key = "fp:${selection.id}",
                points = footprints.filter { it.footprintID == selection.id }.mapNotNull { it.coordinate() },
                singlePointZoom = 16f
            )
            is TimelineSelection.Transport -> TimelineCameraFit(
                key = "tp:${selection.id}",
                points = transports.filter { it.transport.recordID == selection.id }
                    .flatMap { routePoints(it.transport.pointsJson) }
            )
        }
        fit
    }
    SideEffect { previousSelection = selection }

    Box(modifier = modifier.background(if (isDark) Color.Black else Color(0xFFE7EEF0))) {
        TimelineMapView(
            overlays = overlays,
            cameraFit = cameraFit,
            bottomPaddingPx = bottomPaddingPx,
            userLocation = userLocation,
            isFollowingUser = isFollowingUser,
            followUserRequest = followUserRequest,
            photoBitmaps = photoBitmaps,
            onUserPan = {
                isFollowingUser = false
                onUserPan()
            },
            onMarkerClick = { markerID ->
                when {
                    markerID.startsWith("transport:") ->
                        onSelect(TimelineSelection.Transport(markerID.removePrefix("transport:")))
                    else -> {
                        val marker = overlays.markers.firstOrNull { it.id == markerID }
                        if (marker != null && marker.memberIDs.size > 1 && selection == null) {
                            groupedMarker = marker
                        } else {
                            onSelect(TimelineSelection.Footprint(markerID))
                        }
                    }
                }
            },
            modifier = Modifier.fillMaxSize()
        )

        if (userLocation != null) {
            // Locate-me sits just above the sheet: filled while following,
            // outlined once the user pans away (iOS user-tracking button).
            IconButton(
                onClick = {
                    isFollowingUser = true
                    followUserRequest += 1
                },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = sheetHeight + 12.dp)
                    .size(40.dp)
                    .shadow(4.dp, CircleShape)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface)
            ) {
                Icon(
                    if (isFollowingUser) Icons.Filled.MyLocation else Icons.Outlined.MyLocation,
                    contentDescription = "定位到当前位置",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
            }
        }

        val isToday = normalizeTimelineDate(selectedDate).time == normalizeTimelineDate(Date()).time
        if (!isToday && selection == null && overlays.markers.isEmpty() && dailyPoints.isNullOrBlank()) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(top = 120.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(Icons.Default.Map, null, tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.55f), modifier = Modifier.size(42.dp))
                Spacer(Modifier.height(10.dp))
                Text(
                    "${timelineDateTitle(selectedDate)}暂无地图轨迹",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f)
                )
            }
        }
    }

    groupedMarker?.let { marker ->
        val members = marker.memberIDs.mapNotNull { id -> footprints.firstOrNull { it.footprintID == id } }
        AggregatedFootprintSheet(
            footprints = members,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            onDismiss = { groupedMarker = null },
            onSelect = { fp ->
                groupedMarker = null
                onSelect(TimelineSelection.Footprint(fp.footprintID))
            }
        )
    }
}

/** iOS AggregatedFootprintListView: title + "共 N 条足迹" + footprint cards. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AggregatedFootprintSheet(
    footprints: List<FootprintEntity>,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    onDismiss: () -> Unit,
    onSelect: (FootprintEntity) -> Unit
) {
    val representative = footprints.maxByOrNull { it.duration }
    val title = representative?.let { rep ->
        allPlaces.firstOrNull { it.placeID == rep.placeID && it.isUserDefined }?.name
            ?: rep.address?.takeIf { it.isNotEmpty() }
    } ?: "同地点足迹"
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.Top
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("共 ${footprints.size} 条足迹", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onDismiss, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Default.Close, contentDescription = "关闭", modifier = Modifier.size(14.dp))
            }
        }
        LazyColumn(
            modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp),
            contentPadding = PaddingValues(top = 12.dp, bottom = 20.dp)
        ) {
            items(footprints, key = { it.footprintID }) { fp ->
                FootprintCardView(
                    footprint = fp,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    isFirst = false,
                    isLast = false,
                    showTimeline = false,
                    onClick = { onSelect(fp) }
                )
            }
        }
    }
}

private fun FootprintEntity.coordinate(): LatLng? = runCatching {
    val lats = org.json.JSONArray(latitudeJson)
    val lons = org.json.JSONArray(longitudeJson)
    if (lats.length() == 0 || lons.length() == 0) null
    else LatLng(lats.getDouble(0), lons.getDouble(0))
}.getOrNull()?.takeIf { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 }

private fun routePoints(pointsJson: String): List<LatLng> = parseRouteSegments(pointsJson).flatten()

/** iOS shows a tappable transport icon at the midpoint of every route. */
internal fun buildTransportMapMarkers(items: List<TimelineItem.TransportItem>): List<FootprintMapMarker> =
    items.mapNotNull { item ->
        val points = routePoints(item.transport.pointsJson)
        if (points.size < 2) return@mapNotNull null
        val midpoint = points[points.lastIndex / 2]
        FootprintMapMarker(
            id = "transport:${item.transport.recordID}",
            latitude = midpoint.latitude,
            longitude = midpoint.longitude,
            icon = TransportType.from(item.transport.manualTypeRaw ?: item.transport.typeRaw).icon,
            colorHex = "#00A0AC"
        )
    }

private fun loadPinThumbnail(context: android.content.Context, uriString: String): Bitmap? = runCatching {
    val uri = Uri.parse(uriString)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
        context.contentResolver.loadThumbnail(uri, Size(160, 160), null)
    } else {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 160 && bounds.outHeight / (sample * 2) >= 160) sample *= 2
        context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }
}.getOrNull()
