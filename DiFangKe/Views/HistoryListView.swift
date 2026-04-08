import SwiftUI
import SwiftData
import MapKit

struct DaySummary: Identifiable, Equatable {
    struct TimelineIcon: Identifiable, Equatable {
        let id = UUID()
        let icon: String
        let colorHex: String
        let isTransport: Bool
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
    let trajectoryCount: Int // New field
    let mileage: Double // New field
    
    var activityLevel: Float {
        let maxHours: TimeInterval = 8 * 3600
        return Float(min(totalDuration / maxHours, 1.0))
    }
    
    var marker: String? {
        if highlightCount > 0 { return "★" }
        if hasConfirmed { return "●" }
        if hasCandidate { return "○" }
        return nil
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
                pastLimitOffset: -3650
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
    }

    @State private var hasScrolledWeek = false
    @State private var hasScrolledMonth = false
    
    init(initialDate: Date = Date(), showImportOnAppear: Bool = false) {
        self.initialDate = Calendar.current.startOfDay(for: initialDate)
        self.showImportOnAppear = showImportOnAppear
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 视图切换
            pickerSection
            
            // 内容区域
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
                for fp in selectedFootprints {
                    modelContext.insert(fp)
                }
                try? modelContext.save()
                OpenAIService.shared.enqueueFootprintsForAnalysis(selectedFootprints)
                isShowingResults = false
                scannedResults = []
                updateSummaries()
                self.successCount = selectedFootprints.count
                self.showingImportSuccessAlert = true
            }
        ))
        .modifier(ImportOverlaysModifier(
            isScanning: isScanning,
            scanProgress: scanProgress,
            scanTotal: scanTotal,
            showingNoResultsAlert: $showingNoResultsAlert,
            showingImportSuccessAlert: $showingImportSuccessAlert,
            showingPermissionAlert: $showingPermissionAlert,
            successCount: successCount
        ))
        .modifier(ImportToolbarModifier(onTapAction: checkPhotoPermission))
    }
    
    private var pickerSection: some View {
        HStack {
            Picker("视图", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.dfkBackground)
    }
    
    private var contentArea: some View {
        TabView(selection: $viewMode) {
            HistoryWeekView(summaries: cachedSummaries, targetDate: initialDate, hasScrolled: $hasScrolledWeek) { date in
                showingDate = IdentifiableDate(date: date)
            }
            .tag(ViewMode.week)
            
            HistoryMonthView(summaries: cachedSummaries, targetDate: initialDate, hasScrolled: $hasScrolledMonth) { date in
                showingDate = IdentifiableDate(date: date)
            }
            .tag(ViewMode.month)
            
            HistoryFavoritesView(onUpdate: updateSummaries)
                .environment(locationManager)
                .tag(ViewMode.favorites)
            
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
    
    
    private func checkPhotoPermission() {
        let status = photoService.authorizationStatus
        if status == .notDetermined {
            photoService.requestPermission { granted in
                if granted {
                    showingPhotoImportRange = true
                }
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
        isScanning = true
        // 适当延迟以确保 UI 切换完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 设置 end 为当天的 23:59:59
            let finalEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            // 收集所有已存在的照片 ID 用于过滤
            let existingIDs = Set(self.allFootprints.flatMap { $0.photoAssetIDs })
            
            PhotoService.shared.autoScanFootprints(from: start, to: finalEnd, allPlaces: allPlacesForScan, excludedAssetIDs: existingIDs, onProgress: { current, total in
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
    
    private func updateSummaries() {
        let validFootprints = allFootprints.filter { $0.status != .ignored }
        let manualSelections = allManualSelections.filter { !$0.isDeleted }
        let rawDates = locationManager.availableRawDates
        
        let allDates = Set(validFootprints.map { Calendar.current.startOfDay(for: $0.startTime) } + 
                           manualSelections.map { Calendar.current.startOfDay(for: $0.startTime) } + 
                           rawDates.map { Calendar.current.startOfDay(for: $0) })
        
        let activityTypes = allActivityTypes
        Task {
            let newDict = await Task.detached(priority: .userInitiated) {
                var results: [Date: DaySummary] = [:]
                
                for date in allDates.sorted(by: { $0 > $1 }) {
                    let dayFootprints = validFootprints.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }
                    let dayManual = manualSelections.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }
                    
                    let highlightCount = dayFootprints.filter { $0.isHighlight == true }.count
                    let highlights = dayFootprints.filter { $0.isHighlight == true }
                    let highlightTitle = highlights.first?.title
                    let hasConfirmed = dayFootprints.contains { $0.status == .confirmed }
                    let hasCandidate = dayFootprints.contains { $0.status == .candidate }
                    let totalDuration = dayFootprints.reduce(0) { $0 + $1.duration }
                    
                    let totalTrajectoryCount = RawLocationStore.shared.getTotalPointsCount(for: date)
                    let fpsLite = dayFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
                    let manualLite = dayManual.map { TimelineBuilder.convertToOverrideLite($0) }
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
                            isTransport: item.isTransport
                        )
                    }
                    
                    let totalMileage = timelineItems.reduce(0.0) { sum, item in
                        if case .transport(let t) = item { return sum + t.distance }
                        return sum
                    }
                    
                    results[date] = DaySummary(
                        date: date,
                        totalDuration: totalDuration,
                        footprintCount: dayFootprints.count,
                        highlightCount: highlightCount,
                        highlightTitle: highlightTitle,
                        hasConfirmed: hasConfirmed,
                        hasCandidate: hasCandidate,
                        activeHours: [],
                        favoriteHours: [],
                        timelineIcons: timelineIcons,
                        trajectoryCount: totalTrajectoryCount,
                        mileage: totalMileage
                    )
                }
                return results
            }.value
            
            await MainActor.run {
                self.cachedSummaries = newDict
            }
        }
    }
    
    private func emptySummary(for date: Date) -> DaySummary {
        DaySummary(date: date, totalDuration: 0, footprintCount: 0, highlightCount: 0, highlightTitle: nil, hasConfirmed: false, hasCandidate: false, activeHours: [], favoriteHours: [], timelineIcons: [], trajectoryCount: 0, mileage: 0)
    }
}

// MARK: - Week View
struct HistoryWeekView: View {
    let summaries: [Date: DaySummary]
    let targetDate: Date
    @Binding var hasScrolled: Bool
    let onDayTap: (Date) -> Void
    
    var weeks: [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let startOfTodayWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        
        // Find earliest footprint date (or default to 8 weeks ago if none)
        let allDates = summaries.keys
        let earliestDate = allDates.min() ?? calendar.date(byAdding: .weekOfYear, value: -8, to: today)!
        let startOfEarliestWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: earliestDate))!
        
        // Also consider the targetDate to ensure it's included in the range
        let minStartWeek = targetDate < startOfEarliestWeek ? calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: targetDate))! : startOfEarliestWeek
        
        let weekCount = calendar.dateComponents([.weekOfYear], from: minStartWeek, to: startOfTodayWeek).weekOfYear ?? 0
        
        return (0...max(weekCount, 4)).map { weekOffset in
            let startOfWeek = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: startOfTodayWeek)!
            // Reverse days within the week (Sun to Mon)
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
                            // Find the Monday of this week for a stable ID
                            let monday = Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstDate))!
                            Section(header: weekHeader(for: firstDate)) {
                                VStack(spacing: 8) {
                                    ForEach(weekDates, id: \.self) { date in
                                        DayCell(
                                            date: date,
                                            targetDate: targetDate, // Pass target date
                                            summary: summaries[date],
                                            onTap: { onDayTap(date) }
                                        )
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .id("week-" + monday.dayID)
                        }
                    }
                }
                .padding(.top)
            }
            .task(id: targetDate) {
                // Only scroll if we haven't scrolled for this view instance yet
                if !hasScrolled {
                    // Attempt multiple scrolls as layout and data might change
                    for delay in [200_000_000, 600_000_000, 1_200_000_000] {
                        if !hasScrolled {
                            try? await Task.sleep(nanoseconds: UInt64(delay))
                            scrollToTarget(proxy: proxy)
                        }
                    }
                }
            }
            .onChange(of: summaries) { _, newValue in
                if !newValue.isEmpty && !hasScrolled {
                    scrollToTarget(proxy: proxy)
                }
            }
        }
    }
    
    private func scrollToTarget(proxy: ScrollViewProxy) {
        if !summaries.isEmpty {
            hasScrolled = true
        }
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: targetDate)
        if let startOfWeek = calendar.date(from: components) {
            withAnimation {
                proxy.scrollTo("week-" + startOfWeek.dayID, anchor: UnitPoint(x: 0.5, y: 0.3))
            }
        }
    }
    
    private func weekHeader(for date: Date) -> some View {
        let calendar = Calendar.current
        // Find the Monday of this week for header display
        let monday = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
        let year = calendar.component(.year, from: monday)
        let week = calendar.component(.weekOfYear, from: monday)
        
        return HStack {
            Text("\(String(format: "%d", year))年 第\(week)周")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.dfkBackground.opacity(0.95))
            Spacer()
        }
    }
}

