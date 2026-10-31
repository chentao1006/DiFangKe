@file:Suppress("DEPRECATION")

package com.ct106.difangke.ui.screens.statistics

import android.graphics.Bitmap
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.entity.FootprintEntity
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.data.model.TransportType
import com.ct106.difangke.service.LocationTrackingService
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.createTransportOverviewIconBitmap
import com.ct106.difangke.ui.screens.main.loadPinThumbnail
import com.ct106.difangke.ui.share.photoUris
import com.ct106.difangke.ui.share.shareCenter
import com.ct106.difangke.ui.theme.DfkAccent
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptor
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
import com.tencent.tencentmap.mapsdk.maps.model.CameraPosition
import com.tencent.tencentmap.mapsdk.maps.model.CircleOptions
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.Marker
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The Review ("回顾") life map: iOS DFKMapView in review mode
 * (`condensesTransportOverview && clustersPlacesByMapScale`).
 *
 * Places are merged by [reviewIntegratedPlaceKey] and clustered on a 7×7 grid
 * of the visible region; transport is drawn as de-duplicated routes, fused
 * trajectory points and per-type icons. When interactive and zoomed in to
 * [AppConfig.REVIEW_MAP_TRAJECTORY_PATH_MAX_SPAN], only the real paths inside
 * the visible region are drawn. Everything is redrawn only when [revision],
 * dark mode, the clustering region (interactive camera idle) or loaded pin
 * photos change.
 */
