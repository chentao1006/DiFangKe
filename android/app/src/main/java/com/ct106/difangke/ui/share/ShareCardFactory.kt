package com.ct106.difangke.ui.share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import com.ct106.difangke.AppConfig
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.timeline.RouteCodec
import com.ct106.difangke.service.timeline.RouteCoordinate
import com.ct106.difangke.ui.screens.statistics.reviewIntegratedPlaceKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.util.Date
import kotlin.math.max
import kotlin.math.roundToLong

/** iOS DFKShareCardFactory + DFKShareImageLoader, reading straight from Room. */
internal object ShareCardFactory {
    private val db get() = DiFangKeApp.instance.database

    suspend fun load(context: Context, request: ShareCardRequest): SharePayload? = withContext(Dispatchers.IO) {
        when (request) {
            is ShareCardRequest.Moment -> moment(context, request.footprintId)
            is ShareCardRequest.Timeline -> timeline(context, request.startDate, request.endDate)
            is ShareCardRequest.Stats -> stats(context, request)
        }
    }

    private fun activityFor(footprint: FootprintEntity, activities: List<ActivityTypeEntity>): ActivityTypeEntity? {
        val value = footprint.activityTypeValue?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return activities.firstOrNull { it.id == value || it.name == value }
    }

    // ── Moment ──────────────────────────────────────────────────────────────

    private suspend fun moment(context: Context, id: String): SharePayload? {
        val footprint = db.footprintDao().getById(id) ?: return null
        val activities = db.activityTypeDao().getAll()
        val activity = activityFor(footprint, activities)
        val place = ShareFormat.displayPlace(footprint)
        val center = footprint.shareCenter()
        val entry = ShareEntry(
            time = ShareFormat.timeRange(footprint.startTime, footprint.endTime),
            title = place,
            detail = footprint.reason?.trim(),
            tag = activity?.name,
            activityIcon = activity?.icon,
            activityColor = parseHexColor(activity?.colorHex),
            coordinate = center,
            footprintIDs = listOf(footprint.footprintID)
        )
        val coordinates = footprint.sharePoints().ifEmpty { listOfNotNull(center) }
        val markers = markersFor(listOf(footprint), activities)
        val photos = loadPhotos(context, footprint.photoUris())
        val map = ShareMapSnapshotter.snapshot(coordinates, markers = markers, markerScale = 2.2f)
        return SharePayload(
            kind = ShareCardKind.MOMENT,
            title = place,
            subtitle = "这一刻，被认真留了下来",
            rangeText = ShareFormat.dateText(footprint.startTime),
            locationText = ShareFormat.locationText(listOf(footprint)),
            photos = photos,
            contentMap = map,
            backgroundMap = map,
            coordinates = coordinates,
            mapMarkers = markers,
            markerScale = 2.2f,
            entries = listOf(entry)
        )
    }

    // ── Timeline ────────────────────────────────────────────────────────────

    private suspend fun timeline(context: Context, startDate: Date, endDate: Date): SharePayload {
        val start = ShareFormat.startOfDay(minOf(startDate, endDate))
        val selectedEnd = ShareFormat.startOfDay(maxOf(startDate, endDate))
        val endExclusive = ShareFormat.addDays(selectedEnd, 1)
        val footprints = db.footprintDao().getBetween(start, endExclusive).sortedBy { it.startTime }
        val transports = db.transportRecordDao().getActiveBetween(start, endExclusive).sortedBy { it.startTime }
        val activities = db.activityTypeDao().getAll()
        val distinctDays = footprints.map { ShareFormat.startOfDay(it.startTime) }.toSet()
        val entries = mergedEntries(footprints, activities, showsDayDividers = distinctDays.size > 1)
        val markers = markersFor(footprints, activities)
        val routes = transports.map { it.sharePoints() }.filter { it.size > 1 }
        val coordinates = footprints.flatMap { it.sharePoints() } + routes.flatten()
        val markerScale = if (footprints.size <= 1) 2.2f else 1.5f
        val photos = loadPhotos(context, footprints.flatMap { it.photoUris() })
        val map = ShareMapSnapshotter.snapshot(coordinates, markers = markers, routes = routes, markerScale = markerScale)
        return SharePayload(
            kind = ShareCardKind.TIMELINE,
            title = if (entries.isEmpty()) "这段时间还没有足迹" else "这段时间去了 ${entries.size} 个地方",
            subtitle = "我这一段时间去了哪里",
            rangeText = ShareFormat.rangeText(start, selectedEnd),
            locationText = ShareFormat.locationText(footprints),
            photos = photos,
            contentMap = map,
            backgroundMap = map,
            coordinates = coordinates,
            mapMarkers = markers,
            mapRoutes = routes,
            mapTransports = transports,
            markerScale = markerScale,
            entries = entries
        )
    }

