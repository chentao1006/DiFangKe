import SwiftUI
import CoreLocation
import SwiftData
import Aptabase

// MARK: - Footprint Card View
private struct AdjacentFootprintMergeCandidate {
    let base: Footprint
    let other: Footprint

    var first: Footprint {
        base.startTime <= other.startTime ? base : other
    }

    var second: Footprint {
        base.startTime <= other.startTime ? other : base
    }
}

struct FootprintCardView: View {
    @Bindable var footprint: Footprint
    let allPlaces: [Place]
    var contextDate: Date? = nil
    var isFirst: Bool = false
    var isLast: Bool = false
    var isToday: Bool = false
    var showTimeline: Bool = true
    var showDateAboveTitle: Bool = false
    var fixedWidth: CGFloat? = nil
    var disableContextMenu: Bool = false
    var displayAddressOverride: String? = nil
    var resolvesUnknownAddress: Bool = true
    let onTap: (Footprint, Bool) -> Void
    
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @State private var highlightVisible: Bool = false
    @State private var showingDeleteConfirm = false
    @State private var showingIgnoreConfirm = false
    @State private var showingMergeConfirm = false
    @State private var showingAddImportantPlace = false
    @State private var showingSplitFootprint = false
    @State private var pendingMergeCandidate: AdjacentFootprintMergeCandidate?
    @State private var isResolvingUnknownPlace = false
    @State private var isPlaceTitleBreathing = false
    @State private var activityPickerPresentation: ActivityPickerPresentation?
    
