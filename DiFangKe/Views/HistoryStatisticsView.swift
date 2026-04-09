import SwiftUI
import SwiftData
import Charts
import MapKit

enum StatisticsRange: String, CaseIterable {
    case last7Days = "7天"
    case last30Days = "30天"
    case last90Days = "90天"
    case lastYear = "1年"
    case all = "全部"
    
    var days: Int? {
        switch self {
        case .last7Days: return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .lastYear: return 365
        case .all: return nil
        }
    }
}

struct HistoryStatisticsView: View {
    @Query(filter: #Predicate<Footprint> { $0.statusValue != "ignored" }, sort: \Footprint.startTime, order: .reverse) 
    private var allFootprints: [Footprint]
    
    @Query(sort: \ActivityType.sortOrder) 
    private var activityTypes: [ActivityType]
    
    @State private var selectedRange: StatisticsRange = .last30Days
    @State private var appearanceTrigger = false
    @State private var mapPosition: MapCameraPosition = .automatic
    
    // AI Summary State
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var aiSummary: String? = nil
    @State private var isGeneratingSummary = false
    // Cache structure: [RangeRawValue: (text: String, timestamp: Double)]
    @State private var summaryCache: [String: [String: Any]] = (UserDefaults.standard.dictionary(forKey: "statistics_ai_cache") as? [String: [String: Any]]) ?? [:]
    
    @Namespace private var rangeNamespace
    
    // Filtered footprints based on range
    private var filteredFootprints: [Footprint] {
        guard let days = selectedRange.days else { return allFootprints }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return allFootprints.filter { $0.startTime >= cutoff }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: stickyHeader) {
                    VStack(spacing: 24) {
                        if isAiAssistantEnabled {
                            aiSummarySection
                        }
                        
                        heatmapSection
                        activityRankSection
                        trendSection
                        Spacer(minLength: 60)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .background(Color.dfkBackground)
        .onChange(of: selectedRange) { _, _ in
            updateAiSummary()
            updateMapPosition()
        }
        .onAppear {
            updateAiSummary()
            updateMapPosition()
            withAnimation(.easeIn(duration: 0.6)) {
                appearanceTrigger = true
            }
        }
    }
    
    // MARK: - AI Summary Section
    private var aiSummarySection: some View {
        Group {
            if let summary = aiSummary {
                Text(summary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineSpacing(6)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if isGeneratingSummary {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("数据分析中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
        }
    }
    
    private func updateAiSummary() {
        guard isAiAssistantEnabled else { return }
        
        let key = selectedRange.rawValue
        if let cachedData = summaryCache[key],
           let text = cachedData["text"] as? String,
           let timestamp = cachedData["timestamp"] as? Double {
            
            let date = Date(timeIntervalSince1970: timestamp)
            let expiration = getExpirationFor(selectedRange)
            
            if Date().timeIntervalSince(date) < expiration {
                withAnimation {
                    self.aiSummary = text
                }
                return
            }
        }
        
        generateAiSummary()
    }
    
    private func getExpirationFor(_ range: StatisticsRange) -> TimeInterval {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        
        switch range {
        case .last7Days: return 1 * day // 7天 -> 1天过期
        case .last30Days: return 3 * day // 30天 -> 3天过期
        case .last90Days: return 7 * day // 90天 -> 7天过期
        case .lastYear: return 30 * day // 11年 -> 30天过期
        case .all: return 90 * day     // 全部 -> 90天过期
        }
    }
    
    private func generateAiSummary() {
        let rangeAtStart = selectedRange
        let footprintsInScope = filteredFootprints
        guard !footprintsInScope.isEmpty else {
            self.aiSummary = nil
            return
        }
        
        isGeneratingSummary = true
        self.aiSummary = nil
        
        // Prepare data for AI
        let rangeStr = selectedRange.rawValue
        let rankData = getActivityRankData().prefix(3).map { "\($0.name)(\($0.count)次)" }.joined(separator: ", ")
        let topPlaces = getTopLocations().prefix(3).map { loc in
            "核心区域"
        }.count
        
        let prompt = """
        请作为一位睿智的生活观察者，对用户在过去“\(rangeStr)”的足迹数据进行一次有深度且清晰的总结。
        
        数据概览：
        - 记录密度：\(footprintsInScope.count)个生活片段
        - 活动重心：\(rankData)
        - 探索版图：在\(topPlaces)个核心片区留下了足迹
        
        要求：
        1. 语气：客观睿智、理感平衡。不要过于文艺或晦涩，要让用户感到“你精准地捕捉到了他的生活规律”。
        2. 内容维度：通过活动分布推断生活重心（例如：是在专心事业、还是由于多样的尝试而充满活力），通过空间分布感知生活节奏（是在熟悉的半径内规律生活，还是跨度巨大的积极探索）。
        3. 洞察：总结出这段时间潜藏的“生活逻辑”或“情感底色”。
        4. 篇幅：80字左右，表达清晰且具有现代感。
        5. 杜绝数字罗列，将枯燥的统计转化为对生活步调的敏锐观察。
        """
        
        OpenAIService.shared.getCustomSummary(prompt: prompt) { summary in
            // 竞态过滤
            guard rangeAtStart == self.selectedRange else { return }
            
            withAnimation {
                let finalized = summary ?? "这段时间，你更倾向于在熟悉的领域深耕，生活步调稳健而有序。"
                self.aiSummary = finalized
                
                // Save to persistent cache
                let cacheItem: [String: Any] = [
                    "text": finalized,
                    "timestamp": Date().timeIntervalSince1970
                ]
                self.summaryCache[rangeAtStart.rawValue] = cacheItem
                UserDefaults.standard.set(self.summaryCache, forKey: "statistics_ai_cache")
                
                self.isGeneratingSummary = false
            }
        }
    }
    
    private func updateMapPosition() {
        let all = filteredFootprints
        guard !all.isEmpty else { return }
        
        // 性能优化：如果数据量极大，进行等距抽样（最多取1000个点用于计算缩放，精度已足够）
        let step = max(1, all.count / 1000)
        var coords: [CLLocationCoordinate2D] = []
        for i in stride(from: 0, to: all.count, by: step) {
            let fp = all[i]
            coords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
        }
        
        withAnimation(.easeInOut(duration: 1.0)) {
            let region = getRegion(for: coords)
            mapPosition = .region(region)
        }
    }
    
    private func getRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        
        let delta = max(0.015, (lats.max()! - lats.min()!) * 1.6)
        let deltaLon = max(0.015, (lons.max()! - lons.min()!) * 1.6)
        
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: deltaLon))
    }
    
    // MARK: - Sticky Header
    private var stickyHeader: some View {
        VStack(spacing: 0) {
            rangePicker
                .padding(.vertical, 12)
                .background(Color.dfkBackground.opacity(0.95))
            Divider().opacity(0.5)
        }
    }
    
    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(StatisticsRange.allCases, id: \.self) { range in
                Text(range.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedRange == range ? .white : .secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        ZStack {
                            if selectedRange == range {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.dfkAccent)
                                    .matchedGeometryEffect(id: "range_bg", in: rangeNamespace)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedRange = range
                        }
                    }
            }
        }
        .padding(4)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal, 20)
    }
    
