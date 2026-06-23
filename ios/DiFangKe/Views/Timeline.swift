import SwiftUI
import MapKit
import SwiftData
import Photos
import UIKit
import Aptabase

struct DFKTimelineView: View {
    var initialDate: Date?

    var body: some View {
        ContinuousTimelineView(initialDate: initialDate)
    }
}

#Preview {
    DFKTimelineView()
}

extension CodableCoordinate: @unchecked Sendable {}

private struct TimelineFootprintSnapshot: Sendable {
    let footprintID: UUID
    let date: Date
    let startTime: Date
    let endTime: Date
    let coordinates: [CodableCoordinate]
    let locationHash: String
    let reason: String?
    let status: FootprintStatus
    let aiScore: Float
    let isHighlight: Bool?
    let placeID: UUID?
    let photoAssetIDs: [String]
    let address: String?
    let isPlaceSuggestionIgnored: Bool
    let aiAnalyzed: Bool
    let isAddressEditedByHand: Bool
    let activityTypeValue: String?
    let stepCount: Int?
    let walkingDistance: Double?
    let floorsAscended: Int?
}

private struct TimelineTransportSnapshot: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let startLocation: String
    let endLocation: String
    let typeRaw: String
    let manualTypeRaw: String?
    let distance: Double
    let averageSpeed: Double
    let points: [CodableCoordinate]
    let stepCount: Int?
}

private struct TimelineDaySnapshot: Sendable {
    let date: Date
    let footprints: [TimelineFootprintSnapshot]
    let transports: [TimelineTransportSnapshot]
}

private struct TimelineBackfillSnapshot: Sendable {
    let days: [TimelineDaySnapshot]
    let places: [PlaceLite]
}

@MainActor
private final class ContinuousTimelineCache {
    private var timelinesByDate: [Date: [TimelineItem]] = [:]
    private var hiddenDates = Set<Date>()

    func contains(_ date: Date) -> Bool {
        timelinesByDate[date] != nil || hiddenDates.contains(date)
    }

    func cachedTimeline(for date: Date) -> [TimelineItem]? {
        timelinesByDate[date]
    }

    func isHidden(_ date: Date) -> Bool {
        hiddenDates.contains(date)
    }

    func invalidate(_ dates: some Sequence<Date>) {
        for date in dates {
            timelinesByDate.removeValue(forKey: date)
            hiddenDates.remove(date)
        }
    }

    func store(_ fetchedTimelines: [Date: [TimelineItem]], visibleDates: Set<Date>, hiddenDates: Set<Date>) {
        for (date, items) in fetchedTimelines {
            timelinesByDate[date] = items
        }
        self.hiddenDates.subtract(visibleDates)
        self.hiddenDates.formUnion(hiddenDates)
    }
}

private struct ContinuousTimelineView: View {
    var initialDate: Date?

