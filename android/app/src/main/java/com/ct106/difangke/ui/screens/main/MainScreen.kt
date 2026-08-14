package com.ct106.difangke.ui.screens.main

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.service.GeocodeService
import com.ct106.difangke.ui.components.*
import com.ct106.difangke.viewmodel.MainViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import java.text.SimpleDateFormat
import java.util.*
import org.json.JSONArray
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
    initialFutureTripID: String? = null,
    onNavigateToHistory: (Date) -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: (Date?) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToRawPoints: (Date) -> Unit,
    onNavigateToPlaces: () -> Unit
) {
    val context = LocalContext.current
    
    var showCalendar by remember { mutableStateOf(false) }
    var showShareOptions by remember { mutableStateOf(false) }
    val availableDates by viewModel.availableDates.collectAsState()
    val currentDate by viewModel.currentDate.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val allFutureTripsForEditor by viewModel.allFutureTripsForEditor.collectAsState(initial = emptyList())
    val trackingState by viewModel.trackingState.collectAsState()
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()
    var visibleMapDates by remember { mutableStateOf(setOf(Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.time)) }
    var showsUndatedFutureTripsOnMap by remember { mutableStateOf(false) }
    fun shareText(title: String, text: String) {
        context.startActivity(
            android.content.Intent.createChooser(
                android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(android.content.Intent.EXTRA_TEXT, text),
                title
            )
        )
    }
    fun shareRange(start: Date, end: Date) {
        val rangeStart = normalizeTimelineDate(start)
        val rangeEnd = Calendar.getInstance().apply { time = normalizeTimelineDate(end); add(Calendar.DAY_OF_YEAR, 1) }.time
        viewModel.loadTimelineItemsForRange(rangeStart, rangeEnd) { items ->
            shareText("分享足迹", timelineShareText(rangeStart, end, items))
        }
    }
    fun pickShareRange() {
        val initial = Calendar.getInstance().apply { time = currentDate }
        android.app.DatePickerDialog(context, { _, startYear, startMonth, startDay ->
            val start = Calendar.getInstance().apply { set(startYear, startMonth, startDay, 0, 0, 0); set(Calendar.MILLISECOND, 0) }.time
            android.app.DatePickerDialog(context, { _, endYear, endMonth, endDay ->
                val end = Calendar.getInstance().apply { set(endYear, endMonth, endDay, 0, 0, 0); set(Calendar.MILLISECOND, 0) }.time
                shareRange(minOf(start, end), maxOf(start, end))
            }, initial.get(Calendar.YEAR), initial.get(Calendar.MONTH), initial.get(Calendar.DAY_OF_MONTH)).show()
        }, initial.get(Calendar.YEAR), initial.get(Calendar.MONTH), initial.get(Calendar.DAY_OF_MONTH)).show()
    }
    
    // 初始化到特定日期 (如果是从历史跳转过来的)
    LaunchedEffect(initialDate) {
        if (initialDate != null) {
            viewModel.setDate(initialDate)
        }
    }

    val today = normalizeTimelineDate(Date())
    
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
    var locationPermissionNeedsSettings by remember { mutableStateOf(false) }
    var showLocationSettingsAlert by remember { mutableStateOf(false) }
    var hasNotificationPermission by remember(context) { mutableStateOf(
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true
    ) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        val fineGranted = perms[Manifest.permission.ACCESS_FINE_LOCATION] == true
        locationPermissionNeedsSettings = !fineGranted
        showLocationSettingsAlert = !fineGranted
        if (fineGranted) {
            hasPermissionState = true
            if (isTrackingEnabled) {
                LocationTrackingService.start(context) // 授权后立即开启服务
            }
        }
    }

    // Returning from Android's Settings does not recreate this composable.
    // Refresh the live permission state so the timeline immediately resumes
    // tracking instead of continuing to show a stale denied prompt.
    // NavHost can compose this destination before a lifecycle CompositionLocal
    // has been installed. The screen is always hosted by MainActivity, so use
    // that real owner rather than requiring LocalLifecycleOwner here.
    val lifecycleOwner = context.findComponentActivity()
    if (lifecycleOwner != null) {
        DisposableEffect(lifecycleOwner, context) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) {
                    hasPermissionState = ContextCompat.checkSelfPermission(
                        context, Manifest.permission.ACCESS_FINE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    if (hasPermissionState) {
                        locationPermissionNeedsSettings = false
                        showLocationSettingsAlert = false
                    }
                }
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
        }
    }
    
    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasNotificationPermission = granted
    }

    val sharedPreferences = remember { context.getSharedPreferences("dfk_prefs", android.content.Context.MODE_PRIVATE) }
    var isNotificationGuideDismissed by remember { 
        mutableStateOf(sharedPreferences.getBoolean("isNotificationGuideDismissed", false)) 
    }
    val dismissGuide = {
        isNotificationGuideDismissed = true
        sharedPreferences.edit().putBoolean("isNotificationGuideDismissed", true).apply()
    }
    
    val backgroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted && isTrackingEnabled) {
            LocationTrackingService.start(context) // 后台授权后也尝试开启/刷新服务
        }
    }

    fun openAppLocationSettings() {
        context.startActivity(
            android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", context.packageName, null)
            )
        )
    }

    LaunchedEffect(isTrackingEnabled, hasPermissionState) {
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
    var selectedFutureTripDetail by remember { mutableStateOf<FutureTripEntity?>(null) }
    var pendingFutureTripID by remember(initialFutureTripID) { mutableStateOf(initialFutureTripID) }

    LaunchedEffect(pendingFutureTripID, allFutureTripsForEditor) {
        pendingFutureTripID?.let { tripID ->
            allFutureTripsForEditor.firstOrNull { it.tripID == tripID }?.let { trip ->
                selectedFutureTripDetail = trip
                pendingFutureTripID = null
            }
        }
    }
    
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
            visibleDates = visibleMapDates,
            showsUndatedFutureTripsOnMap = showsUndatedFutureTripsOnMap,
            selectedFutureTripID = selectedFutureTripDetail?.tripID,
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
            onNavigateToPlaces = onNavigateToPlaces,
            onShare = { showShareOptions = true },
            onAddFutureTrip = {
                editingFutureTrip = null
                showingFutureTripEditor = true
            },
            onEditFutureTrip = {
                selectedFutureTripDetail = it
            },
            onRequestPermission = {
                if (locationPermissionNeedsSettings) openAppLocationSettings()
                else launcher.launch(permissionsToRequest)
            },
            onRequestNotification = {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                dismissGuide()
            },
            onDismissNotificationGuide = { dismissGuide() },
            onEnableTracking = { viewModel.setTrackingEnabled(true) },
            onVisibleDatesChanged = { dates -> visibleMapDates = dates },
            onUndatedFutureTripsVisibilityChanged = { showsUndatedFutureTripsOnMap = it }
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

        if (showShareOptions) {
            TimelineShareOptionsDialog(
                onDismiss = { showShareOptions = false },
                onShareCurrentDate = {
                    showShareOptions = false
                    shareRange(currentDate, currentDate)
                },
                onShareDateRange = {
                    showShareOptions = false
                    pickShareRange()
                },
                onShareFuturePlans = {
                    showShareOptions = false
                    val todayStart = normalizeTimelineDate(Date())
                    val plans = allFutureTripsForEditor.filter { !it.isCompleted && (!it.hasPlanDate || !it.arrivalDate.before(todayStart)) }
                    shareText("分享未来计划", futurePlansShareText(plans))
                }
            )
        }

        if (showingFutureTripEditor) {
            FutureTripEditorDialog(
                editingTrip = editingFutureTrip,
                places = allPlaces,
                activityTypes = activityTypes,
                allFutureTrips = allFutureTripsForEditor,
                onDismiss = { showingFutureTripEditor = false },
                onSave = { place, date, hasPlanDate, hasArrivalTime, hour, minute, insertionAnchorTripID, activityTypeValue, notes ->
                    viewModel.saveFutureTrip(
                        editingTrip = editingFutureTrip,
                        place = place,
                        date = date,
                        hasPlanDate = hasPlanDate,
                        hasArrivalTime = hasArrivalTime,
                        hour = hour,
                        minute = minute,
                        insertionAnchorTripID = insertionAnchorTripID,
                        activityTypeValue = activityTypeValue,
                        notes = notes
                    )
                    showingFutureTripEditor = false
                }
            )
        }

        selectedFutureTripDetail?.let { trip ->
            FutureTripDetailDialog(
                trip = trip,
                activityTypes = activityTypes,
                onDismiss = { selectedFutureTripDetail = null },
                onEdit = {
                    selectedFutureTripDetail = null
                    editingFutureTrip = trip
                    showingFutureTripEditor = true
                },
                onComplete = {
                    viewModel.completeFutureTrip(trip)
                    selectedFutureTripDetail = null
                },
                onDelay = { delayMillis ->
                    viewModel.delayFutureTrip(trip, delayMillis)
                    selectedFutureTripDetail = null
                },
                onAbandon = {
                    viewModel.deleteFutureTrip(trip)
                    selectedFutureTripDetail = null
                },
                onNavigate = {
                    if (trip.latitude.isFinite() && trip.longitude.isFinite() && trip.latitude != 0.0 && trip.longitude != 0.0) {
                        val label = android.net.Uri.encode(trip.placeName)
                        val intent = android.content.Intent(
                            android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse("geo:${trip.latitude},${trip.longitude}?q=${trip.latitude},${trip.longitude}($label)")
                        )
                        runCatching { context.startActivity(intent) }
                    }
                }
            )
        }

        if (showBackgroundRationale) {
            AlertDialog(
                onDismissRequest = { showBackgroundRationale = false },
                title = { Text("需要后台定位权限") },
                text = { Text("为了在您关闭屏幕或使用其他应用时持续记录足迹，请在随后的系统中选择“始终允许”定位权限。") },
                confirmButton = {
                    Button(onClick = {
                        showBackgroundRationale = false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            openAppLocationSettings()
                        } else {
                            backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                        }
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

        if (isTrackingEnabled && showLocationSettingsAlert) {
            AlertDialog(
                onDismissRequest = { showLocationSettingsAlert = false },
                title = { Text("定位权限已关闭") },
                text = { Text("地方客无法记录足迹、停留与行程。请在系统设置中允许定位。") },
                confirmButton = {
                    TextButton(onClick = {
                        showLocationSettingsAlert = false
                        openAppLocationSettings()
                    }) { Text("前往系统设置") }
                },
                dismissButton = {
                    TextButton(onClick = { showLocationSettingsAlert = false }) { Text("稍后") }
                }
            )
        }

    }
}

private tailrec fun Context.findComponentActivity(): ComponentActivity? = when (this) {
    is ComponentActivity -> this
    is ContextWrapper -> baseContext.findComponentActivity()
    else -> null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ContinuousTimelineScaffold(
    selectedDate: Date,
    visibleDates: Set<Date>,
    showsUndatedFutureTripsOnMap: Boolean,
    selectedFutureTripID: String?,
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
    onNavigateToPlaces: () -> Unit,
    onShare: () -> Unit,
    onAddFutureTrip: () -> Unit,
    onEditFutureTrip: (FutureTripEntity) -> Unit,
    onRequestPermission: () -> Unit,
    onRequestNotification: () -> Unit,
    onDismissNotificationGuide: () -> Unit,
    onEnableTracking: () -> Unit,
    onVisibleDatesChanged: (Set<Date>) -> Unit,
    onUndatedFutureTripsVisibilityChanged: (Boolean) -> Unit
) {
    // Match the iOS TimelineView: the map remains a full-screen canvas and
    // the timeline is a draggable, rounded sheet over it.  A permanent split
    // makes both surfaces too small and changes the navigation hierarchy.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        var sheetHeightPx by remember { mutableFloatStateOf(Float.NaN) }
        var isDraggingSheetHandle by remember { mutableStateOf(false) }
        // Full height still leaves deliberate breathing room above the sheet;
        // the status-bar inset alone is too tight on tall Android displays.
        val expandedTopMargin = maxOf(
            WindowInsets.statusBars.asPaddingValues().calculateTopPadding(),
            72.dp
        )
        val expandedSheetHeight = maxHeight - expandedTopMargin
        val minimizedSheetHeightPx = with(density) { 88.dp.toPx() }
        val halfSheetHeightPx = with(density) { (maxHeight * 0.52f).toPx() }
        val expandedSheetHeightPx = with(density) { expandedSheetHeight.toPx() }
        val sheetDetents = remember(minimizedSheetHeightPx, halfSheetHeightPx, expandedSheetHeightPx) {
            listOf(minimizedSheetHeightPx, halfSheetHeightPx, expandedSheetHeightPx)
        }
        LaunchedEffect(minimizedSheetHeightPx, halfSheetHeightPx, expandedSheetHeightPx) {
            sheetHeightPx = if (sheetHeightPx.isNaN()) {
                halfSheetHeightPx
            } else {
                sheetHeightPx.coerceIn(minimizedSheetHeightPx, expandedSheetHeightPx)
            }
        }
        val animatedSheetHeightPx by animateFloatAsState(
            targetValue = sheetHeightPx.takeUnless { it.isNaN() } ?: halfSheetHeightPx,
            animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
            label = "timeline_sheet_settle"
        )
        val displayedSheetHeightPx = if (isDraggingSheetHandle) sheetHeightPx else animatedSheetHeightPx
        val displayedSheetHeight = with(density) { displayedSheetHeightPx.toDp() }
        val isTimelineMinimized = displayedSheetHeightPx < (minimizedSheetHeightPx + halfSheetHeightPx) / 2f

        TimelineMapPane(
            modifier = Modifier.fillMaxSize(),
            selectedDate = selectedDate,
            visibleDates = visibleDates,
            showsUndatedFutureTripsOnMap = showsUndatedFutureTripsOnMap,
            selectedFutureTripID = selectedFutureTripID,
            viewModel = viewModel,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            onNavigateToMap = { onNavigateToMap(selectedDate) },
            onNavigateToHistory = { onNavigateToHistory(selectedDate) },
            onNavigateToStatistics = onNavigateToStatistics,
            onNavigateToSettings = onNavigateToSettings,
            onShowCalendar = onShowCalendar,
            onNavigateToDetail = onNavigateToDetail,
            onEditFutureTrip = onEditFutureTrip,
            mapBottomOcclusionFraction =
                (displayedSheetHeightPx / with(density) { maxHeight.toPx() }).coerceIn(0f, 1f)
        )

        Surface(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(displayedSheetHeight),
            shape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp),
            color = if (isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color(0xFFF2F2F7),
            contentColor = MaterialTheme.colorScheme.onSurface,
            shadowElevation = 8.dp
        ) {
            Column(Modifier.fillMaxSize()) {
                // The sheet and the list deliberately do not share a nested
                // scroll connection. Only this handle changes sheet height.
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp, bottom = 4.dp)
                    .pointerInput(minimizedSheetHeightPx, halfSheetHeightPx, expandedSheetHeightPx) {
                        detectVerticalDragGestures(
                            onDragStart = { isDraggingSheetHandle = true },
                            onVerticalDrag = { change, dragAmount ->
                                change.consume()
                                sheetHeightPx = (sheetHeightPx - dragAmount)
                                    .coerceIn(minimizedSheetHeightPx, expandedSheetHeightPx)
                            },
                            onDragCancel = {
                                isDraggingSheetHandle = false
                                sheetHeightPx = sheetDetents.minBy { detent ->
                                    kotlin.math.abs(detent - sheetHeightPx)
                                }
                            },
                            onDragEnd = {
                                isDraggingSheetHandle = false
                                sheetHeightPx = sheetDetents.minBy { detent ->
                                    kotlin.math.abs(detent - sheetHeightPx)
                                }
                            }
                        )
                    },
                contentAlignment = Alignment.Center
            ) {
                Box(
                    Modifier
                        .size(width = 36.dp, height = 5.dp)
                        .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.32f))
                )
            }
                TimelineSheetHeader(
                    date = selectedDate,
                    onShowCalendar = onShowCalendar,
                    onShowHistory = { onNavigateToHistory(selectedDate) },
                    onShare = onShare,
                    onShowSettings = onNavigateToSettings,
                    onManagePlaces = onNavigateToPlaces,
                    onShowStatistics = onNavigateToStatistics,
                    onViewRawPoints = { onViewRawPoints(selectedDate) },
                    onRebuild = { onRebuildDate(selectedDate) },
                    onAddFutureTrip = onAddFutureTrip
                )
                if (!isTimelineMinimized) {
                    ContinuousTimelineList(
                        modifier = Modifier.weight(1f),
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
                        onEnableTracking = onEnableTracking,
                        onVisibleDatesChanged = onVisibleDatesChanged,
                        onUndatedFutureTripsVisibilityChanged = onUndatedFutureTripsVisibilityChanged
                    )
                }
            }
        }
    }
}

