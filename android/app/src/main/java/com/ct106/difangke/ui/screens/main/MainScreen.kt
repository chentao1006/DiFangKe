package com.ct106.difangke.ui.screens.main

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TimelineItem
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.screens.detail.AddImportantPlaceSheet
import com.ct106.difangke.ui.screens.detail.FootprintDetailContent
import com.ct106.difangke.ui.screens.detail.FootprintSplitSheet
import com.ct106.difangke.ui.screens.detail.TransportDetailContent
import com.ct106.difangke.ui.screens.detail.TransportSplitSheet
import com.ct106.difangke.ui.share.ShareCardPreviewDialog
import com.ct106.difangke.ui.share.ShareCardRequest
import com.ct106.difangke.ui.share.ShareRangePickerDialog
import com.ct106.difangke.ui.shared.TimelineEditActions
import com.ct106.difangke.ui.theme.DfkAccent
import com.ct106.difangke.viewmodel.MainViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

/** iOS `collapsedTimelineDetentHeight`. */
private val CollapsedSheetHeight = 76.dp

/** iOS ContinuousTimelineView.timelineVisibleDateBatchSize. */
private const val TIMELINE_DATE_BATCH_SIZE = 30

private enum class SheetDetent { COLLAPSED, MEDIUM, LARGE }

/**
 * iOS TimelineView → ContinuousTimelineView: a full-screen map canvas with the
 * continuous, multi-day timeline in a draggable sheet over it. Tapping a row or
 * a map pin selects it: the map focuses that item and its detail opens above
 * the timeline, exactly like the iOS footprint / transport modal sheets.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = androidx.lifecycle.viewmodel.compose.viewModel(),
    initialDate: Date? = null,
    onNavigateToHistory: (Date) -> Unit,
    onNavigateToStatistics: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToMap: (Date?) -> Unit,
    onNavigateToDetail: (String) -> Unit,
    onNavigateToRawPoints: (Date) -> Unit,
    onNavigateToPlaces: () -> Unit
) {
    val context = LocalContext.current
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()

    // ── Location permission flow (iOS LocationSettingsAlertModifier) ─────────
    val permissionsToRequest = remember {
        buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }.toTypedArray()
    }
    var hasPermissionState by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED)
    }
    var showLocationSettingsAlert by remember { mutableStateOf(false) }
    var showBackgroundRationale by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { perms ->
        val fineGranted = perms[Manifest.permission.ACCESS_FINE_LOCATION] == true
        showLocationSettingsAlert = !fineGranted
        if (fineGranted) {
            hasPermissionState = true
            if (isTrackingEnabled) LocationTrackingService.start(context)
        }
    }
    val backgroundLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted && isTrackingEnabled) LocationTrackingService.start(context)
    }

    fun openAppSettings() {
        context.startActivity(
            android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", context.packageName, null)
            )
        )
    }

    // Returning from Android's Settings does not recreate this composable;
    // refresh the live permission state on resume (iOS scenePhase .active).
    val lifecycleOwner = context.findComponentActivity()
    if (lifecycleOwner != null) {
        DisposableEffect(lifecycleOwner, context) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) {
                    hasPermissionState = ContextCompat.checkSelfPermission(
                        context, Manifest.permission.ACCESS_FINE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    if (hasPermissionState) showLocationSettingsAlert = false
                }
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
        }
    }

    LaunchedEffect(isTrackingEnabled, hasPermissionState) {
        if (!isTrackingEnabled) return@LaunchedEffect
        if (!hasPermissionState) {
            launcher.launch(permissionsToRequest)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val hasBackground = ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            if (!hasBackground) showBackgroundRationale = true else LocationTrackingService.start(context)
        } else {
            LocationTrackingService.start(context)
        }
    }

    ContinuousTimelineScreen(
        viewModel = viewModel,
        initialDate = initialDate,
        onNavigateToHistory = onNavigateToHistory,
        onNavigateToSettings = onNavigateToSettings,
        onNavigateToRawPoints = onNavigateToRawPoints,
        onNavigateToPlaces = onNavigateToPlaces
    )

    if (showBackgroundRationale) {
        AlertDialog(
            onDismissRequest = { showBackgroundRationale = false },
            title = { Text("需要后台定位权限") },
            text = { Text("为了在您关闭屏幕或使用其他应用时持续记录足迹，请在随后的系统中选择“始终允许”定位权限。") },
            confirmButton = {
                Button(onClick = {
                    showBackgroundRationale = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) openAppSettings()
                    else backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                }) { Text("去设置") }
            },
            dismissButton = { TextButton(onClick = { showBackgroundRationale = false }) { Text("取消") } }
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
                    openAppSettings()
                }) { Text("前往系统设置") }
            },
            dismissButton = { TextButton(onClick = { showLocationSettingsAlert = false }) { Text("稍后") } }
        )
    }
}

private tailrec fun Context.findComponentActivity(): ComponentActivity? = when (this) {
    is ComponentActivity -> this
    is ContextWrapper -> baseContext.findComponentActivity()
    else -> null
}

/** Pending confirmation dialogs (iOS footprintPendingDeletion / …MergeCandidate). */
private sealed class PendingAction {
    data class DeleteFootprint(val id: String) : PendingAction()
    data class DeleteTransport(val id: String) : PendingAction()
    data class IgnoreFootprint(val id: String) : PendingAction()
    data class MergeFootprints(val candidate: MainViewModel.FootprintMergeCandidate, val message: String) : PendingAction()
    data class MergeTransports(val candidate: MainViewModel.TransportMergeCandidate, val message: String) : PendingAction()
}