    /** iOS snapshotMarkers: one pin per place, in time order. */
    fun markersFor(footprints: List<FootprintEntity>, activities: List<ActivityTypeEntity>): List<ShareMapMarker> {
        val seen = mutableSetOf<String>()
        return footprints.sortedBy { it.startTime }.mapNotNull { footprint ->
            val center = footprint.shareCenter()?.takeIf { it.isRenderable } ?: return@mapNotNull null
            val key = footprint.placeID
                ?: footprint.address?.trim()?.replace(Regex("\\s+"), " ")?.lowercase()?.takeIf { it.isNotEmpty() }
                ?: String.format("%.5f,%.5f", center.lat, center.lon)
            if (!seen.add(key)) return@mapNotNull null
            val activity = activityFor(footprint, activities)
            ShareMapMarker(
                point = center,
                icon = activity?.icon ?: "place",
                color = parseHexColor(activity?.colorHex) ?: 0xFF8E8E93.toInt(),
                durationSeconds = footprint.duration,
                footprintID = footprint.footprintID
            )
        }
    }

    private fun placeKey(footprint: FootprintEntity, center: GeoPoint?): String {
        val name = ShareFormat.displayPlace(footprint).trim().replace(Regex("\\s+"), " ").lowercase()
        if (name.isNotEmpty() && name != "一个生活现场") return name
        footprint.placeID?.let { return it }
        return String.format("%.5f,%.5f", center?.lat ?: 0.0, center?.lon ?: 0.0)
    }

    /** iOS mergedEntries: merge the same place within a day; day dividers for multi-day ranges. */
    private fun mergedEntries(
        footprints: List<FootprintEntity>,
        activities: List<ActivityTypeEntity>,
        showsDayDividers: Boolean
    ): List<ShareEntry> {
        class Acc(
            var wLat: Double, var wLon: Double, var total: Double,
            var first: Date, var last: Date, var representative: FootprintEntity, var count: Int,
            var detail: String?, var tag: String?, var icon: String?, var color: Int?,
            val ids: MutableList<String>
        )
        val buckets = linkedMapOf<String, Acc>()
        footprints.sortedBy { it.startTime }.forEach { footprint ->
            val center = footprint.shareCenter() ?: GeoPoint(0.0, 0.0)
            val key = "${ShareFormat.startOfDay(footprint.startTime).time}|${placeKey(footprint, center)}"
            val detail = footprint.reason?.trim()
            val activity = activityFor(footprint, activities)
            val weight = max(footprint.duration.toDouble(), 1.0)
            val existing = buckets[key]
            if (existing != null) {
                existing.wLat += center.lat * weight
                existing.wLon += center.lon * weight
                existing.total += weight
                if (footprint.startTime < existing.first) existing.first = footprint.startTime
                if (footprint.endTime > existing.last) existing.last = footprint.endTime
                existing.count += 1
                existing.ids += footprint.footprintID
                if (footprint.duration > existing.representative.duration) existing.representative = footprint
                if (existing.detail.isNullOrEmpty()) existing.detail = detail
                if (existing.tag.isNullOrEmpty()) existing.tag = activity?.name
                if (existing.icon.isNullOrEmpty()) {
                    existing.icon = activity?.icon
                    existing.color = parseHexColor(activity?.colorHex)
                }
            } else {
                buckets[key] = Acc(
                    center.lat * weight, center.lon * weight, weight, footprint.startTime, footprint.endTime,
                    footprint, 1, detail, activity?.name, activity?.icon, parseHexColor(activity?.colorHex),
                    mutableListOf(footprint.footprintID)
                )
            }
        }
        var previousDay: Date? = null
        return buckets.values.map { item ->
            val duration = max(item.total, 1.0)
            val day = ShareFormat.startOfDay(item.first)
            val divider = if (showsDayDividers && previousDay != day) ShareFormat.dayDivider(day) else null
            previousDay = day
            ShareEntry(
                time = ShareFormat.startAndAccumulatedDuration(item.first, duration),
                title = ShareFormat.displayPlace(item.representative),
                detail = item.detail,
                tag = item.tag,
                activityIcon = item.icon,
                activityColor = item.color,
                coordinate = GeoPoint(item.wLat / duration, item.wLon / duration),
                count = item.count,
                dayDividerText = divider,
                footprintIDs = item.ids
            )
        }
    }

