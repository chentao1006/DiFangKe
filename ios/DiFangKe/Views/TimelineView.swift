import SwiftUI
import MapKit
import SwiftData
import Photos
import UIKit
import Aptabase

/// Fits only a selected footprint into the unobscured part of the map.
/// Map points use the same Mercator projection on both axes, so fitting does
/// not depend on latitude/longitude spans having different physical scales.
enum FootprintCameraFraming {
    static func coordinates(rawPoints: [CLLocation], start: Date, end: Date,
                            fallback: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        // Adjacent timeline items share a boundary. The sample at `end`
        // belongs to the next item (often the first fix after departure),
        // not to the stay whose camera we are fitting.
        let selected = rawPoints.filter { $0.timestamp >= start && $0.timestamp < end }
            .map(\.coordinate).filter { CLLocationCoordinate2DIsValid($0) }
        return selected.isEmpty ? fallback : selected
    }

    static func mapRect(coordinates: [CLLocationCoordinate2D], viewport: CGSize, visibleRect: CGRect) -> MKMapRect? {
        let coordinates = coordinates.filter { CLLocationCoordinate2DIsValid($0) && abs($0.latitude) < 85 }
        guard !coordinates.isEmpty, viewport.width > 1, viewport.height > 1,
              visibleRect.width > 1, visibleRect.height > 1 else { return nil }

        let worldWidth = MKMapRect.world.size.width
        let originX = MKMapPoint(coordinates[0]).x
        let points = coordinates.map { coordinate -> MKMapPoint in
            var point = MKMapPoint(coordinate)
            // Keep a footprint crossing the date line local, not world-wide.
            if point.x - originX > worldWidth / 2 { point.x -= worldWidth }
            if point.x - originX < -worldWidth / 2 { point.x += worldWidth }
            return point
        }
        let center = MKMapPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                y: points.map(\.y).reduce(0, +) / Double(points.count))
        let halfWidth = points.map { abs($0.x - center.x) }.max() ?? 0
        let halfHeight = points.map { abs($0.y - center.y) }.max() ?? 0
        // A single point still needs a usable street-level view. Larger
        // footprints scale with their actual extent; there is no fixed zoom.
        let minimumExtent = 120 * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let scale = max(max(halfWidth * 2.4, minimumExtent) / visibleRect.width,
                        max(halfHeight * 2.4, minimumExtent) / visibleRect.height)
        return MKMapRect(x: center.x - visibleRect.midX * scale,
                         y: center.y - visibleRect.midY * scale,
                         width: viewport.width * scale,
                         height: viewport.height * scale)
    }
}

private struct FootprintCameraSourceKey: Hashable {
    let id: UUID
    let start: Date
    let end: Date
}

private struct ImportantPlaceDraft: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D?
    var name: String?
}

#Preview {
    MainTabView()
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
    let countryCode: String?
    let countryName: String?
    let cityName: String?
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

private struct TimelineSnapshotBatch: Sendable {
    let days: [TimelineDaySnapshot]
    let places: [PlaceLite]
}

private struct LocationSettingsAlertModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("定位权限已关闭", isPresented: $isPresented) {
            Button("前往系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("地方客无法记录足迹、停留与行程。请在系统设置中允许定位。")
        }
    }
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

/// Owns record data and map coordination. The app shell chooses where its
/// map and record surfaces are hosted; this feature does not own app navigation.
struct TimelineScene<Content: View>: View {
    var initialDate: Date?
    let isActive: Bool
    let isSideBySide: Bool
    @Binding var activeTimelineDate: Date
    @Binding var timelineDetent: PresentationDetent
    /// Owned by the app shell: its map-backed detail must not get the
    /// under-tab-bar background used for full-height sheets.
    @Binding var selectedTransport: Transport?
    @Binding var destination: TimelineDestination?
    let returnToNowRequest: Int
    let onRequestRecords: () -> Void
    @ViewBuilder let content: (AnyView, AnyView) -> Content