/** Editing sheets opened from the timeline context menu. */
private sealed class EditSheet {
    data class SplitFootprint(val footprint: FootprintEntity) : EditSheet()
    data class SplitTransport(val transport: TransportRecordEntity) : EditSheet()
    data class ImportantPlace(val footprint: FootprintEntity) : EditSheet()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ContinuousTimelineScreen(
    viewModel: MainViewModel,
    initialDate: Date?,
    onNavigateToHistory: (Date) -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToRawPoints: (Date) -> Unit,
    onNavigateToPlaces: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val availableDates by viewModel.availableDates.collectAsState()
    val activityTypes by viewModel.activityTypes.collectAsState()
    val allPlaces by viewModel.allPlaces.collectAsState()
    val trackingState by viewModel.trackingState.collectAsState()
    val isTrackingEnabled by viewModel.isTrackingEnabled.collectAsState()
    val initialLoadCompleted by viewModel.initialTimelineLoadCompleted.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()

    val today = normalizeTimelineDate(Date())
    var activeDate by remember { mutableStateOf(today) }
    var visibleDates by remember { mutableStateOf(setOf(today)) }
    var headerDates by remember { mutableStateOf(listOf(today)) }
    var loadedDateCount by remember { mutableIntStateOf(TIMELINE_DATE_BATCH_SIZE) }
    var scrollTarget by remember { mutableStateOf<Date?>(null) }
    var scrollRequest by remember { mutableIntStateOf(0) }

    var selection by remember { mutableStateOf<TimelineSelection?>(null) }
    var pendingAction by remember { mutableStateOf<PendingAction?>(null) }
    var editSheet by remember { mutableStateOf<EditSheet?>(null) }
    var showCalendar by remember { mutableStateOf(false) }
    var showRebuildAlert by remember { mutableStateOf(false) }
    var shareRequest by remember { mutableStateOf<ShareCardRequest?>(null) }
    var showShareRangePicker by remember { mutableStateOf(false) }
    var showArrivalConfirmation by remember { mutableStateOf(false) }

    val prefs = remember { context.getSharedPreferences("dfk_prefs", Context.MODE_PRIVATE) }
    var isImportantPlaceGuideDismissed by remember {
        mutableStateOf(prefs.getBoolean("isImportantPlaceGuideDismissed", false))
    }

    // iOS timelineDates: every loadable day plus today, oldest first.
    val allTimelineDates = remember(availableDates, today.time) {
        (availableDates + today).map(::normalizeTimelineDate)
            .filter { !it.after(today) }
            .distinctBy { it.time }
            .sortedBy { it.time }
    }
    val timelineDates = remember(allTimelineDates, loadedDateCount) { allTimelineDates.takeLast(loadedDateCount) }
    val canLoadEarlier = allTimelineDates.size > timelineDates.size

    fun scrollToDate(date: Date) {
        val target = normalizeTimelineDate(date)
        val index = allTimelineDates.indexOfFirst { it.time == target.time }
        if (index >= 0) {
            val needed = allTimelineDates.size - index
            if (needed > loadedDateCount) {
                loadedDateCount = ((needed + TIMELINE_DATE_BATCH_SIZE - 1) / TIMELINE_DATE_BATCH_SIZE) * TIMELINE_DATE_BATCH_SIZE
            }
        }
        activeDate = target
        headerDates = listOf(target)
        visibleDates = setOf(target)
        scrollTarget = target
        scrollRequest += 1
    }

    LaunchedEffect(initialDate, initialLoadCompleted) {
        if (initialDate != null && initialLoadCompleted) scrollToDate(initialDate)
    }

    // iOS scheduleMidnightTimelineRefresh: today changes at midnight.
    LaunchedEffect(today.time) {
        val nextMidnight = Calendar.getInstance().apply {
            time = today; add(Calendar.DAY_OF_YEAR, 1)
        }.time.time
        delay((nextMidnight - System.currentTimeMillis()).coerceAtLeast(1_000L) + 500L)
        viewModel.refresh()
    }

    fun select(item: TimelineItem) {
        selection = when (item) {
            is TimelineItem.FootprintItem -> TimelineSelection.Footprint(item.footprint.footprintID)
            is TimelineItem.TransportItem -> TimelineSelection.Transport(item.transport.recordID)
        }
    }

    fun rowActions(item: TimelineItem): RowActions = RowActions(
        onTap = { select(item) },
        onMerge = {
            scope.launch {
                when (item) {
                    is TimelineItem.FootprintItem -> viewModel.footprintMergeCandidate(item.footprint.footprintID)?.let {
                        pendingAction = PendingAction.MergeFootprints(
                            it, TimelineEditActions.footprintMergeMessage(it.first, it.second, allPlaces)
                        )
                    }
                    is TimelineItem.TransportItem -> viewModel.transportMergeCandidate(item.transport.recordID)?.let {
                        pendingAction = PendingAction.MergeTransports(
                            it, TimelineEditActions.transportMergeMessage(it.first, it.second)
                        )
                    }
                }
            }
        },
        onSplit = {
            scope.launch {
                editSheet = when (item) {
                    is TimelineItem.FootprintItem ->
                        viewModel.storedFootprint(item.footprint.footprintID)?.let { EditSheet.SplitFootprint(it) }
                    is TimelineItem.TransportItem ->
                        viewModel.storedTransport(item.transport.recordID)?.let { EditSheet.SplitTransport(it) }
                }
            }
        },
        onToggleFavorite = {
            (item as? TimelineItem.FootprintItem)?.let { viewModel.toggleFavorite(it.footprint.footprintID) }
        },
        onSetImportantPlace = {
            val fp = (item as? TimelineItem.FootprintItem)?.footprint ?: return@RowActions
            scope.launch {
                editSheet = EditSheet.ImportantPlace(viewModel.storedFootprint(fp.footprintID) ?: fp)
            }
        },
        onIgnore = {
            (item as? TimelineItem.FootprintItem)?.let { pendingAction = PendingAction.IgnoreFootprint(it.footprint.footprintID) }
        },
        onDelete = {
            pendingAction = when (item) {
                is TimelineItem.FootprintItem -> PendingAction.DeleteFootprint(item.footprint.footprintID)
                is TimelineItem.TransportItem -> PendingAction.DeleteTransport(item.transport.recordID)
            }
        }
    )

    BoxWithConstraints(Modifier.fillMaxSize().background(if (isSystemInDarkTheme()) Color.Black else Color(0xFFE7EEF0))) {
        val density = LocalDensity.current
        val topMargin = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + 12.dp
        val collapsedPx = with(density) { CollapsedSheetHeight.toPx() }
        val mediumPx = with(density) { (maxHeight * 0.5f).toPx() }
        val largePx = with(density) { (maxHeight - topMargin).toPx() }
        var detent by remember { mutableStateOf(SheetDetent.MEDIUM) }
        var dragHeightPx by remember { mutableStateOf<Float?>(null) }
        fun detentPx(d: SheetDetent) = when (d) {
            SheetDetent.COLLAPSED -> collapsedPx
            SheetDetent.MEDIUM -> mediumPx
            SheetDetent.LARGE -> largePx
        }
        val animatedHeightPx by animateFloatAsState(
            targetValue = detentPx(detent),
            animationSpec = tween(durationMillis = 260, easing = FastOutSlowInEasing),
            label = "timeline_sheet_detent"
        )
        val sheetHeightPx = dragHeightPx ?: animatedHeightPx
        val sheetHeight = with(density) { sheetHeightPx.toDp() }
        val isCollapsed = detent == SheetDetent.COLLAPSED && dragHeightPx == null

        // iOS handleSelectedFootprintChange: selecting an item parks the
        // timeline at half height so the focused map stays visible.
        LaunchedEffect(selection) {
            if (selection != null) detent = SheetDetent.MEDIUM
        }

        TimelineMapPane(
            modifier = Modifier.fillMaxSize(),
            selectedDate = activeDate,
            visibleDates = visibleDates,
            selection = selection,
            viewModel = viewModel,
            activityTypes = activityTypes,
            allPlaces = allPlaces,
            // iOS: the locate button rides 48pt above the sheet until large.
            sheetHeight = if (detent == SheetDetent.LARGE) 4.dp else sheetHeight + 36.dp,
            bottomPaddingPx = sheetHeightPx.toInt(),
            onUserPan = {
                // iOS handleMapInteraction: touching the map minimizes the timeline.
                if (selection == null && detent != SheetDetent.COLLAPSED) detent = SheetDetent.COLLAPSED
            },
            onSelect = { selection = it }
        )

        Surface(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(sheetHeight),
            shape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp),
            color = if (isSystemInDarkTheme()) Color(0xFF1C1C1E) else Color(0xFFF2F2F7),
            contentColor = MaterialTheme.colorScheme.onSurface,
            shadowElevation = 8.dp
        ) {
            Box(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize()) {
                    SheetDragHandle(
                        onDrag = { delta ->
                            val current = dragHeightPx ?: detentPx(detent)
                            dragHeightPx = (current - delta).coerceIn(collapsedPx, largePx)
                        },
                        onDragEnd = {
                            val h = dragHeightPx ?: detentPx(detent)
                            detent = SheetDetent.entries.minBy { kotlin.math.abs(detentPx(it) - h) }
                            dragHeightPx = null
                        }
                    )
                    TimelineSheetHeader(
                        headerDates = headerDates,
                        viewModel = viewModel,
                        onShowHistory = { onNavigateToHistory(activeDate) },
                        onShowCalendar = { showCalendar = true },
                        onViewRawPoints = { onNavigateToRawPoints(activeDate) },
                        onRebuild = { showRebuildAlert = true },
                        onShareCurrentDate = { shareRequest = ShareCardRequest.Timeline(activeDate, activeDate) },
                        onShareRange = { showShareRangePicker = true },
                        onShowSettings = onNavigateToSettings
                    )
                    // iOS keeps the scroll view mounted while collapsed so its
                    // offset survives re-expansion, but renders it transparent.
                    Box(
                        Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .alpha(if (isCollapsed) 0f else 1f)
                    ) {
                        ContinuousTimelineList(
                            timelineDates = timelineDates,
                            canLoadEarlier = canLoadEarlier,
                            initialLoadCompleted = initialLoadCompleted,
                            viewModel = viewModel,
                            trackingState = trackingState,
                            isTrackingEnabled = isTrackingEnabled,
                            activityTypes = activityTypes,
                            allPlaces = allPlaces,
                            scrollTarget = scrollTarget,
                            scrollRequest = scrollRequest,
                            interactive = !isCollapsed,
                            showsImportantPlaceGuide = !isImportantPlaceGuideDismissed && allPlaces.none { it.isUserDefined },
                            onLoadEarlier = { loadedDateCount += TIMELINE_DATE_BATCH_SIZE },
                            onImportPhotos = { onNavigateToHistory(today) },
                            onViewportChanged = { visible, header, bottom ->
                                if (visible.isNotEmpty()) visibleDates = visible
                                if (header.isNotEmpty()) headerDates = header
                                if (bottom != null) activeDate = bottom
                            },
                            rowActions = ::rowActions,
                            onRequestArrival = { showArrivalConfirmation = true },
                            onAddImportantPlace = onNavigateToPlaces,
                            onDismissImportantPlaceGuide = {
                                isImportantPlaceGuideDismissed = true
                                prefs.edit().putBoolean("isImportantPlaceGuideDismissed", true).apply()
                            }
                        )
                        if (!isCollapsed && activeDate.before(today)) {
                            ReturnToTodayButton(
                                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp),
                                onClick = { scrollToDate(today) }
                            )
                        }
                    }
                }
                if (!initialLoadCompleted) InitialTimelineLoadingOverlay()
            }
        }

        if (isRefreshing) ResettingIndicator()
    }

    // ── Selected item detail (iOS FootprintModalView / TransportModalView) ──
    selection?.let { current ->
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
        ModalBottomSheet(
            onDismissRequest = { selection = null },
            sheetState = sheetState,
            scrimColor = Color.Transparent,
            dragHandle = { BottomSheetDefaults.DragHandle() }
        ) {
            when (current) {
                is TimelineSelection.Footprint -> FootprintDetailContent(
                    footprintId = current.id,
                    onDismiss = { selection = null },
                    modifier = Modifier.fillMaxWidth(),
                    showMap = false
                )
                is TimelineSelection.Transport -> TransportDetailContent(
                    transportId = current.id,
                    onDismiss = { selection = null },
                    modifier = Modifier.fillMaxWidth(),
                    showMap = false
                )
            }
        }
    }

    when (val sheet = editSheet) {
        is EditSheet.SplitFootprint -> FootprintSplitSheet(
            footprint = sheet.footprint,
            activities = activityTypes,
            onDismiss = { editSheet = null }
        ) { split, first, second ->
            viewModel.splitFootprint(sheet.footprint, split, first, second)
            editSheet = null
        }
        is EditSheet.SplitTransport -> TransportSplitSheet(
            transport = sheet.transport,
            onDismiss = { editSheet = null }
        ) { split ->
            viewModel.splitTransport(sheet.transport, split)
            editSheet = null
        }
        is EditSheet.ImportantPlace -> AddImportantPlaceSheet(
            footprint = sheet.footprint,
            onDismiss = { editSheet = null }
        ) { name, lat, lon, radius, address ->
            viewModel.addImportantPlace(sheet.footprint, name, lat, lon, radius, address)
            editSheet = null
        }
        null -> Unit
    }

    pendingAction?.let { action -> PendingActionDialog(action, viewModel, onDone = { pendingAction = null }) }

    if (showRebuildAlert) {
        AlertDialog(
            onDismissRequest = { showRebuildAlert = false },
            title = { Text("重新生成本日数据") },
            text = { Text("这将删除已手动修正或确认的足迹记录，并基于原始轨迹点重新分析生成时间线。") },
            confirmButton = {
                TextButton(onClick = {
                    showRebuildAlert = false
                    viewModel.rebuildTimeline(activeDate)
                }) { Text("确定重新生成", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { showRebuildAlert = false }) { Text("取消") } }
        )
    }

    if (showCalendar) {
        CalendarSelectionDialog(
            selectedDate = activeDate,
            availableDates = allTimelineDates,
            onDateSelected = { date ->
                showCalendar = false
                scrollToDate(date)
            },
            onDismiss = { showCalendar = false }
        )
    }

    if (showShareRangePicker) {
        ShareRangePickerDialog(
            initialDate = activeDate,
            onPick = { start, end ->
                showShareRangePicker = false
                shareRequest = ShareCardRequest.Timeline(start, end)
            },
            onDismiss = { showShareRangePicker = false }
        )
    }
    shareRequest?.let { ShareCardPreviewDialog(it, onDismiss = { shareRequest = null }) }

    if (showArrivalConfirmation) {
        ArrivalConfirmationDialog(
            onDismiss = { showArrivalConfirmation = false },
            onConfirm = {
                showArrivalConfirmation = false
                requestConfirmArrival(context)
            }
        )
    }
}

