package com.ct106.difangke.ui.screens.main

import android.graphics.Bitmap
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import com.ct106.difangke.data.db.entity.PlaceEntity
import com.ct106.difangke.ui.components.FootprintMapMarker
import com.ct106.difangke.ui.components.addFootprintMarkers
import com.ct106.difangke.ui.components.addImportantPlaceCircles
import com.tencent.tencentmap.mapsdk.maps.CameraUpdateFactory
import com.tencent.tencentmap.mapsdk.maps.TencentMap
import com.tencent.tencentmap.mapsdk.maps.TextureMapView
import com.tencent.tencentmap.mapsdk.maps.model.BitmapDescriptorFactory
import com.tencent.tencentmap.mapsdk.maps.model.CameraPosition
import com.tencent.tencentmap.mapsdk.maps.model.LatLng
import com.tencent.tencentmap.mapsdk.maps.model.LatLngBounds
import com.tencent.tencentmap.mapsdk.maps.model.MarkerOptions
import com.tencent.tencentmap.mapsdk.maps.model.PolylineOptions
import com.tencent.tencentmap.mapsdk.maps.model.TencentMapGestureListener

/** Everything drawn on the home map. A new instance triggers one redraw. */
data class TimelineMapOverlays(
    val markers: List<FootprintMapMarker>,
    /** Route JSON arrays ([[lat,lon],...]); [0,0] separates segments. */
    val routes: List<String>,
    val places: List<PlaceEntity>
)

/**
 * A camera framing request. The map applies it once per distinct [key];
 * [skipMove] records the key without moving (iOS: dismissing a detail sheet
 * restores the timeline without jumping the camera).
 */
data class TimelineCameraFit(
    val key: String,
    val points: List<LatLng>,
    val singlePointZoom: Float = 15f,
    val skipMove: Boolean = false
)

private class TimelineMapHolder {
    var lastOverlays: TimelineMapOverlays? = null
    var lastPhotos: Map<String, Bitmap>? = null
    var lastFitKey: String? = null
    var lastFollowRequest: Int = 0
    var lastUser: LatLng? = null
    var lastDark: Boolean? = null
    var lastBottomPadding: Int = -1
    var gestureInstalled = false
    var onUserPan: () -> Unit = {}
    var onMarkerClick: (String) -> Unit = {}
}

/**
 * Full-screen Tencent map behind the home timeline sheet (iOS
 * ContinuousTimelineView.mapContent). Redraws only when overlays change, frames
 * the camera per [cameraFit] with the sheet height as bottom padding, and
 * reports user pans so the caller can collapse the sheet.
 */
