import SwiftUI
import SwiftData
import MapKit

struct DaySummary: Identifiable, Equatable {
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

// MARK: - Simple Daily Timeline Modal
struct SimpleDayTimelineView: View {
    let date: Date
    @Query(sort: \Footprint.startTime, order: .reverse) private var allFootprints: [Footprint]
    @Query private var allPlaces: [Place]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFootprint: Footprint?
    
    var dailyFootprints: [Footprint] {
        allFootprints.filter { 
            Calendar.current.isDate($0.date, inSameDayAs: date) &&
            $0.status != .ignored
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if dailyFootprints.isEmpty {
                        VStack(spacing: 20) {
                            Spacer().frame(height: 100)
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 60)).foregroundColor(Color.dfkCandidate)
                            Text("比较平常，没有发现特别足迹").font(.subheadline.bold()).foregroundColor(Color.dfkSecondaryText)
                            Spacer()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(dailyFootprints) { footprint in
                                FootprintCardView(footprint: footprint, allPlaces: allPlaces) { item, _ in
                                    self.selectedFootprint = item
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .navigationTitle(date.formatted(.dateTime.year(.defaultDigits).month(.wide).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.bold)
                }
            }
            .sheet(item: $selectedFootprint) { footprint in
                FootprintModalView(footprint: footprint, autoFocus: false)
            }
        }
    }
}

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Footprint.date, order: .reverse) private var allFootprints: [Footprint]
    
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
    
    @Query(sort: \Place.name) private var allPlacesForScan: [Place]
    
    struct IdentifiableDate: Identifiable {
        var id: Date { date }
        let date: Date
    }
    
    enum ViewMode: String, CaseIterable {
        case week = "周"
        case month = "月"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 视图切换
            pickerSection
            
            // 内容区域
            contentArea
        }
        .navigationTitle("往昔足迹")
        .navigationBarTitleDisplayMode(.large)
        .background(Color.dfkBackground)
        .onAppear { updateSummaries() }
        .onChange(of: allFootprints) { updateSummaries() }
        .sheet(item: $showingDate) { item in
            SimpleDayTimelineView(date: item.date)
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
                for fp in selectedFootprints {
                    OpenAIService.shared.analyzeFootprint(fp) { _ in
                        try? self.modelContext.save()
                    }
                }
                isShowingResults = false
                scannedResults = []
                updateSummaries()
                self.successCount = selectedFootprints.count
                self.showingImportSuccessAlert = true
            }
        ))
        .modifier(ImportOverlaysModifier(
            isScanning: isScanning,
            showingNoResultsAlert: $showingNoResultsAlert,
            showingImportSuccessAlert: $showingImportSuccessAlert,
            successCount: successCount
        ))
        .modifier(ImportToolbarModifier(showingPhotoImportRange: $showingPhotoImportRange))
    }
    
    private var pickerSection: some View {
        Picker("视图", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }
    
    private var contentArea: some View {
        ZStack {
            if viewMode == .week {
                HistoryWeekView(summaries: cachedSummaries) { date in
                    showingDate = IdentifiableDate(date: date)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)),
                    removal: .opacity.combined(with: .scale(scale: 1.02))
                ))
            } else {
                HistoryMonthView(summaries: cachedSummaries) { date in
                    showingDate = IdentifiableDate(date: date)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)),
                    removal: .opacity.combined(with: .scale(scale: 1.02))
                ))
            }
        }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: viewMode)
    }
    
    
    private func startScanning(start: Date, end: Date) {
        isScanning = true
        // 适当延迟以确保 UI 切换完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 设置 end 为当天的 23:59:59
            let finalEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            // 收集所有已存在的照片 ID 用于过滤
            let existingIDs = Set(self.allFootprints.flatMap { $0.photoAssetIDs })
            
            PhotoService.shared.autoScanFootprints(from: start, to: finalEnd, allPlaces: allPlacesForScan, excludedAssetIDs: existingIDs) { results in
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
        let grouped = Dictionary(grouping: validFootprints) { Calendar.current.startOfDay(for: $0.date) }
        var dict: [Date: DaySummary] = [:]
        
        for (date, footprints) in grouped {
            let totalDuration = footprints.reduce(0) { $0 + $1.duration }
            let highlightCount = footprints.filter { $0.isHighlight == true }.count
            let highlights = footprints.filter { $0.isHighlight == true }
            let highlightTitle = highlights.first?.title
            let hasConfirmed = footprints.contains { $0.status == .confirmed }
            let hasCandidate = footprints.contains { $0.status == .candidate }
            
            var activeHours = Set<Int>()
            var favoriteHours = Set<Int>()
            for fp in footprints {
                let calendar = Calendar.current
                let startH = calendar.component(.hour, from: fp.startTime)
                let endH = calendar.component(.hour, from: fp.endTime)
                let isFav = fp.isHighlight == true
                
                if startH <= endH {
                    for h in startH...endH {
                        activeHours.insert(h)
                        if isFav { favoriteHours.insert(h) }
                    }
                } else {
                    // Spans midnight
                    for h in startH...23 {
                        activeHours.insert(h)
                        if isFav { favoriteHours.insert(h) }
                    }
                    for h in 0...endH {
                        activeHours.insert(h)
                        if isFav { favoriteHours.insert(h) }
                    }
                }
            }
            
            dict[date] = DaySummary(
                date: date,
                totalDuration: totalDuration,
                footprintCount: footprints.count,
                highlightCount: highlightCount,
                highlightTitle: highlightTitle,
                hasConfirmed: hasConfirmed,
                hasCandidate: hasCandidate,
                activeHours: activeHours,
                favoriteHours: favoriteHours
            )
        }
        self.cachedSummaries = dict
    }
    
    private func emptySummary(for date: Date) -> DaySummary {
        DaySummary(date: date, totalDuration: 0, footprintCount: 0, highlightCount: 0, highlightTitle: nil, hasConfirmed: false, hasCandidate: false, activeHours: [], favoriteHours: [])
    }
}