    nonisolated private static var initialTimelineVisibleDateBatchSize: Int { 30 }
    nonisolated private static var timelineVisibleDateBatchSize: Int { 30 }
    nonisolated private static var gapLoadDateBatchSize: Int { 30 }
    // Historical days can contain very long routes. Yield between every day
    // while materializing UI models so one "load earlier" batch never owns
    // the main actor for the whole batch.
    nonisolated private static var timelineCommitChunkSize: Int { 1 }
    nonisolated private static var timelineCoordinateConversionChunkSize: Int { 2_048 }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocationManager.self) private var locationManager
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = true
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showLocationSettingsAlert = false
    @State private var showingArrivalConfirmation = false
    @State private var loadedDates: [Date] = []
    @State private var timelinesByDate: [Date: [TimelineItem]] = [:]
    @State private var isLoadingEarlierDates = false
    @State private var todayScrollRequest = 0
    @State private var targetScrollDate: Date? = nil
    @State private var layoutViewportState = ContinuousTimelineLayoutViewportState()
    @State private var visibleTimelineItems: [TimelineItem] = []
    @State private var visibleTimelineDates = Set<Date>()
    @State private var visibleTimelineItemIDs = Set<String>()
    @State private var renderedMapItemIDs = Set<String>()
    @State private var renderedCameraItemIDs = Set<String>()
    @State private var renderedMapDetentKey: String = ""
    @State private var renderedSelectedFootprintID: UUID? = nil
    @State private var renderedMapRegion: MKCoordinateRegion?
    @State private var displayedMapRegion: MKCoordinateRegion?
    @State private var mapCameraTransitionTask: Task<Void, Never>?
    @State private var mapInteractionLockedVisibleDates: Set<Date>?
    @State private var isCalendarScrollLocked = false
    @State private var visibleMapUpdateTask: Task<Void, Never>?
    @State private var deferredVisibleTimelineDates: Set<Date>?
    @State private var deferredTimelineWorkCount = 0
    @State private var mapViewportSize: CGSize = .zero
    @State private var mapViewportRevision = 0
    @State private var didRequestInitialTimeline = false
    @State private var hasCompletedInitialTimelineLoad = false
    @State private var allowsMapInteractionCollapse = false
    @State private var timelineCache = ContinuousTimelineCache()
    @State private var availableTimelineDateSet = Set<Date>()
    @State private var hiddenTimelineDateSet = Set<Date>()
    @State private var timelineReloadTask: Task<Void, Never>?
    @State private var midnightTimelineRefreshTask: Task<Void, Never>?
    @State private var isReloadingTimelineExternally = false
    @State private var mapInteractionEnableTask: Task<Void, Never>?
    @State private var selectedFootprint: Footprint?
    @State private var selectedFootprintStartsExpanded = false
    @State private var timelineDetentBeforeFootprintDetail: PresentationDetent?
    @State private var mapTapDetentBeforeCollapse: PresentationDetent?
    @State private var loadedFootprintCameraKey: FootprintCameraSourceKey?
    @State private var loadedFootprintCameraCoordinates: [CLLocationCoordinate2D] = []
    @State private var selectedFootprintGroup: DFKMapView.AggregatedFootprint?
    @State private var selectedMapPhotoAssetID: String? = nil


    private var timelineDates: [Date] {
        var dates = Set(loadedDates)
        dates.insert(activeTimelineDate)
        return Array(dates).sorted()
    }

    private var mapTimelineItems: [TimelineItem] {
        visibleTimelineItems
    }
    
    private var mapPoints: [CLLocationCoordinate2D] {
        guard let key = footprintCameraSourceKey, loadedFootprintCameraKey == key else { return [] }
        return loadedFootprintCameraCoordinates
    }

    private var footprintCameraSourceKey: FootprintCameraSourceKey? {
        selectedFootprint.map { FootprintCameraSourceKey(id: $0.footprintID, start: $0.startTime, end: $0.endTime) }
    }

    private var selectedFootprintMapCoordinate: CLLocationCoordinate2D? {
        let points = mapPoints
        guard !points.isEmpty else { return nil }
        return CLLocationCoordinate2D(latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                                      longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
    }
    
    private var mapPrefersActivityIcons: Bool {
        false
    }
    

    // Shared by timeline framing and native user-location tracking.
    private var mediumMapVisibleVerticalRange: ClosedRange<CGFloat> { 0.075...0.435 }

    private var mapContent: some View {
        DFKMapView(
            cameraPosition: $cameraPosition,
            isInteractive: true,
            showsUserLocation: selectedFootprint == nil,
            points: mapPoints,
            timelineItems: mapTimelineItems,
            photoAssets: [],
            showsStandalonePhotos: false,
            prefersActivityIcons: mapPrefersActivityIcons,
            selectedFootprintID: selectedFootprint?.footprintID,
            selectedFootprintCoordinate: selectedFootprintMapCoordinate,
            timelineUpdateIdentifier: mapViewportRevision,
            onMapInteraction: handleMapInteraction,
            onTimelineItemTap: { item in
                onRequestRecords()
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    switch item {
                    case .footprint(let footprint):
                        if timelineDetentBeforeFootprintDetail == nil {
                            timelineDetentBeforeFootprintDetail = mapTapDetentBeforeCollapse ?? timelineDetent
                        }
                        mapTapDetentBeforeCollapse = nil
                        selectedFootprint = storedFootprint(matching: footprint)
                    case .transport(let transport):
                        mapTapDetentBeforeCollapse = nil
                        selectedTransport = transport
                    }
                }
            },
            onAggregatedFootprintTap: { aggregated in
                onRequestRecords()
                if timelineDetentBeforeFootprintDetail == nil {
                    timelineDetentBeforeFootprintDetail = mapTapDetentBeforeCollapse ?? timelineDetent
                }
                mapTapDetentBeforeCollapse = nil
                timelineDetent = .medium
                selectedFootprintGroup = aggregated
            },
            onPhotoTap: { asset in
                selectedMapPhotoAssetID = asset.localIdentifier
            },
            onUserLocationTap: focusMapOnCurrentLocation
        )
    }

    private func focusMapOnCurrentLocation() {
        guard let region = currentLocationMapRegion() else { return }
        moveMapCamera(to: region, animated: true)
    }

    private func handleMapInteraction(_ interaction: DFKMapView.MapInteractionType) {
        mapCameraTransitionTask?.cancel()
        renderedMapRegion = nil
        displayedMapRegion = nil
        guard allowsMapInteractionCollapse, isActive else { return }
        guard !isSideBySide else { return }

        if case .tap = interaction {
            mapTapDetentBeforeCollapse = timelineDetent
            Task { @MainActor in
                await Task.yield()
                guard selectedFootprint == nil, selectedFootprintGroup == nil else { return }
                mapTapDetentBeforeCollapse = nil
            }
        }

        // Annotation taps can reach this callback before or after their own
        // selection callback. Once selection won the race, do not collapse the
        // timeline underneath the detail.
        guard selectedFootprint == nil, selectedFootprintGroup == nil else { return }

        lockVisibleTimelineMapForInteraction()
        guard timelineDetent != .height(collapsedTimelineDetentHeight) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            timelineDetent = .height(collapsedTimelineDetentHeight)
        }
    }

    @ViewBuilder
    private var timelineNavigationContent: some View {
        TimelineView(
            dates: timelineDates,
            timelinesByDate: timelinesByDate,
            initialTimelineLoadCompleted: hasCompletedInitialTimelineLoad,
            layoutViewportState: layoutViewportState,
            isReloadingTimelineExternally: isReloadingTimelineExternally,
            locationManager: locationManager,
            activeTimelineDate: $activeTimelineDate,
            todayScrollRequest: $todayScrollRequest,
            returnToNowRequest: returnToNowRequest,
            targetScrollDate: $targetScrollDate,
            timelineDetent: $timelineDetent,
            isCalendarScrollLocked: $isCalendarScrollLocked,
            isSideBySide: isSideBySide,
            selectedFootprint: $selectedFootprint,
            selectedFootprintStartsExpanded: $selectedFootprintStartsExpanded,
            selectedTransport: $selectedTransport,
            selectedFootprintGroup: $selectedFootprintGroup,
            onFootprintGroupCancelled: restoreTimelineDetentAfterFootprintDetail,
            loadEarlierDates: loadEarlierTimeline,
            loadLaterDates: loadLaterTimeline,
            loadLaterDatesAfter: { date in await loadLaterTimeline(from: date) },
            loadGapDates: loadTimelineGapDates,
            loadDate: { date, allowEmpty in await loadTimelineDate(date, allowEmpty: allowEmpty) },
            gapLoadBatchSize: Self.gapLoadDateBatchSize,
            availableDates: loadableTimelineDateSet,
            visibleDatesChanged: updateVisibleTimelineDates,
            visibleItemIDsChanged: updateVisibleTimelineItemIDs,
            isActive: isActive,
            selectedMapPhotoAssetID: $selectedMapPhotoAssetID
        )
        // The same native sheet hosts navigation on both iPhone and iPad.
        // It is therefore the common presenter for a persisted denied location
        // permission on every layout.
        .modifier(LocationSettingsAlertModifier(isPresented: $showLocationSettingsAlert))
        .onAppear(perform: handleTimelinePermissionPresenterAppear)
    }

    @ViewBuilder
    private var timelineMainContent: some View {
        GeometryReader { geometry in
            mapContent
            .onAppear {
                updateMapViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateMapViewportSize(newSize)
            }
        }
        .ignoresSafeArea(edges: isSideBySide ? [.top, .bottom, .trailing] : .all)
    }

    var body: some View {
        content(AnyView(timelineMainContent), AnyView(timelineNavigationContent))
        .onChange(of: destination?.id) { _, _ in consumeDestination() }
        .onChange(of: returnToNowRequest) { _, _ in returnToNow() }
        .onChange(of: hasCompletedInitialTimelineLoad) { _, ready in
            if ready { consumeDestination() }
        }
        .onAppear {
            handleTimelineAppear()
            consumeDestination()
        }
        .onDisappear(perform: handleTimelineDisappear)
        .task { await loadInitialTimeline() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged")), perform: handleFootprintDataChanged)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DFKDeepLinkNotification"))) { notification in
            handleDeepLink(userInfo: notification.userInfo)
        }
        .onChange(of: selectedFootprint?.footprintID) { _, _ in
            handleSelectedFootprintChange(selectedFootprint)
        }
        .task(id: footprintCameraSourceKey) {
            await loadSelectedFootprintCameraCoordinates()
        }
        .onChange(of: allPlaces) { _, newValue in
            locationManager.allPlaces = newValue
            locationManager.forceRefreshOngoingAnalysis()
        }
        .onChange(of: timelineDetent) { oldValue, newValue in
            handleTimelineDetentChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: isCalendarScrollLocked) { _, isLocked in
            if isLocked {
                visibleMapUpdateTask?.cancel()
                if selectedFootprint == nil {
                    mapCameraTransitionTask?.cancel()
                    if let displayedMapRegion {
                        renderedMapRegion = displayedMapRegion
                    }
                }
                return
            }
            // An explicit date jump has already finished positioning the
            // timeline. Start its camera animation in the same run-loop turn;
            // manual scrolling still uses the geometry coalescer below.
            refreshVisibleTimelineMap(for: visibleTimelineDates, delayNanoseconds: 0)
        }
        .onChange(of: cameraPosition.followsUserLocation) { _, isFollowing in
            guard isFollowing else { return }
            // A pending timeline fit must not overwrite an explicit locate request.
            visibleMapUpdateTask?.cancel()
            mapCameraTransitionTask?.cancel()
            if !isSideBySide, timelineDetent == .medium {
                focusMapOnCurrentLocation()
            } else {
                renderedMapRegion = nil
                displayedMapRegion = nil
            }
        }
        .onChange(of: locationManager.lastLocation?.timestamp) { _, _ in
            guard visibleTimelineItems.isEmpty else { return }
            refreshVisibleTimelineMap(delayNanoseconds: 0)
        }
        .onChange(of: locationManager.authStatus) { _, _ in
            scheduleLocationSettingsAlertIfNeeded()
        }
        .onChange(of: isTrackingEnabled) { _, _ in
            scheduleLocationSettingsAlertIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            locationManager.refreshAuthorizationStatus()
            scheduleLocationSettingsAlertIfNeeded()
            Task { await refreshTimelineForCurrentDayIfNeeded() }
        }
        .onOpenURL(perform: handleDeepLinkURL)
        .alert("确认已到达？", isPresented: $showingArrivalConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认到达") {
                Task { await locationManager.confirmArrival() }
            }
        } message: {
            Text("将结束当前移动，并开始记录停留。")
        }
    }

    private func consumeDestination() {
        guard hasCompletedInitialTimelineLoad, let requested = destination else { return }
        destination = nil
        openDate(requested.date, footprintID: requested.footprintID)
    }

    private func returnToNow() {
        selectedFootprint = nil
        selectedFootprintGroup = nil
        selectedTransport = nil
        targetScrollDate = nil
    }

    private func handleDeepLinkURL(_ url: URL) {
        guard url.scheme == "difangke" else { return }
        onRequestRecords()

        if url.host == "timeline" {
            openTimelineDeepLink(url)
        } else if url.host == "current" {
            handleCurrentActivityDeepLink(url)
        }
    }

    private func handleCurrentActivityDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value else { return }

        let kind = components.queryItems?.first(where: { $0.name == "kind" })?.value
        if url.path == "/detail",
           kind == CurrentTrackingActivityKind.transport.rawValue
            || kind == CurrentTrackingActivityKind.footprint.rawValue,
           let timelineURL = URL(string: "difangke://timeline?offset=0") {
            openTimelineDeepLink(timelineURL)
            return
        }

        guard let id = UUID(uuidString: idString) else { return }

        if url.path == "/action",
           components.queryItems?.first(where: { $0.name == "type" })?.value == "arrive" {
            let recentThreshold = Date().addingTimeInterval(-AppConfig.shared.currentTransportLookback)
            let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                $0.recordID == id && $0.statusRaw == "active" && $0.endTime >= recentThreshold
            })
            guard (try? modelContext.fetch(descriptor).first) != nil else { return }
            showingArrivalConfirmation = true
            return
        }

    }

    private func handleTimelineAppear() {
        setupLocationManager()
        enableMapInteractionCollapseAfterInitialLayout()
        scheduleMidnightTimelineRefresh()
        Task { await refreshAvailableTimelineDateCache() }
    }

    private func handleTimelinePermissionPresenterAppear() {
        locationManager.refreshAuthorizationStatus()
        scheduleLocationSettingsAlertIfNeeded()
    }

    private func handleTimelineDisappear() {
        midnightTimelineRefreshTask?.cancel()
        timelineReloadTask?.cancel()
        visibleMapUpdateTask?.cancel()
        mapCameraTransitionTask?.cancel()
        mapInteractionEnableTask?.cancel()
    }

    private func handleFootprintDataChanged(_: Notification) {
        // CloudKit imports and one logical timeline save can emit a burst of
        // store-change notifications. Reloading all mounted days and the map
        // for every event causes visible stalls and sustained CPU/GPU work.
        timelineReloadTask?.cancel()
        timelineReloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            reloadLoadedTimeline()
            _ = await refreshAvailableTimelineDateCache()
        }
    }

    private func scheduleLocationSettingsAlertIfNeeded() {
        guard isTrackingEnabled else {
            showLocationSettingsAlert = false
            return
        }
        let status = locationManager.authStatus
        guard status == .denied || status == .restricted else {
            showLocationSettingsAlert = false
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard isTrackingEnabled else { return }
            let currentStatus = locationManager.authStatus
            guard currentStatus == .denied || currentStatus == .restricted else { return }
            showLocationSettingsAlert = true
        }
    }

    private func openTimelineDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let offsetString = components.queryItems?.first(where: { $0.name == "offset" })?.value,
              let offset = Int(offsetString),
              let targetDate = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) else {
            return
        }
        let scrollsToNow = offset == 0
            && components.queryItems?.first(where: { $0.name == "anchor" })?.value == "now"

        Task { @MainActor in
            timelineDetent = .medium
            activeTimelineDate = targetDate
            updateVisibleTimelineDates([targetDate])

            guard hasCompletedInitialTimelineLoad else { return }
            _ = await refreshAvailableTimelineDateCache()
            _ = await loadTimelineDate(targetDate)
            targetScrollDate = scrollsToNow ? nil : targetDate
            todayScrollRequest += 1
        }
    }

    private func scheduleMidnightTimelineRefresh() {
        midnightTimelineRefreshTask?.cancel()
        let calendar = Calendar.current
        guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) else { return }

        midnightTimelineRefreshTask = Task { @MainActor in
            let delay = max(1, nextMidnight.timeIntervalSinceNow + 0.5)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await refreshTimelineForCurrentDayIfNeeded()
            scheduleMidnightTimelineRefresh()
        }
    }

    private func refreshTimelineForCurrentDayIfNeeded() async {
        let today = Calendar.current.startOfDay(for: Date())
        guard !Calendar.current.isDate(activeTimelineDate, inSameDayAs: today) else { return }

        // Fetch latest data silently without disrupting the user's current view
        _ = await refreshAvailableTimelineDateCache()
        _ = await loadTimelineDate(today)
    }

    private func updateMapViewportSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(mapViewportSize.width - size.width) > 0.5 || abs(mapViewportSize.height - size.height) > 0.5 else { return }
        mapViewportSize = size
        if let footprint = selectedFootprint {
            focusMap(on: footprint, animated: false)
            // Match the timeline path below: MapKit otherwise preserves the
            // old screen-space visible rect when the split-view detail column
            // changes width, leaving a correctly fitted footprint visibly
            // offset toward the former viewport.
            mapViewportRevision &+= 1
        } else if isSideBySide, let region = displayedMapRegion ?? renderedMapRegion {
            // NavigationSplitView can preserve MapKit's old screen-space visible
            // rect when its detail column changes width. Recreate the Map surface
            // with the same geographic region so that region is centered in the
            // new detail viewport rather than the previous column frame.
            mapCameraTransitionTask?.cancel()
            displayedMapRegion = region
            renderedMapRegion = region
            cameraPosition = .region(region)
            mapViewportRevision &+= 1
        }
    }

    private func handleSelectedFootprintChange(_ newFootprint: Footprint?) {
        guard let footprint = newFootprint else {
            selectedFootprintStartsExpanded = false
            visibleMapUpdateTask?.cancel()
            renderedSelectedFootprintID = nil
            restoreTimelineDetentAfterFootprintDetail()
            return
        }

        // Selection takes ownership from any pending timeline camera update.
        // Present the detail over the medium timeline, then restore the exact
        // height the user had before opening it when the detail closes.
        visibleMapUpdateTask?.cancel()
        if timelineDetentBeforeFootprintDetail == nil {
            timelineDetentBeforeFootprintDetail = timelineDetent
        }
        timelineDetent = .medium
        focusMap(on: footprint)
    }

    private func restoreTimelineDetentAfterFootprintDetail() {
        guard let previousDetent = timelineDetentBeforeFootprintDetail else { return }
        timelineDetentBeforeFootprintDetail = nil
        timelineDetent = previousDetent
    }

    private func loadSelectedFootprintCameraCoordinates() async {
        guard let footprint = selectedFootprint, let key = footprintCameraSourceKey else {
            loadedFootprintCameraKey = nil
            loadedFootprintCameraCoordinates = []
            return
        }
        let fallback = footprint.coordinates.isEmpty
            ? [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
            : footprint.coordinates
        let coordinates = await Task.detached(priority: .userInitiated) {
            let calendar = Calendar.current
            var day = calendar.startOfDay(for: key.start)
            let lastDay = calendar.startOfDay(for: max(key.start, key.end))
            var rawPoints: [CLLocation] = []
            while day <= lastDay {
                rawPoints.append(contentsOf: RawLocationStore.shared.loadAllDevicesLocations(for: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
            return FootprintCameraFraming.coordinates(rawPoints: rawPoints, start: key.start, end: key.end,
                                                     fallback: fallback)
        }.value
        guard !Task.isCancelled, footprintCameraSourceKey == key else { return }
        loadedFootprintCameraCoordinates = coordinates
        loadedFootprintCameraKey = key
        focusMap(on: footprint)
    }

    private func focusMap(on footprint: Footprint, animated: Bool = true) {
        let key = FootprintCameraSourceKey(id: footprint.footprintID, start: footprint.startTime, end: footprint.endTime)
        guard loadedFootprintCameraKey == key else { return }
        let coordinates = loadedFootprintCameraCoordinates
        // Wait for real geometry instead of fitting with a guessed aspect ratio.
        guard mapViewportSize.width > 1, mapViewportSize.height > 1 else { return }
        let visibleRect = CGRect(
            x: mapViewportSize.width * 0.08,
            y: mapViewportSize.height * 0.10,
            width: mapViewportSize.width * 0.84,
            height: mapViewportSize.height * 0.80
        )
        guard let rect = FootprintCameraFraming.mapRect(
            coordinates: coordinates, viewport: mapViewportSize, visibleRect: visibleRect
        ) else { return }
        let baseRegion = MKCoordinateRegion(rect)
        let targetRegion = adjustedMapRegion(baseRegion)
        renderedSelectedFootprintID = footprint.footprintID
        renderedMapRegion = targetRegion
        displayedMapRegion = targetRegion
        // Commit the destination once and let MapKit animate the camera.
        withAnimation(animated ? .easeInOut(duration: 0.35) : nil) {
            cameraPosition = .region(targetRegion)
        }
    }

    private func storedFootprint(matching footprint: Footprint) -> Footprint {
        let footprintID = footprint.footprintID
        let fetchDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == footprintID })
        if let stored = try? modelContext.fetch(fetchDescriptor).first {
            return stored
        }
        return footprint
    }

    private func handleTimelineDetentChange(oldValue: PresentationDetent, newValue: PresentationDetent) {
        visibleMapUpdateTask?.cancel()
        renderedMapDetentKey = currentMapDetentKey
        let collapsedDetent = PresentationDetent.height(collapsedTimelineDetentHeight)

        if oldValue == collapsedDetent, newValue == .medium {
            mapInteractionLockedVisibleDates = nil
            if let source = displayedMapRegion ?? renderedMapRegion {
                animateMapCameraForDetent(to: mediumDetentMapRegion(fitting: source))
            }
            return
        }
        if oldValue == .medium, newValue == collapsedDetent {
            lockVisibleTimelineMapForInteraction()
            if let source = displayedMapRegion ?? renderedMapRegion {
                animateMapCameraForDetent(to: collapsedMapRegion(fromMediumCamera: source))
            }
            return
        }

        if oldValue == collapsedDetent { mapInteractionLockedVisibleDates = nil }
        if newValue == collapsedDetent { lockVisibleTimelineMapForInteraction() }
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
        mapInteractionEnableTask?.cancel()
        mapInteractionEnableTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            allowsMapInteractionCollapse = true
        }
    }

    private func loadInitialTimeline() async {
        guard !didRequestInitialTimeline else { return }
        didRequestInitialTimeline = true

        let calendar = Calendar.current
        var targetDate = calendar.startOfDay(for: initialDate ?? activeTimelineDate)
        activeTimelineDate = targetDate
        updateVisibleTimelineDates([targetDate])

        let availableDates = await refreshAvailableTimelineDateCache()
        // A widget URL can arrive while the availability query is in flight.
        // Honor that selected day rather than resetting the initial timeline to today.
        if initialDate == nil {
            let requestedDate = calendar.startOfDay(for: activeTimelineDate)
            if requestedDate != targetDate {
                targetDate = requestedDate
                updateVisibleTimelineDates([targetDate])
            }
        }

        var initialDates = availableDates
            .filter { $0 <= targetDate }
        if !initialDates.contains(targetDate) {
            initialDates.append(targetDate)
        }
        initialDates = Array(initialDates.sorted().suffix(Self.initialTimelineVisibleDateBatchSize))

        _ = await loadVisibleTimelineDates(initialDates.reversed(), visibleDateLimit: initialDates.count, defersMapUpdates: false, reloadLoadedDates: true)
        guard !Task.isCancelled else { return }
        hasCompletedInitialTimelineLoad = true

        refreshVisibleTimelineMap(for: [targetDate], delayNanoseconds: 120_000_000)
        
        handleColdLaunchDeepLink()
        NotificationCenter.default.post(name: NSNotification.Name("TimelineInitialLoadCompleted"), object: nil)
    }

    private func handleDeepLink(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              userInfo["type"] as? String == "highlight_footprint",
              let date = userInfo["date"] as? Date else { return }
        openDate(date, footprintID: userInfo["footprintID"] as? UUID)
    }

    /// Shared by parent navigation and notification deep links.
    private func openDate(_ date: Date, footprintID: UUID?) {
        onRequestRecords()
        let dayStart = Calendar.current.startOfDay(for: date)
        if locationManager.deepLinkDate == dayStart {
            locationManager.deepLinkDate = nil
            locationManager.deepLinkFootprintID = nil
        }

        Task { @MainActor in
            activeTimelineDate = dayStart
            updateVisibleTimelineDates([dayStart])
            _ = await refreshAvailableTimelineDateCache()
            _ = await loadTimelineDate(dayStart)
            targetScrollDate = dayStart
            todayScrollRequest += 1

            if let footprintID {
                let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == footprintID })
                if let fetched = try? modelContext.fetch(descriptor).first {
                    selectedFootprint = fetched
                }
            }
        }
    }

    private func handleColdLaunchDeepLink() {
        if let date = locationManager.deepLinkDate {
            locationManager.deepLinkDate = nil
            let footprintID = locationManager.deepLinkFootprintID
            locationManager.deepLinkFootprintID = nil
            
            Task {
                let dayStart = Calendar.current.startOfDay(for: date)
                activeTimelineDate = dayStart
                updateVisibleTimelineDates([dayStart])
                _ = await refreshAvailableTimelineDateCache()
                _ = await loadTimelineDate(dayStart)
                // A cold-launch notification reaches this path after the initial
                // timeline load. Preserve its historic day for the pending scroll.
                targetScrollDate = dayStart
                todayScrollRequest += 1
                
                if let fid = footprintID {
                    let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == fid })
                    if let fetched = try? modelContext.fetch(descriptor).first {
                        selectedFootprint = fetched
                    }
                }
            }
        }
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

    private func loadTimelineDate(_ date: Date, allowEmpty: Bool = false) async -> Bool {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        if let items = timelinesByDate[normalizedDate] {
            guard shouldDisplayTimelineDate(normalizedDate, items: items, allowEmpty: allowEmpty) else { return false }
            if !loadedDates.contains(normalizedDate) {
                loadedDates = Set(loadedDates).union([normalizedDate]).sorted()
            }
            hiddenTimelineDateSet.remove(normalizedDate)
            return true
        }
        if let cachedItems = timelineCache.cachedTimeline(for: normalizedDate) {
            guard shouldDisplayTimelineDate(normalizedDate, items: cachedItems, allowEmpty: allowEmpty) else { return false }
            timelinesByDate[normalizedDate] = cachedItems
            loadedDates = Set(loadedDates).union([normalizedDate]).sorted()
            hiddenTimelineDateSet.remove(normalizedDate)
            return true
        }
        if !allowEmpty, timelineCache.isHidden(normalizedDate) {
            return false
        }

        let availableDates = await availableTimelineDatesForLookup()
        guard availableDates.contains(normalizedDate) || calendar.isDateInToday(normalizedDate) || allowEmpty else { return false }

        return await loadVisibleTimelineDates([normalizedDate], visibleDateLimit: 1, defersMapUpdates: true, reloadLoadedDates: true, allowEmpty: allowEmpty)
    }

    private func loadTimelineGapDates(_ dates: [Date]) async -> Bool {
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

            let items = await Self.timelineItems(from: daySnapshot, allPlaces: snapshot.places)
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

    nonisolated private static func fetchTimelineSnapshots(for dates: [Date], in container: ModelContainer) -> TimelineSnapshotBatch {
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
            let footprints = ((try? context.fetch(fpDescriptor)) ?? [])
                .map { footprint in
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
                    countryCode: footprint.countryCode,
                    countryName: footprint.countryName,
                    cityName: footprint.cityName,
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
            let transports = ((try? context.fetch(tpDescriptor)) ?? [])
                .map { transport in
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

        return TimelineSnapshotBatch(days: days, places: places)
    }

    @MainActor
    private static func timelineItems(from snapshot: TimelineDaySnapshot, allPlaces: [PlaceLite]) async -> [TimelineItem] {
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
            model.countryCode = footprint.countryCode
            model.countryName = footprint.countryName
            model.cityName = footprint.cityName
            items.append(.footprint(model))
        }

        for transport in snapshot.transports {
            var pathPoints: [TransportPathPoint] = []
            pathPoints.reserveCapacity(transport.points.count)
            for (index, point) in transport.points.enumerated() {
                pathPoints.append(TransportPathPoint(
                    coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                    timestamp: point.timestamp,
                    isSyntheticPadding: point.isSyntheticPadding ?? false
                ))
                if index > 0, index % Self.timelineCoordinateConversionChunkSize == 0 {
                    await Task.yield()
                }
            }
            var coordinates: [CLLocationCoordinate2D] = []
            coordinates.reserveCapacity(pathPoints.count)
            for (index, point) in pathPoints.enumerated() {
                coordinates.append(point.coordinate)
                if index > 0, index % Self.timelineCoordinateConversionChunkSize == 0 {
                    await Task.yield()
                }
            }
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

    private func loadVisibleTimelineDates<S: Sequence>(_ candidateDates: S, visibleDateLimit: Int, defersMapUpdates: Bool, reloadLoadedDates: Bool = false, allowEmpty: Bool = false) async -> Bool where S.Element == Date {
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

        if let today = datesToLoad.first(where: { calendar.isDateInToday($0) }) {
            _ = PersistentTimelineBuilder.fetchTimeline(for: today, in: modelContext)
        }
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

            let items = await Self.timelineItems(from: daySnapshot, allPlaces: snapshot.places)
            fetchedTimelines[daySnapshot.date] = items

            if shouldDisplayTimelineDate(daySnapshot.date, items: items, allowEmpty: allowEmpty) {
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

        let changedDates = Set(fetchedTimelines.keys).union(visibleDates).union(hiddenDates)
        guard !changedDates.isDisjoint(with: visibleTimelineDates) else { return }
        if deferredTimelineWorkCount > 0 {
            deferredVisibleTimelineDates = visibleTimelineDates
        } else {
            refreshVisibleTimelineMap(for: visibleTimelineDates, delayNanoseconds: 0)
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

    private func shouldDisplayTimelineDate(_ date: Date, items: [TimelineItem], allowEmpty: Bool = false) -> Bool {
        if !items.isEmpty { return true }
        if allowEmpty { return true }
        return Calendar.current.isDateInToday(date)
    }

    private func reloadLoadedTimeline() {
        let datesToReload = Array(Set(timelinesByDate.keys).union(visibleTimelineDates)).sorted()
        guard !datesToReload.isEmpty else { return }
        timelineCache.invalidate(datesToReload)
        // Reloading can reshuffle every loaded date section's content/height (e.g. a burst of
        // CloudKit changes arriving after the app returns from background). Signal the sheet so
        // it can freeze viewport-driven date tracking while that happens, otherwise transient
        // scroll geometry gets misread as the user having scrolled to an old date.
        isReloadingTimelineExternally = true
        Task(priority: .utility) { @MainActor in
            _ = await loadTimelineIncrementally(for: datesToReload, batchSize: 1, defersMapUpdates: true)
            isReloadingTimelineExternally = false
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
        guard mapInteractionLockedVisibleDates == nil || isSideBySide else {
            mapInteractionLockedVisibleDates = dates
            resetLockedMapCamera(animated: true)
            return
        }
        if deferredTimelineWorkCount > 0 {
            deferredVisibleTimelineDates = dates
            return
        }
        refreshVisibleTimelineMap(for: dates, delayNanoseconds: 80_000_000)
    }

    private func updateVisibleTimelineItemIDs(_ ids: Set<String>) {
        guard ids != visibleTimelineItemIDs else { return }
        visibleTimelineItemIDs = ids
        refreshVisibleTimelineMap(for: visibleTimelineDates, delayNanoseconds: 80_000_000)
    }

    /// Narrows a day's full item list down to whichever of those items are
    /// currently scrolled into view in the timeline, so the map camera and
    /// annotations track the visible viewport rather than the whole day.
    /// Falls back to the unfiltered list when nothing overlaps yet (e.g. right
    /// after a day loads, before its rows have published frames).
    private func filteredForVisibleItems(_ items: [TimelineItem]) -> [TimelineItem] {
        // A collapsed card has no visible rows. Fit the entire selected day,
        // rather than retaining the last expanded viewport's subset.
        guard isSideBySide || timelineDetent != .height(collapsedTimelineDetentHeight) else { return items }
        guard !visibleTimelineItemIDs.isEmpty else { return items }
        let filtered = items.filter { visibleTimelineItemIDs.contains($0.id) }
        return filtered.isEmpty ? items : filtered
    }

    private func lockVisibleTimelineMapForInteraction() {
        let lockedDates = visibleTimelineDates.isEmpty ? [activeTimelineDate] : visibleTimelineDates
        mapInteractionLockedVisibleDates = lockedDates
        visibleMapUpdateTask?.cancel()
    }

    private func resetLockedMapCamera(animated: Bool) {
        if let footprint = selectedFootprint {
            focusMap(on: footprint, animated: animated)
            return
        }
        let lockedDates = mapInteractionLockedVisibleDates ?? (visibleTimelineDates.isEmpty ? [activeTimelineDate] : visibleTimelineDates)
        let items = timelineItemsForVisibleDates(visibleDates: lockedDates)
        let cameraItems = filteredForVisibleItems(items)

        visibleTimelineItems = items

        renderedMapItemIDs = mapContentIDs(for: items)
        renderedCameraItemIDs = mapContentIDs(for: cameraItems)
        renderedMapDetentKey = currentMapDetentKey
        renderedSelectedFootprintID = selectedFootprint?.footprintID

        let region: MKCoordinateRegion?
        if items.isEmpty {
            region = currentLocationMapRegion()
        } else {
            region = adjustedMapRegion(for: mapCameraCoordinates(for: cameraItems))
        }

        guard let region else {
            renderedMapRegion = nil
            return
        }

        moveMapCamera(to: region, animated: animated)
    }

    private func unlockVisibleTimelineMapAfterInteraction() {
        guard mapInteractionLockedVisibleDates != nil else {
            refreshVisibleTimelineMap()
            return
        }
        mapInteractionLockedVisibleDates = nil
        refreshVisibleTimelineMap(delayNanoseconds: 120_000_000)
    }

    private func refreshVisibleTimelineMap(for visibleDates: Set<Date>? = nil, delayNanoseconds: UInt64 = 360_000_000) {
        guard isSideBySide || mapInteractionLockedVisibleDates == nil else { return }
        // A first long-distance calendar jump can otherwise start a large,
        // multi-step camera flight at the same time as ScrollViewReader is
        // resolving a newly inserted lazy row. Defer that map work until the
        // explicit timeline scroll has settled; the final refresh below still
        // renders the selected day's markers and transport lines.
        guard !isCalendarScrollLocked else { return }
        let targetVisibleDates = visibleDates
        visibleMapUpdateTask?.cancel()
        visibleMapUpdateTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, !isCalendarScrollLocked else { return }

            let mapDates = targetVisibleDates ?? ((isSideBySide || timelineDetent == .large) ? visibleTimelineDates : (mapInteractionLockedVisibleDates ?? visibleTimelineDates))
            let items = timelineItemsForVisibleDates(visibleDates: mapDates)
            let cameraItems = filteredForVisibleItems(items)

            // A detail selection owns the camera. Today is continually
            // reloaded as new raw locations arrive; those reloads still need
            // to update routes and markers, but must never replace the
            // selected footprint's camera with the day's transport bounds.
            if selectedFootprint != nil {
                visibleTimelineItems = items
                renderedMapItemIDs = mapContentIDs(for: items)
                renderedCameraItemIDs = mapContentIDs(for: cameraItems)
                renderedMapDetentKey = currentMapDetentKey
                renderedSelectedFootprintID = selectedFootprint?.footprintID
                return
            }
            guard !items.isEmpty else {
                visibleTimelineItems = []
                renderedMapItemIDs = []
                renderedCameraItemIDs = []
                renderedMapDetentKey = currentMapDetentKey
                renderedSelectedFootprintID = selectedFootprint?.footprintID

                let region = currentLocationMapRegion()
                if let region {
                    if shouldUpdateMapRegion(to: region) {
                        moveMapCamera(to: region, animated: true)
                    }
                } else {
                    renderedMapRegion = nil
                }
                return
            }

            let mapItemIDs = mapContentIDs(for: items)
            let cameraItemIDs = mapContentIDs(for: cameraItems)
            let detentKey = currentMapDetentKey
            let selectedFootprintID = selectedFootprint?.footprintID
            let mapStateChanged = mapItemIDs != renderedMapItemIDs || detentKey != renderedMapDetentKey || selectedFootprintID != renderedSelectedFootprintID
            let cameraStateChanged = cameraItemIDs != renderedCameraItemIDs || detentKey != renderedMapDetentKey || selectedFootprintID != renderedSelectedFootprintID
            renderedMapItemIDs = mapItemIDs
            renderedCameraItemIDs = cameraItemIDs
            renderedMapDetentKey = detentKey
            renderedSelectedFootprintID = selectedFootprintID

            visibleTimelineItems = items
            guard mapStateChanged || cameraStateChanged else { return }

            let coordinates = mapCameraCoordinates(for: cameraItems)

            if let region = adjustedMapRegion(for: coordinates), shouldUpdateMapRegion(to: region) {
                moveMapCamera(to: region, animated: true)
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

    private func mapContentIDs(for items: [TimelineItem]) -> Set<String> {
        Set(items.map(\.id))
    }

    private func shouldUpdateMapRegion(to newRegion: MKCoordinateRegion) -> Bool {
        guard isRenderableMapRegion(newRegion) else { return false }
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

    private func isMinorCameraAdjustment(from source: MKCoordinateRegion, to target: MKCoordinateRegion) -> Bool {
        let referenceLatitudeSpan = max(source.span.latitudeDelta, target.span.latitudeDelta, 0.0001)
        let referenceLongitudeSpan = max(source.span.longitudeDelta, target.span.longitudeDelta, 0.0001)

        let centerLatitudeDelta = abs(source.center.latitude - target.center.latitude)
        let centerLongitudeDelta = abs(shortestLongitudeDelta(from: source.center.longitude, to: target.center.longitude))
        let latitudeSpanDelta = abs(source.span.latitudeDelta - target.span.latitudeDelta)
        let longitudeSpanDelta = abs(source.span.longitudeDelta - target.span.longitudeDelta)

        return centerLatitudeDelta <= referenceLatitudeSpan * 0.6 &&
            centerLongitudeDelta <= referenceLongitudeSpan * 0.6 &&
            latitudeSpanDelta <= referenceLatitudeSpan * 0.6 &&
            longitudeSpanDelta <= referenceLongitudeSpan * 0.6
    }

    private func moveMapCamera(to target: MKCoordinateRegion, animated: Bool) {
        guard isRenderableMapRegion(target) else { return }
        mapCameraTransitionTask?.cancel()
        let source = displayedMapRegion ?? renderedMapRegion
        renderedMapRegion = target

        guard animated, let source else {
            displayedMapRegion = target
            if animated {
                withAnimation(.easeInOut(duration: 0.5)) {
                    cameraPosition = .region(target)
                }
            } else {
                cameraPosition = .region(target)
            }
            return
        }

        guard !isMinorCameraAdjustment(from: source, to: target) else {
            displayedMapRegion = target
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(target)
            }
            return
        }

        let latitudeDistance = abs(target.center.latitude - source.center.latitude)
        let longitudeDistance = abs(shortestLongitudeDelta(from: source.center.longitude, to: target.center.longitude))
        let distance = hypot(latitudeDistance, longitudeDistance)
        let stepCount = min(36, max(12, Int(distance * 0.8) + 12))

        mapCameraTransitionTask = Task { @MainActor in
            for step in 1...stepCount {
                guard !Task.isCancelled else { return }
                let progress = Double(step) / Double(stepCount)
                let easedProgress = progress * progress * (3 - 2 * progress)
                let region = interpolatedMapRegion(from: source, to: target, progress: easedProgress)
                displayedMapRegion = region
                withAnimation(.linear(duration: 0.03)) {
                    cameraPosition = .region(region)
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// A sheet detent transition changes which vertical portion of the same
    /// full-screen map is visible. Submit one camera animation alongside the
    /// sheet animation; never resize or inset the Map itself.
    private func animateMapCameraForDetent(to target: MKCoordinateRegion) {
        guard isRenderableMapRegion(target) else { return }
        mapCameraTransitionTask?.cancel()
        renderedMapRegion = target
        displayedMapRegion = target
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(target)
        }
    }

    private func interpolatedMapRegion(from source: MKCoordinateRegion, to target: MKCoordinateRegion, progress: Double) -> MKCoordinateRegion {
        let longitudeDelta = shortestLongitudeDelta(from: source.center.longitude, to: target.center.longitude)
        let longitude = normalizedLongitude(source.center.longitude + longitudeDelta * progress)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: source.center.latitude + (target.center.latitude - source.center.latitude) * progress,
                longitude: longitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: source.span.latitudeDelta + (target.span.latitudeDelta - source.span.latitudeDelta) * progress,
                longitudeDelta: source.span.longitudeDelta + (target.span.longitudeDelta - source.span.longitudeDelta) * progress
            )
        )
    }

    private func shortestLongitudeDelta(from source: CLLocationDegrees, to target: CLLocationDegrees) -> CLLocationDegrees {
        let delta = target - source
        if delta > 180 { return delta - 360 }
        if delta < -180 { return delta + 360 }
        return delta
    }

    private func normalizedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
        ((longitude + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
    }

    private func isRenderableMapRegion(_ region: MKCoordinateRegion) -> Bool {
        guard region.center.isRenderableMapCoordinate else { return false }
        guard region.span.latitudeDelta.isFinite,
              region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0,
              region.span.longitudeDelta > 0 else { return false }
        return region.span.latitudeDelta <= 180 && region.span.longitudeDelta <= 360
    }

    private func mapCameraCoordinates(for items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        let itemCoordinates: [CLLocationCoordinate2D]
        if !isSideBySide && timelineDetent == .medium {
            itemCoordinates = mediumDetentAnnotationCoordinates(for: items)
        } else {
            itemCoordinates = items.flatMap { item -> [CLLocationCoordinate2D] in
                switch item {
                case .footprint(let footprint):
                    return [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
                case .transport(let transport):
                    if !isSideBySide && timelineDetent == .height(collapsedTimelineDetentHeight) {
                        return transport.points
                    }
                    return sampledCoordinates(from: transport.points, maximumCount: 24)
                }
            }
        }

        return itemCoordinates
    }

    private func mediumDetentAnnotationCoordinates(for items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        var coordinates = aggregatedFootprintCameraCoordinates(for: items)

        for item in items {
            guard case .transport(let transport) = item else { continue }
            let transportCoordinates = transport.lineSegments
                .flatMap { $0.coordinates }
                .filter(\.isRenderableMapCoordinate)
            if let midpoint = transportCoordinates.distanceMidpoint {
                coordinates.append(midpoint)
            }
        }

        if coordinates.isEmpty {
            return items.flatMap { item -> [CLLocationCoordinate2D] in
                switch item {
                case .footprint(let footprint):
                    return [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
                case .transport(let transport):
                    return sampledCoordinates(from: transport.points, maximumCount: 24)
                }
            }
        }

        return coordinates
    }

    private struct FootprintCameraBucket {
        var weightedLatitude: Double
        var weightedLongitude: Double
        var totalWeight: TimeInterval
        var totalDuration: TimeInterval
    }

    private func aggregatedFootprintCameraCoordinates(for items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        var buckets: [String: FootprintCameraBucket] = [:]
        var orderedKeys: [String] = []

        for item in items {
            guard case .footprint(let footprint) = item else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            guard coordinate.isRenderableMapCoordinate else { continue }

            let key: String
            if let placeID = footprint.placeID {
                key = "place:\(placeID.uuidString)"
            } else if !footprint.locationHash.isEmpty {
                key = "hash:\(footprint.locationHash)"
            } else {
                key = String(format: "coord:%.5f,%.5f", footprint.latitude, footprint.longitude)
            }

            let durationWeight = max(footprint.duration, 1)
            if var bucket = buckets[key] {
                bucket.weightedLatitude += footprint.latitude * durationWeight
                bucket.weightedLongitude += footprint.longitude * durationWeight
                bucket.totalWeight += durationWeight
                bucket.totalDuration += footprint.duration
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = FootprintCameraBucket(
                    weightedLatitude: footprint.latitude * durationWeight,
                    weightedLongitude: footprint.longitude * durationWeight,
                    totalWeight: durationWeight,
                    totalDuration: footprint.duration
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let divisor = max(bucket.totalWeight, 1)
            return CLLocationCoordinate2D(
                latitude: bucket.weightedLatitude / divisor,
                longitude: bucket.weightedLongitude / divisor
            )
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
        guard let region = coordinates.boundingRegion(paddingFactor: 1.4),
              isRenderableMapRegion(region) else { return nil }
        return adjustedMapRegion(region)
    }

    private func adjustedMapRegion(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        guard !isSideBySide, timelineDetent == .medium else { return region }
        let adjustedRegion = mediumDetentMapRegion(fitting: region)
        return isRenderableMapRegion(adjustedRegion) ? adjustedRegion : region
    }

    private func mediumDetentMapRegion(fitting region: MKCoordinateRegion) -> MKCoordinateRegion {
        let targetTopFraction = Double(mediumMapVisibleVerticalRange.lowerBound)
        let targetBottomFraction = Double(mediumMapVisibleVerticalRange.upperBound)
        let visibleFraction = targetBottomFraction - targetTopFraction
        let targetCenterFraction = (targetTopFraction + targetBottomFraction) / 2
        let fullMapAspectRatio = mapViewportSize.height > 1 && mapViewportSize.width > 1
            ? mapViewportSize.height / mapViewportSize.width
            : 2.15
        let longitudeDrivenLatitudeDelta = region.span.longitudeDelta
            * cos(region.center.latitude * .pi / 180)
            * fullMapAspectRatio
        let latitudeDelta = min(
            max(region.span.latitudeDelta / visibleFraction, longitudeDrivenLatitudeDelta),
            170
        )
        let centerLatitude = region.center.latitude
            - (0.5 - targetCenterFraction) * latitudeDelta

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: centerLatitude,
                longitude: region.center.longitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            )
        )
    }

    private func collapsedMapRegion(fromMediumCamera region: MKCoordinateRegion) -> MKCoordinateRegion {
        let targetTopFraction = Double(mediumMapVisibleVerticalRange.lowerBound)
        let targetBottomFraction = Double(mediumMapVisibleVerticalRange.upperBound)
        let visibleFraction = targetBottomFraction - targetTopFraction
        let targetCenterFraction = (targetTopFraction + targetBottomFraction) / 2

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: region.center.latitude
                    + (0.5 - targetCenterFraction) * region.span.latitudeDelta,
                longitude: region.center.longitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: region.span.latitudeDelta * visibleFraction,
                longitudeDelta: region.span.longitudeDelta
            )
        )
    }

}


private struct TimelineView: View {
    private enum ScrollTarget: Hashable {
        case date(Date)
        case now
        case todayBottom
        case dateLine(Date)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var activityTypes: [ActivityType]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var isShowingCalendar = false
    @State private var scrollRestorer = ContinuousTimelineScrollRestorer()
    @State private var headerVisibleDates: [Date] = []
    @State private var freezesViewportDrivenUpdatesUntil: Date? = Date.distantFuture
    @State private var activeTimelineDateBeforeBackground: Date?
    @State private var viewportAnchorBeforeBackground: ContinuousTimelineScrollAnchor?
    @State private var externalReloadViewportAnchor: ContinuousTimelineScrollAnchor?
    @State private var externalReloadDateAnchor: ContinuousTimelineDateAnchor?
    @State private var externalReloadDateRestoreTask: Task<Void, Never>?
    // Reference box: written on every geometry callback without invalidating
    // the view, so date-anchored restoration can read current row frames.
    @State private var rawDateFrames = ContinuousTimelineRawDateFrames()
    @State private var calendarScrollLockTarget: Date?
    @State private var collapsedTimelineDateAwaitingAlignment: Date?
    @State private var calendarScrollRetryTask: Task<Void, Never>?
    @State private var calendarScrollAlignsTargetToTop = false
    @State private var latestDateFrames: [Date: CGRect] = [:]
    @State private var latestViewportHeight: CGFloat = 0
    @State private var dateFrameUpdateCoalescer = ContinuousTimelineDateFrameUpdateCoalescer()
    @State private var itemFrameUpdateCoalescer = ContinuousTimelineDateFrameUpdateCoalescer()
    @State private var latestVisibleItemIDs = Set<String>()
    /// The map fits the active day as a whole until the user scrolls the
    /// timeline by hand; only then does it follow the visible rows.
    @State private var mapFollowsVisibleContent = false
    @State private var initialTodayScrollTask: Task<Void, Never>?
    @State private var initialLoadingFallbackTask: Task<Void, Never>?
    @State private var allowsInitialLoadingFallback = false
    @State private var scrollNavigationGeneration = UUID()
    @State private var returnToTodayTask: Task<Void, Never>?
    @State private var timelineScrollPosition: ScrollTarget?
    @State private var isLoadingMoreEarlier = false
    @State private var isPreservingViewportForEarlierLoad = false
    @State private var isLoadingMoreLater = false
    @State private var loadingGapAfterDates = Set<Date>()
    @State private var loadingGapBeforeDates = Set<Date>()
    @State private var showingResetAlert = false
    @State private var showingRawPointsDate: IdentifiableDate?
    @State private var didScheduleInitialScrollToToday = false
    @State private var footprintPendingDeletion: Footprint?
    @State private var footprintPendingIgnore: Footprint?
    @State private var transportPendingDeletion: Transport?
    @State private var footprintPendingSplit: Footprint?
    @State private var transportPendingSplit: Transport?
    @State private var pendingMergeCandidate: ContinuousAdjacentFootprintMergeCandidate?
    @State private var pendingTransportMergeCandidate: ContinuousAdjacentTransportMergeCandidate?
    @State private var hasCompletedInitialTimelinePositioning = false
    @State private var importantPlaceDraft: ImportantPlaceDraft?
    @State private var sharePayload: DFKShareCardPayload?
    @State private var showingTimelineShareRangePicker = false
    @AppStorage("isImportantPlaceGuideDismissed") private var isImportantPlaceGuideDismissed = false

    let dates: [Date]
    let timelinesByDate: [Date: [TimelineItem]]
    let initialTimelineLoadCompleted: Bool
    let layoutViewportState: ContinuousTimelineLayoutViewportState
    let isReloadingTimelineExternally: Bool
    let locationManager: LocationManager
    @Binding var activeTimelineDate: Date
    @Binding var todayScrollRequest: Int
    let returnToNowRequest: Int
    @Binding var targetScrollDate: Date?
    @Binding var timelineDetent: PresentationDetent
    @Binding var isCalendarScrollLocked: Bool
    let isSideBySide: Bool
    @Binding var selectedFootprint: Footprint?
    @Binding var selectedFootprintStartsExpanded: Bool
    @Binding var selectedTransport: Transport?
    /// Presented here rather than by the map: the map lives in the app
    /// window, beneath the records window that hosts every sheet.
    @Binding var selectedFootprintGroup: DFKMapView.AggregatedFootprint?
    @State private var footprintSelectedFromGroup: Footprint?
    let onFootprintGroupCancelled: () -> Void
    let loadEarlierDates: () async -> Bool
    let loadLaterDates: () async -> Bool
    let loadLaterDatesAfter: (Date) async -> Bool
    let loadGapDates: ([Date]) async -> Bool
    let loadDate: (Date, Bool) async -> Bool
    let gapLoadBatchSize: Int
    let availableDates: Set<Date>
    let visibleDatesChanged: (Set<Date>) -> Void
    let visibleItemIDsChanged: (Set<String>) -> Void
    let isActive: Bool
    /// Starts the shared photo import flow here, without leaving Records.
    @State private var isPhotoImportRequested = false
    @Binding var selectedMapPhotoAssetID: String?
    @State private var selectedMapPhotoAssetIDs: [String] = []

    private var isCollapsed: Bool {
        !isSideBySide && timelineDetent == .height(collapsedTimelineDetentHeight)
    }

    private var timelineScrollPositionBinding: Binding<ScrollTarget?> {
        Binding(
            // Prepending dates is preserved directly on UIScrollView using its
            // content-height delta. Detach SwiftUI's ID-based positioning for
            // that operation; otherwise both systems adjust the offset and the
            // timeline visibly bounces before eventually snapping to an edge.
            get: { isPreservingPhysicalViewport ? nil : timelineScrollPosition },
            set: { newValue in
                // While a calendar jump is in flight, viewport updates may
                // report the old (usually today) row. Keep the requested ID
                // until that destination has actually become visible.
                guard !isPreservingPhysicalViewport,
                      calendarScrollLockTarget == nil,
                      returnToTodayTask == nil else { return }
                timelineScrollPosition = newValue
            }
        )
    }

    private var isPreservingPhysicalViewport: Bool {
        isPreservingViewportForEarlierLoad || scenePhase != .active ||
        viewportAnchorBeforeBackground != nil || isReloadingTimelineExternally ||
        scrollRestorer.isRestoring || calendarScrollLockTarget != nil
    }

    private var isShowingFootprintDeletionAlert: Binding<Bool> {
        alertBinding(for: $footprintPendingDeletion)
    }

    private var isShowingFootprintIgnoreAlert: Binding<Bool> {
        alertBinding(for: $footprintPendingIgnore)
    }

    private var isShowingTransportDeletionAlert: Binding<Bool> {
        alertBinding(for: $transportPendingDeletion)
    }

    private var isShowingFootprintMergeAlert: Binding<Bool> {
        alertBinding(for: $pendingMergeCandidate)
    }

    private var isShowingTransportMergeAlert: Binding<Bool> {
        alertBinding(for: $pendingTransportMergeCandidate)
    }

    private func alertBinding<Item>(for item: Binding<Item?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }

    private var canLoadEarlierDates: Bool {
        guard let firstDate = currentDates.first else { return false }
        return availableDates.contains { $0 < firstDate }
    }

    private var canLoadLaterDates: Bool {
        guard let lastDate = currentDates.last else { return false }
        let today = Calendar.current.startOfDay(for: Date())
        return availableDates.contains { $0 > lastDate && $0 <= today }
    }

    private func loadableTimelineDates(between earlierDate: Date, and laterDate: Date) -> [Date] {
        let calendar = Calendar.current
        let earlierDate = calendar.startOfDay(for: earlierDate)
        let laterDate = calendar.startOfDay(for: laterDate)
        return availableDates.compactMap { availableDate -> Date? in
            let normalizedDate = calendar.startOfDay(for: availableDate)
            guard normalizedDate > earlierDate && normalizedDate < laterDate && !currentDates.contains(normalizedDate) else { return nil }
            return normalizedDate
        }.sorted()
    }

    /// The rendered date list, safe to read after an `await`. Tasks capture a
    /// copy of this struct whose `dates` stays frozen at capture time, so a
    /// row loaded during the task would look missing through `dates`.
    private var currentDates: [Date] { rawDateFrames.dates }

    var body: some View {
        let _ = { rawDateFrames.dates = dates }()
        ScrollViewReader { proxy in
            recordsPage(proxy: proxy)
                .onChange(of: todayScrollRequest) { _, _ in
                    requestScrollToToday(using: proxy)
                }
                .onChange(of: returnToNowRequest) { _, _ in
                    requestScrollToToday(using: proxy, expandsCollapsedTimeline: false)
                }
        }
    }

    private func recordsPage(proxy: ScrollViewProxy) -> some View {
        ZStack {
            if isSideBySide, let selectedFootprint {
                buildFootprintModalView(for: selectedFootprint, isInline: true)
            } else {
                NavigationStack {
                    GeometryReader { viewport in
                        // Keep the scroll view mounted while collapsed so its
                        // current offset survives re-expansion. Rendering it
                        // transparent prevents its first row from peeking
                        // below the title bar in the collapsed detent.
                        mainScrollView(proxy: proxy, viewport: viewport)
                            // The reader's frame ends at the title bar; rows
                            // never draw over the sheet's top band.
                            .clipped()
                            .opacity(isCollapsed ? 0 : 1)
                            .allowsHitTesting(!isCollapsed)
                    .sheet(item: $footprintPendingSplit, onDismiss: handleFootprintSplitDismissal) { footprint in
                        FootprintSplitView(footprint: footprint)
                            .environment(locationManager)
                    }
                    .sheet(item: $transportPendingSplit, onDismiss: handleTransportSplitDismissal) { transport in
                        TransportSplitView(transport: transport)
                    }
                    .sheet(item: $selectedTransport) { transport in
                        TransportModalView(transport: transport) { newType in
                            updateTransport(transport, type: newType)
                        } onLocationUpdate: {
                            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                        }
                        .environment(locationManager)
                    }
                    .sheet(item: $sharePayload) { _ in
                        DFKShareCardSheet(payload: $sharePayload)
                    }
                    .sheet(isPresented: $showingTimelineShareRangePicker) {
                        DFKTimelineShareRangePicker(initialDate: activeTimelineDate) { startDate, endDate in
                            prepareTimelineShare(startDate: startDate, endDate: endDate)
                        }
                    }
                    .sheet(item: $importantPlaceDraft) { draft in
                        AddPlaceSheet(
                            initialCoordinate: draft.coordinate,
                            initialName: draft.name
                        ) { newPlace in
                            modelContext.insert(newPlace)
                            try? modelContext.save()
                            CloudSettingsManager.shared.triggerDataSyncPulse()
                        }
                        .id(draft.id)
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
                        .alert("确认删除足迹？", isPresented: isShowingFootprintDeletionAlert) {
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
                        .alert("忽略并删除在此地点的足迹？", isPresented: isShowingFootprintIgnoreAlert) {
                            Button("忽略并删除", role: .destructive) {
                                if let footprintPendingIgnore {
                                    let time = footprintPendingIgnore.startTime
                                    locationManager.ignoreLocation(for: footprintPendingIgnore)
                                    invalidateAndRefreshTimeline(containing: time)
                                }
                                footprintPendingIgnore = nil
                            }
                            Button("取消", role: .cancel) { footprintPendingIgnore = nil }
                        } message: {
                            Text("添加为忽略地点后，以后将不再记录此处的足迹，且现有的同地点足迹也将被隐藏。")
                        }
                        .alert("确认删除此交通记录？", isPresented: isShowingTransportDeletionAlert) {
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
                        .alert("合并相邻足迹？", isPresented: isShowingFootprintMergeAlert) {
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
                        .alert("合并相邻交通？", isPresented: isShowingTransportMergeAlert) {
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
                        .onChange(of: locationManager.isResettingData) { oldValue, newValue in
                            if oldValue && !newValue {
                                let targetDate = Calendar.current.startOfDay(for: activeTimelineDate)
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    withAnimation {
                                        proxy.scrollTo(ScrollTarget.date(targetDate), anchor: .bottom)
                                    }
                                }
                            }
                        }
                    .toolbar { headerToolbar(proxy: proxy) }
                    .navigationBarTitleDisplayMode(.inline)
                    } // GeometryReader
                } // NavigationStack
                .toolbar(removing: .sidebarToggle)
            }
            if isInitialTimelineLoading && (!isSideBySide || selectedFootprint == nil) {
                Group {
                    if isSideBySide {
                        initialTimelineLoadingOverlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.container)
                    } else {
                        // This is outside the scroll view so its material reaches
                        // the sheet's bottom edge while its title band stays clear.
                        GeometryReader { viewport in
                            initialTimelineLoadingOverlay
                                .frame(
                                    width: viewport.size.width,
                                    height: max(0, viewport.size.height - 64)
                                )
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            resettingIndicator
        } // ZStack
        // The imported footprints reach the timeline through the existing
        // FootprintDataChanged reload that the flow posts.
        .photoImportFlow(isRequested: $isPhotoImportRequested)
        .fullScreenCover(item: Binding(
            get: { selectedMapPhotoAssetID.map { IdentifiableString(value: $0) } },
            set: {
                selectedMapPhotoAssetID = $0?.value
                if $0 == nil { selectedMapPhotoAssetIDs = [] }
            }
        )) { item in
            let assetIDs = selectedMapPhotoAssetIDs.isEmpty ? [item.value] : selectedMapPhotoAssetIDs
            let currentIndex = assetIDs.firstIndex(of: item.value) ?? 0
            PhotoFullscreenView(assetIDs: assetIDs, currentIndex: currentIndex)
        }
        .sheet(item: Binding(
            get: { isActive && !isSideBySide ? selectedFootprint : nil },
            set: { selectedFootprint = $0 }
        )) { footprint in
            buildFootprintModalView(for: footprint)
        }
        .sheet(item: Binding(
            get: { isActive ? selectedFootprintGroup : nil },
            set: { selectedFootprintGroup = $0 }
        ), onDismiss: {
            guard let footprint = footprintSelectedFromGroup else {
                onFootprintGroupCancelled()
                return
            }
            footprintSelectedFromGroup = nil
            selectedFootprint = storedFootprint(matching: footprint)
        }) { aggregated in
            FootprintGroupSheet(aggregated: aggregated, allPlaces: allPlaces) { footprint in
                footprintSelectedFromGroup = footprint
                selectedFootprintGroup = nil
            }
        }
    } // body
    
    @ViewBuilder
    private func mainScrollView(proxy: ScrollViewProxy, viewport: GeometryProxy) -> some View {
                        ScrollView {
                            ScrollOffsetObserver(restorer: scrollRestorer)
                            .frame(width: 0, height: 0)

                            LazyVStack(alignment: .leading, spacing: 0) {
                                if canLoadEarlierDates {
                                    TimelineLoadMoreButton(
                                        title: "查看更早的足迹",
                                        isLoading: isLoadingMoreEarlier,
                                        action: requestLoadEarlierDates
                                    )
                                    // A notification deep link can complete its
                                    // calendar positioning through a different
                                    // path than the normal launch-to-today flow.
                                    // The button must follow data readiness, not
                                    // that optional positioning flag.
                                    .opacity(initialTimelineLoadCompleted ? 1 : 0)
                                    .allowsHitTesting(initialTimelineLoadCompleted)
                                } else if initialTimelineLoadCompleted {
                                    TimelineLoadMoreButton(
                                        title: "从照片导入足迹",
                                        isLoading: false,
                                        action: {
                                            isPhotoImportRequested = true
                                        }
                                    )
                                    .opacity(initialTimelineLoadCompleted ? 1 : 0)
                                    .allowsHitTesting(initialTimelineLoadCompleted)
                                }

                                ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                                    VStack(spacing: 0) {
                                        if let previousDate = dates[safe: index - 1] {
                                            let loadableGapDates = loadableTimelineDates(between: previousDate, and: date)
                                            if !loadableGapDates.isEmpty {
                                                TimelineLoadMoreButton(
                                                    title: "查看更多足迹",
                                                    isLoading: loadingGapAfterDates.contains(previousDate),
                                                    action: { requestLoadDates(after: previousDate, before: date) }
                                                )
                                                .padding(.bottom, 6)
                                            }

                                            if let gapDays = Calendar.current.dateComponents([.day], from: previousDate, to: date).day,
                                               gapDays > 1 {
                                                TimelineDateGapConnector(skippedDays: gapDays - 1)
                                            }

                                            if !loadableGapDates.isEmpty {
                                                TimelineLoadMoreButton(
                                                    title: "查看更早的足迹",
                                                    isLoading: loadingGapBeforeDates.contains(date),
                                                    action: { requestLoadDates(before: date, after: previousDate) }
                                                )
                                                .padding(.top, 6)
                                            }
                                        }

                                        timelineDay(for: date)
                                            // The section ID also covers gap
                                            // controls; this one starts at the date line.
                                            .id(ScrollTarget.dateLine(date))
                                            .background {
                                                GeometryReader { geometry in
                                                    Color.clear.preference(
                                                        key: ContinuousTimelineDateFramePreferenceKey.self,
                                                        value: [date: geometry.frame(in: .named("continuousTimelineScroll"))]
                                                    )
                                                }
                                            }
                                    }
                                    .id(ScrollTarget.date(date))
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
                            .scrollTargetLayout()
                        }
                        .scrollPosition(id: timelineScrollPositionBinding, anchor: .bottom)
                        // Viewport restoration already cancels itself as soon
                        // as the user interacts. Do not freeze the whole
                        // timeline while historical data is fetched.
                        .scrollDisabled(isCollapsed)
                        .timelineHiddenScrollEdges()
                        .coordinateSpace(name: "continuousTimelineScroll")
                        .onChange(of: viewport.size) { oldSize, newSize in
                            restoreTimelineDateAfterRotation(from: oldSize, to: newSize, using: proxy)
                        }
                        .onPreferenceChange(ContinuousTimelineDateFramePreferenceKey.self) { frames in
                            guard isActive, !isCollapsed else { return }
                            let viewportHeight = viewport.size.height
                            rawDateFrames.update(frames: frames, viewportHeight: viewportHeight)
                            // A detent animation changes the viewport height on
                            // every frame. Keep the latest geometry available
                            // for restoration, but do not compete with UIKit by
                            // recalculating titles, dates and map input mid-resize.
                            guard !rawDateFrames.isViewportResizing else {
                                dateFrameUpdateCoalescer.cancel()
                                itemFrameUpdateCoalescer.cancel()
                                return
                            }
                            // An explicit date jump owns the title until its
                            // destination has settled. Geometry snapshots from
                            // the row we just left can otherwise arrive one
                            // frame late and visibly put the title back.
                            if !isFreezingViewportDrivenUpdates {
                                updateHeaderDateDisplay(from: frames, viewportHeight: viewportHeight)
                            }
                            if hasCompletedInitialTimelinePositioning,
                               !isFreezingViewportDrivenUpdates,
                               let anchor = currentDateAnchor() {
                                layoutViewportState.anchor = anchor
                            }
                            // LazyVStack may publish several geometry snapshots
                            // in one frame. Keep only the newest one so state/map
                            // updates cannot form a per-frame feedback loop.
                            dateFrameUpdateCoalescer.schedule(
                                userWasInteracting: scrollRestorer.isUserInteracting,
                                isInteractionActive: { scrollRestorer.isUserInteracting }
                            ) { userWasInteracting in
                                applyDateFrameUpdate(frames, viewportHeight: viewportHeight, userWasInteracting: userWasInteracting)
                            }
                        }
                        .onPreferenceChange(ContinuousTimelineItemFramePreferenceKey.self) { frames in
                            guard isActive, !isCollapsed else { return }
                            guard !rawDateFrames.isViewportResizing else {
                                itemFrameUpdateCoalescer.cancel()
                                return
                            }
                            let viewportHeight = viewport.size.height
                            let userIsInteracting = scrollRestorer.isUserInteracting
                            // Before the first manual scroll, the camera fits
                            // the active day and does not consume row frames.
                            guard mapFollowsVisibleContent || userIsInteracting else { return }
                            itemFrameUpdateCoalescer.schedule(
                                userWasInteracting: userIsInteracting,
                                isInteractionActive: { scrollRestorer.isUserInteracting }
                            ) { userWasInteracting in
                                applyItemFrameUpdate(frames, viewportHeight: viewportHeight, userWasInteracting: userWasInteracting)
                            }
                        }
                    .onAppear {
                        if targetScrollDate != nil {
                            requestScrollToToday(using: proxy)
                        } else if hasCompletedInitialTimelinePositioning,
                                  let anchor = layoutViewportState.anchor {
                            restoreDateAnchorAfterExternalReload(anchor, using: proxy)
                        } else {
                            scheduleInitialScrollToTodayIfNeeded(using: proxy)
                        }
                        scheduleInitialLoadingFallback()
                    }
                    .onChange(of: initialTimelineLoadCompleted) { _, _ in
                        guard calendarScrollLockTarget == nil,
                              isActive else { return }
                        scheduleInitialScrollToTodayIfNeeded(using: proxy)
                    }
                    .onChange(of: timelineDetent) { oldValue, newValue in
                        // A sheet resize changes every published frame even
                        // though the user did not scroll the timeline. Ignore
                        // that layout-only geometry so it cannot refit the map.
                        dateFrameUpdateCoalescer.cancel()
                        itemFrameUpdateCoalescer.cancel()
                        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
                        mapFollowsVisibleContent = false
                        latestVisibleItemIDs = []

                        if oldValue == .height(collapsedTimelineDetentHeight),
                           newValue != .height(collapsedTimelineDetentHeight),
                           let date = collapsedTimelineDateAwaitingAlignment {
                            collapsedTimelineDateAwaitingAlignment = nil
                            // The target row may still be unmounted after a
                            // distant collapsed-date change. Reuse the normal
                            // measured alignment path instead of issuing one
                            // best-effort ScrollViewProxy jump.
                            scrollToDate(date, using: proxy, alignToTop: true)
                        }
                    }
                    .onChange(of: isReloadingTimelineExternally) { _, isReloading in
                        // A reload triggered outside this view (e.g. CloudKit changes syncing in
                        // after the app returns from background) can reshuffle every loaded date
                        // section's content/height. Freeze viewport-driven date tracking for the
                        // duration so the transient scroll geometry isn't misread as the user
                        // having scrolled to an old date. Leave the initial launch positioning
                        // alone entirely — it manages this same freeze on its own timeline, and
                        // stepping on it here would race the "stay on today at launch" behavior.
                        guard hasCompletedInitialTimelinePositioning else { return }
                        if isReloading {
                            externalReloadDateRestoreTask?.cancel()
                            externalReloadViewportAnchor = returnToTodayTask == nil && calendarScrollLockTarget == nil
                                ? (viewportAnchorBeforeBackground ?? scrollRestorer.captureAnchor()) : nil
                            // The reload rebuilds every loaded day, including
                            // the (often many) days below the viewport. A
                            // content-offset anchor compensates for the whole
                            // content-height delta as if it were inserted
                            // above, which drops a historical viewport onto an
                            // intermediate day. Anchor to the row instead,
                            // unless the viewport is following the bottom.
                            if scenePhase == .active,
                               viewportAnchorBeforeBackground == nil,
                               let anchor = externalReloadViewportAnchor,
                               anchor.bottomDistance >= 8,
                               let dateAnchor = currentDateAnchor() {
                                externalReloadDateAnchor = dateAnchor
                                externalReloadViewportAnchor = nil
                            } else {
                                externalReloadDateAnchor = nil
                            }
                            timelineScrollPosition = nil
                            freezesViewportDrivenUpdatesUntil = Date.distantFuture
                        } else {
                            // Don't force an immediate re-read here: latestDateFrames can still
                            // reflect stale/incomplete geometry from before the reload settled.
                            // Give layout a brief moment, then let the ordinary preference-key
                            // pipeline (which reports real, settled frames) resume driving date
                            // tracking on its own.
                            freezesViewportDrivenUpdatesUntil = scenePhase == .active
                                ? Date().addingTimeInterval(0.3) : Date.distantFuture
                            if let anchor = externalReloadViewportAnchor {
                                if scenePhase == .active {
                                    scrollRestorer.restore(anchor, fallbackBottomDistance: anchor.bottomDistance)
                                } else {
                                    scrollRestorer.beginContinuousRestoration(anchor, fallbackBottomDistance: anchor.bottomDistance)
                                }
                            }
                            externalReloadViewportAnchor = nil
                            if let dateAnchor = externalReloadDateAnchor, scenePhase == .active {
                                restoreDateAnchorAfterExternalReload(dateAnchor, using: proxy)
                            }
                            externalReloadDateAnchor = nil
                        }
                    }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        // Returning from background can make the LazyVStack's underlying
                        // UICollectionView remount/relayout its rows, which briefly reports
                        // incorrect frames through ContinuousTimelineDateFramePreferenceKey.
                        // Freezing only reactively on the way back to .active leaves a race:
                        // the bad geometry read can land at/just before that callback fires,
                        // before the freeze is in effect. So freeze indefinitely the moment we
                        // leave .active, keeping protection engaged with no gap for the entire
                        // backgrounded stretch, then shrink it to a short settle window once
                        // we're actually back. Gate on initial positioning so this can't fire
                        // during (and interfere with) the cold-launch "stay on today" sequence.
                        guard hasCompletedInitialTimelinePositioning else { return }
                        if newPhase == .active {
                            if oldPhase != .active {
                                freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.6)
                                if let anchor = viewportAnchorBeforeBackground {
                                    // SwiftUI may remount the LazyVStack while inactive. Keep
                                    // the same content offset as well as the same date state;
                                    // freezing frame reads alone cannot prevent a physical jump.
                                    scrollRestorer.restore(anchor, fallbackBottomDistance: anchor.bottomDistance)
                                }
                                viewportAnchorBeforeBackground = nil
                                // Belt-and-suspenders: don't just rely on the freeze window
                                // timing out safely — deterministically put the date state back
                                // to what it was right before backgrounding, in case a bad
                                // geometry read already slipped through before this callback
                                // ran. The scroll view itself never physically moved while
                                // backgrounded, so this can't fight the user's real position.
                                if let restoredDate = activeTimelineDateBeforeBackground {
                                    activeTimelineDate = restoredDate
                                    visibleDatesChanged([Calendar.current.startOfDay(for: restoredDate)])
                                }
                                activeTimelineDateBeforeBackground = nil
                            }
                        } else {
                            if oldPhase == .active {
                                activeTimelineDateBeforeBackground = activeTimelineDate
                                viewportAnchorBeforeBackground = scrollRestorer.captureAnchor()
                                // Discard the old row ID before background layout can reuse it.
                                timelineScrollPosition = nil
                                if let anchor = viewportAnchorBeforeBackground {
                                    scrollRestorer.beginContinuousRestoration(anchor, fallbackBottomDistance: anchor.bottomDistance)
                                }
                            }
                            freezesViewportDrivenUpdatesUntil = Date.distantFuture
                        }
                    }
                    .onDisappear {
                        if let destination = calendarScrollLockTarget {
                            // The retry task is cancelled below, so its lock must
                            // not outlive it (a disappear can also come from a
                            // stacked sheet, e.g. the calendar, while this tab
                            // stays active). Resume the jump on reappearance.
                            targetScrollDate = targetScrollDate ?? destination
                            scrollNavigationGeneration = UUID()
                            calendarScrollLockTarget = nil
                            isCalendarScrollLocked = false
                        } else if !isActive, let anchor = currentDateAnchor() {
                            layoutViewportState.anchor = anchor
                        }
                        returnToTodayTask?.cancel()
                        scrollRestorer.cancelRestoration()
                        initialTodayScrollTask?.cancel()
                        initialTodayScrollTask = nil
                        initialLoadingFallbackTask?.cancel()
                        initialLoadingFallbackTask = nil
                        if !hasCompletedInitialTimelinePositioning, targetScrollDate == nil {
                            didScheduleInitialScrollToToday = false
                        }
                        calendarScrollRetryTask?.cancel()
                        calendarScrollRetryTask = nil
                        externalReloadDateRestoreTask?.cancel()
                        dateFrameUpdateCoalescer.cancel()
                        itemFrameUpdateCoalescer.cancel()
                    }
    }

    @ViewBuilder
    private var resettingIndicator: some View {
        if locationManager.isResettingData {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在重新生成...")
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .padding(30)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
        }
    }

    private var isInitialTimelineLoading: Bool {
        !initialTimelineLoadCompleted
            || (!hasCompletedInitialTimelinePositioning && !allowsInitialLoadingFallback)
    }

    private func scheduleInitialLoadingFallback() {
        guard initialLoadingFallbackTask == nil, !allowsInitialLoadingFallback else { return }
        initialLoadingFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            allowsInitialLoadingFallback = true
        }
    }

    private var initialTimelineLoadingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)

                Text("正在加载时间轴")
                    .font(.headline)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("正在加载时间轴")
    }
    @ViewBuilder
    private func buildFootprintModalView(for footprint: Footprint, isInline: Bool = false) -> some View {
        FootprintModalView(
            footprint: footprint,
            autoFocus: false,
            isInline: isInline,
            startsExpanded: selectedFootprintStartsExpanded,
            scrollsToPhotosOnAppear: selectedFootprintStartsExpanded,
            onDismiss: { didChange in
                guard didChange else { return }
                invalidateAndRefreshTimeline(containing: footprint.startTime)
                CloudSettingsManager.shared.triggerDataSyncPulse()
            },
            onRequestClose: isInline ? { selectedFootprint = nil } : nil
        )
        .environment(locationManager)
        .transition(.move(edge: .bottom))
    }

    @ToolbarContentBuilder
    private func headerToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                navigateRecordedDay(forward: false, using: proxy)
            } label: {
                Label("上一天", systemImage: "chevron.left")
            }
            .disabled(adjacentRecordedDate(forward: false) == nil)
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
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Text(limitedSecondaryHeader)
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
            .sheet(isPresented: $isShowingCalendar) {
                NavigationStack {
                    HistoryListView(initialDate: activeTimelineDate, calendarOnly: true, onDateSelected: { date in
                        isShowingCalendar = false
                        scrollToDate(Calendar.current.startOfDay(for: date), using: proxy)
                    })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingCalendar = false }
                        }
                    }
                }
                .presentationDetents([.large])
            }
            .contextMenu {
                Button {
                    prepareTimelineShare()
                } label: {
                    Label("分享当前日期足迹", systemImage: "square.and.arrow.up")
                }
                Button {
                    showingTimelineShareRangePicker = true
                } label: {
                    Label("选择日期范围分享", systemImage: "calendar.badge.plus")
                }
                Divider()
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
            Button {
                navigateRecordedDay(forward: true, using: proxy)
            } label: {
                Label("下一天", systemImage: "chevron.right")
            }
            .disabled(adjacentRecordedDate(forward: true) == nil)
        }
    }

    private func adjacentRecordedDate(forward: Bool) -> Date? {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: calendarScrollLockTarget ?? activeTimelineDate)
        let today = calendar.startOfDay(for: Date())
        let candidates = availableDates.filter { date in
            date <= today && (forward ? date > base : date < base)
        }
        return forward ? candidates.min() : candidates.max()
    }

    private func navigateRecordedDay(forward: Bool, using proxy: ScrollViewProxy) {
        guard let date = adjacentRecordedDate(forward: forward) else { return }
        scrollToDate(date, using: proxy, alignToTop: true, prefersImmediateLoadedTarget: true)
    }

    private func prepareTimelineShare() {
        let date = Calendar.current.startOfDay(for: activeTimelineDate)
        let items = timelinesByDate[date] ?? []
        let photoAssetIDs = items.flatMap { item -> [String] in
            if case .footprint(let footprint) = item {
                return footprint.photoAssetIDs
            }
            return []
        }
        let footprints = items.compactMap { item -> Footprint? in
            if case .footprint(let footprint) = item {
                return footprint
            }
            return nil
        }
        let transports = shareTransportRecords(from: items)
        let coordinates = shareMapCoordinates(from: items)
        let loadingPayload = DFKShareCardFactory.loadingPayload(
            kind: .timeline,
            rangeText: DFKShareCardFactory.dateText(date),
            coordinates: coordinates
        )
        sharePayload = loadingPayload
        let payloadID = loadingPayload.id

        DFKShareImageLoader.loadShareMedia(
            assetIDs: photoAssetIDs,
            coordinates: coordinates,
            footprints: footprints,
            transports: transports,
            widgetDate: date,
            activities: activityTypes,
            markerScale: footprints.count <= 1 ? 2.2 : 1.5
        ) { media in
            var payload = DFKShareCardFactory.timelinePayload(
                date: date,
                items: items,
                activities: activityTypes,
                images: media.images,
                mapImage: media.mapImage,
                lightMapImage: media.lightMapImage,
                darkMapImage: media.darkMapImage
            )
            payload.contentMapImage = media.mapImage
            payload.contentMapLightImage = media.lightMapImage
            payload.contentMapDarkImage = media.darkMapImage
            payload.backgroundMapImage = media.backgroundMapImage
            payload.backgroundMapLightImage = media.backgroundLightMapImage
            payload.backgroundMapDarkImage = media.backgroundDarkMapImage
            payload.mapTransports = transports
            guard sharePayload?.id == payloadID else { return }
            payload.id = payloadID
            sharePayload = payload
        }
    }

    private func prepareTimelineShare(startDate: Date, endDate: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let selectedEnd = calendar.startOfDay(for: max(startDate, endDate))
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: selectedEnd) ?? selectedEnd.addingTimeInterval(24 * 3600)
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> {
                $0.startTime < endExclusive && $0.endTime > start && $0.statusValue != "ignored"
            },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let footprints = (try? modelContext.fetch(descriptor)) ?? []
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate<TransportRecord> {
                $0.startTime < endExclusive && $0.endTime > start && $0.statusRaw != "ignored"
            },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let transports = (try? modelContext.fetch(transportDescriptor)) ?? []
        let photoAssetIDs = footprints.flatMap(\.photoAssetIDs)
        let rangeText = DFKShareCardFactory.rangeText(from: start, to: selectedEnd)
        let coordinates = footprints.flatMap(\.coordinates) + shareMapCoordinates(from: transports)
        let loadingPayload = DFKShareCardFactory.loadingPayload(
            kind: .timeline,
            rangeText: rangeText,
            coordinates: coordinates
        )
        sharePayload = loadingPayload
        let payloadID = loadingPayload.id

        DFKShareImageLoader.loadShareMedia(
            assetIDs: photoAssetIDs,
            coordinates: coordinates,
            footprints: footprints,
            transports: transports,
            widgetDate: start == selectedEnd ? start : nil,
            activities: activityTypes,
            markerScale: footprints.count <= 1 ? 2.2 : 1.5
        ) { media in
            var payload = DFKShareCardFactory.timelinePayload(
                rangeText: rangeText,
                footprints: footprints,
                activities: activityTypes,
                images: media.images,
                mapImage: media.mapImage,
                lightMapImage: media.lightMapImage,
                darkMapImage: media.darkMapImage
            )
            payload.contentMapImage = media.mapImage
            payload.contentMapLightImage = media.lightMapImage
            payload.contentMapDarkImage = media.darkMapImage
            payload.backgroundMapImage = media.backgroundMapImage
            payload.backgroundMapLightImage = media.backgroundLightMapImage
            payload.backgroundMapDarkImage = media.backgroundDarkMapImage
            payload.mapTransports = transports
            guard sharePayload?.id == payloadID else { return }
            payload.id = payloadID
            sharePayload = payload
        }
    }

    private func shareTransportRecords(from items: [TimelineItem]) -> [TransportRecord] {
        items.compactMap { item -> TransportRecord? in
            guard case .transport(let transport) = item else { return nil }
            let encodedPoints = transport.pathPoints.map {
                CodableCoordinate(
                    lat: $0.coordinate.latitude,
                    lon: $0.coordinate.longitude,
                    timestamp: $0.timestamp,
                    isSyntheticPadding: $0.isSyntheticPadding
                )
            }
            guard let pointsData = try? JSONEncoder().encode(encodedPoints), !encodedPoints.isEmpty else {
                return nil
            }
            let record = TransportRecord(
                recordID: transport.id,
                day: Calendar.current.startOfDay(for: transport.startTime),
                startTime: transport.startTime,
                endTime: transport.endTime,
                startLocation: transport.startLocation,
                endLocation: transport.endLocation,
                typeRaw: transport.type.rawValue,
                distance: transport.distance,
                averageSpeed: transport.averageSpeed,
                pointsData: pointsData,
                statusRaw: "active",
                stepCount: transport.stepCount
            )
            record.manualTypeRaw = transport.manualType?.rawValue
            return record
        }
    }

    private func shareMapCoordinates(from items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        items.flatMap { item -> [CLLocationCoordinate2D] in
            switch item {
            case .footprint(let footprint):
                let coordinates = footprint.coordinates
                if !coordinates.isEmpty { return coordinates }
                return [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
            case .transport(let transport):
                let coordinates = transport.lineSegments.flatMap(\.coordinates)
                if !coordinates.isEmpty { return coordinates }
                return transport.points
            }
        }
    }

    private func shareMapCoordinates(from transports: [TransportRecord]) -> [CLLocationCoordinate2D] {
        transports.flatMap { record in
            ((try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData)) ?? [])
                .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                .filter {
                    $0.latitude.isFinite &&
                    $0.longitude.isFinite &&
                    CLLocationCoordinate2DIsValid($0)
                }
        }
    }

    private func handleDateHeaderTap() {
        isShowingCalendar = true
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
            return timelineDateSecondaryTitleWithCity(for: firstDate)
        }

        let weekdayRange = "\(firstDate.formatted(.dateTime.weekday(.wide)))-\(lastDate.formatted(.dateTime.weekday(.wide)))"
        let cityNames = uniqueTimelineCityNames(for: displayDates)
        return cityNames.isEmpty ? weekdayRange : "\(weekdayRange) · \(cityNames.joined(separator: "、"))"
    }

    private var limitedSecondaryHeader: String {
        let characterLimit = 16
        guard secondaryHeader.count > characterLimit else { return secondaryHeader }
        return String(secondaryHeader.prefix(characterLimit)) + "…"
    }

    private func timelineDateSecondaryTitleWithCity(for display: Date) -> String {
        let dateTitle = timelineDateSecondaryTitle(for: display)
        let cityNames = uniqueTimelineCityNames(for: [display])
        return cityNames.isEmpty ? dateTitle : "\(dateTitle) · \(cityNames.joined(separator: "、"))"
    }

    private func uniqueTimelineCityNames(for dates: [Date]) -> [String] {
        let calendar = Calendar.current
        let normalizedDates = Set(dates.map { calendar.startOfDay(for: $0) })
        let footprints = timelinesByDate
            .filter { normalizedDates.contains(calendar.startOfDay(for: $0.key)) }
            .flatMap(\.value)
            .compactMap { item -> Footprint? in
                guard case .footprint(let footprint) = item else { return nil }
                return footprint
            }
            .sorted { $0.startTime < $1.startTime }

        var seen = Set<String>()
        return footprints.compactMap { footprint in
            guard let cityName = footprint.cityName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cityName.isEmpty,
                  seen.insert(cityName).inserted else { return nil }
            return cityName
        }
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
        if calendarScrollLockTarget != nil { return true }
        guard let freezesViewportDrivenUpdatesUntil else { return false }
        return Date() < freezesViewportDrivenUpdatesUntil
    }

    private func restoreTimelineDateAfterRotation(from oldSize: CGSize, to newSize: CGSize, using proxy: ScrollViewProxy) {
        // A real rotation swaps both dimensions of the window. Dragging the
        // timeline sheet between detents only ever changes its height (the
        // collapsed detent is shorter than the sheet is wide, medium/large are
        // taller), which flips the width>height comparison on its own and used
        // to be misread as a rotation, firing a live scrollTo mid-drag.
        guard oldSize.width > 0, oldSize.height > 0,
              newSize.width > 0, newSize.height > 0,
              abs(oldSize.width - newSize.width) > 1,
              (oldSize.width > oldSize.height) != (newSize.width > newSize.height) else {
            return
        }

        let anchor = layoutViewportState.anchor
            ?? ContinuousTimelineDateAnchor(date: Calendar.current.startOfDay(for: activeTimelineDate), bottomOffset: 0)
        guard currentDates.contains(anchor.date) else { return }
        restoreDateAnchorAfterExternalReload(anchor, using: proxy)
    }

    private func applyDateFrameUpdate(_ frames: [Date: CGRect], viewportHeight: CGFloat, userWasInteracting: Bool) {
        let startedFollowingVisibleContent = beginFollowingVisibleContentIfNeeded(userWasInteracting: userWasInteracting)
        if calendarScrollLockTarget == nil,
           !startedFollowingVisibleContent,
           !shouldProcessDateFrameUpdate(frames, viewportHeight: viewportHeight) {
            return
        }

        latestDateFrames = frames
        latestViewportHeight = viewportHeight
        // Geometry callbacks from the old viewport can arrive while the
        // explicit calendar animation is in flight. Do not let them promote
        // an intermediate row to activeTimelineDate or mutate the map
        // selection; either can rebuild the list mid-scroll.
        guard calendarScrollLockTarget == nil else { return }
        guard !isFreezingViewportDrivenUpdates else { return }
        applyViewportDates(from: frames, viewportHeight: viewportHeight)
        if let anchor = currentDateAnchor() {
            layoutViewportState.anchor = anchor
        }
    }

    private func significantVisibleDates(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Set<Date> {
        let bandTop: CGFloat = 52
        let bandBottom = max(bandTop, viewportHeight - 72)
        let centerY = viewportHeight * 0.5
        let bottomContentProbeY = max(bandTop, viewportHeight - 132)
        var visibleDates = Set<Date>()
        var bottomDate: Date?
        var bottomDateMinY = -CGFloat.infinity

        for (date, frame) in frames {
            let intersectionTop = max(frame.minY, bandTop)
            let intersectionBottom = min(frame.maxY, bandBottom)
            let intersectionHeight = max(0, intersectionBottom - intersectionTop)
            let minimumVisibleHeight = min(90, max(36, frame.height * 0.2))
            let containsCenter = frame.minY <= centerY && frame.maxY >= centerY
            if intersectionHeight >= minimumVisibleHeight || containsCenter {
                visibleDates.insert(date)
            }
            if frame.minY <= bottomContentProbeY,
               frame.maxY >= bottomContentProbeY,
               frame.minY > bottomDateMinY {
                bottomDate = date
                bottomDateMinY = frame.minY
            }
        }

        if bottomDate == nil {
            for (date, frame) in frames
                where frame.maxY > bandTop && frame.minY < viewportHeight && frame.minY > bottomDateMinY {
                bottomDate = date
                bottomDateMinY = frame.minY
            }
        }
        if let bottomDate {
            visibleDates.insert(bottomDate)
        }

        return visibleDates
    }

    /// Returns true only for the update in which a manual scroll starts.
    private func beginFollowingVisibleContentIfNeeded(userWasInteracting: Bool) -> Bool {
        guard !mapFollowsVisibleContent,
              calendarScrollLockTarget == nil,
              userWasInteracting || scrollRestorer.isUserInteracting else { return false }
        mapFollowsVisibleContent = true
        return true
    }

    private func applyItemFrameUpdate(_ frames: [String: CGRect], viewportHeight: CGFloat, userWasInteracting: Bool) {
        guard !isFreezingViewportDrivenUpdates else { return }
        _ = beginFollowingVisibleContentIfNeeded(userWasInteracting: userWasInteracting)
        // No visible-item subset means the map fits the whole active day.
        let itemIDs = mapFollowsVisibleContent
            ? significantVisibleItemIDs(in: frames, viewportHeight: viewportHeight)
            : []
        guard itemIDs != latestVisibleItemIDs else { return }
        latestVisibleItemIDs = itemIDs
        visibleItemIDsChanged(itemIDs)
    }

    /// Same overlap-with-a-fixed-viewport-band test as `significantVisibleDates`,
    /// but per timeline row, so the map camera can track only the footprints
    /// and transport actually scrolled into view rather than a whole day.
    private func significantVisibleItemIDs(in frames: [String: CGRect], viewportHeight: CGFloat) -> Set<String> {
        guard viewportHeight > 0 else { return [] }
        let bandTop: CGFloat = 52
        let bandBottom = max(bandTop, viewportHeight - 72)
        let centerY = viewportHeight * 0.5
        var visibleItemIDs = Set<String>()

        for (id, frame) in frames {
            let intersectionTop = max(frame.minY, bandTop)
            let intersectionBottom = min(frame.maxY, bandBottom)
            let intersectionHeight = max(0, intersectionBottom - intersectionTop)
            let minimumVisibleHeight = min(48, max(16, frame.height * 0.3))
            let containsCenter = frame.minY <= centerY && frame.maxY >= centerY
            if intersectionHeight >= minimumVisibleHeight || containsCenter {
                visibleItemIDs.insert(id)
            }
        }
        return visibleItemIDs
    }

    private func bottomVisibleDate(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Date? {
        let bandTop: CGFloat = 52
        let bottomContentProbeY = max(bandTop, viewportHeight - 132)
        var probeDate: Date?
        var probeMinY = -CGFloat.infinity
        var fallbackDate: Date?
        var fallbackMinY = -CGFloat.infinity

        for (date, frame) in frames {
            if frame.minY <= bottomContentProbeY,
               frame.maxY >= bottomContentProbeY,
               frame.minY > probeMinY {
                probeDate = date
                probeMinY = frame.minY
            }
            if frame.maxY > bandTop,
               frame.minY < viewportHeight,
               frame.minY > fallbackMinY {
                fallbackDate = date
                fallbackMinY = frame.minY
            }
        }
        return probeDate ?? fallbackDate
    }

    private func headerVisibleDate(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Date? {
        let bandTop: CGFloat = 52
        let headerProbeY = max(bandTop, viewportHeight * 0.38)
        var probeDate: Date?
        var probeMinY = -CGFloat.infinity
        var fallbackDate: Date?
        var fallbackDistance = CGFloat.infinity

        for (date, frame) in frames {
            if frame.minY <= headerProbeY,
               frame.maxY >= headerProbeY,
               frame.minY > probeMinY {
                probeDate = date
                probeMinY = frame.minY
            }
            if frame.maxY > bandTop, frame.minY < viewportHeight {
                let distance = abs(frame.midY - headerProbeY)
                if distance < fallbackDistance {
                    fallbackDate = date
                    fallbackDistance = distance
                }
            }
        }
        return probeDate ?? fallbackDate
    }

    /// Keep the title visually attached to the row under the header while the
    /// finger is moving. This intentionally changes display-only state: the
    /// coalesced viewport handler remains solely responsible for active date,
    /// map range, loading, and other timeline calculations.
    private func updateHeaderDateDisplay(from frames: [Date: CGRect], viewportHeight: CGFloat) {
        let date: Date?
        if (scrollRestorer.currentMetrics?.bottomDistance ?? .infinity) < 8 {
            date = currentDates.last
        } else {
            date = headerVisibleDate(in: frames, viewportHeight: viewportHeight)
        }
        guard let date, headerVisibleDates != [date] else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            headerVisibleDates = [date]
        }
    }

    private func applyViewportDates(from frames: [Date: CGRect], viewportHeight: CGFloat) {
        if (scrollRestorer.currentMetrics?.bottomDistance ?? .infinity) < 8,
           let bottomDate = currentDates.last {
            activeTimelineDate = bottomDate
            if headerVisibleDates != [bottomDate] {
                headerVisibleDates = [bottomDate]
            }
            visibleDatesChanged([bottomDate])
            return
        }

        var mapDates = significantVisibleDates(in: frames, viewportHeight: viewportHeight)
        if let headerDate = headerVisibleDate(in: frames, viewportHeight: viewportHeight) {
            activeTimelineDate = headerDate
            if headerVisibleDates != [headerDate] {
                headerVisibleDates = [headerDate]
            }
        }
        // Keep the visible-range map behavior, but always include the date
        // currently represented by the title.
        let activeDate = Calendar.current.startOfDay(for: activeTimelineDate)
        mapDates.insert(activeDate)
        visibleDatesChanged(mapFollowsVisibleContent ? mapDates : [activeDate])
    }

    private func shouldProcessDateFrameUpdate(_ frames: [Date: CGRect], viewportHeight: CGFloat) -> Bool {
        guard latestViewportHeight > 0 else { return true }
        guard abs(latestViewportHeight - viewportHeight) <= 1 else { return true }
        guard frames.count == latestDateFrames.count,
              frames.keys.allSatisfy({ latestDateFrames[$0] != nil }) else { return true }

        let oldVisibleDates = significantVisibleDates(in: latestDateFrames, viewportHeight: latestViewportHeight)
        let newVisibleDates = significantVisibleDates(in: frames, viewportHeight: viewportHeight)
        if oldVisibleDates != newVisibleDates { return true }

        let oldHeaderDate = headerVisibleDate(in: latestDateFrames, viewportHeight: latestViewportHeight)
        let newHeaderDate = headerVisibleDate(in: frames, viewportHeight: viewportHeight)
        return oldHeaderDate != newHeaderDate
    }

    private func applySelectedCalendarDate(_ date: Date) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        activeTimelineDate = normalizedDate
        headerVisibleDates = [normalizedDate]
        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
        visibleDatesChanged([normalizedDate])
    }

    private enum MixedTimelineItem: Identifiable {
        case timelineItem(TimelineItem, Int)
        case currentStay

        var id: String {
            switch self {
            case .timelineItem(let item, _): return item.id
            case .currentStay: return "currentStay"
            }
        }

        var sortTime: Date {
            switch self {
            case .timelineItem(let item, _): return item.startTime
            case .currentStay: 
                return Date()
            }
        }
    }

    @ViewBuilder
    private func timelineDay(for date: Date) -> some View {
        let items = (timelinesByDate[date] ?? []).sorted { $0.startTime < $1.startTime }

        let mixedItems: [MixedTimelineItem] = {
            var mixed = [MixedTimelineItem]()
            for (index, item) in items.enumerated() {
                mixed.append(.timelineItem(item, index))
            }
            if Calendar.current.isDateInToday(date) {
                mixed.append(.currentStay)
            }
            mixed.sort { lhs, rhs in
                lhs.sortTime < rhs.sortTime
            }
            return mixed
        }()

        VStack(alignment: .leading, spacing: 0) {
            if date == currentDates.first {
                Color.clear
                    .frame(height: 1)
            }

            ZStack(alignment: .leading) {
                DottedTimelineSeparator()
                    .offset(y: ContinuousTimelineLayout.dateSeparatorOffset)
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
            
            ForEach(mixedItems) { mixedItem in
                switch mixedItem {
                case .timelineItem(let item, let index):
                    ContinuousTimelineRow(
                        item: item,
                        nextStartTime: items.indices.contains(index + 1) ? items[index + 1].startTime : nil,
                        activityTypes: activityTypes,
                        allPlaces: allPlaces,
                        showsContinuation: true,
                        canMergeItem: canMergeAdjacentTimelineItem(item, at: index, in: items),
                        onTap: {
                            selectedFootprintStartsExpanded = false
                            withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                                switch item {
                                case .footprint(let footprint): selectedFootprint = storedFootprint(matching: footprint)
                                case .transport(let transport): selectedTransport = transport
                                }
                            }
                        },
                        onPhotoTap: { assetID in
                            guard case .footprint(let footprint) = item else { return }
                            selectedMapPhotoAssetIDs = PhotoService.shared.displayableAssetIDs(footprint.photoAssetIDs)
                            selectedMapPhotoAssetID = assetID
                        },
                        onShowAllPhotos: {
                            guard case .footprint(let footprint) = item else { return }
                            selectedFootprintStartsExpanded = true
                            selectedFootprint = storedFootprint(matching: footprint)
                        },
                        onMerge: {
                            switch item {
                            case .footprint(let footprint):
                                pendingMergeCandidate = adjacentMergeCandidate(for: storedFootprint(matching: footprint))
                            case .transport:
                                pendingTransportMergeCandidate = adjacentTransportMergeCandidate(for: item)
                            }
                        },
                        onSplit: {
                            switch item {
                            case .footprint(let footprint):
                                footprintPendingSplit = storedFootprint(matching: footprint)
                            case .transport(let transport):
                                transportPendingSplit = transport
                            }
                        },
                        onToggleFavorite: {
                            guard case .footprint(let footprint) = item else { return }
                            toggleFavorite(for: footprint)
                        },
                        onSetImportantPlace: {
                            guard case .footprint(let footprint) = item else { return }
                            importantPlaceDraft = ImportantPlaceDraft(
                                coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
                                name: footprintDisplayTitle(for: footprint)
                            )
                        },
                        onIgnore: {
                            guard case .footprint(let footprint) = item else { return }
                            footprintPendingIgnore = footprint
                        },
                        onDelete: {
                            switch item {
                            case .footprint(let footprint): footprintPendingDeletion = footprint
                            case .transport(let transport): transportPendingDeletion = transport
                            }
                        }
                    )
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ContinuousTimelineItemFramePreferenceKey.self,
                                value: [item.id: geometry.frame(in: .named("continuousTimelineScroll"))]
                            )
                        }
                    }
                case .currentStay:
                    CurrentStayTimelineCard(locationManager: locationManager)
                        .id(ScrollTarget.now)
                        
                    if !isImportantPlaceGuideDismissed && !allPlaces.contains(where: { $0.isUserDefined }) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 18)
                            }.frame(width: 54)
                            
                            ImportantPlaceGuide(isGuideDismissed: $isImportantPlaceGuideDismissed) {
                                importantPlaceDraft = ImportantPlaceDraft()
                            }
                            .padding(.leading, -16)
                            .padding(.bottom, 14)
                        }
                    }
                }
            }

            if Calendar.current.isDateInToday(date) {
                Color.clear
                    .frame(height: 1)
                    .id(ScrollTarget.todayBottom)
            }

        }
    }

    /// An explicit destination supersedes every previously captured viewport.
    /// Data loads may finish, but their old anchors must never win afterward.
    private func beginExplicitTimelineNavigation() {
        dateFrameUpdateCoalescer.cancel()
        itemFrameUpdateCoalescer.cancel()
        layoutViewportState.anchor = nil
        mapFollowsVisibleContent = false
        latestVisibleItemIDs = []
        visibleItemIDsChanged([])
        scrollNavigationGeneration = UUID()
        isCalendarScrollLocked = true
        // From this point onward the first-launch positioning pass must never
        // be allowed to start again after the explicit destination is chosen.
        didScheduleInitialScrollToToday = true
        isPreservingViewportForEarlierLoad = false
        returnToTodayTask?.cancel()
        returnToTodayTask = nil
        initialTodayScrollTask?.cancel()
        calendarScrollRetryTask?.cancel()
        calendarScrollRetryTask = nil
        calendarScrollLockTarget = nil
        externalReloadViewportAnchor = nil
        externalReloadDateAnchor = nil
        externalReloadDateRestoreTask?.cancel()
        externalReloadDateRestoreTask = nil
        viewportAnchorBeforeBackground = nil
        activeTimelineDateBeforeBackground = nil
        timelineScrollPosition = nil
        scrollRestorer.cancelRestoration()
        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.8)
    }

    private func requestScrollToToday(
        using proxy: ScrollViewProxy,
        expandsCollapsedTimeline: Bool = true
    ) {
        if let target = targetScrollDate {
            scrollToDate(target, using: proxy)
            targetScrollDate = nil
            return
        }
        
        beginExplicitTimelineNavigation()
        let generation = scrollNavigationGeneration
        if isCollapsed && expandsCollapsedTimeline {
            withAnimation(.easeInOut(duration: 0.2)) {
                timelineDetent = .medium
            }
        }

        returnToTodayTask = Task { @MainActor in
            defer {
                if generation == scrollNavigationGeneration {
                    returnToTodayTask = nil
                    isCalendarScrollLocked = false
                }
            }
            let today = Calendar.current.startOfDay(for: Date())
            layoutViewportState.anchor = ContinuousTimelineDateAnchor(date: today, bottomOffset: 0)
            if !currentDates.contains(today) { _ = await loadDate(today, false) }
            for (index, delay) in [0, 90_000_000, 220_000_000, 420_000_000].enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                guard !Task.isCancelled, generation == scrollNavigationGeneration else { return }
                scrollToToday(using: proxy)
                // Later passes only correct lazy-layout drift. The first pass
                // is already the visible destination, so it can release the
                // map immediately instead of holding it for all retries.
                if index == 0 { isCalendarScrollLocked = false }
            }
            hasCompletedInitialTimelinePositioning = true
        }
    }

    private func scheduleInitialScrollToToday(using proxy: ScrollViewProxy) {
        initialTodayScrollTask?.cancel()
        initialTodayScrollTask = Task { @MainActor in
            // The date section is a stable lazy-list target. Align the selected
            // day's bottom to the viewport bottom so startup opens at the latest
            // point in that day.
            for delay in [0, 220_000_000, 420_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                guard !Task.isCancelled else { return }
                await positionInitialTimelineAtSelectedDateBottom(using: proxy)
            }
            guard !Task.isCancelled else { return }
            hasCompletedInitialTimelinePositioning = true
        }
    }

    private func positionInitialTimelineAtSelectedDateBottom(using proxy: ScrollViewProxy) async {
        let targetDate = Calendar.current.startOfDay(for: activeTimelineDate)
        guard currentDates.contains(targetDate) else { return }

        // Mirrors scrollToToday's target/anchor choice: when there's an ongoing stay or
        // transport, center that card in the timeline instead of pinning it to the bottom.
        let hasCurrentStatus = locationManager.isTracking && Calendar.current.isDateInToday(targetDate)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(ScrollTarget.date(targetDate), anchor: .bottom)
            if hasCurrentStatus {
                proxy.scrollTo(ScrollTarget.now, anchor: .center)
            }
        }
        applySelectedCalendarDate(targetDate)
    }

    private func scheduleInitialScrollToTodayIfNeeded(using proxy: ScrollViewProxy) {
        guard initialTimelineLoadCompleted,
              !didScheduleInitialScrollToToday,
              calendarScrollLockTarget == nil,
              isActive else { return }
        didScheduleInitialScrollToToday = true
        
        if let target = targetScrollDate {
            scrollToDate(target, using: proxy)
            targetScrollDate = nil
        } else if let anchor = layoutViewportState.anchor, currentDates.contains(anchor.date) {
            applySelectedCalendarDate(anchor.date)
            restoreDateAnchorAfterExternalReload(anchor, using: proxy)
            hasCompletedInitialTimelinePositioning = true
            return
        } else {
            scheduleInitialScrollToToday(using: proxy)
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            freezesViewportDrivenUpdatesUntil = nil
        }
    }

    private func handleFootprintSplitDismissal() {
        if let date = footprintPendingSplit?.startTime {
            invalidateAndRefreshTimeline(containing: date)
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
        }
        footprintPendingSplit = nil
    }

    private func handleTransportSplitDismissal() {
        if let date = transportPendingSplit?.startTime {
            invalidateAndRefreshTimeline(containing: date)
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
        }
        transportPendingSplit = nil
    }

    private func scrollToDate(
        _ date: Date,
        using proxy: ScrollViewProxy,
        alignToTop: Bool = true,
        prefersImmediateLoadedTarget: Bool = false
    ) {
        if isCollapsed {
            selectDateWhileCollapsed(date)
            return
        }

        beginExplicitTimelineNavigation()
        let generation = scrollNavigationGeneration
        let normalizedDate = Calendar.current.startOfDay(for: date)
        calendarScrollAlignsTargetToTop = alignToTop
        layoutViewportState.anchor = ContinuousTimelineDateAnchor(date: normalizedDate, bottomOffset: 0)

        // Lock viewport-driven date updates while the destination is loaded.
        // Do not change activeTimelineDate yet: timelineDates automatically
        // inserts that value, which would create an unloaded placeholder and
        // make the bottom-anchored ScrollView move before the real row exists.
        calendarScrollLockTarget = normalizedDate

        Task { @MainActor in
            if !currentDates.contains(normalizedDate) {
                guard await loadDate(normalizedDate, true) else {
                    if generation == scrollNavigationGeneration, calendarScrollLockTarget == normalizedDate {
                        calendarScrollLockTarget = nil
                        isCalendarScrollLocked = false
                        freezesViewportDrivenUpdatesUntil = nil
                    }
                    return
                }
            }

            // A newer calendar selection may have replaced this request while
            // the target date was loading.
            guard generation == scrollNavigationGeneration,
                  calendarScrollLockTarget == normalizedDate else { return }

            applySelectedCalendarDate(normalizedDate)
            // Start the jump in this tap's main-actor turn. The locked scroll
            // loop below already re-measures and corrects newly mounted rows,
            // so delaying every navigation for a speculative layout pass only
            // makes already-loaded adjacent dates feel unresponsive.
            scheduleLockedCalendarScroll(
                using: proxy,
                usesImmediateMountedPath: prefersImmediateLoadedTarget
            )
        }
    }

    /// A collapsed timeline is invisible. Moving its ScrollView through many
    /// lazy rows only competes with the visible map camera animation. Select
    /// and load the date now, then align the list once it is expanded again.
    private func selectDateWhileCollapsed(_ date: Date) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        scrollNavigationGeneration = UUID()
        let generation = scrollNavigationGeneration

        // Record the destination before loading. If the sheet is expanded
        // while that load is still in flight, its detent change must still
        // start the visible timeline alignment.
        collapsedTimelineDateAwaitingAlignment = normalizedDate

        returnToTodayTask?.cancel()
        initialTodayScrollTask?.cancel()
        calendarScrollRetryTask?.cancel()
        calendarScrollRetryTask = nil
        calendarScrollLockTarget = nil
        isCalendarScrollLocked = false
        dateFrameUpdateCoalescer.cancel()
        itemFrameUpdateCoalescer.cancel()
        mapFollowsVisibleContent = false
        latestVisibleItemIDs = []
        visibleItemIDsChanged([])

        Task { @MainActor in
            if !currentDates.contains(normalizedDate) {
                guard await loadDate(normalizedDate, true) else { return }
            }
            guard generation == scrollNavigationGeneration else { return }

            layoutViewportState.anchor = ContinuousTimelineDateAnchor(date: normalizedDate, bottomOffset: 0)
            applySelectedCalendarDate(normalizedDate)
            hasCompletedInitialTimelinePositioning = true
        }
    }

    private func currentDateAnchor() -> ContinuousTimelineDateAnchor? {
        let date = Calendar.current.startOfDay(for: activeTimelineDate)
        guard rawDateFrames.viewportHeight > 0, let frame = rawDateFrames.frames[date] else { return nil }
        return ContinuousTimelineDateAnchor(date: date, bottomOffset: frame.maxY - rawDateFrames.viewportHeight)
    }

    private func restoreDateAnchorAfterExternalReload(_ anchor: ContinuousTimelineDateAnchor, using proxy: ScrollViewProxy) {
        externalReloadDateRestoreTask?.cancel()
        let generation = scrollNavigationGeneration
        freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.8)
        externalReloadDateRestoreTask = Task { @MainActor in
            // Rebuilt rows settle over a few layout passes; realign the same
            // row edge after each one instead of trusting the old offset.
            for delay in [0, 80_000_000, 160_000_000, 240_000_000] {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay)) }
                guard !Task.isCancelled,
                      generation == scrollNavigationGeneration,
                      calendarScrollLockTarget == nil,
                      !scrollRestorer.isUserInteracting,
                      rawDateFrames.dates.contains(anchor.date) else { return }

                if let frame = rawDateFrames.frames[anchor.date], rawDateFrames.viewportHeight > 0 {
                    let delta = frame.maxY - (rawDateFrames.viewportHeight + anchor.bottomOffset)
                    if abs(delta) > 1 { scrollRestorer.offset(by: delta) }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(ScrollTarget.date(anchor.date), anchor: .bottom)
                    }
                }
            }
            guard !Task.isCancelled, generation == scrollNavigationGeneration else { return }
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.25)
        }
    }

    /// Signed content-offset step that moves the viewport toward an unmounted
    /// target row, sized from the measured height of the rows that are
    /// mounted now rather than from SwiftUI's estimates.
    private func calendarSeekStep(toward target: Date, mountedFrames: [Date: CGRect], viewportHeight: CGFloat) -> CGFloat? {
        guard let targetIndex = currentDates.firstIndex(of: target) else { return nil }
        let mounted = mountedFrames
            .compactMap { date, frame in currentDates.firstIndex(of: date).map { (index: $0, frame: frame) } }
            .sorted { $0.index < $1.index }
        guard let first = mounted.first, let last = mounted.last else { return nil }

        let averageHeight = max(80, mounted.map(\.frame.height).reduce(0, +) / CGFloat(mounted.count))
        if targetIndex < first.index {
            // Target is above: bring its estimated bottom to the viewport bottom.
            let rowsBetween = CGFloat(first.index - targetIndex - 1)
            let estimatedTargetMaxY = first.frame.minY - rowsBetween * averageHeight
            return min(-1, estimatedTargetMaxY - viewportHeight)
        }
        if targetIndex > last.index {
            let rowsBetween = CGFloat(targetIndex - last.index - 1)
            let estimatedTargetMaxY = last.frame.maxY + rowsBetween * averageHeight + averageHeight
            return max(1, estimatedTargetMaxY - viewportHeight)
        }
        // Target sits between mounted rows but is not mounted itself
        // (e.g. still being laid out); nudge through the nearest neighbour.
        let upper = mounted.last { $0.index < targetIndex }
        return upper.map { max(1, $0.frame.maxY + averageHeight - viewportHeight) }
    }

    private func scheduleLockedCalendarScroll(
        using proxy: ScrollViewProxy,
        usesImmediateMountedPath: Bool = false
    ) {
        guard let target = calendarScrollLockTarget else { return }
        guard calendarScrollRetryTask == nil else { return }

        let generation = scrollNavigationGeneration
        let alignsToTop = calendarScrollAlignsTargetToTop
        calendarScrollRetryTask = Task { @MainActor in
            defer {
                if generation == scrollNavigationGeneration { calendarScrollRetryTask = nil }
            }

            guard !Task.isCancelled,
                  generation == scrollNavigationGeneration,
                  calendarScrollLockTarget == target else { return }

            applySelectedCalendarDate(target)

            // Previous/next navigation always targets an already loaded,
            // neighbouring day. Do not send that common path through the
            // distant-date 40-pass seek loop: after many historical days are
            // loaded, repeatedly measuring the large LazyVStack is the hitch
            // the user feels after tapping an arrow.
            if usesImmediateMountedPath {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(
                        alignsToTop ? ScrollTarget.dateLine(target) : ScrollTarget.date(target),
                        anchor: alignsToTop ? .top : .bottom
                    )
                }

                // One next-run-loop correction is enough for a neighbouring
                // row that was just mounted. It also avoids keeping the date
                // lock alive for the old minimum of six 50 ms passes.
                await Task.yield()
                guard !Task.isCancelled,
                      generation == scrollNavigationGeneration,
                      calendarScrollLockTarget == target else { return }
                // Immediately after launch the neighbouring day can be in the
                // loaded data but not yet mounted by LazyVStack. In that case
                // ScrollViewProxy has only issued an estimated jump; unlocking
                // here loses the destination entirely. Finish quickly only
                // after the target row actually exists. Otherwise retain the
                // lock and fall through to the measured seek path below.
                let viewportHeight = rawDateFrames.viewportHeight
                if let targetFrame = rawDateFrames.frames[target],
                   viewportHeight > 0,
                   targetFrame.maxY > 0,
                   targetFrame.minY < viewportHeight {
                    withTransaction(transaction) {
                        proxy.scrollTo(
                            alignsToTop ? ScrollTarget.dateLine(target) : ScrollTarget.date(target),
                            anchor: alignsToTop ? .top : .bottom
                        )
                    }

                    dateFrameUpdateCoalescer.cancel()
                    itemFrameUpdateCoalescer.cancel()
                    hasCompletedInitialTimelinePositioning = true
                    timelineScrollPosition = nil
                    calendarScrollLockTarget = nil
                    isCalendarScrollLocked = false
                    applySelectedCalendarDate(target)
                    visibleDatesChanged([target])
                    return
                }
            }

            // LazyVStack positions rows it has never rendered from an average
            // of the rows it has measured. A day whose real height is far from
            // that average (very sparse or very dense) makes scrollTo land on
            // a neighbouring day, and only on the first visit, since the row
            // is measured afterwards. So scrollTo is used only to bring the
            // target near the viewport; the final position is corrected from
            // the target row's real frame, directly on the UIScrollView.
            let startsMounted = rawDateFrames.frames[target] != nil
            if startsMounted {
                if alignsToTop {
                    // Start at the date line itself; the section ID also
                    // covers gap controls above it.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(ScrollTarget.dateLine(target), anchor: .top)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                } else {
                    // Bottom-aligned restoration retains its existing motion.
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(ScrollTarget.date(target), anchor: .bottom)
                    }
                    try? await Task.sleep(nanoseconds: 420_000_000)
                }
            } else {
                // Animating across unmeasured rows is what drifted. Jump
                // directly; the correction below then aligns real geometry.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(ScrollTarget.date(target), anchor: alignsToTop ? .top : .bottom)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            // ScrollViewProxy resolves an unmounted row from SwiftUI's own
            // height estimates; once those are wrong, repeated scrollTo calls
            // do not move at all (observed: the list stays on a later day
            // while scrollTo keeps reporting success). Seek from measured
            // geometry instead: step toward the target using the real height
            // of the mounted rows, re-measure, and align precisely once the
            // target row itself is mounted.
            var stableAlignmentPasses = 0
            // Where SwiftUI's own `.top` alignment puts a row, measured in the
            // row coordinate space. UIKit insets do not share that space.
            var visibleTop: CGFloat?
            var isMeasuringVisibleTop = startsMounted && alignsToTop
            for _ in 0..<40 {
                guard !Task.isCancelled,
                      generation == scrollNavigationGeneration,
                      calendarScrollLockTarget == target else { return }
                // A toolbar tap can arrive while the ScrollView is still
                // reporting the tail of a previous deceleration. That is not
                // the user taking over this new jump. Wait for it to end;
                // breaking here used to mark an unperformed jump as complete.
                if scrollRestorer.isUserInteracting {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                let frames = rawDateFrames.frames
                let viewportHeight = rawDateFrames.viewportHeight
                guard viewportHeight > 0 else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                let offsetBefore = scrollRestorer.currentMetrics?.contentOffsetY
                var attemptedOffset = false

                if alignsToTop, frames[target] != nil, visibleTop == nil, !isMeasuringVisibleTop {
                    stableAlignmentPasses = 0
                    isMeasuringVisibleTop = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(ScrollTarget.dateLine(target), anchor: .top)
                    }
                } else if let frame = frames[target] {
                    if alignsToTop, isMeasuringVisibleTop {
                        visibleTop = frame.minY
                        isMeasuringVisibleTop = false
                    }
                    let delta: CGFloat
                    if alignsToTop, let visibleTop {
                        // The date line is drawn inside the row's top edge;
                        // keep the row where SwiftUI's `.top` alignment put it
                        // while rows above it finish measuring.
                        delta = frame.minY - visibleTop
                    } else {
                        let bottomInset = scrollRestorer.currentMetrics?.adjustedBottomInset ?? 0
                        delta = frame.maxY - (viewportHeight - bottomInset)
                    }
                    if abs(delta) <= 2 {
                        stableAlignmentPasses += 1
                        // Keep the remaining passes as silent alignment checks,
                        // but do not make the map wait after the timeline has
                        // visibly reached its destination.
                        if stableAlignmentPasses == 1 {
                            isCalendarScrollLocked = false
                        }
                        if stableAlignmentPasses >= 6 { break }
                    } else {
                        stableAlignmentPasses = 0
                        attemptedOffset = true
                        scrollRestorer.offset(by: delta)
                    }
                } else if let step = calendarSeekStep(toward: target, mountedFrames: frames, viewportHeight: viewportHeight) {
                    stableAlignmentPasses = 0
                    attemptedOffset = true
                    scrollRestorer.offset(by: step)
                } else {
                    stableAlignmentPasses = 0
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(ScrollTarget.date(target), anchor: alignsToTop ? .top : .bottom)
                    }
                }

                // Clamped at a content edge: as close as the list allows.
                if attemptedOffset,
                   let offsetBefore,
                   offsetBefore == scrollRestorer.currentMetrics?.contentOffsetY,
                   frames[target] != nil {
                    break
                }
                // Let rows at the new offset mount and report real frames.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled,
                  generation == scrollNavigationGeneration,
                  calendarScrollLockTarget == target else { return }

            hasCompletedInitialTimelinePositioning = true
            let settledTarget = target
            dateFrameUpdateCoalescer.cancel()
            itemFrameUpdateCoalescer.cancel()
            timelineScrollPosition = nil
            calendarScrollLockTarget = nil
            isCalendarScrollLocked = false
            applySelectedCalendarDate(settledTarget)
            visibleDatesChanged([settledTarget])
        }
    }

    private func scrollToToday(using proxy: ScrollViewProxy, animated: Bool = true) {
        let today = Calendar.current.startOfDay(for: Date())
        guard currentDates.contains(today) else { return }
        applySelectedCalendarDate(today)
        let hasCurrentStatus = locationManager.isTracking
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

    private func requestLoadEarlierDates() {
        guard !isLoadingMoreEarlier else { return }

        let generation = scrollNavigationGeneration
        Task { @MainActor in
            guard generation == scrollNavigationGeneration else { return }
            isLoadingMoreEarlier = true
            isPreservingViewportForEarlierLoad = true
            defer {
                isLoadingMoreEarlier = false
                isPreservingViewportForEarlierLoad = false
                freezesViewportDrivenUpdatesUntil = nil
            }
            timelineScrollPosition = nil
            freezesViewportDrivenUpdatesUntil = Date.distantFuture
            let anchorBeforeLoading = scrollRestorer.captureAnchor()
            let bottomDistanceBeforeLoading = anchorBeforeLoading?.bottomDistance
                ?? scrollRestorer.currentMetrics?.bottomDistance
                ?? 0
            scrollRestorer.beginContinuousRestoration(
                anchorBeforeLoading,
                fallbackBottomDistance: bottomDistanceBeforeLoading
            )
            let didLoad = await loadEarlierDates()
            guard generation == scrollNavigationGeneration else {
                scrollRestorer.cancelRestoration()
                return
            }

            if didLoad {
                // Inserting history above the viewport increases content height.
                // Restore the previous offset plus that height so the rows under
                // the user's finger remain visually fixed.
                scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
                for _ in 0..<30 where scrollRestorer.isRestoring {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                guard generation == scrollNavigationGeneration else {
                    scrollRestorer.cancelRestoration()
                    return
                }
                if scrollRestorer.isRestoring {
                    scrollRestorer.cancelRestoration()
                }
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            } else {
                scrollRestorer.cancelRestoration()
            }
        }
    }

    private func requestLoadLaterDates() {
        guard !isLoadingMoreLater else { return }

        let generation = scrollNavigationGeneration
        Task { @MainActor in
            guard generation == scrollNavigationGeneration else { return }
            isLoadingMoreLater = true
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadLaterDates()
            isLoadingMoreLater = false
            guard generation == scrollNavigationGeneration else { return }
            freezesViewportDrivenUpdatesUntil = nil
            if !didLoad {
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        }
    }

    private func requestLoadDates(after earlierDate: Date, before laterDate: Date) {
        let calendar = Calendar.current
        let normalizedEarlierDate = calendar.startOfDay(for: earlierDate)
        guard !loadingGapAfterDates.contains(normalizedEarlierDate) else { return }
        let datesToLoad = Array(loadableTimelineDates(between: earlierDate, and: laterDate).prefix(gapLoadBatchSize))
        guard !datesToLoad.isEmpty else { return }

        let generation = scrollNavigationGeneration
        Task { @MainActor in
            guard generation == scrollNavigationGeneration else { return }
            loadingGapAfterDates.insert(normalizedEarlierDate)
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadGapDates(datesToLoad)
            loadingGapAfterDates.remove(normalizedEarlierDate)
            guard generation == scrollNavigationGeneration else { return }
            freezesViewportDrivenUpdatesUntil = nil
            if !didLoad {
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        }
    }

    private func requestLoadDates(before laterDate: Date, after earlierDate: Date) {
        let calendar = Calendar.current
        let normalizedLaterDate = calendar.startOfDay(for: laterDate)
        guard !loadingGapBeforeDates.contains(normalizedLaterDate) else { return }
        let datesToLoad = Array(loadableTimelineDates(between: earlierDate, and: laterDate).suffix(gapLoadBatchSize))
        guard !datesToLoad.isEmpty else { return }

        let generation = scrollNavigationGeneration
        Task { @MainActor in
            guard generation == scrollNavigationGeneration else { return }
            loadingGapBeforeDates.insert(normalizedLaterDate)
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let anchorBeforeLoading = scrollRestorer.captureAnchor()
            let bottomDistanceBeforeLoading = anchorBeforeLoading?.bottomDistance
                ?? scrollRestorer.currentMetrics?.bottomDistance
                ?? 0
            scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
            let didLoad = await loadGapDates(datesToLoad)
            loadingGapBeforeDates.remove(normalizedLaterDate)
            guard generation == scrollNavigationGeneration else { return }
            if didLoad {
                scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 340_000_000)
                    guard generation == scrollNavigationGeneration, !scrollRestorer.isRestoring else { return }
                    freezesViewportDrivenUpdatesUntil = nil
                    applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
                }
            } else {
                freezesViewportDrivenUpdatesUntil = nil
                applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
            }
        }
    }

    private func canMergeAdjacentTimelineItem(_ item: TimelineItem, at index: Int, in items: [TimelineItem]) -> Bool {
        switch item {
        case .footprint(let footprint):
            return adjacentFootprintForMerge(around: footprint, at: index, in: items) != nil
        case .transport(let transport):
            return adjacentTransportForMerge(around: transport, at: index, in: items) != nil
        }
    }

    private func adjacentFootprintForMerge(around footprint: Footprint, at index: Int, in items: [TimelineItem]) -> Footprint? {
        if let previousItem = items[safe: index - 1],
           case .footprint(let previousFootprint) = previousItem,
           canMergeAdjacentFootprintSnapshots(previousFootprint, footprint) {
            return previousFootprint
        }

        if let nextItem = items[safe: index + 1],
           case .footprint(let nextFootprint) = nextItem,
           canMergeAdjacentFootprintSnapshots(footprint, nextFootprint) {
            return nextFootprint
        }

        return nil
    }

    private func adjacentTransportForMerge(around transport: Transport, at index: Int, in items: [TimelineItem]) -> Transport? {
        if let previousItem = items[safe: index - 1],
           case .transport(let previousTransport) = previousItem,
           canMergeAdjacentTransportSnapshots(previousTransport, transport) {
            return previousTransport
        }

        if let nextItem = items[safe: index + 1],
           case .transport(let nextTransport) = nextItem,
           canMergeAdjacentTransportSnapshots(transport, nextTransport) {
            return nextTransport
        }

        return nil
    }

    private func canMergeAdjacentFootprintSnapshots(_ first: Footprint, _ second: Footprint) -> Bool {
        guard first.status != .ignored, second.status != .ignored else { return false }
        guard first.footprintID != second.footprintID else { return false }
        guard Calendar.current.isDate(first.startTime, inSameDayAs: first.endTime.addingTimeInterval(-0.001)) else { return false }
        guard Calendar.current.isDate(second.startTime, inSameDayAs: second.endTime.addingTimeInterval(-0.001)) else { return false }
        return Calendar.current.isDate(first.startTime, inSameDayAs: second.startTime)
    }

    private func canMergeAdjacentTransportSnapshots(_ first: Transport, _ second: Transport) -> Bool {
        guard first.id != second.id else { return false }
        return Calendar.current.isDate(first.startTime, inSameDayAs: second.startTime)
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
        base.allowsAutomaticDurationExtension = true
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
        modelContext.delete(other)
        try? modelContext.save()
        Footprint.resumeMergedCurrentStay(base, context: modelContext)
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        invalidateTimelineAfterMerge(start: mergedStart, end: base.endTime)
        Aptabase.shared.trackEvent("footprint_adjacent_merged")
    }

    private func mergeAdjacentTransports(_ candidate: ContinuousAdjacentTransportMergeCandidate) {
        let base = candidate.first
        let other = candidate.second
        let mergedStart = min(base.startTime, other.startTime)
        let mergedEnd = max(base.endTime, other.endTime)

        base.day = Calendar.current.startOfDay(for: mergedStart)
        base.startTime = mergedStart
        base.endTime = mergedEnd
        base.distance += other.distance
        let mergedDuration = mergedEnd.timeIntervalSince(mergedStart)
        base.averageSpeed = mergedDuration > 0 ? base.distance / mergedDuration : 0
        base.stepCount = combinedOptionalSum(base.stepCount, other.stepCount)

        // A user-initiated merge owns the resulting interval.  Persist that
        // ownership even if neither source segment had its type edited before;
        // otherwise the periodic timeline sifter treats the merged record as
        // automatic data and can split/reclassify it on a later launch.
        let explicitlySelectedType = base.manualTypeRaw ?? other.manualTypeRaw

        if !other.endLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           other.endLocation != "终点",
           other.endLocation != "正在获取位置..." {
            base.endLocation = other.endLocation
        }

        let mergedPoints = decodedTransportPoints(base) + decodedTransportPoints(other)
        if let pointsData = try? JSONEncoder().encode(mergedPoints) {
            base.pointsData = pointsData
        }
        let observedCount = mergedPoints.filter { $0.isSyntheticPadding != true && $0.timestamp != nil }.count
        let inferredType = TransportType.from(
            speed: base.averageSpeed,
            stepCount: base.stepCount ?? 0,
            duration: mergedDuration,
            distanceMeters: base.distance,
            pointCount: mergedPoints.count,
            observedPointCount: observedCount
        )
        base.typeRaw = explicitlySelectedType ?? inferredType.rawValue
        base.manualTypeRaw = base.typeRaw // Preserve the manual merge boundary during timeline rebuilding.

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

private struct ContinuousTimelineItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private struct ContinuousTimelineDateAnchor {
    let date: Date
    /// Row bottom relative to the viewport bottom (positive = below it).
    let bottomOffset: CGFloat
}

/// Owned above the portrait-sheet/landscape-sidebar branches. Geometry writes
/// do not invalidate the view, and remounts retain the last stable viewport.
@MainActor
private final class ContinuousTimelineLayoutViewportState {
    var anchor: ContinuousTimelineDateAnchor?
}

private final class ContinuousTimelineRawDateFrames {
    var frames: [Date: CGRect] = [:]
    var viewportHeight: CGFloat = 0
    private var lastViewportResizeTime = Date.distantPast
    /// Latest rendered date list; see `TimelineView.currentDates`.
    var dates: [Date] = []

    var isViewportResizing: Bool {
        Date().timeIntervalSince(lastViewportResizeTime) < 0.12
    }

    func update(frames: [Date: CGRect], viewportHeight: CGFloat) {
        if self.viewportHeight > 0, abs(self.viewportHeight - viewportHeight) > 1 {
            lastViewportResizeTime = Date()
        }
        self.frames = frames
        self.viewportHeight = viewportHeight
    }
}

@MainActor
private final class ContinuousTimelineDateFrameUpdateCoalescer {
    private var task: Task<Void, Never>?
    private var pendingUpdate: (@MainActor (Bool) -> Void)?
    private var pendingUserInteraction = false
    private var isInteractionActive: (@MainActor () -> Bool)?
    private var latestScheduleTime = Date.distantPast

    func schedule(
        userWasInteracting: Bool,
        isInteractionActive: @escaping @MainActor () -> Bool,
        _ update: @escaping @MainActor (Bool) -> Void
    ) {
        pendingUpdate = update
        pendingUserInteraction = pendingUserInteraction || userWasInteracting
        self.isInteractionActive = isInteractionActive
        latestScheduleTime = Date()
        // Crossing a date boundary can publish many geometry snapshots. Keep
        // one waiter alive and only replace its payload; repeatedly cancelling
        // and creating main-actor tasks causes a visible hitch while scrolling.
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isInteractionActive?() == true { continue }
                if Date().timeIntervalSince(self.latestScheduleTime) < 0.12 { continue }
                break
            }
            guard !Task.isCancelled, let self else { return }
            let latestUpdate = self.pendingUpdate
            let userWasInteracting = self.pendingUserInteraction
            self.pendingUpdate = nil
            self.pendingUserInteraction = false
            self.isInteractionActive = nil
            self.task = nil
            latestUpdate?(userWasInteracting)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingUpdate = nil
        pendingUserInteraction = false
        isInteractionActive = nil
        latestScheduleTime = .distantPast
    }
}

private struct ContinuousTimelineScrollMetrics: Equatable {
    var topOffsetY: CGFloat = .infinity
    var contentOffsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var adjustedTopInset: CGFloat = 0
    var adjustedBottomInset: CGFloat = 0
    var isUserInteracting: Bool = false

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.restorer = restorer
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(from: uiView)
        }
    }

    final class Coordinator {
        var restorer = ContinuousTimelineScrollRestorer()
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        func attachIfNeeded(from view: UIView) {
            guard scrollView == nil else { return }
            guard let scrollView = view.enclosingScrollView() else { return }

            self.scrollView = scrollView
            restorer.attach(scrollView)
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.restorer.recordUserInteractionIfNeeded()
            }
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                self?.restorer.applyPendingBottomDistanceIfNeeded()
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
                self?.restorer.applyPendingBottomDistanceIfNeeded()
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
    private(set) var lastUserInteractionTime = Date.distantPast

    var currentMetrics: ContinuousTimelineScrollMetrics? {
        guard let scrollView else { return nil }
        return ContinuousTimelineScrollMetrics(
            topOffsetY: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom,
            isUserInteracting: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
        )
    }

    var isUserInteracting: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
    }

    func recordUserInteractionIfNeeded() {
        if isUserInteracting {
            lastUserInteractionTime = Date()
        }
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

    func cancelRestoration() {
        restoreTask?.cancel()
        restoreTask = nil
        pendingAnchor = nil
        pendingFallbackBottomDistance = nil
        isRestoring = false
    }

    /// Keep compensating for every content-size change until the caller
    /// explicitly replaces or cancels this restoration. This is used while an
    /// async prepend may publish cached and fetched rows at different times.
    func beginContinuousRestoration(_ anchor: ContinuousTimelineScrollAnchor?, fallbackBottomDistance: CGFloat) {
        restoreTask?.cancel()
        restoreTask = nil
        pendingAnchor = anchor
        pendingFallbackBottomDistance = fallbackBottomDistance
        isRestoring = true
        applyPendingBottomDistanceIfNeeded()
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
        // Scrolling changes `bounds`, which re-enters here. A restoration left
        // running (e.g. one begun on leaving the foreground) must never pin the
        // viewport against the user's finger; their scroll supersedes it.
        if isUserInteracting {
            cancelRestoration()
            return
        }
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
        // A bottom viewport must follow the actual bottom, including changed
        // sheet height and safe-area insets during foreground layout.
        if anchor.bottomDistance < 8 {
            applyBottomDistance(anchor.bottomDistance)
            return
        }
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

enum ContinuousTimelineLayout {
    static let timeColumnWidth: CGFloat = 48
    static let dateColumnWidth: CGFloat = 64
    static let markerSpacing: CGFloat = 12
    static let markerSize: CGFloat = 26
    static let markerCenterX = timeColumnWidth + markerSpacing + markerSize / 2
    static let minItemSpacing: CGFloat = 12
    static let maxItemSpacing: CGFloat = 160
    static let photoThumbnailSize: CGFloat = 58
    static let multiPhotoGridMaxWidth: CGFloat = 252
    static let dateSeparatorOffset: CGFloat = -12
    static let lineColor = Color.secondary.opacity(0.35)
}

struct TimelineFootprintMarker: View {
    let icon: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
            Circle()
                .fill(LinearGradient(colors: [tint.lighter(by: 0.25), tint], startPoint: .top, endPoint: .bottom))
                .padding(2.5)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: ContinuousTimelineLayout.markerSize, height: ContinuousTimelineLayout.markerSize)
    }
}

struct TimelineTransportMarker: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.dfkAccent)
            .frame(width: ContinuousTimelineLayout.markerSize - 4, height: ContinuousTimelineLayout.markerSize - 4)
            .background(Color(uiColor: .systemBackground), in: Circle())
            .overlay(Circle().strokeBorder(Color.dfkAccent, lineWidth: 1.2))
            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
    }
}