@Composable
private fun PendingActionDialog(action: PendingAction, viewModel: MainViewModel, onDone: () -> Unit) {
    val title: String
    val message: String
    val confirm: String
    val destructive: Boolean
    val run: () -> Unit
    when (action) {
        is PendingAction.DeleteFootprint -> {
            title = "确认删除足迹？"; message = "删除后，该足迹将不再出现在时间轴上。"
            confirm = "删除"; destructive = true
            run = { viewModel.deleteFootprint(action.id) }
        }
        is PendingAction.DeleteTransport -> {
            title = "确认删除此交通记录？"; message = "删除后该段交通将从时间轴中隐藏。"
            confirm = "删除"; destructive = true
            run = { viewModel.deleteTransport(action.id) }
        }
        is PendingAction.IgnoreFootprint -> {
            title = "忽略并删除在此地点的足迹？"
            message = "添加为忽略地点后，以后将不再记录此处的足迹，且现有的同地点足迹也将被隐藏。"
            confirm = "忽略并删除"; destructive = true
            run = { viewModel.ignoreFootprintLocation(action.id) }
        }
        is PendingAction.MergeFootprints -> {
            title = "合并相邻足迹？"; message = action.message
            confirm = "合并"; destructive = false
            run = { viewModel.mergeFootprints(action.candidate) }
        }
        is PendingAction.MergeTransports -> {
            title = "合并相邻交通？"; message = action.message
            confirm = "合并"; destructive = false
            run = { viewModel.mergeTransports(action.candidate) }
        }
    }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = { run(); onDone() }) {
                Text(confirm, color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("取消") } }
    )
}

