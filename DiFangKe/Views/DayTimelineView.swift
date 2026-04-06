import SwiftUI
import SwiftData
import MapKit
import UIKit
import Combine
import Photos

struct DayTimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Footprint> { $0.statusValue != "ignored" }, sort: \Footprint.startTime, order: .reverse) private var footprints: [Footprint]
    
    @State private var selectedDate: Date
    @State private var scrollID: Date?
    @Environment(LocationManager.self) private var locationManager
    
    @State private var repeatTimer: Timer?
    @State private var repeatTimerInterval: Double = 0.2
    @State private var isPressingArrow = false
    @State private var currentPressDirection = 0
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query private var manualSelections: [TransportManualSelection]
    
    @State private var cachedDates: [Date] = []
    @State private var pastLimitOffset: Int = -1
    @State private var groupedFootprints: [Date: [Footprint]] = [:]
    @State private var groupedManualSelections: [Date: [TransportManualSelection]] = [:]
    @State private var showingResetAlert = false
    @State private var updateTask: Task<Void, Never>?
    @State private var preLoadTask: Task<Void, Never>?

    init(selectedDate: Date = Calendar.current.startOfDay(for: Date())) {
        self._selectedDate = State(initialValue: selectedDate)
        self._scrollID = State(initialValue: selectedDate)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dateNavigator
                
                ZStack(alignment: .top) {
                    ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(cachedDates, id: \.self) { date in
                            let offset = latestOffsetIn(date: date)
                            let dayFootprints = groupedFootprints[date] ?? []
                            let dayManualSelections = groupedManualSelections[date] ?? []
                            TimelinePageView(date: date, footprints: dayFootprints, manualSelections: dayManualSelections, allPlaces: allPlaces, offset: offset, locationManager: locationManager, pastLimitOffset: pastLimitOffset)
                                .frame(width: UIScreen.main.bounds.width)
                                .id(date)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID)
                .onChange(of: scrollID) { oldValue, newValue in
                    if let newValue {
                        if newValue != oldValue {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        selectedDate = newValue
                        // 如果滑动到了非今天的日期，记录已学会滑动
                        if !Calendar.current.isDate(newValue, inSameDayAs: Date()) {
                            UserDefaults.standard.set(true, forKey: "hasSwiped")
                        }
                        
                        // Optimized: Debounced neighborhood pre-loading to avoid lagging during rapid swiping
                        preLoadTask?.cancel()
                        preLoadTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms stable delay
                            if Task.isCancelled { return }
                            preLoadNeighborDates(around: newValue)
                        }
                    }
                }
                
                // Date Switcher Bottom Gradient Fade
                LinearGradient(
                    stops: [
                        .init(color: .dfkBackground, location: 0),
                        .init(color: .dfkBackground.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 32)
                .allowsHitTesting(false)
            } // ZStack
            .navigationTitle("地方客")
            .navigationBarTitleDisplayMode(.inline)
            .background(
                LinearGradient(
                    colors: [
                        .dfkBackground,
                        .dfkAccent.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: HistoryListView(initialDate: selectedDate)) {
                        Image(systemName: "calendar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                locationManager.modelContext = modelContext
                locationManager.allPlaces = allPlaces
                if UserDefaults.standard.bool(forKey: "isTrackingEnabled") && !locationManager.isTracking {
                    locationManager.startTracking()
                }
                locationManager.refreshAvailableRawDates()
                updateData()
            }
            .onDisappear {
                stopRepeatTimer()
                updateTask?.cancel()
            }
            .onChange(of: footprints) { _, _ in
                updateData()
            }

            .onChange(of: allPlaces) { _, newValue in
                locationManager.allPlaces = newValue
                locationManager.forceRefreshOngoingAnalysis()
            }
            .alert("重置本日数据", isPresented: $showingResetAlert) {
                Button("确定重置", role: .destructive) {
                    locationManager.resetData(for: selectedDate)
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这将删除已保存的足迹记录和交通纠错，并从原始轨迹重新生成。")
            }
            } // VStack
        } // NavigationStack
    } // body

    private func updateData() {
        updateTask?.cancel()
        
        let rawDates = locationManager.availableRawDates
        let today = Calendar.current.startOfDay(for: Date())
        
        updateTask = Task { @MainActor in
            // Wait for 100ms debounce before starting expensive grouping
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }

            let calendar = Calendar.current
            
            // 1. Group footprints - Optimize by doing only once
            var newGrouped: [Date: [Footprint]] = [:]
            let footprintSnapshots = footprints // Capture snapshot to iterate
            for fp in footprintSnapshots {
                // If a footprint spans multiple days, we add it to each
                var datePtr = calendar.startOfDay(for: fp.startTime)
                let lastDate = calendar.startOfDay(for: fp.endTime)
                
                while datePtr <= lastDate {
                    newGrouped[datePtr, default: []].append(fp)
                    guard let nextDate = calendar.date(byAdding: .day, value: 1, to: datePtr) else { break }
                    datePtr = nextDate
                }
            }
            
            // 2. Group manual selections
            var newManualGrouped: [Date: [TransportManualSelection]] = [:]
            let selectionSnapshots = manualSelections
            for selection in selectionSnapshots {
                let day = calendar.startOfDay(for: selection.startTime)
                newManualGrouped[day, default: []].append(selection)
            }
            
            var limitOffset = -1
            if let earliestFootprint = footprints.last {
                let earliestDataDate = calendar.startOfDay(for: earliestFootprint.startTime)
                if let limitDate = calendar.date(byAdding: .day, value: -1, to: earliestDataDate) {
                    let diff = calendar.dateComponents([.day], from: today, to: limitDate).day ?? 0
                    limitOffset = min(-1, diff)
                }
            }
            
            // 3. Generate dates (Filtered to only show dates with data, plus context: today, tomorrow, and start date)
            let allOffsets = Array(limitOffset...1)
            var finalDates: [Date] = []
            
            let validDatesWithData = Set(newGrouped.keys).union(rawDates)
            finalDates = allOffsets.compactMap { offset in
                if offset == 1 || offset == 0 || offset == limitOffset {
                    return calendar.date(byAdding: .day, value: offset, to: today)
                }
                if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                    return validDatesWithData.contains(date) ? date : nil
                }
                return nil
            }
            
            if Task.isCancelled { return }
            
            // Only update if structural changes occurred to preserve scroll performance
            let structureChanged = self.cachedDates.count != finalDates.count || self.cachedDates.first != finalDates.first || self.pastLimitOffset != limitOffset
            
            if structureChanged {
                self.cachedDates = finalDates
                self.pastLimitOffset = limitOffset
            }
            
            self.groupedFootprints = newGrouped
            self.groupedManualSelections = newManualGrouped
        }
    }


    /// Pre-build timelines for neighbor dates so they are ready before the user swipes to them
    private func preLoadNeighborDates(around date: Date) {
        let calendar = Calendar.current
        let neighbors = [
            calendar.date(byAdding: .day, value: -1, to: date),
            calendar.date(byAdding: .day, value: 1, to: date)
        ].compactMap { $0 }
        
        for neighbor in neighbors {
            let startOfDay = calendar.startOfDay(for: neighbor)
            guard TimelineBuilder.timelineCache[startOfDay] == nil else { continue }
            
            // Optimized: Skip pre-loading for empty historical dates
            let dayFootprints = groupedFootprints[startOfDay] ?? []
            let hasRawData = locationManager.availableRawDates.contains(startOfDay)
            if !calendar.isDateInToday(neighbor) && dayFootprints.isEmpty && !hasRawData {
                TimelineBuilder.timelineCache[startOfDay] = []
                continue
            }
            
            let dayManualSelections = groupedManualSelections[startOfDay] ?? []
            let places = allPlaces
            
            // Capture snapshots and convert to Lite for background processing
            let fpsLite = dayFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
            let placesLite = places.map { TimelineBuilder.convertToPlaceLite($0) }
            let overridesLite = dayManualSelections.map { TimelineBuilder.convertToOverrideLite($0) }

            // Detach entire heavy process to background
            Task {
                let items = await Task.detached(priority: .background) {
                    let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: startOfDay)
                    return TimelineBuilder.buildTimeline(
                        for: startOfDay,
                        footprints: fpsLite,
                        allRawPoints: rawPoints,
                        allPlaces: placesLite,
                        overrides: overridesLite
                    )
                }.value
                
                await MainActor.run {
                    TimelineBuilder.timelineCache[startOfDay] = items
                }
            }
        }
    }
    
    private var dateNavigator: some View {
        HStack {
            navigationArrow(direction: -1)
            
            Spacer()
            Menu {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Label("重置本日数据", systemImage: "arrow.counterclockwise")
                }
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(dateHeader).font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Text(secondaryHeader).font(.caption).foregroundColor(.secondary)
                }
                .foregroundColor(.primary)
            }
            Spacer()
            
            navigationArrow(direction: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.dfkBackground.ignoresSafeArea(edges: .top))
    }
    
    @ViewBuilder
    private func navigationArrow(direction: Int) -> some View {
        let isDisabled = (direction == -1) ? isAtStart : isAtEnd
        let icon = (direction == -1) ? "arrow.left" : rightArrowIcon
        
        Image(systemName: icon)
            .foregroundColor(isDisabled ? Color.secondary.opacity(0.3) : Color.dfkAccent)
            .padding(8)
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.5 : (isPressingArrow && currentPressDirection == direction ? 0.6 : 1.0))
            .onLongPressGesture(minimumDuration: 0.3, perform: {}) { pressing in
                self.isPressingArrow = pressing
                self.currentPressDirection = pressing ? direction : 0
                if pressing && !isDisabled {
                    startRepeatTimer(direction: direction)
                } else {
                    stopRepeatTimer()
                }
            }
            .onTapGesture {
                if !isDisabled {
                    if direction == 1 && isFarFromToday {
                        jumpToToday()
                    } else {
                        changeDate(by: direction)
                    }
                }
            }
    }
    
    private var rightArrowIcon: String {
        isFarFromToday ? "arrow.right.to.line" : "arrow.right"
    }
    
    private let sharedCalendar = Calendar.current
    
    private func latestOffsetIn(date: Date) -> Int {
        let today = sharedCalendar.startOfDay(for: Date())
        let diff = sharedCalendar.dateComponents([.day], from: today, to: sharedCalendar.startOfDay(for: date)).day ?? 0
        return diff
    }
    
    private var isAtEnd: Bool {
        if !cachedDates.isEmpty {
            return (cachedDates.firstIndex(of: selectedDate) ?? 0) >= (cachedDates.count - 1)
        }
        return true
    }
    
    private var isAtStart: Bool {
        if !cachedDates.isEmpty {
             return (cachedDates.firstIndex(of: selectedDate) ?? 0) <= 0
        }
        return true
    }
    
    private var isTodaySelected: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: Date())
    }
    
    /// 距离今天超过5天时显示跳回图标
    private var isFarFromToday: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: selectedDate, to: today).day ?? 0
        return days >= 5
    }
    
    private func startRepeatTimer(direction: Int) {
        stopRepeatTimer()
        repeatTimerInterval = 0.2 // 初始间隔 0.2s
        
        // 延迟一段时间后开始连续触发
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.isPressingArrow && self.currentPressDirection == direction else { return }
            self.triggerNextStep(direction: direction)
        }
    }
    
    private func triggerNextStep(direction: Int) {
        guard isPressingArrow && currentPressDirection == direction else { return }
        
        step(direction: direction)
        
        // 速度递增逻辑：每次缩短 10% 的间隔，直到达到最快 0.05s
        repeatTimerInterval = max(0.05, repeatTimerInterval * 0.9)
        
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatTimerInterval, repeats: false) { _ in
            self.triggerNextStep(direction: direction)
        }
    }
    
    private func stopRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
    
    private var dateHeader: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return "今天" }
        if calendar.isDateInYesterday(selectedDate) { return "昨天" }
        if calendar.isDateInTomorrow(selectedDate) { return "明天" }
        
        let today = calendar.startOfDay(for: Date())
        if let dby = calendar.date(byAdding: .day, value: -2, to: today),
           calendar.isDate(selectedDate, inSameDayAs: dby) {
            return "前天"
        }
        
        let isCurrentYear = calendar.component(.year, from: selectedDate) == calendar.component(.year, from: today)
        return isCurrentYear ? selectedDate.formatted(.dateTime.month().day()) : selectedDate.formatted(.dateTime.year().month().day())
    }
    
    private var secondaryHeader: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dby = calendar.date(byAdding: .day, value: -2, to: today)!
        let isRelative = calendar.isDateInToday(selectedDate) || 
                         calendar.isDateInYesterday(selectedDate) || 
                         calendar.isDateInTomorrow(selectedDate) ||
                         calendar.isDate(selectedDate, inSameDayAs: dby)
        
        if isRelative {
            let isCurrentYear = calendar.component(.year, from: selectedDate) == calendar.component(.year, from: today)
            let dateStr = isCurrentYear ? selectedDate.formatted(.dateTime.month().day()) : selectedDate.formatted(.dateTime.year().month().day())
            return "\(dateStr) \(selectedDate.formatted(.dateTime.weekday(.wide)))"
        } else {
            return selectedDate.formatted(.dateTime.weekday(.wide))
        }
    }
    
    private func step(direction: Int) {
        let isDisabled = (direction == -1) ? isAtStart : isAtEnd
        if !isDisabled {
            changeDate(by: direction)
        } else {
            stopRepeatTimer()
        }
    }
    
    private func jumpToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            selectedDate = today
            scrollID = today
        }
    }
    
    private func changeDate(by direction: Int) {
        guard let currentIndex = cachedDates.firstIndex(of: selectedDate) else {
            jumpToToday()
            return
        }
        
        let nextIndex = currentIndex + direction
        if nextIndex >= 0 && nextIndex < cachedDates.count {
            let targetDate = cachedDates[nextIndex]
            withAnimation(.spring()) {
                selectedDate = targetDate
                scrollID = targetDate
            }
        }
    }
}

