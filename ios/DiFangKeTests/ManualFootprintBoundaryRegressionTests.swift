import CoreLocation
import SwiftData
import XCTest

@testable import 地方客

@MainActor
final class ManualFootprintBoundaryRegressionTests: XCTestCase {
    func testManualSplitAndCustomActivitiesSurviveRestartAndIncomingOverlap() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let split = day.addingTimeInterval(30 * 60)

        let first = footprint(
            start: day,
            end: split,
            activity: "work",
            status: .manual
        )
        let second = footprint(
            start: split,
            end: day.addingTimeInterval(60 * 60),
            activity: "exercise",
            status: .manual
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        // Simulate a later sync bringing an old, unsplit automatic snapshot
        // from another device into a fresh context after the app was restarted.
        let restartedContext = ModelContext(container)
        restartedContext.insert(footprint(
            start: day,
            end: day.addingTimeInterval(60 * 60),
            activity: nil,
            status: .confirmed
        ))
        try restartedContext.save()

        _ = DataDeduplicationService.run(context: restartedContext)

        let restored = try restartedContext.fetch(
            FetchDescriptor<Footprint>(sortBy: [SortDescriptor(\.startTime)])
        )
        let manual = restored.filter { $0.status == .manual }
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(manual.count, 2)
        XCTAssertEqual(manual.map(\.startTime), [day, split])
        XCTAssertEqual(manual.map(\.endTime), [split, day.addingTimeInterval(60 * 60)])
        XCTAssertEqual(manual.map(\.activityTypeValue), ["work", "exercise"])
    }

    func testEditedActivitySuppressesLongerReplayAndRepairsStoredDuplicate() throws {
        let context = ModelContext(try makeContainer())
        let start = Date(timeIntervalSince1970: 1_726_660_000)
        let edited = footprint(start: start, end: start.addingTimeInterval(31 * 60), activity: "food", status: .manual)
        let replay = footprint(start: start, end: start.addingTimeInterval(34 * 60), activity: "family", status: .confirmed)
        context.insert(edited)
        try context.save()
        XCTAssertTrue(Footprint.automaticStayIntervals(start: replay.startTime, end: replay.endTime, context: context).isEmpty)
        context.insert(replay)
        try context.save()
        _ = DataDeduplicationService.run(context: context)
        let remaining = try context.fetch(FetchDescriptor<Footprint>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.footprintID, edited.footprintID)
        XCTAssertEqual(edited.activityTypeValue, "food")
        XCTAssertEqual(edited.endTime, start.addingTimeInterval(31 * 60))
    }

    func testManualIntervalClipsReplayButDoesNotSuppressAdjacentStay() throws {
        let start = Date(timeIntervalSince1970: 1_726_660_000)
        let manual = footprint(start: start.addingTimeInterval(600), end: start.addingTimeInterval(1200), activity: nil, status: .manual)
        let intervals = Footprint.automaticStayIntervals(start: start, end: start.addingTimeInterval(1800), manuals: [manual])
        XCTAssertEqual(intervals.map(\.start), [start, manual.endTime])
        XCTAssertEqual(intervals.map(\.end), [manual.startTime, start.addingTimeInterval(1800)])
        let adjacent = Footprint.automaticStayIntervals(start: manual.endTime, end: start.addingTimeInterval(1500), manuals: [manual])
        XCTAssertEqual(adjacent.count, 1)
        XCTAssertEqual(adjacent.first?.start, manual.endTime)
    }