@Composable
private fun SheetDragHandle(onDrag: (Float) -> Unit, onDragEnd: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .pointerInput(Unit) {
                detectVerticalDragGestures(
                    onVerticalDrag = { change, dragAmount ->
                        change.consume()
                        onDrag(dragAmount)
                    },
                    onDragEnd = onDragEnd,
                    onDragCancel = onDragEnd
                )
            }
            .padding(top = 6.dp, bottom = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier
                .size(width = 36.dp, height = 5.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.32f))
        )
    }
}

/** iOS headerToolbar: history · date title (calendar / context menu) · share · settings. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TimelineSheetHeader(
    headerDates: List<Date>,
    viewModel: MainViewModel,
    onShowHistory: () -> Unit,
    onShowCalendar: () -> Unit,
    onViewRawPoints: () -> Unit,
    onRebuild: () -> Unit,
    onShareCurrentDate: () -> Unit,
    onShareRange: () -> Unit,
    onShowSettings: () -> Unit
) {
    var showDateMenu by remember { mutableStateOf(false) }
    var showShareMenu by remember { mutableStateOf(false) }
    val displayDates = headerDates.sortedBy { it.time }
    val first = displayDates.first()
    val last = displayDates.last()
    val isSingleDay = isSameDay(first, last)
    val dateSet = remember(displayDates) { displayDates.toSet() }
    val headerItems by remember(dateSet) { viewModel.getTimelineItemsForDates(dateSet) }
        .collectAsState(initial = emptyList())
    val cityNames = remember(headerItems) {
        headerItems.filterIsInstance<TimelineItem.FootprintItem>()
            .sortedBy { it.footprint.startTime }
            .mapNotNull { it.footprint.cityName?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
    }
    val title = if (isSingleDay) timelineDateTitle(first) else "${timelineDateTitle(first)}-${timelineDateTitle(last)}"
    val baseSecondary = if (isSingleDay) timelineDateSecondaryTitle(first) else "${weekdayText(first)}-${weekdayText(last)}"
    val secondary = if (cityNames.isEmpty()) baseSecondary else "$baseSecondary · ${cityNames.joinToString("、")}"
    // iOS limitedSecondaryHeader: 16 characters, then an ellipsis.
    val limitedSecondary = if (secondary.length > 16) secondary.take(16) + "…" else secondary

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp)
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onShowHistory) {
            Icon(Icons.Default.EventRepeat, contentDescription = "往昔足迹")
        }
        Spacer(Modifier.weight(1f))
        Box {
            Column(
                modifier = Modifier
                    .widthIn(min = 132.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .combinedClickable(onClick = onShowCalendar, onLongClick = { showDateMenu = true })
                    .padding(vertical = 4.dp, horizontal = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        Icons.Default.UnfoldMore,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    )
                }
                Text(
                    limitedSecondary,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1
                )
            }
            DropdownMenu(expanded = showDateMenu, onDismissRequest = { showDateMenu = false }) {
                DropdownMenuItem(
                    text = { Text("查看所有轨迹点") },
                    leadingIcon = { Icon(Icons.Default.Sensors, null) },
                    onClick = { showDateMenu = false; onViewRawPoints() }
                )
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("重新生成本日数据", color = MaterialTheme.colorScheme.error) },
                    leadingIcon = { Icon(Icons.Default.Restore, null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { showDateMenu = false; onRebuild() }
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Box {
            IconButton(onClick = { showShareMenu = true }) {
                Icon(Icons.Default.IosShare, contentDescription = "分享")
            }
            DropdownMenu(expanded = showShareMenu, onDismissRequest = { showShareMenu = false }) {
                DropdownMenuItem(
                    text = { Text("分享当前日期足迹") },
                    leadingIcon = { Icon(Icons.Default.Route, null) },
                    onClick = { showShareMenu = false; onShareCurrentDate() }
                )
                DropdownMenuItem(
                    text = { Text("选择日期范围分享") },
                    leadingIcon = { Icon(Icons.Default.DateRange, null) },
                    onClick = { showShareMenu = false; onShareRange() }
                )
            }
        }
        IconButton(onClick = onShowSettings) {
            Icon(Icons.Outlined.Settings, contentDescription = "设置")
        }
    }
}

private fun dayKey(date: Date): String = "day_${date.time}"

/**
 * iOS ContinuousTimelineSheet.mainScrollView: oldest day at the top, today at
 * the bottom, the list resting on its bottom edge. Implemented as a reversed
 * LazyColumn over newest-first days so the bottom anchor is native.
 */
