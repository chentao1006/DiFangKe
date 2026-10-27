import Foundation
import SwiftData
import CoreLocation
#if canImport(ActivityKit)
import ActivityKit
import MapKit
import SwiftUI
import UIKit
#endif

struct TripImportedCity: Sendable, Hashable {
    let countryCode: String
    let countryName: String
    let cityName: String
    let latitude: Double?
    let longitude: Double?
}

struct TripImportedDay: Sendable {
    let day: Date
    let cities: [TripImportedCity]
    let lastCity: TripImportedCity?
}

struct TripActivityStyle: Sendable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
}

struct TripActualDayRequest: Sendable {
    let id: UUID
    let day: Date
    let timeZoneIdentifier: String
}

struct TripActualItemSnapshot: Sendable {
    let dayID: UUID
    let kind: TripItemKind
    let countryCode: String?
    let countryName: String?
    let cityName: String?
    let placeID: UUID?
    let placeName: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let startTime: Date
    let endTime: Date
    let activityTypeValue: String?
    let transportTypeRaw: String?
    let startLocationName: String?
    let endLocationName: String?
    let notes: String
    let sourceFootprintID: UUID?
    let sourceTransportRecordID: UUID?
    let photoAssetIDs: [String]
}

@MainActor
@Observable
final class TripScanManager {
    static let shared = TripScanManager()

    private(set) var isScanning = false
    private(set) var scannedThrough: Date?
    private var legacyContainer: ModelContainer?
    private var tripContainer: ModelContainer?
    private var scanTask: Task<Void, Never>?
    private var resumesAfterReturningToForeground = false
    private var pausedForAppBackground = false
    private var rescansAfterPhotoImport = false
    private(set) var requestedTripID: UUID?
    private(set) var requestedTripArrivalStopID: UUID?
    private var progressRouteByStopID: [UUID: (summary: String, guidance: String?, coordinates: [CLLocationCoordinate2D])] = [:]

    private init() {
        scannedThrough = UserDefaults.standard.object(forKey: Keys.cursor) as? Date
    }

    var recordModelContainer: ModelContainer? { legacyContainer }

    func refreshActiveTripProgress() {
        refreshActiveTripProgress(at: LocationManager.shared.lastLocation)
    }

    /// Only the next unfinished destination is eligible. Lifecycle and movement
    /// transitions may complete it, but a later stop must never skip the plan ahead.
    private func refreshActiveTripProgress(at location: CLLocation?) {
        guard let tripContainer else { return }
        let now = Date()
        let context = tripContainer.mainContext
        let activeTrips = (try? context.fetch(FetchDescriptor<Trip>()))?.filter { $0.state == .active } ?? []
        guard let trip = activeTrips.sorted(by: { ($0.actualStartedAt ?? .distantPast) > ($1.actualStartedAt ?? .distantPast) }).first else {
            progressRouteByStopID.removeAll()
#if canImport(ActivityKit)
            if #available(iOS 16.1, *) { TripProgressLiveActivityManager.shared.stop() }
#endif
            return
        }
        let days = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? [])
            .filter { $0.tripID == trip.id }
            .sorted { $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day }
        let dayOrder = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.id, $0.offset) })
        let orderedStops = ((try? context.fetch(FetchDescriptor<TripItem>())) ?? [])
            .filter {
                dayOrder[$0.tripDayID] != nil &&
                $0.kindRaw == TripItemKind.stop.rawValue
            }
            .sorted(by: {
                let leftDay = dayOrder[$0.tripDayID] ?? .max
                let rightDay = dayOrder[$1.tripDayID] ?? .max
                return leftDay == rightDay ? $0.orderIndex < $1.orderIndex : leftDay < rightDay
            })
        var next = orderedStops.first { $0.planStatusRaw == "planned" }
        let arrivalRadius = AppConfig.shared.tripPlanArrivalRadiusMeters
        let hasFreshLocation = location.map {
            abs($0.timestamp.timeIntervalSinceNow) <= AppConfig.shared.currentLocationFreshnessThreshold
        } ?? false
        if let location,
           hasFreshLocation,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= arrivalRadius,
           arrivalRadius > 0,
           let currentNext = next,
           let latitude = currentNext.latitude,
           let longitude = currentNext.longitude,
           location.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= arrivalRadius {
            currentNext.planStatusRaw = "completed"
            trip.updatedAt = now
            try? context.save()
            next = orderedStops.first { $0.planStatusRaw == "planned" }
        }