    nonisolated private static let initialTimelineVisibleDateBatchSize = 30
    nonisolated private static let timelineVisibleDateBatchSize = 30
    nonisolated private static let calendarBackfillDateBatchSize = 30
    nonisolated private static let timelineCommitChunkSize = 24

    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isTimelinePresented = true
    @State private var loadedDates: [Date] = []
    @State private var timelinesByDate: [Date: [TimelineItem]] = [:]
    @State private var isLoadingEarlierDates = false
    @State private var todayScrollRequest = 0
    @State private var activeTimelineDate = Calendar.current.startOfDay(for: Date())
    @State private var timelineDetent: PresentationDetent = .medium
    @State private var visibleTimelineItems: [TimelineItem] = []
    @State private var visibleTimelineDates = Set<Date>()
    @State private var renderedMapItemIDs = Set<String>()
    @State private var renderedMapDetentKey = ""
    @State private var renderedMapRegion: MKCoordinateRegion?
    @State private var mapInteractionLockedVisibleDates: Set<Date>?
    @State private var visibleMapUpdateTask: Task<Void, Never>?
    @State private var deferredVisibleTimelineDates: Set<Date>?
    @State private var deferredTimelineWorkCount = 0
    @State private var isShowingSettings = false
    @State private var didRequestInitialTimeline = false
    @State private var allowsMapInteractionCollapse = false
    @State private var skipsNextMapExpansionCameraReset = false
    @State private var timelineCache = ContinuousTimelineCache()
    @State private var availableTimelineDateSet = Set<Date>()
    @State private var hiddenTimelineDateSet = Set<Date>()
    @State private var visibleTimelineFillTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                DFKMapView(
                    cameraPosition: $cameraPosition,
                    isInteractive: true,
                    timelineItems: visibleTimelineItems,
                    onMapInteraction: { interactionType in
                        guard allowsMapInteractionCollapse else { return }
                        lockVisibleTimelineMapForInteraction()
                        guard timelineDetent != .height(88) else { return }
                        skipsNextMapExpansionCameraReset = interactionType != .tap
                        withAnimation(.easeOut(duration: 0.2)) {
                            timelineDetent = .height(88)
                        }
                    },
                    showsMapControls: false
                )
            }
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                setupLocationManager()
                enableMapInteractionCollapseAfterInitialLayout()
                Task { await refreshAvailableTimelineDateCache() }
            }
            .task { await loadInitialTimeline() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in
                reloadLoadedTimeline()
                Task { await refreshAvailableTimelineDateCache() }
            }
            .onChange(of: allPlaces) { _, newValue in
                locationManager.allPlaces = newValue
                locationManager.forceRefreshOngoingAnalysis()
            }
            .onChange(of: timelineDetent) { oldValue, newValue in
                if oldValue == .height(88), newValue != .height(88) {
                    unlockVisibleTimelineMapAfterInteraction()
                    return
                }
                if isMapExpansion(from: oldValue, to: newValue) {
                    lockVisibleTimelineMapForInteraction()
                    guard !skipsNextMapExpansionCameraReset else {
                        skipsNextMapExpansionCameraReset = false
                        return
                    }
                    resetLockedMapCamera(animated: true)
                    return
                }
                guard mapInteractionLockedVisibleDates == nil else { return }
                refreshVisibleTimelineMap()
            }
            .onChange(of: locationManager.lastLocation?.timestamp) { _, _ in
                guard visibleTimelineItems.isEmpty else { return }
                refreshVisibleTimelineMap(delayNanoseconds: 0)
            }
            .sheet(isPresented: $isTimelinePresented) {
                ContinuousTimelineSheet(
                    dates: loadedDates,
                    timelinesByDate: timelinesByDate,
                    locationManager: locationManager,
                    activeTimelineDate: $activeTimelineDate,
                    todayScrollRequest: $todayScrollRequest,
                    timelineDetent: $timelineDetent,
                    loadEarlierDates: loadEarlierTimeline,
                    loadLaterDates: loadLaterTimeline,
                    loadLaterDatesAfter: { date in await loadLaterTimeline(from: date) },
                    loadDate: loadTimelineDate,
                    loadBackfillDates: loadTimelineDatesForBackfill,
                    calendarBackfillBatchSize: Self.calendarBackfillDateBatchSize,
                    availableDates: loadableTimelineDateSet,
                    visibleDatesChanged: updateVisibleTimelineDates,
                    isShowingSettings: $isShowingSettings
                )
                .presentationDetents([.height(88), .medium, .large], selection: $timelineDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .interactiveDismissDisabled()
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    private var loadableTimelineDateSet: Set<Date> {
        availableTimelineDateSet.subtracting(hiddenTimelineDateSet)
    }

    private func setupLocationManager() {
        locationManager.modelContext = modelContext
        locationManager.allPlaces = allPlaces
        if UserDefaults.standard.bool(forKey: "isTrackingEnabled") && !locationManager.isTracking {
            locationManager.startTracking()
        }
        locationManager.refreshAvailableRawDates()
    }

    private func enableMapInteractionCollapseAfterInitialLayout() {
        allowsMapInteractionCollapse = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            allowsMapInteractionCollapse = true
        }
    }

    private func loadInitialTimeline() async {
        guard !didRequestInitialTimeline else { return }
        didRequestInitialTimeline = true

        let targetDate = initialDate ?? Calendar.current.startOfDay(for: Date())
        activeTimelineDate = targetDate
        updateVisibleTimelineDates([targetDate])

        var initialDates = await refreshAvailableTimelineDateCache()
            .filter { $0 <= targetDate }
        if !initialDates.contains(targetDate) {
            initialDates.append(targetDate)
        }
        initialDates = Array(initialDates.sorted().suffix(Self.initialTimelineVisibleDateBatchSize))

        _ = await loadVisibleTimelineDates(initialDates.reversed(), visibleDateLimit: initialDates.count, defersMapUpdates: false, reloadLoadedDates: true)
        guard !Task.isCancelled else { return }

        refreshVisibleTimelineMap(for: [targetDate], delayNanoseconds: 120_000_000)
    }

    private func publishTimelineDatePlaceholders(for dates: [Date], including dateToInclude: Date? = nil) {
        var placeholderDates = Set(dates.map { Calendar.current.startOfDay(for: $0) })
        if let dateToInclude {
            placeholderDates.insert(Calendar.current.startOfDay(for: dateToInclude))
        }
        guard !placeholderDates.isEmpty else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedDates = Set(loadedDates).union(placeholderDates).sorted()
        }
    }

    private func publishTimelineDatePlaceholders(around date: Date, in availableDates: [Date]? = nil, radius: Int = 14) {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let dates = (availableDates ?? Array(availableTimelineDateSet)).map { calendar.startOfDay(for: $0) }.sorted()
        guard !dates.isEmpty else {
            publishTimelineDatePlaceholders(for: [normalizedDate])
            return
        }

        let anchorIndex = dates.firstIndex(of: normalizedDate) ?? (dates.firstIndex { $0 >= normalizedDate } ?? dates.endIndex)
        let lowerBound = max(dates.startIndex, anchorIndex - radius)
        let upperBound = min(dates.endIndex, anchorIndex + radius + 1)
        var placeholderDates = Array(dates[lowerBound..<upperBound])
        if !placeholderDates.contains(normalizedDate) {
            placeholderDates.append(normalizedDate)
        }
        publishTimelineDatePlaceholders(for: placeholderDates)
    }

    private func loadEarlierTimeline() async -> Bool {
        guard !isLoadingEarlierDates, let oldestDate = loadedDates.first else { return false }
        return await loadEarlierTimeline(from: oldestDate)
    }

    private func loadLaterTimeline() async -> Bool {
        guard !isLoadingEarlierDates, let newestDate = loadedDates.last else { return false }
        return await loadLaterTimeline(from: newestDate)
    }

    private func loadTimelineDate(_ date: Date) async -> Bool {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        if timelinesByDate[normalizedDate] != nil || timelineCache.contains(normalizedDate) {
            return loadedDates.contains(normalizedDate)
        }

        let availableDates = await availableTimelineDatesForLookup()
        guard availableDates.contains(normalizedDate) || calendar.isDateInToday(normalizedDate) else { return false }

        return await loadVisibleTimelineDates([normalizedDate], visibleDateLimit: 1, defersMapUpdates: true, reloadLoadedDates: true)
    }

    private func loadTimelineDatesForBackfill(_ dates: [Date]) async -> Bool {
        let calendar = Calendar.current
        let availableDates = await availableTimelineDatesForLookup()
        let normalizedDates = Array(Set(dates.map { calendar.startOfDay(for: $0) }))
            .filter { availableDates.contains($0) && !loadedDates.contains($0) }
            .sorted()
        guard !normalizedDates.isEmpty else { return false }

        let container = modelContext.container
        let snapshot = await Task.detached(priority: .utility) {
            Self.fetchTimelineSnapshots(for: normalizedDates, in: container)
        }.value
        guard !snapshot.days.isEmpty else { return false }

        var fetchedTimelines: [Date: [TimelineItem]] = [:]
        var loadedVisibleDates = Set<Date>()
        var hiddenDates = Set<Date>()
        var didLoadVisibleDate = false
        for (index, daySnapshot) in snapshot.days.sorted(by: { $0.date < $1.date }).enumerated() {
            guard !Task.isCancelled else { break }
            guard !loadedDates.contains(daySnapshot.date) else { continue }

            let items = Self.timelineItems(from: daySnapshot, allPlaces: snapshot.places)
            fetchedTimelines[daySnapshot.date] = items

            if shouldDisplayTimelineDate(daySnapshot.date, items: items) {
                loadedVisibleDates.insert(daySnapshot.date)
                didLoadVisibleDate = true
            } else {
                hiddenDates.insert(daySnapshot.date)
            }

            if index > 0, index % Self.timelineCommitChunkSize == 0 {
                await yieldAfterTimelineBatch()
            }
        }

        publishLoadedTimelines(fetchedTimelines, visibleDates: loadedVisibleDates, hiddenDates: hiddenDates)

        return didLoadVisibleDate
    }

    nonisolated private static func fetchTimelineSnapshots(for dates: [Date], in container: ModelContainer) -> TimelineBackfillSnapshot {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let places = ((try? context.fetch(FetchDescriptor<Place>())) ?? []).map { place in
            PlaceLite(
                placeID: place.placeID,
                name: place.name,
                latitude: place.latitude,
                longitude: place.longitude,
                radius: Int(place.radius),
                isIgnored: place.isIgnored,
                isUserDefined: place.isUserDefined,
                isPriority: place.isPriority,
                address: place.address,
                category: place.category
            )
        }

        let days: [TimelineDaySnapshot] = dates.compactMap { date in
            let startOfDay = calendar.startOfDay(for: date)
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }

            let fpDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
                $0.startTime < endOfDay && $0.endTime > startOfDay && $0.statusValue != "ignored"
            })
            let footprints = ((try? context.fetch(fpDescriptor)) ?? []).map { footprint in
                TimelineFootprintSnapshot(
                    footprintID: footprint.footprintID,
                    date: footprint.date,
                    startTime: max(footprint.startTime, startOfDay),
                    endTime: min(max(footprint.endTime, footprint.startTime), endOfDay),
                    coordinates: footprint.footprintLocations.map { CodableCoordinate(lat: $0.latitude, lon: $0.longitude) },
                    locationHash: footprint.locationHash,
                    reason: footprint.reason,
                    status: footprint.status,
                    aiScore: footprint.aiScore,
                    isHighlight: footprint.isHighlight,
                    placeID: footprint.placeID,
                    photoAssetIDs: footprint.photoAssetIDs,
                    address: footprint.address,
                    isPlaceSuggestionIgnored: footprint.isPlaceSuggestionIgnored,
                    aiAnalyzed: footprint.aiAnalyzed,
                    isAddressEditedByHand: footprint.isAddressEditedByHand,
                    activityTypeValue: footprint.activityTypeValue,
                    stepCount: footprint.stepCount,
                    walkingDistance: footprint.walkingDistance,
                    floorsAscended: footprint.floorsAscended
                )
            }

            let tpDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.startTime < endOfDay && $0.endTime > startOfDay && $0.statusRaw != "ignored"
            })
            let transports = ((try? context.fetch(tpDescriptor)) ?? []).map { transport in
                let boundedStart = max(transport.startTime, startOfDay)
                let boundedEnd = min(max(transport.endTime, boundedStart), endOfDay)
                let decoded = (try? JSONDecoder().decode([CodableCoordinate].self, from: transport.pointsData)) ?? []
                return TimelineTransportSnapshot(
                    id: transport.recordID,
                    startTime: boundedStart,
                    endTime: boundedEnd,
                    startLocation: transport.startLocation,
                    endLocation: transport.endLocation,
                    typeRaw: transport.typeRaw,
                    manualTypeRaw: transport.manualTypeRaw,
                    distance: transport.distance,
                    averageSpeed: transport.averageSpeed,
                    points: decoded,
                    stepCount: transport.stepCount
                )
            }

            return TimelineDaySnapshot(date: startOfDay, footprints: footprints, transports: transports)
        }

        return TimelineBackfillSnapshot(days: days, places: places)
    }

    @MainActor
    private static func timelineItems(from snapshot: TimelineDaySnapshot, allPlaces: [PlaceLite]) -> [TimelineItem] {
        var items: [TimelineItem] = []

        for footprint in snapshot.footprints {
            let coordinates = footprint.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let model = Footprint(
                footprintID: footprint.footprintID,
                date: footprint.date,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                footprintLocations: coordinates,
                locationHash: footprint.locationHash,
                duration: max(0, footprint.endTime.timeIntervalSince(footprint.startTime)),
                reason: footprint.reason,
                status: footprint.status,
                aiScore: footprint.aiScore,
                isHighlight: footprint.isHighlight,
                placeID: footprint.placeID,
                photoAssetIDs: footprint.photoAssetIDs,
                address: footprint.address,
                isPlaceSuggestionIgnored: footprint.isPlaceSuggestionIgnored,
                aiAnalyzed: footprint.aiAnalyzed,
                isAddressEditedByHand: footprint.isAddressEditedByHand,
                activityTypeValue: footprint.activityTypeValue,
                stepCount: footprint.stepCount,
                walkingDistance: footprint.walkingDistance,
                floorsAscended: footprint.floorsAscended
            )
            items.append(.footprint(model))
        }

        for transport in snapshot.transports {
            let pathPoints = transport.points.map {
                TransportPathPoint(
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    timestamp: $0.timestamp,
                    isSyntheticPadding: $0.isSyntheticPadding ?? false
                )
            }
            let coordinates = pathPoints.map(\.coordinate)
            let type = TransportType(rawValue: transport.typeRaw) ?? .slow
            let manualType = transport.manualTypeRaw.flatMap { TransportType(rawValue: $0) }
            items.append(.transport(Transport(
                id: transport.id,
                startTime: transport.startTime,
                endTime: transport.endTime,
                startLocation: transport.startLocation,
                endLocation: transport.endLocation,
                type: type,
                distance: transport.distance,
                averageSpeed: transport.averageSpeed,
                points: coordinates,
                pathPoints: pathPoints.isEmpty ? nil : pathPoints,
                manualType: manualType,
                stepCount: transport.stepCount
            )))
        }

        items.sort { $0.startTime < $1.startTime }
        return TimelineBuilder.alignTransportLocations(items, allPlaces: allPlaces).sorted { $0.startTime > $1.startTime }
    }

    @discardableResult
    private func loadRecentTimeline(visibleDateLimit: Int) async -> Bool {
        guard visibleDateLimit > 0 else { return false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var candidateDates = await refreshAvailableTimelineDateCache()
        candidateDates = candidateDates.filter { $0 <= today }
        if !candidateDates.contains(today) {
            candidateDates.append(today)
        }

        return await loadVisibleTimelineDates(candidateDates.sorted().reversed(), visibleDateLimit: visibleDateLimit, defersMapUpdates: true)
    }

    @discardableResult
    private func loadEarlierTimeline(from referenceDate: Date, visibleDateLimit: Int = Self.timelineVisibleDateBatchSize) async -> Bool {
        guard visibleDateLimit > 0 else { return false }

        let availableDates = await refreshAvailableTimelineDateCache()
        guard let earliestAvailableDate = availableDates.first else { return false }

        let calendar = Calendar.current
        let referenceDate = calendar.startOfDay(for: referenceDate)
        guard referenceDate > earliestAvailableDate else { return false }

        isLoadingEarlierDates = true
        defer { isLoadingEarlierDates = false }

        let candidateDates = availableDates.filter { $0 < referenceDate }
        guard !candidateDates.isEmpty else { return false }

        return await loadVisibleTimelineDates(candidateDates.reversed(), visibleDateLimit: visibleDateLimit, defersMapUpdates: true)
    }

    @discardableResult
    private func loadLaterTimeline(from referenceDate: Date, visibleDateLimit: Int = Self.timelineVisibleDateBatchSize) async -> Bool {
        guard visibleDateLimit > 0 else { return false }

        let availableDates = await refreshAvailableTimelineDateCache()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let referenceDate = calendar.startOfDay(for: referenceDate)
        let candidateDates = availableDates.filter { $0 > referenceDate && $0 <= today }
        guard !candidateDates.isEmpty else { return false }

        isLoadingEarlierDates = true
        defer { isLoadingEarlierDates = false }

        return await loadVisibleTimelineDates(candidateDates, visibleDateLimit: visibleDateLimit, defersMapUpdates: true)
    }

    private func loadVisibleTimelineDates<S: Sequence>(_ candidateDates: S, visibleDateLimit: Int, defersMapUpdates: Bool, reloadLoadedDates: Bool = false) async -> Bool where S.Element == Date {
        guard visibleDateLimit > 0 else { return false }

        let calendar = Calendar.current
        var uniqueDates = Set<Date>()
        var datesToLoad: [Date] = []

        for date in candidateDates {
            let normalizedDate = calendar.startOfDay(for: date)
            let hasRenderedTimeline = timelinesByDate[normalizedDate] != nil || timelineCache.isHidden(normalizedDate)
            guard (reloadLoadedDates || !hasRenderedTimeline), !uniqueDates.contains(normalizedDate) else { continue }
            uniqueDates.insert(normalizedDate)
            datesToLoad.append(normalizedDate)
            if datesToLoad.count >= visibleDateLimit { break }
        }

        guard !datesToLoad.isEmpty else { return false }

        var cachedTimelines: [Date: [TimelineItem]] = [:]
        var cachedVisibleDates = Set<Date>()
        var cachedHiddenDates = Set<Date>()
        datesToLoad.removeAll { date in
            if !reloadLoadedDates, let cachedTimeline = timelineCache.cachedTimeline(for: date) {
                cachedTimelines[date] = cachedTimeline
                cachedVisibleDates.insert(date)
                return true
            }
            if !reloadLoadedDates, timelineCache.isHidden(date) {
                cachedHiddenDates.insert(date)
                return true
            }
            return false
        }

        if !cachedTimelines.isEmpty || !cachedVisibleDates.isEmpty || !cachedHiddenDates.isEmpty {
            publishLoadedTimelines(cachedTimelines, visibleDates: cachedVisibleDates, hiddenDates: cachedHiddenDates)
        }

        guard !datesToLoad.isEmpty else { return !cachedVisibleDates.isEmpty }

        beginDeferredTimelineWork(defersMapUpdates: defersMapUpdates)
        defer { endDeferredTimelineWork(defersMapUpdates: defersMapUpdates) }

        let container = modelContext.container
        let snapshot = await Task.detached(priority: .utility) {
            Self.fetchTimelineSnapshots(for: datesToLoad, in: container)
        }.value
        guard !snapshot.days.isEmpty else {
            publishLoadedTimelines([:], visibleDates: [], hiddenDates: Set(datesToLoad))
            return false
        }

        var fetchedTimelines: [Date: [TimelineItem]] = [:]
        var loadedVisibleDates = Set<Date>()
        var hiddenDates = Set<Date>()
        var didLoadVisibleDate = false
        var fetchedDates = Set<Date>()

        for (index, daySnapshot) in snapshot.days.sorted(by: { $0.date < $1.date }).enumerated() {
            guard !Task.isCancelled else { break }
            fetchedDates.insert(daySnapshot.date)
            let hasRenderedTimeline = timelinesByDate[daySnapshot.date] != nil || timelineCache.isHidden(daySnapshot.date)
            guard reloadLoadedDates || !hasRenderedTimeline else { continue }

            let items = Self.timelineItems(from: daySnapshot, allPlaces: snapshot.places)
            fetchedTimelines[daySnapshot.date] = items

            if shouldDisplayTimelineDate(daySnapshot.date, items: items) {
                loadedVisibleDates.insert(daySnapshot.date)
                didLoadVisibleDate = true
            } else {
                hiddenDates.insert(daySnapshot.date)
            }

            if index > 0, index % Self.timelineCommitChunkSize == 0 {
                await yieldAfterTimelineBatch()
            }
        }

        hiddenDates.formUnion(Set(datesToLoad).subtracting(fetchedDates))

        publishLoadedTimelines(fetchedTimelines, visibleDates: loadedVisibleDates, hiddenDates: hiddenDates)
        return didLoadVisibleDate
    }

    private func publishLoadedTimelines(_ fetchedTimelines: [Date: [TimelineItem]], visibleDates: Set<Date>, hiddenDates: Set<Date>) {
        guard !fetchedTimelines.isEmpty || !visibleDates.isEmpty || !hiddenDates.isEmpty else { return }

        timelineCache.store(fetchedTimelines, visibleDates: visibleDates, hiddenDates: hiddenDates)
        hiddenTimelineDateSet.subtract(visibleDates)
        hiddenTimelineDateSet.formUnion(hiddenDates)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for (date, items) in fetchedTimelines {
                timelinesByDate[date] = items
            }

            var nextLoadedDates = Set(loadedDates)
            nextLoadedDates.subtract(hiddenDates)
            nextLoadedDates.formUnion(visibleDates)
            loadedDates = nextLoadedDates.sorted()
        }
    }

    private func loadTimelineIncrementally(for dates: [Date], batchSize: Int, defersMapUpdates: Bool) async -> [Date] {
        guard batchSize > 0, !dates.isEmpty else { return [] }
        let originalLoadedDates = Set(loadedDates)
        _ = await loadVisibleTimelineDates(dates, visibleDateLimit: dates.count, defersMapUpdates: defersMapUpdates, reloadLoadedDates: true)
        return loadedDates.filter { !originalLoadedDates.contains($0) }
    }

    private func yieldAfterTimelineBatch() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func beginDeferredTimelineWork(defersMapUpdates: Bool) {
        guard defersMapUpdates else { return }
        deferredTimelineWorkCount += 1
        visibleMapUpdateTask?.cancel()
    }

    private func endDeferredTimelineWork(defersMapUpdates: Bool) {
        guard defersMapUpdates else { return }
        deferredTimelineWorkCount = max(0, deferredTimelineWorkCount - 1)
        guard deferredTimelineWorkCount == 0 else { return }
        guard let deferredVisibleTimelineDates else { return }
        self.deferredVisibleTimelineDates = nil
        refreshVisibleTimelineMap(for: deferredVisibleTimelineDates, delayNanoseconds: 650_000_000)
    }

    @discardableResult
    private func refreshAvailableTimelineDateCache() async -> [Date] {
        let dates = await availableTimelineDatesForLoading()
        availableTimelineDateSet = Set(dates)
        return dates
    }

    private func availableTimelineDatesForLookup() async -> Set<Date> {
        if !availableTimelineDateSet.isEmpty { return availableTimelineDateSet }
        return Set(await refreshAvailableTimelineDateCache())
    }

    private func availableTimelineDatesForLoading() async -> [Date] {
        let rawDates = Array(locationManager.availableRawDates)
        let container = modelContext.container
        return await Task.detached(priority: .utility) {
            Self.fetchAvailableTimelineDates(rawDates: rawDates, in: container)
        }.value
    }

    nonisolated private static func fetchAvailableTimelineDates(rawDates _: [Date], in container: ModelContainer) -> [Date] {
        let calendar = Calendar.current
        var candidates = Set<Date>()
        let context = ModelContext(container)

        func insertCoveredDates(from startTime: Date, to endTime: Date) {
            var date = calendar.startOfDay(for: startTime)
            let endDate = calendar.startOfDay(for: max(endTime, startTime))
            while date <= endDate {
                candidates.insert(date)
                guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = nextDate
            }
        }

        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        if let footprints = try? context.fetch(footprintDescriptor) {
            for footprint in footprints {
                insertCoveredDates(from: footprint.startTime, to: footprint.endTime)
            }
        }

        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        if let transports = try? context.fetch(transportDescriptor) {
            for transport in transports {
                insertCoveredDates(from: transport.startTime, to: transport.endTime)
            }
        }

        return candidates.sorted()
    }

    @discardableResult
    private func loadTimeline(for dates: [Date]) -> [Date] {
        let calendar = Calendar.current
        var visibleDates = Set<Date>()
        var hiddenDates = Set<Date>()

        for date in dates {
            let normalizedDate = calendar.startOfDay(for: date)
            let items = PersistentTimelineBuilder.fetchTimeline(for: normalizedDate, in: modelContext)
            timelinesByDate[normalizedDate] = items
            if shouldDisplayTimelineDate(normalizedDate, items: items) {
                visibleDates.insert(normalizedDate)
            } else {
                hiddenDates.insert(normalizedDate)
            }
        }

        var nextLoadedDates = Set(loadedDates)
        nextLoadedDates.subtract(hiddenDates)
        nextLoadedDates.formUnion(visibleDates)
        loadedDates = nextLoadedDates.sorted()
        return visibleDates.sorted()
    }

    private func shouldDisplayTimelineDate(_ date: Date, items: [TimelineItem]) -> Bool {
        if !items.isEmpty { return true }
        return Calendar.current.isDateInToday(date)
    }

    private func reloadLoadedTimeline() {
        let datesToReload = Array(Set(timelinesByDate.keys).union(visibleTimelineDates)).sorted()
        guard !datesToReload.isEmpty else { return }
        timelineCache.invalidate(datesToReload)
        Task(priority: .utility) { @MainActor in
            _ = await loadTimelineIncrementally(for: datesToReload, batchSize: 1, defersMapUpdates: true)
        }
    }

    private func updateVisibleTimelineDates(_ dates: Set<Date>) {
        guard dates != visibleTimelineDates else {
            if deferredTimelineWorkCount > 0 {
                deferredVisibleTimelineDates = dates
            }
            return
        }
        visibleTimelineDates = dates
        guard mapInteractionLockedVisibleDates == nil else { return }
        if deferredTimelineWorkCount > 0 {
            deferredVisibleTimelineDates = dates
            return
        }
        refreshVisibleTimelineMap(for: dates)
    }

    private func scheduleVisibleTimelineFill(for dates: Set<Date>) {
        visibleTimelineFillTask?.cancel()
        let datesToFill = dates.filter { date in
            timelinesByDate[date] == nil && !timelineCache.isHidden(date)
        }
        guard !datesToFill.isEmpty else { return }

        visibleTimelineFillTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            _ = await loadVisibleTimelineDates(datesToFill.sorted(), visibleDateLimit: datesToFill.count, defersMapUpdates: true)
        }
    }

    private func lockVisibleTimelineMapForInteraction() {
        let lockedDates = visibleTimelineDates.isEmpty ? [activeTimelineDate] : visibleTimelineDates
        mapInteractionLockedVisibleDates = lockedDates
        visibleMapUpdateTask?.cancel()
    }

    private func resetLockedMapCamera(animated: Bool) {
        let lockedDates = mapInteractionLockedVisibleDates ?? (visibleTimelineDates.isEmpty ? [activeTimelineDate] : visibleTimelineDates)
        let items = timelineItemsForVisibleDates(visibleDates: lockedDates)
        visibleTimelineItems = items
        renderedMapItemIDs = Set(items.map(\.id))
        renderedMapDetentKey = currentMapDetentKey

        let region: MKCoordinateRegion?
        if items.isEmpty {
            region = currentLocationMapRegion()
        } else {
            region = adjustedMapRegion(for: mapCameraCoordinates(for: items))
        }

        guard let region else {
            renderedMapRegion = nil
            return
        }

        renderedMapRegion = region
        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }

    private func unlockVisibleTimelineMapAfterInteraction() {
        guard mapInteractionLockedVisibleDates != nil else {
            refreshVisibleTimelineMap()
            return
        }
        mapInteractionLockedVisibleDates = nil
        refreshVisibleTimelineMap(delayNanoseconds: 120_000_000)
    }

    private func isMapExpansion(from oldDetent: PresentationDetent, to newDetent: PresentationDetent) -> Bool {
        mapVisibilityRank(for: newDetent) > mapVisibilityRank(for: oldDetent)
    }

    private func mapVisibilityRank(for detent: PresentationDetent) -> Int {
        if detent == .height(88) { return 2 }
        if detent == .medium { return 1 }
        return 0
    }

    private func refreshVisibleTimelineMap(for visibleDates: Set<Date>? = nil, delayNanoseconds: UInt64 = 360_000_000) {
        guard mapInteractionLockedVisibleDates == nil else { return }
        let visibleDates = visibleDates ?? visibleTimelineDates
        visibleMapUpdateTask?.cancel()
        visibleMapUpdateTask = Task { @MainActor [visibleDates] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }

            let items = timelineItemsForVisibleDates(visibleDates: visibleDates)
            guard !items.isEmpty else {
                visibleTimelineItems = []
                renderedMapItemIDs = []
                renderedMapDetentKey = currentMapDetentKey

                if let region = currentLocationMapRegion() {
                    if shouldUpdateMapRegion(to: region) {
                        renderedMapRegion = region
                        withAnimation(.easeInOut(duration: 0.18)) {
                            cameraPosition = .region(region)
                        }
                    }
                } else {
                    renderedMapRegion = nil
                }
                return
            }

            let mapItemIDs = Set(items.map(\.id))
            let detentKey = currentMapDetentKey
            guard mapItemIDs != renderedMapItemIDs || detentKey != renderedMapDetentKey else { return }
            renderedMapItemIDs = mapItemIDs
            renderedMapDetentKey = detentKey

            visibleTimelineItems = items
            let coordinates = mapCameraCoordinates(for: items)

            if let region = adjustedMapRegion(for: coordinates) {
                if shouldUpdateMapRegion(to: region) {
                    renderedMapRegion = region
                    withAnimation(.easeInOut(duration: 0.18)) {
                        cameraPosition = .region(region)
                    }
                }
            }
        }
    }

    private func timelineItemsForVisibleDates(visibleDates: Set<Date>) -> [TimelineItem] {
        guard !visibleDates.isEmpty else { return [] }
        let calendar = Calendar.current
        return visibleDates
            .sorted()
            .flatMap { date in
                (timelinesByDate[calendar.startOfDay(for: date)] ?? []).filter { item in
                    visibleDates.contains(calendar.startOfDay(for: item.startTime))
                }
            }
    }

    private func shouldUpdateMapRegion(to newRegion: MKCoordinateRegion) -> Bool {
        guard let oldRegion = renderedMapRegion else { return true }

        let centerLatitudeDelta = abs(oldRegion.center.latitude - newRegion.center.latitude)
        let centerLongitudeDelta = abs(oldRegion.center.longitude - newRegion.center.longitude)
        let latitudeSpanDelta = abs(oldRegion.span.latitudeDelta - newRegion.span.latitudeDelta)
        let longitudeSpanDelta = abs(oldRegion.span.longitudeDelta - newRegion.span.longitudeDelta)
        let latitudeThreshold = max(oldRegion.span.latitudeDelta, newRegion.span.latitudeDelta) * 0.04
        let longitudeThreshold = max(oldRegion.span.longitudeDelta, newRegion.span.longitudeDelta) * 0.04

        return centerLatitudeDelta > latitudeThreshold ||
            centerLongitudeDelta > longitudeThreshold ||
            latitudeSpanDelta > latitudeThreshold ||
            longitudeSpanDelta > longitudeThreshold
    }

    private func mapCameraCoordinates(for items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        items.flatMap { item -> [CLLocationCoordinate2D] in
            switch item {
            case .footprint(let footprint):
                return [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
            case .transport(let transport):
                return sampledCoordinates(from: transport.points, maximumCount: 24)
            }
        }
    }

    private func sampledCoordinates(from coordinates: [CLLocationCoordinate2D], maximumCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 2 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[Int((Double(index) * step).rounded())]
        }
    }

    private func currentLocationMapRegion() -> MKCoordinateRegion? {
        guard let coordinate = locationManager.lastLocation?.coordinate ?? locationManager.potentialStopStartLocation?.coordinate else { return nil }
        return adjustedMapRegion(for: [coordinate])
    }

    private var currentMapDetentKey: String {
        if timelineDetent == .medium { return "medium" }
        if timelineDetent == .large { return "large" }
        return "collapsed"
    }

    private func adjustedMapRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard var region = coordinates.boundingRegion(paddingFactor: 1.4) else { return nil }
        guard timelineDetent == .medium else { return region }

        let visibleFraction = 0.48
        let screenHeight = max(1, UIScreen.main.bounds.height)
        let topInsetFraction = min(max(0, currentTopSafeAreaInset / screenHeight), max(0, visibleFraction - 0.25))
        let usableVisibleFraction = max(0.25, visibleFraction - topInsetFraction)
        let adjustedLatitudeDelta = region.span.latitudeDelta / usableVisibleFraction
        let centerShift = adjustedLatitudeDelta * (0.5 - topInsetFraction - usableVisibleFraction / 2)

        region.center.latitude -= centerShift
        region.span.latitudeDelta = adjustedLatitudeDelta
        region.span.longitudeDelta *= 1.18
        return region
    }

    private var currentTopSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

}

