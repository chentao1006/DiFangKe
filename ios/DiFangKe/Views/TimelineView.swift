import SwiftUI
import MapKit
import SwiftData
import Photos
import UIKit
import Aptabase

struct TimelineView: View {
    var initialDate: Date?

    var body: some View {
        ContinuousTimelineView(initialDate: initialDate)
    }
}

#Preview {
    TimelineView()
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

private struct ContinuousTimelineView: View {
    var initialDate: Date?

    nonisolated private static let initialTimelineVisibleDateBatchSize = 30
    nonisolated private static let timelineVisibleDateBatchSize = 30
    nonisolated private static let calendarBackfillDateBatchSize = 30
    nonisolated private static let timelineCommitChunkSize = 24

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocationManager.self) private var locationManager
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = true
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: \FutureTrip.arrivalDate) private var futureTrips: [FutureTrip]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isTimelinePresented = true
    @State private var showLocationSettingsAlert = false
    @State private var loadedDates: [Date] = []
    @State private var timelinesByDate: [Date: [TimelineItem]] = [:]
    @State private var isLoadingEarlierDates = false
    @State private var todayScrollRequest = 0
    @State private var targetScrollDate: Date? = nil
    @State private var activeTimelineDate = Calendar.current.startOfDay(for: Date())
    @State private var timelineDetent: PresentationDetent = .medium
    @State private var visibleTimelineItems: [TimelineItem] = []
    @State private var renderedFutureTrips: [FutureTrip] = []
    @State private var visibleTimelineDates = Set<Date>()
    @State private var renderedMapItemIDs = Set<String>()
    @State private var renderedMapDetentKey: String = ""
    @State private var renderedSelectedFootprintID: UUID? = nil
    @State private var renderedSelectedFutureTripID: UUID? = nil
    @State private var renderedMapRegion: MKCoordinateRegion?
    @State private var displayedMapRegion: MKCoordinateRegion?
    @State private var mapCameraTransitionTask: Task<Void, Never>?
    @State private var mapInteractionLockedVisibleDates: Set<Date>?
    @State private var visibleMapUpdateTask: Task<Void, Never>?
    @State private var deferredVisibleTimelineDates: Set<Date>?
    @State private var deferredTimelineWorkCount = 0
    @State private var mapViewportSize: CGSize = .zero
    @State private var isShowingSettings = false
    @State private var didRequestInitialTimeline = false
    @State private var hasCompletedInitialTimelineLoad = false
    @State private var allowsMapInteractionCollapse = false
    @State private var skipsNextMapExpansionCameraReset = false
    @State private var timelineCache = ContinuousTimelineCache()
    @State private var availableTimelineDateSet = Set<Date>()
    @State private var hiddenTimelineDateSet = Set<Date>()
    @State private var visibleTimelineFillTask: Task<Void, Never>?
    @State private var midnightTimelineRefreshTask: Task<Void, Never>?
    @State private var isReloadingTimelineExternally = false
    @State private var mapInteractionEnableTask: Task<Void, Never>?
    @State private var selectedFootprintPhotoFetchTask: Task<Void, Never>?
    @State private var selectedFootprint: Footprint?
    @State private var selectedFutureTripDetail: FutureTrip?
    @State private var selectedTransport: Transport?
    @State private var selectedFutureTripFromMap: FutureTrip?
    @State private var selectedFootprintPhotos: [PHAsset] = []
    @State private var selectedMapPhotoAssetID: String? = nil
    @State private var showsUndatedFutureTripsOnMap = false
    @State private var isFollowingUserLocation = false
    @State private var navigatingTrip: FutureTrip? = nil
    @State private var pendingFutureTripDelayOptionsID: UUID? = nil
    @State private var showingNavigationOptions = false
    @State private var pendingFutureTripAbandonAlertID: UUID? = nil


    private var timelineDates: [Date] {
        let calendar = Calendar.current
        var dates = Set(loadedDates)
        dates.insert(activeTimelineDate)

        if hasCompletedInitialTimelineLoad {
            let futureDates = futureTrips.filter(\.hasPlanDate).map { calendar.startOfDay(for: $0.arrivalDate) }
            dates.formUnion(futureDates)
        }

        return Array(dates).sorted()
    }

    private var mapTimelineItems: [TimelineItem] {
        visibleTimelineItems
    }
    
    private var mapPoints: [CLLocationCoordinate2D] {
        selectedFootprint?.coordinates ?? []
    }
    
    private var mapPhotoAssets: [PHAsset] {
        selectedFootprint != nil ? selectedFootprintPhotos : []
    }
    
    private var mapShowsStandalonePhotos: Bool {
        selectedFootprint != nil
    }
    
    private var mapPrefersActivityIcons: Bool {
        false
    }
    
    private var mapFutureTrips: [FutureTrip] {
        var trips = renderedFutureTrips
        if let detail = selectedFutureTripDetail, !detail.isCompleted, !trips.contains(where: { $0.id == detail.id }) {
            trips.append(detail)
        }
        return trips
    }


    private var mapContent: some View {
        DFKMapView(
            cameraPosition: $cameraPosition,
            isInteractive: true,
            showsUserLocation: selectedFootprint == nil,
            points: mapPoints,
            timelineItems: mapTimelineItems,
            futureTrips: mapFutureTrips,
            photoAssets: mapPhotoAssets,
            showsStandalonePhotos: mapShowsStandalonePhotos,
            prefersActivityIcons: mapPrefersActivityIcons,
            selectedFootprintID: selectedFootprint?.footprintID,
            selectedFutureTripID: selectedFutureTripDetail?.id,
            onMapInteraction: handleMapInteraction,
            onTimelineItemTap: { item in
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    switch item {
                    case .footprint(let footprint): selectedFootprint = storedFootprint(matching: footprint)
                    case .transport(let transport): selectedTransport = transport
                    }
                }
            },
            onFutureTripTap: { trip in
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    selectedFutureTripDetail = trip
                }
            },
            onPhotoTap: { asset in
                selectedMapPhotoAssetID = asset.localIdentifier
            },
            onUserLocationTap: focusMapOnCurrentLocation
        )
    }

    private func focusMapOnCurrentLocation() {
        guard let region = currentLocationMapRegion() else { return }
        isFollowingUserLocation = true
        moveMapCamera(to: region, animated: true)
    }

    private var isSideBySide: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    private func sheetHeight(in mapHeight: CGFloat) -> CGFloat {
        if isSideBySide { return 0 }
        if timelineDetent == .height(88) { return 88 }
        if timelineDetent == .medium { return mapHeight * 0.5 }
        return mapHeight
    }

    private var mapLocationSheetClearance: CGFloat {
        timelineDetent == .medium ? 32 : 16
    }

    private func mapLocationButton(mapHeight: CGFloat) -> some View {
        let desiredPadding: CGFloat
        if isSideBySide || timelineDetent != .large {
            desiredPadding = 48 + sheetHeight(in: mapHeight)
        } else {
            desiredPadding = 16
        }
        return Button(action: focusMapOnCurrentLocation) {
            Image(systemName: isFollowingUserLocation ? "location.fill" : "location")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .mapLocationButtonStyle()
        .controlSize(.small)
        .accessibilityLabel("定位到当前位置")
        .padding(.trailing, 16)
        .padding(.bottom, desiredPadding)
    }

    private func handleMapInteraction(_ interactionType: DFKMapView.MapInteractionType) {
        if interactionType == .pan {
            isFollowingUserLocation = false
        }
        
        renderedMapRegion = nil
        displayedMapRegion = nil
        guard allowsMapInteractionCollapse else { return }
        guard !isSideBySide else { return }

        lockVisibleTimelineMapForInteraction()
        guard timelineDetent != .height(88) else { return }
        skipsNextMapExpansionCameraReset = interactionType != .tap
        withAnimation(.easeOut(duration: 0.2)) {
            timelineDetent = .height(88)
        }
    }

    @ViewBuilder
    private var timelineSidebarContent: some View {
        ContinuousTimelineSheet(
            dates: timelineDates,
            timelinesByDate: timelinesByDate,
            futureTrips: hasCompletedInitialTimelineLoad ? futureTrips : [],
            initialTimelineLoadCompleted: hasCompletedInitialTimelineLoad,
            isReloadingTimelineExternally: isReloadingTimelineExternally,
            locationManager: locationManager,
            activeTimelineDate: $activeTimelineDate,
            todayScrollRequest: $todayScrollRequest,
            targetScrollDate: $targetScrollDate,
            timelineDetent: $timelineDetent,
            isSideBySide: isSideBySide,
            selectedFootprint: $selectedFootprint,
            selectedFutureTripDetail: $selectedFutureTripDetail,
            selectedTransport: $selectedTransport,
            loadEarlierDates: loadEarlierTimeline,
            loadLaterDates: loadLaterTimeline,
            loadLaterDatesAfter: { date in await loadLaterTimeline(from: date) },
            loadGapDates: loadTimelineDatesForBackfill,
            loadDate: loadTimelineDate,
            loadBackfillDates: loadTimelineDatesForBackfill,
            calendarBackfillBatchSize: Self.calendarBackfillDateBatchSize,
            availableDates: loadableTimelineDateSet,
            visibleDatesChanged: updateVisibleTimelineDates,
            undatedFutureTripsVisibilityChanged: { isVisible in
                guard showsUndatedFutureTripsOnMap != isVisible else { return }
                showsUndatedFutureTripsOnMap = isVisible
                refreshVisibleTimelineMap(for: visibleTimelineDates, delayNanoseconds: 0)
            },
            isShowingSettings: $isShowingSettings,
            pendingFutureTripDelayOptionsID: $pendingFutureTripDelayOptionsID,
            pendingFutureTripAbandonAlertID: $pendingFutureTripAbandonAlertID,
            selectedMapPhotoAssetID: $selectedMapPhotoAssetID
        )
        // This content is the iPhone bottom timeline sheet and the iPad sidebar.
        // It is therefore the common presenter for a persisted denied location
        // permission on every layout.
        .modifier(LocationSettingsAlertModifier(isPresented: $showLocationSettingsAlert))
        .onAppear(perform: handleTimelinePermissionPresenterAppear)
        .confirmationDialog("选择导航应用", isPresented: $showingNavigationOptions, titleVisibility: .visible) {
            if let trip = navigatingTrip {
                Button("苹果地图") {
                    let coordinate = CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)
                    let placemark = MKPlacemark(coordinate: coordinate)
                    let mapItem = MKMapItem(placemark: placemark)
                    mapItem.name = trip.placeName
                    mapItem.openInMaps()
                }
                
                if let url = URL(string: "iosamap://"), UIApplication.shared.canOpenURL(url) {
                    Button("高德地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "iosamap://path?sourceApplication=DiFangKe&dlat=\(trip.latitude)&dlon=\(trip.longitude)&dname=\(name)&dev=0&t=0") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "baidumap://"), UIApplication.shared.canOpenURL(url) {
                    Button("百度地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "baidumap://map/direction?destination=latlng:\(trip.latitude),\(trip.longitude)|name:\(name)&mode=driving&coord_type=wgs84") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "qqmap://"), UIApplication.shared.canOpenURL(url) {
                    Button("腾讯地图") {
                        let name = trip.placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let targetURL = URL(string: "qqmap://map/routeplan?type=drive&to=\(name)&tocoord=\(trip.latitude),\(trip.longitude)") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
                
                if let url = URL(string: "comgooglemaps://"), UIApplication.shared.canOpenURL(url) {
                    Button("Google 地图") {
                        if let targetURL = URL(string: "comgooglemaps://?daddr=\(trip.latitude),\(trip.longitude)&directionsmode=driving") {
                            UIApplication.shared.open(targetURL)
                        }
                    }
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var timelineSheet: some View {
        timelineSidebarContent
            .presentationDetents([.height(88), .medium, .large], selection: $timelineDetent)
            .presentationBackground(.clear)
            .presentationDragIndicator(.visible)
            // A selected footprint presents an editor above this sheet. Let its
            // scroll view keep its touches instead of turning them into a resize
            // gesture on the underlying timeline sheet.
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled()
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    @ViewBuilder
    private var timelineMainContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                mapContent
                mapLocationButton(mapHeight: geometry.size.height)
            }
            .onAppear {
                updateMapViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateMapViewportSize(newSize)
            }
        }
        .ignoresSafeArea(edges: isSideBySide ? [.top, .bottom, .trailing] : .all)
    }

    private var sidebarNavigationTitle: String {
        if selectedFootprint != nil { return "足迹详情" }
        if selectedFutureTripDetail != nil { return "计划详情" }
        return "地方客"
    }

    @ViewBuilder
    private var responsiveTimelineLayout: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    timelineSidebarContent
                        .navigationTitle(sidebarNavigationTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(removing: .sidebarToggle)
                        .navigationSplitViewColumnWidth(min: 350, ideal: 420, max: 500)
                        .sheet(item: $selectedFutureTripFromMap) { trip in
                            FutureTripDraftModal(editingTrip: trip)
                        }
                } detail: {
                    timelineMainContent
                        .toolbar(.hidden, for: .navigationBar)
                }
                .toolbar(removing: .sidebarToggle)
            } else if verticalSizeClass == .compact {
                HStack(spacing: 0) {
                    NavigationStack {
                        timelineSidebarContent
                            .navigationTitle(sidebarNavigationTitle)
                            .navigationBarTitleDisplayMode(.inline)
                            .sheet(item: $selectedFutureTripFromMap) { trip in
                                FutureTripDraftModal(editingTrip: trip)
                            }
                    }
                    .frame(width: 340)

                    Divider()

                    timelineMainContent
                }
            } else {
                NavigationStack {
                    timelineMainContent
                        .toolbar(.hidden, for: .navigationBar)
                        .sheet(isPresented: $isTimelinePresented) {
                            timelineSheet
                        }
                        .sheet(item: $selectedFutureTripFromMap) { trip in
                            FutureTripDraftModal(editingTrip: trip)
                        }

                }
            }
        }
    }

    var body: some View {
        responsiveTimelineLayout
        .onAppear(perform: handleTimelineAppear)
        .onDisappear(perform: handleTimelineDisappear)
        .task { await loadInitialTimeline() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged")), perform: handleFootprintDataChanged)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DFKDeepLinkNotification"))) { notification in
            handleDeepLink(userInfo: notification.userInfo)
        }
        .onChange(of: selectedFootprint) { _, newFootprint in
            handleSelectedFootprintChange(newFootprint)
        }
        .onChange(of: selectedFutureTripDetail) { _, newTrip in
            handleSelectedFutureTripChange(newTrip)
        }
        .onChange(of: allPlaces) { _, newValue in
            locationManager.allPlaces = newValue
            locationManager.forceRefreshOngoingAnalysis()
        }
        .onChange(of: timelineDetent) { oldValue, newValue in
            handleTimelineDetentChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: locationManager.lastLocation?.timestamp) { _, _ in
            guard visibleTimelineItems.isEmpty else { return }
            refreshVisibleTimelineMap(delayNanoseconds: 0)
        }
        .onChange(of: futureTrips) { _, _ in
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
    }

    private func handleDeepLinkURL(_ url: URL) {
        guard url.scheme == "difangke" else { return }

        if url.host == "timeline" {
            openTimelineDeepLink(url)
        } else if url.host == "trip", url.path == "/action" {
            handleTripAction(url: url)
        } else if url.host == "trip", url.path == "/detail" {
            openTripDetailDeepLink(url)
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
        visibleMapUpdateTask?.cancel()
        visibleTimelineFillTask?.cancel()
        mapCameraTransitionTask?.cancel()
        mapInteractionEnableTask?.cancel()
        selectedFootprintPhotoFetchTask?.cancel()
        selectedFootprintPhotos = []
    }

    private func handleFootprintDataChanged(_: Notification) {
        reloadLoadedTimeline()
        Task { await refreshAvailableTimelineDateCache() }
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
        guard let offsetString = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "offset" })?.value,
              let offset = Int(offsetString),
              let targetDate = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) else {
            return
        }

        Task { @MainActor in
            timelineDetent = .medium
            activeTimelineDate = targetDate
            updateVisibleTimelineDates([targetDate])

            guard hasCompletedInitialTimelineLoad else { return }
            _ = await refreshAvailableTimelineDateCache()
            _ = await loadTimelineDate(targetDate)
            targetScrollDate = targetDate
            todayScrollRequest += 1
        }
    }

    private func openTripDetailDeepLink(_ url: URL) {
        guard let tripIDString = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              let tripID = UUID(uuidString: tripIDString),
              let trip = futureTrips.first(where: { $0.id == tripID }) else {
            return
        }
        selectedFutureTripDetail = trip
    }

    private func handleTripAction(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let actionType = queryItems.first(where: { $0.name == "type" })?.value else { return }
              
        if actionType == "navigate" {
            if let tripIdString = queryItems.first(where: { $0.name == "id" })?.value,
               let tripId = UUID(uuidString: tripIdString),
               let trip = futureTrips.first(where: { $0.id == tripId }) {
                selectedFutureTripDetail = trip
                navigatingTrip = trip
                showingNavigationOptions = true
            }
            return
        }
        
        guard let tripIdString = queryItems.first(where: { $0.name == "id" })?.value,
              let tripId = UUID(uuidString: tripIdString) else { return }
              
        guard let trip = futureTrips.first(where: { $0.id == tripId }) else { return }
        
        if actionType == "arrive" {
            completeFutureTrip(trip)

        } else if actionType == "complete" {
            completeFutureTrip(trip)
            
        } else if actionType == "abandon" {
            selectedFutureTripDetail = trip
            pendingFutureTripAbandonAlertID = trip.id
            
        } else if actionType == "delay" {
            guard !trip.isOrdered else { return }
            selectedFutureTripDetail = trip
            pendingFutureTripDelayOptionsID = trip.id
        }
    }

    private func completeFutureTrip(_ trip: FutureTrip) {
        NotificationManager.shared.cancelFutureTripNotification(for: trip.id)
        trip.markCompleted()
        try? modelContext.save()
        selectedFutureTripDetail = nil
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            TripLiveActivityManager.shared.endActivity(for: trip.id)
        }
