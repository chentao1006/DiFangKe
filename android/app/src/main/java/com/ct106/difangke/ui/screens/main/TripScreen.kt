@file:Suppress("DEPRECATION")

package com.ct106.difangke.ui.screens.main

import android.content.Context
import android.location.Location
import android.icu.text.AlphabeticIndex
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.filled.*
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.zIndex
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.AppConfig
import com.ct106.difangke.ConfiguredTripCity
import com.ct106.difangke.data.db.entity.*
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.data.prefs.AppPreferences
import com.ct106.difangke.service.TripScanWorker
import com.ct106.difangke.service.GeocodeService
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.getIconForName
import com.ct106.difangke.ui.components.timelineTransportIcon
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.FootprintPhotoThumbnail
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.screens.detail.FootprintDetailContent
import com.ct106.difangke.ui.theme.DfkAccent
import com.ct106.difangke.ui.share.GeoPoint
import com.ct106.difangke.ui.share.ShareMapSnapshotter
import com.ct106.difangke.ui.share.sharePoints
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import org.json.JSONArray
import org.json.JSONObject
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*
import kotlin.math.abs
import kotlin.math.roundToInt

private enum class TripCreationMode { PLANNED, HISTORICAL }
private enum class PlannedTripEditorMode { BASIC, ITINERARY }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class, ExperimentalMaterialApi::class)
@Composable
fun TripScreen() {
    val context = LocalContext.current
    val dao = remember { AppDatabase.getInstance(context).tripDao() }
    val preferences = remember { AppPreferences(context) }
    val trips by dao.observeTrips().collectAsState(initial = emptyList())
    val allDays by dao.observeAllDays().collectAsState(initial = emptyList())
    val allCities by dao.observeAllCities().collectAsState(initial = emptyList())
    val allItems by dao.observeAllItems().collectAsState(initial = emptyList())
    val allFootprints by AppDatabase.getInstance(context).footprintDao().observeAll().collectAsState(initial = emptyList())
    val activityTypes by AppDatabase.getInstance(context).activityTypeDao().observeAll().collectAsState(initial = emptyList())
    val transportRecords by AppDatabase.getInstance(context).transportRecordDao().observeAll().collectAsState(initial = emptyList())
    val homeCity by dao.observeHomeCity().collectAsState(initial = null)
    val introCompleted by preferences.tripIntroductionCompleted.collectAsState(initial = true)
    val scanRunning by preferences.tripScanRunning.collectAsState(initial = false)
    var selectedTrip by remember { mutableStateOf<TripEntity?>(null) }
    var editingTrip by remember { mutableStateOf<TripEntity?>(null) }
    var editingTripMode by remember { mutableStateOf<PlannedTripEditorMode?>(null) }
    var choosingEditorForTrip by remember { mutableStateOf<TripEntity?>(null) }
    var splittingTrip by remember { mutableStateOf<TripEntity?>(null) }
    var deletingTrip by remember { mutableStateOf<TripEntity?>(null) }
    var showingCreate by remember { mutableStateOf(false) }
    var showingCreateChoice by remember { mutableStateOf(false) }
    var createMode by remember { mutableStateOf<TripCreationMode?>(null) }
    var showingOptions by remember { mutableStateOf(false) }
    var showingIntroduction by remember { mutableStateOf(false) }
    var isSelecting by remember { mutableStateOf(false) }
    var selectedTripIDs by remember { mutableStateOf(emptySet<String>()) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var confirmingMerge by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun selectOrOpen(trip: TripEntity) {
        if (!isSelecting) selectedTrip = trip
        else selectedTripIDs = if (trip.id in selectedTripIDs) selectedTripIDs - trip.id else selectedTripIDs + trip.id
    }

    fun endSelection() {
        isSelecting = false
        selectedTripIDs = emptySet()
    }

    LaunchedEffect(homeCity, introCompleted) {
        if (!introCompleted) showingIntroduction = true
        else if (homeCity != null) TripScanWorker.schedule(context, runNow = true)
    }

    val active = trips.firstOrNull { it.state == TripState.ACTIVE }
    val planned = trips.filter { it.state == TripState.PLANNED }
        .sortedWith(compareByDescending<TripEntity> { it.datesUserEdited }.thenBy { it.plannedStartDay })
    val remaining = trips.filter { it.id != active?.id && it.state != TripState.PLANNED }
        .sortedByDescending { it.plannedStartDay }
    val yearGroups = remember(remaining) {
        remaining.groupBy { trip -> Calendar.getInstance().apply { time = trip.plannedStartDay }.get(Calendar.YEAR) }
            .toSortedMap(compareByDescending { it })
    }
    val listState = rememberLazyListState()
    val pullRefreshState = rememberPullRefreshState(
        refreshing = scanRunning,
        onRefresh = {
            if (!scanRunning) {
                scope.launch {
                    preferences.resetTripScanState()
                    TripScanWorker.rescan(context, onlyMissingDates = true)
                }
            }
        }
    )

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(if (isSelecting) "已选择 ${selectedTripIDs.size} 项" else "出行", fontWeight = FontWeight.Bold)
                },
                navigationIcon = {
                    if (isSelecting) {
                        IconButton(onClick = { endSelection() }) { Icon(Icons.Default.Close, "完成选择") }
                    } else if (scanRunning) {
                        CircularProgressIndicator(Modifier.padding(start = 16.dp).size(20.dp), strokeWidth = 2.dp)
                    }
                },
                actions = {
                    if (isSelecting) {
                        TextButton(onClick = {
                            selectedTripIDs = if (selectedTripIDs.size == trips.size) emptySet() else trips.map { it.id }.toSet()
                        }) { Text(if (selectedTripIDs.size == trips.size) "取消全选" else "全选") }
                        TextButton(onClick = { endSelection() }) { Text("完成") }
                    } else {
                        IconButton(onClick = { showingCreateChoice = true }) { Icon(Icons.Default.Add, "创建行程") }
                        IconButton(onClick = { showingOptions = true }) { Icon(Icons.Default.Tune, "出行选项") }
                    }
                }
            )
        },
        bottomBar = {
            if (isSelecting) {
                BottomAppBar {
                    OutlinedButton(
                        onClick = { confirmingDelete = true },
                        enabled = selectedTripIDs.isNotEmpty(),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.Delete, null); Spacer(Modifier.width(6.dp)); Text("删除")
                    }
                    Spacer(Modifier.width(12.dp))
                    Button(
                        onClick = { confirmingMerge = true },
                        enabled = selectedTripIDs.size > 1,
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.AutoMirrored.Filled.MergeType, null); Spacer(Modifier.width(6.dp)); Text("合并")
                    }
                }
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).pullRefresh(pullRefreshState)) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            active?.let { trip ->
                item(key = "active-large") {
                    TripCard(
                        trip = trip,
                        activityType = activityTypes.firstOrNull { it.id == trip.activityTypeValue || it.name == trip.activityTypeValue },
                        allDays = allDays,
                        allCities = allCities,
                        allItems = allItems,
                        allFootprints = allFootprints,
                        transportRecords = transportRecords,
                        prominent = true,
                        isSelecting = isSelecting,
                        isSelected = trip.id in selectedTripIDs,
                        onClick = { selectOrOpen(trip) },
                        onSelect = { isSelecting = true; selectedTripIDs = setOf(trip.id) },
                        onEdit = { choosingEditorForTrip = trip },
                        onSplit = { splittingTrip = trip },
                        onDelete = { deletingTrip = trip }
                    )
                }
                stickyHeader(key = "active-sticky") {
                    if (listState.firstVisibleItemIndex > 0 && !isSelecting) {
                        Surface(
                            modifier = Modifier.clickable { selectedTrip = trip },
                            shadowElevation = 4.dp
                        ) {
                            Row(
                                Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Box(Modifier.size(8.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(50)))
                                Spacer(Modifier.width(8.dp))
                                Text(trip.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Spacer(Modifier.weight(1f))
                                Text("进行中", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                                Icon(Icons.Default.ChevronRight, null)
                            }
                        }
                    }
                }
            }
            if (planned.isNotEmpty()) {
                item(key = "upcoming-header") {
                    Text(
                        "计划行程",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, top = 14.dp, bottom = 2.dp)
                    )
                }
                items(planned, key = { "planned-${it.id}" }) { trip ->
                    TripCard(
                        trip = trip,
                        activityType = activityTypes.firstOrNull { it.id == trip.activityTypeValue || it.name == trip.activityTypeValue },
                        allDays = allDays,
                        allCities = allCities,
                        allItems = allItems,
                        allFootprints = allFootprints,
                        transportRecords = transportRecords,
                        prominent = false,
                        isSelecting = isSelecting,
                        isSelected = trip.id in selectedTripIDs,
                        onClick = { selectOrOpen(trip) },
                        onSelect = { isSelecting = true; selectedTripIDs = setOf(trip.id) },
                        onEdit = { choosingEditorForTrip = trip },
                        onSplit = { splittingTrip = trip },
                        onDelete = { deletingTrip = trip }
                    )
                }
            }
            yearGroups.forEach { (year, yearTrips) ->
                item(key = "year-$year") {
                    Text(
                        "${year}年",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, top = 14.dp, bottom = 2.dp)
                    )
                }
                items(yearTrips, key = { it.id }) { trip ->
                    TripCard(
                        trip = trip,
                        activityType = activityTypes.firstOrNull { it.id == trip.activityTypeValue || it.name == trip.activityTypeValue },
                        allDays = allDays,
                        allCities = allCities,
                        allItems = allItems,
                        allFootprints = allFootprints,
                        transportRecords = transportRecords,
                        prominent = false,
                        isSelecting = isSelecting,
                        isSelected = trip.id in selectedTripIDs,
                        onClick = { selectOrOpen(trip) },
                        onSelect = { isSelecting = true; selectedTripIDs = setOf(trip.id) },
                        onEdit = {
                            if (trip.state == TripState.PLANNED || trip.state == TripState.ACTIVE) choosingEditorForTrip = trip
                            else editingTrip = trip
                        },
                        onSplit = { splittingTrip = trip },
                        onDelete = { deletingTrip = trip }
                    )
                }
            }
            if (trips.isEmpty()) {
                item {
                    Column(
                        Modifier.fillParentMaxHeight(.7f).fillMaxWidth(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(Icons.Default.Map, null, Modifier.size(46.dp), tint = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.height(12.dp))
                        Text("还没有行程", style = MaterialTheme.typography.titleMedium)
                        Text("规划未来行程，或从足迹整理过去的出行。", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (scanRunning) {
                item(key = "scan-status") {
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 14.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp)); Text("正在整理行程…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        PullRefreshIndicator(scanRunning, pullRefreshState, Modifier.align(Alignment.TopCenter))
        }
    }

    if (showingCreateChoice) {
        AlertDialog(
            onDismissRequest = { showingCreateChoice = false },
            title = { Text("创建行程") },
            text = { Text("你想规划未来，还是整理一段过去的出行？") },
            confirmButton = {
                TextButton(onClick = {
                    showingCreateChoice = false
                    createMode = TripCreationMode.PLANNED
                    showingCreate = true
                }) { Text("规划一次出行") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showingCreateChoice = false
                    createMode = TripCreationMode.HISTORICAL
                    showingCreate = true
                }) { Text("补记过去行程") }
            }
        )
    }
    if (showingCreate && createMode == TripCreationMode.PLANNED) {
        PlanTripDialog(
            dao = dao,
            onDismiss = { showingCreate = false; createMode = null },
            onCreated = { trip ->
                showingCreate = false
                createMode = null
                selectedTrip = trip
            }
        )
    } else if (showingCreate) {
        CreateTripDialog(context = context, dao = dao, forcesHistorical = true, onDismiss = { showingCreate = false; createMode = null })
    }
    if (showingOptions) {
        TripOptionsDialog(context = context, dao = dao, onDismiss = { showingOptions = false })
    }
    if (showingIntroduction) {
        TripIntroductionDialog(context, dao, homeCity) { showingIntroduction = false }
    }
    editingTrip?.let { trip ->
        Dialog(onDismissRequest = { editingTrip = null; editingTripMode = null }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            if (trip.state == TripState.PLANNED || trip.state == TripState.ACTIVE) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                    Surface(
                        modifier = Modifier.fillMaxWidth().fillMaxHeight(0.74f),
                        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp)
                    ) {
                        TripEditorScreen(trip = trip, activityTypes = activityTypes, dao = dao, mode = editingTripMode) {
                            editingTrip = null; editingTripMode = null
                        }
                    }
                }
            } else {
                TripEditorScreen(trip = trip, activityTypes = activityTypes, dao = dao, onDismiss = { editingTrip = null })
            }
        }
    }
    choosingEditorForTrip?.let { trip ->
        AlertDialog(
            onDismissRequest = { choosingEditorForTrip = null },
            title = { Text("编辑计划") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        choosingEditorForTrip = null
                        editingTripMode = PlannedTripEditorMode.BASIC
                        editingTrip = trip
                    }, modifier = Modifier.fillMaxWidth()) { Text("基本信息") }
                    TextButton(onClick = {
                        choosingEditorForTrip = null
                        editingTripMode = PlannedTripEditorMode.ITINERARY
                        editingTrip = trip
                    }, modifier = Modifier.fillMaxWidth()) { Text("行程安排") }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { choosingEditorForTrip = null }) { Text("取消") } }
        )
    }
    splittingTrip?.let { trip ->
        TripSplitDialog(
            trip = trip,
            days = allDays.filter { it.tripID == trip.id },
            cities = allCities,
            onDismiss = { splittingTrip = null },
            onSplit = { day ->
                splittingTrip = null
                scope.launch {
                    suppressAutomaticRanges(preferences, listOf(trip))
                    dao.splitTrip(trip.id, day)
                }
            }
        )
    }
    deletingTrip?.let { trip ->
        AlertDialog(
            onDismissRequest = { deletingTrip = null },
            title = { Text("删除行程？") },
            text = { Text("“${trip.title}”将从出行列表中删除，原来的足迹、交通和照片仍会保留。") },
            confirmButton = {
                TextButton(onClick = {
                    deletingTrip = null
                    scope.launch {
                        suppressAutomaticRanges(preferences, listOf(trip))
                        dao.deleteTrips(setOf(trip.id))
                    }
                }) { Text("删除行程", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deletingTrip = null }) { Text("取消") } }
        )
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("删除所选的 ${selectedTripIDs.size} 个行程？") },
            text = { Text("会删除行程及其中按天整理的城市、足迹和交通引用；原始记录时间线不会被删除。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmingDelete = false
                    scope.launch {
                        suppressAutomaticRanges(preferences, trips.filter { it.id in selectedTripIDs })
                        dao.deleteTrips(selectedTripIDs)
                        endSelection()
                    }
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("取消") } }
        )
    }
    if (confirmingMerge) {
        AlertDialog(
            onDismissRequest = { confirmingMerge = false },
            title = { Text("合并所选的 ${selectedTripIDs.size} 个行程？") },
            text = { Text("日期、城市、足迹、交通、行程类型、标题和备注都会合并到一个行程中。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmingMerge = false
                    scope.launch { dao.mergeTrips(selectedTripIDs); endSelection() }
                }) { Text("合并") }
            },
            dismissButton = { TextButton(onClick = { confirmingMerge = false }) { Text("取消") } }
        )
    }
    selectedTrip?.let { selected ->
        val trip = trips.firstOrNull { it.id == selected.id } ?: selected
        Dialog(
            onDismissRequest = { selectedTrip = null },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false
            )
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background
            ) {
                if (trip.state == TripState.PLANNED || trip.state == TripState.ACTIVE) {
                    PlannedTripScreen(
                        trip = trip,
                        homeCity = homeCity,
                        activityTypes = activityTypes,
                        transportRecords = transportRecords,
                        onBack = { selectedTrip = null }
                    )
                } else {
                    TripDetailScreen(
                        trip = trip,
                        activityTypes = activityTypes,
                        transportRecords = transportRecords,
                        onBack = { selectedTrip = null }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripSplitDialog(
    trip: TripEntity,
    days: List<TripDayEntity>,
    cities: List<TripDayCityEntity>,
    onDismiss: () -> Unit,
    onSplit: (Date) -> Unit
) {
    var isSplitting by remember { mutableStateOf(false) }
    val calendar = Calendar.getInstance()
    val earliestDate = calendar.apply {
        time = startOfLocalDay(trip.plannedStartDay)
        add(Calendar.DAY_OF_YEAR, 1)
    }.time
    val latestDate = startOfLocalDay(trip.plannedEndDay)
    fun pickerMillis(date: Date): Long {
        val local = Calendar.getInstance().apply { time = date }
        return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
        }.timeInMillis
    }
    fun localDate(utcMillis: Long): Date {
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = utcMillis }
        return Calendar.getInstance().apply {
            clear()
            set(utc.get(Calendar.YEAR), utc.get(Calendar.MONTH), utc.get(Calendar.DAY_OF_MONTH))
        }.time
    }
    val earliest = pickerMillis(earliestDate)
    val latest = pickerMillis(latestDate)
    val pickerState = rememberDatePickerState(
        initialSelectedDateMillis = earliest,
        selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis in earliest..latest
        }
    )
    val selectedDay = pickerState.selectedDateMillis?.let(::localDate) ?: earliestDate
    val splitTime = startOfLocalDay(selectedDay).time
    val firstDays = days.filter { startOfLocalDay(it.day).time < splitTime }.sortedBy { it.day }
    val secondDays = days.filter { startOfLocalDay(it.day).time >= splitTime }.sortedBy { it.day }
    fun cityNames(segmentDays: List<TripDayEntity>): List<String> = segmentDays.flatMap { day ->
        cities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
    }.map { it.cityName.trim() }.filter { it.isNotEmpty() }.distinct()
    val firstCities = cityNames(firstDays)
    val secondCities = cityNames(secondDays)
    val firstEnd = Calendar.getInstance().apply { time = selectedDay; add(Calendar.DAY_OF_YEAR, -1) }.time
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = pickerState.selectedDateMillis != null && !isSplitting,
                onClick = {
                    pickerState.selectedDateMillis?.let {
                        if (!isSplitting) {
                            isSplitting = true
                            onSplit(localDate(it))
                        }
                    }
                }
            ) { Text("拆分") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    ) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            DatePicker(state = pickerState, title = { Text("第二段开始日期", Modifier.padding(start = 24.dp, top = 16.dp)) })
            HorizontalDivider()
            Text(
                "拆分预览",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 14.dp)
            )
            TripSplitSegmentPreview(
                title = "第一段",
                dateRange = formatRange(trip.plannedStartDay, firstEnd),
                cities = firstCities
            )
            TripSplitSegmentPreview(
                title = "第二段",
                dateRange = formatRange(selectedDay, trip.plannedEndDay),
                cities = secondCities
            )
            Text(
                "这一天及之后的行程内容会移到第二段，原来的足迹、交通和照片不会改变。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp)
            )
        }
    }
}