private struct ContinuousTimelineSheet: View {
    private enum ScrollTarget: Hashable {
        case date(Date)
        case now
        case todayBottom
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var activityTypes: [ActivityType]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var lastPrefetchOldestDate: Date?
    @State private var selectedFootprint: Footprint?
    @State private var selectedTransport: Transport?
    @State private var allowsEarlierDatePrefetch = false
    @State private var latestScrollOffsetY: CGFloat = .infinity
    @State private var didReachEarliestAvailableDate = false
    @State private var lastEarlierDatePrefetchTime: Date?
    @State private var isShowingCalendar = false
    @State private var earlierDatePrefetchTask: Task<Void, Never>?
    @State private var scrollMetrics = ContinuousTimelineScrollMetrics()
    @State private var scrollRestorer = ContinuousTimelineScrollRestorer()
    @State private var headerVisibleDates: [Date] = []
    @State private var freezesViewportDrivenUpdatesUntil: Date?
    @State private var calendarScrollLockTarget: Date?
    @State private var pendingCalendarBackfillDates: [Date] = []
    @State private var calendarScrollRetryTask: Task<Void, Never>?
    @State private var calendarBackfillPinnedDate: Date?
    @State private var calendarBackfillPinTask: Task<Void, Never>?
    @State private var suppressesViewportUpdatesForBackfill = false
    @State private var backfillViewportSuppressionToken = UUID()
    @State private var latestDateFrames: [Date: CGRect] = [:]
    @State private var latestViewportHeight: CGFloat = 0
    @State private var calendarBackfillTask: Task<Void, Never>?
    @State private var lastUserInteractionTime = Date.distantPast
    @State private var isLoadingMoreEarlier = false
    @State private var isLoadingMoreLater = false
    @State private var loadingGapAfterDates = Set<Date>()
    @State private var showingResetAlert = false
    @State private var showingRawPointsDate: IdentifiableDate?
    @State private var footprintPendingDeletion: Footprint?
    @State private var transportPendingDeletion: Transport?
    @State private var footprintPendingSplit: Footprint?
    @State private var pendingMergeCandidate: ContinuousAdjacentFootprintMergeCandidate?
    @State private var pendingTransportMergeCandidate: ContinuousAdjacentTransportMergeCandidate?