@Composable
private fun ContinuousTimelineList(
    timelineDates: List<Date>,
    canLoadEarlier: Boolean,
    initialLoadCompleted: Boolean,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    scrollTarget: Date?,
    scrollRequest: Int,
    interactive: Boolean,
    showsImportantPlaceGuide: Boolean,
    onLoadEarlier: () -> Unit,
    onImportPhotos: () -> Unit,
    onViewportChanged: (visible: Set<Date>, header: List<Date>, bottom: Date?) -> Unit,
    rowActions: (TimelineItem) -> RowActions,
    onRequestArrival: () -> Unit,
    onAddImportantPlace: () -> Unit,
    onDismissImportantPlaceGuide: () -> Unit
) {
    val listState = rememberLazyListState()
    val newestFirst = remember(timelineDates) { timelineDates.reversed() }
    val currentNewestFirst by rememberUpdatedState(newestFirst)
    var isProgrammaticScroll by remember { mutableStateOf(false) }

    LaunchedEffect(scrollRequest) {
        val target = scrollTarget ?: return@LaunchedEffect
        // Wait until a newly loaded batch containing the target is composed.
        val index = withTimeoutOrNull(2_000L) {
            snapshotFlow { currentNewestFirst.indexOfFirst { it.time == target.time } }.first { it >= 0 }
        } ?: return@LaunchedEffect
        isProgrammaticScroll = true
        try {
            // Reversed layout: scrolling to the item rests the day's bottom
            // on the viewport bottom (iOS proxy.scrollTo(.date, anchor: .bottom)).
            if (kotlin.math.abs(listState.firstVisibleItemIndex - index) > 6) listState.scrollToItem(index)
            else listState.animateScrollToItem(index)
        } finally {
            isProgrammaticScroll = false
        }
    }

    LaunchedEffect(listState) {
        snapshotFlow { viewportDates(listState) }
            .distinctUntilChanged()
            .collect { (visible, header, bottom) ->
                if (!isProgrammaticScroll) onViewportChanged(visible, header, bottom)
            }
    }

    LazyColumn(
        state = listState,
        reverseLayout = true,
        userScrollEnabled = interactive,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 30.dp, bottom = 128.dp)
    ) {
        items(newestFirst.size, key = { dayKey(newestFirst[it]) }) { index ->
            val date = newestFirst[index]
            val olderDate = newestFirst.getOrNull(index + 1)
            Column(Modifier.fillMaxWidth()) {
                if (olderDate != null) {
                    val gapDays = ((date.time - olderDate.time) / 86_400_000L).toInt()
                    if (gapDays > 1) TimelineDateGapConnector(skippedDays = gapDays - 1)
                }
                TimelineDaySection(
                    date = date,
                    viewModel = viewModel,
                    trackingState = trackingState,
                    isTrackingEnabled = isTrackingEnabled,
                    activityTypes = activityTypes,
                    allPlaces = allPlaces,
                    showsImportantPlaceGuide = showsImportantPlaceGuide,
                    rowActions = rowActions,
                    onRequestArrival = onRequestArrival,
                    onAddImportantPlace = onAddImportantPlace,
                    onDismissImportantPlaceGuide = onDismissImportantPlaceGuide
                )
            }
        }
        item(key = "timeline_top") {
            if (initialLoadCompleted) {
                if (canLoadEarlier) {
                    TimelineLoadMoreButton(title = "查看更早的足迹", isLoading = false, onClick = onLoadEarlier)
                } else {
                    TimelineLoadMoreButton(title = "从照片导入足迹", isLoading = false, onClick = onImportPhotos)
                }
            }
        }
    }
}

