package com.ct106.difangke.service.tracking

import kotlin.math.max

/** Ports of the iOS departure-evidence predicates. All pure. */
object DepartureDetector {

    /** iOS `hasConfirmedDeparture(from:to:isSamePlace:isMovingBySensor:)`. */
    fun hasConfirmedDeparture(
        stayStart: TrackingFix,
        fix: TrackingFix,
        isSamePlace: Boolean,
        isMovingBySensor: Boolean,
        nowMs: Long
    ): Boolean {
        val distance = fix.distanceTo(stayStart)
        // Reported high speed (e.g. high-speed rail) is decisive even with poor accuracy.
        if (fix.speed >= TrackingConfig.REPORTED_HIGH_SPEED_THRESHOLD &&
            distance > TrackingConfig.DEPARTURE_HIGH_SPEED_DISTANCE
        ) return true
        if (isSamePlace) return false
        if (fix.accuracy < 0 || fix.accuracy >= TrackingConfig.DEPARTURE_ACCURACY_THRESHOLD) return false
        if (distance <= TrackingConfig.DEPARTURE_DISTANCE_THRESHOLD) return false

        // After a long stay a single drifting fix must not end the stay
        // unless motion sensors agree.
        val stayDuration = (nowMs - stayStart.timeMs) / 1000.0
        if (stayDuration > TrackingConfig.DEPARTURE_LONG_STAY_DURATION && !isMovingBySensor) {
            val threshold = max(
                TrackingConfig.DEPARTURE_DRIFT_RESISTANT_FLOOR,
                fix.accuracy * TrackingConfig.DEPARTURE_DRIFT_RESISTANT_RATIO
            )
            return distance > threshold
        }
        return true
    }

    /** iOS `hasPromptAutomaticDepartureEvidence`. */
    fun hasPromptDepartureEvidence(fix: TrackingFix, anchor: TrackingFix, speed: Double = fix.speed): Boolean =
        fix.accuracy > 0 &&
            fix.accuracy <= TrackingConfig.LOW_POWER_DEPARTURE_ACCURACY &&
            speed >= TrackingConfig.LOW_POWER_DEPARTURE_SPEED &&
            fix.distanceTo(anchor) > max(
                TrackingConfig.LOW_POWER_DEPARTURE_DISTANCE_FLOOR,
                fix.accuracy * TrackingConfig.LOW_POWER_DEPARTURE_ACCURACY_RATIO
            )

    data class Evidence(
        val hasStrongGpsDeparture: Boolean,
        val hasPromptLowPowerDeparture: Boolean,
        val hasLowPowerGpsDeparture: Boolean,
        val isMovingByGps: Boolean
    )

    /**
     * Combines the per-fix evidence flags computed in iOS processLocationUpdate.
     *
     * @param anchor stationary low-power anchor, else the current stay start
     * @param speed reported speed, or (Android) a displacement-derived speed
     *   for network fixes which carry no speed
     * @param motionSaysStationary sensor classification is explicitly stationary
     */
    fun evaluate(
        fix: TrackingFix,
        anchor: TrackingFix?,
        speed: Double,
        isFresh: Boolean,
        isLowPower: Boolean,
        motionSaysStationary: Boolean
    ): Evidence {
        val distanceFromStop = anchor?.let { fix.distanceTo(it) } ?: 0.0
        val accOk = fix.accuracy >= 0 && fix.accuracy < TrackingConfig.DEPARTURE_ACCURACY_THRESHOLD
        val strong = isFresh && accOk && distanceFromStop > max(
            TrackingConfig.DEPARTURE_DRIFT_RESISTANT_FLOOR,
            fix.accuracy * TrackingConfig.DEPARTURE_DRIFT_RESISTANT_RATIO
        )
        val prompt = isLowPower && isFresh && anchor != null &&
            hasPromptDepartureEvidence(fix, anchor, speed)
        val lowPowerGps = prompt || (isLowPower && isFresh && accOk &&
            speed > TrackingConfig.STATIONARY_DWELL_SPEED &&
            distanceFromStop > max(
                TrackingConfig.LOW_POWER_STRICT_DWELL_DISTANCE,
                fix.accuracy * TrackingConfig.DEPARTURE_DRIFT_RESISTANT_RATIO
            ))
        val movingByGps = isFresh && speed >= 0 && speed > TrackingConfig.STATIONARY_DWELL_SPEED &&
            (!motionSaysStationary || strong || lowPowerGps)
        return Evidence(strong, prompt, lowPowerGps, movingByGps)
    }
}

/**
 * iOS `updateUIMovementState`: moving immediately on evidence; back to
 * stationary only after [holdSeconds] without evidence.
 */
class MovementHysteresis(private val holdSeconds: Double = TrackingConfig.UI_MOVING_HOLD_DURATION) {
    var isMoving: Boolean = false
        private set
    var lastMovingEvidenceMs: Long = Long.MIN_VALUE
        private set

    enum class Transition { NONE, BECAME_MOVING, BECAME_STATIONARY }

    fun update(isMovingEvidence: Boolean, nowMs: Long): Transition {
        if (isMovingEvidence) {
            lastMovingEvidenceMs = nowMs
            if (!isMoving) {
                isMoving = true
                return Transition.BECAME_MOVING
            }
            return Transition.NONE
        }
        if (isMoving && (lastMovingEvidenceMs == Long.MIN_VALUE ||
                (nowMs - lastMovingEvidenceMs) / 1000.0 > holdSeconds)
        ) {
            isMoving = false
            return Transition.BECAME_STATIONARY
        }
        return Transition.NONE
    }

    /** Used by confirmArrival: drop to stationary without waiting for the hold. */
    fun forceStationary() {
        isMoving = false
        lastMovingEvidenceMs = Long.MIN_VALUE
    }

    fun hasRecentEvidence(nowMs: Long): Boolean =
        lastMovingEvidenceMs != Long.MIN_VALUE && (nowMs - lastMovingEvidenceMs) / 1000.0 < holdSeconds
}

/**
 * iOS `triggerTimelineSiftDebounced(moving:)`: at most one automatic sift per
 * 120 s while moving, per 900 s otherwise.
 */
class SiftDebouncer {
    private var lastSiftMs: Long = Long.MIN_VALUE

    fun shouldSift(moving: Boolean, nowMs: Long): Boolean {
        val interval = if (moving) TrackingConfig.MOVING_TIMELINE_SIFT_INTERVAL
        else TrackingConfig.TIMELINE_SIFT_DEBOUNCE_INTERVAL
        if (lastSiftMs != Long.MIN_VALUE && (nowMs - lastSiftMs) / 1000.0 < interval) return false
        lastSiftMs = nowMs
        return true
    }
}

/** iOS reverse-geocode throttle: 1000 m when >10 m/s, else 100 m. */
class GeocodeThrottle {
    var lastGeocoded: TrackingFix? = null
        private set

    fun shouldGeocode(fix: TrackingFix): Boolean {
        val last = lastGeocoded
        val threshold = if (fix.speed > TrackingConfig.GEOCODE_HIGH_SPEED_THRESHOLD)
            TrackingConfig.GEOCODE_HIGH_SPEED_DISTANCE else TrackingConfig.GEOCODE_DISTANCE
        val should = last == null || fix.distanceTo(last) > threshold
        if (should) lastGeocoded = fix
        return should
    }

    fun reset() { lastGeocoded = null }
}