struct TimelinePageView: View {
    @Environment(\.modelContext) private var modelContext
    let date: Date
    let footprints: [Footprint]
    let manualSelections: [TransportManualSelection]
    let allPlaces: [Place]
    let offset: Int
    let locationManager: LocationManager
    let pastLimitOffset: Int
    
    @State private var selectedFootprint: Footprint?
    @State private var selectedTransport: Transport?
    @State private var autoFocusOnOpen = false
    @State private var tomorrowQuoteTitle: String = "明天是个未拆的礼物"
    @State private var tomorrowQuoteSubtitle: String = "愿明天的你，能在平凡中发现惊喜。"
    
    @State private var pastQuoteTitle: String = "真希望能早点遇到你"
    @State private var pastQuoteSubtitle: String = "要是早点遇见，就能记录更多精彩了。"
    
    @State private var showingAddPlaceSheet = false
    @AppStorage("isGuideDismissed") private var isGuideDismissed = false
    @AppStorage("isNotificationGuideDismissed") private var isNotificationGuideDismissed = false
    @AppStorage("hasSwiped") private var hasSwiped = false
    @State private var animateHint = false
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    
    @State private var timelineItems: [TimelineItem]
    @State private var isLoadingTimeline: Bool
    @State private var refreshTask: Task<Void, Never>?
    
