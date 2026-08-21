package com.ct106.difangke.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.service.OpenAIService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import com.ct106.difangke.data.model.DaySummary
import com.ct106.difangke.data.model.TimelineItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.ct106.difangke.data.location.RawLocationStore
import com.ct106.difangke.service.PhotoService
import com.ct106.difangke.service.PlaceMatcher
import com.ct106.difangke.service.GeocodeService

class HistoryViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DiFangKeApp.instance.database
    val openAI = OpenAIService.shared
    private val builder = com.ct106.difangke.service.PersistentTimelineBuilder(application)

    private val _footprints = MutableStateFlow<List<FootprintEntity>>(emptyList())
    
    // 按天分组的足迹
    val groupedFootprints = _footprints.map { list ->
        list.groupBy { fp ->
            val cal = Calendar.getInstance()
            cal.time = fp.startTime
            cal.set(Calendar.HOUR_OF_DAY, 0)
            cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            cal.time
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val _summaries = MutableStateFlow<Map<Date, DaySummary>>(emptyMap())
    val summaries: StateFlow<Map<Date, DaySummary>> = _summaries.asStateFlow()

    private val _activityTypes = MutableStateFlow<List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>>(emptyList())
    val activityTypes: StateFlow<List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>> = _activityTypes.asStateFlow()

    private val _allPlaces = MutableStateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>>(emptyList())
    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = _allPlaces.asStateFlow()

    val favoriteFootprints = _footprints.map { list ->
        list.filter { it.isHighlight == true && it.statusValue != "ignored" }
            .sortedByDescending { it.startTime }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _lastDataSyncTrigger = MutableStateFlow(Date())
    val lastDataSyncTrigger: StateFlow<Date> = _lastDataSyncTrigger.asStateFlow()

    private val _photoCandidates = MutableStateFlow<List<FootprintEntity>>(emptyList())
    val photoCandidates: StateFlow<List<FootprintEntity>> = _photoCandidates.asStateFlow()
    private val _isScanningPhotos = MutableStateFlow(false)
    val isScanningPhotos: StateFlow<Boolean> = _isScanningPhotos.asStateFlow()

    init {
        refreshData()
        viewModelScope.launch {
            combine(
                db.footprintDao().observeAll(),
                db.futureTripDao().observeAll(),
                db.transportRecordDao().observeAll()
            ) { _, _, _ -> Unit }.drop(1).collect { refreshData() }
        }
    }

    fun refreshData() {
        viewModelScope.launch {
            _isRefreshing.value = true
            val allFootprints = db.footprintDao().getAll()
            val allActivityTypes = db.activityTypeDao().getAll()
            val allPlaces = db.placeDao().getAll()
            val allFutureTrips = db.futureTripDao().getAll()
            val allTransports = db.transportRecordDao().getAllSync().filter { it.statusRaw == "active" }
            
            _footprints.value = allFootprints
            _activityTypes.value = allActivityTypes
            _allPlaces.value = allPlaces
            
            // 计算总结数据 (耗时操作移至 IO 线程)
            withContext(Dispatchers.IO) {
                val grouped = allFootprints.groupBy { fp ->
                    Calendar.getInstance().apply {
                        time = fp.startTime
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }.time
                }
                val futureTripsByDate = allFutureTrips
                    .filter { trip -> trip.hasPlanDate && !trip.isCompleted }
                    .groupBy { trip ->
                        Calendar.getInstance().apply {
                            time = trip.arrivalDate
                            set(Calendar.HOUR_OF_DAY, 0)
                            set(Calendar.MINUTE, 0)
                            set(Calendar.SECOND, 0)
                            set(Calendar.MILLISECOND, 0)
                        }.time
                    }
                val transportsByDate = allTransports.groupBy { transport ->
                    Calendar.getInstance().apply {
                        time = transport.day
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }.time
                }
                
                val summaryMap = mutableMapOf<Date, DaySummary>()
                (grouped.keys + futureTripsByDate.keys + transportsByDate.keys).forEach { date ->
                    val fps = grouped[date].orEmpty()
                    val futureTrips = futureTripsByDate[date].orEmpty()
                    val transports = transportsByDate[date].orEmpty()
                    
                    val timelineItems = (fps.map { TimelineItem.FootprintItem(it) } + 
                                       transports.map { TimelineItem.TransportItem(it) } +
                                       futureTrips.map { TimelineItem.FutureTripItem(it) })
                                       .sortedByDescending { it.startTime }
                    
                    val store = RawLocationStore.getInstance(getApplication())
                    val totalMileage = store.calculateTotalDistance(date)
                    val totalPoints = store.getTotalPointsCount(date)
                    
                    val icons = buildTimelineIcons(timelineItems, allActivityTypes)
                    val activityById = allActivityTypes.associateBy { it.id }
                    val latestFootprintId = fps.maxByOrNull { it.startTime }?.footprintID
                    val isToday = Calendar.getInstance().run {
                        time = date
                        val today = Calendar.getInstance()
                        get(Calendar.YEAR) == today.get(Calendar.YEAR) &&
                            get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)
                    }
                    val segments = buildList {
                        fps.forEach { footprint ->
                            add(DaySummary.TimelineSegment(
                                id = footprint.footprintID,
                                startTime = footprint.startTime,
                                endTime = footprint.endTime,
                                colorHex = activityById[footprint.activityTypeValue]?.colorHex ?: "#00A0AC",
                                isTransport = false,
                                isCurrent = isToday && footprint.footprintID == latestFootprintId
                            ))
                        }
                        transports.forEach { transport ->
                            add(DaySummary.TimelineSegment(
                                id = transport.recordID,
                                startTime = transport.startTime,
                                endTime = transport.endTime,
                                colorHex = "#00A0AC",
                                isTransport = true,
                                isCurrent = false
                            ))
                        }
                    }.sortedBy { it.startTime }

                    summaryMap[date] = DaySummary(
                        date = date,
                        totalDuration = fps.sumOf { it.duration },
                        footprintCount = fps.map { (it.title ?: "").ifEmpty { it.locationHash } }.distinct().size,
                        highlightCount = fps.count { it.isHighlight == true },
                        highlightTitle = fps.firstOrNull { it.isHighlight == true }?.title,
                        hasConfirmed = fps.any { it.aiAnalyzed } || futureTrips.isNotEmpty(),
                        hasCandidate = fps.any { !it.aiAnalyzed },
                        timelineIcons = icons,
                        timelineSegments = segments,
                        plannedArrivalTimes = futureTrips.filter { it.hasArrivalTime }.map { it.arrivalDate },
                        trajectoryCount = totalPoints,
                        mileage = totalMileage
                    )
                }
                _summaries.value = summaryMap
            }
            _isRefreshing.value = false
        }
    }

    fun deleteFootprint(footprint: FootprintEntity) {
        viewModelScope.launch {
            db.footprintDao().delete(footprint)
            refreshData()
        }
    }

    fun rebuildTimeline(date: Date) {
        viewModelScope.launch {
            _isRefreshing.value = true
            builder.rebuildDay(date)
            refreshData()
            _isRefreshing.value = false
            _lastDataSyncTrigger.value = Date()
        }
    }

    fun scanPhotos(photoUris: List<android.net.Uri>) {
        viewModelScope.launch {
            _isScanningPhotos.value = true
            val existingPhotoUris = db.footprintDao().getAll()
                .flatMap { footprint ->
                    runCatching {
                        val ids = org.json.JSONArray(footprint.photoAssetIDsJson)
                        (0 until ids.length()).mapNotNull { ids.optString(it).takeIf(String::isNotBlank) }
                    }.getOrDefault(emptyList())
                }
                .toSet()
            val rawCandidates = PhotoService.getInstance(getApplication())
                .scanFootprintCandidates(photoUris, existingPhotoUris)
            val places = db.placeDao().getAll()
            _photoCandidates.value = withContext(Dispatchers.IO) {
                rawCandidates.mapNotNull { candidate ->
                    val coordinate = runCatching {
                        org.json.JSONArray(candidate.latitudeJson).getDouble(0) to
                            org.json.JSONArray(candidate.longitudeJson).getDouble(0)
                    }.getOrNull() ?: return@mapNotNull null
                    val (latitude, longitude) = coordinate
                    // Keep the same safety rule as iOS photo recovery: a place the
                    // user has explicitly ignored must not be recreated by scans.
                    val isNearIgnoredPlace = places.any { place ->
                        if (!place.isIgnored) false else {
                            val meters = FloatArray(1)
                            android.location.Location.distanceBetween(latitude, longitude, place.latitude, place.longitude, meters)
                            meters[0] < 250f
                        }
                    }
                    if (isNearIgnoredPlace) return@mapNotNull null

                    val place = PlaceMatcher.bestPlaceForCoordinate(latitude, longitude, places)
                    // A saved place owns its display label, but it must not prevent
                    // the photo footprint from receiving its geographic hierarchy.
                    val geocode = runCatching {
                        GeocodeService.shared.reverseGeocodeDetails(latitude, longitude)
                    }.getOrNull()
                    val address = when {
                        place?.isUserDefined == true -> place.name
                        !place?.address.isNullOrBlank() -> place?.address
                        else -> geocode?.address
                    }
                    candidate.copy(
                        placeID = place?.placeID,
                        address = address,
                        countryCode = geocode?.countryCode,
                        countryName = geocode?.countryName,
                        cityName = geocode?.cityName
                    )
                }
            }
            _isScanningPhotos.value = false
        }
    }

    fun importPhotoCandidates(candidates: List<FootprintEntity>) {
        viewModelScope.launch {
            if (candidates.isNotEmpty()) db.footprintDao().insertAll(candidates)
            _photoCandidates.value = emptyList()
            refreshData()
        }
    }

    private fun buildTimelineIcons(
        items: List<TimelineItem>,
        activityTypes: List<com.ct106.difangke.data.db.entity.ActivityTypeEntity>
    ): List<DaySummary.TimelineIcon> {
        val ordered = mutableListOf<DaySummary.TimelineIcon>()
        val positions = mutableMapOf<String, Int>()
        val activityTypeById = activityTypes.associateBy { it.id }

        items
            .sortedBy { it.startTime }
            .forEach { item ->
                val isTransport = item is TimelineItem.TransportItem
                val isHighlight = (item as? TimelineItem.FootprintItem)?.footprint?.isHighlight ?: false
                val icon = when (item) {
                    is TimelineItem.FootprintItem -> {
                        activityTypeById[item.footprint.activityTypeValue]?.icon ?: "place"
                    }
                    is TimelineItem.TransportItem -> "directions_bus"
                    is TimelineItem.FutureTripItem -> "explore"
                }
                val colorHex = when (item) {
                    is TimelineItem.FootprintItem -> {
                        activityTypeById[item.footprint.activityTypeValue]?.colorHex ?: "#00A0AC"
                    }
                    is TimelineItem.TransportItem -> "#8E8E93"
                    is TimelineItem.FutureTripItem -> "#FF9500"
                }
                val key = "$icon|$isTransport"
                val existingIndex = positions[key]

                if (existingIndex == null) {
                    positions[key] = ordered.size
                    ordered += DaySummary.TimelineIcon(
                        icon = icon,
                        colorHex = colorHex,
                        isTransport = isTransport,
                        isHighlight = isHighlight
                    )
                } else if (isHighlight && !ordered[existingIndex].isHighlight) {
                    ordered[existingIndex] = ordered[existingIndex].copy(isHighlight = true)
                }
            }

        return ordered.take(10)
    }
}
