import Foundation
import WatchConnectivity
import WidgetKit

struct WatchActivityOption: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
}

struct WatchTripSnapshot: Codable, Hashable, Identifiable {
    let id: String
    let placeName: String
    let distance: Double?
    let arrivalDate: Date
    let hasArrivalTime: Bool
}

struct WatchCoordinate: Codable, Hashable {
    let lat: Double
    let lon: Double
}

struct WatchTimelineItem: Codable, Hashable, Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date
    let title: String
    let icon: String
    let colorHex: String?
    let isTransport: Bool?
    let latitude: Double?
    let longitude: Double?
    let routeCoordinates: [WatchCoordinate]?
    let activityName: String?
    let distance: Double?
}

struct WatchDaySnapshot: Codable, Hashable, Identifiable {
    let date: Date
    let timeline: [WatchTimelineItem]
    let distance: Double

    var id: Date { date }
}

struct WatchStatisticsSnapshot: Codable, Hashable {
    let summaries: [WatchStatisticsSummary]
    let availableYears: [Int]
}

struct WatchStatisticsSummary: Codable, Hashable, Identifiable {
    let id: String
    let footprintCount: Int
    let transportCount: Int
    let frequentPlaces: [WatchStatisticsRankItem]
    let activities: [WatchStatisticsRankItem]
}

struct WatchStatisticsRankItem: Codable, Hashable, Identifiable {
    let name: String
    let icon: String?
    let colorHex: String?
    let duration: TimeInterval
    let count: Int

    var id: String { name }
}

struct WatchSnapshot: Codable, Hashable {
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
    let todayTimeline: [WatchTimelineItem]?
    let recentDays: [WatchDaySnapshot]?
    let statistics: WatchStatisticsSnapshot?
    let futureTrips: [WatchTripSnapshot]?

    static let placeholder = WatchSnapshot(currentFootprintID: nil, placeName: "请先打开 iPhone 上的地方客", address: "首次同步完成后，手表可显示最近的数据。", startedAt: nil, isTracking: false, currentActivityID: nil, currentTransportType: nil, currentTransportStartedAt: nil, todayFootprintCount: 0, todayDistance: 0, nextTrip: nil, activities: [], todayTimeline: [], recentDays: [], statistics: nil, futureTrips: [])
}

final class WatchStore: NSObject, ObservableObject, WCSessionDelegate {
    /// The connectivity delegate must exist even when watchOS wakes the process
    /// for a complication transfer without constructing the SwiftUI scene.
    static let shared = WatchStore()

    private let complicationSnapshotKey = "watchComplicationSnapshot"
    private let complicationGroupID = "group.com.ct106.difangke"
    /// watchOS delivers a queued `updateApplicationContext` payload only once the app
    /// process launches and its session activates — it does not wake the app on its
    /// own. Without a periodic background refresh, the complication is stuck showing
    /// whatever was current the last time someone opened the app, silently ticking
    /// its duration forward against stale data. Scheduling and handling that refresh
    /// lives in `WatchAppDelegate` — `WKApplication.scheduleBackgroundRefresh` requires
    /// a `WKApplicationDelegate` that implements `handleBackgroundTasks`, and crashes
    /// immediately on launch if none is registered.
    static let backgroundRefreshInterval: TimeInterval = 15 * 60
    @Published private(set) var snapshot = WatchSnapshot.placeholder
    @Published private(set) var requestedActivityPickerFootprintID: String?

    override init() {
        super.init()
        activateSession()
    }

    func activateSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var currentActivity: WatchActivityOption? {
        snapshot.activities.first { $0.id == snapshot.currentActivityID }
    }

    var hasReceivedSnapshot: Bool {
        snapshot.currentFootprintID != nil || !snapshot.activities.isEmpty
    }

    func selectActivity(_ activity: WatchActivityOption?) {
        guard let footprintID = snapshot.currentFootprintID else { return }
        let payload: [String: Any] = ["footprintID": footprintID, "activityID": activity?.id as Any]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
        snapshot = WatchSnapshot(currentFootprintID: snapshot.currentFootprintID, placeName: snapshot.placeName, address: snapshot.address, startedAt: snapshot.startedAt, isTracking: snapshot.isTracking, currentActivityID: activity?.id, currentTransportType: snapshot.currentTransportType, currentTransportStartedAt: snapshot.currentTransportStartedAt, todayFootprintCount: snapshot.todayFootprintCount, todayDistance: snapshot.todayDistance, nextTrip: snapshot.nextTrip, activities: snapshot.activities, todayTimeline: snapshot.todayTimeline, recentDays: snapshot.recentDays, statistics: snapshot.statistics, futureTrips: snapshot.futureTrips)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        apply(session.receivedApplicationContext)
    }

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { apply(applicationContext) }

    /// `transferCurrentComplicationUserInfo` is the iPhone's high-priority path
    /// for new complication data. Unlike application context it can wake this app
    /// in the background, so persist and reload the WidgetKit timeline as soon as
    /// it is delivered.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { apply(userInfo) }

    /// Fast path for when the watch is reachable: the phone sends the same payload via
    /// sendMessage so the complication updates immediately instead of waiting for the
    /// next background wake to pick up the queued application context.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { apply(message) }

    private func apply(_ context: [String: Any]) {
        let requestedPickerID = context["activityPickerFootprintID"] as? String
        if let complicationData = context["complicationSnapshot"] as? Data {
            // This is intentionally decoded by the Widget extension, not by the
            // Watch-home model. It stays small enough for reliable background
            // delivery even when the full Watch snapshot contains route history.
            DispatchQueue.main.async {
                UserDefaults(suiteName: self.complicationGroupID)?.set(complicationData, forKey: self.complicationSnapshotKey)
                WidgetCenter.shared.reloadTimelines(ofKind: "DiFangKeWatchComplication")
                WatchAppDelegate.completeConnectivityBackgroundTasks()
                if let requestedPickerID {
                    self.requestedActivityPickerFootprintID = requestedPickerID
                }
            }
        }
        guard let data = context["snapshot"] as? Data,
              let decoded = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else {
            if let requestedPickerID {
                DispatchQueue.main.async { self.requestedActivityPickerFootprintID = requestedPickerID }
            }
            return
        }
        DispatchQueue.main.async {
            self.snapshot = decoded
            self.persistForComplications(decoded)
            WatchAppDelegate.completeConnectivityBackgroundTasks()
            self.requestedActivityPickerFootprintID = requestedPickerID
        }
    }

    /// A Watch complication extension cannot receive WatchConnectivity messages
    /// itself. The companion app is the receiver and shares this compact copy.
    private func persistForComplications(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: complicationGroupID)?.set(data, forKey: complicationSnapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "DiFangKeWatchComplication")
    }
}
