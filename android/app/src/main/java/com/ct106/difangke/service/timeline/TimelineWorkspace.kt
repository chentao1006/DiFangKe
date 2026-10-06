package com.ct106.difangke.service.timeline

import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.location.RawLocationStore.RawPoint
import com.google.gson.JsonArray
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import java.util.Calendar
import java.util.Date
import java.util.UUID

/**
 * Mutable working copy of a footprint, mirroring the in-place mutation style of
 * the iOS SwiftData models so the iOS algorithms can be ported line by line.
 * Converted back to [FootprintEntity] (preserving unknown fields of [original]).
 */
class WFootprint(
    val id: String,
    var date: Date,
    var startTime: Date,
    var endTime: Date,
    var lats: MutableList<Double>,
    var lons: MutableList<Double>,
    var locationHash: String,
    var reason: String?,
    var status: String,
    var placeID: String?,
    var address: String?,
    var isHighlight: Boolean?,
    var aiAnalyzed: Boolean,
    var activityTypeValue: String?,
    var photos: MutableList<String>,
    var stepCount: Int?,
    var walkingDistance: Double?,
    var floorsAscended: Int?,
    var allowsAutomaticDurationExtension: Boolean,
    var isAddressEditedByHand: Boolean,
    val original: FootprintEntity?
) {
    val isManual get() = status == "manual"
    val isIgnored get() = status == "ignored"
    /** iOS `Footprint.latitude`: mean of stored latitudes (0 when empty). */
    val latitude get() = if (lats.isEmpty()) 0.0 else lats.sum() / lats.size
    val longitude get() = if (lons.isEmpty()) 0.0 else lons.sum() / lons.size
    val hasLocations get() = lats.isNotEmpty() && lons.isNotEmpty()
    val durationSec get() = maxOf(0.0, secs(startTime, endTime))

    /** iOS `isUserModifiedForDailySummary`. */
    val isUserModified: Boolean get() =
        status == "manual" || status == "confirmed" || isAddressEditedByHand || isHighlight == true ||
            photos.isNotEmpty() || !reason.isNullOrBlank()

    fun appendLocations(otherLats: List<Double>, otherLons: List<Double>) {
        lats = (lats + otherLats).toMutableList()
        lons = (lons + otherLons).toMutableList()
    }

    fun mergePhotos(other: List<String>) {
        for (p in other) if (!photos.contains(p)) photos.add(p)
    }

    fun toEntity(): FootprintEntity = (original ?: FootprintEntity(footprintID = id, title = "")).copy(
        footprintID = id,
        date = date,
        startTime = startTime,
        endTime = endTime,
        latitudeJson = doublesToJson(lats),
        longitudeJson = doublesToJson(lons),
        locationHash = locationHash,
        reason = reason,
        statusValue = status,
        placeID = placeID,
        address = address,
        isHighlight = isHighlight,
        aiAnalyzed = aiAnalyzed,
        activityTypeValue = activityTypeValue,
        photoAssetIDsJson = stringsToJson(photos),
        stepCount = stepCount,
        walkingDistance = walkingDistance,
        floorsAscended = floorsAscended,
        allowsAutomaticDurationExtension = allowsAutomaticDurationExtension,
        isAddressEditedByHand = isAddressEditedByHand
    )

    companion object {
        fun from(e: FootprintEntity) = WFootprint(
            id = e.footprintID, date = e.date, startTime = e.startTime, endTime = e.endTime,
            lats = jsonToDoubles(e.latitudeJson), lons = jsonToDoubles(e.longitudeJson),
            locationHash = e.locationHash, reason = e.reason, status = e.statusValue,
            placeID = e.placeID, address = e.address, isHighlight = e.isHighlight,
            aiAnalyzed = e.aiAnalyzed, activityTypeValue = e.activityTypeValue,
            photos = jsonToStrings(e.photoAssetIDsJson), stepCount = e.stepCount,
            walkingDistance = e.walkingDistance, floorsAscended = e.floorsAscended,
            allowsAutomaticDurationExtension = e.allowsAutomaticDurationExtension,
            isAddressEditedByHand = e.isAddressEditedByHand, original = e
        )

        fun create(
            date: Date, startTime: Date, endTime: Date,
            coords: List<Pair<Double, Double>>, locationHash: String,
            status: String = "confirmed"
        ) = WFootprint(
            id = UUID.randomUUID().toString(), date = date, startTime = startTime, endTime = endTime,
            lats = coords.map { it.first }.toMutableList(), lons = coords.map { it.second }.toMutableList(),
            locationHash = locationHash, reason = null, status = status, placeID = null, address = null,
            isHighlight = null, aiAnalyzed = false, activityTypeValue = null, photos = mutableListOf(),
            stepCount = null, walkingDistance = null, floorsAscended = null,
            allowsAutomaticDurationExtension = false, isAddressEditedByHand = false, original = null
        )
    }
}

