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

struct WatchTimelineItem: Codable, Hashable, Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date
    let title: String
    let icon: String
    let colorHex: String?
}

struct WatchDaySnapshot: Codable, Hashable, Identifiable {
    let date: Date
    let timeline: [WatchTimelineItem]

    var id: Date { date }
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
    let futureTrips: [WatchTripSnapshot]?

    static let placeholder = WatchSnapshot(currentFootprintID: nil, placeName: "请先打开 iPhone 上的地方客", address: "首次同步完成后，手表可显示最近的数据。", startedAt: nil, isTracking: false, currentActivityID: nil, currentTransportType: nil, currentTransportStartedAt: nil, todayFootprintCount: 0, todayDistance: 0, nextTrip: nil, activities: [], todayTimeline: [], recentDays: [], futureTrips: [])
}

final class WatchStore: NSObject, ObservableObject, WCSessionDelegate {
    private let complicationSnapshotKey = "watchComplicationSnapshot"
    private let complicationGroupID = "group.com.ct106.difangke"
    @Published private(set) var snapshot = WatchSnapshot.placeholder
    @Published private(set) var requestedActivityPickerFootprintID: String?

    override init() {
        super.init()
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
        snapshot = WatchSnapshot(currentFootprintID: snapshot.currentFootprintID, placeName: snapshot.placeName, address: snapshot.address, startedAt: snapshot.startedAt, isTracking: snapshot.isTracking, currentActivityID: activity?.id, currentTransportType: snapshot.currentTransportType, currentTransportStartedAt: snapshot.currentTransportStartedAt, todayFootprintCount: snapshot.todayFootprintCount, todayDistance: snapshot.todayDistance, nextTrip: snapshot.nextTrip, activities: snapshot.activities, todayTimeline: snapshot.todayTimeline, recentDays: snapshot.recentDays, futureTrips: snapshot.futureTrips)
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

    private func apply(_ context: [String: Any]) {
        let requestedPickerID = context["activityPickerFootprintID"] as? String
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