    @State private var totalPointsCount: Int = 0
    @State private var trajectoryPoints: [CLLocationCoordinate2D] = []
    
    init(date: Date, footprints: [Footprint], manualSelections: [TransportManualSelection], allPlaces: [Place], offset: Int, locationManager: LocationManager, pastLimitOffset: Int) {
        self.date = date
        self.footprints = footprints
        self.manualSelections = manualSelections
        self.allPlaces = allPlaces
        self.offset = offset
        self.locationManager = locationManager
        self.pastLimitOffset = pastLimitOffset
        
        let cached = TimelineBuilder.timelineCache[date]
        self._timelineItems = State(initialValue: cached ?? [])
        self._isLoadingTimeline = State(initialValue: cached == nil)
    }
    
    var body: some View {
        let currentDayFootprints = self.footprints
        ScrollView {
            VStack(spacing: 0) {
                let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
                
                if offset > 0 {
                    futurePlaceholderView
                } else if offset == pastLimitOffset {
                    pastPlaceholderView
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if isToday {
                            RecordingStatusCard(locationManager: locationManager, footprintCount: currentDayFootprints.count)
                                .padding(.horizontal, 16)
                        } else {
                            DaySummaryCard(
                                date: date,
                                totalPoints: totalPointsCount,
                                footprintCount: timelineItems.filter { if case .footprint = $0 { return true }; return false }.count,
                                transportMileage: timelineItems.reduce(0) { sum, item in
                                    if case .transport(let t) = item { return sum + t.distance }
                                    return sum
                                },
                                points: trajectoryPoints
                            )
                            .padding(.horizontal, 16)
                        }
                        
                        if timelineItems.isEmpty && !isLoadingTimeline {
                            PlaceholderFootprintCard()
                                .padding(.horizontal, 0)
                        }
                        
                        if allPlaces.isEmpty && !isGuideDismissed {
                            importantPlaceGuide
                                .padding(.top, 20)
                                .padding(.bottom, 20)
                        }
                    }
                    
                    if currentDayFootprints.isEmpty && timelineItems.isEmpty && (!isToday || locationManager.potentialStopStartLocation == nil) {
                        if allPlaces.isEmpty && isToday && !isGuideDismissed {
                            EmptyView()
                        } else if !isLoadingTimeline {
                            emptyStateView
                        }
                    } else {
                        if !isNotificationGuideDismissed && isToday && notificationAuthStatus == .notDetermined && !currentDayFootprints.isEmpty {
                            notificationGuide
                                .padding(.top, 10)
                                .padding(.bottom, 16)
                        }
                        
                        let items = self.timelineItems
                        let count = items.count
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .footprint(let footprint):
                                FootprintCardView(
                                    footprint: footprint, 
                                    allPlaces: allPlaces,
                                    contextDate: date,
                                    isFirst: index == 0,
                                    isLast: index == count - 1,
                                    isToday: isToday
                                ) { item, focus in
                                    self.autoFocusOnOpen = focus
                                    self.selectedFootprint = item
                                }
                                .padding(.horizontal, 16)
                            case .transport(let transport):
                                TransportCardView(
                                    transport: transport,
                                    isFirst: index == 0,
                                    isLast: index == count - 1,
                                    isToday: isToday,
                                    onSelect: { selected in
                                        self.selectedTransport = selected
                                    },
                                    onDelete: { selected in
                                        let selection = TransportManualSelection(startTime: selected.startTime, endTime: selected.endTime, isDeleted: true)
                                        modelContext.insert(selection)
                                        try? modelContext.save()
                                        refreshTimeline()
                                    }
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    
                    if offset <= 0 && !hasSwiped {
                        swipeHintFooter
                            .padding(.top, 40)
                            .padding(.bottom, 60)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    animateHint = true
                                }
                            }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 10)
        }
        .onAppear {
            NotificationManager.shared.getAuthorizationStatus { status in
                self.notificationAuthStatus = status
            }
            
            let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
            let notInCache = TimelineBuilder.timelineCache[date] == nil
            
            // REFRESH ALWAYS: stats (trajectoryPoints/totalPointsCount) are NOT cached in TimelineBuilder. 
            // So we must refresh once to at least pull raw points if stats are missing.
            if timelineItems.isEmpty || (notInCache && isToday) || trajectoryPoints.isEmpty {
                refreshTimeline()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
        }
        .onChange(of: footprints) { _, _ in refreshTimeline() }
        .onChange(of: manualSelections) { _, _ in refreshTimeline() }
        .sheet(item: $selectedFootprint) { footprint in
            FootprintModalView(footprint: footprint, autoFocus: autoFocusOnOpen)
                .onDisappear { autoFocusOnOpen = false }
        }
        .sheet(isPresented: $showingAddPlaceSheet) {
            AddPlaceSheet(initialCoordinate: locationManager.lastLocation?.coordinate, 
                          initialName: locationManager.currentAddress) { newPlace in
                modelContext.insert(newPlace)
                try? modelContext.save()
            }
        }
        .sheet(item: $selectedTransport) { transport in
            TransportModalView(transport: transport) { newType in
                if let index = timelineItems.firstIndex(where: { 
                    if case .transport(let t) = $0, t.id == transport.id { return true }
                    return false
                }) {
                    if case .transport(let t) = timelineItems[index] {
                        let updated = t.updatingType(newType)
                        timelineItems[index] = .transport(updated)
                    }
                }
            } onLocationUpdate: {
                refreshTimeline()
            }
        }
    }
    
    @MainActor
    private func refreshTimeline() {
        refreshTask?.cancel()
        
        let currentFootprints = footprints.filter { $0.status != .ignored }
        let currentOverrides = manualSelections
        let currentPlaces = allPlaces
        let targetDate = date
        let availableRawDates = locationManager.availableRawDates
        
        let fpsLite = currentFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
        let placesLite = currentPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
        let overridesLite = currentOverrides.map { TimelineBuilder.convertToOverrideLite($0) }

        refreshTask = Task { @MainActor in
            let isToday = Calendar.current.isDateInToday(targetDate)
            let hasExistingFootprints = !currentFootprints.isEmpty
            let hasRawData = availableRawDates.contains(Calendar.current.startOfDay(for: targetDate))
            
            if !isToday && !hasExistingFootprints && !hasRawData {
                self.timelineItems = []
                self.isLoadingTimeline = false
                TimelineBuilder.timelineCache[targetDate] = []
                return
            }

            if self.timelineItems.isEmpty {
                if let cached = TimelineBuilder.timelineCache[targetDate] {
                    self.timelineItems = cached 
                    self.isLoadingTimeline = false
                } else {
                    self.isLoadingTimeline = true
                }
            }
            
            if !self.timelineItems.isEmpty || TimelineBuilder.timelineCache[targetDate] != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if Task.isCancelled { return }
            
            let cachedItems = TimelineBuilder.timelineCache[targetDate]
            let result = await Task.detached(priority: .userInitiated) {
                let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
                
                // If we already have items from cache and it's NOT today, 
                // we can just return the raw points and count, skipping the build.
                if let cached = cachedItems, !isToday, !cached.isEmpty {
                    return (cached, rawPoints.map { $0.coordinate }, rawPoints.count)
                }
                
                let items = TimelineBuilder.buildTimeline(
                    for: targetDate, 
                    footprints: fpsLite, 
                    allRawPoints: rawPoints, 
                    allPlaces: placesLite, 
                    overrides: overridesLite
                )
                return (items, rawPoints.map { $0.coordinate }, rawPoints.count)
            }.value
            
            let items = result.0
            self.trajectoryPoints = result.1
            self.totalPointsCount = result.2
            
            if Task.isCancelled { return }
            
            if !self.timelineItems.isEmpty {
                var mergedItems = items
                for i in 0..<mergedItems.count {
                    if i < self.timelineItems.count {
                        let old = self.timelineItems[i]
                        let new = mergedItems[i]
                        
                        if case .footprint(let oldF) = old, case .footprint(let newF) = new {
                            let oldTitle = oldF.title.trimmingCharacters(in: .whitespaces)
                            let newTitle = newF.title.trimmingCharacters(in: .whitespaces)
                            
                            let isOldValid = !oldTitle.isEmpty && !["地点记录", "正在获取位置...", "在某地停留", ""].contains(oldTitle)
                            let isNewPlaceholder = newTitle.isEmpty || ["地点记录", "正在获取位置...", "在某地停留", ""].contains(newTitle)
                            
                            if isOldValid && isNewPlaceholder && abs(oldF.startTime.timeIntervalSince(newF.startTime)) < 300 {
                                mergedItems[i] = old
                            }
                        }
                    }
                }
                self.timelineItems = mergedItems
            } else {
                self.timelineItems = items
            }
            
            TimelineBuilder.timelineCache[targetDate] = self.timelineItems
            self.isLoadingTimeline = false
            
            locationManager.backfillGaps(for: targetDate)
            resolveTimelineAddresses(for: self.timelineItems)
        }
    }
    
    private func resolveTimelineAddresses(for items: [TimelineItem]) {
        for (index, item) in items.enumerated() {
            switch item {
            case .transport(let transport):
                if (transport.startLocation == "正在获取位置..." || transport.startLocation == "起点") && !transport.points.isEmpty {
                    TimelineBuilder.resolveAddress(coordinate: transport.points.first!) { name in
                        updateTimelineItemAddress(index: index, type: .start, name: name)
                    }
                }
                
                if (transport.endLocation == "正在获取位置..." || transport.endLocation == "终点") && !transport.points.isEmpty {
                    TimelineBuilder.resolveAddress(coordinate: transport.points.last!) { name in
                        updateTimelineItemAddress(index: index, type: .end, name: name)
                    }
                }
            case .footprint(let footprint):
                let needsResolution = (footprint.title == "地点记录" || footprint.title == "正在获取位置..." || footprint.title == "在某地停留") 
                    && (footprint.address == nil || footprint.address!.isEmpty || footprint.address == "正在解析位置...")
                
                if needsResolution && !footprint.footprintLocations.isEmpty {
                    let avgLat = footprint.footprintLocations.map { $0.latitude }.reduce(0, +) / Double(footprint.footprintLocations.count)
                    let avgLon = footprint.footprintLocations.map { $0.longitude }.reduce(0, +) / Double(footprint.footprintLocations.count)
                    
                    TimelineBuilder.resolveAddress(coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)) { name in
                        updateTimelineItemAddress(index: index, type: .stay, name: name)
                    }
                }
            }
        }
    }
    
    enum AddressType { case start, end, stay }
    
    private func updateTimelineItemAddress(index: Int, type: AddressType, name: String) {
        Task { @MainActor in
            guard index < timelineItems.count else { return }
            let item = timelineItems[index]
            switch item {
            case .transport(let transport):
                let updated = type == .start ? transport.updatingStart(name) : transport.updatingEnd(name)
                timelineItems[index] = .transport(updated)
            case .footprint(let footprint):
                if type == .stay {
                    footprint.title = name
                    footprint.address = name
                    
                    if let context = footprint.modelContext {
                        try? context.save()
                    }
                    
                    timelineItems[index] = .footprint(footprint)
                }
            }
        }
    }
    
    var notificationGuide: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.dfkHighlight.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "bell.badge.fill").font(.system(size: 14, weight: .bold)).foregroundColor(Color.dfkHighlight))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("开启晚间足迹总结").font(.system(size: 14, weight: .bold))
                Text("每日晚间为您汇总今日精彩足迹与回忆").font(.system(size: 12)).foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button("立即开启") {
                    NotificationManager.shared.requestAuthorization { granted in
                        withAnimation(.spring()) { 
                            isNotificationGuideDismissed = true 
                            if granted {
                                UserDefaults.standard.set(true, forKey: "isDailyNotificationEnabled")
                            }
                        }
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color.dfkHighlight)
                
                Button {
                    withAnimation(.spring()) { isNotificationGuideDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dfkHighlight.opacity(0.06)))
        .padding(.horizontal, 16)
    }
    
    var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 100)
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 60))
                .foregroundColor(Color.dfkCandidate)
            Text("比较平常，没有发现特别足迹")
                .font(.subheadline.bold())
                .foregroundColor(Color.dfkSecondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
    
    var futurePlaceholderView: some View {
        VStack(spacing: 30) {
            Spacer().frame(height: 100)
            Image(systemName: "sparkles").font(.system(size: 70)).foregroundColor(Color.dfkHighlight)
            VStack(spacing: 12) {
                Text(tomorrowQuoteTitle).font(.title3.bold())
                Text(tomorrowQuoteSubtitle).font(.subheadline).foregroundColor(Color.dfkSecondaryText)
            }
            Spacer()
        }
        .onAppear {
            if offset == 1 {
                OpenAIService.shared.generateTomorrowQuote { title, sub in
                    self.tomorrowQuoteTitle = title
                    self.tomorrowQuoteSubtitle = sub
                }
            }
        }
    }
    
    var pastPlaceholderView: some View {
        VStack(spacing: 30) {
            Spacer().frame(height: 100)
            Image(systemName: "timer") .font(.system(size: 70)).foregroundColor(Color.dfkCandidate)
            VStack(spacing: 12) {
                Text(pastQuoteTitle).font(.title3.bold())
                Text(pastQuoteSubtitle).font(.subheadline).foregroundColor(Color.dfkSecondaryText)
            }
            
            NavigationLink(destination: HistoryListView(initialDate: date, showImportOnAppear: true)) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.badge.clock")
                    Text("从相册寻回当时的足迹")
                }
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.dfkAccent.opacity(0.1))
                .foregroundColor(.dfkAccent)
                .cornerRadius(20)
            }
            .padding(.top, 10)
            
            Spacer()
        }
        .onAppear {
            OpenAIService.shared.generatePastQuote { title, sub in
                self.pastQuoteTitle = title
                self.pastQuoteSubtitle = sub
            }
        }
    }
    
    var importantPlaceGuide: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "mappin.and.ellipse").font(.system(size: 14, weight: .bold)).foregroundColor(.orange))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("添加重要地点").font(.system(size: 14, weight: .bold))
                Text("更智能地归纳停留轨迹").font(.system(size: 12)).foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button("立即添加") {
                    showingAddPlaceSheet = true
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.orange)
                
                Button {
                    withAnimation(.spring()) { isGuideDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.06)))
        .padding(.horizontal, 16)
    }
    
    var swipeHintFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .offset(x: animateHint ? -8 : 8)
            Text("左右滑动切换日期")
                .font(.caption.bold())
            Image(systemName: "chevron.right")
                .offset(x: animateHint ? 8 : -8)
        }
        .foregroundColor(.secondary.opacity(0.6))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Components

