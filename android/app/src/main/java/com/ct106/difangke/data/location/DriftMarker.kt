package com.ct106.difangke.data.location

import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.location.RawLocationStore.RawPoint
import com.ct106.difangke.service.timeline.GeoMath
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Result of drift marking: chronological valid points plus the drift timestamps (epoch millis). */
data class DriftMarkResult(
    val entries: List<RawLocationStore.RawPointEntry>,
    val validPoints: List<RawPoint>,
    val driftTimestamps: Set<Long>
)

/**
 * Line-by-line port of iOS `RawLocationStore.markDriftPoints` and
 * `normalizedChronologicalLocations`. Pure Kotlin so it can be unit tested.
 */
object DriftMarker {

    private fun dist(a: RawPoint, b: RawPoint) = GeoMath.distance(a.latitude, a.longitude, b.latitude, b.longitude)
    private fun secs(from: RawPoint, to: RawPoint) = (to.timestamp.time - from.timestamp.time) / 1000.0

    /** Sort by timestamp; duplicate timestamps keep the best (smallest valid) accuracy. */
    fun normalizeChronological(points: List<RawPoint>): List<RawPoint> {
        val best = LinkedHashMap<Long, RawPoint>()
        for (p in points) {
            val ts = p.timestamp.time
            val existing = best[ts]
            if (existing == null) {
                best[ts] = p
            } else {
                val existingAcc = if (existing.accuracy >= 0) existing.accuracy else Double.MAX_VALUE
                val candidateAcc = if (p.accuracy >= 0) p.accuracy else Double.MAX_VALUE
                if (candidateAcc < existingAcc) best[ts] = p
            }
        }
        return best.values.sortedBy { it.timestamp.time }
    }

    fun mark(points: List<RawPoint>): DriftMarkResult {
        val entries = markEntries(points)
        return DriftMarkResult(
            entries = entries,
            validPoints = entries.filter { !it.isDriftPoint }.map { it.point },
            driftTimestamps = entries.filter { it.isDriftPoint }.map { it.point.timestamp.time }.toSet()
        )
    }

    fun filterRidiculousSpikes(points: List<RawPoint>): List<RawPoint> {
        if (points.size < 3) return points
        return markEntries(points).filter { !it.isDriftPoint }.map { it.point }
    }