@Composable
fun TimelineMapView(
    overlays: TimelineMapOverlays,
    cameraFit: TimelineCameraFit?,
    bottomPaddingPx: Int,
    userLocation: LatLng?,
    isFollowingUser: Boolean,
    followUserRequest: Int,
    photoBitmaps: Map<String, Bitmap>,
    onUserPan: () -> Unit,
    onMarkerClick: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val holder = remember { TimelineMapHolder() }
    holder.onUserPan = onUserPan
    holder.onMarkerClick = onMarkerClick
    val isDark = isSystemInDarkTheme()
    val routeColor = MaterialTheme.colorScheme.primary.toArgb()

    AndroidView(
        factory = { ctx -> TextureMapView(ctx).apply { onResume() } },
        modifier = modifier,
        onRelease = { view ->
            view.onPause()
            view.onDestroy()
        }
    ) { view ->
        val map = view.map
        if (!holder.gestureInstalled) {
            holder.gestureInstalled = true
            map.uiSettings.apply {
                isZoomControlsEnabled = false
                isMyLocationButtonEnabled = false
                isRotateGesturesEnabled = false
                isTiltGesturesEnabled = false
                isScrollGesturesEnabled = true
                isZoomGesturesEnabled = true
            }
            map.addTencentMapGestureListener(object : TencentMapGestureListener {
                override fun onDoubleTap(x: Float, y: Float) = false
                override fun onSingleTap(x: Float, y: Float) = false
                override fun onFling(x: Float, y: Float) = false
                override fun onScroll(x: Float, y: Float): Boolean {
                    view.post { holder.onUserPan() }
                    return false
                }
                override fun onLongPress(x: Float, y: Float) = false
                override fun onDown(x: Float, y: Float) = false
                override fun onUp(x: Float, y: Float) = false
                override fun onTwoFingerMoveAgainst(
                    status: TencentMapGestureListener.TwoFingerMoveAgainstStatus?,
                    position: CameraPosition?
                ) = false
                override fun onMapStable() {}
            })
        }
        if (holder.lastDark != isDark) {
            holder.lastDark = isDark
            map.mapType = if (isDark) TencentMap.MAP_TYPE_DARK else TencentMap.MAP_TYPE_NORMAL
        }

        val needsRedraw = holder.lastOverlays != overlays || holder.lastPhotos != photoBitmaps ||
            holder.lastUser != userLocation
        if (needsRedraw) {
            holder.lastOverlays = overlays
            holder.lastPhotos = photoBitmaps
            holder.lastUser = userLocation
            map.clear()
            map.addImportantPlaceCircles(overlays.places)
            overlays.routes.forEach { drawSmoothedRoute(map, it, routeColor) }
            userLocation?.let {
                map.addMarker(
                    MarkerOptions()
                        .position(it)
                        .anchor(0.5f, 0.5f)
                        .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))
                        .zIndex(200f)
                        .title("当前位置")
                )
            }
            if (overlays.markers.isNotEmpty()) {
                map.addFootprintMarkers(
                    overlays.markers,
                    isDark = isDark,
                    onMarkerClick = { id -> holder.onMarkerClick(id) },
                    photoBitmaps = photoBitmaps
                )
            }
        }

        val density = view.context.resources.displayMetrics.density
        holder.lastBottomPadding = bottomPaddingPx

        if (followUserRequest != holder.lastFollowRequest && userLocation != null) {
            holder.lastFollowRequest = followUserRequest
            map.animateCamera(CameraUpdateFactory.newLatLngZoom(userLocation, 15f))
        } else if (isFollowingUser && userLocation != null && needsRedraw) {
            map.animateCamera(CameraUpdateFactory.newLatLng(userLocation))
        }

        val fit = cameraFit
        if (fit != null && fit.key != holder.lastFitKey && fit.points.isNotEmpty()) {
            holder.lastFitKey = fit.key
            if (!fit.skipMove && !isFollowingUser) {
                val apply = {
                    applyFit(map, view, fit, bottomPaddingPx, density)
                }
                if (view.width > 0 && view.height > 0) apply() else map.addOnMapLoadedCallback { apply() }
            }
        } else if (fit != null && fit.points.isEmpty()) {
            // Wait for data before consuming this key.
        }
    }
}

private fun applyFit(
    map: TencentMap,
    view: TextureMapView,
    fit: TimelineCameraFit,
    bottomPaddingPx: Int,
    density: Float
) {
    val side = (40 * density).toInt()
    val top = (72 * density).toInt()
    val bottom = (bottomPaddingPx + 24 * density).toInt().coerceAtMost((view.height * 0.85f).toInt())
    runCatching {
        if (fit.points.size == 1 || spanMeters(fit.points) < 150f) {
            val center = centerOf(fit.points)
            // Offset the target so the point sits in the visible area above the sheet.
            map.setPadding(0, 0, 0, bottom)
            map.animateCamera(CameraUpdateFactory.newLatLngZoom(center, fit.singlePointZoom))
            return
        }
        val bounds = LatLngBounds.builder().apply { fit.points.forEach { include(it) } }.build()
        // iOS skips tiny camera adjustments: if everything is already in view
        // and occupies a reasonable part of it, leave the camera alone.
        val visible = runCatching { map.projection.visibleRegion.latLngBounds }.getOrNull()
        if (visible != null && fit.points.all { visible.contains(it) }) {
            val ratio = bounds.latitudeSpan / visible.latitudeSpan.coerceAtLeast(1e-9)
            if (ratio > 0.35) return
        }
        map.setPadding(0, 0, 0, 0)
        map.animateCamera(CameraUpdateFactory.newLatLngBoundsRect(bounds, side, side, top, bottom))
    }
}

