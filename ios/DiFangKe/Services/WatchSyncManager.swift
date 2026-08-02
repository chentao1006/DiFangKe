import CoreLocation
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
    let todayFootprintCount: Int
    let todayDistance: Double
    let nextTrip: WatchTripSnapshot?
    let activities: [WatchActivityOption]
}

struct WatchTripSnapshot: Codable {
    let id: String
    let placeName: String
    let distance: Double?
    let arrivalDate: Date
    let hasArrivalTime: Bool
}

@MainActor
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private var modelContext: ModelContext?

    func start(context: ModelContext) {
        modelContext = context
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        syncSnapshot()
    }

    func syncSnapshot() {
        guard let context = modelContext,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(makeSnapshot(context: context)) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    private func makeSnapshot(context: ModelContext) -> WatchSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let footprints = (try? context.fetch(FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= todayStart && $0.startTime < todayEnd },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        ))) ?? []
        let activities = ((try? context.fetch(FetchDescriptor<ActivityType>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? [])
            .map { WatchActivityOption(id: $0.id.uuidString, name: $0.name, icon: $0.icon, colorHex: $0.colorHex) }
        let latest = footprints.first
        let nextTrip = FutureTrip.dayOrdered((try? context.fetch(FetchDescriptor<FutureTrip>())) ?? [])
            .first(where: { !$0.isCompleted && $0.hasPlanDate && ($0.isOrdered ? calendar.isDateInToday($0.arrivalDate) : $0.effectiveArrivalDate(now: now) >= now) })
        let distance = nextTrip.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            .flatMap { destination in LocationManager.shared.lastLocation.map { $0.distance(from: destination) } }

        return WatchSnapshot(
            currentFootprintID: latest?.footprintID.uuidString,
            placeName: latest?.address?.isEmpty == false ? latest!.address! : "正在定位",
            address: latest?.reason,
            startedAt: latest?.startTime,
            isTracking: LocationManager.shared.isTracking,
            currentActivityID: latest?.activityTypeValue,
            todayFootprintCount: footprints.count,
            todayDistance: footprints.compactMap(\.walkingDistance).reduce(0, +),
            nextTrip: nextTrip.map { WatchTripSnapshot(id: $0.id.uuidString, placeName: $0.placeName, distance: distance, arrivalDate: $0.arrivalDate, hasArrivalTime: $0.hasArrivalTime) },
            activities: activities
        )
    }

    private func applyActivityChange(footprintID: String, activityID: String?) {
        guard let context = modelContext, let id = UUID(uuidString: footprintID) else { return }
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == id })
        guard let footprint = try? context.fetch(descriptor).first else { return }
        footprint.updateActivityType(to: activityID, in: context)
        try? context.save()
        syncSnapshot()
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
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