    // ── Stats (iOS HistoryStatisticsView.prepareStatsShare + statsPayload) ───

    private suspend fun stats(context: Context, request: ShareCardRequest.Stats): SharePayload {
        val start = request.startDate
        val end = request.endDate
        val footprints = db.footprintDao().getBetween(start, end)
            .filter { it.startTime >= start && it.startTime < end }
        val transports = db.transportRecordDao().getActiveBetween(start, end)
            .filter { it.startTime >= start && it.startTime < end }
        val places = db.placeDao().getAll()
        val activities = db.activityTypeDao().getAll()
        val placesById = places.associateBy { it.placeID }

        val review = request.review ?: fallbackReview(footprints, transports, placesById, activities, start, end)
        val map = reviewMap(footprints, transports, placesById)
        val memories = loadReviewMemories(context, review.memories.take(4))
        return SharePayload(
            kind = ShareCardKind.STATS,
            title = "我的回顾",
            subtitle = "这段时间的生活快照",
            rangeText = request.rangeText,
            contentMap = map,
            coordinates = footprints.mapNotNull { it.shareCenter() },
            stats = review.stats,
            placeRankings = review.regionRankings,
            activityRankings = review.activityRankings,
            transportRankings = review.transportRankings,
            reviewRhythmValues = review.rhythmValues,
            reviewRhythmStartText = review.rhythmStartText,
            reviewRhythmEndText = review.rhythmEndText,
            reviewMemories = memories
        )
    }

    /** iOS DFKShareImageLoader.loadReviewMapImages: Review-style place counts + transport lines. */
    private suspend fun reviewMap(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        placesById: Map<String, PlaceEntity>
    ): ShareMapImages? {
        // iOS aggregatedFootprints keyed by reviewIntegratedPlaceKey, duration-weighted centers.
        class Bucket(var lat: Double = 0.0, var lon: Double = 0.0, var weight: Double = 0.0)
        val buckets = linkedMapOf<String, Bucket>()
        footprints.forEach { footprint ->
            val center = footprint.shareCenter()?.takeIf { it.isRenderable } ?: return@forEach
            val weight = max(footprint.duration.toDouble(), 1.0)
            val bucket = buckets.getOrPut(reviewIntegratedPlaceKey(footprint, placesById)) { Bucket() }
            bucket.lat += center.lat * weight
            bucket.lon += center.lon * weight
            bucket.weight += weight
        }
        val placeCenters = buckets.values.map { GeoPoint(it.lat / it.weight, it.lon / it.weight) }
        return ShareMapSnapshotter.reviewSnapshot(
            footprintCoordinates = footprints.flatMap { it.sharePoints() },
            places = placeCenters,
            transports = transports.mapNotNull(::reviewMapTransport),
            markerScale = 1.5f
        )
    }

