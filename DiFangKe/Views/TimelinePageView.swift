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
    let summaryContent: String?
    
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
    @State private var dayPhotoAssets: [PHAsset] = []
    
    init(date: Date, footprints: [Footprint], manualSelections: [TransportManualSelection], allPlaces: [Place], offset: Int, locationManager: LocationManager, pastLimitOffset: Int, isFromHistory: Bool = false, summaryContent: String? = nil) {
        self.date = date
        self.footprints = footprints
        self.manualSelections = manualSelections
        self.allPlaces = allPlaces
        self.offset = offset
        self.locationManager = locationManager
        self.pastLimitOffset = pastLimitOffset
        self.isFromHistory = isFromHistory
        self.summaryContent = summaryContent
        
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
        Group {
            if !isFromHistory && Calendar.current.isDateInToday(date) {
                timelineScrollView
                    .refreshable {
                        await handlePullToRefresh()
                    }
            } else {
                timelineScrollView
            }
        }
        .onAppear {
            appearanceTask?.cancel()
            appearanceTask = Task { @MainActor in
                // 只有停留超过 400ms 才开始业务逻辑，防止快速划过时的卡顿
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                
                NotificationManager.shared.getAuthorizationStatus { status in
                    self.notificationAuthStatus = status
                }
                
                // 只有当没有任何数据时，才进行初次同步
                if timelineItems.isEmpty {
                    refreshTimeline()
                }
                
                // AI 每日摘要检查
                if isAiAssistantEnabled && !footprints.isEmpty {
                    if summaryContent == nil {
                        // 只为过去日期生成
                        let isPast = Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
                        
                        if isPast {
                            OpenAIService.shared.enqueueDailySummary(for: date, footprints: footprints)
                        }
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
            // 当后台完成活动匹配或 AI 分析时，触发完整刷新以展示最新状态
            refreshTimeline(force: true)
        }
        .onChange(of: locationManager.lastRawDataUpdateTrigger) { _, _ in refreshTimeline(force: true) }
        .sheet(item: $selectedFootprint) { footprint in
            FootprintModalView(
                footprint: footprint, 
                autoFocus: autoFocusOnOpen,
                onDismiss: { didChange in
                    autoFocusOnOpen = false
                    refreshTimeline(force: didChange)
                }
            )
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
                if let index = timelineItems.firstIndex(where: { 
                    if case .transport(let t) = $0, t.id == transport.id { return true }
                    return false
                }) {
                    if case .transport(let t) = timelineItems[index] {
                        let updated = t.updatingType(newType)
                        timelineItems[index] = .transport(updated)
                    }
                }
                refreshTimeline(force: true)
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
        let items = self.timelineItems
        let isToday = Calendar.current.isDateInToday(date)
        guard isToday, let ongoingStart = locationManager.potentialStopStartLocation?.timestamp else {
            return items
        }
        
        // 我们只过滤列表顶部的、可能与实时状态卡片冲突的记录
        let ongoingLoc = locationManager.potentialStopStartLocation
        
        return items.filter { item in
            switch item {
            case .footprint(let fp):
                // 1. 时间：如果足迹结束时间晚于当前停留开始时间（容错 60s）
                let isTimeOverlap = fp.endTime > ongoingStart.addingTimeInterval(60)
                
                // 2. 地点：如果位置重合（200米内，认为属于同一个停留）
                var isLocationOverlap = false
                if let ol = ongoingLoc {
                    let fpLoc = CLLocation(latitude: fp.latitude, longitude: fp.longitude)
                    isLocationOverlap = fpLoc.distance(from: ol) < 200
                }
                
                // 如果时间和地点都重合，说明它是正在进行的停留的“前身”或者重复，在列表中隐藏它
                if isTimeOverlap && isLocationOverlap { return false }
                
            case .transport(let tp):
                // 如果交通段结束于实时停留开始之后，可能是位移漂移导致，也暂时隐藏
                if tp.endTime > ongoingStart.addingTimeInterval(30) { return false }
            }
            return true
        }
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
                    photoAssets: dayPhotoAssets,
                    summary: summaryContent
                )
                .padding(.horizontal, 16)
            } else {
                DaySummaryCard(
                    date: date,
                    totalPoints: totalPointsCount,
                    footprintCount: filteredTimelineItems.filter { if case .footprint = $0 { return true }; return false }.count,
                    transportMileage: filteredTimelineItems.reduce(0) { sum, item in
                        if case .transport(let t) = item { return sum + t.distance }
                        return sum
                    },
                    points: trajectoryPoints,
                    timelineItems: filteredTimelineItems,
                    onTimelineItemTap: handleTimelineItemTap,
                    photoAssets: dayPhotoAssets,
                    summary: summaryContent
                )
                .padding(.horizontal, 16)
            }
            
            if timelineItems.isEmpty && !isLoadingTimeline {
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
            if !isNotificationGuideDismissed && isToday && notificationAuthStatus == .notDetermined && !footprints.isEmpty {
                NotificationGuide(isNotificationGuideDismissed: $isNotificationGuideDismissed)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
            }
            
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
        
        // 执行彻底的持久化时间线同步算法
        if force || hasRawData || isToday {
            await PersistentTimelineBuilder.syncDay(date: targetDate, in: modelContext)
        }
        
        if Task.isCancelled { return }
        
        let items = PersistentTimelineBuilder.fetchTimeline(for: targetDate, in: modelContext)
        self.timelineItems = items
        
        let result = await Task.detached(priority: .userInitiated) {
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
            let rawCoords = rawPoints.map { $0.coordinate }
            let simplified = LocationManager.simplifyCoordinates(rawCoords, tolerance: 0.00005)
            return (simplified, rawPoints.count)
        }.value
        
        self.trajectoryPoints = result.0
        self.totalPointsCount = result.1
        
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
        
        // 触发摘要重新生成：如果是由足迹/交通修改引发的强制刷新，且启用了 AI，则强制重新生成当日概览
        if force && isAiAssistantEnabled && !footprints.isEmpty {
            let isPast = Calendar.current.startOfDay(for: targetDate) < Calendar.current.startOfDay(for: Date())
            if isPast {
                OpenAIService.shared.enqueueDailySummary(for: targetDate, footprints: footprints, force: true)
            }
        }
        
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
                let needsResolution = Footprint.isGenericTitle(footprint.title) 
                    && (footprint.address == nil || footprint.address!.isEmpty || footprint.address == "正在解析位置...")
                
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
                    footprint.title = Footprint.generateRandomTitle(for: name, seed: Int(footprint.startTime.timeIntervalSince1970))
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
        // 1. 同步远程原始轨迹
        await locationManager.performRawDataSync()
        
        // 2. 触发位置碎片合并计算
        await locationManager.triggerTimelineSift()
        
        // 3. 强制异步刷新当前页面的时间线显示
        await refreshTimelineAsync(force: true)
        
        // 4. 触感反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
