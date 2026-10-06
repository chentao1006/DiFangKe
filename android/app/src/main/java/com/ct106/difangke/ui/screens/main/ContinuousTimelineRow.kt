package com.ct106.difangke.ui.screens.main

import androidx.compose.animation.core.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.ui.components.FootprintPhotoThumbnail
import com.ct106.difangke.ui.components.getIconForName
import com.ct106.difangke.ui.components.timelineTransportIcon
import com.ct106.difangke.ui.theme.DfkAccent
import com.ct106.difangke.viewmodel.MainViewModel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** iOS ContinuousTimelineLayout. */
internal object TimelineLayout {
    val timeColumnWidth = 48.dp
    val dateColumnWidth = 64.dp
    val markerSpacing = 12.dp
    val markerSize = 26.dp
    val markerCenterX = timeColumnWidth + markerSpacing + markerSize / 2
    val minItemSpacing = 12.dp
    val maxItemSpacing = 160.dp
    val photoThumbnailSize = 58.dp
}

@Composable
internal fun timelineLineColor(): Color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)

internal fun parseActivityColor(hex: String?): Color = runCatching {
    if (hex.isNullOrBlank()) Color.Gray else Color(android.graphics.Color.parseColor(hex))
}.getOrDefault(Color.Gray)

internal data class RowActions(
    val onTap: () -> Unit,
    val onMerge: () -> Unit,
    val onSplit: () -> Unit,
    val onToggleFavorite: () -> Unit,
    val onSetImportantPlace: () -> Unit,
    val onIgnore: () -> Unit,
    val onDelete: () -> Unit
)