#endif
        FutureTrip.postDidChangeNotification()
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
    }

    private func handleSelectedFootprintChange(_ newFootprint: Footprint?) {
        if newFootprint != nil, selectedFutureTripDetail != nil {
            selectedFutureTripDetail = nil
        }
        if let footprint = newFootprint {
            focusMap(on: footprint)
        }
        refreshVisibleTimelineMap(delayNanoseconds: 0)
        selectedFootprintPhotoFetchTask?.cancel()
        if let footprint = newFootprint {
            timelineDetent = .medium
            selectedFootprintPhotoFetchTask = Task { @MainActor in
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: footprint.photoAssetIDs, options: nil)
                var assets: [PHAsset] = []
                fetchResult.enumerateObjects { asset, _, _ in
                    if asset.location != nil {
                        assets.append(asset)
                    }
                }
                guard !Task.isCancelled else { return }
                selectedFootprintPhotos = assets
            }
        } else {
            selectedFootprintPhotos = []
            timelineDetent = .medium
        }
    }

    private func focusMap(on footprint: Footprint) {
        let coordinates = footprint.coordinates.isEmpty
            ? [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
            : footprint.coordinates
        guard let region = adjustedMapRegion(for: coordinates) else { return }
        moveMapCamera(to: region, animated: true)
    }

    private func handleSelectedFutureTripChange(_ newTrip: FutureTrip?) {
        if newTrip != nil, selectedFootprint != nil {
            selectedFootprint = nil
        }
        refreshVisibleTimelineMap(delayNanoseconds: 0)
        if newTrip != nil {
            timelineDetent = .medium
            selectedFootprintPhotos = []
        } else {
            timelineDetent = .medium
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
        if oldValue == .height(88), newValue != .height(88) {
            unlockVisibleTimelineMapAfterInteraction()
            return
        }
        if newValue == .height(88) {
            lockVisibleTimelineMapForInteraction()
            guard !skipsNextMapExpansionCameraReset else {
                skipsNextMapExpansionCameraReset = false
                return
            }
            resetLockedMapCamera(animated: true)
            return
        }
        guard mapInteractionLockedVisibleDates == nil || isSideBySide else { return }
        refreshVisibleTimelineMap()
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
        guard let userInfo = userInfo else { return }
        
        if let type = userInfo["type"] as? String {
            if type == "future_trip",
               let tripIDStr = userInfo["tripID"] as? String,
               let tripID = UUID(uuidString: tripIDStr) {
                
                if let trip = futureTrips.first(where: { $0.id == tripID }) {
                    let tripDate = Calendar.current.startOfDay(for: trip.arrivalDate)
                    
                    Task {
                        activeTimelineDate = tripDate
                        updateVisibleTimelineDates([tripDate])
                        _ = await refreshAvailableTimelineDateCache()
                        _ = await loadTimelineDate(tripDate)
                        todayScrollRequest += 1
                        selectedFutureTripDetail = trip
                    }
                }
            } else if type == "highlight_footprint",
                      let date = userInfo["date"] as? Date {
                
                let footprintID = userInfo["footprintID"] as? UUID
                
                Task {
                    let dayStart = Calendar.current.startOfDay(for: date)
                    activeTimelineDate = dayStart
                    updateVisibleTimelineDates([dayStart])
                    _ = await refreshAvailableTimelineDateCache()
                    _ = await loadTimelineDate(dayStart)
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
    }
    
    private func handleColdLaunchDeepLink() {
        if let tripID = locationManager.deepLinkFutureTripID {
            locationManager.deepLinkFutureTripID = nil
            
            if let trip = futureTrips.first(where: { $0.id == tripID }) {
                let tripDate = Calendar.current.startOfDay(for: trip.arrivalDate)
                Task {
                    activeTimelineDate = tripDate
                    updateVisibleTimelineDates([tripDate])
                    _ = await refreshAvailableTimelineDateCache()
                    _ = await loadTimelineDate(tripDate)
                    todayScrollRequest += 1
                    selectedFutureTripDetail = trip
                }
            }
        } else if let date = locationManager.deepLinkDate {
            locationManager.deepLinkDate = nil
            let footprintID = locationManager.deepLinkFootprintID
            locationManager.deepLinkFootprintID = nil
            
            Task {
                let dayStart = Calendar.current.startOfDay(for: date)
                activeTimelineDate = dayStart
                updateVisibleTimelineDates([dayStart])
                _ = await refreshAvailableTimelineDateCache()
                _ = await loadTimelineDate(dayStart)
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

    private func loadTimelineDate(_ date: Date) async -> Bool {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        if let items = timelinesByDate[normalizedDate] {
            guard shouldDisplayTimelineDate(normalizedDate, items: items) else { return false }
            if !loadedDates.contains(normalizedDate) {
                loadedDates = Set(loadedDates).union([normalizedDate]).sorted()
            }
            hiddenTimelineDateSet.remove(normalizedDate)
            return true
        }
        if let cachedItems = timelineCache.cachedTimeline(for: normalizedDate) {
            guard shouldDisplayTimelineDate(normalizedDate, items: cachedItems) else { return false }
            timelinesByDate[normalizedDate] = cachedItems
            loadedDates = Set(loadedDates).union([normalizedDate]).sorted()
            hiddenTimelineDateSet.remove(normalizedDate)
            return true
        }
        if timelineCache.isHidden(normalizedDate) {
            return false
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
        let visibleFutureTrips = futureTrips(for: lockedDates)
        
        visibleTimelineItems = items
        renderedFutureTrips = visibleFutureTrips
        
        renderedMapItemIDs = mapContentIDs(for: items, futureTrips: visibleFutureTrips)
        renderedMapDetentKey = currentMapDetentKey
        renderedSelectedFootprintID = selectedFootprint?.footprintID
        renderedSelectedFutureTripID = selectedFutureTripDetail?.id

        let region: MKCoordinateRegion?
        if let footprint = selectedFootprint {
            var coordinates = footprint.coordinates
            if coordinates.isEmpty {
                coordinates = [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
            }
            region = adjustedMapRegion(for: coordinates)
        } else if let trip = selectedFutureTripDetail {
            region = adjustedMapRegion(for: [CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)])
        } else if items.isEmpty {
            region = adjustedMapRegion(for: visibleFutureTrips.map(\.coordinate)) ?? currentLocationMapRegion()
        } else {
            region = adjustedMapRegion(for: mapCameraCoordinates(for: items, futureTrips: visibleFutureTrips))
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
        guard isSideBySide || mapInteractionLockedVisibleDates == nil || showsUndatedFutureTripsOnMap else { return }
        let targetVisibleDates = visibleDates
        visibleMapUpdateTask?.cancel()
        visibleMapUpdateTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let mapDates = targetVisibleDates ?? ((isSideBySide || timelineDetent == .large) ? visibleTimelineDates : (mapInteractionLockedVisibleDates ?? visibleTimelineDates))
            let items = timelineItemsForVisibleDates(visibleDates: mapDates)
            let visibleFutureTrips = futureTrips(for: mapDates)
            let usesFutureTripCamera = showsUndatedFutureTripsOnMap &&
                selectedFootprint == nil &&
                selectedFutureTripDetail == nil &&
                !visibleFutureTrips.isEmpty
            guard !items.isEmpty else {
                visibleTimelineItems = []
                renderedFutureTrips = visibleFutureTrips
                renderedMapItemIDs = mapContentIDs(for: [], futureTrips: visibleFutureTrips)
                renderedMapDetentKey = currentMapDetentKey
                renderedSelectedFootprintID = selectedFootprint?.footprintID
                renderedSelectedFutureTripID = selectedFutureTripDetail?.id

                let futureTripCoordinates: [CLLocationCoordinate2D]
                if let footprint = selectedFootprint {
                    futureTripCoordinates = footprint.coordinates.isEmpty
                        ? [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
                        : footprint.coordinates
                } else if let trip = selectedFutureTripDetail {
                    futureTripCoordinates = [CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)]
                } else {
                    futureTripCoordinates = visibleFutureTrips.map(\.coordinate).filter(\.isRenderableMapCoordinate)
                }
                let region = adjustedMapRegion(for: futureTripCoordinates) ?? currentLocationMapRegion()
                if let region {
                    if usesFutureTripCamera {
                        moveMapCamera(to: region, animated: true)
                    } else if shouldUpdateMapRegion(to: region) {
                        moveMapCamera(to: region, animated: true)
                    }
                } else {
                    renderedMapRegion = nil
                }
                return
            }

            let mapItemIDs = mapContentIDs(for: items, futureTrips: visibleFutureTrips)
            let detentKey = currentMapDetentKey
            let selectedFootprintID = selectedFootprint?.footprintID
            let selectedTripID = selectedFutureTripDetail?.id
            let mapStateChanged = mapItemIDs != renderedMapItemIDs || detentKey != renderedMapDetentKey || selectedFootprintID != renderedSelectedFootprintID || selectedTripID != renderedSelectedFutureTripID
            renderedMapItemIDs = mapItemIDs
            renderedMapDetentKey = detentKey
            renderedSelectedFootprintID = selectedFootprintID
            renderedSelectedFutureTripID = selectedTripID

            visibleTimelineItems = items
            renderedFutureTrips = visibleFutureTrips
            guard mapStateChanged || usesFutureTripCamera else { return }
            
            var coordinates: [CLLocationCoordinate2D] = []
            if usesFutureTripCamera {
                coordinates = visibleFutureTrips.map(\.coordinate).filter(\.isRenderableMapCoordinate)
            } else if let footprint = selectedFootprint {
                coordinates = footprint.coordinates
                if coordinates.isEmpty {
                    coordinates = [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
                }
            } else if let trip = selectedFutureTripDetail {
                coordinates = [CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)]
            } else {
                coordinates = mapCameraCoordinates(for: items, futureTrips: visibleFutureTrips)
            }

            if let region = adjustedMapRegion(for: coordinates) {
                if usesFutureTripCamera {
                    moveMapCamera(to: region, animated: true)
                } else if shouldUpdateMapRegion(to: region) {
                    moveMapCamera(to: region, animated: true)
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

    private func futureTrips(for dates: Set<Date>) -> [FutureTrip] {
        guard hasCompletedInitialTimelineLoad else { return [] }
        let calendar = Calendar.current
        if showsUndatedFutureTripsOnMap {
            return futureTrips.filter { !$0.isCompleted && !$0.hasPlanDate }
        }
        return futureTrips.filter { trip in
            !trip.isCompleted && trip.hasPlanDate && dates.contains(calendar.startOfDay(for: trip.arrivalDate))
        }
    }

    private func mapContentIDs(for items: [TimelineItem], futureTrips: [FutureTrip]) -> Set<String> {
        Set(items.map(\.id)).union(
            futureTrips
                .filter { $0.coordinate.isRenderableMapCoordinate }
                .map { trip in
                    "future-trip:\(trip.id.uuidString):\(trip.latitude):\(trip.longitude)"
                }
        )
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

    private func moveMapCamera(to target: MKCoordinateRegion, animated: Bool) {
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

    private func mapCameraCoordinates(for items: [TimelineItem], futureTrips: [FutureTrip]) -> [CLLocationCoordinate2D] {
        let itemCoordinates: [CLLocationCoordinate2D]
        if !isSideBySide && timelineDetent == .medium {
            itemCoordinates = mediumDetentAnnotationCoordinates(for: items)
        } else {
            itemCoordinates = items.flatMap { item -> [CLLocationCoordinate2D] in
                switch item {
                case .footprint(let footprint):
                    return [CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)]
                case .transport(let transport):
                    return sampledCoordinates(from: transport.points, maximumCount: 24)
                }
            }
        }

        return itemCoordinates + futureTrips.map(\.coordinate).filter(\.isRenderableMapCoordinate)
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

    private func aggregatedFootprintCameraCoordinates(for items: [TimelineItem]) -> [CLLocationCoordinate2D] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalWeight: TimeInterval
            var totalDuration: TimeInterval
        }

        var buckets: [String: Bucket] = [:]
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
                buckets[key] = Bucket(
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
        guard let region = coordinates.boundingRegion(paddingFactor: 1.4) else { return nil }
        if isSideBySide { return isRenderableMapRegion(region) ? region : nil }
        guard timelineDetent == .medium else { return isRenderableMapRegion(region) ? region : nil }

        let mediumRegion = mediumDetentMapRegion(fitting: region)
        // Widely separated future plans can make the medium-sheet adjustment
        // exceed MapKit's valid latitude span. Keep the valid bounding region
        // rather than dropping the camera update altogether.
        if isRenderableMapRegion(mediumRegion) {
            return mediumRegion
        }
        return isRenderableMapRegion(region) ? region : nil
    }

    private func mediumDetentMapRegion(fitting region: MKCoordinateRegion) -> MKCoordinateRegion {
        let targetTopFraction = 0.075
        let targetBottomFraction = 0.435
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let longitudeDelta = region.span.longitudeDelta * 1.5
        let fullMapAspectRatio = mapViewportSize.height > 1 && mapViewportSize.width > 1 ? mapViewportSize.height / mapViewportSize.width : 2.15
        let longitudeDrivenLatitudeDelta = longitudeDelta * cos(region.center.latitude * .pi / 180) * fullMapAspectRatio
        let desiredLatitudeDelta = max(
            region.span.latitudeDelta,
            (north - south) / (targetBottomFraction - targetTopFraction),
            longitudeDrivenLatitudeDelta
        )
        // Keep the medium-sheet offset valid even when plans span a continent.
        let latitudeDelta = min(desiredLatitudeDelta, 170)
        let centerLatitude = north - (0.5 - targetTopFraction) * latitudeDelta

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: region.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
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
        case futureTrip(UUID)
        case now
        case todayBottom
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var activityTypes: [ActivityType]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var lastPrefetchOldestDate: Date?
    @State private var allowsEarlierDatePrefetch = false
    @State private var latestScrollOffsetY: CGFloat = .infinity
    @State private var didReachEarliestAvailableDate = false
    @State private var lastEarlierDatePrefetchTime: Date?
    @State private var isShowingCalendar = false
    @State private var isShowingHistory = false
    @State private var isHistoryContentReady = false
    @State private var historyContentPreparationTask: Task<Void, Never>?
    @State private var isHistoryStatisticsActive = false
    @State private var earlierDatePrefetchTask: Task<Void, Never>?
    @State private var scrollMetrics = ContinuousTimelineScrollMetrics()
    @State private var scrollRestorer = ContinuousTimelineScrollRestorer()
    @State private var headerVisibleDates: [Date] = []
    @State private var isViewingUndatedFutureTrips = false
    @State private var freezesViewportDrivenUpdatesUntil: Date? = Date.distantFuture
    @State private var activeTimelineDateBeforeBackground: Date?
    @State private var viewportAnchorBeforeBackground: ContinuousTimelineScrollAnchor?
    @State private var externalReloadViewportAnchor: ContinuousTimelineScrollAnchor?
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
    @State private var initialTodayScrollTask: Task<Void, Never>?
    @State private var initialLoadingFallbackTask: Task<Void, Never>?
    @State private var allowsInitialLoadingFallback = false
    @State private var timelineScrollPosition: ScrollTarget?
    @State private var lastUserInteractionTime = Date.distantPast
    @State private var isLoadingMoreEarlier = false
    @State private var isLoadingMoreLater = false
    @State private var loadingGapAfterDates = Set<Date>()
    @State private var loadingGapBeforeDates = Set<Date>()
    @State private var showingResetAlert = false
    @State private var showingRawPointsDate: IdentifiableDate?
    @State private var isShowingFutureTripModal = false
    @State private var selectedFutureTrip: FutureTrip?
    @State private var futureTripPendingDeletion: FutureTrip?
    @State private var futureTripTimelineAnchorDate: Date?
    @State private var futureTripTimelineAnchorID: UUID?
    @State private var didScheduleInitialScrollToToday = false
    @State private var footprintPendingDeletion: Footprint?
    @State private var footprintPendingIgnore: Footprint?
    @State private var transportPendingDeletion: Transport?
    @State private var footprintPendingSplit: Footprint?
    @State private var pendingMergeCandidate: ContinuousAdjacentFootprintMergeCandidate?
    @State private var pendingTransportMergeCandidate: ContinuousAdjacentTransportMergeCandidate?
    @State private var hasCompletedInitialTimelinePositioning = false
    @State private var requestedHistoryImport = false
    @State private var showingAddPlaceSheet = false
    @State private var sharePayload: DFKShareCardPayload?
    @State private var showingTimelineShareRangePicker = false
    @AppStorage("isImportantPlaceGuideDismissed") private var isImportantPlaceGuideDismissed = false

    let dates: [Date]
    let timelinesByDate: [Date: [TimelineItem]]
    let futureTrips: [FutureTrip]
    let initialTimelineLoadCompleted: Bool
    let isReloadingTimelineExternally: Bool
    let locationManager: LocationManager
    @Binding var activeTimelineDate: Date
    @Binding var todayScrollRequest: Int
    @Binding var targetScrollDate: Date?
    @Binding var timelineDetent: PresentationDetent
    let isSideBySide: Bool
    @Binding var selectedFootprint: Footprint?
    @Binding var selectedFutureTripDetail: FutureTrip?
    @Binding var selectedTransport: Transport?
    let loadEarlierDates: () async -> Bool
    let loadLaterDates: () async -> Bool
    let loadLaterDatesAfter: (Date) async -> Bool
    let loadGapDates: ([Date]) async -> Bool
    let loadDate: (Date) async -> Bool
    let loadBackfillDates: ([Date]) async -> Bool
    let calendarBackfillBatchSize: Int
    private let calendarBackfillDateLoadLimit = 1_000
    let availableDates: Set<Date>
    let visibleDatesChanged: (Set<Date>) -> Void
    let undatedFutureTripsVisibilityChanged: (Bool) -> Void
    @Binding var isShowingSettings: Bool
    @Binding var pendingFutureTripDelayOptionsID: UUID?
    @Binding var pendingFutureTripAbandonAlertID: UUID?
    @Binding var selectedMapPhotoAssetID: String?

    private var isCollapsed: Bool {
        !isSideBySide && timelineDetent == .height(88)
    }

    private var timelineScrollPositionBinding: Binding<ScrollTarget?> {
        Binding(
            get: { timelineScrollPosition },
            set: { newValue in
                // While a calendar jump is in flight, viewport updates may
                // report the old (usually today) row. Keep the requested ID
                // until that destination has actually become visible.
                guard calendarScrollLockTarget == nil else { return }
                timelineScrollPosition = newValue
            }
        )
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

    private var isShowingFutureTripDeletionAlert: Binding<Bool> {
        alertBinding(for: $futureTripPendingDeletion)
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

    private var showsReturnToTodayButton: Bool {
        guard !isCollapsed else { return false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activeDate = calendar.startOfDay(for: activeTimelineDate)
        let daysFromToday = calendar.dateComponents([.day], from: activeDate, to: today).day ?? 0
        return daysFromToday > 1
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

    private func loadableTimelineDates(between earlierDate: Date, and laterDate: Date) -> [Date] {
        let calendar = Calendar.current
        let earlierDate = calendar.startOfDay(for: earlierDate)
        let laterDate = calendar.startOfDay(for: laterDate)
        return availableDates.compactMap { availableDate -> Date? in
            let normalizedDate = calendar.startOfDay(for: availableDate)
            guard normalizedDate > earlierDate && normalizedDate < laterDate && !dates.contains(normalizedDate) else { return nil }
            return normalizedDate
        }.sorted()
    }

    private func hasLoadableTimelineDate(between earlierDate: Date, and laterDate: Date) -> Bool {
        !loadableTimelineDates(between: earlierDate, and: laterDate).isEmpty
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        // Keep the scroll view mounted while collapsed so its
                        // current offset survives re-expansion. Rendering it
                        // transparent prevents its first row from peeking
                        // below the title bar in the 88pt detent.
                        mainScrollView(proxy: proxy, viewport: viewport)
                            .opacity(isCollapsed ? 0 : 1)
                            .allowsHitTesting(!isCollapsed)
                    .sheet(item: $footprintPendingSplit, onDismiss: handleFootprintSplitDismissal) { footprint in
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
                    .sheet(item: $sharePayload) { payload in
                        DFKShareCardPreviewView(payload: payload)
                    }
                    .sheet(isPresented: $showingTimelineShareRangePicker) {
                        DFKTimelineShareRangePicker(initialDate: activeTimelineDate) { startDate, endDate in
                            prepareTimelineShare(startDate: startDate, endDate: endDate)
                        }
                    }
                    .sheet(isPresented: $isShowingSettings) {
                        NavigationStack {
                            SettingsView()
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button {
                                            isShowingSettings = false
                                        } label: {
                                            Image(systemName: "xmark").dfkToolbarDismissIcon()
                                        }
                                    }
                                }
                        }
                    }
                    .background(
                        EmptyView()
                            .sheet(isPresented: $isShowingFutureTripModal) {
                                FutureTripDraftModal()
                            }
                            .sheet(item: $selectedFutureTrip) { trip in
                                FutureTripDraftModal(editingTrip: trip)
                            }
                    )
                    .sheet(isPresented: $isShowingHistory) {
                        NavigationStack {
                            Group {
                                if isHistoryContentReady {
                                    HistoryListView(initialDate: activeTimelineDate, showImportOnAppear: requestedHistoryImport, onDateSelected: { selectedDate in
                                        isShowingHistory = false
                                        scrollToDate(selectedDate, using: proxy)
                                    }, onStatisticsVisibilityChanged: { isActive in
                                        isHistoryStatisticsActive = isActive
                                    })
                                    .onDisappear {
                                        requestedHistoryImport = false
                                    }
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color.dfkBackground)
                                        .accessibilityLabel("正在打开历史")
                                }
                            }
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    HStack(spacing: 18) {
                                        if isHistoryStatisticsActive {
                                            Button {
                                                NotificationCenter.default.post(name: .dfkShareHistoryStatistics, object: nil)
                                            } label: {
                                                Image(systemName: "square.and.arrow.up")
                                            }
                                            .accessibilityLabel("分享统计")
                                        }

                                        Button {
                                            isShowingHistory = false
                                        } label: {
                                            Image(systemName: "xmark").dfkToolbarDismissIcon()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: isShowingHistory) { _, isPresented in
                        historyContentPreparationTask?.cancel()

                        guard isPresented else {
                            isHistoryContentReady = false
                            isHistoryStatisticsActive = false
                            requestedHistoryImport = false
                            return
                        }

                        // Yield one event-loop turn so the sheet can begin its
                        // transition, then mount HistoryListView. The history
                        // view itself waits for its index before mounting the
                        // month grid, avoiding an empty-ring first frame.
                        isHistoryContentReady = false
                        historyContentPreparationTask = Task { @MainActor in
                            await Task.yield()
                            guard !Task.isCancelled, isShowingHistory else { return }
                            isHistoryContentReady = true
                        }
                    }
                    .sheet(isPresented: $showingAddPlaceSheet) {
                        AddPlaceSheet { newPlace in
                            modelContext.insert(newPlace)
                            try? modelContext.save()
                            CloudSettingsManager.shared.triggerDataSyncPulse()
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
                        .alert("确认删除行程计划？", isPresented: isShowingFutureTripDeletionAlert) {
                            Button("取消", role: .cancel) { futureTripPendingDeletion = nil }
                            Button("删除", role: .destructive) {
                                if let futureTripPendingDeletion {
                                    deleteFutureTrip(futureTripPendingDeletion)
                                }
                                futureTripPendingDeletion = nil
                            }
                        } message: {
                            Text("删除后该行程计划将不再出现在时间轴上。")
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
                } // ScrollViewReader
            } // NavigationStack
            if isInitialTimelineLoading {
                // This is outside the scroll view so its material reaches the
                // sheet's bottom edge. Keep the full title-bar band clear.
                GeometryReader { viewport in
                    initialTimelineLoadingOverlay
                        .frame(
                            width: viewport.size.width,
                            height: max(0, viewport.size.height - 64)
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                .allowsHitTesting(false)
            }
            resettingIndicator
        } // ZStack
        .fullScreenCover(item: Binding(
            get: { selectedMapPhotoAssetID.map { IdentifiableString(value: $0) } },
            set: { selectedMapPhotoAssetID = $0?.value }
        )) { item in
            let assetIDs = selectedFootprint?.photoAssetIDs ?? [item.value]
            let currentIndex = assetIDs.firstIndex(of: item.value) ?? 0
            PhotoFullscreenView(assetIDs: assetIDs, currentIndex: currentIndex)
        }
        .sheet(item: $selectedFootprint) { footprint in
            buildFootprintModalView(for: footprint)
                .presentationDetents([.large])
        }
        .sheet(item: $selectedFutureTripDetail) { trip in
            buildFutureTripDetailView(for: trip)
                .presentationDetents([.medium, .large])
        }
    } // body
    
    @ViewBuilder
    private func mainScrollView(proxy: ScrollViewProxy, viewport: GeometryProxy) -> some View {
                        ScrollView {
                            ScrollOffsetObserver(restorer: scrollRestorer) { metrics in
                                Task { @MainActor in
                                    applyScrollMetrics(metrics)
                                }
                            }
                            .frame(width: 0, height: 0)

                            LazyVStack(alignment: .leading, spacing: 0) {
                                if canLoadEarlierDates {
                                    TimelineLoadMoreButton(
                                        title: "查看更早的足迹",
                                        isLoading: isLoadingMoreEarlier,
                                        action: requestLoadEarlierDates
                                    )
                                    .opacity(hasCompletedInitialTimelinePositioning ? 1 : 0)
                                    .allowsHitTesting(hasCompletedInitialTimelinePositioning)
                                } else if initialTimelineLoadCompleted {
                                    TimelineLoadMoreButton(
                                        title: "从照片导入足迹",
                                        isLoading: false,
                                        action: {
                                            requestedHistoryImport = true
                                            isShowingHistory = true
                                        }
                                    )
                                    .opacity(hasCompletedInitialTimelinePositioning ? 1 : 0)
                                    .allowsHitTesting(hasCompletedInitialTimelinePositioning)
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

                                // Keep future plans out of the initial timeline
                                // layout. This prevents launch from fitting the
                                // map to future coordinates before today's data
                                // has finished loading.
                                if initialTimelineLoadCompleted && !undatedFutureTrips.isEmpty {
                                    undatedFutureTripsSection
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: ContinuousTimelineUndatedFutureTripsFramePreferenceKey.self,
                                                    value: geometry.frame(in: .global)
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
                            .scrollTargetLayout()
                        }
                        .scrollPosition(id: timelineScrollPositionBinding, anchor: .bottom)
                        .scrollDisabled(isCollapsed)
                        .coordinateSpace(name: "continuousTimelineScroll")
                        .onPreferenceChange(ContinuousTimelineDateFramePreferenceKey.self) { frames in
                            let viewportHeight = viewport.size.height
                            Task { @MainActor in
                                await Task.yield()
                                applyDateFrameUpdate(frames, viewportHeight: viewportHeight, using: proxy)
                            }
                        }
                        .onPreferenceChange(ContinuousTimelineUndatedFutureTripsFramePreferenceKey.self) { frame in
                            let viewportFrame = viewport.frame(in: .global)
                            let isFutureCurrent = frame.map { futureFrame in
                                // Future becomes the active timeline section
                                // only once its top reaches the scroll viewport
                                // top, just like a normal date header.
                                futureFrame.minY <= viewportFrame.minY &&
                                    futureFrame.maxY > viewportFrame.minY
                            } ?? false
                            guard isFutureCurrent != isViewingUndatedFutureTrips else { return }
                            isViewingUndatedFutureTrips = isFutureCurrent
                            undatedFutureTripsVisibilityChanged(isFutureCurrent)
                        }
                        .overlay(alignment: .bottom) {
                            if isCollapsed {
                                EmptyView()
                            } else if showsReturnToTodayButton {
                                Button {
                                    requestScrollToToday(using: proxy)
                                } label: {
                                    Label("回到当下", systemImage: "location.fill")
                                }
                                .returnToTodayButtonStyle()
                                .accessibilityLabel("回到当下")
                            } else {
                                Button {
                                    futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: activeTimelineDate)
                                    isShowingFutureTripModal = true
                                } label: {
                                    Label("行程计划", systemImage: "plus")
                                }
                                .returnToTodayButtonStyle()
                                .accessibilityLabel("行程计划")
                            }
                        }
                    .onChange(of: dates) { oldDates, newDates in
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
                    .onAppear {
                        scheduleInitialScrollToTodayIfNeeded(using: proxy)
                        scheduleInitialLoadingFallback()
                    }
                    .onChange(of: initialTimelineLoadCompleted) { _, _ in
                        scheduleInitialScrollToTodayIfNeeded(using: proxy)
                    }
                    .onChange(of: todayScrollRequest) { _, _ in
                        requestScrollToToday(using: proxy)
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
                            externalReloadViewportAnchor = scrollRestorer.captureAnchor()
                            freezesViewportDrivenUpdatesUntil = Date.distantFuture
                        } else {
                            // Don't force an immediate re-read here: latestDateFrames can still
                            // reflect stale/incomplete geometry from before the reload settled.
                            // Give layout a brief moment, then let the ordinary preference-key
                            // pipeline (which reports real, settled frames) resume driving date
                            // tracking on its own.
                            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.3)
                            if let anchor = externalReloadViewportAnchor {
                                scrollRestorer.restore(anchor, fallbackBottomDistance: anchor.bottomDistance)
                            }
                            externalReloadViewportAnchor = nil
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
                            }
                            freezesViewportDrivenUpdatesUntil = Date.distantFuture
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: FutureTrip.didChangeNotification)) { _ in
                        restoreFutureTripTimelinePosition(using: proxy)
                    }
                    .onDisappear {
                        initialTodayScrollTask?.cancel()
                        initialLoadingFallbackTask?.cancel()
                        calendarScrollRetryTask?.cancel()
                        calendarBackfillPinTask?.cancel()
                        calendarBackfillTask?.cancel()
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
    private func buildFootprintModalView(for footprint: Footprint) -> some View {
        FootprintModalView(
            footprint: footprint,
            autoFocus: false,
            isInline: false
        ) { didChange in
            guard didChange else { return }
            invalidateAndRefreshTimeline(containing: footprint.startTime)
            CloudSettingsManager.shared.triggerDataSyncPulse()
        }
        .environment(locationManager)
        .transition(.move(edge: .bottom))
    }
    
    @ViewBuilder
    private func buildFutureTripDetailView(for trip: FutureTrip) -> some View {
        FutureTripDetailView(
            trip: trip,
            isInline: false,
            presentationDetent: .constant(.medium),
            showDelayOptionsOnAppear: pendingFutureTripDelayOptionsID == trip.id,
            onDelayOptionsPresented: {
                pendingFutureTripDelayOptionsID = nil
            },
            showAbandonAlertOnAppear: pendingFutureTripAbandonAlertID == trip.id,
            onAbandonAlertPresented: {
                pendingFutureTripAbandonAlertID = nil
            },
            onDismiss: {
                selectedFutureTripDetail = nil
            },
            onEdit: {
                selectedFutureTrip = trip
            }
        )
        .environment(locationManager)
    }

    @ToolbarContentBuilder
    private func headerToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingHistory = true
            } label: {
                Image(systemName: "calendar.badge.clock")
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
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    if !isViewingUndatedFutureTrips {
                        Text(secondaryHeader)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
                let futureTripDates = futureTrips.filter(\.hasPlanDate).map { Calendar.current.startOfDay(for: $0.arrivalDate) }
                let activeDates = Set(availableDates.filter { $0 <= today }).union(futureTripDates)

                MiniCalendarView(
                    selectedDate: Binding(
                        get: { activeTimelineDate },
                        set: { _ in }
                    ),
                    availableDates: activeDates
                ) { date in
                    isShowingCalendar = false
                    let normalizedDate = Calendar.current.startOfDay(for: date)
                    scrollToDate(normalizedDate, using: proxy)
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
                Menu {
                    Button {
                        prepareTimelineShare()
                    } label: {
                        Label("分享当前日期足迹", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    Button {
                        showingTimelineShareRangePicker = true
                    } label: {
                        Label("选择日期范围分享", systemImage: "calendar.badge.plus")
                    }
                    Divider()
                    Button {
                        prepareFuturePlansShare()
                    } label: {
                        Label("分享未来计划", systemImage: "calendar.badge.clock")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享")

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
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

    private func prepareFuturePlansShare() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let selectedTrips = futureTrips.filter { !$0.hasPlanDate || $0.arrivalDate >= start }
        let rangeText = "未来计划"
        let coordinates = selectedTrips.map(\.coordinate)
        let loadingPayload = DFKShareCardFactory.loadingPayload(kind: .plan, rangeText: rangeText, coordinates: coordinates)
        sharePayload = loadingPayload
        let payloadID = loadingPayload.id
        var payload = DFKShareCardFactory.planPayload(
            title: "计划行程",
            rangeText: rangeText,
            trips: selectedTrips,
            activities: activityTypes
        )
        payload.id = payloadID
        DFKShareImageLoader.loadPlanMapImages(
            plans: payload.plans
        ) { mapImages in
            DFKShareImageLoader.loadBackgroundMapImages(coordinates: coordinates) { backgroundImages in
                payload.backgroundMapImage = backgroundImages.light ?? backgroundImages.dark
                payload.backgroundMapLightImage = backgroundImages.light
                payload.backgroundMapDarkImage = backgroundImages.dark
                payload.contentMapImage = mapImages.light ?? mapImages.dark
                payload.contentMapLightImage = mapImages.light
                payload.contentMapDarkImage = mapImages.dark
                sharePayload = payload
            }
        }
    }

    private func trips(in startDate: Date, through endDate: Date) -> [FutureTrip] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return futureTrips.filter { trip in
            trip.hasPlanDate && trip.arrivalDate >= start && trip.arrivalDate < end
        }
    }

    private func expandTimelineIfCollapsed() {
        guard isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            timelineDetent = .medium
        }
    }

    private func handleDateHeaderTap() {
        isShowingCalendar = true
    }

    private var dateHeader: String {
        if isViewingUndatedFutureTrips { return "未来" }
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

    private func applyScrollMetrics(_ metrics: ContinuousTimelineScrollMetrics) {
        guard metrics != scrollMetrics else { return }
        scrollMetrics = metrics
        latestScrollOffsetY = metrics.topOffsetY
        if scrollRestorer.isUserInteracting {
            lastUserInteractionTime = Date()
        }
    }

    private func applyDateFrameUpdate(
        _ frames: [Date: CGRect],
        viewportHeight: CGFloat,
        using proxy: ScrollViewProxy
    ) {
        if calendarScrollLockTarget == nil,
           calendarBackfillPinnedDate == nil,
           !shouldProcessDateFrameUpdate(frames, viewportHeight: viewportHeight) {
            return
        }

        latestDateFrames = frames
        latestViewportHeight = viewportHeight
        if let target = calendarScrollLockTarget, frames[target] != nil {
            scheduleLockedCalendarScroll(using: proxy)
            return
        }
        if let pinnedDate = calendarBackfillPinnedDate, frames[pinnedDate] != nil {
            scheduleCalendarBackfillPin(to: pinnedDate, using: proxy)
            return
        }
        guard !isFreezingViewportDrivenUpdates else { return }
        applyViewportDates(from: frames, viewportHeight: viewportHeight)
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

    private func headerVisibleDate(in frames: [Date: CGRect], viewportHeight: CGFloat) -> Date? {
        let bandTop: CGFloat = 52
        let headerProbeY = max(bandTop, viewportHeight * 0.38)

        if let probeDate = frames
            .filter({ _, frame in frame.minY <= headerProbeY && frame.maxY >= headerProbeY })
            .max(by: { $0.value.minY < $1.value.minY })?
            .key {
            return probeDate
        }

        return frames
            .filter { _, frame in frame.maxY > bandTop && frame.minY < viewportHeight }
            .min { first, second in
                abs(first.value.midY - headerProbeY) < abs(second.value.midY - headerProbeY)
            }?
            .key
    }

    private func applyViewportDates(from frames: [Date: CGRect], viewportHeight: CGFloat) {
        // The future section owns its active state while it is on screen.
        // Date-frame updates must not overwrite it with the preceding date.
        if isViewingUndatedFutureTrips { return }

        if scrollMetrics.bottomDistance < 8, let bottomDate = dates.last {
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
        mapDates.insert(Calendar.current.startOfDay(for: activeTimelineDate))
        visibleDatesChanged(mapDates)
    }

    private func shouldProcessDateFrameUpdate(_ frames: [Date: CGRect], viewportHeight: CGFloat) -> Bool {
        guard latestViewportHeight > 0 else { return true }
        guard abs(latestViewportHeight - viewportHeight) <= 1 else { return true }
        guard Set(frames.keys) == Set(latestDateFrames.keys) else { return true }

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
        case futureTrip(FutureTrip)
        case currentStay

        var id: String {
            switch self {
            case .timelineItem(let item, _): return item.id
            case .futureTrip(let trip): return trip.id.uuidString
            case .currentStay: return "currentStay"
            }
        }

        var sortTime: Date {
            switch self {
            case .timelineItem(let item, _): return item.startTime
            case .futureTrip(let trip): 
                return trip.arrivalDate
            case .currentStay: 
                return Date()
            }
        }
    }

    @ViewBuilder
    private func timelineDay(for date: Date) -> some View {
        let items = (timelinesByDate[date] ?? []).sorted { $0.startTime < $1.startTime }
        let trips = futureTrips(for: date)
        let tripSortTimes = futureTripSortTimes(for: trips, on: date)

        let mixedItems: [MixedTimelineItem] = {
            var mixed = [MixedTimelineItem]()
            for (index, item) in items.enumerated() {
                mixed.append(.timelineItem(item, index))
            }
            for trip in trips {
                mixed.append(.futureTrip(trip))
            }
            if Calendar.current.isDateInToday(date) {
                mixed.append(.currentStay)
            }
            mixed.sort { lhs, rhs in
                mixedSortTime(for: lhs, tripSortTimes: tripSortTimes) < mixedSortTime(for: rhs, tripSortTimes: tripSortTimes)
            }
            return mixed
        }()

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
            
            ForEach(mixedItems) { mixedItem in
                switch mixedItem {
                case .timelineItem(let item, let index):
                    ContinuousTimelineRow(
                        item: item,
                        nextStartTime: items.indices.contains(index + 1) ? items[index + 1].startTime : nil,
                        activityTypes: activityTypes,
                        showsContinuation: true,
                        usesMinimumBottomSpacing: shouldUseMinimumSpacingBeforeCurrentStay(item, at: index, in: items, date: date),
                        canMergeItem: canMergeAdjacentTimelineItem(item, at: index, in: items),
                        onTap: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                                switch item {
                                case .footprint(let footprint): selectedFootprint = storedFootprint(matching: footprint)
                                case .transport(let transport): selectedTransport = transport
                                }
                            }
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
                            guard case .footprint(let footprint) = item else { return }
                            footprintPendingSplit = storedFootprint(matching: footprint)
                        },
                        onToggleFavorite: {
                            guard case .footprint(let footprint) = item else { return }
                            toggleFavorite(for: footprint)
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
                case .currentStay:
                    CurrentStayTimelineCard(locationManager: locationManager)
                        .id(ScrollTarget.now)
                        
                    if !isImportantPlaceGuideDismissed && !allPlaces.contains(where: { $0.isUserDefined }) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 18)
                            }.frame(width: 54)
                            
                            ImportantPlaceGuide(isGuideDismissed: $isImportantPlaceGuideDismissed) {
                                showingAddPlaceSheet = true
                            }
                            .padding(.leading, -16)
                            .padding(.bottom, 14)
                        }
                    }
                case .futureTrip(let trip):
                    FutureTripTimelineRow(trip: trip, activityTypes: activityTypes)
                        .id(ScrollTarget.futureTrip(trip.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: trip.arrivalDate)
                            futureTripTimelineAnchorID = trip.id
                            withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                                selectedFutureTripDetail = trip
                            }
                        }
                        .contextMenu {
                            if !trip.isCompleted {
                                Button {
                                    futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: trip.arrivalDate)
                                    futureTripTimelineAnchorID = trip.id
                                    selectedFutureTrip = trip
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                            }

                            Button(role: .destructive) {
                                futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: trip.arrivalDate)
                                futureTripTimelineAnchorID = nil
                                futureTripPendingDeletion = trip
                            } label: {
                                Label("删除", systemImage: "trash")
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

    private var undatedFutureTrips: [FutureTrip] {
        FutureTrip.dayOrdered(futureTrips.filter { !$0.hasPlanDate && !$0.isCompleted })
    }

    private var undatedFutureTripsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineDateGapConnector(skippedDays: 7)

            ZStack(alignment: .leading) {
                DottedTimelineSeparator()
                    .offset(y: -12)
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2, height: 30)
                    .offset(x: ContinuousTimelineLayout.markerCenterX - 1)
                Text("未来")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: ContinuousTimelineLayout.dateColumnWidth, alignment: .leading)
            }
            .frame(height: 30)

            ForEach(undatedFutureTrips) { trip in
                FutureTripTimelineRow(trip: trip, activityTypes: activityTypes)
                    .id(ScrollTarget.futureTrip(trip.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: activeTimelineDate)
                        futureTripTimelineAnchorID = trip.id
                        withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                            selectedFutureTripDetail = trip
                        }
                    }
                    .contextMenu {
                        Button {
                            futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: activeTimelineDate)
                            futureTripTimelineAnchorID = trip.id
                            selectedFutureTrip = trip
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: activeTimelineDate)
                            futureTripTimelineAnchorID = nil
                            futureTripPendingDeletion = trip
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func requestScrollToToday(using proxy: ScrollViewProxy) {
        if let target = targetScrollDate {
            scrollToDate(target, using: proxy)
            targetScrollDate = nil
            return
        }
        
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
        guard dates.contains(targetDate) else { return }

        // Mirrors scrollToToday's target/anchor choice: when there's an ongoing stay or
        // transport, center that card in the timeline instead of pinning it to the bottom.
        let hasCurrentStatus = locationManager.potentialStopStartLocation != nil || locationManager.uiIsMoving

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
        guard initialTimelineLoadCompleted, !didScheduleInitialScrollToToday else { return }
        didScheduleInitialScrollToToday = true
        
        if let target = targetScrollDate {
            scrollToDate(target, using: proxy)
            targetScrollDate = nil
            // Widget deep links arrive before the sheet's first positioning pass.
            // Keep the normal pass so the initial-position state also settles.
            scheduleInitialScrollToToday(using: proxy)
        } else if todayScrollRequest == 0 {
            scheduleInitialScrollToToday(using: proxy)
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            allowsEarlierDatePrefetch = true
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

    private func futureTrips(for date: Date) -> [FutureTrip] {
        let calendar = Calendar.current
        return FutureTrip.dayOrdered(futureTrips
            .filter { $0.hasPlanDate && !$0.isCompleted && calendar.isDate($0.arrivalDate, inSameDayAs: date) }
        )
    }

    private func futureTripSortTimes(for trips: [FutureTrip], on date: Date) -> [UUID: Date] {
        var sortTimes: [UUID: Date] = [:]
        var anchorTime = Calendar.current.startOfDay(for: date)
        var orderedOffset = 1
        let now = Date()

        for trip in trips {
            if trip.isOrdered {
                let orderedTime = anchorTime.addingTimeInterval(TimeInterval(orderedOffset))
                sortTimes[trip.id] = max(orderedTime, now.addingTimeInterval(TimeInterval(orderedOffset)))
                orderedOffset += 1
            } else {
                let effectiveArrivalDate = trip.effectiveArrivalDate(now: now)
                sortTimes[trip.id] = effectiveArrivalDate
                anchorTime = effectiveArrivalDate
                orderedOffset = 1
            }
        }

        return sortTimes
    }

    private func mixedSortTime(for item: MixedTimelineItem, tripSortTimes: [UUID: Date]) -> Date {
        switch item {
        case .futureTrip(let trip):
            return tripSortTimes[trip.id] ?? trip.arrivalDate
        default:
            return item.sortTime
        }
    }

    private func deleteFutureTrip(_ trip: FutureTrip) {
        futureTripTimelineAnchorDate = Calendar.current.startOfDay(for: trip.arrivalDate)
        futureTripTimelineAnchorID = nil
        modelContext.delete(trip)
        try? modelContext.save()
        FutureTrip.postDidChangeNotification()
    }

    private func restoreFutureTripTimelinePosition(using proxy: ScrollViewProxy) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let anchorDate = futureTripTimelineAnchorDate ?? calendar.startOfDay(for: activeTimelineDate)
        let anchorID = futureTripTimelineAnchorID
        futureTripTimelineAnchorDate = nil
        futureTripTimelineAnchorID = nil

        Task { @MainActor in
            for delay in [0, 120_000_000, 320_000_000, 650_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }

                if let anchorID, dates.contains(anchorDate) {
                    applySelectedCalendarDate(anchorDate)
                    proxy.scrollTo(ScrollTarget.futureTrip(anchorID), anchor: .center)
                } else if calendar.isDate(anchorDate, inSameDayAs: today) || !dates.contains(anchorDate) {
                    scrollToToday(using: proxy, animated: false)
                } else {
                    applySelectedCalendarDate(anchorDate)
                    proxy.scrollTo(ScrollTarget.date(anchorDate), anchor: .center)
                }
            }
        }
    }

    private func scrollToDate(_ date: Date, using proxy: ScrollViewProxy) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        calendarBackfillTask?.cancel()
        calendarScrollRetryTask?.cancel()
        calendarScrollRetryTask = nil

        // Lock viewport-driven date updates while the destination is loaded.
        // Do not change activeTimelineDate yet: timelineDates automatically
        // inserts that value, which would create an unloaded placeholder and
        // make the bottom-anchored ScrollView move before the real row exists.
        calendarScrollLockTarget = normalizedDate
        pendingCalendarBackfillDates = timelineDatesToBackfill(afterSelecting: normalizedDate)

        Task { @MainActor in
            if !dates.contains(normalizedDate) {
                guard await loadDate(normalizedDate) else {
                    if calendarScrollLockTarget == normalizedDate {
                        calendarScrollLockTarget = nil
                        pendingCalendarBackfillDates = []
                        freezesViewportDrivenUpdatesUntil = nil
                    }
                    return
                }
            }

            // A newer calendar selection may have replaced this request while
            // the target date was loading.
            guard calendarScrollLockTarget == normalizedDate else { return }
            applySelectedCalendarDate(normalizedDate)
            timelineScrollPosition = .date(normalizedDate)
            scheduleLockedCalendarScroll(using: proxy)
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
                timelineScrollPosition = .date(target)

                if attempt == 0 {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(ScrollTarget.date(target), anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(ScrollTarget.date(target), anchor: .bottom)
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
                proxy.scrollTo(ScrollTarget.date(date), anchor: .bottom)
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func isCalendarScrollTargetVisible(_ date: Date) -> Bool {
        guard latestViewportHeight > 0, let frame = latestDateFrames[date] else { return false }
        // Calendar navigation scrolls the selected day with a .bottom anchor.
        // Merely being somewhere inside the viewport is not success: recently
        // loaded days can still have a stale/partially visible frame while the
        // calendar popover is dismissing, which used to stop retries after the
        // small bottom nudge the user observed.
        return abs(frame.maxY - latestViewportHeight) <= 32
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
                proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .bottom)
                _ = await loadBackfillDates(batch)
                applySelectedCalendarDate(pinnedDate)
                proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .bottom)
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(ScrollTarget.date(pinnedDate), anchor: .bottom)
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

    private func requestLoadEarlierDates() {
        guard !isLoadingMoreEarlier else { return }

        Task { @MainActor in
            isLoadingMoreEarlier = true
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let anchorBeforeLoading = scrollRestorer.captureAnchor()
            let bottomDistanceBeforeLoading = anchorBeforeLoading?.bottomDistance ?? scrollMetrics.bottomDistance
            scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
            let didLoad = await loadEarlierDates()
            isLoadingMoreEarlier = false

            if didLoad {
                // Inserting history above the viewport increases content height.
                // Restore the previous offset plus that height so the rows under
                // the user's finger remain visually fixed.
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

    private func requestLoadDates(after earlierDate: Date, before laterDate: Date) {
        let calendar = Calendar.current
        let normalizedEarlierDate = calendar.startOfDay(for: earlierDate)
        guard !loadingGapAfterDates.contains(normalizedEarlierDate) else { return }
        let datesToLoad = Array(loadableTimelineDates(between: earlierDate, and: laterDate).prefix(calendarBackfillBatchSize))
        guard !datesToLoad.isEmpty else { return }

        Task { @MainActor in
            loadingGapAfterDates.insert(normalizedEarlierDate)
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let didLoad = await loadGapDates(datesToLoad)
            loadingGapAfterDates.remove(normalizedEarlierDate)
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
        let datesToLoad = Array(loadableTimelineDates(between: earlierDate, and: laterDate).suffix(calendarBackfillBatchSize))
        guard !datesToLoad.isEmpty else { return }

        Task { @MainActor in
            loadingGapBeforeDates.insert(normalizedLaterDate)
            freezesViewportDrivenUpdatesUntil = Date().addingTimeInterval(0.45)
            let anchorBeforeLoading = scrollRestorer.captureAnchor()
            let bottomDistanceBeforeLoading = anchorBeforeLoading?.bottomDistance ?? scrollMetrics.bottomDistance
            scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
            let didLoad = await loadGapDates(datesToLoad)
            loadingGapBeforeDates.remove(normalizedLaterDate)
            if didLoad {
                scrollRestorer.restore(anchorBeforeLoading, fallbackBottomDistance: bottomDistanceBeforeLoading)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 340_000_000)
                    guard !scrollRestorer.isRestoring else { return }
                    freezesViewportDrivenUpdatesUntil = nil
                    applyViewportDates(from: latestDateFrames, viewportHeight: latestViewportHeight)
                }
            } else {
                freezesViewportDrivenUpdatesUntil = nil
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

        // A user-initiated merge owns the resulting interval.  Persist that
        // ownership even if neither source segment had its type edited before;
        // otherwise the periodic timeline sifter treats the merged record as
        // automatic data and can split/reclassify it on a later launch.
        let selectedType = base.manualTypeRaw
            ?? other.manualTypeRaw
            ?? (baseDurationBeforeMerge >= otherDurationBeforeMerge ? base.typeRaw : other.typeRaw)
        base.manualTypeRaw = selectedType
        base.typeRaw = selectedType

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

private struct ContinuousTimelineUndatedFutureTripsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
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
        private var lastPublishedMetrics: ContinuousTimelineScrollMetrics?

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
                adjustedBottomInset: scrollView.adjustedContentInset.bottom,
                isUserInteracting: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
            )
            guard shouldPublish(metrics) else { return }
            lastPublishedMetrics = metrics

            if Thread.isMainThread {
                onChange(metrics)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onChange(metrics)
                }
            }
        }

        private func shouldPublish(_ metrics: ContinuousTimelineScrollMetrics) -> Bool {
            guard let lastPublishedMetrics else { return true }

            if metrics.isUserInteracting != lastPublishedMetrics.isUserInteracting { return true }
            if abs(metrics.contentHeight - lastPublishedMetrics.contentHeight) > 1 { return true }
            if abs(metrics.viewportHeight - lastPublishedMetrics.viewportHeight) > 1 { return true }
            if abs(metrics.adjustedTopInset - lastPublishedMetrics.adjustedTopInset) > 1 { return true }
            if abs(metrics.adjustedBottomInset - lastPublishedMetrics.adjustedBottomInset) > 1 { return true }

            let offsetThreshold: CGFloat = metrics.isUserInteracting ? 24 : 8
            return abs(metrics.contentOffsetY - lastPublishedMetrics.contentOffsetY) >= offsetThreshold ||
                abs(metrics.topOffsetY - lastPublishedMetrics.topOffsetY) >= offsetThreshold
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
            adjustedBottomInset: scrollView.adjustedContentInset.bottom,
            isUserInteracting: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
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

enum ContinuousTimelineLayout {
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
    let onIgnore: () -> Void
    let onDelete: () -> Void
    @State private var isResolvingUnknownPlace = false
    @State private var isPlaceTitleBreathing = false

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
                Menu {
                    if case .footprint(let footprint) = item {
                        Button {
                            footprint.updateActivityType(to: nil, in: modelContext)
                            try? modelContext.save()
                        } label: {
                            Label("无", systemImage: "circle.slash")
                        }
                        
                        Divider()
                        
                        ForEach(activityTypes) { type in
                            Button {
                                footprint.updateActivityType(to: type.id.uuidString, in: modelContext)
                                try? modelContext.save()
                            } label: {
                                Label(type.name, systemImage: type.icon)
                            }
                        }
                    } else if case .transport(let transport) = item {
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
                    }
                } label: {
                    if case .footprint = item {
                        ZStack {
                            Circle()
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                                .frame(width: markerSize, height: markerSize)

                            Circle()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [tint.lighter(by: 0.25), tint]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: markerSize - 5, height: markerSize - 5)

                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: icon)
                            .font(markerIconFont)
                            .foregroundStyle(markerForeground)
                            .frame(width: markerSize, height: markerSize)
                            .background(markerBackground, in: Circle())
                            .overlay(Circle().strokeBorder(markerStroke, lineWidth: markerStrokeWidth))
                            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                    }
                }
                .buttonStyle(.plain)
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
        .task(id: unresolvedFootprintID) {
            await retryUnknownFootprintLocationIfNeeded()
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
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

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
                if let thumbnail {
                    self.image = thumbnail
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    self.requestID = nil
                }
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
    @State private var showingOngoingLocationSearch = false

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
                    Menu {
                        SuggestionsMenuContent(
                            locationManager: locationManager,
                            coordinate: ongoingSelectionCoordinate,
                            forOngoing: true
                        ) {
                            showingOngoingLocationSearch = true
                        }
                    } label: {
                        Text(resolvedTitle)
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
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
            
            Spacer(minLength: 0)
        }
        .frame(minHeight: 92, alignment: .top)
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

    private var canSelectOngoingPlace: Bool {
        locationManager.potentialStopStartLocation != nil
    }

    private var ongoingSelectionCoordinate: CLLocationCoordinate2D? {
        locationManager.lastLocation?.coordinate ?? locationManager.potentialStopStartLocation?.coordinate
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
        return String(format: "当前速度 %.1f 千米/小时", speedKmh)
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
    func returnToTodayButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .font(.headline.weight(.semibold))
        }
    }

    @ViewBuilder
    func mapLocationButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.circle)
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
