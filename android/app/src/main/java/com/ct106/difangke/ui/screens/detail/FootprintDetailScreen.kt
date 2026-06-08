package com.ct106.difangke.ui.screens.detail

import android.os.Bundle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import com.ct106.difangke.ui.components.getIconForName
import java.text.SimpleDateFormat
import java.util.*
import org.json.JSONArray
import com.aptabase.Aptabase

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FootprintDetailScreen(
    footprintId: String,
    onBack: () -> Unit,
    viewModel: FootprintDetailViewModel = viewModel()
) {
    val footprint by viewModel.footprint.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val previousFootprint by viewModel.previousFootprint.collectAsState()
    val nextFootprint by viewModel.nextFootprint.collectAsState()
    
    var title by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var addressText by remember { mutableStateOf("") }
    var selectedPlaceID by remember { mutableStateOf<String?>(null) }
    var selectedLocationIsSaved by remember { mutableStateOf(false) }
    var didEditLocation by remember { mutableStateOf(false) }
    var selectedActivityType by remember { mutableStateOf<String?>(null) }
    var isHighlight by remember { mutableStateOf(false) }
    val nearbyPOIs by viewModel.nearbyPOIs.collectAsState()
    
    var showLocationPicker by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState()
    var showingDeleteAlert by remember { mutableStateOf(false) }
    var showingTimeDialog by remember { mutableStateOf(false) }
    var showingSplitDialog by remember { mutableStateOf(false) }
    var showingMergeDialog by remember { mutableStateOf(false) }
    var mergeUsePrevious by remember { mutableStateOf(true) }
    
    if (showingDeleteAlert) {
        AlertDialog(
            onDismissRequest = { showingDeleteAlert = false },
            title = { Text("删除足迹", fontWeight = FontWeight.Bold) },
            text = { Text("确定要删除这段段时光吗？此操作不可撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteFootprint()
                        onBack()
                        showingDeleteAlert = false
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { showingDeleteAlert = false }) {
                    Text("取消")
                }
            }
        )
    }

    footprint?.let { fp ->
        if (showingTimeDialog) {
            FootprintTimeAdjustDialog(
                footprint = fp,
                previous = previousFootprint,
                next = nextFootprint,
                onDismiss = { showingTimeDialog = false },
                onSave = { start, end ->
                    viewModel.adjustTime(start, end) {
                        showingTimeDialog = false
                    }
                }
            )
        }

        if (showingSplitDialog) {
            FootprintSplitDialog(
                footprint = fp,
                onDismiss = { showingSplitDialog = false },
                onSave = { split ->
                    viewModel.splitFootprint(split) {
                        showingSplitDialog = false
                    }
                }
            )
        }

        if (showingMergeDialog) {
            val target = if (mergeUsePrevious) previousFootprint else nextFootprint
            val mergeTimeFormat = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
            AlertDialog(
                onDismissRequest = { showingMergeDialog = false },
                title = { Text("合并相邻足迹") },
                text = {
                    Text(
                        if (target != null) {
                            "将合并 ${mergeTimeFormat.format(target.startTime)}-${mergeTimeFormat.format(target.endTime)} 和 ${mergeTimeFormat.format(fp.startTime)}-${mergeTimeFormat.format(fp.endTime)} 两条足迹。"
                        } else {
                            "没有可合并的相邻足迹。"
                        }
                    )
                },
                confirmButton = {
                    TextButton(
                        enabled = target != null,
                        onClick = {
                            viewModel.mergeAdjacent(mergeUsePrevious) {
                                showingMergeDialog = false
                            }
                        }
                    ) { Text("合并") }
                },
                dismissButton = {
                    TextButton(onClick = { showingMergeDialog = false }) { Text("取消") }
                }
            )
        }
    }

    LaunchedEffect(footprintId) {
        viewModel.loadFootprint(footprintId)
    }

    val matchedPlace by viewModel.matchedPlace.collectAsState()

    LaunchedEffect(footprint, matchedPlace) {
        footprint?.let {
            title = it.title
            reason = it.reason ?: ""
            selectedPlaceID = it.placeID
            selectedLocationIsSaved = it.placeID != null
            selectedActivityType = it.activityTypeValue
            isHighlight = it.isHighlight == true
            
            if (!didEditLocation) {
                addressText = when {
                    matchedPlace != null -> matchedPlace!!.name
                    !it.address.isNullOrEmpty() && it.address != "null" && it.address != "[]" -> it.address!!
                    else -> ""
                }.ifEmpty { "" }
            }
        }
    }

    val timeFormat = SimpleDateFormat("HH:mm", Locale.CHINA)
    val dateFormat = SimpleDateFormat("yyyy年M月d日 EEEE", Locale.CHINA)

    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)

    Scaffold(
        containerColor = bgColor,
        topBar = {
            TopAppBar(
                title = { Text("足迹详情", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { 
                        isHighlight = !isHighlight 
                        Aptabase.instance.trackEvent("footprint_highlighted")
                    }) {
                        Icon(
                            imageVector = if (isHighlight) Icons.Default.Star else Icons.Default.StarOutline,
                            contentDescription = if (isHighlight) "取消收藏" else "收藏",
                            tint = if (isHighlight) Color(0xFFFFCC00) else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    var showMoreMenu by remember { mutableStateOf(false) }
                    Box {
                        IconButton(onClick = { showMoreMenu = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = "更多")
                        }
                        DropdownMenu(
                            expanded = showMoreMenu,
                            onDismissRequest = { showMoreMenu = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("调整时间") },
                                onClick = {
                                    showMoreMenu = false
                                    showingTimeDialog = true
                                },
                                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) }
                            )
                            DropdownMenuItem(
                                text = { Text("拆分足迹") },
                                onClick = {
                                    showMoreMenu = false
                                    showingSplitDialog = true
                                },
                                leadingIcon = { Icon(Icons.Default.ContentCut, contentDescription = null) }
                            )
                            if (previousFootprint != null) {
                                DropdownMenuItem(
                                    text = { Text("与上一条合并") },
                                    onClick = {
                                        showMoreMenu = false
                                        mergeUsePrevious = true
                                        showingMergeDialog = true
                                    },
                                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.CallMerge, contentDescription = null) }
                                )
                            }
                            if (nextFootprint != null) {
                                DropdownMenuItem(
                                    text = { Text("与下一条合并") },
                                    onClick = {
                                        showMoreMenu = false
                                        mergeUsePrevious = false
                                        showingMergeDialog = true
                                    },
                                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.CallMerge, contentDescription = null) }
                                )
                            }
                        }
                    }
                    TextButton(onClick = {
                        viewModel.updateFootprint(title, reason, addressText, selectedPlaceID, selectedActivityType, isHighlight) {
                            onBack()
                        }
                    }) {
                        Text("保存", fontWeight = FontWeight.Bold)
                    }
                }
            )
        }
    ) { padding ->
        if (footprint == null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 32.dp)
            ) {
                // 1. 标题和活动类型
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .clickable { showLocationPicker = true }
                                .padding(vertical = 8.dp)
                        ) {
                            val mPlace = matchedPlace
                            val locationText = addressText.ifEmpty { mPlace?.name ?: "未知位置" }
                            
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = locationText,
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.Bold,
                                    color = if (selectedLocationIsSaved || mPlace?.isUserDefined == true) Color(0xFFFF9800) else MaterialTheme.colorScheme.onSurface,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Icon(
                                    imageVector = Icons.Default.Edit,
                                    contentDescription = "修改地点",
                                    modifier = Modifier.size(16.dp),
                                    tint = Color.Gray.copy(alpha = 0.5f)
                                )
                            }
                        }
                        
                        Spacer(modifier = Modifier.width(12.dp))
                        
                        ActivityTypeIcon(
                            selectedId = selectedActivityType,
                            allTypes = activityTypes,
                            onTypeSelected = { selectedActivityType = it }
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(12.dp))
                    
                    ActivitySuggestions(
                        allTypes = activityTypes,
                        selectedId = selectedActivityType,
                        onTypeSelected = { selectedActivityType = it }
                    )
                }

                // 2. 时间和地址卡片
                val importantColor = Color(0xFFFF9800) // Orange
                
                ElevatedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.elevatedCardColors(containerColor = if (isDark) Color(0xFF1C1C1E) else Color.White)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        // Time display

                        if (showLocationPicker) {
                            ModalBottomSheet(
                                onDismissRequest = { showLocationPicker = false },
                                sheetState = sheetState,
                                containerColor = if (isDark) Color(0xFF1C1C1E) else Color.White
                            ) {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(bottom = 32.dp)
                                ) {
                                    Text(
                                        "选择正确地点",
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(16.dp)
                                    )
                                    
                                    HorizontalDivider(color = Color.Gray.copy(alpha = 0.1f))
                                    
                                    // 搜索框
                                    var searchQuery by remember { mutableStateOf("") }
                                    OutlinedTextField(
                                        value = searchQuery,
                                        onValueChange = { 
                                            searchQuery = it 
                                            viewModel.searchPOI(it)
                                        },
                                        placeholder = { Text("搜索地点关键词...") },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(horizontal = 16.dp, vertical = 8.dp),
                                        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                                        trailingIcon = {
                                            if (searchQuery.isNotEmpty()) {
                                                IconButton(onClick = { 
                                                    searchQuery = "" 
                                                    viewModel.searchPOI("") // 重置搜索
                                                }) {
                                                    Icon(Icons.Default.Clear, contentDescription = null)
                                                }
                                            }
                                        },
                                        shape = RoundedCornerShape(12.dp),
                                        singleLine = true,
                                        colors = OutlinedTextFieldDefaults.colors(
                                            unfocusedBorderColor = Color.Gray.copy(alpha = 0.2f),
                                            focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)
                                        )
                                    )

                                    if (nearbyPOIs.isEmpty()) {
                                        Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                                            Text("未发现周边显著地点", color = Color.Gray)
                                        }
                                    } else {
                                        androidx.compose.foundation.lazy.LazyColumn(
                                            modifier = Modifier.heightIn(max = 400.dp)
                                        ) {
                                            items(nearbyPOIs.size) { index ->
                                                val poi = nearbyPOIs[index]
                                                ListItem(
                                                    headlineContent = { Text(poi.name, fontWeight = FontWeight.SemiBold) },
                                                    supportingContent = { Text(poi.address, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                                    leadingContent = { Icon(Icons.Default.LocationOn, contentDescription = null, tint = Color.Gray.copy(alpha = 0.5f)) },
                                                    modifier = Modifier.clickable {
                                                        addressText = poi.name
                                                        selectedPlaceID = poi.placeID
                                                        selectedLocationIsSaved = poi.isSavedPlace
                                                        didEditLocation = true
                                                        showLocationPicker = false
                                                    }
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        Spacer(modifier = Modifier.height(12.dp))
                        
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.CalendarToday, contentDescription = null, modifier = Modifier.size(14.dp), tint = Color.Gray)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(dateFormat.format(footprint!!.date), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                        }
                        
                        Spacer(modifier = Modifier.height(4.dp))
                        
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AccessTime, contentDescription = null, modifier = Modifier.size(14.dp), tint = Color.Gray)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                "${timeFormat.format(footprint!!.startTime)} - ${timeFormat.format(footprint!!.endTime)}",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.Gray
                            )
                            Spacer(modifier = Modifier.weight(1f))
                            val durationMins = (footprint!!.endTime.time - footprint!!.startTime.time) / 60000
                            Text("停留 ${if (durationMins >= 60) "${durationMins/60}小时${durationMins%60}分" else "${durationMins}分钟"}", 
                                style = MaterialTheme.typography.bodySmall, 
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.primary.copy(alpha=0.7f)
                            )
                            IconButton(
                                onClick = { showingTimeDialog = true },
                                modifier = Modifier.size(32.dp)
                            ) {
                                Icon(
                                    Icons.Default.Edit,
                                    contentDescription = "调整足迹时间",
                                    modifier = Modifier.size(16.dp),
                                    tint = Color.Gray.copy(alpha = 0.65f)
                                )
                            }
                        }
                    }
                }

                // 3. 地图展示
                Text(
                    "位置轨迹",
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.Gray,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                )
                
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(240.dp)
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    DetailMapView(
                        footprint = footprint!!,
                        allPlaces = allPlaces,
                        activityTypes = activityTypes
                    )
                }

                // 4. 感想备注
                Text(
                    "感想与备注",
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.Gray,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp)
                )
                
                OutlinedTextField(
                    value = reason,
                    onValueChange = { reason = it },
                    placeholder = { Text("记录此刻的心情...") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
                        unfocusedBorderColor = Color.Transparent,
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f),
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)
                    ),
                    minLines = 4
                )
                
                Spacer(modifier = Modifier.height(24.dp))
                
                // 删除按钮
                TextButton(
                    onClick = { showingDeleteAlert = true },
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Icon(Icons.Default.Delete, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("删除此足迹")
                }
            }
        }
    }
}