/** Mutable working copy of a transport record (iOS `TransportRecord`). */
class WTransport(
    val id: String,
    var day: Date,
    var startTime: Date,
    var endTime: Date,
    var startLocation: String,
    var endLocation: String,
    var typeRaw: String,
    var distance: Double,
    var averageSpeed: Double,
    var pointsJson: String,
    var manualTypeRaw: String?,
    var statusRaw: String,
    var stepCount: Int?,
    val original: TransportRecordEntity?
) {
    val isManual get() = manualTypeRaw != null
    val points: List<RouteCoordinate> get() = RouteCodec.decode(pointsJson)
    val pointsOrNull: List<RouteCoordinate>? get() = RouteCodec.decodeOrNull(pointsJson)
    fun setPoints(points: List<RouteCoordinate>) { pointsJson = RouteCodec.encode(points) }

    fun toEntity(): TransportRecordEntity = (original ?: TransportRecordEntity(recordID = id)).copy(
        recordID = id, day = day, startTime = startTime, endTime = endTime,
        startLocation = startLocation, endLocation = endLocation, typeRaw = typeRaw,
        distance = distance, averageSpeed = averageSpeed, pointsJson = pointsJson,
        manualTypeRaw = manualTypeRaw, statusRaw = statusRaw, stepCount = stepCount
    )

    companion object {
        fun from(e: TransportRecordEntity) = WTransport(
            e.recordID, e.day, e.startTime, e.endTime, e.startLocation, e.endLocation, e.typeRaw,
            e.distance, e.averageSpeed, e.pointsJson, e.manualTypeRaw, e.statusRaw, e.stepCount, e
        )

        fun create(
            day: Date, startTime: Date, endTime: Date, startLocation: String, endLocation: String,
            typeRaw: String, distance: Double, averageSpeed: Double, points: List<RouteCoordinate>,
            stepCount: Int? = null
        ) = WTransport(
            UUID.randomUUID().toString(), day, startTime, endTime, startLocation, endLocation, typeRaw,
            distance, averageSpeed, RouteCodec.encode(points), null, "active", stepCount, null
        )
    }
}

/** Optional Health metrics (Android has no Health Connect yet: null means "unknown"). */
data class HealthMetrics(val steps: Int? = null, val walkingDistance: Double? = null, val floors: Int? = null)

/** Optional sensor/health hooks for classification. Defaults degrade to speed-only. */
interface TimelineSensors {
    fun metrics(start: Date, end: Date): HealthMetrics = HealthMetrics()
    /** Android DetectedActivity code, see TransportType.Motion. */
    fun motion(start: Date, end: Date): Int = com.ct106.difangke.data.model.TransportType.Motion.UNKNOWN

    object None : TimelineSensors
}

/** Live state from the tracking service (iOS LocationManager.potentialStopStartLocation etc). */
data class LiveStayContext(
    val anchor: RawPoint,
    val current: RawPoint?,
    val isHoldingStationaryStay: Boolean,
    val uiIsMoving: Boolean
)

