import Foundation
import SwiftData

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

    private init() {
        scannedThrough = UserDefaults.standard.object(forKey: Keys.cursor) as? Date
    }

    var recordModelContainer: ModelContainer? { legacyContainer }

    func configure(legacyContainer: ModelContainer, tripContainer: ModelContainer) {
        self.legacyContainer = legacyContainer
        self.tripContainer = tripContainer
        Task.detached(priority: .utility) {
            Self.finalizeLegacyAutomaticDrafts(in: tripContainer)
        }
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
                pending?.citiesByDay[key] = Array(Set(converted)).sorted { $0.cityName < $1.cityName }
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
            let pendingCities = pending.citiesByDay.values.flatMap { $0 }
            trip = Trip(
                title: automaticTitle(for: pendingCities, home: home),
                kind: .historical,
                state: .historical,
                origin: .automatic,
                plannedStartDay: pending.startDay,
                plannedEndDay: pending.endDay
            )
            trip.homeCityKeyAtCreation = cityKey(home.countryCode, home.cityName)
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
            let currentKeys = Set(allCities.filter { $0.tripDayID == tripDay.id }.map { cityKey($0.countryCode, $0.cityName) })
            for (index, city) in cities.enumerated() where !currentKeys.contains(cityKey(city.countryCode, city.cityName)) {
                context.insert(TripDayCity(tripDayID: tripDay.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, latitude: city.latitude, longitude: city.longitude, orderIndex: index, isUserEdited: false))
            }
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

    nonisolated private static func automaticTitle(for cities: [PendingCity], home: HomeCity) -> String {
        var seenCountries = Set<String>()
        let foreignCountries = cities.compactMap { city -> String? in
            guard isKnownForeignCountry(city, home: home) else { return nil }
            let countryName = city.countryName.trimmingCharacters(in: .whitespacesAndNewlines)
            let countryCode = city.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = countryCode.isEmpty ? normalized(countryName) : countryCode
            guard !key.isEmpty, seenCountries.insert(key).inserted else { return nil }
            return countryName.isEmpty ? countryCode : countryName
        }
        if !foreignCountries.isEmpty {
            return foreignCountries.prefix(3).joined(separator: "、")
        }
        let cityNames = cities.map(\.cityName).uniqued()
        return cityNames.prefix(3).joined(separator: "、")
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

    nonisolated private static func cityKey(_ country: String, _ city: String) -> String {
        "\(country)|\(city)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>(); return filter { seen.insert($0).inserted }
    }
}

extension Notification.Name {
    static let tripScanDidFinish = Notification.Name("TripScanDidFinish")
}