    let dates: [Date]
    let timelinesByDate: [Date: [TimelineItem]]
    let locationManager: LocationManager
    @Binding var activeTimelineDate: Date
    @Binding var todayScrollRequest: Int
    @Binding var timelineDetent: PresentationDetent
    let loadEarlierDates: () async -> Bool
    let loadLaterDates: () async -> Bool
    let loadLaterDatesAfter: (Date) async -> Bool
    let loadDate: (Date) async -> Bool
    let loadBackfillDates: ([Date]) async -> Bool
    let calendarBackfillBatchSize: Int
    private let calendarBackfillDateLoadLimit = 1_000
    let availableDates: Set<Date>
    let visibleDatesChanged: (Set<Date>) -> Void
    @Binding var isShowingSettings: Bool

    private var isCollapsed: Bool {
        timelineDetent == .height(88)
    }

    private var showsReturnToTodayButton: Bool {
        guard !isCollapsed else { return false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activeDate = calendar.startOfDay(for: activeTimelineDate)
        let daysFromToday = calendar.dateComponents([.day], from: activeDate, to: today).day ?? 0
        return daysFromToday > 3
    }

    private var canLoadEarlierDates: Bool {
        guard let firstDate = dates.first else { return false }
        return availableDates.contains { $0 < firstDate }
    }

    private var canLoadLaterDates: Bool {
        guard let lastDate = dates.last else { return false }
        let today = Calendar.current.startOfDay(for: Date())
        return availableDates.contains { $0 > lastDate && $0 <= today }
    }

    private func hasLoadableTimelineDate(between earlierDate: Date, and laterDate: Date) -> Bool {
        let calendar = Calendar.current
        let earlierDate = calendar.startOfDay(for: earlierDate)
        let laterDate = calendar.startOfDay(for: laterDate)
        return availableDates.contains { availableDate in
            let normalizedDate = calendar.startOfDay(for: availableDate)
            return normalizedDate > earlierDate && normalizedDate < laterDate && !dates.contains(normalizedDate)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        ScrollOffsetObserver(restorer: scrollRestorer) { metrics in
                            scrollMetrics = metrics
                            latestScrollOffsetY = metrics.topOffsetY
                            if scrollRestorer.isUserInteracting {
                                lastUserInteractionTime = Date()
                            }
                        }
                        .frame(width: 0, height: 0)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            if canLoadEarlierDates {
                                TimelineLoadMoreButton(
                                    title: "查看更早的足迹",
                                    isLoading: isLoadingMoreEarlier,
                                    action: { requestLoadEarlierDates(using: proxy) }
                                )
                            }

                            ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                                if let previousDate = dates[safe: index - 1],
                                   let gapDays = Calendar.current.dateComponents([.day], from: previousDate, to: date).day,
                                   gapDays > 1 {
                                    if hasLoadableTimelineDate(between: previousDate, and: date) {
                                        TimelineLoadMoreButton(
                                            title: "查看更多足迹",
                                            isLoading: loadingGapAfterDates.contains(previousDate),
                                            action: { requestLoadDates(after: previousDate) }
                                        )
                                    }
                                    TimelineDateGapConnector(skippedDays: gapDays - 1)
                                }

                                timelineDay(for: date)
                                    .id(ScrollTarget.date(date))
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: ContinuousTimelineDateFramePreferenceKey.self,
                                                value: [date: geometry.frame(in: .named("continuousTimelineScroll"))]
                                            )
                                        }
                                    }
                            }