@Composable
fun ReviewMapView(
    footprints: List<FootprintEntity>,
    places: List<PlaceEntity>,
    routes: List<ReviewMapRoute>,
    overviewPoints: List<ReviewTransportOverviewPoint>,
    bounds: ReviewMapBounds?,
    interactive: Boolean,
    revision: Any,
    modifier: Modifier = Modifier,
    topContentPadding: Dp = 0.dp,
    bottomContentPadding: Dp = 0.dp,
    showsUserLocation: Boolean = false,
    onFootprintsTap: (List<FootprintEntity>) -> Unit = {}
) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val density = LocalDensity.current
    val topPaddingPx = with(density) { topContentPadding.roundToPx() }
    val bottomPaddingPx = with(density) { bottomContentPadding.roundToPx() }
    val accent = DfkAccent.toArgb()

    var prepared by remember { mutableStateOf<ReviewMapPrepared?>(null) }
    // iOS transportOverviewVisibleRegion / placeClusterVisibleRegion: nil until the camera settles.
    var visibleRegion by remember { mutableStateOf<ReviewMapRegion?>(null) }
    var display by remember { mutableStateOf<ReviewMapDisplay?>(null) }
    var photoBitmaps by remember { mutableStateOf<Map<String, Bitmap>>(emptyMap()) }

    val holder = remember { ReviewMapHolder() }
    holder.interactive = interactive
    holder.onFootprintsTap = onFootprintsTap
    holder.onVisibleRegion = { region -> if (region != visibleRegion) visibleRegion = region }

    LaunchedEffect(revision) {
        visibleRegion = null
        prepared = withContext(Dispatchers.Default) {
            prepareReviewMap(footprints, places, routes, overviewPoints, bounds)
        }
    }

    LaunchedEffect(prepared, visibleRegion, interactive) {
        val source = prepared ?: return@LaunchedEffect
        val region = if (interactive) visibleRegion else null
        display = withContext(Dispatchers.Default) { buildReviewMapDisplay(source, region, interactive) }
    }

    // Latest photo of every single-place pin, as on the home map (loadPinThumbnail).
    LaunchedEffect(display) {
        val uris = display?.markers?.mapNotNull { it.photoUri }?.distinct().orEmpty()
        val missing = uris.filter { it !in photoBitmaps }
        if (missing.isEmpty()) return@LaunchedEffect
        val loaded = withContext(Dispatchers.IO) {
            missing.mapNotNull { uri -> loadPinThumbnail(context, uri)?.let { uri to it } }.toMap()
        }
        if (loaded.isNotEmpty()) photoBitmaps = photoBitmaps + loaded
    }

    val trackingState by LocationTrackingService.stateFlow.collectAsState()
    val userLocation = if (!showsUserLocation) null else when (val state = trackingState) {
        is LocationTrackingService.TrackingState.Tracking ->
            if (state.lat != null && state.lon != null) LatLng(state.lat, state.lon) else null
        is LocationTrackingService.TrackingState.OngoingStay -> LatLng(state.lat, state.lon)
        LocationTrackingService.TrackingState.Idle -> null
    }?.takeIf { it.latitude.isFinite() && it.longitude.isFinite() && it.latitude != 0.0 }

    Box(modifier = modifier) {
        AndroidView(
            factory = { ctx -> TextureMapView(ctx).apply { onResume() } },
            modifier = Modifier.fillMaxSize(),
            onRelease = { view ->
                view.onPause()
                view.onDestroy()
            }
        ) { view ->
            val map = view.map
            if (!holder.listenerInstalled) {
                holder.listenerInstalled = true
                map.setOnCameraChangeListener(object : TencentMap.OnCameraChangeListener {
                    override fun onCameraChange(p0: CameraPosition?) {}
                    override fun onCameraChangeFinished(p0: CameraPosition?) {
                        // iOS onMapCameraChange(frequency: .onEnd): re-cluster when the camera settles.
                        if (!holder.interactive) return
                        view.post {
                            val visible = runCatching { map.projection.visibleRegion.latLngBounds }.getOrNull()
                                ?: return@post
                            holder.onVisibleRegion(ReviewMapRegion.from(visible))
                        }
                    }
                })
            }
            if (holder.lastInteractive != interactive) {
                holder.lastInteractive = interactive
                map.uiSettings.apply {
                    isZoomControlsEnabled = false
                    isMyLocationButtonEnabled = false
                    if (interactive) {
                        isScrollGesturesEnabled = true
                        isZoomGesturesEnabled = true
                        isRotateGesturesEnabled = false
                        isTiltGesturesEnabled = false
                    } else {
                        setAllGesturesEnabled(false)
                    }
                }
            }
            if (holder.lastDark != isDark) {
                map.mapType = if (isDark) TencentMap.MAP_TYPE_DARK else TencentMap.MAP_TYPE_NORMAL
            }

            val currentDisplay = display
            val needsRedraw = holder.lastDisplay !== currentDisplay ||
                holder.lastPhotos != photoBitmaps || holder.lastDark != isDark
            holder.lastDark = isDark
            if (needsRedraw) {
                holder.lastDisplay = currentDisplay
                holder.lastPhotos = photoBitmaps
                map.clear()
                holder.userMarker = null
                holder.lastUser = null
                if (currentDisplay != null) {
                    drawReviewMap(map, view, currentDisplay, isDark, accent, photoBitmaps, holder)
                }
            }

            if (holder.lastUser != userLocation || (userLocation != null && holder.userMarker == null)) {
                holder.lastUser = userLocation
                holder.userMarker?.remove()
                holder.userMarker = userLocation?.let {
                    // Same user dot as the home map (TimelineMapView).
                    map.addMarker(
                        MarkerOptions()
                            .position(it)
                            .anchor(0.5f, 0.5f)
                            .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))
                            .zIndex(200f)
                            .title("当前位置")
                    )
                }
            }

            val fitKey = "$revision:$topPaddingPx:$bottomPaddingPx"
            val fitBounds = bounds
            if (fitBounds != null && holder.lastFitKey != fitKey) {
                holder.lastFitKey = fitKey
                val apply = { fitReviewRegion(map, view, fitBounds.reviewRegion(), topPaddingPx, bottomPaddingPx) }
                if (view.width > 0 && view.height > 0) apply() else map.addOnMapLoadedCallback { apply() }
            }
        }

        if (!interactive) {
            // iOS `.allowsHitTesting(false)`: the hero map never receives touches,
            // so vertical drags and taps fall through to the parent list/card.
            Box(
                Modifier
                    .matchParentSize()
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) awaitPointerEvent()
                        }
                    }
            )
        }
    }
}

// region Model

private class ReviewMapHolder {
    var listenerInstalled = false
    var interactive = false
    var lastInteractive: Boolean? = null
    var lastDark: Boolean? = null
    var lastDisplay: ReviewMapDisplay? = null
    var lastPhotos: Map<String, Bitmap>? = null
    var lastFitKey: String? = null
    var lastUser: LatLng? = null
    var userMarker: Marker? = null
    var onFootprintsTap: (List<FootprintEntity>) -> Unit = {}
    var onVisibleRegion: (ReviewMapRegion) -> Unit = {}
}