@Composable
private fun TripSplitSegmentPreview(title: String, dateRange: String, cities: List<String>) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 7.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        Row(Modifier.fillMaxWidth()) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(dateRange, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        Text(
            cities.ifEmpty { listOf("暂无城市") }.joinToString(" · "),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TripCard(
    trip: TripEntity,
    activityType: ActivityTypeEntity?,
    allDays: List<TripDayEntity>,
    allCities: List<TripDayCityEntity>,
    allItems: List<TripItemEntity>,
    allFootprints: List<FootprintEntity>,
    transportRecords: List<TransportRecordEntity>,
    prominent: Boolean,
    isSelecting: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onSplit: () -> Unit,
    onDelete: () -> Unit
) {
    val context = LocalContext.current
    val preferences = remember { AppPreferences(context) }
    var menuExpanded by remember { mutableStateOf(false) }
    val tint = when (trip.state) {
        TripState.ACTIVE -> MaterialTheme.colorScheme.primary
        TripState.PLANNED -> MaterialTheme.colorScheme.secondary
        TripState.DRAFT -> MaterialTheme.colorScheme.tertiary
        TripState.CANCELLED -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val orderedTripDays = allDays.filter { it.tripID == trip.id }
        .sortedWith(compareBy<TripDayEntity> { it.day }.thenBy { it.orderIndex })
    val storedItems = orderedTripDays.flatMap { day ->
        allItems.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
    }
    val tripItems = if (trip.kindRaw == TripKind.HISTORICAL.raw) {
        actualTripItems(orderedTripDays, allFootprints, transportRecords)
    } else storedItems
    val nextStop = tripItems.firstOrNull {
        prominent && it.kindRaw == "stop" && it.planStatusRaw == "planned"
    }
    val nextStopIndex = nextStop?.let { stop -> tripItems.indexOfFirst { it.id == stop.id } } ?: -1
    val previousStop = if (nextStopIndex > 0) {
        tripItems.subList(0, nextStopIndex).lastOrNull { it.kindRaw == "stop" }
    } else null
    val activeRouteKey = listOf(previousStop?.id, nextStop?.id, nextStop?.transportTypeRaw).joinToString("|")
    val activeRoute by produceState<GeocodeService.RoutePlan?>(null, activeRouteKey) {
        val origin = previousStop
        val destination = nextStop
        val originLatitude = origin?.latitude
        val originLongitude = origin?.longitude
        val destinationLatitude = destination?.latitude
        val destinationLongitude = destination?.longitude
        val transportTypeRaw = destination?.transportTypeRaw
        value = if (originLatitude != null && originLongitude != null &&
            destinationLatitude != null && destinationLongitude != null &&
            !transportTypeRaw.isNullOrBlank()
        ) {
            val plans = GeocodeService.shared.routePlans(
                originLatitude,
                originLongitude,
                destinationLatitude,
                destinationLongitude,
                transportTypeRaw
            )
            val preferredIndex = preferences.getTripRouteOptionIndex(destination.id)
                .coerceIn(0, plans.lastIndex.coerceAtLeast(0))
            plans.getOrNull(preferredIndex)
        } else null
    }
    Box {
    Card(
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = { menuExpanded = true }),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)
    ) {
        val tripCities = orderedTripDays.flatMap { day ->
            allCities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
        }
        TripCardHero(tripItems, tripCities, allFootprints, transportRecords, prominent)
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (isSelecting) {
                    Icon(
                        if (isSelected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                        null,
                        tint = if (isSelected) DfkAccent else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(trip.title.ifBlank { "未命名行程" }, style = if (prominent) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            }
            val cityText = tripCities.asSequence()
                .map { it.cityName }
                .distinct()
                .take(4)
                .joinToString(" · ")
            if (cityText.isNotBlank()) Text(cityText, color = MaterialTheme.colorScheme.onSurfaceVariant)
            activityType?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(getIconForName(it.icon), null, tint = parseActivityColor(it.colorHex), modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(it.name, color = parseActivityColor(it.colorHex), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                }
            }
            if (trip.kindRaw != TripKind.PLANNED.raw || trip.datesUserEdited) {
                Text(formatRange(trip.plannedStartDay, trip.plannedEndDay), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (trip.state == TripState.PLANNED) {
                val tripDays = allDays.filter { it.tripID == trip.id }
                val arrangedIDs = storedItems.map { it.tripDayID }.toSet()
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (trip.datesUserEdited) {
                        Text(plannedTripStatus(trip), color = DfkAccent, fontWeight = FontWeight.SemiBold)
                    }
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${tripDays.count { it.id in arrangedIDs }}/${tripDays.size.coerceAtLeast(1)} 天有详细安排",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            if (prominent) {
                Row(Modifier.fillMaxWidth().background(tint.copy(alpha = .08f), RoundedCornerShape(12.dp)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        nextStop?.transportTypeRaw?.let { timelineTransportIcon(it) } ?: Icons.Default.LocationOn,
                        null,
                        tint = tint
                    )
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(nextStop?.let(::plannedItemTitle) ?: "行程进行中", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            plannedRouteGuidance(activeRoute)
                                ?: if (nextStop != null && previousStop != null) plannedRouteSummary(nextStop, previousStop, activeRoute)
                                else nextStop?.address ?: nextStop?.notes?.takeIf(String::isNotBlank) ?: "查看地图与行程安排",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
        DropdownMenuItem(
            text = { Text("选择") },
            leadingIcon = { Icon(Icons.Default.CheckCircleOutline, null) },
            onClick = { menuExpanded = false; onSelect() }
        )
        DropdownMenuItem(
            text = { Text("编辑") },
            leadingIcon = { Icon(Icons.Default.Edit, null) },
            onClick = { menuExpanded = false; onEdit() }
        )
        if (trip.kindRaw == TripKind.HISTORICAL.raw && trip.state == TripState.HISTORICAL &&
            tripInclusiveDayCount(trip.plannedStartDay, trip.plannedEndDay) > 1 &&
            allDays.count { it.tripID == trip.id } > 1
        ) {
            DropdownMenuItem(
                text = { Text("拆分") },
                leadingIcon = { Icon(Icons.Default.ContentCut, null) },
                onClick = { menuExpanded = false; onSplit() }
            )
        }
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text("删除", color = MaterialTheme.colorScheme.error) },
            leadingIcon = { Icon(Icons.Default.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) },
            onClick = { menuExpanded = false; onDelete() }
        )
    }
    }
}

private fun plannedTripStatus(trip: TripEntity): String {
    if (trip.state == TripState.ACTIVE) return "进行中"
    val days = localDayDifference(startOfLocalDay(Date()), startOfLocalDay(trip.plannedStartDay))
    return when {
        days > 0 -> "还有${days}天"
        days == 0 -> "今天出发"
        else -> "尚未开始"
    }
}

@Composable
private fun TripCardHero(
    items: List<TripItemEntity>,
    cities: List<TripDayCityEntity>,
    footprints: List<FootprintEntity>,
    transportRecords: List<TransportRecordEntity>,
    prominent: Boolean
) {
    val dark = isSystemInDarkTheme()
    val footprintByID = remember(footprints) { footprints.associateBy { it.footprintID } }
    val transportByID = remember(transportRecords) { transportRecords.associateBy { it.recordID } }
    val signature = remember(items, cities) {
        items.joinToString(";") { "${it.id}:${it.latitude}:${it.longitude}:${it.sourceFootprintID}:${it.sourceTransportRecordID}" } +
            "#" + cities.joinToString(";") { "${it.id}:${it.latitude}:${it.longitude}" }
    }
    val photoUris = remember(signature, footprintByID) {
        items.asSequence().mapNotNull { it.sourceFootprintID }.distinct().flatMap { id ->
            val json = footprintByID[id]?.photoAssetIDsJson ?: "[]"
            runCatching {
                val array = JSONArray(json)
                (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
            }.getOrDefault(emptyList()).asSequence()
        }.distinct()
            .sortedBy { "$signature|$it".hashCode() }
            .take(5)
            .toList()
    }
    var mapBitmap by remember(signature, dark) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(signature, dark, transportRecords) {
        val stops = items.mapNotNull { item ->
            val lat = item.latitude
            val lon = item.longitude
            if (item.kindRaw == "stop" && lat != null && lon != null) GeoPoint(lat, lon) else null
        } + cities.mapNotNull { city ->
            val lat = city.latitude
            val lon = city.longitude
            if (lat != null && lon != null) GeoPoint(lat, lon) else null
        }
        val routes = items.mapNotNull { it.sourceTransportRecordID }
            .distinct().mapNotNull { transportByID[it]?.sharePoints()?.takeIf { points -> points.isNotEmpty() } }
        val snapshot = ShareMapSnapshotter.snapshot(stops + routes.flatten(), routes = routes, drawsPath = false)
        mapBitmap = if (dark) snapshot?.dark ?: snapshot?.light else snapshot?.light ?: snapshot?.dark
    }
    val cardColor = MaterialTheme.colorScheme.surfaceContainer
    Box(Modifier.fillMaxWidth().height(if (prominent) 154.dp else 132.dp)) {
        mapBitmap?.let { bitmap ->
            Image(bitmap.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        } ?: Box(Modifier.fillMaxSize().background(cardColor), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Map, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .5f), modifier = Modifier.size(36.dp))
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(listOf(Color.Transparent, cardColor.copy(alpha = .2f), cardColor))
            )
        )
        if (photoUris.isNotEmpty()) {
            Box(Modifier.align(Alignment.CenterEnd).width(128.dp).height(92.dp).padding(end = 18.dp)) {
                photoUris.forEachIndexed { index, uri ->
                    val shape = RoundedCornerShape(11.dp)
                    FootprintPhotoThumbnail(
                        uri,
                        Modifier.align(Alignment.CenterEnd)
                            .offset(x = ((photoUris.lastIndex - index) * -26).dp)
                            .rotate((index - 1) * 4f)
                            .shadow(5.dp, shape)
                            .size(width = 58.dp, height = 76.dp)
                            .clip(shape)
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                        "行程照片"
                    )
                }
            }
        }
    }
}

private fun formatRange(start: Date, end: Date): String {
    val startText = SimpleDateFormat("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE).format(start)
    val startYear = Calendar.getInstance().apply { time = start }.get(Calendar.YEAR)
    val endYear = Calendar.getInstance().apply { time = end }.get(Calendar.YEAR)
    val endPattern = if (startYear == endYear) "M月d日" else "yyyy年M月d日"
    val endText = SimpleDateFormat(endPattern, Locale.SIMPLIFIED_CHINESE).format(end)
    return "$startText—$endText"
}

private fun actualTripItems(
    days: List<TripDayEntity>,
    footprints: List<FootprintEntity>,
    transports: List<TransportRecordEntity>
): List<TripItemEntity> {
    if (days.isEmpty()) return emptyList()
    val intervals = days.map { day ->
        val calendar = Calendar.getInstance(TimeZone.getTimeZone(day.timeZoneIdentifier)).apply {
            time = day.day
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val start = calendar.time
        calendar.add(Calendar.DAY_OF_YEAR, 1)
        Triple(day, start, calendar.time)
    }
    fun dayFor(start: Date, end: Date): TripDayEntity? =
        intervals.firstOrNull { start >= it.second && start < it.third }?.first
            ?: intervals.firstOrNull { start < it.third && end > it.second }?.first
    fun firstCoordinate(json: String): Double? = runCatching { JSONArray(json).optDouble(0).takeIf { it.isFinite() } }.getOrNull()
    val stops = footprints.mapNotNull { footprint ->
        val day = dayFor(footprint.startTime, footprint.endTime) ?: return@mapNotNull null
        TripItemEntity(
            id = "actual-f-${footprint.footprintID}", tripDayID = day.id, kindRaw = "stop",
            stopScopeRaw = if (footprint.placeID == null) "city" else "place",
            countryCode = footprint.countryCode, countryName = footprint.countryName, cityName = footprint.cityName,
            placeID = footprint.placeID, placeName = footprint.address ?: footprint.cityName,
            address = footprint.address, latitude = firstCoordinate(footprint.latitudeJson), longitude = firstCoordinate(footprint.longitudeJson),
            startTime = footprint.startTime, endTime = footprint.endTime, activityTypeValue = footprint.activityTypeValue,
            notes = footprint.reason.orEmpty(), sourceFootprintID = footprint.footprintID, planStatusRaw = "actual"
        )
    }
    val moves = transports.filter { it.statusRaw != "ignored" }.mapNotNull { transport ->
        val day = dayFor(transport.startTime, transport.endTime) ?: return@mapNotNull null
        TripItemEntity(
            id = "actual-t-${transport.recordID}", tripDayID = day.id, kindRaw = "transport",
            startTime = transport.startTime, endTime = transport.endTime,
            transportTypeRaw = transport.manualTypeRaw ?: transport.typeRaw,
            startLocationName = transport.startLocation, endLocationName = transport.endLocation,
            sourceTransportRecordID = transport.recordID, planStatusRaw = "actual"
        )
    }
    return (stops + moves).sortedBy { it.startTime }.mapIndexed { index, item -> item.copy(orderIndex = index) }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun PlannedTripScreen(
    trip: TripEntity,
    homeCity: HomeCityEntity?,
    activityTypes: List<ActivityTypeEntity>,
    transportRecords: List<TransportRecordEntity>,
    onBack: () -> Unit
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val dao = remember { AppDatabase.getInstance(context).tripDao() }
    val preferences = remember { AppPreferences(context) }
    val trips by dao.observeTrips().collectAsState(initial = emptyList())
    val days by dao.observeDays(trip.id).collectAsState(initial = emptyList())
    val allCities by dao.observeAllCities().collectAsState(initial = emptyList())
    val allItems by dao.observeAllItems().collectAsState(initial = emptyList())
    val allFootprints by AppDatabase.getInstance(context).footprintDao().observeAll().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    var editorMode by remember { mutableStateOf<PlannedTripEditorMode?>(null) }
    var showingStartChoice by remember { mutableStateOf(false) }
    var showingCancelActiveConfirmation by remember { mutableStateOf(false) }
    var pendingPlanStatusItem by remember { mutableStateOf<TripItemEntity?>(null) }
    var activeConflict by remember { mutableStateOf<TripEntity?>(null) }
    var routeSelection by remember { mutableStateOf<TripPlanRouteSelection?>(null) }
    var placeSelection by remember { mutableStateOf<TripPlaceDetailSelection?>(null) }
    var routePreferenceVersion by remember { mutableIntStateOf(0) }
    var isPlanPanelCollapsed by remember { mutableStateOf(false) }
    var planPanelDragDistance by remember { mutableFloatStateOf(0f) }
    val planListState = rememberLazyListState()
    val compactPlanListState = rememberLazyListState()
    var mapFocusedItem by remember { mutableStateOf<TripItemEntity?>(null) }
    var userDidScrollPlanTimeline by remember { mutableStateOf(false) }
    val planTimelineScrollObserver = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput) userDidScrollPlanTimeline = true
                return Offset.Zero
            }
        }
    }
    val nextDestinationBringIntoViewRequester = remember { BringIntoViewRequester() }
    val orderedDays = days.sortedWith(compareBy<TripDayEntity> { it.day }.thenBy { it.orderIndex })
    val dayIDs = orderedDays.map { it.id }.toSet()
    val cities = allCities.filter { it.tripDayID in dayIDs }
    val storedPlanItems = allItems.filter { it.tripDayID in dayIDs }
    val items = migrateLegacyPlannedTransportItems(orderedDays, storedPlanItems)
    val arrangedDays = items.map { it.tripDayID }.toSet().size
    val orderedPlanItems = orderedDays.flatMap { day -> items.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex } }
    val routeRequestKey = remember(orderedPlanItems, homeCity, routePreferenceVersion) {
        "${homeCity?.latitude},${homeCity?.longitude}|" + orderedPlanItems.joinToString("|") { item ->
            listOf(item.id, item.latitude, item.longitude, item.transportTypeRaw).joinToString(":")
        } + "|$routePreferenceVersion"
    }
    val plannedRoutePlans by produceState<Map<String, GeocodeService.RoutePlan>>(
        initialValue = emptyMap(),
        key1 = routeRequestKey
    ) {
        val loaded = mutableMapOf<String, GeocodeService.RoutePlan>()
        orderedPlanItems.forEach { destination ->
            val origin = plannedRouteOrigin(destination, orderedPlanItems, homeCity) ?: return@forEach
            val originLatitude = origin.latitude
            val originLongitude = origin.longitude
            val destinationLatitude = destination.latitude
            val destinationLongitude = destination.longitude
            if (destinationLatitude != null && destinationLongitude != null &&
                !destination.transportTypeRaw.isNullOrBlank()
            ) {
                val plans = GeocodeService.shared.routePlans(
                    originLatitude,
                    originLongitude,
                    destinationLatitude,
                    destinationLongitude,
                    destination.transportTypeRaw
                )
                plans.getOrNull(preferences.getTripRouteOptionIndex(destination.id).coerceIn(0, plans.lastIndex.coerceAtLeast(0)))?.let {
                    loaded[destination.id] = it
                    value = loaded.toMap()
                }
            }
        }
        value = loaded
    }
    val nextDestinationID = orderedPlanItems.firstOrNull {
        it.kindRaw == "stop" && it.stopScopeRaw == "place" && it.planStatusRaw == "planned"
    }?.id
    val nextDestination = orderedPlanItems.firstOrNull { it.id == nextDestinationID }
    val nextDestinationDayIndex = orderedDays.indexOfFirst { day ->
        nextDestinationID != null && items.any { it.tripDayID == day.id && it.id == nextDestinationID }
    }
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val planPanelHeight = if (isPlanPanelCollapsed) 176.dp else configuration.screenHeightDp.dp * 0.68f
    val mapBottomPaddingPx = with(density) { planPanelHeight.roundToPx() }

    LaunchedEffect(orderedDays, storedPlanItems) {
        val legacy = storedPlanItems.filter { it.kindRaw == "transport" }
        if (legacy.isNotEmpty()) {
            dao.replacePlanItems(trip.id, items)
        }
    }
    LaunchedEffect(trip.stateRaw, nextDestinationID, isPlanPanelCollapsed) {
        if (trip.state == TripState.ACTIVE && nextDestinationDayIndex >= 0 && !isPlanPanelCollapsed) {
            planListState.animateScrollToItem(nextDestinationDayIndex + 1)
            nextDestinationBringIntoViewRequester.bringIntoView()
        }
    }
    LaunchedEffect(planListState, isPlanPanelCollapsed, userDidScrollPlanTimeline) {
        if (isPlanPanelCollapsed || !userDidScrollPlanTimeline) return@LaunchedEffect
        snapshotFlow { planListState.firstVisibleItemIndex to planListState.firstVisibleItemScrollOffset }
            .collect { (lazyIndex, _) ->
                val day = orderedDays.getOrNull((lazyIndex - 1).coerceAtLeast(0))
                mapFocusedItem = day?.let { visibleDay ->
                    items.firstOrNull { it.tripDayID == visibleDay.id && it.latitude != null && it.longitude != null }
                }
            }
    }
    LaunchedEffect(compactPlanListState, isPlanPanelCollapsed, userDidScrollPlanTimeline) {
        if (!isPlanPanelCollapsed || !userDidScrollPlanTimeline) return@LaunchedEffect
        snapshotFlow { compactPlanListState.firstVisibleItemIndex to compactPlanListState.firstVisibleItemScrollOffset }
            .collect { (itemIndex, _) ->
                mapFocusedItem = orderedPlanItems.getOrNull(itemIndex)
                    ?.takeIf { it.latitude != null && it.longitude != null }
            }
    }

    Box(Modifier.fillMaxSize()) {
        TripMap(
            cities = cities,
            items = items,
            footprints = allFootprints,
            activityTypes = activityTypes,
            transportRecords = transportRecords,
            selectedItem = mapFocusedItem,
            bottomPaddingPx = mapBottomPaddingPx,
            homeCity = homeCity,
            routePreferenceVersion = routePreferenceVersion,
            onOpenFootprint = { },
            onOpenPlannedPlace = { itemID ->
                items.firstOrNull { it.id == itemID }?.let { placeSelection = TripPlaceDetailSelection(it) }
            }
        )
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            FloatingActionButton(onClick = onBack, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Default.Close, "关闭")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloatingActionButton(
                    onClick = { editorMode = PlannedTripEditorMode.ITINERARY },
                    modifier = Modifier.size(44.dp)
                ) {
                    Icon(Icons.Default.Edit, "编辑行程安排")
                }
                FloatingActionButton(
                    onClick = { editorMode = PlannedTripEditorMode.BASIC },
                    modifier = Modifier.size(44.dp)
                ) {
                    Icon(Icons.Default.Info, "编辑基本信息")
                }
            }
        }
        Surface(
            modifier = Modifier.fillMaxWidth().height(planPanelHeight).align(Alignment.BottomCenter),
            shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.88f),
            tonalElevation = 6.dp,
            shadowElevation = 12.dp
        ) {
            Column {
                Box(
                    Modifier.fillMaxWidth().height(28.dp)
                        .clickable { isPlanPanelCollapsed = !isPlanPanelCollapsed }
                        .pointerInput(isPlanPanelCollapsed) {
                            detectVerticalDragGestures(
                                onDragStart = { planPanelDragDistance = 0f },
                                onVerticalDrag = { change, dragAmount ->
                                    change.consume()
                                    planPanelDragDistance += dragAmount
                                },
                                onDragEnd = {
                                    if (planPanelDragDistance > 24f) isPlanPanelCollapsed = true
                                    if (planPanelDragDistance < -24f) isPlanPanelCollapsed = false
                                    planPanelDragDistance = 0f
                                },
                                onDragCancel = { planPanelDragDistance = 0f }
                            )
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Box(Modifier.width(38.dp).height(5.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f)))
                }
                Box(Modifier.weight(1f)) {
                    if (isPlanPanelCollapsed) {
                    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(trip.title, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Bold)
                            if (trip.datesUserEdited) {
                                Text(plannedTripStatus(trip), color = DfkAccent, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        LazyRow(
                            modifier = Modifier.nestedScroll(planTimelineScrollObserver),
                            state = compactPlanListState,
                            contentPadding = PaddingValues(horizontal = 16.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            items(orderedPlanItems, key = { it.id }) { item ->
                                val index = orderedPlanItems.indexOfFirst { it.id == item.id }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    val origin = plannedRouteOrigin(item, orderedPlanItems, homeCity)
                                    if (origin != null) {
                                        IconButton(
                                            onClick = { routeSelection = makeTripPlanRouteSelection(item, orderedPlanItems, homeCity) },
                                            modifier = Modifier.size(36.dp)
                                        ) {
                                            Icon(
                                                item.transportTypeRaw?.takeIf(String::isNotBlank)?.let { timelineTransportIcon(it) } ?: Icons.Default.Add,
                                                "查看交通详情",
                                                tint = DfkAccent
                                            )
                                        }
                                    }
                                    Card(
                                        onClick = { placeSelection = TripPlaceDetailSelection(item) },
                                        modifier = Modifier.width(220.dp).height(66.dp),
                                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                                    ) {
                                        Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                            if (trip.state == TripState.ACTIVE) {
                                                Icon(
                                                    if (item.planStatusRaw == "completed") Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                                    null,
                                                    tint = if (item.planStatusRaw == "completed") Color(0xFF22A447) else MaterialTheme.colorScheme.onSurfaceVariant,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                            } else {
                                                Surface(
                                                    shape = CircleShape,
                                                    color = DfkAccent.copy(alpha = 0.14f),
                                                    modifier = Modifier.size(32.dp)
                                                ) {
                                                    Box(contentAlignment = Alignment.Center) {
                                                        Text("${index + 1}", color = DfkAccent, fontWeight = FontWeight.Bold)
                                                    }
                                                }
                                            }
                                            Spacer(Modifier.width(8.dp))
                                            Text(
                                                plannedItemTitle(item),
                                                modifier = Modifier.weight(1f),
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                                fontWeight = FontWeight.SemiBold,
                                                style = MaterialTheme.typography.bodyMedium
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    } else LazyColumn(
                    Modifier.fillMaxSize().nestedScroll(planTimelineScrollObserver),
                    state = planListState,
                    contentPadding = PaddingValues(start = 16.dp, top = 0.dp, end = 16.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                item {
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.94f))) {
                        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                            Text(trip.title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                            if (trip.datesUserEdited) {
                                Text(formatRange(trip.plannedStartDay, trip.plannedEndDay), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            val cityNames = orderedDays.flatMap { day ->
                                cities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                            }.map { it.cityName }.distinct()
                            if (cityNames.isNotEmpty()) {
                                Text(cityNames.joinToString(" · "), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Row(Modifier.fillMaxWidth()) {
                                if (trip.datesUserEdited) {
                                    Text(plannedTripStatus(trip), color = DfkAccent, fontWeight = FontWeight.SemiBold)
                                }
                                Spacer(Modifier.weight(1f))
                                Text("$arrangedDays/${orderedDays.size} 天有详细安排", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
                items(orderedDays, key = { it.id }) { day ->
                    val dayIndex = orderedDays.indexOf(day)
                    val dayItems = items.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            TripDayTitleChip(
                                dayNumber = dayIndex + 1,
                                dateText = formatFullDate(day.day).takeIf { trip.datesUserEdited }
                            )
                            if (dayItems.isEmpty()) {
                                Text("这天还没有详细安排", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
                            } else {
                                dayItems.forEach { item ->
                                    val isCompleted = item.planStatusRaw == "completed"
                                    val isNext = item.id == nextDestinationID
                                    val itemIndex = orderedPlanItems.indexOfFirst { it.id == item.id }
                                    val origin = plannedRouteOrigin(item, orderedPlanItems, homeCity)
                                    if (origin != null) {
                                        val hasTransport = !item.transportTypeRaw.isNullOrBlank()
                                        val routePlan = plannedRoutePlans[item.id]
                                        Row(
                                            Modifier
                                                .fillMaxWidth()
                                                .clickable { routeSelection = makeTripPlanRouteSelection(item, orderedPlanItems, homeCity) }
                                                .padding(horizontal = 16.dp, vertical = 8.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(
                                                if (hasTransport) timelineTransportIcon(item.transportTypeRaw.orEmpty()) else Icons.Default.AddCircleOutline,
                                                null,
                                                Modifier.size(20.dp),
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                            Spacer(Modifier.width(8.dp))
                                            Text(
                                                if (hasTransport) plannedRouteSummary(item, origin, routePlan) else "选择交通方式",
                                                modifier = Modifier.weight(1f),
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                style = MaterialTheme.typography.bodyMedium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                    Card(
                                        onClick = { placeSelection = TripPlaceDetailSelection(item) },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .then(
                                                if (isNext) Modifier.bringIntoViewRequester(nextDestinationBringIntoViewRequester)
                                                else Modifier
                                            ),
                                        border = if (isNext) BorderStroke(1.dp, DfkAccent.copy(alpha = 0.32f)) else null,
                                        colors = CardDefaults.cardColors(
                                            containerColor = if (isNext) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.surfaceContainerHigh
                                        ),
                                        shape = RoundedCornerShape(18.dp)
                                    ) {
                                        Row(
                                            Modifier.fillMaxWidth().padding(14.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            if (trip.state == TripState.ACTIVE && item.stopScopeRaw == "place") {
                                                IconButton(
                                                    onClick = { pendingPlanStatusItem = item },
                                                    modifier = Modifier.size(44.dp)
                                                ) {
                                                    Icon(
                                                        if (isCompleted) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                                        if (isCompleted) "标记为未到达" else "标记为已到达",
                                                        tint = if (isCompleted) Color(0xFF22A447) else MaterialTheme.colorScheme.onSurfaceVariant,
                                                        modifier = Modifier.size(30.dp)
                                                    )
                                                }
                                            } else {
                                                Surface(
                                                    shape = CircleShape,
                                                    color = if (isNext) DfkAccent else DfkAccent.copy(alpha = 0.14f),
                                                    modifier = Modifier.size(36.dp)
                                                ) {
                                                    Box(contentAlignment = Alignment.Center) {
                                                        Text(
                                                            "${itemIndex + 1}",
                                                            color = if (isNext) Color.White else DfkAccent,
                                                            fontWeight = FontWeight.Bold
                                                        )
                                                    }
                                                }
                                            }
                                            Spacer(Modifier.width(12.dp))
                                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                                Text(
                                                    plannedItemTitle(item),
                                                    fontWeight = FontWeight.SemiBold,
                                                    color = if (isCompleted) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
                                                )
                                                plannedItemAddress(item)?.let { address ->
                                                    Text(
                                                        address,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        style = MaterialTheme.typography.bodySmall
                                                    )
                                                }
                                                item.startTime?.let { arrivalTime ->
                                                    Text("到达 ${SimpleDateFormat("HH:mm", Locale.getDefault()).format(arrivalTime)}", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                                                }
                                            }
                                            Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                }
                }
                if (trip.state == TripState.PLANNED && !trip.datesUserEdited) {
                    Button(
                        onClick = {
                            val active = trips.firstOrNull { it.state == TripState.ACTIVE && it.id != trip.id }
                            if (active != null) activeConflict = active
                            else scope.launch {
                                dao.startPlan(trip.id, localDayDifference(trip.plannedStartDay, Date()), Date())
                                onBack()
                            }
                        },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)
                    ) { Text("开始行程") }
                } else if (trip.state == TripState.ACTIVE) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedButton(
                            onClick = { showingCancelActiveConfirmation = true },
                            modifier = Modifier.weight(1f)
                        ) { Text("恢复为计划") }
                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    dao.upsertTrip(trip.copy(
                                        kindRaw = TripKind.HISTORICAL.raw,
                                        stateRaw = TripState.HISTORICAL.raw,
                                        actualEndedAt = Date(),
                                        endReasonRaw = "manual",
                                        updatedAt = Date()
                                    ))
                                    onBack()
                                }
                            },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                        ) { Text("结束行程") }
                    }
                }
            }
        }
    }

    editorMode?.let { mode ->
        Dialog(
            onDismissRequest = { editorMode = null },
            properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                Surface(
                    modifier = Modifier.fillMaxWidth().fillMaxHeight(0.74f),
                    shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
                    tonalElevation = 8.dp
                ) {
                    TripEditorScreen(trip, activityTypes, dao, mode = mode) { editorMode = null }
                }
            }
        }
    }
    if (showingCancelActiveConfirmation) {
        AlertDialog(
            onDismissRequest = { showingCancelActiveConfirmation = false },
            title = { Text("恢复为计划？") },
            text = { Text("将取消进行中状态，日期和行程安排都会保留。") },
            confirmButton = {
                TextButton(onClick = {
                    showingCancelActiveConfirmation = false
                    scope.launch {
                        dao.upsertTrip(trip.copy(
                            kindRaw = TripKind.PLANNED.raw,
                            stateRaw = TripState.PLANNED.raw,
                            actualStartedAt = null,
                            actualEndedAt = Date(),
                            endReasonRaw = "corrected",
                            updatedAt = Date()
                        ))
                        onBack()
                    }
                }) { Text("恢复为计划") }
            },
            dismissButton = { TextButton(onClick = { showingCancelActiveConfirmation = false }) { Text("取消") } }
        )
    }
    pendingPlanStatusItem?.let { item ->
        val isCompleted = item.planStatusRaw == "completed"
        AlertDialog(
            onDismissRequest = { pendingPlanStatusItem = null },
            title = { Text(if (isCompleted) "取消已到达状态？" else "确认已到达？") },
            text = {
                Text(
                    if (isCompleted) "将把“${plannedItemTitle(item)}”恢复为未到达。"
                    else "确认已经到达“${plannedItemTitle(item)}”？"
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingPlanStatusItem = null
                    scope.launch {
                        dao.upsertItem(item.copy(planStatusRaw = if (isCompleted) "planned" else "completed"))
                        dao.upsertTrip(trip.copy(updatedAt = Date()))
                    }
                }) { Text(if (isCompleted) "取消已到达" else "确认已到达") }
            },
            dismissButton = { TextButton(onClick = { pendingPlanStatusItem = null }) { Text("取消") } }
        )
    }
    if (showingStartChoice) {
        AlertDialog(
            onDismissRequest = { showingStartChoice = false },
            title = { Text("计划日期与今天不同") },
            text = { Text("原计划从${formatShortDate(trip.plannedStartDay)}开始。") },
            confirmButton = {
                TextButton(onClick = {
                    showingStartChoice = false
                    scope.launch { dao.startPlan(trip.id, localDayDifference(trip.plannedStartDay, Date()), Date()); onBack() }
                }) { Text("从今天开始并平移日程") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showingStartChoice = false
                    scope.launch { dao.startPlan(trip.id, 0, Date()); onBack() }
                }) { Text("保留原计划日期") }
            }
        )
    }
    activeConflict?.let { active ->
        AlertDialog(
            onDismissRequest = { activeConflict = null },
            title = { Text("已有进行中的行程") },
            text = { Text("请先结束“${active.title}”，再开始这段行程。") },
            confirmButton = { TextButton(onClick = { activeConflict = null }) { Text("知道了") } }
        )
    }
    routeSelection?.let { selection ->
        TripPlanRouteDialog(
            selection = selection,
            onTransportTypeChange = { rawValue ->
                allItems.firstOrNull { it.id == selection.id }?.let { destination ->
                    scope.launch {
                        dao.upsertItem(destination.copy(transportTypeRaw = rawValue, lineName = null))
                        dao.upsertTrip(trip.copy(updatedAt = Date()))
                    }
                }
            },
            onDismiss = {
                routeSelection = null
                routePreferenceVersion += 1
            }
        )
    }
    placeSelection?.let { selection ->
        TripPlaceDetailDialog(selection = selection, onDismiss = { placeSelection = null })
    }
}

private data class TripPlaceDetailSelection(
    val id: String,
    val title: String,
    val address: String?,
    val notes: String?,
    val arrivalTime: Date?,
    val coordinate: LatLng?
) {
    constructor(item: TripItemEntity) : this(
        id = item.id,
        title = plannedItemTitle(item),
        address = item.address?.takeIf(String::isNotBlank),
        notes = item.notes.takeIf(String::isNotBlank),
        arrivalTime = item.startTime,
        coordinate = item.latitude?.let { latitude -> item.longitude?.let { LatLng(latitude, it) } }
    )
}

private data class TripPlanRouteSelection(
    val id: String,
    val title: String,
    val subtitle: String?,
    val originName: String?,
    val origin: LatLng?,
    val destinationName: String?,
    val destination: LatLng?,
    val transportTypeRaw: String?
)

private data class TripPlanOrigin(
    val name: String,
    val latitude: Double,
    val longitude: Double
)

private data class TripRouteLoadState(
    val isLoading: Boolean,
    val plans: List<GeocodeService.RoutePlan>
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripPlaceDetailDialog(selection: TripPlaceDetailSelection, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val mapView = remember { TextureMapView(context) }
    DisposableEffect(mapView) {
        mapView.onStart()
        mapView.onResume()
        onDispose {
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            BoxWithConstraints {
            Column {
                TopAppBar(
                    title = { Text("地点详情") },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "关闭") } }
                )
                AndroidView(
                    factory = { mapView },
                    modifier = Modifier.fillMaxWidth().height(maxHeight * 0.4f),
                    update = { view ->
                        val map = view.map
                        map.uiSettings.isZoomControlsEnabled = false
                        map.uiSettings.isMyLocationButtonEnabled = false
                        map.clear()
                        selection.coordinate?.let { coordinate ->
                            map.addMarker(MarkerOptions().position(coordinate).title(selection.title))
                            map.moveCamera(CameraUpdateFactory.newLatLngZoom(coordinate, 16f))
                        }
                    }
                )
                Column(
                    Modifier.fillMaxWidth().weight(1f).padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(selection.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    selection.address?.takeIf { it != selection.title }?.let {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                            Icon(Icons.Default.Place, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    selection.arrivalTime?.let {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Schedule, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text("到达 ${SimpleDateFormat("HH:mm", Locale.getDefault()).format(it)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    selection.notes?.let { Text(it) }
                }
            }
            }
        }
    }
}

private fun makeTripPlanRouteSelection(
    item: TripItemEntity,
    orderedItems: List<TripItemEntity>,
    homeCity: HomeCityEntity?
): TripPlanRouteSelection {
    val origin = plannedRouteOrigin(item, orderedItems, homeCity)
    return TripPlanRouteSelection(
        id = item.id,
        title = plannedItemTitle(item),
        subtitle = if (origin != null && !item.transportTypeRaw.isNullOrBlank()) {
            tripPlanTransportSummary(item, origin)
        } else item.address,
        originName = origin?.name,
        origin = origin?.let { LatLng(it.latitude, it.longitude) },
        destinationName = item.placeName ?: item.address ?: item.cityName,
        destination = item.latitude?.let { latitude -> item.longitude?.let { LatLng(latitude, it) } },
        transportTypeRaw = if (origin == null) null else item.transportTypeRaw
    )
}

private fun plannedRouteOrigin(
    destination: TripItemEntity,
    orderedItems: List<TripItemEntity>,
    homeCity: HomeCityEntity?
): TripPlanOrigin? {
    val index = orderedItems.indexOfFirst { it.id == destination.id }
    if (index < 0) return null
    if (index > 0) {
        val previous = orderedItems[index - 1]
        val latitude = previous.latitude
        val longitude = previous.longitude
        if (latitude != null && longitude != null) {
            return TripPlanOrigin(
                previous.placeName ?: previous.address ?: previous.cityName ?: "上一站",
                latitude,
                longitude
            )
        }
    }
    val latitude = homeCity?.latitude
    val longitude = homeCity?.longitude
    if (latitude == null || longitude == null) return null
    return TripPlanOrigin(homeCity.cityName.ifBlank { "常居地" }, latitude, longitude)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripPlanRouteDialog(
    selection: TripPlanRouteSelection,
    onTransportTypeChange: (String?) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val preferences = remember { AppPreferences(context) }
    val scope = rememberCoroutineScope()
    val mapView = remember { TextureMapView(context) }
    val accent = DfkAccent.toArgb()
    val markerBackground = MaterialTheme.colorScheme.surface.toArgb()
    var transportMenuExpanded by remember { mutableStateOf(false) }
    var selectedTransportTypeRaw by remember(selection.id) { mutableStateOf(selection.transportTypeRaw) }
    var selectedRouteIndex by remember(selection.id) { mutableIntStateOf(0) }
    var selectedInstructionIndex by remember(selection.id, selectedTransportTypeRaw) { mutableStateOf<Int?>(null) }
    var detailPanelFraction by rememberSaveable(selection.id) { mutableFloatStateOf(0.58f) }
    val supportsRoutePlanning = selectedTransportTypeRaw != TransportType.AIRPLANE.raw &&
        selectedTransportTypeRaw != TransportType.SHIP.raw
    val instructionListState = rememberLazyListState()
    var routeRetryVersion by remember { mutableIntStateOf(0) }
    val routeLoadState by produceState(
        initialValue = TripRouteLoadState(isLoading = true, plans = emptyList()),
        selection.id,
        selectedTransportTypeRaw,
        routeRetryVersion
    ) {
        value = TripRouteLoadState(isLoading = true, plans = emptyList())
        val origin = selection.origin
        val destination = selection.destination
        val plans = if (supportsRoutePlanning && origin != null && destination != null && !selectedTransportTypeRaw.isNullOrBlank()) {
            GeocodeService.shared.routePlans(
                origin.latitude,
                origin.longitude,
                destination.latitude,
                destination.longitude,
                selectedTransportTypeRaw
            )
        } else emptyList()
        value = TripRouteLoadState(isLoading = false, plans = plans)
    }
    val navigationPlan = routeLoadState.plans.getOrNull(selectedRouteIndex) ?: routeLoadState.plans.firstOrNull()
    val navigationRoute = navigationPlan?.points.orEmpty()
        .map { (latitude, longitude) -> LatLng(latitude, longitude) }
    LaunchedEffect(selection.id, selectedTransportTypeRaw, routeLoadState.plans.size) {
        selectedRouteIndex = if (routeLoadState.plans.isEmpty()) 0 else {
            preferences.getTripRouteOptionIndex(selection.id)
                .coerceIn(0, routeLoadState.plans.lastIndex)
        }
    }
    LaunchedEffect(selectedInstructionIndex) {
        selectedInstructionIndex?.let { instructionListState.animateScrollToItem(it) }
    }
    DisposableEffect(mapView) {
        mapView.onStart()
        mapView.onResume()
        onDispose {
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
            val totalHeightPx = with(LocalDensity.current) { maxHeight.toPx() }
            val detailPanelHeight = maxHeight * detailPanelFraction
            Column {
                TopAppBar(
                    title = { Text("路线") },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "关闭") } }
                )
                AndroidView(
                    factory = { mapView },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    update = { view ->
                        val map = view.map
                        map.uiSettings.isZoomControlsEnabled = false
                        map.uiSettings.isMyLocationButtonEnabled = false
                        map.clear()
                        val endpointPoints = listOfNotNull(selection.origin, selection.destination)
                        selection.origin?.let {
                            map.addMarker(
                                MarkerOptions()
                                    .position(it)
                                    .anchor(0.5f, 0.5f)
                                    .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_GREEN))
                            )
                        }
                        selection.destination?.let {
                            map.addMarker(
                                MarkerOptions()
                                    .position(it)
                                    .anchor(0.5f, 0.5f)
                                    .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))
                            )
                        }
                        if (navigationRoute.size > 1) {
                            map.addPolyline(PolylineOptions().addAll(navigationRoute).width(12f).color(accent))
                        }
                        val currentPlan = navigationPlan
                        val instructionSegments = currentPlan?.instructions?.mapIndexed { index, instruction ->
                            routeInstructionPoints(currentPlan, index, instruction)
                        }.orEmpty()
                        instructionSegments.forEachIndexed { index, points ->
                            if (points.size < 2) return@forEachIndexed
                            val selected = selectedInstructionIndex == index
                            map.addPolyline(
                                PolylineOptions()
                                    .addAll(points)
                                    .width(if (selected) 16f else 7f)
                                    .color(if (selected) accent else (accent and 0x00FFFFFF) or (0x48 shl 24))
                            )
                            listOf(points.first(), points.last()).forEach { point ->
                                map.addMarker(
                                    MarkerOptions()
                                        .position(point)
                                        .anchor(0.5f, 0.5f)
                                        .icon(
                                            BitmapDescriptorFactory.fromBitmap(
                                                tripRouteEndpointMarkerBitmap(
                                                    context,
                                                    isSelected = selected,
                                                    backgroundColor = markerBackground
                                                )
                                            )
                                        )
                                        .zIndex(if (selected) 200f else 120f)
                                ).setTag("route-step:$index")
                            }
                        }
                        map.setOnMarkerClickListener { marker ->
                            val index = (marker.tag as? String)
                                ?.removePrefix("route-step:")
                                ?.toIntOrNull()
                                ?: return@setOnMarkerClickListener false
                            selectedInstructionIndex = index
                            true
                        }
                        if (navigationRoute.size > 1) {
                            val selectedSegment = selectedInstructionIndex?.let { instructionSegments.getOrNull(it) }
                            if (selectedSegment != null && selectedSegment.size > 1) {
                                val selectedBounds = LatLngBounds.Builder().also { builder ->
                                    selectedSegment.forEach(builder::include)
                                }.build()
                                runCatching { map.animateCamera(CameraUpdateFactory.newLatLngBounds(selectedBounds, 180)) }
                            } else {
                                val bounds = LatLngBounds.Builder().also { builder -> navigationRoute.forEach(builder::include) }.build()
                                runCatching { map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, 140)) }
                            }
                        } else if (endpointPoints.size == 2) {
                            map.addPolyline(
                                PolylineOptions()
                                    .addAll(endpointPoints)
                                    .width(4f)
                                    .color((accent and 0x00FFFFFF) or (0x66 shl 24))
                                    .lineType(PolylineOptions.LineType.LINE_TYPE_DOTTEDLINE)
                            )
                            runCatching {
                                map.moveCamera(
                                    CameraUpdateFactory.newLatLngBounds(
                                        LatLngBounds.builder().include(endpointPoints[0]).include(endpointPoints[1]).build(),
                                        140
                                    )
                                )
                            }
                        } else if (endpointPoints.size == 1) {
                            map.moveCamera(CameraUpdateFactory.newLatLngZoom(endpointPoints[0], 15f))
                        }
                    }
                )
                Column(
                    Modifier
                        .fillMaxWidth()
                        .height(detailPanelHeight)
                        .padding(horizontal = 18.dp)
                        .padding(bottom = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(26.dp)
                            .pointerInput(totalHeightPx) {
                                detectVerticalDragGestures { change, dragAmount ->
                                    change.consume()
                                    detailPanelFraction = (detailPanelFraction - dragAmount / totalHeightPx)
                                        .coerceIn(0.42f, 0.82f)
                                }
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        Box(
                            Modifier
                                .width(44.dp)
                                .height(5.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f))
                        )
                    }
                    Text(selection.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Box(Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            onClick = { transportMenuExpanded = true },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                selectedTransportTypeRaw?.let { timelineTransportIcon(it) } ?: Icons.Default.SwapVert,
                                null
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                selectedTransportTypeRaw?.let { TransportType.from(it).localizedName } ?: "选择交通方式",
                                modifier = Modifier.weight(1f)
                            )
                            Icon(Icons.Default.UnfoldMore, null)
                        }
                        DropdownMenu(
                            expanded = transportMenuExpanded,
                            onDismissRequest = { transportMenuExpanded = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("未设置") },
                                leadingIcon = { Icon(Icons.Default.RemoveCircleOutline, null) },
                                onClick = {
                                    transportMenuExpanded = false
                                    selectedTransportTypeRaw = null
                                    selectedRouteIndex = 0
                                    selectedInstructionIndex = null
                                    scope.launch { preferences.setTripRouteOptionIndex(selection.id, null) }
                                    onTransportTypeChange(null)
                                }
                            )
                            TransportType.entries.forEach { type ->
                                DropdownMenuItem(
                                    text = { Text(type.localizedName) },
                                    leadingIcon = { Icon(timelineTransportIcon(type.raw), null) },
                                    onClick = {
                                        transportMenuExpanded = false
                                        selectedTransportTypeRaw = type.raw
                                        selectedRouteIndex = 0
                                        selectedInstructionIndex = null
                                        scope.launch { preferences.setTripRouteOptionIndex(selection.id, null) }
                                        onTransportTypeChange(type.raw)
                                    }
                                )
                            }
                        }
                    }
                    if (routeLoadState.plans.size > 1) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            itemsIndexed(routeLoadState.plans) { index, plan ->
                                val distance = if (plan.distanceMeters < 1_000) {
                                    "${plan.distanceMeters.toInt().coerceAtLeast(1)}米"
                                } else {
                                    String.format(java.util.Locale.CHINA, "%.1f公里", plan.distanceMeters / 1_000)
                                }
                                FilterChip(
                                    selected = selectedRouteIndex == index,
                                    onClick = {
                                        selectedRouteIndex = index
                                        selectedInstructionIndex = null
                                        scope.launch { preferences.setTripRouteOptionIndex(selection.id, index) }
                                    },
                                    label = {
                                        Column {
                                            Text("方案${index + 1}", fontWeight = FontWeight.SemiBold)
                                            Text("$distance · 约${plan.durationMinutes.toInt().coerceAtLeast(1)}分钟", style = MaterialTheme.typography.labelSmall)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    val typeName = selectedTransportTypeRaw?.let { TransportType.from(it).localizedName }
                    if (!supportsRoutePlanning) {
                        val distance = if (selection.origin != null && selection.destination != null) {
                            "直线${tripPlanDirectDistanceText(selection.origin, selection.destination)}"
                        } else null
                        Text(
                            listOfNotNull(typeName, distance).joinToString(" · "),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    } else if (routeLoadState.isLoading) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text("正在规划路线…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    } else navigationPlan?.let { plan ->
                        val distance = if (plan.distanceMeters < 1_000) {
                            "${plan.distanceMeters.toInt().coerceAtLeast(1)}米"
                        } else {
                            String.format(java.util.Locale.CHINA, "%.1f公里", plan.distanceMeters / 1_000)
                        }
                        Text(
                            listOfNotNull(typeName, distance, plan.durationMinutes.takeIf { it > 0 }?.let { "约${it.toInt().coerceAtLeast(1)}分钟" })
                                .joinToString(" · "),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (plan.instructions.isNotEmpty()) {
                            LazyColumn(
                                modifier = Modifier.heightIn(max = 190.dp),
                                state = instructionListState
                            ) {
                                itemsIndexed(plan.instructions) { index, instruction ->
                                    Row(
                                        Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(if (selectedInstructionIndex == index) DfkAccent.copy(alpha = 0.13f) else Color.Transparent)
                                            .clickable {
                                                selectedInstructionIndex = index
                                            }
                                            .padding(horizontal = 8.dp, vertical = 9.dp),
                                        verticalAlignment = Alignment.Top,
                                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                                    ) {
                                        Icon(
                                            timelineTransportIcon(instruction.transportTypeRaw),
                                            null,
                                            Modifier.size(24.dp),
                                            tint = DfkAccent
                                        )
                                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                            Text(instruction.title, fontWeight = FontWeight.SemiBold)
                                            instruction.detail?.let {
                                                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            }
                                        }
                                    }
                                    if (index < plan.instructions.lastIndex) HorizontalDivider(Modifier.padding(start = 36.dp))
                                }
                            }
                        }
                    } ?: if (selection.origin != null && selection.destination != null && selectedTransportTypeRaw.isNullOrBlank()) {
                        Text("请先在行程中选择交通方式", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("暂时没有取得这段路线", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { routeRetryVersion += 1 }) { Text("重试") }
                    }
                }
            }
            }
        }
    }
}

private fun tripRouteEndpointMarkerBitmap(
    context: Context,
    isSelected: Boolean,
    backgroundColor: Int
): android.graphics.Bitmap {
    val density = context.resources.displayMetrics.density
    val size = ((if (isSelected) 16 else 11) * density).roundToInt().coerceAtLeast(12)
    val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bitmap)
    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
    val center = size / 2f
    paint.color = if (isSelected) android.graphics.Color.rgb(0, 188, 201) else backgroundColor
    paint.style = android.graphics.Paint.Style.FILL
    canvas.drawCircle(center, center, center - density, paint)
    paint.color = android.graphics.Color.rgb(0, 160, 172)
    paint.style = android.graphics.Paint.Style.STROKE
    paint.strokeWidth = (if (isSelected) 2f else 1.5f) * density
    canvas.drawCircle(center, center, center - paint.strokeWidth, paint)
    return bitmap
}

private fun routeInstructionPoints(
    plan: GeocodeService.RoutePlan,
    index: Int,
    instruction: GeocodeService.RouteInstruction
): List<LatLng> {
    val stored = instruction.points.map { (latitude, longitude) -> LatLng(latitude, longitude) }
    if (stored.size > 1) return stored
    val start = instruction.latitude?.let { latitude -> instruction.longitude?.let { LatLng(latitude, it) } }
        ?: return emptyList()
    val next = plan.instructions.drop(index + 1).firstNotNullOfOrNull { nextInstruction ->
        nextInstruction.latitude?.let { latitude ->
            nextInstruction.longitude?.let { longitude -> LatLng(latitude, longitude) }
        }
    } ?: plan.points.lastOrNull()?.let { (latitude, longitude) -> LatLng(latitude, longitude) }
    return if (next == null) listOf(start) else listOf(start, next)
}

private fun tripPlanDirectDistanceText(origin: LatLng, destination: LatLng): String {
    val result = FloatArray(1)
    Location.distanceBetween(origin.latitude, origin.longitude, destination.latitude, destination.longitude, result)
    val meters = result[0].toDouble()
    return if (meters < 1_000) {
        "约${maxOf(1, meters.roundToInt())}米"
    } else {
        String.format(Locale.SIMPLIFIED_CHINESE, "约%.1f公里", meters / 1_000)
    }
}

private fun plannedItemTitle(item: TripItemEntity): String {
    if (item.kindRaw == "transport") {
        val type = TransportType.from(item.transportTypeRaw.orEmpty()).localizedName
        return item.lineName?.takeIf(String::isNotBlank)?.let { "$type · $it" } ?: type
    }
    return item.placeName ?: item.address ?: item.cityName ?: "地点"
}

private fun plannedItemAddress(item: TripItemEntity): String? {
    val title = plannedItemTitle(item)
    return item.address?.takeIf { it.isNotBlank() && it != title }
        ?: item.cityName?.takeIf { it.isNotBlank() && it != title }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripDetailScreen(
    trip: TripEntity,
    activityTypes: List<ActivityTypeEntity>,
    transportRecords: List<TransportRecordEntity>,
    showsLifecycleActions: Boolean = true,
    onBack: () -> Unit
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val dao = remember { AppDatabase.getInstance(context).tripDao() }
    val days by dao.observeDays(trip.id).collectAsState(initial = emptyList())
    val allCities by dao.observeAllCities().collectAsState(initial = emptyList())
    val allItems by dao.observeAllItems().collectAsState(initial = emptyList())
    val allFootprints by AppDatabase.getInstance(context).footprintDao().observeAll().collectAsState(initial = emptyList())
    val dayIDs = remember(days) { days.map { it.id }.toSet() }
    val cities = allCities.filter { it.tripDayID in dayIDs }
    val storedItems = allItems.filter { it.tripDayID in dayIDs }
    val items = if (trip.kindRaw == TripKind.HISTORICAL.raw) {
        actualTripItems(days, allFootprints, transportRecords)
    } else storedItems
    val scope = rememberCoroutineScope()
    var selectedTimelineItem by remember { mutableStateOf<TripItemEntity?>(null) }
    var selectedFootprintID by remember { mutableStateOf<String?>(null) }
    val sheetState = rememberStandardBottomSheetState(initialValue = SheetValue.Expanded, skipHiddenState = true)
    val sheetScrollState = rememberScrollState()
    val detailSheetHeight = LocalConfiguration.current.screenHeightDp.dp * 0.5f
    val detailSheetHeightPx = with(LocalDensity.current) { detailSheetHeight.roundToPx() }
    var showingEditor by remember { mutableStateOf(false) }

    BottomSheetScaffold(
        scaffoldState = rememberBottomSheetScaffoldState(sheetState),
        sheetPeekHeight = 72.dp,
        sheetContent = {
            val isExpanded = sheetState.currentValue == SheetValue.Expanded
            Column(
                Modifier
                    .fillMaxWidth()
                    .height(detailSheetHeight)
            ) {
                CenterAlignedTopAppBar(
                    title = {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(trip.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(tripHeaderSubtitle(trip), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    },
                    actions = { IconButton(onClick = { showingEditor = true }) { Icon(Icons.Default.Edit, "编辑行程") } }
                )
                if (isExpanded) {
                    Column(
                        Modifier.fillMaxWidth().weight(1f).verticalScroll(sheetScrollState).padding(horizontal = 18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                    activityTypes.firstOrNull { it.id == trip.activityTypeValue || it.name == trip.activityTypeValue }?.let { type ->
                        AssistChip(
                            onClick = {},
                            label = { Text(type.name) },
                            leadingIcon = { Icon(getIconForName(type.icon), null, tint = parseActivityColor(type.colorHex), modifier = Modifier.size(18.dp)) }
                        )
                    }
                    if (trip.notes.isNotBlank()) Text(trip.notes, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    days.forEachIndexed { dayIndex, day ->
                        val dayItems = items.filter { it.tripDayID == day.id }.sortedWith(
                            compareBy<TripItemEntity> { it.startTime }.thenBy { it.orderIndex }
                        )
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            TripDayTitleChip(
                                dayNumber = dayIndex + 1,
                                dateText = SimpleDateFormat("M月d日 E", Locale.SIMPLIFIED_CHINESE).format(day.day)
                            )
                            dayItems.forEach { item ->
                                TripTimelineRow(
                                    item = item,
                                    activityType = activityTypes.firstOrNull {
                                        it.id == item.activityTypeValue || it.name == item.activityTypeValue
                                    },
                                    transportRecord = item.sourceTransportRecordID?.let { sourceID ->
                                        transportRecords.firstOrNull { it.recordID == sourceID }
                                    },
                                    photoUris = item.sourceFootprintID?.let { sourceID ->
                                        allFootprints.firstOrNull { it.footprintID == sourceID }?.let(::tripFootprintPhotoUris)
                                    }.orEmpty(),
                                    onSelect = { selectedTimelineItem = item }
                                )
                            }
                        }
                    }
                    if (showsLifecycleActions) {
                        when (trip.state) {
                            TripState.PLANNED -> Button(onClick = { scope.launch { dao.upsertTrip(trip.copy(stateRaw = TripState.ACTIVE.raw, actualStartedAt = Date(), updatedAt = Date())) } }, Modifier.fillMaxWidth()) { Text("开始行程") }
                            TripState.ACTIVE -> Button(onClick = { scope.launch { dao.upsertTrip(trip.copy(kindRaw = TripKind.HISTORICAL.raw, stateRaw = TripState.HISTORICAL.raw, actualEndedAt = Date(), endReasonRaw = "manual", updatedAt = Date())) } }, Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("结束行程") }
                            else -> Unit
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                    }
                }
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            TripMap(
                cities = cities,
                items = items,
                footprints = allFootprints,
                activityTypes = activityTypes,
                transportRecords = transportRecords,
                selectedItem = selectedTimelineItem,
                bottomPaddingPx = detailSheetHeightPx,
                onOpenFootprint = { footprintID -> selectedFootprintID = footprintID }
            )
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                FloatingActionButton(onClick = onBack, modifier = Modifier.size(44.dp)) { Icon(Icons.Default.ArrowBack, "返回") }
            }
        }
    }
    if (showingEditor) {
        Dialog(onDismissRequest = { showingEditor = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            TripEditorScreen(trip = trip, activityTypes = activityTypes, dao = dao, onDismiss = { showingEditor = false })
        }
    }
    selectedFootprintID?.let { footprintID ->
        ModalBottomSheet(
            onDismissRequest = { selectedFootprintID = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
            scrimColor = Color.Transparent,
            dragHandle = { BottomSheetDefaults.DragHandle() }
        ) {
            FootprintDetailContent(
                footprintId = footprintID,
                onDismiss = { selectedFootprintID = null },
                modifier = Modifier.fillMaxWidth(),
                showMap = false
            )
        }
    }
}

@Composable
private fun TripDayTitleChip(dayNumber: Int, dateText: String?) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.9f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("第${dayNumber}天", fontWeight = FontWeight.Bold)
            dateText?.takeIf(String::isNotBlank)?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun tripHeaderSubtitle(trip: TripEntity): String {
    val calendar = Calendar.getInstance()
    calendar.time = trip.plannedStartDay
    val startYear = calendar.get(Calendar.YEAR)
    calendar.time = trip.plannedEndDay
    val endYear = calendar.get(Calendar.YEAR)
    val year = if (startYear == endYear) "${startYear}年" else "$startYear–${endYear}年"
    val days = tripInclusiveDayCount(trip.plannedStartDay, trip.plannedEndDay)
    return "$year · 共${days}天"
}

private fun tripInclusiveDayCount(start: Date, end: Date): Int {
    val calendar = Calendar.getInstance()
    var cursor = startOfLocalDay(start)
    val last = startOfLocalDay(end)
    var count = 1
    while (cursor.before(last)) {
        calendar.time = cursor
        calendar.add(Calendar.DAY_OF_YEAR, 1)
        cursor = calendar.time
        count += 1
    }
    return count
}

private data class TripItemEditTarget(val day: TripDayEntity, val item: TripItemEntity)
private data class TripPlaceTarget(val day: TripDayEntity, val item: TripItemEntity?)
private data class TripPlaceSelection(val result: GeocodeService.SearchResult, val details: GeocodeService.ReverseGeocodeResult)
private data class TripPlaceUpdate(val selection: TripPlaceSelection?, val arrivalTime: Date?)
private data class TripEditorCityGroup(
    val id: String,
    val key: String,
    val name: String,
    val storedCityID: String?,
    val stops: List<TripItemEntity>
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripEditorScreen(
    trip: TripEntity,
    activityTypes: List<ActivityTypeEntity>,
    dao: com.ct106.difangke.data.db.dao.TripDao,
    mode: PlannedTripEditorMode? = null,
    onDismiss: () -> Unit
) {
    val editsPlan = trip.state == TripState.PLANNED || trip.state == TripState.ACTIVE
    val homeCity by dao.observeHomeCity().collectAsState(initial = null)
    val observedDays by dao.observeDays(trip.id).collectAsState(initial = emptyList())
    val observedCities by dao.observeAllCities().collectAsState(initial = emptyList())
    val observedItems by dao.observeAllItems().collectAsState(initial = emptyList())
    val draftDays = remember { mutableStateListOf<TripDayEntity>() }
    val draftCities = remember { mutableStateListOf<TripDayCityEntity>() }
    val draftItems = remember { mutableStateListOf<TripItemEntity>() }
    var draftDirty by remember { mutableStateOf(false) }
    var draftLoaded by remember(trip.id) { mutableStateOf(!editsPlan) }
    LaunchedEffect(trip.id) {
        if (editsPlan) {
            val loadedDays = dao.getAllDays().filter { it.tripID == trip.id }.sortedBy { it.day }
            val dayIDs = loadedDays.map { it.id }.toSet()
            val loadedCities = dao.getAllCities().filter { it.tripDayID in dayIDs }.map { city ->
                val latitude = city.latitude
                val longitude = city.longitude
                if (!city.cityIdentifier.isNullOrBlank() || latitude == null || longitude == null) city
                else city.copy(cityIdentifier = runCatching {
                    GeocodeService.shared.resolveCityIdentifier(latitude, longitude, city.cityName, city.countryCode)
                }.getOrNull())
            }
            val loadedItems = migrateLegacyPlannedTransportItems(
                loadedDays,
                dao.getAllItems().filter { it.tripDayID in dayIDs }
            ).map { item ->
                val latitude = item.latitude
                val longitude = item.longitude
                val cityName = item.cityName
                if (!item.cityIdentifier.isNullOrBlank() || latitude == null || longitude == null || cityName.isNullOrBlank()) item
                else item.copy(cityIdentifier = runCatching {
                    GeocodeService.shared.resolveCityIdentifier(latitude, longitude, cityName, item.countryCode.orEmpty())
                }.getOrNull())
            }
            loadedCities.filter { it.cityIdentifier != null }.forEach { dao.upsertCity(it) }
            loadedItems.filter { it.cityIdentifier != null }.forEach { dao.upsertItem(it) }
            if (!draftDirty) {
                draftDays.clear(); draftDays.addAll(loadedDays)
                draftCities.clear(); draftCities.addAll(loadedCities)
                draftItems.clear(); draftItems.addAll(loadedItems)
            }
            draftLoaded = true
        }
    }
    val days: List<TripDayEntity> = if (editsPlan) draftDays else observedDays
    val allCities: List<TripDayCityEntity> = if (editsPlan) draftCities else observedCities
    val allItems: List<TripItemEntity> = if (editsPlan) draftItems else observedItems
    val orderedDraftStops = days.sortedWith(compareBy<TripDayEntity> { it.day }.thenBy { it.orderIndex })
        .flatMap { day -> allItems.filter { it.tripDayID == day.id && it.kindRaw == "stop" }.sortedBy { it.orderIndex } }
    var title by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(trip.title)) }
    var notes by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(trip.notes)) }
    var itemTarget by remember { mutableStateOf<TripItemEditTarget?>(null) }
    var placeTarget by remember { mutableStateOf<TripPlaceTarget?>(null) }
    var activityTypeValue by rememberSaveable { mutableStateOf(trip.activityTypeValue) }
    var planStartDay by remember { mutableStateOf(startOfLocalDay(trip.plannedStartDay)) }
    var planEndDay by remember { mutableStateOf(startOfLocalDay(trip.plannedEndDay)) }
    var hasPlannedDates by remember { mutableStateOf(trip.datesUserEdited) }
    var editorDateTarget by remember { mutableStateOf<PlanDateTarget?>(null) }
    var pendingShorterEnd by remember { mutableStateOf<Date?>(null) }
    var saving by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    var draggedDraftItemID by remember { mutableStateOf<String?>(null) }
    var draggedDraftOffsetY by remember { mutableFloatStateOf(0f) }
    var draggedDraftPointerY by remember { mutableFloatStateOf(0f) }
    val draftItemBounds = remember { mutableStateMapOf<String, Rect>() }
    val draftDayDropBounds = remember { mutableStateMapOf<String, Rect>() }

    fun finishDraftItemDrag() {
        val draggedID = draggedDraftItemID
        if (draggedID != null && moveTripDraftItem(
                items = draftItems,
                cities = draftCities,
                days = days,
                draggedID = draggedID,
                pointerY = draggedDraftPointerY,
                itemBounds = draftItemBounds,
                dayDropBounds = draftDayDropBounds
            )) {
            draftDirty = true
        }
        draggedDraftItemID = null
        draggedDraftOffsetY = 0f
        draggedDraftPointerY = 0f
    }

    Surface(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Text(when (mode) {
                            PlannedTripEditorMode.BASIC -> "基本信息"
                            PlannedTripEditorMode.ITINERARY -> "行程安排"
                            null -> if (editsPlan) "编辑计划" else "编辑行程"
                        })
                    },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "取消") } },
                    actions = {
                        TextButton(enabled = draftLoaded && !saving, onClick = {
                            saving = true
                            scope.launch {
                                val trimmedTitle = title.text.trim()
                                val titleChanged = trimmedTitle.isNotEmpty() && trimmedTitle != trip.title
                                val userEditedTitle = trimmedTitle.isNotEmpty() && (trip.titleUserEdited || titleChanged)
                                val savedTitle = if (editsPlan && !userEditedTitle) {
                                    automaticTripTitle(
                                        draftDays.sortedBy { it.day }.flatMap { day -> draftCities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex } }.map { it.cityName },
                                        draftDays.size
                                    )
                                } else trimmedTitle.ifEmpty { trip.title }
                                val updated = trip.copy(
                                    title = if (mode == PlannedTripEditorMode.ITINERARY) {
                                        if (trip.titleUserEdited) trip.title else savedTitle
                                    } else savedTitle,
                                    notes = if (mode == PlannedTripEditorMode.ITINERARY) trip.notes else notes.text,
                                    activityTypeValue = if (mode == PlannedTripEditorMode.ITINERARY) trip.activityTypeValue else activityTypeValue,
                                    titleUserEdited = if (mode == PlannedTripEditorMode.ITINERARY) trip.titleUserEdited else userEditedTitle,
                                    citiesUserEdited = trip.citiesUserEdited || draftDirty,
                                    datesUserEdited = if (mode == PlannedTripEditorMode.ITINERARY) trip.datesUserEdited else hasPlannedDates,
                                    plannedStartDay = if (mode == PlannedTripEditorMode.ITINERARY) trip.plannedStartDay else planStartDay,
                                    plannedEndDay = if (mode == PlannedTripEditorMode.ITINERARY) trip.plannedEndDay else planEndDay,
                                    actualEndedAt = if (
                                        trip.stateRaw == TripState.PLANNED.raw &&
                                        trip.endReasonRaw == "corrected" &&
                                        (startOfLocalDay(trip.plannedStartDay) != startOfLocalDay(planStartDay) ||
                                            startOfLocalDay(trip.plannedEndDay) != startOfLocalDay(planEndDay))
                                    ) null else trip.actualEndedAt,
                                    endReasonRaw = if (
                                        trip.stateRaw == TripState.PLANNED.raw &&
                                        trip.endReasonRaw == "corrected" &&
                                        (startOfLocalDay(trip.plannedStartDay) != startOfLocalDay(planStartDay) ||
                                            startOfLocalDay(trip.plannedEndDay) != startOfLocalDay(planEndDay))
                                    ) null else trip.endReasonRaw,
                                    updatedAt = Date()
                                )
                                runCatching {
                                    if (editsPlan) {
                                        dao.replacePlan(updated, draftDays.toList(), draftCities.toList(), draftItems.toList())
                                    } else {
                                        dao.upsertTrip(updated)
                                    }
                                }.onSuccess {
                                    onDismiss()
                                }.onFailure {
                                    saving = false
                                    saveError = "你的修改还在当前页面，请稍后再试。"
                                }
                            }
                        }) { Text("保存") }
                    }
                )
            }
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                if (mode != PlannedTripEditorMode.ITINERARY) {
                    OutlinedTextField(title, { title = it }, label = { Text("标题") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(notes, { notes = it }, label = { Text("备注") }, modifier = Modifier.fillMaxWidth())
                    TripActivityTypeMenu(activityTypes, activityTypeValue) { activityTypeValue = it }
                    if (!editsPlan) {
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.CalendarMonth, null)
                                Spacer(Modifier.width(8.dp))
                                Text("行程内容", fontWeight = FontWeight.Bold)
                            }
                            Text("足迹和交通来自记录页；在记录页修改后，这里会自动同步。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                            days.forEach { day ->
                                Text(SimpleDateFormat("yyyy年M月d日 EEEE", Locale.SIMPLIFIED_CHINESE).format(day.day))
                            }
                        }
                    }
                    } else {
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("行程日期", fontWeight = FontWeight.Bold)
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text("设置日期", Modifier.weight(1f))
                                Switch(checked = hasPlannedDates, onCheckedChange = { hasPlannedDates = it })
                            }
                            if (hasPlannedDates) {
                                OutlinedButton(
                                    onClick = { editorDateTarget = PlanDateTarget.Start },
                                    enabled = draftLoaded,
                                    modifier = Modifier.fillMaxWidth()
                                ) { Text("开始日期 ${formatShortDate(planStartDay)}") }
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("行程天数", modifier = Modifier.weight(1f))
                                OutlinedButton(
                                    onClick = { pendingShorterEnd = addLocalDays(planEndDay, -1) },
                                    enabled = draftLoaded && draftDays.size > 1
                                ) { Icon(Icons.Default.Remove, "减少一天") }
                                Text("${draftDays.size.coerceAtLeast(1)}天", Modifier.padding(horizontal = 14.dp), fontWeight = FontWeight.SemiBold)
                                OutlinedButton(
                                    onClick = {
                                        if (draftDays.size < AppConfig.TRIP_MAXIMUM_DURATION_DAYS) {
                                            val nextDay = addLocalDays(planStartDay, draftDays.size)
                                            draftDays += TripDayEntity(tripID = trip.id, day = nextDay, orderIndex = draftDays.size)
                                            planEndDay = nextDay
                                            draftDirty = true
                                        }
                                    },
                                    enabled = draftLoaded && draftDays.size < AppConfig.TRIP_MAXIMUM_DURATION_DAYS
                                ) { Icon(Icons.Default.Add, "添加一天") }
                            }
                            if (hasPlannedDates) {
                                Text("结束日期 ${formatShortDate(planEndDay)}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    }
                }
                if (editsPlan && mode != PlannedTripEditorMode.BASIC) {
                    if (!draftLoaded) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 28.dp), horizontalArrangement = Arrangement.Center) {
                            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                        }
                    }
                    days.forEachIndexed { dayIndex, day ->
                    val dayItems = allItems.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                    val stops = dayItems.filter { it.kindRaw == "stop" }
                    TripDayTitleChip(
                        dayNumber = dayIndex + 1,
                        dateText = SimpleDateFormat("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)
                            .format(day.day)
                            .takeIf { hasPlannedDates }
                    )
                    val storedCities = allCities.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                    val storedByKey = storedCities.associateBy { tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) }
                    val cityGroups = mutableListOf<TripEditorCityGroup>()
                    val representedCityKeys = mutableSetOf<String>()
                    stops.forEach { stop ->
                        val cityName = stop.cityName?.takeIf(String::isNotBlank) ?: "未识别城市"
                        val key = tripCityIdentityKey(stop.cityIdentifier, stop.countryCode, cityName)
                        representedCityKeys += key
                        val last = cityGroups.lastOrNull()
                        if (last?.key == key) {
                            cityGroups[cityGroups.lastIndex] = last.copy(stops = last.stops + stop)
                        } else {
                            cityGroups += TripEditorCityGroup("$key#${cityGroups.size}", key, cityName, storedByKey[key]?.id, listOf(stop))
                        }
                    }
                    val appendedEmptyCityKeys = mutableSetOf<String>()
                    storedCities.filterNot { tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) in representedCityKeys }.forEach { city ->
                        val key = tripCityIdentityKey(city.cityIdentifier, city.countryCode, city.cityName)
                        if (appendedEmptyCityKeys.add(key)) {
                            cityGroups += TripEditorCityGroup("$key#empty", key, city.cityName, city.id, emptyList())
                        }
                    }
                    cityGroups.forEach { group ->
                        val cityStops = group.stops
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(group.name, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                            if (cityStops.isEmpty()) {
                                IconButton(onClick = {
                                    val cityID = group.storedCityID
                                    if (cityID != null) {
                                        draftCities.removeAll { it.id == cityID }
                                        draftDirty = true
                                    }
                                }, modifier = Modifier.size(48.dp)) {
                                    Icon(Icons.Default.RemoveCircleOutline, "移除城市", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                        cityStops.forEach { stop ->
                            val origin = plannedRouteOrigin(stop, orderedDraftStops, homeCity)
                            val activity = activityTypes.firstOrNull { it.id == stop.activityTypeValue || it.name == stop.activityTypeValue }
                            val activityTint = parseActivityColor(activity?.colorHex)
                            var stopMenu by remember(stop.id) { mutableStateOf(false) }
                            if (origin != null) {
                                val hasTransport = !stop.transportTypeRaw.isNullOrBlank()
                                TextButton(
                                    onClick = { itemTarget = TripItemEditTarget(day, stop) },
                                    modifier = Modifier.padding(start = 16.dp)
                                ) {
                                    Icon(
                                        if (hasTransport) timelineTransportIcon(stop.transportTypeRaw.orEmpty()) else Icons.Default.AddCircleOutline,
                                        null
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                                        Text(if (hasTransport) "前往${tripItemEditorTitle(stop)}" else "设置前往${tripItemEditorTitle(stop)}的方式")
                                        if (hasTransport) {
                                            Text(
                                                tripPlanTransportSummary(stop, origin),
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        }
                                    }
                                    Icon(Icons.Default.ChevronRight, null, Modifier.size(16.dp))
                                }
                            }
                            Box {
                                Surface(
                                    shape = RoundedCornerShape(16.dp),
                                    color = MaterialTheme.colorScheme.surfaceVariant,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onGloballyPositioned { coordinates ->
                                            if (draggedDraftItemID != stop.id) draftItemBounds[stop.id] = coordinates.boundsInRoot()
                                        }
                                        .offset {
                                            IntOffset(0, if (draggedDraftItemID == stop.id) draggedDraftOffsetY.roundToInt() else 0)
                                        }
                                        .zIndex(if (draggedDraftItemID == stop.id) 10f else 0f)
                                        .combinedClickable(
                                            onClick = { placeTarget = TripPlaceTarget(day, stop) },
                                            onLongClick = { stopMenu = true }
                                        )
                                ) {
                                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Box(Modifier.size(38.dp).clip(CircleShape).background(activityTint.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                                            Icon(getIconForName(activity?.icon ?: "place"), null, tint = activityTint, modifier = Modifier.size(20.dp))
                                        }
                                        Spacer(Modifier.width(12.dp))
                                        Column(Modifier.weight(1f)) {
                                            Text(tripItemEditorTitle(stop), style = MaterialTheme.typography.titleMedium)
                                            val detail = listOfNotNull(
                                                stop.startTime?.let {
                                                    SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE).format(it)
                                                },
                                                activity?.name
                                            ).joinToString(" · ")
                                            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            stop.address?.takeIf { it.isNotBlank() && it != stop.placeName }?.let { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                        }
                                        Icon(Icons.Default.DragHandle, "拖动地点", Modifier.size(48.dp).pointerInput(stop.id) {
                                            detectDragGesturesAfterLongPress(
                                                onDragStart = { local ->
                                                    draggedDraftItemID = stop.id
                                                    draggedDraftOffsetY = 0f
                                                    draggedDraftPointerY = (draftItemBounds[stop.id]?.top ?: 0f) + local.y
                                                },
                                                onDrag = { change, amount ->
                                                    change.consume()
                                                    draggedDraftOffsetY += amount.y
                                                    draggedDraftPointerY += amount.y
                                                },
                                                onDragEnd = { finishDraftItemDrag() },
                                                onDragCancel = { finishDraftItemDrag() }
                                            )
                                        }.padding(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                DropdownMenu(expanded = stopMenu, onDismissRequest = { stopMenu = false }) {
                                    DropdownMenuItem(text = { Text("删除地点") }, leadingIcon = { Icon(Icons.Default.DeleteOutline, null) }, onClick = {
                                        stopMenu = false
                                        draftItems.removeAll { it.id == stop.id }
                                        normalizeDraftItems(draftItems, day.id)
                                        draftDirty = true
                                    })
                                }
                            }
                        }
                    }
                    if (stops.isEmpty()) {
                        Text("还没有安排，先添加一个想去的地点。", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TripAddPlaceCard(
                        onClick = { placeTarget = TripPlaceTarget(day, null) },
                        modifier = Modifier.onGloballyPositioned { draftDayDropBounds[day.id] = it.boundsInRoot() }
                    )
                    HorizontalDivider()
                    }
                }
            }
        }
    }

    editorDateTarget?.let { target ->
        val initial = if (target == PlanDateTarget.Start) planStartDay else planEndDay
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = pickerMillisForLocalDate(initial))
        DatePickerDialog(
            onDismissRequest = { editorDateTarget = null },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { selectedMillis ->
                        val selected = localDateFromPickerMillis(selectedMillis)
                        if (target == PlanDateTarget.Start) {
                            val offset = localDayDifference(planStartDay, selected)
                            planStartDay = selected
                            planEndDay = addLocalDays(planEndDay, offset)
                            draftDays.indices.forEach { index -> draftDays[index] = draftDays[index].copy(day = addLocalDays(draftDays[index].day, offset)) }
                            draftItems.indices.forEach { index ->
                                val item = draftItems[index]
                                draftItems[index] = item.copy(
                                    startTime = item.startTime?.let { addLocalDays(it, offset) },
                                    endTime = item.endTime?.let { addLocalDays(it, offset) }
                                )
                            }
                            draftDirty = true
                        } else {
                            val resolvedEnd = maxOf(planStartDay, selected)
                            val newCount = tripDayTimes(planStartDay, resolvedEnd).size
                            if (newCount < draftDays.size) {
                                pendingShorterEnd = resolvedEnd
                            } else {
                                for (index in draftDays.size until newCount) {
                                    draftDays += TripDayEntity(tripID = trip.id, day = addLocalDays(planStartDay, index), orderIndex = index)
                                }
                                planEndDay = resolvedEnd
                                draftDirty = true
                            }
                        }
                    }
                    editorDateTarget = null
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { editorDateTarget = null }) { Text("取消") } }
        ) { DatePicker(pickerState) }
    }

    pendingShorterEnd?.let { shorterEnd ->
        val newCount = tripDayTimes(planStartDay, shorterEnd).size
        val removedDays = draftDays.sortedBy { it.day }.drop(newCount)
        val removedIDs = removedDays.map { it.id }.toSet()
        val removedCityCount = draftCities.count { it.tripDayID in removedIDs }
        val removedItemCount = draftItems.count { it.tripDayID in removedIDs }
        AlertDialog(
            onDismissRequest = { pendingShorterEnd = null },
            title = { Text("缩短行程？") },
            text = { Text("将移除最后${removedDays.size}天、${removedCityCount}座城市安排和${removedItemCount}个地点或交通。原始足迹与交通不会改变。") },
            confirmButton = {
                TextButton(onClick = {
                    draftDays.removeAll { it.id in removedIDs }
                    draftCities.removeAll { it.tripDayID in removedIDs }
                    draftItems.removeAll { it.tripDayID in removedIDs }
                    draftDays.indices.forEach { index -> draftDays[index] = draftDays[index].copy(orderIndex = index) }
                    planEndDay = shorterEnd
                    draftDirty = true
                    pendingShorterEnd = null
                }) { Text("缩短", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { pendingShorterEnd = null }) { Text("取消") } }
        )
    }

    saveError?.let { message ->
        AlertDialog(
            onDismissRequest = { saveError = null },
            title = { Text("没有保存成功") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { saveError = null }) { Text("知道了") } }
        )
    }

    placeTarget?.let { target ->
        val preferredCityName = target.item?.cityName ?: allCities
            .filter { it.tripDayID == target.day.id }
            .maxByOrNull { it.orderIndex }
            ?.cityName
        TripPlaceEditorDialog(target = target, preferredCityName = preferredCityName, onDismiss = { placeTarget = null }) { update ->
            val selection = update.selection
            val base = target.item ?: TripItemEntity(tripDayID = target.day.id, kindRaw = "stop", orderIndex = allItems.count { it.tripDayID == target.day.id })
            val updatedItem = base.copy(
                placeName = selection?.result?.name ?: base.placeName,
                address = selection?.result?.address ?: base.address,
                latitude = selection?.result?.latitude ?: base.latitude,
                longitude = selection?.result?.longitude ?: base.longitude,
                countryCode = selection?.details?.countryCode ?: base.countryCode,
                countryName = selection?.details?.countryName ?: base.countryName,
                cityName = selection?.details?.cityName ?: base.cityName,
                cityIdentifier = selection?.details?.cityIdentifier ?: base.cityIdentifier,
                startTime = update.arrivalTime,
                endTime = null
            )
            val itemIndex = draftItems.indexOfFirst { it.id == updatedItem.id }
            if (itemIndex >= 0) draftItems[itemIndex] = updatedItem else draftItems += updatedItem
            if (selection != null) {
                val result = selection.result
                val details = selection.details
                val key = tripCityIdentityKey(details.cityIdentifier, details.countryCode, details.cityName)
                if (!details.cityName.isNullOrBlank() && draftCities.none {
                        it.tripDayID == target.day.id &&
                            tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) == key
                    }) {
                    draftCities += TripDayCityEntity(tripDayID = target.day.id, countryCode = details.countryCode.orEmpty(), countryName = details.countryName.orEmpty(), cityName = details.cityName, cityIdentifier = details.cityIdentifier, latitude = result.latitude, longitude = result.longitude, orderIndex = draftCities.count { it.tripDayID == target.day.id })
                }
            }
            draftDirty = true
            placeTarget = null
        }
    }
    itemTarget?.let { target ->
        TripItemEditorDialog(target = target, onDismiss = { itemTarget = null }) { item ->
            val index = draftItems.indexOfFirst { it.id == item.id }
            if (index >= 0) draftItems[index] = item
            draftDirty = true
            itemTarget = null
        }
    }
}

@Composable
private fun TripAddPlaceCard(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)),
        modifier = modifier.fillMaxWidth()
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(38.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Add, null, tint = MaterialTheme.colorScheme.primary)
            }
            Spacer(Modifier.width(12.dp))
            Text("添加地点", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
            Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        }
    }
}

private fun normalizeDraftItems(items: MutableList<TripItemEntity>, dayID: String) {
    val normalized = items.filter { it.tripDayID == dayID && it.kindRaw == "stop" }.sortedBy { it.orderIndex }
        .mapIndexed { index, item -> item.copy(orderIndex = index) }
    items.removeAll { it.tripDayID == dayID }
    items.addAll(normalized)
}

private fun migrateLegacyPlannedTransportItems(
    days: List<TripDayEntity>,
    items: List<TripItemEntity>
): List<TripItemEntity> {
    val dayOrder = days.sortedWith(compareBy<TripDayEntity> { it.day }.thenBy { it.orderIndex })
        .mapIndexed { index, day -> day.id to index }.toMap()
    val ordered = items.filter { it.tripDayID in dayOrder }
        .sortedWith(compareBy<TripItemEntity> { dayOrder[it.tripDayID] ?: Int.MAX_VALUE }.thenBy { it.orderIndex })
    if (ordered.none { it.kindRaw == "transport" }) {
        return ordered.filter { it.kindRaw == "stop" }
    }
    val stopsByID = ordered.filter { it.kindRaw == "stop" }.associateBy { it.id }.toMutableMap()
    ordered.forEachIndexed { index, transport ->
        if (transport.kindRaw != "transport") return@forEachIndexed
        val destination = ordered.drop(index + 1).firstOrNull { it.kindRaw == "stop" } ?: return@forEachIndexed
        stopsByID[destination.id] = (stopsByID[destination.id] ?: destination).copy(
            transportTypeRaw = transport.transportTypeRaw,
            lineName = transport.lineName
        )
    }
    return days.flatMap { day ->
        ordered.filter { it.tripDayID == day.id && it.kindRaw == "stop" }.mapIndexed { index, stop ->
            val migrated = stopsByID[stop.id] ?: stop
            migrated.copy(orderIndex = index)
        }
    }
}

private fun moveTripDraftItem(
    items: MutableList<TripItemEntity>,
    cities: MutableList<TripDayCityEntity>,
    days: List<TripDayEntity>,
    draggedID: String,
    pointerY: Float,
    itemBounds: Map<String, Rect>,
    dayDropBounds: Map<String, Rect>
): Boolean {
    val dragged = items.firstOrNull { it.id == draggedID } ?: return false
    val sourceDayID = dragged.tripDayID
    val sourceItems = items.filter { it.tripDayID == sourceDayID && it.kindRaw == "stop" }.sortedBy { it.orderIndex }
    val sourceIndex = sourceItems.indexOfFirst { it.id == draggedID }
    if (sourceIndex < 0) return false

    val moving = listOf(dragged)
    val movingIDs = moving.map { it.id }.toSet()

    val targetDayID = dayDropBounds.entries.firstOrNull { pointerY in it.value.top..it.value.bottom }?.key
        ?: itemBounds.entries
            .filter { it.key !in movingIDs }
            .minByOrNull { abs(it.value.center.y - pointerY) }
            ?.key
            ?.let { id -> items.firstOrNull { it.id == id }?.tripDayID }
        ?: dayDropBounds.entries.minByOrNull { abs(it.value.center.y - pointerY) }?.key
        ?: sourceDayID
    if (days.none { it.id == targetDayID }) return false

    val remainingSource = sourceItems.filter { it.id !in movingIDs }
    val targetItems = (if (targetDayID == sourceDayID) remainingSource else items.filter { it.tripDayID == targetDayID && it.kindRaw == "stop" }.sortedBy { it.orderIndex }).toMutableList()
    val targetID = targetItems
        .filter { itemBounds.containsKey(it.id) }
        .firstOrNull { (itemBounds[it.id]?.center?.y ?: Float.MAX_VALUE) > pointerY }
        ?.id
    var insertion = targetID?.let { id -> targetItems.indexOfFirst { it.id == id } }?.takeIf { it >= 0 } ?: targetItems.size
    targetItems.addAll(insertion.coerceIn(0, targetItems.size), moving.map { it.copy(tripDayID = targetDayID) })
    items.removeAll { it.tripDayID == sourceDayID || it.tripDayID == targetDayID }
    if (sourceDayID != targetDayID) {
        items.addAll(remainingSource.mapIndexed { index, item -> item.copy(orderIndex = index) })
    }
    items.addAll(targetItems.mapIndexed { index, item -> item.copy(orderIndex = index) })

    if (sourceDayID != targetDayID) {
        val cityName = dragged.cityName?.takeIf { it.isNotBlank() }
        if (cityName != null) {
            val countryCode = dragged.countryCode.orEmpty()
            val key = tripCityIdentityKey(dragged.cityIdentifier, countryCode, cityName)
            if (cities.none {
                    it.tripDayID == targetDayID &&
                        tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) == key
                }) {
                cities += TripDayCityEntity(
                    tripDayID = targetDayID,
                    countryCode = countryCode,
                    countryName = dragged.countryName.orEmpty(),
                    cityName = cityName,
                    cityIdentifier = dragged.cityIdentifier,
                    latitude = dragged.latitude,
                    longitude = dragged.longitude,
                    orderIndex = cities.count { it.tripDayID == targetDayID }
                )
            }
            val sourceStillUsesCity = items.any {
                it.tripDayID == sourceDayID && it.kindRaw == "stop" &&
                    tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) == key
            }
            if (!sourceStillUsesCity) {
                cities.removeAll {
                    it.tripDayID == sourceDayID &&
                        tripCityIdentityKey(it.cityIdentifier, it.countryCode, it.cityName) == key
                }
            }
        }
    }
    return true
}

private fun tripTransportTitle(item: TripItemEntity): String {
    val type = TransportType.from(item.transportTypeRaw.orEmpty()).localizedName
    return item.lineName?.takeIf(String::isNotBlank)?.let { "$type · $it" } ?: type
}

private fun tripPlanTransportSummary(destination: TripItemEntity, origin: TripItemEntity): String {
    val latitude = origin.latitude ?: return tripTransportTitle(destination)
    val longitude = origin.longitude ?: return tripTransportTitle(destination)
    return tripPlanTransportSummary(
        destination,
        TripPlanOrigin(
            origin.placeName ?: origin.address ?: origin.cityName ?: "上一站",
            latitude,
            longitude
        )
    )
}

private fun tripPlanTransportSummary(destination: TripItemEntity, origin: TripPlanOrigin): String {
    val parts = mutableListOf(tripTransportTitle(destination))
    val distance = tripPlanDirectDistanceText(origin, destination)
    if (distance != null) parts += distance
    return parts.joinToString(" · ")
}

private fun plannedRouteSummary(
    destination: TripItemEntity,
    origin: TripPlanOrigin,
    routePlan: GeocodeService.RoutePlan?
): String {
    if (routePlan == null) return tripPlanTransportSummary(destination, origin)
    val distance = if (routePlan.distanceMeters < 1_000) {
        "${routePlan.distanceMeters.toInt().coerceAtLeast(1)}米"
    } else {
        String.format(Locale.SIMPLIFIED_CHINESE, "%.1f公里", routePlan.distanceMeters / 1_000)
    }
    return buildList {
        add(tripTransportTitle(destination))
        add(distance)
        if (routePlan.durationMinutes > 0) add("约${routePlan.durationMinutes.toInt().coerceAtLeast(1)}分钟")
    }.joinToString(" · ")
}

private fun plannedRouteSummary(
    destination: TripItemEntity,
    origin: TripItemEntity,
    routePlan: GeocodeService.RoutePlan?
): String {
    val latitude = origin.latitude ?: return tripTransportTitle(destination)
    val longitude = origin.longitude ?: return tripTransportTitle(destination)
    return plannedRouteSummary(
        destination,
        TripPlanOrigin(origin.placeName ?: origin.address ?: origin.cityName ?: "上一站", latitude, longitude),
        routePlan
    )
}

private fun plannedRouteGuidance(routePlan: GeocodeService.RoutePlan?): String? {
    val instructions = routePlan?.instructions.orEmpty()
    if (instructions.isEmpty()) return null
    return instructions.joinToString(" → ") { instruction ->
        if (instruction.title == "步行") return@joinToString instruction.title
        val stations = instruction.detail.orEmpty().split("·")
            .map(String::trim)
            .filter { it.endsWith("上车") || it.endsWith("下车") }
        if (stations.isEmpty()) instruction.title else "${instruction.title}：${stations.joinToString(" → ")}"
    }
}

private fun tripPlanDirectDistanceText(origin: TripPlanOrigin, destination: TripItemEntity): String? {
    val originLatitude = origin.latitude
    val originLongitude = origin.longitude
    val destinationLatitude = destination.latitude ?: return null
    val destinationLongitude = destination.longitude ?: return null
    val result = FloatArray(1)
    Location.distanceBetween(originLatitude, originLongitude, destinationLatitude, destinationLongitude, result)
    val meters = result[0].toDouble()
    return if (meters < 1_000) "约${maxOf(1, meters.roundToInt())}米" else String.format(Locale.SIMPLIFIED_CHINESE, "约%.1f公里", meters / 1_000)
}

private fun tripItemEditorTitle(item: TripItemEntity): String = if (item.kindRaw == "transport") {
    val type = TransportType.from(item.transportTypeRaw.orEmpty()).localizedName
    item.lineName?.takeIf { it.isNotBlank() }?.let { "$type · $it" } ?: type
} else item.placeName ?: item.address ?: item.cityName ?: "足迹"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripPlaceEditorDialog(
    target: TripPlaceTarget,
    preferredCityName: String?,
    onDismiss: () -> Unit,
    onSave: (TripPlaceUpdate) -> Unit
) {
    val context = LocalContext.current
    var selectedPlace by remember(target.item?.id) { mutableStateOf<TripPlaceSelection?>(null) }
    var showingSearch by remember { mutableStateOf(false) }
    var hasArrivalTime by rememberSaveable(target.item?.id) { mutableStateOf(target.item?.startTime != null) }
    var arrivalTimeMillis by rememberSaveable(target.item?.id) {
        mutableStateOf(target.item?.startTime?.time ?: Calendar.getInstance().apply {
            time = target.day.day
            set(Calendar.HOUR_OF_DAY, 9)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis)
    }
    val placeName = selectedPlace?.result?.name ?: target.item?.placeName ?: target.item?.address

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = { Text(if (target.item == null) "添加地点" else "编辑地点") },
                        navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "取消") } },
                        actions = {
                            TextButton(
                                enabled = placeName != null,
                                onClick = { onSave(TripPlaceUpdate(selectedPlace, if (hasArrivalTime) Date(arrivalTimeMillis) else null)) }
                            ) { Text(if (target.item == null) "添加" else "保存") }
                        }
                    )
                }
            ) { padding ->
                Column(
                    Modifier.padding(padding).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    Surface(
                        onClick = { showingSearch = true },
                        shape = RoundedCornerShape(16.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Place, null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.width(12.dp))
                            Text(placeName ?: "选择地点", Modifier.weight(1f))
                            Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                        Column {
                            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("到达时间", Modifier.weight(1f))
                                Switch(checked = hasArrivalTime, onCheckedChange = { hasArrivalTime = it })
                            }
                            if (hasArrivalTime) {
                                HorizontalDivider()
                                val formattedTime = remember(arrivalTimeMillis) {
                                    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(arrivalTimeMillis))
                                }
                                ListItem(
                                    headlineContent = { Text("时间") },
                                    trailingContent = { Text(formattedTime, color = MaterialTheme.colorScheme.primary) },
                                    modifier = Modifier.clickable {
                                        val initial = Calendar.getInstance().apply { timeInMillis = arrivalTimeMillis }
                                        android.app.TimePickerDialog(
                                            context,
                                            { _, hour, minute ->
                                                arrivalTimeMillis = Calendar.getInstance().apply {
                                                    time = target.day.day
                                                    set(Calendar.HOUR_OF_DAY, hour)
                                                    set(Calendar.MINUTE, minute)
                                                    set(Calendar.SECOND, 0)
                                                    set(Calendar.MILLISECOND, 0)
                                                }.timeInMillis
                                            },
                                            initial.get(Calendar.HOUR_OF_DAY),
                                            initial.get(Calendar.MINUTE),
                                            true
                                        ).show()
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if (showingSearch) {
        TripPlaceSearchDialog(
            preferredCityName = selectedPlace?.details?.cityName ?: preferredCityName,
            onDismiss = { showingSearch = false }
        ) { selection ->
            selectedPlace = selection
            showingSearch = false
        }
    }
}

@Composable
private fun TripPlaceSearchDialog(
    preferredCityName: String?,
    onDismiss: () -> Unit,
    onSelect: (TripPlaceSelection) -> Unit
) {
    val scope = rememberCoroutineScope()
    var query by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
    var results by remember { mutableStateOf<List<GeocodeService.SearchResult>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var resolving by remember { mutableStateOf(false) }
    var resolutionError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(query.text) {
        val value = query.text.trim()
        if (value.isEmpty()) { results = emptyList(); searching = false; return@LaunchedEffect }
        val city = preferredCityName?.trim().orEmpty()
        val cityStem = city.removeSuffix("市")
        val searchKeyword = if (city.isNotEmpty() && !value.startsWith(city) && !value.startsWith(cityStem)) "$city $value" else value
        kotlinx.coroutines.delay(400); searching = true
        results = runCatching { GeocodeService.shared.searchPlaces(searchKeyword) }.getOrDefault(emptyList())
        searching = false
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column {
                Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "取消") }
                    Text("选择地点", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                }
                OutlinedTextField(query, { query = it }, placeholder = { Text("搜索地点") }, leadingIcon = { Icon(Icons.Default.Search, null) }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                if (searching || resolving) LinearProgressIndicator(Modifier.fillMaxWidth())
                resolutionError?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                }
                LazyColumn {
                    items(results, key = { "${it.name}|${it.latitude}|${it.longitude}" }) { result ->
                        ListItem(
                            headlineContent = { Text(result.name) },
                            supportingContent = { Text(result.address, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            modifier = Modifier.clickable(enabled = !resolving) {
                                resolving = true
                                resolutionError = null
                                scope.launch {
                                    val details = runCatching { GeocodeService.shared.reverseGeocodeDetails(result.latitude, result.longitude) }.getOrNull()
                                    val resolvedDetails = details?.takeIf { !it.cityName.isNullOrBlank() }
                                    if (resolvedDetails != null) {
                                        onSelect(TripPlaceSelection(result, resolvedDetails))
                                    } else {
                                        resolving = false
                                        resolutionError = "暂时无法确定这个地点所在的城市，请稍后重试或选择其他结果。"
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TripItemEditorDialog(
    target: TripItemEditTarget,
    onDismiss: () -> Unit,
    onSave: (TripItemEntity) -> Unit
) {
    val original = target.item
    var lineName by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(original.lineName.orEmpty())) }
    var transportTypeRaw by rememberSaveable { mutableStateOf(original.transportTypeRaw.orEmpty()) }
    var typeMenuExpanded by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("前往${original.placeName ?: original.cityName ?: "下一站"}") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box {
                    OutlinedButton(onClick = { typeMenuExpanded = true }, Modifier.fillMaxWidth()) {
                        val selectedType = transportTypeRaw.takeIf(String::isNotBlank)?.let { TransportType.from(it) }
                        Icon(selectedType?.let { timelineTransportIcon(it.raw) } ?: Icons.Default.RemoveCircleOutline, null)
                        Spacer(Modifier.width(8.dp))
                        Text(selectedType?.localizedName ?: "未设置")
                    }
                    DropdownMenu(expanded = typeMenuExpanded, onDismissRequest = { typeMenuExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text("未设置") },
                            leadingIcon = { Icon(Icons.Default.RemoveCircleOutline, null) },
                            onClick = { transportTypeRaw = ""; typeMenuExpanded = false }
                        )
                        TransportType.entries.forEach { type ->
                            DropdownMenuItem(
                                text = { Text(type.localizedName) },
                                leadingIcon = { Icon(timelineTransportIcon(type.raw), null) },
                                onClick = { transportTypeRaw = type.raw; typeMenuExpanded = false }
                            )
                        }
                    }
                }
                OutlinedTextField(lineName, { lineName = it }, label = { Text("线路（可选）") })
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(original.copy(
                    transportTypeRaw = transportTypeRaw.ifBlank { null },
                    lineName = if (transportTypeRaw.isBlank()) null else lineName.text.trim().ifBlank { null }
                ))
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
private fun TripTimelineRow(
    item: TripItemEntity,
    activityType: ActivityTypeEntity?,
    transportRecord: TransportRecordEntity?,
    photoUris: List<String>,
    onSelect: () -> Unit
) {
    val isTransport = item.kindRaw == "transport"
    val start = item.startTime
    val end = item.endTime
    val timeFormat = remember { SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE) }
    val spacing = TimelineLayout.minItemSpacing

    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).height(IntrinsicSize.Min).clickable(onClick = onSelect),
        verticalAlignment = Alignment.Top
    ) {
        Text(
            start?.let(timeFormat::format).orEmpty(),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = FontFamily.Monospace,
            color = if (isTransport) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.width(TimelineLayout.timeColumnWidth).padding(top = 4.dp)
        )
        Spacer(Modifier.width(TimelineLayout.markerSpacing))
        Column(
            Modifier.width(TimelineLayout.markerSize).fillMaxHeight(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            if (isTransport) {
                TimelineTransportMarker(item.transportTypeRaw.orEmpty())
            } else {
                val tint = parseActivityColor(activityType?.colorHex)
                TimelineFootprintMarker(activityType?.icon ?: "place", tint)
            }
            Box(Modifier.width(2.dp).weight(1f).background(timelineLineColor()))
        }
        Spacer(Modifier.width(TimelineLayout.markerSpacing))
        if (isTransport) {
            val duration = if (start != null && end != null) formattedTimelineDuration((end.time - start.time) / 1000) else ""
            val distance = transportRecord?.let { formattedTimelineDistance(it.distance) }.orEmpty()
            Text(
                listOf(distance, duration)
                    .filter { it.isNotBlank() }
                    .joinToString(" · "),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(top = 5.dp, bottom = spacing)
            )
        } else {
            Column(Modifier.weight(1f).padding(bottom = spacing), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    item.placeName ?: item.address ?: item.cityName ?: "未知地点",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2
                )
                val duration = if (start != null && end != null) formattedTimelineDuration((end.time - start.time) / 1000) else ""
                Text(
                    listOf(activityType?.name.orEmpty(), duration).filter { it.isNotBlank() }.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (item.notes.isNotBlank()) {
                    Text(item.notes, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 5)
                }
                if (photoUris.isNotEmpty()) {
                    TripFootprintPhotoGrid(photoUris.take(9), Modifier.padding(top = 2.dp))
                }
            }
        }
    }
}

private fun tripFootprintPhotoUris(footprint: FootprintEntity): List<String> = runCatching {
    val array = JSONArray(footprint.photoAssetIDsJson)
    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }.distinct()
}.getOrDefault(emptyList())

@Composable
private fun TripFootprintPhotoGrid(uris: List<String>, modifier: Modifier = Modifier) {
    val visibleUris = uris.take(9)
    val columns = when (visibleUris.size) {
        0, 1 -> 1
        2 -> 2
        else -> 3
    }
    val cellSize = if (columns == 1) 210.dp else 72.dp
    val gridWidth = when (columns) {
        1 -> 210.dp
        2 -> 149.dp
        else -> 226.dp
    }
    var previewUri by remember(visibleUris) { mutableStateOf<String?>(null) }

    Column(modifier.width(gridWidth), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        visibleUris.chunked(columns).forEach { rowUris ->
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                rowUris.forEach { uri ->
                    TripPhotoImage(
                        uri,
                        Modifier.size(cellSize).clickable { previewUri = uri },
                        targetPixels = 500,
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop
                    )
                }
            }
        }
    }

    previewUri?.let { uri ->
        Dialog(
            onDismissRequest = { previewUri = null },
            properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
        ) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                TripPhotoImage(
                    uri,
                    Modifier.fillMaxSize(),
                    targetPixels = 2_048,
                    contentScale = androidx.compose.ui.layout.ContentScale.Fit
                )
                IconButton(
                    onClick = { previewUri = null },
                    modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(12.dp)
                ) {
                    Icon(Icons.Default.Close, "关闭照片", tint = Color.White)
                }
            }
        }
    }
}

@Composable
private fun TripPhotoImage(
    uri: String,
    modifier: Modifier,
    targetPixels: Int,
    contentScale: androidx.compose.ui.layout.ContentScale
) {
    val context = LocalContext.current
    val bitmap by produceState<android.graphics.Bitmap?>(null, uri, targetPixels) {
        value = withContext(Dispatchers.IO) { decodeTripPhoto(context, uri, targetPixels) }
    }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
        bitmap?.let {
            Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = contentScale)
        }
    }
}

private fun decodeTripPhoto(context: Context, uri: String, targetPixels: Int): android.graphics.Bitmap? = runCatching {
    val parsed = android.net.Uri.parse(uri)
    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(parsed)?.use {
        android.graphics.BitmapFactory.decodeStream(it, null, bounds)
    }
    var sampleSize = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sampleSize * 2) >= targetPixels) sampleSize *= 2
    val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sampleSize }
    context.contentResolver.openInputStream(parsed)?.use {
        android.graphics.BitmapFactory.decodeStream(it, null, options)
    }
}.getOrNull()

@Composable
private fun TripMap(
    cities: List<TripDayCityEntity>,
    items: List<TripItemEntity>,
    footprints: List<FootprintEntity>,
    activityTypes: List<ActivityTypeEntity>,
    transportRecords: List<TransportRecordEntity>,
    selectedItem: TripItemEntity?,
    bottomPaddingPx: Int,
    homeCity: HomeCityEntity? = null,
    routePreferenceVersion: Int = 0,
    onOpenFootprint: (String) -> Unit,
    onOpenPlannedPlace: (String) -> Unit = { }
) {
    val context = LocalContext.current
    val preferences = remember { AppPreferences(context) }
    val mapView = remember { mutableStateOf<TextureMapView?>(null) }
    val holder = remember { TripMapHolder() }
    val footprintByID = remember(footprints) { footprints.associateBy { it.footprintID } }
    val tripTransportIDs = remember(items) { items.mapNotNull { it.sourceTransportRecordID }.toSet() }
    val tripTransports = remember(transportRecords, tripTransportIDs) {
        transportRecords.filter { it.recordID in tripTransportIDs }
    }
    val plannedStops = remember(items) {
        items.filter { it.kindRaw == "stop" && it.latitude != null && it.longitude != null }
    }
    val plannedRouteKey = remember(plannedStops, homeCity, routePreferenceVersion) {
        "${homeCity?.latitude},${homeCity?.longitude}|" +
            plannedStops.joinToString("|") { "${it.id}:${it.latitude},${it.longitude}:${it.transportTypeRaw}" } +
            "|$routePreferenceVersion"
    }
    val plannedNavigationRoutes by produceState<Map<String, List<LatLng>>>(emptyMap(), plannedRouteKey) {
        val loaded = mutableMapOf<String, List<LatLng>>()
        plannedStops.forEach { destination ->
            val origin = plannedRouteOrigin(destination, plannedStops, homeCity) ?: return@forEach
            val transportTypeRaw = destination.transportTypeRaw?.takeIf(String::isNotBlank)
                ?: return@forEach
            val plans = GeocodeService.shared.routePlans(
                origin.latitude,
                origin.longitude,
                destination.latitude ?: return@forEach,
                destination.longitude ?: return@forEach,
                transportTypeRaw
            )
            val preferredIndex = preferences.getTripRouteOptionIndex(destination.id)
                .coerceIn(0, plans.lastIndex.coerceAtLeast(0))
            val points = plans.getOrNull(preferredIndex)?.points.orEmpty()
                .map { (latitude, longitude) -> LatLng(latitude, longitude) }
            if (points.size > 1) {
                loaded[destination.id] = points
                value = loaded.toMap()
            }
        }
        value = loaded
    }
    val routeColor = MaterialTheme.colorScheme.primary.toArgb()
    val isDark = isSystemInDarkTheme()
    val photoUris = remember(items, footprintByID) {
        items.mapNotNull { item ->
            item.sourceFootprintID?.let(footprintByID::get)?.let(::tripFootprintPhotoUris)?.lastOrNull()
        }.distinct()
    }
    var photoBitmaps by remember { mutableStateOf<Map<String, android.graphics.Bitmap>>(emptyMap()) }
    LaunchedEffect(photoUris) {
        val missing = photoUris.filter { it !in photoBitmaps }
        if (missing.isEmpty()) return@LaunchedEffect
        val loaded = withContext(Dispatchers.IO) {
            missing.mapNotNull { uri -> loadPinThumbnail(context, uri)?.let { uri to it } }.toMap()
        }
        if (loaded.isNotEmpty()) photoBitmaps = photoBitmaps + loaded
    }
    DisposableEffect(Unit) { onDispose { mapView.value?.onPause(); mapView.value?.onDestroy() } }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx -> TextureMapView(ctx).also { it.onResume(); mapView.value = it } },
        update = { view ->
            val map = view.map
            val photoBitmapKey = photoBitmaps.keys.sorted().joinToString(",")
            val overlayKey = cities.joinToString("|") { "${it.id}:${it.latitude},${it.longitude}" } +
                items.joinToString("|") { "${it.id}:${it.latitude},${it.longitude}:${it.activityTypeValue}" } +
                activityTypes.joinToString("|") { "${it.id}:${it.icon}:${it.colorHex}" } +
                tripTransports.joinToString("|") { "${it.recordID}:${it.pointsJson.hashCode()}" } +
                "|${plannedNavigationRoutes.hashCode()}|${selectedItem?.id}|$isDark|$photoBitmapKey"
            if (holder.overlayKey != overlayKey) {
                holder.overlayKey = overlayKey
                map.clear()
                val usesPlannedMarkers = items.any { it.planStatusRaw != "actual" } && tripTransports.isEmpty()
                val footprintMarkers = items.filter { it.kindRaw == "stop" }.mapNotNull { item ->
                    val latitude = item.latitude ?: return@mapNotNull null
                    val longitude = item.longitude ?: return@mapNotNull null
                    val activity = activityTypes.firstOrNull { it.id == item.activityTypeValue || it.name == item.activityTypeValue }
                    val footprint = item.sourceFootprintID?.let(footprintByID::get)
                    FootprintMapMarker(
                        id = footprint?.footprintID,
                        latitude = latitude,
                        longitude = longitude,
                        icon = activity?.icon ?: "place",
                        colorHex = activity?.colorHex ?: "#00A0AC",
                        durationSeconds = if (item.startTime != null && item.endTime != null) ((item.endTime.time - item.startTime.time) / 1000).coerceAtLeast(0) else 0,
                        memberIDs = listOf(item.id),
                        photoUri = footprint?.let(::tripFootprintPhotoUris)?.lastOrNull(),
                        scale = if (selectedItem?.id == item.id) 1.5f else 1f
                    )
                }
                if (footprintMarkers.isEmpty()) {
                    cities.forEach { city ->
                        val lat = city.latitude; val lon = city.longitude
                        if (lat != null && lon != null) map.addMarker(MarkerOptions(LatLng(lat, lon)).title(city.cityName))
                    }
                }
                val mapMarkers = footprintMarkers.toMutableList()
                val plannedCoordinates = items.filter { it.kindRaw == "stop" }
                    .mapNotNull { item ->
                        val latitude = item.latitude ?: return@mapNotNull null
                        val longitude = item.longitude ?: return@mapNotNull null
                        LatLng(latitude, longitude)
                    }
                if (items.any { it.planStatusRaw != "actual" } && tripTransports.isEmpty() && plannedCoordinates.size > 1) {
                    val plannedRouteColor = (routeColor and 0x00FFFFFF) or 0x99000000.toInt()
                    plannedStops.zipWithNext().forEach { (origin, destination) ->
                        val route = plannedNavigationRoutes[destination.id]
                        if (route != null) {
                            map.addPolyline(PolylineOptions().addAll(route).width(6f).color(plannedRouteColor))
                        } else {
                            map.addPolyline(
                                PolylineOptions()
                                    .addAll(
                                        listOf(
                                            LatLng(origin.latitude!!, origin.longitude!!),
                                            LatLng(destination.latitude!!, destination.longitude!!)
                                        )
                                    )
                                    .width(4f)
                                    .color((routeColor and 0x00FFFFFF) or (0x66 shl 24))
                                    .lineType(PolylineOptions.LineType.LINE_TYPE_DOTTEDLINE)
                            )
                        }
                    }
                }
                tripTransports.forEach { transport ->
                    drawSmoothedTimelineRoute(map, transport.pointsJson, routeColor)
                    val points = parseRouteSegments(transport.pointsJson).flatten()
                    if (points.size > 1) {
                        val item = items.firstOrNull { it.sourceTransportRecordID == transport.recordID }
                        val type = TransportType.from(item?.transportTypeRaw ?: transport.manualTypeRaw ?: transport.typeRaw)
                        val midpoint = routeDistanceMidpoint(points) ?: return@forEach
                        mapMarkers += FootprintMapMarker(
                            id = "transport:${item?.id ?: transport.recordID}",
                            latitude = midpoint.latitude,
                            longitude = midpoint.longitude,
                            icon = type.icon,
                            colorHex = "#00A0AC",
                            scale = if (selectedItem?.sourceTransportRecordID == transport.recordID) 1.5f else 1f
                        )
                    }
                }
                if (usesPlannedMarkers) {
                    items.filter { it.kindRaw == "stop" && it.latitude != null && it.longitude != null }
                        .forEachIndexed { index, item ->
                            map.addMarker(
                                MarkerOptions()
                                    .position(LatLng(item.latitude!!, item.longitude!!))
                                    .anchor(0.5f, 0.5f)
                                    .icon(BitmapDescriptorFactory.fromBitmap(tripSequenceMarkerBitmap(context, index + 1)))
                                    .zIndex(if (selectedItem?.id == item.id) 150f else 100f)
                            ).setTag(item.id)
                        }
                    map.setOnMarkerClickListener { marker ->
                        val itemID = marker.tag as? String ?: return@setOnMarkerClickListener false
                        onOpenPlannedPlace(itemID)
                        true
                    }
                } else {
                    map.addFootprintMarkers(
                        mapMarkers,
                        isDark = isDark,
                        onMarkerClick = { markerID ->
                            if (!markerID.startsWith("transport:")) onOpenFootprint(markerID)
                        },
                        photoBitmaps = photoBitmaps
                    )
                }
            }
            val selectedCoordinate = selectedItem?.let { item ->
                if (item.latitude != null && item.longitude != null) LatLng(item.latitude, item.longitude) else null
            }
            val selectedRoute = selectedItem?.sourceTransportRecordID?.let { selectedID ->
                tripTransports.firstOrNull { it.recordID == selectedID }
            }?.let { parseRouteSegments(it.pointsJson).flatten() }.orEmpty()
            val allCoordinates = buildList {
                cities.forEach { city ->
                    if (city.latitude != null && city.longitude != null) add(LatLng(city.latitude, city.longitude))
                }
                items.forEach { item ->
                    if (item.latitude != null && item.longitude != null) add(LatLng(item.latitude, item.longitude))
                }
                tripTransports.forEach { transport ->
                    parseRouteSegments(transport.pointsJson).forEach { addAll(it) }
                }
                plannedNavigationRoutes.values.forEach { addAll(it) }
            }
            val cameraKey = (selectedItem?.id ?: allCoordinates.joinToString("|") { "${it.latitude},${it.longitude}" }) +
                "|bottom:$bottomPaddingPx"
            if (cameraKey != holder.cameraKey) {
                holder.cameraKey = cameraKey
                when {
                    selectedRoute.size > 1 -> runCatching {
                        val builder = LatLngBounds.Builder()
                        selectedRoute.forEach(builder::include)
                        val side = (24 * view.context.resources.displayMetrics.density).toInt()
                        map.animateCamera(CameraUpdateFactory.newLatLngBoundsRect(builder.build(), side, side, side, bottomPaddingPx))
                    }
                    selectedCoordinate != null -> map.animateCamera(CameraUpdateFactory.newLatLngZoom(selectedCoordinate, 16f))
                    allCoordinates.size == 1 -> map.moveCamera(CameraUpdateFactory.newLatLngZoom(allCoordinates.first(), 13f))
                    allCoordinates.size > 1 -> runCatching {
                        val builder = LatLngBounds.Builder()
                        allCoordinates.forEach(builder::include)
                        val side = (24 * view.context.resources.displayMetrics.density).toInt()
                        map.moveCamera(CameraUpdateFactory.newLatLngBoundsRect(builder.build(), side, side, side, bottomPaddingPx))
                    }
                }
            }
        }
    )
}

private fun tripSequenceMarkerBitmap(context: Context, number: Int): android.graphics.Bitmap {
    val density = context.resources.displayMetrics.density
    val size = (38 * density).roundToInt().coerceAtLeast(38)
    val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bitmap)
    val center = size / 2f
    val radius = center - 2 * density
    canvas.drawCircle(center, center, radius, android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.rgb(0, 188, 201)
        style = android.graphics.Paint.Style.FILL
    })
    canvas.drawCircle(center, center, radius, android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.WHITE
        style = android.graphics.Paint.Style.STROKE
        strokeWidth = 2 * density
    })
    val textPaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.WHITE
        textAlign = android.graphics.Paint.Align.CENTER
        textSize = 15 * density
        typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
    }
    canvas.drawText(number.toString(), center, center - (textPaint.ascent() + textPaint.descent()) / 2, textPaint)
    return bitmap
}