// MARK: - Week View
struct HistoryWeekView: View {
    let summaries: [Date: DaySummary]
    let onDayTap: (Date) -> Void
    
    var weeks: [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let startOfTodayWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        
        // Find earliest footprint date (or default to 8 weeks ago if none)
        let allDates = summaries.keys
        let earliestDate = allDates.min() ?? calendar.date(byAdding: .weekOfYear, value: -8, to: today)!
        let startOfEarliestWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: earliestDate))!
        
        let weekCount = calendar.dateComponents([.weekOfYear], from: startOfEarliestWeek, to: startOfTodayWeek).weekOfYear ?? 0
        
        return (0...max(weekCount, 4)).map { weekOffset in
            let startOfWeek = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: startOfTodayWeek)!
            // Reverse days within the week (Sun to Mon)
            return (0..<7).compactMap { dayOffset in
                calendar.date(byAdding: .day, value: 6 - dayOffset, to: startOfWeek)
            }
        }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(weeks, id: \.self) { weekDates in
                    if let firstDate = weekDates.first {
                        Section(header: weekHeader(for: firstDate)) {
                            VStack(spacing: 8) {
                                ForEach(weekDates, id: \.self) { date in
                                    DayCell(
                                        date: date,
                                        summary: summaries[date],
                                        onTap: { onDayTap(date) }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.top)
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
    let summary: DaySummary?
    let onTap: () -> Void
    
    var body: some View {
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        let hasData = summary != nil && (summary?.footprintCount ?? 0) > 0
        
        HStack(spacing: 12) {
            // Mon/Tue
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
                .opacity(hasData ? 1.0 : 0.4)
            
            // 4月3日
            Text(date.formatted(.dateTime.month().day()))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(hasData ? .primary : .secondary.opacity(0.5))
                .layoutPriority(1)
                .fixedSize()
            
            // Activity Bar
            ActivityBar(
                activeHours: summary?.activeHours ?? [],
                favoriteHours: summary?.favoriteHours ?? []
            )
            .opacity(hasData ? 1.0 : 0.2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                if isToday {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.dfkAccent.opacity(0.06))
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

struct ActivityBar: View {
    let activeHours: Set<Int>
    let favoriteHours: Set<Int>
    
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<24, id: \.self) { h in
                let color: Color = {
                    if favoriteHours.contains(h) { return .dfkHighlight }
                    if activeHours.contains(h) { return .dfkAccent }
                    return .secondary.opacity(0.1)
                }()
                
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
            }
        }
    }
}

// MARK: - Month View
struct HistoryMonthView: View {
    let summaries: [Date: DaySummary]
    let onDayTap: (Date) -> Void
    
    var months: [Date] {
        let calendar = Calendar.current
        let today = Date().startOfMonth ?? Date()
        
        let allDates = summaries.keys
        let earliestDate = allDates.min() ?? calendar.date(byAdding: .month, value: -6, to: today)!
        let startOfEarliestMonth = earliestDate.startOfMonth ?? earliestDate
        
        // Calculate number of months between startOfEarliestMonth and today
        let monthCount = calendar.dateComponents([.month], from: startOfEarliestMonth, to: today).month ?? 0
        
        return (0...max(monthCount, 5)).compactMap { calendar.date(byAdding: .month, value: -$0, to: today) }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 32, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.self) { month in
                    Section(header: monthHeader(for: month)) {
                        monthGrid(for: month)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .background(Color.dfkBackground)
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
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
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
        // We want Monday = 0... Sunday = 6
        // Calendar weekday (1 = Sun, 2 = Mon...)
        let adjusted = (weekday + 5) % 7
        return adjusted
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
    let summary: DaySummary?
    let onTap: () -> Void
    
    var body: some View {
        let hasData = summary != nil && (summary?.footprintCount ?? 0) > 0
        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
        
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(hasData ? (isToday ? .dfkAccent : .primary) : .secondary.opacity(0.4))
            
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
                    Circle()
                        .stroke(Color.dfkAccent.opacity(hasData ? 0.2 : 0.1), lineWidth: 1)
                        .padding(2)
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
            }
    }
}

struct ImportOverlaysModifier: ViewModifier {
    let isScanning: Bool
    @Binding var showingNoResultsAlert: Bool
    @Binding var showingImportSuccessAlert: Bool
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
            .overlay {
                if isScanning {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("正在穿越时空...")
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                        .padding(40)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.dfkBackground.opacity(0.8)))
                    }
                }
            }
    }
}

struct ImportToolbarModifier: ViewModifier {
    @Binding var showingPhotoImportRange: Bool
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPhotoImportRange = true
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
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var endDate = Date()
    
    var onSelect: (Date, Date) -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        DatePicker("开始日期", selection: $startDate, in: ...endDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                    } header: {
                        Text("选择日期范围")
                    } footer: {
                        Text("我们将分析选定时间段内的照片地理位置，为您生成足迹。")
                    }
                    
                    Section {
                        Button(action: {
                            onSelect(startDate, endDate)
                        }) {
                            HStack {
                                Spacer()
                                Text("下一步")
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.dfkAccent)
                    }
                }
            }
            .navigationTitle("找回那天的足迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Photo Import Results View
struct PhotoImportResultsView: View {
    let results: [Footprint]
    let onConfirm: ([Footprint]) -> Void
    @Environment(\.dismiss) var dismiss
    @Query private var allPlaces: [Place]
    @State private var selectedIDs: Set<UUID> = []

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
                        Text("共寻回 **\(results.count)** 个足迹")
                            .font(.subheadline)
                        Spacer()
                        Button(selectedIDs.count == results.count ? "取消全选" : "全选") {
                            if selectedIDs.count == results.count {
                                selectedIDs = []
                            } else {
                                selectedIDs = Set(results.map { $0.footprintID })
                            }
                        }
                        .font(.caption)
                    }
                }
                
                ForEach(results, id: \.footprintID) { fp in
                    HStack(spacing: 12) {
                        Image(systemName: selectedIDs.contains(fp.footprintID) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedIDs.contains(fp.footprintID) ? .dfkAccent : .secondary)
                            .font(.system(size: 20))
                            .onTapGesture {
                                if selectedIDs.contains(fp.footprintID) {
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
                            
                            FootprintCardView(footprint: fp, allPlaces: allPlaces) { _, _ in }
                                .disabled(true)
                                .opacity(selectedIDs.contains(fp.footprintID) ? 1.0 : 0.6)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
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

#Preview {
    NavigationStack {
        HistoryListView()
    }
}