private struct DottedTimelineSeparator: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
            }
            .stroke(
                Color.secondary.opacity(0.38),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        .frame(height: 2)
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
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager

    let item: TimelineItem
    let nextStartTime: Date?
    let activityTypes: [ActivityType]
    let allPlaces: [Place]
    let showsContinuation: Bool
    let canMergeItem: Bool
    let onTap: () -> Void
    let onPhotoTap: (String) -> Void
    let onShowAllPhotos: () -> Void
    let onMerge: () -> Void
    let onSplit: () -> Void
    let onToggleFavorite: () -> Void
    let onSetImportantPlace: () -> Void
    let onIgnore: () -> Void
    let onDelete: () -> Void
    @State private var isResolvingUnknownPlace = false
    @State private var isPlaceTitleBreathing = false
    @State private var activityPickerPresentation: ActivityPickerPresentation?
    @State private var displayablePhotoAssetIDs: [String] = []
    @State private var didResolvePhotoAssetIDs = false
    @State private var didRequestPhotoLink = false

    var body: some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(item.startTime.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(item.isTransport ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 4)

            VStack(spacing: 0) {
                if case .footprint = item {
                    Button {
                        prepareActivityPicker()
                    } label: {
                        timelineMarker
                    }
                    .buttonStyle(.plain)
                    .popover(item: $activityPickerPresentation) { presentation in
                        StableActivityPickerPopover(
                            suggestedItems: presentation.suggestedItems,
                            allItems: presentation.allItems,
                            onSelect: applyActivityType
                        )
                    }
                } else if case .transport(let transport) = item {
                    Menu {
                        ForEach(TransportType.allCases, id: \.self) { type in
                            Button {
                                let tid = transport.id
                                let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == tid })
                                if let record = try? modelContext.fetch(descriptor).first {
                                    record.manualTypeRaw = type.rawValue
                                    try? modelContext.save()
                                }
                            } label: {
                                Label(type.localizedName, systemImage: type.icon)
                            }
                        }
                    } label: {
                        timelineMarker
                    }
                    .buttonStyle(.plain)
                }
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

            VStack(alignment: .leading, spacing: 8) {
                if item.isTransport {
                    Text(transportLineText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTap)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(titleFont)
                            .foregroundStyle(titleStyle)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(isResolvingUnknownPlace && isPlaceTitleBreathing ? 0.38 : 1)
                            .scaleEffect(isResolvingUnknownPlace && isPlaceTitleBreathing ? 0.985 : 1, anchor: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                }

                if !timelinePhotoAssetIDs.isEmpty {
                    TimelinePhotoGrid(
                        assetIDs: timelinePhotoAssetIDs,
                        onPhotoTap: onPhotoTap,
                        onOverflowTap: onShowAllPhotos
                    )
                }
            }
            .padding(.bottom, bottomSpacing)
        }
        .frame(minHeight: 52, alignment: .top)
        .task(id: unresolvedFootprintID) {
            await retryUnknownFootprintLocationIfNeeded()
        }
        .task(id: photoAssetIDs) {
            didResolvePhotoAssetIDs = false
            displayablePhotoAssetIDs = PhotoService.shared.displayableAssetIDs(photoAssetIDs)
            didResolvePhotoAssetIDs = true
        }
        .onAppear {
            // Same as FootprintCardView: associate photos taken (or synced)
            // after the footprint was saved, so rows show them and photo
            // import excludes them, without opening the detail first.
            if !didRequestPhotoLink, case .footprint(let footprint) = item {
                didRequestPhotoLink = true
                locationManager.linkPhotos(to: footprint, context: modelContext)
            }
        }
        .onChange(of: isResolvingUnknownPlace) { _, isResolving in
            guard isResolving else {
                isPlaceTitleBreathing = false
                return
            }
            isPlaceTitleBreathing = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPlaceTitleBreathing = true
            }
        }
        .contextMenu {
            if case .footprint(let footprint) = item {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(footprint.isHighlight == true ? "取消收藏" : "收藏", systemImage: footprint.isHighlight == true ? "star.slash" : "star.fill")
                }

                if !allPlaces.contains(where: { place in
                    guard place.isUserDefined else { return false }
                    if place.placeID == footprint.placeID { return true }
                    let address = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return !address.isEmpty && (
                        place.name.trimmingCharacters(in: .whitespacesAndNewlines) == address ||
                        place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == address
                    )
                }) {
                    Button(action: onSetImportantPlace) {
                        Label("设为重要地点", systemImage: "mappin.and.ellipse")
                    }
                }

                Divider()
            }

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
            }

            if case .transport = item {
                Button {
                    onSplit()
                } label: {
                    Label("拆分交通", systemImage: "slider.horizontal.below.square.filled.and.square")
                }
            }

            Button {
                onTap()
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            if case .footprint = item {
                Button {
                    onIgnore()
                } label: {
                    Label("忽略地点", systemImage: "mappin.slash")
                }
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var timelineMarker: some View {
        if case .footprint = item {
            TimelineFootprintMarker(icon: icon, tint: tint)
        } else {
            TimelineTransportMarker(icon: icon)
        }
    }

    private func prepareActivityPicker() {
        guard case .footprint(let footprint) = item else { return }
        let allItems = activityTypes.map {
            StableActivityPickerItem(id: $0.id, name: $0.name, icon: $0.icon)
        }
        let suggestions = ActivityType.getSuggestedActivities(
            for: footprint,
            allActivities: activityTypes.map { $0.convertToLite() },
            allPlaces: allPlaces.map { $0.convertToLite() },
            includeFallback: false
        )
        let suggestedItems = suggestions.compactMap { suggestion in
            allItems.first { $0.id == suggestion.id }
        }
        activityPickerPresentation = ActivityPickerPresentation(suggestedItems: suggestedItems, allItems: allItems)
    }

    private func applyActivityType(_ id: UUID?) {
        guard case .footprint(let footprint) = item else { return }
        footprint.updateActivityType(to: id?.uuidString, in: modelContext)
        try? modelContext.save()
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
        item.isTransport ? ContinuousTimelineLayout.markerSize - 4 : ContinuousTimelineLayout.markerSize
    }

    private var markerIconFont: Font {
        item.isTransport ? .system(size: 9, weight: .bold) : .caption.weight(.bold)
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

    private var photoAssetIDs: [String] {
        guard case .footprint(let footprint) = item else { return [] }
        return footprint.photoAssetIDs
    }

    /// LazyVStack may recreate an off-screen row. Keep its photo layout present
    /// while the displayable-ID check runs so recycling the row cannot collapse
    /// and then expand its height.
    private var timelinePhotoAssetIDs: [String] {
        didResolvePhotoAssetIDs ? displayablePhotoAssetIDs : photoAssetIDs
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

    private var unresolvedFootprintID: UUID? {
        guard case .footprint(let footprint) = item else { return nil }
        let address = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let unresolvedValues: Set<String> = ["", "未知位置", "未知地点", "地点记录", "正在解析位置...", "此处"]
        return unresolvedValues.contains(address) ? footprint.footprintID : nil
    }

    @MainActor
    private func retryUnknownFootprintLocationIfNeeded() async {
        guard let unresolvedFootprintID,
              case .footprint(let footprint) = item else { return }

        isResolvingUnknownPlace = true
        defer { isResolvingUnknownPlace = false }

        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        // A timeline item that still says “未知位置” is a historical Apple
        // miss. Go straight to OSM so a stalled Apple callback cannot leave
        // the breathing indicator running forever.
        guard let resolvedAddress = await OpenStreetMapGeocoder.shared.lookup(coordinate: coordinate)?.address,
              !resolvedAddress.isEmpty else { return }

        // The row may have been recycled while awaiting a response. Re-fetch by
        // stable ID before mutating so the result never lands on another row.
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == unresolvedFootprintID })
        if let persistedFootprint = try? modelContext.fetch(descriptor).first {
            persistedFootprint.address = resolvedAddress
            try? modelContext.save()
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

struct ContinuousTimelinePhotoThumbnail: View {
    /// All of the footprint's photos; the thumbnail shows the latest taken.
    let assetIDs: [String]
    var targetSide: CGFloat = ContinuousTimelineLayout.photoThumbnailSize
    var fitsOriginalAspectRatio = false
    var onImageSizeChange: ((CGSize) -> Void)? = nil
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var requestGeneration = UUID()

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fitsOriginalAspectRatio ? .fit : .fill)
            } else {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(
            fitsOriginalAspectRatio ? originalAspectRatio : 1,
            contentMode: .fit
        )
        .clipped()
        .task(id: assetIDs) {
            requestThumbnail()
        }
        .onDisappear {
            cancelRequest()
            image = nil
        }
    }

    private var originalAspectRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 4 / 3 }
        return image.size.width / image.size.height
    }

    private func requestThumbnail() {
        cancelRequest()
        image = nil
        let generation = UUID()
        requestGeneration = generation

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        guard let asset = PhotoService.shared.latestAsset(among: assetIDs) else { return }

        let side = targetSide * (fitsOriginalAspectRatio ? 3 : 2)
        let qualityKey = fitsOriginalAspectRatio ? "high-v2" : "fast"
        let cacheKey = "\(asset.localIdentifier)|\(Int(side.rounded()))|\(fitsOriginalAspectRatio ? "fit" : "fill")|\(qualityKey)"
        if let cached = TimelinePhotoThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            onImageSizeChange?(cached.size)
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = fitsOriginalAspectRatio ? .highQualityFormat : .fastFormat
        options.resizeMode = fitsOriginalAspectRatio ? .exact : .fast
        options.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        requestID = manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: fitsOriginalAspectRatio ? .aspectFit : .aspectFill,
            options: options
        ) { thumbnail, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }

            DispatchQueue.main.async {
                guard self.requestGeneration == generation else { return }
                if let thumbnail {
                    TimelinePhotoThumbnailCache.shared.setImage(thumbnail, for: cacheKey)
                    self.image = thumbnail
                    self.onImageSizeChange?(thumbnail.size)
                }
                self.requestID = nil
            }
        }
    }

    private func cancelRequest() {
        requestGeneration = UUID()
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            self.requestID = nil
        }
    }
}

