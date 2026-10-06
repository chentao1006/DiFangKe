package com.ct106.difangke.service.timeline

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Pure geometry helpers shared by the timeline engine (no Android dependencies). */
object GeoMath {
    private const val EARTH_RADIUS = 6_371_000.0

    fun distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return EARTH_RADIUS * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    fun isValidCoordinate(lat: Double, lon: Double): Boolean =
        lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0

    /** iOS TimelineBuilder.calculateMaxDiameter: bounding-box diagonal. */
    fun maxDiameter(coords: List<Pair<Double, Double>>): Double {
        if (coords.isEmpty()) return 0.0
        var minLat = coords[0].first; var maxLat = coords[0].first
        var minLon = coords[0].second; var maxLon = coords[0].second
        for ((lat, lon) in coords) {
            if (lat < minLat) minLat = lat
            if (lat > maxLat) maxLat = lat
            if (lon < minLon) minLon = lon
            if (lon > maxLon) maxLon = lon
        }
        return distance(minLat, minLon, maxLat, maxLon)
    }

    fun pathDistance(coords: List<Pair<Double, Double>>): Double {
        if (coords.size < 2) return 0.0
        var total = 0.0
        for (i in 0 until coords.size - 1) {
            total += distance(coords[i].first, coords[i].second, coords[i + 1].first, coords[i + 1].second)
        }
        return total
    }

    fun centroid(coords: List<Pair<Double, Double>>): Pair<Double, Double> {
        if (coords.isEmpty()) return 0.0 to 0.0
        return coords.sumOf { it.first } / coords.size to coords.sumOf { it.second } / coords.size
    }
}
