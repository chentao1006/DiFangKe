package com.ct106.difangke.ui.screens.main

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.*
import com.ct106.difangke.viewmodel.MainViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import java.text.SimpleDateFormat
import java.util.*
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.ct106.difangke.data.db.entity.FutureTripEntity
import com.ct106.difangke.data.db.entity.PlaceEntity

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = androidx.lifecycle.viewmodel.compose.viewModel(),
    initialDate: Date? = null,
    onNavigateToHistory: (Date) -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: (Date?) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToRawPoints: (Date) -> Unit
) {
    val context = LocalContext.current
    
    var showCalendar by remember { mutableStateOf(false) }
    val availableDates by viewModel.availableDates.collectAsState()
    val currentDate by viewModel.currentDate.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()
    
    // 初始化到特定日期 (如果是从历史跳转过来的)
    LaunchedEffect(initialDate) {
        if (initialDate != null) {
            viewModel.setDate(initialDate)
        }
    }

    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    
    var showBackgroundRationale by remember { mutableStateOf(false) }
    
    // 权限请求逻辑
    val permissionsToRequest = remember {
        val list = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        list.toTypedArray()
    }

    var hasPermissionState by remember { 
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        )
    }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        val fineGranted = perms[Manifest.permission.ACCESS_FINE_LOCATION] == true
        if (fineGranted) {
            hasPermissionState = true
            if (isTrackingEnabled) {
                LocationTrackingService.start(context) // 授权后立即开启服务
            }
        }
    }
    
    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        // Triggered when user responds to notification permission
    }

    val sharedPreferences = remember { context.getSharedPreferences("dfk_prefs", android.content.Context.MODE_PRIVATE) }
    var isNotificationGuideDismissed by remember { 
        mutableStateOf(sharedPreferences.getBoolean("isNotificationGuideDismissed", false)) 
    }
    val dismissGuide = {
        isNotificationGuideDismissed = true
        sharedPreferences.edit().putBoolean("isNotificationGuideDismissed", true).apply()
    }
    
    val hasNotificationPermission = remember(context) { 
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true
    }

    val backgroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted && isTrackingEnabled) {
            LocationTrackingService.start(context) // 后台授权后也尝试开启/刷新服务
        }
    }

    LaunchedEffect(isTrackingEnabled) {
        if (!isTrackingEnabled) {
            return@LaunchedEffect
        }

        // 1. 检查并申请基础权限
        if (!hasPermissionState) {
            launcher.launch(permissionsToRequest)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 2. 检查后台定位权限
            val hasBackground = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
            if (!hasBackground) {
                showBackgroundRationale = true
            } else {
                // 如果权限都齐了，确保服务启动
                LocationTrackingService.start(context)
            }
        } else {
            // Q 以下版本，只要有基础定位就开启
            LocationTrackingService.start(context)
        }
    }
    
    val isDark = isSystemInDarkTheme()
    val bgColor = if (isDark) Color.Black else Color(0xFFF2F2F7)

    var showRebuildConfirm by remember { mutableStateOf<java.util.Date?>(null) }
    var editingFutureTrip by remember { mutableStateOf<FutureTripEntity?>(null) }
    var showingFutureTripEditor by remember { mutableStateOf(false) }
    
    if (showRebuildConfirm != null) {
        AlertDialog(
            onDismissRequest = { showRebuildConfirm = null },
            title = { Text("重新生成数据") },
            text = { Text("确定要重新生成这一天的足迹和交通吗？这会覆盖已有的候选数据。") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.rebuildTimeline(showRebuildConfirm!!)
                    showRebuildConfirm = null
                }) { Text("确定", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showRebuildConfirm = null }) { Text("取消") }
            }
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgColor)
    ) {
        ContinuousTimelineScaffold(
            selectedDate = currentDate,
            availableDates = availableDates,
            viewModel = viewModel,
            trackingState = trackingState,
            isTrackingEnabled = isTrackingEnabled,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            hasLocationPermission = hasPermissionState,
            hasNotificationPermission = hasNotificationPermission,
            isNotificationGuideDismissed = isNotificationGuideDismissed,
            onSelectDate = { viewModel.setDate(it) },
            onShowCalendar = { showCalendar = true },
            onRebuildDate = { showRebuildConfirm = it },
            onViewRawPoints = onNavigateToRawPoints,
            onNavigateToMap = onNavigateToMap,
            onNavigateToDetail = onNavigateToDetail,
            onNavigateToHistory = onNavigateToHistory,
            onNavigateToStatistics = onNavigateToStatistics,
            onNavigateToSettings = onNavigateToSettings,
            onAddFutureTrip = {
                editingFutureTrip = null
                showingFutureTripEditor = true
            },
            onEditFutureTrip = {
                editingFutureTrip = it
                showingFutureTripEditor = true
            },
            onRequestPermission = { launcher.launch(permissionsToRequest) },
            onRequestNotification = {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                dismissGuide()
            },
            onDismissNotificationGuide = { dismissGuide() },
            onEnableTracking = { viewModel.setTrackingEnabled(true) }
        )

        TodayFloatingButton(
            isVisible = currentDate.time != today.time,
            onClick = { viewModel.setDate(today) }
        )

        if (showCalendar) {
            CalendarSelectionDialog(
                selectedDate = currentDate,
                availableDates = availableDates,
                onDateSelected = { date ->
                    viewModel.setDate(date)
                    showCalendar = false
                },
                onDismiss = { showCalendar = false }
            )
        }

        // TODO: FutureTripEditorDialog was unresolved, commented out to fix build.
        // if (showingFutureTripEditor) { ... }

        if (showBackgroundRationale) {
            AlertDialog(
                onDismissRequest = { showBackgroundRationale = false },
                title = { Text("需要后台定位权限") },
                text = { Text("为了在您关闭屏幕或使用其他应用时持续记录足迹，请在随后的系统中选择“始终允许”定位权限。") },
                confirmButton = {
                    Button(onClick = {
                        showBackgroundRationale = false
                        backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    }) {
                        Text("去设置")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showBackgroundRationale = false }) {
                        Text("取消")
                    }
                }
            )
        }

    }
}