private data class ViewportDates(val visible: Set<Date>, val header: List<Date>, val bottom: Date?)

/** iOS significantVisibleDates / bottomVisibleDate over the reversed list. */
private fun viewportDates(listState: LazyListState): ViewportDates {
    val info = listState.layoutInfo
    val viewportStart = info.viewportStartOffset
    val viewportEnd = info.viewportEndOffset
    val viewportHeight = (viewportEnd - viewportStart).coerceAtLeast(1)
    val days = info.visibleItemsInfo.mapNotNull { item ->
        val key = item.key as? String ?: return@mapNotNull null
        val ms = key.removePrefix("day_").takeIf { it != key }?.toLongOrNull() ?: return@mapNotNull null
        val visible = (minOf(item.offset + item.size, viewportEnd) - maxOf(item.offset, viewportStart)).coerceAtLeast(0)
        Triple(Date(ms), visible, item.size)
    }
    if (days.isEmpty()) return ViewportDates(emptySet(), emptyList(), null)
    val significant = days.filter { (_, visible, size) ->
        visible >= viewportHeight * 0.3f || (size > 0 && visible >= size * 0.6f)
    }.map { it.first }
    // First visible item of a reversed list is the bottom-most day.
    val bottom = days.firstOrNull { it.second > 0 }?.first
    val header = significant.ifEmpty { listOfNotNull(bottom) }
    return ViewportDates(days.filter { it.second > 0 }.map { it.first }.toSet(), header, bottom)
}

/** iOS ContinuousTimelineSheet.timelineDay(for:). */
@Composable
private fun TimelineDaySection(
    date: Date,
    viewModel: MainViewModel,
    trackingState: LocationTrackingService.TrackingState,
    isTrackingEnabled: Boolean,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    showsImportantPlaceGuide: Boolean,
    rowActions: (TimelineItem) -> RowActions,
    onRequestArrival: () -> Unit,
    onAddImportantPlace: () -> Unit,
    onDismissImportantPlaceGuide: () -> Unit
) {
    val items by remember(date.time) { viewModel.getTimelineItems(date) }.collectAsState(initial = emptyList())
    val points by remember(date.time) { viewModel.getPointsCount(date) }.collectAsState(initial = 0)
    val sortedItems = remember(items) { items.sortedBy { it.startTime } }
    val isToday = isSameDay(date, Date())

    // Past days with raw points but no timeline yet are built on demand.
    LaunchedEffect(date.time, items.isEmpty(), points) {
        if (!isToday && items.isEmpty() && points > 0) {
            delay(1000)
            viewModel.ensureTimelineForDate(date)
        }
    }

    // iOS CurrentStayTimelineCard only renders with a live status timestamp.
    val showsCurrentStay = isToday && isTrackingEnabled && when (trackingState) {
        is LocationTrackingService.TrackingState.OngoingStay -> true
        is LocationTrackingService.TrackingState.Tracking -> trackingState.isMoving
        LocationTrackingService.TrackingState.Idle -> false
    }
    val now = Date()
    val currentStayIndex = if (showsCurrentStay) {
        sortedItems.indexOfFirst { it.startTime.after(now) }.let { if (it < 0) sortedItems.size else it }
    } else -1

    DayTimelineContent(
        date = date,
        items = sortedItems,
        viewModel = viewModel,
        activityTypes = activityTypes,
        allPlaces = allPlaces,
        lastItemUsesMinimumSpacing = showsCurrentStay && lastFootprintIsCurrentStay(sortedItems, trackingState, allPlaces),
        rowActions = rowActions,
        insertAt = currentStayIndex
    ) {
        CurrentStayTimelineRow(
            trackingState = trackingState,
            places = allPlaces,
            onRequestArrival = onRequestArrival
        )
        if (showsImportantPlaceGuide) {
            ImportantPlaceGuide(onAdd = onAddImportantPlace, onDismiss = onDismissImportantPlaceGuide)
        }
    }
}

/** iOS shouldUseMinimumSpacingBeforeCurrentStay. */
private fun lastFootprintIsCurrentStay(
    items: List<TimelineItem>,
    trackingState: LocationTrackingService.TrackingState,
    places: List<PlaceEntity>
): Boolean {
    val footprint = (items.lastOrNull() as? TimelineItem.FootprintItem)?.footprint ?: return false
    val stay = trackingState as? LocationTrackingService.TrackingState.OngoingStay ?: return false
    val stayPlaceID = places
        .filter { it.isUserDefined && !it.isIgnored }
        .firstOrNull { place ->
            val r = FloatArray(1)
            android.location.Location.distanceBetween(stay.lat, stay.lon, place.latitude, place.longitude, r)
            r[0] <= maxOf(place.radius, 30f)
        }?.placeID
    if (footprint.placeID != null && footprint.placeID == stayPlaceID) return true
    val r = FloatArray(1)
    android.location.Location.distanceBetween(
        stay.lat, stay.lon,
        footprint.representativeLat(), footprint.representativeLon(), r
    )
    return r[0] <= 80f
}

