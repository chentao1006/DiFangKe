package com.ct106.difangke.ui.screens.statistics

import android.app.Application
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.FootprintStatus
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.GeocodeService
import com.ct106.difangke.ui.screens.detail.photoTakenDate
import com.ct106.difangke.ui.screens.main.parseRouteSegments
import com.ct106.difangke.ui.share.GeoPoint
import com.ct106.difangke.ui.share.photoUris
import com.ct106.difangke.ui.share.shareCenter
import com.ct106.difangke.ui.theme.DfkAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** iOS StatisticsRange. */
sealed class StatisticsRange(val label: String, val days: Int?) {
    object LAST_7_DAYS : StatisticsRange("7天", 7)
    object LAST_30_DAYS : StatisticsRange("30天", 30)
    object LAST_90_DAYS : StatisticsRange("90天", 90)
    object LAST_YEAR : StatisticsRange("1年", 365)
    data class CUSTOM_YEAR(val year: Int) : StatisticsRange("$year", null)

    /** iOS statisticsRangeText. */
    val rangeText: String get() = when (this) {
        LAST_7_DAYS -> "最近7天"
        LAST_30_DAYS -> "最近30天"
        LAST_90_DAYS -> "最近90天"
        LAST_YEAR -> "过去一年"
        is CUSTOM_YEAR -> "${year}年"
    }

    /** iOS reviewMapRevision range code. */
    val code: Int get() = (this as? CUSTOM_YEAR)?.year ?: days ?: 0
}

enum class FrequentPlaceRankScope(val label: String) { COUNTRY("国家"), CITY("城市"), PLACE("地点") }

/** iOS ReviewBentoDetail. */
enum class ReviewBentoDetail(val title: String) {
    ACTIVITY("时间花在哪"),
    RHYTHM("出行节奏"),
    TRANSPORT("最常用交通"),
    REGIONS("最常停留的区域")
}

/** iOS ReviewMemoryCandidate. `icon` is an SF Symbol name resolved by the screen. */
data class ReviewMemory(
    val id: String,
    val date: Date,
    val footprint: FootprintEntity?,
    val title: String,
    val evidence: String,
    val reason: String,
    val icon: String,
    val photoUris: List<String>,
    val score: Double
) {
    val isFavorite: Boolean get() = id.startsWith("favorite-")
    val isPastMemory: Boolean get() = id.startsWith("past-memory-")
}

/** iOS ReviewPlaceSelection. */
data class ReviewPlaceSelection(
    val id: String,
    val title: String,
    val rangeText: String,
    val visits: List<FootprintEntity>,
    val photoUris: List<String>
)

/** iOS ReviewPlaceListSelection / ReviewMapPlaceCluster. */
data class ReviewPlaceListSelection(
    val id: String,
    val title: String,
    val places: List<ReviewPlaceSelection>
)

data class ReviewActivitySlice(val id: String, val name: String, val duration: Double, val color: Color, val icon: String)
data class ReviewTransportSlice(val id: String, val name: String, val count: Int, val distance: Double, val color: Color, val icon: String)
data class ReviewDailyDistance(val date: Date, val distance: Double)
data class ReviewDailyCount(val date: Date, val count: Int)

data class ReviewMileageMetrics(
    val dailyValues: List<ReviewDailyDistance>,
    val total: Double,
    val dailyAverage: Double,
    val peakDay: ReviewDailyDistance?,
    val activeDayCount: Int,
    val weekdayAverages: List<Double>
)

data class FrequentPlaceItem(
    val id: String,
    val name: String,
    val address: String,
    val count: Int,
    val duration: Double,
    val footprintIDs: List<String>
)

data class ReviewGeographyMetric(val icon: String, val value: String, val label: String)
data class ReviewRegion(val name: String, val duration: Double)

// iOS Color.blue/green/orange/purple (light appearance).
private val transportSliceColors = listOf(DfkAccent, Color(0xFF007AFF), Color(0xFF34C759), Color(0xFFFF9500), Color(0xFFAF52DE))

private val monthDayFormatter = ThreadLocal.withInitial { SimpleDateFormat("M月d日", Locale.SIMPLIFIED_CHINESE) }

/** iOS `.dateTime.month().day()` in zh_Hans. */
fun reviewMonthDay(date: Date): String = monthDayFormatter.get()!!.format(date)

/** iOS formatRankDuration. */
fun formatRankDuration(duration: Double): String {
    val totalMinutes = (duration / 60).toInt()
    if (totalMinutes < 60) return "${totalMinutes}分钟"
    val totalHours = totalMinutes / 60
    if (totalHours >= 24) {
        val days = totalHours / 24
        if (duration > 3 * 24 * 60 * 60) return "${days}天"
        return "${days}天${totalHours % 24}小时"
    }
    val hours = totalMinutes / 60.0
    if (hours < 10) return String.format(Locale.US, "%.1f小时", hours)
    return "${hours.toInt()}小时"
}

/** iOS formatRankMileage. */
fun formatRankMileage(distance: Double): String {
    if (distance < 1_000) return "${distance.roundToLong()}米"
    return String.format(Locale.US, "%.1f公里", distance / 1_000)
}

/** iOS reviewRhythmCompactNumber. */
fun reviewCompactNumber(value: Double): String {
    if (abs(value.roundToLong() - value) < 0.05) return value.roundToLong().toString()
    return String.format(Locale.US, "%.1f", value)
}

/** iOS mondayFirstIndex: (weekday + 5) % 7 with Calendar.SUNDAY == 1. */
internal fun mondayFirstIndex(date: Date): Int = Calendar.getInstance().run {
    time = date
    (get(Calendar.DAY_OF_WEEK) + 5) % 7
}

internal fun hourOf(date: Date): Int = Calendar.getInstance().run { time = date; get(Calendar.HOUR_OF_DAY) }

internal fun startOfDay(date: Date): Date = Calendar.getInstance().run {
    time = date
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    time
}

private fun addDays(date: Date, days: Int): Date = Calendar.getInstance().run { time = date; add(Calendar.DAY_OF_YEAR, days); time }

private fun yearOf(date: Date): Int = Calendar.getInstance().run { time = date; get(Calendar.YEAR) }