@Composable
private fun ContinuousTimelineScaffold(
    selectedDate: Date,
    availableDates: List<Date>,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    hasLocationPermission: Boolean,
    hasNotificationPermission: Boolean,
    isNotificationGuideDismissed: Boolean,
    onSelectDate: (Date) -> Unit,
    onShowCalendar: () -> Unit,
    onRebuildDate: (Date) -> Unit,
    onViewRawPoints: (Date) -> Unit,
    onNavigateToMap: (Date?) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToHistory: (Date) -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onAddFutureTrip: () -> Unit,
    onEditFutureTrip: (FutureTripEntity) -> Unit,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onEnableTracking: () -> Unit
) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val isLandscape = maxWidth > maxHeight
        if (isLandscape) {
            Row(modifier = Modifier.fillMaxSize()) {
                ContinuousTimelineList(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    selectedDate = selectedDate,
                    availableDates = availableDates,
                    viewModel = viewModel,
                    trackingState = trackingState,
                    isTrackingEnabled = isTrackingEnabled,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    hasLocationPermission = hasLocationPermission,
                    hasNotificationPermission = hasNotificationPermission,
                    isNotificationGuideDismissed = isNotificationGuideDismissed,
                    onSelectDate = onSelectDate,
                    onShowCalendar = onShowCalendar,
                    onRebuildDate = onRebuildDate,
                    onViewRawPoints = onViewRawPoints,
                    onNavigateToDetail = onNavigateToDetail,
                    onAddFutureTrip = onAddFutureTrip,
                    onEditFutureTrip = onEditFutureTrip,
                    onRequestPermission = onRequestPermission,
                    onRequestNotification = onRequestNotification,
                    onDismissNotificationGuide = onDismissNotificationGuide,
                    onEnableTracking = onEnableTracking
                )
                TimelineMapPane(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    selectedDate = selectedDate,
                    viewModel = viewModel,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    onNavigateToMap = { onNavigateToMap(selectedDate) },
                    onNavigateToHistory = { onNavigateToHistory(selectedDate) },
                    onNavigateToStatistics = onNavigateToStatistics,
                    onNavigateToSettings = onNavigateToSettings,
                    onShowCalendar = onShowCalendar
                )
            }
        } else {
            Column(modifier = Modifier.fillMaxSize()) {
                TimelineMapPane(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    selectedDate = selectedDate,
                    viewModel = viewModel,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    onNavigateToMap = { onNavigateToMap(selectedDate) },
                    onNavigateToHistory = { onNavigateToHistory(selectedDate) },
                    onNavigateToStatistics = onNavigateToStatistics,
                    onNavigateToSettings = onNavigateToSettings,
                    onShowCalendar = onShowCalendar
                )
                ContinuousTimelineList(
                    modifier = Modifier
                        .weight(2f)
                        .fillMaxWidth(),
                    selectedDate = selectedDate,
                    availableDates = availableDates,
                    viewModel = viewModel,
                    trackingState = trackingState,
                    isTrackingEnabled = isTrackingEnabled,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    hasLocationPermission = hasLocationPermission,
                    hasNotificationPermission = hasNotificationPermission,
                    isNotificationGuideDismissed = isNotificationGuideDismissed,
                    onSelectDate = onSelectDate,
                    onShowCalendar = onShowCalendar,
                    onRebuildDate = onRebuildDate,
                    onViewRawPoints = onViewRawPoints,
                    onNavigateToDetail = onNavigateToDetail,
                    onAddFutureTrip = onAddFutureTrip,
                    onEditFutureTrip = onEditFutureTrip,
                    onRequestPermission = onRequestPermission,
                    onRequestNotification = onRequestNotification,
                    onDismissNotificationGuide = onDismissNotificationGuide,
                    onEnableTracking = onEnableTracking
                )
            }
        }
    }
}