    /** iOS WidgetDecodedTransport + widgetTransportLineSegments. */
    private fun reviewMapTransport(record: TransportRecordEntity): ShareReviewMapTransport? {
        val type = TransportType.entries.firstOrNull { it.raw == (record.manualTypeRaw ?: record.typeRaw) }
            ?: TransportType.SLOW
        val decoded = RouteCodec.decode(record.pointsJson)
        // Android routes may hold [0,0] separators: each run between them is its own polyline.
        val runs = mutableListOf<MutableList<RouteCoordinate>>(mutableListOf())
        decoded.forEach { point ->
            if (point.isValid && GeoPoint(point.lat, point.lon).isRenderable) runs.last().add(point)
            else if (runs.last().isNotEmpty()) runs.add(mutableListOf())
        }
        val points = runs.flatten().map { GeoPoint(it.lat, it.lon) }
        if (points.isEmpty()) return null
        val segments = runs.filter { it.size >= 2 }.flatMap { run ->
            val result = mutableListOf<ShareReviewMapSegment>()
            var chunk = mutableListOf(GeoPoint(run[0].lat, run[0].lon))
            var chunkDashed: Boolean? = null
            run.zipWithNext().forEach { (current, next) ->
                val isDashed = when {
                    current.isSyntheticPadding || next.isSyntheticPadding -> true
                    current.timestamp != null && next.timestamp != null ->
                        kotlin.math.abs(next.timestamp - current.timestamp) > REVIEW_ROUTE_TIME_GAP_MILLIS ||
                            distanceMeters(GeoPoint(current.lat, current.lon), GeoPoint(next.lat, next.lon)) >
                            AppConfig.WIDGET_INFERRED_ROUTE_DISTANCE_THRESHOLD
                    // Samples without times are inferred connections.
                    else -> true
                }
                if (chunkDashed == null) chunkDashed = isDashed
                val nextPoint = GeoPoint(next.lat, next.lon)
                if (chunkDashed == isDashed) {
                    chunk += nextPoint
                } else {
                    result += ShareReviewMapSegment(chunk, chunkDashed == true)
                    chunk = mutableListOf(GeoPoint(current.lat, current.lon), nextPoint)
                    chunkDashed = isDashed
                }
            }
            if (chunk.size >= 2) result += ShareReviewMapSegment(chunk, chunkDashed == true)
            result
        }
        return ShareReviewMapTransport(type, points, segments)
    }

    /** iOS DFKShareImageLoader.loadFirstImage per memory candidate. */
    private suspend fun loadReviewMemories(
        context: Context,
        memories: List<ShareReviewMemory>
    ): List<ShareReviewMemoryCard> = coroutineScope {
        memories.mapIndexed { index, memory ->
            async(Dispatchers.IO) {
                val photo = memory.photoUri?.takeIf { it.isNotBlank() }?.let { uri ->
                    // The first memory is the full-width card; the rest are thumbnails.
                    runCatching { decodeScaled(context, Uri.parse(uri), if (index == 0) 1200 else 600) }.getOrNull()
                }
                ShareReviewMemoryCard(memory.id, memory.reason, memory.title, memory.detail, photo)
            }
        }.awaitAll()
    }

