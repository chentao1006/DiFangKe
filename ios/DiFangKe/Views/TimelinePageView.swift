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
    let isActivePage: Bool
    let isFromHistory: Bool
    let dailyInsight: DailyInsight?
    
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
    @State private var lastSummaryTimelineSignature: String?
    
    init(date: Date, footprints: [Footprint], manualSelections: [TransportManualSelection], allPlaces: [Place], offset: Int, locationManager: LocationManager, pastLimitOffset: Int, isActivePage: Bool = true, isFromHistory: Bool = false, dailyInsight: DailyInsight? = nil) {
        self.date = date
        self.dailyInsight = dailyInsight
        
        self.footprints = footprints
        self.manualSelections = manualSelections
        self.allPlaces = allPlaces
        self.offset = offset
        self.locationManager = locationManager
        self.pastLimitOffset = pastLimitOffset
        self.isActivePage = isActivePage
        self.isFromHistory = isFromHistory
        
        let cached = TimelineBuilder.timelineCache[date] ?? []
        // 初始化时立即执行重链接，确保首次渲染就是数据库真实模型
        let linkedItems = cached.compactMap { item -> TimelineItem? in
            if case .footprint(let tempFp) = item {
                if let realFp = footprints.first(where: { $0.footprintID == tempFp.footprintID }) {
                    return .footprint(realFp)
                }
                // 丢弃已删除且无法重链的持久化足迹，避免访问失效实例。
                if tempFp.modelContext != nil {
                    return nil
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
            activatePageIfNeeded()
        }
        .onChange(of: isActivePage) { _, newValue in
            if newValue {
                activatePageIfNeeded()
            } else {
                deactivatePage()
            }
        }
        .onDisappear {
            deactivatePage()
        }
        .onChange(of: footprints) { _, _ in
            guard isActivePage, !isModalPresented else { return }
            // 安全刷新：仅重新获取数据库内容刷新 UI，不触发 syncDay 算法，彻底杜绝死循环
            let items = PersistentTimelineBuilder.fetchTimeline(for: date, in: modelContext)
            applyTimelineItems(items, triggerAiIfChanged: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in
            guard isActivePage, !isModalPresented else { return }
            // 当后台完成活动匹配时，仅刷新 UI，不触发 AI 重新总结
            refreshTimeline(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataWillReset"))) { notification in
            guard isActivePage else { return }
            if let resetDate = notification.userInfo?["date"] as? Date,
               !Calendar.current.isDate(resetDate, inSameDayAs: date) {
                return
            }

            // 重置前先释放当前页引用，避免 SwiftData 删除后渲染到无效对象。
            selectedFootprint = nil
            selectedTransport = nil
            timelineItems = []
            dayPhotoAssets = []
            refreshTask?.cancel()
        }
        .onChange(of: locationManager.lastRawDataUpdateTrigger) { _, _ in
            guard isActivePage, !isModalPresented else { return }
            refreshTimeline(force: false)
        }
        .sheet(item: $selectedFootprint, onDismiss: {
            autoFocusOnOpen = false
            refreshTimeline(force: false)
        }) { footprint in
            FootprintModalView(
                footprint: footprint, 
                autoFocus: autoFocusOnOpen,
                onDismiss: { didChange in
                    autoFocusOnOpen = false
                    Task { @MainActor in
                        if didChange {
                            await refreshTransportEndpointsForCurrentDay()
                            CloudSettingsManager.shared.triggerDataSyncPulse()
                        }

                        refreshTimeline(force: false)

                        if didChange && isAiAssistantEnabled {
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
        .sheet(item: $selectedTransport, onDismiss: {
            refreshTimeline(force: false)
        }) { transport in
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
            guard isActivePage else { return }
            checkDeepLink(targetID: newValue)
        }
    }

    @MainActor
    private func activatePageIfNeeded() {
        guard isActivePage else { return }

        appearanceTask?.cancel()
        appearanceTask = Task { @MainActor in
            NotificationManager.shared.getAuthorizationStatus { status in
                self.notificationAuthStatus = status
            }

            // 只在真正停留到当前页后才执行刷新，避免快速划过时触发重计算。
            refreshTimeline()


            checkDeepLink(targetID: locationManager.deepLinkFootprintID)
        }
    }

    @MainActor
    private func deactivatePage() {
        appearanceTask?.cancel()
        refreshTask?.cancel()
    }

    private var isModalPresented: Bool {
        selectedFootprint != nil || selectedTransport != nil || showingAddPlaceSheet
    }
    
    // 过滤掉与当前正在进行的实时停留重合的足迹，避免双重视图
    private var filteredTimelineItems: [TimelineItem] {
        self.timelineItems
    }

    private var ongoingFootprintItem: TimelineItem? {
        guard Calendar.current.isDateInToday(date),
              let startLocation = locationManager.potentialStopStartLocation else {
            return nil
        }

        let startTime = startLocation.timestamp
        let endTime = max(Date(), startTime)
        let matchedPlace = locationManager.matchedPlace
        let matchedActivityType = inferredActivityTypeValue(for: matchedPlace?.placeID, at: startTime)
        let address = locationManager.ongoingTitle ?? {
            let currentAddress = locationManager.currentAddress
            return (currentAddress == "正在解析位置..." || currentAddress == "未知位置") ? nil : currentAddress
        }()

        let alreadyCovered = filteredTimelineItems.contains { item in
            guard case .footprint(let footprint) = item else { return false }

            if let placeID = matchedPlace?.placeID, footprint.placeID == placeID {
                let samePlaceGrace = max(AppConfig.shared.liveStayMergeTimeThreshold, AppConfig.shared.samePlaceMergeGapThreshold)
                return endTime.timeIntervalSince(footprint.endTime) <= samePlaceGrace
            }

            let footprintLocation = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
            let distance = startLocation.distance(from: footprintLocation)
            guard distance < 120 else { return false }

            let userPinned = !(footprint.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !footprint.photoAssetIDs.isEmpty
                || footprint.isHighlight == true
                || footprint.status == .manual

            if userPinned {
                let pinnedGrace = max(AppConfig.shared.liveStayMergeTimeThreshold, 1800)
                return endTime.timeIntervalSince(footprint.endTime) <= pinnedGrace
            }

            return footprint.endTime >= startTime.addingTimeInterval(-300)
        }

        guard !alreadyCovered else { return nil }

        let temporaryFootprint = Footprint(
            date: Calendar.current.startOfDay(for: date),
            startTime: startTime,
            endTime: endTime,
            footprintLocations: [startLocation.coordinate],
            locationHash: "ONGOING_STAY",
            duration: endTime.timeIntervalSince(startTime),
            status: .manual,
            placeID: matchedPlace?.placeID,
            address: address,
            isAddressEditedByHand: matchedPlace != nil,
            activityTypeValue: matchedActivityType
        )

        return .footprint(temporaryFootprint)
    }

    private func inferredActivityTypeValue(for placeID: UUID?, at time: Date) -> String? {
        guard let placeID else { return nil }

        // 优先复用当天同地点最近一次已确定的活动类型，确保实时卡片展示稳定。
        if let sameDayType = footprints
            .filter({ $0.placeID == placeID && $0.activityTypeValue != nil })
            .sorted(by: { $0.endTime > $1.endTime })
            .first?
            .activityTypeValue {
            return sameDayType
        }

        // 回退到全局习惯匹配规则（与已有自动补齐逻辑一致）。
        return locationManager.suggestFrequentActivityType(for: placeID, at: time)
    }

    private var displayedTimelineItems: [TimelineItem] {
        var items = filteredTimelineItems
        guard let ongoingFootprintItem else { return items }

        items.append(ongoingFootprintItem)
        return items.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime > $1.endTime
            }
            return $0.startTime > $1.startTime
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
                    timelineItems: displayedTimelineItems,
                    rendersLiveMap: isActivePage,
                    onTimelineItemTap: handleTimelineItemTap,
                    photoAssets: dayPhotoAssets
                )
                .padding(.horizontal, 16)
            } else {
                    DaySummaryCard(
                        date: date,
                        dateOffset: offset,
                        totalPoints: totalPointsCount,
                        footprintCount: displayedTimelineItems.filter { if case .footprint = $0 { return true }; return false }.count,
                        totalMileage: totalDailyMileage,
                        points: trajectoryPoints,
                    timelineItems: displayedTimelineItems,
                    onTimelineItemTap: handleTimelineItemTap,
                    photoAssets: dayPhotoAssets,
                    summary: dailyInsight?.content,
                    isLoading: isLoadingTimeline,
                    rendersLiveMap: isActivePage
                )
                .padding(.horizontal, 16)
            }
            
            if isToday && displayedTimelineItems.isEmpty && !isLoadingTimeline {
                PlaceholderFootprintCard()
                    .padding(.horizontal, 0)
            }
            
            if allPlaces.isEmpty && !isGuideDismissed {
                ImportantPlaceGuide(isGuideDismissed: $isGuideDismissed)
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
        if footprints.isEmpty && displayedTimelineItems.isEmpty && dayPhotoAssets.isEmpty && (!isToday || locationManager.potentialStopStartLocation == nil) {
            if allPlaces.isEmpty && isToday && !isGuideDismissed {
                EmptyView()
            } else if !isLoadingTimeline {
                emptyStateView
            }
        } else {
            let items = displayedTimelineItems
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
                            deleteTransport(selected)
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

    private func deleteTransport(_ selected: Transport) {
        let targetId = selected.id

        let recordDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == targetId })
        if let records = try? modelContext.fetch(recordDescriptor), let record = records.first {
            record.statusRaw = "ignored"
        }

        let overrideDescriptor = FetchDescriptor<TransportManualSelection>(predicate: #Predicate { $0.recordID == targetId })
        let existingOverride = (try? modelContext.fetch(overrideDescriptor))?.first
        let deletionOverride = existingOverride ?? TransportManualSelection(
            recordID: targetId,
            startTime: selected.startTime,
            endTime: selected.endTime,
            vehicleType: selected.currentType.rawValue,
            isDeleted: true
        )

        deletionOverride.startTime = selected.startTime
        deletionOverride.endTime = selected.endTime
        deletionOverride.vehicleType = selected.currentType.rawValue
        deletionOverride.isDeleted = true
        deletionOverride.startLocationOverride = nil
        deletionOverride.endLocationOverride = nil

        if existingOverride == nil {
            modelContext.insert(deletionOverride)
        }

        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
        refreshTimeline(force: false)
        if isAiAssistantEnabled {
            Task {
                await refreshAiSummary(force: true)
            }
        }
    }
    
    @MainActor
    private func applyTimelineItems(_ items: [TimelineItem], triggerAiIfChanged: Bool) {
        self.timelineItems = items

        let signature = timelineSummarySignature(for: items)
        let previousSignature = lastSummaryTimelineSignature
        lastSummaryTimelineSignature = signature

        guard triggerAiIfChanged,
              isAiAssistantEnabled else { return }

        let isMissingSummary = dailyInsight?.content?.isEmpty ?? true
        let signatureChanged = previousSignature != nil && previousSignature != signature
        
        guard signatureChanged || (previousSignature == nil && isMissingSummary) else { return }

        Task {
            await refreshAiSummary(force: false)
        }
    }

    private func timelineSummarySignature(for items: [TimelineItem]) -> String {
        items.map { item in
            switch item {
            case .footprint(let footprint):
                return [
                    "f",
                    footprint.footprintID.uuidString,
                    String(Int(footprint.startTime.timeIntervalSince1970)),
                    String(Int(footprint.endTime.timeIntervalSince1970)),
                    footprint.placeID?.uuidString ?? "nil",
                    footprint.activityTypeValue ?? "nil",
                    String(format: "%.4f", footprint.latitude),
                    String(format: "%.4f", footprint.longitude),
                    String(footprint.photoAssetIDs.count)
                ].joined(separator: ":")
            case .transport(let transport):
                return [
                    "t",
                    transport.id.uuidString,
                    String(Int(transport.startTime.timeIntervalSince1970)),
                    String(Int(transport.endTime.timeIntervalSince1970)),
                    transport.currentType.rawValue,
                    transport.points.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";")
                ].joined(separator: ":")
            }
        }.joined(separator: "|")
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
        
        // 同步策略：仅在手动/强制刷新时执行，不再自动触发。
        let shouldSync = force
        
        if shouldSync {
            await PersistentTimelineBuilder.syncDay(date: targetDate, in: modelContext)
        }
        
        if Task.isCancelled { return }
        
        let items = PersistentTimelineBuilder.fetchTimeline(for: targetDate, in: modelContext)
        applyTimelineItems(items, triggerAiIfChanged: true)
        
        struct FootprintSnapshot: Sendable {
            let startTime: Date
            let latitude: Double
            let longitude: Double
        }

        let footprintSnapshots = items.compactMap { item -> FootprintSnapshot? in
            guard case .footprint(let fp) = item else { return nil }
            return FootprintSnapshot(
                startTime: fp.startTime,
                latitude: fp.latitude,
                longitude: fp.longitude
            )
        }

        let linkedPhotoAssetIDs = Set(items.compactMap { item -> [String]? in
            guard case .footprint(let footprint) = item else { return nil }
            return footprint.photoAssetIDs
        }.flatMap { $0 })

        let result = await Task.detached(priority: .userInitiated) {
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: targetDate)
            var totalMileage = LocationManager.calculatePathDistance(rawPoints)
            
            // 核心改进：如果没有原始轨迹点（如仅导入了照片），则尝试通过所有足迹点（包含照片生成的足迹）计算直线距离之和
            if totalMileage < 50 && footprintSnapshots.count >= 2 {
                var estimatedDist: Double = 0
                let fpCoords = footprintSnapshots
                    .sorted { $0.startTime < $1.startTime }
                    .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
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
                // 仅显示明确关联到当天时间线足迹的照片，避免闭包内访问已失效模型。
                let linkedAssets = filtered.filter { linkedPhotoAssetIDs.contains($0.localIdentifier) }
                finalAssets.append(contentsOf: linkedAssets)
            }
            
            DispatchQueue.main.async {
                // Ensure unique assets by ID
                var seen = Set<String>()
                self.dayPhotoAssets = finalAssets.filter { asset in
                    if seen.contains(asset.localIdentifier) { return false }
                    seen.insert(asset.localIdentifier)
                    return true
                }
            }

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
                // 1. 自动关联缺失或无效的照片（仅在页面激活且确实需要时执行）
                if isActivePage && footprint.modelContext != nil {
                    let needsSync = footprint.photoAssetIDs.isEmpty || !PhotoService.shared.validateAssetIDs(footprint.photoAssetIDs)
                    if needsSync {
                        locationManager.linkPhotos(to: footprint, context: modelContext)
                    }
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
            if offset == 1 && isActivePage {
                OpenAIService.shared.enqueueTomorrowQuote { title, sub in
                    self.tomorrowQuoteTitle = title
                    self.tomorrowQuoteSubtitle = sub
                }
            }
        }
        .onChange(of: isActivePage) { _, newValue in
            guard newValue, offset == 1 else { return }
            OpenAIService.shared.enqueueTomorrowQuote { title, sub in
                self.tomorrowQuoteTitle = title
                self.tomorrowQuoteSubtitle = sub
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
            guard isActivePage else { return }
            OpenAIService.shared.enqueuePastQuote { title, sub in
                self.pastQuoteTitle = title
                self.pastQuoteSubtitle = sub
            }
        }
        .onChange(of: isActivePage) { _, newValue in
            guard newValue else { return }
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
                let cloudChangedKeys = CloudSettingsManager.shared.syncFromCloudNow()
                if cloudChangedKeys.contains("raw_recording_source_device_id") {
                    await locationManager.refreshForRecordingDeviceChange()
                }

                // 手动下拉应先上传本地轨迹，再拉取其他设备更新，保证多设备刷新可见最新足迹。
                async let syncTask: () = locationManager.performRawDataSync(onlyRecent: true, skipUpload: false)
                async let siftTask: () = locationManager.triggerTimelineSift()
                async let cloudSettingsSyncTask: () = {
                    CloudSettingsManager.shared.manualSyncNow()
                    CloudSettingsManager.shared.triggerDataSyncPulseManual()
                }()
                
                // 等待两者完成
                _ = await (syncTask, siftTask, cloudSettingsSyncTask)
            }
            
            // 3. 异步刷新，【强制】触发重新同步构建（保证下拉能拉取最新轨迹并转为足迹）
            await refreshTimelineAsync(force: true)
            
            // 3.5 手动下拉强制触发照片关联检查（针对当前所有足迹）
            for item in timelineItems {
                if case .footprint(let footprint) = item {
                    locationManager.linkPhotos(to: footprint, context: modelContext)
                }
            }
            
            // 4. 手动触发 AI 摘要强制重新生成（仅针对过去日期，今日不重复生成）
            if isAiAssistantEnabled && !isToday {
                await refreshAiSummary(force: true)
            }
        }
        
        // 触感反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    private func refreshTransportEndpointsForCurrentDay() async {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

        let placeDescriptor = FetchDescriptor<Place>()
        let allPlaces = (try? modelContext.fetch(placeDescriptor)) ?? []

        let footprintDescriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let dayFootprints = (try? modelContext.fetch(footprintDescriptor)) ?? []

        let transportDescriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw != "ignored"
        }, sortBy: [SortDescriptor(\.startTime)])
        let dayTransports = (try? modelContext.fetch(transportDescriptor)) ?? []

        var hasChanges = false

        for transport in dayTransports {
            var transportChanged = false
            var decodedPoints: [CodableCoordinate] = []
            if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: transport.pointsData) {
                decodedPoints = decoded
            }

            if let previousFootprint = dayFootprints.last(where: { $0.endTime <= transport.startTime + AppConfig.shared.snapTimeBuffer }) {
                let gap = transport.startTime.timeIntervalSince(previousFootprint.endTime)
                if gap >= 0 && gap < AppConfig.shared.transportAlignmentThreshold {
                    transport.startTime = previousFootprint.endTime
                    let locationName = preferredTransportLocationName(for: previousFootprint, allPlaces: allPlaces)
                    if !locationName.isEmpty && locationName != "某地" && transport.startLocation != locationName {
                        transport.startLocation = locationName
                    }

                    let footprintCoordinate = CodableCoordinate(lat: previousFootprint.latitude, lon: previousFootprint.longitude)
                    if decodedPoints.first?.lat != footprintCoordinate.lat || decodedPoints.first?.lon != footprintCoordinate.lon {
                        decodedPoints.insert(footprintCoordinate, at: 0)
                    }
                    transportChanged = true
                }
            }

            if let nextFootprint = dayFootprints.first(where: { $0.startTime >= transport.endTime - AppConfig.shared.snapTimeBuffer }) {
                let gap = nextFootprint.startTime.timeIntervalSince(transport.endTime)
                if gap >= 0 && gap < AppConfig.shared.transportAlignmentThreshold {
                    transport.endTime = nextFootprint.startTime
                    let locationName = preferredTransportLocationName(for: nextFootprint, allPlaces: allPlaces)
                    if !locationName.isEmpty && locationName != "某地" && transport.endLocation != locationName {
                        transport.endLocation = locationName
                    }

                    let footprintCoordinate = CodableCoordinate(lat: nextFootprint.latitude, lon: nextFootprint.longitude)
                    if decodedPoints.last?.lat != footprintCoordinate.lat || decodedPoints.last?.lon != footprintCoordinate.lon {
                        decodedPoints.append(footprintCoordinate)
                    }
                    transportChanged = true
                }
            }

            if transportChanged {
                if let newPointsData = try? JSONEncoder().encode(decodedPoints) {
                    transport.pointsData = newPointsData
                }
                transport.distance = TimelineBuilder.calculatePathDistance(decodedPoints)
                let duration = transport.endTime.timeIntervalSince(transport.startTime)
                if duration > 0 {
                    transport.averageSpeed = transport.distance / duration
                }
                hasChanges = true
            }
        }

        if hasChanges {
            try? modelContext.save()
        }
    }

    private func preferredTransportLocationName(for footprint: Footprint, allPlaces: [Place]) -> String {
        if footprint.isAddressEditedByHand, let address = footprint.address, !address.isEmpty {
            return address
        }

        if let placeID = footprint.placeID, let place = allPlaces.first(where: { $0.placeID == placeID }) {
            return place.name
        }

        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        let litePlaces = allPlaces.map { TimelineBuilder.convertToPlaceLite($0) }
        if let matched = TimelineBuilder.getPlaceForCoordinate(coordinate, allPlaces: litePlaces) {
            return matched.name
        }

        if let address = footprint.address, !address.isEmpty {
            return address
        }

        return "未知位置"
    }
    
    private func refreshAiSummary(force: Bool = false) async {
        let startOfDay = Calendar.current.startOfDay(for: date)
        guard !Calendar.current.isDateInToday(startOfDay) else {
            return
        }

        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusValue != "ignored"
        })
        let latestFootprints = (try? modelContext.fetch(descriptor)) ?? []
        
        let tpDesc = FetchDescriptor<TransportRecord>(predicate: #Predicate {
            $0.startTime >= startOfDay && $0.startTime < endOfDay && $0.statusRaw == "active"
        })
        let latestTransports = (try? modelContext.fetch(tpDesc)) ?? []

        let isPastDay = startOfDay < Calendar.current.startOfDay(for: Date())
        let summaryFootprints = latestFootprints.filter { 
            $0.isUserModifiedForDailySummary || (isPastDay && $0.statusValue != "ignored")
        }

        if summaryFootprints.isEmpty {
            let insightDescriptor = FetchDescriptor<DailyInsight>(predicate: #Predicate {
                $0.date == startOfDay
            })
            if let existingInsight = (try? modelContext.fetch(insightDescriptor))?.first,
               existingInsight.aiGenerated == true {
                existingInsight.content = nil
                existingInsight.dataFingerprint = nil
                try? modelContext.save()
            }
            return
        }
        
        OpenAIService.shared.enqueueDailySummary(for: date, footprints: summaryFootprints, transports: latestTransports, force: force)
    }
}