private fun routeDistanceMidpoint(points: List<LatLng>): LatLng? {
    if (points.isEmpty()) return null
    if (points.size == 1) return points.first()
    val distances = points.zipWithNext { first, second ->
        FloatArray(1).also {
            android.location.Location.distanceBetween(first.latitude, first.longitude, second.latitude, second.longitude, it)
        }[0].toDouble()
    }
    val total = distances.sum()
    if (total <= 0) return points[points.size / 2]
    val middle = total / 2
    var distanceSoFar = 0.0
    distances.forEachIndexed { index, distance ->
        if (distanceSoFar + distance >= middle) {
            val fraction = if (distance > 0) (middle - distanceSoFar) / distance else 0.0
            val first = points[index]
            val second = points[index + 1]
            return LatLng(
                first.latitude + (second.latitude - first.latitude) * fraction,
                first.longitude + (second.longitude - first.longitude) * fraction
            )
        }
        distanceSoFar += distance
    }
    return points.last()
}

private class TripMapHolder {
    var overlayKey: String? = null
    var cameraKey: String? = null
}

@Composable
private fun TripActivityTypeMenu(
    activityTypes: List<ActivityTypeEntity>,
    selection: String?,
    onSelected: (String?) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val selected = activityTypes.firstOrNull { it.id == selection || it.name == selection }
    Box(Modifier.fillMaxWidth()) {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth()) {
            if (selected != null) {
                Icon(getIconForName(selected.icon), null, tint = parseActivityColor(selected.colorHex), modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
            }
            Text(selected?.name ?: "选择行程类型")
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.ArrowDropDown, null)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("未设置") }, onClick = { onSelected(null); expanded = false })
            activityTypes.forEach { type ->
                DropdownMenuItem(
                    text = { Text(type.name) },
                    leadingIcon = { Icon(getIconForName(type.icon), null, tint = parseActivityColor(type.colorHex)) },
                    onClick = { onSelected(type.id); expanded = false }
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlanTripDialog(
    dao: com.ct106.difangke.data.db.dao.TripDao,
    onDismiss: () -> Unit,
    onCreated: (TripEntity) -> Unit
) {
    var startDay by remember { mutableStateOf(startOfLocalDay(Date())) }
    var endDay by remember { mutableStateOf(startDay) }
    var hasPlannedDates by remember { mutableStateOf(false) }
    val cityStays = remember { mutableStateListOf<PlanCityStayDraft>() }
    var showingCitySearch by remember { mutableStateOf(false) }
    var dateTarget by remember { mutableStateOf<PlanDateTarget?>(null) }
    var saving by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val days = remember(startDay, endDay) { tripDayTimes(startDay, maxOf(startDay, endDay)) }
    val title = remember(cityStays.toList(), days.size) {
        val orderedCities = cityStays.withIndex()
            .sortedWith(compareBy<IndexedValue<PlanCityStayDraft>> { it.value.arrivalDay }.thenBy { it.index })
            .map { it.value.city.cityName }
        automaticTripTitle(orderedCities, days.size)
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = { Text("规划一次出行") },
                        navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "取消") } },
                        actions = {
                            TextButton(
                                enabled = cityStays.isNotEmpty() && !saving,
                                onClick = {
                                    saving = true
                                    scope.launch {
                                        val trip = TripEntity(
                                            title = title,
                                            kindRaw = TripKind.PLANNED.raw,
                                            stateRaw = TripState.PLANNED.raw,
                                            plannedStartDay = startOfLocalDay(startDay),
                                            plannedEndDay = startOfLocalDay(endDay),
                                            titleUserEdited = false,
                                            datesUserEdited = hasPlannedDates,
                                            citiesUserEdited = true
                                        )
                                        val dayEntities = days.mapIndexed { index, dayTime ->
                                            TripDayEntity(tripID = trip.id, day = Date(dayTime), orderIndex = index)
                                        }
                                        val cityEntities = dayEntities.flatMap { day ->
                                            cityStays.filter { stay -> day.day.time in startOfLocalDay(stay.arrivalDay).time..startOfLocalDay(stay.departureDay).time }
                                                .distinctBy { it.city.key }
                                                .mapIndexed { index, stay ->
                                                    TripDayCityEntity(
                                                        tripDayID = day.id,
                                                        countryCode = stay.city.countryCode,
                                                        countryName = stay.city.countryName,
                                                        cityName = stay.city.cityName,
                                                        latitude = stay.city.latitude,
                                                        longitude = stay.city.longitude,
                                                        orderIndex = index,
                                                        isUserEdited = true
                                                    )
                                                }
                                        }
                                        runCatching { dao.createPlan(trip, dayEntities, cityEntities) }
                                            .onSuccess { onCreated(trip) }
                                            .onFailure {
                                                saving = false
                                                saveError = "计划还没有创建，请稍后再试。"
                                            }
                                    }
                                }
                            ) { Text("创建") }
                        }
                    )
                }
            ) { padding ->
                Column(
                    Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Text("什么时候", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("设置日期", Modifier.weight(1f))
                        Switch(checked = hasPlannedDates, onCheckedChange = { enabled ->
                            hasPlannedDates = enabled
                            if (!enabled) {
                                cityStays.indices.forEach { index ->
                                    cityStays[index] = cityStays[index].copy(arrivalDay = startDay, departureDay = endDay)
                                }
                            }
                        })
                    }
                    if (hasPlannedDates) {
                        OutlinedButton(onClick = { dateTarget = PlanDateTarget.Start }, Modifier.fillMaxWidth()) {
                            Text("开始日期 ${formatShortDate(startDay)}")
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("行程天数", modifier = Modifier.weight(1f))
                        OutlinedButton(
                            onClick = {
                                if (days.size > 1) {
                                    endDay = addLocalDays(endDay, -1)
                                    cityStays.indices.forEach { index ->
                                        val arrival = minOf(cityStays[index].arrivalDay, endDay)
                                        cityStays[index] = cityStays[index].copy(
                                            arrivalDay = arrival,
                                            departureDay = minOf(maxOf(cityStays[index].departureDay, arrival), endDay)
                                        )
                                    }
                                }
                            },
                            enabled = days.size > 1
                        ) { Icon(Icons.Default.Remove, "减少一天") }
                        Text("${days.size}天", Modifier.padding(horizontal = 14.dp), fontWeight = FontWeight.SemiBold)
                        OutlinedButton(
                            onClick = {
                                endDay = addLocalDays(endDay, 1)
                                if (!hasPlannedDates) {
                                    cityStays.indices.forEach { index ->
                                        cityStays[index] = cityStays[index].copy(arrivalDay = startDay, departureDay = endDay)
                                    }
                                }
                            },
                            enabled = days.size < AppConfig.TRIP_MAXIMUM_DURATION_DAYS
                        ) { Icon(Icons.Default.Add, "添加一天") }
                    }
                    if (hasPlannedDates) {
                        Text("结束日期 ${formatShortDate(endDay)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }

                    Text("去哪里", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    cityStays.forEach { stay ->
                        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.LocationCity, null, tint = DfkAccent)
                                    Spacer(Modifier.width(8.dp))
                                    Text(stay.city.cityName, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                                    IconButton(onClick = { cityStays.removeAll { it.id == stay.id } }) {
                                        Icon(Icons.Default.DeleteOutline, "移除城市", tint = MaterialTheme.colorScheme.error)
                                    }
                                }
                                if (hasPlannedDates) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    TextButton(onClick = { dateTarget = PlanDateTarget.Arrival(stay.id) }, Modifier.weight(1f)) {
                                        Text("到达 ${formatShortDate(stay.arrivalDay)}")
                                    }
                                    TextButton(onClick = { dateTarget = PlanDateTarget.Departure(stay.id) }, Modifier.weight(1f)) {
                                        Text("离开 ${formatShortDate(stay.departureDay)}")
                                    }
                                }
                            }
                        }
                    }
                    OutlinedButton(onClick = { showingCitySearch = true }, Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.Add, null)
                        Spacer(Modifier.width(6.dp))
                        Text(if (cityStays.isEmpty()) "添加目的地" else "继续添加城市")
                    }
                    if (hasPlannedDates) {
                        Text("选择每座城市的停留日期，同一天可以安排多座城市。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }

                    if (cityStays.isNotEmpty()) {
                        Text("行程预览", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                        Text(title, style = MaterialTheme.typography.titleMedium)
                        days.forEachIndexed { dayIndex, dayTime ->
                            val cityText = cityStays.filter { dayTime in startOfLocalDay(it.arrivalDay).time..startOfLocalDay(it.departureDay).time }
                                .distinctBy { it.city.key }
                                .joinToString(" · ") { it.city.cityName }
                            Row(Modifier.fillMaxWidth()) {
                                Text(if (hasPlannedDates) formatFullDate(Date(dayTime)) else "第${dayIndex + 1}天", modifier = Modifier.weight(1f))
                                Text(cityText.ifBlank { "待安排" }, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }

    dateTarget?.let { target ->
        val initial = when (target) {
            PlanDateTarget.Start -> startDay
            is PlanDateTarget.Arrival -> cityStays.firstOrNull { it.id == target.id }?.arrivalDay ?: startDay
            is PlanDateTarget.Departure -> cityStays.firstOrNull { it.id == target.id }?.departureDay ?: endDay
        }
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = pickerMillisForLocalDate(initial))
        DatePickerDialog(
            onDismissRequest = { dateTarget = null },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { selectedMillis ->
                        val selected = localDateFromPickerMillis(selectedMillis)
                        when (target) {
                            PlanDateTarget.Start -> {
                                val offset = localDayDifference(startDay, selected)
                                startDay = selected
                                endDay = addLocalDays(endDay, offset)
                                cityStays.indices.forEach { index ->
                                    cityStays[index] = cityStays[index].copy(
                                        arrivalDay = addLocalDays(cityStays[index].arrivalDay, offset),
                                        departureDay = addLocalDays(cityStays[index].departureDay, offset)
                                    )
                                }
                            }
                            is PlanDateTarget.Arrival -> {
                                val index = cityStays.indexOfFirst { it.id == target.id }
                                if (index >= 0) {
                                    val arrival = minOf(maxOf(selected, startDay), endDay)
                                    cityStays[index] = cityStays[index].copy(arrivalDay = arrival, departureDay = maxOf(cityStays[index].departureDay, arrival))
                                }
                            }
                            is PlanDateTarget.Departure -> {
                                val index = cityStays.indexOfFirst { it.id == target.id }
                                if (index >= 0) cityStays[index] = cityStays[index].copy(departureDay = minOf(maxOf(selected, cityStays[index].arrivalDay), endDay))
                            }
                        }
                    }
                    dateTarget = null
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { dateTarget = null }) { Text("取消") } }
        ) { DatePicker(pickerState) }
    }

    if (showingCitySearch) {
        CitySearchDialog(
            onDismiss = { showingCitySearch = false },
            onSelect = { city ->
                cityStays += PlanCityStayDraft(city = city, arrivalDay = startDay, departureDay = endDay)
                showingCitySearch = false
            }
        )
    }

    saveError?.let { message ->
        AlertDialog(
            onDismissRequest = { saveError = null },
            title = { Text("没有创建成功") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { saveError = null }) { Text("知道了") } }
        )
    }
}

private data class PlanCityStayDraft(
    val id: String = UUID.randomUUID().toString(),
    val city: SelectedHomeCity,
    val arrivalDay: Date,
    val departureDay: Date
)

private sealed class PlanDateTarget {
    object Start : PlanDateTarget()
    data class Arrival(val id: String) : PlanDateTarget()
    data class Departure(val id: String) : PlanDateTarget()
}

private fun localDayDifference(from: Date, to: Date): Int {
    val calendar = Calendar.getInstance()
    return ((startOfLocalDay(to).time - startOfLocalDay(from).time) / 86_400_000L).toInt().let { approximate ->
        if (addLocalDays(from, approximate).time == startOfLocalDay(to).time) approximate
        else calendar.run {
            var cursor = startOfLocalDay(from)
            var count = 0
            val direction = if (cursor.before(to)) 1 else -1
            while (startOfLocalDay(cursor).time != startOfLocalDay(to).time) {
                time = cursor; add(Calendar.DAY_OF_YEAR, direction); cursor = time; count += direction
            }
            count
        }
    }
}

private fun addLocalDays(date: Date, days: Int): Date = Calendar.getInstance().apply {
    time = startOfLocalDay(date)
    add(Calendar.DAY_OF_YEAR, days)
}.time

private fun pickerMillisForLocalDate(date: Date): Long {
    val local = Calendar.getInstance().apply { time = date }
    return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
    }.timeInMillis
}

private fun localDateFromPickerMillis(utcMillis: Long): Date {
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = utcMillis }
    return Calendar.getInstance().apply {
        clear()
        set(utc.get(Calendar.YEAR), utc.get(Calendar.MONTH), utc.get(Calendar.DAY_OF_MONTH))
    }.time
}