    func testActivityOnlyEditContinuesDurationAfterRestart() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(1800), activity: "family", status: .confirmed)
        context.insert(stay)
        stay.updateActivityType(to: "food", in: context)
        try context.save()

        let restarted = ModelContext(container)
        XCTAssertTrue(Footprint.extendActivityEditedStay(start: start, end: start.addingTimeInterval(2400),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: restarted))
        let restored = try XCTUnwrap(restarted.fetch(FetchDescriptor<Footprint>()).first)
        XCTAssertEqual(restored.activityTypeValue, "food")
        XCTAssertEqual(restored.duration, 2400)
        XCTAssertTrue(Footprint.automaticStayIntervals(start: start, end: restored.endTime, context: restarted).isEmpty)
        restored.setManualActivityType(nil)
        XCTAssertTrue(restored.allowsAutomaticDurationExtension)
        XCTAssertTrue(Footprint.extendActivityEditedStay(start: restored.endTime, end: start.addingTimeInterval(2700),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: restarted))
        XCTAssertNil(restored.activityTypeValue)
    }

    func testExplicitManualBoundaryCannotExtendAfterActivityEdit() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(1800), activity: nil, status: .manual)
        context.insert(stay)
        stay.setManualActivityType("food")
        XCTAssertFalse(Footprint.extendActivityEditedStay(start: start, end: start.addingTimeInterval(2400),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: context))
        XCTAssertEqual(stay.duration, 1800)
    }

    func testActivityEditedStayExtendsAcrossSamplingGapButStopsAtAnotherStay() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(1800), activity: nil, status: .confirmed)
        context.insert(stay)
        stay.setManualActivityType("food")
        let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        XCTAssertTrue(Footprint.extendActivityEditedStay(start: start.addingTimeInterval(1805), end: start.addingTimeInterval(2400), coordinate: coordinate, context: context))
        let next = footprint(start: start.addingTimeInterval(2410), end: start.addingTimeInterval(2500), activity: nil, status: .manual)
        context.insert(next)
        XCTAssertFalse(Footprint.extendActivityEditedStay(start: start.addingTimeInterval(2405), end: start.addingTimeInterval(2700), coordinate: coordinate, context: context))
        XCTAssertEqual(stay.endTime, start.addingTimeInterval(2400))
    }

    func testActivityPropagationPreservesExplicitNone() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let first = footprint(start: start, end: start.addingTimeInterval(600), activity: nil, status: .manual)
        let second = footprint(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(2400), activity: nil, status: .confirmed)
        first.address = "same place"
        second.address = "same place"
        context.insert(first)
        context.insert(second)
        second.updateActivityType(to: "food", in: context)
        XCTAssertNil(first.activityTypeValue)
        XCTAssertEqual(second.activityTypeValue, "food")
    }

    func testExactCloneCleanupAfterLateImportPreservesManualDifferences() throws {
        let container = try makeContainer()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let end = day.addingTimeInterval(600)
        let context = ModelContext(container)
        context.insert(footprint(start: day, end: end, activity: "food", status: .manual))
        try context.save()
        XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: container), 0)

        let incoming = ModelContext(container)
        incoming.insert(footprint(start: day, end: end, activity: "food", status: .manual))
        let edited = footprint(start: day, end: end, activity: "food", status: .manual)
        edited.reason = "keep my note"
        incoming.insert(edited)
        incoming.insert(footprint(start: end, end: end.addingTimeInterval(600), activity: "food", status: .manual))
        try incoming.save()

        XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: container), 1)
        XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: container), 0)
        let restored = try ModelContext(container).fetch(FetchDescriptor<Footprint>())
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.filter { $0.reason == "keep my note" }.count, 1)
        XCTAssertEqual(restored.filter { $0.startTime == end }.count, 1)
    }

    func testExactTransportCloneCleanupRequiresIdenticalRouteAndManualType() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        for index in 0..<4 {
            let record = TransportRecord(day: day, startTime: day, endTime: day.addingTimeInterval(600),
                                         typeRaw: "slow", distance: 500, averageSpeed: 0.8,
                                         pointsData: Data(index == 2 ? [1, 3] : [1, 2]))
            if index == 3 { record.manualTypeRaw = "cycling" }
            context.insert(record)
        }
        try context.save()
        XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: container), 1)
        XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: container), 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TransportRecord>()), 3)
    }

    func testBackupThenCloudAndCloudThenBackupUseStableIdentity() throws {
        let source = try makeContainer()
        let sourceContext = ModelContext(source)
        let start = Date(timeIntervalSince1970: 1_726_660_000.375)
        let original = footprint(start: start, end: start.addingTimeInterval(600), activity: "food", status: .manual)
        original.countryCode = "CN"
        original.stepCount = 123
        sourceContext.insert(original)
        let trip = TransportRecord(day: original.date, startTime: start, endTime: start.addingTimeInterval(500),
                                   typeRaw: "slow", distance: 300, averageSpeed: 0.6, pointsData: Data("[]".utf8))
        sourceContext.insert(trip)
        try sourceContext.save()
        let backup = try BackupService.shared.generateBackup(footprints: [original], places: [], activities: [], transports: [trip], futureTrips: [])

        for cloudFirst in [false, true] {
            let destination = try makeContainer()
            let local = ModelContext(destination)
            func importCloud() throws {
                let incoming = ModelContext(destination)
                let copy = footprint(start: start, end: original.endTime, activity: "food", status: .manual)
                copy.footprintID = original.footprintID
                copy.countryCode = "CN"
                copy.stepCount = 123
                incoming.insert(copy)
                incoming.insert(TransportRecord(recordID: trip.recordID, day: trip.day, startTime: start,
                                               endTime: trip.endTime, typeRaw: "slow", distance: 300,
                                               averageSpeed: 0.6, pointsData: trip.pointsData))
                try incoming.save()
            }
            if cloudFirst { try importCloud() }
            _ = try BackupService.shared.restoreBackup(data: backup, context: local)
            if !cloudFirst { try importCloud() }
            _ = DataDeduplicationService.reconcileImportedDuplicates(in: destination)
            XCTAssertEqual(DataDeduplicationService.reconcileImportedDuplicates(in: destination), 0)
            let check = ModelContext(destination)
            let footprints = try check.fetch(FetchDescriptor<Footprint>())
            XCTAssertEqual(footprints.count, 1)
            XCTAssertEqual(footprints.first?.footprintID, original.footprintID)
            XCTAssertEqual(footprints.first?.countryCode, "CN")
            XCTAssertEqual(footprints.first?.stepCount, 123)
            XCTAssertEqual(try check.fetchCount(FetchDescriptor<TransportRecord>()), 1)
            let repeated = try BackupService.shared.restoreBackup(data: backup, context: check)
            XCTAssertEqual(repeated.newFootprints, 0)
            XCTAssertEqual(repeated.newTransports, 0)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Footprint.self,
            Place.self,
            TransportManualSelection.self,
            ActivityType.self,
            DailyInsight.self,
            TransportRecord.self,
            FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func footprint(
        start: Date,
        end: Date,
        activity: String?,
        status: FootprintStatus
    ) -> Footprint {
        Footprint(
            date: Calendar.current.startOfDay(for: start),
            startTime: start,
            endTime: end,
            footprintLocations: [CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)],
            locationHash: "manual-boundary-regression",
            duration: end.timeIntervalSince(start),
            status: status,
            activityTypeValue: activity
        )
    }
}