    /**
     * Used only when the caller has no Review data: the same figures the iOS
     * Review screen passes to statsPayload, derived from the window's records.
     */
    private fun fallbackReview(
        footprints: List<FootprintEntity>,
        transports: List<TransportRecordEntity>,
        placesById: Map<String, PlaceEntity>,
        activities: List<ActivityTypeEntity>,
        start: Date,
        end: Date
    ): ShareStatsReview {
        // iOS reviewGeographyMetric.
        val countries = footprints.mapNotNull { it.countryCode?.trim()?.uppercase()?.takeIf(String::isNotEmpty) }.toSet()
        val cities = footprints.mapNotNull { fp ->
            fp.cityName?.trim()?.takeIf { it.isNotEmpty() }?.let { "${fp.countryCode?.uppercase().orEmpty()}|$it" }
        }.toSet()
        val geography = when {
            countries.size > 1 -> ShareStatEntry("个国家", "${countries.size}")
            cities.size > 1 -> ShareStatEntry("座城市", "${cities.size}")
            else -> ShareStatEntry("个地点", "${footprints.map { reviewIntegratedPlaceKey(it, placesById) }.toSet().size}")
        }
        val stats = listOf(
            geography,
            ShareStatEntry("路程", rankMileage(transports.sumOf { max(0.0, it.distance) })),
            ShareStatEntry("段路程", "${transports.size}")
        )

        class Slice(val title: String, val icon: String, val color: Int, var duration: Double = 0.0, var count: Int = 0, var distance: Double = 0.0)
        val activitySlices = linkedMapOf<String, Slice>()
        footprints.forEach { fp ->
            val activity = activityFor(fp, activities) ?: return@forEach
            activitySlices.getOrPut(activity.name) {
                Slice(activity.name, activity.icon, parseHexColor(activity.colorHex) ?: SHARE_APP_ACCENT)
            }.duration += fp.duration.toDouble()
        }
        val sortedActivities = activitySlices.values.sortedByDescending { it.duration }
        val activityTotal = max(1.0, sortedActivities.sumOf { it.duration })
        val activityRankings = sortedActivities.take(5).map {
            ShareRankingEntry(it.title, null, rankDuration(it.duration), it.icon, it.color, it.duration / activityTotal)
        }

        // iOS reviewActivityBuckets: 24 equal slices of the window.
        val bucketCount = 24
        val window = max(1L, end.time - start.time).toDouble()
        val rhythm = IntArray(bucketCount)
        footprints.forEach { fp ->
            val progress = (fp.startTime.time - start.time) / window
            rhythm[(progress * bucketCount).toInt().coerceIn(0, bucketCount - 1)] += 1
        }
        val axis = java.text.SimpleDateFormat("M月d日", java.util.Locale.SIMPLIFIED_CHINESE)

        val transportSlices = linkedMapOf<TransportType, Slice>()
        transports.forEach { t ->
            val type = TransportType.entries.firstOrNull { it.raw == (t.manualTypeRaw ?: t.typeRaw) } ?: TransportType.SLOW
            val slice = transportSlices.getOrPut(type) { Slice(type.localizedName, type.icon, SHARE_APP_ACCENT) }
            slice.count += 1
            slice.distance += max(0.0, t.distance)
        }
        val transportRankings = transportSlices.values
            .sortedWith(compareByDescending<Slice> { it.distance }.thenByDescending { it.count })
            .take(3)
            .map { ShareRankingEntry(it.title, rankMileage(it.distance), "${it.count}次", it.icon, it.color) }

        val regions = linkedMapOf<String, Slice>()
        footprints.forEach { fp ->
            val city = fp.cityName?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
            regions.getOrPut("${fp.countryCode.orEmpty()}|$city") { Slice(city, "mappin.and.ellipse", SHARE_APP_ACCENT) }
                .duration += fp.duration.toDouble()
        }
        val regionRankings = regions.values.sortedByDescending { it.duration }.take(3)
            .map { ShareRankingEntry(it.title, null, rankDuration(it.duration), it.icon, it.color) }

        return ShareStatsReview(
            stats = stats,
            memories = emptyList(),
            activityRankings = activityRankings,
            rhythmValues = rhythm.toList(),
            rhythmStartText = axis.format(start),
            rhythmEndText = axis.format(Date(max(start.time, end.time - 1))),
            transportRankings = transportRankings,
            regionRankings = regionRankings
        )
    }