@Composable
private fun TimelineMapPane(
    modifier: Modifier,
    selectedDate: Date,
    visibleDates: Set<Date>,
    showsUndatedFutureTripsOnMap: Boolean,
    selectedFutureTripID: String?,
    viewModel: MainViewModel,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allPlaces: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    onNavigateToMap: () -> Unit,
    onNavigateToHistory: () -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onShowCalendar: () -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onEditFutureTrip: (FutureTripEntity) -> Unit,
    mapBottomOcclusionFraction: Float
) {
    val mapDates = remember(selectedDate, visibleDates) { (visibleDates + selectedDate).map { normalizeTimelineDate(it) }.toSet() }
    val items by viewModel.getTimelineItemsForDates(mapDates).collectAsState(initial = emptyList())
    val undatedTrips by viewModel.undatedFutureTrips.collectAsState(initial = emptyList())
    val dailyInsight by viewModel.getDailyInsight(selectedDate).collectAsState(initial = null)
    val dailyPoints by viewModel.getDailyTrajectoryForDates(mapDates).collectAsState(initial = null)
    val dailyMarkers by viewModel.getDailyMarkers(selectedDate).collectAsState(initial = null)
    val selectedDayItems by viewModel.getTimelineItems(selectedDate).collectAsState(initial = emptyList())
    val trackingState by viewModel.trackingState.collectAsState()
    var focusUserLocationRequest by remember { mutableIntStateOf(0) }
    val mapFutureTrips = remember(items, undatedTrips, showsUndatedFutureTripsOnMap) {
        items.filterIsInstance<TimelineItem.FutureTripItem>().map { it.trip } +
            if (showsUndatedFutureTripsOnMap) undatedTrips else emptyList()
    }
    val selectedFutureTrip = remember(mapFutureTrips, selectedFutureTripID) {
        mapFutureTrips.firstOrNull { it.tripID == selectedFutureTripID }
    }
    val footprintMarkers = remember(items, mapFutureTrips, activityTypes) {
        buildFootprintMapMarkers(
            items.filterIsInstance<TimelineItem.FootprintItem>().map { it.footprint },
            activityTypes
        ) + buildTransportMapMarkers(items.filterIsInstance<TimelineItem.TransportItem>()) + mapFutureTrips
            .filter { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
            .map { trip ->
                val activity = activityTypes.firstOrNull { it.id == trip.activityTypeValue }
                FootprintMapMarker(
                    id = "future:${trip.tripID}",
                    latitude = trip.latitude,
                    longitude = trip.longitude,
                    icon = activity?.icon ?: "event",
                    colorHex = activity?.colorHex ?: "#FF9500"
                )
            }
    }
    val centerPoint = remember(items, mapFutureTrips) {
        items.filterIsInstance<TimelineItem.FootprintItem>()
            .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
            ?.let { it.latitude to it.longitude }
            ?: mapFutureTrips
                .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
                ?.let { it.latitude to it.longitude }
    }
    // Map overlays may include neighbouring visible days, but changing the
    // timeline date must always move the camera to that selected day's data.
    val selectedDayCenter = remember(selectedDayItems) {
        selectedDayItems.filterIsInstance<TimelineItem.FootprintItem>()
            .firstOrNull { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 && it.longitude != 0.0 }
            ?.let { it.latitude to it.longitude }
    }
    val isDark = isSystemInDarkTheme()

    val today = normalizeTimelineDate(Date())
    val isToday = selectedDate.time == today.time
    val currentLocation = when (val state = trackingState) {
        is LocationTrackingService.TrackingState.Tracking -> state.lat to state.lon
        is LocationTrackingService.TrackingState.OngoingStay -> state.lat to state.lon
        LocationTrackingService.TrackingState.Idle -> null
    }

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
            userLatitude = currentLocation?.first,
            userLongitude = currentLocation?.second,
            focusUserLocationRequest = focusUserLocationRequest,
            focusLatitude = selectedFutureTrip?.latitude ?: selectedDayCenter?.first,
            focusLongitude = selectedFutureTrip?.longitude ?: selectedDayCenter?.second,
            focusTargetID = selectedFutureTrip?.tripID ?: "day:${selectedDate.time}",
            focusZoom = if (selectedFutureTrip != null) 15f else 13.5f,
            modifier = Modifier.fillMaxSize(),
            cornerRadius = 0.dp,
            gesturesEnabled = true,
            showClickOverlay = false,
            cameraBottomPaddingFraction = mapBottomOcclusionFraction,
            onMarkerClick = { markerID ->
                if (markerID.startsWith("future:")) {
                    mapFutureTrips.firstOrNull { it.tripID == markerID.removePrefix("future:") }
                        ?.let(onEditFutureTrip)
                } else if (markerID.startsWith("transport:")) {
                    onNavigateToDetail("t_${markerID.removePrefix("transport:")}")
                } else {
                    onNavigateToDetail("f_$markerID")
                }
            },
            onClick = onNavigateToMap
        )

        if (currentLocation?.first?.isFinite() == true && currentLocation.second?.isFinite() == true) {
            MapIconButton(
                icon = Icons.Default.MyLocation,
                label = "定位到当前位置",
                onClick = { focusUserLocationRequest += 1 },
                // The draggable timeline sheet covers the bottom of the map at
                // every useful detent. Keep this control in the always-visible
                // map chrome so "locate me" remains reachable while browsing
                // older dates.
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 56.dp, end = 16.dp)
            )
        }

        MapEmptyHint(
            isVisible = !isToday && footprintMarkers.isEmpty() && (dailyPoints ?: dailyInsight?.rawPointsJson).isNullOrBlank(),
            date = selectedDate
        )

    }
}

