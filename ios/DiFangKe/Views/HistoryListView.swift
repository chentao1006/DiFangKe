import SwiftUI
import SwiftData
import MapKit
import Photos
import Aptabase

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

private struct TimelineIconKey: Hashable {
    let icon: String
    let isTransport: Bool
}

private struct SummaryIconStyle {
    let backgroundColor: Color
    let foregroundColor: Color
    let showsCircularBackground: Bool
}

private struct StarOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.5

        for index in 0..<10 {
            let angle = Double(index) * (.pi / 5) - (.pi / 2)
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

private func deduplicatedTimelineIcons(_ icons: [DaySummary.TimelineIcon]) -> [DaySummary.TimelineIcon] {
    var ordered: [DaySummary.TimelineIcon] = []
    var positions: [TimelineIconKey: Int] = [:]

    for item in icons {
        let key = TimelineIconKey(icon: item.icon, isTransport: item.isTransport)
        if let index = positions[key] {
            if item.isHighlight && !ordered[index].isHighlight {
                ordered[index] = DaySummary.TimelineIcon(
                    icon: ordered[index].icon,
                    colorHex: ordered[index].colorHex,
                    isTransport: ordered[index].isTransport,
                    isHighlight: true
                )
            }
        } else {
            positions[key] = ordered.count
            ordered.append(item)
        }
    }

    return Array(ordered.prefix(10))
}

private func timelineIconStyle(for item: DaySummary.TimelineIcon, colorScheme: ColorScheme) -> SummaryIconStyle {
    let fallback = item.isTransport ? Color(hex: "#8E8E93") ?? .dfkAccent : Color.dfkAccent
    let background = (Color(hex: item.colorHex) ?? fallback).opacity(0.9)
    let foreground: Color = colorScheme == .dark ? .black : .white
    return SummaryIconStyle(
        backgroundColor: background,
        foregroundColor: foreground,
        showsCircularBackground: !item.isTransport && !item.isHighlight
    )
}



private extension View {
    func contentVisibility(for mode: HistoryListView.ViewMode, matching target: HistoryListView.ViewMode) -> some View {
        self
            .opacity(mode == target ? 1 : 0)
            .allowsHitTesting(mode == target)
            .accessibilityHidden(mode != target)
    }
}

struct IdentifiableDate: Identifiable {
    var id: Date { date }
    let date: Date
}

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: \Footprint.date, order: .reverse) private var allFootprints: [Footprint]
    @Query private var allManualSelections: [TransportManualSelection]
    @Query(sort: \TransportRecord.startTime, order: .reverse) private var allTransportRecords: [TransportRecord]
    @Query private var allInsights: [DailyInsight]
    @Query(sort: \ActivityType.sortOrder) private var allActivityTypes: [ActivityType]
    @Query(sort: \FutureTrip.arrivalDate) private var futureTrips: [FutureTrip]
    
    let initialDate: Date
    let showImportOnAppear: Bool
    @State private var viewMode: ViewMode = .month
    @State private var selectedDate: Date
    @State private var showingDate: IdentifiableDate? = nil
    @State private var showingPhotoImportRange = false
    @State private var showingRawPointsDate: IdentifiableDate? = nil
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
    
    enum ViewMode: String, CaseIterable {
        case month = "历史"
        case favorites = "收藏"
        case statistics = "统计"
    }

    @State private var hasScrolledMonth = false
    
    var onDateSelected: ((Date) -> Void)? = nil
    var onStatisticsVisibilityChanged: ((Bool) -> Void)? = nil

    init(initialDate: Date = Date(), showImportOnAppear: Bool = false, onDateSelected: ((Date) -> Void)? = nil, onStatisticsVisibilityChanged: ((Bool) -> Void)? = nil) {
        let normalizedDate = Calendar.current.startOfDay(for: initialDate)
        self.initialDate = normalizedDate
        self.showImportOnAppear = showImportOnAppear
        self.onDateSelected = onDateSelected
        self.onStatisticsVisibilityChanged = onStatisticsVisibilityChanged
        _selectedDate = State(initialValue: normalizedDate)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            pickerSection
            contentArea
                .overlay(alignment: .topTrailing) {
                    yearJumpOverlay
                }
        }
        .navigationTitle("往昔足迹")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.dfkBackground)
        .onAppear {
            rebuildIndex()
            onStatisticsVisibilityChanged?(viewMode == .statistics)
            if showImportOnAppear {
                checkPhotoPermission()
            }
        }
        .onChange(of: viewMode) { _, mode in
            onStatisticsVisibilityChanged?(mode == .statistics)
        }
        .onDisappear {
            onStatisticsVisibilityChanged?(false)
        }
        .onChange(of: allFootprints) { rebuildIndex() }
        .onChange(of: allTransportRecords) { rebuildIndex() }
        .onChange(of: futureTrips) { rebuildIndex() }
        .onChange(of: allActivityTypes) { rebuildIndex() }
        .sheet(item: $showingDate) { item in
            TimelineView(initialDate: item.date)
                .environment(locationManager)
                .onDisappear { rebuildIndex() }
        }
        .sheet(item: $showingRawPointsDate) { item in
            RawPointsListView(date: item.date)
                .environment(locationManager)
                .onDisappear { rebuildIndex() }
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
                    
                    await MainActor.run {
                        scannedResults = []
                        rebuildIndex()
                        self.successCount = selectedFootprints.count
                        self.isImporting = false
                        self.showingImportSuccessAlert = true
                        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
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
    
    private var pickerSection: some View {
        Picker("视图", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 15)
        .background(Color.dfkBackground)
    }
    
    private var yearJumpOverlay: some View {
        Group {
            if shouldShowYearJump, !historyYears.isEmpty {
                Menu {
                    ForEach(historyYears, id: \.year) { item in
                        Button("\(String(item.year))年") {
                            jumpToYear(item.date)
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                }
                .yearJumpButtonStyle()
                .padding(.top, 6)
                .padding(.trailing, 20)
            }
        }
    }
    
    private var contentArea: some View {
        ZStack {
            HistoryMonthView(footprintsByDay: footprintsByDay, transportsByDay: transportsByDay, futureTripsByDay: futureTripsByDay, allActivityTypes: allActivityTypes, targetDate: selectedDate, earliestDate: earliestHistoryDate, latestDate: latestHistoryDate, hasScrolled: $hasScrolledMonth, showingRawPointsDate: $showingRawPointsDate) { date in
                if let onDateSelected = onDateSelected {
                    onDateSelected(date)
                } else {
                    showingDate = IdentifiableDate(date: date)
                }
            }
            .contentVisibility(for: viewMode, matching: .month)

            HistoryFavoritesView(onUpdate: rebuildIndex)
                .environment(locationManager)
                .contentVisibility(for: viewMode, matching: .favorites)

            HistoryStatisticsView()
                .contentVisibility(for: viewMode, matching: .statistics)
        }
    }
    
    private var earliestHistoryDate: Date {
        let footprintDate = allFootprints.last?.startTime
        let futureTripDate = futureTrips.filter(\.hasPlanDate).map(\.arrivalDate).min()
        return [footprintDate, futureTripDate].compactMap { $0 }.min() ?? Calendar.current.startOfDay(for: Date())
    }

    private var latestHistoryDate: Date {
        let today = Calendar.current.startOfDay(for: Date())
        let footprintDate = allFootprints.first?.startTime
        let futureTripDate = futureTrips.filter(\.hasPlanDate).map(\.arrivalDate).max()
        return [today, footprintDate, futureTripDate].compactMap { $0 }.max() ?? today
    }
    
    private var shouldShowYearJump: Bool {
        viewMode == .month
    }
    
    private var historyYears: [(year: Int, date: Date)] {
        let calendar = Calendar.current
        let dates = allFootprints.map(\.startTime) + futureTrips.filter(\.hasPlanDate).map(\.arrivalDate)
        let grouped = Dictionary(grouping: dates) { date in
            calendar.component(.year, from: date)
        }
        
        return grouped.compactMap { year, dates in
            let earliestDateInYear = dates
                .map { calendar.startOfDay(for: $0) }
                .min()
            return earliestDateInYear.map { (year: year, date: $0) }
        }
        .sorted { $0.year > $1.year }
    }
    
    private func jumpToYear(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        hasScrolledMonth = false
    }
    
    @State private var footprintsByDay: [Date: [Footprint]] = [:]
    @State private var transportsByDay: [Date: [TransportRecord]] = [:]
    @State private var futureTripsByDay: [Date: [FutureTrip]] = [:]

    /// Days a [start, end) span meaningfully overlaps, skipping any day where the
    /// overlap is under `minOverlap` (e.g. a span that ends right at midnight would
    /// otherwise flag the next day too, even though it has ~0s of actual time on it).
    private func daysWithMeaningfulOverlap(from start: Date, to end: Date, calendar: Calendar, minOverlap: TimeInterval = 60) -> [Date] {
        guard end > start else { return [calendar.startOfDay(for: start)] }
        var days: [Date] = []
        var current = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        while current <= lastDay {
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            let overlapStart = max(start, current)
            let overlapEnd = min(end, next)
            if overlapEnd.timeIntervalSince(overlapStart) >= minOverlap {
                days.append(current)
            }
            current = next
        }
        return days.isEmpty ? [calendar.startOfDay(for: start)] : days
    }

    private func rebuildIndex() {
        let calendar = Calendar.current
        var fpMap: [Date: [Footprint]] = [:]
        var tpMap: [Date: [TransportRecord]] = [:]
        var tripMap: [Date: [FutureTrip]] = [:]

        for fp in allFootprints where fp.statusValue != "ignored" {
            for day in daysWithMeaningfulOverlap(from: fp.startTime, to: fp.endTime, calendar: calendar) {
                fpMap[day, default: []].append(fp)
            }
        }

        for tp in allTransportRecords where tp.statusRaw != "ignored" {
            for day in daysWithMeaningfulOverlap(from: tp.startTime, to: tp.endTime, calendar: calendar) {
                tpMap[day, default: []].append(tp)
            }
        }

        for trip in futureTrips where trip.hasPlanDate {
            let day = calendar.startOfDay(for: trip.arrivalDate)
            tripMap[day, default: []].append(trip)
        }
        
        self.footprintsByDay = fpMap
        self.transportsByDay = tpMap
        self.futureTripsByDay = tripMap
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
            let activeFootprints = self.allFootprints.filter { $0.status != .ignored }
            let existingIDs = Set(activeFootprints.flatMap { $0.photoAssetIDs })
            let liteHistory = activeFootprints.map { TimelineBuilder.convertToFootprintLite($0) }
            let litePlaces = allPlacesForScan.map { $0.convertToLite() }
            let liteActivities = allActivityTypes.map { $0.convertToLite() }
            
            PhotoService.shared.autoScanFootprints(from: start, to: finalEnd, allPlaces: litePlaces, allActivities: liteActivities, excludedAssetIDs: existingIDs, history: liteHistory, onProgress: { current, total in
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(icons) { item in
                let style = timelineIconStyle(for: item, colorScheme: colorScheme)
                ZStack {
                    if item.isHighlight {
                        StarOutlineShape()
                            .fill(style.backgroundColor)
                            .frame(width: 21, height: 21)
                    } else if style.showsCircularBackground {
                        Circle()
                            .fill(style.backgroundColor)
                            .frame(width: 18, height: 18)
                    }

                    Image(systemName: item.icon)
                        .font(.system(size: item.isHighlight ? 11 : 10.5, weight: .semibold))
                        .foregroundColor(item.isTransport ? .dfkAccent : style.foregroundColor)
                }
                .frame(width: item.isHighlight ? 21 : 20, height: item.isHighlight ? 21 : 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DayStatsView: View {
    let footprintCount: Int
    let mileage: Double
    let photoCount: Int
    
    var body: some View {
        HStack(spacing: 8) {
            if footprintCount > 0 { statItem(icon: "mappin.and.ellipse", value: "\(footprintCount)") }
            if mileage > 0 { statItem(icon: "figure.walk", value: formatMileage(mileage)) }
            if photoCount > 0 { statItem(icon: "photo.on.rectangle", value: "\(photoCount)") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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

struct HistoryMonthView: View {
    let footprintsByDay: [Date: [Footprint]]
    let transportsByDay: [Date: [TransportRecord]]
    let futureTripsByDay: [Date: [FutureTrip]]
    let allActivityTypes: [ActivityType]
    let targetDate: Date
    let earliestDate: Date
    let latestDate: Date
    @Binding var hasScrolled: Bool
    @Binding var showingRawPointsDate: IdentifiableDate?
    let onDayTap: (Date) -> Void
    
    @State private var rawPointsDialogDate: IdentifiableDate?
    
    var monthsCount: Int {
        let calendar = Calendar.current
        let latestMonth = latestDate.startOfMonth ?? latestDate
        let startOfEarliestMonth = earliestDate.startOfMonth ?? earliestDate
        return max(0, calendar.dateComponents([.month], from: startOfEarliestMonth, to: latestMonth).month ?? 0)
    }
    
    var months: [Date] {
        let calendar = Calendar.current
        let startOfEarliestMonth = earliestDate.startOfMonth ?? earliestDate
        return (0...monthsCount).compactMap { calendar.date(byAdding: .month, value: $0, to: startOfEarliestMonth) }
    }

    private var scrollTargetKey: String {
        let earliestMonthID = (earliestDate.startOfMonth ?? earliestDate).dayID
        return targetDate.dayID + "-" + earliestMonthID + "-" + String(monthsCount)
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
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

                if let rawPointsDialogDate {
                    rawPointsActionOverlay(for: rawPointsDialogDate)
                }
            }
            .background(Color.dfkBackground)
            .task(id: scrollTargetKey) {
                if !hasScrolled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await scrollToTarget(proxy: proxy)
                }
            }
        }
    }
    
    private func scrollToTarget(proxy: ScrollViewProxy) async {
        guard let startOfMonth = targetDate.startOfMonth else { return }
        guard months.contains(where: { Calendar.current.isDate($0, equalTo: targetDate, toGranularity: .month) }) else { return }

        proxy.scrollTo("month-" + startOfMonth.dayID, anchor: .top)
        try? await Task.sleep(nanoseconds: 80_000_000)
        proxy.scrollTo("day-" + targetDate.dayID, anchor: .center)
        try? await Task.sleep(nanoseconds: 80_000_000)
        proxy.scrollTo("day-" + targetDate.dayID, anchor: .center)
        hasScrolled = true
    }

    private func rawPointsActionOverlay(for item: IdentifiableDate) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        rawPointsDialogDate = nil
                    }
                }

            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("日期操作")
                        .font(.headline)
                    Text(item.date.formatted(.dateTime.year().month().day()))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(.dfkAccent)
                    Text("查看所有轨迹点")
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
                .onTapGesture {
                    showingRawPointsDate = item
                    rawPointsDialogDate = nil
                }

                Divider()

                Text("取消")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            rawPointsDialogDate = nil
                        }
                    }
            }
            .frame(width: 280)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .zIndex(10)
    }
    
    private func monthHeader(for date: Date) -> some View {
        HStack {
            Text(date.formatted(.dateTime.year().month(.wide))).font(.system(size: 18, weight: .bold)).padding(.horizontal, 20).padding(.vertical, 10)
            Spacer()
        }
        .background(Color.dfkBackground.opacity(0.95))
    }
    
    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let firstIndex = calendar.firstWeekday - 1 // firstWeekday is 1-indexed (1=Sun, 2=Mon)
        return Array(symbols[firstIndex..<symbols.count] + symbols[0..<firstIndex])
    }
    
    private func monthGrid(for month: Date) -> some View {
        let days = daysInMonth(for: month)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary.opacity(0.6)).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 10) {
                let leadingSpaces = calculateLeadingSpaces(for: month)
                ForEach(0..<leadingSpaces, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(days, id: \.self) { date in
                    MonthDayCell(
                        date: date,
                        targetDate: targetDate,
                        footprints: footprintsByDay[date] ?? [],
                        transports: transportsByDay[date] ?? [],
                        futureTrips: futureTripsByDay[date] ?? [],
                        activityTypes: allActivityTypes,
                        onTap: { onDayTap(date) }
                    )
                        .id("day-" + date.dayID)
                        .onLongPressGesture(minimumDuration: 0.45) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            rawPointsDialogDate = IdentifiableDate(date: date)
                        }
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func calculateLeadingSpaces(for month: Date) -> Int {
        guard let firstDay = month.startOfMonth else { return 0 }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: firstDay) // 1=Sun, 2=Mon...
        return (weekday - calendar.firstWeekday + 7) % 7
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
    let footprints: [Footprint]
    let transports: [TransportRecord]
    let futureTrips: [FutureTrip]
    let activityTypes: [ActivityType]
    let onTap: () -> Void
    private var timelineSegments: [MonthDayTimelineSegment] {
        let footprintSegments = footprints.map { footprint in
            let activity = footprint.activityTypeValue.flatMap { value in
                activityTypes.first { $0.id.uuidString == value || $0.name == value }
            }
            return MonthDayTimelineSegment(
                id: footprint.footprintID.uuidString,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                color: Color(hex: activity?.colorHex ?? "") ?? .dfkAccent,
                isTransport: false,
                isCurrent: Calendar.current.isDateInToday(date) && footprint.footprintID == latestFootprintID
            )
        }
        let transportSegments = transports.map { transport in
            MonthDayTimelineSegment(
                id: transport.recordID.uuidString,
                startTime: transport.startTime,
                endTime: transport.endTime,
                color: .dfkAccent,
                isTransport: true,
                isCurrent: false
            )
        }
        return (footprintSegments + transportSegments).sorted { $0.startTime < $1.startTime }
    }

    private var latestFootprintID: UUID? {
        footprints.max { $0.startTime < $1.startTime }?.footprintID
    }

    var body: some View {
        let hasData = !footprints.isEmpty || !transports.isEmpty || !futureTrips.isEmpty
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        let isTarget = Calendar.current.isDate(date, inSameDayAs: targetDate)
        
        ZStack {
            if hasData {
                MonthDayTimelineRing(
                    date: date,
                    segments: timelineSegments,
                    plannedTrips: futureTrips
                )
                .frame(width: 34, height: 34)
            }
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(hasData ? .primary : .secondary.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
            ZStack {
                if isToday { RoundedRectangle(cornerRadius: 12).fill(Color.dfkAccent.opacity(0.06)) }
                else if isTarget { RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)) }
            }
        )
        .onTapGesture { if hasData { onTap() } }
    }
}

private struct MonthDayTimelineSegment: Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date
    let color: Color
    let isTransport: Bool
    let isCurrent: Bool
}

/// The calendar's compact counterpart to the Watch day ring.  A data day has
/// its time distribution around the date rather than a row of unrelated icons.
private struct MonthDayTimelineRing: View {
    let date: Date
    let segments: [MonthDayTimelineSegment]
    let plannedTrips: [FutureTrip]

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            Circle()
                .stroke(.gray.opacity(isToday ? 0.16 : unrecordedOpacity), lineWidth: 3.2)
            if isToday {
                Circle()
                    .trim(from: 0, to: elapsedDayFraction)
                    .stroke(.gray.opacity(0.30), lineWidth: 3.2)
            }

            ForEach(segments.filter(\.isTransport)) { segment in
                transportArc(for: segment)
            }
            ForEach(segments.filter { !$0.isTransport }) { segment in
                arc(for: segment, lineWidth: segment.isCurrent ? 5.4 : 3.5)
            }
            ForEach(plannedTrips.filter(\.hasArrivalTime), id: \.id) { trip in
                planMarker(for: trip)
            }
        }
        .rotationEffect(.degrees(-90))
    }

    @ViewBuilder
    private func arc(for segment: MonthDayTimelineSegment, lineWidth: CGFloat) -> some View {
        let range = clippedFractionRange(start: segment.startTime, end: segment.endTime)
        // Rounded caps extend past the trim point.  This larger inset keeps a
        // real visible gray break between adjacent segments in a 34pt cell.
        let gap = min(0.028, range.length * 0.18)
        if range.length > gap * 2 {
            Circle()
                .trim(from: range.start + gap, to: range.start + range.length - gap)
                .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    /// Transport is a hollow band: white interior with a thin theme-colour
    /// outline, kept narrower than a footprint segment.
    @ViewBuilder
    private func transportArc(for segment: MonthDayTimelineSegment) -> some View {
        let range = clippedFractionRange(start: segment.startTime, end: segment.endTime)
        let gap = min(0.028, range.length * 0.18)
        if range.length > gap * 2 {
            let start = range.start + gap
            let end = range.start + range.length - gap
            Circle()
                .trim(from: start, to: end)
                .stroke(Color.dfkAccent, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            Circle()
                .trim(from: start, to: end)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }

    private func planMarker(for trip: FutureTrip) -> some View {
        let range = clippedFractionRange(start: trip.arrivalDate, end: trip.arrivalDate.addingTimeInterval(10 * 60))
        return Circle()
            .trim(from: range.start, to: min(1, range.start + max(0.012, range.length)))
            .stroke(Color.dfkAccent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    private var unrecordedOpacity: Double {
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: Date()) ? 0.16 : 0.30
    }

    private var isToday: Bool { calendar.isDateInToday(date) }

    private var elapsedDayFraction: Double {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(dayStart) / dayEnd.timeIntervalSince(dayStart)))
    }

    private func clippedFractionRange(start: Date, end: Date) -> (start: Double, length: Double) {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return (0, 0) }
        let clippedStart = max(start, dayStart)
        let clippedEnd = min(end, dayEnd)
        guard clippedEnd > clippedStart else { return (0, 0) }
        let duration = dayEnd.timeIntervalSince(dayStart)
        return (
            max(0, clippedStart.timeIntervalSince(dayStart) / duration),
            min(1, clippedEnd.timeIntervalSince(clippedStart) / duration)
        )
    }

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
                            Text("正在读取照片...").foregroundColor(.white).font(.headline)
                            Text("\(scanProgress) / \(scanTotal)").foregroundColor(.white.opacity(0.7)).font(.caption.monospacedDigit())
                        }
                        
                        Button(role: .cancel) {
                            onCancelScan()
                        } label: {
                            Text("取消导入")
                        }
                        .historyActionButtonStyle()
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
        content.toolbar { ToolbarItem(placement: .topBarLeading) { Button { onTapAction() } label: { Image(systemName: "square.and.arrow.down.badge.clock") } } }
    }
}