private fun flagEmoji(countryCode: String): String = countryCode.uppercase().map { char ->
    String(Character.toChars(127397 + char.code))
}.joinToString("")

/**
 * Every value the iOS review page derives from the source arrays for one
 * applied range. Built off the main thread; detail-only values are lazy.
 */
class ReviewSnapshot(
    val range: StatisticsRange,
    val now: Date,
    val allFootprints: List<FootprintEntity>,
    val footprints: List<FootprintEntity>,
    val transports: List<TransportRecordEntity>,
    val activityTypes: List<ActivityTypeEntity>,
    val places: List<PlaceEntity>
) {
    val rangeText: String = range.rangeText
    val placesById: Map<String, PlaceEntity> = places.associateBy { it.placeID }
    private val centers: Map<String, GeoPoint?> = allFootprints.associate { it.footprintID to it.shareCenter() }
    private val placeKeys: Map<String, String> = allFootprints.associate {
        it.footprintID to reviewIntegratedPlaceKey(it, placesById)
    }

    fun latitude(footprint: FootprintEntity): Double = centers[footprint.footprintID]?.lat ?: footprint.shareCenter()?.lat ?: 0.0
    fun longitude(footprint: FootprintEntity): Double = centers[footprint.footprintID]?.lon ?: footprint.shareCenter()?.lon ?: 0.0

    fun placeKey(footprint: FootprintEntity): String =
        placeKeys[footprint.footprintID] ?: reviewIntegratedPlaceKey(footprint, placesById)

    /** iOS reviewPlaceName. */
    fun placeName(footprint: FootprintEntity): String {
        footprint.placeID?.let(placesById::get)?.name?.takeIf { it.isNotEmpty() }?.let { return it }
        val address = footprint.address?.trim().orEmpty()
        return address.ifEmpty { "这个地方" }
    }

    fun activityOf(footprint: FootprintEntity): ActivityTypeEntity? {
        val value = footprint.activityTypeValue?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return activityTypes.firstOrNull { it.id == value || it.name == value }
    }

    fun transportType(record: TransportRecordEntity): TransportType =
        record.manualTypeRaw?.let { raw -> TransportType.entries.firstOrNull { it.raw == raw } }
            ?: TransportType.entries.firstOrNull { it.raw == record.typeRaw }
            ?: TransportType.SLOW

    // ── Hero ──────────────────────────────────────────────────────

    val totalDistance: Double = transports.sumOf { it.distance }
    val distanceText: String = formatRankMileage(totalDistance)

    /** iOS getTopLocations(delta: 0.01).count: ~110 m cells, capped at 200. */
    private val placeCount: Int = min(200, footprints.map { footprint ->
        val factor = 1_000.0
        "${(latitude(footprint) * factor).roundToLong() / factor},${(longitude(footprint) * factor).roundToLong() / factor}"
    }.toSet().size)

    val geographyMetric: ReviewGeographyMetric = run {
        val countries = footprints.mapNotNull { it.countryCode?.trim()?.takeIf(String::isNotEmpty)?.uppercase() }.toSet()
        if (countries.size > 1) return@run ReviewGeographyMetric("globe.asia.australia.fill", "${countries.size}", "个国家")
        val cities = footprints.mapNotNull { footprint ->
            val city = footprint.cityName?.trim().orEmpty()
            if (city.isEmpty()) null else "${footprint.countryCode?.uppercase().orEmpty()}|$city"
        }.toSet()
        if (cities.size > 1) return@run ReviewGeographyMetric("building.2.fill", "${cities.size}", "座城市")
        ReviewGeographyMetric("mappin.and.ellipse", "$placeCount", "个地点")
    }

    /** iOS reviewMapRevision. */
    val revision: Int = run {
        val latestFootprint = footprints.maxOfOrNull { it.endTime.time / 1000 } ?: 0L
        val latestTransport = transports.maxOfOrNull { it.endTime.time / 1000 } ?: 0L
        val dataRevision = range.code * 1_000_003 + footprints.size * 10_007 + transports.size * 101 +
            maxOf(latestFootprint, latestTransport).toInt()
        dataRevision * 31 + 6
    }

    // ── Activity ──────────────────────────────────────────────────

    private val recognizedByName: Map<String, List<FootprintEntity>> =
        footprints.mapNotNull { footprint -> activityOf(footprint)?.let { it.name to footprint } }
            .groupBy({ it.first }, { it.second })

    val recognizedFootprintCount: Int = recognizedByName.values.sumOf { it.size }

    val activitySlices: List<ReviewActivitySlice> = recognizedByName.mapNotNull { (name, visits) ->
        val activity = activityTypes.firstOrNull { it.name == name } ?: return@mapNotNull null
        ReviewActivitySlice(
            id = name,
            name = name,
            duration = visits.sumOf { it.duration }.toDouble(),
            color = parseColor(activity.colorHex),
            icon = activity.icon
        )
    }.sortedByDescending { it.duration }

    fun activityVisitCount(name: String): Int = recognizedByName[name]?.size ?: 0

    fun activityWeekdayCounts(name: String): List<Int> = IntArray(7).also { values ->
        recognizedByName[name]?.forEach { values[mondayFirstIndex(it.startTime)] += 1 }
    }.toList()

    fun activityHourlyCounts(name: String): List<Int> = IntArray(24).also { values ->
        recognizedByName[name]?.forEach { values[hourOf(it.startTime)] += 1 }
    }.toList()

    // ── Transport ─────────────────────────────────────────────────

    private val transportsByType: Map<TransportType, List<TransportRecordEntity>> = transports.groupBy(::transportType)

    val transportSlices: List<ReviewTransportSlice> = transportsByType.map { (type, records) ->
        ReviewTransportSlice(
            id = type.raw,
            name = type.localizedName,
            count = records.size,
            distance = records.sumOf { it.distance },
            color = transportSliceColors[TransportType.entries.indexOf(type) % transportSliceColors.size],
            icon = type.icon
        )
    }.sortedWith(compareByDescending<ReviewTransportSlice> { it.count }.thenByDescending { it.distance })

    private fun transportsOf(typeID: String): List<TransportRecordEntity> =
        transportsByType.entries.firstOrNull { it.key.raw == typeID }?.value.orEmpty()

    fun transportActiveDays(typeID: String): Int = transportsOf(typeID).map { startOfDay(it.startTime) }.toSet().size

    fun transportWeekdayCounts(typeID: String): List<Int> = IntArray(7).also { values ->
        transportsOf(typeID).forEach { values[mondayFirstIndex(it.startTime)] += 1 }
    }.toList()

    fun transportHourlyCounts(typeID: String): List<Int> = IntArray(24).also { values ->
        transportsOf(typeID).forEach { values[hourOf(it.startTime)] += 1 }
    }.toList()

    // ── Regions ───────────────────────────────────────────────────

    /** iOS reviewTopRegions. */
    val topRegions: List<ReviewRegion> = footprints.groupBy { footprint ->
        footprint.cityName?.trim()?.takeIf(String::isNotEmpty) ?: placeName(footprint)
    }.map { (name, visits) -> ReviewRegion(name, visits.sumOf { it.duration }.toDouble()) }
        .sortedByDescending { it.duration }

    private val frequentPlacesCache = HashMap<FrequentPlaceRankScope, List<FrequentPlaceItem>>()

    /** iOS getFrequentPlacesData(for:). */
    fun frequentPlaces(scope: FrequentPlaceRankScope): List<FrequentPlaceItem> = synchronized(frequentPlacesCache) {
        frequentPlacesCache.getOrPut(scope) { computeFrequentPlaces(scope) }
    }

    private fun computeFrequentPlaces(scope: FrequentPlaceRankScope): List<FrequentPlaceItem> {
        class Group(val name: String, val address: String, var count: Int, var duration: Double, val footprintIDs: MutableList<String>)

        val groups = LinkedHashMap<String, Group>()
        val hasMultipleCountries = footprints.mapNotNull { it.countryCode?.trim()?.takeIf(String::isNotEmpty) }.toSet().size > 1
        footprints.forEach { footprint ->
            var address = ""
            var placeName = ""
            val place = footprint.placeID?.let(placesById::get)
            if (place != null) {
                placeName = place.name
                address = place.address ?: footprint.address ?: ""
            } else if (!footprint.address.isNullOrEmpty()) {
                val addr = footprint.address
                val parts = addr.substringAfterLast("市").substringAfterLast("区").substringAfterLast("县")
                placeName = parts.substringBefore(" ")
                address = addr
            }
            val name = when (scope) {
                FrequentPlaceRankScope.PLACE -> placeName
                FrequentPlaceRankScope.COUNTRY -> {
                    val countryName = footprint.countryName
                    val countryCode = footprint.countryCode
                    if (countryName == null || countryCode == null) null
                    else "${flagEmoji(countryCode)} ${GeocodeService.simplifiedChinese(countryName)}"
                }
                FrequentPlaceRankScope.CITY -> footprint.cityName?.let { GeocodeService.simplifiedChinese(it) }
            } ?: return@forEach
            if (name.isEmpty() || name.contains("未知") || (scope == FrequentPlaceRankScope.PLACE && address.isEmpty())) return@forEach

            val subtitle: String
            val key: String
            when (scope) {
                FrequentPlaceRankScope.COUNTRY -> {
                    subtitle = ""
                    key = footprint.countryCode ?: name
                }
                FrequentPlaceRankScope.CITY -> {
                    subtitle = if (hasMultipleCountries) GeocodeService.simplifiedChinese(footprint.countryName ?: "") else ""
                    key = "${footprint.countryCode ?: ""}|$name"
                }
                FrequentPlaceRankScope.PLACE -> {
                    subtitle = address
                    key = placeKey(footprint)
                }
            }
            val existing = groups[key]
            if (existing != null) {
                existing.count += 1
                existing.duration += footprint.duration
                existing.footprintIDs += footprint.footprintID
            } else {
                groups[key] = Group(name, subtitle, 1, footprint.duration.toDouble(), mutableListOf(footprint.footprintID))
            }
        }
        return groups.filter { (_, value) -> scope != FrequentPlaceRankScope.PLACE || value.duration >= 3600 }
            .map { (key, value) -> FrequentPlaceItem(key, value.name, value.address, value.count, value.duration, value.footprintIDs) }
            .sortedByDescending { it.duration }
    }

    // ── Place selections ──────────────────────────────────────────

    /** iOS reviewPlaceSelection(id:visits:photoAssetIDs:). */
    fun placeSelection(id: String, visits: List<FootprintEntity>, photoUris: List<String>? = null): ReviewPlaceSelection? {
        val ordered = visits.sortedByDescending { it.startTime }
        val representative = ordered.firstOrNull() ?: return null
        return ReviewPlaceSelection(
            id = id,
            title = placeName(representative),
            rangeText = rangeText,
            visits = ordered,
            photoUris = photoUris ?: ordered.flatMap { it.photoUris() }.distinct()
        )
    }

    /** iOS reviewPlaceSelection(for candidate:). */
    fun placeSelection(memory: ReviewMemory): ReviewPlaceSelection? {
        val footprint = memory.footprint ?: return null
        val key = placeKey(footprint)
        return placeSelection(key, footprints.filter { placeKey(it) == key }, memory.photoUris)
    }

    /** iOS openReviewRegionItem: places of a ranking row, longest total stay first. */
    fun placeSelections(footprintIDs: Collection<String>): List<ReviewPlaceSelection> {
        val ids = footprintIDs.toSet()
        return footprints.filter { it.footprintID in ids }
            .groupBy(::placeKey)
            .mapNotNull { (key, visits) -> placeSelection(key, visits) }
            .sortedByDescending { place -> place.visits.sumOf { it.duration } }
    }

    /** iOS FullReviewMapView.placeSelection: titled place → address → city. */
    fun mapPlaceSelection(id: String, visits: List<FootprintEntity>): ReviewPlaceSelection? {
        val ordered = visits.sortedByDescending { it.startTime }
        val representative = ordered.firstOrNull() ?: return null
        val title = listOfNotNull(
            representative.placeID?.let(placesById::get)?.name?.trim(),
            representative.address?.trim(),
            representative.cityName?.trim()
        ).firstOrNull { it.isNotEmpty() } ?: "地点"
        return ReviewPlaceSelection(id, title, rangeText, ordered, ordered.flatMap { it.photoUris() }.distinct())
    }

    /** iOS FullReviewMapView.placeSelections(from:). */
    fun mapPlaceSelections(visits: List<FootprintEntity>): List<ReviewPlaceSelection> =
        visits.groupBy(::placeKey)
            .mapNotNull { (key, group) -> mapPlaceSelection(key, group) }
            .sortedByDescending { place -> place.visits.sumOf { it.duration } }

    // ── Rhythm ────────────────────────────────────────────────────

    val rangeStart: Date = when (range) {
        is StatisticsRange.CUSTOM_YEAR -> Calendar.getInstance().run { clear(); set(range.year, Calendar.JANUARY, 1); time }
        else -> addDays(now, -(range.days ?: 0))
    }

    val rangeEnd: Date = when (range) {
        is StatisticsRange.CUSTOM_YEAR -> Calendar.getInstance().run { clear(); set(range.year, Calendar.DECEMBER, 31); time }
        else -> now
    }

    val rhythmAxisStartText: String get() = reviewMonthDay(rangeStart)
    val rhythmAxisEndText: String get() = reviewMonthDay(rangeEnd)

    /** iOS reviewActivityBuckets: footprint starts in 24 equal slices of the range. */
    val activityBuckets: List<Int> = IntArray(24).also { buckets ->
        val duration = maxOf(1L, rangeEnd.time - rangeStart.time).toDouble()
        footprints.forEach { footprint ->
            val progress = (footprint.startTime.time - rangeStart.time) / duration
            buckets[(progress * 24).toInt().coerceIn(0, 23)] += 1
        }
    }.toList()

    /** iOS reviewRhythmDailyCounts. */
    val dailyCounts: List<ReviewDailyCount> = run {
        val endDate = startOfDay(if (rangeEnd.before(now)) rangeEnd else now)
        val dayCount = range.days ?: run {
            val start = startOfDay(rangeStart)
            maxOf(1, daysBetween(start, endDate) + 1)
        }
        val firstDate = addDays(endDate, -(dayCount - 1))
        val countsByDate = footprints.groupingBy { startOfDay(it.startTime) }.eachCount()
        (0 until dayCount).map { offset ->
            val date = addDays(firstDate, offset)
            ReviewDailyCount(date, countsByDate[date] ?: 0)
        }
    }

    /** iOS reviewMileageMetrics. */
    val mileage: ReviewMileageMetrics = run {
        val distanceByDate = transports.groupBy { startOfDay(it.startTime) }.mapValues { (_, records) -> records.sumOf { it.distance } }
        val dailyValues = dailyCounts.map { ReviewDailyDistance(it.date, distanceByDate[it.date] ?: 0.0) }
        val total = dailyValues.sumOf { it.distance }
        val totals = DoubleArray(7)
        val occurrences = IntArray(7)
        dailyValues.forEach { item ->
            val index = mondayFirstIndex(item.date)
            totals[index] += item.distance
            occurrences[index] += 1
        }
        ReviewMileageMetrics(
            dailyValues = dailyValues,
            total = total,
            dailyAverage = if (dailyValues.isEmpty()) 0.0 else total / dailyValues.size,
            peakDay = dailyValues.maxByOrNull { it.distance },
            activeDayCount = dailyValues.count { it.distance > 0 },
            weekdayAverages = totals.indices.map { totals[it] / maxOf(1, occurrences[it]) }
        )
    }

    val rhythmActiveDayCount: Int get() = dailyCounts.count { it.count > 0 }

    val rhythmActiveDayRate: Int get() =
        (rhythmActiveDayCount.toDouble() / maxOf(1, dailyCounts.size) * 100).roundToInt()

    val rhythmWeeklyAverageText: String get() {
        val total = dailyCounts.sumOf { it.count }
        return "${reviewCompactNumber(total * 7.0 / maxOf(1, dailyCounts.size))}次"
    }

    val rhythmActiveDayAverageText: String get() {
        val total = dailyCounts.sumOf { it.count }
        return "${reviewCompactNumber(total.toDouble() / maxOf(1, rhythmActiveDayCount))}次"
    }

    val rhythmPeakCount: Int get() = dailyCounts.maxOfOrNull { it.count } ?: 0

    val rhythmLongestStreak: Int get() {
        var longest = 0
        var current = 0
        dailyCounts.forEach { item ->
            if (item.count > 0) {
                current += 1
                longest = maxOf(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    val rhythmWeekdayAverages: List<Double> get() {
        val totals = IntArray(7)
        val occurrences = IntArray(7)
        dailyCounts.forEach { item ->
            val index = mondayFirstIndex(item.date)
            totals[index] += item.count
            occurrences[index] += 1
        }
        return totals.indices.map { totals[it].toDouble() / maxOf(1, occurrences[it]) }
    }

    val rhythmHourlyCounts: List<Int> get() = IntArray(24).also { values ->
        footprints.forEach { values[hourOf(it.startTime)] += 1 }
    }.toList()

    // ── Memories ──────────────────────────────────────────────────

    /** iOS pastMemoryCandidate: the earliest same-day visit in a past year. */
    val pastMemory: ReviewMemory? = run {
        val today = Calendar.getInstance().apply { time = now }
        val importantPlaceIDs = places.filter { it.isPriority }.map { it.placeID }.toSet()
        val footprint = allFootprints.filter { footprint ->
            val components = Calendar.getInstance().apply { time = footprint.startTime }
            components.get(Calendar.MONTH) == today.get(Calendar.MONTH) &&
                components.get(Calendar.DAY_OF_MONTH) == today.get(Calendar.DAY_OF_MONTH) &&
                components.get(Calendar.YEAR) < today.get(Calendar.YEAR) &&
                footprint.placeID != null && footprint.placeID !in importantPlaceIDs &&
                !footprint.activityTypeValue.isNullOrEmpty()
        }.minByOrNull { it.startTime } ?: return@run null
        val years = maxOf(1, wholeYearsBetween(footprint.startTime, now))
        ReviewMemory(
            id = "past-memory-${footprint.footprintID}",
            date = footprint.startTime,
            footprint = footprint,
            title = placeName(footprint),
            evidence = "${years}年前",
            reason = "往年今日",
            icon = "clock.arrow.circlepath",
            photoUris = footprint.photoUris(),
            score = 0.0
        )
    }

    /** iOS buildReviewMemoryCandidatesCooperatively. */
    suspend fun buildMemories(): List<ReviewMemory> {
        val candidates = mutableListOf<ReviewMemory>()
        val historyByPlace = allFootprints.groupBy(::placeKey)
        val visitsByPlace = footprints.groupBy(::placeKey)
        val photosByPlace = visitsByPlace.mapValues { (_, visits) -> visits.flatMap { it.photoUris() }.distinct() }
        val durationByPlace = visitsByPlace.mapValues { (_, visits) -> visits.sumOf { it.duration }.toDouble() }
        val visitCountByPlace = visitsByPlace.mapValues { it.value.size }
        val representativeIDByPlace = visitsByPlace.mapValues { (_, visits) ->
            visits.maxWithOrNull(compareBy<FootprintEntity> { it.photoUris().size }.thenBy { it.duration })?.footprintID
        }
        val longStayMin = AppConfig.REVIEW_MEMORY_LONG_STAY_MIN_DURATION
        val rankedDurationPlaces = durationByPlace.filter { it.value >= longStayMin }
            .entries.sortedByDescending { it.value }.take(3)
        val longStayPlaceKeys = rankedDurationPlaces.map { it.key }.toSet()
        val longestPlaceKey = rankedDurationPlaces.firstOrNull()?.key
        val mostVisitedPlaceKey = visitCountByPlace.entries.maxWithOrNull(
            compareBy<Map.Entry<String, Int>> { it.value }.thenBy { durationByPlace[it.key] ?: 0.0 }
        )?.key
        val mostPhotoPlaceKey = photosByPlace.entries.maxByOrNull { it.value.size }?.key
        val frequentVisitMinCount = AppConfig.REVIEW_MEMORY_FREQUENT_VISIT_MIN_COUNT
        val longestFootprintID = footprints.maxWithOrNull(
            compareBy<FootprintEntity> { it.duration }.thenByDescending { it.startTime }
        )?.footprintID

        val previousVisitByID = HashMap<String, Date>()
        val firstVisitIDByPlace = HashMap<String, String>()
        val averageDurationByPlace = HashMap<String, Double>()
        historyByPlace.forEach { (key, history) ->
            kotlin.coroutines.coroutineContext.ensureActive()
            val ordered = history.sortedWith(compareBy<FootprintEntity> { it.startTime }.thenBy { it.footprintID })
            ordered.firstOrNull()?.let { firstVisitIDByPlace[key] = it.footprintID }
            var previousDate: Date? = null
            ordered.forEach { footprint ->
                previousDate?.let { previousVisitByID[footprint.footprintID] = it }
                previousDate = footprint.startTime
            }
            averageDurationByPlace[key] = history.sumOf { it.duration }.toDouble() / maxOf(1, history.size)
        }

        val firstCountryDate = HashMap<String, Date>()
        val firstCityDate = HashMap<String, Date>()
        allFootprints.forEach { footprint ->
            val country = footprint.countryCode?.trim()?.uppercase().orEmpty()
            if (country.isNotEmpty()) {
                val current = firstCountryDate[country]
                if (current == null || footprint.startTime.before(current)) firstCountryDate[country] = footprint.startTime
            }
            val city = footprint.cityName?.trim().orEmpty()
            if (city.isNotEmpty()) {
                val key = "$country|$city"
                val current = firstCityDate[key]
                if (current == null || footprint.startTime.before(current)) firstCityDate[key] = footprint.startTime
            }
        }

        footprints.forEach { footprint ->
            kotlin.coroutines.coroutineContext.ensureActive()
            val placeKey = placeKey(footprint)
            val placePhotos = photosByPlace[placeKey].orEmpty()
            val footprintPhotos = footprint.photoUris()
            val placeDuration = durationByPlace[placeKey] ?: 0.0
            val placeVisitCount = visitsByPlace[placeKey]?.size ?: 0
            val isPlaceRepresentative = representativeIDByPlace[placeKey] == footprint.footprintID
            val previousVisit = previousVisitByID[footprint.footprintID]
            val averageDuration = averageDurationByPlace[placeKey] ?: 0.0
            // “第一次来到这里”只属于该地点全部历史记录中的最早一次，
            // 不能因为当前统计周期或候选顺序改变而重新产生。
            val firstVisit = firstVisitIDByPlace[placeKey] == footprint.footprintID
            val daysSincePrevious = previousVisit?.let { ((footprint.startTime.time - it.time) / 86_400_000L).toInt() } ?: 0
            val countryCode = footprint.countryCode?.trim()?.uppercase().orEmpty()
            val cityName = footprint.cityName?.trim().orEmpty()
            val firstCountry = countryCode.isNotEmpty() && firstCountryDate[countryCode] == footprint.startTime
            val firstCity = cityName.isNotEmpty() && firstCityDate["$countryCode|$cityName"] == footprint.startTime
            val duration = footprint.duration.toDouble()

            var score = 0.0
            var reason = ""
            var evidence = ""
            var icon = "sparkles"

            if (firstVisit && footprintPhotos.size >= AppConfig.REVIEW_MEMORY_FIRST_VISIT_PHOTO_MIN_COUNT) {
                score += 6
                reason = "第一次来到这里"
                evidence = "${footprintPhotos.size}张照片 · ${formatRankDuration(duration)}"
                icon = "flag.fill"
            }
            if (firstCountry) {
                score += 7
                reason = "第一次来到这个国家"
                evidence = footprint.countryName ?: countryCode
                icon = "globe.asia.australia.fill"
            } else if (firstCity) {
                score += 5
                if (reason.isEmpty()) {
                    reason = "第一次来到这座城市"
                    evidence = cityName
                    icon = "building.2.fill"
                }
            }
            if (footprint.footprintID == longestFootprintID && duration >= longStayMin) {
                score += 4
                if (!firstCountry && !firstCity) {
                    reason = "停留最久的一次"
                    evidence = "停留${formatRankDuration(duration)}"
                    icon = "hourglass.bottomhalf.filled"
                }
            }
            if (isPlaceRepresentative && placeKey == mostVisitedPlaceKey && placeVisitCount > 1) {
                score += 3
                if (!firstCountry && !firstCity && footprint.footprintID != longestFootprintID) {
                    reason = "停留最多的地方"
                    evidence = "${placeVisitCount}次到访 · 累计${formatRankDuration(placeDuration)}"
                    icon = "repeat.circle.fill"
                }
            }
            if (isPlaceRepresentative && placeKey in longStayPlaceKeys) {
                score += minOf(4.0, placeDuration / longStayMin)
                if (reason.isEmpty() || (reason == "第一次来到这里" && placeVisitCount >= frequentVisitMinCount)) {
                    reason = when {
                        placeKey == longestPlaceKey -> "这段时间最常停留"
                        placeVisitCount >= frequentVisitMinCount -> "常常回到这里"
                        else -> "在这里度过了不少时间"
                    }
                    evidence = "累计${formatRankDuration(placeDuration)} · ${placeVisitCount}次到访"
                    icon = "clock.fill"
                }
            }
            if (averageDuration > 0 && duration >= averageDuration * AppConfig.REVIEW_MEMORY_UNUSUAL_DURATION_RATIO) {
                score += 2
                if (reason.isEmpty() || reason == "第一次来到这里") {
                    reason = "这次停留得格外久"
                    evidence = "停留${formatRankDuration(duration)}"
                    icon = "hourglass"
                }
            }
            if (isPlaceRepresentative && placePhotos.size >= AppConfig.REVIEW_MEMORY_PHOTO_MIN_COUNT) {
                score += minOf(4.0, placePhotos.size.toDouble() / maxOf(1, AppConfig.REVIEW_MEMORY_PHOTO_MIN_COUNT))
                if (reason.isEmpty() || (placeKey == mostPhotoPlaceKey && reason == "第一次来到这里")) {
                    reason = if (placeKey == mostPhotoPlaceKey) "照片最多的地方" else "用照片记下这里"
                    evidence = "累计拍了${placePhotos.size}张照片"
                    icon = "photo.on.rectangle.angled"
                }
            }
            if (daysSincePrevious >= AppConfig.LONG_TIME_NO_SEE_DAYS) {
                score += 4
                if (!firstCountry && !firstCity) {
                    reason = "很久以后又回来"
                    evidence = "相隔${daysSincePrevious}天"
                    icon = "arrow.uturn.backward.circle.fill"
                }
            }
            if (footprint.status == FootprintStatus.MANUAL || footprint.status == FootprintStatus.CONFIRMED) score += 0.8
            if (footprint.isAddressEditedByHand) score += 0.8
            val personalNote = footprint.reason?.trim().orEmpty()
            if (personalNote.isNotEmpty()) {
                score += 1.2
                if (reason == "第一次来到这里" || reason == "用照片记下这里") {
                    reason = "你特别记下的一次停留"
                    evidence = personalNote
                    icon = "note.text"
                }
            }
            if (footprint.isHighlight == true) score += 0.4

            if (score < AppConfig.REVIEW_MEMORY_MINIMUM_SCORE || reason.isEmpty() || placePhotos.isEmpty()) return@forEach
            candidates += ReviewMemory(
                id = "footprint-${footprint.footprintID}",
                date = footprint.startTime,
                footprint = footprint,
                title = placeName(footprint),
                evidence = evidence,
                reason = reason,
                icon = icon,
                photoUris = placePhotos,
                score = score
            )
        }

        farthestDayMemory()?.let { candidates += it }
        candidates += transportMemories().filter { it.photoUris.isNotEmpty() }

        // A favorite is an explicit user choice, so keep one visible as a
        // compact memory card even when its automatic score is not high enough.
        val favoriteFootprints = footprints.filter { it.isHighlight == true && it.status != FootprintStatus.IGNORED }
        val orderedFavorites = favoriteFootprints.sortedWith(compareBy<FootprintEntity> { it.startTime }.thenBy { it.footprintID })
        val favoriteFootprint = orderedFavorites.firstOrNull { it.photoUris().isNotEmpty() } ?: orderedFavorites.firstOrNull()
        val favoriteCandidate = favoriteFootprint?.let { footprint ->
            ReviewMemory(
                id = "favorite-${footprint.footprintID}",
                date = footprint.startTime,
                footprint = null,
                title = "${favoriteFootprints.size}个重要片段",
                evidence = "点开查看全部收藏",
                reason = "收藏足迹",
                icon = "star.fill",
                photoUris = footprint.photoUris(),
                score = 0.0
            )
        }

        val usedDays = HashSet<Date>()
        val usedPlaces = HashSet<String>()
        val usedReasons = HashSet<String>()
        val selected = mutableListOf<ReviewMemory>()
        val automaticLimit = maxOf(0, AppConfig.REVIEW_MEMORY_MAXIMUM_COUNT - (if (favoriteCandidate == null) 0 else 1))
        val ranked = candidates.sortedWith(
            compareByDescending<ReviewMemory> { it.score }.thenBy { it.date }.thenBy { it.id }
        )
        fun appendIfAvailable(candidate: ReviewMemory, requiresNewReason: Boolean) {
            if (selected.size >= automaticLimit) return
            val day = startOfDay(candidate.date)
            val placeKey = candidate.footprint?.let(::placeKey)
            if (day in usedDays || (placeKey != null && placeKey in usedPlaces) ||
                (requiresNewReason && candidate.reason in usedReasons)
            ) return
            selected += candidate
            usedDays += day
            usedReasons += candidate.reason
            placeKey?.let { usedPlaces += it }
        }
        ranked.forEach { appendIfAvailable(it, requiresNewReason = true) }
        if (selected.size < automaticLimit) ranked.forEach { appendIfAvailable(it, requiresNewReason = false) }
        favoriteCandidate?.let { selected += it }
        return selected
    }

    private fun photoUrisOn(day: Date): List<String> =
        footprints.filter { startOfDay(it.startTime) == day }.flatMap { it.photoUris() }

    /** iOS reviewFarthestDay. */
    private fun farthestDayMemory(): ReviewMemory? {
        val item = transports.groupBy { startOfDay(it.startTime) }
            .map { (day, records) -> day to records.sumOf { it.distance } }
            .maxByOrNull { it.second } ?: return null
        if (item.second < AppConfig.REVIEW_MEMORY_TRAVEL_DISTANCE_MIN) return null
        val photos = photoUrisOn(item.first)
        if (photos.isEmpty()) return null
        return ReviewMemory(
            id = "distance-${item.first.time / 1000}",
            date = item.first,
            footprint = null,
            title = reviewMonthDay(item.first),
            evidence = formatRankMileage(item.second),
            reason = "走得最远的一天",
            icon = "point.topleft.down.to.point.bottomright.curvepath",
            photoUris = photos,
            score = 5.0
        )
    }

    /** iOS reviewTransportMemoryCandidates. */
    private fun transportMemories(): List<ReviewMemory> {
        val grouped = transports.groupBy { startOfDay(it.startTime) }
        val result = mutableListOf<ReviewMemory>()
        grouped.map { (day, records) ->
            day to records.filter {
                val type = transportType(it)
                type == TransportType.SLOW || type == TransportType.RUNNING
            }.sumOf { it.distance }
        }.maxByOrNull { it.second }?.takeIf { it.second >= AppConfig.REVIEW_MEMORY_WALK_DISTANCE_MIN }?.let { (day, distance) ->
            result += ReviewMemory(
                id = "walking-${day.time / 1000}", date = day, footprint = null,
                title = reviewMonthDay(day), evidence = formatRankMileage(distance),
                reason = "步行最多的一天", icon = "figure.walk", photoUris = photoUrisOn(day), score = 4.8
            )
        }
        grouped.map { (day, records) ->
            day to records.map { it.manualTypeRaw ?: it.typeRaw }.filter { it.isNotEmpty() }.toSet().size
        }.maxByOrNull { it.second }?.takeIf { it.second >= AppConfig.REVIEW_MEMORY_DIVERSE_TRANSPORT_MIN_COUNT }?.let { (day, count) ->
            result += ReviewMemory(
                id = "modes-${day.time / 1000}", date = day, footprint = null,
                title = reviewMonthDay(day), evidence = "用了${count}种交通方式",
                reason = "出行方式最丰富的一天", icon = "arrow.triangle.branch", photoUris = photoUrisOn(day), score = 4.4
            )
        }
        return result
    }

    // ── Map ───────────────────────────────────────────────────────

    data class MapData(
        val routes: List<ReviewMapRoute>,
        val overviewPoints: List<ReviewTransportOverviewPoint>,
        val bounds: ReviewMapBounds?
    )

    /** iOS startReviewDerivedDataRefresh's detached decode: routes, fused trajectory points and bounds. */
    suspend fun buildMapData(): MapData {
        class Bucket(var latitude: Double = 0.0, var longitude: Double = 0.0, var count: Int = 0)

        val routes = transports.map { record ->
            kotlin.coroutines.coroutineContext.ensureActive()
            ReviewMapRoute(record.recordID, transportType(record), record.distance, parseRouteSegments(record.pointsJson))
        }
        var cellSize = AppConfig.REVIEW_MAP_TRAJECTORY_BASE_CELL_DEGREES
        var buckets = HashMap<String, Bucket>()
        var minimumLatitude = Double.MAX_VALUE
        var maximumLatitude = -Double.MAX_VALUE
        var minimumLongitude = Double.MAX_VALUE
        var maximumLongitude = -Double.MAX_VALUE
        fun isRenderable(latitude: Double, longitude: Double) =
            latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
                !(latitude == 0.0 && longitude == 0.0)
        fun include(latitude: Double, longitude: Double) {
            if (!isRenderable(latitude, longitude)) return
            minimumLatitude = minOf(minimumLatitude, latitude)
            maximumLatitude = maxOf(maximumLatitude, latitude)
            minimumLongitude = minOf(minimumLongitude, longitude)
            maximumLongitude = maxOf(maximumLongitude, longitude)
        }

        footprints.forEach { include(latitude(it), longitude(it)) }
        routes.forEach { route ->
            route.segments.forEach { segment ->
                segment.forEach { point ->
                    if (!isRenderable(point.latitude, point.longitude)) return@forEach
                    include(point.latitude, point.longitude)
                    val key = "${(point.longitude / cellSize).roundToLong()}:${(point.latitude / cellSize).roundToLong()}"
                    val bucket = buckets.getOrPut(key) { Bucket() }
                    bucket.latitude += point.latitude
                    bucket.longitude += point.longitude
                    bucket.count += 1
                }
            }
        }
        while (buckets.size > AppConfig.REVIEW_MAP_TRAJECTORY_MAX_DRAW_POINTS) {
            kotlin.coroutines.coroutineContext.ensureActive()
            cellSize *= 1.6
            val merged = HashMap<String, Bucket>()
            buckets.values.forEach { bucket ->
                val latitude = bucket.latitude / bucket.count
                val longitude = bucket.longitude / bucket.count
                val key = "${(longitude / cellSize).roundToLong()}:${(latitude / cellSize).roundToLong()}"
                val target = merged.getOrPut(key) { Bucket() }
                target.latitude += bucket.latitude
                target.longitude += bucket.longitude
                target.count += bucket.count
            }
            buckets = merged
        }
        val overviewPoints = buckets.map { (key, bucket) ->
            ReviewTransportOverviewPoint(key, bucket.latitude / bucket.count, bucket.longitude / bucket.count, bucket.count)
        }
        val bounds = if (minimumLatitude == Double.MAX_VALUE) null
        else ReviewMapBounds(minimumLatitude, maximumLatitude, minimumLongitude, maximumLongitude)
        return MapData(routes, overviewPoints, bounds)
    }

    private fun parseColor(hex: String): Color = runCatching {
        Color(android.graphics.Color.parseColor(if (hex.startsWith("#")) hex else "#$hex"))
    }.getOrDefault(DfkAccent)

    private fun daysBetween(start: Date, end: Date): Int {
        val calendar = Calendar.getInstance().apply { time = start }
        var days = 0
        while (calendar.time.before(end)) {
            calendar.add(Calendar.DAY_OF_YEAR, 1)
            if (!calendar.time.after(end)) days += 1
        }
        return days
    }

    private fun wholeYearsBetween(start: Date, end: Date): Int {
        val calendar = Calendar.getInstance().apply { time = start }
        var years = 0
        while (true) {
            calendar.add(Calendar.YEAR, 1)
            if (calendar.time.after(end)) return years
            years += 1
        }
    }
}

data class ReviewUiState(
    val selectedRange: StatisticsRange = StatisticsRange.LAST_30_DAYS,
    val snapshot: ReviewSnapshot? = null,
    val memories: List<ReviewMemory> = emptyList(),
    val mapData: ReviewSnapshot.MapData? = null,
    /** iOS reviewRoutesReady: maps, memories and rankings of the applied range are complete. */
    val isReady: Boolean = false,
    val availableYears: List<Int> = emptyList()
)

class StatisticsViewModel(application: Application) : AndroidViewModel(application) {
    private val db = DiFangKeApp.instance.database

    private class Source(
        val footprints: List<FootprintEntity>,
        val transports: List<TransportRecordEntity>,
        val activityTypes: List<ActivityTypeEntity>,
        val places: List<PlaceEntity>
    )

    private val _state = MutableStateFlow(ReviewUiState())
    val state: StateFlow<ReviewUiState> = _state.asStateFlow()

    private var source: Source? = null
    private var sourceFingerprint: Int? = null
    private var appliedRange: StatisticsRange = StatisticsRange.LAST_30_DAYS
    private var refreshJob: Job? = null

    /** iOS onAppear → scheduleReviewRefresh(fetchesData: true). */
    fun onAppear() = scheduleRefresh(range = null, fetchesData = true)

    /** iOS onChange(of: selectedRange): drop the previous range's result before rebuilding. */
    fun setRange(range: StatisticsRange) {
        if (range == _state.value.selectedRange && range == appliedRange) return
        _state.update { it.copy(selectedRange = range, isReady = false, mapData = null) }
        scheduleRefresh(range = range, fetchesData = false)
    }

    private fun scheduleRefresh(range: StatisticsRange?, fetchesData: Boolean) {
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            // Commit the tab or picker selection first; the data work starts later.
            delay(16)
            var sourceChanged = false
            if (fetchesData) sourceChanged = fetchData()
            if (range != null) appliedRange = range
            // Re-entering the page keeps the current result when the source is
            // unchanged; only a range change or new data rebuilds it.
            if (range == null && !sourceChanged && _state.value.snapshot != null) return@launch
            val current = source ?: return@launch
            rebuild(current, appliedRange)
        }
    }

    private suspend fun fetchData(): Boolean = withContext(Dispatchers.IO) {
        val footprints = db.footprintDao().getAll()
            .filter { it.statusValue != FootprintStatus.IGNORED.raw }
            .sortedByDescending { it.startTime }
        val transports = db.transportRecordDao().getAllSync().filter { it.statusRaw == "active" }
        val activityTypes = db.activityTypeDao().getAll().sortedBy { it.sortOrder }
        val places = db.placeDao().getAll()
        val fingerprint = listOf(
            footprints.map {
                listOf(it.footprintID, it.startTime, it.endTime, it.latitudeJson.length, it.longitudeJson.length,
                    it.photoAssetIDsJson, it.placeID, it.activityTypeValue, it.countryCode, it.cityName,
                    it.statusValue, it.isHighlight, it.address, it.reason)
            },
            transports.map {
                // Route payloads can be very large; identity, time range and
                // length are enough to detect normal edits.
                listOf(it.recordID, it.startTime, it.endTime, it.typeRaw, it.manualTypeRaw, it.distance, it.pointsJson.length)
            },
            activityTypes.map { listOf(it.id, it.name, it.icon, it.colorHex, it.sortOrder) },
            places.map { listOf(it.placeID, it.name, it.latitude, it.longitude, it.address, it.category, it.isPriority) }
        ).hashCode()
        if (fingerprint == sourceFingerprint) return@withContext false
        sourceFingerprint = fingerprint
        source = Source(footprints, transports, activityTypes, places)
        true
    }

    private suspend fun rebuild(source: Source, range: StatisticsRange) {
        val now = Date()
        val snapshot = withContext(Dispatchers.Default) {
            val cutoff = range.days?.let { addDays(now, -it) }
            fun inRange(date: Date) = when (range) {
                is StatisticsRange.CUSTOM_YEAR -> yearOf(date) == range.year
                else -> !date.before(cutoff)
            }
            ReviewSnapshot(
                range = range,
                now = now,
                allFootprints = source.footprints,
                footprints = source.footprints.filter { inRange(it.startTime) },
                transports = source.transports.filter { inRange(it.startTime) },
                activityTypes = source.activityTypes,
                places = source.places
            )
        }
        val years = source.footprints.map { yearOf(it.startTime) }.distinct().sortedDescending()
        _state.update {
            it.copy(snapshot = snapshot, memories = emptyList(), mapData = null, isReady = false, availableYears = years)
        }
        val mapData = withContext(Dispatchers.Default) { snapshot.buildMapData() }
        val memories = withContext(Dispatchers.Default) { snapshot.buildMemories() }
        val orderedMemories = withContext(Dispatchers.IO) {
            memories.map { memory -> memory.copy(photoUris = photosOldestFirst(memory.photoUris)) }
        }
        if (appliedRange != range) return
        _state.update { it.copy(memories = orderedMemories, mapData = mapData, isReady = true) }
    }

    /** iOS PhotoService.assetIDsOldestFirst. */
    private fun photosOldestFirst(uris: List<String>): List<String> {
        if (uris.size <= 1) return uris
        val context = getApplication<Application>()
        return uris.mapIndexed { index, uri -> Triple(uri, photoTakenDate(context, uri), index) }
            .sortedWith(compareBy<Triple<String, Date?, Int>, Long?>(nullsLast<Long>()) { it.second?.time }.thenBy { it.third })
            .map { it.first }
    }
}
