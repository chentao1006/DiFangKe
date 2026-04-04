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
    
    @AppStorage("timelineFilter") private var timelineFilter: TimelineFilter = .all
    enum TimelineFilter: String, CaseIterable, Identifiable {
        case all = "全部日期"
        case footprintsOnly = "仅有足迹日期"
        var id: String { self.rawValue }
    }
    @State private var cachedFilteredOffsets: [Int] = []

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
                        ForEach(cachedFilteredOffsets, id: \.self) { offset in
                            if let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) {
                                TimelinePageView(date: date, footprints: footprints, offset: offset, locationManager: locationManager, pastLimitOffset: pastLimitOffset)
                                    .frame(width: UIScreen.main.bounds.width)
                                    .id(Calendar.current.startOfDay(for: date))
                            }
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
            }
        }
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
                    HStack(spacing: 16) {
                        filterMenu
                        
                        NavigationLink(destination: SettingsView()) {
                            Image(systemName: "gearshape")
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
                updateFilteredOffsets()
            }
            .onDisappear {
                stopRepeatTimer()
            }
            .onChange(of: footprints) { _, _ in
                updateFilteredOffsets()
            }
            .onChange(of: timelineFilter) { _, _ in
                updateFilteredOffsets()
                // 当切换过滤模式时，如果当前选中的日期被过滤了，跳回今天
                if !cachedFilteredOffsets.contains(latestOffsetIn(date: selectedDate)) {
                    jumpToToday()
                }
            }
            .onChange(of: allPlaces) { _, newValue in
                locationManager.allPlaces = newValue
                // If a place was added or modified, re-analyze his current stay immediately
                locationManager.forceRefreshOngoingAnalysis()
            }
        }
    }
    
    private var filterMenu: some View {
        Menu {
            Picker("日期过滤", selection: $timelineFilter) {
                ForEach(TimelineFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Image(systemName: timelineFilter == .footprintsOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundColor(timelineFilter == .footprintsOnly ? .dfkAccent : .primary)
        }
    }
    
    private func updateFilteredOffsets() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let all = Array(pastLimitOffset...1)
        
        if timelineFilter == .all {
            self.cachedFilteredOffsets = all
            return
        }
        
        let validDatesWithData = Set(footprints.compactMap { $0.status != .ignored ? calendar.startOfDay(for: $0.date) : nil })
        
        self.cachedFilteredOffsets = all.filter { offset in
            // 明天 (1), 今天 (0), 和 最早一天 (pastLimitOffset) 始终显示
            if offset == 1 || offset == 0 || offset == pastLimitOffset { return true }
            
            if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                return validDatesWithData.contains(date)
            }
            return false
        }
    }

    private var dateNavigator: some View {
        HStack {
            navigationArrow(direction: -1)
            
            Spacer()
            VStack(spacing: 2) {
                Text(dateHeader).font(.headline)
                Text(secondaryHeader).font(.caption).foregroundColor(.secondary)
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
    
    private var dateHeader: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return "今天" }
        if calendar.isDateInYesterday(selectedDate) { return "昨天" }
        if calendar.isDateInTomorrow(selectedDate) { return "明天" }
        
        if let dby = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date())),
           calendar.isDate(selectedDate, inSameDayAs: dby) {
            return "前天"
        }
        
        let isCurrentYear = calendar.component(.year, from: selectedDate) == calendar.component(.year, from: Date())
        return isCurrentYear ? selectedDate.formatted(.dateTime.month().day()) : selectedDate.formatted(.dateTime.year().month().day())
    }
    
    private var secondaryHeader: String {
        let calendar = Calendar.current
        let isRelative = calendar.isDateInToday(selectedDate) || 
                         calendar.isDateInYesterday(selectedDate) || 
                         calendar.isDateInTomorrow(selectedDate) ||
                         calendar.isDate(selectedDate, inSameDayAs: calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!)
        
        if isRelative {
            let isCurrentYear = calendar.component(.year, from: selectedDate) == calendar.component(.year, from: Date())
            let dateStr = isCurrentYear ? selectedDate.formatted(.dateTime.month().day()) : selectedDate.formatted(.dateTime.year().month().day())
            return "\(dateStr) \(selectedDate.formatted(.dateTime.weekday(.wide)))"
        } else {
            return selectedDate.formatted(.dateTime.weekday(.wide))
        }
    }
    
    private var isAtEnd: Bool {
        if !cachedFilteredOffsets.isEmpty {
            return (cachedFilteredOffsets.firstIndex(of: latestOffsetIn(date: selectedDate)) ?? 0) >= (cachedFilteredOffsets.count - 1)
        }
        return true
    }
    
    private func latestOffsetIn(date: Date) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let diff = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        return diff
    }
    
    private var pastLimitOffset: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // 过滤掉已忽略的足迹，只看可见数据
        let validFootprints = footprints.filter { $0.status != .ignored }
        
        // 由于 footprints 按 startTime reverse 排序，最后一项就是最早的
        if let earliestFootprint = validFootprints.last {
            let earliestDataDate = calendar.startOfDay(for: earliestFootprint.date)
            // 在最早数据的基础上多让滚一天（空白日期）
            if let limitDate = calendar.date(byAdding: .day, value: -1, to: earliestDataDate) {
                let diff = calendar.dateComponents([.day], from: today, to: limitDate).day ?? 0
                return min(-1, diff) // 确保至少能看到昨天（offset -1）
            }
        }
        
        // 默认如果没有数据，允许看到昨天
        return -1
    }
    
    private var limitDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: pastLimitOffset, to: today) ?? today
    }
    
    private var isAtStart: Bool {
        if !cachedFilteredOffsets.isEmpty {
             return (cachedFilteredOffsets.firstIndex(of: latestOffsetIn(date: selectedDate)) ?? 0) <= 0
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
        let currentOffset = latestOffsetIn(date: selectedDate)
        guard let currentIndex = cachedFilteredOffsets.firstIndex(of: currentOffset) else {
            // 如果当前日期不在过滤列表中（切换过滤模式时可能发生），尝试找最近的
            jumpToToday()
            return
        }
        
        let nextIndex = currentIndex + direction
        if nextIndex >= 0 && nextIndex < cachedFilteredOffsets.count {
            let nextOffset = cachedFilteredOffsets[nextIndex]
            if let nextDate = Calendar.current.date(byAdding: .day, value: nextOffset, to: Date()) {
                let targetDate = Calendar.current.startOfDay(for: nextDate)
                withAnimation(.spring()) {
                    selectedDate = targetDate
                    scrollID = targetDate
                }
            }
        }
    }
}