/**
 * iOS exposes a tappable transport icon at the midpoint of every rendered
 * route. Keep the Android presentation Material, but retain that navigable
 * map affordance instead of making transport paths read-only decoration.
 */
private fun buildTransportMapMarkers(
    items: List<TimelineItem.TransportItem>
): List<FootprintMapMarker> = items.mapNotNull { item ->
    val points = runCatching {
        val array = JSONArray(item.transport.pointsJson)
        buildList {
            for (index in 0 until array.length()) {
                val point = array.optJSONArray(index) ?: continue
                val latitude = point.optDouble(0, Double.NaN)
                val longitude = point.optDouble(1, Double.NaN)
                if (latitude.isFinite() && longitude.isFinite() && latitude != 0.0 && longitude != 0.0) {
                    add(latitude to longitude)
                }
            }
        }
    }.getOrDefault(emptyList())
    if (points.size < 2) return@mapNotNull null
    val midpoint = points[points.lastIndex / 2]
    FootprintMapMarker(
        id = "transport:${item.transport.recordID}",
        latitude = midpoint.first,
        longitude = midpoint.second,
        icon = TransportType.from(item.transport.manualTypeRaw ?: item.transport.typeRaw).icon,
        colorHex = "#00A0AC"
    )
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
private fun MapIconButton(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(
        onClick = onClick,
        modifier = modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.82f))
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(19.dp), tint = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun TimelineSheetHeader(
    date: Date,
    onShowCalendar: () -> Unit,
    onShowHistory: () -> Unit,
    onShare: () -> Unit,
    onShowSettings: () -> Unit,
    onManagePlaces: () -> Unit,
    onShowStatistics: () -> Unit,
    onViewRawPoints: () -> Unit,
    onRebuild: () -> Unit,
    onAddFutureTrip: () -> Unit
) {
    var showMoreMenu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onShowHistory) {
            Icon(Icons.Default.History, contentDescription = "往昔足迹")
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(10.dp))
                .clickable(onClick = onShowCalendar)
                .padding(vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(timelineDateTitle(date), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Default.UnfoldMore,
                    contentDescription = null,
                    modifier = Modifier.size(15.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.58f)
                )
            }
            Text(
                timelineDateSubtitle(date),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        IconButton(onClick = onShare) {
            Icon(Icons.Default.Share, contentDescription = "分享")
        }
        IconButton(onClick = onAddFutureTrip) {
            Icon(Icons.Default.Add, contentDescription = "新增行程计划")
        }
        Box {
            IconButton(onClick = { showMoreMenu = true }) {
                Icon(Icons.Default.MoreHoriz, contentDescription = "更多")
            }
            DropdownMenu(expanded = showMoreMenu, onDismissRequest = { showMoreMenu = false }) {
                DropdownMenuItem(
                    text = { Text("统计洞察") },
                    leadingIcon = { Icon(Icons.Default.BarChart, contentDescription = null) },
                    onClick = { showMoreMenu = false; onShowStatistics() }
                )
                DropdownMenuItem(
                    text = { Text("重要地点") },
                    leadingIcon = { Icon(Icons.Default.Place, contentDescription = null) },
                    onClick = { showMoreMenu = false; onManagePlaces() }
                )
                DropdownMenuItem(
                    text = { Text("查看所有轨迹点") },
                    leadingIcon = { Icon(Icons.Default.Timeline, contentDescription = null) },
                    onClick = { showMoreMenu = false; onViewRawPoints() }
                )
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("重新生成本日数据") },
                    leadingIcon = { Icon(Icons.Default.Refresh, contentDescription = null) },
                    onClick = { showMoreMenu = false; onRebuild() }
                )
            }
        }
        IconButton(onClick = onShowSettings) {
            Icon(Icons.Default.Settings, contentDescription = "设置")
        }
    }
}

