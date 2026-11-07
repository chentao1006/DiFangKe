import Foundation
import CoreLocation
import CryptoKit

/// Display-only inference. The core SwiftData store and recorded points never
/// contain these coordinates. All entry points doing geometry or I/O run off main.
enum TransportRouteCompletion {
    static let didChange = Notification.Name("TransportInferredRoutesChanged")
    static let didFinishBatch = Notification.Name("TransportInferredRoutesBatchFinished")
    static var revision: Double { UserDefaults.standard.double(forKey: "transportInferredRoutesRevision") }

    struct Gap: Sendable {
        let recordID: UUID
        let index: Int
        let type: TransportType
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let duration: TimeInterval?
        let distance: CLLocationDistance
        let key: String
    }

    private struct CachedRoute: Codable {
        struct Coordinate: Codable {
            let latitude: Double
            let longitude: Double
        }
        let version: Int
        let key: String
        let recordID: UUID
        let typeRaw: String
        let source: String
        let coordinateSystem: String
        let fetchedAt: Date
        let matchingVersion: Int?
        // Optional additions keep existing v1 cache files readable.
        let failureCount: Int?
        let permanentlyFailed: Bool?
        // Empty attempts cool down until the failure limit permanently stops them.
        let coordinates: [Coordinate]

        var recordedFailureCount: Int {
            failureCount ?? (coordinates.isEmpty ? 1 : 0)
        }

        var hasStoppedRetrying: Bool {
            permanentlyFailed == true || (coordinates.isEmpty &&
                recordedFailureCount >= max(1, AppConfig.shared.transportRouteCompletionFailureLimit))
        }
    }