@Composable
private fun TimelineMapPane(
    modifier: Modifier,
    selectedDate: Date,
    viewModel: MainViewModel,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    onNavigateToMap: () -> Unit,
    onNavigateToHistory: () -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onShowCalendar: () -> Unit
) {
    val items by viewModel.getTimelineItems(selectedDate).collectAsState(initial = emptyList())
    val dailyInsight by viewModel.getDailyInsight(selectedDate).collectAsState(initial = null)
    val dailyPoints by viewModel.getDailyTrajectory(selectedDate).collectAsState(initial = null)
    val dailyMarkers by viewModel.getDailyMarkers(selectedDate).collectAsState(initial = null)
    val footprintMarkers = remember(items, activityTypes) {
        val markers = buildFootprintMapMarkers(
            items.filterIsInstance<TimelineItem.FootprintItem>().map { it.footprint },
            activityTypes
        )
        markers
    }
    val centerPoint = remember(items) {
        items.filterIsInstance<TimelineItem.FootprintItem>()
            .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
            ?.let { it.latitude to it.longitude }
            ?: items.filterIsInstance<TimelineItem.FutureTripItem>()
                .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
                ?.let { it.latitude to it.longitude }
    }
    val isDark = isSystemInDarkTheme()

    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    val isToday = selectedDate.time == today.time

    Box(
        modifier = modifier
            .background(if (isDark) Color.Black else Color(0xFFE7EEF0))
    ) {
        MiniMapView(
            lat = centerPoint?.first,
            lon = centerPoint?.second,
            pointsJson = dailyPoints ?: dailyInsight?.rawPointsJson,
            markersJson = dailyMarkers ?: dailyInsight?.markersJson,
            footprintMarkers = footprintMarkers,
            allPlaces = allPlaces,
            modifier = Modifier.fillMaxSize(),
            cornerRadius = 0.dp,
            gesturesEnabled = true,
            showClickOverlay = false,
            onClick = onNavigateToMap
        )

        MapEmptyHint(
            isVisible = !isToday && footprintMarkers.isEmpty() && (dailyPoints ?: dailyInsight?.rawPointsJson).isNullOrBlank(),
            date = selectedDate
        )

        Row(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            MapIconButton(icon = Icons.Default.CalendarMonth, label = "日历", onClick = onShowCalendar)
            MapIconButton(icon = Icons.Default.History, label = "历史", onClick = onNavigateToHistory)
            MapIconButton(icon = Icons.Default.BarChart, label = "统计", onClick = onNavigateToStatistics)
            MapIconButton(icon = Icons.Default.Settings, label = "设置", onClick = onNavigateToSettings)
        }
        
        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            MapIconButton(icon = Icons.Default.MyLocation, label = "定位", onClick = { })
            MapIconButton(icon = Icons.Default.OpenInFull, label = "全屏地图", onClick = onNavigateToMap)
        }
    }
}

@Composable
private fun MapEmptyHint(isVisible: Boolean, date: Date) {
    if (!isVisible) return
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.Map, contentDescription = null, tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.55f), modifier = Modifier.size(42.dp))
        Spacer(Modifier.height(10.dp))
        Text(
            text = "${timelineDateTitle(date)}暂无地图轨迹",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f)
        )
    }
}

