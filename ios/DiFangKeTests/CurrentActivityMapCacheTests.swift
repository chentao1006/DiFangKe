import Foundation
import XCTest

@testable import 地方客

final class CurrentActivityMapCacheTests: XCTestCase {
    func testLiveActivityKeepsSameThemeMapWhileReplacementSessionRenders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-map-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func add(_ name: String, modified: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path
            )
            return url
        }
        let oldLight = try add("current_activity_old_4_light.png", modified: 100)
        let oldDark = try add("current_activity_old_4_dark.png", modified: 100)
        _ = try add("current_activity_old_photo_9_dark.png", modified: 500)

        // A new activity has no files yet. Reuse a map without crossing themes
        // or mistaking photo thumbnails for a map.
        XCTAssertEqual(CurrentActivityMapSnapshotCache.imageURLs(
            in: directory, sessionID: "new", revision: 0, suffix: "light"
        ), [oldLight])
        XCTAssertEqual(CurrentActivityMapSnapshotCache.imageURLs(
            in: directory, sessionID: "new", revision: 0, suffix: "dark"
        ), [oldDark])

        let currentLight = try add("current_activity_new_1_light.png", modified: 50)
        XCTAssertEqual(CurrentActivityMapSnapshotCache.imageURLs(
            in: directory, sessionID: "new", revision: 0, suffix: "light"
        ).first, currentLight)

        // Keep the published revision first even when a newer render exists.
        _ = try add("current_activity_new_2_light.png", modified: 200)
        XCTAssertEqual(CurrentActivityMapSnapshotCache.imageURLs(
            in: directory, sessionID: "new", revision: 1, suffix: "light"
        ).first, currentLight)
        try FileManager.default.removeItem(at: oldDark)
        XCTAssertTrue(CurrentActivityMapSnapshotCache.imageURLs(
            in: directory, sessionID: "new", revision: 1, suffix: "dark"
        ).isEmpty)
    }
}