// MARK: - Day Cell (for Week View)
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
            // 左侧：星期和日期上下排列，确保文字不换行
            VStack(alignment: .leading, spacing: 4) {
                Text(date.formatted(.dateTime.weekday()))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Text(date.formatted(.dateTime.month().day()))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(hasData ? .primary : .secondary.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 60, alignment: .leading) // 设置足够宽的固定宽度，确保对齐
            .opacity(hasData ? 1.0 : 0.4)
            
            // 右侧：统计数据和图标上下排列
            VStack(alignment: .leading, spacing: 6) {
                if let summary = summary, hasData {
                    DayStatsView(
                        trajectoryCount: summary.trajectoryCount,
                        footprintCount: summary.footprintCount,
                        mileage: summary.mileage
                    )
                    
                    TimelineIconsView(icons: summary.timelineIcons)
                } else {
                    Text("暂无记录")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.3))
                        .padding(.top, 14)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            ZStack {
                if isToday {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.dfkAccent.opacity(0.06))
                } else if isTarget {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.12))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5))
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasData {
                onTap()
            }
        }
        .allowsHitTesting(hasData)
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
            if icons.count > 10 {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }
}

struct DayStatsView: View {
    let trajectoryCount: Int
    let footprintCount: Int
    let mileage: Double
    