/** MKCoordinateRegion equivalent. */
private data class ReviewMapRegion(
    val centerLatitude: Double,
    val centerLongitude: Double,
    val latitudeDelta: Double,
    val longitudeDelta: Double
) {
    val maxSpan: Double get() = max(latitudeDelta, longitudeDelta)

    /** The region grown by 8% on each side (iOS visible-point filtering). */
    fun paddedContains(latitude: Double, longitude: Double): Boolean =
        latitude in paddedMinLatitude..paddedMaxLatitude && longitude in paddedMinLongitude..paddedMaxLongitude

    val paddedMinLatitude: Double get() = centerLatitude - latitudeDelta / 2 - latitudeDelta * 0.08
    val paddedMaxLatitude: Double get() = centerLatitude + latitudeDelta / 2 + latitudeDelta * 0.08
    val paddedMinLongitude: Double get() = centerLongitude - longitudeDelta / 2 - longitudeDelta * 0.08
    val paddedMaxLongitude: Double get() = centerLongitude + longitudeDelta / 2 + longitudeDelta * 0.08

    companion object {
        fun from(bounds: LatLngBounds): ReviewMapRegion {
            val ne = bounds.northeast
            val sw = bounds.southwest
            var longitudeDelta = ne.longitude - sw.longitude
            if (longitudeDelta < 0) longitudeDelta += 360.0
            return ReviewMapRegion(
                centerLatitude = (ne.latitude + sw.latitude) / 2,
                centerLongitude = sw.longitude + longitudeDelta / 2,
                latitudeDelta = ne.latitude - sw.latitude,
                longitudeDelta = longitudeDelta
            )
        }
    }
}

/** iOS HistoryStatisticsView.mapRegion(for:): the review camera region for the range's bounds. */
private fun ReviewMapBounds.reviewRegion(): ReviewMapRegion = ReviewMapRegion(
    centerLatitude = (minimumLatitude + maximumLatitude) / 2,
    centerLongitude = (minimumLongitude + maximumLongitude) / 2,
    latitudeDelta = max(0.015, (maximumLatitude - minimumLatitude) * 1.6),
    longitudeDelta = max(0.015, (maximumLongitude - minimumLongitude) * 1.6)
)

/** iOS AggregatedFootprint as used by the review map. */
private class ReviewPlaceAggregate(
    val id: String,
    val latitude: Double,
    val longitude: Double,
    val totalDuration: Long,
    val representative: FootprintEntity,
    /** Oldest first. */
    val footprints: List<FootprintEntity>,
    val placeCount: Int
)

/** One transport record's distance midpoint for the per-type icon grid. */
private class ReviewRouteMidpoint(
    val type: TransportType,
    val midpoint: LatLng,
    val travelsWest: Boolean
)

private class ReviewMapPrepared(
    val places: List<ReviewPlaceAggregate>,
    /** iOS renderedTransportSegments, with each segment's extent for visibility tests. */
    val segments: List<ReviewSegment>,
    val routeMidpoints: List<ReviewRouteMidpoint>,
    /** iOS fusedTransportPoints. */
    val fusedPoints: List<ReviewTransportOverviewPoint>,
    /** iOS placeClusterRegion. */
    val initialRegion: ReviewMapRegion?
)

private class ReviewSegment(
    val coordinates: List<LatLng>,
    val minLatitude: Double,
    val maxLatitude: Double,
    val minLongitude: Double,
    val maxLongitude: Double
)

/** iOS DFKTransportIconPoint. */
private class ReviewTransportIconPoint(
    val latitude: Double,
    val longitude: Double,
    val type: TransportType,
    val travelsWest: Boolean
)

private class ReviewMapDisplay(
    val interactive: Boolean,
    val markers: List<FootprintMapMarker>,
    val footprintsByMarkerID: Map<String, List<FootprintEntity>>,
    val segments: List<List<LatLng>>,
    /** iOS showsDetailedTransportPaths. */
    val showsDetailedPaths: Boolean,
    val overviewPoints: List<ReviewTransportOverviewPoint>,
    val iconPoints: List<ReviewTransportIconPoint>
)