                            if canLoadLaterDates {
                                TimelineLoadMoreButton(
                                    title: "查看更多足迹",
                                    isLoading: isLoadingMoreLater,
                                    action: { requestLoadLaterDates() }
                                )
                            }
                        }
                        .padding(.top, 30)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 128)
                    }
                    .scrollDisabled(isCollapsed)
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: "continuousTimelineScroll")
                    .onPreferenceChange(ContinuousTimelineDateFramePreferenceKey.self) { frames in
                        latestDateFrames = frames
                        latestViewportHeight = viewport.size.height
                        if let target = calendarScrollLockTarget, frames[target] != nil {
                            scheduleLockedCalendarScroll(using: proxy)
                            return
                        }
                        if let pinnedDate = calendarBackfillPinnedDate, frames[pinnedDate] != nil {
                            scheduleCalendarBackfillPin(to: pinnedDate, using: proxy)
                            return
                        }
                        guard !isFreezingViewportDrivenUpdates else { return }
                        applyViewportDates(from: frames, viewportHeight: viewport.size.height)
                    }
                    .overlay(alignment: .bottom) {
                        if showsReturnToTodayButton {
                            Button {
                                requestScrollToToday(using: proxy)
                            } label: {
                                Label("回到当下", systemImage: "location.fill")
                            }
                            .returnToTodayButtonStyle()
                            .accessibilityLabel("回到当下")
                        }
                    }
                    .onChange(of: dates) { oldDates, newDates in
                        if oldDates.isEmpty, !newDates.isEmpty {
                            applySelectedCalendarDate(Calendar.current.startOfDay(for: Date()))
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                allowsEarlierDatePrefetch = true
                                freezesViewportDrivenUpdatesUntil = nil
                            }
                        }

                        if let requestedOldestDate = lastPrefetchOldestDate,
                           newDates.first == requestedOldestDate {
                            didReachEarliestAvailableDate = true
                        } else if newDates.first != oldDates.first {
                            didReachEarliestAvailableDate = false
                        }

                        if let target = calendarScrollLockTarget, newDates.contains(target) {
                            scheduleLockedCalendarScroll(using: proxy)
                        }
                        if let pinnedDate = calendarBackfillPinnedDate, newDates.contains(pinnedDate) {
                            scheduleCalendarBackfillPin(to: pinnedDate, using: proxy)
                        }
                    }
                    .onChange(of: todayScrollRequest) { _, _ in
                        requestScrollToToday(using: proxy)
                    }
                    .onDisappear {
                        calendarScrollRetryTask?.cancel()
                        calendarBackfillPinTask?.cancel()
                        calendarBackfillTask?.cancel()
                    }
                    .sheet(item: $selectedFootprint) { footprint in
                        FootprintModalView(footprint: footprint, autoFocus: false) { didChange in
                            guard didChange else { return }
                            invalidateAndRefreshTimeline(containing: footprint.startTime)
                            CloudSettingsManager.shared.triggerDataSyncPulse()
                        }
                            .environment(locationManager)
                    }
                    .sheet(item: $footprintPendingSplit, onDismiss: {
                        if let date = footprintPendingSplit?.startTime {
                            invalidateAndRefreshTimeline(containing: date)
                        } else {
                            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                        }
                        footprintPendingSplit = nil
                    }) { footprint in
                        FootprintSplitView(footprint: footprint)
                            .environment(locationManager)
                    }
                    .sheet(item: $selectedTransport) { transport in
                        TransportModalView(transport: transport) { newType in
                            updateTransport(transport, type: newType)
                        } onLocationUpdate: {
                            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                        }
                        .environment(locationManager)
                    }
                    .sheet(isPresented: $isShowingSettings) {
                        NavigationStack {
                            SettingsView()
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button {
                                            isShowingSettings = false
                                        } label: {
                                            Image(systemName: "xmark")
                                        }
                                    }
                                }
                        }
                    }
                        .sheet(item: $showingRawPointsDate) { item in
                            RawPointsListView(date: item.date)
                                .environment(locationManager)
                        }
                        .alert("重新生成本日数据", isPresented: $showingResetAlert) {
                            Button("确定重新生成", role: .destructive) {
                                locationManager.resetData(for: activeTimelineDate)
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("这将删除已手动修正或确认的足迹记录，并基于原始轨迹点重新分析生成时间线。")
                        }
                        .alert("确认删除足迹？", isPresented: Binding(
                            get: { footprintPendingDeletion != nil },
                            set: { if !$0 { footprintPendingDeletion = nil } }
                        )) {
                            Button("删除", role: .destructive) {
                                if let footprintPendingDeletion {
                                    deleteFootprint(footprintPendingDeletion)
                                }
                                footprintPendingDeletion = nil
                            }
                            Button("取消", role: .cancel) { footprintPendingDeletion = nil }
                        } message: {
                            Text("删除后，该足迹将不再出现在时间轴上。")
                        }
                        .alert("确认删除此交通记录？", isPresented: Binding(
                            get: { transportPendingDeletion != nil },
                            set: { if !$0 { transportPendingDeletion = nil } }
                        )) {
                            Button("取消", role: .cancel) { transportPendingDeletion = nil }
                            Button("删除", role: .destructive) {
                                if let transportPendingDeletion {
                                    deleteTransport(transportPendingDeletion)
                                }
                                transportPendingDeletion = nil
                            }
                        } message: {
                            Text("删除后该段交通将从时间轴中隐藏。")
                        }
                        .alert("合并相邻足迹？", isPresented: Binding(
                            get: { pendingMergeCandidate != nil },
                            set: { if !$0 { pendingMergeCandidate = nil } }
                        )) {
                            Button("合并") {
                                if let pendingMergeCandidate {
                                    mergeAdjacentFootprints(pendingMergeCandidate)
                                }
                                pendingMergeCandidate = nil
                            }
                            Button("取消", role: .cancel) { pendingMergeCandidate = nil }
                        } message: {
                            Text(mergeConfirmationMessage)
                        }
                        .alert("合并相邻交通？", isPresented: Binding(
                            get: { pendingTransportMergeCandidate != nil },
                            set: { if !$0 { pendingTransportMergeCandidate = nil } }
                        )) {
                            Button("合并") {
                                if let pendingTransportMergeCandidate {
                                    mergeAdjacentTransports(pendingTransportMergeCandidate)
                                }
                                pendingTransportMergeCandidate = nil
                            }
                            Button("取消", role: .cancel) { pendingTransportMergeCandidate = nil }
                        } message: {
                            Text(transportMergeConfirmationMessage)
                        }
                    .toolbar { headerToolbar(proxy: proxy) }
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func headerToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if timelineDetent == .large {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        timelineDetent = .medium
                    }
                } label: {
                    Image(systemName: "map")
                }
            }
        }

        ToolbarItem(placement: .principal) {
            Button {
                handleDateHeaderTap()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(dateHeader)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Text(secondaryHeader)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.primary)
                .frame(minWidth: 132, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                TapGesture().onEnded {
                    handleDateHeaderTap()
                }
            )
            .popover(isPresented: $isShowingCalendar) {
                let today = Calendar.current.startOfDay(for: Date())
                let activeDates = Set(availableDates.filter { $0 <= today })

                MiniCalendarView(selectedDate: $activeTimelineDate, availableDates: activeDates) { date in
                    isShowingCalendar = false
                    scrollToDate(date, using: proxy)
                }
                .presentationCompactAdaptation(.popover)
            }
            .contextMenu {
                Button {
                    showingRawPointsDate = IdentifiableDate(date: activeTimelineDate)
                } label: {
                    Label("查看所有轨迹点", systemImage: "dot.radiowaves.left.and.right")
                }

                Divider()

                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Label("重新生成本日数据", systemImage: "arrow.counterclockwise")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    private func expandTimelineIfCollapsed() {
        guard isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            timelineDetent = .medium
        }
    }

    private func handleDateHeaderTap() {
        if isCollapsed {
            expandTimelineIfCollapsed()
        } else {
            isShowingCalendar = true
        }
    }

    private var dateHeader: String {
        let displayDates = headerVisibleDates.isEmpty ? [activeTimelineDate] : headerVisibleDates
        guard let firstDate = displayDates.first, let lastDate = displayDates.last else { return timelineDateTitle(for: activeTimelineDate) }

        if Calendar.current.isDate(firstDate, inSameDayAs: lastDate) {
            return timelineDateTitle(for: firstDate)
        }

        return "\(timelineDateTitle(for: firstDate))-\(timelineDateTitle(for: lastDate))"
    }

    private var secondaryHeader: String {
        let displayDates = headerVisibleDates.isEmpty ? [activeTimelineDate] : headerVisibleDates
        guard let firstDate = displayDates.first, let lastDate = displayDates.last else { return timelineDateSecondaryTitle(for: activeTimelineDate) }

        if Calendar.current.isDate(firstDate, inSameDayAs: lastDate) {
            return timelineDateSecondaryTitle(for: firstDate)
        }

        return "\(firstDate.formatted(.dateTime.weekday(.wide)))-\(lastDate.formatted(.dateTime.weekday(.wide)))"
    }

    private func timelineDateTitle(for display: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(display) { return "今天" }
        if calendar.isDateInYesterday(display) { return "昨天" }
        if calendar.isDateInTomorrow(display) { return "明天" }

        let today = calendar.startOfDay(for: Date())
        if let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: today),
           calendar.isDate(display, inSameDayAs: dayBeforeYesterday) {
            return "前天"
        }

        let isCurrentYear = calendar.component(.year, from: display) == calendar.component(.year, from: today)
        return isCurrentYear ? display.formatted(.dateTime.month().day()) : display.formatted(.dateTime.year().month().day())
    }

    private func timelineDateSecondaryTitle(for display: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: today)!
        let isRelative = calendar.isDateInToday(display) ||
                         calendar.isDateInYesterday(display) ||
                         calendar.isDateInTomorrow(display) ||
                         calendar.isDate(display, inSameDayAs: dayBeforeYesterday)

        if isRelative {
            let isCurrentYear = calendar.component(.year, from: display) == calendar.component(.year, from: today)
            let dateText = isCurrentYear ? display.formatted(.dateTime.month().day()) : display.formatted(.dateTime.year().month().day())
            return "\(dateText) \(display.formatted(.dateTime.weekday(.wide)))"
        }

        return display.formatted(.dateTime.weekday(.wide))
    }

    private var isFreezingViewportDrivenUpdates: Bool {
        if suppressesViewportUpdatesForBackfill { return true }
        if calendarScrollLockTarget != nil { return true }
        if calendarBackfillPinnedDate != nil { return true }
        guard let freezesViewportDrivenUpdatesUntil else { return false }
        return Date() < freezesViewportDrivenUpdatesUntil
    }

    private func significantVisibleDates(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Set<Date> {
        let bandTop: CGFloat = 52
        let bandBottom = max(bandTop, viewportHeight - 72)
        let centerY = viewportHeight * 0.5

        var visibleDates = Set(frames.compactMap { date, frame in
            let intersectionTop = max(frame.minY, bandTop)
            let intersectionBottom = min(frame.maxY, bandBottom)
            let intersectionHeight = max(0, intersectionBottom - intersectionTop)
            let minimumVisibleHeight = min(90, max(36, frame.height * 0.2))
            let containsCenter = frame.minY <= centerY && frame.maxY >= centerY
            return intersectionHeight >= minimumVisibleHeight || containsCenter ? date : nil
        })

        if let bottomDate = bottomVisibleDate(in: frames, viewportHeight: viewportHeight) {
            visibleDates.insert(bottomDate)
        }

        return visibleDates
    }

    private func bottomVisibleDate(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Date? {
        let bandTop: CGFloat = 52
        let bottomContentProbeY = max(bandTop, viewportHeight - 132)

        if let probeDate = frames
            .filter({ _, frame in frame.minY <= bottomContentProbeY && frame.maxY >= bottomContentProbeY })
            .max(by: { $0.value.minY < $1.value.minY })?
            .key {
            return probeDate
        }

        return frames
            .filter { _, frame in frame.maxY > bandTop && frame.minY < viewportHeight }
            .max(by: { $0.value.minY < $1.value.minY })?
            .key
    }

    private func applyViewportDates(from frames: [Date: CGRect], viewportHeight: CGFloat) {
        if scrollMetrics.bottomDistance < 8, let bottomDate = dates.last {
            activeTimelineDate = bottomDate
            if headerVisibleDates != [bottomDate] {
                headerVisibleDates = [bottomDate]
            }
            visibleDatesChanged([bottomDate])
            return
        }

        let visibleDates = significantVisibleDates(in: frames, viewportHeight: viewportHeight)
        if let headerDate = bottomVisibleDate(in: frames, viewportHeight: viewportHeight) {
            activeTimelineDate = headerDate
            if headerVisibleDates != [headerDate] {
                headerVisibleDates = [headerDate]
            }
        }
        visibleDatesChanged(visibleDates)
    }

    private func applySelectedCalendarDate(_ date: Date) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        activeTimelineDate = normalizedDate
        headerVisibleDates = [normalizedDate]
        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
        visibleDatesChanged([normalizedDate])
    }

    @ViewBuilder
    private func timelineDay(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if date == dates.first {
                Color.clear
                    .frame(height: 1)
            }

            ZStack(alignment: .leading) {
                DottedTimelineSeparator()
                    .offset(y: -12)
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2, height: 30)
                    .offset(x: ContinuousTimelineLayout.markerCenterX - 1)
                Text(date.formatted(.dateTime.month().day()))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: ContinuousTimelineLayout.dateColumnWidth, alignment: .leading)
            }
            .frame(height: 30)

            Color.clear
                .frame(height: 1)

            let items = (timelinesByDate[date] ?? []).sorted { $0.startTime < $1.startTime }
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let mergeCandidate = adjacentMergeCandidate(for: item)
                let transportMergeCandidate = adjacentTransportMergeCandidate(for: item)
                ContinuousTimelineRow(
                    item: item,
                    nextStartTime: items.indices.contains(index + 1) ? items[index + 1].startTime : nil,
                    activityTypes: activityTypes,
                    showsContinuation: true,
                    usesMinimumBottomSpacing: shouldUseMinimumSpacingBeforeCurrentStay(item, at: index, in: items, date: date),
                    canMergeItem: mergeCandidate != nil || transportMergeCandidate != nil,
                    onTap: {
                        switch item {
                        case .footprint(let footprint): selectedFootprint = storedFootprint(matching: footprint)
                        case .transport(let transport): selectedTransport = transport
                        }
                    },
                    onMerge: {
                        switch item {
                        case .footprint:
                            pendingMergeCandidate = mergeCandidate
                        case .transport:
                            pendingTransportMergeCandidate = transportMergeCandidate
                        }
                    },
                    onSplit: {
                        guard case .footprint(let footprint) = item else { return }
                        footprintPendingSplit = storedFootprint(matching: footprint)
                    },
                    onToggleFavorite: {
                        guard case .footprint(let footprint) = item else { return }
                        toggleFavorite(for: footprint)
                    },
                    onDelete: {
                        switch item {
                        case .footprint(let footprint): footprintPendingDeletion = footprint
                        case .transport(let transport): transportPendingDeletion = transport
                        }
                    }
                )
            }

            if Calendar.current.isDateInToday(date) {
                CurrentStayTimelineCard(locationManager: locationManager)
                    .id(ScrollTarget.now)
                Color.clear
                    .frame(height: 1)
                    .id(ScrollTarget.todayBottom)
            }

        }
    }

    private func requestScrollToToday(using proxy: ScrollViewProxy) {
        if isCollapsed {
            withAnimation(.easeInOut(duration: 0.2)) {
                timelineDetent = .medium
            }
        }

        Task { @MainActor in
            for delay in [0, 90_000_000, 220_000_000, 420_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                scrollToToday(using: proxy)
            }
        }
    }

    private func scrollToDate(_ date: Date, using proxy: ScrollViewProxy) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        Task { @MainActor in
            calendarBackfillTask?.cancel()
            calendarScrollRetryTask?.cancel()
            calendarScrollRetryTask = nil
            calendarScrollLockTarget = normalizedDate
            pendingCalendarBackfillDates = timelineDatesToBackfill(afterSelecting: normalizedDate)
            if !dates.contains(normalizedDate) {
                guard await loadDate(normalizedDate) else {
                    calendarScrollLockTarget = nil
                    pendingCalendarBackfillDates = []
                    freezesViewportDrivenUpdatesUntil = nil
                    return
                }
            }

            applySelectedCalendarDate(normalizedDate)
            if dates.contains(normalizedDate) || latestDateFrames[normalizedDate] != nil {
                scheduleLockedCalendarScroll(using: proxy)
            }
        }
    }

    private func scheduleLockedCalendarScroll(using proxy: ScrollViewProxy) {
        guard let target = calendarScrollLockTarget else { return }
        guard calendarScrollRetryTask == nil else { return }

        calendarScrollRetryTask = Task { @MainActor in
            defer { calendarScrollRetryTask = nil }

            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                applySelectedCalendarDate(target)

                if attempt == 0 {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(ScrollTarget.date(target), anchor: .top)
                    }
                } else {
                    proxy.scrollTo(ScrollTarget.date(target), anchor: .top)
                }

                try? await Task.sleep(nanoseconds: attempt < 3 ? 120_000_000 : 220_000_000)
                if isCalendarScrollTargetVisible(target) {
                    break
                }
            }

            applySelectedCalendarDate(target)
            calendarScrollLockTarget = nil
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.25)
            let backfillDates = pendingCalendarBackfillDates
            pendingCalendarBackfillDates = []
            startCalendarBackfill(for: backfillDates, pinnedTo: target, using: proxy)
        }
    }

    private func scheduleCalendarBackfillPin(to date: Date, using proxy: ScrollViewProxy) {
        guard calendarBackfillPinTask == nil else { return }

        calendarBackfillPinTask = Task { @MainActor in
            defer { calendarBackfillPinTask = nil }

            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                guard calendarBackfillPinnedDate == date else { return }
                applySelectedCalendarDate(date)
                proxy.scrollTo(ScrollTarget.date(date), anchor: .top)
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func isCalendarScrollTargetVisible(_ date: Date) -> Bool {
        guard latestViewportHeight > 0, let frame = latestDateFrames[date] else { return false }
        return frame.maxY > 52 && frame.minY < latestViewportHeight - 72
    }

    private func timelineDatesToBackfill(afterSelecting selectedDate: Date) -> [Date] {
        []
    }

    private func startCalendarBackfill(for datesToLoad: [Date], pinnedTo pinnedDate: Date, using proxy: ScrollViewProxy) {
        calendarBackfillTask?.cancel()
        guard !datesToLoad.isEmpty else { return }

        calendarBackfillTask = Task(priority: .utility) { @MainActor in
            let suppressionToken = UUID()
            backfillViewportSuppressionToken = suppressionToken
            suppressesViewportUpdatesForBackfill = true
            calendarBackfillPinnedDate = pinnedDate
            defer {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    guard backfillViewportSuppressionToken == suppressionToken else { return }
                    suppressesViewportUpdatesForBackfill = false
                    calendarBackfillPinnedDate = nil
                }
            }

            await yieldBeforeCalendarBackfillStarts()

            var batchStartIndex = datesToLoad.startIndex
            while batchStartIndex < datesToLoad.endIndex {
                guard !Task.isCancelled else { return }
                let batchEndIndex = datesToLoad.index(
                    batchStartIndex,
                    offsetBy: max(1, calendarBackfillBatchSize),
                    limitedBy: datesToLoad.endIndex
                ) ?? datesToLoad.endIndex
                let batch = Array(datesToLoad[batchStartIndex..<batchEndIndex]).filter { !dates.contains($0) }
                batchStartIndex = batchEndIndex
                guard !batch.isEmpty else { continue }

                await waitForCalendarBackfillSlot()
                guard !Task.isCancelled else { return }

                applySelectedCalendarDate(pinnedDate)
                proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .top)
                _ = await loadBackfillDates(batch)
                applySelectedCalendarDate(pinnedDate)
                proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .top)
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .top)
                }
                await yieldAfterCalendarBackfillBatch()
            }
        }
    }

    private func yieldBeforeCalendarBackfillStarts() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func waitForCalendarBackfillSlot() async {
        while scrollRestorer.isRestoring || scrollRestorer.isUserInteracting || !hasUserInteractionSettled {
            guard !Task.isCancelled else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
    }

    private var hasUserInteractionSettled: Bool {
        !scrollRestorer.isUserInteracting && Date().timeIntervalSince(lastUserInteractionTime) >= 0.75
    }

    private func waitForAnyUserInteractionToSettle() async {
        while scrollRestorer.isRestoring || !hasUserInteractionSettled {
            guard !Task.isCancelled else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func yieldAfterCalendarBackfillBatch() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 650_000_000)
    }

    private func scrollToToday(using proxy: ScrollViewProxy, animated: Bool = true) {
        let today = Calendar.current.startOfDay(for: Date())
        guard dates.contains(today) else { return }
        applySelectedCalendarDate(today)
        let hasCurrentStatus = locationManager.potentialStopStartLocation != nil || locationManager.uiIsMoving
        let target: ScrollTarget = hasCurrentStatus ? .now : .todayBottom
        let anchor: UnitPoint = hasCurrentStatus ? .center : .bottom
        if animated {
            withAnimation(.easeInOut) {
                proxy.scrollTo(ScrollTarget.date(today), anchor: .bottom)
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(ScrollTarget.date(today), anchor: .bottom)
            proxy.scrollTo(target, anchor: anchor)
        }
        applySelectedCalendarDate(today)
    }

    private func requestLoadEarlierDates(using proxy: ScrollViewProxy) {
        guard !isLoadingMoreEarlier else { return }
        let anchorDate = Calendar.current.startOfDay(for: activeTimelineDate)

        Task { @MainActor in
            isLoadingMoreEarlier = true
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadEarlierDates()
            isLoadingMoreEarlier = false

            if didLoad {
                applySelectedCalendarDate(anchorDate)
                Task { @MainActor in
                    for delay in [0, 80_000_000, 180_000_000, 320_000_000, 520_000_000] {
                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay))
                        }
                        guard dates.contains(anchorDate) else { continue }
                        applySelectedCalendarDate(anchorDate)
                        proxy.scrollTo(ScrollTarget.date(anchorDate), anchor: .top)
                        scrollRestorer.offset(by: -58)
                    }
                    freezesViewportDrivenUpdatesUntil = nil
                    applySelectedCalendarDate(anchorDate)
                }
            } else {
                didReachEarliestAvailableDate = true
                freezesViewportDrivenUpdatesUntil = nil
            }
        }
    }

    private func requestLoadLaterDates() {
        guard !isLoadingMoreLater else { return }

        Task { @MainActor in
            isLoadingMoreLater = true
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadLaterDates()
            isLoadingMoreLater = false
            freezesViewportDrivenUpdatesUntil = nil
            if !didLoad {
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        }
    }

    private func requestLoadDates(after date: Date) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        guard !loadingGapAfterDates.contains(normalizedDate) else { return }

        Task { @MainActor in
            loadingGapAfterDates.insert(normalizedDate)
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadLaterDatesAfter(normalizedDate)
            loadingGapAfterDates.remove(normalizedDate)
            freezesViewportDrivenUpdatesUntil = nil
            if !didLoad {
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        }
    }

    private func prefetchEarlierDatesIfNeeded(scrollOffsetY: CGFloat) {
        guard allowsEarlierDatePrefetch else { return }
        guard !scrollRestorer.isRestoring else { return }
        guard !scrollRestorer.isUserInteracting else { return }
        guard hasUserInteractionSettled else { return }
        guard !didReachEarliestAvailableDate else { return }
        guard let oldestDate = dates.first else { return }

        let prefetchDistance: CGFloat = 520
        guard scrollOffsetY < prefetchDistance else { return }

        scheduleEarlierDatePrefetch(for: oldestDate)
    }

    private func scheduleEarlierDatePrefetch(for oldestDate: Date) {
        guard allowsEarlierDatePrefetch else { return }
        guard !scrollRestorer.isRestoring else { return }
        guard !didReachEarliestAvailableDate else { return }
        guard lastPrefetchOldestDate != oldestDate else { return }

        earlierDatePrefetchTask?.cancel()
        earlierDatePrefetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            guard !scrollRestorer.isRestoring else { return }
            guard !scrollRestorer.isUserInteracting else { return }
            guard hasUserInteractionSettled else { return }
            guard latestScrollOffsetY < 520 else { return }
            await loadEarlierDatesIfNeeded(for: oldestDate)
        }
    }

    private func loadEarlierDatesIfNeeded(for oldestDate: Date) async {
        guard allowsEarlierDatePrefetch else { return }
        guard !scrollRestorer.isRestoring else { return }
        guard !scrollRestorer.isUserInteracting else { return }
        guard hasUserInteractionSettled else { return }
        guard !didReachEarliestAvailableDate else { return }
        guard lastPrefetchOldestDate != oldestDate else { return }
        let now = Date()
        if let lastEarlierDatePrefetchTime,
           now.timeIntervalSince(lastEarlierDatePrefetchTime) < 0.9 {
            return
        }

        let anchorBeforeLoading = scrollRestorer.captureAnchor()
        let bottomDistanceBeforeLoading = anchorBeforeLoading?.bottomDistance ?? scrollMetrics.bottomDistance
        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
        lastEarlierDatePrefetchTime = now
        lastPrefetchOldestDate = oldestDate

        scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
        await waitForAnyUserInteractionToSettle()
        guard !Task.isCancelled else { return }
        guard hasUserInteractionSettled else { return }
        let loadedEarlierDates = await loadEarlierDates()

        if loadedEarlierDates {
            scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 340_000_000)
                guard !scrollRestorer.isRestoring else { return }
                freezesViewportDrivenUpdatesUntil = nil
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        } else {
            didReachEarliestAvailableDate = true
            freezesViewportDrivenUpdatesUntil = nil
        }
    }

    private func shouldUseMinimumSpacingBeforeCurrentStay(_ item: TimelineItem, at index: Int, in items: [TimelineItem], date: Date) -> Bool {
        guard Calendar.current.isDateInToday(date) else { return false }
        guard let lastIndex = items.indices.last, index == lastIndex else { return false }
        guard case .footprint(let footprint) = item else { return false }
        guard let stopLocation = locationManager.potentialStopStartLocation else { return false }

        if let footprintPlaceID = footprint.placeID,
           let currentPlace = locationManager.matchedPlace,
           footprintPlaceID == currentPlace.placeID {
            return true
        }

        let footprintLocation = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
        return footprintLocation.distance(from: stopLocation) <= 80
    }

    private func updateTransport(_ transport: Transport, type: TransportType) {
        let transportID = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == transportID })
        if let record = try? modelContext.fetch(descriptor).first {
            record.manualTypeRaw = type.rawValue
            record.typeRaw = type.rawValue
            try? modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
        }
        invalidateAndRefreshTimeline(containing: transport.startTime)
    }

    private func storedFootprint(matching footprint: Footprint) -> Footprint {
        let footprintID = footprint.footprintID
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == footprintID })
        return (try? modelContext.fetch(descriptor).first) ?? footprint
    }

    private func storedTransportRecord(matching transport: Transport) -> TransportRecord? {
        let transportID = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == transportID })
        return try? modelContext.fetch(descriptor).first
    }

    private func adjacentMergeCandidate(for item: TimelineItem) -> ContinuousAdjacentFootprintMergeCandidate? {
        guard case .footprint(let footprint) = item else { return nil }
        return adjacentMergeCandidate(for: storedFootprint(matching: footprint))
    }

    private func adjacentMergeCandidate(for footprint: Footprint) -> ContinuousAdjacentFootprintMergeCandidate? {
        let allFootprints = adjacentSearchFootprints(around: footprint)
        guard let index = allFootprints.firstIndex(where: { $0.footprintID == footprint.footprintID }) else {
            return nil
        }

        if index > 0 {
            let previous = allFootprints[index - 1]
            if canMergeAdjacentFootprints(previous, footprint) {
                return ContinuousAdjacentFootprintMergeCandidate(base: previous, other: footprint)
            }
        }

        if index < allFootprints.count - 1 {
            let next = allFootprints[index + 1]
            if canMergeAdjacentFootprints(footprint, next) {
                return ContinuousAdjacentFootprintMergeCandidate(base: footprint, other: next)
            }
        }

        return nil
    }

    private func adjacentSearchFootprints(around footprint: Footprint) -> [Footprint] {
        let lowerBound = footprint.startTime.addingTimeInterval(-172800)
        let upperBound = footprint.endTime.addingTimeInterval(172800)
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate {
                $0.statusValue != "ignored" &&
                $0.endTime >= lowerBound &&
                $0.startTime <= upperBound
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func canMergeAdjacentFootprints(_ first: Footprint, _ second: Footprint) -> Bool {
        guard first.status != .ignored, second.status != .ignored else { return false }
        guard first.footprintID != second.footprintID else { return false }
        guard isSameDayFootprint(first), isSameDayFootprint(second) else { return false }
        guard Calendar.current.isDate(first.startTime, inSameDayAs: second.startTime) else { return false }
        return !hasTransportBetween(first, second)
    }

    private func isSameDayFootprint(_ footprint: Footprint) -> Bool {
        Calendar.current.isDate(footprint.startTime, inSameDayAs: footprint.endTime.addingTimeInterval(-0.001))
    }

    private func hasTransportBetween(_ first: Footprint, _ second: Footprint) -> Bool {
        let lowerBound = min(first.endTime, second.endTime)
        let upperBound = max(first.startTime, second.startTime)
        guard upperBound > lowerBound else { return false }

        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.statusRaw != "ignored" &&
                $0.endTime > lowerBound &&
                $0.startTime < upperBound
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private func adjacentTransportMergeCandidate(for item: TimelineItem) -> ContinuousAdjacentTransportMergeCandidate? {
        guard case .transport(let transport) = item,
              let record = storedTransportRecord(matching: transport) else { return nil }
        return adjacentTransportMergeCandidate(for: record)
    }

    private func adjacentTransportMergeCandidate(for record: TransportRecord) -> ContinuousAdjacentTransportMergeCandidate? {
        let allTransports = adjacentSearchTransports(around: record)
        guard let index = allTransports.firstIndex(where: { $0.recordID == record.recordID }) else {
            return nil
        }

        if index > 0 {
            let previous = allTransports[index - 1]
            if canMergeAdjacentTransports(previous, record) {
                return ContinuousAdjacentTransportMergeCandidate(base: previous, other: record)
            }
        }

        if index < allTransports.count - 1 {
            let next = allTransports[index + 1]
            if canMergeAdjacentTransports(record, next) {
                return ContinuousAdjacentTransportMergeCandidate(base: record, other: next)
            }
        }

        return nil
    }

    private func adjacentSearchTransports(around record: TransportRecord) -> [TransportRecord] {
        let lowerBound = record.startTime.addingTimeInterval(-172800)
        let upperBound = record.endTime.addingTimeInterval(172800)
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.statusRaw != "ignored" &&
                $0.endTime >= lowerBound &&
                $0.startTime <= upperBound
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func canMergeAdjacentTransports(_ first: TransportRecord, _ second: TransportRecord) -> Bool {
        guard first.statusRaw != "ignored", second.statusRaw != "ignored" else { return false }
        guard first.recordID != second.recordID else { return false }
        guard Calendar.current.isDate(first.startTime, inSameDayAs: second.startTime) else { return false }
        return !hasFootprintBetween(first, second)
    }

    private func hasFootprintBetween(_ first: TransportRecord, _ second: TransportRecord) -> Bool {
        let lowerBound = min(first.endTime, second.endTime)
        let upperBound = max(first.startTime, second.startTime)
        guard upperBound > lowerBound else { return false }

        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate {
                $0.statusValue != "ignored" &&
                $0.endTime > lowerBound &&
                $0.startTime < upperBound
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private var mergeConfirmationMessage: String {
        guard let pendingMergeCandidate else {
            return "合并后会保留较早的足迹，并删除另一条相邻足迹。"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let first = pendingMergeCandidate.first
        let second = pendingMergeCandidate.second
        return "将合并：\n\(footprintMergeDescription(for: first, formatter: formatter))\n\(footprintMergeDescription(for: second, formatter: formatter))"
    }

    private var transportMergeConfirmationMessage: String {
        guard let pendingTransportMergeCandidate else {
            return "合并后会保留较早的交通记录，并删除另一条相邻交通。"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let first = pendingTransportMergeCandidate.first
        let second = pendingTransportMergeCandidate.second
        return "将合并：\n\(transportMergeDescription(for: first, formatter: formatter))\n\(transportMergeDescription(for: second, formatter: formatter))"
    }

    private func footprintMergeDescription(for footprint: Footprint, formatter: DateFormatter) -> String {
        "\(formatter.string(from: footprint.startTime))-\(formatter.string(from: footprint.endTime))  \(footprintDisplayTitle(for: footprint))"
    }

    private func footprintDisplayTitle(for footprint: Footprint) -> String {
        if let placeID = footprint.placeID,
           let place = allPlaces.first(where: { $0.placeID == placeID && $0.isUserDefined }) {
            return place.name
        }
        return footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知地点"
    }

    private func transportMergeDescription(for record: TransportRecord, formatter: DateFormatter) -> String {
        let type = TransportType(rawValue: record.manualTypeRaw ?? record.typeRaw)?.localizedName ?? "交通"
        let route = "\(transportLocationTitle(record.startLocation)) → \(transportLocationTitle(record.endLocation))"
        return "\(formatter.string(from: record.startTime))-\(formatter.string(from: record.endTime))  \(type) · \(route)"
    }

    private func transportLocationTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知地点"
    }

    private func mergeAdjacentFootprints(_ candidate: ContinuousAdjacentFootprintMergeCandidate) {
        let base = candidate.first
        let other = candidate.second

        base.startTime = min(base.startTime, other.startTime)
        base.endTime = max(base.endTime, other.endTime)
        base.date = Calendar.current.startOfDay(for: base.startTime)
        base.status = .manual

        var mergedLocations = base.footprintLocations
        mergedLocations.append(contentsOf: other.footprintLocations)
        base.footprintLocations = mergedLocations

        if base.reason?.isEmpty ?? true {
            base.reason = other.reason
        }
        if base.address?.isEmpty ?? true {
            base.address = other.address
            base.isAddressEditedByHand = other.isAddressEditedByHand
        }
        if base.placeID == nil {
            base.placeID = other.placeID
        }
        if base.activityTypeValue == nil {
            base.activityTypeValue = other.activityTypeValue
        }
        if base.isHighlight != true {
            base.isHighlight = other.isHighlight
        }
        base.stepCount = combinedOptionalSum(base.stepCount, other.stepCount)
        base.walkingDistance = combinedOptionalSum(base.walkingDistance, other.walkingDistance)
        base.floorsAscended = combinedOptionalSum(base.floorsAscended, other.floorsAscended)

        var mergedPhotos = base.photoAssetIDs
        for photoID in other.photoAssetIDs where !mergedPhotos.contains(photoID) {
            mergedPhotos.append(photoID)
        }
        base.photoAssetIDs = mergedPhotos

        var mergedMetadata = base.photoMetadata
        for metadata in other.photoMetadata where !mergedMetadata.contains(metadata) {
            mergedMetadata.append(metadata)
        }
        base.photoMetadata = mergedMetadata

        let mergedStart = base.startTime
        let mergedEnd = base.endTime
        modelContext.delete(other)
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateTimelineAfterMerge(start: mergedStart, end: mergedEnd)
        Aptabase.shared.trackEvent("footprint_adjacent_merged")
    }

    private func mergeAdjacentTransports(_ candidate: ContinuousAdjacentTransportMergeCandidate) {
        let base = candidate.first
        let other = candidate.second
        let baseDurationBeforeMerge = base.endTime.timeIntervalSince(base.startTime)
        let otherDurationBeforeMerge = other.endTime.timeIntervalSince(other.startTime)
        let mergedStart = min(base.startTime, other.startTime)
        let mergedEnd = max(base.endTime, other.endTime)

        base.day = Calendar.current.startOfDay(for: mergedStart)
        base.startTime = mergedStart
        base.endTime = mergedEnd
        base.distance += other.distance
        let mergedDuration = mergedEnd.timeIntervalSince(mergedStart)
        base.averageSpeed = mergedDuration > 0 ? base.distance / mergedDuration : 0
        base.stepCount = combinedOptionalSum(base.stepCount, other.stepCount)

        if base.manualTypeRaw == nil, let otherManualType = other.manualTypeRaw {
            base.manualTypeRaw = otherManualType
            base.typeRaw = otherManualType
        } else if base.manualTypeRaw == nil {
            base.typeRaw = baseDurationBeforeMerge >= otherDurationBeforeMerge ? base.typeRaw : other.typeRaw
        }

        if !other.endLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           other.endLocation != "终点",
           other.endLocation != "正在获取位置..." {
            base.endLocation = other.endLocation
        }

        let mergedPoints = decodedTransportPoints(base) + decodedTransportPoints(other)
        if let pointsData = try? JSONEncoder().encode(mergedPoints) {
            base.pointsData = pointsData
        }

        cleanupManualSelection(for: other.recordID)
        modelContext.delete(other)
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateTimelineAfterMerge(start: mergedStart, end: mergedEnd)
        Aptabase.shared.trackEvent("transport_adjacent_merged")
    }

    private func decodedTransportPoints(_ record: TransportRecord) -> [CodableCoordinate] {
        (try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData)) ?? []
    }

    private func cleanupManualSelection(for recordID: UUID) {
        let descriptor = FetchDescriptor<TransportManualSelection>(predicate: #Predicate { $0.recordID == recordID })
        for selection in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(selection)
        }
    }

    private func combinedOptionalSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func combinedOptionalSum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func toggleFavorite(for footprint: Footprint) {
        let storedFootprint = storedFootprint(matching: footprint)
        storedFootprint.isHighlight = !(storedFootprint.isHighlight ?? false)
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateAndRefreshTimeline(containing: storedFootprint.startTime)
    }

    private func deleteFootprint(_ footprint: Footprint) {
        let storedFootprint = storedFootprint(matching: footprint)
        storedFootprint.status = .ignored
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateAndRefreshTimeline(containing: storedFootprint.startTime)
    }

    private func deleteTransport(_ selected: Transport) {
        let targetId = selected.id

        let recordDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == targetId })
        if let record = try? modelContext.fetch(recordDescriptor).first {
            modelContext.delete(record)
        }

        let overrideDescriptor = FetchDescriptor<TransportManualSelection>(predicate: #Predicate { $0.recordID == targetId })
        let existingOverride = (try? modelContext.fetch(overrideDescriptor))?.first
        let deletionOverride = existingOverride ?? TransportManualSelection(
            recordID: targetId,
            startTime: selected.startTime,
            endTime: selected.endTime,
            vehicleType: selected.currentType.rawValue,
            isDeleted: true
        )

        deletionOverride.startTime = selected.startTime
        deletionOverride.endTime = selected.endTime
        deletionOverride.vehicleType = selected.currentType.rawValue
        deletionOverride.isDeleted = true
        deletionOverride.startLocationOverride = nil
        deletionOverride.endLocationOverride = nil

        if existingOverride == nil {
            modelContext.insert(deletionOverride)
        }

        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateAndRefreshTimeline(containing: selected.startTime)
    }

    private func invalidateAndRefreshTimeline(containing date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        TimelineBuilder.timelineCache.removeValue(forKey: day)
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": day]
        )
    }

    private func invalidateTimelineAfterMerge(start: Date, end: Date) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = max(start, end.addingTimeInterval(-0.001))
        let endDay = calendar.startOfDay(for: effectiveEnd)

        var cursor = startDay
        while cursor <= endDay {
            TimelineBuilder.timelineCache.removeValue(forKey: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": startDay]
        )

        if calendar.isDateInToday(start) || calendar.isDateInToday(end) {
            locationManager.triggerNotificationSummaryRefresh()
        }
    }
}

private struct ContinuousAdjacentFootprintMergeCandidate {
    let base: Footprint
    let other: Footprint

    var first: Footprint {
        base.startTime <= other.startTime ? base : other
    }

    var second: Footprint {
        base.startTime <= other.startTime ? other : base
    }
}

private struct ContinuousAdjacentTransportMergeCandidate {
    let base: TransportRecord
    let other: TransportRecord

    var first: TransportRecord {
        base.startTime <= other.startTime ? base : other
    }

    var second: TransportRecord {
        base.startTime <= other.startTime ? other : base
    }
}

private struct ContinuousTimelineDateFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Date: CGRect] = [:]

    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ContinuousTimelineScrollMetrics: Equatable {
    var topOffsetY: CGFloat = .infinity
    var contentOffsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var adjustedTopInset: CGFloat = 0
    var adjustedBottomInset: CGFloat = 0

    var bottomDistance: CGFloat {
        max(0, contentHeight + adjustedBottomInset - (contentOffsetY + viewportHeight))
    }
}

private struct ContinuousTimelineScrollAnchor {
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let adjustedBottomInset: CGFloat

    var bottomDistance: CGFloat {
        max(0, contentHeight + adjustedBottomInset - (contentOffsetY + viewportHeight))
    }
}

private struct ScrollOffsetObserver: UIViewRepresentable {
    let restorer: ContinuousTimelineScrollRestorer
    let onChange: (ContinuousTimelineScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.restorer = restorer
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(from: uiView)
        }
    }

    final class Coordinator {
        var onChange: (ContinuousTimelineScrollMetrics) -> Void
        var restorer: ContinuousTimelineScrollRestorer
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        init(onChange: @escaping (ContinuousTimelineScrollMetrics) -> Void) {
            self.onChange = onChange
            self.restorer = ContinuousTimelineScrollRestorer()
        }

        func attachIfNeeded(from view: UIView) {
            guard scrollView == nil else { return }
            guard let scrollView = view.enclosingScrollView() else { return }

            self.scrollView = scrollView
            restorer.attach(scrollView)
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.publishMetrics()
            }
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                self?.restorer.applyPendingBottomDistanceIfNeeded()
                self?.publishMetrics()
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
                self?.restorer.applyPendingBottomDistanceIfNeeded()
                self?.publishMetrics()
            }
        }

        private func publishMetrics() {
            guard let scrollView else { return }
            let metrics = ContinuousTimelineScrollMetrics(
                topOffsetY: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
                contentOffsetY: scrollView.contentOffset.y,
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                adjustedTopInset: scrollView.adjustedContentInset.top,
                adjustedBottomInset: scrollView.adjustedContentInset.bottom
            )
            if Thread.isMainThread {
                onChange(metrics)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onChange(metrics)
                }
            }
        }
    }
}