@MainActor
final class DuplicateTransportEndpointRegressionTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_726_660_000)

    private func record(offset: TimeInterval, duration: TimeInterval = 600, synthetic: Bool = false, route: [(Double, Double)]) throws -> TransportRecord {
        let start = day.addingTimeInterval(offset)
        let points = route.enumerated().map { index, coordinate in
            CodableCoordinate(lat: coordinate.0, lon: coordinate.1,
                              timestamp: start.addingTimeInterval(Double(index) * duration / Double(route.count - 1)),
                              isSyntheticPadding: synthetic)
        }
        return TransportRecord(day: day, startTime: start, endTime: start.addingTimeInterval(duration),
                               typeRaw: "car", distance: 1400, averageSpeed: 1400 / duration,
                               pointsData: try JSONEncoder().encode(points))
    }

    func testSyntheticBridgeAndObservedRoadRouteAreOneTrip() throws {
        let sparse = try record(offset: 0, synthetic: true, route: [(25, 102), (25.01, 102.01)])
        let road = try record(offset: 600, route: [
            (25, 102), (25, 102.01), (25.003, 102.01), (25.006, 102.01), (25.01, 102.01)
        ])
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(sparse, road))
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(road, sparse))
    }

    func testReturnAlongSameRoadIsSeparateTrip() throws {
        let outward = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let returning = try record(offset: 600, route: [(25.01, 102.01), (25, 102)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(outward, returning))
    }

    func testManualAdjacentTripRemainsSeparate() throws {
        let manual = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        manual.manualTypeRaw = "car"
        let automatic = try record(offset: 600, route: [(25, 102), (25.01, 102.01)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(manual, automatic))
    }

    func testSameRouteLaterInDayRemainsSeparate() throws {
        let first = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let later = try record(offset: 3600, route: [(25, 102), (25.01, 102.01)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(first, later))
    }

    func testPartialReturnIsSeparateEvenWhenRecordIntervalsWereExpanded() throws {
        let outward = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let returning = try record(offset: 600, route: [(25.01, 102.01), (25.005, 102.005)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(outward, returning))
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(returning, outward))
        // Old cleanup expanded record bounds, but raw samples still belong to
        // separate trips. The 80% record-overlap shortcut must not swallow them.
        outward.endTime = returning.endTime
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(outward, returning))
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(returning, outward))
    }

    func testAdjacentObservedTripsWithSameEndpointsRemainSeparate() throws {
        let first = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let second = try record(offset: 600, route: [(25, 102), (25.01, 102.01)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(first, second))
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(second, first))
    }

    func testSameSamplesWithShiftedRecordBoundsStillDeduplicate() throws {
        let first = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let shifted = try record(offset: 600, route: [(25, 102), (25.01, 102.01)])
        shifted.pointsData = first.pointsData
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(first, shifted))
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(shifted, first))
    }

    func testSyntheticPartialReturnRemainsSeparate() throws {
        let outward = try record(offset: 0, synthetic: true, route: [(25, 102), (25.01, 102.01)])
        let returning = try record(offset: 600, synthetic: true, route: [(25.01, 102.01), (25.005, 102.005)])
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(outward, returning))
        XCTAssertFalse(PersistentTimelineBuilder.isSameAutomaticTrip(returning, outward))
    }

    func testCleanupPreservesCompleteRouteOverDenserFragmentAndIsIdempotent() async throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let full = try record(offset: 0, route: (0...6).map { (25 + Double($0) / 600, 102) })
        let fragment = try record(offset: 200, duration: 200,
                                  route: (0...100).map { (25 + (200 + Double($0) * 2) / 60000, 102) })
        full.distance = 1110
        fragment.distance = 370
        let fullPoints = full.pointsData
        context.insert(fragment)
        context.insert(full)
        try context.save()

        for _ in 0..<2 {
            await PersistentTimelineBuilder.removeDuplicateRouteTransports(for: day, in: context)
            try context.save()
            let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
            XCTAssertEqual(remaining.count, 1)
            XCTAssertTrue(remaining.first === full)
            XCTAssertEqual(remaining.first?.pointsData, fullPoints)
            XCTAssertEqual(remaining.first?.distance, 1110)
            XCTAssertEqual(remaining.first?.startTime, day)
            XCTAssertEqual(remaining.first?.endTime, day.addingTimeInterval(600))
        }
    }

    func testCleanupRemovesBothDisconnectedBookendsCoveredByCompleteRoute() async throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        // Sorting is [complete, head, tail]. The complete route matches both
        // fragments, while the separated head and tail do not match each other.
        let complete = try record(offset: 0, route: (0...6).map { (25 + Double($0) / 600, 102) })
        let head = try record(offset: 100, duration: 100,
                              route: [(25.0017, 102), (25.0033, 102)])
        let tail = try record(offset: 400, duration: 100,
                              route: [(25.0067, 102), (25.0083, 102)])
        complete.distance = 1110
        head.distance = 180
        tail.distance = 180
        context.insert(complete)
        context.insert(head)
        context.insert(tail)
        try context.save()

        await PersistentTimelineBuilder.removeDuplicateRouteTransports(for: day, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.first === complete)
        XCTAssertEqual(remaining.first?.distance, 1110)
    }

    func testCleanupDoesNotBridgeAcrossManualTransport() async throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let before = try record(offset: 0, duration: 100,
                                route: [(25, 102), (25.002, 102)])
        let manual = try record(offset: 200, duration: 100,
                                route: [(25.004, 102), (25.006, 102)])
        manual.manualTypeRaw = "car"
        let after = try record(offset: 400, duration: 100,
                               route: [(25.008, 102), (25.01, 102)])
        let staleWideAutomatic = try record(offset: 0, duration: 500,
                                            route: (0...10).map { (25 + Double($0) / 1000, 102) })

        context.insert(before)
        context.insert(manual)
        context.insert(after)
        context.insert(staleWideAutomatic)
        try context.save()

        await PersistentTimelineBuilder.removeDuplicateRouteTransports(for: day, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 3)
        let automatic = remaining.filter { $0.manualTypeRaw == nil }.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(automatic.map(\.startTime), [day, day.addingTimeInterval(300)])
        XCTAssertEqual(automatic.map(\.endTime), [day.addingTimeInterval(200), day.addingTimeInterval(500)])
        XCTAssertTrue(remaining.contains { $0 === manual })
        XCTAssertFalse(automatic.contains { $0.startTime < manual.endTime && $0.endTime > manual.startTime })
    }

    func testInsertionHonorsManualBeforeUpdatingAnAutomaticMatch() throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let automatic = try record(offset: 0, duration: 100, route: [(25, 102), (25.002, 102)])
        let manual = try record(offset: 200, duration: 100, route: [(25.004, 102), (25.006, 102)])
        manual.manualTypeRaw = "car"
        context.insert(automatic)
        context.insert(manual)
        try context.save()
        let candidate = try record(offset: 0, duration: 500,
                                   route: (0...10).map { (25 + Double($0) / 1000, 102) })

        PersistentTimelineBuilder.insertAutomaticallyDetectedTransport(
            candidate, startOfDay: Calendar.current.startOfDay(for: day), context: context
        )

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 3)
        let automaticSegments = remaining.filter { $0.manualTypeRaw == nil }
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(automaticSegments.map(\.startTime), [day, day.addingTimeInterval(300)])
        XCTAssertEqual(automaticSegments.map(\.endTime), [
            day.addingTimeInterval(200), day.addingTimeInterval(500),
        ])
        XCTAssertTrue(automaticSegments.first === automatic)
        XCTAssertFalse(automaticSegments.contains {
            $0.startTime < manual.endTime && $0.endTime > manual.startTime
        })
        XCTAssertEqual(manual.manualTypeRaw, "car")
        XCTAssertEqual(manual.startTime, day.addingTimeInterval(200))
        XCTAssertEqual(manual.endTime, day.addingTimeInterval(300))
    }

    func testInsertionDropsCandidateFullyOwnedByManualTransport() throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let manual = try record(offset: 0, duration: 500,
                                route: [(25, 102), (25.01, 102)])
        manual.manualTypeRaw = "car"
        context.insert(manual)
        try context.save()

        let candidate = try record(offset: 100, duration: 200,
                                   route: [(25.002, 102), (25.006, 102)])
        PersistentTimelineBuilder.insertAutomaticallyDetectedTransport(
            candidate, startOfDay: Calendar.current.startOfDay(for: day), context: context
        )

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.first === manual)
    }

    func testStartupDedupReportsOneSidedManualTrim() throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let manual = try record(offset: 0, duration: 200,
                                route: [(25, 102), (25.004, 102)])
        manual.manualTypeRaw = "car"
        let automatic = try record(offset: 100, duration: 400,
                                   route: (0...8).map { (25.002 + Double($0) / 1000, 102) })
        context.insert(manual)
        context.insert(automatic)
        try context.save()

        XCTAssertEqual(DataDeduplicationService.deduplicateTransports(context: context), 1)
        XCTAssertEqual(automatic.startTime, day.addingTimeInterval(200))
        XCTAssertEqual(automatic.endTime, day.addingTimeInterval(500))
        XCTAssertFalse(automatic.startTime < manual.endTime && automatic.endTime > manual.startTime)
    }

    func testSparseSyntheticRouteSplitsAroundManualInterval() throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let manual = try record(offset: 200, duration: 100,
                                route: [(25.004, 102), (25.006, 102)])
        manual.manualTypeRaw = "car"
        let sparse = try record(offset: 0, duration: 500, synthetic: true,
                                route: [(25, 102), (25.01, 102)])
        context.insert(manual)
        context.insert(sparse)
        try context.save()

        XCTAssertEqual(DataDeduplicationService.deduplicateTransports(context: context), 1)

        let automatic = try context.fetch(FetchDescriptor<TransportRecord>())
            .filter { $0.manualTypeRaw == nil }
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(automatic.count, 2)
        XCTAssertEqual(automatic.map(\.startTime), [day, day.addingTimeInterval(300)])
        XCTAssertEqual(automatic.map(\.endTime), [
            day.addingTimeInterval(200), day.addingTimeInterval(500),
        ])
        for segment in automatic {
            let points = try JSONDecoder().decode([CodableCoordinate].self, from: segment.pointsData)
            XCTAssertGreaterThanOrEqual(points.count, 2)
            XCTAssertEqual(points.first?.timestamp, segment.startTime)
            XCTAssertEqual(points.last?.timestamp, segment.endTime)
        }
    }

    func testStartupDedupUsesCompleteRouteAndPreservesManualBoundary() throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let before = try record(offset: 0, duration: 100,
                                route: [(25, 102), (25.002, 102)])
        let manual = try record(offset: 200, duration: 100,
                                route: [(25.004, 102), (25.006, 102)])
        manual.manualTypeRaw = "car"
        let after = try record(offset: 400, duration: 100,
                               route: [(25.008, 102), (25.01, 102)])
        let staleWideAutomatic = try record(offset: 0, duration: 500,
                                            route: (0...10).map { (25 + Double($0) / 1000, 102) })

        context.insert(before)
        context.insert(manual)
        context.insert(after)
        context.insert(staleWideAutomatic)
        try context.save()

        XCTAssertEqual(DataDeduplicationService.deduplicateTransports(context: context), 2)

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 3)
        let automatic = remaining.filter { $0.manualTypeRaw == nil }.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(automatic.map(\.startTime), [day, day.addingTimeInterval(300)])
        XCTAssertEqual(automatic.map(\.endTime), [day.addingTimeInterval(200), day.addingTimeInterval(500)])
        XCTAssertTrue(remaining.contains { $0 === manual })
        XCTAssertFalse(automatic.contains { $0.startTime < manual.endTime && $0.endTime > manual.startTime })
    }

}