    var body: some View {
        HStack(spacing: 8) {
            if trajectoryCount > 0 {
                statItem(icon: "dot.radiowaves.left.and.right", value: "\(trajectoryCount)")
            }
            if footprintCount > 0 {
                statItem(icon: "mappin.and.ellipse", value: "\(footprintCount)")
            }
            if mileage > 0 {
                statItem(icon: "figure.walk", value: formatMileage(mileage))
            }
        }
    }
    
    private func statItem(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
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
    @Binding var hasScrolled: Bool
    let onDayTap: (Date) -> Void
    
    var months: [Date] {
        let calendar = Calendar.current
        let today = Date().startOfMonth ?? Date()
        
        let allDates = summaries.keys
        let earliestDate = allDates.min() ?? calendar.date(byAdding: .month, value: -6, to: today)!
        let startOfEarliestMonth = earliestDate.startOfMonth ?? earliestDate
        
        // Ensure targetDate's month is included too
        let minStartMonth = targetDate < startOfEarliestMonth ? targetDate.startOfMonth ?? startOfEarliestMonth : startOfEarliestMonth
        
        // Calculate number of months between startOfEarliestMonth and today
        let monthCount = calendar.dateComponents([.month], from: minStartMonth, to: today).month ?? 0
        
        return (0...max(monthCount, 5)).compactMap { calendar.date(byAdding: .month, value: -$0, to: today) }
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
                }
                .padding(.bottom, 30)
            }
            .background(Color.dfkBackground)
            .task(id: targetDate) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !hasScrolled {
                    scrollToTarget(proxy: proxy)
                }
            }
            .onChange(of: summaries) { _, newValue in
                if !newValue.isEmpty && !hasScrolled {
                    scrollToTarget(proxy: proxy)
                }
            }
        }
    }
    
    private func scrollToTarget(proxy: ScrollViewProxy) {
        if !summaries.isEmpty {
            hasScrolled = true
        }
        if let startOfMonth = targetDate.startOfMonth {
            withAnimation {
                proxy.scrollTo("month-" + startOfMonth.dayID, anchor: UnitPoint(x: 0.5, y: 0.2))
            }
        }
    }
    
    private func monthHeader(for date: Date) -> some View {
        HStack {
            Text(date.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Spacer()
        }
        .background(Color.dfkBackground.opacity(0.95))
    }
    
    private func monthGrid(for month: Date) -> some View {
        let days = daysInMonth(for: month)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        
        return VStack(spacing: 8) {
            // Weekday Headers
            HStack(spacing: 0) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            
            LazyVGrid(columns: columns, spacing: 10) {
                let leadingSpaces = calculateLeadingSpaces(for: month)
                
                ForEach(0..<leadingSpaces, id: \.self) { i in
                    Color.clear.frame(height: 40)
                }
                
                ForEach(days, id: \.self) { date in
                    MonthDayCell(
                        date: date,
                        targetDate: targetDate,
                        summary: summaries[date],
                        onTap: { onDayTap(date) }
                    )
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func calculateLeadingSpaces(for month: Date) -> Int {
        let calendar = Calendar.current
        guard let firstDay = month.startOfMonth else { return 0 }
        let weekday = calendar.component(.weekday, from: firstDay)
        // Sunday = 1, Monday = 2 ... Saturday = 7
        // We want Sunday = 0, Monday = 1 ... Saturday = 6
        return weekday - 1
    }
    
    private func daysInMonth(for month: Date) -> [Date] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstDay = month.startOfMonth else { return [] }
        
        return range.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
    }
}

struct MonthDayCell: View {
    let date: Date
    let targetDate: Date
    let summary: DaySummary?
    let onTap: () -> Void
    
    var body: some View {
        let hasData = summary != nil && (summary?.footprintCount ?? 0) > 0
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        let isTarget = Calendar.current.isDate(date, inSameDayAs: targetDate)
        
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(hasData ? .primary : .secondary.opacity(0.4))
            
            ZStack {
                if let summary = summary, summary.footprintCount > 0 {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(Color.dfkAccent.opacity(summary.activityLevel > 0.5 ? 1.0 : 0.4))
                            .frame(width: 5, height: 5)
                        
                        if summary.highlightCount > 0 {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.dfkHighlight)
                        }
                    }
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            ZStack {
                if isToday {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.dfkAccent.opacity(0.06))
                } else if isTarget {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.12))
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasData {
                onTap()
            }
        }
        .allowsHitTesting(hasData)
    }
}

// MARK: - Extensions
extension Date {
    var dayID: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: self)
    }
    
    var startOfWeek: Date {
        Calendar.current.dateComponents([.calendar, .yearForWeekOfYear, .weekOfYear], from: self).date!
    }
    
    var startOfMonth: Date? {
        let components = Calendar.current.dateComponents([.year, .month], from: self)
        return Calendar.current.date(from: components)
    }
}

