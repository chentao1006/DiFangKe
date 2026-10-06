import Foundation
import SwiftData
import WatchConnectivity
import CoreLocation

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
    let currentAverageSpeed: Double?
    let todayFootprintCount: Int
    let todayDistance: Double
    let activities: [WatchActivityOption]
    let todayTimeline: [WatchTimelineItem]
    let recentDays: [WatchDaySnapshot]
    let statistics: WatchStatisticsSnapshot
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
    /// Footprint activity name; nil for transport items.
    let activityName: String?
    /// Transport distance in meters; nil for footprint items.
    let distance: Double?
}

struct WatchDaySnapshot: Codable {
    let date: Date
    let timeline: [WatchTimelineItem]
    let distance: Double
}

/// Compact statistics for the Watch. Keep this separate from recentDays so
/// expanding a statistics range never requires sending full historical routes.
struct WatchStatisticsSnapshot: Codable {
    let summaries: [WatchStatisticsSummary]
    let availableYears: [Int]
}

struct WatchStatisticsSummary: Codable {
    let id: String
    let footprintCount: Int
    let transportCount: Int
    let frequentPlaces: [WatchStatisticsRankItem]
    let activities: [WatchStatisticsRankItem]
}

struct WatchStatisticsRankItem: Codable {
    let name: String
    let icon: String?
    let colorHex: String?
    let duration: TimeInterval
    let count: Int
}

/// Keep the complication transport independent from the full Watch-home payload.
/// The latter contains history, route points, and statistics and can grow beyond
/// WatchConnectivity's transfer limit. The complication only renders these fields.
private struct WatchComplicationSnapshot: Codable {
    let currentFootprintID: String?
    let placeName: String
    let address: String?
    let startedAt: Date?
    let isTracking: Bool
    let currentActivityID: String?
    let currentTransportType: String?
    let currentTransportStartedAt: Date?
    let currentAverageSpeed: Double?
    let todayFootprintCount: Int
    let todayDistance: Double
    let activities: [WatchActivityOption]
    let todayTimeline: [WatchComplicationTimelineItem]

    init(snapshot: WatchSnapshot) {
        currentFootprintID = snapshot.currentFootprintID
        placeName = snapshot.placeName
        address = snapshot.address
        startedAt = snapshot.startedAt
        isTracking = snapshot.isTracking
        currentActivityID = snapshot.currentActivityID
        currentTransportType = snapshot.currentTransportType
        currentTransportStartedAt = snapshot.currentTransportStartedAt
        currentAverageSpeed = snapshot.currentAverageSpeed
        todayFootprintCount = snapshot.todayFootprintCount
        todayDistance = snapshot.todayDistance
        activities = snapshot.activities
        todayTimeline = snapshot.todayTimeline.map(WatchComplicationTimelineItem.init)
    }
}

/// What actually matters for the complication's *appearance* changing, as
/// opposed to time simply continuing to pass. Deliberately excludes
/// `todayDistance` and each timeline item's `endTime`: those advance on
/// nearly every location callback while the current stay/trip is ongoing,
/// but the complication doesn't need a push to reflect that — its duration
/// label already computes itself from `startedAt`/`currentTransportStartedAt`
/// against the entry's own clock, and the ring/bar shape from an ongoing
/// item's endTime barely moves tick to tick.
private struct ComplicationBudgetFingerprint: Codable {
    let currentFootprintID: String?
    let placeName: String
    let address: String?
    let startedAt: Date?
    let isTracking: Bool
    let currentActivityID: String?
    let currentTransportType: String?
    let currentTransportStartedAt: Date?
    let todayFootprintCount: Int
    let timelineItemIDs: [String]

    init(_ snapshot: WatchComplicationSnapshot) {
        currentFootprintID = snapshot.currentFootprintID
        placeName = snapshot.placeName
        address = snapshot.address
        startedAt = snapshot.startedAt
        isTracking = snapshot.isTracking
        currentActivityID = snapshot.currentActivityID
        currentTransportType = snapshot.currentTransportType
        currentTransportStartedAt = snapshot.currentTransportStartedAt
        todayFootprintCount = snapshot.todayFootprintCount
        timelineItemIDs = snapshot.todayTimeline.map(\.id)
    }
}