    // MARK: - Heatmap Section (Thermal Style)
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("常去地点", icon: "map.fill")
            
            let topLocations = getTopLocations()
            
            if topLocations.isEmpty {
                placeholderView("暂无地点数据")
            } else {
                let maxIntensity = topLocations.map { $0.count }.max() ?? 1
                Map(position: $mapPosition) {
                    ForEach(topLocations, id: \.hash) { loc in
                        Annotation("", coordinate: loc.coord) {
                            ThermalBlipView(intensity: loc.count, maxIntensity: maxIntensity)
                        }
                    }
                }
                .frame(height: 280)
                .cornerRadius(24)
                .padding(.horizontal, 16)
            }
        }
    }
    
    struct ThermalBlipView: View {
        let intensity: Int
        let maxIntensity: Int
        
        var body: some View {
            let ratio = Double(intensity) / Double(max(1, maxIntensity))
            // Orange (Low) -> Red (Medium) -> Purple (High)
            let color: Color = ratio < 0.3 ? .orange : (ratio < 0.7 ? .red : .purple)
            
            ZStack {
                // Outer glow
                let size = CGFloat(max(25, min(120, intensity * 8)))
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: size/2))
                    .frame(width: size, height: size)
                    .blur(radius: size/12)
                
                // Core
                let coreSize = CGFloat(max(8, min(40, intensity * 3)))
                Circle()
                    .fill(RadialGradient(colors: [color, color.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: coreSize/2))
                    .frame(width: coreSize, height: coreSize)
                    .blur(radius: coreSize/15)
            }
        }
    }
    
    // MARK: - Activity Rank Section
    private var activityRankSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("活动偏好排行", icon: "medal.fill")
            
            let data = getActivityRankData()
            let maxCount = data.first?.count ?? 1
            
            if data.isEmpty {
                placeholderView("暂无活动数据")
            } else {
                VStack(spacing: 16) {
                    ForEach(data) { item in
                        HStack(spacing: 12) {
                            // Icon + Name
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(item.color)
                                    .frame(width: 20)
                                Text(item.name)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .frame(width: 80, alignment: .leading)
                            
                            // Horizontal Bar
                            GeometryReader { geo in
                                let width = geo.size.width * CGFloat(item.count) / CGFloat(maxCount)
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(item.color.gradient)
                                    .frame(width: max(6, width))
                            }
                            .frame(height: 12)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 24)
                .background(Color.white.opacity(0.05))
                .cornerRadius(24)
                .padding(.horizontal, 16)
            }
        }
    }
    
    // MARK: - Trend Section
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("生活活跃趋势", icon: "chart.line.uptrend.xyaxis")
            
            let data = getTrendData()
            
            if data.isEmpty {
                placeholderView("数据加载中...")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Chart {
                        ForEach(data) { item in
                            AreaMark(
                                x: .value("日期", item.date, unit: .day),
                                y: .value("活跃度", item.score)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.dfkAccent.opacity(0.3), Color.dfkAccent.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)
                            
                            LineMark(
                                x: .value("日期", item.date, unit: .day),
                                y: .value("活跃度", item.score)
                            )
                            .foregroundStyle(Color.dfkAccent.gradient)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartXAxis {
                        switch selectedRange {
                        case .last7Days:
                            AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month().day())
                                    .font(.system(size: 9))
                            }
                        case .last30Days:
                            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month().day())
                                    .font(.system(size: 9))
                            }
                        case .last90Days:
                            AxisMarks(values: .stride(by: .day, count: 15)) { _ in
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month().day())
                                    .font(.system(size: 9))
                            }
                        case .lastYear, .all:
                            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month())
                                    .font(.system(size: 9))
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 180)
                    .padding(.horizontal, 8)
                    
                    Text("数据说明：综合了你的出行频率、去过的地方和拍下的照片")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.leading, 12)
                }
                .padding(.vertical, 20)
                .background(Color.white.opacity(0.05))
                .cornerRadius(24)
                .padding(.horizontal, 16)
            }
        }
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.dfkAccent)
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
    
    private func placeholderView(_ text: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 30))
                    .foregroundColor(.gray.opacity(0.3))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }
    
    // MARK: - Data Helpers
    
    struct LocationPoint {
        let hash: String
        let coord: CLLocationCoordinate2D
        let count: Int
    }
    
    private func getTopLocations() -> [LocationPoint] {
        var groups: [String: (CLLocationCoordinate2D, Int)] = [:]
        
        for fp in filteredFootprints {
            // Round to ~200m precision to create better "heat" clusters
            let lat = Double(String(format: "%.3f", fp.latitude))!
            let lon = Double(String(format: "%.3f", fp.longitude))!
            let key = "\(lat),\(lon)"
            if let existing = groups[key] {
                groups[key] = (existing.0, existing.1 + 1)
            } else {
                groups[key] = (CLLocationCoordinate2D(latitude: lat, longitude: lon), 1)
            }
        }
        
        return groups.map { LocationPoint(hash: $0.key, coord: $0.value.0, count: $0.value.1) }
            .sorted { $0.count > $1.count }
            .prefix(30)
            .map { $0 }
    }
    
    private func getRegion(for points: [LocationPoint]) -> MKCoordinateRegion {
        if points.isEmpty { return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4), span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)) }
        
        let lats = points.map { $0.coord.latitude }
        let lons = points.map { $0.coord.longitude }
        
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        
        let delta = max(0.015, (lats.max()! - lats.min()!) * 1.8)
        let deltaLon = max(0.015, (lons.max()! - lons.min()!) * 1.8)
        
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: deltaLon))
    }
    
    struct RankItem: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let color: Color
        let icon: String
    }
    
    private func getActivityRankData() -> [RankItem] {
        var counts: [String: Int] = [:]
        for fp in filteredFootprints {
            if let type = fp.getActivityType(from: activityTypes)?.name {
                counts[type, default: 0] += 1
            }
        }
        
        return counts.map { name, count in
            let activity = activityTypes.first { $0.name == name }
            let color = activity?.color ?? .gray
            let icon = activity?.icon ?? "mappin.and.ellipse"
            return RankItem(name: name, count: count, color: color, icon: icon)
        }.sorted { $0.count > $1.count }
    }
    
    struct TrendItem: Identifiable {
        let id = UUID()
        let date: Date
        let score: Double
    }
    
    private func getTrendData() -> [TrendItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let days: Int
        if let rangeDays = selectedRange.days {
            days = rangeDays
        } else {
            // "全部" 模式：计算最早足迹到今天的天数
            if let earliest = filteredFootprints.last?.startTime {
                let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: today).day ?? 0
                days = max(1, diff + 1)
            } else {
                days = 90
            }
        }
        
        var points: [TrendItem] = []
        let grouped = Dictionary(grouping: filteredFootprints) { calendar.startOfDay(for: $0.startTime) }
        
        for i in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            let dayFootprints = grouped[date] ?? []
            
            let uniqueTypes = Set(dayFootprints.compactMap { $0.activityTypeValue }).count
            let photoCount = dayFootprints.reduce(0) { $0 + $1.photoAssetIDs.count }
            
            let baseScore = Double(dayFootprints.count * 10) + Double(uniqueTypes * 15) + Double(min(photoCount, 50))
            points.append(TrendItem(date: date, score: baseScore))
        }
        
        return points
    }
}