// MARK: - View Modifiers to simplify HistoryListView body
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
                PhotoImportRangePicker { start, end in
                    showingPhotoImportRange = false
                    onStartScan(start, end)
                }
            }
            .sheet(isPresented: $isShowingResults) {
                PhotoImportResultsView(results: scannedResults, onConfirm: onConfirmImport)
                    .environment(locationManager)
            }
    }
}

struct ImportOverlaysModifier: ViewModifier {
    let isScanning: Bool
    let scanProgress: Int
    let scanTotal: Int
    @Binding var showingNoResultsAlert: Bool
    @Binding var showingImportSuccessAlert: Bool
    @Binding var showingPermissionAlert: Bool
    let successCount: Int
    
    func body(content: Content) -> some View {
        content
            .alert("未发现足迹", isPresented: $showingNoResultsAlert) {
                Button("好", role: .cancel) { }
            } message: {
                Text("在选定的时间范围内没有找到包含位置信息的照片。")
            }
            .alert("同步成功", isPresented: $showingImportSuccessAlert) {
                Button("太棒了", role: .cancel) { }
            } message: {
                Text("成功寻回并入库了 \(successCount) 个历史足迹！")
            }
            .alert("照片权限未开启", isPresented: $showingPermissionAlert) {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("好", role: .cancel) { }
            } message: {
                Text("“地方客”需要访问您的相册以发现那时的足迹。请在系统设置中开启照片读取权限。")
            }
            .overlay {
                if isScanning {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        VStack(spacing: 20) {
                            if scanTotal > 0 {
                                VStack(spacing: 12) {
                                    ProgressView(value: Double(scanProgress), total: Double(scanTotal))
                                        .progressViewStyle(.linear)
                                        .tint(.white)
                                        .frame(width: 200)
                                    
                                    Text("\(scanProgress)/\(scanTotal)")
                                        .foregroundColor(.white)
                                        .font(.system(.subheadline, design: .monospaced))
                                }
                            } else {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .tint(.white)
                            }
                            
                            Text("正在穿越时空...")
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                        .padding(40)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.7)))
                    }
                }
            }
    }
}

