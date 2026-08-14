package com.ct106.difangke.ui.screens.detail

import android.os.Bundle
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.FootprintTitles
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import com.ct106.difangke.ui.components.buildFootprintMapMarkers
import com.ct106.difangke.ui.components.getIconForName
import com.ct106.difangke.ui.components.FootprintPhotoThumbnail
import com.ct106.difangke.ui.components.NearbyPlacePickerSheet
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
    var showingIgnoreLocationAlert by remember { mutableStateOf(false) }
    var showingTimeDialog by remember { mutableStateOf(false) }
    var showingSplitDialog by remember { mutableStateOf(false) }
    var showingMergeDialog by remember { mutableStateOf(false) }
    var mergeUsePrevious by remember { mutableStateOf(true) }
    var skipDisposeSave by remember { mutableStateOf(false) }
    var selectedPhotoUri by remember { mutableStateOf<String?>(null) }
    var showFullMap by remember { mutableStateOf(false) }
    val context = LocalContext.current
    // Use the exact same picker as the live "正在停留" row: same POI source,
    // search, retry behaviour, and nearby saved-place merge.
    footprint?.let { selectedFootprint ->
        if (showLocationPicker) {
            val coordinate = remember(selectedFootprint.footprintID) {
                runCatching {
                    org.json.JSONArray(selectedFootprint.latitudeJson).getDouble(0) to
                        org.json.JSONArray(selectedFootprint.longitudeJson).getDouble(0)
                }.getOrNull()
            }
            if (coordinate != null) {
                NearbyPlacePickerSheet(
                    latitude = coordinate.first,
                    longitude = coordinate.second,
                    savedPlaces = allPlaces,
                    onDismiss = { showLocationPicker = false },
                    onSelect = { poi ->
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
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            uris.forEach { uri ->
                runCatching {
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
            }
            val existing = footprint?.let(::footprintPhotoUris).orEmpty()
            viewModel.updatePhotos(existing + uris.map { it.toString() })
        }
    }
    
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

        if (showingIgnoreLocationAlert) {
            AlertDialog(
                onDismissRequest = { showingIgnoreLocationAlert = false },
                title = { Text("忽略并删除此地点足迹？") },
                text = { Text("以后将不再自动记录此地点附近的足迹，已有的同地点足迹也会移入回收站。") },
                confirmButton = {
                    TextButton(
                        onClick = {
                            skipDisposeSave = true
                            viewModel.ignoreLocation {
                                showingIgnoreLocationAlert = false
                                onBack()
                            }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    ) { Text("忽略并删除") }
                },
                dismissButton = { TextButton(onClick = { showingIgnoreLocationAlert = false }) { Text("取消") } }
            )
        }
    }

    LaunchedEffect(footprintId) {
        viewModel.loadFootprint(footprintId)
    }

    val matchedPlace by viewModel.matchedPlace.collectAsState()

    fun saveDraftReasonIfNeeded(afterSave: () -> Unit = {}) {
        val fp = footprint ?: return afterSave()
        if (reason != (fp.reason ?: "")) {
            skipDisposeSave = true
            viewModel.updateFootprint(title, reason, addressText, selectedPlaceID, selectedActivityType, isHighlight, afterSave)
        } else {
            afterSave()
        }
    }

    DisposableEffect(footprint?.footprintID) {
        onDispose {
            if (!skipDisposeSave) saveDraftReasonIfNeeded()
        }
    }

    LaunchedEffect(footprint, matchedPlace) {
        footprint?.let {
            title = it.title ?: ""
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
                    IconButton(onClick = { saveDraftReasonIfNeeded { onBack() } }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { 
                        val nextValue = !isHighlight
                        isHighlight = nextValue
                        viewModel.setHighlight(nextValue)
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
                            DropdownMenuItem(
                                text = { Text("忽略此地点") },
                                onClick = {
                                    showMoreMenu = false
                                    showingIgnoreLocationAlert = true
                                },
                                leadingIcon = { Icon(Icons.Default.LocationOff, contentDescription = null) }
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
                        skipDisposeSave = true
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
                            suggestedTypes = activityTypes.take(3),
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

                        if (false && showLocationPicker) {
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

                        val healthSummary = buildList {
                            footprint!!.stepCount?.takeIf { it > 0 }?.let { add("$it 步") }
                            footprint!!.walkingDistance?.takeIf { it > 0 }?.let {
                                add(if (it >= 1000) String.format(Locale.CHINA, "%.1f 公里步行", it / 1000) else "${it.toInt()} 米步行")
                            }
                            footprint!!.floorsAscended?.takeIf { it > 0 }?.let { add("$it 层") }
                        }
                        if (healthSummary.isNotEmpty()) {
                            Spacer(modifier = Modifier.height(6.dp))
                            Text(
                                healthSummary.joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.secondary
                            )
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
                    FilledTonalIconButton(
                        onClick = { showFullMap = true },
                        modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)
                        )
                    ) {
                        Icon(Icons.Default.Fullscreen, contentDescription = "打开完整足迹地图")
                    }
                }

                FootprintPhotosSection(
                    uris = footprintPhotoUris(footprint!!),
                    onAddPhotos = { photoPicker.launch(arrayOf("image/*")) },
                    onOpenPhoto = { selectedPhotoUri = it },
                    onRemovePhoto = { uri ->
                        viewModel.updatePhotos(footprintPhotoUris(footprint!!).filterNot { it == uri })
                    }
                )

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

    selectedPhotoUri?.let { uri ->
        FootprintPhotoViewer(uri = uri, onDismiss = { selectedPhotoUri = null })
    }
    footprint?.let { currentFootprint ->
        if (showFullMap) {
            FootprintFullMapDialog(
                footprint = currentFootprint,
                allPlaces = allPlaces,
                activityTypes = activityTypes,
                onDismiss = { showFullMap = false }
            )
        }
    }
}

private fun footprintPhotoUris(footprint: FootprintEntity): List<String> = runCatching {
    val array = JSONArray(footprint.photoAssetIDsJson)
    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
}.getOrDefault(emptyList())

@Composable
private fun FootprintFullMapDialog(
    footprint: FootprintEntity,
    allPlaces: List<PlaceEntity>,
    activityTypes: List<ActivityTypeEntity>,
    onDismiss: () -> Unit
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box {
                DetailMapView(
                    footprint = footprint,
                    allPlaces = allPlaces,
                    activityTypes = activityTypes
                )
                Surface(
                    modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth(),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Default.Close, contentDescription = "关闭完整足迹地图")
                        }
                        Text("足迹地图", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

@Composable
private fun FootprintPhotosSection(
    uris: List<String>,
    onAddPhotos: () -> Unit,
    onOpenPhoto: (String) -> Unit,
    onRemovePhoto: (String) -> Unit
) {
    Text(
        "照片",
        style = MaterialTheme.typography.labelLarge,
        color = Color.Gray,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp)
    )
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        uris.take(4).forEach { uri ->
            Box(Modifier.size(76.dp).clip(RoundedCornerShape(12.dp)).clickable { onOpenPhoto(uri) }) {
                FootprintPhotoThumbnail(uri, Modifier.fillMaxSize(), "查看足迹照片")
                IconButton(
                    onClick = { onRemovePhoto(uri) },
                    modifier = Modifier.align(Alignment.TopEnd).size(28.dp).padding(2.dp)
                ) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "移除照片",
                        tint = Color.White,
                        modifier = Modifier
                            .size(18.dp)
                            .background(Color.Black.copy(alpha = 0.45f), CircleShape)
                            .padding(2.dp)
                    )
                }
            }
        }
        OutlinedButton(
            onClick = onAddPhotos,
            modifier = Modifier.size(width = 76.dp, height = 76.dp),
            contentPadding = PaddingValues(0.dp)
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.AddPhotoAlternate, contentDescription = null)
                Text("添加", style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
private fun FootprintPhotoViewer(uri: String, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
            AndroidView(
                factory = { context ->
                    android.widget.ImageView(context).apply {
                        scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
                        setImageURI(android.net.Uri.parse(uri))
                    }
                },
                update = { imageView -> imageView.setImageURI(android.net.Uri.parse(uri)) },
                modifier = Modifier.fillMaxSize()
            )
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.align(Alignment.TopEnd).padding(16.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape)
            ) {
                Icon(Icons.Default.Close, contentDescription = "关闭照片", tint = Color.White)
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
    // Footprints represent completed stays, so the editor must not expose a
    // time after the current minute even when there is no following item.
    val latestAllowedEnd = remember(footprint.footprintID) {
        Date((System.currentTimeMillis() / 60_000L) * 60_000L)
    }
    val rangeStart = maxOf(previous?.endTime?.time ?: dayStart.time, dayStart.time)
    val rangeEnd = minOf(next?.startTime?.time ?: dayEnd.time, dayEnd.time, latestAllowedEnd.time)
    val hasAdjustableRange = rangeEnd - rangeStart >= 60_000L
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
                if (!hasAdjustableRange) {
                    Text("这条足迹没有可调整的已发生时间范围。")
                } else {
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
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(startDate, endDate) }, enabled = hasAdjustableRange) {
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
    suggestedTypes: List<ActivityTypeEntity> = emptyList(),
    onTypeSelected: (String?) -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }
    val selected = allTypes.find { it.id == selectedId }
    val genuineSuggestions = suggestedTypes.distinctBy { it.id }
    
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
                
                if (genuineSuggestions.isNotEmpty()) {
                    Text(
                        text = "推荐活动",
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.Gray,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                    genuineSuggestions.forEach { type ->
                        ActivityTypeListItem(
                            type = type,
                            selectedId = selectedId,
                            onClick = { onTypeSelected(type.id); showMenu = false }
                        )
                    }
                    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                }

                Text(
                    text = "所有活动",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.Gray,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                )
                allTypes.forEach { type ->
                    ActivityTypeListItem(
                        type = type,
                        selectedId = selectedId,
                        onClick = { onTypeSelected(type.id); showMenu = false }
                    )
                }
            }
        }
    }
}
}

@Composable
private fun ActivityTypeListItem(
    type: ActivityTypeEntity,
    selectedId: String?,
    onClick: () -> Unit
) {
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
        modifier = Modifier.clickable(onClick = onClick)
    )
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
            com.tencent.tencentmap.mapsdk.maps.TextureMapView(ctx).apply {
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
        amap.mapType = if (isDark) com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_DARK else com.tencent.tencentmap.mapsdk.maps.TencentMap.MAP_TYPE_NORMAL
        
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
            val points = mutableListOf<com.tencent.tencentmap.mapsdk.maps.model.LatLng>()
            val builder = com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds.Builder()
            
            for (i in 0 until lats.length()) {
                val p = com.tencent.tencentmap.mapsdk.maps.model.LatLng(lats.getDouble(i), lons.getDouble(i))
                points.add(p)
                builder.include(p)
            }
            
            amap.clear()
            amap.addImportantPlaceCircles(allPlaces)
            amap.addPolyline(
                com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions()
                    .addAll(points)
                    .width(12f)
                    .color(primaryColor)
                    .gradient(true)
            )
            amap.addFootprintMarkers(buildFootprintMapMarkers(listOf(footprint), activityTypes), isDark = isDark)
            
            // 移动相机到轨迹范围 (优化版)
            if (points.size == 1) {
                amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngZoom(points[0], 17f))
            } else {
                val bounds = builder.build()
                // 使用 post 确保地图布局完成
                view.post {
                    try {
                        amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngBounds(bounds, 150))
                        // 再次校验缩放，防止单点附近太近导致范围过大
                        if (amap.cameraPosition.zoom > 17f) {
                            amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.zoomTo(17f))
                        }
                    } catch (e: Exception) {
                        amap.moveCamera(com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory.newLatLngZoom(points[0], 16f))
                    }
                }
            }
        }
    }
}