/**
 * iOS ContinuousTimelineRow: time column, marker with connecting line,
 * title/detail/note and photo thumbnail; long-press menu; tapping the marker
 * opens the activity (footprint) or transport-type picker.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ContinuousTimelineRow(
    item: TimelineItem,
    nextStartTime: Date?,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    usesMinimumBottomSpacing: Boolean,
    canMergeItem: Boolean,
    viewModel: MainViewModel,
    actions: RowActions
) {
    val footprint = (item as? TimelineItem.FootprintItem)?.footprint
    val transport = (item as? TimelineItem.TransportItem)?.transport
    if (footprint == null && transport == null) return
    val isTransport = transport != null
    var showMenu by remember { mutableStateOf(false) }
    val timeFormat = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }

    // A4: retry placeholder addresses once, pulsing the title meanwhile.
    val unresolvedID = footprint?.takeIf {
        (it.address?.trim() ?: "") in MainViewModel.UNRESOLVED_ADDRESSES
    }?.footprintID
    var isResolving by remember(unresolvedID) { mutableStateOf(false) }
    LaunchedEffect(unresolvedID) {
        if (unresolvedID != null && footprint != null) {
            isResolving = true
            try { viewModel.retryUnknownAddress(footprint) } finally { isResolving = false }
        }
    }

    val bottomSpacing = remember(item, nextStartTime, usesMinimumBottomSpacing) {
        if (usesMinimumBottomSpacing) TimelineLayout.minItemSpacing else {
            val reference = nextStartTime ?: item.endTime
            val minutes = maxOf(1.0, (reference.time - item.startTime.time) / 60_000.0)
            val progress = minOf(1.0, minutes / 60.0 / 14.0).toFloat()
            TimelineLayout.minItemSpacing + (TimelineLayout.maxItemSpacing - TimelineLayout.minItemSpacing) * progress
        }
    }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .height(IntrinsicSize.Min)
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = actions.onTap,
                    onLongClick = { showMenu = true }
                )
                .padding(horizontal = 16.dp)
        ) {
            Text(
                timeFormat.format(item.startTime),
                style = MaterialTheme.typography.labelMedium,
                fontFamily = FontFamily.Monospace,
                color = if (isTransport) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                modifier = Modifier.width(TimelineLayout.timeColumnWidth).padding(top = 4.dp)
            )
            Spacer(Modifier.width(TimelineLayout.markerSpacing))
            Box(Modifier.width(TimelineLayout.markerSize).fillMaxHeight()) {
                Column(Modifier.fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                    if (footprint != null) {
                        FootprintMarkerWithPicker(footprint, activityTypes, allPlaces, viewModel)
                    } else if (transport != null) {
                        TransportMarkerWithMenu(transport.recordID, transport.manualTypeRaw ?: transport.typeRaw, viewModel)
                    }
                    Box(
                        Modifier
                            .width(2.dp)
                            .weight(1f)
                            .background(timelineLineColor())
                    )
                }
                if (footprint?.isHighlight == true) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .offset(y = TimelineLayout.markerSize + 2.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(3.dp)
                    ) {
                        Icon(Icons.Default.Star, null, tint = Color(0xFFFFCC00), modifier = Modifier.size(10.dp))
                    }
                }
            }
            Spacer(Modifier.width(TimelineLayout.markerSpacing))
            Row(
                modifier = Modifier.weight(1f).padding(bottom = bottomSpacing),
                verticalAlignment = Alignment.Top
            ) {
                if (transport != null) {
                    val duration = (transport.endTime.time - transport.startTime.time) / 1000
                    Text(
                        "${formattedTimelineDistance(transport.distance)} · ${formattedTimelineDuration(duration)}",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).padding(top = 5.dp)
                    )
                } else if (footprint != null) {
                    FootprintRowText(footprint, activityTypes, isResolving, Modifier.weight(1f))
                    val photos = remember(footprint.photoAssetIDsJson) { footprintPhotos(footprint) }
                    if (photos.isNotEmpty()) {
                        Spacer(Modifier.width(12.dp))
                        Box(
                            Modifier
                                .size(TimelineLayout.photoThumbnailSize)
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .border(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
                        ) {
                            FootprintPhotoThumbnail(photos.first(), Modifier.fillMaxSize(), "足迹照片")
                            if (photos.size > 1) {
                                Text(
                                    "${photos.size}",
                                    color = Color.White,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .padding(4.dp)
                                        .background(Color.Black.copy(alpha = 0.58f), RoundedCornerShape(50))
                                        .padding(horizontal = 5.dp, vertical = 1.dp)
                                )
                            }
                        }
                    }
                }
            }
        }

        RowContextMenu(
            expanded = showMenu,
            onDismiss = { showMenu = false },
            footprint = footprint,
            allPlaces = allPlaces,
            canMerge = canMergeItem,
            actions = actions
        )
    }
}

@Composable
private fun FootprintRowText(
    footprint: FootprintEntity,
    activityTypes: List<ActivityTypeEntity>,
    isResolving: Boolean,
    modifier: Modifier
) {
    val pulse = rememberInfiniteTransition(label = "unresolved_place")
    val alpha by pulse.animateFloat(
        initialValue = 1f,
        targetValue = 0.38f,
        animationSpec = infiniteRepeatable(tween(800, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "unresolved_alpha"
    )
    val title = footprint.address?.trim()?.takeIf { it.isNotEmpty() } ?: "未知地点"
    val duration = formattedTimelineDuration((footprint.endTime.time - footprint.startTime.time) / 1000)
    val activityName = activityTypes.firstOrNull { it.id == footprint.activityTypeValue }?.name
    val detail = activityName?.let { "$it · $duration" } ?: duration
    Column(modifier, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.graphicsLayer { this.alpha = if (isResolving) alpha else 1f }
        )
        Text(detail, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        footprint.reason?.trim()?.takeIf { it.isNotEmpty() }?.let { note ->
            Text(
                note,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 5,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

private fun footprintPhotos(footprint: FootprintEntity): List<String> = runCatching {
    val array = org.json.JSONArray(footprint.photoAssetIDsJson)
    List(array.length()) { array.getString(it) }.filter { it.isNotBlank() }
}.getOrDefault(emptyList())

/** White ring + gradient activity disc + white glyph; tap opens the activity picker (A2). */
@Composable
private fun FootprintMarkerWithPicker(
    footprint: FootprintEntity,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    viewModel: MainViewModel
) {
    val scope = rememberCoroutineScope()
    var showPicker by remember { mutableStateOf(false) }
    var suggested by remember { mutableStateOf<List<ActivityTypeEntity>>(emptyList()) }
    val activity = activityTypes.firstOrNull { it.id == footprint.activityTypeValue }
    val tint = activity?.let { parseActivityColor(it.colorHex) } ?: Color.Gray
    Box {
        Box(
            modifier = Modifier
                .size(TimelineLayout.markerSize)
                .shadow(2.dp, CircleShape)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface)
                .clickable {
                    scope.launch {
                        suggested = viewModel.suggestedActivities(footprint, activityTypes, allPlaces)
                        showPicker = true
                    }
                },
            contentAlignment = Alignment.Center
        ) {
            Box(
                Modifier
                    .size(TimelineLayout.markerSize - 5.dp)
                    .clip(CircleShape)
                    .background(Brush.verticalGradient(listOf(lerp(tint, Color.White, 0.25f), tint))),
                contentAlignment = Alignment.Center
            ) {
                Icon(getIconForName(activity?.icon ?: "place"), null, tint = Color.White, modifier = Modifier.size(12.dp))
            }
        }
        ActivityPickerMenu(
            expanded = showPicker,
            suggested = suggested,
            all = activityTypes,
            onDismiss = { showPicker = false },
            onSelect = { id ->
                showPicker = false
                viewModel.setFootprintActivity(footprint.footprintID, id)
            }
        )
    }
}