/** All records the engine may read/modify for one day. */
class TimelineWorkspace(
    val dayStart: Date,
    footprints: List<WFootprint>,
    val ignoredFootprints: List<WFootprint>,
    transports: List<WTransport>,
    /** Raw deleted-transport overrides (un-widened) near the day. */
    val deletedSelections: List<Pair<Date, Date>>,
    val places: List<PlaceEntity>,
    /** Activity history (startTime, activity) by placeID for records outside the workspace. */
    private val externalActivityHistory: Map<String, List<ActivityHabits.HistoryEntry>> = emptyMap()
) {
    val footprints: MutableList<WFootprint> = footprints.toMutableList()
    val transports: MutableList<WTransport> = transports.toMutableList()
    val deletedFootprintIDs = mutableSetOf<String>()
    val deletedTransportIDs = mutableSetOf<String>()

    val dayEnd: Date = addDays(dayStart, 1)

    fun deleteFootprint(fp: WFootprint) {
        if (footprints.remove(fp)) deletedFootprintIDs.add(fp.id)
    }

    fun deleteTransport(tp: WTransport) {
        if (transports.remove(tp)) deletedTransportIDs.add(tp.id)
    }

    fun insertFootprint(fp: WFootprint) { footprints.add(fp); deletedFootprintIDs.remove(fp.id) }
    fun insertTransport(tp: WTransport) { transports.add(tp); deletedTransportIDs.remove(tp.id) }

    /** iOS fetch: startTime < endOfDay && endTime > startOfDay && status != ignored, sorted by start. */
    fun dayFootprints(): List<WFootprint> =
        footprints.filter { it.startTime < dayEnd && it.endTime > dayStart && !it.isIgnored }.sortedBy { it.startTime }

    fun dayTransports(): List<WTransport> =
        transports.filter { it.startTime < dayEnd && it.endTime > dayStart && it.statusRaw != "ignored" }
            .sortedBy { it.startTime }

    /** External entries must exclude workspace records (the builder loads them that way). */
    fun activityHistory(placeID: String): List<ActivityHabits.HistoryEntry> =
        externalActivityHistory[placeID].orEmpty() +
            footprints.filter { it.placeID == placeID && it.activityTypeValue != null }
                .map { ActivityHabits.HistoryEntry(it.startTime, it.activityTypeValue!!) }
}

// ── shared helpers ──

fun secs(from: Date, to: Date): Double = (to.time - from.time) / 1000.0
fun Date.plusSeconds(seconds: Double): Date = Date(time + Math.round(seconds * 1000))
fun maxDate(a: Date, b: Date) = if (a >= b) a else b
fun minDate(a: Date, b: Date) = if (a <= b) a else b

fun startOfDay(date: Date): Date = Calendar.getInstance().apply {
    time = date
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.time

fun addDays(date: Date, days: Int): Date = Calendar.getInstance().apply { time = date; add(Calendar.DAY_OF_YEAR, days) }.time

fun isSameDay(a: Date, b: Date) = startOfDay(a) == startOfDay(b)

fun RawPoint.distanceTo(other: RawPoint) = GeoMath.distance(latitude, longitude, other.latitude, other.longitude)
fun RawPoint.distanceTo(lat: Double, lon: Double) = GeoMath.distance(latitude, longitude, lat, lon)
val RawPoint.latLon get() = latitude to longitude

fun jsonToDoubles(json: String?): MutableList<Double> = try {
    val root = JsonParser.parseString(json ?: "[]")
    if (root.isJsonArray) root.asJsonArray.mapNotNull { runCatching { it.asDouble }.getOrNull() }.toMutableList()
    else mutableListOf()
} catch (_: Exception) { mutableListOf() }

fun jsonToStrings(json: String?): MutableList<String> = try {
    val root = JsonParser.parseString(json ?: "[]")
    if (root.isJsonArray) root.asJsonArray.mapNotNull { runCatching { it.asString }.getOrNull() }.toMutableList()
    else mutableListOf()
} catch (_: Exception) { mutableListOf() }

fun doublesToJson(values: List<Double>): String = JsonArray().apply { values.forEach { add(JsonPrimitive(it)) } }.toString()
fun stringsToJson(values: List<String>): String = JsonArray().apply { values.forEach { add(JsonPrimitive(it)) } }.toString()
