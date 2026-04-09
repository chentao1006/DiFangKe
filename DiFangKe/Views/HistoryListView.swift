import SwiftUI
import SwiftData
import MapKit
import Photos

struct DaySummary: Identifiable, Equatable {
    struct TimelineIcon: Identifiable, Equatable {
        let id = UUID()
        let icon: String
        let colorHex: String
        let isTransport: Bool
        let isHighlight: Bool
    }
    
    var id: Date { date }
    let date: Date
    let totalDuration: TimeInterval
    let footprintCount: Int
    let highlightCount: Int
    let highlightTitle: String?
    let hasConfirmed: Bool
    let hasCandidate: Bool
    let activeHours: Set<Int>
    let favoriteHours: Set<Int>
    let timelineIcons: [TimelineIcon]
    let trajectoryCount: Int
    let mileage: Double
    var photoCount: Int
    
    var activityLevel: Float {
        let maxHours: TimeInterval = 8 * 3600
        return Float(min(totalDuration / maxHours, 1.0))
    }
}

// MARK: - Daily Timeline Modal
struct SimpleDayTimelineView: View {
    let date: Date
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    @Query private var allManualSelections: [TransportManualSelection]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            TimelinePageView(
                date: date,
                footprints: allFootprints.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) },
                manualSelections: allManualSelections.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) },
                allPlaces: allPlaces,
                offset: Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0,
                locationManager: locationManager,
                pastLimitOffset: -3650,
                isFromHistory: true
            )
            .navigationTitle(date.formatted(.dateTime.year().month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
    }
}

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Footprint.date, order: .reverse) private var allFootprints: [Footprint]
    @Query private var allManualSelections: [TransportManualSelection]
    @Query(sort: \ActivityType.sortOrder) private var allActivityTypes: [ActivityType]
    
    let initialDate: Date
    let showImportOnAppear: Bool
    @State private var viewMode: ViewMode = .week
    @State private var cachedSummaries: [Date: DaySummary] = [:]
    @State private var showingDate: IdentifiableDate? = nil
    @State private var showingPhotoImportRange = false
    @State private var selectedRange: (Date, Date)? = nil
    @State private var isScanning = false
    @State private var isImporting = false
    @State private var scannedResults: [Footprint] = []
    @State private var isShowingResults = false
    @State private var showingNoResultsAlert = false
    @State private var showingImportSuccessAlert = false
    @State private var successCount = 0
    @State private var showingPermissionAlert = false
    @State private var scanProgress = 0
    @State private var scanTotal = 0
    @ObservedObject private var photoService = PhotoService.shared
    
    @Query(sort: \Place.name) private var allPlacesForScan: [Place]
    
    struct IdentifiableDate: Identifiable {
        var id: Date { date }
        let date: Date
    }
    
    enum ViewMode: String, CaseIterable {
        case week = "周"
        case month = "月"
        case favorites = "收藏"
        case statistics = "统计"
    }

    @State private var hasScrolledWeek = false
    @State private var hasScrolledMonth = false
    
    init(initialDate: Date = Date(), showImportOnAppear: Bool = false) {
        self.initialDate = Calendar.current.startOfDay(for: initialDate)
        self.showImportOnAppear = showImportOnAppear
    }
    
    var body: some View {
        VStack(spacing: 0) {
            pickerSection
            contentArea
        }
        .navigationTitle("往昔足迹")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.dfkBackground)
        .onAppear { 
            updateSummaries() 
            if showImportOnAppear {
                checkPhotoPermission()
            }
        }
        .onChange(of: allFootprints) { updateSummaries() }
        .onChange(of: allManualSelections) { updateSummaries() }
        .sheet(item: $showingDate) { item in
            SimpleDayTimelineView(date: item.date)
                .environment(locationManager)
                .onDisappear { updateSummaries() }
        }
        .modifier(ImportSheetsModifier(
            showingPhotoImportRange: $showingPhotoImportRange,
            isShowingResults: $isShowingResults,
            scannedResults: $scannedResults,
            onStartScan: startScanning,
            onConfirmImport: { selectedFootprints in
                isImporting = true
                isShowingResults = false
                
                // 为了避免主线程卡顿，我们将保存和后续处理移入异步任务
                // 虽然 Footprint 已在 MainActor 创建，但 yield 允许 UI 保持响应
                Task {
                    for fp in selectedFootprints {
                        modelContext.insert(fp)
                    }
                    
                    // 尝试在后台进行保存（SwiftData 支持在异步上下文中调用 save）
                    try? modelContext.save()
                    
                    // 获取 ID 列表用于后续 AI 分析（在 save 后获取 ID 更稳定）
                    let identifiers = selectedFootprints.map { $0.persistentModelID }
                    
                    await MainActor.run {
                        OpenAIService.shared.enqueueFootprintsForAnalysis(identifiers)
                        scannedResults = []
                        updateSummaries()
                        self.successCount = selectedFootprints.count
                        self.isImporting = false
                        self.showingImportSuccessAlert = true
                    }
                }
            }
        ))
        .modifier(ImportOverlaysModifier(
            isScanning: isScanning,
            isImporting: isImporting,
            scanProgress: scanProgress,
            scanTotal: scanTotal,
            showingNoResultsAlert: $showingNoResultsAlert,
            showingImportSuccessAlert: $showingImportSuccessAlert,
            showingPermissionAlert: $showingPermissionAlert,
            successCount: successCount,
            onCancelScan: { stopScanning() }
        ))
        .modifier(ImportToolbarModifier(onTapAction: checkPhotoPermission))
    }
    
    @Namespace private var modeNamespace
    
    private var pickerSection: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(viewMode == mode ? .white : .secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        ZStack {
                            if viewMode == mode {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.dfkAccent)
                                    .matchedGeometryEffect(id: "mode_bg", in: modeNamespace)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewMode = mode
                        }
                    }
            }
        }
        .padding(4)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 15)
        .background(Color.dfkBackground)
    }
    
    private var contentArea: some View {
        TabView(selection: $viewMode) {
            HistoryWeekView(summaries: cachedSummaries, targetDate: initialDate, earliestDate: earliestFootprintDate, hasScrolled: $hasScrolledWeek, requestSummary: ensureSummary) { date in
                showingDate = IdentifiableDate(date: date)
            }
            .tag(ViewMode.week)
            
            HistoryMonthView(summaries: cachedSummaries, targetDate: initialDate, earliestDate: earliestFootprintDate, hasScrolled: $hasScrolledMonth, requestSummary: ensureSummary) { date in
                showingDate = IdentifiableDate(date: date)
            }
            .tag(ViewMode.month)
            
            HistoryFavoritesView(onUpdate: updateSummaries)
                .environment(locationManager)
                .tag(ViewMode.favorites)
            
            HistoryStatisticsView()
                .tag(ViewMode.statistics)
            
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
    
    private var earliestFootprintDate: Date {
        allFootprints.last?.startTime ?? Calendar.current.startOfDay(for: Date())
    }
    
    private func updateSummaries() {
        // Pre-warm just Today
        ensureSummary(for: Calendar.current.startOfDay(for: Date()))
    }
    
    private func ensureSummary(for date: Date) {
        if cachedSummaries[date] != nil && !Calendar.current.isDateInToday(date) {
            return
        }
        
        // Use a task to fetch single day summary
        let validFootprints = allFootprints.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }
        let manualSelectionsForDate = allManualSelections.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) && !$0.isDeleted }
        let activityTypes = allActivityTypes
        
        Task {
            // 第一阶段：异步计算核心轨迹和足迹数据（这也是最耗时的，因为涉及 CSV 读取）
            let coreSummary = await Task.detached(priority: .userInitiated) {
                let highlightCount = validFootprints.filter { $0.isHighlight == true }.count
                let highlights = validFootprints.filter { $0.isHighlight == true }
                let highlightTitle = highlights.first?.title
                let hasConfirmed = validFootprints.contains { $0.status == .confirmed }
                let hasCandidate = validFootprints.contains { $0.status == .candidate }
                let totalDuration = validFootprints.reduce(0) { $0 + $1.duration }
                
                let totalTrajectoryCount = RawLocationStore.shared.getTotalPointsCount(for: date)
                let fpsLite = validFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
                let manualLite = manualSelectionsForDate.map { TimelineBuilder.convertToOverrideLite($0) }
                let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: date)
                
                let timelineItems = TimelineBuilder.buildTimeline(
                    for: date,
                    footprints: fpsLite,
                    allRawPoints: rawPoints,
                    allPlaces: [],
                    overrides: manualLite
                )
                
                let timelineIcons = timelineItems.reversed().map { item in
                    DaySummary.TimelineIcon(
                        icon: item.getIcon(allActivityTypes: activityTypes),
                        colorHex: item.getColor(allActivityTypes: activityTypes),
                        isTransport: item.isTransport,
                        isHighlight: item.isHighlight
                    )
                }
                
                let totalMileage = timelineItems.reduce(0.0) { sum, item in
                    if case .transport(let t) = item { return sum + t.distance }
                    return sum
                }
                
                // 暂时不数照片，先让核心数据出来
                return DaySummary(
                    date: date,
                    totalDuration: totalDuration,
                    footprintCount: validFootprints.count,
                    highlightCount: highlightCount,
                    highlightTitle: highlightTitle,
                    hasConfirmed: hasConfirmed,
                    hasCandidate: hasCandidate,
                    activeHours: [],
                    favoriteHours: [],
                    timelineIcons: timelineIcons,
                    trajectoryCount: totalTrajectoryCount,
                    mileage: totalMileage,
                    photoCount: 0
                )
            }.value
            
            await MainActor.run {
                self.cachedSummaries[date] = coreSummary
            }
            
            // 第二阶段：异步“数照片”，数完后局部更新
            let finalPhotoCount = await Task.detached(priority: .background) {
                return PhotoService.shared.fetchCount(
                    startTime: Calendar.current.startOfDay(for: date),
                    endTime: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date)!
                )
            }.value
            
            await MainActor.run {
                if var existing = self.cachedSummaries[date] {
                    existing.photoCount = finalPhotoCount
                    self.cachedSummaries[date] = existing
                }
            }
        }
    }
    
    private func checkPhotoPermission() {
        let status = photoService.authorizationStatus
        if status == .notDetermined {
            photoService.requestPermission { granted in
                if granted { showingPhotoImportRange = true }
            }
        } else if status == .authorized || status == .limited {
            showingPhotoImportRange = true
        } else {
            showingPermissionAlert = true
        }
    }
    
    private func startScanning(start: Date, end: Date) {
        self.scanProgress = 0
        self.scanTotal = 0
        photoService.isScanCancelled = false
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let finalEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            let existingIDs = Set(self.allFootprints.flatMap { $0.photoAssetIDs })
            let existingBriefs = self.allFootprints.map { ($0.startTime, $0.endTime, $0.latitude, $0.longitude) }
            PhotoService.shared.autoScanFootprints(from: start, to: finalEnd, allPlaces: allPlacesForScan, excludedAssetIDs: existingIDs, existingFootprints: existingBriefs, onProgress: { current, total in
                self.scanProgress = current
                self.scanTotal = total
            }) { results in
                self.isScanning = false
                if !results.isEmpty {
                    self.scannedResults = results
                    self.isShowingResults = true
                } else {
                    self.showingNoResultsAlert = true
                }
            }
        }
    }
    
    private func stopScanning() {
        photoService.isScanCancelled = true
        isScanning = false
    }
}