private final class ContinuousTimelineScrollRestorer {
    private weak var scrollView: UIScrollView?
    private var restoreTask: Task<Void, Never>?
    private var pendingAnchor: ContinuousTimelineScrollAnchor?
    private var pendingFallbackBottomDistance: CGFloat?
    private(set) var isRestoring = false

    var currentMetrics: ContinuousTimelineScrollMetrics? {
        guard let scrollView else { return nil }
        return ContinuousTimelineScrollMetrics(
            topOffsetY: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    var isUserInteracting: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
    }

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func captureAnchor() -> ContinuousTimelineScrollAnchor? {
        guard let scrollView else { return nil }
        return ContinuousTimelineScrollAnchor(
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    func restore(_ anchor: ContinuousTimelineScrollAnchor?, fallbackBottomDistance: CGFloat) {
        restoreTask?.cancel()
        pendingAnchor = anchor
        pendingFallbackBottomDistance = fallbackBottomDistance
        isRestoring = true
        applyPendingBottomDistanceIfNeeded()
        restoreTask = Task { @MainActor [weak self] in
            for step in 0..<18 {
                if step > 0 {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                guard !Task.isCancelled else { return }
                self?.applyPendingBottomDistanceIfNeeded()
            }
            self?.pendingAnchor = nil
            self?.pendingFallbackBottomDistance = nil
            self?.isRestoring = false
        }
    }

    func applyPendingBottomDistanceIfNeeded() {
        guard isRestoring else { return }
        if let pendingAnchor {
            apply(anchor: pendingAnchor)
        } else if let pendingFallbackBottomDistance {
            applyBottomDistance(pendingFallbackBottomDistance)
        }
    }

    func offset(by deltaY: CGFloat) {
        guard let scrollView else { return }
        applyOffsetY(scrollView.contentOffset.y + deltaY)
    }

    private func apply(anchor: ContinuousTimelineScrollAnchor) {
        guard let scrollView else { return }
        let insertedHeight = scrollView.contentSize.height - anchor.contentHeight
        applyOffsetY(anchor.contentOffsetY + insertedHeight)
    }

    private func applyBottomDistance(_ bottomDistance: CGFloat) {
        guard let scrollView else { return }
        let targetOffsetY = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height - bottomDistance
        applyOffsetY(targetOffsetY)
    }

    private func applyOffsetY(_ offsetY: CGFloat) {
        guard let scrollView else { return }

        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        )
        let clampedOffsetY = min(max(offsetY, minOffsetY), maxOffsetY)

        guard abs(scrollView.contentOffset.y - clampedOffsetY) > 0.5 else { return }
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: clampedOffsetY), animated: false)
            scrollView.layoutIfNeeded()
        }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let currentView = view {
            if let scrollView = currentView as? UIScrollView {
                return scrollView
            }
            view = currentView.superview
        }
        return nil
    }
}

