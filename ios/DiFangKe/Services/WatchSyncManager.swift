import Foundation
import SwiftData
import WatchConnectivity

struct WatchActivityOption: Codable, Hashable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
}

struct WatchSnapshot: Codable {
    let currentFootprintID: String?
    let placeName: String
    let address: String?
    let startedAt: Date?
    let isTracking: Bool
    let currentActivityID: String?
    let currentTransportType: String?
    let currentTransportStartedAt: Date?
    let todayFootprintCount: Int
    let todayDistance: Double
    let nextTrip: WatchTripSnapshot?
    let activities: [WatchActivityOption]
    let todayTimeline: [WatchTimelineItem]
    let recentDays: [WatchDaySnapshot]
    let futureTrips: [WatchTripSnapshot]
}

struct WatchTripSnapshot: Codable {
    let id: String
    let placeName: String
    let distance: Double?
    let arrivalDate: Date
    let hasArrivalTime: Bool
}

struct WatchCoordinate: Codable {
    let lat: Double
    let lon: Double
}

struct WatchTimelineItem: Codable {
    let id: String
    let startTime: Date
    let endTime: Date
    let title: String
    let icon: String
    let colorHex: String?
    /// Kept optional so a Watch with a previously persisted snapshot can still
    /// decode it while the iPhone is updating the shared complication data.
    let isTransport: Bool?
    /// Footprint location; nil for transport items, which carry `routeCoordinates` instead.
    let latitude: Double?
    let longitude: Double?
    /// Downsampled transport route, kept short so the payload stays small over WatchConnectivity.
    let routeCoordinates: [WatchCoordinate]?
}

struct WatchDaySnapshot: Codable {
    let date: Date
    let timeline: [WatchTimelineItem]
}