// MARK: - Week View
struct HistoryWeekView: View {
    let summaries: [Date: DaySummary]
    let targetDate: Date
    let earliestDate: Date
    @Binding var hasScrolled: Bool
    let requestSummary: (Date) -> Void
    let onDayTap: (Date) -> Void
    
    @State private var weeksLimit: Int = 15 // 每页预加载多一些周
    
    var weeksCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startOfTodayWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        let startOfEarliestWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: earliestDate))!
        return calendar.dateComponents([.weekOfYear], from: startOfEarliestWeek, to: startOfTodayWeek).weekOfYear ?? 0
    }
    
    var weeks: [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startOfTodayWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        
        let count = min(weeksLimit, weeksCount)
        
        return (0...count).map { weekOffset in
            let startOfWeek = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: startOfTodayWeek)!
            return (0..<7).compactMap { dayOffset in
                calendar.date(byAdding: .day, value: 6 - dayOffset, to: startOfWeek)
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(weeks, id: \.self) { weekDates in
                        if let firstDate = weekDates.first {
                            let monday = Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstDate))!
                            Section(header: weekHeader(for: firstDate)) {
                                VStack(spacing: 8) {
                                    ForEach(weekDates, id: \.self) { date in
                                        DayCell(
                                            date: date,
                                            targetDate: targetDate,
                                            summary: summaries[date],
                                            onTap: { onDayTap(date) }
                                        )
                                        .onAppear { requestSummary(date) }
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .id("week-" + monday.dayID)
                        }
                    }
                    
                    if weeksLimit < weeksCount {
                        ProgressView()
                            .padding()
                            .onAppear {
                                // 滚动到底部时自动加载更多
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    weeksLimit += 15
                                }
                            }
                    }
                }
                .padding(.top)
            }
            .onAppear {
                adjustLimitForTarget()
            }
            .task(id: targetDate) {
                if !hasScrolled {
                    adjustLimitForTarget()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    scrollToTarget(proxy: proxy)
                }
            }
        }
    }
    
    private func adjustLimitForTarget() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weeksToTarget = calendar.dateComponents([.weekOfYear], from: targetDate, to: today).weekOfYear ?? 0
        if weeksToTarget >= weeksLimit {
            weeksLimit = weeksToTarget + 5
        }
    }
    
    private func scrollToTarget(proxy: ScrollViewProxy) {
        hasScrolled = true
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: targetDate)
        if let startOfWeek = calendar.date(from: components) {
            withAnimation {
                proxy.scrollTo("week-" + startOfWeek.dayID, anchor: .top)
            }
        }
    }
    
    private func weekHeader(for date: Date) -> some View {
        let calendar = Calendar.current
        let monday = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
        let year = calendar.component(.year, from: monday)
        let week = calendar.component(.weekOfYear, from: monday)
        
        return HStack {
            Text("\(String(format: "%d", year))年 第\(week)周")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dfkBackground.opacity(0.95))
    }
}