@Composable
private fun TimelineShareOptionsDialog(
    onDismiss: () -> Unit,
    onShareCurrentDate: () -> Unit,
    onShareDateRange: () -> Unit,
    onShareFuturePlans: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("分享") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("选择要通过系统分享面板发送的内容。", color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton(onClick = onShareCurrentDate, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Today, null)
                    Spacer(Modifier.width(8.dp))
                    Text("分享当前日期足迹")
                }
                OutlinedButton(onClick = onShareDateRange, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.DateRange, null)
                    Spacer(Modifier.width(8.dp))
                    Text("选择日期范围分享")
                }
                OutlinedButton(onClick = onShareFuturePlans, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Event, null)
                    Spacer(Modifier.width(8.dp))
                    Text("分享未来计划")
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

private fun timelineShareText(start: Date, end: Date, items: List<TimelineItem>): String {
    val range = if (isSameDay(start, end)) timelineDateTitle(start) else "${timelineDateTitle(start)} 至 ${timelineDateTitle(end)}"
    val timeFormat = SimpleDateFormat("HH:mm", Locale.CHINA)
    val lines = items.map { item ->
        when (item) {
            is TimelineItem.FootprintItem -> "${timeFormat.format(item.footprint.startTime)} · ${item.footprint.title ?: item.footprint.address ?: "停留地点"}"
            is TimelineItem.TransportItem -> "${timeFormat.format(item.transport.startTime)} · ${item.transport.startLocation ?: "出发地"} → ${item.transport.endLocation ?: "目的地"}"
            is TimelineItem.FutureTripItem -> "${timeFormat.format(item.trip.effectiveArrivalDate())} · 计划：${item.trip.placeName}"
        }
    }
    return buildString {
        append("地方客 · ").append(range)
        if (lines.isEmpty()) append("\n暂无足迹记录") else lines.forEach { append("\n").append(it) }
    }
}

