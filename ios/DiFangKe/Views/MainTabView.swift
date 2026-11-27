import SwiftUI
import SwiftData
import UIKit

// Scope Duo-specific layout changes to the hardware, including its simulator.
enum IPhoneDuo {
    static let isCurrent: Bool = {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
#else
        var info = utsname()
        guard uname(&info) == 0 else { return false }
        return withUnsafeBytes(of: &info.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) == "iPhone19,4"
        }
#endif
    }()
}

struct DisplayFoldDivision: Equatable {
    let stacksVertically: Bool
    let leadingExtent: CGFloat

    let gap: ClosedRange<CGFloat>

    init?(_ geometry: GeometryProxy, activeOnly: Bool = false) {
        guard #available(iOS 27.1, *),
              let fold = geometry.reservedRegions(kind: .division).first(where: { !activeOnly || $0.isActive }) else { return nil }
        stacksVertically = fold.frame.width > fold.frame.height
        leadingExtent = stacksVertically ? fold.frame.midY : fold.frame.midX
        let extent = stacksVertically ? geometry.size.height : geometry.size.width
        let start = stacksVertically ? fold.frame.minY : fold.frame.minX
        let end = stacksVertically ? fold.frame.maxY : fold.frame.maxX
        gap = max(0, min(start, extent))...max(0, min(end, extent))
        guard leadingExtent > 0, leadingExtent < extent else { return nil }
    }

    static func layout(for division: Self?) -> AnyLayout {
        if division?.stacksVertically == true { return AnyLayout(VStackLayout(spacing: 0)) }
        return AnyLayout(HStackLayout(spacing: 0))
    }
}

extension EnvironmentValues {
    var usesWideDuoLayout: Bool { IPhoneDuo.isCurrent && horizontalSizeClass == .regular }

    var duoVerticalBarEdge: HorizontalEdge? {
        if #available(iOS 27.1, *), IPhoneDuo.isCurrent { return toolbarVerticalEdge }
        return nil
    }
}

// The native grabber area plus the two-line navigation header.
let collapsedTimelineDetentHeight: CGFloat = UINavigationBar().sizeThatFits(.zero).height + 20
let nativeTabBarHeight: CGFloat = UITabBar().sizeThatFits(.zero).height
let timelineUnderTabBarColor = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
})

/// An explicit navigation request, including repeated requests for the same day.
struct TimelineDestination: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    var footprintID: UUID?
}

/// Owns navigation. Only Records hosts a map and a native resizable sheet.
struct MainTabView: View {
    private enum Tab: Hashable {
        case records, trip, review, settings
    }

