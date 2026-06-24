import Foundation
import SwiftData

@MainActor
enum FutureTripMigrationService {
    static func migrateLegacyTripsIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: FutureTrip.migrationCompletedKey) else { return }

        let legacyTrips = FutureTrip.loadLegacyTrips()
        guard !legacyTrips.isEmpty else {
            UserDefaults.standard.set(true, forKey: FutureTrip.migrationCompletedKey)
            return
        }

        let existingTrips = (try? context.fetch(FetchDescriptor<FutureTrip>())) ?? []
        let existingIDs = Set(existingTrips.map(\.id))

        var insertedCount = 0
        for legacyTrip in legacyTrips where !existingIDs.contains(legacyTrip.id) {
            let trip = FutureTrip(
                id: legacyTrip.id,
                placeName: legacyTrip.placeName,
                address: legacyTrip.address,
                notes: legacyTrip.notes,
                coordinate: legacyTrip.coordinate,
                arrivalDate: legacyTrip.arrivalDate,
                hasArrivalTime: legacyTrip.hasArrivalTime,
                activityTypeValue: legacyTrip.activityTypeValue,
                createdAt: legacyTrip.createdAt
            )
            context.insert(trip)
            insertedCount += 1
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: FutureTrip.migrationCompletedKey)
            print("[FutureTripMigration] migrated legacy trips=\(insertedCount)")
            FutureTrip.postDidChangeNotification()
        } catch {
            print("[FutureTripMigration] save failed: \(error)")
        }
    }
}
