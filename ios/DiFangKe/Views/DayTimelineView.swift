import SwiftUI
import SwiftData
import MapKit
import UIKit
import Combine
import Photos
import Aptabase

struct DayTimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Footprint.startTime, order: .reverse) private var footprints: [Footprint]
    
    @State private var selectedDate: Date
    @State private var activatedDate: Date
    @State private var scrollID: Date?
    @Environment(LocationManager.self) private var locationManager
    
    @State private var repeatTimer: Timer?
    @State private var repeatTimerInterval: Double = 0.2
    @State private var isPressingArrow = false
    @State private var currentPressDirection = 0
    @State private var repeatStepCount = 0
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query private var manualSelections: [TransportManualSelection]
    
    @State private var cachedDates: [Date] = []
    @State private var pastLimitOffset: Int = -1
    @State private var groupedFootprints: [Date: [Footprint]] = [:]
    @State private var groupedManualSelections: [Date: [TransportManualSelection]] = [:]
    @Query private var allInsights: [DailyInsight]
    @State private var groupedInsights: [Date: DailyInsight] = [:]
    @State private var showingResetAlert = false
    @State private var showingRawPointsDate: IdentifiableDate? = nil
    @State private var showingCalendar = false
    @State private var updateTask: Task<Void, Never>?
    @State private var preLoadTask: Task<Void, Never>?
    @State private var activationTask: Task<Void, Never>?
    @State private var arrowTapTargetDate: Date?
    @State private var arrowTapPreviewDate: Date?
    @State private var isArrowTapAnimating = false
    @State private var arrowTapFinalizeTask: Task<Void, Never>?
    @State private var arrowTapPreviewTask: Task<Void, Never>?
    @State private var jumpToTodayHapticTask: Task<Void, Never>?
    @State private var longPressPreviewDate: Date?
    @State private var longPressStartDate: Date?
    @State private var navigatingToPlacesManager = false
    

    init(selectedDate: Date = Calendar.current.startOfDay(for: Date())) {
        self._selectedDate = State(initialValue: selectedDate)
        self._activatedDate = State(initialValue: selectedDate)
        self._scrollID = State(initialValue: selectedDate)
    }
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    dateNavigator(proxy: proxy)
                    pagedTimelineScrollView
                }
            }
            .navigationTitle("地方客")
            .navigationBarTitleDisplayMode(.inline)
            .background(
                LinearGradient(
                    colors: [.dfkBackground, .dfkAccent.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .toolbar { toolbarContent }
            .onAppear { setupView() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DFKDeepLinkNotification"))) { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in updateData() }
            .overlay { statusOverlays }
            .sheet(item: $showingRawPointsDate) { item in
                RawPointsListView(date: item.date)
                    .environment(locationManager)
            }
            .onDisappear {
                stopRepeatTimer()
                updateTask?.cancel()
                activationTask?.cancel()
                arrowTapFinalizeTask?.cancel()
                arrowTapPreviewTask?.cancel()
                jumpToTodayHapticTask?.cancel()
            }
            .onChange(of: manualSelections) { _, _ in
                updateData()
            }
            .onChange(of: allInsights) { _, _ in
                updateInsights()
            }

            .onChange(of: footprints) { _, _ in
                updateData()
            }
            .onChange(of: allPlaces) { _, newValue in
                locationManager.allPlaces = newValue
                locationManager.forceRefreshOngoingAnalysis()
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .alert("重新生成本日数据", isPresented: $showingResetAlert) {
                Button("确定重新生成", role: .destructive) {
                    Aptabase.shared.trackEvent("timeline_rebuilt")
                    locationManager.resetData(for: activatedDate)
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这将删除已手动修正或确认的足迹记录，并基于原始轨迹点重新分析生成时间线。")
            }
            .navigationDestination(isPresented: $navigatingToPlacesManager) {
                PlacesManagerView(startInAddMode: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToImportantPlaces"))) { _ in
                navigatingToPlacesManager = true
            }
        }
    }
    
    @ViewBuilder
    private var pagedTimelineScrollView: some View {
        ZStack(alignment: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(cachedDates, id: \.self) { date in
                        timelinePage(for: date)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollID)
            .onChange(of: scrollID) { oldValue, newValue in
                handleScrollChange(oldValue: oldValue, newValue: newValue)
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
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(destination: HistoryListView(initialDate: activatedDate)) {
                Image(systemName: "calendar.badge.clock")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Text("地方客").font(.headline).foregroundColor(.primary)
                if OpenAIService.shared.isNetworkRequesting {
                    ProgressView().controlSize(.small).transition(.opacity.combined(with: .scale))
                }
            }
        }
    }
    
    @ViewBuilder
    private var statusOverlays: some View {
        if locationManager.showSyncInquiry {
            syncInquiryOverlay
        } else if locationManager.isSyncingInitialData {
            syncingOverlay
        } else if locationManager.isResettingData {
            resettingOverlay
        }
    }
    
    private var syncingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(locationManager.syncStatusMessage).font(.headline).foregroundColor(.white)
                VStack(spacing: 12) {
                    ProgressView(value: locationManager.syncProgress, total: 1.0)
                        .progressViewStyle(.linear).tint(.white).frame(width: 240).scaleEffect(x: 1, y: 1.5, anchor: .center)
                    Text("\(Int(locationManager.syncProgress * 100))%").font(.caption).foregroundColor(.white.opacity(0.7))
                }
                Text("正在为您处理数据\n这可能需要一点时间").font(.caption).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.8))
            }
            .padding(32).background(.ultraThinMaterial).cornerRadius(28).shadow(radius: 20)
        }
        .transition(.opacity.combined(with: .scale))
    }
    
    private var resettingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.5).tint(.primary)
                Text("正在重置数据...").font(.headline).foregroundColor(.primary)
                Text("正在重新分析原始轨迹点\n这可能需要几十秒时间").font(.caption).multilineTextAlignment(.center).foregroundColor(.primary.opacity(0.8))
            }
            .padding(32).background(.ultraThinMaterial).cornerRadius(28).shadow(color: .black.opacity(0.2), radius: 20)
        }
        .transition(.opacity.combined(with: .scale))
    }
    
    private func setupView() {
        locationManager.modelContext = modelContext
        locationManager.allPlaces = allPlaces
        if UserDefaults.standard.bool(forKey: "isTrackingEnabled") && !locationManager.isTracking {
            locationManager.startTracking()
        }
        locationManager.refreshAvailableRawDates()
        updateData()
        
        if !UserDefaults.standard.bool(forKey: "didInitialSyncAfterInstall") {
            if locationManager.hasExistingCloudData() {
                locationManager.showSyncInquiry = true
            } else {
                UserDefaults.standard.set(true, forKey: "didInitialSyncAfterInstall")
            }
        }
        
        // 核心修复：处理冷启动时的 deep link
        if let deepLinkDate = locationManager.deepLinkDate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring()) {
                    self.selectedDate = deepLinkDate
                    self.scrollID = deepLinkDate
                }
            }
            locationManager.deepLinkDate = nil
        }
    }
    
    private func handleScrollChange(oldValue: Date?, newValue: Date?) {
        guard let newValue = newValue else { return }

        if newValue != oldValue {
            // 限制振动频率，避免连续切换时马达过载
            if !isPressingArrow {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        
        if isArrowTapAnimating {
            // 正在箭头动画中，仅更新预览日期供 Header 显示，坚决不提前激活和进行重绘
            arrowTapPreviewDate = newValue
            return
        }
        
        if !isPressingArrow {
            selectedDate = newValue
            scheduleDateActivation(for: newValue)
        }
        if !Calendar.current.isDate(newValue, inSameDayAs: Date()) {
            UserDefaults.standard.set(true, forKey: "hasSwiped")
        }
        preLoadTask?.cancel()
        preLoadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // Delay preloading to avoid stuttering during scroll animation
            if Task.isCancelled { return }
            preLoadNeighborDates(around: newValue)
        }
    }

    private func scheduleDateActivation(for date: Date, delayOverride: UInt64? = nil) {
        activationTask?.cancel()
        
        // 增加防抖时间，防止快速滑动时频繁触发重绘
        let delay: UInt64 = delayOverride ?? (isPressingArrow ? 300_000_000 : 200_000_000)
        
        activationTask = Task { @MainActor in
            if delay == 0 {
                // 即使 delay 为 0，也让当前渲染帧完成后再激活，避免卡住动画
                await Task.yield()
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                activatedDate = date
            }
        }
    }

    private func finalizeArrowTapSwipeIfNeeded() {
        guard isArrowTapAnimating, let targetDate = arrowTapTargetDate else { return }
        arrowTapFinalizeTask?.cancel()
        arrowTapPreviewTask?.cancel()
        jumpToTodayHapticTask?.cancel()

        // proxy.scrollTo 不保证总会及时回写 scrollID，收尾必须以目标日期为准。
        scrollID = targetDate
        selectedDate = targetDate
        isArrowTapAnimating = false
        arrowTapTargetDate = nil
        arrowTapPreviewDate = nil

        // 给一小段时间让滚动动画帧先完成渲染，再触发耗时的 TimelinePageView 重建
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms，让 scroll settle
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                activatedDate = targetDate
            }
            preLoadNeighborDates(around: targetDate)
        }
    }

    private func scheduleArrowTapFinalizeFallbackIfNeeded(duration: TimeInterval) {
        arrowTapFinalizeTask?.cancel()
        arrowTapFinalizeTask = Task { @MainActor in
            let nanos = UInt64((duration + 0.05) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            finalizeArrowTapSwipeIfNeeded()
        }
    }
    
    private func handleDeepLink(_ notification: Notification) {
        if let date = notification.userInfo?["date"] as? Date {
            let dayStart = Calendar.current.startOfDay(for: date)
            
            if let footprintID = notification.userInfo?["footprintID"] as? UUID {
                locationManager.deepLinkFootprintID = footprintID
            }
            
            locationManager.deepLinkDate = dayStart
            withAnimation(.spring()) {
                self.selectedDate = dayStart
                self.scrollID = dayStart
            }
        }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == "difangke" && url.host == "timeline" else { return }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let offsetString = components?.queryItems?.first(where: { $0.name == "offset" })?.value,
           let offset = Int(offsetString) {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            if let targetDate = calendar.date(byAdding: .day, value: offset, to: today) {
                withAnimation(.spring()) {
                    self.selectedDate = targetDate
                    self.scrollID = targetDate
                }
            }
        }
    }

    @ViewBuilder
    private func timelinePage(for date: Date) -> some View {
        let offset = latestOffsetIn(date: date)
        let dayFootprints = groupedFootprints[date] ?? []
        let dayManualSelections = groupedManualSelections[date] ?? []
        let dayInsight = groupedInsights[date]
        TimelinePageView(
            date: date, 
            footprints: dayFootprints, 
            manualSelections: dayManualSelections, 
            allPlaces: allPlaces, 
            offset: offset, 
            locationManager: locationManager, 
            pastLimitOffset: pastLimitOffset,
            isActivePage: activatedDate == date,
            dailyInsight: dayInsight
        )
        .frame(width: UIScreen.main.bounds.width)
        .id(date)
    }

    private func updateData() {
        updateTask?.cancel()
        
        let rawDates = locationManager.availableRawDates
        let todayVal = Calendar.current.startOfDay(for: Date())
        
        updateTask = Task { @MainActor in
            // 清理当前选中日期的缓存，确保刷新后能看到最新结果
            TimelineBuilder.timelineCache.removeValue(forKey: activatedDate)
            
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            // 1. 获取所有足迹并合并重复 UUID（防止脏数据导致时间轴重叠显示两个一模一样的）
            // 移入 Task 中并放在 sleep 之后，利用防抖避免主线程卡顿
            var seenUUIDs = Set<UUID>()
            let uniqueFootprints = footprints.filter { fp in
                if seenUUIDs.contains(fp.footprintID) || fp.status == .ignored { return false }
                seenUUIDs.insert(fp.footprintID)
                return true
            }

            let calendar = Calendar.current
            let capturedToday = todayVal
            let capturedRawDates = rawDates
            
            // 1. Group everything on main thread to avoid PersistentIdentifier crossing context issues
            var newGrouped: [Date: [Footprint]] = [:]
            for fp in uniqueFootprints {
                let startDay = calendar.startOfDay(for: fp.startTime)
                let effectiveEndTime = fp.endTime.addingTimeInterval(-0.001)
                let endDay = calendar.startOfDay(for: max(fp.startTime, effectiveEndTime))
                
                var datePtr = startDay
                while datePtr <= endDay {
                    newGrouped[datePtr, default: []].append(fp)
                    guard let nextDate = calendar.date(byAdding: .day, value: 1, to: datePtr) else { break }
                    datePtr = nextDate
                }
            }
            
            var newManualGrouped: [Date: [TransportManualSelection]] = [:]
            for selection in manualSelections {
                let day = calendar.startOfDay(for: selection.startTime)
                newManualGrouped[day, default: []].append(selection)
            }
            
            var newGroupedInsights: [Date: DailyInsight] = [:]
            for insight in allInsights {
                if let d = insight.date {
                    let day = calendar.startOfDay(for: d)
                    newGroupedInsights[day] = insight
                }
            }
            
            let results = await Task.detached(priority: .userInitiated) {
                // Generate date list and limitOffset in background
                var limitOffset = -1
                if let earliest = uniqueFootprints.last {
                    let earliestDataDate = calendar.startOfDay(for: earliest.startTime)
                    if let limitDate = calendar.date(byAdding: .day, value: -1, to: earliestDataDate) {
                        let diff = calendar.dateComponents([.day], from: capturedToday, to: limitDate).day ?? 0
                        limitOffset = min(-1, diff)
                    }
                }
                
                let validDatesWithData = Set(newGrouped.keys).union(capturedRawDates)
                let allOffsets = Array(limitOffset...1)
                let finalDates = allOffsets.compactMap { offset in
                    if offset == 1 || offset == 0 || offset == limitOffset {
                        return calendar.date(byAdding: .day, value: offset, to: capturedToday)
                    }
                    if let date = calendar.date(byAdding: .day, value: offset, to: capturedToday) {
                        return validDatesWithData.contains(date) ? date : nil
                    }
                    return nil
                }
                
                return (limitOffset, finalDates)
            }.value
            
            if Task.isCancelled { return }
            
            await MainActor.run {
                let (limitOffset, finalDates) = results
                
                let structureChanged = self.cachedDates.count != finalDates.count || self.cachedDates.first != finalDates.first || self.pastLimitOffset != limitOffset
                
                if structureChanged {
                    self.cachedDates = finalDates
                    self.pastLimitOffset = limitOffset
                }
                
                self.groupedFootprints = newGrouped
                self.groupedManualSelections = newManualGrouped
                self.groupedInsights = newGroupedInsights
            }
        }
    }

    private func updateInsights() {
        // Now handled inside updateData background task to avoid main thread work
        // but kept for immediate changes to allInsights
        let calendar = Calendar.current
        var newGrouped: [Date: DailyInsight] = [:]
        for insight in allInsights {
            if let d = insight.date {
                let day = calendar.startOfDay(for: d)
                newGrouped[day] = insight
            }
        }
        self.groupedInsights = newGrouped
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
            
            // Optimized: Skip pre-loading for empty historical dates
            let dayFootprints = groupedFootprints[startOfDay] ?? []
            let hasRawData = locationManager.availableRawDates.contains(startOfDay)
            if !calendar.isDateInToday(neighbor) && dayFootprints.isEmpty && !hasRawData {
                TimelineBuilder.timelineCache[startOfDay] = []
                continue
            }
            
            // 只预读数据库里已经保存的时间线，不能在切日期时重新按 raw points 生成。
            // 否则会把时间线编辑器里的手动拆分/合并/拖拽结果用旧算法缓存盖掉。
            TimelineBuilder.timelineCache[startOfDay] = PersistentTimelineBuilder.fetchTimeline(for: startOfDay, in: modelContext)
        }
    }
    
    private func dateNavigator(proxy: ScrollViewProxy) -> some View {
        HStack {
            navigationArrow(direction: -1, proxy: proxy)
            
            Spacer()
            Button {
                showingCalendar = true
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
            .popover(isPresented: $showingCalendar) {
                let today = Calendar.current.startOfDay(for: Date())
                let activeDates = Set(cachedDates.filter { $0 <= today })
                
                MiniCalendarView(selectedDate: $selectedDate, availableDates: activeDates) { date in
                    showingCalendar = false
                    scrollID = date
                }
                .presentationCompactAdaptation(.popover)
            }
            .contextMenu {
                Button {
                    showingRawPointsDate = IdentifiableDate(date: activatedDate)
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
            
            Spacer()
            
            navigationArrow(direction: 1, proxy: proxy)
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
    private func navigationArrow(direction: Int, proxy: ScrollViewProxy) -> some View {
        let isDisabled = (direction == -1) ? isAtStart : isAtEnd
        let icon = (direction == -1) ? "chevron.left" : rightArrowIcon
        
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isDisabled ? .secondary.opacity(0.5) : .primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.secondary.opacity(0.1)))
            .contentShape(Circle())
            .opacity(isDisabled ? 0.5 : (isPressingArrow && currentPressDirection == direction ? 0.7 : 1.0))
            .onLongPressGesture(minimumDuration: 0.3, perform: {}) { pressing in
                self.isPressingArrow = pressing
                self.currentPressDirection = pressing ? direction : 0
                if pressing && !isDisabled && !isArrowTapAnimating {
                    startRepeatTimer(direction: direction, proxy: proxy)
                } else {
                    stopRepeatTimer()
                }
            }
            .onTapGesture {
                if !isDisabled && !isArrowTapAnimating {
                    if direction == 1 && isFarFromToday {
                        simulateArrowTapSwipeToToday(proxy: proxy)
                    } else {
                        simulateArrowTapSwipe(by: direction, proxy: proxy)
                    }
                }
            }
    }
    
    private var rightArrowIcon: String {
        isFarFromToday ? "chevron.right.to.line" : "chevron.right"
    }

    private var displayDate: Date {
        if isPressingArrow {
            return longPressPreviewDate ?? scrollID ?? selectedDate
        }
        if isArrowTapAnimating {
            return arrowTapPreviewDate ?? scrollID ?? selectedDate
        }
        return selectedDate
    }
    
    private let sharedCalendar = Calendar.current
    
    private func latestOffsetIn(date: Date) -> Int {
        let today = sharedCalendar.startOfDay(for: Date())
        let diff = sharedCalendar.dateComponents([.day], from: today, to: sharedCalendar.startOfDay(for: date)).day ?? 0
        return diff
    }
    
    private var isAtEnd: Bool {
        let referenceDate = isPressingArrow ? (longPressPreviewDate ?? scrollID ?? selectedDate) : selectedDate
        if !cachedDates.isEmpty {
            return (cachedDates.firstIndex(of: referenceDate) ?? 0) >= (cachedDates.count - 1)
        }
        return true
    }
    
    private var isAtStart: Bool {
        let referenceDate = isPressingArrow ? (longPressPreviewDate ?? scrollID ?? selectedDate) : selectedDate
        if !cachedDates.isEmpty {
             return (cachedDates.firstIndex(of: referenceDate) ?? 0) <= 0
        }
        return true
    }
    
    private var isTodaySelected: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: Date())
    }
    
    /// 距离今天超过5天时显示跳回图标
    private var isFarFromToday: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: displayDate, to: today).day ?? 0
        return days >= 5
    }
    
    private func startRepeatTimer(direction: Int, proxy: ScrollViewProxy) {
        stopRepeatTimer()
        let startDate = scrollID ?? selectedDate
        longPressStartDate = startDate
        longPressPreviewDate = startDate
        repeatTimerInterval = 0.24
        repeatStepCount = 0
        
        // 延迟一段时间后开始连续触发
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.isPressingArrow && self.currentPressDirection == direction else { return }
            self.triggerNextStep(direction: direction, proxy: proxy)
        }
    }
    
    private func triggerNextStep(direction: Int, proxy: ScrollViewProxy) {
        guard isPressingArrow && currentPressDirection == direction else { return }
        
        repeatStepCount += 1
        let daysToAdvance = longPressStepSpan(for: repeatStepCount, interval: repeatTimerInterval)
        let duration = longPressAnimationDuration(for: daysToAdvance)
        let didAdvance = step(direction: direction, days: daysToAdvance, duration: duration, proxy: proxy)
        guard didAdvance else { return }

        // 对齐小日历：每推进一步给一次 light impact。
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // 速度递增逻辑：更快的加速度，更小的最小间隔
        let nextInterval = max(0.08, repeatTimerInterval * 0.85)
        repeatTimerInterval = nextInterval
        
        let nextTick = max(0.08, min(duration * 0.82, repeatTimerInterval))
        repeatTimer = Timer.scheduledTimer(withTimeInterval: nextTick, repeats: false) { _ in
            self.triggerNextStep(direction: direction, proxy: proxy)
        }
    }
    
    private func stopRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = nil

        let finalDate = longPressPreviewDate ?? scrollID ?? selectedDate
        selectedDate = finalDate
        longPressPreviewDate = nil
        longPressStartDate = nil
        
        // 长按结束，确保最后停下的日期被激活并渲染
        if activatedDate != selectedDate {
            scrollID = selectedDate
            withAnimation(.easeInOut(duration: 0.2)) {
                activatedDate = selectedDate
            }
            preLoadTask?.cancel()
            preLoadTask = Task { @MainActor in
                preLoadNeighborDates(around: selectedDate)
            }
        }
    }
    
    private var dateHeader: String {
        let calendar = Calendar.current
        let display = displayDate
        if calendar.isDateInToday(display) { return "今天" }
        if calendar.isDateInYesterday(display) { return "昨天" }
        if calendar.isDateInTomorrow(display) { return "明天" }
        
        let today = calendar.startOfDay(for: Date())
        if let dby = calendar.date(byAdding: .day, value: -2, to: today),
           calendar.isDate(display, inSameDayAs: dby) {
            return "前天"
        }
        
        let isCurrentYear = calendar.component(.year, from: display) == calendar.component(.year, from: today)
        return isCurrentYear ? display.formatted(.dateTime.month().day()) : display.formatted(.dateTime.year().month().day())
    }
    
    private var secondaryHeader: String {
        let calendar = Calendar.current
        let display = displayDate
        let today = calendar.startOfDay(for: Date())
        let dby = calendar.date(byAdding: .day, value: -2, to: today)!
        let isRelative = calendar.isDateInToday(display) || 
                         calendar.isDateInYesterday(display) || 
                         calendar.isDateInTomorrow(display) ||
                         calendar.isDate(display, inSameDayAs: dby)
        
        if isRelative {
            let isCurrentYear = calendar.component(.year, from: display) == calendar.component(.year, from: today)
            let dateStr = isCurrentYear ? display.formatted(.dateTime.month().day()) : display.formatted(.dateTime.year().month().day())
            return "\(dateStr) \(display.formatted(.dateTime.weekday(.wide)))"
        } else {
            return display.formatted(.dateTime.weekday(.wide))
        }
    }
    
    private func step(direction: Int, days: Int, duration: TimeInterval, proxy: ScrollViewProxy) -> Bool {
        let isDisabled = (direction == -1) ? isAtStart : isAtEnd
        if !isDisabled {
            return fastContinuousScroll(by: direction, days: days, duration: duration, proxy: proxy)
        } else {
            stopRepeatTimer()
            return false
        }
    }

    private func fastContinuousScroll(by direction: Int, days: Int, duration: TimeInterval, proxy: ScrollViewProxy) -> Bool {
        let anchorDate = longPressPreviewDate ?? scrollID ?? selectedDate
        guard let currentIndex = cachedDates.firstIndex(of: anchorDate) else { return false }

        let nextIndex = currentIndex + direction * max(1, days)
        guard nextIndex >= 0 && nextIndex < cachedDates.count else { return false }

        let targetDate = cachedDates[nextIndex]
        longPressPreviewDate = targetDate

        withAnimation(.linear(duration: duration)) {
            proxy.scrollTo(targetDate, anchor: .center)
        }
        return true
    }

    private func longPressStepSpan(for stepCount: Int, interval: Double) -> Int {
        if stepCount < 5 { return 1 }
        if interval > 0.18 { return 2 }
        if interval > 0.13 { return 3 }
        return 4
    }

    private func longPressAnimationDuration(for days: Int) -> TimeInterval {
        let scaled = 0.22 + Double(max(days, 1)) * 0.06
        return min(0.55, max(0.22, scaled))
    }

    private func simulateArrowTapSwipe(by direction: Int, proxy: ScrollViewProxy) {
        let anchorDate = scrollID ?? selectedDate
        guard let currentIndex = cachedDates.firstIndex(of: anchorDate) else { return }

        let nextIndex = currentIndex + direction
        guard nextIndex >= 0 && nextIndex < cachedDates.count else { return }

        let targetDate = cachedDates[nextIndex]
        arrowTapTargetDate = targetDate
        arrowTapPreviewDate = targetDate // 立刻更新 header 显示，无需等动画结束
        isArrowTapAnimating = true
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(targetDate, anchor: .center)
        }
        scheduleArrowTapFinalizeFallbackIfNeeded(duration: 0.45)
    }

    private func simulateArrowTapSwipeToToday(proxy: ScrollViewProxy) {
        let anchorDate = scrollID ?? selectedDate
        let today = Calendar.current.startOfDay(for: Date())
        guard !Calendar.current.isDate(anchorDate, inSameDayAs: today) else { return }

        let distance = abs(Calendar.current.dateComponents([.day], from: anchorDate, to: today).day ?? 0)
        let duration = jumpToTodayAnimationDuration(for: distance)

        arrowTapTargetDate = today
        arrowTapPreviewDate = anchorDate
        isArrowTapAnimating = true
        animateArrowTapPreview(from: anchorDate, to: today, duration: duration)
        scheduleArrowTapFinalizeFallbackIfNeeded(duration: duration)
        startJumpToTodayHaptics(duration: duration)
        withAnimation(.linear(duration: duration)) {
            proxy.scrollTo(today, anchor: .center)
        }
    }

    private func animateArrowTapPreview(from startDate: Date, to endDate: Date, duration: TimeInterval) {
        arrowTapPreviewTask?.cancel()

        guard let startIndex = cachedDates.firstIndex(of: startDate),
              let endIndex = cachedDates.firstIndex(of: endDate),
              startIndex != endIndex else {
            arrowTapPreviewDate = endDate
            return
        }

        let total = abs(endIndex - startIndex)
        let direction = endIndex > startIndex ? 1 : -1

        arrowTapPreviewTask = Task { @MainActor in
            let start = Date()
            var lastStep = -1

            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let progress = min(1, elapsed / max(duration, 0.001))
                let stepped = min(total, Int((Double(total) * progress).rounded(.down)))

                if stepped != lastStep {
                    let idx = startIndex + stepped * direction
                    if idx >= 0 && idx < cachedDates.count {
                        arrowTapPreviewDate = cachedDates[idx]
                    }
                    lastStep = stepped
                }

                if progress >= 1 { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            arrowTapPreviewDate = endDate
        }
    }

    private func startJumpToTodayHaptics(duration: TimeInterval) {
        jumpToTodayHapticTask?.cancel()
        jumpToTodayHapticTask = Task { @MainActor in
            let start = Date()
            var tick = 0

            while !Task.isCancelled, Date().timeIntervalSince(start) < duration {
                let elapsed = Date().timeIntervalSince(start)
                let progress = min(1, elapsed / max(duration, 0.001))

                if progress < 0.45 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else if progress < 0.8 {
                    if tick % 2 == 0 {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                } else {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
                }

                tick += 1
                let interval = max(0.06, 0.16 - progress * 0.1)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func jumpToTodayAnimationDuration(for distance: Int) -> TimeInterval {
        guard distance > 1 else { return 0.3 }
        // 距离越远滚动越慢，确保能感知到跨多天滑动效果。
        let scaled = 0.24 + Double(distance) * 0.11
        return min(2.0, max(0.3, scaled))
    }

    private func jumpToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        let days = abs(Calendar.current.dateComponents([.day], from: selectedDate, to: today).day ?? 0)
        
        // 动态计算响应时间：日期间隔越远，滚动越慢
        let response = min(1.2, 0.5 + Double(days) * 0.01)
        
        withAnimation(.spring(response: response, dampingFraction: 0.95)) {
            selectedDate = today
            scrollID = today
        }
        
        // 既然是主动跳转今天，直接激活
        withAnimation(.easeInOut(duration: 0.2)) {
            activatedDate = today
        }
    }
    
    private func changeDate(by direction: Int, isContinuous: Bool = false) {
        guard let currentIndex = cachedDates.firstIndex(of: selectedDate) else {
            jumpToToday()
            return
        }
        
        let nextIndex = currentIndex + direction
        if nextIndex >= 0 && nextIndex < cachedDates.count {
            let targetDate = cachedDates[nextIndex]
            
            if isContinuous {
                // 连续切换时：使用响应极快的交互式弹簧，模拟滑动手感，但不开启全量重绘
                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85, blendDuration: 0.1)) {
                    selectedDate = targetDate
                    scrollID = targetDate
                }
            } else {
                // 单次点击：保持标准弹性滑动动画，提供明确的反馈感
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    selectedDate = targetDate
                    scrollID = targetDate
                }
            }
        }
    }
    
    // MARK: - Sync Inquiry Helper
    @State private var showingPurgeConfirmation = false
    
    private var syncInquiryOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 28) {
                // Header
                ZStack {
                    Circle()
                        .fill(Color.dfkAccent.opacity(0.1))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.dfkAccent)
                }
                
                VStack(spacing: 12) {
                    Text("发现云端历史记录")
                        .font(.title3.bold())
                    
                    Text("我们在 iCloud 中发现了您之前的足迹记录，是否需要将它们恢复到此设备？")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                
                VStack(spacing: 12) {
                    // Sync Button
                    Button {
                        locationManager.showSyncInquiry = false
                        UserDefaults.standard.set(true, forKey: "isSyncChoiceMade")
                        UserDefaults.standard.set(true, forKey: "didInitialSyncAfterInstall")
                        
                        // 通知 App 重新加载带 CloudKit 的 ModelContainer
                        NotificationCenter.default.post(name: NSNotification.Name("RefreshModelContainer"), object: nil)
                        
                        Task {
                            await locationManager.performRawDataSync(showOverlay: true)
                        }
                    } label: {
                        Text("立即同步")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.dfkAccent)
                            .cornerRadius(16)
                    }
                    
                    // Purge Button
                    Button {
                        showingPurgeConfirmation = true
                    } label: {
                        Text("不使用历史记录")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
            }
            .padding(32)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(30)
            .shadow(radius: 25)
            .padding(30)
        }
        .transition(.opacity.combined(with: .scale))
        .alert("确定不进行同步吗？", isPresented: $showingPurgeConfirmation) {
            Button("同步", role: .cancel) { }
            Button("确定不同步并删除", role: .destructive) {
                locationManager.showSyncInquiry = false
                UserDefaults.standard.set(true, forKey: "isSyncChoiceMade")
                UserDefaults.standard.set(true, forKey: "didInitialSyncAfterInstall")
                
                // 即使不同步，也要让 Container 恢复正常（虽然云端已被删，但后续需要正常开启 iCloud 备份本地数据）
                NotificationCenter.default.post(name: NSNotification.Name("RefreshModelContainer"), object: nil)
                
                Task {
                    await locationManager.purgeCloudData()
                }
            }
        } message: {
            Text("这将会永久删除 iCloud 中的所有记录，且无法恢复。如果您想开启全新的记录体验，请选择确定。")
        }
    }
}