@Composable
private fun FootprintTimeAdjustDialog(
    footprint: FootprintEntity,
    previous: FootprintEntity?,
    next: FootprintEntity?,
    onDismiss: () -> Unit,
    onSave: (Date, Date) -> Unit
) {
    val formatter = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
    val dayStart = remember(footprint.date) {
        Calendar.getInstance().apply {
            time = footprint.date
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.time
    }
    val dayEnd = remember(dayStart) { Date(dayStart.time + 24 * 60 * 60_000L) }
    val rangeStart = maxOf(previous?.endTime?.time ?: dayStart.time, dayStart.time)
    val rangeEnd = minOf(next?.startTime?.time ?: dayEnd.time, dayEnd.time)
    val totalMinutes = maxOf(1, ((rangeEnd - rangeStart) / 60_000L).toInt())
    var startMinute by remember(footprint.footprintID, rangeStart) {
        mutableFloatStateOf(((footprint.startTime.time - rangeStart) / 60_000L).coerceIn(0L, (totalMinutes - 1).toLong()).toFloat())
    }
    var endMinute by remember(footprint.footprintID, rangeStart) {
        mutableFloatStateOf(((footprint.endTime.time - rangeStart) / 60_000L).coerceIn(1L, totalMinutes.toLong()).toFloat())
    }
    if (endMinute <= startMinute) endMinute = startMinute + 1

    val startDate = Date(rangeStart + startMinute.toLong() * 60_000L)
    val endDate = Date(rangeStart + endMinute.toLong() * 60_000L)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("调整时间") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(
                    "可调整范围 ${formatter.format(Date(rangeStart))}-${formatter.format(Date(rangeEnd))}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    "${formatter.format(startDate)} - ${formatter.format(endDate)}",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Text("开始", style = MaterialTheme.typography.labelMedium)
                Slider(
                    value = startMinute,
                    onValueChange = { value ->
                        startMinute = value.coerceIn(0f, endMinute - 1f)
                    },
                    valueRange = 0f..totalMinutes.toFloat(),
                    steps = maxOf(0, totalMinutes - 1)
                )
                Text("结束", style = MaterialTheme.typography.labelMedium)
                Slider(
                    value = endMinute,
                    onValueChange = { value ->
                        endMinute = value.coerceIn(startMinute + 1f, totalMinutes.toFloat())
                    },
                    valueRange = 0f..totalMinutes.toFloat(),
                    steps = maxOf(0, totalMinutes - 1)
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(startDate, endDate) }) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}

@Composable
private fun FootprintSplitDialog(
    footprint: FootprintEntity,
    onDismiss: () -> Unit,
    onSave: (Date) -> Unit
) {
    val formatter = remember { SimpleDateFormat("HH:mm", Locale.CHINA) }
    val durationMinutes = maxOf(1, ((footprint.endTime.time - footprint.startTime.time) / 60_000L).toInt())
    val canSplit = durationMinutes >= 2
    var splitMinute by remember(footprint.footprintID) {
        mutableFloatStateOf((durationMinutes / 2).coerceIn(1, maxOf(1, durationMinutes - 1)).toFloat())
    }
    val splitDate = Date(footprint.startTime.time + splitMinute.toLong() * 60_000L)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("拆分足迹") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (!canSplit) {
                    Text("这条足迹太短，无法拆分。")
                } else {
                    Text(
                        "拆分点 ${formatter.format(splitDate)}",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Slider(
                        value = splitMinute,
                        onValueChange = { value ->
                            splitMinute = value.coerceIn(1f, (durationMinutes - 1).toFloat())
                        },
                        valueRange = 1f..(durationMinutes - 1).toFloat(),
                        steps = maxOf(0, durationMinutes - 3)
                    )
                    Text(
                        "${formatter.format(footprint.startTime)}-${formatter.format(splitDate)} / ${formatter.format(splitDate)}-${formatter.format(footprint.endTime)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        },
        confirmButton = {
            TextButton(enabled = canSplit, onClick = { onSave(splitDate) }) {
                Text("拆分")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivityTypeIcon(
    selectedId: String?,
    allTypes: List<ActivityTypeEntity>,
    onTypeSelected: (String?) -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }
    val selected = allTypes.find { it.id == selectedId }
    
    Box {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                .clickable { showMenu = true },
            contentAlignment = Alignment.Center
        ) {
            if (selected != null) {
                // 这里可以根据 icon 字符串映射到图标
                Icon(
                    imageVector = com.ct106.difangke.ui.components.getIconForName(selected.icon),
                    contentDescription = selected.name,
                    tint = try { Color(android.graphics.Color.parseColor(selected.colorHex)) } catch (e: Exception) { MaterialTheme.colorScheme.primary },
                    modifier = Modifier.size(28.dp)
                )
            } else {
                Icon(
                    Icons.Default.Category,
                    contentDescription = "选择类型",
                    tint = Color.Gray,
                    modifier = Modifier.size(24.dp)
                )
            }
        }
    if (showMenu) {
        ModalBottomSheet(
            onDismissRequest = { showMenu = false },
            sheetState = rememberModalBottomSheetState(),
            containerColor = MaterialTheme.colorScheme.surface,
            dragHandle = { BottomSheetDefaults.DragHandle() }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 32.dp)
            ) {
                Text(
                    text = "选择活动类型",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(16.dp)
                )
                
                ListItem(
                    headlineContent = { Text("无类型") },
                    leadingContent = { Icon(Icons.Default.Close, contentDescription = null) },
                    modifier = Modifier.clickable { onTypeSelected(null); showMenu = false }
                )
                
                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                
                allTypes.forEach { type ->
                    ListItem(
                        headlineContent = { Text(type.name) },
                        leadingContent = { 
                            Icon(
                                imageVector = com.ct106.difangke.ui.components.getIconForName(type.icon),
                                contentDescription = null,
                                tint = try { Color(android.graphics.Color.parseColor(type.colorHex)) } catch (e: Exception) { Color.Gray },
                                modifier = Modifier.size(24.dp)
                            )
                        },
                        trailingContent = {
                            if (selectedId == type.id) {
                                Icon(Icons.Default.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            }
                        },
                        modifier = Modifier.clickable { onTypeSelected(type.id); showMenu = false }
                    )
                }
            }
        }
    }
}
}

@Composable
fun ActivitySuggestions(
    allTypes: List<ActivityTypeEntity>,
    selectedId: String?,
    onTypeSelected: (String) -> Unit
) {
    if (selectedId != null) return
    
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("建议: ", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        Spacer(modifier = Modifier.width(8.dp))
        allTypes.take(3).forEach { type ->
            SuggestionChip(
                onClick = { onTypeSelected(type.id) },
                label = { Text(type.name, fontSize = 12.sp) },
                modifier = Modifier.padding(end = 8.dp)
            )
        }
    }
}

@Composable
fun DetailMapView(
    footprint: FootprintEntity,
    allPlaces: List<PlaceEntity> = emptyList(),
    activityTypes: List<ActivityTypeEntity> = emptyList()
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val primaryColor = MaterialTheme.colorScheme.primary.toArgb()
    
    AndroidView(
        factory = { ctx ->
            com.amap.api.maps.TextureMapView(ctx).apply {
                onCreate(Bundle())
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
        }
        
        // 解析轨迹点
        val lats = try { JSONArray(footprint.latitudeJson) } catch (e: Exception) { JSONArray() }
        val lons = try { JSONArray(footprint.longitudeJson) } catch (e: Exception) { JSONArray() }
        
        if (lats.length() > 0) {
            val points = mutableListOf<com.amap.api.maps.model.LatLng>()
            val builder = com.amap.api.maps.model.LatLngBounds.Builder()
            
            for (i in 0 until lats.length()) {
                val p = com.amap.api.maps.model.LatLng(lats.getDouble(i), lons.getDouble(i))
                points.add(p)
                builder.include(p)
            }
            
            amap.clear()
            amap.addImportantPlaceCircles(allPlaces)
            amap.addPolyline(
                com.amap.api.maps.model.PolylineOptions()
                    .addAll(points)
                    .width(12f)
                    .color(primaryColor)
                    .useGradient(true)
            )
            amap.addFootprintMarkers(buildFootprintMapMarkers(listOf(footprint), activityTypes))
            
            // 移动相机到轨迹范围 (优化版)
            if (points.size == 1) {
                amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points[0], 17f))
            } else {
                val bounds = builder.build()
                // 使用 post 确保地图布局完成
                view.post {
                    try {
                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngBounds(bounds, 150))
                        // 再次校验缩放，防止单点附近太近导致范围过大
                        if (amap.cameraPosition.zoom > 17f) {
                            amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.zoomTo(17f))
                        }
                    } catch (e: Exception) {
                        amap.moveCamera(com.amap.api.maps.CameraUpdateFactory.newLatLngZoom(points[0], 16f))
                    }
                }
            }
        }
    }
}
