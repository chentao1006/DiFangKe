package com.ct106.difangke.ui.screens.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.location.RawLocationStore
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import com.aptabase.Aptabase
import org.json.JSONArray
import java.util.Calendar
import java.util.Date
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

class FootprintDetailViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database
    private val rawStore = RawLocationStore.getInstance(application)

    private val _footprint = MutableStateFlow<FootprintEntity?>(null)
    val footprint: StateFlow<FootprintEntity?> = _footprint.asStateFlow()

    private val _matchedPlace = MutableStateFlow<com.ct106.difangke.data.db.entity.PlaceEntity?>(null)
    val matchedPlace: StateFlow<com.ct106.difangke.data.db.entity.PlaceEntity?> = _matchedPlace.asStateFlow()

    val allPlaces: StateFlow<List<com.ct106.difangke.data.db.entity.PlaceEntity>> = db.placeDao().observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _activityTypes = MutableStateFlow<List<ActivityTypeEntity>>(emptyList())
    val activityTypes: StateFlow<List<ActivityTypeEntity>> = _activityTypes.asStateFlow()

    private val _nearbyPOIs = MutableStateFlow<List<com.ct106.difangke.service.GeocodeService.SearchResult>>(emptyList())
    val nearbyPOIs: StateFlow<List<com.ct106.difangke.service.GeocodeService.SearchResult>> = _nearbyPOIs.asStateFlow()

    private val _previousFootprint = MutableStateFlow<FootprintEntity?>(null)
    val previousFootprint: StateFlow<FootprintEntity?> = _previousFootprint.asStateFlow()

    private val _nextFootprint = MutableStateFlow<FootprintEntity?>(null)
    val nextFootprint: StateFlow<FootprintEntity?> = _nextFootprint.asStateFlow()

    private val geocodeService = com.ct106.difangke.service.GeocodeService.shared

    init {
        viewModelScope.launch {
            db.activityTypeDao().observeAll().collect {
                _activityTypes.value = it
            }
        }
    }

    fun loadFootprint(id: String) {
        viewModelScope.launch {
            val fp = db.footprintDao().getById(id)
            _footprint.value = fp
            refreshAdjacentFootprints(fp)
            
            val allPlaces = db.placeDao().getAll()
            _matchedPlace.value = fp?.placeID?.let { placeID ->
                allPlaces.find { place -> place.placeID == placeID && place.isUserDefined }
            }

            // 加载周边 POI
            if (fp != null) {
                try {
                    val lats = org.json.JSONArray(fp.latitudeJson)
                    val lons = org.json.JSONArray(fp.longitudeJson)
                    if (lats.length() > 0 && lons.length() > 0) {
                        val lat = lats.getDouble(0)
                        val lon = lons.getDouble(0)
                        
                        val amapPois = geocodeService.getNearbyPOIs(lat, lon)
                        
                        // 加载已保存地点
                        val allSaved = db.placeDao().getAll()
                        val nearbySaved = allSaved.filter { 
                             val results = FloatArray(1)
                             android.location.Location.distanceBetween(lat, lon, it.latitude, it.longitude, results)
                             results[0] < 500 // 500米以内视为“附近”
                        }.map {
                            com.ct106.difangke.service.GeocodeService.SearchResult(
                                name = it.name,
                                address = it.address ?: "已保存地点",
                                latitude = it.latitude,
                                longitude = it.longitude,
                                isSavedPlace = true,
                                placeID = it.placeID
                            )
                        }
                        
                        // 合并列表，已保存地点优先
                        _nearbyPOIs.value = (nearbySaved + amapPois).distinctBy { it.name }

                        // 如果地址缺失，自动反查
                        if (fp.address.isNullOrEmpty()) {
                            val addr = geocodeService.reverseGeocode(lat, lon)
                            if (!addr.isNullOrEmpty()) {
                                val updated = fp.copy(address = addr)
                                db.footprintDao().update(updated)
                                _footprint.value = updated
                            }
                        }
                    }
                } catch (e: Exception) {
                    _nearbyPOIs.value = emptyList()
                }
            }
        }
    }

    fun searchPOI(keyword: String) {
        if (keyword.isBlank()) {
             // 如果关键字为空，还原为初始状态列表
             val id = _footprint.value?.footprintID ?: return
             loadFootprint(id)
             return
        }
        
        val fp = _footprint.value ?: return
        viewModelScope.launch {
            try {
                val lats = org.json.JSONArray(fp.latitudeJson)
                val lons = org.json.JSONArray(fp.longitudeJson)
                if (lats.length() > 0 && lons.length() > 0) {
                    val lat = lats.getDouble(0)
                    val lon = lons.getDouble(0)
                    _nearbyPOIs.value = geocodeService.searchNearby(keyword, lat, lon)
                }
            } catch (e: Exception) {
                _nearbyPOIs.value = emptyList()
            }
        }
    }

    fun updateFootprint(
        title: String,
        reason: String,
        address: String,
        placeID: String? = null,
        activityTypeValue: String? = null,
        isHighlight: Boolean = false,
        onSaved: () -> Unit = {}
    ) {
        val current = _footprint.value ?: return
        Aptabase.instance.trackEvent("footprint_edited")
        viewModelScope.launch {
            val updated = current.copy(
                title = title, 
                reason = reason,
                address = address.ifBlank { null },
                placeID = placeID,
                activityTypeValue = activityTypeValue ?: current.activityTypeValue,
                isHighlight = isHighlight,
                isTitleEditedByHand = true,
                aiAnalyzed = true
            )
            db.footprintDao().update(updated)
            _footprint.value = updated
            val allPlaces = db.placeDao().getAll()
            _matchedPlace.value = updated.placeID?.let { id ->
                allPlaces.find { place -> place.placeID == id && place.isUserDefined }
            }
            onSaved()
        }
    }

    fun updateActivityType(activityTypeValue: String?) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = current.copy(
                activityTypeValue = activityTypeValue,
                statusValue = "manual",
                aiAnalyzed = true
            )
            db.footprintDao().update(updated)
            _footprint.value = updated
            refreshAdjacentFootprints(updated)
        }
    }

    /** 收藏是独立即时操作，不能依赖详情页最后的“保存”按钮。 */
    fun setHighlight(isHighlight: Boolean) {
        val current = _footprint.value ?: return
        if (current.isHighlight == isHighlight) return
        Aptabase.instance.trackEvent("footprint_highlighted")
        viewModelScope.launch {
            val updated = current.copy(isHighlight = isHighlight)
            db.footprintDao().update(updated)
            _footprint.value = updated
        }
    }

    fun updatePhotos(uris: List<String>) {
        val current = _footprint.value ?: return
        viewModelScope.launch {
            val updated = current.copy(photoAssetIDsJson = JSONArray(uris.distinct()).toString())
            db.footprintDao().update(updated)
            _footprint.value = updated
            Aptabase.instance.trackEvent("footprint_photos_edited")
        }
    }

    fun adjustTime(newStart: Date, newEnd: Date, onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        // A footprint is an observed event, never a future plan.  Keep the
        // persisted value safe even if an older UI or another caller supplies
        // a future time.
        val latestAllowedEnd = Date((System.currentTimeMillis() / 60_000L) * 60_000L)
        val requestedEnd = minOf(roundedToMinute(newEnd).time, latestAllowedEnd.time)
        val roundedStart = Date(
            minOf(roundedToMinute(newStart).time, requestedEnd - 60_000L)
        )
        val roundedEnd = Date(maxOf(requestedEnd, roundedStart.time + 60_000L))
        if (roundedStart == current.startTime && roundedEnd == current.endTime) return

        viewModelScope.launch {
            val updatedCoordinates = coordinatesJsonForRange(roundedStart, roundedEnd)
            val updated = current.copy(
                date = startOfDay(roundedStart),
                startTime = roundedStart,
                endTime = roundedEnd,
                latitudeJson = updatedCoordinates?.first ?: current.latitudeJson,
                longitudeJson = updatedCoordinates?.second ?: current.longitudeJson,
                locationHash = if (current.locationHash == "ONGOING_STAY" || current.locationHash.startsWith("GAP_STAY")) "MANUAL_STAY" else current.locationHash,
                statusValue = "manual",
                aiAnalyzed = true
            )

            db.transportRecordDao().getAdjacentEndingAt(
                current.startTime,
                Date(current.startTime.time - 30 * 60_000L),
                Date(current.startTime.time + 60_000L)
            )?.let { transport ->
                if (roundedStart.after(transport.startTime)) {
                    db.transportRecordDao().update(refreshTransportTiming(transport.copy(endTime = roundedStart)))
                }
            }

            db.transportRecordDao().getAdjacentStartingAt(
                current.endTime,
                Date(current.endTime.time - 60_000L),
                Date(current.endTime.time + 30 * 60_000L)
            )?.let { transport ->
                if (roundedEnd.before(transport.endTime)) {
                    db.transportRecordDao().update(refreshTransportTiming(transport.copy(startTime = roundedEnd, day = startOfDay(roundedEnd))))
                }
            }

            db.footprintDao().update(updated)
            _footprint.value = updated
            refreshAdjacentFootprints(updated)
            Aptabase.instance.trackEvent("footprint_time_adjusted")
            onSaved()
        }
    }

    fun splitFootprint(splitTime: Date, onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        if (current.endTime.time - current.startTime.time < 120_000L) return
        val split = roundedToMinute(Date(splitTime.time.coerceIn(current.startTime.time + 60_000L, current.endTime.time - 60_000L)))

        viewModelScope.launch {
            val firstRatio = (split.time - current.startTime.time).toDouble() /
                (current.endTime.time - current.startTime.time).toDouble()
            val firstSteps = current.stepCount?.let { (it * firstRatio).toInt() }
            val firstDistance = current.walkingDistance?.times(firstRatio)
            val firstFloors = current.floorsAscended?.let { (it * firstRatio).toInt() }
            val firstCoords = coordinatesJsonForRange(current.startTime, split)
                ?: fallbackCoordinatesByRatio(current, 0.0, (split.time - current.startTime.time).toDouble() / (current.endTime.time - current.startTime.time).toDouble())
            val secondCoords = coordinatesJsonForRange(split, current.endTime)
                ?: fallbackCoordinatesByRatio(current, (split.time - current.startTime.time).toDouble() / (current.endTime.time - current.startTime.time).toDouble(), 1.0)

            val first = current.copy(
                endTime = split,
                latitudeJson = firstCoords.first,
                longitudeJson = firstCoords.second,
                stepCount = firstSteps,
                walkingDistance = firstDistance,
                floorsAscended = firstFloors,
                statusValue = "manual",
                aiAnalyzed = true
            )
            val second = current.copy(
                footprintID = UUID.randomUUID().toString(),
                date = startOfDay(split),
                startTime = split,
                latitudeJson = secondCoords.first,
                longitudeJson = secondCoords.second,
                stepCount = current.stepCount?.minus(firstSteps ?: 0),
                walkingDistance = current.walkingDistance?.minus(firstDistance ?: 0.0),
                floorsAscended = current.floorsAscended?.minus(firstFloors ?: 0),
                isHighlight = false,
                statusValue = "manual",
                aiAnalyzed = true
            )
            db.footprintDao().update(first)
            db.footprintDao().insert(second)
            _footprint.value = first
            refreshAdjacentFootprints(first)
            Aptabase.instance.trackEvent("footprint_split")
            onSaved()
        }
    }

    fun mergeAdjacent(usePrevious: Boolean, onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        val other = (if (usePrevious) _previousFootprint.value else _nextFootprint.value) ?: return

        viewModelScope.launch {
            val first = if (current.startTime <= other.startTime) current else other
            val second = if (current.startTime <= other.startTime) other else current
            if (!canMerge(first, second)) return@launch

            val mergedLat = JSONArray()
            val mergedLon = JSONArray()
            appendCoordinates(mergedLat, mergedLon, first)
            appendCoordinates(mergedLat, mergedLon, second)

            val photos = (jsonStringArray(first.photoAssetIDsJson) + jsonStringArray(second.photoAssetIDsJson)).distinct()
            val merged = first.copy(
                startTime = minDate(first.startTime, second.startTime),
                endTime = maxDate(first.endTime, second.endTime),
                date = startOfDay(minDate(first.startTime, second.startTime)),
                latitudeJson = mergedLat.toString(),
                longitudeJson = mergedLon.toString(),
                reason = first.reason?.takeIf { it.isNotBlank() } ?: second.reason,
                address = first.address?.takeIf { it.isNotBlank() } ?: second.address,
                placeID = first.placeID ?: second.placeID,
                activityTypeValue = first.activityTypeValue ?: second.activityTypeValue,
                isHighlight = if (first.isHighlight == true) true else second.isHighlight,
                photoAssetIDsJson = JSONArray(photos).toString(),
                stepCount = nullableIntSum(first.stepCount, second.stepCount),
                walkingDistance = nullableDoubleSum(first.walkingDistance, second.walkingDistance),
                floorsAscended = nullableIntSum(first.floorsAscended, second.floorsAscended),
                statusValue = "manual",
                aiAnalyzed = true
            )

            db.footprintDao().update(merged)
            db.footprintDao().delete(second)
            _footprint.value = merged
            refreshAdjacentFootprints(merged)
            Aptabase.instance.trackEvent("footprint_adjacent_merged")
            onSaved()
        }
    }

    private fun nullableIntSum(first: Int?, second: Int?): Int? =
        if (first == null && second == null) null else (first ?: 0) + (second ?: 0)

    private fun nullableDoubleSum(first: Double?, second: Double?): Double? =
        if (first == null && second == null) null else (first ?: 0.0) + (second ?: 0.0)

    fun deleteFootprint() {
        Aptabase.instance.trackEvent("footprint_deleted")
        val current = _footprint.value ?: return
        viewModelScope.launch {
            // iOS deletes into the footprint recycle bin first; preserve the
            // record so the user can restore it from Data Manager.
            db.footprintDao().update(current.copy(statusValue = "ignored"))
            _footprint.value = null
        }
    }

    /** Mirrors iOS: create/update a 100 m ignored place and hide all nearby stays. */
    fun ignoreLocation(onSaved: () -> Unit = {}) {
        val current = _footprint.value ?: return
        val coordinate = representativeCoordinate(current) ?: return
        viewModelScope.launch {
            val existing = current.placeID?.let { db.placeDao().getById(it) }
            val ignoredPlace = existing?.copy(isIgnored = true) ?: PlaceEntity(
                name = current.address?.takeIf { it.isNotBlank() } ?: "已忽略地点",
                latitude = coordinate.first,
                longitude = coordinate.second,
                radius = 100f,
                address = current.address,
                isIgnored = true,
                isUserDefined = false
            )
            db.placeDao().insert(ignoredPlace)
            val threshold = ignoredPlace.radius + 100f
            db.footprintDao().getAll().forEach { footprint ->
                val other = representativeCoordinate(footprint) ?: return@forEach
                if (footprint.placeID == ignoredPlace.placeID || distanceMeters(coordinate, other) <= threshold) {
                    db.footprintDao().update(footprint.copy(statusValue = "ignored", placeID = ignoredPlace.placeID))
                }
            }
            _footprint.value = null
            Aptabase.instance.trackEvent("footprint_location_ignored")
            onSaved()
        }
    }

    private suspend fun refreshAdjacentFootprints(fp: FootprintEntity?) {
        if (fp == null) {
            _previousFootprint.value = null
            _nextFootprint.value = null
            return
        }
        _previousFootprint.value = db.footprintDao().getPreviousBefore(fp.footprintID, fp.startTime)
        _nextFootprint.value = db.footprintDao().getNextAfter(fp.footprintID, fp.endTime)
    }

    private suspend fun canMerge(first: FootprintEntity, second: FootprintEntity): Boolean {
        if (first.footprintID == second.footprintID) return false
        val lower = minDate(first.endTime, second.endTime)
        val upper = maxDate(first.startTime, second.startTime)
        if (!upper.after(lower)) return true
        return db.transportRecordDao().getActiveBetween(lower, upper).isEmpty()
    }

    private fun startOfDay(date: Date): Date = Calendar.getInstance().apply {
        time = date
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.time

    private fun roundedToMinute(date: Date): Date = Date(((date.time + 30_000L) / 60_000L) * 60_000L)

    private fun touchedDates(start: Date, end: Date): List<Date> {
        val result = mutableListOf<Date>()
        val cal = Calendar.getInstance().apply { time = startOfDay(start) }
        val endDay = startOfDay(Date(max(start.time, end.time - 1L)))
        while (!cal.time.after(endDay)) {
            result += cal.time
            cal.add(Calendar.DATE, 1)
        }
        return result
    }

    private fun coordinatesJsonForRange(start: Date, end: Date): Pair<String, String>? {
        val points = touchedDates(start, end)
            .flatMap { rawStore.loadLocations(it) }
            .filter { it.timestamp >= start && it.timestamp <= end }
            .sortedBy { it.timestamp }
        if (points.isEmpty()) return null
        val lats = JSONArray()
        val lons = JSONArray()
        points.forEach {
            lats.put(it.latitude)
            lons.put(it.longitude)
        }
        return lats.toString() to lons.toString()
    }

    private fun fallbackCoordinatesByRatio(fp: FootprintEntity, startRatio: Double, endRatio: Double): Pair<String, String> {
        val lats = JSONArray(fp.latitudeJson)
        val lons = JSONArray(fp.longitudeJson)
        val count = min(lats.length(), lons.length())
        if (count == 0) return "[]" to "[]"
        val start = (count * startRatio).toInt().coerceIn(0, count - 1)
        val endExclusive = max(start + 1, (count * endRatio).toInt().coerceIn(1, count))
        val outLat = JSONArray()
        val outLon = JSONArray()
        for (i in start until endExclusive) {
            outLat.put(lats.getDouble(i))
            outLon.put(lons.getDouble(i))
        }
        return outLat.toString() to outLon.toString()
    }

    private fun appendCoordinates(latsOut: JSONArray, lonsOut: JSONArray, fp: FootprintEntity) {
        val lats = JSONArray(fp.latitudeJson)
        val lons = JSONArray(fp.longitudeJson)
        for (i in 0 until min(lats.length(), lons.length())) {
            latsOut.put(lats.getDouble(i))
            lonsOut.put(lons.getDouble(i))
        }
    }

    private fun representativeCoordinate(fp: FootprintEntity): Pair<Double, Double>? = runCatching {
        val lats = JSONArray(fp.latitudeJson)
        val lons = JSONArray(fp.longitudeJson)
        val count = min(lats.length(), lons.length())
        if (count == 0) return@runCatching null
        val latitudes = (0 until count).map { lats.getDouble(it) }.filter(Double::isFinite)
        val longitudes = (0 until count).map { lons.getDouble(it) }.filter(Double::isFinite)
        if (latitudes.isEmpty() || longitudes.isEmpty()) null else latitudes.average() to longitudes.average()
    }.getOrNull()

    private fun distanceMeters(first: Pair<Double, Double>, second: Pair<Double, Double>): Float {
        val result = FloatArray(1)
        android.location.Location.distanceBetween(first.first, first.second, second.first, second.second, result)
        return result[0]
    }

    private fun jsonStringArray(json: String): List<String> = runCatching {
        val array = JSONArray(json)
        (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
    }.getOrDefault(emptyList())

    private fun refreshTransportTiming(record: com.ct106.difangke.data.db.entity.TransportRecordEntity): com.ct106.difangke.data.db.entity.TransportRecordEntity {
        val duration = max(1.0, (record.endTime.time - record.startTime.time) / 1000.0)
        return record.copy(
            day = startOfDay(record.startTime),
            averageSpeed = record.distance / duration,
            statusRaw = if (record.endTime.after(record.startTime)) record.statusRaw else "ignored"
        )
    }

    private fun minDate(a: Date, b: Date): Date = if (a <= b) a else b
    private fun maxDate(a: Date, b: Date): Date = if (a >= b) a else b
}
