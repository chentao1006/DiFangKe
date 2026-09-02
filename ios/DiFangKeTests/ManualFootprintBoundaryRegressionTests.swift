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
        XCTAssertEqual(manual.count, 2)
        XCTAssertEqual(manual.map(\.startTime), [day, split])
        XCTAssertEqual(manual.map(\.endTime), [split, day.addingTimeInterval(60 * 60)])
        XCTAssertEqual(manual.map(\.activityTypeValue), ["work", "exercise"])
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