private fun FootprintEntity.representativeLat(): Double = runCatching {
    org.json.JSONArray(latitudeJson).getDouble(0)
}.getOrDefault(Double.NaN)

private fun FootprintEntity.representativeLon(): Double = runCatching {
    org.json.JSONArray(longitudeJson).getDouble(0)
}.getOrDefault(Double.NaN)

/** iOS canMergeAdjacentFootprintSnapshots / canMergeAdjacentTransportSnapshots. */
private fun canMergeAdjacent(items: List<TimelineItem>, index: Int): Boolean {
    val item = items[index]
    fun sameDay(a: Date, b: Date) = isSameDay(a, b)
    fun compatible(first: TimelineItem, second: TimelineItem): Boolean = when {
        first is TimelineItem.FootprintItem && second is TimelineItem.FootprintItem -> {
            val a = first.footprint
            val b = second.footprint
            a.statusValue != "ignored" && b.statusValue != "ignored" &&
                a.footprintID != b.footprintID &&
                sameDay(a.startTime, Date(a.endTime.time - 1)) &&
                sameDay(b.startTime, Date(b.endTime.time - 1)) &&
                sameDay(a.startTime, b.startTime)
        }
        first is TimelineItem.TransportItem && second is TimelineItem.TransportItem ->
            first.transport.recordID != second.transport.recordID &&
                sameDay(first.transport.startTime, second.transport.startTime)
        else -> false
    }
    val previous = items.getOrNull(index - 1)
    val next = items.getOrNull(index + 1)
    return (previous != null && compatible(previous, item)) || (next != null && compatible(item, next))
}

/**
 * One day of the continuous timeline: dotted separator with the date label,
 * then the rows. [insertAt] places [inserted] (the live "now" row) among them.
 */
@Composable
private fun DayTimelineContent(
    date: Date,
    items: List<TimelineItem>,
    viewModel: MainViewModel,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    lastItemUsesMinimumSpacing: Boolean,
    rowActions: (TimelineItem) -> RowActions,
    insertAt: Int = -1,
    inserted: @Composable () -> Unit = {}
) {
    Column(Modifier.fillMaxWidth()) {
        TimelineDateHeader(date)
        Spacer(Modifier.height(1.dp))
        items.forEachIndexed { index, item ->
            if (index == insertAt) inserted()
            ContinuousTimelineRow(
                item = item,
                nextStartTime = items.getOrNull(index + 1)?.startTime,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                usesMinimumBottomSpacing = lastItemUsesMinimumSpacing && index == items.lastIndex,
                canMergeItem = canMergeAdjacent(items, index),
                viewModel = viewModel,
                actions = rowActions(item)
            )
        }
        if (insertAt >= items.size) inserted()
    }
}

/** iOS DottedTimelineSeparator + the date label + the line through the marker column. */
@Composable
private fun TimelineDateHeader(date: Date) {
    val separatorColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
    val lineColor = timelineLineColor()
    Box(
        Modifier
            .fillMaxWidth()
            .height(30.dp)
    ) {
        Canvas(Modifier.matchParentSize()) {
            val gutter = 16.dp.toPx()
            // The separator sits 12pt above the header (iOS .offset(y: -12)).
            val y = -12.dp.toPx() + 1.dp.toPx()
            drawLine(separatorColor, Offset(gutter, y), Offset(size.width - gutter, y), 2.dp.toPx(), StrokeCap.Round)
            val x = gutter + TimelineLayout.markerCenterX.toPx()
            drawLine(lineColor, Offset(x, 0f), Offset(x, size.height), 2.dp.toPx())
        }
        Text(
            SimpleDateFormat("M月d日", Locale.CHINA).format(date),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            modifier = Modifier
                .padding(start = 16.dp)
                .width(TimelineLayout.dateColumnWidth)
                .align(Alignment.CenterStart)
        )
    }
}

/** iOS TimelineDateGapConnector: dashed line for skipped empty days. */
@Composable
private fun TimelineDateGapConnector(skippedDays: Int) {
    val height = minOf(120, 32 + skippedDays * 14).dp
    val color = timelineLineColor()
    Canvas(Modifier.fillMaxWidth().height(height)) {
        val x = (16.dp + TimelineLayout.markerCenterX).toPx()
        drawLine(
            color = color,
            start = Offset(x, 0f),
            end = Offset(x, size.height),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 7.dp.toPx()))
        )
    }
}

/** iOS TimelineLoadMoreButton. */
@Composable
private fun TimelineLoadMoreButton(title: String, isLoading: Boolean, onClick: () -> Unit) {
    val lineColor = timelineLineColor()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(
                enabled = !isLoading,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick
            )
            .padding(vertical = 2.dp)
            .padding(start = 16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Spacer(Modifier.width(TimelineLayout.timeColumnWidth + TimelineLayout.markerSpacing))
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            DashedSegment(lineColor)
            Box(
                Modifier
                    .size(TimelineLayout.markerSize)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface)
                    .border(1.dp, lineColor, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                if (isLoading) {
                    CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
                } else {
                    Icon(Icons.Default.MoreHoriz, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                }
            }
            DashedSegment(lineColor)
        }
        Spacer(Modifier.width(TimelineLayout.markerSpacing))
        Text(
            if (isLoading) "正在加载" else title,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .border(1.dp, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.28f), RoundedCornerShape(50))
                .padding(horizontal = 10.dp, vertical = 6.dp)
        )
    }
}

@Composable
private fun DashedSegment(color: Color) {
    Canvas(Modifier.width(2.dp).height(10.dp)) {
        drawLine(
            color = color,
            start = Offset(size.width / 2, 0f),
            end = Offset(size.width / 2, size.height),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 6.dp.toPx()))
        )
    }
}