private fun centerOf(points: List<LatLng>): LatLng =
    LatLng(points.map { it.latitude }.average(), points.map { it.longitude }.average())

private fun spanMeters(points: List<LatLng>): Float {
    if (points.size < 2) return 0f
    val minLat = points.minOf { it.latitude }
    val maxLat = points.maxOf { it.latitude }
    val minLon = points.minOf { it.longitude }
    val maxLon = points.maxOf { it.longitude }
    val result = FloatArray(1)
    android.location.Location.distanceBetween(minLat, minLon, maxLat, maxLon, result)
    return result[0]
}

/** Parses a route JSON array into segments split by [0,0] separators. */
internal fun parseRouteSegments(pointsJson: String?): List<List<LatLng>> {
    if (pointsJson.isNullOrBlank()) return emptyList()
    return runCatching {
        val array = org.json.JSONArray(pointsJson)
        val segments = mutableListOf<MutableList<LatLng>>()
        var current = mutableListOf<LatLng>()
        for (i in 0 until array.length()) {
            val p = array.optJSONArray(i)
            val lat: Double
            val lon: Double
            if (p != null) {
                lat = p.optDouble(0, Double.NaN)
                lon = p.optDouble(1, Double.NaN)
            } else {
                val o = array.optJSONObject(i) ?: continue
                lat = o.optDouble("lat", o.optDouble("latitude", Double.NaN))
                lon = o.optDouble("lon", o.optDouble("longitude", Double.NaN))
            }
            if (!lat.isFinite() || !lon.isFinite()) continue
            if (lat == 0.0 && lon == 0.0) {
                if (current.isNotEmpty()) {
                    segments.add(current)
                    current = mutableListOf()
                }
            } else {
                // Some legacy rows store [lon, lat].
                current.add(if (kotlin.math.abs(lat) > 90.0) LatLng(lon, lat) else LatLng(lat, lon))
            }
        }
        if (current.isNotEmpty()) segments.add(current)
        segments as List<List<LatLng>>
    }.getOrDefault(emptyList())
}

/** Distance-filtered, moving-average + Catmull-Rom smoothed polyline (as the old MiniMapView). */
private fun smooth(segment: List<LatLng>): List<LatLng> {
    if (segment.size < 2) return segment
    val filtered = mutableListOf(segment.first())
    val result = FloatArray(1)
    for (i in 1 until segment.size - 1) {
        val prev = filtered.last()
        val curr = segment[i]
        android.location.Location.distanceBetween(prev.latitude, prev.longitude, curr.latitude, curr.longitude, result)
        if (result[0] > 4f) filtered.add(curr)
    }
    filtered.add(segment.last())
    val averaged = filtered.indices.map { i ->
        if (i == 0 || i == filtered.lastIndex) filtered[i] else {
            val s = maxOf(0, i - 2)
            val e = minOf(filtered.lastIndex, i + 2)
            val window = filtered.subList(s, e + 1)
            LatLng(window.map { it.latitude }.average(), window.map { it.longitude }.average())
        }
    }
    if (averaged.size < 3) return averaged
    val out = mutableListOf<LatLng>()
    val granularity = 10
    for (i in 0 until averaged.size - 1) {
        val p0 = averaged[maxOf(i - 1, 0)]
        val p1 = averaged[i]
        val p2 = averaged[i + 1]
        val p3 = averaged[minOf(i + 2, averaged.lastIndex)]
        for (step in 0 until granularity) {
            val t = step / granularity.toDouble()
            val t2 = t * t
            val t3 = t2 * t
            fun cr(a: Double, b: Double, c: Double, d: Double) =
                0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
            out.add(LatLng(cr(p0.latitude, p1.latitude, p2.latitude, p3.latitude), cr(p0.longitude, p1.longitude, p2.longitude, p3.longitude)))
        }
    }
    out.add(averaged.last())
    return out
}

private fun drawSmoothedRoute(map: TencentMap, pointsJson: String, color: Int) {
    val segments = parseRouteSegments(pointsJson).map(::smooth).filter { it.size >= 2 }
    segments.forEach { map.addPolyline(PolylineOptions().addAll(it).width(12f).color(color)) }
}