struct DayCell: View {
    let date: Date
    let targetDate: Date
    let summary: DaySummary?
    let onTap: () -> Void
    
    var body: some View {
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        let isTarget = Calendar.current.isDate(date, inSameDayAs: targetDate)
        let hasData = summary != nil && ((summary?.footprintCount ?? 0) > 0 || !(summary?.timelineIcons.isEmpty ?? true))
        
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(date.formatted(.dateTime.weekday()))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Text(date.formatted(.dateTime.month().day()))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(hasData ? .primary : .secondary.opacity(0.5))
            }
            .frame(width: 75, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 6) {
                if let summary = summary, hasData {
                    DayStatsView(
                        trajectoryCount: summary.trajectoryCount,
                        footprintCount: summary.footprintCount,
                        mileage: summary.mileage,
                        photoCount: summary.photoCount
                    )
                    TimelineIconsView(icons: summary.timelineIcons)
                } else if summary == nil {
                    ProgressView().scaleEffect(0.5).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("暂无记录").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.3)).padding(.top, 14)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            ZStack {
                if isToday { RoundedRectangle(cornerRadius: 16).fill(Color.dfkAccent.opacity(0.06)) }
                else if isTarget { RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.12)) }
                else { RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5)) }
            }
        )
        .onTapGesture { if hasData { onTap() } }
    }
}

