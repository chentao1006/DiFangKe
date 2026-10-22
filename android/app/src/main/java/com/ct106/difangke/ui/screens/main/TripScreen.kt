package com.ct106.difangke.ui.screens.main

import android.content.Context
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
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
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
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.*

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
    var splittingTrip by remember { mutableStateOf<TripEntity?>(null) }
    var deletingTrip by remember { mutableStateOf<TripEntity?>(null) }
    var showingCreate by remember { mutableStateOf(false) }
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
    val remaining = trips.filterNot { it.id == active?.id }.sortedWith(
        compareBy<TripEntity> { it.state != TripState.PLANNED }
            .thenBy { if (it.state == TripState.PLANNED) it.plannedStartDay.time else -it.plannedStartDay.time }
    )
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
                        IconButton(onClick = { showingCreate = true }) { Icon(Icons.Default.Add, "创建行程") }
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
                        onEdit = { editingTrip = trip },
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
            yearGroups.forEach { (year, yearTrips) ->
                item(key = "year-$year") {
                    Text(
                        "$year年",
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
                        onEdit = { editingTrip = trip },
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
                        Text("根据日期自动判断计划、进行中或历史行程", color = MaterialTheme.colorScheme.onSurfaceVariant)
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
                        Spacer(Modifier.width(10.dp)); Text("正在后台扫描历史足迹…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        PullRefreshIndicator(scanRunning, pullRefreshState, Modifier.align(Alignment.TopCenter))
        }
    }

    if (showingCreate) {
        CreateTripDialog(context = context, dao = dao, onDismiss = { showingCreate = false })
    }
    if (showingOptions) {
        TripOptionsDialog(context = context, dao = dao, onDismiss = { showingOptions = false })
    }
    if (showingIntroduction) {
        TripIntroductionDialog(context, dao, homeCity) { showingIntroduction = false }
    }
    editingTrip?.let { trip ->
        Dialog(onDismissRequest = { editingTrip = null }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            TripEditorScreen(trip = trip, activityTypes = activityTypes, dao = dao, onDismiss = { editingTrip = null })
        }
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
    selectedTrip?.let { trip ->
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
    var menuExpanded by remember { mutableStateOf(false) }
    val tint = when (trip.state) {
        TripState.ACTIVE -> MaterialTheme.colorScheme.primary
        TripState.PLANNED -> MaterialTheme.colorScheme.secondary
        TripState.DRAFT -> MaterialTheme.colorScheme.tertiary
        TripState.CANCELLED -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Box {
    Card(
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = { menuExpanded = true }),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)
    ) {
        val tripDayIDs = allDays.asSequence().filter { it.tripID == trip.id }.map { it.id }.toSet()
        val storedItems = allItems.filter { it.tripDayID in tripDayIDs }.sortedBy { it.orderIndex }
        val tripItems = if (trip.kindRaw == TripKind.HISTORICAL.raw) {
            actualTripItems(allDays.filter { it.id in tripDayIDs }, allFootprints, transportRecords)
        } else storedItems
        val tripCities = allCities.filter { it.tripDayID in tripDayIDs }.sortedBy { it.orderIndex }
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
            val cityText = allCities.asSequence()
                .filter { it.tripDayID in tripDayIDs }
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
            Text(formatRange(trip.plannedStartDay, trip.plannedEndDay), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (prominent) {
                Row(Modifier.fillMaxWidth().background(tint.copy(alpha = .08f), RoundedCornerShape(12.dp)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.LocationOn, null, tint = tint)
                    Spacer(Modifier.width(8.dp))
                    Column { Text("行程进行中", fontWeight = FontWeight.SemiBold); Text("查看地图与今日安排", style = MaterialTheme.typography.bodySmall) }
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
        if (tripInclusiveDayCount(trip.plannedStartDay, trip.plannedEndDay) > 1 &&
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripDetailScreen(
    trip: TripEntity,
    activityTypes: List<ActivityTypeEntity>,
    transportRecords: List<TransportRecordEntity>,
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
                    days.forEach { day ->
                        val dayCities = cities.filter { it.tripDayID == day.id }
                        val dayItems = items.filter { it.tripDayID == day.id }.sortedWith(
                            compareBy<TripItemEntity> { it.startTime }.thenBy { it.orderIndex }
                        )
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.fillMaxWidth().height(30.dp)) {
                                Box(
                                    Modifier
                                        .fillMaxWidth()
                                        .height(2.dp)
                                        .offset(y = (-12).dp)
                                        .background(timelineLineColor())
                                )
                                Box(
                                    Modifier
                                        .width(2.dp)
                                        .height(30.dp)
                                        .offset(x = TimelineLayout.markerCenterX - 1.dp)
                                        .background(timelineLineColor())
                                )
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        SimpleDateFormat("M月d日", Locale.SIMPLIFIED_CHINESE).format(day.day),
                                        style = MaterialTheme.typography.labelMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.width(TimelineLayout.dateColumnWidth)
                                    )
                                    if (dayCities.isNotEmpty()) {
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            dayCities.joinToString(" · ") { it.cityName },
                                            style = MaterialTheme.typography.labelMedium,
                                            fontWeight = FontWeight.SemiBold,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                            }
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
                    when (trip.state) {
                        TripState.PLANNED -> Button(onClick = { scope.launch { dao.upsertTrip(trip.copy(stateRaw = TripState.ACTIVE.raw, actualStartedAt = Date(), updatedAt = Date())) } }, Modifier.fillMaxWidth()) { Text("开始行程") }
                        TripState.ACTIVE -> Button(onClick = { scope.launch { dao.upsertTrip(trip.copy(kindRaw = TripKind.HISTORICAL.raw, stateRaw = TripState.HISTORICAL.raw, actualEndedAt = Date(), endReasonRaw = "manual", updatedAt = Date())) } }, Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("结束行程") }
                        else -> Unit
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

private data class TripItemEditTarget(val day: TripDayEntity, val item: TripItemEntity?, val kindRaw: String, val afterStopID: String? = null)
private data class TripPlaceTarget(val day: TripDayEntity, val item: TripItemEntity?)
private data class TripPlaceSelection(val result: GeocodeService.SearchResult, val details: GeocodeService.ReverseGeocodeResult)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripEditorScreen(
    trip: TripEntity,
    activityTypes: List<ActivityTypeEntity>,
    dao: com.ct106.difangke.data.db.dao.TripDao,
    onDismiss: () -> Unit
) {
    val days by dao.observeDays(trip.id).collectAsState(initial = emptyList())
    val allCities by dao.observeAllCities().collectAsState(initial = emptyList())
    val allItems by dao.observeAllItems().collectAsState(initial = emptyList())
    var title by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(trip.title)) }
    var notes by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(trip.notes)) }
    var itemTarget by remember { mutableStateOf<TripItemEditTarget?>(null) }
    var placeTarget by remember { mutableStateOf<TripPlaceTarget?>(null) }
    var activityTypeValue by rememberSaveable { mutableStateOf(trip.activityTypeValue) }
    val scope = rememberCoroutineScope()

    Surface(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("编辑行程") },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "取消") } },
                    actions = {
                        TextButton(onClick = {
                            scope.launch {
                                dao.upsertTrip(trip.copy(title = title.text.trim(), notes = notes.text, activityTypeValue = activityTypeValue, titleUserEdited = true, updatedAt = Date()))
                                onDismiss()
                            }
                        }) { Text("完成") }
                    }
                )
            }
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedTextField(title, { title = it }, label = { Text("标题") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(notes, { notes = it }, label = { Text("备注") }, modifier = Modifier.fillMaxWidth())
                TripActivityTypeMenu(activityTypes, activityTypeValue) { activityTypeValue = it }
                if (trip.kindRaw == TripKind.HISTORICAL.raw) {
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.CalendarMonth, null)
                                Spacer(Modifier.width(8.dp))
                                Text("实际记录按日期关联", fontWeight = FontWeight.Bold)
                            }
                            Text("足迹和交通来自记录页；在记录页修改后，这里会自动同步。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                            days.forEach { day ->
                                Text(SimpleDateFormat("yyyy年M月d日 EEEE", Locale.SIMPLIFIED_CHINESE).format(day.day))
                            }
                        }
                    }
                } else days.forEach { day ->
                    val dayItems = allItems.filter { it.tripDayID == day.id }.sortedBy { it.orderIndex }
                    Text(SimpleDateFormat("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE).format(day.day), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    val stops = dayItems.filter { it.kindRaw == "stop" }
                    stops.groupBy { it.cityName?.takeIf { name -> name.isNotBlank() } ?: "未识别城市" }.forEach { (cityName, cityStops) ->
                        Text(cityName, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        cityStops.forEach { stop ->
                            val following = dayItems.dropWhile { it.id != stop.id }.drop(1).takeWhile { it.kindRaw == "transport" }
                            val activity = activityTypes.firstOrNull { it.id == stop.activityTypeValue || it.name == stop.activityTypeValue }
                            val activityTint = parseActivityColor(activity?.colorHex)
                            var dragY by remember(stop.id) { mutableFloatStateOf(0f) }
                            var stopMenu by remember(stop.id) { mutableStateOf(false) }
                            Box {
                                Surface(
                                    shape = RoundedCornerShape(16.dp),
                                    color = MaterialTheme.colorScheme.surfaceVariant,
                                    modifier = Modifier.fillMaxWidth().combinedClickable(
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
                                            val detail = listOfNotNull(stop.startTime?.let { SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE).format(it) }, activity?.name).joinToString(" · ")
                                            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            stop.address?.takeIf { it.isNotBlank() && it != stop.placeName }?.let { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                        }
                                        Icon(Icons.Default.DragHandle, "拖动排序", Modifier.pointerInput(stop.id) {
                                            detectDragGesturesAfterLongPress(
                                                onDragStart = { dragY = 0f },
                                                onDrag = { change, amount -> change.consume(); dragY += amount.y },
                                                onDragEnd = {
                                                    val direction = when { dragY > 24f -> 1; dragY < -24f -> -1; else -> 0 }
                                                    if (direction != 0) scope.launch { reorderTripStop(dayItems, cityStops, stop, direction, dao) }
                                                }
                                            )
                                        }, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                DropdownMenu(expanded = stopMenu, onDismissRequest = { stopMenu = false }) {
                                    DropdownMenuItem(text = { Text("删除地点") }, leadingIcon = { Icon(Icons.Default.DeleteOutline, null) }, onClick = {
                                        stopMenu = false
                                        scope.launch { (following + stop).forEach { dao.deleteItem(it) }; normalizeTripItems(dayItems.filter { it.id != stop.id && it !in following }, dao) }
                                    })
                                }
                            }
                            following.forEach { transport ->
                                var transportMenu by remember(transport.id) { mutableStateOf(false) }
                                Box(Modifier.padding(start = 28.dp)) {
                                    Row(
                                        Modifier.fillMaxWidth().combinedClickable(
                                            onClick = { itemTarget = TripItemEditTarget(day, transport, "transport", stop.id) },
                                            onLongClick = { transportMenu = true }
                                        ).padding(vertical = 10.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Icon(timelineTransportIcon(transport.transportTypeRaw.orEmpty()), null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                                        Spacer(Modifier.width(10.dp)); Text(tripItemEditorTitle(transport), Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                                    }
                                    DropdownMenu(expanded = transportMenu, onDismissRequest = { transportMenu = false }) {
                                        DropdownMenuItem(text = { Text("删除交通") }, leadingIcon = { Icon(Icons.Default.DeleteOutline, null) }, onClick = { transportMenu = false; scope.launch { dao.deleteItem(transport) } })
                                    }
                                }
                            }
                            if (dayItems.dropWhile { it.id != stop.id }.drop(1).any { it.kindRaw == "stop" }) {
                                TextButton(onClick = { itemTarget = TripItemEditTarget(day, null, "transport", stop.id) }, Modifier.padding(start = 48.dp)) {
                                    Icon(Icons.Default.AddCircleOutline, null); Spacer(Modifier.width(6.dp)); Text("添加交通")
                                }
                            }
                        }
                        TripAddPlaceCard { placeTarget = TripPlaceTarget(day, null) }
                    }
                    if (stops.isEmpty()) {
                        TripAddPlaceCard { placeTarget = TripPlaceTarget(day, null) }
                    }
                    HorizontalDivider()
                }
            }
        }
    }

    placeTarget?.let { target ->
        TripPlaceSearchDialog(onDismiss = { placeTarget = null }) { selection ->
            scope.launch {
                val result = selection.result; val details = selection.details
                val base = target.item ?: TripItemEntity(tripDayID = target.day.id, kindRaw = "stop", orderIndex = allItems.count { it.tripDayID == target.day.id })
                dao.upsertItem(base.copy(placeName = result.name, address = result.address, latitude = result.latitude, longitude = result.longitude, countryCode = details.countryCode, countryName = details.countryName, cityName = details.cityName))
                val key = "${details.countryCode}|${details.cityName}".lowercase()
                if (!details.cityName.isNullOrBlank() && allCities.none { it.tripDayID == target.day.id && "${it.countryCode}|${it.cityName}".lowercase() == key }) {
                    dao.upsertCity(TripDayCityEntity(tripDayID = target.day.id, countryCode = details.countryCode.orEmpty(), countryName = details.countryName.orEmpty(), cityName = details.cityName, latitude = result.latitude, longitude = result.longitude, orderIndex = allCities.count { it.tripDayID == target.day.id }))
                }
                dao.upsertTrip(trip.copy(citiesUserEdited = true, updatedAt = Date())); placeTarget = null
            }
        }
    }
    itemTarget?.let { target ->
        TripItemEditorDialog(target = target, onDismiss = { itemTarget = null }) { item ->
            scope.launch {
                if (target.item == null && target.afterStopID != null) {
                    val dayItems = allItems.filter { it.tripDayID == target.day.id }.sortedBy { it.orderIndex }
                    val stopIndex = dayItems.indexOfFirst { it.id == target.afterStopID }
                    val insertion = stopIndex + 1 + dayItems.drop(stopIndex + 1).takeWhile { it.kindRaw == "transport" }.size
                    dayItems.drop(insertion).forEach { dao.upsertItem(it.copy(orderIndex = it.orderIndex + 1)) }
                    dao.upsertItem(item.copy(orderIndex = insertion))
                } else dao.upsertItem(item)
                dao.upsertTrip(trip.copy(citiesUserEdited = true, updatedAt = Date()))
                itemTarget = null
            }
        }
    }
}

@Composable
private fun TripAddPlaceCard(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(38.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Add, null, tint = MaterialTheme.colorScheme.primary)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("添加地点", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                Text("选择地点后自动识别城市", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        }
    }
}

private suspend fun normalizeTripItems(items: List<TripItemEntity>, dao: com.ct106.difangke.data.db.dao.TripDao) {
    items.sortedBy { it.orderIndex }.forEachIndexed { index, item -> dao.upsertItem(item.copy(orderIndex = index)) }
}

private suspend fun reorderTripStop(
    dayItems: List<TripItemEntity>, cityStops: List<TripItemEntity>, stop: TripItemEntity, direction: Int,
    dao: com.ct106.difangke.data.db.dao.TripDao
) {
    val localIndex = cityStops.indexOfFirst { it.id == stop.id }
    val target = localIndex + direction
    if (localIndex < 0 || target !in cityStops.indices) return
    val reorderedCity = cityStops.toMutableList().apply { add(target, removeAt(localIndex)) }
    val iterator = reorderedCity.iterator()
    val orderedStops = dayItems.filter { it.kindRaw == "stop" }.map { candidate ->
        if (cityStops.any { it.id == candidate.id }) iterator.next() else candidate
    }
    val rebuilt = buildList {
        orderedStops.forEach { orderedStop ->
            add(orderedStop)
            val tail = dayItems.dropWhile { it.id != orderedStop.id }.drop(1).takeWhile { it.kindRaw == "transport" }
            addAll(tail)
        }
    }
    normalizeTripItems(rebuilt, dao)
}

private fun tripItemEditorTitle(item: TripItemEntity): String = if (item.kindRaw == "transport") {
    val type = TransportType.from(item.transportTypeRaw.orEmpty()).localizedName
    item.lineName?.takeIf { it.isNotBlank() }?.let { "$type · $it" } ?: type
} else item.placeName ?: item.address ?: item.cityName ?: "足迹"

@Composable
private fun TripPlaceSearchDialog(onDismiss: () -> Unit, onSelect: (TripPlaceSelection) -> Unit) {
    val scope = rememberCoroutineScope()
    var query by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
    var results by remember { mutableStateOf<List<GeocodeService.SearchResult>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var resolving by remember { mutableStateOf(false) }
    LaunchedEffect(query.text) {
        val value = query.text.trim()
        if (value.isEmpty()) { results = emptyList(); searching = false; return@LaunchedEffect }
        kotlinx.coroutines.delay(400); searching = true
        results = runCatching { GeocodeService.shared.searchPlaces(value) }.getOrDefault(emptyList())
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
                LazyColumn {
                    items(results, key = { "${it.name}|${it.latitude}|${it.longitude}" }) { result ->
                        ListItem(
                            headlineContent = { Text(result.name) },
                            supportingContent = { Text(result.address, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            modifier = Modifier.clickable(enabled = !resolving) {
                                resolving = true
                                scope.launch {
                                    val details = runCatching { GeocodeService.shared.reverseGeocodeDetails(result.latitude, result.longitude) }.getOrNull()
                                    if (details?.cityName != null) onSelect(TripPlaceSelection(result, details)) else resolving = false
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
    var lineName by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(original?.lineName.orEmpty())) }
    var notes by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(original?.notes.orEmpty())) }
    var startTime by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE).format(original?.startTime ?: target.day.day))) }
    var endTime by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE).format(original?.endTime ?: target.day.day))) }
    var transportTypeRaw by rememberSaveable { mutableStateOf(original?.transportTypeRaw ?: TransportType.SLOW.raw) }
    var typeMenuExpanded by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (target.kindRaw == "transport") "编辑交通" else "编辑足迹") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box {
                    OutlinedButton(onClick = { typeMenuExpanded = true }, Modifier.fillMaxWidth()) {
                        Text(TransportType.from(transportTypeRaw).localizedName)
                    }
                    DropdownMenu(expanded = typeMenuExpanded, onDismissRequest = { typeMenuExpanded = false }) {
                        TransportType.entries.forEach { type ->
                            DropdownMenuItem(text = { Text(type.localizedName) }, onClick = { transportTypeRaw = type.raw; typeMenuExpanded = false })
                        }
                    }
                }
                OutlinedTextField(lineName, { lineName = it }, label = { Text("线路（可选）") })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(startTime, { startTime = it }, label = { Text("开始 HH:mm") }, singleLine = true, modifier = Modifier.weight(1f))
                    OutlinedTextField(endTime, { endTime = it }, label = { Text("结束 HH:mm") }, singleLine = true, modifier = Modifier.weight(1f))
                }
                OutlinedTextField(notes, { notes = it }, label = { Text("备注") })
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val base = original ?: TripItemEntity(
                    tripDayID = target.day.id, kindRaw = target.kindRaw,
                    orderIndex = 0, startTime = target.day.day, endTime = target.day.day
                )
                onSave(base.copy(
                    kindRaw = target.kindRaw,
                    startTime = tripEditorTime(startTime.text, target.day.day) ?: base.startTime,
                    endTime = tripEditorTime(endTime.text, target.day.day) ?: base.endTime,
                    transportTypeRaw = transportTypeRaw,
                    lineName = lineName.text.trim(),
                    notes = notes.text
                ))
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

private fun tripEditorTime(value: String, day: Date): Date? {
    val parsed = runCatching { SimpleDateFormat("HH:mm", Locale.SIMPLIFIED_CHINESE).apply { isLenient = false }.parse(value.trim()) }.getOrNull() ?: return null
    val time = Calendar.getInstance().apply { this.time = parsed }
    return Calendar.getInstance().apply {
        this.time = day
        set(Calendar.HOUR_OF_DAY, time.get(Calendar.HOUR_OF_DAY))
        set(Calendar.MINUTE, time.get(Calendar.MINUTE))
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.time
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
    onOpenFootprint: (String) -> Unit
) {
    val context = LocalContext.current
    val mapView = remember { mutableStateOf<TextureMapView?>(null) }
    val holder = remember { TripMapHolder() }
    val footprintByID = remember(footprints) { footprints.associateBy { it.footprintID } }
    val tripTransportIDs = remember(items) { items.mapNotNull { it.sourceTransportRecordID }.toSet() }
    val tripTransports = remember(transportRecords, tripTransportIDs) {
        transportRecords.filter { it.recordID in tripTransportIDs }
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
            val overlayKey = cities.joinToString("|") { "${it.id}:${it.latitude},${it.longitude}" } +
                items.joinToString("|") { "${it.id}:${it.latitude},${it.longitude}:${it.activityTypeValue}" } +
                activityTypes.joinToString("|") { "${it.id}:${it.icon}:${it.colorHex}" } +
                tripTransports.joinToString("|") { "${it.recordID}:${it.pointsJson.hashCode()}" } +
                "|${selectedItem?.id}|$isDark|${photoBitmaps.keys.sorted().joinToString(",")}"
            if (holder.overlayKey != overlayKey) {
                holder.overlayKey = overlayKey
                map.clear()
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
                map.addFootprintMarkers(
                    mapMarkers,
                    isDark = isDark,
                    onMarkerClick = { markerID ->
                        if (!markerID.startsWith("transport:")) onOpenFootprint(markerID)
                    },
                    photoBitmaps = photoBitmaps
                )
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
            }
            val cameraKey = selectedItem?.id ?: allCoordinates.joinToString("|") { "${it.latitude},${it.longitude}" }
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
private fun CreateTripDialog(context: Context, dao: com.ct106.difangke.data.db.dao.TripDao, onDismiss: () -> Unit) {
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
                        normalizedEnd.before(today) -> TripState.HISTORICAL
                        !startDay.after(today) -> TripState.ACTIVE
                        else -> TripState.PLANNED
                    }
                    val trip = TripEntity(title = titleValue.text.trim(), notes = notesValue.text, activityTypeValue = activityTypeValue, kindRaw = if (state == TripState.PLANNED) TripKind.PLANNED.raw else TripKind.HISTORICAL.raw, stateRaw = state.raw, plannedStartDay = startDay, plannedEndDay = normalizedEnd, actualStartedAt = if (state == TripState.ACTIVE) startDay else null, titleUserEdited = true, datesUserEdited = true)
                    dao.upsertTrip(trip)
                    val imported = if (importExisting) importFootprintCities(context, startDay, normalizedEnd) else emptyMap()
                    val createdDays = mutableMapOf<Long, TripDayEntity>()
                    imported.forEach { (dayTime, cities) ->
                        val day = TripDayEntity(tripID = trip.id, day = Date(dayTime)); dao.upsertDay(day); createdDays[dayTime] = day
                        cities.forEachIndexed { index, value -> dao.upsertCity(TripDayCityEntity(tripDayID = day.id, countryCode = value.countryCode, countryName = value.countryName, cityName = value.cityName, latitude = value.latitude, longitude = value.longitude, orderIndex = index, isUserEdited = false)) }
                    }
                    days.forEach { dayTime ->
                        val day = createdDays[dayTime] ?: TripDayEntity(tripID = trip.id, day = Date(dayTime)).also { dao.upsertDay(it) }
                        val importedKeys = imported[dayTime].orEmpty().map { "${it.countryCode}|${it.cityName}".lowercase() }.toSet()
                        citiesByDay[dayTime].orEmpty().filterNot { it.key in importedKeys }.forEachIndexed { index, city ->
                            dao.upsertCity(TripDayCityEntity(tripDayID = day.id, countryCode = city.countryCode, countryName = city.countryName, cityName = city.cityName, latitude = city.latitude, longitude = city.longitude, orderIndex = index, isUserEdited = true))
                        }
                    }
                    onDismiss()
                }
            }) { Text("创建") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
    if (choosingStart || choosingEnd) {
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = if (choosingStart) startDay.time else endDay.time)
        DatePickerDialog(onDismissRequest = { choosingStart = false; choosingEnd = false }, confirmButton = {
            TextButton(onClick = {
                pickerState.selectedDateMillis?.let { selected ->
                    if (choosingStart) {
                        val durationDays = tripInclusiveDayCount(startDay, maxOf(startDay, endDay)) - 1
                        startDay = startOfLocalDay(Date(selected))
                        endDay = Calendar.getInstance().apply {
                            time = startDay
                            add(Calendar.DAY_OF_YEAR, durationDays)
                        }.time
                    }
                    else endDay = maxOf(startDay, startOfLocalDay(Date(selected)))
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
    val localMatches = remember(queryValue.text) { localCatalogMatches(queryValue.text) }
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
                            modifier = Modifier.clickable { onSelect(city) }
                        )
                    }
                    items(
                        results.filter { result -> localMatches.none { it.key == SelectedHomeCity(result).key } },
                        key = { "network|${it.countryCode}|${it.cityName}" }
                    ) { result ->
                        ListItem(
                            headlineContent = { Text(result.cityName) },
                            supportingContent = { if (result.countryName.isNotBlank()) Text(result.countryName) },
                            modifier = Modifier.clickable { onSelect(SelectedHomeCity(result)) }
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
    val longitude: Double
) {
    constructor(home: HomeCityEntity) : this(home.cityName, home.countryCode, home.countryName, home.latitude ?: 0.0, home.longitude ?: 0.0)
    constructor(result: GeocodeService.CitySearchResult) : this(result.cityName, result.countryCode, result.countryName, result.latitude, result.longitude)
    constructor(city: ConfiguredTripCity) : this(city.cityName, city.countryCode, city.countryName, city.latitude, city.longitude)
    val label: String get() = if (countryName.isBlank()) cityName else "$cityName，$countryName"
    val key: String get() = "$countryCode|$cityName".lowercase()
    fun entity(id: String) = HomeCityEntity(id = id, cityName = cityName, countryCode = countryCode, countryName = countryName, latitude = latitude, longitude = longitude, updatedAt = Date())
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
    var draggedCityInitial by remember { mutableStateOf<String?>(null) }
    var cityIndexHeightPx by remember { mutableIntStateOf(0) }

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
                    longitude = coordinates.second
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
                    modifier = Modifier.clickable { onSelect(city); queryValue = TextFieldValue() }
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
                                    modifier = Modifier.clickable { onSelect(city) }
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
                            modifier = Modifier.clickable { onSelect(city); queryValue = TextFieldValue() }
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
                            modifier = Modifier.clickable { onSelect(SelectedHomeCity(city)); queryValue = TextFieldValue() }
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
                Row(verticalAlignment = Alignment.CenterVertically) { Text("自动识别行程", Modifier.weight(1f)); Switch(auto, { auto = it }) }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("行程通知与实时状态", Modifier.weight(1f)); Switch(notifications, { notifications = it }) }
                Text("常居地只由你设置，系统不会自行猜测。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                HorizontalDivider()
                TextButton(
                    onClick = { confirmingRescan = true },
                    enabled = !scanRunning && auto && selectedCity != null,
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) { Text("重新扫描历史足迹") }
                Text(
                    "替换未手动编辑的自动行程并在后台重新识别。手动行程和用户修改内容会保留。",
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
            title = { Text("重新扫描历史足迹？") },
            text = { Text("未手动编辑的自动行程会被替换。原始足迹、手动行程和用户修改内容不会删除。") },
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
                }) { Text("重新扫描", color = MaterialTheme.colorScheme.error) }
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
                Text("把分散的足迹按日期和城市整理成行程，识别结果会直接加入出行列表。")
                HomeCitySearchField(selectedCity) { selectedCity = it }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("在后台扫描历史足迹", Modifier.weight(1f)); Switch(scan, { scan = it }) }
                Text("扫描分批执行，只读取足迹中已有的城市信息，不会修改原始足迹。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