// endregion

// region Preparation (off the main thread)

private fun prepareReviewMap(
    footprints: List<FootprintEntity>,
    places: List<PlaceEntity>,
    routes: List<ReviewMapRoute>,
    overviewPoints: List<ReviewTransportOverviewPoint>,
    bounds: ReviewMapBounds?
): ReviewMapPrepared {
    val placeAggregates = aggregateReviewPlaces(footprints, places)
    val renderableRoutes = routes.mapNotNull { route ->
        val segments = route.segments.map { segment -> segment.filter { it.isRenderableReviewCoordinate() } }
        if (segments.sumOf { it.size } >= 2) route to segments else null
    }
    return ReviewMapPrepared(
        places = placeAggregates,
        segments = renderedReviewSegments(renderableRoutes.flatMap { it.second }),
        routeMidpoints = renderableRoutes.mapNotNull { (route, segments) ->
            val coordinates = segments.flatten()
            val midpoint = coordinates.distanceMidpoint() ?: return@mapNotNull null
            ReviewRouteMidpoint(route.type, midpoint, coordinates.travelsWest())
        },
        fusedPoints = overviewPoints.ifEmpty { fuseRoutePoints(renderableRoutes.flatMap { it.second }) },
        initialRegion = bounds?.reviewRegion()
    )
}

/** iOS placeAggregatedFootprints with clustersPlacesByMapScale: duration-weighted place buckets. */
private fun aggregateReviewPlaces(
    footprints: List<FootprintEntity>,
    places: List<PlaceEntity>
): List<ReviewPlaceAggregate> {
    class Bucket(
        var weightedLatitude: Double,
        var weightedLongitude: Double,
        var totalWeight: Long,
        var totalDuration: Long,
        var representative: FootprintEntity,
        val footprints: MutableList<FootprintEntity>
    )

    val placesById = places.associateBy { it.placeID }
    val buckets = linkedMapOf<String, Bucket>()
    footprints.forEach { footprint ->
        val center = footprint.shareCenter() ?: return@forEach
        if (!center.lat.isFinite() || !center.lon.isFinite() ||
            center.lat !in -90.0..90.0 || center.lon !in -180.0..180.0
        ) return@forEach
        val weight = max(footprint.duration, 1L)
        val key = reviewIntegratedPlaceKey(footprint, placesById)
        val bucket = buckets[key]
        if (bucket == null) {
            buckets[key] = Bucket(
                weightedLatitude = center.lat * weight,
                weightedLongitude = center.lon * weight,
                totalWeight = weight,
                totalDuration = footprint.duration,
                representative = footprint,
                footprints = mutableListOf(footprint)
            )
        } else {
            bucket.weightedLatitude += center.lat * weight
            bucket.weightedLongitude += center.lon * weight
            bucket.totalWeight += weight
            bucket.totalDuration += footprint.duration
            bucket.footprints.add(footprint)
            if (footprint.duration > bucket.representative.duration) bucket.representative = footprint
        }
    }
    return buckets.map { (key, bucket) ->
        val divisor = max(bucket.totalWeight, 1L).toDouble()
        ReviewPlaceAggregate(
            id = key,
            latitude = bucket.weightedLatitude / divisor,
            longitude = bucket.weightedLongitude / divisor,
            totalDuration = bucket.totalDuration,
            representative = bucket.representative,
            footprints = bucket.footprints.sortedBy { it.startTime },
            placeCount = 1
        )
    }
}

/** iOS renderedTransportSegments: drop routes whose 24-sample shape repeats forward or reversed. */
private fun renderedReviewSegments(segments: List<List<LatLng>>): List<ReviewSegment> {
    val seen = HashSet<String>()
    val result = mutableListOf<ReviewSegment>()
    for (coordinates in segments) {
        if (coordinates.size < 2) continue
        val step = max(1, coordinates.size / 24)
        val sampled = (coordinates.indices step step).map { coordinates[it] }.toMutableList()
        val last = coordinates.last()
        if (sampled.last().latitude != last.latitude || sampled.last().longitude != last.longitude) {
            sampled.add(last)
        }
        fun keyOf(points: List<LatLng>) = points.joinToString(";") {
            String.format(Locale.US, "%.3f,%.3f", it.latitude, it.longitude)
        }
        val forward = keyOf(sampled)
        val reverse = keyOf(sampled.asReversed())
        // Android routes carry no inferred/dashed gaps, so every segment is solid ("s").
        val key = "s:" + if (forward <= reverse) forward else reverse
        if (!seen.add(key)) continue
        result.add(
            ReviewSegment(
                coordinates = coordinates,
                minLatitude = coordinates.minOf { it.latitude },
                maxLatitude = coordinates.maxOf { it.latitude },
                minLongitude = coordinates.minOf { it.longitude },
                maxLongitude = coordinates.maxOf { it.longitude }
            )
        )
    }
    return result
}