private enum ContinuousTimelineLayout {
    static let timeColumnWidth: CGFloat = 48
    static let dateColumnWidth: CGFloat = 64
    static let markerSpacing: CGFloat = 12
    static let markerSize: CGFloat = 26
    static let markerCenterX = timeColumnWidth + markerSpacing + markerSize / 2
    static let minItemSpacing: CGFloat = 12
    static let maxItemSpacing: CGFloat = 160
    static let photoThumbnailSize: CGFloat = 58
    static let lineColor = Color.secondary.opacity(0.35)
}

private struct DottedTimelineSeparator: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
            }
            .stroke(
                Color.secondary.opacity(0.28),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 5])
            )
        }
        .frame(height: 1)
    }
}

private struct TimelineDateGapConnector: View {
    let skippedDays: Int

    private var height: CGFloat {
        min(120, 32 + CGFloat(skippedDays) * 14)
    }

    var body: some View {
        Path { path in
            let x = ContinuousTimelineLayout.markerCenterX
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
        }
        .stroke(
            ContinuousTimelineLayout.lineColor,
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7])
        )
        .frame(height: height)
    }
}

private struct TimelineLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: ContinuousTimelineLayout.markerSpacing) {
                Color.clear
                    .frame(width: ContinuousTimelineLayout.timeColumnWidth)