    private final class MemoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: CachedRoute] = [:]

        func value(for key: String) -> CachedRoute? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ entry: CachedRoute) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= max(1, AppConfig.shared.transportRouteCompletionMemoryLimit) {
                entries.removeAll(keepingCapacity: true)
            }
            entries[entry.key] = entry
        }
    }

    private static let memory = MemoryCache()

    /// Reuse the existing model's solid/dashed segmentation and smoothing.
    /// Only supplied missing edges get different display coordinates.
    static func cachedSegments(for transport: Transport) -> [TransportLineSegment] {
        var replacements: [Int: [CLLocationCoordinate2D]] = [:]
        for gap in gaps(for: transport) {
            if let entry = cached(gap), !entry.coordinates.isEmpty {
                replacements[gap.index] = entry.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
        }
        return transport.lineSegments(replacingInferredGaps: replacements)
    }

    static func transport(
        id: UUID,
        typeRaw: String,
        points: [CodableCoordinate]
    ) -> Transport {
        let path = points.map {
            TransportPathPoint(
                coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                timestamp: $0.timestamp,
                isSyntheticPadding: $0.isSyntheticPadding == true
            )
        }
        return Transport(
            id: id,
            startTime: points.first?.timestamp ?? .distantPast,
            endTime: points.last?.timestamp ?? .distantPast,
            startLocation: "", endLocation: "",
            type: TransportType(rawValue: typeRaw) ?? .slow,
            distance: 0, averageSpeed: 0,
            points: path.map(\.coordinate), pathPoints: path
        )
    }

    static func gaps(for transport: Transport) -> [Gap] {
        switch transport.currentType {
        case .airplane, .ship: return []
        default: break
        }
        let points = transport.pathPoints.filter { valid($0.coordinate) }
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).compactMap { index in
            let first = points[index], second = points[index + 1]
            guard Transport.isInferredGap(first, second) else { return nil }
            let distance = meters(first.coordinate, second.coordinate)
            guard distance > 0 else { return nil }
            // Include direction, mode and original sample times. Editing any
            // of these selects a new file instead of reusing stale inference.
            let identity = [
                "v1", transport.id.uuidString, transport.currentType.rawValue,
                String(first.coordinate.latitude), String(first.coordinate.longitude),
                String(second.coordinate.latitude), String(second.coordinate.longitude),
                first.timestamp.map { String($0.timeIntervalSince1970) } ?? "unknown",
                second.timestamp.map { String($0.timeIntervalSince1970) } ?? "unknown"
            ].joined(separator: "|")
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let duration = (first.isSyntheticPadding || second.isSyntheticPadding) ? nil :
                first.timestamp.flatMap { start in second.timestamp.map { $0.timeIntervalSince(start) } }
            return Gap(recordID: transport.id, index: index, type: transport.currentType,
                       start: first.coordinate, end: second.coordinate,
                       duration: duration, distance: distance, key: digest)
        }
    }

    /// Called by map loading, never by tracking/automatic record inference.
    /// Background requests are serialized; explicit detail requests bypass that queue.
    static func prepare(_ transports: [Transport], activelyRequested: Bool = false) async {
        guard !transports.isEmpty,
              !AppConfig.shared.tencentMapKey.isEmpty,
              !AppConfig.shared.tencentMapSecret.isEmpty else { return }
        let gaps = await Task.detached(priority: .utility) {
            var seen = Set<String>()
            return transports.flatMap { Self.gaps(for: $0) }
                .filter { gap in
                    guard seen.insert(gap.key).inserted else { return false }
                    guard let entry = cached(gap) else { return true }
                    return !entry.hasStoppedRetrying && entry.coordinates.isEmpty &&
                        (activelyRequested || entry.matchingVersion != 4 ||
                         Date().timeIntervalSince(entry.fetchedAt) >= AppConfig.shared.transportRouteCompletionRetryInterval)
                }
                .sorted { $0.distance > $1.distance }
        }.value
        guard !Task.isCancelled else { return }
        if !activelyRequested {
            await Requests.shared.enqueue(gaps)
            return
        }
        var changed = false
        for gap in gaps {
            guard !Task.isCancelled else { break }
            if await Requests.shared.complete(gap, activelyRequested: activelyRequested) { changed = true }
        }
        if changed {
            await MainActor.run { () -> Void in
                // Widget snapshots consume the same files at their normal
                // refresh entry; trigger that refresh after the batch is saved.
                NotificationCenter.default.post(name: didFinishBatch, object: nil)
                _ = Task { await WidgetDataSyncManager.shared.syncAll() }
            }
        }
    }

    private actor Requests {
        static let shared = Requests()
        private var inFlight: [String: Task<Bool, Never>] = [:]
        private var pending: [Gap] = []
        private var requestTail: Task<Bool, Never>?
        private var lastRequestFinishedAt: Date?
        private var pendingKeys = Set<String>()
        private var nextIndex = 0
        private var worker: Task<Void, Never>?

        func enqueue(_ gaps: [Gap]) {
            for gap in gaps where pendingKeys.insert(gap.key).inserted {
                pending.append(gap)
            }
            guard worker == nil, nextIndex < pending.count else { return }
            // Owned by the service, not a SwiftUI task that restarts on every
            // route revision. One worker drains all maps' deduplicated requests.
            worker = Task { await self.drain() }
        }

        private func drain() async {
            var changed = false
            while nextIndex < pending.count {
                let gap = pending[nextIndex]
                nextIndex += 1
                if await complete(gap, activelyRequested: false) { changed = true }
                pendingKeys.remove(gap.key)
            }
            pending.removeAll(keepingCapacity: true)
            nextIndex = 0
            worker = nil
            if changed {
                await MainActor.run { () -> Void in
                    NotificationCenter.default.post(name: didFinishBatch, object: nil)
                    _ = Task { await WidgetDataSyncManager.shared.syncAll() }
                }
            }
        }

        func complete(_ gap: Gap, activelyRequested: Bool) async -> Bool {
            if let task = inFlight[gap.key] { return await task.value }
            let previous = requestTail
            // Reserve the key BEFORE any await (including disk-cache reads).
            // Otherwise a second caller can act on a stale cache miss after
            // the first request has already completed and left inFlight.
            let task = Task {
                _ = await previous?.value
                let needsRequest = await Task.detached(priority: .utility) {
                    guard let entry = cached(gap) else { return true }
                    return !entry.hasStoppedRetrying && entry.coordinates.isEmpty &&
                        (activelyRequested || entry.matchingVersion != 4 ||
                         Date().timeIntervalSince(entry.fetchedAt) >= AppConfig.shared.transportRouteCompletionRetryInterval)
                }.value
                guard needsRequest,
                      !AppConfig.shared.tencentMapKey.isEmpty,
                      !AppConfig.shared.tencentMapSecret.isEmpty else { return false }
                // Detail and automatic requests share spacing, not just the
                // background worker. Cache hits never wait for the interval.
                if let finished = lastRequestFinishedAt {
                    let remaining = AppConfig.shared.transportRouteCompletionRequestInterval - Date().timeIntervalSince(finished)
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                }
                let candidates = await TencentTripDirections.routes(
                    from: gap.start, to: gap.end,
                    transportTypeRaw: gap.type.rawValue, prefersStoredRoutes: true,
                    refreshesCachedRoutes: activelyRequested
                )
                lastRequestFinishedAt = Date()
                let changed = await Task.detached(priority: .utility) {
                    let coordinates = bestCoordinates(candidates, for: gap)
                    print("[TransportRouteCompletion] mode=\(gap.type.rawValue), candidates=\(candidates.count), acceptedPoints=\(coordinates?.count ?? 0)")
                    return store(coordinates ?? [], for: gap) && coordinates != nil
                }.value
                if changed {
                    await MainActor.run { () -> Void in
                        NotificationCenter.default.post(name: didChange, object: nil)
                    }
                }
                return changed
            }
            inFlight[gap.key] = task
            requestTail = task
            let changed = await task.value
            inFlight[gap.key] = nil
            return changed
        }
    }

    private static func bestCoordinates(_ candidates: [TripPlannedRoute], for gap: Gap) -> [CLLocationCoordinate2D]? {
        let config = AppConfig.shared
        var best: (hasIntermediateStations: Bool, length: Double, coordinates: [CLLocationCoordinate2D])?
        for candidate in candidates {
            let coordinates = candidate.coordinates
            var hasIntermediateStations = false
            if [.train, .subway, .bus].contains(gap.type) {
                let transit = candidate.instructions.filter {
                    $0.systemImage == TransportType.train.icon ||
                    $0.systemImage == TransportType.subway.icon ||
                    $0.systemImage == TransportType.bus.icon
                }
                guard !transit.isEmpty else { continue }
                if gap.type == .train {
                    // A rail itinerary may include access/egress walking, metro
                    // or bus legs. Validate the complete itinerary's endpoints,
                    // not station positions against arbitrary GPS gap endpoints.
                    let rail = transit.filter { $0.systemImage == TransportType.train.icon }
                    guard !rail.isEmpty else { continue }
                    let sections = rail.map { ($0.segmentCoordinates ?? []).map(\.coordinate) }
                    guard sections.allSatisfy({ $0.count >= 2 && $0.allSatisfy(valid) }) else { continue }
                    hasIntermediateStations = sections.contains { $0.count > 2 } || sections.count > 1
                } else {
                    guard transit.allSatisfy({ $0.systemImage == gap.type.icon }),
                          transit.allSatisfy({ ($0.segmentCoordinates?.count ?? 0) > 2 }) else { continue }
                }
            }
            guard coordinates.count >= (gap.type == .train ? 2 : 3), coordinates.allSatisfy(valid),
                  let first = coordinates.first, let last = coordinates.last else { continue }
            let startOffset = meters(first, gap.start)
            let endOffset = meters(last, gap.end)
            guard startOffset <= config.transportRouteCompletionEndpointTolerance,
                  endOffset <= config.transportRouteCompletionEndpointTolerance else {
                print("[TransportRouteCompletion] rejected=endpoints, mode=\(gap.type.rawValue), startOffsetMeters=\(Int(startOffset)), endOffsetMeters=\(Int(endOffset))")
                continue
            }
            let length = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { $0 + meters($1.0, $1.1) }
            guard length.isFinite, length > 0,
                  length <= gap.distance * config.transportRouteCompletionMaxDetourRatio else { continue }
            // Today's timetable (including waiting/transfers) does not measure
            // the duration of a historical train's missing GPS samples.
            if gap.type != .train, let duration = gap.duration, duration > 0 {
                guard candidate.expectedTravelTime > 0,
                      candidate.expectedTravelTime <= duration * config.transportRouteCompletionDurationRatio else { continue }
            }
            // Prefer a station itinerary over an endpoint-only train result.
            // Never choose the latter merely because its straight line is shorter.
            if best == nil || (hasIntermediateStations && !best!.hasIntermediateStations) ||
                (hasIntermediateStations == best!.hasIntermediateStations && length < best!.length) {
                best = (hasIntermediateStations, length, [gap.start] + coordinates + [gap.end])
            }
        }
        return best?.coordinates
    }

    private static func cached(_ gap: Gap) -> CachedRoute? {
        if let entry = memory.value(for: gap.key) { return entry }
        guard let data = try? Data(contentsOf: cacheURL(for: gap)),
              let entry = try? JSONDecoder().decode(CachedRoute.self, from: data),
              entry.version == 1, entry.key == gap.key, entry.recordID == gap.recordID,
              entry.typeRaw == gap.type.rawValue, entry.coordinateSystem == "GCJ02",
              entry.hasStoppedRetrying || gap.type != .train || entry.matchingVersion == 4,
              entry.coordinates.isEmpty || (entry.coordinates.count > 2 && entry.coordinates.allSatisfy({
                  valid(.init(latitude: $0.latitude, longitude: $0.longitude))
              })) else { return nil }
        memory.store(entry)
        return entry
    }

    private static func store(_ coordinates: [CLLocationCoordinate2D], for gap: Gap) -> Bool {
        let failureLimit = max(1, AppConfig.shared.transportRouteCompletionFailureLimit)
        let failures = coordinates.isEmpty
            ? min(cached(gap)?.recordedFailureCount ?? 0, failureLimit) + 1 : 0
        let entry = CachedRoute(
            version: 1, key: gap.key, recordID: gap.recordID,
            typeRaw: gap.type.rawValue,
            source: gap.type == .train ? "tencent-rail-stations" : "tencent-directions", coordinateSystem: "GCJ02",
            fetchedAt: Date(), matchingVersion: 4,
            failureCount: failures, permanentlyFailed: failures >= failureLimit,
            coordinates: coordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        )
        memory.store(entry)
        do {
            let url = cacheURL(for: gap)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
            memory.store(entry)
            if !coordinates.isEmpty {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "transportInferredRoutesRevision")
            }
            return true
        } catch {
            print("[TransportRouteCompletion] Could not save display route: \(error.localizedDescription)")
            return false
        }
    }

    private static func cacheURL(for gap: Gap) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransportRoutes/v1", isDirectory: true)
            .appendingPathComponent(gap.recordID.uuidString, isDirectory: true)
            .appendingPathComponent("\(gap.key).json")
    }

    private static func valid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
    }

    private static func meters(_ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }
}