@MainActor
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private var modelContext: ModelContext?
    private let pendingActivityFootprintKey = "pendingWatchActivityFootprintID"
    private let pendingActivityIDKey = "pendingWatchActivityID"
    private let lastHourlySyncKey = "lastWatchHourlySyncTimestamp"
    private var footprintDataChangedObserver: NSObjectProtocol?
    private var pendingSnapshotSync: Task<Void, Never>?

    func start(context: ModelContext) {
        modelContext = context
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        applyPendingActivityChangeIfNeeded()
        if footprintDataChangedObserver == nil {
            footprintDataChangedObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("FootprintDataChanged"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleImmediateSnapshotSync()
                }
            }
        }
        syncSnapshot()
    }

    /// Timeline reconstruction may emit several changes for one location update.
    /// Coalesce them briefly, then publish the final activity/transport state to Watch.
    private func scheduleImmediateSnapshotSync() {
        pendingSnapshotSync?.cancel()
        pendingSnapshotSync = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.syncSnapshot()
        }
    }

    func syncSnapshot() {
        guard let context = modelContext,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        guard let data = try? JSONEncoder().encode(makeSnapshot(context: context)) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    /// A best-effort hourly catch-up for the installed companion app. Location-triggered
    /// sync remains immediate; this covers changes that otherwise have no location event.
    func syncHourlyIfNeeded(now: Date = Date()) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: lastHourlySyncKey) >= 60 * 60 else { return }
        syncSnapshot()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastHourlySyncKey)
    }

    func requestActivityPicker(for footprintID: String) {
        guard let context = modelContext,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(makeSnapshot(context: context)) else { return }
        try? WCSession.default.updateApplicationContext([
            "snapshot": data,
            "activityPickerFootprintID": footprintID
        ])
    }

    private func makeSnapshot(context: ModelContext) -> WatchSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let historyStart = calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart
        let footprints = (try? context.fetch(FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= todayStart && $0.startTime < todayEnd },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        ))) ?? []
        let activities = ((try? context.fetch(FetchDescriptor<ActivityType>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? [])
            .map { WatchActivityOption(id: $0.id.uuidString, name: $0.name, icon: $0.icon, colorHex: $0.colorHex) }
        let latest = footprints.first
        let recentTransportEndThreshold = now.addingTimeInterval(-5 * 60)
        let transports = (try? context.fetch(FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.statusRaw == "active" && $0.startTime <= now && $0.endTime >= recentTransportEndThreshold },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        ))) ?? []
        let currentTransport = transports.first
        let todayTransports = (try? context.fetch(FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.statusRaw != "ignored" && $0.startTime < todayEnd && $0.endTime >= todayStart },
            sortBy: [SortDescriptor(\.startTime)]
        ))) ?? []
        let activityByValue = activities.reduce(into: [String: WatchActivityOption]()) { result, activity in
            result[activity.id] = activity
            result[activity.name] = activity
        }
        let recentFootprints = (try? context.fetch(FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= historyStart && $0.startTime < todayEnd },
            sortBy: [SortDescriptor(\.startTime)]
        ))) ?? []
        let recentTransports = (try? context.fetch(FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.statusRaw != "ignored" && $0.startTime < todayEnd && $0.endTime >= historyStart },
            sortBy: [SortDescriptor(\.startTime)]
        ))) ?? []
        func timeline(footprints: [Footprint], transports: [TransportRecord]) -> [WatchTimelineItem] {
            (footprints.map { footprint in
                let activity = footprint.activityTypeValue.flatMap { activityByValue[$0] }
                return WatchTimelineItem(
                    id: footprint.footprintID.uuidString,
                    startTime: footprint.startTime,
                    endTime: footprint.endTime,
                    title: footprint.address?.isEmpty == false ? footprint.address! : "未知地点",
                    icon: activity?.icon ?? "mappin.and.ellipse",
                    colorHex: activity?.colorHex,
                    isTransport: false,
                    latitude: footprint.latitude,
                    longitude: footprint.longitude,
                    routeCoordinates: nil
                )
            }
            + transports.map { transport in
                let type = TransportType(rawValue: transport.manualTypeRaw ?? transport.typeRaw)
                return WatchTimelineItem(
                    id: transport.recordID.uuidString,
                    startTime: transport.startTime,
                    endTime: transport.endTime,
                    title: type?.localizedName ?? "出行",
                    icon: type?.sfSymbol ?? "arrow.triangle.swap",
                    colorHex: nil,
                    isTransport: true,
                    latitude: nil,
                    longitude: nil,
                    routeCoordinates: Self.downsampledRoute(from: transport.pointsData)
                )
            }
            ).sorted { $0.startTime < $1.startTime }
        }
        let recentDays = (0..<14).compactMap { offset -> WatchDaySnapshot? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return WatchDaySnapshot(
                date: dayStart,
                timeline: timeline(
                    footprints: recentFootprints.filter { $0.startTime >= dayStart && $0.startTime < dayEnd },
                    transports: recentTransports.filter { $0.startTime < dayEnd && $0.endTime >= dayStart }
                )
            )
        }
        let futureTrips = FutureTrip.dayOrdered((try? context.fetch(FetchDescriptor<FutureTrip>())) ?? [])
            .filter { !$0.isCompleted && $0.hasPlanDate && ($0.isOrdered ? $0.arrivalDate >= now : $0.effectiveArrivalDate(now: now) >= now) }
            .prefix(10)
            .map { WatchTripSnapshot(id: $0.id.uuidString, placeName: $0.placeName, distance: nil, arrivalDate: $0.arrivalDate, hasArrivalTime: $0.hasArrivalTime) }
        let nextTrip = futureTrips.first

        return WatchSnapshot(
            currentFootprintID: latest?.footprintID.uuidString,
            placeName: latest?.address?.isEmpty == false ? latest!.address! : "正在定位",
            address: latest?.reason,
            startedAt: latest?.startTime,
            isTracking: LocationManager.shared.isTracking,
            currentActivityID: latest?.activityTypeValue,
            currentTransportType: currentTransport.map { $0.manualTypeRaw ?? $0.typeRaw },
            currentTransportStartedAt: currentTransport?.startTime,
            todayFootprintCount: footprints.count,
            todayDistance: footprints.compactMap(\.walkingDistance).reduce(0, +),
            nextTrip: nextTrip,
            activities: activities,
            todayTimeline: timeline(footprints: footprints, transports: todayTransports),
            recentDays: recentDays,
            futureTrips: Array(futureTrips)
        )
    }

    func applyActivityChange(footprintID: String, activityID: String?) {
        guard let context = modelContext else {
            UserDefaults.standard.set(footprintID, forKey: pendingActivityFootprintKey)
            UserDefaults.standard.set(activityID, forKey: pendingActivityIDKey)
            return
        }
        guard let id = UUID(uuidString: footprintID) else { return }
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
        guard let footprint = try? context.fetch(descriptor).first else { return }
        footprint.updateActivityType(to: activityID, in: context)
        try? context.save()
        syncSnapshot()
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
    }

    /// Watch map routes only need to convey the shape of a trip on a tiny screen, so the
    /// full GPS trace is thinned to a fixed point budget to keep the WatchConnectivity payload small.
    private static func downsampledRoute(from pointsData: Data, maxCount: Int = 40) -> [WatchCoordinate]? {
        guard let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: pointsData), decoded.count >= 2 else { return nil }
        guard decoded.count > maxCount else {
            return decoded.map { WatchCoordinate(lat: $0.lat, lon: $0.lon) }
        }
        let step = Double(decoded.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { i in
            let index = min(Int((Double(i) * step).rounded()), decoded.count - 1)
            let point = decoded[index]
            return WatchCoordinate(lat: point.lat, lon: point.lon)
        }
    }

    private func applyPendingActivityChangeIfNeeded() {
        guard let footprintID = UserDefaults.standard.string(forKey: pendingActivityFootprintKey),
              let activityID = UserDefaults.standard.string(forKey: pendingActivityIDKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingActivityFootprintKey)
        UserDefaults.standard.removeObject(forKey: pendingActivityIDKey)
        applyActivityChange(footprintID: footprintID, activityID: activityID)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.syncSnapshot() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let footprintID = message["footprintID"] as? String else { return }
        let activityID = message["activityID"] as? String
        DispatchQueue.main.async { self.applyActivityChange(footprintID: footprintID, activityID: activityID) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        self.session(session, didReceiveMessage: userInfo)
    }
}