    var body: some View {
        if footprint.status == .ignored {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                 timelineIndicator
                 ZStack(alignment: .topTrailing) {
                     
                     VStack(alignment: .leading, spacing: 4) {
                        if showDateAboveTitle && (contextDate == nil || !Calendar.current.isDate(footprint.date, inSameDayAs: contextDate!)) {
                            Text(footprint.date.formatted(.dateTime.year().month().day()))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.bottom, -2)
                        }
                        
                        HStack(spacing: 6) {
                            let matchedPlace = matchedImportantPlace
                            let displayText = matchedPlace?.name ?? displayAddressOverride ?? footprint.address ?? "未知地点"
                            
                            Text(displayText)
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(matchedPlace != nil ? .orange : Color.dfkMainText)
                                .lineLimit(1)
                                .opacity(isResolvingUnknownPlace && isPlaceTitleBreathing ? 0.38 : 1)
                                .scaleEffect(isResolvingUnknownPlace && isPlaceTitleBreathing ? 0.985 : 1, anchor: .leading)
                        }
                        
                        HStack(spacing: 4) {
                            Text(timeRangeString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.3))
                            Text(durationString)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                        
                                if let reason = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !reason.isEmpty {
                            Text(reason)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(Color.dfkMainText.opacity(0.8))
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.leading, 0)
                    .padding(.trailing, footprint.photoAssetIDs.isEmpty ? 16 : 84) // Increased for larger photo
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    
                    if let firstID = footprint.photoAssetIDs.first {
                        ZStack(alignment: .topTrailing) {
                            Color.clear // Expand to fill parent
                            
                            ZStack(alignment: .topTrailing) {
                                AssetThumbnailView(assetID: firstID, showsTime: false, targetSize: CGSize(width: 120, height: 120))
                                    .id(firstID)
                                    .frame(width: 60, height: 60)
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
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                        }
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
            .if(!disableContextMenu) { view in
                view.contextMenu { longPressMenu }
            }
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
            .alert("合并相邻足迹？", isPresented: $showingMergeConfirm) {
                Button("合并") {
                    if let pendingMergeCandidate {
                        mergeAdjacentFootprints(pendingMergeCandidate)
                    }
                    pendingMergeCandidate = nil
                }
                Button("取消", role: .cancel) {
                    pendingMergeCandidate = nil
                }
            } message: {
                Text(mergeConfirmationMessage)
            }
            .sheet(isPresented: $showingAddImportantPlace) {
                AddToFavoriteModal(footprint: footprint)
            }
            .sheet(isPresented: $showingSplitFootprint) {
                FootprintSplitView(footprint: footprint)
            }
            .onAppear {
                if footprint.isHighlight == true {
                    withAnimation(.easeOut(duration: 0.3).delay(0.2)) { highlightVisible = true }
                }
                if resolvesUnknownAddress {
                    geocodeAddress()
                }
                
                // 自动关联缺失或无效的照片（针对首次入场或跨设备同步的情况）
                locationManager.linkPhotos(to: footprint, context: modelContext)
            }
            .onChange(of: isResolvingUnknownPlace) { _, isResolving in
                guard isResolving else {
                    isPlaceTitleBreathing = false
                    return
                }
                isPlaceTitleBreathing = false
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPlaceTitleBreathing = true
                }
            }
        }
    }
    
    private func geocodeAddress() {
        let existingAddress = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unresolvedValues: Set<String> = ["", "未知位置", "未知地点", "地点记录", "正在解析位置...", "此处"]
        guard unresolvedValues.contains(existingAddress) else { return }

        let targetFootprint = footprint
        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)

        // These are already known Apple misses from an older import/history.
        // Start with OSM instead of waiting for another potentially stalled
        // Apple request; use Apple only if OSM has no result.
        Task { @MainActor in
            isResolvingUnknownPlace = true
            defer { isResolvingUnknownPlace = false }

            let osmAddress = await OpenStreetMapGeocoder.shared.lookup(coordinate: coordinate)?.address
            let resolvedAddress = osmAddress
            guard let resolvedAddress, !resolvedAddress.isEmpty else { return }

            targetFootprint.address = resolvedAddress
            try? targetFootprint.modelContext?.save()
        }
    }

    private var matchedImportantPlace: Place? {
        allPlaces.first(where: { place in
            if place.placeID == footprint.placeID && place.isUserDefined { return true }
            guard place.isUserDefined else { return false }
            let fpAddr = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fpAddr.isEmpty else { return false }
            return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr ||
                   (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr)
        })
    }
    
    private func getSuggestedActivities(includeFallback: Bool = true) -> [ActivityType] {
        let liteActivities = allActivities.map { $0.convertToLite() }
        let litePlaces = allPlaces.map { $0.convertToLite() }
        let suggestions = ActivityType.getSuggestedActivities(for: footprint, allActivities: liteActivities, allPlaces: litePlaces, includeFallback: includeFallback)
        
        return suggestions.compactMap { lite in
            allActivities.first { $0.id == lite.id }
        }
    }
    
    private var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let startStr = formatter.string(from: footprint.startTime)
        let endStr = formatter.string(from: footprint.endTime)
        
        let calendar = Calendar.current
        let referenceDate = contextDate ?? footprint.date
        let isStartSameDay = calendar.isDate(footprint.startTime, inSameDayAs: referenceDate)
        let isEndSameDay = calendar.isDate(footprint.endTime, inSameDayAs: referenceDate)
        
        if isStartSameDay && isEndSameDay {
            return "\(startStr)-\(endStr)"
        } else if !isStartSameDay && isEndSameDay {
            return "昨日\(startStr)-\(endStr)"
        } else if isStartSameDay && !isEndSameDay {
            return "\(startStr)-次日\(endStr)"
        } else {
            let isSameDay = calendar.isDate(footprint.startTime, inSameDayAs: footprint.endTime)
            let monthDayFormatter = DateFormatter()
            monthDayFormatter.dateFormat = "M月d日 HH:mm"
            
            if isSameDay {
                return "\(monthDayFormatter.string(from: footprint.startTime))-\(endStr)"
            } else {
                return "\(monthDayFormatter.string(from: footprint.startTime))-\(monthDayFormatter.string(from: footprint.endTime))"
            }
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
        let activity = footprint.getActivityType(from: allActivities)
        let iconName = activity?.icon ?? FootprintIconDefaults.card
        let iconColor = activity?.color ?? .secondary.opacity(0.4)
        
        return VStack(spacing: 0) {
            if showTimeline {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(height: 12)
                    .opacity(isFirst && !isToday ? 0 : 1)
            } else {
                Spacer().frame(height: 8)
            }
            
            Button {
                prepareActivityPicker()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                        .frame(width: 32, height: 32)
                        
                    Circle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [iconColor.opacity(0.7), iconColor]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 27, height: 27)
                        
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .popover(item: $activityPickerPresentation) { presentation in
                StableActivityPickerPopover(
                    suggestedItems: presentation.suggestedItems,
                    allItems: presentation.allItems,
                    onSelect: applyActivityType
                )
            }
            
            if showTimeline {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, -12)
                    .opacity(isLast ? 0 : 1)
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .top) {
            if footprint.isHighlight == true {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color.dfkHighlight)
                    .padding(3)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .offset(y: 36)
            }
        }
        .frame(width: 54)
    }