@Composable
private fun MapIconButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.82f))
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(19.dp), tint = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun ContinuousTimelineList(
    modifier: Modifier,
    selectedDate: Date,
    availableDates: List<Date>,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    hasLocationPermission: Boolean,
    hasNotificationPermission: Boolean,
    isNotificationGuideDismissed: Boolean,
    onSelectDate: (Date) -> Unit,
    onShowCalendar: () -> Unit,
    onRebuildDate: (Date) -> Unit,
    onViewRawPoints: (Date) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onAddFutureTrip: () -> Unit,
    onEditFutureTrip: (FutureTripEntity) -> Unit,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onEnableTracking: () -> Unit
) {
    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    val timelineDates = remember(availableDates, selectedDate, today) {
        (availableDates + selectedDate + today)
            .distinctBy { it.time }
            .sortedByDescending { it.time }
    }
    val isDark = isSystemInDarkTheme()
    val listBackground = if (isDark) Color.Black else Color(0xFFF2F2F7)
    val listState = rememberLazyListState()

    LaunchedEffect(selectedDate.time, timelineDates) {
        val index = timelineDates.indexOfFirst { isSameDay(it, selectedDate) }
        if (index != -1) {
            val visibleDate = visibleTimelineDate(listState)
            if (visibleDate == null) {
                listState.scrollToItem(index)
            } else if (!isSameDay(visibleDate, selectedDate)) {
                listState.animateScrollToItem(index)
            }
        }
    }

    LaunchedEffect(listState, selectedDate.time, timelineDates) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collectLatest { isScrolling ->
                if (!isScrolling) {
                    delay(160)
                    val visibleDate = visibleTimelineDate(listState) ?: return@collectLatest
                    if (!isSameDay(visibleDate, selectedDate)) {
                        onSelectDate(visibleDate)
                    }
                }
            }
    }

    LazyColumn(
        state = listState,
        modifier = modifier.background(listBackground),
        contentPadding = PaddingValues(top = 16.dp, bottom = 88.dp),
        reverseLayout = true
    ) {
        itemsIndexed(
            items = timelineDates,
            key = { _, date -> timelineDateItemKey(date) }
        ) { index, date ->
            DateTimelineSection(
                date = date,
                isSelected = isSameDay(date, selectedDate),
                isFirstAvailableDate = index == timelineDates.lastIndex,
                viewModel = viewModel,
                trackingState = trackingState,
                isTrackingEnabled = isTrackingEnabled,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                hasLocationPermission = hasLocationPermission,
                hasNotificationPermission = hasNotificationPermission,
                isNotificationGuideDismissed = isNotificationGuideDismissed,
                onSelectDate = onSelectDate,
                onNavigateToDetail = onNavigateToDetail,
                onEditFutureTrip = onEditFutureTrip,
                onRequestPermission = onRequestPermission,
                onRequestNotification = onRequestNotification,
                onDismissNotificationGuide = onDismissNotificationGuide,
                onEnableTracking = onEnableTracking
            )
        }


    }
}

private fun timelineDateItemKey(date: Date): String = "day_${date.time}"

private fun visibleTimelineDate(listState: LazyListState): Date? {
    val layoutInfo = listState.layoutInfo
    val visibleItems = layoutInfo.visibleItemsInfo
    if (visibleItems.isEmpty()) return null

    if (!listState.canScrollBackward) {
        val firstItem = visibleItems.first()
        val key = firstItem.key as? String
        if (key != null) {
            val timestamp = key.removePrefix("day_").takeIf { it != key }?.toLongOrNull()
            if (timestamp != null) {
                return Date(timestamp)
            }
        }
    }

    val targetY = layoutInfo.viewportStartOffset +
        ((layoutInfo.viewportEndOffset - layoutInfo.viewportStartOffset) * 0.62f)

    return visibleItems
        .asSequence()
        .mapNotNull { item ->
            val key = item.key as? String ?: return@mapNotNull null
            val timestamp = key.removePrefix("day_").takeIf { it != key }?.toLongOrNull()
                ?: return@mapNotNull null
            val itemCenter = item.offset + item.size / 2f
            Date(timestamp) to kotlin.math.abs(itemCenter - targetY)
        }
        .minByOrNull { it.second }
        ?.first
}