struct RecordingStatusCard: View {
    let locationManager: LocationManager
    let footprintCount: Int
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    private var displayTitle: String {
        let isStopped = !locationManager.isTracking
        if isStopped {
            return "定位记录已关闭"
        }
        
        // 探测实时移动状态
        if let location = locationManager.lastLocation, location.speed > 1.0 {
            let speedKmh = location.speed * 3.6
            if speedKmh > 90 {
                return "正在高速移动"
            } else if speedKmh > 30 {
                return "正在快速移动"
            } else if speedKmh > 5 {
                return "正在持续移动"
            }
        }
        
        if let ongoing = locationManager.ongoingTitle {
            return ongoing
        } else {
            return "正在此处停留"
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. 时间轴指示器
            VStack(spacing: 0) {
                Spacer().frame(height: 22)
                
                // 呼吸圆点 (采用 TimelineView 彻底解决重绘导致的动画跳变)
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let duration = locationManager.pulseDuration
                    let progress = (now.truncatingRemainder(dividingBy: duration)) / duration
                    let scale = 1.0 + (progress * 2.5) // 1.0 -> 3.5
                    let opacity = (1.0 - progress) * 0.4
                    
                    ZStack {
                        Circle().stroke(Color.dfkAccent.opacity(opacity), lineWidth: 3)
                            .frame(width: 8, height: 8)
                            .scaleEffect(scale)
                        
                        Circle().fill(Color.dfkAccent).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 24, height: 24)
                
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, -20)
            }.frame(width: 40)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top Section: Info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(!locationManager.isTracking ? .secondary : Color.dfkMainText)
                        
                        // 地址行
                        if locationManager.isTracking && !locationManager.currentAddress.isEmpty && locationManager.currentAddress != "正在解析位置..." {
                            Text(locationManager.currentAddress)
                                .font(.caption2)
                                .foregroundColor(Color.dfkSecondaryText)
                                .lineLimit(1)
                                .padding(.top, 1)
                        }
                        
                        HStack(spacing: 4) {                            
                            if !locationManager.isTracking {
                                Text("点击开启或查看说明")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else if let durationStr = locationManager.stayDuration {
                                Text("已停留 \(durationStr)")
                                    .font(.caption2)
                                    .foregroundColor(Color.dfkSecondaryText)
                                    .id("duration-\(durationStr)")
                            }
                        }
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 6) {
                        // if locationManager.isTracking {
                        //     // 精度/能效状态标识
                        //     Group {
                        //         let duration = locationManager.pulseDuration
                        //         if duration < 1.0 {
                        //             Text("高精度")
                        //                 .foregroundColor(.dfkAccent)
                        //         } else if duration < 2.0 {
                        //             Text("巡航中")
                        //                 .foregroundColor(.blue)
                        //         } else {
                        //             Text("低功耗")
                        //                 .foregroundColor(.secondary)
                        //         }
                        //     }
                        //     .font(.system(size: 9, weight: .bold))
                        //     .padding(.horizontal, 6)
                        //     .padding(.vertical, 3)
                        //     .background(Color.secondary.opacity(0.06))
                        //     .cornerRadius(6)
                        // }

                        if let place = locationManager.matchedPlace, place.isUserDefined {
                            Text(place.name)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, -2) // 微调垂直对齐
                }
                .padding(.vertical, 16)
                .padding(.leading, 8)
                .padding(.trailing, 16)
                
                // DFKMapView Section
                DFKMapView(
                    cameraPosition: $cameraPosition,
                    isInteractive: false,
                    showsUserLocation: true,
                    points: locationManager.allTodayPoints.map { $0.coordinate }
                )
                .frame(height: 160)
                .cornerRadius(12)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .onAppear {
                    let todayPoints = locationManager.allTodayPoints.map { $0.coordinate }
                    if let region = todayPoints.boundingRegion() {
                        cameraPosition = .region(region)
                    } else if let newLoc = locationManager.lastLocation {
                        cameraPosition = .region(MKCoordinateRegion(center: newLoc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
                    }
                }
                .onChange(of: locationManager.allTodayPoints.count) { _, count in
                    // Only auto-adjust if the trajectory is growing and not already focused by user manual
                    let todayPoints = locationManager.allTodayPoints.map { $0.coordinate }
                    if let region = todayPoints.boundingRegion() {
                        withAnimation {
                            cameraPosition = .region(region)
                        }
                    }
                }
                .onChange(of: locationManager.lastLocation) { _, newLoc in
                    // If no points yet, keep tracking current position
                    if locationManager.allTodayPoints.isEmpty, let newLoc {
                        withAnimation {
                            cameraPosition = .region(MKCoordinateRegion(center: newLoc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .padding(.bottom, 14)
        .onTapGesture {
            showFullscreenMap = true
        }
        .sheet(isPresented: $showFullscreenMap) {
            FullFrameTrajectoryMapView(
                title: "今日轨迹",
                points: locationManager.allTodayPoints.map { $0.coordinate },
                showsUserLocation: true
            )
        }
    }
}

struct FootprintCardView: View {
    @Bindable var footprint: Footprint
    let allPlaces: [Place]
    var contextDate: Date? = nil
    var isFirst: Bool = false
    var isLast: Bool = false
    var isToday: Bool = false
    var showTimeline: Bool = true
    var showDateAboveTitle: Bool = false
    var fixedWidth: CGFloat? = nil
    let onTap: (Footprint, Bool) -> Void
    
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @State private var highlightVisible: Bool = false
    @State private var showingDeleteConfirm = false
    @State private var showingIgnoreConfirm = false
    @State private var confirmedAnimating: Bool = false
    
    var body: some View {
        if footprint.status == .ignored {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                 if showTimeline {
                     timelineIndicator
                 }
                 ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 4) {
                    if showDateAboveTitle && (contextDate == nil || !Calendar.current.isDate(footprint.date, inSameDayAs: contextDate!)) {
                        Text(footprint.date.formatted(.dateTime.year().month().day()))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.bottom, -2)
                    }
                    
                    HStack(spacing: 6) {
                        Text(footprint.title.isEmpty ? "地点记录" : footprint.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(Color.dfkMainText)
                            .lineLimit(1)
                        
                        if let placeID = footprint.placeID,
                           let place = allPlaces.first(where: { $0.placeID == placeID && $0.isUserDefined }) {
                            Spacer(minLength: 4)
                            Text(place.name)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                    }
                    

                    if let addr = footprint.address, !addr.isEmpty {
                        Text(addr)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(Color.dfkSecondaryText)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                    
                    HStack(spacing: 4) {
                        Text(timeRangeString).font(.system(.caption, design: .monospaced)).foregroundColor(Color.dfkSecondaryText).lineLimit(1)
                        Text("·").foregroundColor(Color.dfkSecondaryText.opacity(0.4))
                        Text(durationString).font(.caption2).foregroundColor(Color.dfkSecondaryText)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    
                    Text(footprint.reason ?? "")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Color.dfkSecondaryText.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                        .padding(.top, 2)
                }
                .padding(.vertical, 14)
                .padding(.leading, showTimeline ? 0 : 16)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                
                if let firstID = footprint.photoAssetIDs.first {
                    ZStack(alignment: .topTrailing) {
                        AssetThumbnailView(assetID: firstID, onAssetMissing: {
                            withAnimation {
                                var ids = footprint.photoAssetIDs
                                ids.removeAll { $0 == firstID }
                                footprint.photoAssetIDs = ids
                                try? modelContext.save()
                            }
                        })
                            .id(firstID)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        if footprint.photoAssetIDs.count > 1 {
                            Text("\(footprint.photoAssetIDs.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Capsule())
                                .offset(x: -4, y: 4)
                        }
                    }
                    .padding(.bottom, 14)
                    .padding(.trailing, 12)
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: footprint.photoAssetIDs)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .padding(.bottom, 12)
        .frame(width: fixedWidth)
        .contentShape(Rectangle())
        .onTapGesture { onTap(footprint, false) }
        .contextMenu { longPressMenu }
        .alert("确认删除足迹？", isPresented: $showingDeleteConfirm) {
            Button("删除", role: .destructive) { ignoreFootprint() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后，该足迹将不再出现在时间轴上。")
        }
        .alert("忽略并删除在此地点的足迹？", isPresented: $showingIgnoreConfirm) {
            Button("忽略并删除", role: .destructive) {
                locationManager.ignoreLocation(for: footprint)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("添加为忽略地点后，以后将不再记录此处的足迹，且现有的同地点足迹也将被隐藏。")
        }
        .onAppear {
            if footprint.isHighlight == true {
                withAnimation(.easeOut(duration: 0.3).delay(0.2)) { highlightVisible = true }
            }
            geocodeAddress()
        }
    }
}
    
    private func geocodeAddress() {
        guard (footprint.address ?? "").isEmpty else { return }
        
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
        
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard let placemark = placemarks?.first, error == nil else { return }
            
            let name = placemark.name ?? ""
            let subLocality = placemark.subLocality ?? ""
            let thoroughfare = placemark.thoroughfare ?? ""
            
            let addressStr: String
            if !thoroughfare.isEmpty && name != thoroughfare {
                addressStr = "\(thoroughfare) \(name)"
            } else if !subLocality.isEmpty {
                addressStr = "\(subLocality) \(name)"
            } else {
                addressStr = name
            }
            
            if !addressStr.isEmpty {
                DispatchQueue.main.async {
                    footprint.address = addressStr
                    try? footprint.modelContext?.save()
                }
            }
        }
    }
    
    private var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let startStr = formatter.string(from: footprint.startTime)
        let endStr = formatter.string(from: footprint.endTime)
        
        let calendar = Calendar.current
        let referenceDate = contextDate ?? footprint.date
        let isStartSameDay = calendar.isDate(footprint.startTime, inSameDayAs: referenceDate)
        let isEndSameDay = calendar.isDate(footprint.endTime, inSameDayAs: referenceDate)
        
        if isStartSameDay && isEndSameDay {
            return "\(startStr)-\(endStr)"
        } else if !isStartSameDay && isEndSameDay {
            return "昨日\(startStr)-\(endStr)"
        } else if isStartSameDay && !isEndSameDay {
            return "\(startStr)-次日\(endStr)"
        } else {
            let calendar = Calendar.current
            let isSameDay = calendar.isDate(footprint.startTime, inSameDayAs: footprint.endTime)
            let monthDayFormatter = DateFormatter()
            monthDayFormatter.dateFormat = "M月d日 HH:mm"
            
            if isSameDay {
                return "\(monthDayFormatter.string(from: footprint.startTime))-\(endStr)"
            } else {
                return "\(monthDayFormatter.string(from: footprint.startTime))-\(monthDayFormatter.string(from: footprint.endTime))"
            }
        }
    }
    
    private var durationString: String {
        let totalMinutes = Int(footprint.duration / 60)
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes > 0 {
                return "\(hours) 小时 \(minutes) 分钟"
            } else {
                return "\(hours) 小时"
            }
        } else {
            return "\(max(1, totalMinutes)) 分钟"
        }
    }
    
    private var timelineIndicator: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(height: 22)
                .opacity(isFirst && !isToday ? 0 : 1)
            
            ZStack {
                if footprint.isHighlight == true {
                    Image(systemName: "star.fill").font(.system(size: 14)).foregroundColor(Color.dfkHighlight).padding(4).background(Circle().fill(Color(uiColor: .systemBackground)))
                } else {
                    Circle().fill(Color.dfkAccent).frame(width: 10, height: 10)
                        .scaleEffect(confirmedAnimating ? 1.4 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: confirmedAnimating)
                }
            }.frame(width: 24, height: 24)
            
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .padding(.bottom, -12)
                .opacity(isLast ? 0 : 1)
        }.frame(width: 40)
    }
    
    @ViewBuilder
    private var longPressMenu: some View {
        Button { onTap(footprint, true) } label: { Label("编辑", systemImage: "pencil") }
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                footprint.isHighlight = !(footprint.isHighlight ?? false)
                try? modelContext.save()
                highlightVisible = (footprint.isHighlight == true)
            }
        } label: { Label(footprint.isHighlight == true ? "取消收藏" : "收藏", systemImage: footprint.isHighlight == true ? "star.slash" : "star.fill") }
        
        Divider()
        
        Button {
            showingIgnoreConfirm = true
        } label: { Label("忽略地点", systemImage: "mappin.slash") }
        
        Button(role: .destructive) { showingDeleteConfirm = true } label: { Label("删除", systemImage: "trash") }
    }
    
    private func confirmFootprint() {
        withAnimation(.spring(response: 0.3)) {
            footprint.status = .confirmed
            confirmedAnimating = true
            try? modelContext.save()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmedAnimating = false }
    }
    
    private func ignoreFootprint() { withAnimation { footprint.status = .ignored; try? modelContext.save() } }
}

// MARK: - Day Summary Components

struct DaySummaryCard: View {
    let date: Date
    let totalPoints: Int
    let footprintCount: Int
    let transportMileage: Double
    let points: [CLLocationCoordinate2D]
    
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. Timeline Indicator (Summary Style)
            VStack(spacing: 0) {
                Spacer().frame(height: 18)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.dfkAccent)
                    .frame(width: 24, height: 24)
                Spacer()
            }.frame(width: 40)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top Section: Info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(date.formatted(.dateTime.month().day())) 总结")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(Color.dfkMainText)
                        
                        HStack(spacing: 12) {
                            DayStatItem(value: "\(totalPoints)", label: "轨迹点")
                            DayStatSeparator()
                            DayStatItem(value: "\(footprintCount)", label: "足迹")
                            DayStatSeparator()
                            DayStatItem(value: formatDistance(transportMileage), label: "里程数")
                        }
                        .padding(.top, 2)
                    }
                    
                }
                .padding(.vertical, 16)
                .padding(.leading, 8)
                .padding(.trailing, 16)
                
                // Mini Map Section
                if !points.isEmpty {
                    DFKMapView(
                        cameraPosition: $cameraPosition,
                        isInteractive: false,
                        showsUserLocation: false,
                        points: points
                    )
                    .frame(height: 140)
                    .cornerRadius(12)
                    .onAppear {
                        if let region = points.boundingRegion() {
                            cameraPosition = .region(region)
                        }
                    }
                    .cornerRadius(12)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                } else {
                    // Placeholder if no points but still showing card
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.05))
                        .frame(height: 140)
                        .overlay(
                            Text("暂无轨迹信息")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        )
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .padding(.bottom, 14)
        .onTapGesture {
            if !points.isEmpty {
                showFullscreenMap = true
            }
        }
        .sheet(isPresented: $showFullscreenMap) {
            FullFrameTrajectoryMapView(
                title: date.formatted(.dateTime.month().day()) + " 轨迹",
                points: points,
                showsUserLocation: false
            )
        }
    }
    
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000.0)
        }
    }
}