/** iOS "回到当下" capsule (returnToTodayButtonStyle). */
@Composable
private fun ReturnToTodayButton(modifier: Modifier, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = modifier.shadow(6.dp, RoundedCornerShape(50)),
        shape = RoundedCornerShape(50),
        color = DfkAccent,
        contentColor = Color.White
    ) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Default.NearMe, null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("回到当下", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
    }
}

/** iOS initialTimelineLoadingOverlay. */
@Composable
private fun InitialTimelineLoadingOverlay() {
    Box(
        Modifier
            .fillMaxSize()
            .padding(top = 64.dp)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.86f)),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            CircularProgressIndicator()
            Text("正在加载时间轴", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** iOS resettingIndicator. */
@Composable
private fun ResettingIndicator() {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(Color.DarkGray.copy(alpha = 0.85f))
                .padding(30.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            CircularProgressIndicator(color = Color.White)
            Text("正在重新生成...", color = Color.White, style = MaterialTheme.typography.titleMedium)
        }
    }
}

/**
 * A single day rendered with the continuous-timeline rows, for the History →
 * day screen. Rows open details through [onItemClick] (prefixed item IDs).
 */
@Composable
fun TimelinePage(
    date: Date,
    viewModel: MainViewModel,
    activityTypes: List<ActivityTypeEntity>,
    allPlaces: List<PlaceEntity>,
    onItemClick: (String) -> Unit
) {
    val items by remember(date.time) { viewModel.getTimelineItems(date) }.collectAsState(initial = emptyList())
    val sortedItems = remember(items) { items.sortedBy { it.startTime } }
    if (sortedItems.isEmpty()) {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text("这一天没有足迹", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 30.dp, bottom = 120.dp)) {
        item {
            DayTimelineContent(
                date = date,
                items = sortedItems,
                viewModel = viewModel,
                activityTypes = activityTypes,
                allPlaces = allPlaces,
                lastItemUsesMinimumSpacing = false,
                rowActions = { item ->
                    RowActions(
                        onTap = { onItemClick(item.id) },
                        onMerge = { onItemClick(item.id) },
                        onSplit = { onItemClick(item.id) },
                        onToggleFavorite = {
                            (item as? TimelineItem.FootprintItem)?.let { viewModel.toggleFavorite(it.footprint.footprintID) }
                        },
                        onSetImportantPlace = { onItemClick(item.id) },
                        onIgnore = {
                            (item as? TimelineItem.FootprintItem)?.let { viewModel.ignoreFootprintLocation(it.footprint.footprintID) }
                        },
                        onDelete = {
                            when (item) {
                                is TimelineItem.FootprintItem -> viewModel.deleteFootprint(item.footprint.footprintID)
                                is TimelineItem.TransportItem -> viewModel.deleteTransport(item.transport.recordID)
                            }
                        }
                    )
                }
            )
        }
    }
}

// ── Calendar (iOS MiniCalendarView popover) ────────────────────────────

@Composable
fun CalendarSelectionDialog(
    selectedDate: Date,
    availableDates: List<Date>,
    onDateSelected: (Date) -> Unit,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
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
    var currentMonth by remember {
        mutableStateOf(Calendar.getInstance().apply {
            time = selectedDate
            set(Calendar.DAY_OF_MONTH, 1)
        }.time)
    }
    val weekDays = listOf("日", "一", "二", "三", "四", "五", "六")
    val isDark = isSystemInDarkTheme()
    val primaryColor = DfkAccent
    val surfaceColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val titleColor = MaterialTheme.colorScheme.onSurface
    val secondaryTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
    val disabledTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f)
    val subtleTextColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.48f)
    val dataTextColor = MaterialTheme.colorScheme.onSurface
    fun changeMonth(delta: Int) {
        currentMonth = Calendar.getInstance().apply { time = currentMonth; add(Calendar.MONTH, delta) }.time
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
                SimpleDateFormat("yyyy年M月", Locale.CHINA).format(currentMonth),
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
        Spacer(Modifier.height(16.dp))
        Row(Modifier.fillMaxWidth()) {
            weekDays.forEach { day ->
                Text(
                    day,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall,
                    color = secondaryTextColor,
                    fontWeight = FontWeight.Bold
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        val days = remember(currentMonth) { getDaysInMonth(currentMonth) }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            days.chunked(7).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { date ->
                        if (date == null) {
                            Spacer(Modifier.weight(1f))
                        } else {
                            val isSelected = isSameDay(date, selectedDate)
                            val isToday = isSameDay(date, Date())
                            val hasData = availableDates.any { isSameDay(it, date) }
                            val isFuture = date.time > System.currentTimeMillis() + 60_000
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .aspectRatio(1f)
                                    .clip(CircleShape)
                                    .background(if (isSelected) primaryColor else Color.Transparent)
                                    .clickable(enabled = (hasData || isToday) && !isFuture) { onDateSelected(date) },
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    Calendar.getInstance().apply { time = date }.get(Calendar.DAY_OF_MONTH).toString(),
                                    color = when {
                                        isSelected -> Color.White
                                        isFuture -> disabledTextColor
                                        isToday -> primaryColor
                                        hasData -> dataTextColor
                                        else -> subtleTextColor
                                    },
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = if (isSelected || isToday) FontWeight.Bold else FontWeight.Medium
                                )
                                if (hasData && !isSelected) {
                                    Box(
                                        Modifier
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
    val firstDayOfWeek = calendar.get(Calendar.DAY_OF_WEEK) - 1
    val result = MutableList<Date?>(firstDayOfWeek) { null }
    repeat(daysInMonth) {
        result.add(calendar.time)
        calendar.add(Calendar.DAY_OF_MONTH, 1)
    }
    while (result.size < 42) result.add(null)
    return result
}
