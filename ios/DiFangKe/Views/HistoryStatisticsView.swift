import SwiftUI
import SwiftData
import Charts
import MapKit

enum StatisticsRange: Hashable {
    case last7Days
    case last30Days
    case last90Days
    case lastYear
    case customYear(Int)
    
    var rawValue: String {
        switch self {
        case .last7Days: return "7天"
        case .last30Days: return "30天"
        case .last90Days: return "90天"
        case .lastYear: return "1年"
        case .customYear(let y): return String(y)
        }
    }
    
    var days: Int? {
        switch self {
        case .last7Days: return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .lastYear: return 365
        default: return nil
        }
    }
}

struct HistoryStatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    
    @State private var allFootprints: [Footprint] = []
    @State private var manualTransports: [TransportManualSelection] = []
    @State private var activityTypes: [ActivityType] = []
    @State private var allPlaces: [Place] = []
    
    @State private var selectedRange: StatisticsRange = .last30Days
    @State private var appearanceTrigger = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapDelta: Double = 0.1
    @State private var heatmapPoints: [DFKMapView.HeatmapPoint] = []
    
    // AI Summary State
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var aiSummary: String? = nil
    @State private var isGeneratingSummary = false
    // Cache structure: [RangeRawValue: (text: String, timestamp: Double)]
    @State private var summaryCache: [String: [String: Any]] = (UserDefaults.standard.dictionary(forKey: "statistics_ai_cache") as? [String: [String: Any]]) ?? [:]
    
    @State private var showingFullMap = false
    @State private var activeYearForSegment: Int = Calendar.current.component(.year, from: Date())
    
    // Filtered footprints based on range
    private var filteredFootprints: [Footprint] {
        let calendar = Calendar.current
        switch selectedRange {
        case .last7Days:
            let cutoff = calendar.date(byAdding: .day, value: -7, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .last30Days:
            let cutoff = calendar.date(byAdding: .day, value: -30, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .last90Days:
            let cutoff = calendar.date(byAdding: .day, value: -90, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .lastYear:
            let cutoff = calendar.date(byAdding: .day, value: -365, to: Date())!
            return allFootprints.filter { $0.startTime >= cutoff }
        case .customYear(let year):
            return allFootprints.filter { calendar.component(.year, from: $0.startTime) == year }
        }
    }
    
    private var availableYears: [Int] {
        let years = Set(allFootprints.map { Calendar.current.component(.year, from: $0.startTime) })
        return years.sorted(by: >)
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
            fetchData()
            updateAiSummary()
            updateMapPosition()
            withAnimation(.easeIn(duration: 0.6)) {
                appearanceTrigger = true
            }
        }
        .fullScreenCover(isPresented: $showingFullMap) {
            FullHeatmapView(heatmapPoints: heatmapPoints, initialPosition: mapPosition)
        }
    }
    
    // MARK: - AI Summary Section
    private var aiSummarySection: some View {
        Group {
            if let summary = aiSummary {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(summary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                        .lineSpacing(6)
                    
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        generateAiSummary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
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
                .padding(.bottom, 12)
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
        case .last7Days: return 1 * day
        case .last30Days: return 3 * day
        case .last90Days: return 7 * day
        case .lastYear, .customYear: return 30 * day
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
        let rankData = getActivityRankData().prefix(3).map { "\($0.name)(\($0.count)次)" }.joined(separator: ", ")
        let topPlacesCount = getTopLocations(delta: 0.01).prefix(3).count
        
        // 寻找主要地点分组
        let validPlaces = Dictionary(grouping: footprintsInScope) { fp -> String in
            let addr = fp.address ?? ""
            if addr.isEmpty { return "" }
            return addr.components(separatedBy: "市").last?.components(separatedBy: "区").last?.components(separatedBy: "县").last ?? addr
        }
        .filter { $0.key.count > 1 && !$0.key.contains("未知") }
        .sorted { $0.value.count > $1.value.count }
        .prefix(5)
        
        // 提取时间跨度描述
        let timeSpanText: String
        switch rangeAtStart {
        case .last7Days: timeSpanText = "最近7天"
        case .last30Days: timeSpanText = "最近1个月"
        case .last90Days: timeSpanText = "最近3个月"
        case .lastYear: timeSpanText = "过去一年"
        case .customYear(let year): timeSpanText = "\(year)年"
        }
        
        // 提前在主线程筛选出有自定义标签的重要地点足迹
        var userPlaceCounts: [String: Int] = [:]
        for fp in footprintsInScope {
            if let pID = fp.placeID, let place = allPlaces.first(where: { $0.placeID == pID }), place.isUserDefined, !place.name.isEmpty {
                userPlaceCounts[place.name, default: 0] += 1
            }
        }
        
        Task {
            // 构建需要反查的代表性足迹列表
            var repsToGeocode: [Footprint] = []
            
            // 1. 全局 55km 网格抽样 (保障广度)
            var uniqueGrids: [String: Footprint] = [:]
            for fp in footprintsInScope {
                let key = "\(Int(fp.latitude * 2))_\(Int(fp.longitude * 2))"
                if uniqueGrids[key] == nil {
                    uniqueGrids[key] = fp
                    repsToGeocode.append(fp)
                }
            }
            repsToGeocode = Array(repsToGeocode.prefix(8))
            
            // 2. Top 5 地点的代表足迹 (保障精度)
            for placeGroup in validPlaces {
                if let firstFp = placeGroup.value.first {
                    if !repsToGeocode.contains(where: { $0.footprintID == firstFp.footprintID }) {
                        repsToGeocode.append(firstFp)
                    }
                }
            }
            
            let geocoder = CLGeocoder()
            var fpToCity: [UUID: String] = [:]
            var fpToCountry: [UUID: String] = [:]
            
            for fp in repsToGeocode {
                let location = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
                   let placemark = placemarks.first {
                    var bestCityName: String? = nil
                    
                    // 1. 优先提取区县级 (如果是县级市、县等具备独立城市属性的区域)
                    if let subLocality = placemark.subLocality, 
                       (subLocality.hasSuffix("市") || subLocality.hasSuffix("县") || subLocality.hasSuffix("州") || subLocality.hasSuffix("旗") || subLocality.hasSuffix("盟")) {
                        bestCityName = subLocality
                    } 
                    // 2. 否则使用地级市
                    else if let locality = placemark.locality {
                        bestCityName = locality
                    } 
                    // 3. 直辖市兜底
                    else if let adminArea = placemark.administrativeArea {
                        bestCityName = adminArea
                    }
                    
                    if let city = bestCityName {
                        fpToCity[fp.footprintID] = city
                    }
                    if let country = placemark.country {
                        fpToCountry[fp.footprintID] = country
                    }
                }
            }
            
            // 提取所有涉及的城市和国家
            let citiesArray = Array(Set(fpToCity.values)).sorted()
            let countriesArray = Array(Set(fpToCountry.values)).sorted()
            
            let citiesStr = citiesArray.prefix(3).joined(separator: "、")
            let countriesStr = countriesArray.prefix(3).joined(separator: "、")
            let hasMultipleCities = citiesArray.count > 1
            let hasMultipleCountries = countriesArray.count > 1
            let isCrossRegion = hasMultipleCities || hasMultipleCountries
            
            var scopeContexts: [String] = []
            if hasMultipleCountries { scopeContexts.append("\(countriesStr)等多个国家") }
            else if !countriesArray.isEmpty && countriesArray.first != "中国" { scopeContexts.append("\(countriesStr)") }
            
            if hasMultipleCities { scopeContexts.append("\(citiesStr)等多个城市") }
            
            let scopeContext = scopeContexts.isEmpty ? "" : "- 范围：跨越了\(scopeContexts.joined(separator: "，"))\n"
            
            // 将地点按所属城市分组
            var cityToPlaces: [String: [String]] = [:]
            for placeGroup in validPlaces {
                let placeName = placeGroup.key
                let count = placeGroup.value.count
                let firstFp = placeGroup.value.first!
                
                let city = fpToCity[firstFp.footprintID] ?? "未知区域"
                cityToPlaces[city, default: []].append("\(placeName)(\(count)次)")
            }
            let topNamesGrouped = cityToPlaces.map { "\($0.key)的\($0.value.joined(separator: "、"))" }.joined(separator: "；")
            
            // 提取重要节点 (所有用户自定义标签)
            let topUserPlaces = userPlaceCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key)(\($0.value)次)" }
            
            let importantContext = topUserPlaces.isEmpty ? "" : "- 核心节点：\(topUserPlaces.joined(separator: "，"))\n"
            
            // 增补更丰富的信息维度
            let totalDuration = footprintsInScope.reduce(0) { $0 + $1.duration }
            let durationHours = Int(totalDuration / 3600)
            let totalPhotos = footprintsInScope.reduce(0) { $0 + $1.photoAssetIDs.count }
            
            let timeRequirement = "3. **贴合时间跨度**：当前总结的时间跨度是“\(timeSpanText)”。绝不要笼统地说“最近”，请在文中自然地体现出这个时间范围（如“这\(timeSpanText)里”、“在整个\(timeSpanText)中”）。"
            
            let locationRequirement = isCrossRegion 
                ? "4. **提及跨地域与地标**：你的足迹跨越了不同的城市或国家，请在总结中自然地提及你的跨城/跨国节奏（如：\(citiesArray.first ?? "")），并带出一两个具体地点（如：\(validPlaces.first?.key ?? "某地")）。"
                : "4. **必须提及地名**：在总结中必须自然地提及一到两个你最常去的具体地点名称（如：\(validPlaces.first?.key ?? "某地")），增加专属感。"
                
            let visionRequirement = isCrossRegion
                ? "5. **视角与格局**：因为活动跨越了不同地域，请用相对广阔的视角，体现出你穿梭于不同城市间的活力、充实或奔波。"
                : "5. **视角与格局**：因为活动集中在一地，请用贴近生活的微观视角，体现出你在熟悉街区里深耕日常的规律与踏实。"
            
            let prompt = """
            请作为读者的老朋友，直接对着读者本人说话，帮他回顾这段时间的生活。
            
            数据事实：
            - 时间跨度：\(timeSpanText)
            \(scopeContext)\(importantContext)        - 密度：\(footprintsInScope.count)次记录，约\(durationHours)小时的停留
            - 偏好：主要活动包含\(rankData)
            - 广度：在\(topPlacesCount)个区域活动频繁（常去：\(topNamesGrouped)）
            - 影像：拍了\(totalPhotos)张照片
            
            撰写要求：
            1. **严格第二人称**：必须全程使用“你”、“你的”来称呼读者。绝对禁止在文中出现“我”、“我的”、“他”、“她”，不要写成日记口吻，必须是你在对朋友说话的口吻。
            2. **禁止堆砌数字**：严禁直接输出干巴巴的统计数字（如“50次”、“80小时”），要把数字转化为日常的描述（如“经常去”、“待了很久”、“拍了不少照片”）。不要用太文艺肉麻的词汇。
            \(timeRequirement)
            \(locationRequirement)
            \(visionRequirement)
            6. **多维推理**：如果照片多，可以说你喜欢记录；如果地点分散，说明你经常到处跑；如果集中，说明生活比较规律安稳。
            7. **语言与篇幅**：80字左右。语气必须平实、正常、干练，绝对不要过度抒情，绝对不要写得太文绉绉、不要肉麻。
            """
            
            OpenAIService.shared.getCustomSummary(prompt: prompt) { summary in
                // 竞态过滤
                guard rangeAtStart == self.selectedRange else { return }
                
                withAnimation {
                    let finalized = summary ?? ""
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
            mapDelta = region.span.latitudeDelta
            updateHeatmapPoints(delta: region.span.latitudeDelta)
        }
    }
    
    private func updateHeatmapPoints(delta: Double) {
        let locations = getTopLocations(delta: delta)
        let maxIntensity = locations.map { $0.count }.max() ?? 1
        let newPoints = locations.map { DFKMapView.HeatmapPoint(coordinate: $0.coord, intensity: $0.count, maxIntensity: maxIntensity) }
        
        // 只有当聚类点发生较大变化或首次加载时才更新
        if heatmapPoints.count != newPoints.count || heatmapPoints.first?.id != newPoints.first?.id {
            withAnimation(.easeOut(duration: 0.3)) {
                heatmapPoints = newPoints
            }
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
        Picker("时间范围", selection: $selectedRange) {
            Text("7天").tag(StatisticsRange.last7Days)
            Text("30天").tag(StatisticsRange.last30Days)
            Text("90天").tag(StatisticsRange.last90Days)
            Text("1年").tag(StatisticsRange.lastYear)
            Text(isCustomYear ? "\(String(activeYearForSegment)) ▾" : "年份 ▾").tag(StatisticsRange.customYear(activeYearForSegment))
        }
        .pickerStyle(.segmented)
        .overlay(
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                    if !availableYears.isEmpty {
                        Menu {
                            ForEach(availableYears, id: \.self) { year in
                                Button(String(year)) {
                                    activeYearForSegment = year
                                    selectedRange = .customYear(year)
                                }
                            }
                        } label: {
                            Color.white.opacity(0.001) // 完全透明，用于拦截第五个分段的点击
                        }
                        .frame(width: geo.size.width / 5)
                    }
                }
            }
        )
        .padding(.horizontal, 20)
        .onAppear {
            if activeYearForSegment == Calendar.current.component(.year, from: Date()) && !availableYears.isEmpty {
                activeYearForSegment = availableYears.first ?? Calendar.current.component(.year, from: Date())
            }
        }
    }
    
    private var isCustomYear: Bool {
        if case .customYear = selectedRange { return true }
        return false
    }
    

    
    // MARK: - Heatmap Section (Thermal Style)
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("热点地区", icon: "map.fill")
            
            if heatmapPoints.isEmpty {
                placeholderView("暂无地点数据")
            } else {
                DFKMapView(
                    cameraPosition: $mapPosition,
                    isInteractive: false,
                    showsUserLocation: false,
                    heatmapPoints: heatmapPoints
                )
                .onMapCameraChange(frequency: .onEnd) { context in
                    // 地图缩放变化时，动态重新聚类
                    updateHeatmapPoints(delta: context.region.span.latitudeDelta)
                }
                .frame(height: 280)
                .cornerRadius(24)
                .padding(.horizontal, 16)
                .onTapGesture {
                    showingFullMap = true
                }
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
                                    .font(.system(size: 16))
                                    .foregroundColor(item.color)
                                    .frame(width: 22)
                                Text(item.name)
                                    .font(.system(size: 15, weight: .medium))
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
                        case .lastYear, .customYear:
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
    
    private func getTopLocations(delta: Double) -> [LocationPoint] {
        var groups: [String: (Double, Double, Int)] = [:]
        
        // 根据地图缩放程度（delta）动态调整聚合精度
        // 越缩小（delta 越大），聚合范围越广
        let precision: Int
        if delta < 0.05 { precision = 3 }      // 约 110m 精度
        else if delta < 0.5 { precision = 2 }   // 约 1.1km 精度
        else if delta < 5.0 { precision = 1 }   // 约 11km 精度
        else { precision = 0 }                  // 约 110km 精度
        
        let factor = pow(10.0, Double(precision))
        
        for fp in filteredFootprints {
            // 使用舍入计算网格点，而非字符串格式化，性能更优
            let lat = (fp.latitude * factor).rounded() / factor
            let lon = (fp.longitude * factor).rounded() / factor
            let key = "\(lat),\(lon)"
            
            if let existing = groups[key] {
                groups[key] = (lat, lon, existing.2 + 1)
            } else {
                groups[key] = (lat, lon, 1)
            }
        }
        
        return groups.map { LocationPoint(hash: $0.key, coord: CLLocationCoordinate2D(latitude: $0.value.0, longitude: $0.value.1), count: $0.value.2) }
            .sorted { 
                if $0.count == $1.count {
                    return $0.hash < $1.hash
                }
                return $0.count > $1.count 
            }
            .prefix(200) // 聚合后点数减少，可以适当放宽显示上限
            .map { $0 }
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
        
        // 1. 统计驻留活动 (Stays/Footprints)
        for fp in filteredFootprints {
            if let type = fp.getActivityType(from: activityTypes)?.name {
                counts[type, default: 0] += 1
            }
        }
        
        // 2. 统计交通活动 (Manual Transports)
        // 注意：自动识别的交通目前未持久化为单个对象，此处先计入用户手动确认或修改的交通
        let calendar = Calendar.current
        let rangeFilteredTransports = manualTransports.filter { transport in
            switch selectedRange {
            case .last7Days:
                let cutoff = calendar.date(byAdding: .day, value: -7, to: Date())!
                return transport.startTime >= cutoff
            case .last30Days:
                let cutoff = calendar.date(byAdding: .day, value: -30, to: Date())!
                return transport.startTime >= cutoff
            case .last90Days:
                let cutoff = calendar.date(byAdding: .day, value: -90, to: Date())!
                return transport.startTime >= cutoff
            case .lastYear:
                let cutoff = calendar.date(byAdding: .day, value: -365, to: Date())!
                return transport.startTime >= cutoff
            case .customYear(let year):
                return calendar.component(.year, from: transport.startTime) == year
            }
        }
        
        for transport in rangeFilteredTransports {
            if let type = TransportType(rawValue: transport.vehicleType) {
                counts[type.localizedName, default: 0] += 1
            }
        }
        
        return counts.map { name, count in
            // 优先匹配预定义活动
            if let activity = activityTypes.first(where: { $0.name == name }) {
                return RankItem(name: name, count: count, color: activity.color, icon: activity.icon)
            }
            
            // 匹配交通工具类型
            if let transportType = TransportType.allCases.first(where: { $0.localizedName == name }) {
                return RankItem(name: name, count: count, color: .dfkAccent, icon: transportType.sfSymbol)
            }
            
            return RankItem(name: name, count: count, color: .gray, icon: "mappin.and.ellipse")
        }.sorted { 
            if $0.count == $1.count {
                return $0.name < $1.name
            }
            return $0.count > $1.count 
        }
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
        let endDate: Date
        
        if let rangeDays = selectedRange.days {
            days = rangeDays
            endDate = today
        } else if case .customYear(let year) = selectedRange {
            if year == calendar.component(.year, from: today) {
                let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                days = calendar.dateComponents([.day], from: startOfYear, to: today).day ?? 1
                endDate = today
            } else {
                let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                let endOfYear = calendar.date(from: DateComponents(year: year, month: 12, day: 31))!
                days = calendar.dateComponents([.day], from: startOfYear, to: endOfYear).day ?? 365
                endDate = endOfYear
            }
        } else {
            days = 30
            endDate = today
        }
        
        var points: [TrendItem] = []
        let grouped = Dictionary(grouping: filteredFootprints) { calendar.startOfDay(for: $0.startTime) }
        
        for i in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -i, to: endDate) else { continue }
            let dayFootprints = grouped[date] ?? []
            
            let uniqueTypes = Set(dayFootprints.compactMap { $0.activityTypeValue }).count
            let photoCount = dayFootprints.reduce(0) { $0 + $1.photoAssetIDs.count }
            
            let baseScore = Double(dayFootprints.count * 10) + Double(uniqueTypes * 15) + Double(min(photoCount, 50))
            points.append(TrendItem(date: date, score: baseScore))
        }
        
        return points
    }
    
    private func fetchData() {
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate<Footprint> { $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\Footprint.startTime, order: .reverse)]
        )
        if let fetched = try? modelContext.fetch(footprintDescriptor) {
            allFootprints = fetched
        }
        
        let transportDescriptor = FetchDescriptor<TransportManualSelection>(
            predicate: #Predicate<TransportManualSelection> { $0.isDeleted == false }
        )
        if let fetched = try? modelContext.fetch(transportDescriptor) {
            manualTransports = fetched
        }
        
        let activityDescriptor = FetchDescriptor<ActivityType>(
            sortBy: [SortDescriptor(\ActivityType.sortOrder)]
        )
        if let fetched = try? modelContext.fetch(activityDescriptor) {
            activityTypes = fetched
        }
        
        let placeDescriptor = FetchDescriptor<Place>()
        if let fetched = try? modelContext.fetch(placeDescriptor) {
            allPlaces = fetched
        }
    }
}

struct FullHeatmapView: View {
    @Environment(\.dismiss) private var dismiss
    let heatmapPoints: [DFKMapView.HeatmapPoint]
    let initialPosition: MapCameraPosition
    
    @State private var position: MapCameraPosition
    @State private var maxIntensity: Int
    
    init(heatmapPoints: [DFKMapView.HeatmapPoint], initialPosition: MapCameraPosition) {
        self.heatmapPoints = heatmapPoints
        self.initialPosition = initialPosition
        self._position = State(initialValue: initialPosition)
        self._maxIntensity = State(initialValue: heatmapPoints.map { $0.intensity }.max() ?? 1)
    }
    
    var body: some View {
        NavigationStack {
            DFKMapView(
                cameraPosition: $position,
                isInteractive: true,
                showsUserLocation: true,
                heatmapPoints: heatmapPoints
            )
            .navigationTitle("热点地区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
        }
    }
}

struct HistoryStatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryStatisticsView()
    }
}