struct TimelinePageView: View {
    @Environment(\.modelContext) private var modelContext
    let date: Date
    let footprints: [Footprint]
    let offset: Int
    let locationManager: LocationManager
    let pastLimitOffset: Int
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    
    @State private var selectedFootprint: Footprint?
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
    
    var dailyFootprints: [Footprint] {
        footprints.filter { 
            Calendar.current.isDate($0.date, inSameDayAs: date) &&
            $0.status != .ignored
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
                
                if offset > 0 {
                    futurePlaceholderView
                } else if offset == pastLimitOffset {
                    pastPlaceholderView
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // 1. Unified Status & Ongoing Card
                        if isToday {
                            RecordingStatusCard(locationManager: locationManager, footprintCount: dailyFootprints.count)
                                .padding(.horizontal, 16)
                            
                            // Important Place Guide
                            if allPlaces.isEmpty && !isGuideDismissed {
                                importantPlaceGuide
                                    .padding(.top, 20)
                                    .padding(.bottom, 20)
                            }
                        }
                        
                         // 2. Historical Footprints
                         if dailyFootprints.isEmpty && (!isToday || locationManager.potentialStopStartLocation == nil) {
                             if allPlaces.isEmpty && isToday && !isGuideDismissed {
                                 EmptyView()
                             } else {
                                 emptyStateView
                             }
                         } else {
                             // Notification Guide (Show once first footprints are generated)
                             if !isNotificationGuideDismissed && isToday && notificationAuthStatus == .notDetermined {
                                 notificationGuide
                                     .padding(.top, 10)
                                     .padding(.bottom, 16)
                             }
                             
                             let count = dailyFootprints.count
                             ForEach(Array(dailyFootprints.enumerated()), id: \.element.id) { index, footprint in
                                 FootprintCardView(
                                     footprint: footprint, 
                                     allPlaces: allPlaces,
                                     isFirst: index == 0,
                                     isLast: index == count - 1,
                                     isToday: isToday
                                 ) { item, focus in
                                     self.autoFocusOnOpen = focus
                                     self.selectedFootprint = item
                                 }
                                 .padding(.horizontal, 16)
                             }
                         }
                    }
                    
                    // 3. Swipe Hint Footer (Only Today, only before first swipe)
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
        }
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
    @State private var showingStatusModal = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pulseScale: CGFloat = 1.0
    
    private var displayTitle: String {
        let isStopped = !locationManager.isTracking
        if isStopped {
            return "定位记录已关闭"
        } else if let ongoing = locationManager.ongoingTitle {
            return ongoing
        } else {
            return "正在记录足迹..."
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. 时间轴指示器：第一个点对齐标题，线上端不伸出
            VStack(spacing: 0) {
                // 顶部留白，使圆点圆心与卡片标题对齐 (16px padding + 5px height diff = 21px)
                Spacer().frame(height: 22)
                
                // 第一个圆点（带脉冲）
                ZStack {
                    Circle().stroke(Color.dfkAccent.opacity(0.3), lineWidth: 2)
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulseScale)
                        .opacity(2.2 - Double(pulseScale))
                    Circle().fill(Color.dfkAccent).frame(width: 10, height: 10)
                }.frame(width: 24, height: 24)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                        pulseScale = 2.2
                    }
                }
                
                // 只有向下的线下
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, -20)
            }.frame(width: 36)
            
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
                            } else if let duration = locationManager.stayDuration {
                                Text("已停留 \(duration)")
                                    .font(.caption2)
                                    .foregroundColor(Color.dfkSecondaryText)
                                    .id("duration-\(duration)")
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if let place = locationManager.matchedPlace {
                        let label = place.name
                        Text(label)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 16)
                .padding(.leading, 8)
                .padding(.trailing, 16)
                
                // Map Section
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    ForEach(locationManager.allPlaces) { place in
                        MapCircle(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: Double(place.radius))
                            .foregroundStyle(Color.orange.opacity(0.1))
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    }
                }
                .frame(height: 160)
                .cornerRadius(12)
                .disabled(true)
                .allowsHitTesting(false)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .onChange(of: locationManager.lastLocation, initial: true) { _, newLoc in
                    if let newLoc {
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
        .padding(.bottom, 14) // 使左侧线能连贯到下一个卡片
        .onTapGesture {
            showingStatusModal = true
        }
        .sheet(isPresented: $showingStatusModal) {
            TrackingStatusModalView(locationManager: locationManager, footprintCount: footprintCount)
        }
    }
}

