package com.ct106.difangke.service.tracking

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Android analog of iOS HealthManager's Core Motion + CMPedometer feed,
 * without Google Play Services:
 *
 *  - TYPE_STEP_COUNTER (hardware, low power; needs ACTIVITY_RECOGNITION on
 *    API 29+) gives "moving" evidence when ≥3 new steps arrive, held for
 *    UI_MOVING_HOLD_DURATION, exactly like the iOS pedometer path.
 *  - TYPE_SIGNIFICANT_MOTION (one-shot wake-up trigger, no permission) is the
 *    departure watch while the GPS is in stationary low power.
 */
class MotionSensorMonitor(
    context: Context,
    private val onMovingEvidence: () -> Unit,
    private val onSignificantMotion: () -> Unit
) {
    private val appContext = context.applicationContext
    private val sensorManager = appContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val stepSensor: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
    private val significantMotionSensor: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)

    @Volatile private var lastStepCount: Float? = null
    private val recentSteps = ArrayDeque<Pair<Long, Float>>()
    @Volatile private var lastStepMovementMs: Long = Long.MIN_VALUE
    @Volatile private var stepTrackingSinceMs: Long = Long.MIN_VALUE
    @Volatile private var isStepTracking = false
    @Volatile private var isSignificantMotionArmed = false

    val hasSignificantMotionSensor: Boolean get() = significantMotionSensor != null

    /** True once the step counter is delivering data (analog of hasReceivedMotionActivity). */
    val hasMotionClassification: Boolean get() = isStepTracking

    val isMovingBySensor: Boolean
        get() = lastStepMovementMs != Long.MIN_VALUE &&
            (System.currentTimeMillis() - lastStepMovementMs) / 1000.0 < TrackingConfig.UI_MOVING_HOLD_DURATION

    /**
     * "Stationary" classification analog: the step counter has been running for
     * the long dwell window and saw no walking in that window. Used only for
     * the broad 150 m anchor and while a stay anchor exists (see service).
     */
    fun saysStationary(nowMs: Long = System.currentTimeMillis()): Boolean {
        if (!isStepTracking || stepTrackingSinceMs == Long.MIN_VALUE) return false
        val window = TrackingConfig.LOW_POWER_DWELL_DURATION * 1000
        if (nowMs - stepTrackingSinceMs < window) return false
        return lastStepMovementMs == Long.MIN_VALUE || nowMs - lastStepMovementMs >= window
    }

    private val stepListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val count = event.values.firstOrNull() ?: return
            val now = System.currentTimeMillis()
            val previous = lastStepCount
            lastStepCount = count
            // The first value is a since-boot total; treat it as a baseline.
            if (previous == null || count < previous) {
                recentSteps.clear()
                recentSteps.addLast(now to count)
                return
            }
            // Hardware may report one step per event; evaluate the delta over
            // a short rolling window like the chunked CMPedometer updates.
            recentSteps.addLast(now to count)
            while (recentSteps.size > 1 && now - recentSteps.first().first > STEP_WINDOW_MS) {
                recentSteps.removeFirst()
            }
            val base = recentSteps.first().second
            if (count - base >= TrackingConfig.PEDOMETER_MIN_MOVING_STEP_DELTA) {
                lastStepMovementMs = now
                recentSteps.clear()
                recentSteps.addLast(now to count)
                onMovingEvidence()
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    private val significantMotionListener = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent?) {
            isSignificantMotionArmed = false
            Log.i(TAG, "Significant motion detected")
            onSignificantMotion()
        }
    }

    fun start() {
        if (isStepTracking) return
        val sensor = stepSensor ?: return
        if (!hasActivityRecognitionPermission()) return
        runCatching {
            // Step events are cheap hardware events; allow 10 s batching.
            isStepTracking = sensorManager?.registerListener(
                stepListener, sensor, SensorManager.SENSOR_DELAY_NORMAL, 10_000_000
            ) == true
            if (isStepTracking) {
                stepTrackingSinceMs = System.currentTimeMillis()
                lastStepCount = null
            }
        }.onFailure { Log.w(TAG, "Step counter unavailable", it) }
    }

    fun stop() {
        if (isStepTracking) runCatching { sensorManager?.unregisterListener(stepListener) }
        isStepTracking = false
        lastStepCount = null
        lastStepMovementMs = Long.MIN_VALUE
        stepTrackingSinceMs = Long.MIN_VALUE
        disarmSignificantMotion()
    }

    /** Re-tries step registration (e.g. after the user grants the permission). */
    fun refresh() {
        if (!isStepTracking) start()
    }

    fun armSignificantMotion() {
        val sensor = significantMotionSensor ?: return
        if (isSignificantMotionArmed) return
        isSignificantMotionArmed = runCatching {
            sensorManager?.requestTriggerSensor(significantMotionListener, sensor) == true
        }.getOrDefault(false)
    }

    fun disarmSignificantMotion() {
        val sensor = significantMotionSensor ?: return
        if (!isSignificantMotionArmed) return
        runCatching { sensorManager?.cancelTriggerSensor(significantMotionListener, sensor) }
        isSignificantMotionArmed = false
    }

    private fun hasActivityRecognitionPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "MotionSensorMonitor"
        private const val STEP_WINDOW_MS = 60_000L
    }
}