    fun markEntries(points: List<RawPoint>): List<RawLocationStore.RawPointEntry> {
        if (points.size < 2) {
            return points.mapIndexed { index, p -> RawLocationStore.RawPointEntry(p, false, index) }
        }
        val n = points.size
        val drift = BooleanArray(n)

        // Weak, nearly stationary cluster followed by a precise confirmed fix.
        if (n >= 6) {
            for (exitIndex in 4 until n - 1) {
                val exit = points[exitIndex]
                val confirmation = points[exitIndex + 1]
                val lastWeak = points[exitIndex - 1]
                val exitTime = secs(lastWeak, exit)
                if (!(exit.accuracy > 0 && exit.accuracy <= 100)) continue
                if (!(confirmation.accuracy > 0 && confirmation.accuracy <= 150)) continue
                if (secs(exit, confirmation) > 120) continue
                if (dist(exit, confirmation) > 150) continue
                if (exitTime <= 0) continue
                val jump = dist(lastWeak, exit)
                if (jump < 2_000) continue
                if (jump / exitTime <= AppConfig.TRANSPORT_MAX_REASONABLE_SPEED) continue

                val earliest = max(0, exitIndex - 15)
                for (startIndex in earliest until (exitIndex - 2)) {
                    if (secs(points[startIndex], lastWeak) > 5 * 60) continue
                    val cluster = points.subList(startIndex, exitIndex)
                    val weakCount = cluster.count { it.accuracy >= 150 }
                    if (weakCount * 5 < cluster.size * 4) continue
                    if (!cluster.all { dist(it, lastWeak) <= 100 }) continue
                    for (index in startIndex until exitIndex) drift[index] = true
                    break
                }
            }
        }

        // Pass 1: three-point rebound.
        for (i in 1 until n - 1) {
            val a = points[i - 1]; val b = points[i]; val c = points[i + 1]
            if (abs(secs(a, c)) >= 30) continue
            val distAC = dist(a, c); val distAB = dist(a, b); val distBC = dist(b, c)
            if (distAC < 100 && distAB > 80 && distBC > 80) { drift[i] = true; continue }
            if (distAC < 200 && distAB > 200 && distBC > 200) { drift[i] = true; continue }
            if (b.accuracy > 65 && distAC < 150 && distAB > 100) { drift[i] = true; continue }
        }

        // Pass 2: multi-point rebound.
        for (i in 1 until n - 1) {
            if (drift[i]) continue
            var prevIdx = i - 1
            while (prevIdx >= 0 && drift[prevIdx]) prevIdx--
            if (prevIdx < 0) continue
            var nextIdx = i + 1
            while (nextIdx < n && drift[nextIdx]) nextIdx++
            if (nextIdx >= n) continue
            val prev = points[prevIdx]; val current = points[i]; val next = points[nextIdx]
            if (abs(secs(prev, next)) >= 60) continue
            if (dist(prev, next) < 100 && dist(prev, current) > 150 && dist(current, next) > 150) drift[i] = true
        }

        // Pass 3: physically impossible speed / very poor accuracy.
        for (i in 0 until n) {
            if (drift[i]) continue
            val current = points[i]
            if (i > 0 && !drift[i - 1]) {
                val prev = points[i - 1]
                val d = dist(current, prev)
                val time = max(secs(prev, current), 0.1)
                val speed = d / time
                if (speed > AppConfig.PHYSICAL_MAX_SPEED_THRESHOLD) {
                    if (i + 1 < n) {
                        val next = points[i + 1]
                        if (dist(prev, next) < d * 0.5) { drift[i] = true; continue }
                    }
                    if (current.accuracy > 80 && current.speed < 20) { drift[i] = true; continue }
                }
                if (d > 1_500 && current.accuracy > 400 && current.speed < 20) { drift[i] = true; continue }
            }
            if (current.accuracy > 1500) {
                var nearbyGood = false
                for (j in max(0, i - 3)..min(n - 1, i + 3)) {
                    if (j != i && !drift[j] && dist(current, points[j]) < 500) { nearbyGood = true; break }
                }
                if (!nearbyGood) drift[i] = true
            }
        }

        // Pass 4: jump-cluster rebound (entry must itself be abnormally fast).
        var cleanedIndex = 0
        for (i in 1 until n) {
            if (drift[i]) continue
            val prev = points[cleanedIndex]
            val current = points[i]
            val d = dist(current, prev)
            val time = max(secs(prev, current), 0.1)
            val speed = d / time
            if (speed > 60 || (d > 800 && speed > 20)) {
                var foundReturn = false
                val searchLimit = min(i + 15, n)
                for (j in (i + 1) until searchLimit) {
                    val next = points[j]
                    if (secs(current, next) > 5 * 60) break
                    val tPrevToNext = max(secs(prev, next), 0.1)
                    val dPrevToNext = dist(next, prev)
                    val avgSpeed = dPrevToNext / tPrevToNext
                    val returnedNearPrevious = dPrevToNext <= max(100.0, d * 0.5)
                    if (avgSpeed < 42 && d > 800 && returnedNearPrevious) {
                        for (k in i until j) drift[k] = true
                        foundReturn = true
                        break
                    }
                }
                if (!foundReturn && current.accuracy > 1500 && d > 2000) drift[i] = true
            }
            if (!drift[i]) cleanedIndex = i
        }

        return points.mapIndexed { index, p -> RawLocationStore.RawPointEntry(p, drift[index], index) }
    }
}
