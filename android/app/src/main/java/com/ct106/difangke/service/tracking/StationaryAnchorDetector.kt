package com.ct106.difangke.service.tracking

import kotlin.math.ceil
import kotlin.math.max

/**
 * Port of iOS `stationaryAnchor(for:motion:isMovingBySensor:)`.
 *
 * Keeps a ≥30 s-spaced sample window. Returns an anchor when either
 *  - motion explicitly says stationary and ≥80 % of samples over ≥600 s lie
 *    within 150 m of one sample, or
 *  - reported speed < 1 m/s and ≥90 % of samples over ≥300 s lie within 20 m.
 */
class StationaryAnchorDetector {
    private val window = ArrayList<TrackingFix>()

    val samples: List<TrackingFix> get() = window

    fun reset() = window.clear()

    fun anchorFor(
        fix: TrackingFix,
        hasMotionClassification: Boolean,
        motionSaysStationary: Boolean,
        isMovingBySensor: Boolean
    ): TrackingFix? {
        val last = window.lastOrNull()
        if (last != null && fix.secondsSince(last) < TrackingConfig.LOW_POWER_SAMPLE_INTERVAL) return null
        window.add(fix)
        val keep = max(TrackingConfig.LOW_POWER_DWELL_DURATION, TrackingConfig.LOW_POWER_STRICT_DWELL_DURATION) +
            TrackingConfig.LOW_POWER_WINDOW_GRACE_PERIOD
        window.removeAll { fix.secondsSince(it) > keep }

        if (hasMotionClassification && motionSaysStationary && !isMovingBySensor) {
            clusteredAnchor(
                window, fix,
                TrackingConfig.LOW_POWER_DWELL_DURATION,
                TrackingConfig.LOW_POWER_DWELL_DISTANCE,
                TrackingConfig.LOW_POWER_CLUSTER_FRACTION
            )?.let { return it }
        }

        if (fix.speed >= TrackingConfig.STATIONARY_DWELL_SPEED) return null
        val strict = window.filter {
            fix.secondsSince(it) <= TrackingConfig.LOW_POWER_STRICT_DWELL_DURATION +
                TrackingConfig.LOW_POWER_WINDOW_GRACE_PERIOD
        }
        return clusteredAnchor(
            strict, fix,
            TrackingConfig.LOW_POWER_STRICT_DWELL_DURATION,
            TrackingConfig.LOW_POWER_STRICT_DWELL_DISTANCE,
            TrackingConfig.LOW_POWER_STRICT_CLUSTER_FRACTION
        )
    }

    companion object {
        fun clusteredAnchor(
            samples: List<TrackingFix>,
            current: TrackingFix,
            dwellSeconds: Double,
            radius: Double,
            fraction: Double
        ): TrackingFix? {
            val first = samples.firstOrNull() ?: return null
            if (current.secondsSince(first) < dwellSeconds) return null
            val required = ceil(samples.size * fraction).toInt()
            for (anchor in samples) {
                val nearby = samples.count { anchor.distanceTo(it) < radius }
                if (nearby >= required && anchor.distanceTo(current) < radius) return anchor
            }
            return null
        }
    }
}
