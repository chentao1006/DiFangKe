package com.ct106.difangke.service.tracking

import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveTrackingLogicTest {
    private val baseLat = 31.2304
    private val baseLon = 121.4737
    private val t0 = 1_760_000_000_000L // fixed instant

    /** Offset north by [meters]. */
    private fun fix(sec: Long, northMeters: Double = 0.0, acc: Double = 10.0, speed: Double = 0.0) =
        TrackingFix(t0 + sec * 1000, baseLat + northMeters / 111_195.0, baseLon, acc, speed)

    // ── Pre-filter ──

    @Test fun preFilterRejectsImpossibleJump() {
        val recent = listOf(fix(0))
        assertFalse(LiveIngestFilter.shouldAccept(fix(5, 4_000.0, acc = 20.0), recent)) // 800 m/s
    }

    @Test fun preFilterRejectsInaccurateFastDrift() {
        val recent = listOf(fix(0))
        assertFalse(LiveIngestFilter.shouldAccept(fix(10, 700.0, acc = 120.0), recent)) // 70 m/s, acc 120
    }

    @Test fun preFilterKeepsReportedHighSpeedRail() {
        val recent = listOf(fix(0))
        assertTrue(LiveIngestFilter.shouldAccept(fix(10, 700.0, acc = 120.0, speed = 70.0), recent))
    }

    @Test fun preFilterExemptsPreciseReturnFromWeakCluster() {
        val weak = (0 until 5).map { fix(it * 30L, it.toDouble(), acc = 300.0) }
        // 2.5 km in 30 s = 83 m/s with good accuracy after a weak cluster.
        assertTrue(LiveIngestFilter.shouldAccept(fix(150, 2_504.0, acc = 30.0), weak))
    }

    @Test fun preFilterIgnoresLateSamples() {
        val recent = listOf(fix(100))
        assertTrue(LiveIngestFilter.shouldAccept(fix(50, 5_000.0, acc = 500.0), recent))
    }

    // ── Raw save throttle ──

    private val idle = RawSaveThrottle.Context(false, null, false, false, false)

    @Test fun throttleSavesAtMostEveryFiveSeconds() {
        val t = RawSaveThrottle(TimeZone.getTimeZone("UTC"))
        val a = fix(0, 0.0, acc = 30.0, speed = 3.0)
        assertTrue(t.evaluate(a, idle).shouldSave); t.commit(a, false)
        assertFalse(t.evaluate(fix(3, 10.0, acc = 30.0, speed = 3.0), idle).shouldSave)
        assertTrue(t.evaluate(fix(6, 20.0, acc = 30.0, speed = 3.0), idle).shouldSave)
    }

    @Test fun throttleAlwaysSavesLateBatchSample() {
        val t = RawSaveThrottle(TimeZone.getTimeZone("UTC"))
        val a = fix(100, speed = 3.0, acc = 30.0)
        t.commit(a, false)
        val d = t.evaluate(fix(80, 50.0, acc = 30.0, speed = 3.0), idle)
        assertTrue(d.shouldSave); assertTrue(d.isDelayedBatchSample)
        t.commit(fix(80, 50.0), true)
        assertEquals(t0 + 100_000, t.lastSaveWatermarkMs)
    }

    @Test fun throttleSkipsRedundantStationaryFix() {
        val t = RawSaveThrottle(TimeZone.getTimeZone("UTC"))
        val a = fix(0, acc = 5.0)
        t.commit(a, false)
        assertFalse(t.evaluate(fix(60, 3.0, acc = 5.0), idle).shouldSave)
        // Heartbeat after 300 s.
        assertTrue(t.evaluate(fix(301, 3.0, acc = 5.0), idle).shouldSave)
    }

    @Test fun throttleSkipsLowPowerFixNearAnchorButKeepsPromptDeparture() {
        val t = RawSaveThrottle(TimeZone.getTimeZone("UTC"))
        val anchor = fix(0, acc = 30.0)
        t.commit(anchor, false)
        val lp = RawSaveThrottle.Context(true, anchor, false, false, false)
        assertFalse(t.evaluate(fix(60, 10.0, acc = 40.0), lp).shouldSave)
        val prompt = RawSaveThrottle.Context(true, anchor, false, true, true)
        assertTrue(t.evaluate(fix(62, 80.0, acc = 20.0, speed = 3.0), prompt).shouldSave)
    }

    // ── Departure ──

    @Test fun highReportedSpeedDepartsEvenAtSamePlace() {
        val stop = fix(0)
        assertTrue(DepartureDetector.hasConfirmedDeparture(stop, fix(60, 600.0, acc = 300.0, speed = 25.0), true, false, t0 + 60_000))
    }

    @Test fun samePlaceOrPoorAccuracyDoesNotDepart() {
        val stop = fix(0)
        assertFalse(DepartureDetector.hasConfirmedDeparture(stop, fix(60, 200.0), true, false, t0 + 60_000))
        assertFalse(DepartureDetector.hasConfirmedDeparture(stop, fix(60, 200.0, acc = 150.0), false, false, t0 + 60_000))
        assertTrue(DepartureDetector.hasConfirmedDeparture(stop, fix(60, 200.0), false, false, t0 + 60_000))
    }

    @Test fun longStayNeedsDriftResistantDistanceWithoutSensor() {
        val stop = fix(0)
        val now = t0 + 40 * 60_000L
        val f = fix(2_400, 200.0, acc = 50.0)
        assertFalse(DepartureDetector.hasConfirmedDeparture(stop, f, false, false, now))
        assertTrue(DepartureDetector.hasConfirmedDeparture(stop, f, false, true, now))
        assertTrue(DepartureDetector.hasConfirmedDeparture(stop, fix(2_400, 400.0, acc = 50.0), false, false, now))
    }

    @Test fun promptLowPowerDepartureEvidence() {
        val anchor = fix(0)
        assertTrue(DepartureDetector.hasPromptDepartureEvidence(fix(30, 40.0, acc = 20.0, speed = 3.0), anchor))
        assertFalse(DepartureDetector.hasPromptDepartureEvidence(fix(30, 25.0, acc = 20.0, speed = 3.0), anchor))
        assertFalse(DepartureDetector.hasPromptDepartureEvidence(fix(30, 100.0, acc = 80.0, speed = 3.0), anchor))
    }

    @Test fun gpsSpeedIsIgnoredWhenMotionSaysStationaryUnlessStrong() {
        val anchor = fix(0)
        val noisy = fix(30, 20.0, acc = 30.0, speed = 2.0)
        assertFalse(DepartureDetector.evaluate(noisy, anchor, 2.0, true, false, true).isMovingByGps)
        assertTrue(DepartureDetector.evaluate(noisy, anchor, 2.0, true, false, false).isMovingByGps)
        val far = fix(30, 400.0, acc = 30.0, speed = 2.0)
        assertTrue(DepartureDetector.evaluate(far, anchor, 2.0, true, false, true).isMovingByGps)
    }

    // ── Hysteresis ──

    @Test fun hysteresisHoldsMovingFor120Seconds() {
        val h = MovementHysteresis()
        assertEquals(MovementHysteresis.Transition.BECAME_MOVING, h.update(true, 0))
        assertEquals(MovementHysteresis.Transition.NONE, h.update(false, 100_000))
        assertTrue(h.isMoving)
        assertEquals(MovementHysteresis.Transition.BECAME_STATIONARY, h.update(false, 121_000))
        assertFalse(h.isMoving)
    }

    // ── Stationary anchor ──

    @Test fun strictClusterAnchorsAfterFiveMinutes() {
        val d = StationaryAnchorDetector()
        var anchor: TrackingFix? = null
        for (i in 0..10) anchor = d.anchorFor(fix(i * 30L, (i % 3).toDouble()), false, false, false)
        assertNotNull(anchor)
    }

    @Test fun strictClusterRejectsSlowCrawl() {
        val d = StationaryAnchorDetector()
        var anchor: TrackingFix? = null
        for (i in 0..12) anchor = d.anchorFor(fix(i * 30L, i * 8.0, speed = 0.5), false, false, false)
        assertNull(anchor)
    }

    @Test fun motionStationaryAllowsBroadClusterAfterTenMinutes() {
        val d = StationaryAnchorDetector()
        var broad: TrackingFix? = null
        for (i in 0..20) broad = d.anchorFor(fix(i * 30L, (i % 5) * 25.0, acc = 60.0), true, true, false)
        assertNotNull(broad)
        val d2 = StationaryAnchorDetector()
        var none: TrackingFix? = null
        for (i in 0..20) none = d2.anchorFor(fix(i * 30L, (i % 5) * 25.0, acc = 60.0), false, false, false)
        assertNull(none)
    }

    @Test fun anchorWindowIgnoresDenseSamples() {
        val d = StationaryAnchorDetector()
        // 5 s fixes for 25 min: only ≥30 s-spaced samples are kept, and only
        // within max(dwell, strictDwell) + grace (iOS stationaryLocationWindow).
        for (i in 0..300) d.anchorFor(fix(i * 5L), false, false, false)
        val keep = maxOf(TrackingConfig.LOW_POWER_DWELL_DURATION, TrackingConfig.LOW_POWER_STRICT_DWELL_DURATION) +
            TrackingConfig.LOW_POWER_WINDOW_GRACE_PERIOD
        assertTrue(d.samples.size <= (keep / TrackingConfig.LOW_POWER_SAMPLE_INTERVAL).toInt() + 1)
        assertTrue(d.samples.zipWithNext().all { (a, b) -> b.secondsSince(a) >= TrackingConfig.LOW_POWER_SAMPLE_INTERVAL })
    }

    // ── Sift / geocode ──

    @Test fun siftDebounceDependsOnMovement() {
        val s = SiftDebouncer()
        assertTrue(s.shouldSift(true, 0))
        assertFalse(s.shouldSift(true, 100_000))
        assertTrue(s.shouldSift(true, 121_000))
        assertFalse(s.shouldSift(false, 500_000))
        assertTrue(s.shouldSift(false, 121_000 + 900_000))
    }

    @Test fun geocodeThrottleUsesSpeed() {
        val g = GeocodeThrottle()
        assertTrue(g.shouldGeocode(fix(0)))
        assertFalse(g.shouldGeocode(fix(10, 90.0)))
        assertTrue(g.shouldGeocode(fix(20, 150.0)))
        assertFalse(g.shouldGeocode(fix(30, 900.0, speed = 15.0)))
        assertTrue(g.shouldGeocode(fix(40, 1_200.0, speed = 15.0)))
    }

    // ── Live merge / new place ──

    private fun fp(id: String, startMin: Long, endMin: Long, north: Double, place: String? = null, status: String = "candidate") =
        FootprintSummary(id, t0 + startMin * 60_000, t0 + endMin * 60_000, baseLat + north / 111_195.0, baseLon, place, status)

    @Test fun mergesSamePlaceNeighboursWithoutTransport() {
        val now = t0 + 60 * 60_000
        val list = listOf(fp("a", 0, 30, 0.0), fp("b", 35, 58, 50.0))
        val utc = TimeZone.getTimeZone("UTC")
        assertEquals(listOf("a" to "b"), LiveFootprintRules.planRecentMerges(list, emptyList(), now, utc))
        assertTrue(LiveFootprintRules.planRecentMerges(list, listOf(TimeSpan(t0 + 31 * 60_000, t0 + 34 * 60_000)), now, utc).isEmpty())
        val manual = listOf(fp("a", 0, 30, 0.0, status = "manual"), fp("b", 35, 58, 50.0))
        assertTrue(LiveFootprintRules.planRecentMerges(manual, emptyList(), now, utc).isEmpty())
        val far = listOf(fp("a", 0, 30, 0.0), fp("b", 35, 58, 400.0))
        assertTrue(LiveFootprintRules.planRecentMerges(far, emptyList(), now, utc).isEmpty())
    }

    @Test fun firstVisitUses200mRadiusAndPlaceID() {
        val history = listOf(fp("old", -1_000, -900, 150.0))
        assertFalse(LiveFootprintRules.isFirstVisit(history, t0, baseLat, baseLon, null))
        val farHistory = listOf(fp("old", -1_000, -900, 250.0))
        assertTrue(LiveFootprintRules.isFirstVisit(farHistory, t0, baseLat, baseLon, null))
        val samePlace = listOf(fp("old", -1_000, -900, 5_000.0, place = "p1"))
        assertFalse(LiveFootprintRules.isFirstVisit(samePlace, t0, baseLat, baseLon, "p1"))
    }

    @Test fun candidateMergeRules() {
        val last = fp("a", 0, 30, 0.0, place = "p1")
        assertTrue(LiveFootprintRules.shouldMergeCandidate(last, t0 + 80 * 60_000, baseLat + 0.01, baseLon, "p1"))
        assertFalse(LiveFootprintRules.shouldMergeCandidate(last, t0 + 80 * 60_000, baseLat, baseLon, null))
        assertTrue(LiveFootprintRules.shouldMergeCandidate(last, t0 + 50 * 60_000, baseLat, baseLon, null))
        assertFalse(LiveFootprintRules.shouldMergeCandidate(last.copy(status = "manual"), t0 + 31 * 60_000, baseLat, baseLon, "p1"))
    }

    @Test fun ongoingIgnoredStayExtendsItsOwnIgnoredFootprint() {
        val ignoredRow = fp("ig", 0, 30, 0.0, place = "ignoredPlace", status = "ignored")
        // Ongoing stay refreshed a minute later at the same ignored place → extend the existing row.
        assertEquals(
            "ig",
            LiveFootprintRules.ignoredFootprintToExtend(listOf(ignoredRow), emptyList(), t0, baseLat, baseLon, "ignoredPlace")?.id
        )
        // Same location without a place ID still matches by distance, like visible footprints.
        assertEquals(
            "ig",
            LiveFootprintRules.ignoredFootprintToExtend(listOf(ignoredRow), emptyList(), t0 + 31 * 60_000, baseLat, baseLon, null)?.id
        )
        // The latest ignored row is the one extended.
        val older = fp("old", -300, -200, 0.0, place = "ignoredPlace", status = "ignored")
        assertEquals(
            "ig",
            LiveFootprintRules.ignoredFootprintToExtend(listOf(older, ignoredRow), emptyList(), t0 + 31 * 60_000, baseLat, baseLon, "ignoredPlace")?.id
        )
        // A far-away candidate or a visible stay in between starts a new row instead.
        assertNull(LiveFootprintRules.ignoredFootprintToExtend(listOf(ignoredRow), emptyList(), t0 + 31 * 60_000, baseLat + 0.01, baseLon, null))
        val visibleInBetween = listOf(fp("v", 35, 50, 2_000.0))
        assertNull(LiveFootprintRules.ignoredFootprintToExtend(listOf(ignoredRow), visibleInBetween, t0 + 55 * 60_000, baseLat, baseLon, "ignoredPlace"))
        assertNull(LiveFootprintRules.ignoredFootprintToExtend(emptyList(), emptyList(), t0, baseLat, baseLon, "ignoredPlace"))
    }

    @Test fun automaticIntervalsClipAroundManual() {
        val pieces = LiveFootprintRules.automaticIntervals(0, 100, listOf(TimeSpan(40, 60)))
        assertEquals(listOf(TimeSpan(0, 40), TimeSpan(60, 100)), pieces)
    }

    @Test fun earliestStayStartBackfillsContiguousRun() {
        val pts = listOf(fix(0, 900.0), fix(60, 10.0), fix(120, 5.0), fix(180, 0.0))
        val start = LiveFootprintRules.earliestContiguousStayStart(pts, baseLat, baseLon, 100.0, 1_800_000, 0)
        assertEquals(t0 + 60_000, start?.timeMs)
    }

    @Test fun placeCountDedupesByName() {
        val n = DailyStats.placeCount(listOf(
            DailyStats.PlaceKeyInput("咖啡馆", null, 1.0, 1.0),
            DailyStats.PlaceKeyInput("咖啡馆 ", "x", 2.0, 2.0),
            DailyStats.PlaceKeyInput("此处", "p", 3.0, 3.0),
            DailyStats.PlaceKeyInput(null, null, 3.0, 3.0)
        ))
        assertEquals(3, n)
    }
}