#if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard let next else {
            TripProgressLiveActivityManager.shared.endActivity(for: trip.id)
            return
        }
        let coordinate = next.latitude.flatMap { latitude in
            next.longitude.map { longitude in CLLocation(latitude: latitude, longitude: longitude) }
        }
        let distance = location.flatMap { current in coordinate.map { current.distance(from: $0) } }
        let day = days.first { $0.id == next.tripDayID }
        let arrivalDate = next.startTime.flatMap { value -> Date? in
            guard let day else { return value }
            return value == Calendar.autoupdatingCurrent.startOfDay(for: day.day) ? nil : value
        }
        let nextIndex = orderedStops.firstIndex(where: { $0.id == next.id }) ?? 0
        let homeCity = ((try? context.fetch(FetchDescriptor<HomeCity>())) ?? []).first
        let segmentOrigin: (name: String, location: CLLocation)? = {
            if nextIndex > 0,
               let latitude = orderedStops[nextIndex - 1].latitude,
               let longitude = orderedStops[nextIndex - 1].longitude {
                let previous = orderedStops[nextIndex - 1]
                return (
                    previous.placeName ?? previous.address ?? previous.cityName ?? "上一站",
                    CLLocation(latitude: latitude, longitude: longitude)
                )
            }
            if let homeCity,
               let latitude = homeCity.latitude,
               let longitude = homeCity.longitude {
                return (
                    homeCity.cityName.isEmpty ? "常居地" : homeCity.cityName,
                    CLLocation(latitude: latitude, longitude: longitude)
                )
            }
            return nil
        }()
        let segmentDistance = segmentOrigin.flatMap { origin in
            coordinate.map { origin.location.distance(from: $0) }
        }
        let cachedRoute = progressRouteByStopID[next.id]
        let tripActivityStyle = resolvedActivityStyle(for: trip.activityTypeValue)
        let state = TripProgressActivityAttributes.ContentState(
            stopID: next.id.uuidString,
            placeName: next.placeName ?? next.address ?? next.cityName ?? "地点",
            cityName: next.cityName,
            notes: {
                let value = next.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }(),
            currentDistance: distance,
            segmentDistance: segmentDistance,
            originName: segmentOrigin?.name,
            sequenceNumber: nextIndex + 1,
            totalStops: orderedStops.count,
            arrivalDate: arrivalDate,
            transportTypeRaw: next.transportTypeRaw,
            routeSummary: cachedRoute?.summary,
            routeGuidance: cachedRoute?.guidance,
            tripActivityIcon: tripActivityStyle?.icon,
            tripActivityColorHex: tripActivityStyle?.colorHex,
            isWithinArrivalRadius: distance.map { $0 <= arrivalRadius } ?? false,
            latitude: next.latitude,
            longitude: next.longitude
        )
        TripProgressLiveActivityManager.shared.update(
            tripID: trip.id,
            tripTitle: trip.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "进行中的行程"
                : trip.title,
            state: state,
            originCoordinate: segmentOrigin?.location.coordinate,
            destinationCoordinate: coordinate?.coordinate,
            currentCoordinate: location?.coordinate,
            routeCoordinates: cachedRoute?.coordinates
        )
        if let segmentOrigin,
           let destinationLatitude = next.latitude,
           let destinationLongitude = next.longitude,
           next.transportTypeRaw?.isEmpty == false {
            let tripID = trip.id
            let tripTitle = trip.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "进行中的行程"
                : trip.title
            let nextID = next.id
            let transportTypeRaw = next.transportTypeRaw
            Task { @MainActor in
                let routes = await TencentTripDirections.routes(
                    from: segmentOrigin.location.coordinate,
                    to: CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude),
                    transportTypeRaw: transportTypeRaw
                )
                guard !routes.isEmpty,
                      orderedStops.first(where: { $0.planStatusRaw == "planned" })?.id == nextID else { return }
                let preferredIndex = TripRouteOptionSelectionStore.selectedIndex(
                    for: nextID,
                    optionCount: routes.count
                )
                let route = routes[preferredIndex]
                let summary = Self.routeSummary(route, transportTypeRaw: transportTypeRaw)
                let guidance = Self.routeGuidance(route)
                self.progressRouteByStopID[nextID] = (summary, guidance, route.coordinates)
                var routeState = state
                routeState.routeSummary = summary
                routeState.routeGuidance = guidance
                TripProgressLiveActivityManager.shared.update(
                    tripID: tripID,
                    tripTitle: tripTitle,
                    state: routeState,
                    originCoordinate: segmentOrigin.location.coordinate,
                    destinationCoordinate: CLLocationCoordinate2D(
                        latitude: destinationLatitude,
                        longitude: destinationLongitude
                    ),
                    currentCoordinate: location?.coordinate,
                    routeCoordinates: route.coordinates
                )
            }
        }
#endif
    }

    private func resolvedActivityStyle(for value: String?) -> TripActivityStyle? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let legacyContainer else { return nil }
        let context = ModelContext(legacyContainer)
        let descriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return ((try? context.fetch(descriptor)) ?? []).first {
            $0.id.uuidString == value || $0.name == value
        }.map {
            TripActivityStyle(id: $0.id.uuidString, name: $0.name, icon: $0.icon, colorHex: $0.colorHex)
        }
    }

#if canImport(ActivityKit)
    private static func routeSummary(_ route: TripPlannedRoute, transportTypeRaw: String?) -> String {
        let type = TransportType(rawValue: transportTypeRaw ?? "")?.localizedName ?? "交通"
        let distance = route.distance < 1_000
            ? "\(max(1, Int(route.distance.rounded())))米"
            : String(format: "%.1f公里", route.distance / 1_000)
        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        return "\(type) · \(distance) · 约\(minutes)分钟"
    }

    private static func routeGuidance(_ route: TripPlannedRoute) -> String? {
        guard !route.instructions.isEmpty else { return nil }
        return route.instructions.map { instruction in
            guard instruction.title != "步行", let detail = instruction.detail else {
                return instruction.title
            }
            let stations = detail.split(separator: "·")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasSuffix("上车") || $0.hasSuffix("下车") }
            return stations.isEmpty
                ? instruction.title
                : "\(instruction.title)：\(stations.joined(separator: " → "))"
        }.joined(separator: " → ")
    }
#endif

    func requestOpenTrip(_ tripID: UUID) {
        requestedTripID = tripID
    }

    func consumeRequestedTripID() {
        requestedTripID = nil
    }

    func requestPlannedStopArrivalConfirmation(_ stopID: UUID, tripID: UUID) {
        requestedTripArrivalStopID = stopID
        requestOpenTrip(tripID)
    }

    func consumeRequestedTripArrivalStopID() {
        requestedTripArrivalStopID = nil
    }

    func endTripProgressActivity(for tripID: UUID) {
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            TripProgressLiveActivityManager.shared.endActivity(for: tripID)
        }