    /** iOS HistoryStatisticsView.formatRankDuration. */
    private fun rankDuration(seconds: Double): String {
        val totalMinutes = (seconds / 60).toInt()
        if (totalMinutes < 60) return "${totalMinutes}分钟"
        val totalHours = totalMinutes / 60
        if (totalHours >= 24) {
            val days = totalHours / 24
            return if (seconds > 3 * 24 * 60 * 60) "${days}天" else "${days}天${totalHours % 24}小时"
        }
        val hours = totalMinutes / 60.0
        return if (hours < 10) String.format("%.1f小时", hours) else "${hours.toInt()}小时"
    }

    /** iOS HistoryStatisticsView.formatRankMileage. */
    private fun rankMileage(meters: Double): String =
        if (meters < 1000) "${Math.round(meters)}米" else String.format("%.1f公里", meters / 1000)

    /** iOS widgetTransportLineSegments: a gap longer than 3 minutes is an inferred link. */
    private const val REVIEW_ROUTE_TIME_GAP_MILLIS = 3 * 60 * 1000L

    // ── Photos ──────────────────────────────────────────────────────────────

    /** iOS loadShareMedia: up to 20 shuffled distinct photos, ~1200 px. */
    private suspend fun loadPhotos(context: Context, uris: List<String>): List<Bitmap> = coroutineScope {
        uris.distinct().shuffled().take(20).map { uri ->
            async(Dispatchers.IO) { runCatching { decodeScaled(context, Uri.parse(uri), 1200) }.getOrNull() }
        }.awaitAll().filterNotNull()
    }

    private fun decodeScaled(context: Context, uri: Uri, maxDimension: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val largest = max(info.size.width, info.size.height)
                if (largest > maxDimension) {
                    val ratio = maxDimension.toDouble() / largest
                    decoder.setTargetSize(
                        (info.size.width * ratio).roundToLong().toInt().coerceAtLeast(1),
                        (info.size.height * ratio).roundToLong().toInt().coerceAtLeast(1)
                    )
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val resolver = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxDimension) sample *= 2
        val bitmap = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val rotation = resolver.openInputStream(uri)?.use { ExifInterface(it).rotationDegrees } ?: 0
        if (rotation == 0) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
    }

    /** Re-snapshot after per-entry toggles (iOS refreshSelectedMap). */
    suspend fun refreshedTimelineMap(payload: SharePayload): ShareMapImages? {
        val included = payload.includedEntries
        val ids = included.flatMap { it.footprintIDs }.toSet()
        val markers = payload.mapMarkers.filter { it.footprintID in ids }
        val coordinates = included.mapNotNull { it.coordinate }
        if (coordinates.isEmpty() && payload.mapRoutes.isEmpty()) return null
        val scale = if (markers.size <= 1) 2.2f else 1.5f
        return ShareMapSnapshotter.snapshot(
            coordinates + payload.mapRoutes.flatten(),
            markers = markers,
            routes = payload.mapRoutes,
            markerScale = scale
        )
    }

    /** Fact lines for the AI title prompt (transport part). */
    fun transportFacts(transports: List<TransportRecordEntity>): String = transports
        .filter { it.statusRaw == "active" }
        .sortedBy { it.startTime }
        .joinToString("\n") { t ->
            val raw = t.manualTypeRaw ?: t.typeRaw
            val type = com.ct106.difangke.data.model.TransportType.entries.firstOrNull { it.raw == raw }?.localizedName ?: "出行"
            val distance = if (t.distance >= 1000) String.format("%.1f公里", t.distance / 1000) else "${Math.round(t.distance)}米"
            val time = "${ShareFormat.time(t.startTime)}-${ShareFormat.time(t.endTime)}"
            listOf(time, type, distance, t.startLocation, t.endLocation)
                .map { it.trim() }.filter { it.isNotEmpty() }.joinToString("｜")
        }
}