private fun automaticTripTitle(cityNames: List<String>, dayCount: Int): String {
    val names = cityNames.map(String::trim).filter(String::isNotEmpty).distinct().map {
        if (it.endsWith("市")) it.dropLast(1) else it
    }
    val destinations = if (names.size <= 2) names.joinToString("") else names.take(2).joinToString("") + "等"
    val chineseDays = chineseDayCount(dayCount.coerceAtLeast(1))
    return "$destinations${chineseDays}日行"
}

private fun chineseDayCount(value: Int): String {
    val digits = listOf("零", "一", "二", "三", "四", "五", "六", "七", "八", "九")
    return when (value) {
        in 1..9 -> digits[value]
        10 -> "十"
        in 11..19 -> "十${digits[value % 10]}"
        in 20..99 -> "${digits[value / 10]}十${if (value % 10 == 0) "" else digits[value % 10]}"
        else -> value.toString()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreateTripDialog(
    context: Context,
    dao: com.ct106.difangke.data.db.dao.TripDao,
    forcesHistorical: Boolean = false,
    onDismiss: () -> Unit
) {
    val activityTypes by AppDatabase.getInstance(context).activityTypeDao().observeAll().collectAsState(initial = emptyList())
    var titleValue by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var notesValue by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var startDay by remember { mutableStateOf(startOfLocalDay(Date())) }
    var endDay by remember { mutableStateOf(startDay) }
    var importExisting by remember { mutableStateOf(true) }
    var choosingStart by remember { mutableStateOf(false) }
    var choosingEnd by remember { mutableStateOf(false) }
    val citiesByDay = remember { mutableStateMapOf<Long, List<SelectedHomeCity>>() }
    var citySearchDay by remember { mutableStateOf<Long?>(null) }
    var activityTypeValue by rememberSaveable { mutableStateOf<String?>(null) }
    val days = remember(startDay, endDay) { tripDayTimes(startDay, maxOf(startDay, endDay)) }
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("创建行程") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(titleValue, { titleValue = it }, label = { Text("标题") }, singleLine = true)
                OutlinedTextField(notesValue, { notesValue = it }, label = { Text("备注") })
                TripActivityTypeMenu(activityTypes, activityTypeValue) { activityTypeValue = it }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { choosingStart = true }, Modifier.weight(1f)) { Text("开始 ${formatShortDate(startDay)}") }
                    OutlinedButton(onClick = { choosingEnd = true }, Modifier.weight(1f)) { Text("结束 ${formatShortDate(endDay)}") }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("自动导入日期范围内的足迹", Modifier.weight(1f)); Switch(importExisting, { importExisting = it })
                }
                days.forEach { dayTime ->
                    Text(formatFullDate(Date(dayTime)), fontWeight = FontWeight.SemiBold)
                    citiesByDay[dayTime].orEmpty().forEach { city ->
                        ListItem(
                            headlineContent = { Text(city.label) },
                            leadingContent = { Icon(Icons.Default.LocationOn, null) },
                            trailingContent = {
                                IconButton(onClick = { citiesByDay[dayTime] = citiesByDay[dayTime].orEmpty().filterNot { it.key == city.key } }) {
                                    Icon(Icons.Default.RemoveCircleOutline, "移除城市")
                                }
                            }
                        )
                    }
                    OutlinedButton(onClick = { citySearchDay = dayTime }, Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.Add, null); Spacer(Modifier.width(6.dp)); Text("添加城市")
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = titleValue.text.isNotBlank(), onClick = {
                scope.launch {
                    val normalizedEnd = maxOf(startDay, endDay)
                    val today = startOfLocalDay(Date())
                    val state = when {
                        forcesHistorical -> TripState.HISTORICAL
                        normalizedEnd.before(today) -> TripState.HISTORICAL
                        !startDay.after(today) -> TripState.ACTIVE
                        else -> TripState.PLANNED
                    }
                    val trip = TripEntity(title = titleValue.text.trim(), notes = notesValue.text, activityTypeValue = activityTypeValue, kindRaw = if (state == TripState.PLANNED) TripKind.PLANNED.raw else TripKind.HISTORICAL.raw, stateRaw = state.raw, plannedStartDay = startDay, plannedEndDay = normalizedEnd, actualStartedAt = if (state == TripState.ACTIVE) startDay else null, titleUserEdited = true, datesUserEdited = true)
                    dao.upsertTrip(trip)
                    val imported = if (importExisting) importFootprintCities(context, startDay, normalizedEnd) else emptyMap()
                    val importedCityIdentifiers = mutableMapOf<String, String>()
                    imported.values.flatten().forEach { city ->
                        val latitude = city.latitude
                        val longitude = city.longitude
                        if (latitude != null && longitude != null) {
                            runCatching {
                                GeocodeService.shared.resolveCityIdentifier(latitude, longitude, city.cityName, city.countryCode)
                            }.getOrNull()?.let { identifier ->
                                importedCityIdentifiers[tripCityIdentityKey(null, city.countryCode, city.cityName)] = identifier
                            }
                        }
                    }
                    val createdDays = mutableMapOf<Long, TripDayEntity>()
                    imported.forEach { (dayTime, cities) ->
                        val day = TripDayEntity(tripID = trip.id, day = Date(dayTime)); dao.upsertDay(day); createdDays[dayTime] = day
                        cities.forEachIndexed { index, value ->
                            val legacyKey = tripCityIdentityKey(null, value.countryCode, value.cityName)
                            dao.upsertCity(TripDayCityEntity(tripDayID = day.id, countryCode = value.countryCode, countryName = value.countryName, cityName = value.cityName, cityIdentifier = importedCityIdentifiers[legacyKey], latitude = value.latitude, longitude = value.longitude, orderIndex = index, isUserEdited = false))
                        }
                    }
                    days.forEach { dayTime ->
                        val day = createdDays[dayTime] ?: TripDayEntity(tripID = trip.id, day = Date(dayTime)).also { dao.upsertDay(it) }
                        val importedCities = imported[dayTime].orEmpty()
                        citiesByDay[dayTime].orEmpty().filterNot { selected ->
                            importedCities.any { imported ->
                                tripCitiesMatch(
                                    importedCityIdentifiers[tripCityIdentityKey(null, imported.countryCode, imported.cityName)],
                                    imported.countryCode,
                                    imported.cityName,
                                    selected.cityIdentifier,
                                    selected.countryCode,
                                    selected.cityName
                                )
                            }
                        }.forEachIndexed { index, city ->
                            dao.upsertCity(TripDayCityEntity(tripDayID = day.id, countryCode = city.countryCode, countryName = city.countryName, cityName = city.cityName, cityIdentifier = city.cityIdentifier, latitude = city.latitude, longitude = city.longitude, orderIndex = index, isUserEdited = true))
                        }
                    }
                    onDismiss()
                }
            }) { Text("创建") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
    if (choosingStart || choosingEnd) {
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = pickerMillisForLocalDate(if (choosingStart) startDay else endDay))
        DatePickerDialog(onDismissRequest = { choosingStart = false; choosingEnd = false }, confirmButton = {
            TextButton(onClick = {
                pickerState.selectedDateMillis?.let { selected ->
                    if (choosingStart) {
                        val durationDays = tripInclusiveDayCount(startDay, maxOf(startDay, endDay)) - 1
                        startDay = localDateFromPickerMillis(selected)
                        endDay = Calendar.getInstance().apply {
                            time = startDay
                            add(Calendar.DAY_OF_YEAR, durationDays)
                        }.time
                    }
                    else endDay = maxOf(startDay, localDateFromPickerMillis(selected))
                }
                choosingStart = false; choosingEnd = false
            }) { Text("确定") }
        }) { DatePicker(pickerState) }
    }
    citySearchDay?.let { dayTime ->
        CitySearchDialog(
            onDismiss = { citySearchDay = null },
            onSelect = { city ->
                val current = citiesByDay[dayTime].orEmpty()
                if (current.none { it.key == city.key }) citiesByDay[dayTime] = current + city
                citySearchDay = null
            }
        )
    }
}

