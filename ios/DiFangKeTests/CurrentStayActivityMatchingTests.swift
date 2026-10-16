import CoreLocation
import SwiftData
import XCTest

@testable import 地方客

@MainActor
final class CurrentStayActivityMatchingTests: XCTestCase {
    func testArrivalOverlapKeepsCurrentActivityButRejectsPreviousVisit() throws {
        let schema = Schema([Footprint.self, TransportRecord.self, ActivityType.self, Place.self,
                             TransportManualSelection.self, DailyInsight.self, FutureTrip.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let tolerance = AppConfig.shared.activityContinuationTolerance
        let coordinate = CLLocationCoordinate2D(latitude: 25.1, longitude: 102.73)
        let placeID = UUID()
        let old = Footprint(date: arrival, startTime: arrival.addingTimeInterval(-3600),
                            endTime: arrival.addingTimeInterval(-600), footprintLocations: [coordinate],
                            locationHash: "previous", duration: 0, status: .manual, placeID: placeID,
                            activityTypeValue: "old")
        old.allowsAutomaticDurationExtension = true
        let current = Footprint(date: arrival, startTime: arrival.addingTimeInterval(-tolerance / 2),
                                endTime: arrival.addingTimeInterval(3600), footprintLocations: [coordinate],
                                locationHash: "current", duration: 0, placeID: placeID, activityTypeValue: "home")
        context.insert(old)
        context.insert(current)
        context.insert(TransportRecord(day: arrival, startTime: arrival.addingTimeInterval(-600),
                                       endTime: arrival, typeRaw: TransportType.bicycle.rawValue,
                                       distance: 1000, averageSpeed: 2, pointsData: Data()))
        let anchor = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                verticalAccuracy: 10, timestamp: current.startTime)
        let now = arrival.addingTimeInterval(3600)
        let selected = WatchSyncManager.currentStayFootprint(in: context, anchor: anchor,
                                                             placeID: placeID, now: now, distanceThreshold: 100)
        XCTAssertEqual(selected?.footprintID, current.footprintID)
        XCTAssertEqual(selected?.activityTypeValue, "home")
        let staleAnchor = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                     verticalAccuracy: 10, timestamp: old.startTime)
        XCTAssertEqual(WatchSyncManager.currentStayFootprint(in: context, anchor: staleAnchor,
                                                             placeID: placeID, now: now, distanceThreshold: 100)?.footprintID,
                       current.footprintID)
        context.delete(current)
        XCTAssertNil(WatchSyncManager.currentStayFootprint(in: context, anchor: staleAnchor,
                                                          placeID: placeID, now: now, distanceThreshold: 100))
    }
}
