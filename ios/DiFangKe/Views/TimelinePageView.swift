import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import Photos

struct TimelinePageView: View {
    @Environment(\.modelContext) private var modelContext
    let date: Date
    let footprints: [Footprint]
    let manualSelections: [TransportManualSelection]
    let allPlaces: [Place]
    let offset: Int
    let locationManager: LocationManager
    let pastLimitOffset: Int
    let isFromHistory: Bool
    @Query private var pageInsights: [DailyInsight]
    
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
    
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    
    @State private var timelineItems: [TimelineItem]
    @State private var isLoadingTimeline: Bool
    @State private var refreshTask: Task<Void, Never>?
    @State private var appearanceTask: Task<Void, Never>?
    
    @State private var totalPointsCount: Int = 0
    @State private var trajectoryPoints: [CLLocationCoordinate2D] = []
    @State private var totalDailyMileage: Double = 0
    @State private var dayPhotoAssets: [PHAsset] = []
    
    init(date: Date, footprints: [Footprint], manualSelections: [TransportManualSelection], allPlaces: [Place], offset: Int, locationManager: LocationManager, pastLimitOffset: Int, isFromHistory: Bool = false) {
        self.date = date
        let start = Calendar.current.startOfDay(for: date)
        _pageInsights = Query(filter: #Predicate<DailyInsight> { insight in
            insight.date == start
        })
        
        self.footprints = footprints
        self.manualSelections = manualSelections
        self.allPlaces = allPlaces
        self.offset = offset
        self.locationManager = locationManager
        self.pastLimitOffset = pastLimitOffset
        self.isFromHistory = isFromHistory
        
        let cached = TimelineBuilder.timelineCache[date] ?? []
        // 初始化时立即执行重链接，确保首次渲染就是数据库真实模型
        let linkedItems = cached.map { item -> TimelineItem in
            if case .footprint(let tempFp) = item {
                if let realFp = footprints.first(where: { $0.footprintID == tempFp.footprintID }) {
                    return .footprint(realFp)
                }
            }
            return item
        }
        