private struct WatchComplicationTimelineItem: Codable {
    let id: String
    let startTime: Date
    let endTime: Date
    let colorHex: String?
    let isTransport: Bool?

    init(_ item: WatchTimelineItem) {
        id = item.id
        startTime = item.startTime
        endTime = item.endTime
        colorHex = item.colorHex
        isTransport = item.isTransport
    }
}

// WCSessionDelegate is not @MainActor-isolated: WatchConnectivity invokes its
// methods on an arbitrary background queue, and every method below already
// hops to main itself (DispatchQueue.main.async) before touching @MainActor
// state. @preconcurrency tells the compiler to trust that existing contract
// instead of treating the whole conformance as isolated to this actor.
@MainActor
final class WatchSyncManager: NSObject, @preconcurrency WCSessionDelegate {
    static let shared = WatchSyncManager()
    static let provisionalMovingType = "moving"
    private var modelContext: ModelContext?
    private let pendingActivityFootprintKey = "pendingWatchActivityFootprintID"
    private let pendingActivityIDKey = "pendingWatchActivityID"
    private let lastHourlySyncKey = "lastWatchHourlySyncTimestamp"
    private var footprintDataChangedObserver: NSObjectProtocol?
    private var pendingSnapshotSync: Task<Void, Never>?
    private var lastMovingAverageSpeedSyncAt: Date = .distantPast
    private var pendingBackgroundSnapshotTransfer: WCSessionUserInfoTransfer?
    private var cachedStatistics: WatchStatisticsSnapshot?
    private var statisticsCacheDay: Date?
    private var needsStatisticsRefresh = true
    /// `updateApplicationContext` does not launch a suspended Watch app. Keep the
    /// last payload we sent through the complication channel so actual timeline
    /// changes can use that high-priority path without spending its budget on
    /// repeated location callbacks that produce the same snapshot.
    private var lastComplicationFingerprint: Data?
    private var lastBackgroundSnapshotData: Data?
    private var lastFullSnapshotData: Data?

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
                    self?.needsStatisticsRefresh = true
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
        let snapshot = makeSnapshot(context: context)
        if snapshot.currentTransportType != nil, snapshot.currentAverageSpeed != nil {
            lastMovingAverageSpeedSyncAt = Date()
        }
        let complicationSnapshot = WatchComplicationSnapshot(snapshot: snapshot)
        guard let complicationData = try? JSONEncoder().encode(complicationSnapshot) else { return }
        let complicationPayload = ["complicationSnapshot": complicationData]
        // updateApplicationContext always runs so the watch has the latest state whenever
        // it next wakes (background refresh or manual open). sendMessage is a best-effort
        // fast path: it only succeeds while the watch app is reachable, but when it does,
        // the complication updates instantly instead of waiting for the next wake.
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(complicationPayload, replyHandler: nil, errorHandler: nil)
        }

        // The complete payload is for the Watch app UI only; it is never sent through
        // the budgeted complication channel below because it includes historical routes.
        let fullData = try? JSONEncoder().encode(snapshot)
        if let fullData {
            // updateApplicationContext is a latest-value cache: it reaches the Watch
            // process the moment it is next running, but never wakes a suspended one.
            try? session.updateApplicationContext(["snapshot": fullData])
        }

        // This is the delivery-guaranteed fallback for the budgeted complication
        // channel below, and also the only channel that reliably wakes a suspended
        // Watch app: unlike application context, user-info transfers remain queued
        // for background delivery via WKWatchConnectivityRefreshBackgroundTask.
        // The full snapshot rides in the same transfer as the compact complication
        // data so one wake/task/delegate cycle updates both — splitting them into
        // two independent transfers risked WatchAppDelegate completing the shared
        // background task after only one of the two had actually been delivered,
        // letting the system suspend the process before the other one arrived.
        // Keep at most one snapshot in the queue: the Watch only needs the newest
        // state, and an old footprint must never arrive after a newer transport.
        if complicationData != lastBackgroundSnapshotData || fullData != lastFullSnapshotData {
            var backgroundPayload = complicationPayload
            if let fullData {
                backgroundPayload["snapshot"] = fullData
            }
            pendingBackgroundSnapshotTransfer?.cancel()
            pendingBackgroundSnapshotTransfer = session.transferUserInfo(backgroundPayload)
            lastBackgroundSnapshotData = complicationData
            lastFullSnapshotData = fullData
        }

        // Application context is deliberately a latest-value cache and will not
        // wake a terminated Watch app. A complication update needs to arrive when
        // a new footprint or transport is saved, not only at the next opportunistic
        // Watch background refresh. This is the dedicated, high-priority transfer
        // Apple provides for that job. It is budgeted (a fixed number of transfers
        // per day) — gate it on a fingerprint that excludes the fields which drift
        // on essentially every location callback (the ongoing item's endTime,
        // today's cumulative distance) but keep no real information for the
        // complication, since its duration label already ticks forward on its own
        // from startedAt. Spending the scarce budget on those non-events was
        // exhausting it hours into the day, after which updates silently fell back
        // to the slow queue until the phone app was next opened.
        if let fingerprint = try? JSONEncoder().encode(ComplicationBudgetFingerprint(complicationSnapshot)),
           fingerprint != lastComplicationFingerprint,
           session.isComplicationEnabled,
           session.remainingComplicationUserInfoTransfers > 0 {
            // Apple requires an active clock-face complication for this API. The
            // compact regular user-info transfer above remains the reliable
            // fallback for Smart Stack and any inactive complication placement.
            session.transferCurrentComplicationUserInfo(complicationPayload)
            lastComplicationFingerprint = fingerprint
        }
    }

    /// While the Watch app is open, publish the same route-average speed used by
    /// the iPhone transport UI without waiting for a full timeline rebuild.
    func syncMovingAverageSpeedIfNeeded(now: Date = Date()) {
        guard let context = modelContext,
              LocationManager.shared.isCurrentlyMoving,
              Self.currentMovementAverageSpeed(
                persistedAverageSpeed: Self.currentTransportRecord(
                    in: context,
                    now: now,
                    isCurrentlyMoving: true,
                    movingStartedAt: LocationManager.shared.uiMovingStartedAt
                )?.averageSpeed,
                locations: LocationManager.shared.allTodayPoints,
                movingStartedAt: LocationManager.shared.uiMovingStartedAt,
                now: now,
                isCurrentlyMoving: true
              ) != nil,
              now.timeIntervalSince(lastMovingAverageSpeedSyncAt)
                >= AppConfig.shared.watchMovingSpeedSyncInterval,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              WCSession.default.isReachable else { return }
        syncSnapshot()
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
        // A recently persisted transport may still end within the five-minute
        // lookup window after the user has explicitly arrived. Live stay state
        // is authoritative for whether Watch should continue showing "moving".
        let liveStayStart = LocationManager.shared.potentialStopStartLocation?.timestamp
        let movingStartedAt = LocationManager.shared.uiMovingStartedAt
        let currentTransport = Self.currentTransportRecord(
            in: context,
            now: now,
            isCurrentlyMoving: LocationManager.shared.isCurrentlyMoving,
            movingStartedAt: movingStartedAt
        )
        let currentTransportPresentation = Self.currentTransportPresentation(
            persistedType: currentTransport.map { $0.manualTypeRaw ?? $0.typeRaw },
            persistedStartedAt: currentTransport?.startTime,
            isCurrentlyMoving: LocationManager.shared.isCurrentlyMoving,
            provisionalType: Self.provisionalMovingType,
            provisionalStartedAt: movingStartedAt
                ?? LocationManager.shared.lastLocation?.timestamp
        )
        let currentAverageSpeed = Self.currentMovementAverageSpeed(
            persistedAverageSpeed: currentTransport?.averageSpeed,
            locations: LocationManager.shared.allTodayPoints,
            movingStartedAt: movingStartedAt,
            now: now,
            isCurrentlyMoving: LocationManager.shared.isCurrentlyMoving
        )
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
        let refreshStatistics = needsStatisticsRefresh
            || cachedStatistics == nil
            || statisticsCacheDay.map { !calendar.isDate($0, inSameDayAs: now) } == true
        let statisticsFootprints = refreshStatistics
            ? ((try? context.fetch(FetchDescriptor<Footprint>(sortBy: [SortDescriptor(\.startTime)]))) ?? [])
            : []
        let statisticsTransports = refreshStatistics
            ? ((try? context.fetch(FetchDescriptor<TransportRecord>(
                predicate: #Predicate { $0.statusRaw != "ignored" },
                sortBy: [SortDescriptor(\.startTime)]
            ))) ?? [])
            : []
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
                    routeCoordinates: nil,
                    activityName: activity?.name,
                    distance: nil
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
                    routeCoordinates: Self.downsampledRoute(from: transport.pointsData),
                    activityName: nil,
                    distance: transport.distance
                )
            }
            ).sorted { $0.startTime < $1.startTime }
        }
        let recentDays = (0..<14).compactMap { offset -> WatchDaySnapshot? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let dayFootprints = recentFootprints.filter { $0.startTime >= dayStart && $0.startTime < dayEnd }
            return WatchDaySnapshot(
                date: dayStart,
                timeline: timeline(
                    footprints: dayFootprints,
                    transports: recentTransports.filter { $0.startTime < dayEnd && $0.endTime >= dayStart }
                ),
                distance: dayFootprints.compactMap(\.walkingDistance).reduce(0, +)
            )
        }
        func statisticsSummary(id: String, includes: (Date) -> Bool) -> WatchStatisticsSummary {
            let footprintsInRange = statisticsFootprints.filter { includes($0.startTime) }
            let transportsInRange = statisticsTransports.filter { includes($0.startTime) }

            var places: [String: (duration: TimeInterval, count: Int)] = [:]
            var activityTotals: [String: (icon: String?, colorHex: String?, duration: TimeInterval, count: Int)] = [:]
            for footprint in footprintsInRange {
                let placeName = footprint.address?.isEmpty == false ? footprint.address! : "未知地点"
                let duration = max(0, footprint.endTime.timeIntervalSince(footprint.startTime))
                var place = places[placeName, default: (0, 0)]
                place.duration += duration
                place.count += 1
                places[placeName] = place

                if let activity = footprint.activityTypeValue.flatMap({ activityByValue[$0] }) {
                    var total = activityTotals[activity.name, default: (activity.icon, activity.colorHex, 0, 0)]
                    total.duration += duration
                    total.count += 1
                    activityTotals[activity.name] = total
                }
            }
            var frequentPlaces = [WatchStatisticsRankItem]()
            frequentPlaces.reserveCapacity(places.count)
            for (name, total) in places {
                frequentPlaces.append(
                    WatchStatisticsRankItem(
                        name: name,
                        icon: nil,
                        colorHex: nil,
                        duration: total.duration,
                        count: total.count
                    )
                )
            }
            frequentPlaces.sort { lhs, rhs in
                lhs.duration == rhs.duration ? lhs.count > rhs.count : lhs.duration > rhs.duration
            }

            var activities = [WatchStatisticsRankItem]()
            activities.reserveCapacity(activityTotals.count)
            for (name, total) in activityTotals {
                activities.append(
                    WatchStatisticsRankItem(
                        name: name,
                        icon: total.icon,
                        colorHex: total.colorHex,
                        duration: total.duration,
                        count: total.count
                    )
                )
            }
            activities.sort { lhs, rhs in
                lhs.duration == rhs.duration ? lhs.count > rhs.count : lhs.duration > rhs.duration
            }

            return WatchStatisticsSummary(
                id: id,
                footprintCount: footprintsInRange.count,
                transportCount: transportsInRange.count,
                frequentPlaces: Array(frequentPlaces.prefix(3)),
                activities: Array(activities.prefix(3))
            )
        }
        let rollingStatisticsRanges: [(id: String, days: Int)] = [
            ("last7Days", 7),
            ("last30Days", 30),
            ("last90Days", 90),
            ("lastYear", 365)
        ]
        var statisticsSummaries = rollingStatisticsRanges.compactMap { range -> WatchStatisticsSummary? in
            guard let cutoff = calendar.date(byAdding: .day, value: -range.days, to: now) else { return nil }
            return statisticsSummary(id: range.id) { $0 >= cutoff }
        }
        let statisticsYears = Set(statisticsFootprints.map { calendar.component(.year, from: $0.startTime) }).sorted(by: >)
        statisticsSummaries += statisticsYears.map { year in
            statisticsSummary(id: "year-\(year)") {
                calendar.component(.year, from: $0) == year
            }
        }
        let statistics: WatchStatisticsSnapshot
        if refreshStatistics {
            statistics = WatchStatisticsSnapshot(summaries: statisticsSummaries, availableYears: statisticsYears)
            cachedStatistics = statistics
            statisticsCacheDay = now
            needsStatisticsRefresh = false
        } else if let cachedStatistics {
            statistics = cachedStatistics
        } else {
            statistics = WatchStatisticsSnapshot(summaries: statisticsSummaries, availableYears: statisticsYears)
        }
        let liveFootprint = LocationManager.shared.potentialStopStartLocation.flatMap { anchor in
            Self.currentStayFootprint(
                in: context,
                anchor: anchor,
                placeID: LocationManager.shared.matchedPlace?.placeID,
                now: now,
                distanceThreshold: AppConfig.shared.stayDistanceThreshold
            )
        }
        let currentFootprint = liveStayStart == nil ? latest : liveFootprint
        let livePlaceName: String? = {
            guard liveStayStart != nil else { return nil }
            if LocationManager.shared.isAwaitingDepartureLocationConfirmation {
                return "检测到活动，等待定位"
            }
            if let place = LocationManager.shared.matchedPlace, !place.isIgnored { return place.name }
            if let title = LocationManager.shared.ongoingTitle,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
            let address = LocationManager.shared.currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty && address != "正在解析位置..." && address != "未知位置" { return address }
            return "正在停留"
        }()

        return WatchSnapshot(
            currentFootprintID: currentFootprint?.footprintID.uuidString,
            placeName: livePlaceName ?? (latest?.address?.isEmpty == false ? latest!.address! : "正在定位"),
            address: LocationManager.shared.isAwaitingDepartureLocationConfirmation ? nil : currentFootprint?.reason,
            startedAt: liveStayStart ?? latest?.startTime,
            isTracking: LocationManager.shared.isTracking,
            currentActivityID: currentFootprint?.activityTypeValue.flatMap {
                activityByValue[$0.trimmingCharacters(in: .whitespacesAndNewlines)]?.id
            },
            currentTransportType: currentTransportPresentation.type,
            currentTransportStartedAt: currentTransportPresentation.startedAt,
            currentAverageSpeed: currentAverageSpeed,
            todayFootprintCount: footprints.count,
            todayDistance: footprints.compactMap(\.walkingDistance).reduce(0, +),
            activities: activities,
            todayTimeline: timeline(footprints: footprints, transports: todayTransports),
            recentDays: recentDays,
            statistics: statistics
        )
    }

    static func currentTransportPresentation(
        persistedType: String?,
        persistedStartedAt: Date?,
        isCurrentlyMoving: Bool,
        provisionalType: String,
        provisionalStartedAt: Date?
    ) -> (type: String?, startedAt: Date?) {
        if let persistedType {
            return (persistedType, persistedStartedAt)
        }
        guard isCurrentlyMoving else { return (nil, nil) }
        return (provisionalType, provisionalStartedAt)
    }

    /// Matches the iPhone transport model: accumulated route distance divided
    /// by elapsed route time. A persisted TransportRecord is authoritative;
    /// before one exists, calculate the same formula from the current route.
    static func currentMovementAverageSpeed(
        persistedAverageSpeed: Double?,
        locations: [CLLocation],
        movingStartedAt: Date?,
        now: Date,
        isCurrentlyMoving: Bool
    ) -> Double? {
        guard isCurrentlyMoving else { return nil }
        if let persistedAverageSpeed,
           persistedAverageSpeed.isFinite,
           persistedAverageSpeed > 0 {
            return persistedAverageSpeed
        }

        let route = locations
            .filter { location in
                location.timestamp <= now
                    && (movingStartedAt.map { location.timestamp >= $0 } ?? true)
                    && CLLocationCoordinate2DIsValid(location.coordinate)
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = route.first,
              let last = route.last,
              route.count >= 2 else { return nil }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return nil }
        let speed = TimelineBuilder.calculateDistance(route) / duration
        return speed.isFinite && speed > 0 ? speed : nil
    }

    /// Single source of truth for the current persisted trip. Both Watch and
    /// Live Activity must select the same record; otherwise one surface can
    /// retain the previous trip while another independently classifies the new one.
    static func currentTransportRecord(
        in context: ModelContext,
        now: Date,
        isCurrentlyMoving: Bool,
        movingStartedAt: Date?
    ) -> TransportRecord? {
        guard isCurrentlyMoving else { return nil }
        let recentThreshold = now.addingTimeInterval(-AppConfig.shared.currentTransportLookback)
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.statusRaw == "active" && $0.startTime <= now && $0.endTime >= recentThreshold
            },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).first { transport in
            guard let movingStartedAt else { return true }
            return transport.endTime >= movingStartedAt
        }
    }

    static func currentStayFootprint(
        in context: ModelContext,
        anchor: CLLocation,
        placeID: UUID?,
        now: Date,
        distanceThreshold: Double,
        continuationTolerance: TimeInterval = AppConfig.shared.activityContinuationTolerance
    ) -> Footprint? {
        let stayStart = anchor.timestamp
        let lookupStart = stayStart.addingTimeInterval(-continuationTolerance)
        // A continuing stay can be split at midnight; select its latest segment.
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate {
                $0.statusValue != "ignored" && $0.endTime >= lookupStart && $0.startTime <= now
            },
            sortBy: [SortDescriptor(\.endTime, order: .reverse), SortDescriptor(\.startTime, order: .reverse)]
        )
        let matches = ((try? context.fetch(descriptor)) ?? []).filter { candidate in
            if let placeID, candidate.placeID == placeID { return true }
            return CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                .distance(from: anchor) < distanceThreshold
        }

        // Activity-only edits deliberately keep the current stay extendable. The
        // live processor may advance its provisional anchor a few seconds beyond
        // the persisted footprint end; retain that edited record across this
        // sampling seam instead of briefly falling back to an unknown activity.
        if let editedContinuation = matches.first(where: {
            $0.status == .manual && $0.allowsAutomaticDurationExtension &&
            $0.endTime >= lookupStart
        }) {
            return editedContinuation
        }
        return matches.first(where: { $0.endTime >= stayStart })
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
        needsStatisticsRefresh = true
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
        if message["requestSnapshot"] as? Bool == true {
            DispatchQueue.main.async { self.syncSnapshot() }
            return
        }
        if message["confirmArrival"] as? Bool == true {
            DispatchQueue.main.async {
                Task { @MainActor in
                    await LocationManager.shared.confirmArrival()
                }
            }
            return
        }
        guard let footprintID = message["footprintID"] as? String else { return }
        let activityID = message["activityID"] as? String
        DispatchQueue.main.async { self.applyActivityChange(footprintID: footprintID, activityID: activityID) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["confirmArrival"] as? Bool == true {
            DispatchQueue.main.async {
                Task { @MainActor in
                    let succeeded = await LocationManager.shared.confirmArrival()
                    replyHandler(["success": succeeded])
                }
            }
            return
        }
        self.session(session, didReceiveMessage: message)
        replyHandler(["accepted": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        self.session(session, didReceiveMessage: userInfo)
    }
}