/** iOS fusedTransportPoints fallback: fuse every real route sample on the base trajectory cell. */
private fun fuseRoutePoints(segments: List<List<LatLng>>): List<ReviewTransportOverviewPoint> {
    val cellSize = AppConfig.REVIEW_MAP_TRAJECTORY_BASE_CELL_DEGREES
    class Bucket(var latitude: Double = 0.0, var longitude: Double = 0.0, var count: Int = 0)
    val buckets = linkedMapOf<String, Bucket>()
    segments.forEach { segment ->
        segment.forEach { point ->
            val x = (point.longitude / cellSize).roundToLong()
            val y = (point.latitude / cellSize).roundToLong()
            val bucket = buckets.getOrPut("$x:$y") { Bucket() }
            bucket.latitude += point.latitude
            bucket.longitude += point.longitude
            bucket.count += 1
        }
    }
    return buckets.map { (key, bucket) ->
        ReviewTransportOverviewPoint(
            id = key,
            latitude = bucket.latitude / bucket.count,
            longitude = bucket.longitude / bucket.count,
            intensity = bucket.count
        )
    }
}

// endregion

// region Display (re-run when the visible region settles)

private fun buildReviewMapDisplay(
    prepared: ReviewMapPrepared,
    visibleRegion: ReviewMapRegion?,
    interactive: Boolean
): ReviewMapDisplay {
    val clusterRegion = visibleRegion ?: prepared.initialRegion
    val clustered = clusterReviewPlaces(prepared.places, clusterRegion)
    val markers = clustered.map { aggregate ->
        FootprintMapMarker(
            id = aggregate.id,
            latitude = aggregate.latitude,
            longitude = aggregate.longitude,
            // iOS DFKReviewPlaceMapMarker: "mappin" glyph, no duration banner.
            icon = "place",
            colorHex = REVIEW_ACCENT_HEX,
            durationSeconds = 0L,
            memberIDs = aggregate.footprints.map { it.footprintID },
            // Single place: its latest photo (same pick as buildFootprintMapMarkers).
            photoUri = if (aggregate.placeCount == 1) {
                aggregate.footprints.sortedByDescending { it.startTime }
                    .firstNotNullOfOrNull { it.photoUris().lastOrNull() }
            } else null,
            scale = REVIEW_PIN_SCALE,
            centerText = if (aggregate.placeCount > 1) aggregate.placeCount.toString() else null
        )
    }

    val showsDetailedPaths = interactive && visibleRegion != null &&
        visibleRegion.maxSpan <= AppConfig.REVIEW_MAP_TRAJECTORY_PATH_MAX_SPAN
    val segments = if (showsDetailedPaths && visibleRegion != null) {
        // iOS visibleDetailedTransportSegments (dashed segments never exist on Android).
        prepared.segments.filter { segment ->
            segment.maxLatitude >= visibleRegion.paddedMinLatitude &&
                segment.minLatitude <= visibleRegion.paddedMaxLatitude &&
                segment.maxLongitude >= visibleRegion.paddedMinLongitude &&
                segment.minLongitude <= visibleRegion.paddedMaxLongitude
        }
    } else {
        prepared.segments
    }

    return ReviewMapDisplay(
        interactive = interactive,
        markers = markers,
        footprintsByMarkerID = clustered.associate { it.id to it.footprints },
        segments = segments.map { it.coordinates },
        showsDetailedPaths = showsDetailedPaths,
        overviewPoints = if (showsDetailedPaths) emptyList() else displayedOverviewPoints(
            prepared.fusedPoints,
            if (interactive) visibleRegion else null
        ),
        iconPoints = transportIconPoints(prepared.routeMidpoints, clusterRegion)
    )
}