private fun futurePlansShareText(plans: List<FutureTripEntity>): String = buildString {
    append("地方客 · 未来计划")
    if (plans.isEmpty()) append("\n暂无待完成计划")
    else FutureTripEntity.dayOrdered(plans).forEach { trip ->
        val dateText = if (trip.isUndated) "未定日期" else SimpleDateFormat("M月d日", Locale.CHINA).format(trip.arrivalDate)
        append("\n").append(dateText).append(" · ").append(trip.placeName)
        trip.notes?.takeIf { it.isNotBlank() }?.let { append("（").append(it).append("）") }
    }
}

@Composable
private fun FutureTripEditorDialog(
    editingTrip: FutureTripEntity?,
    places: List<PlaceEntity>,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    allFutureTrips: List<FutureTripEntity>,
    onDismiss: () -> Unit,
    onSave: (PlaceEntity, Date, Boolean, Boolean, Int, Int, String?, String?, String) -> Unit
) {
    val context = LocalContext.current
    var selectedPlaceID by remember(editingTrip) { mutableStateOf(editingTrip?.placeID ?: places.firstOrNull()?.placeID) }
    var date by remember(editingTrip) { mutableStateOf(editingTrip?.arrivalDate ?: Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 1) }.time) }
    var hasPlanDate by remember(editingTrip) { mutableStateOf(editingTrip?.hasPlanDate ?: true) }
    var hasArrivalTime by remember(editingTrip) { mutableStateOf(editingTrip?.hasArrivalTime ?: false) }
    var notes by remember(editingTrip) { mutableStateOf(editingTrip?.notes.orEmpty()) }
    var activityTypeValue by remember(editingTrip) { mutableStateOf(editingTrip?.activityTypeValue) }
    var insertionAnchorTripID by remember(editingTrip) { mutableStateOf<String?>("__end__") }
    var showPlaces by remember { mutableStateOf(false) }
    var showActivities by remember { mutableStateOf(false) }
    val calendar = remember(date) { Calendar.getInstance().apply { time = date } }
    val selectedPlace = places.firstOrNull { it.placeID == selectedPlaceID }
    val selectedActivity = activityTypes.firstOrNull { it.id == activityTypeValue }
    val orderedCandidates = remember(allFutureTrips, editingTrip, hasPlanDate, date) {
        FutureTripEntity.dayOrdered(
            allFutureTrips.filter { trip ->
                !trip.isCompleted && trip.tripID != editingTrip?.tripID &&
                    if (hasPlanDate) trip.hasPlanDate && isSameDay(trip.arrivalDate, date)
                    else trip.isUndated
            }
        )
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (editingTrip == null) "新增行程计划" else "修改行程计划") },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 460.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("地点", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                Box {
                    OutlinedButton(onClick = { showPlaces = true }, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.Place, null)
                        Spacer(Modifier.width(8.dp))
                        Text(selectedPlace?.name ?: "请选择已保存地点", modifier = Modifier.weight(1f), textAlign = TextAlign.Start)
                        Icon(Icons.Default.ArrowDropDown, null)
                    }
                    DropdownMenu(expanded = showPlaces, onDismissRequest = { showPlaces = false }) {
                        places.filter { !it.isIgnored }.forEach { place ->
                            DropdownMenuItem(
                                text = { Column { Text(place.name); place.address?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.labelSmall) } } },
                                onClick = { selectedPlaceID = place.placeID; showPlaces = false }
                            )
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("设定计划日期", modifier = Modifier.weight(1f))
                    Switch(checked = hasPlanDate, onCheckedChange = {
                        hasPlanDate = it
                        if (!it) hasArrivalTime = false
                    })
                }
                if (hasPlanDate) {
                    Text("计划时间", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    OutlinedButton(
                        onClick = {
                            android.app.DatePickerDialog(context, { _, year, month, day ->
                                date = Calendar.getInstance().apply {
                                    time = date
                                    set(year, month, day)
                                }.time
                            }, calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH), calendar.get(Calendar.DAY_OF_MONTH)).show()
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.CalendarMonth, null)
                        Spacer(Modifier.width(8.dp))
                        Text(SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(date))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text("设置具体时间", modifier = Modifier.weight(1f))
                        Switch(checked = hasArrivalTime, onCheckedChange = { hasArrivalTime = it })
                    }
                }
                if (hasPlanDate && hasArrivalTime) {
                    OutlinedButton(
                        onClick = {
                            android.app.TimePickerDialog(context, { _, hour, minute ->
                                date = Calendar.getInstance().apply { time = date; set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute) }.time
                            }, calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE), true).show()
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Schedule, null)
                        Spacer(Modifier.width(8.dp))
                        Text(SimpleDateFormat("HH:mm", Locale.CHINA).format(date))
                    }
                } else if (hasPlanDate) {
                    Text("未设具体时间的计划将按当天的行程顺序显示。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    Text("未定日期的计划会集中显示在首页时间线末端，可稍后再补充日期。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (!hasPlanDate || !hasArrivalTime) {
                    var showInsertionPositions by remember(hasPlanDate, date, editingTrip) { mutableStateOf(false) }
                    Text("显示顺序", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    Box {
                        OutlinedButton(onClick = { showInsertionPositions = true }, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                when (insertionAnchorTripID) {
                                    "__first__" -> "排在最前"
                                    "__end__", null -> "排在最后"
                                    else -> orderedCandidates.firstOrNull { it.tripID == insertionAnchorTripID }?.let { "排在 ${it.placeName} 之后" } ?: "排在最后"
                                },
                                modifier = Modifier.weight(1f), textAlign = TextAlign.Start
                            )
                            Icon(Icons.Default.ArrowDropDown, null)
                        }
                        DropdownMenu(expanded = showInsertionPositions, onDismissRequest = { showInsertionPositions = false }) {
                            DropdownMenuItem(text = { Text("排在最前") }, onClick = { insertionAnchorTripID = "__first__"; showInsertionPositions = false })
                            orderedCandidates.forEach { candidate ->
                                DropdownMenuItem(
                                    text = { Text("排在 ${candidate.placeName} 之后") },
                                    onClick = { insertionAnchorTripID = candidate.tripID; showInsertionPositions = false }
                                )
                            }
                            DropdownMenuItem(text = { Text("排在最后") }, onClick = { insertionAnchorTripID = "__end__"; showInsertionPositions = false })
                        }
                    }
                }
                Text("活动类型", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                Box {
                    OutlinedButton(onClick = { showActivities = true }, modifier = Modifier.fillMaxWidth()) {
                        Text(selectedActivity?.name ?: "未选择", modifier = Modifier.weight(1f), textAlign = TextAlign.Start)
                        Icon(Icons.Default.ArrowDropDown, null)
                    }
                    DropdownMenu(expanded = showActivities, onDismissRequest = { showActivities = false }) {
                        DropdownMenuItem(text = { Text("未选择") }, onClick = { activityTypeValue = null; showActivities = false })
                        activityTypes.sortedBy { it.sortOrder }.forEach { activity ->
                            DropdownMenuItem(text = { Text(activity.name) }, onClick = { activityTypeValue = activity.id; showActivities = false })
                        }
                    }
                }
                OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("备注") }, minLines = 2, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = {
            TextButton(enabled = selectedPlace != null, onClick = {
                val time = Calendar.getInstance().apply { this.time = date }
                onSave(selectedPlace!!, date, hasPlanDate, hasArrivalTime, time.get(Calendar.HOUR_OF_DAY), time.get(Calendar.MINUTE), insertionAnchorTripID, activityTypeValue, notes)
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
private fun FutureTripDetailDialog(
    trip: FutureTripEntity,
    activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
    onComplete: () -> Unit,
    onDelay: (Long) -> Unit,
    onAbandon: () -> Unit,
    onNavigate: () -> Unit
) {
    var showDelayMenu by remember { mutableStateOf(false) }
    var showAbandonConfirm by remember { mutableStateOf(false) }
    val activity = activityTypes.firstOrNull { it.id == trip.activityTypeValue || it.name == trip.activityTypeValue }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (trip.isCompleted) "已完成的计划" else "计划详情") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(trip.placeName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                trip.address?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(
                    when {
                        trip.isUndated -> "未定日期，等待安排"
                        trip.hasArrivalTime -> "计划于 ${SimpleDateFormat("yyyy年M月d日 HH:mm", Locale.CHINA).format(trip.arrivalDate)}"
                        else -> "计划于 ${SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(trip.arrivalDate)}，按当天顺序安排"
                    },
                    style = MaterialTheme.typography.bodyMedium
                )
                activity?.let { Text("活动类型：${it.name}", style = MaterialTheme.typography.bodyMedium) }
                trip.notes?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                if (!trip.isCompleted) {
                    if (trip.latitude.isFinite() && trip.longitude.isFinite() && trip.latitude != 0.0 && trip.longitude != 0.0) {
                        OutlinedButton(onClick = onNavigate, modifier = Modifier.fillMaxWidth()) {
                            Icon(Icons.Default.Navigation, null)
                            Spacer(Modifier.width(4.dp))
                            Text("导航到这里")
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Button(onClick = onComplete, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Default.Check, null)
                            Spacer(Modifier.width(4.dp))
                            Text("完成")
                        }
                        if (!trip.isUndated && !trip.isOrdered) {
                            Box(modifier = Modifier.weight(1f)) {
                                OutlinedButton(onClick = { showDelayMenu = true }, modifier = Modifier.fillMaxWidth()) {
                                    Icon(Icons.Default.Schedule, null)
                                    Spacer(Modifier.width(4.dp))
                                    Text("推迟")
                                }
                                DropdownMenu(expanded = showDelayMenu, onDismissRequest = { showDelayMenu = false }) {
                                    listOf("推迟5分钟" to 5 * 60_000L, "推迟15分钟" to 15 * 60_000L, "推迟1小时" to 60 * 60_000L, "推迟6小时" to 6 * 60 * 60_000L, "推迟1天" to 24 * 60 * 60_000L).forEach { (title, millis) ->
                                        DropdownMenuItem(text = { Text(title) }, onClick = { showDelayMenu = false; onDelay(millis) })
                                    }
                                }
                            }
                        }
                    }
                    OutlinedButton(
                        onClick = { showAbandonConfirm = true },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    ) { Text("放弃计划") }
                }
            }
        },
        confirmButton = { TextButton(onClick = onEdit) { Text("编辑") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("关闭") } }
    )

    if (showAbandonConfirm) {
        AlertDialog(
            onDismissRequest = { showAbandonConfirm = false },
            title = { Text("放弃计划？") },
            text = { Text("“${trip.placeName}”将被删除，且其提醒会被取消。") },
            confirmButton = { TextButton(onClick = onAbandon) { Text("放弃", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { showAbandonConfirm = false }) { Text("取消") } }
        )
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
    onEnableTracking: () -> Unit,
    onVisibleDatesChanged: (Set<Date>) -> Unit,
    onUndatedFutureTripsVisibilityChanged: (Boolean) -> Unit
) {
    val timelineDates = remember(availableDates) {
        availableDates.map(::normalizeTimelineDate)
            .distinctBy { it.time }
            .sortedByDescending { it.time }
    }
    val isDark = isSystemInDarkTheme()
    val listBackground = if (isDark) Color.Black else Color(0xFFF2F2F7)
    val listState = rememberLazyListState()
    var isProgrammaticDateScroll by remember { mutableStateOf(false) }
    val undatedTrips by viewModel.undatedFutureTrips.collectAsState(initial = emptyList())

    LaunchedEffect(selectedDate.time, timelineDates) {
        val index = timelineDates.indexOfFirst { isSameDay(it, selectedDate) }
        if (index != -1) {
            isProgrammaticDateScroll = true
            try {
                val visibleDate = visibleTimelineDate(listState)
                if (visibleDate == null) {
                    listState.scrollToItem(index)
                } else if (!isSameDay(visibleDate, selectedDate)) {
                    listState.animateScrollToItem(index)
                }
            } finally {
                // Do not let the viewport observer overwrite an explicit
                // target such as "回到当下" while the list is animating.
                isProgrammaticDateScroll = false
            }
        }
    }

    LaunchedEffect(listState, selectedDate.time, timelineDates) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collectLatest { isScrolling ->
                if (!isScrolling && !isProgrammaticDateScroll) {
                    delay(160)
                    val visibleDate = visibleTimelineDate(listState) ?: return@collectLatest
                    if (!isSameDay(visibleDate, selectedDate)) {
                        onSelectDate(visibleDate)
                    }
                }
            }
    }

    LaunchedEffect(listState, timelineDates) {
        snapshotFlow {
            listState.layoutInfo.visibleItemsInfo.mapNotNull { item ->
                (item.key as? String)
                    ?.removePrefix("day_")
                    ?.toLongOrNull()
                    ?.let(::Date)
            }.toSet()
        }
            .distinctUntilChanged()
            .collect { dates ->
                if (dates.isNotEmpty()) onVisibleDatesChanged(dates)
            }
    }

    LaunchedEffect(listState, undatedTrips) {
        snapshotFlow {
            listState.layoutInfo.visibleItemsInfo.any { it.key == "undated_future_trips" }
        }.distinctUntilChanged().collect(onUndatedFutureTripsVisibilityChanged)
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
        if (undatedTrips.isNotEmpty()) {
            item(key = "undated_future_trips") {
                Column(modifier = Modifier.padding(top = 12.dp, bottom = 8.dp)) {
                    Text(
                        text = "未定日期的计划",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)
                    )
                    Text(
                        text = "尚未安排日期，可点按补充计划",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 4.dp)
                    )
                    undatedTrips.forEachIndexed { index, trip ->
                        FutureTripCardView(
                            trip = trip,
                            activityTypes = activityTypes,
                            isFirst = index == 0,
                            isLast = index == undatedTrips.lastIndex,
                            onClick = { onEditFutureTrip(trip) }
                        )
                    }
                }
            }
        }
    }
}

private fun timelineDateItemKey(date: Date): String = "day_${date.time}"

private fun normalizeTimelineDate(date: Date): Date = Calendar.getInstance().apply {
    time = date
    set(Calendar.HOUR_OF_DAY, 0)
    set(Calendar.MINUTE, 0)
    set(Calendar.SECOND, 0)
    set(Calendar.MILLISECOND, 0)
}.time

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
    val context = androidx.compose.ui.platform.LocalContext.current
    val today = normalizeTimelineDate(Date())
    val isToday = date.time == today.time
    // iOS only creates a live "now" row for a confirmed stay or established
    // moving evidence. A just-started Android service reports speed 0 while
    // it gathers its first points; that is neither movement nor a stay.
    val isConfirmedMoving = (trackingState as? LocationTrackingService.TrackingState.Tracking)
        ?.speed
        ?.let { it > 0.5 } == true
    val shouldShowCurrentStay = isToday && isTrackingEnabled &&
        (trackingState is LocationTrackingService.TrackingState.OngoingStay || isConfirmedMoving)

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
            }
        } else {
            // Keep the live status at "now", rather than always appending it
            // after future plans. This is how the iOS mixed timeline preserves
            // the meaning of upcoming scheduled items.
            var currentStayInserted = false
            val now = Date()
            items.forEachIndexed { index, item ->
                if (shouldShowCurrentStay && !currentStayInserted && item.startTime.after(now)) {
                    CurrentStayTimelineRow(
                        trackingState = trackingState,
                        places = allPlaces,
                        onPlaceSelected = { placeID, placeName ->
                            LocationTrackingService.setOngoingPlace(context, placeID, placeName)
                        }
                    )
                    currentStayInserted = true
                }
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
            if (shouldShowCurrentStay && !currentStayInserted) {
                CurrentStayTimelineRow(
                    trackingState = trackingState,
                    places = allPlaces,
                    onPlaceSelected = { placeID, placeName ->
                        LocationTrackingService.setOngoingPlace(context, placeID, placeName)
                    }
                )
            }
        }

        // When today has no persisted entries yet, the live status remains the
        // only timeline event after the onboarding/empty-state affordance.
        if (shouldShowCurrentStay && items.isEmpty()) {
            CurrentStayTimelineRow(
                trackingState = trackingState,
                places = allPlaces,
                onPlaceSelected = { placeID, placeName ->
                    LocationTrackingService.setOngoingPlace(
                        context = context,
                        placeID = placeID,
                        placeName = placeName
                    )
                }
            )
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun CurrentStayTimelineRow(
    trackingState: LocationTrackingService.TrackingState,
    places: List<com.ct106.difangke.data.db.entity.PlaceEntity>,
    onPlaceSelected: (placeID: String?, placeName: String) -> Unit
) {
    val ongoing = trackingState as? LocationTrackingService.TrackingState.OngoingStay
    val tracking = trackingState as? LocationTrackingService.TrackingState.Tracking
    var nearbyPlaces by remember(ongoing?.lat, ongoing?.lon) {
        mutableStateOf<List<GeocodeService.SearchResult>>(emptyList())
    }
    var isLoadingNearbyPlaces by remember(ongoing?.lat, ongoing?.lon) { mutableStateOf(false) }
    var nearbyPlacesRefresh by remember(ongoing?.lat, ongoing?.lon) { mutableIntStateOf(0) }
    var showPlacePicker by remember { mutableStateOf(false) }
    LaunchedEffect(ongoing?.lat, ongoing?.lon, places, nearbyPlacesRefresh) {
        if (ongoing == null) {
            nearbyPlaces = emptyList()
            isLoadingNearbyPlaces = false
            return@LaunchedEffect
        }
        isLoadingNearbyPlaces = true
        val savedNearby = places.filter { place ->
            if (place.isIgnored) return@filter false
            val results = FloatArray(1)
            android.location.Location.distanceBetween(
                ongoing.lat, ongoing.lon, place.latitude, place.longitude, results
            )
            results[0] <= 500f
        }.map { place ->
            GeocodeService.SearchResult(
                name = place.name,
                address = place.address ?: "已保存地点",
                latitude = place.latitude,
                longitude = place.longitude,
                isSavedPlace = true,
                placeID = place.placeID
            )
        }
        val poiResults = try {
            // Same source and radius as the existing "选择正确地点" picker.
            // This is a real nearby-POI lookup, not a list of past places.
            GeocodeService.shared.getNearbyPOIs(ongoing.lat, ongoing.lon)
        } catch (_: Exception) {
            emptyList()
        }
        nearbyPlaces = (savedNearby + poiResults).distinctBy { it.name }
        isLoadingNearbyPlaces = false
    }
    var nowMillis by remember(ongoing?.since) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(ongoing?.since) {
        while (true) {
            nowMillis = System.currentTimeMillis()
            delay(30_000L)
        }
    }
    val title = when {
        ongoing != null -> ongoing.address?.takeIf { it.isNotBlank() }?.let { "正在${it}停留" } ?: "正在此处停留"
        else -> "正在移动"
    }
    val detail = when {
        ongoing != null -> {
            val minutes = ((nowMillis - ongoing.since.time).coerceAtLeast(0L) / 60_000L)
            if (minutes < 60) "已停留 ${minutes} 分钟" else "已停留 ${minutes / 60} 小时 ${minutes % 60} 分"
        }
        tracking != null -> String.format(Locale.CHINA, "当前速度 %.1f 千米/小时", tracking.speed * 3.6)
        else -> "正在更新位置"
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(54.dp)) {
            val pulse = rememberInfiniteTransition(label = "current_stay_pulse")
            val alpha by pulse.animateFloat(
                initialValue = 0.45f,
                targetValue = 0f,
                animationSpec = infiniteRepeatable(tween(2_400, easing = LinearEasing), RepeatMode.Restart),
                label = "current_stay_alpha"
            )
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(32.dp)) {
                Box(Modifier.size(28.dp).background(MaterialTheme.colorScheme.primary.copy(alpha = alpha), CircleShape))
                Box(Modifier.size(10.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
            }
            Box(Modifier.width(1.5.dp).height(24.dp).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)))
        }
        Column(modifier = Modifier.weight(1f).padding(start = 2.dp, top = 4.dp, bottom = 12.dp)) {
            if (ongoing != null) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.clickable { showPlacePicker = true }
                )
            } else {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(3.dp))
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
            SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(nowMillis)),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }

    if (showPlacePicker && ongoing != null) {
        NearbyPlacePickerSheet(
            latitude = ongoing.lat,
            longitude = ongoing.lon,
            savedPlaces = places,
            onDismiss = { showPlacePicker = false },
            onSelect = { place ->
                showPlacePicker = false
                onPlaceSelected(place.placeID, place.name)
            }
        )
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
    
    val today = normalizeTimelineDate(Date())
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
            if (filteredItems.isNotEmpty()) {
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
