import SwiftUI
import SwiftData
import MapKit
import UIKit
import Combine
import Photos

struct DayTimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Footprint.startTime, order: .reverse) private var footprints: [Footprint]
    
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
    @Query private var allInsights: [DailyInsight]
    @State private var groupedInsights: [Date: DailyInsight] = [:]
    @State private var showingResetAlert = false
    @State private var showingCalendar = false
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
                            timelinePage(for: date)
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
                        Image(systemName: "calendar.badge.clock")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
                
                // AI 活动指示器
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("地方客")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if OpenAIService.shared.isNetworkRequesting {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.opacity.combined(with: .scale))
                        }
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
                
                // 探测重装/首次同步
                if !UserDefaults.standard.bool(forKey: "didInitialSyncAfterInstall") {
                    Task {
                        await locationManager.performRawDataSync(showOverlay: true)
                    }
                    UserDefaults.standard.set(true, forKey: "didInitialSyncAfterInstall")
                }
            }
            .overlay {
                if locationManager.isSyncingInitialData {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            
                            Text(locationManager.syncStatusMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Text("正在为您恢复历史足迹数据\n这可能需要一点时间")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(30)
                        .background(.ultraThinMaterial)
                        .cornerRadius(24)
                        .shadow(radius: 20)
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onDisappear {
                stopRepeatTimer()
                updateTask?.cancel()
            }
            .onChange(of: footprints) { _, _ in
                TimelineBuilder.timelineCache.removeAll()
                updateData()
            }
            .onChange(of: manualSelections) { _, _ in
                updateData()
            }
            .onChange(of: allInsights) { _, _ in
                updateInsights()
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
            .alert("AI 服务提示", isPresented: Binding(
                get: { OpenAIService.shared.lastError != nil },
                set: { if !$0 { OpenAIService.shared.lastError = nil } }
            )) {
                Button("确定", role: .cancel) { }
            } message: {
                if let error = OpenAIService.shared.lastError {
                    Text(error)
                }
            }
        } // NavigationStack
    } // body

    @ViewBuilder
    private func timelinePage(for date: Date) -> some View {
        let offset = latestOffsetIn(date: date)
        let dayFootprints = groupedFootprints[date] ?? []
        let dayManualSelections = groupedManualSelections[date] ?? []
        let daySummary = groupedInsights[date]?.content
        
        TimelinePageView(
            date: date, 
            footprints: dayFootprints, 
            manualSelections: dayManualSelections, 
            allPlaces: allPlaces, 
            offset: offset, 
            locationManager: locationManager, 
            pastLimitOffset: pastLimitOffset,
            summaryContent: daySummary
        )
        .frame(width: UIScreen.main.bounds.width)
        .id(date)
    }

    private func updateData() {
        updateTask?.cancel()
        
        let rawDates = locationManager.availableRawDates
        // 1. 获取所有足迹并合并重复 UUID（防止脏数据导致时间轴重叠显示两个一模一样的）
        var seenUUIDs = Set<UUID>()
        let uniqueFootprints = footprints.filter { fp in
            if seenUUIDs.contains(fp.footprintID) { return false }
            seenUUIDs.insert(fp.footprintID)
            return true
        }
        
        let todayVal = Calendar.current.startOfDay(for: Date())
        let footprintIDs = uniqueFootprints.map { $0.persistentModelID }
        let manualIDs = manualSelections.map { $0.persistentModelID }
        let container = modelContext.container
        
        updateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            let calendar = Calendar.current
            let capturedToday = todayVal
            let capturedRawDates = rawDates
            
            // 1. 分类足迹 - Move grouping logic to background safely
            let results = await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                var newGroupedIDs: [Date: [PersistentIdentifier]] = [:]
                
                // Fetch only needed properties or use lite conversion in background
                for id in footprintIDs {
                    guard let fp = context.model(for: id) as? Footprint else { continue }
                    
                    let startDay = calendar.startOfDay(for: fp.startTime)
                    let effectiveEndTime = fp.endTime.addingTimeInterval(-0.001)
                    let endDay = calendar.startOfDay(for: max(fp.startTime, effectiveEndTime))
                    
                    var datePtr = startDay
                    while datePtr <= endDay {
                        newGroupedIDs[datePtr, default: []].append(id)
                        guard let nextDate = calendar.date(byAdding: .day, value: 1, to: datePtr) else { break }
                        datePtr = nextDate
                    }
                }
                
                // 2. 分类手工选择
                var newManualGroupedIDs: [Date: [PersistentIdentifier]] = [:]
                for id in manualIDs {
                    guard let selection = context.model(for: id) as? TransportManualSelection else { continue }
                    let day = calendar.startOfDay(for: selection.startTime)
                    newManualGroupedIDs[day, default: []].append(id)
                }
                
                // Calculate limitOffset in background
                let sortedIDs = footprintIDs // They were already sorted by startTime reverse
                var limitOffset = -1
                if let earliestID = sortedIDs.last, let earliest = context.model(for: earliestID) as? Footprint {
                    let earliestDataDate = calendar.startOfDay(for: earliest.startTime)
                    if let limitDate = calendar.date(byAdding: .day, value: -1, to: earliestDataDate) {
                        let diff = calendar.dateComponents([.day], from: capturedToday, to: limitDate).day ?? 0
                        limitOffset = min(-1, diff)
                    }
                }
                
                // 3. 生成日期列表
                let validDatesWithData = Set(newGroupedIDs.keys).union(capturedRawDates)
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
                
                // 4. 生成总结缓存映射 (New: handle insights in background too)
                var newGroupedInsights: [Date: PersistentIdentifier] = [:]
                let insightDescriptor = FetchDescriptor<DailyInsight>()
                if let insights = try? context.fetch(insightDescriptor) {
                    for insight in insights {
                        if let d = insight.date {
                            let day = calendar.startOfDay(for: d)
                            newGroupedInsights[day] = insight.persistentModelID
                        }
                    }
                }
                
                return (newGroupedIDs, newManualGroupedIDs, limitOffset, finalDates, newGroupedInsights)
            }.value
            
            if Task.isCancelled { return }
            
            await MainActor.run {
                let (newGroupedIDs, newManualIDs, limitOffset, finalDates, newGroupedInsightIDs) = results
                
                // Re-bind to Main Context objects
                let footprintMap = Dictionary(footprints.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
                let manualMap = Dictionary(manualSelections.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
                let insightMap = Dictionary(allInsights.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
                
                let newGrouped = newGroupedIDs.mapValues { ids in
                    ids.compactMap { footprintMap[$0] }
                }
                let newManualGrouped = newManualIDs.mapValues { ids in
                    ids.compactMap { manualMap[$0] }
                }
                let newGroupedInsights = newGroupedInsightIDs.compactMapValues { id in
                    insightMap[id]
                }
                
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
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Label("重置本日数据", systemImage: "arrow.counterclockwise")
                }
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
        isFarFromToday ? "chevron.right.to.line" : "chevron.right"
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
        let days = abs(Calendar.current.dateComponents([.day], from: selectedDate, to: today).day ?? 0)
        
        // 动态计算响应时间：日期间隔越远，滚动越慢
        // 基准 0.5s，每增加 1 天约增加 0.01s，上限 1.2s (约 70 天时达到上限)
        let response = min(1.2, 0.5 + Double(days) * 0.01)
        
        withAnimation(.spring(response: response, dampingFraction: 0.95)) {
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