                VStack(spacing: 0) {
                    TimelineVerticalDashedLine()
                        .frame(width: 2, height: 10)

                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                            .frame(width: ContinuousTimelineLayout.markerSize, height: ContinuousTimelineLayout.markerSize)
                            .overlay(Circle().strokeBorder(ContinuousTimelineLayout.lineColor, lineWidth: 1))

                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    TimelineVerticalDashedLine()
                        .frame(width: 2, height: 10)
                }

                Text(isLoading ? "正在加载" : title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay {
                        Capsule().strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                    }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .padding(.vertical, 2)
    }
}

private struct TimelineVerticalDashedLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let x = geometry.size.width / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
            }
            .stroke(
                ContinuousTimelineLayout.lineColor,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6])
            )
        }
    }
}

private struct ContinuousTimelineRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: TimelineItem
    let nextStartTime: Date?
    let activityTypes: [ActivityType]
    let showsContinuation: Bool
    let usesMinimumBottomSpacing: Bool
    let canMergeItem: Bool
    let onTap: () -> Void
    let onMerge: () -> Void
    let onSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(item.startTime.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 4)

            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(markerIconFont)
                    .foregroundStyle(markerForeground)
                    .frame(width: markerSize, height: markerSize)
                    .background(markerBackground, in: Circle())
                    .overlay(Circle().strokeBorder(markerStroke, lineWidth: markerStrokeWidth))
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2)
                    .frame(maxHeight: showsContinuation ? .infinity : 8)
            }
            .overlay(alignment: .top) {
                if isHighlightedFootprint {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dfkHighlight)
                        .padding(3)
                        .background(Color(uiColor: .systemBackground), in: Circle())
                        .offset(y: markerSize + 2)
                }
            }
            .frame(width: ContinuousTimelineLayout.markerSize)

            HStack(alignment: .top, spacing: 12) {
                if item.isTransport {
                    Text(transportLineText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 5)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(titleFont)
                            .foregroundStyle(titleStyle)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(detailFont)
                            .foregroundStyle(detailStyle)
                        if let footprintNote {
                            Text(footprintNote)
                                .font(footprintNoteFont)
                                .foregroundStyle(detailStyle)
                                .lineLimit(5)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 0)

                if let photoAssetID {
                    ZStack(alignment: .topTrailing) {
                        ContinuousTimelinePhotoThumbnail(assetID: photoAssetID)
                            .frame(width: ContinuousTimelineLayout.photoThumbnailSize, height: ContinuousTimelineLayout.photoThumbnailSize)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )

                        if photoCount > 1 {
                            Text("\(photoCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.58), in: Capsule())
                                .padding(4)
                        }
                    }
                }
            }
            .padding(.bottom, bottomSpacing)
        }
        .frame(minHeight: 52, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if case .footprint = item {
                if canMergeItem {
                    Button {
                        onMerge()
                    } label: {
                        Label("合并相邻足迹", systemImage: "arrow.triangle.merge")
                    }
                    Divider()
                }

                Button {
                    onSplit()
                } label: {
                    Label("拆分足迹", systemImage: "slider.horizontal.below.square.filled.and.square")
                }
            } else if case .transport = item, canMergeItem {
                Button {
                    onMerge()
                } label: {
                    Label("合并相邻交通", systemImage: "arrow.triangle.merge")
                }
                Divider()
            }

            Button {
                onTap()
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            if case .footprint(let footprint) = item {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(footprint.isHighlight == true ? "取消收藏" : "收藏", systemImage: footprint.isHighlight == true ? "star.slash" : "star.fill")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var icon: String {
        item.getIcon(allActivityTypes: activityTypes)
    }

    private var tint: Color {
        switch item {
        case .footprint(let footprint):
            return footprint.getActivityType(from: activityTypes)?.color ?? .gray
        case .transport:
            return .dfkAccent
        }
    }

    private var markerForeground: Color {
        item.isTransport ? .dfkAccent : (colorScheme == .dark ? .black : .white)
    }

    private var markerBackground: Color {
        item.isTransport ? Color(uiColor: .systemBackground) : tint
    }

    private var markerStroke: Color {
        item.isTransport ? .dfkAccent : .clear
    }

    private var markerStrokeWidth: CGFloat {
        item.isTransport ? 1.2 : 0
    }

    private var markerSize: CGFloat {
        ContinuousTimelineLayout.markerSize
    }

    private var markerIconFont: Font {
        item.isTransport ? .system(size: 10, weight: .bold) : .caption.weight(.bold)
    }

    private var titleFont: Font {
        item.isTransport ? .subheadline.weight(.medium) : .body.weight(.bold)
    }

    private var detailFont: Font {
        .caption
    }

    private var footprintNoteFont: Font {
        .footnote
    }

    private var titleStyle: HierarchicalShapeStyle {
        item.isTransport ? .secondary : .primary
    }

    private var detailStyle: HierarchicalShapeStyle {
        item.isTransport ? .tertiary : .secondary
    }

    private var bottomSpacing: CGFloat {
        if usesMinimumBottomSpacing { return ContinuousTimelineLayout.minItemSpacing }

        let minutesUntilNextStart: TimeInterval
        if let nextStartTime {
            minutesUntilNextStart = max(1, nextStartTime.timeIntervalSince(item.startTime) / 60)
        } else {
            minutesUntilNextStart = max(1, item.endTime.timeIntervalSince(item.startTime) / 60)
        }

        let hoursUntilNextStart = CGFloat(minutesUntilNextStart) / 60
        let maximumScaledHours: CGFloat = 14
        let progress = min(1, hoursUntilNextStart / maximumScaledHours)
        return ContinuousTimelineLayout.minItemSpacing + (ContinuousTimelineLayout.maxItemSpacing - ContinuousTimelineLayout.minItemSpacing) * progress
    }

    private var photoAssetID: String? {
        guard case .footprint(let footprint) = item else { return nil }
        return footprint.photoAssetIDs.first
    }

    private var photoCount: Int {
        guard case .footprint(let footprint) = item else { return 0 }
        return footprint.photoAssetIDs.count
    }

    private var isHighlightedFootprint: Bool {
        guard case .footprint(let footprint) = item else { return false }
        return footprint.isHighlight == true
    }

    private var transportLineText: String {
        "\(title) · \(detail)"
    }

    private var title: String {
        switch item {
        case .footprint(let footprint):
            return footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知地点"
        case .transport(let transport):
            return transport.distance.formattedTimelineDistance
        }
    }

    private var footprintNote: String? {
        guard case .footprint(let footprint) = item else { return nil }
        return footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var detail: String {
        let duration = item.endTime.timeIntervalSince(item.startTime)
        switch item {
        case .footprint(let footprint):
            let durationText = duration.formattedTimelineDuration
            guard let activityName = footprint.getActivityType(from: activityTypes)?.name else { return durationText }
            return "\(activityName) · \(durationText)"
        case .transport:
            return duration.formattedTimelineDuration
        }
    }
}

private struct ContinuousTimelinePhotoThumbnail: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: assetID) {
            requestThumbnail()
        }
        .onDisappear {
            cancelRequest()
        }
    }

    private func requestThumbnail() {
        cancelRequest()
        image = nil

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return }

        let scale = UIScreen.main.scale
        let side = ContinuousTimelineLayout.photoThumbnailSize * scale
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let manager = PHImageManager.default()
        requestID = manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: options
        ) { thumbnail, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }

            DispatchQueue.main.async {
                self.image = thumbnail
                self.requestID = nil
            }
        }
    }

    private func cancelRequest() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            self.requestID = nil
        }
    }
}

private struct CurrentStayTimelineCard: View {
    let locationManager: LocationManager

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let timestamp = statusTimestamp {
                statusRow(startTimestamp: timestamp, now: context.date)
            }
        }
    }

    private func statusRow(startTimestamp: Date, now: Date) -> some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 4)
            VStack(spacing: 0) {
                CurrentTimelineBreathingMarker(locationManager: locationManager)
                    .frame(width: ContinuousTimelineLayout.markerSize, height: ContinuousTimelineLayout.markerSize)
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(resolvedTitle)
                    .font(.body.weight(.semibold))
                Text(detailText(for: startTimestamp, now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52, alignment: .top)
    }

    private var statusTimestamp: Date? {
        if let start = locationManager.potentialStopStartLocation {
            return start.timestamp
        }
        if locationManager.uiIsMoving {
            return locationManager.lastLocation?.timestamp ?? Date()
        }
        return nil
    }

    private var resolvedTitle: String {
        let isCurrentlyStaying = locationManager.potentialStopStartLocation != nil
        if locationManager.uiIsMoving && !isCurrentlyStaying {
            if let location = locationManager.lastLocation, location.speed > 0 {
                let speedKmh = location.speed * 3.6
                if speedKmh > 90 { return "正在高速移动" }
                if speedKmh > 30 { return "正在快速移动" }
                if speedKmh > 5 { return "正在持续移动" }
            }
            return "正在移动"
        }

        if let place = locationManager.matchedPlace, place.isUserDefined, !place.isIgnored {
            return "正在\(place.name)停留"
        }

          if hasUserDefinedPlaces,
              let title = locationManager.ongoingTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "正在\(title)停留"
        }

        let address = locationManager.currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeName = (address.isEmpty || address == "正在解析位置..." || address == "未知位置") ? "此处" : address
        return "正在\(placeName)停留"
    }

    private var hasUserDefinedPlaces: Bool {
        locationManager.allPlaces.contains { $0.isUserDefined && !$0.isIgnored }
    }

    private func detailText(for timestamp: Date, now: Date) -> String {
        if locationManager.potentialStopStartLocation != nil {
            return "已 \(now.timeIntervalSince(timestamp).formattedTimelineDuration)"
        }

        let speedKmh = max(locationManager.lastLocation?.speed ?? 0, 0) * 3.6
        return String(format: "当前速度 %.1f km/h", speedKmh)
    }
}

private struct CurrentTimelineBreathingMarker: View {
    let locationManager: LocationManager

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let duration = max(0.1, locationManager.pulseDuration)
            let progress = now.truncatingRemainder(dividingBy: duration) / duration
            let scale = 1.0 + progress * 2.5
            let opacity = (1.0 - progress) * 0.4

            ZStack {
                Circle()
                    .stroke(Color.dfkAccent.opacity(opacity), lineWidth: 3)
                    .frame(width: 8, height: 8)
                    .scaleEffect(scale)

                Circle()
                    .fill(Color.dfkAccent)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private extension View {
    @ViewBuilder
    func returnToTodayButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}

private extension TimeInterval {
    var formattedTimelineDuration: String {
        let totalMinutes = max(1, Int(self / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }
}

private extension Double {
    var formattedTimelineDistance: String {
        self >= 1_000 ? String(format: "%.1f 公里", self / 1_000) : "\(Int(self.rounded())) 米"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
