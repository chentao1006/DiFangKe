import CoreLocation
import MapKit
import SwiftData
import XCTest

@testable import 地方客

@MainActor
final class ManualFootprintBoundaryRegressionTests: XCTestCase {
    func testTransportSplitsAutoExtendedActivityButPreservesFixedManualTime() async throws {
        for extendable in [true, false] {
            let context = ModelContext(try makeContainer())
            let day = Calendar.current.startOfDay(for: Date())
            let start = day.addingTimeInterval(13 * 3600 + 50 * 60)
            let departure = day.addingTimeInterval(19 * 3600 + 50 * 60)
            let arrival = day.addingTimeInterval(20 * 3600 + 14 * 60)
            let end = day.addingTimeInterval(21 * 3600 + 6 * 60)
            let home = CLLocationCoordinate2D(latitude: 25.09975, longitude: 102.73702)
            let away = CLLocationCoordinate2D(latitude: 25.1032, longitude: 102.7348)
            let original = Footprint(date: day, startTime: start, endTime: end,
                                     footprintLocations: [home, away, home], locationHash: "home",
                                     duration: 0, reason: "keep note", status: .manual,
                                     photoAssetIDs: ["keep-photo"], address: "家", activityTypeValue: "home")
            original.allowsAutomaticDurationExtension = extendable
            let originalID = original.footprintID
            context.insert(original)
            context.insert(TransportRecord(day: day, startTime: departure, endTime: arrival,
                                           typeRaw: TransportType.bicycle.rawValue, distance: 2800,
                                           averageSpeed: 2, pointsData: Data()))
            func point(_ coordinate: CLLocationCoordinate2D, _ timestamp: Date) -> CLLocation {
                CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: timestamp)
            }
            await PersistentTimelineBuilder.splitFootprintsByTransports(
                for: day, in: context,
                allRawPoints: [point(home, start), point(away, departure), point(home, arrival)]
            )
            let stays = try context.fetch(FetchDescriptor<Footprint>(sortBy: [SortDescriptor(\.startTime)]))
            XCTAssertEqual(stays.count, extendable ? 2 : 1)
            XCTAssertEqual(original.footprintID, originalID)
            XCTAssertEqual(original.reason, "keep note")
            XCTAssertEqual(original.photoAssetIDs, ["keep-photo"])
            XCTAssertEqual(original.activityTypeValue, "home")
            XCTAssertEqual(original.endTime, extendable ? departure : end)
            if extendable {
                XCTAssertEqual(stays.last?.startTime, arrival)
                XCTAssertEqual(stays.last?.endTime, end)
                XCTAssertFalse(original.allowsAutomaticDurationExtension)
                XCTAssertTrue(stays.last?.allowsAutomaticDurationExtension == true)
                XCTAssertTrue(stays.allSatisfy { $0.coordinates.allSatisfy { $0.latitude == home.latitude } })
                // A second refresh must not keep splitting or create duplicates.
                await PersistentTimelineBuilder.splitFootprintsByTransports(for: day, in: context)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<Footprint>()), 2)
            }
        }
    }

    func testAlreadyOverextendedStayCannotContinueAcrossEmbeddedTransport() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let end = now.addingTimeInterval(-30)
        let home = CLLocationCoordinate2D(latitude: 25.09975, longitude: 102.73702)
        let footprint = Footprint(date: start, startTime: start, endTime: end,
                                  footprintLocations: [home], locationHash: "home", duration: 0, status: .manual)
        footprint.allowsAutomaticDurationExtension = true
        context.insert(footprint)
        context.insert(TransportRecord(day: start, startTime: start.addingTimeInterval(600),
                                       endTime: start.addingTimeInterval(1200), typeRaw: TransportType.bicycle.rawValue,
                                       distance: 1000, averageSpeed: 2, pointsData: Data()))
        let anchor = CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start)
        let current = CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now)
        XCTAssertFalse(Footprint.continueCurrentEditedStay(footprint, anchor: anchor, current: current,
                                                         rawPoints: [], context: context, holdingStationaryStay: true))
        XCTAssertFalse(Footprint.extendActivityEditedStay(start: end, end: now, coordinate: home, context: context))
        XCTAssertEqual(footprint.endTime, end)
    }

    func testExistingClassifierPreservesStayBetweenTwoTransports() async throws {
        let context = ModelContext(try makeContainer())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60)
        let home = CLLocationCoordinate2D(latitude: 25.09975, longitude: 102.73702)
        for (a, b) in [(start.addingTimeInterval(-600), start), (end, end.addingTimeInterval(600))] {
            context.insert(TransportRecord(day: Calendar.current.startOfDay(for: start), startTime: a, endTime: b,
                                           typeRaw: TransportType.bicycle.rawValue, distance: 1000,
                                           averageSpeed: 2, pointsData: Data()))
        }
        let points = (0...8).map { minute in
            CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(Double(minute) * 60))
        }
        // Exercise the existing classifier, not a parallel stay heuristic.
        await PersistentTimelineBuilder.processPoints(points: points, date: start, context: context)
        let stays = try context.fetch(FetchDescriptor<Footprint>())
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays.first?.startTime, start)
        XCTAssertEqual(stays.first?.endTime, end)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransportRecord>()).count, 2)
    }

    func testCurrentStayDoesNotHideEarlierEditedVisitAcrossTransport() throws {
        let context = ModelContext(try makeContainer())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let departure = start.addingTimeInterval(6 * 3600)
        let returned = departure.addingTimeInterval(24 * 60)
        let home = CLLocationCoordinate2D(latitude: 25.09975, longitude: 102.73702)
        let old = Footprint(date: start, startTime: start, endTime: departure,
                            footprintLocations: [home], locationHash: "old-home", duration: 0, status: .manual)
        old.allowsAutomaticDurationExtension = true
        let current = Footprint(date: start, startTime: returned, endTime: returned.addingTimeInterval(1200),
                                footprintLocations: [home], locationHash: "returned-home", duration: 0)
        context.insert(old)
        context.insert(current)
        context.insert(TransportRecord(day: Calendar.current.startOfDay(for: start), startTime: departure,
                                       endTime: returned, typeRaw: TransportType.bicycle.rawValue,
                                       distance: 1700, averageSpeed: 3, pointsData: Data()))
        let anchor = CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: start)
        let now = returned.addingTimeInterval(1200)
        let selected = WatchSyncManager.currentStayFootprint(in: context, anchor: anchor, placeID: nil,
                                                           now: now, distanceThreshold: 100)
        XCTAssertEqual(selected?.footprintID, current.footprintID)
        XCTAssertEqual(WatchSyncManager.continuousStayStart(
            anchorStart: start, persistedStart: selected?.startTime, persistedEnd: selected?.endTime,
            interruptionEnd: WatchSyncManager.latestStayInterruptionEnd(in: context, after: start, now: now)
        ), returned)
    }

    func testFootprintCameraUsesRawTimeWindowInsteadOfUntrimmedStoredCoordinates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60)
        let home = CLLocationCoordinate2D(latitude: 25.0997, longitude: 102.737)
        let outside = CLLocationCoordinate2D(latitude: 25.12, longitude: 102.72)
        func point(_ coordinate: CLLocationCoordinate2D, _ date: Date) -> CLLocation {
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                       verticalAccuracy: 10, timestamp: date)
        }
        let coordinates = FootprintCameraFraming.coordinates(
            rawPoints: [point(outside, start.addingTimeInterval(-1)), point(home, start),
                        point(home, end.addingTimeInterval(-1)), point(outside, end),
                        point(outside, end.addingTimeInterval(1))],
            start: start, end: end, fallback: [home, outside]
        )
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertTrue(coordinates.allSatisfy { $0.latitude == home.latitude && $0.longitude == home.longitude })
        let fallback = FootprintCameraFraming.coordinates(rawPoints: [], start: start, end: end, fallback: [home])
        XCTAssertEqual(fallback.first?.latitude, home.latitude)
    }

    func testFootprintCameraExcludesOctober8DepartureBoundary() throws {
        // Actual consecutive fixes from the supplied 2026-10-08 CSV.
        let start = Date(timeIntervalSince1970: 1791388800)
        let departure = Date(timeIntervalSince1970: 1791414687.598)
        let home = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 25.09970518, longitude: 102.73703525),
                              altitude: 0, horizontalAccuracy: 14.72, verticalAccuracy: 10,
                              timestamp: Date(timeIntervalSince1970: 1791414105.999))
        let moving = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 25.09604651, longitude: 102.72064523),
                                altitude: 0, horizontalAccuracy: 21, verticalAccuracy: 10, timestamp: departure)
        let stay = FootprintCameraFraming.coordinates(rawPoints: [home, moving], start: start, end: departure,
                                                    fallback: [home.coordinate, moving.coordinate])
        XCTAssertEqual(stay.count, 1)
        XCTAssertEqual(stay.first?.longitude, home.coordinate.longitude)
        let rect = try XCTUnwrap(FootprintCameraFraming.mapRect(
            coordinates: stay, viewport: CGSize(width: 390, height: 844),
            visibleRect: CGRect(x: 31.2, y: 84.4, width: 327.6, height: 278.52)
        ))
        XCTAssertLessThan(rect.width * MKMetersPerMapPointAtLatitude(home.coordinate.latitude), 300)
        let next = FootprintCameraFraming.coordinates(rawPoints: [home, moving], start: departure,
                                                    end: departure.addingTimeInterval(60), fallback: [])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.longitude, moving.coordinate.longitude)
    }

    func testFootprintCameraFitsLocalClusterAboveDetailSheet() throws {
        let viewport = CGSize(width: 390, height: 844)
        let visible = CGRect(x: 31.2, y: 84.4, width: 327.6, height: 278.52)
        // Synthetic local cluster, not a reconstruction of the user's raw data.
        let coordinates = (0..<73).map { index in
            CLLocationCoordinate2D(latitude: 25.0997 + Double(index % 9) * 0.00002,
                                   longitude: 102.737 + Double(index / 9) * 0.00002)
        }
        let rect = try XCTUnwrap(FootprintCameraFraming.mapRect(
            coordinates: coordinates, viewport: viewport, visibleRect: visible
        ))
        XCTAssertEqual(rect.width / rect.height, viewport.width / viewport.height, accuracy: 0.000001)
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            let screen = CGPoint(x: (point.x - rect.minX) / rect.width * viewport.width,
                                 y: (point.y - rect.minY) / rect.height * viewport.height)
            XCTAssertTrue(visible.contains(screen))
        }
        let widthMeters = rect.width * MKMetersPerMapPointAtLatitude(25.0997)
        XCTAssertLessThan(widthMeters, 200)
    }

    func testFootprintCameraScalesWithItsOwnPoints() throws {
        let viewport = CGSize(width: 390, height: 844)
        let visible = CGRect(x: 31, y: 84, width: 328, height: 279)
        let center = CLLocationCoordinate2D(latitude: 25.1, longitude: 102.7)
        let small = try XCTUnwrap(FootprintCameraFraming.mapRect(
            coordinates: [center], viewport: viewport, visibleRect: visible
        ))
        let large = try XCTUnwrap(FootprintCameraFraming.mapRect(
            coordinates: [center, CLLocationCoordinate2D(latitude: 25.11, longitude: 102.71)],
            viewport: viewport, visibleRect: visible
        ))
        XCTAssertGreaterThan(large.width, small.width * 5)
        let point = MKMapPoint(center)
        XCTAssertEqual((point.x - small.minX) / small.width * viewport.width, visible.midX, accuracy: 0.001)
        XCTAssertEqual((point.y - small.minY) / small.height * viewport.height, visible.midY, accuracy: 0.001)
    }

    func testFootprintCameraRejectsMissingGeometryAndInvalidPoints() {
        let coordinate = CLLocationCoordinate2D(latitude: 25, longitude: 102)
        XCTAssertNil(FootprintCameraFraming.mapRect(coordinates: [coordinate], viewport: .zero, visibleRect: .zero))
        XCTAssertNil(FootprintCameraFraming.mapRect(coordinates: [], viewport: CGSize(width: 390, height: 844),
                                                 visibleRect: CGRect(x: 0, y: 0, width: 390, height: 400)))
        XCTAssertNil(FootprintCameraFraming.mapRect(
            coordinates: [CLLocationCoordinate2D(latitude: .nan, longitude: 102)],
            viewport: CGSize(width: 390, height: 844),
            visibleRect: CGRect(x: 0, y: 0, width: 390, height: 400)
        ))
    }

    func testFootprintCameraKeepsDateLineClusterLocal() throws {
        let rect = try XCTUnwrap(FootprintCameraFraming.mapRect(
            coordinates: [CLLocationCoordinate2D(latitude: 25, longitude: 179.999),
                          CLLocationCoordinate2D(latitude: 25, longitude: -179.999)],
            viewport: CGSize(width: 390, height: 844),
            visibleRect: CGRect(x: 31, y: 84, width: 328, height: 279)
        ))
        XCTAssertLessThan(rect.width, MKMapRect.world.width / 1000)
    }

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

    // Exact exported fixes around the October 9 morning offset, including
    // two origin fixes and the return plus its independent confirmation.
    private func morningOffsetPoints() -> [CLLocation] {
        let samples: [(TimeInterval, Double, Double, Double, Double)] = [
            (1791499086.873, 25.09985375, 102.73720423, 9.04, 3.35),
            (1791499104.343, 25.09985898, 102.73720793, 8.98, 5.86),
            (1791499117.018, 25.10208266, 102.73930454, 68.30, -1.00),
            (1791499123.017, 25.10232427, 102.73883445, 50.77, -1.00),
            (1791499129.017, 25.10280425, 102.73807717, 37.18, -1.00),
            (1791499135.015, 25.10289682, 102.73804958, 23.37, -1.00),
            (1791499141.016, 25.10290307, 102.73811296, 15.29, 2.09),
            (1791499148.174, 25.10287402, 102.73816058, 13.11, -1.00),
            (1791499154.013, 25.10287923, 102.73814212, 12.41, 3.13),
            (1791499160.013, 25.10293784, 102.73803277, 11.05, 0.00),
            (1791499167.748, 25.10291113, 102.73808125, 10.41, -1.00),
            (1791499173.016, 25.10288476, 102.73816073, 8.55, -1.00),
            (1791499201.377, 25.10290785, 102.73824227, 7.60, -1.00),
            (1791499209.014, 25.10291660, 102.73825397, 7.60, 2.90),
            (1791499218.774, 25.10292747, 102.73825489, 10.17, 2.28),
            (1791499252.013, 25.09990453, 102.73722546, 11.36, -1.00),
            (1791499371.399, 25.09986046, 102.73720672, 10.25, -1.00),
        ]
        return samples.map { time, latitude, longitude, accuracy, speed in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 0,
                       course: 0, speed: speed, timestamp: Date(timeIntervalSince1970: time))
        }
    }

    func testMorningOffsetClusterIsDriftButOriginAndReturnArePreserved() {
        let points = morningOffsetPoints()
        let marked = RawLocationStore.markDriftPoints(points)
        XCTAssertEqual(marked.filter(\.isDriftPoint).map(\.originalIndex), Array(2...14))
        XCTAssertEqual(RawLocationStore.filterRidiculousSpikes(points).count, 4)
    }

    func testMorningOffsetRequiresReturn() {
        let points = Array(morningOffsetPoints().dropLast(2))
        XCTAssertFalse(RawLocationStore.markDriftPoints(points).contains(where: \.isDriftPoint))
        let withReturn = Array(morningOffsetPoints().dropLast())
        XCTAssertEqual(RawLocationStore.markDriftPoints(withReturn).filter(\.isDriftPoint).count, 13)
    }

    func testShortRoundTripWithMeasuredVehicleSpeedIsPreserved() {
        let points = morningOffsetPoints().enumerated().map { index, point in
            CLLocation(coordinate: point.coordinate, altitude: 0,
                       horizontalAccuracy: point.horizontalAccuracy, verticalAccuracy: 0,
                       course: 0, speed: index == 2 ? 25 : point.speed, timestamp: point.timestamp)
        }
        XCTAssertFalse(RawLocationStore.markDriftPoints(points).contains(where: \.isDriftPoint))
    }

    func testSlowShortRoundTripIsPreserved() {
        let original = morningOffsetPoints()
        let start = original[0].timestamp
        let points = original.map { point in
            CLLocation(coordinate: point.coordinate, altitude: 0,
                       horizontalAccuracy: point.horizontalAccuracy, verticalAccuracy: 0,
                       course: 0, speed: point.speed,
                       timestamp: start.addingTimeInterval(point.timestamp.timeIntervalSince(start) * 3))
        }
        XCTAssertFalse(RawLocationStore.markDriftPoints(points).contains(where: \.isDriftPoint))
    }

    func testDenseMorningOffsetDoesNotHideReturn() {
        let original = morningOffsetPoints()
        var points: [CLLocation] = []
        for point in original {
            points.append(point)
            points.append(CLLocation(coordinate: point.coordinate, altitude: 0,
                                     horizontalAccuracy: point.horizontalAccuracy, verticalAccuracy: 0,
                                     course: 0, speed: point.speed,
                                     timestamp: point.timestamp.addingTimeInterval(0.1)))
        }
        XCTAssertEqual(RawLocationStore.markDriftPoints(points).filter(\.isDriftPoint).count, 26)
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

    func testIndoorWalkingDoesNotCloseLongStayFromSingleShiftedFix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: now.addingTimeInterval(-9 * 3600)
        )
        let shiftedFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2320, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: 10,
            course: -1,
            speed: 0.2,
            timestamp: now
        )

        XCTAssertFalse(LocationManager.hasConfirmedDeparture(
            from: anchor,
            to: shiftedFix,
            isSamePlace: false,
            isMovingBySensor: true,
            now: now
        ))
    }

    func testSustainedWalkingConfirmsDepartureFromLongStay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: now.addingTimeInterval(-9 * 3600)
        )
        let firstOutsideFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2320, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 15,
            verticalAccuracy: 10,
            course: 0,
            speed: 1.2,
            timestamp: now.addingTimeInterval(-20)
        )
        let continuedFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.23225, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 15,
            verticalAccuracy: 10,
            course: 0,
            speed: 1.2,
            timestamp: now
        )

        XCTAssertTrue(LocationManager.hasConfirmedDeparture(
            from: anchor,
            to: continuedFix,
            isSamePlace: false,
            isMovingBySensor: true,
            previousCandidate: firstOutsideFix,
            now: now
        ))
    }

    func testCurrentStayKeepsEarlierOverlappingPersistedStart() {
        let anchorStart = Date(timeIntervalSince1970: 1_800_034_200)
        let persistedStart = Date(timeIntervalSince1970: 1_800_000_000)
        let persistedEnd = Date(timeIntervalSince1970: 1_800_037_440)

        XCTAssertEqual(
            WatchSyncManager.continuousStayStart(
                anchorStart: anchorStart,
                persistedStart: persistedStart,
                persistedEnd: persistedEnd
            ),
            persistedStart
        )
    }

    func testCurrentStayDoesNotResumeFootprintThatEndedBeforeAnchor() {
        let anchorStart = Date(timeIntervalSince1970: 1_800_034_200)
        let persistedStart = Date(timeIntervalSince1970: 1_800_000_000)
        let persistedEnd = anchorStart.addingTimeInterval(-1)

        XCTAssertEqual(
            WatchSyncManager.continuousStayStart(
                anchorStart: anchorStart,
                persistedStart: persistedStart,
                persistedEnd: persistedEnd
            ),
            anchorStart
        )
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
        let backup = try BackupService.shared.generateBackup(footprints: [original], places: [], activities: [], transports: [trip])

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

    // Actual October 9 fixes: one growing journey, followed by a delayed
    // shorter snapshot. Both arrival orders must retain one stored identity.
    func testOctober9LiveJourneyReusesRecordForPartialAndCompleteSnapshots() throws {
        let samples: [(TimeInterval, Double, Double)] = [
            (1791553440.000, 25.09551434, 102.72163432),
            (1791553445.000, 25.09552245, 102.72161909),
            (1791553450.001, 25.09560884, 102.72165988),
            (1791553455.001, 25.09560787, 102.72167350),
            (1791553460.001, 25.09558536, 102.72171958),
            (1791553465.001, 25.09553130, 102.72182882),
            (1791553470.001, 25.09548567, 102.72198890),
            (1791553475.001, 25.09542951, 102.72212975),
            (1791553481.000, 25.09534922, 102.72232600),
            (1791553487.000, 25.09527722, 102.72261488),
            (1791553493.000, 25.09523573, 102.72283748),
            (1791553499.000, 25.09514079, 102.72299538),
            (1791553505.000, 25.09507559, 102.72320877),
            (1791553510.000, 25.09503839, 102.72338284),
            (1791553515.000, 25.09498400, 102.72362954),
            (1791553520.000, 25.09494062, 102.72381758),
            (1791553525.000, 25.09501952, 102.72398845),
            (1791553530.000, 25.09509092, 102.72404332),
            (1791553535.000, 25.09507395, 102.72404633),
            (1791553544.000, 25.09506430, 102.72404202),
            (1791553549.000, 25.09505374, 102.72405196),
            (1791553565.000, 25.09507410, 102.72410513),
            (1791553570.000, 25.09507457, 102.72425275),
            (1791553575.001, 25.09513754, 102.72438330),
            (1791553580.001, 25.09528499, 102.72442050),
            (1791553585.001, 25.09546587, 102.72450370),
            (1791553590.001, 25.09567123, 102.72456775),
            (1791553595.001, 25.09588521, 102.72464210),
            (1791553600.001, 25.09609896, 102.72470002),
            (1791553606.000, 25.09639604, 102.72480548),
            (1791553612.000, 25.09668422, 102.72489868),
            (1791553618.000, 25.09693490, 102.72498366),
            (1791553624.000, 25.09719078, 102.72508938),
            (1791553630.000, 25.09743934, 102.72515933),
            (1791553635.000, 25.09761276, 102.72522626),
            (1791553640.000, 25.09774126, 102.72527300),
            (1791553645.000, 25.09781114, 102.72538449),
            (1791553650.000, 25.09776781, 102.72570017),
            (1791553655.000, 25.09766611, 102.72598402),
            (1791553660.000, 25.09753825, 102.72626284),
            (1791553665.000, 25.09742242, 102.72656791),
            (1791553670.000, 25.09736969, 102.72689567),
            (1791553675.000, 25.09727348, 102.72719616),
            (1791553680.000, 25.09715264, 102.72750601),
            (1791553685.000, 25.09706996, 102.72781537),
            (1791553690.000, 25.09697047, 102.72810779),
            (1791553695.000, 25.09684997, 102.72841804),
            (1791553700.001, 25.09675586, 102.72872385),
            (1791553705.001, 25.09664941, 102.72904722),
            (1791553710.001, 25.09652806, 102.72937286),
            (1791553715.001, 25.09644144, 102.72969991),
            (1791553720.001, 25.09634185, 102.72999107),
            (1791553725.001, 25.09623666, 102.73028446),
            (1791553731.000, 25.09612678, 102.73060491),
            (1791553737.000, 25.09604531, 102.73084238),
            (1791553743.000, 25.09600364, 102.73097708),
            (1791553749.000, 25.09600570, 102.73098959),
            (1791553777.000, 25.09598552, 102.73105534),
            (1791553784.000, 25.09598184, 102.73106721),
            (1791553789.000, 25.09597863, 102.73124589),
            (1791553794.000, 25.09629999, 102.73127095),
            (1791553799.000, 25.09653771, 102.73134624),
            (1791553804.000, 25.09676831, 102.73159116),
            (1791553809.000, 25.09695680, 102.73168314),
            (1791553814.000, 25.09720283, 102.73174178),
            (1791553819.000, 25.09740378, 102.73178351),
            (1791553824.000, 25.09769265, 102.73186211),
            (1791553829.000, 25.09802813, 102.73196735),
            (1791553834.000, 25.09836229, 102.73207805),
            (1791553839.000, 25.09865149, 102.73218001),
            (1791553844.000, 25.09889648, 102.73228231),
            (1791553849.000, 25.09921601, 102.73227686),
            (1791553855.000, 25.09957886, 102.73236495),
            (1791553861.000, 25.09979862, 102.73243154),
            (1791553867.000, 25.10001793, 102.73250836),
            (1791553873.000, 25.10016861, 102.73255704),
            (1791553879.000, 25.10015320, 102.73286711),
            (1791553885.000, 25.10006845, 102.73315621),
            (1791553891.000, 25.09996634, 102.73350157),
            (1791553896.000, 25.09993363, 102.73372469),
            (1791553901.000, 25.09998223, 102.73397085),
            (1791553906.000, 25.10012215, 102.73421757),
            (1791553911.000, 25.10022785, 102.73446562),
            (1791553916.000, 25.10030404, 102.73475650),
            (1791553921.000, 25.10026166, 102.73494267),
            (1791553926.000, 25.10018729, 102.73517025),
            (1791553931.000, 25.10013733, 102.73539455),
            (1791553936.000, 25.10001203, 102.73553364),
            (1791553941.000, 25.09985214, 102.73561622),
            (1791553946.000, 25.09974504, 102.73569299),
            (1791553951.000, 25.09971084, 102.73570776),
            (1791553956.000, 25.09968639, 102.73573941),
            (1791553961.000, 25.09981141, 102.73602973),
            (1791553966.000, 25.09966062, 102.73640319),
            (1791553971.000, 25.09973719, 102.73653743),
            (1791553976.000, 25.09978258, 102.73658544),
            (1791553982.000, 25.09970667, 102.73671349),
            (1791553988.000, 25.09961213, 102.73680722),
            (1791553994.000, 25.09963241, 102.73680749),
            (1791554000.000, 25.09953402, 102.73683010),
            (1791554005.000, 25.09950701, 102.73684686),
            (1791554010.000, 25.09961605, 102.73680123),
            (1791554015.000, 25.09962945, 102.73679443),
            (1791554027.549, 25.09975317, 102.73709478),
            (1791554033.547, 25.09975120, 102.73702950),
            (1791554039.974, 25.09977966, 102.73710397),
            (1791554045.544, 25.09985059, 102.73705328),
            (1791554069.553, 25.09966158, 102.73703390),
            (1791554075.000, 25.09964465, 102.73704962),
            (1791554080.000, 25.09960305, 102.73703348),
            (1791554085.000, 25.09960832, 102.73712398),
            (1791554090.000, 25.09960754, 102.73715534),
            (1791554096.000, 25.09960182, 102.73716637),
            (1791554101.000, 25.09965983, 102.73714588),
            (1791554107.000, 25.09972963, 102.73718599),
            (1791554126.602, 25.09985059, 102.73705328),
        ]
        let complete = samples.map { timestamp, latitude, longitude in
            CodableCoordinate(lat: latitude, lon: longitude,
                              timestamp: Date(timeIntervalSince1970: timestamp))
        }
        let partial = Array(complete.prefix(62))
        let date = Calendar.current.startOfDay(for: complete[0].timestamp!)
        for partialFirst in [true, false] {
            let schema = Schema([TransportRecord.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            func candidate(_ points: [CodableCoordinate]) throws -> TransportRecord {
                let start = points.first!.timestamp!
                let end = points.last!.timestamp!
                let distance = TimelineBuilder.calculatePathDistance(points)
                return TransportRecord(day: date, startTime: start, endTime: end,
                                       typeRaw: TransportType.ebike.rawValue, distance: distance,
                                       averageSpeed: distance / end.timeIntervalSince(start),
                                       pointsData: try JSONEncoder().encode(points))
            }
            let first = try candidate(partialFirst ? partial : complete)
            let second = try candidate(partialFirst ? complete : partial)
            PersistentTimelineBuilder.insertAutomaticallyDetectedTransport(first, startOfDay: date, context: context)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TransportRecord>()).isEmpty)
            PersistentTimelineBuilder.insertAutomaticallyDetectedTransport(second, startOfDay: date, context: context)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TransportRecord>()).isEmpty)
            let records = try context.fetch(FetchDescriptor<TransportRecord>())
            XCTAssertEqual(records.count, 1)
            let stored = try XCTUnwrap(records.first)
            XCTAssertEqual(stored.recordID, first.recordID)
            XCTAssertEqual(stored.startTime, complete.first!.timestamp!)
            XCTAssertEqual(stored.endTime, complete.last!.timestamp!)
            XCTAssertEqual(stored.distance, TimelineBuilder.calculatePathDistance(complete), accuracy: 0.001)
            XCTAssertEqual(try JSONDecoder().decode([CodableCoordinate].self, from: stored.pointsData).count, complete.count)
            try context.save()
            let published = try ModelContext(container).fetch(FetchDescriptor<TransportRecord>())
            XCTAssertEqual(published.count, 1)
            XCTAssertEqual(published.first?.recordID, first.recordID)
        }
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