/** iOS StableActivityPickerPopover: 无 / 推荐活动 / 所有活动. */
@Composable
private fun ActivityPickerMenu(
    expanded: Boolean,
    suggested: List<ActivityTypeEntity>,
    all: List<ActivityTypeEntity>,
    onDismiss: () -> Unit,
    onSelect: (String?) -> Unit
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, modifier = Modifier.heightIn(max = 480.dp)) {
        DropdownMenuItem(
            text = { Text("无") },
            leadingIcon = { Icon(Icons.Default.Block, null) },
            onClick = { onSelect(null) }
        )
        if (suggested.isNotEmpty()) {
            HorizontalDivider()
            PickerSectionTitle("推荐活动")
            suggested.forEach { activity ->
                DropdownMenuItem(
                    text = { Text(activity.name) },
                    leadingIcon = { Icon(getIconForName(activity.icon), null, tint = parseActivityColor(activity.colorHex)) },
                    onClick = { onSelect(activity.id) }
                )
            }
        }
        HorizontalDivider()
        if (all.isEmpty()) {
            DropdownMenuItem(
                text = { Text("暂无活动类型", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                leadingIcon = { Icon(Icons.Default.ErrorOutline, null) },
                onClick = {},
                enabled = false
            )
        } else {
            PickerSectionTitle("所有活动")
            all.sortedBy { it.sortOrder }.forEach { activity ->
                DropdownMenuItem(
                    text = { Text(activity.name) },
                    leadingIcon = { Icon(getIconForName(activity.icon), null, tint = parseActivityColor(activity.colorHex)) },
                    onClick = { onSelect(activity.id) }
                )
            }
        }
    }
}

@Composable
private fun PickerSectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
    )
}

/** Smaller accent-stroked transport marker; tap lists every TransportType (A2). */
@Composable
private fun TransportMarkerWithMenu(recordID: String, typeRaw: String, viewModel: MainViewModel) {
    var expanded by remember { mutableStateOf(false) }
    Box(Modifier.size(TimelineLayout.markerSize), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(TimelineLayout.markerSize - 4.dp)
                .shadow(2.dp, CircleShape)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface)
                .border(1.2.dp, DfkAccent, CircleShape)
                .clickable { expanded = true },
            contentAlignment = Alignment.Center
        ) {
            Icon(timelineTransportIcon(typeRaw), null, tint = DfkAccent, modifier = Modifier.size(11.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            TransportType.entries.forEach { type ->
                DropdownMenuItem(
                    text = { Text(type.localizedName) },
                    leadingIcon = { Icon(timelineTransportIcon(type.raw), null) },
                    trailingIcon = if (type.raw == typeRaw) {
                        { Icon(Icons.Default.Check, null) }
                    } else null,
                    onClick = {
                        expanded = false
                        viewModel.setTransportType(recordID, type)
                    }
                )
            }
        }
    }
}

/** iOS ContinuousTimelineRow.contextMenu (A1). */
@Composable
private fun RowContextMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    footprint: FootprintEntity?,
    allPlaces: List<PlaceEntity>,
    canMerge: Boolean,
    actions: RowActions
) {
    fun run(action: () -> Unit): () -> Unit = { onDismiss(); action() }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (footprint != null) {
            val isFavorite = footprint.isHighlight == true
            DropdownMenuItem(
                text = { Text(if (isFavorite) "取消收藏" else "收藏") },
                leadingIcon = { Icon(if (isFavorite) Icons.Outlined.StarOutline else Icons.Default.Star, null) },
                onClick = run(actions.onToggleFavorite)
            )
            val address = footprint.address?.trim().orEmpty()
            val isImportant = allPlaces.any { place ->
                place.isUserDefined && (place.placeID == footprint.placeID ||
                    (address.isNotEmpty() && (place.name.trim() == address || place.address?.trim() == address)))
            }
            if (!isImportant) {
                DropdownMenuItem(
                    text = { Text("设为重要地点") },
                    leadingIcon = { Icon(Icons.Default.AddLocationAlt, null) },
                    onClick = run(actions.onSetImportantPlace)
                )
            }
            HorizontalDivider()
            if (canMerge) {
                DropdownMenuItem(
                    text = { Text("合并相邻足迹") },
                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.MergeType, null) },
                    onClick = run(actions.onMerge)
                )
                HorizontalDivider()
            }
            DropdownMenuItem(
                text = { Text("拆分足迹") },
                leadingIcon = { Icon(Icons.Default.CallSplit, null) },
                onClick = run(actions.onSplit)
            )
        } else {
            if (canMerge) {
                DropdownMenuItem(
                    text = { Text("合并相邻交通") },
                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.MergeType, null) },
                    onClick = run(actions.onMerge)
                )
            }
            DropdownMenuItem(
                text = { Text("拆分交通") },
                leadingIcon = { Icon(Icons.Default.CallSplit, null) },
                onClick = run(actions.onSplit)
            )
        }
        DropdownMenuItem(
            text = { Text("编辑") },
            leadingIcon = { Icon(Icons.Default.Edit, null) },
            onClick = run(actions.onTap)
        )
        HorizontalDivider()
        if (footprint != null) {
            DropdownMenuItem(
                text = { Text("忽略地点") },
                leadingIcon = { Icon(Icons.Default.LocationOff, null) },
                onClick = run(actions.onIgnore)
            )
        }
        DropdownMenuItem(
            text = { Text("删除", color = MaterialTheme.colorScheme.error) },
            leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
            onClick = run(actions.onDelete)
        )
    }
}
