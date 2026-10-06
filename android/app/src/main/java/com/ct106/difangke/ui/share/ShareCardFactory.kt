package com.ct106.difangke.ui.share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import com.ct106.difangke.DiFangKeApp
import com.ct106.difangke.data.db.entity.ActivityTypeEntity
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.db.entity.TransportRecordEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.util.Date
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToLong

/** iOS DFKShareCardFactory + DFKShareImageLoader, reading straight from Room. */
internal object ShareCardFactory {
    private val db get() = DiFangKeApp.instance.database

    suspend fun load(context: Context, request: ShareCardRequest): SharePayload? = withContext(Dispatchers.IO) {
        when (request) {
            is ShareCardRequest.Moment -> moment(context, request.footprintId)
            is ShareCardRequest.Timeline -> timeline(context, request.startDate, request.endDate)
            is ShareCardRequest.Stats -> stats(request.rangeText, request.startDate, request.endDate)
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

    // ── Stats ───────────────────────────────────────────────────────────────

    private suspend fun stats(rangeText: String, start: Date, end: Date): SharePayload {
        val footprints = db.footprintDao().getAll().filter { it.startTime >= start && it.startTime < end }
        val transports = db.transportRecordDao().getAllSync()
            .filter { it.statusRaw == "active" && it.startTime >= start && it.startTime < end }
        val places = db.placeDao().getAll()
        val activities = db.activityTypeDao().getAll()
        val centers = footprints.associateWith { it.shareCenter() }

        val uniquePlaceKeys = footprints.map { it.placeID ?: ShareFormat.displayPlace(it) }.toSet()
        val recorded = transports.sumOf { max(0.0, it.distance) }
        val ordered = footprints.sortedBy { it.startTime }.mapNotNull { centers[it]?.takeIf { p -> p.isRenderable } }
        val inferred = ordered.zipWithNext { a, b -> distanceMeters(a, b) }.sum()
        val totalMileage = max(recorded, inferred)

        val heat = topLocations(footprints.mapNotNull { centers[it] }, precision = 2)
        val maxIntensity = heat.maxOfOrNull { it.second } ?: 1
        val heatPoints = heat.map { ShareHeatPoint(it.first, it.second, maxIntensity) }
        val map = ShareMapSnapshotter.snapshot(
            heatPoints.map { it.point },
            heatPoints = heatPoints,
            drawsOverlays = false
        )
        return SharePayload(
            kind = ShareCardKind.STATS,
            title = "我的生活总结",
            subtitle = "每一次停留，都成为了生活的一部分",
            rangeText = rangeText,
            locationText = ShareFormat.locationText(footprints),
            contentMap = map,
            coordinates = footprints.mapNotNull { centers[it] },
            stats = listOf(
                ShareStatEntry("足迹", "${footprints.size}", "次记录"),
                ShareStatEntry("地点", "${uniquePlaceKeys.size}", "个生活节点"),
                ShareStatEntry("里程", ShareFormat.mileage(totalMileage))
            ),
            placeRankings = placeRankings(footprints, places),
            activityRankings = activityRankings(footprints, activities)
        )
    }

    /** iOS getTopLocations: grid clustering, top 200. */
    fun topLocations(points: List<GeoPoint>, precision: Int): List<Pair<GeoPoint, Int>> {
        val factor = 10.0.pow(precision)
        val groups = linkedMapOf<String, Pair<GeoPoint, Int>>()
        points.forEach { p ->
            val lat = Math.round(p.lat * factor) / factor
            val lon = Math.round(p.lon * factor) / factor
            val key = "$lat,$lon"
            val existing = groups[key]
            groups[key] = GeoPoint(lat, lon) to ((existing?.second ?: 0) + 1)
        }
        return groups.entries.sortedWith(compareByDescending<Map.Entry<String, Pair<GeoPoint, Int>>> { it.value.second }.thenBy { it.key })
            .take(200).map { it.value }
    }

    private fun placeRankings(footprints: List<FootprintEntity>, places: List<PlaceEntity>): List<ShareRankingEntry> {
        class Agg(val title: String, var country: String?, var count: Int = 0, var duration: Long = 0)
        val multipleCountries = footprints.mapNotNull { it.countryCode?.trim()?.takeIf(String::isNotEmpty) }.toSet().size > 1
        val cityKeys = footprints.mapNotNull { fp ->
            fp.cityName?.trim()?.takeIf { it.isNotEmpty() }?.let { "${fp.countryCode.orEmpty()}|$it" }
        }.toSet()
        val ranksPlaces = cityKeys.size <= 1
        val placesById = places.associateBy { it.placeID }
        val groups = linkedMapOf<String, Agg>()
        footprints.forEach { fp ->
            val title: String
            val key: String
            if (ranksPlaces) {
                val place = fp.placeID?.let(placesById::get)?.takeIf { it.name.isNotBlank() }
                if (place != null) {
                    title = place.name; key = place.placeID
                } else {
                    title = ShareFormat.displayPlace(fp); key = title
                }
                if (title.isEmpty() || title == "一个生活现场") return@forEach
            } else {
                val city = fp.cityName?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
                title = city; key = "${fp.countryCode.orEmpty()}|$city"
            }
            val agg = groups.getOrPut(key) { Agg(title, fp.countryName) }
            if (agg.country.isNullOrEmpty()) agg.country = fp.countryName
            agg.count += 1
            agg.duration += fp.duration
        }
        return groups.values
            .sortedWith(compareByDescending<Agg> { it.count }.thenByDescending { it.duration })
            .take(3)
            .map { item ->
                ShareRankingEntry(
                    title = if (multipleCountries) listOfNotNull(item.country?.trim(), item.title.trim())
                        .filter { it.isNotEmpty() }.joinToString(" ") else item.title,
                    value = "${item.count}个足迹",
                    icon = "place",
                    color = SHARE_APP_ACCENT
                )
            }
    }

    private fun activityRankings(footprints: List<FootprintEntity>, activities: List<ActivityTypeEntity>): List<ShareRankingEntry> {
        val groups = linkedMapOf<String, Pair<ActivityTypeEntity, Int>>()
        footprints.forEach { fp ->
            val activity = activityFor(fp, activities) ?: return@forEach
            if (activity.name == "交通") return@forEach
            val existing = groups[activity.name]
            groups[activity.name] = activity to ((existing?.second ?: 0) + 1)
        }
        return groups.entries.sortedByDescending { it.value.second }.take(3).map { (name, agg) ->
            ShareRankingEntry(
                title = name,
                value = "${agg.second}个足迹",
                icon = agg.first.icon,
                color = parseHexColor(agg.first.colorHex) ?: SHARE_APP_ACCENT
            )
        }
    }

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