struct TimelineIconsView: View {
    let icons: [DaySummary.TimelineIcon]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(icons.prefix(10)) { item in
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: item.colorHex) ?? .secondary)
            }
            if icons.count > 10 { Image(systemName: "ellipsis").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5)) }
        }
    }
}

struct DayStatsView: View {
    let trajectoryCount: Int
    let footprintCount: Int
    let mileage: Double
    let photoCount: Int
    
    var body: some View {
        HStack(spacing: 8) {
            if trajectoryCount > 0 { statItem(icon: "dot.radiowaves.left.and.right", value: "\(trajectoryCount)") }
            if footprintCount > 0 { statItem(icon: "mappin.and.ellipse", value: "\(footprintCount)") }
            if mileage > 0 { statItem(icon: "figure.walk", value: formatMileage(mileage)) }
            if photoCount > 0 { statItem(icon: "photo.on.rectangle", value: "\(photoCount)") }
        }
    }
    
    private func statItem(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(value).font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundColor(.secondary)
    }
    
    private func formatMileage(_ m: Double) -> String {
        if m < 1000 { return "\(Int(m))m" }
        return String(format: "%.1fkm", m/1000)
    }
}

// MARK: - Month View
struct HistoryMonthView: View {
    let summaries: [Date: DaySummary]
    let targetDate: Date
    let earliestDate: Date
    @Binding var hasScrolled: Bool
    let requestSummary: (Date) -> Void
    let onDayTap: (Date) -> Void
    