private extension View {
    @ViewBuilder
    func yearJumpButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }

    @ViewBuilder
    func historyActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Supporting Views
struct PhotoImportRangePicker: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var earliestYear = 2010
    var onSelect: (Date, Date) -> Void
    var body: some View {
        NavigationStack {
            VStack {
                Picker("年份", selection: $selectedYear) {
                    ForEach((min(earliestYear, selectedYear)...Calendar.current.component(.year, from: Date())), id: \.self) { Text("\(String(format: "%d", $0))年").tag($0) }
                }.pickerStyle(.wheel)
                Button("开始导入") {
                    let s = Calendar.current.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
                    let e = Calendar.current.date(from: DateComponents(year: selectedYear, month: 12, day: 31, hour: 23, minute: 59))!
                    onSelect(s, e)
                }
                .historyActionButtonStyle()
            }
            .navigationTitle("寻回那年的记忆")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").dfkToolbarDismissIcon() } } }
            .onAppear {
                if let earliestDate = PhotoService.shared.getEarliestAssetDate() {
                    let year = Calendar.current.component(.year, from: earliestDate)
                    earliestYear = year
                }
            }
        }
    }
}

struct PhotoImportResultsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss
    @Query private var allPlaces: [Place]
    @Query(sort: \ActivityType.sortOrder) private var allActivityTypes: [ActivityType]
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectedFootprintForEdit: Footprint?
    @State private var didCommitImport = false
    
    let results: [Footprint]
    let onConfirm: ([Footprint]) -> Void
    
    private var groupedResults: [(Date, [Footprint])] {
        let grouped = Dictionary(grouping: results) { fp in
            Calendar.current.startOfDay(for: fp.startTime)
        }
        return grouped.sorted { $0.key < $1.key }
    }
    
    private var scanYear: String {
        guard let firstDate = results.first?.startTime else { return "" }
        let year = Calendar.current.component(.year, from: firstDate)
        return "\(year)年"
    }
    
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

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedResults, id: \.0) { date, dateResults in
                            Section(header: dateHeader(for: date, dateResults: dateResults)) {
                                VStack(spacing: 0) {
                                    ForEach(dateResults, id: \.footprintID) { fp in
                                        HStack(spacing: 0) {
                                            Image(systemName: selectedIDs.contains(fp.footprintID) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20))
                                                .foregroundColor(selectedIDs.contains(fp.footprintID) ? .dfkAccent : .secondary.opacity(0.3))
                                                .frame(width: 40)
                                                .onTapGesture {
                                                    toggleSelection(fp.footprintID)
                                                }
                                            
                                            PhotoImportResultRow(
                                                footprint: fp,
                                                allPlaces: allPlaces,
                                                onTap: { selectedFootprintForEdit = $0 }
                                            )
                                        }
                                        .padding(.trailing, 16)
                                        .contentShape(Rectangle())
                                    }
                                }
                                .padding(.top, 4)
                                .padding(.bottom, 12)
                            }
                        }
                    }
                }
            }
            .background(Color.dfkBackground)
            .navigationTitle("\(scanYear)的足迹")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedFootprintForEdit) { fp in
                FootprintModalView(footprint: fp, isDraft: true)
                    .environment(locationManager)
            }
            .onAppear {
                PhotoImportDraftRecovery.markPending(results)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").dfkToolbarDismissIcon() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { 
                        didCommitImport = true
                        PhotoImportDraftRecovery.clearPending()
                        Aptabase.shared.trackEvent("photos_imported")
                        onConfirm(results.filter { selectedIDs.contains($0.footprintID) }) 
                    }
                    .fontWeight(.bold)
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .onDisappear {
                discardUnimportedDrafts()
            }
        }
    }

    /// Drafts normally have no model context. This is a final safety net for
    /// any edit path that accidentally attached one while the import preview
    /// was open: closing/cancelling must never leave a footprint in history.
    private func discardUnimportedDrafts() {
        guard !didCommitImport else { return }
        defer { PhotoImportDraftRecovery.clearPending() }
        let attachedDrafts = results.filter { $0.modelContext != nil }
        guard !attachedDrafts.isEmpty else { return }
        for draft in attachedDrafts {
            modelContext.delete(draft)
        }
        try? modelContext.save()
    }
    
    private func dateHeader(for date: Date, dateResults: [Footprint]) -> some View {
        HStack {
            Text(date.formatted(.dateTime.month().day().weekday()))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            
            Spacer()
            
            Menu {
                ForEach(allActivityTypes) { type in
                    Button {
                        withAnimation {
                            for fp in dateResults {
                                fp.activityTypeValue = type.id.uuidString
                            }
                        }
                    } label: {
                        Label(type.name, systemImage: type.icon)
                    }
                }
                
                Divider()
                
                Button(role: .destructive) {
                    withAnimation {
                        for fp in dateResults {
                            fp.activityTypeValue = nil
                        }
                    }
                } label: {
                    Label("清除活动", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "checklist.checked")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.dfkAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.dfkAccent.opacity(0.1)))
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Color.dfkBackground.opacity(0.95))
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

/// Import candidates are draft models, so their address changes are not backed
/// by a SwiftData query. Keep the visible title in row state: the row redraws
/// immediately when geocoding completes, even before the draft is persisted.
private struct PhotoImportResultRow: View {
    @Bindable var footprint: Footprint
    let allPlaces: [Place]
    let onTap: (Footprint) -> Void
    @State private var displayAddress: String?

    init(footprint: Footprint, allPlaces: [Place], onTap: @escaping (Footprint) -> Void) {
        self._footprint = Bindable(footprint)
        self.allPlaces = allPlaces
        self.onTap = onTap
        self._displayAddress = State(initialValue: Self.usableAddress(from: footprint.address))
    }

    var body: some View {
        FootprintCardView(
            footprint: footprint,
            allPlaces: allPlaces,
            showTimeline: false,
            disableContextMenu: true,
            displayAddressOverride: displayAddress,
            resolvesUnknownAddress: false
        ) { footprint, _ in
            onTap(footprint)
        }
        .padding(.vertical, 4)
        .task(id: footprint.address) {
            await refreshDisplayAddress()
        }
    }

    private func refreshDisplayAddress() async {
        let currentAddress = footprint.address
        if let resolved = Self.usableAddress(from: currentAddress) {
            displayAddress = resolved
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        guard let resolved = await OpenStreetMapGeocoder.shared.lookup(coordinate: coordinate)?.address,
              !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              footprint.address == currentAddress else {
            return
        }

        // Update UI state first. The visible title must not wait for the
        // draft model's observation/persistence cycle.
        displayAddress = resolved
        footprint.address = resolved
    }

    private static func usableAddress(from address: String?) -> String? {
        let value = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let unresolved: Set<String> = ["", "未知位置", "未知地点", "地点记录", "正在解析位置...", "此处"]
        return unresolved.contains(value) ? nil : value
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