/** iOS aggregatedFootprints: cluster places on a 7×7 grid of the region. */
private fun clusterReviewPlaces(
    places: List<ReviewPlaceAggregate>,
    region: ReviewMapRegion?
): List<ReviewPlaceAggregate> {
    if (region == null || places.size <= 1) return places
    val latitudeCell = max(region.latitudeDelta / 7, 0.000_001)
    val longitudeCell = max(region.longitudeDelta / 7, 0.000_001)
    val latitudeOrigin = region.centerLatitude - region.latitudeDelta / 2
    val longitudeOrigin = region.centerLongitude - region.longitudeDelta / 2
    val grouped = places.groupBy { place ->
        val latitudeIndex = floor((place.latitude - latitudeOrigin) / latitudeCell).toLong()
        val longitudeIndex = floor((place.longitude - longitudeOrigin) / longitudeCell).toLong()
        "$latitudeIndex:$longitudeIndex"
    }
    return grouped.keys.sorted().mapNotNull { key ->
        val members = grouped[key] ?: return@mapNotNull null
        val first = members.firstOrNull() ?: return@mapNotNull null
        if (members.size == 1) return@mapNotNull first
        val totalWeight = members.sumOf { max(it.totalDuration, 1L).toDouble() }
        ReviewPlaceAggregate(
            id = "cluster:$key:" + members.map { it.id }.sorted().joinToString("|"),
            latitude = members.sumOf { it.latitude * max(it.totalDuration, 1L) } / totalWeight,
            longitude = members.sumOf { it.longitude * max(it.totalDuration, 1L) } / totalWeight,
            totalDuration = members.sumOf { it.totalDuration },
            representative = members.maxByOrNull { it.totalDuration }?.representative ?: first.representative,
            footprints = members.flatMap { it.footprints }.sortedBy { it.startTime },
            placeCount = members.sumOf { it.placeCount }
        )
    }
}

/** iOS displayedTransportOverviewPoints: visible points re-bucketed by span / 110 when interactive. */
private fun displayedOverviewPoints(
    points: List<ReviewTransportOverviewPoint>,
    region: ReviewMapRegion?
): List<ReviewTransportOverviewPoint> {
    if (region == null || points.isEmpty()) return points
    val visible = points.filter { region.paddedContains(it.latitude, it.longitude) }
    val baseCell = AppConfig.REVIEW_MAP_TRAJECTORY_BASE_CELL_DEGREES
    val adaptiveCell = max(baseCell, region.maxSpan / 110)
    if (adaptiveCell <= baseCell) return visible

    class Bucket(var latitude: Double = 0.0, var longitude: Double = 0.0, var intensity: Int = 0)
    val buckets = linkedMapOf<String, Bucket>()
    visible.forEach { point ->
        val x = (point.longitude / adaptiveCell).roundToLong()
        val y = (point.latitude / adaptiveCell).roundToLong()
        val bucket = buckets.getOrPut("$x:$y") { Bucket() }
        bucket.latitude += point.latitude * point.intensity
        bucket.longitude += point.longitude * point.intensity
        bucket.intensity += point.intensity
    }
    return buckets.mapNotNull { (key, bucket) ->
        if (bucket.intensity <= 0) return@mapNotNull null
        ReviewTransportOverviewPoint(
            id = "adaptive:$key",
            latitude = bucket.latitude / bucket.intensity,
            longitude = bucket.longitude / bucket.intensity,
            intensity = bucket.intensity
        )
    }
}

