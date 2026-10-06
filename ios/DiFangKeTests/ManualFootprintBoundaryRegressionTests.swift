import CoreLocation
import SwiftData
import XCTest

@testable import 地方客

@MainActor
final class ManualFootprintBoundaryRegressionTests: XCTestCase {
    func testWatchCurrentStayUsesLatestSegmentAfterMidnight() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = Calendar.current.startOfDay(for: start).addingTimeInterval(24 * 3600)
        let now = boundary.addingTimeInterval(15 * 3600)
        let coordinate = CLLocationCoordinate2D(latitude: 34.5, longitude: 112.2)
        let placeID = UUID()
        let activityID = UUID().uuidString
        let previous = Footprint(date: start, startTime: start, endTime: boundary,
                                 footprintLocations: [coordinate], locationHash: "watch-previous",
                                 duration: 0, placeID: placeID, activityTypeValue: activityID)
        let current = Footprint(date: boundary, startTime: boundary, endTime: now,
                                footprintLocations: [coordinate], locationHash: "watch-current",
                                duration: 0, placeID: placeID, activityTypeValue: activityID)
        context.insert(previous)
        context.insert(current)
        let anchor = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                verticalAccuracy: 10, timestamp: start)

        let selected = WatchSyncManager.currentStayFootprint(
            in: context, anchor: anchor, placeID: placeID, now: now, distanceThreshold: 100
        )

        XCTAssertEqual(selected?.footprintID, current.footprintID)
        XCTAssertEqual(selected?.activityTypeValue, activityID)
    }

    func testWatchCurrentStayFindsRecordStartingBeforeToday() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(28 * 3600)
        let coordinate = CLLocationCoordinate2D(latitude: 34.5, longitude: 112.2)
        let current = Footprint(date: start, startTime: start, endTime: now,
                                footprintLocations: [coordinate], locationHash: "watch-cross-day", duration: 0)
        context.insert(current)
        let anchor = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                verticalAccuracy: 10, timestamp: start)

        XCTAssertLessThan(current.startTime, Calendar.current.startOfDay(for: now))
        XCTAssertEqual(WatchSyncManager.currentStayFootprint(
            in: context, anchor: anchor, placeID: nil, now: now, distanceThreshold: 100
        )?.footprintID, current.footprintID)
    }

    func testWatchCurrentStayRejectsIgnoredAndDifferentPlaces() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(3600)
        let coordinate = CLLocationCoordinate2D(latitude: 34.5, longitude: 112.2)
        context.insert(Footprint(date: start, startTime: start, endTime: now,
                                 footprintLocations: [coordinate], locationHash: "watch-ignored",
                                 duration: 0, status: .ignored))
        context.insert(Footprint(date: start, startTime: start, endTime: now,
                                 footprintLocations: [CLLocationCoordinate2D(latitude: 35.5, longitude: 113.2)],
                                 locationHash: "watch-other-place", duration: 0))
        let anchor = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                verticalAccuracy: 10, timestamp: start)

        XCTAssertNil(WatchSyncManager.currentStayFootprint(
            in: context, anchor: anchor, placeID: nil, now: now, distanceThreshold: 100
        ))
    }

    func testCurrentStayKeepsActivityEditedFootprintAcrossAdvancedAnchor() throws {
        let context = ModelContext(try makeContainer())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let editedEnd = start.addingTimeInterval(20 * 60)
        let edited = footprint(start: start, end: editedEnd, activity: "food", status: .confirmed)
        context.insert(edited)
        edited.setManualActivityType("food")
        let anchor = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: editedEnd.addingTimeInterval(45)
        )

        let selected = WatchSyncManager.currentStayFootprint(
            in: context,
            anchor: anchor,
            placeID: nil,
            now: anchor.timestamp.addingTimeInterval(60),
            distanceThreshold: 100
        )

        XCTAssertEqual(selected?.footprintID, edited.footprintID)
        XCTAssertEqual(selected?.activityTypeValue, "food")
    }

    func testNormalSparseRoundTripIsNotMarkedAsDrift() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples: [(TimeInterval, Double, Double)] = [
            (0, 34.57522, 112.21969),
            (5 * 60, 34.54901, 112.22595),
            (7 * 60, 34.54910, 112.22780),
            (12 * 60, 34.55749, 112.22307),
            (25 * 60, 34.57522, 112.21969),
        ]
        let points = samples.map { offset, latitude, longitude in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: 40,
                verticalAccuracy: 0,
                course: 0,
                speed: -1,
                timestamp: start.addingTimeInterval(offset)
            )
        }

        XCTAssertFalse(RawLocationStore.markDriftPoints(points).contains(where: \.isDriftPoint))
    }

    func testRapidMultiPointReboundRemainsMarkedAsDrift() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples: [(TimeInterval, Double, Double)] = [
            (0, 34.57522, 112.21969),
            (10, 34.54901, 112.22595),
            (20, 34.54910, 112.22780),
            (30, 34.57522, 112.21969),
        ]
        let points = samples.map { offset, latitude, longitude in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: 40,
                verticalAccuracy: 0,
                course: 0,
                speed: -1,
                timestamp: start.addingTimeInterval(offset)
            )
        }

        XCTAssertEqual(
            RawLocationStore.markDriftPoints(points).map(\.isDriftPoint),
            [false, true, true, false]
        )
    }

    func testTransportSplitPreservesStoredOuterEndpointsAndSharesOnlyNewCutPoint() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let split = start.addingTimeInterval(5 * 60)
        let end = start.addingTimeInterval(10 * 60)
        let points = [
            CodableCoordinate(lat: 31.00, lon: 121.00, timestamp: start.addingTimeInterval(-30), isSyntheticPadding: true),
            CodableCoordinate(lat: 31.04, lon: 121.04, timestamp: start.addingTimeInterval(4 * 60)),
            CodableCoordinate(lat: 31.08, lon: 121.08, timestamp: start.addingTimeInterval(8 * 60)),
            CodableCoordinate(lat: 31.10, lon: 121.10, timestamp: end.addingTimeInterval(30), isStableStayBoundary: true)
        ]

        let routes = TransportSplitRouteBuilder.segments(
            points: points,
            startTime: start,
            splitTime: split,
            endTime: end
        )

        XCTAssertEqual(routes.first.first?.lat, points.first?.lat)
        XCTAssertEqual(routes.first.first?.lon, points.first?.lon)
        XCTAssertEqual(routes.first.first?.timestamp, points.first?.timestamp)
        XCTAssertEqual(routes.first.first?.isSyntheticPadding, points.first?.isSyntheticPadding)
        XCTAssertEqual(routes.second.last?.lat, points.last?.lat)
        XCTAssertEqual(routes.second.last?.lon, points.last?.lon)
        XCTAssertEqual(routes.second.last?.timestamp, points.last?.timestamp)
        XCTAssertEqual(routes.second.last?.isStableStayBoundary, points.last?.isStableStayBoundary)
        XCTAssertEqual(routes.first.last?.lat, routes.second.first?.lat)
        XCTAssertEqual(routes.first.last?.lon, routes.second.first?.lon)
        XCTAssertEqual(routes.first.last?.timestamp, split)
        XCTAssertEqual(routes.second.first?.timestamp, split)
        XCTAssertEqual(routes.first.last?.isSyntheticPadding, true)
    }

    func testSparseEightKilometerUrbanTripPrefersRailOverRoadHistory() {
        let duration: TimeInterval = 27 * 60
        let distance = 8_600.0
        let speed = distance / duration

        for roadPreference in [TransportType.ebike, .bus] {
            let inferred = TransportType.from(
                speed: speed,
                motionType: .automotive,
                duration: duration,
                distanceMeters: distance,
                pointCount: 6,
                observedPointCount: 4,
                preferredAutomotive: roadPreference == .bus ? .bus : .car,
                preferredCycling: .ebike,
                preferredTransport: roadPreference
            )
            XCTAssertEqual(inferred, .subway)
        }
    }

    func testFiveObservedPointsDoNotTriggerSparseUrbanRailRule() {
        let duration: TimeInterval = 27 * 60
        let distance = 8_600.0

        XCTAssertEqual(
            TransportType.from(
                speed: distance / duration,
                duration: duration,
                distanceMeters: distance,
                pointCount: 7,
                observedPointCount: 5,
                preferredCycling: .ebike,
                preferredTransport: .ebike
            ),
            .ebike
        )
    }

    func testAutomaticCarIsReclassifiedAfterItsMergedSpeedBecomesRailScale() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let distance = 124_700.0
        let duration = distance / (596.8 / 3.6)
        let record = TransportRecord(
            day: Calendar.current.startOfDay(for: start),
            startTime: start,
            endTime: start.addingTimeInterval(duration),
            typeRaw: TransportType.car.rawValue,
            distance: distance,
            averageSpeed: distance / duration,
            pointsData: Data()
        )

        XCTAssertTrue(PersistentTimelineBuilder.repairImpossibleAutomaticTransportTypes(
            [record],
            preferredAuto: .car,
            preferredCycling: .bicycle,
            preferredTransport: .car
        ))
        XCTAssertEqual(record.typeRaw, TransportType.train.rawValue)
        XCTAssertEqual(record.averageSpeed, 0)
    }

    func testImpossibleSparseTrainSpeedIsMarkedUnavailable() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let distance = 124_700.0
        let duration = distance / (596.8 / 3.6)
        let record = TransportRecord(
            day: Calendar.current.startOfDay(for: start),
            startTime: start,
            endTime: start.addingTimeInterval(duration),
            typeRaw: TransportType.train.rawValue,
            distance: distance,
            averageSpeed: distance / duration,
            pointsData: Data()
        )

        XCTAssertTrue(PersistentTimelineBuilder.repairImpossibleAutomaticTransportTypes(
            [record],
            preferredAuto: .car,
            preferredCycling: .bicycle,
            preferredTransport: .car
        ))
        XCTAssertEqual(record.typeRaw, TransportType.train.rawValue)
        XCTAssertEqual(record.averageSpeed, 0)
    }

    func testTransportTimeEditPreservesRouteDistanceAndEndpointNames() throws {
        let originalStart = Date(timeIntervalSince1970: 1_800_000_000)
        let originalEnd = originalStart.addingTimeInterval(30 * 60)
        let points = [
            CodableCoordinate(lat: 31.2304, lon: 121.4737, timestamp: originalStart),
            CodableCoordinate(lat: 31.2500, lon: 121.5000, timestamp: originalEnd),
        ]
        let pointsData = try JSONEncoder().encode(points)
        let record = TransportRecord(
            day: Calendar.current.startOfDay(for: originalStart),
            startTime: originalStart,
            endTime: originalEnd,
            startLocation: "上海虹桥站",
            endLocation: "上海站",
            typeRaw: TransportType.train.rawValue,
            distance: 18_500,
            averageSpeed: 18_500 / (30 * 60),
            pointsData: pointsData
        )

        let editedStart = originalStart.addingTimeInterval(-15 * 60)
        let editedEnd = originalEnd.addingTimeInterval(20 * 60)
        record.updateTimeRangePreservingRoute(start: editedStart, end: editedEnd)

        XCTAssertEqual(record.startTime, editedStart)
        XCTAssertEqual(record.endTime, editedEnd)
        XCTAssertEqual(record.startLocation, "上海虹桥站")
        XCTAssertEqual(record.endLocation, "上海站")
        XCTAssertEqual(record.pointsData, pointsData)
        XCTAssertEqual(record.distance, 18_500)
        XCTAssertEqual(record.averageSpeed, 18_500 / editedEnd.timeIntervalSince(editedStart), accuracy: 0.000_001)
    }

    func testStableStayBoundariesRecoverClippedShortTransportWithoutAcceptingDrift() throws {
        let base = Date(timeIntervalSince1970: 1_790_207_077)
        func point(
            _ seconds: TimeInterval,
            _ latitude: Double,
            _ longitude: Double,
            synthetic: Bool = false,
            stableBoundary: Bool = false
        ) -> CodableCoordinate {
            CodableCoordinate(
                lat: latitude,
                lon: longitude,
                timestamp: base.addingTimeInterval(seconds),
                isSyntheticPadding: synthetic,
                isStableStayBoundary: stableBoundary
            )
        }
        func record(_ points: [CodableCoordinate]) throws -> TransportRecord {
            TransportRecord(
                day: Calendar.current.startOfDay(for: base),
                startTime: base.addingTimeInterval(6),
                endTime: base.addingTimeInterval(48),
                typeRaw: TransportType.ebike.rawValue,
                distance: 377,
                averageSpeed: 377 / 42,
                pointsData: try JSONEncoder().encode(points)
            )
        }

        let clippedRealTrip = try record([
            point(0, 25.10008000, 102.73331000, synthetic: true, stableBoundary: true),
            point(6, 25.10024005, 102.73439256),
            point(18, 25.10021892, 102.73517815),
            point(30, 25.09988864, 102.73561169),
            point(42, 25.09982451, 102.73612879),
            point(54, 25.09984500, 102.73704500, synthetic: true, stableBoundary: true),
        ])
        XCTAssertTrue(PersistentTimelineBuilder.hasMinimumAutomaticTransportSpan(clippedRealTrip))

        let stationaryDrift = try record([
            point(0, 25.10008000, 102.73331000, synthetic: true, stableBoundary: true),
            point(6, 25.10009000, 102.73332000),
            point(18, 25.10007000, 102.73330000),
            point(30, 25.10010000, 102.73333000),
            point(42, 25.10008000, 102.73331000),
            point(54, 25.09984500, 102.73704500, synthetic: true, stableBoundary: true),
        ])
        XCTAssertFalse(PersistentTimelineBuilder.hasMinimumAutomaticTransportSpan(stationaryDrift))
    }

    func testAutomaticSyncReopensTransportThatEndedAtMidRoutePause() {
        let end = Date(timeIntervalSince1970: 1_790_116_740)
        func point(_ seconds: TimeInterval, _ latitude: Double, _ longitude: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                       altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                       timestamp: end.addingTimeInterval(seconds))
        }
        let stillMoving = [
            point(5, 25.0960, 102.7310),
            point(60, 25.0970, 102.7320),
            point(120, 25.0980, 102.7340),
            point(220, 25.0997, 102.7370)
        ]
        XCTAssertTrue(PersistentTimelineBuilder.hasTransportSizedMovementAfterPrematureEnd(
            recordEnd: end, footprintStart: end.addingTimeInterval(240),
            footprintEnd: end.addingTimeInterval(1_200), rawPoints: stillMoving
        ))

        let stationary = [
            point(5, 25.09970, 102.73700),
            point(120, 25.09973, 102.73702),
            point(220, 25.09969, 102.73701)
        ]
        XCTAssertFalse(PersistentTimelineBuilder.hasTransportSizedMovementAfterPrematureEnd(
            recordEnd: end, footprintStart: end,
            footprintEnd: end.addingTimeInterval(1_200), rawPoints: stationary
        ))
    }

    func testAutomaticDepartureWatchBoostsOnFirstAccurateMovingFix() {
        let now = Date()
        let anchor = CLLocation(latitude: 31.2304, longitude: 121.4737)
        func fix(latitude: Double, speed: CLLocationSpeed) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 121.4737),
                       altitude: 0, horizontalAccuracy: 15, verticalAccuracy: 15,
                       course: -1, speed: speed, timestamp: now)
        }

        XCTAssertTrue(LocationManager.hasPromptAutomaticDepartureEvidence(
            fix(latitude: 31.23075, speed: 3), from: anchor
        ))
        XCTAssertFalse(LocationManager.hasPromptAutomaticDepartureEvidence(
            fix(latitude: 31.23048, speed: 3), from: anchor
        ))
        XCTAssertFalse(LocationManager.hasPromptAutomaticDepartureEvidence(
            fix(latitude: 31.23075, speed: 0.2), from: anchor
        ))
    }

    func testReportedHighSpeedConfirmsDepartureAfterMeaningfulDistance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: now.addingTimeInterval(-3600)
        )
        func fix(latitude: Double) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 121.4737),
                altitude: 0,
                horizontalAccuracy: 180,
                verticalAccuracy: 20,
                course: 0,
                speed: 40,
                timestamp: now
            )
        }

        XCTAssertTrue(LocationManager.hasConfirmedDeparture(
            from: anchor,
            to: fix(latitude: 31.2360),
            isSamePlace: true,
            isMovingBySensor: false,
            now: now
        ))
        XCTAssertFalse(LocationManager.hasConfirmedDeparture(
            from: anchor,
            to: fix(latitude: 31.2330),
            isSamePlace: false,
            isMovingBySensor: true,
            now: now
        ))
    }

    func testWatchShowsProvisionalMovingStateBeforeTransportIsPersisted() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let presentation = WatchSyncManager.currentTransportPresentation(
            persistedType: nil,
            persistedStartedAt: nil,
            isCurrentlyMoving: true,
            provisionalType: WatchSyncManager.provisionalMovingType,
            provisionalStartedAt: startedAt
        )

        XCTAssertEqual(presentation.type, WatchSyncManager.provisionalMovingType)
        XCTAssertEqual(presentation.startedAt, startedAt)
    }

    func testCurrentMovementAverageSpeedMatchesTransportDistanceOverDuration() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 50,
            timestamp: now.addingTimeInterval(-60)
        )
        let last = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2394, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 1,
            timestamp: now
        )
        let expected = first.distance(from: last) / 60

        let calculated = WatchSyncManager.currentMovementAverageSpeed(
            persistedAverageSpeed: nil,
            locations: [first, last],
            movingStartedAt: first.timestamp,
            now: now,
            isCurrentlyMoving: true
        )
        XCTAssertNotNil(calculated)
        XCTAssertEqual(calculated!, expected, accuracy: 0.001)
        XCTAssertEqual(
            WatchSyncManager.currentMovementAverageSpeed(
                persistedAverageSpeed: 12.5,
                locations: [first, last],
                movingStartedAt: first.timestamp,
                now: now,
                isCurrentlyMoving: true
            ),
            12.5
        )
        XCTAssertNil(
            WatchSyncManager.currentMovementAverageSpeed(
                persistedAverageSpeed: 12.5,
                locations: [first, last],
                movingStartedAt: first.timestamp,
                now: now,
                isCurrentlyMoving: false
            )
        )
    }

    func testWatchDoesNotInventTransportBeforeDepartureIsConfirmed() {
        let presentation = WatchSyncManager.currentTransportPresentation(
            persistedType: nil,
            persistedStartedAt: nil,
            isCurrentlyMoving: false,
            provisionalType: TransportType.car.rawValue,
            provisionalStartedAt: Date()
        )

        XCTAssertNil(presentation.type)
        XCTAssertNil(presentation.startedAt)
    }

    func testWatchAndLiveActivitySelectTheSameCurrentTransport() throws {
        let context = ModelContext(try makeContainer())
        let movingStartedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = TransportRecord(
            day: Calendar.current.startOfDay(for: movingStartedAt),
            startTime: movingStartedAt.addingTimeInterval(-20 * 60),
            endTime: movingStartedAt.addingTimeInterval(-30),
            typeRaw: TransportType.subway.rawValue,
            distance: 8_000,
            averageSpeed: 10,
            pointsData: Data()
        )
        let current = TransportRecord(
            day: Calendar.current.startOfDay(for: movingStartedAt),
            startTime: movingStartedAt,
            endTime: movingStartedAt.addingTimeInterval(90),
            typeRaw: TransportType.bicycle.rawValue,
            distance: 500,
            averageSpeed: 5,
            pointsData: Data()
        )
        context.insert(previous)
        context.insert(current)

        let selected = WatchSyncManager.currentTransportRecord(
            in: context,
            now: movingStartedAt.addingTimeInterval(90),
            isCurrentlyMoving: true,
            movingStartedAt: movingStartedAt
        )

        XCTAssertEqual(selected?.recordID, current.recordID)
        XCTAssertEqual(selected?.typeRaw, TransportType.bicycle.rawValue)
    }

    func testAutomaticStartDoesNotKeepOldHeartbeatOrMergedStart() throws {
        let oldStayEnd = Date(timeIntervalSince1970: 1_726_660_000)
        let firstFix = oldStayEnd.addingTimeInterval(900)
        let moving = [
            CodableCoordinate(lat: 31.2350, lon: 121.4800, timestamp: firstFix),
            CodableCoordinate(lat: 31.2355, lon: 121.4810, timestamp: firstFix.addingTimeInterval(15)),
            CodableCoordinate(lat: 31.2360, lon: 121.4820, timestamp: firstFix.addingTimeInterval(30))
        ]
        let anchor = CodableCoordinate(lat: 31.2304, lon: 121.4737,
                                       timestamp: oldStayEnd, isSyntheticPadding: true)
        func record(_ points: [CodableCoordinate]) throws -> TransportRecord {
            TransportRecord(day: Calendar.current.startOfDay(for: oldStayEnd),
                            startTime: oldStayEnd, endTime: firstFix.addingTimeInterval(30),
                            typeRaw: TransportType.car.rawValue, distance: 1_000,
                            averageSpeed: 1, pointsData: try JSONEncoder().encode(points))
        }

        let withStay = try record([anchor] + moving)
        let inferred = PersistentTimelineBuilder.automaticTransportStart(
            withStay, proposedStart: oldStayEnd, trustedStart: oldStayEnd
        )
        XCTAssertGreaterThan(inferred, firstFix.addingTimeInterval(-121))
        XCTAssertLessThanOrEqual(inferred, firstFix)

        let withoutStay = try record(moving)
        XCTAssertEqual(PersistentTimelineBuilder.automaticTransportStart(
            withoutStay, proposedStart: oldStayEnd, trustedStart: oldStayEnd
        ), firstFix)
    }

    func testSchoolStopBetweenTripsSurvivesFifteenMinuteLocationGap() throws {
        let base = Date(timeIntervalSince1970: 1_790_082_000)
        func point(_ seconds: TimeInterval, _ latitude: Double, _ longitude: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                       altitude: 0, horizontalAccuracy: 15, verticalAccuracy: 15,
                       timestamp: base.addingTimeInterval(seconds))
        }
        let points = [
            point(0, 25.09985, 102.73705),
            point(60, 25.0970, 102.7300),
            point(120, 25.09596, 102.72070),
            point(150, 25.09594, 102.72069),
            point(180, 25.09592, 102.72068),
            point(240, 25.09591, 102.72068),
            point(1_152, 25.09773, 102.72616),
            point(1_212, 25.09975, 102.73702)
        ]
        let stop = try XCTUnwrap(PersistentTimelineBuilder.dormantGapStay(in: points))
        XCTAssertEqual(stop.arrivalIndex, 2)
        XCTAssertEqual(stop.resumeIndex, 6)
        XCTAssertEqual(stop.start, points[2].timestamp)
        XCTAssertEqual(stop.end, points[5].timestamp.addingTimeInterval(300))
    }

    func testConfirmedLowPowerStayIsReadyBeforeDepartureFix() throws {
        let start = Date(timeIntervalSince1970: 1_726_660_000)
        let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let points = (0...6).map { index in
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 12,
                       verticalAccuracy: 12, timestamp: start.addingTimeInterval(Double(index * 60)))
        }

        let candidate = try XCTUnwrap(FootprintProcessor.shared.confirmedStationaryCandidate(
            in: points, near: points[0]
        ))
        XCTAssertEqual(candidate.startTime, start)
        XCTAssertEqual(candidate.endTime, points.last?.timestamp)
        XCTAssertEqual(candidate.rawLocations.count, points.count)
    }

    func testAutomaticTransportKeepsPreviousStayAsStartAcrossDormantGap() {
        let departure = Date(timeIntervalSince1970: 1_726_660_000)
        let stay = CodableCoordinate(
            lat: 31.2304,
            lon: 121.4737,
            timestamp: departure.addingTimeInterval(-3600),
            isSyntheticPadding: true
        )
        let firstDetectedMovement = CodableCoordinate(
            lat: 31.2384,
            lon: 121.4937,
            timestamp: departure
        )
        let laterMovement = CodableCoordinate(
            lat: 31.2400,
            lon: 121.5000,
            timestamp: departure.addingTimeInterval(60)
        )

        let anchored = TimelineBuilder.anchoringAutomaticTransportStart(
            [firstDetectedMovement, laterMovement],
            at: stay
        )

        XCTAssertEqual(anchored.count, 3)
        XCTAssertEqual(anchored.first?.lat, stay.lat)
        XCTAssertEqual(anchored.first?.lon, stay.lon)
        XCTAssertEqual(anchored.first?.isSyntheticPadding, true)
        XCTAssertEqual(anchored[1].lat, firstDetectedMovement.lat)
        XCTAssertEqual(anchored[1].lon, firstDetectedMovement.lon)
    }

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

    func testMetadataEditThenActivityEditExtendsSameStayAcrossSamplingGap() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(17 * 60), activity: nil, status: .confirmed)
        context.insert(stay)
        stay.reason = "edited note"
        stay.address = "edited place"
        stay.photoAssetIDs = ["kept-photo"]
        stay.markManualMetadataEdit()
        stay.setManualActivityType("visit")
        try context.save()

        let restarted = ModelContext(container)
        XCTAssertTrue(Footprint.extendActivityEditedStay(
            start: stay.endTime.addingTimeInterval(120), end: start.addingTimeInterval(30 * 60),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: restarted
        ))
        let remaining = try restarted.fetch(FetchDescriptor<Footprint>())
        XCTAssertEqual(remaining.count, 1)
        let restored = try XCTUnwrap(remaining.first)
        XCTAssertEqual(restored.footprintID, stay.footprintID)
        XCTAssertEqual(restored.endTime, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(restored.activityTypeValue, "visit")
        XCTAssertEqual(restored.reason, "edited note")
        XCTAssertEqual(restored.address, "edited place")
        XCTAssertEqual(restored.photoAssetIDs, ["kept-photo"])
    }

    func testMetadataEditDoesNotUnlockExplicitSplitBoundary() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(1800), activity: nil, status: .manual)
        context.insert(stay)
        stay.markManualMetadataEdit()
        stay.setManualActivityType("visit")
        XCTAssertFalse(stay.allowsAutomaticDurationExtension)
        XCTAssertFalse(Footprint.extendActivityEditedStay(
            start: stay.endTime.addingTimeInterval(120), end: start.addingTimeInterval(2400),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: context
        ))
    }

    func testEditedStayCannotExtendAcrossTransportInSamplingGap() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(1800), activity: "visit", status: .confirmed)
        context.insert(stay)
        stay.markManualMetadataEdit()
        context.insert(TransportRecord(
            day: start, startTime: stay.endTime.addingTimeInterval(10),
            endTime: stay.endTime.addingTimeInterval(90), typeRaw: "slow", distance: 100,
            averageSpeed: 1, pointsData: Data("[]".utf8)
        ))
        XCTAssertFalse(Footprint.extendActivityEditedStay(
            start: stay.endTime.addingTimeInterval(120), end: start.addingTimeInterval(2400),
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), context: context
        ))
        XCTAssertEqual(stay.endTime, start.addingTimeInterval(1800))
    }

    func testAdjacentAutomaticDuplicateIsAbsorbedIntoEditedStay() throws {
        let context = ModelContext(try makeContainer())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_726_660_000))
        let stay = footprint(start: start, end: start.addingTimeInterval(17 * 60), activity: "visit", status: .manual)
        let duplicate = footprint(start: stay.endTime, end: start.addingTimeInterval(26 * 60), activity: nil, status: .confirmed)
        stay.reason = "kept note"
        stay.photoAssetIDs = ["original-photo"]
        duplicate.photoAssetIDs = ["new-photo"]
        context.insert(stay)
        context.insert(duplicate)
        XCTAssertTrue(Footprint.absorbAdjacentAutomaticContinuations(
            [stay, duplicate], transports: [], context: context
        ))
        let remaining = try context.fetch(FetchDescriptor<Footprint>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.footprintID, stay.footprintID)
        XCTAssertEqual(stay.activityTypeValue, "visit")
        XCTAssertEqual(stay.reason, "kept note")
        XCTAssertEqual(stay.endTime, start.addingTimeInterval(26 * 60))
        XCTAssertEqual(stay.photoAssetIDs, ["original-photo", "new-photo"])
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

    func testAdjacentObservedTripsWithSameDirectedEndpointsMerge() throws {
        // Zero real-world gap, same direction, matching A/B endpoints: this
        // is what a single physical trip looks like when Health/Motion
        // flips its activity guess partway through (e.g. briefly read as
        // walking, then correctly as automotive), producing two adjacent
        // TransportRecords for one continuous movement. Two genuinely
        // separate trips cannot share this exact shape, since that would
        // require instantly teleporting back to A with no dwell at all.
        let first = try record(offset: 0, route: [(25, 102), (25.01, 102.01)])
        let second = try record(offset: 600, route: [(25, 102), (25.01, 102.01)])
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(first, second))
        XCTAssertTrue(PersistentTimelineBuilder.isSameAutomaticTrip(second, first))
    }

    func testPostGapFillMergeCombinesAdjacentRailSegments() async throws {
        let schema = Schema([
            Footprint.self, Place.self, TransportManualSelection.self, ActivityType.self,
            DailyInsight.self, TransportRecord.self, FutureTrip.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let first = try record(
            offset: 0,
            duration: 6 * 60,
            route: [(25.0000, 102.0000), (25.0200, 102.0200)]
        )
        first.typeRaw = TransportType.train.rawValue
        first.distance = 3_600
        first.averageSpeed = first.distance / first.endTime.timeIntervalSince(first.startTime)
        let second = try record(
            offset: 7 * 60,
            duration: 27 * 60,
            route: [(25.0200, 102.0200), (25.1600, 102.1600)]
        )
        second.typeRaw = TransportType.train.rawValue
        second.distance = 20_600
        second.averageSpeed = second.distance / second.endTime.timeIntervalSince(second.startTime)
        let expectedEnd = second.endTime
        context.insert(first)
        context.insert(second)
        try context.save()

        await PersistentTimelineBuilder.mergeConsecutiveTransports(for: day, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TransportRecord>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.startTime, first.startTime)
        XCTAssertEqual(remaining.first?.endTime, expectedEnd)
        XCTAssertEqual(remaining.first?.distance, 24_200)
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
