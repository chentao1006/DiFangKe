package com.ct106.difangke.service.tracking

import java.util.Calendar
import java.util.TimeZone

/**
 * Port of the drift pre-filter at the top of iOS
 * `LocationManager.processLocationUpdate`. It runs before a fix can reach the
 * raw CSV, so obviously impossible jumps never pollute the stored track.
 */
object LiveIngestFilter {

    /**
     * @param fix the incoming sample
     * @param recent in-memory tracked points (chronological); only the tail is used
     * @return true when the fix may continue through the pipeline
     */
    fun shouldAccept(fix: TrackingFix, recent: List<TrackingFix>): Boolean {
        val last = recent.lastOrNull() ?: return true
        // A late background sample must never be compared with a future point.
        if (last.timeMs >= fix.timeMs) return true
        val dist = fix.distanceTo(last)
        val time = fix.secondsSince(last)
        if (time <= 0) return true
        val calcSpeed = dist / time

        val exempt = isPreciseReturnFromWeakCluster(fix, recent, dist)
        if (calcSpeed > TrackingConfig.PHYSICAL_MAX_SPEED_THRESHOLD && !exempt) return false

        val hasReportedHighSpeed = fix.speed >= TrackingConfig.REPORTED_HIGH_SPEED_THRESHOLD
        val isRidiculous =
            (fix.accuracy > TrackingConfig.RIDICULOUS_JUMP_ACCURACY &&
                dist > TrackingConfig.RIDICULOUS_JUMP_DISTANCE && !hasReportedHighSpeed) ||
                (calcSpeed > TrackingConfig.RIDICULOUS_CALC_SPEED &&
                    fix.accuracy > TrackingConfig.RIDICULOUS_CALC_SPEED_ACCURACY && !hasReportedHighSpeed)
        return !(isRidiculous && !exempt)
    }

    /**
     * A precise fix arriving after several compact, inaccurate fixes must reach
     * the raw store so the drift marker can compare both sides.
     */
    fun isPreciseReturnFromWeakCluster(
        fix: TrackingFix,
        recent: List<TrackingFix>,
        distanceFromLast: Double
    ): Boolean {
        val last = recent.lastOrNull() ?: return false
        val window = recent.takeLast(TrackingConfig.WEAK_CLUSTER_WINDOW_POINTS).filter {
            last.secondsSince(it) <= TrackingConfig.WEAK_CLUSTER_WINDOW
        }
        val weakCount = window.count { it.accuracy >= TrackingConfig.WEAK_CLUSTER_WEAK_ACCURACY }
        return fix.accuracy > 0 && fix.accuracy <= TrackingConfig.WEAK_CLUSTER_RETURN_ACCURACY &&
            distanceFromLast >= TrackingConfig.WEAK_CLUSTER_RETURN_DISTANCE &&
            window.size >= 3 &&
            weakCount * 5 >= window.size * 4 &&
            window.all { it.distanceTo(last) <= TrackingConfig.WEAK_CLUSTER_RADIUS }
    }
}

/**
 * Port of the iOS raw-location save throttle. Keeps a forward watermark so a
 * late batch sample cannot reopen the 5 s throttle for subsequent live fixes.
 */
class RawSaveThrottle(
    private val timeZone: TimeZone = TimeZone.getDefault()
) {
    var lastSaveWatermarkMs: Long = Long.MIN_VALUE
        private set
    var lastSaved: TrackingFix? = null
        private set

    data class Context(
        val isLowPower: Boolean,
        val lowPowerAnchor: TrackingFix?,
        val isMovingBySensor: Boolean,
        val hasLowPowerDepartureEvidence: Boolean,
        val hasPromptDepartureEvidence: Boolean
    )

    data class Decision(val shouldSave: Boolean, val isDelayedBatchSample: Boolean)

    fun evaluate(fix: TrackingFix, ctx: Context): Decision {
        val minInterval = TrackingConfig.FOOTPRINT_MIN_SAMPLE_INTERVAL
        val hasWatermark = lastSaveWatermarkMs != Long.MIN_VALUE
        val deltaSec = if (hasWatermark) (fix.timeMs - lastSaveWatermarkMs) / 1000.0 else Double.MAX_VALUE
        val isDelayed = hasWatermark && deltaSec <= -minInterval
        val saved = lastSaved

        val redundantConfirmedStationary = run {
            if (isDelayed || !ctx.isLowPower || ctx.isMovingBySensor || ctx.hasLowPowerDepartureEvidence) return@run false
            if (fix.speed >= TrackingConfig.STATIONARY_DWELL_SPEED) return@run false
            val anchor = ctx.lowPowerAnchor ?: return@run false
            if (saved == null || !sameDay(saved.timeMs, fix.timeMs)) return@run false
            if (fix.secondsSince(saved) >= TrackingConfig.RAW_STATIONARY_HEARTBEAT_INTERVAL) return@run false
            fix.distanceTo(anchor) < TrackingConfig.LOW_POWER_STRICT_DWELL_DISTANCE
        }
        val redundantStationary = run {
            if (isDelayed || fix.speed >= TrackingConfig.STATIONARY_DWELL_SPEED) return@run false
            if (fix.accuracy >= TrackingConfig.RAW_STATIONARY_MAX_ACCURACY) return@run false
            if (saved == null || saved.accuracy >= TrackingConfig.RAW_STATIONARY_MAX_ACCURACY) return@run false
            if (!sameDay(saved.timeMs, fix.timeMs)) return@run false
            if (fix.secondsSince(saved) >= TrackingConfig.RAW_STATIONARY_HEARTBEAT_INTERVAL) return@run false
            val d = fix.distanceTo(saved)
            d < TrackingConfig.RAW_STATIONARY_EXACT_DUPLICATE_DISTANCE ||
                (!ctx.isMovingBySensor && d < TrackingConfig.RAW_STATIONARY_DUPLICATE_DISTANCE)
        }
        val shouldSave = !redundantConfirmedStationary && !redundantStationary &&
            (!hasWatermark || deltaSec >= minInterval || isDelayed || ctx.hasPromptDepartureEvidence)
        return Decision(shouldSave, isDelayed)
    }

    /** Record that [fix] was written. */
    fun commit(fix: TrackingFix, isDelayedBatchSample: Boolean) {
        lastSaveWatermarkMs = maxOf(lastSaveWatermarkMs, fix.timeMs)
        if (!isDelayedBatchSample) lastSaved = fix
    }

    private fun sameDay(a: Long, b: Long): Boolean {
        val ca = Calendar.getInstance(timeZone).apply { timeInMillis = a }
        val cb = Calendar.getInstance(timeZone).apply { timeInMillis = b }
        return ca.get(Calendar.YEAR) == cb.get(Calendar.YEAR) &&
            ca.get(Calendar.DAY_OF_YEAR) == cb.get(Calendar.DAY_OF_YEAR)
    }
}