/** iOS displayedTransportIconPoints: one icon per transport type per 1/7 region cell. */
private fun transportIconPoints(
    midpoints: List<ReviewRouteMidpoint>,
    region: ReviewMapRegion?
): List<ReviewTransportIconPoint> {
    val latitudeCell = max((region?.latitudeDelta ?: 0.05) / 7, 0.000_01)
    val longitudeCell = max((region?.longitudeDelta ?: 0.05) / 7, 0.000_01)

    class Bucket(
        var latitude: Double,
        var longitude: Double,
        var count: Int,
        val type: TransportType,
        var westwardCount: Int
    )
    val buckets = linkedMapOf<String, Bucket>()
    midpoints.forEach { item ->
        val x = (item.midpoint.longitude / longitudeCell).roundToLong()
        val y = (item.midpoint.latitude / latitudeCell).roundToLong()
        val key = "${item.type.raw}:$x:$y"
        val bucket = buckets[key]
        if (bucket == null) {
            buckets[key] = Bucket(
                item.midpoint.latitude,
                item.midpoint.longitude,
                1,
                item.type,
                if (item.travelsWest) 1 else 0
            )
        } else {
            bucket.latitude += item.midpoint.latitude
            bucket.longitude += item.midpoint.longitude
            bucket.count += 1
            if (item.travelsWest) bucket.westwardCount += 1
        }
    }
    return buckets.values.map { bucket ->
        ReviewTransportIconPoint(
            latitude = bucket.latitude / bucket.count,
            longitude = bucket.longitude / bucket.count,
            type = bucket.type,
            travelsWest = bucket.westwardCount * 2 > bucket.count
        )
    }
}

// endregion

// region Drawing

private fun drawReviewMap(
    map: TencentMap,
    view: TextureMapView,
    display: ReviewMapDisplay,
    isDark: Boolean,
    accent: Int,
    photoBitmaps: Map<String, Bitmap>,
    holder: ReviewMapHolder
) {
    val density = view.resources.displayMetrics.density

    // Routes: overview 2.5pt @ 0.65, detailed real paths 2.2pt @ 0.68 (iOS transportMapContent).
    val lineWidth = (if (display.showsDetailedPaths) 2.2f else 2.5f) * density
    val lineColor = withAlpha(accent, if (display.showsDetailedPaths) 0.68 else 0.65)
    display.segments.forEach { segment ->
        if (segment.size >= 2) {
            map.addPolyline(PolylineOptions().addAll(segment).width(lineWidth).color(lineColor))
        }
    }

    if (display.interactive) {
        // iOS MapCircle: radius in metres, min(7, 3.5 + log2(intensity)).
        display.overviewPoints.forEach { point ->
            val level = log2Intensity(point.intensity)
            map.addCircle(
                CircleOptions()
                    .center(LatLng(point.latitude, point.longitude))
                    .radius(min(7.0, 3.5 + level))
                    .fillColor(withAlpha(accent, min(0.72, 0.36 + level * 0.06)))
                    .strokeColor(android.graphics.Color.TRANSPARENT)
                    .strokeWidth(0f)
            )
        }
    } else {
        // iOS snapshot: screen-sized dots, diameter min(5.5, 2.5 + log2 * 0.7) pt.
        val dotCache = HashMap<Int, BitmapDescriptor>()
        display.overviewPoints.forEach { point ->
            val level = log2Intensity(point.intensity)
            val diameterPx = (min(5.5, 2.5 + level * 0.7) * density).roundToInt().coerceAtLeast(2)
            val alpha = min(0.72, 0.34 + level * 0.06)
            val cacheKey = diameterPx * 1000 + (alpha * 100).roundToInt()
            val descriptor = dotCache.getOrPut(cacheKey) {
                BitmapDescriptorFactory.fromBitmap(overviewDotBitmap(diameterPx, withAlpha(accent, alpha)))
            }
            map.addMarker(
                MarkerOptions()
                    .position(LatLng(point.latitude, point.longitude))
                    .icon(descriptor)
                    .anchor(0.5f, 0.5f)
                    .zIndex(1f)
            )
        }
    }

    // Transport type icons: 24pt circle, 1.5pt accent stroke, 12pt glyph.
    val iconCache = HashMap<String, BitmapDescriptor>()
    display.iconPoints.forEach { point ->
        val descriptor = iconCache.getOrPut("${point.type.raw}:${point.travelsWest}") {
            BitmapDescriptorFactory.fromBitmap(
                createTransportOverviewIconBitmap(
                    icon = point.type.icon,
                    isDark = isDark,
                    flipped = point.travelsWest,
                    diameterPx = (24 * density).roundToInt(),
                    iconSizePx = 12 * density,
                    strokeWidthPx = 1.5f * density,
                    accentColor = accent
                )
            )
        }
        map.addMarker(
            MarkerOptions()
                .position(LatLng(point.latitude, point.longitude))
                .icon(descriptor)
                .anchor(0.5f, 0.5f)
                .zIndex(5f)
        )
    }

    if (display.markers.isNotEmpty()) {
        val onMarkerClick: ((String) -> Unit)? = if (display.interactive) {
            { id -> display.footprintsByMarkerID[id]?.let { holder.onFootprintsTap(it) } }
        } else {
            null
        }
        map.addFootprintMarkers(
            display.markers,
            isDark = isDark,
            onMarkerClick = onMarkerClick,
            photoBitmaps = photoBitmaps
        )
    }
}