struct DayStatItem: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color.dfkMainText)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

struct DayStatSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .frame(width: 1, height: 18)
            .padding(.top, 2)
    }
}

struct FullFrameTrajectoryMapView: View {
    let title: String
    let points: [CLLocationCoordinate2D]
    var showsUserLocation: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        NavigationStack {
            DFKMapView(
                cameraPosition: $cameraPosition,
                isInteractive: true,
                showsUserLocation: showsUserLocation,
                points: points
            )
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                if let region = points.boundingRegion() {
                    cameraPosition = .region(region)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}

struct PlaceholderFootprintCard: View {
    private let phrases = [
        "今日份回忆正在后台悄悄酝酿...",
        "正在捕捉第一段时光足迹...",
        "别急，这一天的故事正在落笔...",
        "时光正在被系统悉心收纳...",
        "正在为您打磨今日的轨迹线...",
        "第一段记忆正在慢慢发酵..."
    ]
    
    @State private var phrase: String = ""
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let phase = (now.truncatingRemainder(dividingBy: 3.5)) / 3.5
            let sinValue = sin(phase * .pi * 2) // -1 to 1
            let opacity = 0.3 + (sinValue + 1.0) / 2.0 * 0.3 // 0.3 to 0.6
            
            HStack(alignment: .top, spacing: 0) {
                // 1. 时间轴指示器 (严格对齐 RecordingStatusCard)
                VStack(spacing: 0) {
                    // 上半部分连线 (高度 22 对齐逻辑上的卡片顶部边距)
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5, height: 22)
                    
                    // 占位空心圆点
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                    }.frame(width: 24, height: 24)
                    
                    Spacer()
                }
                .frame(width: 40)
                
                // 2. 占位文字与骨架
                VStack(alignment: .leading, spacing: 12) {
                    Text(phrase)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.4))
                        .lineLimit(2)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.05))
                            .frame(width: 140, height: 8)
                        
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.03))
                                .frame(width: 60, height: 8)
                            Circle().fill(Color.secondary.opacity(0.03)).frame(width: 3, height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.03))
                                .frame(width: 40, height: 8)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 14)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
            )
            .opacity(opacity) // 应用呼吸透明度
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .onAppear {
            phrase = phrases.randomElement() ?? phrases[0]
        }
    }
}