        self._timelineItems = State(initialValue: linkedItems)
        self._isLoadingTimeline = State(initialValue: cached.isEmpty)
    }
    
    var body: some View {
        timelineScrollView
        .onAppear {
            appearanceTask?.cancel()
            appearanceTask = Task { @MainActor in
                // 只有停留超过 400ms 才开始业务逻辑，防止快速划过时的卡顿
                try? await Task.sleep(nanoseconds: AppConfig.shared.uiDebounceIntervalNS)
                if Task.isCancelled { return }
                
                NotificationManager.shared.getAuthorizationStatus { status in
                    self.notificationAuthStatus = status
                }
                
                // 即使已有缓存数据，也要执行刷新任务以加载原始轨迹路径（Trajectory Points）和照片
                refreshTimeline()
                
                // AI 每日摘要检查：仅在缺失时静默生成，不强制刷新
                let currentSummary = pageInsights.first?.content
                if isAiAssistantEnabled && !footprints.isEmpty && (currentSummary == nil || currentSummary?.isEmpty == true) {
                    let startOfDate = Calendar.current.startOfDay(for: date)
                    if startOfDate < Calendar.current.startOfDay(for: Date()) {
                        let endOfDate = Calendar.current.date(byAdding: .day, value: 1, to: startOfDate)!
                        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                            $0.startTime >= startOfDate && $0.startTime < endOfDate && $0.statusRaw == "active"
                        })
                        let transports = (try? modelContext.fetch(tpDesc)) ?? []
                        OpenAIService.shared.enqueueDailySummary(for: date, footprints: footprints, transports: transports)
                    }
                }
                
                checkDeepLink(targetID: locationManager.deepLinkFootprintID)
            }
        }
        .onDisappear {
            appearanceTask?.cancel()
            refreshTask?.cancel()
        }
        .onChange(of: footprints) { _, _ in
            // 安全刷新：仅重新获取数据库内容刷新 UI，不触发 syncDay 算法，彻底杜绝死循环
            let items = PersistentTimelineBuilder.fetchTimeline(for: date, in: modelContext)
            self.timelineItems = items
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in
            // 当后台完成活动匹配时，仅刷新 UI，不触发 AI 重新总结
            refreshTimeline(force: false)
        }
        .onChange(of: locationManager.lastRawDataUpdateTrigger) { _, _ in refreshTimeline(force: false) }
        .sheet(item: $selectedFootprint) { footprint in
            FootprintModalView(
                footprint: footprint, 
                autoFocus: autoFocusOnOpen,
                onDismiss: { didChange in
                    autoFocusOnOpen = false
                    refreshTimeline(force: false)
                    if didChange && isAiAssistantEnabled {
                        Task {
                            await refreshAiSummary(force: true)
                        }
                    }
                })
            .environment(locationManager)
        }
        .sheet(isPresented: $showingAddPlaceSheet) {
            AddPlaceSheet(initialCoordinate: locationManager.lastLocation?.coordinate, 
                          initialName: locationManager.currentAddress) { newPlace in
                modelContext.insert(newPlace)
                try? modelContext.save()
                CloudSettingsManager.shared.triggerDataSyncPulse()
            }
        }
        .sheet(item: $selectedTransport) { transport in
            TransportModalView(transport: transport) { newType in
                // --- 核心修复：直接将修改持久化到数据库，而不是仅修改内存 ---
                let targetId = transport.id
                let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == targetId })
                if let records = try? modelContext.fetch(descriptor), let record = records.first {
                    record.manualTypeRaw = newType.rawValue
                    record.typeRaw = newType.rawValue
                    try? modelContext.save()
                }
                
                // 仅刷新 UI 展示，严禁 force: true 触发算法重整全天
                refreshTimeline(force: false)
            } onLocationUpdate: {
                refreshTimeline(force: true)
            }
            .environment(locationManager)
        }
        .onChange(of: locationManager.deepLinkFootprintID) { _, newValue in
            checkDeepLink(targetID: newValue)
        }
    }
    
    // 过滤掉与当前正在进行的实时停留重合的足迹，避免双重视图
    private var filteredTimelineItems: [TimelineItem] {
        self.timelineItems
    }
    
    private var timelineScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
                
                if offset > 0 {
                    futurePlaceholderView
                        .padding(.horizontal, 24)
                } else if offset == pastLimitOffset {
                    pastPlaceholderView
                        .padding(.horizontal, 24)
                } else {
                    summaryCardSection(isToday: isToday)
                    timelineListSection(isToday: isToday)
                    
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
        .refreshable {
            await handlePullToRefresh()
        }
    }

    
    @ViewBuilder
    private func summaryCardSection(isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isToday {
                RecordingStatusCard(
                    locationManager: locationManager, 
                    footprintCount: footprints.count,
                    timelineItems: filteredTimelineItems,
                    onTimelineItemTap: handleTimelineItemTap,
                    photoAssets: dayPhotoAssets
                )
                .padding(.horizontal, 16)
            } else {
                    DaySummaryCard(
                        date: date,
                        totalPoints: totalPointsCount,
                        footprintCount: filteredTimelineItems.filter { if case .footprint = $0 { return true }; return false }.count,
                        totalMileage: totalDailyMileage,
                        points: trajectoryPoints,
                    timelineItems: filteredTimelineItems,
                    onTimelineItemTap: handleTimelineItemTap,
                    photoAssets: dayPhotoAssets,
                    summary: pageInsights.first?.content,
                    isLoading: isLoadingTimeline
                )
                .padding(.horizontal, 16)
            }
            
            if isToday && timelineItems.isEmpty && !isLoadingTimeline {
                PlaceholderFootprintCard()
                    .padding(.horizontal, 0)
            }
            
            if allPlaces.isEmpty && !isGuideDismissed {
                ImportantPlaceGuide(isGuideDismissed: $isGuideDismissed) {
                    showingAddPlaceSheet = true
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            
            if !isNotificationGuideDismissed && isToday && notificationAuthStatus == .notDetermined {
                NotificationGuide(isNotificationGuideDismissed: $isNotificationGuideDismissed)
                    .padding(.top, allPlaces.isEmpty && !isGuideDismissed ? 0 : 20)
                    .padding(.bottom, 20)
            }
        }
    }
    
    @ViewBuilder
    private func timelineListSection(isToday: Bool) -> some View {
        if footprints.isEmpty && timelineItems.isEmpty && dayPhotoAssets.isEmpty && (!isToday || locationManager.potentialStopStartLocation == nil) {
            if allPlaces.isEmpty && isToday && !isGuideDismissed {
                EmptyView()
            } else if !isLoadingTimeline {
                emptyStateView
            }
        } else {
            let items = filteredTimelineItems
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
                        allPlaces: allPlaces,
                        isFirst: index == 0,
                        isLast: index == count - 1,
                        isToday: isToday,
                        onSelect: { selected in
                            self.selectedTransport = selected
                        },
                        onDelete: { selected in
                            let targetId = selected.id
                            let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == targetId })
                            if let records = try? modelContext.fetch(descriptor), let record = records.first {
                                record.statusRaw = "ignored"
                            }
                            try? modelContext.save()
                            refreshTimeline(force: true)
                        }
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
    }
    
    private func handleTimelineItemTap(_ item: TimelineItem) {
        switch item {
        case .footprint(let footprint):
            self.selectedFootprint = footprint
        case .transport(let transport):
            self.selectedTransport = transport
        }
    }
    
    @MainActor
    private func refreshTimeline(force: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refreshTimelineAsync(force: force)
        }
    }

    @MainActor
    private func refreshTimelineAsync(force: Bool = false) async {
        let targetDate = date
        let availableRawDates = locationManager.availableRawDates

        let isToday = Calendar.current.isDateInToday(targetDate)
        let hasExistingFootprints = !footprints.isEmpty
        let hasRawData = availableRawDates.contains(Calendar.current.startOfDay(for: targetDate))
        
        if !isToday && !hasExistingFootprints && !hasRawData {
            self.timelineItems = []
            self.isLoadingTimeline = false
            return
        }

        self.isLoadingTimeline = true
        
        defer {
            // 只要异步任务结束（无论成功、取消还是失败），都要确保 loading 状态被置回 false
            self.isLoadingTimeline = false
        }
        
        if Task.isCancelled { return }
        
        // 增量同步逻辑调整：
        // 1. 如果是【强制刷新】（如下拉刷新或重置），必然同步
        // 2. 如果是【今天】，因为数据在实时增加，需要自动同步以显示最新足迹
        // 3. 如果是【过去某天】且数据库【完全没有记录】但有原始轨迹，说明是首次访问该日期，自动同步一次
        // 4. 其他情况（已有记录的历史日期）严禁自动同步，必须由用户手动下拉刷新触发，以保护人工修改结果
        let isDayEmpty = !hasExistingFootprints
        let shouldSync = force || isToday || (isDayEmpty && hasRawData && !isFromHistory)
        
        if shouldSync {
            await PersistentTimelineBuilder.syncDay(date: targetDate, in: modelContext)
        }
        
        if Task.isCancelled { return }
        
        let items = PersistentTimelineBuilder.fetchTimeline(for: targetDate, in: modelContext)
        self.timelineItems = items
        
        let result = await Task.detached(priority: .userInitiated) {
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
            var totalMileage = LocationManager.calculatePathDistance(rawPoints)
            
            // 核心改进：如果没有原始轨迹点（如仅导入了照片），则尝试通过所有足迹点（包含照片生成的足迹）计算直线距离之和
            if totalMileage < 50 && items.count >= 2 {
                var estimatedDist: Double = 0
                let sortedItems = items.sorted { $0.startTime < $1.startTime }
                let fpCoords = sortedItems.compactMap { item -> CLLocation? in
                    if case .footprint(let fp) = item {
                        return CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                    }
                    return nil
                }
                if fpCoords.count >= 2 {
                    for i in 0..<fpCoords.count - 1 {
                        estimatedDist += fpCoords[i].distance(from: fpCoords[i+1])
                    }
                    totalMileage = estimatedDist
                }
            }
            
            let rawCoords = rawPoints.map { $0.coordinate }
            let simplified = LocationManager.simplifyCoordinates(rawCoords, tolerance: 0.00005)
            return (simplified, rawPoints.count, totalMileage)
        }.value
        
        self.trajectoryPoints = result.0
        self.totalPointsCount = result.1
        self.totalDailyMileage = result.2
        
        // 异步加载当天的照片用于地图显示
        let start = Calendar.current.startOfDay(for: targetDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        
        let ignoredFpDesc = FetchDescriptor<Footprint>(predicate: #Predicate { 
            $0.startTime >= start && $0.startTime < end && $0.statusValue == "ignored"
        })
        let ignoredFps = (try? modelContext.fetch(ignoredFpDesc)) ?? []
        let blocklist = Set(ignoredFps.flatMap { $0.photoAssetIDs })

        PhotoService.shared.fetchAssets(startTime: start, endTime: end) { assets in
            let filtered = assets.filter { asset in
                asset.location != nil && !blocklist.contains(asset.localIdentifier)
            }
            var finalAssets: [PHAsset] = []
            
            // 策略调整：不再全局限制 10 张，而是每个足迹/交通段最多显示 10 张最接近终点的照片
            // 这样可以避免单个停留点产生上百个图标，同时保证全天的地理标记都能显示出来
            if items.isEmpty {
                // 如果还没有生成时间线（比如刚进入），先取全局前 10 作为占位
                finalAssets = Array(filtered.suffix(10))
            } else {
                for item in items {
                    let itemStart = item.startTime
                    let itemEnd = item.endTime
                    
                    let cluster = filtered.filter { asset in
                        guard let creation = asset.creationDate else { return false }
                        return creation >= itemStart && creation <= itemEnd
                    }
                    
                    // 每个段取最新的 10 张
                    finalAssets.append(contentsOf: cluster.suffix(10))
                }
                
                // 补充那些不在任何段里的零散照片（比如段与段之间的间隙），也限制 10 张
                let orphans = filtered.filter { asset in
                    guard let creation = asset.creationDate else { return false }
                    return !items.contains { creation >= $0.startTime && creation <= $0.endTime }
                }
                finalAssets.append(contentsOf: orphans.suffix(10))
            }
            
            self.dayPhotoAssets = finalAssets
        }
        
        locationManager.backfillGaps(for: targetDate)
        resolveTimelineAddresses(for: self.timelineItems)
        
        // 扫一遍该日期的足迹，自动补齐缺失活动或加入 AI 生成队列
        locationManager.autoFillMissingActivityTypes(for: targetDate)
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
                // 1. 自动关联缺失或无效的照片（仅对已持久化的真实模型）
                if footprint.modelContext != nil {
                    locationManager.linkPhotos(to: footprint, context: modelContext)
                }
                
                // 2. 解析缺失的地址/标题
                let needsResolution = (footprint.address == nil || footprint.address!.isEmpty || footprint.address == "正在解析位置...")
                
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
                    footprint.address = name
                    
                    if let context = footprint.modelContext {
                        try? context.save()
                    }
                    
                    timelineItems[index] = .footprint(footprint)
                }
            }
        }
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
                OpenAIService.shared.enqueueTomorrowQuote { title, sub in
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
            OpenAIService.shared.enqueuePastQuote { title, sub in
                self.pastQuoteTitle = title
                self.pastQuoteSubtitle = sub
            }
        }
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
    
    private func checkDeepLink(targetID: UUID?) {
        guard let targetID = targetID else { return }
        if let fp = footprints.first(where: { $0.footprintID == targetID }) {
            self.selectedFootprint = fp
            // 消耗掉这个 ID，防止重复触发
            locationManager.deepLinkFootprintID = nil
        }
    }
    
    @MainActor
    private func handlePullToRefresh() async {
        if isFromHistory {
            await refreshTimelineAsync(force: false)
            
            let startOfDate = Calendar.current.startOfDay(for: date)
            let isPast = startOfDate < Calendar.current.startOfDay(for: Date())
            if isPast, isAiAssistantEnabled, !footprints.isEmpty {
                let endOfDate = Calendar.current.date(byAdding: .day, value: 1, to: startOfDate)!
                let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
                    $0.startTime >= startOfDate && $0.startTime < endOfDate && $0.statusRaw == "active"
                })
                let transports = (try? modelContext.fetch(tpDesc)) ?? []
                OpenAIService.shared.enqueueDailySummary(for: date, footprints: footprints, transports: transports, force: true)
            }
        } else {
            let isToday = Calendar.current.isDateInToday(date)
            
            if isToday {
                // 并行执行耗时操作：仅下载远程数据（不上传本地轨迹） 与 整理本地足迹
                async let syncTask: () = locationManager.performRawDataSync(onlyRecent: true, skipUpload: true)
                async let siftTask: () = locationManager.triggerTimelineSift()
                
                // 等待两者完成
                _ = await (syncTask, siftTask)
            }
            
            // 3. 异步刷新，仅从数据库获取最新记录，绝对不触发重新同步构建
            await refreshTimelineAsync(force: false)
            
            // 4. 手动触发 AI 摘要强制重新生成（仅针对过去日期，今日不重复生成）
            if isAiAssistantEnabled && !isToday {
                await refreshAiSummary(force: true)
            }
        }
        
        // 触感反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func refreshAiSummary(force: Bool = false) async {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        })
        let latestFootprints = (try? modelContext.fetch(descriptor)) ?? []
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw == "active"
        })
        let latestTransports = (try? modelContext.fetch(tpDesc)) ?? []
        
        if !latestFootprints.isEmpty {
            OpenAIService.shared.enqueueDailySummary(for: date, footprints: latestFootprints, transports: latestTransports, force: force)
        }
    }
}