@MainActor
private final class TimelinePhotoThumbnailCache {
    static let shared = TimelinePhotoThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    private let aspectRatios = NSCache<NSString, NSNumber>()

    private init() {
        images.countLimit = 72
        images.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: key as NSString, cost: cost)
    }

    func aspectRatio(for assetID: String) -> CGFloat? {
        aspectRatios.object(forKey: assetID as NSString).map { CGFloat(truncating: $0) }
    }

    func setAspectRatio(_ aspectRatio: CGFloat, for assetID: String) {
        aspectRatios.setObject(NSNumber(value: Double(aspectRatio)), forKey: assetID as NSString)
    }
}

struct TimelinePhotoGrid: View {
    let assetIDs: [String]
    let onPhotoTap: (String) -> Void
    let onOverflowTap: () -> Void
    @State private var measuredSinglePhotoAspectRatio: CGFloat?

    private var columns: [GridItem] {
        let count = assetIDs.count == 1 || assetIDs.count == 4 ? 2 : min(3, assetIDs.count)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    private var visibleAssetIDs: [String] { Array(assetIDs.prefix(9)) }

    var body: some View {
        Group {
            if let assetID = assetIDs.first, assetIDs.count == 1 {
                Button {
                    onPhotoTap(assetID)
                } label: {
                    ContinuousTimelinePhotoThumbnail(
                        assetIDs: [assetID],
                        targetSide: 300,
                        fitsOriginalAspectRatio: true,
                        onImageSizeChange: { size in
                            guard size.width > 0, size.height > 0 else { return }
                            let ratio = size.width / size.height
                            TimelinePhotoThumbnailCache.shared.setAspectRatio(ratio, for: assetID)
                            guard abs(singlePhotoAspectRatio - ratio) > 0.01 else { return }
                            measuredSinglePhotoAspectRatio = ratio
                        }
                    )
                    .frame(
                        width: singlePhotoSize.width,
                        height: singlePhotoSize.height,
                        alignment: .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    }
                }
                .buttonStyle(.plain)
                .frame(
                    width: singlePhotoSize.width,
                    height: singlePhotoSize.height,
                    alignment: .leading
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleAssetIDs.enumerated()), id: \.offset) { index, assetID in
                        Button {
                            if index == 8 && assetIDs.count > 9 {
                                onOverflowTap()
                            } else {
                                onPhotoTap(assetID)
                            }
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    ContinuousTimelinePhotoThumbnail(
                                        assetIDs: [assetID],
                                        targetSide: 160
                                    )
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06))
                                }
                                .overlay {
                                    if index == 8 && assetIDs.count > 9 {
                                        ZStack {
                                            Color.black.opacity(0.48)
                                            Text("\(assetIDs.count - 9)+")
                                                .font(.title3.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: ContinuousTimelineLayout.multiPhotoGridMaxWidth, alignment: .leading)
            }
        }
        .onChange(of: assetIDs) { _, _ in
            measuredSinglePhotoAspectRatio = nil
        }
    }

    private var singlePhotoAspectRatio: CGFloat {
        if let measuredSinglePhotoAspectRatio { return measuredSinglePhotoAspectRatio }
        guard let assetID = assetIDs.first else { return 4 / 3 }
        return TimelinePhotoThumbnailCache.shared.aspectRatio(for: assetID) ?? 4 / 3
    }

    private var singlePhotoSize: CGSize {
        let ratio = max(0.01, singlePhotoAspectRatio)
        let width = min(ContinuousTimelineLayout.multiPhotoGridMaxWidth, 220 * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

private struct CurrentStayTimelineCard: View {
    @Environment(\.modelContext) private var modelContext
    let locationManager: LocationManager
    @State private var showingOngoingLocationSearch = false
    @State private var showingArrivalConfirmation = false

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let timestamp = statusTimestamp {
                statusRow(startTimestamp: timestamp, now: context.date)
            }
        }
        .sheet(isPresented: $showingOngoingLocationSearch) {
            LocationSearchSheet(
                locationManager: locationManager,
                coordinate: ongoingSelectionCoordinate,
                forOngoing: true
            )
        }
        .alert("确认已到达？", isPresented: $showingArrivalConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认到达") {
                Task { await locationManager.confirmArrival() }
            }
        } message: {
            Text("将结束当前移动，并开始记录停留。")
        }
    }

    private func statusRow(startTimestamp: Date, now: Date) -> some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 24)
            VStack(spacing: 0) {
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2, height: 20)
                CurrentTimelineBreathingMarker(locationManager: locationManager)
                    .frame(width: ContinuousTimelineLayout.markerSize, height: ContinuousTimelineLayout.markerSize)
                    .scaleEffect(1.4)
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 6) {
                if canSelectOngoingPlace {
                    SuggestionsMenu(
                        locationManager: locationManager,
                        coordinate: ongoingSelectionCoordinate,
                        forOngoing: true
                    ) {
                        showingOngoingLocationSearch = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("正在")
                            Text(resolvedPlaceName)
                                .overlay(alignment: .bottom) {
                                    GeometryReader { geometry in
                                        Path { path in
                                            path.move(to: .zero)
                                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                                        }
                                        .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0, 3]))
                                    }
                                    .frame(height: 1)
                                    .offset(y: 3)
                                }
                            Text("停留")
                        }
                        .font(.title3.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("选择当前停留地点")
                } else {
                    Text(resolvedTitle)
                        .font(.title3.weight(.bold))
                }
                Text(detailText(for: startTimestamp, now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isCurrentlyMoving {
                    Button("已到达") {
                        showingArrivalConfirmation = true
                    }
                    .arrivalButtonStyle()
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
            
            Spacer(minLength: 0)
        }
        .frame(minHeight: 92, alignment: .top)
    }

    private var statusTimestamp: Date? {
        locationManager.currentStatusStartedAt
    }

    private var canSelectOngoingPlace: Bool {
        !isCurrentlyMoving && locationManager.potentialStopStartLocation != nil
    }

    private var isCurrentlyMoving: Bool {
        locationManager.isCurrentlyMoving
    }

    private var ongoingSelectionCoordinate: CLLocationCoordinate2D? {
        locationManager.lastLocation?.coordinate ?? locationManager.potentialStopStartLocation?.coordinate
    }

    private var resolvedTitle: String {
        if locationManager.isCurrentlyMoving {
            if let location = locationManager.lastLocation, location.speed > 0 {
                let speedKmh = location.speed * 3.6
                if speedKmh > 90 { return "正在高速移动" }
                if speedKmh > 30 { return "正在快速移动" }
                if speedKmh > 5 { return "正在持续移动" }
            }
            return "正在移动"
        }

        return "正在\(resolvedPlaceName)停留"
    }

    private var resolvedPlaceName: String {
        if let place = locationManager.matchedPlace, place.isUserDefined, !place.isIgnored {
            return place.name
        }

          if hasUserDefinedPlaces,
              let title = locationManager.ongoingTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        let address = locationManager.currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return (address.isEmpty || address == "正在解析位置..." || address == "未知位置") ? "此处" : address
    }

    private var hasUserDefinedPlaces: Bool {
        locationManager.allPlaces.contains { $0.isUserDefined && !$0.isIgnored }
    }

    private func detailText(for timestamp: Date, now: Date) -> String {
        if !isCurrentlyMoving {
            return "已 \(now.timeIntervalSince(timestamp).formattedTimelineDuration)"
        }

        let currentTransport = WatchSyncManager.currentTransportRecord(
            in: modelContext,
            now: now,
            isCurrentlyMoving: locationManager.isCurrentlyMoving,
            movingStartedAt: locationManager.uiMovingStartedAt
        )
        if let averageSpeed = WatchSyncManager.currentMovementAverageSpeed(
            persistedAverageSpeed: currentTransport?.averageSpeed,
            locations: locationManager.allTodayPoints,
            movingStartedAt: locationManager.uiMovingStartedAt,
            now: now,
            isCurrentlyMoving: locationManager.isCurrentlyMoving
        ) {
            let speedKmh = Measurement(value: averageSpeed, unit: UnitSpeed.metersPerSecond)
                .converted(to: .kilometersPerHour)
                .value
            return String(format: "平均速度 %.1f 千米/小时", speedKmh)
        }
        return "运动传感器检测到移动"
    }
}

private struct CurrentTimelineBreathingMarker: View {
    let locationManager: LocationManager

    var body: some View {
        SwiftUI.TimelineView(.animation) { timeline in
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
    func arrivalButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Any top edge effect (hard or soft) paints the title band at full
    /// strength and covers the sheet's glass rim; rows are clipped below the
    /// title bar instead. The bottom effect is drawn by the app's tab bar,
    /// washing the map around it, while the sheet ends above that bar.
    @ViewBuilder
    func timelineHiddenScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            self
        }
    }

}

extension TimeInterval {
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