private fun fitReviewRegion(
    map: TencentMap,
    view: TextureMapView,
    region: ReviewMapRegion,
    topPaddingPx: Int,
    bottomPaddingPx: Int
) {
    runCatching {
        val bounds = LatLngBounds.builder().apply {
            include(LatLng(region.centerLatitude - region.latitudeDelta / 2, region.centerLongitude - region.longitudeDelta / 2))
            include(LatLng(region.centerLatitude + region.latitudeDelta / 2, region.centerLongitude + region.longitudeDelta / 2))
        }.build()
        // Keep at least a sliver of map for the region when the insets are large.
        val maxVertical = (view.height * 0.85f).toInt()
        val top = topPaddingPx.coerceAtMost(maxVertical / 2)
        val bottom = bottomPaddingPx.coerceAtMost(maxVertical - top)
        map.setPadding(0, 0, 0, 0)
        map.moveCamera(CameraUpdateFactory.newLatLngBoundsRect(bounds, 0, 0, top, bottom))
    }
}

private fun overviewDotBitmap(diameterPx: Int, color: Int): Bitmap {
    val bitmap = Bitmap.createBitmap(diameterPx, diameterPx, Bitmap.Config.ARGB_8888)
    val radius = diameterPx / 2f
    android.graphics.Canvas(bitmap).drawCircle(
        radius,
        radius,
        radius,
        android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    )
    return bitmap
}

// endregion

// region Geometry helpers

/** iOS DFKReviewPlaceMapMarker size 36 relative to the standard interactive pin (25 × 1.32). */
private const val REVIEW_PIN_SCALE = 36f / (25f * 1.32f)
private val REVIEW_ACCENT_HEX = String.format(Locale.US, "#%06X", DfkAccent.toArgb() and 0xFFFFFF)

private fun log2Intensity(intensity: Int): Double = ln(max(1, intensity).toDouble()) / ln(2.0)

private fun withAlpha(color: Int, alpha: Double): Int =
    ((alpha * 255).roundToInt().coerceIn(0, 255) shl 24) or (color and 0x00FFFFFF)

private fun LatLng.isRenderableReviewCoordinate(): Boolean =
    latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0

/** iOS `[CLLocationCoordinate2D].travelsWest`. */
private fun List<LatLng>.travelsWest(): Boolean {
    if (size < 2) return false
    var longitudeDelta = last().longitude - first().longitude
    if (longitudeDelta > 180) longitudeDelta -= 360
    if (longitudeDelta < -180) longitudeDelta += 360
    return longitudeDelta < 0
}

/** iOS `[CLLocationCoordinate2D].distanceMidpoint`: the point halfway along the path length. */
private fun List<LatLng>.distanceMidpoint(): LatLng? {
    if (size < 2) return firstOrNull()
    val cumulative = DoubleArray(size)
    val result = FloatArray(1)
    for (i in 0 until size - 1) {
        android.location.Location.distanceBetween(
            this[i].latitude, this[i].longitude, this[i + 1].latitude, this[i + 1].longitude, result
        )
        cumulative[i + 1] = cumulative[i] + result[0]
    }
    val total = cumulative.last()
    if (total == 0.0) return this[size / 2]
    val half = total / 2
    for (i in 0 until size - 1) {
        if (half >= cumulative[i] && half <= cumulative[i + 1]) {
            val segment = cumulative[i + 1] - cumulative[i]
            val fraction = if (segment > 0) (half - cumulative[i]) / segment else 0.0
            return LatLng(
                this[i].latitude + (this[i + 1].latitude - this[i].latitude) * fraction,
                this[i].longitude + (this[i + 1].longitude - this[i].longitude) * fraction
            )
        }
    }
    return this[size / 2]
}

// endregion