@Composable
private fun DateTimelineSection(
    date: Date,
    isSelected: Boolean,
    isFirstAvailableDate: Boolean,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    hasLocationPermission: Boolean,
    hasNotificationPermission: Boolean,
    isNotificationGuideDismissed: Boolean,
    onSelectDate: (Date) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onEditFutureTrip: (FutureTripEntity) -> Unit,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onEnableTracking: () -> Unit
) {
    val items by viewModel.getTimelineItems(date).collectAsState(initial = emptyList())
    val points by viewModel.getPointsCount(date).collectAsState(initial = 0)
    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    val isToday = date.time == today.time

    LaunchedEffect(date.time, items.isEmpty(), points) {
        if (!isToday && items.isEmpty() && points > 0) {
            delay(1000)
            viewModel.ensureTimelineForDate(date)
        }
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        DateSectionHeader(
            date = date,
            isSelected = isSelected,
            onClick = { onSelectDate(date) }
        )

        if (isToday && !isTrackingEnabled) {
            TrackingInlinePrompt(
                hasLocationPermission = hasLocationPermission,
                onEnableTracking = onEnableTracking,
                onRequestPermission = onRequestPermission
            )
        }

        if (isToday && !hasNotificationPermission && !isNotificationGuideDismissed) {
            NotificationGuideCard(
                onDismiss = onDismissNotificationGuide,
                onRequest = onRequestNotification
            )
        }

        if (items.isEmpty()) {
            if (isFirstAvailableDate) {
                PastPlaceholderView()
            } else if (isToday) {
                PlaceholderFootprintCard(trackingState = trackingState)
            }
        } else {
            items.forEachIndexed { index, item ->
                TimelineRow(
                    item = item,
                    isFirst = index == 0,
                    isLast = index == items.lastIndex,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    onClick = {
                        onSelectDate(date)
                        if (item is TimelineItem.FutureTripItem) {
                            onEditFutureTrip(item.trip)
                        } else {
                            onNavigateToDetail(item.id)
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun DateSectionHeader(date: Date, isSelected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = timelineDateTitle(date),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = timelineDateSubtitle(date),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        if (isSelected) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(MaterialTheme.colorScheme.primary, CircleShape)
            )
        }
    }
}

@Composable
private fun TrackingInlinePrompt(
    hasLocationPermission: Boolean,
    onEnableTracking: () -> Unit,
    onRequestPermission: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.28f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Default.MyLocation, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                text = "开启记录后会自动生成今天的足迹",
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            TextButton(onClick = if (hasLocationPermission) onEnableTracking else onRequestPermission) {
                Text("开启")
            }
        }
    }
}

private fun timelineDateTitle(date: Date): String {
    return when {
        isToday(date) -> "今天"
        isYesterday(date) -> "昨天"
        isDayBeforeYesterday(date) -> "前天"
        else -> {
            val currentYear = Calendar.getInstance().get(Calendar.YEAR)
            val displayYear = Calendar.getInstance().apply { time = date }.get(Calendar.YEAR)
            if (currentYear == displayYear) SimpleDateFormat("M月d日", Locale.CHINA).format(date)
            else SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date)
        }
    }
}

private fun timelineDateSubtitle(date: Date): String {
    return SimpleDateFormat("M月d日 EEEE", Locale.CHINA).format(date)
}

@Composable
fun NotificationGuideCard(
    onDismiss: () -> Unit,
    onRequest: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha=0.3f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier.size(36.dp).background(MaterialTheme.colorScheme.primary.copy(alpha=0.2f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.NotificationsActive, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text("开启每日足迹汇总", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleSmall)
                Text("每日为您汇总今日精彩足迹与回忆", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onRequest) {
                Text("立即开启", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
            }
            IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                Icon(Icons.Default.Close, null, modifier = Modifier.size(16.dp), tint = Color.Gray)
            }
        }
    }
}

@Composable
fun TimelinePage(
    date: Date,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    isFirstPage: Boolean,
    isLastPage: Boolean,
    hasLocationPermission: Boolean,
    hasNotificationPermission: Boolean,
    isNotificationGuideDismissed: Boolean,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onItemClick: (String) -> Unit,
    onMapClick: () -> Unit,
    allowAutoRebuild: Boolean = true
) {
    val items by viewModel.getTimelineItems(date).collectAsState(initial = emptyList())
    val dailyInsight by viewModel.getDailyInsight(date).collectAsState(initial = null)
    val mileage by viewModel.getMileage(date).collectAsState(initial = 0.0)
    val points by viewModel.getPointsCount(date).collectAsState(initial = 0)
    
    val today = remember {
        Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.time
    }
    val isToday = date.time == today.time
    val isFuture = date.time > today.time

    LaunchedEffect(allowAutoRebuild, date.time, isFuture, items.isEmpty(), points) {
        if (allowAutoRebuild && !isFuture && items.isEmpty() && points > 0) {
            delay(1000) // 延迟一小会，避免刚切过去就闪烁，并且符合“过一会”的需求
            viewModel.ensureTimelineForDate(date)
        }
    }

    if (isFuture) {
        FuturePlaceholderView()
    } else if (isFirstPage && items.isEmpty()) {
        PastPlaceholderView()
    } else {
        // 使用针对特定日期的 Flow，避免 Pager 中不同页面的数据冲突
        val dailyPoints by viewModel.getDailyTrajectory(date).collectAsState(initial = null)
        val dailyMarkers by viewModel.getDailyMarkers(date).collectAsState(initial = null)
        
        // 计算中心点作为兜底（如果 pointsJson 为空，地图至少能定位到当天的某个足迹）
        val centerPoint = items.filterIsInstance<TimelineItem.FootprintItem>()
            .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
            ?.let { it.latitude to it.longitude }

        TimelineContent(
            items = items,
            dailyInsight = dailyInsight?.content,
            totalMileage = mileage,
            totalPoints = points,
            dailyPoints = dailyPoints ?: dailyInsight?.rawPointsJson,
            dailyMarkers = dailyMarkers ?: dailyInsight?.markersJson,
            centerLat = centerPoint?.first,
            centerLon = centerPoint?.second,
            isToday = isToday,
            trackingState = trackingState,
            isTrackingEnabled = isTrackingEnabled,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            hasLocationPermission = hasLocationPermission,
            hasNotificationPermission = hasNotificationPermission,
            isNotificationGuideDismissed = isNotificationGuideDismissed,
            onRequestPermission = onRequestPermission,
            onRequestNotification = onRequestNotification,
            onDismissNotificationGuide = onDismissNotificationGuide,
            onEnableTracking = { viewModel.setTrackingEnabled(true) },
            onItemClick = onItemClick,
            onMapClick = onMapClick
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimelineContent(
    items: List<TimelineItem>,
    dailyInsight: String?,
    totalMileage: Double,
    totalPoints: Int,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    isToday: Boolean,
    hasLocationPermission: Boolean,
    hasNotificationPermission: Boolean,
    isNotificationGuideDismissed: Boolean,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onEnableTracking: () -> Unit,
    onItemClick: (String) -> Unit,
    onMapClick: () -> Unit,
    dailyPoints: String? = null,
    dailyMarkers: String? = null,
    centerLat: Double? = null,
    centerLon: Double? = null
) {
    // 不再过滤重合项，保持与 iOS 同步 (iOS 已取消此过滤以简化逻辑)
    val filteredItems = items

    Box(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 120.dp)
        ) {
            // 统计概览 / 记录状态 (iOS 风格：今日合并，历史显示快照)
            item {
                if (isToday) {
                    RecordingStatusCard(
                        trackingState = trackingState,
                        isTracking = isTrackingEnabled && trackingState !is LocationTrackingService.TrackingState.Idle,
                        isTrackingEnabled = isTrackingEnabled,
                        footprintCount = items.filterIsInstance<TimelineItem.FootprintItem>().map { (it.footprint.title ?: "").ifEmpty { it.footprint.locationHash } }.distinct().size,
                        mileage = totalMileage,
                        pointCount = totalPoints,
                        pointsJson = dailyPoints,
                        markersJson = dailyMarkers,
                        footprintMarkers = buildFootprintMapMarkers(
                            items.filterIsInstance<TimelineItem.FootprintItem>().map { it.footprint },
                            activityTypes
                        ),
                        allPlaces = allPlaces,
                        onNavigateToMap = onMapClick,
                        onEnableTracking = onEnableTracking,
                        onRequestPermission = onRequestPermission,
                        hasLocationPermission = hasLocationPermission
                    )
                } else {
                    DaySummaryCard(
                        footprintCount = filteredItems.filterIsInstance<TimelineItem.FootprintItem>().map { (it.footprint.title ?: "").ifEmpty { it.footprint.locationHash } }.distinct().size,
                        mileage = totalMileage,
                        pointCount = totalPoints,
                        summary = dailyInsight,
                        pointsJson = dailyPoints,
                        markersJson = dailyMarkers,
                        centerLat = centerLat,
                        centerLon = centerLon,
                        allPlaces = allPlaces,
                        onNavigateToMap = onMapClick
                    )
                }
                
                if (isToday && !hasNotificationPermission && !isNotificationGuideDismissed) {
                    NotificationGuideCard(
                        onDismiss = onDismissNotificationGuide,
                        onRequest = onRequestNotification
                    )
                }
            }

            // 时间轴列表
            if (filteredItems.isEmpty()) {
                item {
                    PlaceholderFootprintCard(trackingState = trackingState)
                }
            } else {
                itemsIndexed(filteredItems) { index, item ->
                    TimelineRow(
                        item = item,
                        isFirst = index == 0,
                        isLast = index == filteredItems.size - 1,
                        activityTypes = activityTypes,
                        allPlaces = allPlaces,
                        onClick = { onItemClick(item.id) }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DateNavigator(
    currentDate: Date,
    canGoBack: Boolean,
    canGoForward: Boolean,
    onPrevClick: () -> Unit,
    onNextClick: () -> Unit,
    onCalendarClick: () -> Unit,
    onRebuildClick: () -> Unit,
    onViewRawPointsClick: () -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }
    val primaryColor = Color(0xFF00A0AC)
    
    val calendar = Calendar.getInstance().apply { time = currentDate }
    val isToday = isToday(currentDate)
    val isYesterday = isYesterday(currentDate)
    val isDby = isDayBeforeYesterday(currentDate)

    val dateHeader = when {
        isToday -> "今天"
        isYesterday -> "昨天"
        isDby -> "前天"
        else -> {
            val currentYear = Calendar.getInstance().get(Calendar.YEAR)
            val displayYear = calendar.get(Calendar.YEAR)
            if (currentYear == displayYear) SimpleDateFormat("M月d日", Locale.CHINA).format(currentDate)
            else SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(currentDate)
        }
    }
    
    val secondaryHeader = if (isToday || isYesterday || isDby) {
        val sdf = SimpleDateFormat("M月d日 EEEE", Locale.CHINA)
        sdf.format(currentDate)
    } else {
        SimpleDateFormat("EEEE", Locale.CHINA).format(currentDate)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .background(
                if (androidx.compose.foundation.isSystemInDarkTheme()) Color.White.copy(alpha = 0.05f)
                else MaterialTheme.colorScheme.primary.copy(alpha = 0.05f), 
                RoundedCornerShape(16.dp)
            )
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(
            onClick = onPrevClick,
            enabled = canGoBack
        ) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft, 
                contentDescription = "Previous", 
                tint = if (canGoBack) primaryColor else Color.Gray.copy(alpha = 0.3f)
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.combinedClickable(
                onClick = { onCalendarClick() },
                onLongClick = { showMenu = true }
            )
        ) {
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false }
            ) {
                DropdownMenuItem(
                    text = { Text("查看所有轨迹点") },
                    onClick = {
                        showMenu = false
                        onViewRawPointsClick()
                    },
                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.List, null) }
                )
                DropdownMenuItem(
                    text = { Text("重新生成本日数据") },
                    onClick = {
                        showMenu = false
                        onRebuildClick()
                    },
                    leadingIcon = { Icon(Icons.Default.Refresh, null) }
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = dateHeader,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.width(4.dp))
                Icon(
                    imageVector = Icons.Default.KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier.size(10.dp),
                    tint = Color.Gray.copy(alpha = 0.5f)
                )
            }
            Text(
                text = secondaryHeader,
                style = MaterialTheme.typography.labelSmall,
                color = Color.Gray
            )
        }

        IconButton(
            onClick = onNextClick,
            enabled = canGoForward
        ) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight, 
                contentDescription = "Next", 
                tint = if (canGoForward) primaryColor else Color.Gray.copy(alpha = 0.3f)
            )
        }
    }
}

