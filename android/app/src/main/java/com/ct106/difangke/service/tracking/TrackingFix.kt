package com.ct106.difangke.service.tracking

import com.ct106.difangke.data.location.RawLocationStore
import java.util.Date
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** One GCJ-02 location sample as seen by the live tracking pipeline. */
data class TrackingFix(
    val timeMs: Long,
    val latitude: Double,
    val longitude: Double,
    /** Horizontal accuracy in metres; <= 0 means unknown/invalid. */
    val accuracy: Double,
    /** Reported speed in m/s; < 0 means unknown. */
    val speed: Double
) {
    fun distanceTo(other: TrackingFix): Double =
        GeoMath.distance(latitude, longitude, other.latitude, other.longitude)

    fun distanceTo(lat: Double, lon: Double): Double =
        GeoMath.distance(latitude, longitude, lat, lon)

    /** Seconds from [other] to this fix (positive when this one is later). */
    fun secondsSince(other: TrackingFix): Double = (timeMs - other.timeMs) / 1000.0

    fun toRawPoint(): RawLocationStore.RawPoint =
        RawLocationStore.RawPoint(Date(timeMs), latitude, longitude, accuracy, speed)

    companion object {
        fun from(point: RawLocationStore.RawPoint) = TrackingFix(
            point.timestamp.time, point.latitude, point.longitude, point.accuracy, point.speed
        )
    }
}

object GeoMath {
    fun distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2).pow(2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2).pow(2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    fun center(points: List<Pair<Double, Double>>): Pair<Double, Double>? {
        if (points.isEmpty()) return null
        return points.map { it.first }.average() to points.map { it.second }.average()
    }
}