struct FootprintCardView: View {
    @Bindable var footprint: Footprint
    let allPlaces: [Place]
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
        HStack(alignment: .top, spacing: 0) {
            if showTimeline {
                timelineIndicator
            }
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 4) {
                    if showDateAboveTitle {
                        Text(footprint.date.formatted(.dateTime.year().month().day()))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.bottom, -2)
                    }
                    
                    HStack(spacing: 6) {
                        Text(footprint.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(Color.dfkMainText)
                            .lineLimit(1)
                        
                        if let placeID = footprint.placeID,
                           let place = allPlaces.first(where: { $0.placeID == placeID }) {
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
                    
                    if !footprint.tags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(footprint.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.1))
                                    .foregroundColor(.green)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
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
                    
                    if let reason = footprint.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(Color.dfkSecondaryText.opacity(0.8))
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 14)
                .padding(.leading, showTimeline ? 0 : 16)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                
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
        let startStr = footprint.startTime.formatted(.dateTime.hour().minute())
        let endStr = footprint.endTime.formatted(.dateTime.hour().minute())
        
        let calendar = Calendar.current
        let isStartSameDay = calendar.isDate(footprint.startTime, inSameDayAs: footprint.date)
        let isEndSameDay = calendar.isDate(footprint.endTime, inSameDayAs: footprint.date)
        
        if isStartSameDay && isEndSameDay {
            return "\(startStr)-\(endStr)"
        } else if !isStartSameDay && isEndSameDay {
            return "昨日\(startStr)-\(endStr)"
        } else if isStartSameDay && !isEndSameDay {
            return "\(startStr)-次日\(endStr)"
        } else {
            return "\(footprint.startTime.formatted(.dateTime.month().day().hour().minute()))-\(footprint.endTime.formatted(.dateTime.month().day().hour().minute()))"
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
            // 上半部分连线：高度与卡片顶部间距对齐
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(height: 22)
                .opacity(isFirst && !isToday ? 0 : 1)
            
            // 状态圆点或五角星
            ZStack {
                if footprint.isHighlight == true {
                    Image(systemName: "star.fill").font(.system(size: 14)).foregroundColor(Color.dfkHighlight).padding(4).background(Circle().fill(Color(uiColor: .systemBackground)))
                } else {
                    Circle().fill(footprint.status == .ignored ? Color.secondary.opacity(0.4) : Color.dfkAccent).frame(width: 10, height: 10)
                        .scaleEffect(confirmedAnimating ? 1.4 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: confirmedAnimating)
                }
            }.frame(width: 24, height: 24)
            
            // 下半部分连线：贯通下方
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .padding(.bottom, -12) // 向下露出 12pt 用于连线（对应底边距 12pt）
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

// MARK: - Tracking Status Modal
struct TrackingStatusModalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    
    @Bindable var locationManager: LocationManager
    let footprintCount: Int
    
    var dailyFootprints: [Footprint] {
        allFootprints.filter { Calendar.current.isDate($0.date, inSameDayAs: Date()) && $0.status != .ignored }
    }
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showFullscreenMap = false
    @State private var showingAddPlaceSheet = false
    @State private var isSuggestionIgnored = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Map Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("今日轨迹预览").font(.subheadline.bold()).foregroundColor(.secondary).padding(.leading, 16)
                        
                        ZStack(alignment: .topTrailing) {
                            Map(position: $cameraPosition) {
                                UserAnnotation()
                                
                                // 改为显示全天流水（物理不删，连贯大连线）
                                let totalPoints = locationManager.allTodayPoints.map { $0.coordinate }
                                
                                if !totalPoints.isEmpty {
                                    MapPolyline(coordinates: totalPoints)
                                        .stroke(Color.dfkAccent, lineWidth: 3)
                                    
                                    if let first = totalPoints.first {
                                        Marker("", coordinate: first).tint(Color.dfkAccent)
                                    }
                                    if let last = totalPoints.last {
                                        Marker("", coordinate: last).tint(Color.dfkAccent)
                                    }
                                }

                                ForEach(locationManager.allPlaces) { place in
                                    MapCircle(center: place.coordinate, radius: Double(place.radius))
                                        .foregroundStyle(Color.orange.opacity(0.1))
                                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                                }
                            }
                            .frame(height: 200)
                            .cornerRadius(12)
                            .disabled(true)
                            
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .padding(12)
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                        .onTapGesture { 
                            showFullscreenMap = true 
                        }
                    }
                    
                    // Info Cards
                    VStack(spacing: 12) {
                        statusRow(title: "追踪状态", value: locationManager.isTracking ? "正在运行" : "已停止", color: locationManager.isTracking ? .green : .red)
                        statusRow(title: "今日记录", value: "\(footprintCount) 个足迹", color: .dfkAccent)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            statusRow(title: "当前位置", value: locationManager.currentAddress)
                            
                            // 参考足迹详情的添加样式
                            if locationManager.matchedPlace == nil && !isSuggestionIgnored {
                                HStack(spacing: 0) {
                                    Button {
                                        showingAddPlaceSheet = true
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "mappin.circle.fill")
                                                .font(.system(size: 16))
                                            Text("添加到重要地点")
                                                .font(.subheadline.bold())
                                            Spacer()
                                        }
                                        .foregroundColor(.orange)
                                        .padding(.leading, 12)
                                        .padding(.vertical, 10)
                                    }
                                    
                                    Rectangle()
                                        .fill(Color.orange.opacity(0.2))
                                        .frame(width: 1, height: 16)
                                        .padding(.horizontal, 4)
                                    
                                    Button {
                                        withAnimation {
                                            isSuggestionIgnored = true
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.secondary)
                                            .padding(12)
                                            .contentShape(Rectangle())
                                    }
                                }
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(10)
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    
                    if !locationManager.isTracking {
                        VStack(spacing: 8) {
                            Text("⚠️ 定位追踪未开启")
                                .font(.headline)
                                .foregroundColor(.orange)
                            Text("开启定位追踪后，地方客将自动记录您在重要地点的停留。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            
                            Button {
                                UserDefaults.standard.set(true, forKey: "isTrackingEnabled")
                                locationManager.startTracking()
                            } label: {
                                Text("立即开启")
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.dfkAccent)
                                    .cornerRadius(12)
                            }
                            .padding(.top, 8)
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.05)))
                    }
                    