    @State private var monthsLimit: Int = 12 // 每页预加载多一些月
    
    var monthsCount: Int {
        let calendar = Calendar.current
        let today = Date().startOfMonth ?? Date()
        let startOfEarliestMonth = earliestDate.startOfMonth ?? earliestDate
        return (calendar.dateComponents([.month], from: startOfEarliestMonth, to: today).month ?? 0)
    }
    
    var months: [Date] {
        let calendar = Calendar.current
        let today = Date().startOfMonth ?? Date()
        let count = min(monthsLimit, monthsCount)
        return (0...count).compactMap { calendar.date(byAdding: .month, value: -$0, to: today) }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 32, pinnedViews: [.sectionHeaders]) {
                    ForEach(months, id: \.self) { month in
                        Section(header: monthHeader(for: month)) {
                            monthGrid(for: month)
                        }
                        .id("month-" + month.dayID)
                    }
                    
                    if monthsLimit < monthsCount {
                        ProgressView()
                            .padding()
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    monthsLimit += 12
                                }
                            }
                    }
                }
                .padding(.bottom, 30)
            }
            .background(Color.dfkBackground)
            .onAppear {
                adjustLimitForTarget()
            }
            .task(id: targetDate) {
                if !hasScrolled {
                    adjustLimitForTarget()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    scrollToTarget(proxy: proxy)
                }
            }
        }
    }
    
    private func adjustLimitForTarget() {
        let calendar = Calendar.current
        let today = Date().startOfMonth ?? Date()
        let monthsToTarget = calendar.dateComponents([.month], from: targetDate.startOfMonth ?? targetDate, to: today).month ?? 0
        if monthsToTarget >= monthsLimit {
            monthsLimit = monthsToTarget + 3
        }
    }
    
    private func scrollToTarget(proxy: ScrollViewProxy) {
        hasScrolled = true
        if let startOfMonth = targetDate.startOfMonth {
            withAnimation {
                proxy.scrollTo("month-" + startOfMonth.dayID, anchor: .top)
            }
        }
    }
    
    private func monthHeader(for date: Date) -> some View {
        HStack {
            Text(date.formatted(.dateTime.year().month(.wide))).font(.system(size: 18, weight: .bold)).padding(.horizontal, 20).padding(.vertical, 10)
            Spacer()
        }
        .background(Color.dfkBackground.opacity(0.95))
    }
    
    private func monthGrid(for month: Date) -> some View {
        let days = daysInMonth(for: month)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary.opacity(0.6)).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 10) {
                let leadingSpaces = calculateLeadingSpaces(for: month)
                ForEach(0..<leadingSpaces, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(days, id: \.self) { date in
                    MonthDayCell(date: date, targetDate: targetDate, summary: summaries[date], onTap: { onDayTap(date) }, onAppearAction: { requestSummary(date) })
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func calculateLeadingSpaces(for month: Date) -> Int {
        guard let firstDay = month.startOfMonth else { return 0 }
        return Calendar.current.component(.weekday, from: firstDay) - 1
    }
    
    private func daysInMonth(for month: Date) -> [Date] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstDay = month.startOfMonth else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: firstDay) }
    }
}

struct MonthDayCell: View {
    let date: Date
    let targetDate: Date
    let summary: DaySummary?
    let onTap: () -> Void
    