private fun isToday(date: Date): Boolean {
    return isSameDay(date, Date())
}

private fun isYesterday(date: Date): Boolean {
    val cal = Calendar.getInstance()
    cal.add(Calendar.DAY_OF_YEAR, -1)
    return isSameDay(date, cal.time)
}

private fun isDayBeforeYesterday(date: Date): Boolean {
    val cal = Calendar.getInstance()
    cal.add(Calendar.DAY_OF_YEAR, -2)
    return isSameDay(date, cal.time)
}

private fun isSameDay(d1: Date, d2: Date): Boolean {
    val c1 = Calendar.getInstance().apply { time = d1 }
    val c2 = Calendar.getInstance().apply { time = d2 }
    return c1.get(Calendar.YEAR) == c2.get(Calendar.YEAR) && c1.get(Calendar.DAY_OF_YEAR) == c2.get(Calendar.DAY_OF_YEAR)
}

@Composable
fun CalendarSelectionDialog(
    selectedDate: Date,
    availableDates: List<Date>,
    onDateSelected: (Date) -> Unit,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(),
            contentAlignment = Alignment.Center
        ) {
            MiniCalendarView(
                selectedDate = selectedDate,
                availableDates = availableDates.toSet(),
                onDateSelected = onDateSelected
            )
        }
    }
}