    @ViewBuilder
    private var longPressMenu: some View {
        if let mergeCandidate = adjacentMergeCandidate {
            Button {
                pendingMergeCandidate = mergeCandidate
                showingMergeConfirm = true
            } label: {
                Label("合并相邻足迹", systemImage: "arrow.triangle.merge")
            }
            Divider()
        }

        Button {
            showingSplitFootprint = true
        } label: {
            Label("拆分足迹", systemImage: "slider.horizontal.below.square.filled.and.square")
        }

        Button { onTap(footprint, true) } label: { Label("编辑", systemImage: "pencil") }
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                footprint.isHighlight = !(footprint.isHighlight ?? false)
                Aptabase.shared.trackEvent("footprint_highlighted")
                try? modelContext.save()
                highlightVisible = (footprint.isHighlight == true)
            }
        } label: { Label(footprint.isHighlight == true ? "取消收藏" : "收藏", systemImage: footprint.isHighlight == true ? "star.slash" : "star.fill") }
        
        Divider()

        if matchedImportantPlace == nil {
            Button {
                showingAddImportantPlace = true
            } label: { Label("添加重要地点", systemImage: "mappin.and.ellipse") }
        }

        Button {
            showingIgnoreConfirm = true
        } label: { Label("忽略地点", systemImage: "mappin.slash") }
        
        Button(role: .destructive) { showingDeleteConfirm = true } label: { Label("删除", systemImage: "trash") }
    }

    private var adjacentMergeCandidate: AdjacentFootprintMergeCandidate? {
        let allFootprints = adjacentSearchFootprints()
        guard let index = allFootprints.firstIndex(where: { $0.footprintID == footprint.footprintID }) else {
            return nil
        }

        if index > 0 {
            let previous = allFootprints[index - 1]
            if canMergeAdjacentFootprints(previous, footprint) {
                return AdjacentFootprintMergeCandidate(base: previous, other: footprint)
            }
        }

        if index < allFootprints.count - 1 {
            let next = allFootprints[index + 1]
            if canMergeAdjacentFootprints(footprint, next) {
                return AdjacentFootprintMergeCandidate(base: footprint, other: next)
            }
        }

        return nil
    }

    private var mergeConfirmationMessage: String {
        guard let pendingMergeCandidate else {
            return "合并后会保留较早的足迹，并删除另一条相邻足迹。"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let first = pendingMergeCandidate.first
        let second = pendingMergeCandidate.second
        return "将合并 \(formatter.string(from: first.startTime))-\(formatter.string(from: first.endTime)) 和 \(formatter.string(from: second.startTime))-\(formatter.string(from: second.endTime)) 两条足迹。"
    }

    private func adjacentSearchFootprints() -> [Footprint] {
        let lowerBound = footprint.startTime.addingTimeInterval(-172800)
        let upperBound = footprint.endTime.addingTimeInterval(172800)
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate {
                $0.statusValue != "ignored" &&
                $0.endTime >= lowerBound &&
                $0.startTime <= upperBound
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func canMergeAdjacentFootprints(_ first: Footprint, _ second: Footprint) -> Bool {
        guard first.status != .ignored, second.status != .ignored else { return false }
        guard first.footprintID != second.footprintID else { return false }
        guard isSameDayFootprint(first), isSameDayFootprint(second) else { return false }
        guard Calendar.current.isDate(first.startTime, inSameDayAs: second.startTime) else { return false }
        return !hasTransportBetween(first, second)
    }

    private func isSameDayFootprint(_ footprint: Footprint) -> Bool {
        Calendar.current.isDate(footprint.startTime, inSameDayAs: footprint.endTime.addingTimeInterval(-0.001))
    }

    private func hasTransportBetween(_ first: Footprint, _ second: Footprint) -> Bool {
        let lowerBound = min(first.endTime, second.endTime)
        let upperBound = max(first.startTime, second.startTime)
        guard upperBound > lowerBound else { return false }

        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.statusRaw != "ignored" &&
                $0.endTime > lowerBound &&
                $0.startTime < upperBound
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private func mergeAdjacentFootprints(_ candidate: AdjacentFootprintMergeCandidate) {
        let base = candidate.first
        let other = candidate.second

        base.startTime = min(base.startTime, other.startTime)
        base.endTime = max(base.endTime, other.endTime)
        base.date = Calendar.current.startOfDay(for: base.startTime)
        base.allowsAutomaticDurationExtension = true
        base.status = .manual

        var mergedLocations = base.footprintLocations
        mergedLocations.append(contentsOf: other.footprintLocations)
        base.footprintLocations = mergedLocations

        if base.reason?.isEmpty ?? true {
            base.reason = other.reason
        }
        if base.address?.isEmpty ?? true {
            base.address = other.address
            base.isAddressEditedByHand = other.isAddressEditedByHand
        }
        if base.placeID == nil {
            base.placeID = other.placeID
        }
        if base.activityTypeValue == nil {
            base.activityTypeValue = other.activityTypeValue
        }
        if base.isHighlight != true {
            base.isHighlight = other.isHighlight
        }
        base.stepCount = combinedOptionalSum(base.stepCount, other.stepCount)
        base.walkingDistance = combinedOptionalSum(base.walkingDistance, other.walkingDistance)
        base.floorsAscended = combinedOptionalSum(base.floorsAscended, other.floorsAscended)

        var mergedPhotos = base.photoAssetIDs
        for photoID in other.photoAssetIDs where !mergedPhotos.contains(photoID) {
            mergedPhotos.append(photoID)
        }
        base.photoAssetIDs = mergedPhotos

        var mergedMetadata = base.photoMetadata
        for metadata in other.photoMetadata where !mergedMetadata.contains(metadata) {
            mergedMetadata.append(metadata)
        }
        base.photoMetadata = mergedMetadata

        modelContext.delete(other)
        try? modelContext.save()
        Footprint.resumeMergedCurrentStay(base, context: modelContext)
        try? modelContext.save()

        invalidateTimelineAfterMerge(start: base.startTime, end: base.endTime)
        Aptabase.shared.trackEvent("footprint_adjacent_merged")
    }

    private func combinedOptionalSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func prepareActivityPicker() {
        let allItems = allActivities.map {
            StableActivityPickerItem(id: $0.id, name: $0.name, icon: $0.icon)
        }
        let suggestedItems = getSuggestedActivities(includeFallback: false).map {
            StableActivityPickerItem(id: $0.id, name: $0.name, icon: $0.icon)
        }
        activityPickerPresentation = ActivityPickerPresentation(suggestedItems: suggestedItems, allItems: allItems)
    }

    private func applyActivityType(_ id: UUID?) {
        let activity = id.flatMap { selectedID in
            allActivities.first(where: { $0.id == selectedID })
        }
        applyActivityType(activity)
    }

    private func applyActivityType(_ activity: ActivityType?) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            footprint.updateActivityType(to: activity?.id.uuidString, in: modelContext)
            try? modelContext.save()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        let day = Calendar.current.startOfDay(for: footprint.startTime)
        TimelineBuilder.timelineCache.removeValue(forKey: day)
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": day]
        )
    }

    private func combinedOptionalSum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func invalidateTimelineAfterMerge(start: Date, end: Date) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = max(start, end.addingTimeInterval(-0.001))
        let endDay = calendar.startOfDay(for: effectiveEnd)

        var cursor = startDay
        while cursor <= endDay {
            TimelineBuilder.timelineCache.removeValue(forKey: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": startDay]
        )

        if calendar.isDateInToday(start) || calendar.isDateInToday(end) {
            locationManager.triggerNotificationSummaryRefresh()
        }
    }
    
    private func ignoreFootprint() {
        withAnimation {
            footprint.status = .ignored
            if footprint.modelContext == nil {
                modelContext.insert(footprint)
            }
            try? modelContext.save()
        }
    }
}

// MARK: - Guides
struct ImportantPlaceGuide: View {
    @Binding var isGuideDismissed: Bool
    var action: (() -> Void)? = nil
    
    var body: some View {
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
                    if let action {
                        action()
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("NavigateToImportantPlaces"), object: nil)
                    }
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
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