#endif
    }

    func configure(legacyContainer: ModelContainer, tripContainer: ModelContainer) {
        self.legacyContainer = legacyContainer
        self.tripContainer = tripContainer
        Task.detached(priority: .utility) {
            Self.finalizeLegacyAutomaticDrafts(in: tripContainer)
        }
        refreshActiveTripProgress()
    }

    func scanIfNeeded(force: Bool = false, onlyMissingDates: Bool = false) {
        guard scanTask == nil,
              UserDefaults.standard.bool(forKey: Keys.enabled),
              let legacyContainer,
              let tripContainer else { return }
        let interval = TimeInterval(AppConfig.shared.tripScanIntervalHours * 3600)
        if !force,
           let lastRun = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date,
           Date().timeIntervalSince(lastRun) < interval { return }

        isScanning = true
        scanTask = Task {
            var cursor: Date?
            repeat {
                let batchTask = Task.detached(priority: .background) {
                    Self.scanOneBatch(
                        legacyContainer: legacyContainer,
                        tripContainer: tripContainer,
                        onlyMissingDates: onlyMissingDates
                    )
                }
                cursor = await withTaskCancellationHandler {
                    await batchTask.value
                } onCancel: {
                    batchTask.cancel()
                }
                scannedThrough = cursor
                guard !Task.isCancelled, let cursor,
                      cursor < Calendar.autoupdatingCurrent.startOfDay(for: Date()) else { break }
                try? await Task.sleep(for: .milliseconds(100))
            } while !Task.isCancelled
            isScanning = false
            scanTask = nil
            NotificationCenter.default.post(name: .tripScanDidFinish, object: nil)
            if rescansAfterPhotoImport {
                rescansAfterPhotoImport = false
                resumesAfterReturningToForeground = false
                scanHistoryPreservingTrips()
            } else if resumesAfterReturningToForeground {
                resumesAfterReturningToForeground = false
                scanIfNeeded(force: true)
            }
        }
    }

    func scanMissingTrips() async {
        guard scanTask == nil,
              UserDefaults.standard.bool(forKey: Keys.enabled) else { return }
        UserDefaults.standard.removeObject(forKey: Keys.cursor)
        UserDefaults.standard.removeObject(forKey: Keys.lastRun)
        UserDefaults.standard.removeObject(forKey: Keys.pending)
        scanIfNeeded(force: true, onlyMissingDates: true)
        let task = scanTask
        await task?.value
    }

    func suppressAutomaticRegeneration(for trips: [Trip]) {
        guard !trips.isEmpty else { return }
        scanTask?.cancel()
        UserDefaults.standard.removeObject(forKey: Keys.pending)
        var ranges = Self.loadSuppressedRanges()
        ranges.append(contentsOf: trips.map {
            SuppressedRange(startDay: $0.plannedStartDay, endDay: $0.plannedEndDay)
        })
        Self.saveSuppressedRanges(Self.mergedSuppressedRanges(ranges))
    }

    func pauseForAppBackground() {
        guard scanTask != nil else { return }
        pausedForAppBackground = true
        resumesAfterReturningToForeground = false
        scanTask?.cancel()
    }

    func resumeAfterAppForeground() {
        guard pausedForAppBackground else { return }
        pausedForAppBackground = false
        if scanTask == nil {
            scanIfNeeded(force: true)
        } else {
            resumesAfterReturningToForeground = true
        }
    }

    func importCities(from start: Date, through end: Date) async -> [TripImportedDay] {
        guard let legacyContainer else { return [] }
        return await Task.detached(priority: .utility) {
            Self.readCities(in: legacyContainer, from: start, through: end)
        }.value
    }

    func activityStyles() async -> [TripActivityStyle] {
        guard let legacyContainer else { return [] }
        return await Task.detached(priority: .utility) {
            let context = ModelContext(legacyContainer)
            let descriptor = FetchDescriptor<ActivityType>(
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
            return ((try? context.fetch(descriptor)) ?? []).map {
                TripActivityStyle(id: $0.id.uuidString, name: $0.name, icon: $0.icon, colorHex: $0.colorHex)
            }
        }.value
    }

    func actualItems(for days: [TripActualDayRequest]) async -> [TripActualItemSnapshot] {
        guard !days.isEmpty, let legacyContainer else { return [] }
        return await Task.detached(priority: .utility) {
            let context = ModelContext(legacyContainer)
            let intervals = days.map { request -> (TripActualDayRequest, Date, Date) in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: request.timeZoneIdentifier) ?? .autoupdatingCurrent
                let start = calendar.startOfDay(for: request.day)
                return (request, start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
            }
            guard let lower = intervals.map(\.1).min(), let upper = intervals.map(\.2).max() else { return [] }
            let footprints = (try? context.fetch(FetchDescriptor<Footprint>(
                predicate: #Predicate { $0.startTime < upper && $0.endTime > lower && $0.statusValue != "ignored" },
                sortBy: [SortDescriptor(\Footprint.startTime)]
            ))) ?? []
            let transports = (try? context.fetch(FetchDescriptor<TransportRecord>(
                predicate: #Predicate { $0.startTime < upper && $0.endTime > lower && $0.statusRaw != "ignored" },
                sortBy: [SortDescriptor(\TransportRecord.startTime)]
            ))) ?? []
            func dayID(for start: Date, end: Date) -> UUID? {
                intervals.first { start >= $0.1 && start < $0.2 }?.0.id
                    ?? intervals.first { start < $0.2 && end > $0.1 }?.0.id
            }
            let stops = footprints.compactMap { footprint -> TripActualItemSnapshot? in
                guard let dayID = dayID(for: footprint.startTime, end: footprint.endTime) else { return nil }
                return .init(dayID: dayID, kind: .stop, countryCode: footprint.countryCode, countryName: footprint.countryName, cityName: footprint.cityName, placeID: footprint.placeID, placeName: footprint.address ?? footprint.cityName, address: footprint.address, latitude: footprint.latitude, longitude: footprint.longitude, startTime: footprint.startTime, endTime: footprint.endTime, activityTypeValue: footprint.activityTypeValue, transportTypeRaw: nil, startLocationName: nil, endLocationName: nil, notes: footprint.reason ?? "", sourceFootprintID: footprint.footprintID, sourceTransportRecordID: nil, photoAssetIDs: footprint.photoAssetIDs)
            }
            let moves = transports.compactMap { transport -> TripActualItemSnapshot? in
                guard let dayID = dayID(for: transport.startTime, end: transport.endTime) else { return nil }
                return .init(dayID: dayID, kind: .transport, countryCode: nil, countryName: nil, cityName: nil, placeID: nil, placeName: nil, address: nil, latitude: nil, longitude: nil, startTime: transport.startTime, endTime: transport.endTime, activityTypeValue: nil, transportTypeRaw: transport.manualTypeRaw ?? transport.typeRaw, startLocationName: transport.startLocation, endLocationName: transport.endLocation, notes: "", sourceFootprintID: nil, sourceTransportRecordID: transport.recordID, photoAssetIDs: [])
            }
            return (stops + moves).sorted { $0.startTime < $1.startTime }
        }.value
    }

    func transportRoutes(for recordIDs: Set<UUID>) async -> [UUID: [CodableCoordinate]] {
        guard !recordIDs.isEmpty, let legacyContainer else { return [:] }
        return await Task.detached(priority: .utility) {
            let context = ModelContext(legacyContainer)
            var routes: [UUID: [CodableCoordinate]] = [:]
            for recordID in recordIDs {
                guard !Task.isCancelled else { return [:] }
                var descriptor = FetchDescriptor<TransportRecord>(
                    predicate: #Predicate { $0.recordID == recordID }
                )
                descriptor.fetchLimit = 1
                guard let record = try? context.fetch(descriptor).first,
                      let points = try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData),
                      !points.isEmpty else { continue }
                routes[record.recordID] = points
            }
            return routes
        }.value
    }

    func tripCardPhotoAssetIDs(for footprintIDs: [UUID], perFootprintLimit: Int = 2, totalLimit: Int = 5) async -> [String] {
        guard !footprintIDs.isEmpty, let legacyContainer else { return [] }
        return await Task.detached(priority: .utility) {
            let context = ModelContext(legacyContainer)
            var result: [String] = []
            var seen = Set<String>()
            for id in footprintIDs {
                guard !Task.isCancelled else { return [] }
                var descriptor = FetchDescriptor<Footprint>(
                    predicate: #Predicate { $0.footprintID == id }
                )
                descriptor.fetchLimit = 1
                guard let footprint = try? context.fetch(descriptor).first else { continue }
                for assetID in footprint.photoAssetIDs.prefix(max(0, perFootprintLimit)) where seen.insert(assetID).inserted {
                    result.append(assetID)
                    if result.count >= totalLimit { return result }
                }
            }
            return result
        }.value
    }

    func rebuildHistoryFromSettings() {
        guard !isScanning, let tripContainer else { return }
        isScanning = true
        scanTask = Task {
            await Task.detached(priority: .utility) {
                Self.removeReplaceableAutomaticTrips(from: tripContainer)
                UserDefaults.standard.removeObject(forKey: Keys.cursor)
                UserDefaults.standard.removeObject(forKey: Keys.lastRun)
                UserDefaults.standard.removeObject(forKey: Keys.pending)
                UserDefaults.standard.removeObject(forKey: Keys.suppressedRanges)
            }.value
            scanTask = nil
            isScanning = false
            scanIfNeeded(force: true)
        }
    }

    func scanAfterPhotoImport() {
        guard UserDefaults.standard.bool(forKey: Keys.enabled),
              let tripContainer else { return }
        let context = ModelContext(tripContainer)
        guard let home = try? context.fetch(FetchDescriptor<HomeCity>()).first,
              !home.cityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if scanTask != nil {
            rescansAfterPhotoImport = true
        } else {
            scanHistoryPreservingTrips()
        }
    }

    private func scanHistoryPreservingTrips() {
        guard scanTask == nil else {
            rescansAfterPhotoImport = true
            return
        }
        UserDefaults.standard.removeObject(forKey: Keys.cursor)
        UserDefaults.standard.removeObject(forKey: Keys.lastRun)
        UserDefaults.standard.removeObject(forKey: Keys.pending)
        scanIfNeeded(force: true)
    }

    nonisolated private static func removeReplaceableAutomaticTrips(from container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let trips = ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).filter {
            $0.originRaw == TripOrigin.automatic.rawValue
                && !$0.titleUserEdited
                && !$0.datesUserEdited
                && !$0.citiesUserEdited
        }
        let tripIDs = Set(trips.map(\.id))
        guard !tripIDs.isEmpty else { return }
        let days = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? []).filter { tripIDs.contains($0.tripID) }
        let dayIDs = Set(days.map(\.id))
        for item in ((try? context.fetch(FetchDescriptor<TripItem>())) ?? []) where dayIDs.contains(item.tripDayID) { context.delete(item) }
        for city in ((try? context.fetch(FetchDescriptor<TripDayCity>())) ?? []) where dayIDs.contains(city.tripDayID) { context.delete(city) }
        for day in days { context.delete(day) }
        for trip in trips { context.delete(trip) }
        try? context.save()
    }

    nonisolated private static func finalizeLegacyAutomaticDrafts(in container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let drafts = ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).filter {
            $0.originRaw == TripOrigin.automatic.rawValue
                && $0.stateRaw == TripState.draft.rawValue
        }
        guard !drafts.isEmpty else { return }
        for trip in drafts {
            applyDateDerivedState(to: trip)
            trip.updatedAt = Date()
        }
        try? context.save()
    }

    private struct Pending: Codable {
        var startDay: Date
        var endDay: Date
        var citiesByDay: [String: [PendingCity]]
    }

    private struct SuppressedRange: Codable {
        var startDay: Date
        var endDay: Date
    }

    private struct PendingCity: Codable, Hashable {
        let countryCode: String
        let countryName: String
        let cityName: String
        let latitude: Double?
        let longitude: Double?
    }

    nonisolated private static func scanOneBatch(
        legacyContainer: ModelContainer,
        tripContainer: ModelContainer,
        onlyMissingDates: Bool
    ) -> Date? {
        guard !Task.isCancelled else { return nil }
        let legacyContext = ModelContext(legacyContainer)
        let tripContext = ModelContext(tripContainer)
        tripContext.autosaveEnabled = false
        guard let home = try? tripContext.fetch(FetchDescriptor<HomeCity>()).first,
              !home.cityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        var cursor = (UserDefaults.standard.object(forKey: Keys.cursor) as? Date).map { calendar.startOfDay(for: $0) }
        if cursor == nil {
            var descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate { $0.statusValue != "ignored" },
                sortBy: [SortDescriptor(\Footprint.startTime)]
            )
            descriptor.fetchLimit = 1
            cursor = (try? legacyContext.fetch(descriptor).first).map { calendar.startOfDay(for: $0.startTime) }
        }
        guard let batchStart = cursor, batchStart < today else {
            UserDefaults.standard.set(Date(), forKey: Keys.lastRun)
            return cursor
        }
        let configuredEnd = calendar.date(byAdding: .day, value: AppConfig.shared.tripScanBatchDays, to: batchStart) ?? today
        let batchEnd = min(configuredEnd, today)
        let days = readCities(in: legacyContainer, from: batchStart, through: calendar.date(byAdding: .day, value: -1, to: batchEnd) ?? batchStart)
        let existingTrips = onlyMissingDates ? ((try? tripContext.fetch(FetchDescriptor<Trip>())) ?? []) : []
        let suppressedRanges = loadSuppressedRanges()
        var pending = loadPending()
        if let loaded = pending,
           inclusiveDayCount(from: loaded.startDay, through: loaded.endDay) > AppConfig.shared.tripMaximumDurationDays {
            let chunks = splitPending(loaded, maximumDays: AppConfig.shared.tripMaximumDurationDays)
            for chunk in chunks.dropLast() {
                persist(chunk, home: home, context: tripContext, legacyContext: legacyContext)
            }
            pending = chunks.last
        }
        var day = batchStart
        while day < batchEnd {
            guard !Task.isCancelled else { return batchStart }
            let isSuppressed = suppressedRanges.contains { range in
                calendar.startOfDay(for: range.startDay) <= day && calendar.startOfDay(for: range.endDay) >= day
            }
            let alreadyCovered = onlyMissingDates && existingTrips.contains {
                calendar.startOfDay(for: $0.plannedStartDay) <= day && calendar.startOfDay(for: $0.plannedEndDay) >= day
            }
            if isSuppressed || alreadyCovered {
                if let completed = pending {
                    persist(completed, home: home, context: tripContext, legacyContext: legacyContext)
                    pending = nil
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? batchEnd
                continue
            }
            let evidence = days.first { calendar.isDate($0.day, inSameDayAs: day) }
            let cities = evidence?.cities ?? []
            let isHomeDay = cities.contains { cityMatches($0, home: home) }
            let away = cities.filter { !cityMatches($0, home: home) }
            if !away.isEmpty {
                if let current = pending,
                   inclusiveDayCount(from: current.startDay, through: day) > AppConfig.shared.tripMaximumDurationDays {
                    persist(current, home: home, context: tripContext, legacyContext: legacyContext)
                    pending = nil
                }
                let converted = away.map { PendingCity(countryCode: $0.countryCode, countryName: $0.countryName, cityName: $0.cityName, latitude: $0.latitude, longitude: $0.longitude) }
                let key = dayKey(day)
                if pending == nil { pending = Pending(startDay: day, endDay: day, citiesByDay: [:]) }
                pending?.endDay = day
                var seenCities = Set<String>()
                pending?.citiesByDay[key] = converted.filter {
                    seenCities.insert(cityKey($0.countryCode, $0.cityName)).inserted
                }
            }
            let endedAtHome = evidence?.lastCity.map { cityMatches($0, home: home) } ?? isHomeDay
            if endedAtHome, let completed = pending {
                persist(completed, home: home, context: tripContext, legacyContext: legacyContext)
                pending = nil
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? batchEnd
        }
        guard !Task.isCancelled else { return batchStart }
        savePending(pending)
        try? tripContext.save()
        UserDefaults.standard.set(batchEnd, forKey: Keys.cursor)
        UserDefaults.standard.set(Date(), forKey: Keys.lastRun)
        return batchEnd
    }

    nonisolated private static func persist(
        _ pending: Pending,
        home: HomeCity,
        context: ModelContext,
        legacyContext: ModelContext
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let pendingStart = calendar.startOfDay(for: pending.startDay)
        let pendingEnd = calendar.startOfDay(for: pending.endDay)
        guard !loadSuppressedRanges().contains(where: {
            calendar.startOfDay(for: $0.startDay) <= pendingEnd
                && calendar.startOfDay(for: $0.endDay) >= pendingStart
        }) else { return }
        let allTrips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let overlapping = allTrips.first {
            let mergedStart = min($0.plannedStartDay, pending.startDay)
            let mergedEnd = max($0.plannedEndDay, pending.endDay)
            return $0.plannedStartDay <= pending.endDay
                && $0.plannedEndDay >= pending.startDay
                && ($0.originRaw != TripOrigin.automatic.rawValue
                    || inclusiveDayCount(from: mergedStart, through: mergedEnd) <= AppConfig.shared.tripMaximumDurationDays)
        }
        let trip: Trip
        if let overlapping {
            trip = overlapping
            if !trip.datesUserEdited {
                trip.plannedStartDay = min(trip.plannedStartDay, pending.startDay)
                trip.plannedEndDay = max(trip.plannedEndDay, pending.endDay)
            }
            trip.updatedAt = Date()
        } else {
            let pendingCities = orderedCities(in: pending)
            trip = Trip(
                title: automaticTitle(for: pendingCities, home: home, start: pending.startDay, end: pending.endDay),
                kind: .historical,
                state: .historical,
                origin: .automatic,
                plannedStartDay: pending.startDay,
                plannedEndDay: pending.endDay
            )
            trip.homeCityKeyAtCreation = cityKey(home.countryCode, home.cityName, identifier: home.cityIdentifier)
            trip.titleUserEdited = false
            context.insert(trip)
        }
        if trip.state == .draft {
            applyDateDerivedState(to: trip)
        }
        let lower = Calendar.autoupdatingCurrent.startOfDay(for: pending.startDay)
        let upper = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: 1,
            to: Calendar.autoupdatingCurrent.startOfDay(for: pending.endDay)
        ) ?? pending.endDay
        let footprints = (try? legacyContext.fetch(FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime < upper && $0.endTime > lower && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime)]
        ))) ?? []
        if trip.coverPhotoIdentifier == nil {
            trip.coverPhotoIdentifier = footprints.lazy.compactMap { $0.photoAssetIDs.first }.first
        }
        if trip.originRaw == TripOrigin.automatic.rawValue, trip.activityTypeValue == nil {
            trip.activityTypeValue = dominantAwayActivityType(in: footprints, home: home)
        }
        let existingDays = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? []).filter { $0.tripID == trip.id }
        var daysByKey: [String: TripDay] = [:]
        for day in existingDays { daysByKey[dayKey(day.day)] = day }
        let allCities = (try? context.fetch(FetchDescriptor<TripDayCity>())) ?? []
        for (key, cities) in pending.citiesByDay {
            guard let date = dayFormatter.date(from: key) else { continue }
            let tripDay = daysByKey[key] ?? TripDay(tripID: trip.id, day: date)
            if tripDay.modelContext == nil { context.insert(tripDay) }
            daysByKey[key] = tripDay
            let currentCities = allCities.filter { $0.tripDayID == tripDay.id }
            for (index, city) in cities.enumerated() {
                if let existing = currentCities.first(where: {
                    tripCitiesMatch(
                        firstIdentifier: $0.cityIdentifier,
                        firstCountryCode: $0.countryCode,
                        firstCityName: $0.cityName,
                        secondIdentifier: nil,
                        secondCountryCode: city.countryCode,
                        secondCityName: city.cityName
                    )
                }) {
                    if !trip.citiesUserEdited, !existing.isUserEdited { existing.orderIndex = index }
                } else {
                    context.insert(TripDayCity(tripDayID: tripDay.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, latitude: city.latitude, longitude: city.longitude, orderIndex: index, isUserEdited: false))
                }
            }
        }
        if trip.originRaw == TripOrigin.automatic.rawValue, !trip.titleUserEdited {
            let refreshedDays = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? [])
                .filter { $0.tripID == trip.id }
                .sorted { $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day }
            let refreshedDayIDs = Set(refreshedDays.map(\.id))
            let refreshedCities = ((try? context.fetch(FetchDescriptor<TripDayCity>())) ?? [])
                .filter { refreshedDayIDs.contains($0.tripDayID) }
            var seen = Set<String>()
            let orderedCities = refreshedDays.flatMap { day in
                refreshedCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
            }.compactMap { city -> PendingCity? in
                guard seen.insert(cityKey(city.countryCode, city.cityName)).inserted else { return nil }
                return PendingCity(
                    countryCode: city.countryCode,
                    countryName: city.countryName,
                    cityName: city.cityName,
                    latitude: city.latitude,
                    longitude: city.longitude
                )
            }
            trip.title = automaticTitle(
                for: orderedCities,
                home: home,
                start: trip.plannedStartDay,
                end: trip.plannedEndDay
            )
        }
    }

    nonisolated private static func inclusiveDayCount(from start: Date, through end: Date) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        return max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1)
    }

    nonisolated private static func applyDateDerivedState(to trip: Trip) {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        if trip.plannedEndDay < today {
            trip.state = .historical
            trip.kind = .historical
        } else if trip.plannedStartDay <= today {
            trip.state = .active
            trip.kind = .historical
        } else {
            trip.state = .planned
            trip.kind = .planned
        }
    }

    nonisolated private static func dominantAwayActivityType(
        in footprints: [Footprint],
        home: HomeCity
    ) -> String? {
        var counts: [String: Int] = [:]
        var firstIndexes: [String: Int] = [:]
        for (index, footprint) in footprints.enumerated() {
            guard !footprintMatchesHome(footprint, home: home),
                  let value = footprint.activityTypeValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            counts[value, default: 0] += 1
            if firstIndexes[value] == nil { firstIndexes[value] = index }
        }
        return counts.keys.max {
            let leftCount = counts[$0, default: 0]
            let rightCount = counts[$1, default: 0]
            if leftCount != rightCount { return leftCount < rightCount }
            return firstIndexes[$0, default: .max] > firstIndexes[$1, default: .max]
        }
    }

    nonisolated private static func footprintMatchesHome(_ footprint: Footprint, home: HomeCity) -> Bool {
        guard normalized(footprint.cityName ?? "") == normalized(home.cityName) else { return false }
        let footprintCode = normalized(footprint.countryCode ?? "")
        let homeCode = normalized(home.countryCode)
        if !footprintCode.isEmpty, !homeCode.isEmpty { return footprintCode == homeCode }
        let footprintCountry = normalized(footprint.countryName ?? "")
        let homeCountry = normalized(home.countryName)
        return footprintCountry.isEmpty || homeCountry.isEmpty || footprintCountry == homeCountry
    }

    nonisolated private static func splitPending(_ pending: Pending, maximumDays: Int) -> [Pending] {
        let calendar = Calendar.autoupdatingCurrent
        var result: [Pending] = []
        var chunkStart = calendar.startOfDay(for: pending.startDay)
        let finalDay = calendar.startOfDay(for: pending.endDay)
        while chunkStart <= finalDay {
            let candidateEnd = calendar.date(byAdding: .day, value: maximumDays - 1, to: chunkStart) ?? finalDay
            let chunkEnd = min(candidateEnd, finalDay)
            let cities = pending.citiesByDay.filter { key, _ in
                guard let date = dayFormatter.date(from: key) else { return false }
                return date >= chunkStart && date <= chunkEnd
            }
            if !cities.isEmpty {
                result.append(Pending(startDay: chunkStart, endDay: chunkEnd, citiesByDay: cities))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: chunkEnd), next > chunkEnd else { break }
            chunkStart = next
        }
        return result
    }

    nonisolated private static func automaticTitle(
        for cities: [PendingCity],
        home: HomeCity,
        start: Date,
        end: Date
    ) -> String {
        var seenCountries = Set<String>()
        let foreignCountries = cities.compactMap { city -> String? in
            guard isKnownForeignCountry(city, home: home) else { return nil }
            let countryName = city.countryName.trimmingCharacters(in: .whitespacesAndNewlines)
            let countryCode = city.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = countryCode.isEmpty ? normalized(countryName) : countryCode
            guard !key.isEmpty, seenCountries.insert(key).inserted else { return nil }
            return countryName.isEmpty ? countryCode : countryName
        }
        let destination: String
        if !foreignCountries.isEmpty {
            destination = foreignCountries.prefix(3).joined()
        } else {
            destination = cities.map(\.cityName).uniqued().prefix(3).map { shortCityName($0) }.joined()
        }
        guard !destination.isEmpty else { return "行程" }
        let dayCount = inclusiveDayCount(from: start, through: end)
        return "\(destination)\(chineseNumber(dayCount))日行"
    }

    nonisolated private static func orderedCities(in pending: Pending) -> [PendingCity] {
        var seen = Set<String>()
        return pending.citiesByDay.keys.sorted().flatMap { pending.citiesByDay[$0] ?? [] }.filter {
            seen.insert(cityKey($0.countryCode, $0.cityName)).inserted
        }
    }

    nonisolated private static func shortCityName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasSuffix("市") ? String(name.dropLast()) : name
    }

    nonisolated private static func chineseNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    nonisolated private static func isKnownForeignCountry(_ city: PendingCity, home: HomeCity) -> Bool {
        let cityCode = normalized(city.countryCode)
        let homeCode = normalized(home.countryCode)
        if !cityCode.isEmpty, !homeCode.isEmpty { return cityCode != homeCode }
        let cityCountry = normalized(city.countryName)
        let homeCountry = normalized(home.countryName)
        return !cityCountry.isEmpty && !homeCountry.isEmpty && cityCountry != homeCountry
    }

    nonisolated private static func readCities(in container: ModelContainer, from start: Date, through end: Date) -> [TripImportedDay] {
        let calendar = Calendar.autoupdatingCurrent
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime < upper && $0.endTime >= lower && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime)]
        )
        let footprints = (try? context.fetch(descriptor)) ?? []
        let finalDay = calendar.startOfDay(for: end)
        var result: [TripImportedDay] = []
        var day = lower
        while day <= finalDay {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? upper
            let overlapping = footprints.filter { $0.startTime < nextDay && $0.endTime > day }
            let orderedCities = overlapping.compactMap { footprint -> TripImportedCity? in
                guard let name = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                return TripImportedCity(
                    countryCode: footprint.countryCode ?? "",
                    countryName: footprint.countryName ?? "",
                    cityName: name,
                    latitude: footprint.latitude,
                    longitude: footprint.longitude
                )
            }
            var seen = Set<String>()
            let cities = orderedCities.filter { city in
                seen.insert(cityKey(city.countryCode, city.cityName)).inserted
            }
            result.append(TripImportedDay(day: day, cities: cities, lastCity: orderedCities.last))
            day = nextDay
        }
        return result
    }

    nonisolated private static func cityMatches(_ city: TripImportedCity, home: HomeCity) -> Bool {
        guard normalized(city.cityName) == normalized(home.cityName) else { return false }
        let cityCountry = normalized(city.countryCode)
        let homeCountry = normalized(home.countryCode)
        return cityCountry.isEmpty || homeCountry.isEmpty || cityCountry == homeCountry
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func cityKey(_ country: String, _ city: String, identifier: String? = nil) -> String {
        tripCityIdentityKey(identifier: identifier, countryCode: country, cityName: city)
    }

    nonisolated private static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
    nonisolated private static func loadPending() -> Pending? {
        guard let data = UserDefaults.standard.data(forKey: Keys.pending) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }
    nonisolated private static func savePending(_ pending: Pending?) {
        UserDefaults.standard.set(pending.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.pending)
    }
    nonisolated private static func loadSuppressedRanges() -> [SuppressedRange] {
        guard let data = UserDefaults.standard.data(forKey: Keys.suppressedRanges) else { return [] }
        return (try? JSONDecoder().decode([SuppressedRange].self, from: data)) ?? []
    }
    nonisolated private static func saveSuppressedRanges(_ ranges: [SuppressedRange]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(ranges), forKey: Keys.suppressedRanges)
    }
    nonisolated private static func mergedSuppressedRanges(_ ranges: [SuppressedRange]) -> [SuppressedRange] {
        let calendar = Calendar.autoupdatingCurrent
        let sorted = ranges.map {
            SuppressedRange(
                startDay: calendar.startOfDay(for: min($0.startDay, $0.endDay)),
                endDay: calendar.startOfDay(for: max($0.startDay, $0.endDay))
            )
        }.sorted { $0.startDay < $1.startDay }
        var result: [SuppressedRange] = []
        for range in sorted {
            guard var last = result.last else {
                result.append(range)
                continue
            }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: last.endDay) ?? last.endDay
            if range.startDay <= nextDay {
                last.endDay = max(last.endDay, range.endDay)
                result[result.count - 1] = last
            } else {
                result.append(range)
            }
        }
        return result
    }

    private enum Keys {
        static let enabled = "tripAutomaticRecognitionEnabled"
        static let cursor = "tripScanCursor"
        static let lastRun = "tripScanLastRun"
        static let pending = "tripScanPendingAwaySegment"
        static let suppressedRanges = "tripSuppressedAutomaticDateRanges"
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
@MainActor
final class TripProgressLiveActivityManager {
    static let shared = TripProgressLiveActivityManager()

    private var currentActivity: Activity<TripProgressActivityAttributes>?
    private var mapSnapshotKeyByTripID: [String: String] = [:]

    private init() {}

    func update(
        tripID: UUID,
        tripTitle: String,
        state: TripProgressActivityAttributes.ContentState,
        originCoordinate: CLLocationCoordinate2D? = nil,
        destinationCoordinate: CLLocationCoordinate2D? = nil,
        currentCoordinate: CLLocationCoordinate2D? = nil,
        routeCoordinates: [CLLocationCoordinate2D]? = nil
    ) {
        Task { @MainActor in
            guard CurrentLiveActivitySettings.isTripProgressEnabled,
                  ActivityAuthorizationInfo().areActivitiesEnabled else {
                await endAll()
                return
            }

            let tripIDString = tripID.uuidString
            let activities = Activity<TripProgressActivityAttributes>.activities
            var activity = activities.first { $0.attributes.tripID == tripIDString }
            for duplicate in activities where duplicate.id != activity?.id {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }

            if let existing = activity,
               existing.attributes.tripTitle != tripTitle {
                await existing.end(nil, dismissalPolicy: .immediate)
                activity = nil
            }

            let transportType = TransportType(rawValue: state.transportTypeRaw ?? "")
            await ensureMapSnapshot(
                tripID: tripIDString,
                latitude: state.latitude,
                longitude: state.longitude,
                originCoordinate: originCoordinate,
                destinationCoordinate: destinationCoordinate,
                currentCoordinate: currentCoordinate,
                routeCoordinates: routeCoordinates,
                transportIcon: transportType?.icon ?? "arrow.triangle.swap",
                drawsDirectConnection: transportType == .airplane || transportType == .ship
            )
            let content = ActivityContent(state: state, staleDate: nil)
            // Route loading and map rendering above suspend this task. Another
            // refresh may have created the activity while it was suspended, so
            // resolve the system activity again immediately before requesting.
            let refreshedActivities = Activity<TripProgressActivityAttributes>.activities
            let refreshedActivity = refreshedActivities.first { $0.attributes.tripID == tripIDString }
            for duplicate in refreshedActivities
            where duplicate.attributes.tripID == tripIDString && duplicate.id != refreshedActivity?.id {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            if let existing = refreshedActivity ?? activity {
                currentActivity = existing
                await existing.update(content)
            } else {
                do {
                    currentActivity = try Activity.request(
                        attributes: TripProgressActivityAttributes(
                            tripID: tripIDString,
                            tripTitle: tripTitle
                        ),
                        content: content,
                        pushType: nil
                    )
                } catch {
                    print("[TripProgressLiveActivity] request failed: \(error)")
                }
            }
        }
    }

    func endActivity(for tripID: UUID) {
        let tripIDString = tripID.uuidString
        Task { @MainActor in
            for activity in Activity<TripProgressActivityAttributes>.activities
            where activity.attributes.tripID == tripIDString {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            if currentActivity?.attributes.tripID == tripIDString {
                currentActivity = nil
            }
            mapSnapshotKeyByTripID[tripIDString] = nil
        }
    }

    func stop() {
        Task { @MainActor in await endAll() }
    }

    private func endAll() async {
        for activity in Activity<TripProgressActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        mapSnapshotKeyByTripID.removeAll()
    }

    private func ensureMapSnapshot(
        tripID: String,
        latitude: Double?,
        longitude: Double?,
        originCoordinate: CLLocationCoordinate2D?,
        destinationCoordinate: CLLocationCoordinate2D?,
        currentCoordinate: CLLocationCoordinate2D?,
        routeCoordinates: [CLLocationCoordinate2D]?,
        transportIcon: String,
        drawsDirectConnection: Bool
    ) async {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.ct106.difangke"
              ) else { return }

        let hash = String(format: "%.3f_%.3f", latitude, longitude)
        let lightURL = container.appendingPathComponent("trip_\(tripID)_\(hash)_light.png")
        let darkURL = container.appendingPathComponent("trip_\(tripID)_\(hash)_dark.png")
        let destination = destinationCoordinate
            ?? CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let current = currentCoordinate ?? originCoordinate ?? destination
        guard CLLocationCoordinate2DIsValid(current), CLLocationCoordinate2DIsValid(destination) else { return }
        let route = (routeCoordinates ?? []).filter(CLLocationCoordinate2DIsValid)
        let routeIdentity = route.isEmpty
            ? "none"
            : "\(route.count):\(String(format: "%.4f,%.4f", route[route.count / 2].latitude, route[route.count / 2].longitude))"
        let snapshotKey = [
            String(format: "%.3f,%.3f", current.latitude, current.longitude),
            String(format: "%.3f,%.3f", destination.latitude, destination.longitude),
            routeIdentity,
            transportIcon
        ].joined(separator: "|")
        guard mapSnapshotKeyByTripID[tripID] != snapshotKey
                || !FileManager.default.fileExists(atPath: lightURL.path)
                || !FileManager.default.fileExists(atPath: darkURL.path) else { return }

        let options = MKMapSnapshotter.Options()
        options.region = remainingRouteRegion(current: current, destination: destination)
        options.size = CGSize(width: 400, height: 200)
        options.scale = 2
        options.showsBuildings = true

        do {
            options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
            let lightSnapshot = try await MKMapSnapshotter(options: options).start()
            let lightImage = renderedTripProgressMap(
                lightSnapshot,
                routeCoordinates: route,
                currentCoordinate: current,
                destinationCoordinate: destination,
                drawsDirectConnection: drawsDirectConnection,
                interfaceStyle: .light
            )
            try lightImage.pngData()?.write(to: lightURL, options: .atomic)

            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            let darkSnapshot = try await MKMapSnapshotter(options: options).start()
            let darkImage = renderedTripProgressMap(
                darkSnapshot,
                routeCoordinates: route,
                currentCoordinate: current,
                destinationCoordinate: destination,
                drawsDirectConnection: drawsDirectConnection,
                interfaceStyle: .dark
            )
            try darkImage.pngData()?.write(to: darkURL, options: .atomic)
            mapSnapshotKeyByTripID[tripID] = snapshotKey
        } catch {
            print("[TripProgressLiveActivity] map snapshot failed: \(error)")
        }
    }

    private func remainingRouteRegion(
        current: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (current.latitude + destination.latitude) / 2,
                longitude: (current.longitude + destination.longitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.01, abs(current.latitude - destination.latitude) * 1.45),
                longitudeDelta: max(0.01, abs(current.longitude - destination.longitude) * 1.45)
            )
        )
    }

    private func renderedTripProgressMap(
        _ snapshot: MKMapSnapshotter.Snapshot,
        routeCoordinates: [CLLocationCoordinate2D],
        currentCoordinate: CLLocationCoordinate2D,
        destinationCoordinate: CLLocationCoordinate2D,
        drawsDirectConnection: Bool,
        interfaceStyle: UIUserInterfaceStyle
    ) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: interfaceStyle)
        let markerBackground = UIColor.systemBackground.resolvedColor(with: traits)
        return UIGraphicsImageRenderer(size: snapshot.image.size).image { _ in
            snapshot.image.draw(at: .zero)

            let displayedRouteCoordinates: [CLLocationCoordinate2D]
            let isDirectConnection: Bool
            if routeCoordinates.count > 1 {
                displayedRouteCoordinates = routeCoordinates
                isDirectConnection = false
            } else if drawsDirectConnection {
                displayedRouteCoordinates = [currentCoordinate, destinationCoordinate]
                isDirectConnection = true
            } else {
                displayedRouteCoordinates = []
                isDirectConnection = false
            }

            if displayedRouteCoordinates.count > 1 {
                let routePath = UIBezierPath()
                for (index, coordinate) in displayedRouteCoordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0 { routePath.move(to: point) } else { routePath.addLine(to: point) }
                }
                UIColor(red: 0, green: 0.73, blue: 0.78, alpha: 0.9).setStroke()
                routePath.lineWidth = isDirectConnection ? 3 : 5
                routePath.lineCapStyle = .round
                routePath.lineJoinStyle = .round
                if isDirectConnection {
                    routePath.setLineDash([8, 8], count: 2, phase: 0)
                }
                routePath.stroke()

            }

            drawTripProgressMapMarker(
                at: snapshot.point(for: currentCoordinate),
                color: UIColor.systemGreen,
                backgroundColor: markerBackground,
                in: snapshot.image.size
            )
            drawTripProgressMapMarker(
                at: snapshot.point(for: destinationCoordinate),
                color: UIColor(red: 0, green: 0.73, blue: 0.78, alpha: 1),
                backgroundColor: markerBackground,
                in: snapshot.image.size
            )
        }
    }

    private func drawTripProgressMapMarker(
        at point: CGPoint,
        color: UIColor,
        backgroundColor: UIColor,
        in size: CGSize
    ) {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return }
        let rect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        let path = UIBezierPath(ovalIn: rect)
        backgroundColor.setFill()
        path.fill()
        color.setFill()
        UIBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
    }
}
#endif

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>(); return filter { seen.insert($0).inserted }
    }
}

extension Notification.Name {
    static let tripScanDidFinish = Notification.Name("TripScanDidFinish")
}