    var body: some View {
        let allIcons = summary?.timelineIcons ?? []
        let hasData = summary != nil && !allIcons.isEmpty
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        let isTarget = Calendar.current.isDate(date, inSameDayAs: targetDate)
        
        VStack(spacing: 0) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(hasData ? .primary : .secondary.opacity(0.4))
                .padding(.top, 3)
            
            if !allIcons.isEmpty {
                FlowLayout(spacing: 1) {
                    ForEach(allIcons) { item in
                        let color = Color(hex: item.colorHex) ?? .dfkAccent
                        ZStack {
                            if item.isHighlight {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(color)
                            } else {
                                Image(systemName: item.icon)
                                    .font(.system(size: 8))
                                    .foregroundColor(color)
                            }
                        }
                        .frame(width: 11, height: 11)
                    }
                }
                .frame(maxWidth: 48)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
            ZStack {
                if isToday { RoundedRectangle(cornerRadius: 12).fill(Color.dfkAccent.opacity(0.06)) }
                else if isTarget { RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)) }
            }
        )
        .onAppear { onAppearAction?() }
        .onTapGesture { if hasData { onTap() } }
    }
    
    var onAppearAction: (() -> Void)? = nil
}

// MARK: - Extensions
extension Date {
    var dayID: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: self)
    }
    var startOfMonth: Date? {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: self))
    }
}

extension View {
    func pickerSegmented() -> some View { self.modifier(SegmentedPickerModifier()) }
}

struct SegmentedPickerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.pickerStyle(.segmented)
    }
}

// MARK: - Import Helpers
struct ImportSheetsModifier: ViewModifier {
    @Environment(LocationManager.self) private var locationManager
    @Binding var showingPhotoImportRange: Bool
    @Binding var isShowingResults: Bool
    @Binding var scannedResults: [Footprint]
    let onStartScan: (Date, Date) -> Void
    let onConfirmImport: ([Footprint]) -> Void
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingPhotoImportRange) { 
                PhotoImportRangePicker { s, e in showingPhotoImportRange = false; onStartScan(s, e) }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $isShowingResults) { 
                PhotoImportResultsView(results: scannedResults, onConfirm: onConfirmImport)
                    .environment(locationManager)
            }
    }
}

struct ImportOverlaysModifier: ViewModifier {
    let isScanning: Bool; let isImporting: Bool
    let scanProgress: Int; let scanTotal: Int
    @Binding var showingNoResultsAlert: Bool; @Binding var showingImportSuccessAlert: Bool; @Binding var showingPermissionAlert: Bool
    let successCount: Int
    let onCancelScan: () -> Void
    func body(content: Content) -> some View {
        content
            .alert("未发现足迹", isPresented: $showingNoResultsAlert) { Button("好", role: .cancel) { } } message: { Text("未发现包含位置信息的照片或者都已导入过。") }
            .alert("同步成功", isPresented: $showingImportSuccessAlert) { Button("太棒了", role: .cancel) { } } message: { Text("成功寻回 \(successCount) 个足迹！") }
            .overlay { if isScanning {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView(value: Double(scanProgress), total: max(1, Double(scanTotal))).tint(.white).frame(width: 200)
                        VStack(spacing: 8) {
                            Text("正在穿越时空...").foregroundColor(.white).font(.headline)
                            Text("\(scanProgress) / \(scanTotal)").foregroundColor(.white.opacity(0.7)).font(.caption.monospacedDigit())
                        }
                        
                        Button(role: .cancel) {
                            onCancelScan()
                        } label: {
                            Text("取消同步")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                        }
                    }.padding(40).background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.8)))
                }
            }}
            .overlay { if isImporting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().tint(.white).controlSize(.large)
                        Text("正在存入时光足迹...").foregroundColor(.white).font(.headline)
                    }
                    .padding(30)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.7)))
                }
            }}
    }
}

struct ImportToolbarModifier: ViewModifier {
    let onTapAction: () -> Void
    func body(content: Content) -> some View {
        content.toolbar { ToolbarItem(placement: .topBarTrailing) { Button { onTapAction() } label: { Image(systemName: "square.and.arrow.down.badge.clock") } } }
    }
}