                    Text("足迹将根据您在重要地点及其周边的停留情况自动记录。如果发现位置偏差或记录不准，请确保已授予“始终允许”定位权限。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)
                    
                    // --- 数据自检控制台 ---
                    VStack(alignment: .leading, spacing: 12) {
                        Text("📡 全天流水监视器").font(.caption.bold()).foregroundColor(.secondary)
                        
                        VStack(spacing: 0) {
                            debugRow(title: "今日数据总计", value: "\(locationManager.todayTotalPointsCount) points", color: .dfkAccent)
                            Divider()
                            debugRow(title: "本次运行流水", value: "\(locationManager.allTodayPoints.count) points", color: .green)
                            Divider()
                            debugRow(title: "实时分析缓存", value: "\(locationManager.trackingPoints.count) points", color: .secondary)
                            Divider()
                            debugRow(title: "今日生成足迹", value: "\(dailyFootprints.count) records", color: .dfkAccent)
                            
                            if !locationManager.allTodayPoints.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("流水最新 5 个坐标 (GCJ-02):").font(.system(size: 10)).foregroundColor(.secondary)
                                    ForEach(Array(locationManager.allTodayPoints.suffix(5).enumerated()), id: \.offset) { _, loc in
                                        Text("\(String(format: "%.6f", loc.coordinate.latitude)), \(String(format: "%.6f", loc.coordinate.longitude))")
                                            .font(.system(.caption2, design: .monospaced))
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(10)
                        
                        if !dailyFootprints.isEmpty {
                            Text("已存足迹详情:").font(.caption.bold()).foregroundColor(.secondary).padding(.top, 4)
                            ForEach(dailyFootprints) { fp in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(fp.title).font(.caption.bold())
                                        Text("\(fp.startTime.formatted(.dateTime.hour().minute())) - \(fp.endTime.formatted(.dateTime.hour().minute()))").font(.system(size: 10))
                                    }
                                    Spacer()
                                    Text("\(fp.footprintLocations.count) 点").font(.system(size: 10)).foregroundColor(.secondary)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.05)))
                    .padding(.top, 20)
                }
                .padding(20)
            }
            .navigationTitle("追踪状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
            .onAppear {
                if let loc = locationManager.lastLocation {
                    cameraPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
                }
            }
            .sheet(isPresented: $showFullscreenMap) {
                FullFrameTrackingMapView(
                    locationManager: locationManager, 
                    points: locationManager.allTodayPoints.map { $0.coordinate }
                )
            }
            .sheet(isPresented: $showingAddPlaceSheet) {
                AddPlaceSheet(initialCoordinate: locationManager.lastLocation?.coordinate, 
                              initialName: locationManager.currentAddress) { newPlace in
                    modelContext.insert(newPlace)
                    try? modelContext.save()
                }
            }
        }
    }
    
    private func debugRow(title: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption.bold()).foregroundColor(color)
        }
        .padding(10)
    }
    
    private func statusRow(title: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundColor(color)
        }
    }
}

struct FullFrameTrackingMapView: View {
    let locationManager: LocationManager
    let points: [CLLocationCoordinate2D]
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition) {
                UserAnnotation()
                if !points.isEmpty {
                    MapPolyline(coordinates: points)
                        .stroke(Color.dfkAccent, lineWidth: 4)
                    
                    if let first = points.first {
                        Marker("", coordinate: first).tint(Color.dfkAccent)
                    }
                    if let last = points.last {
                        Marker("", coordinate: last).tint(Color.dfkAccent)
                    }
                }
                ForEach(locationManager.allPlaces) { place in
                    MapCircle(center: place.coordinate, radius: Double(place.radius))
                        .foregroundStyle(Color.orange.opacity(0.1))
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                }
            }
            .onAppear {
                if let loc = locationManager.lastLocation {
                    cameraPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("追踪地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}