    var initialDate: Date?
    var tripContainer: ModelContainer?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var pastMemory: PastFootprintMemory?
    @State private var pastMemoryPhotos: [String] = []
    @GestureState(resetTransaction: Transaction(animation: .easeOut)) private var bannerDragOffset: CGFloat = 0
    @State private var bannerPresentation = PastMemoryBannerPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memoryRefresh = 0
    @State private var selectedTab: Tab = .records
    @Environment(LocationManager.self) private var locationManager
    @State private var showingDashboard = false
    @State private var isPresented = true
    @State private var presentationDetent: PresentationDetent = .medium
    /// A sheet stacked on the records sheet (calendar, footprint detail) is
    /// at full height; it covers the tab bar area like the large detent does.
    @State private var hasFullHeightStackedSheet = false
    @State private var selectedTransport: Transport?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.duoVerticalBarEdge) private var verticalBarEdge
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var destination: TimelineDestination?
    @State private var usesColumnLayout = false
    @State private var returnToNowRequest = 0
    @State private var isRecordPlaybackActive = false

    private var recordTabIcon: String {
        guard selectedTab == .records else {
            return "point.bottomleft.forward.to.point.topright.scurvepath"
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activeDate = calendar.startOfDay(for: selectedDate)
        return activeDate < today
            ? "location.fill.viewfinder"
            : "point.bottomleft.forward.to.point.topright.scurvepath"
    }

    private var recordTabTitle: String {
        guard selectedTab == .records else { return "足迹" }
        return Calendar.current.isDateInToday(selectedDate) ? "足迹" : "回到当下"
    }

    var body: some View {
        GeometryReader { geometry in
            let usesColumns = horizontalSizeClass == .regular
                || geometry.size.width > geometry.size.height
            TimelineScene(
                initialDate: initialDate,
                isActive: selectedTab == .records,
                isSideBySide: usesColumns,
                activeTimelineDate: $selectedDate,
                timelineDetent: $presentationDetent,
                selectedTransport: $selectedTransport,
                destination: $destination,
                returnToNowRequest: returnToNowRequest,
                openDashboard: { showingDashboard = true },
                onRequestRecords: { selectedTab = .records },
                onPlaybackStateChanged: { isRecordPlaybackActive = $0 }
            ) { map, records in
                let landscapeTopInset = geometry.size.width > geometry.size.height ? geometry.safeAreaInsets.top : nil
                nativeTabs(records: AnyView(recordsWithBanner(map: map, records: records, usesColumns: usesColumns,
                                                              landscapeTopInset: landscapeTopInset)))
            }
            .onChange(of: usesColumns, initial: true) { _, newValue in
                usesColumnLayout = newValue

                // The portrait sheet host leaves the hierarchy while the
                // system split view is active. Drive the presentation binding
                // through false so returning to portrait creates a new native
                // sheet instead of retaining the stale presented state.
                isPresented = false
                guard !newValue else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard !usesColumnLayout else { return }
                    isPresented = true
                }
            }
        }
        .fullScreenCover(isPresented: $showingDashboard) {
            FootprintDashboard(locationManager: locationManager)
        }
        .onOpenURL(perform: handleTripDeepLink)
    }

    private func pastMemoryBanner(_ memory: PastFootprintMemory, open: @escaping () -> Void, collapse: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Group {
                        if pastMemoryPhotos.isEmpty {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title2)
                                .foregroundStyle(Color.dfkAccent)
                        } else {
                            ContinuousTimelinePhotoThumbnail(assetIDs: pastMemoryPhotos, fillsAvailableSpace: true,
                                                             prefersEarliestPhoto: true)
                        }
                    }
                    .frame(width: 60, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("往年今日 · \(memory.yearsAgo)年前")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.dfkAccent)
                        Text(memory.title).font(.headline).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            Button(action: collapse) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭往年今日")
        }
        .padding(10)
        .dfkDetailMaterial(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(coordinateSpace: .global)
                .updating($bannerDragOffset) { value, offset, _ in
                    let delta = value.translation
                    offset = -delta.height > abs(delta.width) ? delta.height : 0
                }
                .onEnded { value in
                    let delta = value.translation
                    if -delta.height > abs(delta.width) { collapse() }
                }
        )
        .offset(y: reduceMotion ? 0 : bannerDragOffset)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func recordsWithBanner(map: AnyView, records: AnyView, usesColumns: Bool, landscapeTopInset: CGFloat?) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let viewingToday = Calendar.current.isDate(selectedDate, inSameDayAs: today)
        let canShowBanner = viewingToday && bannerPresentation.collapsedOn != today
        let eligible = selectedTab == .records && scenePhase == .active && canShowBanner && pastMemory != nil
        let collapsed = bannerPresentation.collapsedOn == today
        func collapse() {
            withAnimation(.easeOut) { bannerPresentation.collapsedOn = today }
        }
        let mapWithBanner = map.environment(\.pastMemoryPresentation, pastMemory == nil ? nil : bannerPresentation).overlay(alignment: .top) {
            if !collapsed, bannerPresentation.shownOn == today, let pastMemory {
                pastMemoryBanner(pastMemory, open: {
                    collapse()
                    openRecord(date: pastMemory.startTime)
                }, collapse: collapse)
                    .if(landscapeTopInset != nil) { banner in
                        banner
                            .padding(.top, landscapeTopInset ?? 0)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        return recordScreen(map: AnyView(mapWithBanner), records: records, usesColumns: usesColumns)
        .task(id: eligible ? today : nil) {
            guard eligible, bannerPresentation.shownOn != today else { return }
            do {
                try await Task.sleep(for: .seconds(AppConfig.shared.pastMemoryBannerDelay))
            } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { bannerPresentation.shownOn = today }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FootprintDataChanged"))) { _ in
            memoryRefresh += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            memoryRefresh += 1
        }
        .task(id: "\(memoryRefresh)-\(selectedTab == .records)-\(scenePhase == .active)") {
            guard selectedTab == .records, scenePhase == .active else { return }
            let memory = await PastFootprintMemory.load(for: Date(), container: modelContext.container)
            guard !Task.isCancelled else { return }
            pastMemory = memory
            pastMemoryPhotos = memory?.assetIDs ?? []
            guard let memory else { return }
            let photos = await PhotoService.shared.displayableAssetIDs(
                storedAssetIDs: memory.assetIDs, startTime: memory.startTime, endTime: memory.endTime,
                coordinate: CLLocationCoordinate2D(latitude: memory.latitude, longitude: memory.longitude)
            )
            guard !Task.isCancelled else { return }
            pastMemoryPhotos = photos
        }
    }

    @ViewBuilder
    private func recordScreen(map: AnyView, records: AnyView, usesColumns: Bool) -> some View {
        if usesColumns {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                records
                    .if(isRecordPlaybackActive && (UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass != .regular)) { view in
                        view.navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 280)
                    }
                    .if(UIDevice.current.userInterfaceIdiom == .pad && !isRecordPlaybackActive) { view in
                        view.navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
                    }
            } detail: {
                map
            }
            .navigationSplitViewStyle(.balanced)
            // Landscape iPhones can retain a compact horizontal size class.
            // This branch has already chosen a two-column layout from the
            // available geometry; prevent the system split from collapsing it.
            .environment(\.horizontalSizeClass, .regular)
        } else {
            ZStack(alignment: .bottom) {
                // Keep the map in the app window so it also appears underneath
                // the native floating tab bar, outside the sheet's window. The
                // map extends itself; its controls keep the safe area.
                map

                // Transport detail shows its map down to the bottom edge.
                if verticalBarEdge == nil, selectedTransport == nil, presentationDetent == .large || hasFullHeightStackedSheet {
                    // The record content ends above the native tab bar. Draw
                    // only outside that content rectangle, behind the floating
                    // tab bar and its lower safe-area margin.
                    timelineUnderTabBarColor
                        .frame(maxWidth: .infinity)
                        .frame(height: nativeTabBarHeight + 40)
                        .offset(y: nativeTabBarHeight + 40)
                        .allowsHitTesting(false)
                }

                RecordSheetContainer(
                    isActive: selectedTab == .records && !showingDashboard,
                    detent: presentationDetent,
                    onFullHeightStackedSheetChange: { hasFullHeightStackedSheet = $0 }
                ) {
                    Color.clear
                        .sheet(isPresented: $isPresented) {
                            records
                                .presentationDetents(
                                    [.height(collapsedTimelineDetentHeight), .medium, .large],
                                    selection: $presentationDetent
                                )
                                .presentationDragIndicator(.visible)
                                .presentationContentInteraction(.scrolls)
                                .interactiveDismissDisabled()
                                .presentationBackgroundInteraction(.enabled)
                        }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    @ViewBuilder
    private func nativeTabs(records: AnyView) -> some View {
        if #available(iOS 27.1, *), IPhoneDuo.isCurrent {
            tabs(records: records)
                .toolbarVerticalCompressionBehavior(.prefersTabBar)
        } else if #available(iOS 18.0, *) {
            tabs(records: records).tabViewStyle(.tabBarOnly)
        } else {
            tabs(records: records)
        }
    }

    private func tabs(records: AnyView) -> some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .records && selectedTab == .records {
                    returnToNowRequest &+= 1
                }
                selectedTab = newTab
            }
        )) {
            records
                .tabItem { Label(recordTabTitle, systemImage: recordTabIcon) }
                .tag(Tab.records)
            Group {
                if let tripContainer {
                    NavigationStack { TripView(isActive: selectedTab == .trip) }
                        .modelContainer(tripContainer)
                } else {
                    NavigationStack {
                        ContentUnavailableView("行程数据不可用", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .tabItem { Label("出行", systemImage: "map") }
            .tag(Tab.trip)
            ReviewTabView(
                initialDate: selectedDate,
                onDateSelected: { date in openRecord(date: date) },
                onFootprintSelected: { footprint in
                    openRecord(date: footprint.startTime, footprintID: footprint.footprintID)
                }
            )
            .tabItem { Label("回顾", systemImage: "chart.bar.xaxis.ascending.badge.clock") }
            .tag(Tab.review)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gear") }
                .tag(Tab.settings)
        }
    }

    private func openRecord(date: Date, footprintID: UUID? = nil) {
        destination = TimelineDestination(date: date, footprintID: footprintID)
        selectedTab = .records
    }

    private func handleTripDeepLink(_ url: URL) {
        guard url.scheme == "difangke", url.host == "trip",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let tripValue = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let tripID = UUID(uuidString: tripValue) else { return }

        selectedTab = .trip
        if url.path == "/action",
           components.queryItems?.first(where: { $0.name == "type" })?.value == "arrive",
           let stopValue = components.queryItems?.first(where: { $0.name == "stop" })?.value,
           let stopID = UUID(uuidString: stopValue) {
            TripScanManager.shared.requestPlannedStopArrivalConfirmation(stopID, tripID: tripID)
        } else {
            TripScanManager.shared.requestOpenTrip(tripID)
        }
    }
}

private struct ReviewTabView: View {
    let initialDate: Date
    let onDateSelected: (Date) -> Void
    let onFootprintSelected: (Footprint) -> Void
    @State private var isStatisticsActive = false

    var body: some View {
        NavigationStack {
            HistoryListView(
                initialDate: initialDate,
                onDateSelected: onDateSelected,
                onFootprintPresentationChanged: { footprint in
                    if let footprint { onFootprintSelected(footprint) }
                },
                onStatisticsVisibilityChanged: { isStatisticsActive = $0 }
            )
            .navigationTitle("回顾")
            .toolbar {
                if isStatisticsActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            NotificationCenter.default.post(name: .dfkShareHistoryStatistics, object: nil)
                        } label: {
                            Label("分享统计", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

/// A scene-local window limits the system presentation to the Records content
/// rectangle. It does not replace the sheet's presentation controller, gestures,
/// detents or appearance, and never moves/reparents the native tab bar.
private struct RecordSheetContainer<Content: View>: UIViewControllerRepresentable {
    // Pass only what the records views need. Overwriting the auxiliary
    // window's whole environment with the app window's replaced SwiftUI's own
    // presentation context on every update, rebuilding stacked sheets.
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    // Only scenes SwiftUI manages get a real phase; this hand-made window
    // would otherwise report `.background` forever, which freezes every
    // viewport-driven timeline update.
    @Environment(\.scenePhase) private var scenePhase
    let isActive: Bool
    let detent: PresentationDetent
    let onFullHeightStackedSheetChange: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> RecordSheetHostController {
        RecordSheetHostController()
    }

    func updateUIViewController(_ controller: RecordSheetHostController, context: Context) {
        controller.onFullHeightStackedSheetChange = onFullHeightStackedSheetChange
        controller.setContent(AnyView(
            content()
                .environment(locationManager)
                .modelContext(modelContext)
                .environment(\.scenePhase, scenePhase)
        ), active: isActive)
        controller.requestDetent(detent)
    }

    static func dismantleUIViewController(_ controller: RecordSheetHostController, coordinator: ()) {
        controller.tearDown()
    }
}

private final class RecordSheetHostController: UIViewController {
    private var recordWindow: UIWindow?
    private var hostingController: UIHostingController<AnyView>?
    private var content = AnyView(EmptyView())
    private var active = false
    private var appeared = false
    private var requestedDetent: PresentationDetent?
    private var stackedSheetObservations: [NSKeyValueObservation] = []
    private var observedStackedSheets: [ObjectIdentifier] = []
    private var hasFullHeightStackedSheet = false
    private var hasFullScreenStackedPresentation = false
    var onFullHeightStackedSheetChange: ((Bool) -> Void)?

    override func loadView() {
        // This view only measures the Records rectangle in the app window. It
        // sits above the map there, so it must never take the map's touches.
        view = RecordSheetPlaceholderView()
        view.backgroundColor = .clear
    }

    func setContent(_ content: AnyView, active: Bool) {
        self.content = content
        self.active = active
        hostingController?.rootView = content
        updateWindow()
        // Stacked sheets are presented and dismissed from SwiftUI state
        // updates; re-check once UIKit has applied them.
        DispatchQueue.main.async { [weak self] in self?.stackedPresentationsDidChange() }
    }

    /// SwiftUI does not forward a programmatic selection change to a sheet
    /// presented from this auxiliary window (e.g. collapsing on map
    /// interaction). Apply only actual binding changes, so a user's drag,
    /// which UIKit owns until it ends, is never overridden.
    func requestDetent(_ detent: PresentationDetent) {
        guard detent != requestedDetent else { return }
        requestedDetent = detent
        guard let sheet = hostingController?.presentedViewController?.sheetPresentationController else { return }
        let identifier: UISheetPresentationController.Detent.Identifier?
        if detent == .large {
            identifier = .large
        } else if detent == .medium {
            identifier = .medium
        } else {
            identifier = sheet.detents.map(\.identifier).first { $0 != .medium && $0 != .large }
        }
        guard let identifier, sheet.selectedDetentIdentifier != identifier else { return }
        sheet.animateChanges {
            sheet.selectedDetentIdentifier = identifier
        }
    }

    /// Sheets stacked above the records sheet live in this window; their
    /// detents are owned by UIKit (see FootprintDetailView), so observe them here.
    fileprivate func stackedPresentationsDidChange() {
        var sheets: [UIViewController] = []
        var presented = hostingController?.presentedViewController?.presentedViewController
        while let controller = presented {
            if !controller.isBeingDismissed { sheets.append(controller) }
            presented = controller.presentedViewController
        }

        let identifiers = sheets.map(ObjectIdentifier.init)
        if identifiers != observedStackedSheets {
            observedStackedSheets = identifiers
            // A detent change resizes the presented view; its layer's model
            // bounds update as soon as UIKit settles on the new detent.
            // Bounds follow detent changes; position follows dismissal.
            stackedSheetObservations = sheets.flatMap { controller -> [NSKeyValueObservation] in
                guard let layer = controller.presentationController?.presentedView?.layer else { return [] }
                let handler: (CALayer, Any) -> Void = { [weak self] _, _ in
                    DispatchQueue.main.async { self?.stackedPresentationsDidChange() }
                }
                return [
                    layer.observe(\.bounds) { layer, change in handler(layer, change) },
                    layer.observe(\.position) { layer, change in handler(layer, change) }
                ]
            }
        }

        let isFullHeight = sheets.contains { controller in
            // Alerts and other non-sheet presentations leave the tab bar area alone.
            guard let sheet = controller.sheetPresentationController else { return false }
            let identifier = sheet.selectedDetentIdentifier ?? sheet.detents.first?.identifier
            return identifier == .large
        }
        let isFullScreen = sheets.contains { controller in
            controller.modalPresentationStyle == .fullScreen
                || controller.modalPresentationStyle == .overFullScreen
        }
        if isFullScreen != hasFullScreenStackedPresentation {
            hasFullScreenStackedPresentation = isFullScreen
            updateWindow()
        }
        if isFullHeight != hasFullHeightStackedSheet {
            hasFullHeightStackedSheet = isFullHeight
            onFullHeightStackedSheetChange?(isFullHeight)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        updateWindow()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        recordWindow?.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateWindow()
    }

    private func updateWindow() {
        guard active, appeared, let parentWindow = view.window,
              let scene = parentWindow.windowScene, !view.bounds.isEmpty else {
            recordWindow?.isHidden = true
            return
        }
        var rectInWindow = view.convert(view.bounds, to: parentWindow)
        // On Duo the tab strip can occupy either side. Constrain the auxiliary
        // sheet window to the native tab controller’s actual content width.
        if #available(iOS 27.1, *), IPhoneDuo.isCurrent, let tabs = tabBarController {
            let guide = tabs.contentLayoutGuide
            if let owner = guide.owningView, !guide.layoutFrame.isEmpty {
                let available = owner.convert(guide.layoutFrame, to: parentWindow)
                let left = max(rectInWindow.minX, available.minX)
                let right = min(rectInWindow.maxX, available.maxX)
                if right > left {
                    rectInWindow.origin.x = left
                    rectInWindow.size.width = right - left
                }
            }
        }
        let recordsFrame = parentWindow.convert(rectInWindow, to: scene.coordinateSpace)
        let frame = hasFullScreenStackedPresentation
            ? scene.coordinateSpace.bounds
            : recordsFrame
        if recordWindow == nil {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            let window = RecordSheetWindow(windowScene: scene)
            window.onLayout = { [weak self] in self?.stackedPresentationsDidChange() }
            window.backgroundColor = .clear
            window.clipsToBounds = true
            window.windowLevel = parentWindow.windowLevel + 1
            window.rootViewController = host
            hostingController = host
            recordWindow = window
        }
        // Never make this auxiliary window key: app navigation and scene-level
        // presentation ownership remain with the app's original window.
        if recordWindow?.frame != frame { recordWindow?.frame = frame }
        recordWindow?.isHidden = false
    }

    func tearDown() {
        stackedSheetObservations = []
        recordWindow?.isHidden = true
        recordWindow?.rootViewController = nil
        hostingController = nil
        recordWindow = nil
    }
}

private final class RecordSheetPlaceholderView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}

/// This window ends above the tab bar, so it must not reserve the physical
/// screen's home-indicator inset a second time. Outside the sheet, touches go
/// through to the map in the app window.
private final class RecordSheetWindow: UIWindow {
    /// Presenting or dismissing a stacked sheet adds/removes its container here.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        onLayout?()
    }

    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        if IPhoneDuo.isCurrent, let scene = windowScene,
           frame.maxY >= scene.coordinateSpace.bounds.maxY {
            return insets
        }
        insets.bottom = 0
        return insets
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let sheet = rootViewController?.presentedViewController else {
            return nil
        }
        // A detail/calendar sheet or alert retains its normal modal backdrop.
        if sheet.presentedViewController != nil {
            return super.hitTest(point, with: event)
        }
        // `presentationController.presentedView` may be a full-window wrapper.
        // The presented controller's own view is the actual sheet surface.
        let sheetFrame = sheet.view.convert(sheet.view.bounds, to: self)
        guard sheetFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

}