// MARK: - Supporting Views
struct PhotoImportRangePicker: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    var onSelect: (Date, Date) -> Void
    var body: some View {
        NavigationStack {
            VStack {
                Picker("年份", selection: $selectedYear) {
                    ForEach((2010...Calendar.current.component(.year, from: Date())), id: \.self) { Text("\(String(format: "%d", $0))年").tag($0) }
                }.pickerStyle(.wheel)
                Button("开启穿越") {
                    let s = Calendar.current.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
                    let e = Calendar.current.date(from: DateComponents(year: selectedYear, month: 12, day: 31, hour: 23, minute: 59))!
                    onSelect(s, e)
                }.buttonStyle(.borderedProminent).padding()
            }.navigationTitle("寻回那年的记忆").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct PhotoImportResultsView: View {
    @Environment(LocationManager.self) private var locationManager
    let results: [Footprint]; let onConfirm: ([Footprint]) -> Void
    @Environment(\.dismiss) var dismiss; @Query private var allPlaces: [Place]; @State private var selectedIDs: Set<UUID> = []
    
    init(results: [Footprint], onConfirm: @escaping ([Footprint]) -> Void) { 
        self.results = results
        self.onConfirm = onConfirm
        self._selectedIDs = State(initialValue: Set(results.map { $0.footprintID })) 
    }
    
    private var isAllSelected: Bool {
        selectedIDs.count == results.count && !results.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Select All Header
                HStack(spacing: 0) {
                    Image(systemName: isAllSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(isAllSelected ? .dfkAccent : .secondary.opacity(0.3))
                        .frame(width: 40)
                    
                    Text(isAllSelected ? "取消全选" : "全选")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Text(" (\(results.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.vertical, 12)
                .background(Color.dfkBackground)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        if isAllSelected {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(results.map { $0.footprintID })
                        }
                    }
                }
                
                Divider().padding(.horizontal, 16).opacity(0.5)

                List(results, id: \.footprintID) { fp in
                    HStack(spacing: 0) {
                        Image(systemName: selectedIDs.contains(fp.footprintID) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(selectedIDs.contains(fp.footprintID) ? .dfkAccent : .secondary.opacity(0.3))
                            .frame(width: 40)
                        
                        FootprintCardView(footprint: fp, allPlaces: allPlaces, showTimeline: false, disableContextMenu: true) { _, _ in 
                            toggleSelection(fp.footprintID)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(fp.footprintID)
                    }
                }
                .listStyle(.plain)
            }
            .background(Color.dfkBackground)
            .navigationTitle("寻回的记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { 
                        onConfirm(results.filter { selectedIDs.contains($0.footprintID) }) 
                    }
                    .fontWeight(.bold)
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }
    
    private func toggleSelection(_ id: UUID) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        }
    }
}

struct HistoryFavoritesView: View {
    @Environment(LocationManager.self) private var locationManager
    @Query(filter: #Predicate<Footprint> { $0.isHighlight == true && $0.statusValue != "ignored" }, sort: \Footprint.startTime, order: .reverse) private var favoriteFootprints: [Footprint]
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var selectedFootprint: Footprint?
    let onUpdate: () -> Void
    
    private var groupedFootprints: [(Date, [Footprint])] {
        let grouped = Dictionary(grouping: favoriteFootprints) { fp in
            Calendar.current.startOfDay(for: fp.startTime)
        }
        return grouped.sorted { $0.key > $1.key }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedFootprints, id: \.0) { date, footprints in
                    Section(header: favoriteHeader(for: date)) {
                        VStack(spacing: 12) {
                            ForEach(footprints) { fp in
                                FootprintCardView(footprint: fp, allPlaces: allPlaces, showTimeline: false) { f, _ in selectedFootprint = f }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .background(Color.dfkBackground)
        .sheet(item: $selectedFootprint) { fp in 
            FootprintModalView(footprint: fp, autoFocus: false)
                .environment(locationManager)
                .onDisappear { onUpdate() } 
        }
    }
    
    private func favoriteHeader(for date: Date) -> some View {
        HStack {
            Text(date.formatted(.dateTime.year().month().day()))
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Spacer()
        }
        .background(Color.dfkBackground.opacity(0.95))
    }
}