struct ImportToolbarModifier: ViewModifier {
    let onTapAction: () -> Void
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onTapAction()
                    } label: {
                        Image(systemName: "square.and.arrow.down.badge.clock")
                    }
                }
            }
    }
}

// MARK: - Date Range Picker View
struct PhotoImportRangePicker: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var earliestYear: Int = 2010
    
    var onSelect: (Date, Date) -> Void
    
    private var years: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((earliestYear...currentYear).reversed())
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选择年份")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                            
                            Picker("年份", selection: $selectedYear) {
                                ForEach(years, id: \.self) { year in
                                    Text("\(String(format: "%04d", year))年").tag(year)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 150)
                            .clipped()
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            
                            Text("我们将纵览您在 \(String(format: "%d", selectedYear)) 年全年的影像，为您找回失落的足迹。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                        }
                        .padding(.top, 20)
                        
                        Button(action: {
                            let calendar = Calendar.current
                            var components = DateComponents()
                            components.year = selectedYear
                            components.month = 1
                            components.day = 1
                            let start = calendar.date(from: components) ?? Date()
                            
                            components.month = 12
                            components.day = 31
                            components.hour = 23
                            components.minute = 59
                            components.second = 59
                            let end = calendar.date(from: components) ?? Date()
                            
                            onSelect(start, end)
                        }) {
                            HStack {
                                Spacer()
                                Text("开启穿越")
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .frame(height: 50)
                            .background(Color.dfkAccent)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("寻回那年的记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let date = PhotoService.shared.getEarliestAssetDate() {
                let year = Calendar.current.component(.year, from: date)
                let currentYear = Calendar.current.component(.year, from: Date())
                self.earliestYear = min(year, currentYear)
                // 确保默认选中年不在范围外
                if selectedYear < self.earliestYear {
                    selectedYear = currentYear
                }
            }
        }
    }
}

// MARK: - Photo Import Results View
struct PhotoImportResultsView: View {
    @Environment(LocationManager.self) private var locationManager
    let results: [Footprint]
    let onConfirm: ([Footprint]) -> Void
    @Environment(\.dismiss) var dismiss
    @Query private var allPlaces: [Place]
    @State private var selectedIDs: Set<UUID> = []
    @State private var editingFootprint: Footprint?

    init(results: [Footprint], onConfirm: @escaping ([Footprint]) -> Void) {
        self.results = results
        self.onConfirm = onConfirm
        // 默认全选
        self._selectedIDs = State(initialValue: Set(results.map { $0.footprintID }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button(selectedIDs.count == results.count ? "取消全选" : "全选") {
                            if selectedIDs.count == results.count {
                                selectedIDs = []
                            } else {
                                selectedIDs = Set(results.map { $0.footprintID })
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.dfkAccent)
                        
                        Spacer()
                        
                        Text("共寻回 **\(results.count)** 个足迹")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                ForEach(results, id: \.footprintID) { fp in
                    let isSelected = selectedIDs.contains(fp.footprintID)
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .dfkAccent : .secondary)
                            .font(.system(size: 20))
                            .onTapGesture {
                                if isSelected {
                                    selectedIDs.remove(fp.footprintID)
                                } else {
                                    selectedIDs.insert(fp.footprintID)
                                }
                            }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(fp.date.formatted(.dateTime.year().month().day()))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Label("\(fp.photoAssetIDs.count) 张照片", systemImage: "photo.on.rectangle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            
                            FootprintCardView(footprint: fp, allPlaces: allPlaces, showTimeline: false) { item, _ in 
                                self.editingFootprint = item
                            }
                            .opacity(isSelected ? 1.0 : 0.6)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .sheet(item: $editingFootprint) { footprint in
                FootprintModalView(footprint: footprint, autoFocus: false)
                    .environment(locationManager)
            }
            .navigationTitle("寻回的记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedIDs.isEmpty ? "导入" : "导入 \(selectedIDs.count) 个足迹") {
                        let selected = results.filter { selectedIDs.contains($0.footprintID) }
                        onConfirm(selected)
                    }
                    .disabled(selectedIDs.isEmpty)
                    .fontWeight(.bold)
                    .foregroundColor(.dfkAccent)
                }
            }
        }
    }
}

// MARK: - History Favorites View
struct HistoryFavoritesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    
    @Query(filter: #Predicate<Footprint> { $0.isHighlight == true && $0.statusValue != "ignored" }, sort: \Footprint.startTime, order: .reverse) 
    private var favoriteFootprints: [Footprint]
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var selectedFootprint: Footprint?
    let onUpdate: () -> Void
    
    private var groupedFavorites: [(Date, [Footprint])] {
        let dictionary = Dictionary(grouping: favoriteFootprints) { footprint in
            Calendar.current.startOfDay(for: footprint.startTime)
        }
        return dictionary.sorted { $0.key > $1.key }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                if favoriteFootprints.isEmpty {
                    VStack(spacing: 20) {
                        Spacer().frame(height: 100)
                        Image(systemName: "star.slash")
                            .font(.system(size: 60))
                            .foregroundColor(Color.dfkCandidate)
                        Text("还没有收藏任何足迹")
                            .font(.subheadline.bold())
                            .foregroundColor(Color.dfkSecondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(groupedFavorites, id: \.0) { date, footprints in
                        Section(header: dateHeader(for: date)) {
                            VStack(spacing: 0) {
                                ForEach(footprints) { fp in
                                    FootprintCardView(footprint: fp, allPlaces: allPlaces, showTimeline: false) { item, _ in
                                        selectedFootprint = item
                                    }
                                    .padding(.horizontal, 16)
                                    .onChange(of: fp.isHighlight) { _, _ in
                                        onUpdate()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .background(Color.dfkBackground)
        .sheet(item: $selectedFootprint) { footprint in
            FootprintModalView(footprint: footprint, autoFocus: false)
                .environment(locationManager)
                .onDisappear { onUpdate() }
        }
    }
    
    private func dateHeader(for date: Date) -> some View {
        HStack {
            Text(date.formatted(.dateTime.year().month().day()))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.dfkBackground.opacity(0.95))
            Spacer()
        }
    }
}


#Preview {
    NavigationStack {
        HistoryListView(initialDate: Date())
    }
}