private fun tripDayTimes(start: Date, end: Date): List<Long> {
    val calendar = Calendar.getInstance()
    var cursor = startOfLocalDay(start)
    val last = startOfLocalDay(end)
    return buildList {
        while (!cursor.after(last)) {
            add(cursor.time)
            calendar.time = cursor
            calendar.add(Calendar.DAY_OF_YEAR, 1)
            cursor = calendar.time
        }
    }
}

private fun formatFullDate(date: Date): String = SimpleDateFormat("yyyy年M月d日 EEEE", Locale.getDefault()).format(date)

@Composable
private fun CitySearchDialog(onDismiss: () -> Unit, onSelect: (SelectedHomeCity) -> Unit) {
    var queryValue by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var results by remember { mutableStateOf<List<GeocodeService.CitySearchResult>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var resolvingCityKey by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val localMatches = remember(queryValue.text) { localCatalogMatches(queryValue.text) }
    val selectResolvedCity: (SelectedHomeCity) -> Unit = { city ->
        if (resolvingCityKey == null) {
            resolvingCityKey = city.key
            scope.launch {
                val identifier = city.cityIdentifier ?: runCatching {
                    GeocodeService.shared.resolveCityIdentifier(city.latitude, city.longitude, city.cityName, city.countryCode)
                }.getOrNull()
                resolvingCityKey = null
                onSelect(city.copy(cityIdentifier = identifier))
            }
        }
    }
    LaunchedEffect(queryValue.text) {
        val query = queryValue.text.trim()
        if (query.isEmpty()) { results = emptyList(); searching = false; return@LaunchedEffect }
        kotlinx.coroutines.delay(450)
        searching = true
        val found = runCatching { GeocodeService.shared.searchCities(query) }.getOrDefault(emptyList())
        if (queryValue.text.trim() == query) {
            results = found
            searching = false
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("搜索城市") },
        text = {
            Column {
                OutlinedTextField(
                    queryValue,
                    { queryValue = it },
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    placeholder = { Text("输入城市名") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                if (searching) LinearProgressIndicator(Modifier.fillMaxWidth())
                LazyColumn(Modifier.heightIn(max = 320.dp)) {
                    items(localMatches, key = { "local|${it.key}" }) { city ->
                        ListItem(
                            headlineContent = { Text(city.cityName) },
                            supportingContent = { Text(city.countryName) },
                            modifier = Modifier.clickable(enabled = resolvingCityKey == null) { selectResolvedCity(city) }
                        )
                    }
                    items(
                        results.filter { result -> localMatches.none { it.key == SelectedHomeCity(result).key } },
                        key = { "network|${it.countryCode}|${it.cityName}" }
                    ) { result ->
                        ListItem(
                            headlineContent = { Text(result.cityName) },
                            supportingContent = { if (result.countryName.isNotBlank()) Text(result.countryName) },
                            modifier = Modifier.clickable(enabled = resolvingCityKey == null) { selectResolvedCity(SelectedHomeCity(result)) }
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

private data class SelectedHomeCity(
    val cityName: String,
    val countryCode: String,
    val countryName: String,
    val latitude: Double,
    val longitude: Double,
    val cityIdentifier: String? = null
) {
    constructor(home: HomeCityEntity) : this(home.cityName, home.countryCode, home.countryName, home.latitude ?: 0.0, home.longitude ?: 0.0, home.cityIdentifier)
    constructor(result: GeocodeService.CitySearchResult) : this(result.cityName, result.countryCode, result.countryName, result.latitude, result.longitude, result.cityIdentifier)
    constructor(city: ConfiguredTripCity) : this(city.cityName, city.countryCode, city.countryName, city.latitude, city.longitude)
    val label: String get() = if (countryName.isBlank()) cityName else "$cityName，$countryName"
    val key: String get() = tripCityIdentityKey(cityIdentifier, countryCode, cityName)
    fun entity(id: String) = HomeCityEntity(id = id, cityName = cityName, cityIdentifier = cityIdentifier, countryCode = countryCode, countryName = countryName, latitude = latitude, longitude = longitude, updatedAt = Date())
}

private fun localCatalogMatches(value: String): List<SelectedHomeCity> {
    val query = value.trim().lowercase()
    if (query.isEmpty()) return emptyList()
    return AppConfig.TRIP_MAJOR_CITIES.filter { city ->
        (listOf(city.cityName, city.countryName, city.countryCode) + city.searchAliases)
            .any { it.lowercase().contains(query) }
    }.map(::SelectedHomeCity)
}

private val tripCityAlphabeticIndex by lazy {
    AlphabeticIndex<Any>(Locale.SIMPLIFIED_CHINESE)
        .addLabels(Locale.ENGLISH)
        .buildImmutableIndex()
}

private fun tripCityInitial(cityName: String): String {
    val bucketIndex = tripCityAlphabeticIndex.getBucketIndex(cityName)
    val label = tripCityAlphabeticIndex.getBucket(bucketIndex)?.label.orEmpty().uppercase()
    return label.takeIf { it.length == 1 && it[0] in 'A'..'Z' } ?: "#"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeCitySearchField(selected: SelectedHomeCity?, onSelect: (SelectedHomeCity?) -> Unit) {
    var queryValue by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var results by remember { mutableStateOf<List<GeocodeService.CitySearchResult>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    val localMatches = remember(queryValue.text) { localCatalogMatches(queryValue.text) }
    val trackingState by LocationTrackingService.stateFlow.collectAsState()
    val currentCoordinates = when (val state = trackingState) {
        is LocationTrackingService.TrackingState.Tracking -> state.lat?.let { lat -> state.lon?.let { lon -> lat to lon } }
        is LocationTrackingService.TrackingState.OngoingStay -> state.lat to state.lon
        else -> null
    }
    var currentCity by remember { mutableStateOf<SelectedHomeCity?>(null) }
    var resolvingCurrentCity by remember { mutableStateOf(false) }
    var majorCityScope by rememberSaveable { mutableStateOf("domestic") }
    val cityListState = rememberLazyListState()
    val cityListScope = rememberCoroutineScope()
    var resolvingSelectedCityKey by remember { mutableStateOf<String?>(null) }
    var draggedCityInitial by remember { mutableStateOf<String?>(null) }
    var cityIndexHeightPx by remember { mutableIntStateOf(0) }
    val selectResolvedCity: (SelectedHomeCity) -> Unit = { city ->
        if (resolvingSelectedCityKey == null) {
            resolvingSelectedCityKey = city.key
            cityListScope.launch {
                val identifier = city.cityIdentifier ?: runCatching {
                    GeocodeService.shared.resolveCityIdentifier(city.latitude, city.longitude, city.cityName, city.countryCode)
                }.getOrNull()
                resolvingSelectedCityKey = null
                onSelect(city.copy(cityIdentifier = identifier))
                queryValue = TextFieldValue()
            }
        }
    }

    LaunchedEffect(currentCoordinates) {
        val coordinates = currentCoordinates
        if (coordinates == null) {
            currentCity = null
            resolvingCurrentCity = false
            return@LaunchedEffect
        }
        resolvingCurrentCity = true
        currentCity = runCatching {
            GeocodeService.shared.reverseGeocodeDetails(coordinates.first, coordinates.second)
        }.getOrNull()?.let { details ->
            details.cityName?.takeIf { it.isNotBlank() }?.let { cityName ->
                SelectedHomeCity(
                    cityName = cityName,
                    countryCode = details.countryCode.orEmpty(),
                    countryName = details.countryName.orEmpty(),
                    latitude = coordinates.first,
                    longitude = coordinates.second,
                    cityIdentifier = details.cityIdentifier
                )
            }
        }
        resolvingCurrentCity = false
    }
    LaunchedEffect(queryValue.text) {
        val value = queryValue.text.trim()
        if (value.isEmpty()) { results = emptyList(); searching = false; return@LaunchedEffect }
        kotlinx.coroutines.delay(450)
        searching = true
        val found = runCatching { GeocodeService.shared.searchCities(value) }.getOrDefault(emptyList())
        if (queryValue.text.trim() == value) {
            results = found
            searching = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (selected != null) {
            ListItem(
                headlineContent = { Text(selected.label) },
                supportingContent = { Text("已选择的标准城市") },
                leadingContent = { Icon(Icons.Default.LocationOn, null) },
                trailingContent = { TextButton(onClick = { onSelect(null); queryValue = TextFieldValue() }) { Text("更改") } }
            )
        }
        if (selected == null) {
            if (currentCity != null) {
                val city = currentCity!!
                ListItem(
                    headlineContent = { Text(city.label) },
                    supportingContent = { Text("当前定位城市") },
                    leadingContent = { Icon(Icons.Default.MyLocation, null) },
                    modifier = Modifier.clickable(enabled = resolvingSelectedCityKey == null) { selectResolvedCity(city) }
                )
            } else if (resolvingCurrentCity) {
                ListItem(
                    headlineContent = { Text("正在获取当前城市…") },
                    leadingContent = { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }
                )
            }

            if (queryValue.text.isBlank()) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    listOf("domestic" to "国内", "international" to "国外").forEachIndexed { index, item ->
                        SegmentedButton(
                            selected = majorCityScope == item.first,
                            onClick = { majorCityScope = item.first },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 2)
                        ) { Text(item.second) }
                    }
                }
                val groupedCities = remember(majorCityScope) {
                    AppConfig.TRIP_MAJOR_CITIES
                        .filter { it.scope == majorCityScope }
                        .groupBy { tripCityInitial(it.cityName) }
                        .toSortedMap()
                        .mapValues { (_, cities) -> cities.sortedBy { it.cityName } }
                }
                val groupStartIndices = remember(groupedCities) {
                    var itemIndex = 0
                    groupedCities.mapValues { (_, cities) ->
                        itemIndex.also { itemIndex += cities.size + 1 }
                    }
                }
                val cityInitials = groupedCities.keys.toList()
                val selectCityInitial: (Float) -> Unit = { y ->
                    if (cityInitials.isNotEmpty() && cityIndexHeightPx > 0) {
                        val maximumY = (cityIndexHeightPx - 1).coerceAtLeast(0).toFloat()
                        val boundedY = y.coerceIn(0f, maximumY)
                        val initialIndex = (
                            boundedY / cityIndexHeightPx.toFloat() * cityInitials.size
                        ).toInt().coerceIn(0, cityInitials.lastIndex)
                        val initial = cityInitials[initialIndex]
                        if (draggedCityInitial != initial) {
                            draggedCityInitial = initial
                            groupStartIndices[initial]?.let { itemIndex ->
                                cityListScope.launch { cityListState.scrollToItem(itemIndex) }
                            }
                        }
                    }
                }
                Box(Modifier.heightIn(max = 300.dp)) {
                    LazyColumn(state = cityListState, modifier = Modifier.fillMaxWidth()) {
                        groupedCities.forEach { (initial, cities) ->
                            item(key = "header|$majorCityScope|$initial") {
                                Text(
                                    initial,
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 2.dp)
                                )
                            }
                            items(cities, key = { "city|${it.countryCode}|${it.cityName}" }) { configured ->
                                val city = SelectedHomeCity(configured)
                                ListItem(
                                    headlineContent = { Text(city.cityName) },
                                    supportingContent = { Text(city.countryName) },
                                    modifier = Modifier.clickable(enabled = resolvingSelectedCityKey == null) { selectResolvedCity(city) }
                                )
                            }
                        }
                    }
                    draggedCityInitial?.let { initial ->
                        Text(
                            initial,
                            color = Color.White,
                            fontSize = 32.sp,
                            fontWeight = FontWeight.SemiBold,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            modifier = Modifier
                                .align(Alignment.CenterEnd)
                                .padding(end = 46.dp)
                                .size(64.dp)
                                .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(14.dp))
                                .wrapContentSize()
                        )
                    }
                    Column(
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .padding(end = 1.dp, top = 6.dp, bottom = 6.dp)
                            .width(28.dp)
                            .fillMaxHeight()
                            .onSizeChanged { cityIndexHeightPx = it.height }
                            .pointerInput(cityInitials, groupStartIndices) {
                                detectDragGestures(
                                    onDragStart = { selectCityInitial(it.y) },
                                    onDragEnd = { draggedCityInitial = null },
                                    onDragCancel = { draggedCityInitial = null },
                                    onDrag = { change, _ -> selectCityInitial(change.position.y) }
                                )
                            },
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        cityInitials.forEach { initial ->
                            Text(
                                initial,
                                color = if (draggedCityInitial == initial) {
                                    MaterialTheme.colorScheme.onSurface
                                } else {
                                    MaterialTheme.colorScheme.primary
                                },
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier
                                    .weight(1f)
                                    .fillMaxWidth()
                                    .wrapContentHeight()
                                    .clickable {
                                        draggedCityInitial = initial
                                        groupStartIndices[initial]?.let { index ->
                                            cityListScope.launch { cityListState.scrollToItem(index) }
                                        }
                                        draggedCityInitial = null
                                    },
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center
                            )
                        }
                    }
                }
            } else {
                if (searching) LinearProgressIndicator(Modifier.fillMaxWidth())
                LazyColumn(Modifier.heightIn(max = 260.dp)) {
                    items(
                        localMatches.filter { it.key != currentCity?.key },
                        key = { "local|${it.key}" }
                    ) { city ->
                        ListItem(
                            headlineContent = { Text(city.cityName) },
                            supportingContent = { Text(city.countryName) },
                            modifier = Modifier.clickable(enabled = resolvingSelectedCityKey == null) { selectResolvedCity(city) }
                        )
                    }
                    items(
                        results.filter {
                            val key = SelectedHomeCity(it).key
                            key != currentCity?.key && localMatches.none { local -> local.key == key }
                        },
                        key = { "network|${it.countryCode}|${it.cityName}" }
                    ) { city ->
                        ListItem(
                            headlineContent = { Text(city.cityName) },
                            supportingContent = { if (city.countryName.isNotBlank()) Text(city.countryName) },
                            modifier = Modifier.clickable(enabled = resolvingSelectedCityKey == null) { selectResolvedCity(SelectedHomeCity(city)) }
                        )
                    }
                }
            }
            OutlinedTextField(
                queryValue,
                { queryValue = it },
                label = { Text("搜索城市") },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun TripOptionsDialog(context: Context, dao: com.ct106.difangke.data.db.dao.TripDao, onDismiss: () -> Unit) {
    val home by dao.observeHomeCity().collectAsState(initial = null)
    val preferences = remember { AppPreferences(context) }
    val savedAuto by preferences.tripAutomaticRecognitionEnabled.collectAsState(initial = false)
    val scanRunning by preferences.tripScanRunning.collectAsState(initial = false)
    var selectedCity by remember(home) { mutableStateOf(home?.let(::SelectedHomeCity)) }
    var auto by remember(savedAuto) { mutableStateOf(savedAuto) }
    val legacyPrefs = remember { context.getSharedPreferences("trip_options", Context.MODE_PRIVATE) }
    var notifications by remember { mutableStateOf(legacyPrefs.getBoolean("notifications", true)) }
    var confirmingRescan by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("出行选项") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("常居地", fontWeight = FontWeight.Bold)
                HomeCitySearchField(selectedCity) { selectedCity = it }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("自动生成行程", Modifier.weight(1f)); Switch(auto, { auto = it }) }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("行程动态提醒", Modifier.weight(1f)); Switch(notifications, { notifications = it }) }
                Text("常居地只由你设置，系统不会自行猜测。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                HorizontalDivider()
                TextButton(
                    onClick = { confirmingRescan = true },
                    enabled = !scanRunning && auto && selectedCity != null,
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) { Text("重新整理历史行程") }
                Text(
                    "根据现有足迹重新生成自动行程。你创建或修改过的行程不会改变。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                legacyPrefs.edit().putBoolean("notifications", notifications).apply()
                scope.launch {
                    if (selectedCity == null) dao.deleteHomeCity() else dao.upsertHomeCity(selectedCity!!.entity(home?.id ?: "home"))
                    preferences.setTripAutomaticRecognitionEnabled(auto)
                    if (auto && selectedCity != null) TripScanWorker.schedule(context, runNow = true) else TripScanWorker.cancel(context)
                    onDismiss()
                }
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
    if (confirmingRescan) {
        AlertDialog(
            onDismissRequest = { confirmingRescan = false },
            title = { Text("重新整理历史行程？") },
            text = { Text("将根据现有足迹重新生成自动行程。原始足迹、你创建的行程和手动修改都会保留。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmingRescan = false
                    scope.launch {
                        if (selectedCity != null) dao.upsertHomeCity(selectedCity!!.entity(home?.id ?: "home"))
                        preferences.setTripAutomaticRecognitionEnabled(true)
                        dao.deleteReplaceableAutomaticTrips()
                        preferences.resetTripScanState()
                        preferences.clearTripSuppressedRanges()
                        TripScanWorker.rescan(context)
                    }
                }) { Text("重新整理", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingRescan = false }) { Text("取消") } }
        )
    }
}

private suspend fun suppressAutomaticRanges(preferences: AppPreferences, trips: List<TripEntity>) {
    if (trips.isEmpty()) return
    val ranges = mutableListOf<Pair<Long, Long>>()
    runCatching {
        val stored = JSONArray(preferences.getTripSuppressedRanges() ?: "[]")
        repeat(stored.length()) { index ->
            val item = stored.optJSONObject(index) ?: return@repeat
            val start = item.optLong("start", Long.MIN_VALUE)
            val end = item.optLong("end", Long.MIN_VALUE)
            if (start != Long.MIN_VALUE && end != Long.MIN_VALUE) ranges += minOf(start, end) to maxOf(start, end)
        }
    }
    ranges += trips.map {
        startOfLocalDay(minOf(it.plannedStartDay, it.plannedEndDay)).time to
            startOfLocalDay(maxOf(it.plannedStartDay, it.plannedEndDay)).time
    }
    val merged = mutableListOf<Pair<Long, Long>>()
    ranges.sortedBy { it.first }.forEach { range ->
        val last = merged.lastOrNull()
        val dayAfterLast = last?.let {
            Calendar.getInstance().apply { timeInMillis = it.second; add(Calendar.DAY_OF_YEAR, 1) }.timeInMillis
        }
        if (last != null && dayAfterLast != null && range.first <= dayAfterLast) {
            merged[merged.lastIndex] = last.first to maxOf(last.second, range.second)
        } else {
            merged += range
        }
    }
    val encoded = JSONArray().apply {
        merged.forEach { (start, end) -> put(JSONObject().put("start", start).put("end", end)) }
    }.toString()
    preferences.setTripScanPending(null)
    preferences.setTripSuppressedRanges(encoded)
}

@Composable
private fun TripIntroductionDialog(
    context: Context,
    dao: com.ct106.difangke.data.db.dao.TripDao,
    homeCity: HomeCityEntity?,
    onDismiss: () -> Unit
) {
    var selectedCity by remember(homeCity) { mutableStateOf(homeCity?.let(::SelectedHomeCity)) }
    var scan by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = {},
        icon = { Icon(Icons.Default.Map, null) },
        title = { Text("欢迎使用出行") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("设置常居地后，离开常居地的记录会自动整理成行程。")
                HomeCitySearchField(selectedCity) { selectedCity = it }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("整理已有足迹", Modifier.weight(1f)); Switch(scan, { scan = it }) }
                Text("原始足迹、交通和照片不会被修改。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(
                    enabled = selectedCity != null,
                    onClick = {
                        scope.launch {
                            dao.upsertHomeCity(selectedCity!!.entity(homeCity?.id ?: "home"))
                            val preferences = AppPreferences(context)
                            preferences.setTripAutomaticRecognitionEnabled(scan)
                            preferences.setTripIntroductionCompleted(true)
                            if (scan) TripScanWorker.schedule(context, runNow = true)
                            onDismiss()
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(52.dp)
                ) { Text("开始使用", fontWeight = FontWeight.Bold) }
            }
        },
        confirmButton = {}
    )
}

private data class ImportedAndroidCity(
    val countryCode: String,
    val countryName: String,
    val cityName: String,
    val latitude: Double?,
    val longitude: Double?
)

private suspend fun importFootprintCities(context: Context, start: Date, end: Date): Map<Long, List<ImportedAndroidCity>> = withContext(Dispatchers.Default) {
    val upper = Calendar.getInstance().apply { time = end; add(Calendar.DAY_OF_YEAR, 1) }.time
    AppDatabase.getInstance(context).footprintDao().getBetween(start, upper)
        .groupBy { startOfLocalDay(it.startTime).time }
        .mapValues { (_, footprints) ->
            footprints.mapNotNull { footprint ->
                footprint.cityName?.trim()?.takeIf { it.isNotEmpty() }?.let { name ->
                    ImportedAndroidCity(
                        footprint.countryCode.orEmpty(), footprint.countryName.orEmpty(), name,
                        firstJsonValue(footprint.latitudeJson), firstJsonValue(footprint.longitudeJson)
                    )
                }
            }.distinctBy { "${it.countryCode.lowercase()}|${it.cityName.lowercase()}" }
        }
}

private fun firstJsonValue(json: String): Double? = runCatching { JSONArray(json).optDouble(0).takeUnless { it.isNaN() } }.getOrNull()
private fun startOfLocalDay(date: Date): Date = Calendar.getInstance().apply { time = date; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.time
private fun formatShortDate(date: Date): String = SimpleDateFormat("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE).format(date)