@Composable
fun MiniCalendarView(
    selectedDate: Date,
    availableDates: Set<Date>,
    onDateSelected: (Date) -> Unit
) {
    val calendar = remember { Calendar.getInstance() }
    var currentMonth by remember { 
        mutableStateOf(Calendar.getInstance().apply { 
            time = selectedDate
            set(Calendar.DAY_OF_MONTH, 1)
        }.time) 
    }
    
    val weekDays = listOf("日", "一", "二", "三", "四", "五", "六")
    val isDark = isSystemInDarkTheme()
    val primaryColor = Color(0xFF00A0AC)
    val surfaceColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = MaterialTheme.colorScheme.onSurface
    val secondaryTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
    val disabledTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f)
    val subtleTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.48f)
    val dataTextColor = MaterialTheme.colorScheme.onSurface
    fun changeMonth(delta: Int) {
        val cal = Calendar.getInstance().apply { time = currentMonth; add(Calendar.MONTH, delta) }
        currentMonth = cal.time
    }
    var dragOffset by remember { mutableFloatStateOf(0f) }

    Column(
        modifier = Modifier
            .width(320.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(surfaceColor)
            .pointerInput(currentMonth) {
                detectHorizontalDragGestures(
                    onDragStart = { dragOffset = 0f },
                    onHorizontalDrag = { _, dragAmount -> dragOffset += dragAmount },
                    onDragEnd = {
                        when {
                            dragOffset > 56f -> changeMonth(-1)
                            dragOffset < -56f -> changeMonth(1)
                        }
                        dragOffset = 0f
                    },
                    onDragCancel = { dragOffset = 0f }
                )
            }
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(
                onClick = { changeMonth(-1) },
                modifier = Modifier.size(32.dp).background(Color.Gray.copy(alpha = 0.1f), CircleShape)
            ) {
                Icon(Icons.Default.ChevronLeft, null, modifier = Modifier.size(16.dp), tint = secondaryTextColor)
            }

            Text(
                text = SimpleDateFormat("yyyy年M月", Locale.CHINA).format(currentMonth),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = titleColor
            )

            IconButton(
                onClick = { changeMonth(1) },
                modifier = Modifier.size(32.dp).background(Color.Gray.copy(alpha = 0.1f), CircleShape)
            ) {
                Icon(Icons.Default.ChevronRight, null, modifier = Modifier.size(16.dp), tint = secondaryTextColor)
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Weekdays
        Row(modifier = Modifier.fillMaxWidth()) {
            weekDays.forEach { day ->
                Text(
                    text = day,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall,
                    color = secondaryTextColor,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        // Days Grid
        val days = remember(currentMonth) { getDaysInMonth(currentMonth) }
        val rows = days.chunked(7)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            rows.forEach { row ->
                Row(modifier = Modifier.fillMaxWidth()) {
                    row.forEach { date ->
                        if (date == null) {
                            Spacer(modifier = Modifier.weight(1f))
                        } else {
                            val isSelected = isSameDay(date, selectedDate)
                            val isToday = isSameDay(date, Date())
                            val hasData = availableDates.any { isSameDay(it, date) }
                            val isCurrentMonth = isSameMonth(date, currentMonth)
                            val isFuture = date.time > System.currentTimeMillis() + 60000

                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .aspectRatio(1f)
                                    .clip(CircleShape)
                                    .background(if (isSelected) primaryColor else Color.Transparent)
                                    .clickable(enabled = (hasData || isToday) && !isFuture) { 
                                        onDateSelected(date) 
                                    },
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = Calendar.getInstance().apply { time = date }.get(Calendar.DAY_OF_MONTH).toString(),
                                    color = when {
                                        isSelected -> Color.White
                                        isFuture -> disabledTextColor
                                        !isCurrentMonth -> disabledTextColor
                                        isToday -> primaryColor
                                        hasData -> dataTextColor
                                        else -> subtleTextColor
                                    },
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = if (isSelected || isToday) FontWeight.Bold else FontWeight.Medium
                                )
                                
                                if (hasData && !isSelected) {
                                    Box(
                                        modifier = Modifier
                                            .align(Alignment.BottomCenter)
                                            .padding(bottom = 4.dp)
                                            .size(3.dp)
                                            .background(if (isToday) primaryColor else secondaryTextColor, CircleShape)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun getDaysInMonth(monthDate: Date): List<Date?> {
    val calendar = Calendar.getInstance().apply {
        time = monthDate
        set(Calendar.DAY_OF_MONTH, 1)
    }
    val daysInMonth = calendar.getActualMaximum(Calendar.DAY_OF_MONTH)
    val firstDayOfWeek = calendar.get(Calendar.DAY_OF_WEEK) - 1 // 0-based
    
    val result = mutableListOf<Date?>()
    for (i in 0 until firstDayOfWeek) {
        result.add(null)
    }
    for (i in 1..daysInMonth) {
        val date = calendar.time
        result.add(date)
        calendar.add(Calendar.DAY_OF_MONTH, 1)
    }
    
    // Fill until 42 to keep grid consistent (6 rows)
    while (result.size < 42) {
        result.add(null)
    }
    return result
}

private fun isSameMonth(d1: Date, d2: Date): Boolean {
    val c1 = Calendar.getInstance().apply { time = d1 }
    val c2 = Calendar.getInstance().apply { time = d2 }
    return c1.get(Calendar.YEAR) == c2.get(Calendar.YEAR) && c1.get(Calendar.MONTH) == c2.get(Calendar.MONTH)
}

@Composable
fun TodayFloatingButton(isVisible: Boolean, onClick: () -> Unit) {
    AnimatedVisibility(
        visible = isVisible,
        enter = fadeIn() + slideInVertically { it },
        exit = fadeOut() + slideOutVertically { it },
        modifier = Modifier.fillMaxSize()
    ) {
        Box(contentAlignment = Alignment.BottomCenter, modifier = Modifier.padding(bottom = 32.dp)) {
            Button(
                onClick = onClick,
                elevation = ButtonDefaults.buttonElevation(defaultElevation = 6.dp),
                shape = RoundedCornerShape(24.dp)
            ) {
                Icon(Icons.Default.Today, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("回到当下", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun FuturePlaceholderView() {
    val isDark = isSystemInDarkTheme()
    val titleColor = if (isDark) Color.White else Color.Black.copy(alpha = 0.8f)
    
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(60.dp), tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.6f))
        Spacer(Modifier.height(16.dp))
        Text("明天是个未拆的礼物", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = titleColor)
        Text("愿明天的你，能在平凡中发现惊喜。", style = MaterialTheme.typography.bodyMedium, color = Color.Gray, textAlign = TextAlign.Center)
    }
}

@Composable
fun PastPlaceholderView() {
    val isDark = isSystemInDarkTheme()
    val titleColor = if (isDark) Color.White else Color.Black.copy(alpha = 0.8f)
    
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.Timer, null, modifier = Modifier.size(60.dp), tint = Color.Gray.copy(alpha = 0.6f))
        Spacer(Modifier.height(16.dp))
        Text("真希望能早点遇到你", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = titleColor)
        Text("要是早点遇见，就能记录更多精彩了。", style = MaterialTheme.typography.bodyMedium, color = Color.Gray, textAlign = TextAlign.Center)
    }
}

private fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val R = 6371000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2)
    val c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    return R * c
}
