import SwiftUI
import MapKit
import SwiftData
import Photos
import PhotosUI
import Aptabase

// MARK: - FootprintModalView
// Replaces old FootprintDetailView content to ensure scope visibility

class ReasonState: ObservableObject {
    @Published var text: String = ""
}

struct IsolatedReasonField: View {
    @ObservedObject var reasonState: ReasonState
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        TextField("输入感悟...", text: $reasonState.text, axis: .vertical)
            .font(.body)
            .foregroundColor(Color.dfkMainText.opacity(0.85))
            .focused($isFocused)
    }
}

struct FootprintModalView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager
    @ObservedObject var photoService = PhotoService.shared
    @Bindable var footprint: Footprint
    var allPlaces: [Place] = []
    var onDismiss: ((Bool) -> Void)? = nil
    
    @Query private var savedPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    
    @State private var hasChanged = false
    @State private var showMap = false
    @State private var showAI = false
    @FocusState private var addressFocused: Bool
    @FocusState private var reasonFocused: Bool
    @StateObject private var reasonState = ReasonState()
    var autoFocus: Bool = false
    @State private var showingDeleteAlert = false
    @State private var showAddPhotoDialog = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotoID: String? = nil
    @State private var showAddPlaceModal = false
    @State private var isUpdatingAddress = false
    @State private var mapPhotos: [PHAsset] = []
    
    @State private var showFullscreenMap = false
    @AppStorage("isAutoPhotoLinkEnabled") private var isAutoPhotoLinkEnabled = true
    @AppStorage("hasSeenPhotoPermissionGuide") private var hasSeenPhotoPermissionGuide = false
    
    @State private var showingPhotoDeleteAlert = false
    @State private var photoToDelete: String? = nil
    @State private var showingSearchSheet = false
    @State private var showingActivityTypeEditor = false
    @State private var showingTimeAdjustment = false
    
    var isDraft: Bool = false
    
    init(footprint: Footprint, allPlaces: [Place] = [], autoFocus: Bool = false, isDraft: Bool = false, onDismiss: ((Bool) -> Void)? = nil) {
        self._footprint = Bindable(footprint)
        self.allPlaces = allPlaces
        self.autoFocus = autoFocus
        self.isDraft = isDraft
        self.onDismiss = onDismiss
    }
    
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var isGeneratingAI = false
    @State private var showingAINotEnabledAlert = false
    @State private var showingAIErrorAlert = false
    @State private var aiErrorMessage = ""
    @State private var isAIPerformingUpdate = false
    
    private func ensureFootprintManaged() {
        if isDraft { return }
        if footprint.modelContext == nil {
            // 核心修复：防止因编辑“幻影”克隆体导致数据库产生重复记录
            let uuid = footprint.footprintID
            let descriptor = FetchDescriptor<Footprint>(predicate: #Predicate { $0.footprintID == uuid })
            let count = (try? modelContext.fetchCount(descriptor)) ?? 0
            if count > 0 {
                // 如果数据库里已经有这个 UUID 的记录了，说明这一支是克隆出来的，不应重复插入
                return
            }
            
            modelContext.insert(footprint)
            // 注意：幻影足迹的 hash 是带时间戳后缀的 (如 GAP_STAY_12345)，所以必须用 hasPrefix
            if footprint.locationHash.hasPrefix("GAP_STAY") {
                footprint.locationHash = "MANUAL_STAY"
            } else if footprint.locationHash == "ONGOING_STAY" {
                footprint.locationHash = "MANUAL_STAY"
            }
            try? modelContext.save()
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    headerContent
                    
                    if showMap {
                        mapContent
                    } else {
                        mapSkeleton
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                    }
                    
                    footerContent
                    
                    Spacer().frame(height: 30)
                }
                .contentShape(Rectangle())
                .onTapGesture { 
                    addressFocused = false
                    reasonFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("足迹详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { 
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.3)) {
                            ensureFootprintManaged()
                            footprint.isHighlight = !(footprint.isHighlight ?? false)
                            Aptabase.shared.trackEvent("footprint_highlighted")
                            hasChanged = true
                            if !isDraft { try? modelContext.save() }
                        }
                    } label: {
                        Image(systemName: (footprint.isHighlight ?? false) ? "star.fill" : "star")
                            .foregroundColor((footprint.isHighlight ?? false) ? Color.dfkHighlight : .secondary)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { 
                        // checkAndGenerateAIContent() // Removed AI generation for titles/remarks
                        saveDraftReasonIfNeeded()
                        if !isDraft { try? modelContext.save() }
                        onDismiss?(hasChanged)
                        dismiss() 
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .alert("确认删除足迹？", isPresented: $showingDeleteAlert) {
                Button("删除", role: .destructive) { ignoreFootprint() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后，该足迹将不再出现在时间轴上。")
            }
            .sheet(isPresented: $showingActivityTypeEditor) {
                ActivityTypeEditorView()
            }
            .sheet(isPresented: $showingTimeAdjustment) {
                FootprintTimeAdjustmentView(footprint: footprint) {
                    hasChanged = true
                }
            }
            .onAppear {
                reasonState.text = footprint.reason ?? ""
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation(.easeOut(duration: 0.25)) { showMap = true } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(.easeOut(duration: 0.3)) { showAI = true } }
                
                if isAutoPhotoLinkEnabled {
                    locationManager.linkPhotos(to: footprint, context: modelContext)
                }
                
                if autoFocus {
                    // Slight longer delay to wait for sheet and keyboard animation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        addressFocused = true
                        // Give it another moment for focus to take effect so that selectAll works
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                        }
                    }
                }
                
                // Fetch address if missing
                if footprint.address == nil {
                    refreshAddress()
                }
                
                enrichPlaceIfNeeded()

                refreshMapPhotos()
                
                // 第一次进入足迹详情且状态为“未定义”时，强提示授权
                if !hasSeenPhotoPermissionGuide && PhotoService.shared.authorizationStatus == .notDetermined {
                    // 我们可以在这里简单打个标记，页面底部的大按钮（原本就有的引导位）已经能承担说明作用。
                    // 为了满足用户说的“说明并请求”，我们可以考虑在这里触发一个弹窗或者在该页面显式滚动到该区域（当前卡片已有按钮）。
                    hasSeenPhotoPermissionGuide = true
                }
            }
            .onChange(of: footprint.photoAssetIDs) { _, _ in
                refreshMapPhotos()
            }
            .sheet(isPresented: $showCamera) {
                CameraPickerView { image in
                    guard let image = image else { return }
                    Task {
                        var localID: String?
                        if let data = image.jpegData(compressionQuality: 0.8) {
                           try? await PHPhotoLibrary.shared().performChanges {
                               let req = PHAssetCreationRequest.forAsset()
                               req.addResource(with: .photo, data: data, options: nil)
                               localID = req.placeholderForCreatedAsset?.localIdentifier
                           }
                        }
                        if let id = localID {
                            // Eagerly fetch cloud identifier to ensure sync metadata is ready
                            let mappings = await PhotoService.shared.getCloudIdentifiers(for: [id])
                            let cloudID = mappings[id]
                            
                            await MainActor.run {
                                ensureFootprintManaged()
                                withAnimation {
                                    var ids = footprint.photoAssetIDs
                                    ids.append(id)
                                    footprint.photoAssetIDs = ids
                                    
                                    if let cloudID = cloudID {
                                        footprint.photoMetadata.append(PhotoMetadata(localIdentifier: id, cloudIdentifier: cloudID))
                                    }
                                    
                                    hasChanged = true
                                }
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker { identifiers in
                    attachSelectedPhotoAssetIdentifiers(identifiers)
                }
            }
            .sheet(isPresented: $showingSearchSheet) {
                LocationSearchSheet(locationManager: locationManager, 
                                    coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), 
                                    forOngoing: false, 
                                    footprint: footprint,
                                    isDraft: isDraft)
            }
            .sheet(item: Binding(get: { selectedPhotoID.map { IdentifiableString(value: $0) } }, set: { selectedPhotoID = $0?.value })) { item in
                let index = footprint.photoAssetIDs.firstIndex(of: item.value) ?? 0
                PhotoFullscreenView(assetIDs: footprint.photoAssetIDs, currentIndex: index)
            }
            .sheet(isPresented: $showAddPlaceModal) {
                AddToFavoriteModal(footprint: footprint)
            }
            .sheet(isPresented: $showFullscreenMap) {
                FullFrameMapView(footprint: footprint, photoAssets: mapPhotos)
            }
            .alert("确认移除照片？", isPresented: $showingPhotoDeleteAlert) {
                Button("移除", role: .destructive) { deletePhoto() }
                Button("取消", role: .cancel) { photoToDelete = nil }
            } message: {
                Text("这张照片将从该足迹中移除。")
            }
            .alert("开启 AI 智能助手", isPresented: $showingAINotEnabledAlert) {
                Button("立刻开启") { 
                    isAiAssistantEnabled = true
                }
                .tint(Color.dfkAccent)
                
                Button("暂时不用", role: .cancel) { }
            } message: {
                Text("开启后，地方客将利用 AI 为您的足迹自动建议标题和感悟，让您的记录更生动。")
            }
            .alert("AI 分析失败", isPresented: $showingAIErrorAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(aiErrorMessage)
            }
        .onDisappear {
            saveDraftReasonIfNeeded()
            if hasChanged {
                Aptabase.shared.trackEvent("footprint_edited")
                footprint.status = .manual
            }
            if !isDraft {
                try? modelContext.save()
            }
            onDismiss?(hasChanged)
        }
    }
}
}

extension FootprintModalView {
    private func saveDraftReasonIfNeeded() {
        let text = reasonState.text
        if text != (footprint.reason ?? "") {
            ensureFootprintManaged()
            footprint.reason = text
            footprint.aiAnalyzed = true
            footprint.status = .manual
            if footprint.locationHash == "ONGOING_STAY" {
                footprint.locationHash = "MANUAL_STAY"
            }
            hasChanged = true
            if !isDraft { try? modelContext.save() }
        }
    }

    private func openPhotoPicker() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            showPhotoPicker = true
        case .notDetermined:
            PhotoService.shared.requestPermission { granted in
                guard granted else { return }
                showPhotoPicker = true
            }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    private func attachSelectedPhotoAssetIdentifiers(_ resolvedIdentifiers: [String]) {
        guard !resolvedIdentifiers.isEmpty else { return }

        ensureFootprintManaged()

        let existingIdentifiers = Set(footprint.photoAssetIDs)
        let newIdentifiers = resolvedIdentifiers.filter { !existingIdentifiers.contains($0) }
        guard !newIdentifiers.isEmpty else { return }

        Task {
            // Eagerly fetch cloud identifiers for sync
            let mappings = await PhotoService.shared.getCloudIdentifiers(for: newIdentifiers)
            
            await MainActor.run {
                withAnimation {
                    footprint.photoAssetIDs.append(contentsOf: newIdentifiers)
                    
                    for id in newIdentifiers {
                        if let cloudID = mappings[id] {
                            footprint.photoMetadata.append(PhotoMetadata(localIdentifier: id, cloudIdentifier: cloudID))
                        }
                    }
                    
                    footprint.status = .manual
                    hasChanged = true
                }

                try? modelContext.save()
                refreshMapPhotos()
            }
        }
    }

    private func refreshMapPhotos() {
        guard !footprint.photoAssetIDs.isEmpty else {
            mapPhotos = []
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: footprint.photoAssetIDs, options: nil)
        var fetchedAssets: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            if asset.location != nil {
                fetchedAssets.append(asset)
            }
        }

        let orderedAssets = footprint.photoAssetIDs.compactMap { assetID in
            fetchedAssets.first(where: { $0.localIdentifier == assetID })
        }

        mapPhotos = orderedAssets
    }

    private func deletePhoto() {
        guard let assetID = photoToDelete else { return }
        ensureFootprintManaged()
        withAnimation {
            var ids = footprint.photoAssetIDs
            ids.removeAll(where: { $0 == assetID })
            footprint.photoAssetIDs = ids
            footprint.status = .manual // 标记为人工修改，防止被重置
            hasChanged = true
            if !isDraft { try? modelContext.save() }
        }
        photoToDelete = nil
    }
    
    
    
    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                SuggestionsMenuContent(locationManager: locationManager, coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), forOngoing: false, footprint: footprint, isDraft: isDraft) {
                    showingSearchSheet = true
                }
            } label: {
                detailMenuRow(
                    title: nil,
                    value: isUpdatingAddress ? "正在重新获取地址..." : displayPlaceText,
                    valueColor: isUpdatingAddress ? Color.dfkMainText.opacity(0.5) : (matchedPlaceByAddress != nil ? .orange : Color.dfkMainText),
                    valueFont: placeValueFont,
                    textLineLimit: 1,
                    textMinimumScaleFactor: 0.72,
                    iconFont: .system(size: 18, weight: .semibold),
                    leadingIcon: "mappin.and.ellipse"
                )
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    clearActivityType()
                } label: {
                    Label("无", systemImage: "circle.slash")
                }
                
                let genuineSuggestions = getSuggestedActivities(includeFallback: false)
                if !genuineSuggestions.isEmpty {
                    Section("推荐活动") {
                        ForEach(genuineSuggestions) { type in
                            Button {
                                applyActivityType(type)
                            } label: {
                                Label(type.name, systemImage: type.icon)
                            }
                        }
                    }
                }
                
                Section("所有活动") {
                    ForEach(allActivities) { type in
                        Button {
                            applyActivityType(type)
                        } label: {
                            Label(type.name, systemImage: type.icon)
                        }
                    }
                }

                Divider()

                Button {
                    showingActivityTypeEditor = true
                } label: {
                    Label("添加活动类型", systemImage: "plus")
                }
            } label: {
                detailMenuRow(
                    title: nil,
                    value: selectedActivityName,
                    valueColor: selectedActivityColor,
                    valueFont: .system(size: 16, weight: .semibold, design: .rounded),
                    textColor: .primary,
                    iconFont: .system(size: 16, weight: .semibold),
                    leadingIcon: selectedActivityIcon
                )
            }
            .buttonStyle(.plain)

            if footprint.activityTypeValue == nil {
                activitySuggestionsRow
                    .padding(.top, -2)
            }
        }
    }

    private var matchedPlaceByAddress: Place? {
        savedPlaces.first(where: { place in
            if place.placeID == footprint.placeID && place.isUserDefined { return true }
            guard place.isUserDefined else { return false }
            let fpAddr = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fpAddr.isEmpty else { return false }
            return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr ||
            place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr
        })
    }

    private var displayPlaceText: String {
        matchedPlaceByAddress?.name ?? footprint.address ?? "未知地点"
    }

    private var placeValueFont: Font {
        let text = isUpdatingAddress ? "正在重新获取地址..." : displayPlaceText
        let count = text.count

        switch count {
        case ...10:
            return .system(.title3, design: .rounded).bold()
        case 11...16:
            return .system(size: 18, weight: .bold, design: .rounded)
        case 17...24:
            return .system(size: 16, weight: .semibold, design: .rounded)
        default:
            return .system(size: 15, weight: .semibold, design: .rounded)
        }
    }

    private var selectedActivityName: String {
        footprint.getActivityType(from: allActivities)?.name ?? "活动类型"
    }

    private var selectedActivityIcon: String {
        footprint.getActivityType(from: allActivities)?.icon ?? "questionmark.circle.dashed"
    }

    private var selectedActivityColor: Color {
        footprint.getActivityType(from: allActivities)?.color ?? .secondary
    }

    @ViewBuilder
    private func detailMenuRow(
        title: String?,
        value: String,
        valueColor: Color,
        valueFont: Font = .system(.title3, design: .rounded).bold(),
        textColor: Color? = nil,
        textLineLimit: Int = 2,
        textMinimumScaleFactor: CGFloat = 1,
        iconFont: Font = .system(size: 13, weight: .semibold),
        leadingIcon: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 6) {
                    if let leadingIcon {
                        Image(systemName: leadingIcon)
                            .font(iconFont)
                            .foregroundColor(valueColor)
                    }

                    Text(value)
                        .font(valueFont)
                        .foregroundColor(textColor ?? valueColor)
                        .lineLimit(textLineLimit)
                        .minimumScaleFactor(textMinimumScaleFactor)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
        .contentShape(Rectangle())
    }
    
    private var activitySuggestionsRow: some View {
        let suggestions = getSuggestedActivities()
        return HStack(spacing: 0) {
            Text("可能的活动")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.leading, 12)
                .padding(.trailing, 2)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { activity in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                ensureFootprintManaged()
                                footprint.activityTypeValue = activity.id.uuidString
                                footprint.status = .manual
                                hasChanged = true
                                if !isDraft { try? modelContext.save() }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: activity.icon)
                                    .font(.system(size: 13))
                                Text(activity.name)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(activity.color.opacity(0.08))
                                    .overlay(Capsule().stroke(activity.color.opacity(0.15), lineWidth: 0.5))
                            )
                            .foregroundColor(activity.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.04))
        )
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }
    
    private func getSuggestedActivities(includeFallback: Bool = true) -> [ActivityType] {
        let liteActivities = allActivities.map { $0.convertToLite() }
        let litePlaces = savedPlaces.map { $0.convertToLite() }
        let suggestions = ActivityType.getSuggestedActivities(for: footprint, allActivities: liteActivities, allPlaces: litePlaces, includeFallback: includeFallback)
        
        return suggestions.compactMap { lite in
            allActivities.first { $0.id == lite.id }
        }
    }

    private func clearActivityType() {
        withAnimation {
            ensureFootprintManaged()
            footprint.activityTypeValue = nil
            footprint.status = .manual
            hasChanged = true
            if !isDraft { try? modelContext.save() }
        }
    }

    private func applyActivityType(_ type: ActivityType) {
        withAnimation {
            ensureFootprintManaged()
            footprint.activityTypeValue = type.id.uuidString
            footprint.status = .manual
            hasChanged = true
            if !isDraft { try? modelContext.save() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    
    private var timeSection: some View {
        Button {
            showingTimeAdjustment = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                            .foregroundColor(Color.secondary)
                        Text(footprint.date.formatted(.dateTime.year().month().day().weekday()))
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(Color.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundColor(Color.secondary)
                        Text(timeRangeString)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 12))
                            .foregroundColor(Color.secondary)
                        Text("停留 \(durationString)")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(Color.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("调整足迹时间")
        .padding(.top, 4)
    }
    
    private var matchedPlace: Place? {
        savedPlaces.first(where: { $0.placeID == footprint.placeID && $0.isUserDefined })
    }
    
    private func enrichPlaceIfNeeded() {
        guard let place = matchedPlace, place.category == nil else { return }
        let name = place.name
        let coordinate = place.coordinate
        
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            request.region = MKCoordinateRegion(center: coordinate, 
                                               latitudinalMeters: 200, 
                                               longitudinalMeters: 200)
            let search = MKLocalSearch(request: request)
            if let response = try? await search.start() {
                if let item = response.mapItems.first(where: { 
                    $0.name?.contains(name) == true || name.contains($0.name ?? "")
                }) ?? response.mapItems.first {
                    place.category = item.pointOfInterestCategory?.rawValue
                    if !isDraft { try? modelContext.save() }
                }
            }
        }
    }
    

    
    private var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let startStr = formatter.string(from: footprint.startTime)
        let endStr = formatter.string(from: footprint.endTime)
        
        let calendar = Calendar.current
        let isStartSameDay = calendar.isDate(footprint.startTime, inSameDayAs: footprint.date)
        let isEndSameDay = calendar.isDate(footprint.endTime, inSameDayAs: footprint.date)
        
        if isStartSameDay && isEndSameDay {
            return "\(startStr)-\(endStr)"
        } else if !isStartSameDay && isEndSameDay {
            return "昨日\(startStr)-\(endStr)"
        } else if isStartSameDay && !isEndSameDay {
            return "\(startStr)-次日\(endStr)"
        } else {
            let monthDayFormatter = DateFormatter()
            monthDayFormatter.dateFormat = "M月d日 HH:mm"
            return "\(monthDayFormatter.string(from: footprint.startTime))-\(monthDayFormatter.string(from: footprint.endTime))"
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
    
    private func refreshAddress() {
        guard !isUpdatingAddress else { return }
        isUpdatingAddress = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        let geocoder = CLGeocoder()
        let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        geocoder.reverseGeocodeLocation(loc) { placemarks, error in
            DispatchQueue.main.async {
                self.isUpdatingAddress = false
                if let pm = placemarks?.first {
                    let poiName = pm.areasOfInterest?.first
                    let name = [poiName, pm.name, pm.thoroughfare].compactMap { $0 }.first
                    
                    let locality = pm.locality ?? ""
                    let subLocality = pm.subLocality ?? ""
                    let result = locality + subLocality + (name ?? "")
                    
                    if !result.isEmpty {
                        withAnimation {
                            ensureFootprintManaged()
                            footprint.address = result
                            hasChanged = true
                            if !isDraft { try? modelContext.save() }
                        }
                    }
                }
            }
        }
    }
    
    private var headerContent: some View {
        Group {
            addressSection.padding(.horizontal, 24).padding(.top, 16)
            timeSection.padding(.horizontal, 24).padding(.top, 12)
        }
    }
    
    
    private var footerContent: some View {
        Group {
            aiContent
            photoSection.padding(.horizontal, 24).padding(.top, 16)
        }
    }
    
    private var mapContent: some View {
        mapSection
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
    
    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("位置轨迹").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 8)
            Button {
                showFullscreenMap = true
            } label: {
                FootprintDetailMapView(footprint: footprint, photoAssets: mapPhotos, isInteractive: false, showsStandalonePhotos: true)
                    .frame(height: 220)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(SpringButtonStyle())
        }
    }
    
    private var aiContent: some View {
        aiSection
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    
    private var mapSkeleton: some View { RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .tertiarySystemGroupedBackground)).frame(height: 220).overlay(ProgressView().scaleEffect(1.2)) }
    
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("足迹感悟与备注").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 8)
            
            HStack(alignment: .top, spacing: 6) {
                IsolatedReasonField(reasonState: reasonState, isFocused: $reasonFocused)
                
                if !reasonFocused {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 6)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(reasonFocused ? Color.dfkAccent.opacity(0.05) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(reasonFocused ? Color.dfkAccent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .onChange(of: reasonFocused) { _, focused in
                if !focused {
                    saveDraftReasonIfNeeded()
                }
            }
        }
    }
    
    
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记录瞬间").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button {
                    showAddPhotoDialog = true
                } label: {
                    Label("添加", systemImage: "photo.badge.plus")
                        .font(.caption.bold())
                        .foregroundColor(.dfkAccent)
                }
                .confirmationDialog("添加照片", isPresented: $showAddPhotoDialog) {
                    Button("拍摄照片") { showCamera = true }
                    Button("从相册选择") { openPhotoPicker() }
                    Button("取消", role: .cancel) { }
                }
            }
            .padding(.leading, 4)
            
            if footprint.photoAssetIDs.isEmpty {
                if PhotoService.shared.authorizationStatus == .notDetermined {
                    // Contextual Permission Request
                    Button {
                        PhotoService.shared.requestPermission { granted in
                            if granted {
                                // Trigger refresh immediately if granted
                                PhotoService.shared.fetchAssets(startTime: footprint.startTime, endTime: footprint.endTime, near: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)) { assets in
                                    if !assets.isEmpty {
                                        let foundIDs = assets.map { $0.localIdentifier }
                                        withAnimation {
                                            let combined = NSMutableOrderedSet(array: footprint.photoAssetIDs)
                                            combined.addObjects(from: foundIDs)
                                            footprint.photoAssetIDs = combined.array as? [String] ?? foundIDs
                                            hasChanged = true
                                            if !isDraft { try? modelContext.save() }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "photo.stack.fill")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                Text("开启自动关联照片")
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            Text("授权相册后，地方客能自动识别并展示您在该时段和地点拍摄的照片。")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showAddPhotoDialog = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.title2)
                            Text("拍摄或选择照片").font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .background(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
                    }
                    .confirmationDialog("添加照片", isPresented: $showAddPhotoDialog) {
                        Button("拍摄照片") { showCamera = true }
                        Button("从相册选择") { openPhotoPicker() }
                        Button("取消", role: .cancel) { }
                    }
                }
            } else {
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(footprint.photoAssetIDs, id: \.self) { assetID in
                        AssetThumbnailView(assetID: assetID, showsTime: true)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { selectedPhotoID = assetID }
                            .contextMenu {
                                Button(role: .destructive) {
                                    photoToDelete = assetID
                                    showingPhotoDeleteAlert = true
                                } label: {
                                    Label("移除照片", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }
    
    private func ignoreFootprint() { 
        Aptabase.shared.trackEvent("footprint_deleted")
        withAnimation { 
            hasChanged = true
        }
        if let context = footprint.modelContext {
            context.delete(footprint)
        }
        try? modelContext.save()
        onDismiss?(hasChanged)
        dismiss() 
    }
}

struct FullFrameMapView: View {
    let footprint: Footprint
    var photoAssets: [PHAsset] = []
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            FootprintDetailMapView(footprint: footprint, photoAssets: photoAssets, isInteractive: true, showsStandalonePhotos: true)
                .navigationTitle("足迹地图")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
        }
    }
}

private struct FootprintTimeAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var footprint: Footprint
    let onSave: () -> Void

    @State private var rangeStart: Date = Date()
    @State private var rangeEnd: Date = Date()
    @State private var draftStart: Date = Date()
    @State private var draftEnd: Date = Date()
    @State private var rawPoints: [CLLocation] = []
    @State private var isLoadingRawPoints = true
    @State private var hasInitializedRange = false

    private var minimumFootprintDuration: TimeInterval {
        max(60, ceil(AppConfig.shared.stayDurationThreshold / 60) * 60)
    }

    private var selectedPoints: [CLLocation] {
        rawPoints.filter { $0.timestamp >= draftStart && $0.timestamp <= draftEnd }
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        selectedPoints
            .map(\.coordinate)
            .filter(\.isRawPointsRenderable)
    }

    private var canSave: Bool {
        hasInitializedRange && draftEnd.timeIntervalSince(draftStart) >= minimumFootprintDuration
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    if proxy.size.width > 1 && proxy.size.height > 1 {
                        FootprintTimeAdjustmentMapView(coordinates: selectedCoordinates)
                            .frame(minWidth: 1, minHeight: 1)
                    }
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomLeading) {
                    Text(isLoadingRawPoints ? "加载轨迹点..." : "\(selectedPoints.count) 个原始点")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(12)
                    }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("调整时间")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(timeText(hasInitializedRange ? draftStart : footprint.startTime))-\(timeText(hasInitializedRange ? draftEnd : footprint.endTime))")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(.dfkMainText)
                    }

                    if hasInitializedRange {
                        FootprintTimeRangeSlider(
                            rangeStart: rangeStart,
                            rangeEnd: rangeEnd,
                            start: $draftStart,
                            end: $draftEnd
                        )
                        .frame(height: 34)
                    } else {
                        Color.clear
                            .frame(height: 34)
                    }

                    HStack {
                        Text(timeText(hasInitializedRange ? rangeStart : footprint.startTime))
                        Spacer()
                        Text(timeText(hasInitializedRange ? rangeEnd : footprint.endTime))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("调整时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveAdjustment()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            setupInitialRange()
            loadRawPoints()
        }
    }

    private func setupInitialRange() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: footprint.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        rangeStart = max(previousFootprintEnd(defaultingTo: dayStart), dayStart)
        rangeEnd = min(nextFootprintStart(defaultingTo: dayEnd), dayEnd)

        if rangeEnd <= rangeStart {
            rangeStart = dayStart
            rangeEnd = dayEnd
        }

        draftStart = min(max(footprint.startTime, rangeStart), rangeEnd.addingTimeInterval(-minimumFootprintDuration))
        draftEnd = max(min(footprint.endTime, rangeEnd), draftStart.addingTimeInterval(minimumFootprintDuration))
        hasInitializedRange = true
    }

    private func loadRawPoints() {
        isLoadingRawPoints = true
        let dates = touchedDates(start: rangeStart, end: rangeEnd)
        Task {
            let points = await Task.detached {
                dates.flatMap { RawLocationStore.shared.loadAllDevicesLocations(for: $0) }
                    .sorted { $0.timestamp < $1.timestamp }
            }.value
            await MainActor.run {
                rawPoints = points
                isLoadingRawPoints = false
            }
        }
    }

    private func previousFootprintEnd(defaultingTo fallback: Date) -> Date {
        let id = footprint.footprintID
        let start = footprint.startTime
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.footprintID != id && $0.endTime <= start && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor).first?.endTime) ?? fallback
    }

    private func nextFootprintStart(defaultingTo fallback: Date) -> Date {
        let id = footprint.footprintID
        let end = footprint.endTime
        let descriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.footprintID != id && $0.startTime >= end && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        return (try? modelContext.fetch(descriptor).first?.startTime) ?? fallback
    }

    private func saveAdjustment() {
        let oldStart = footprint.startTime
        let oldEnd = footprint.endTime
        let roundedStart = roundedToMinute(draftStart)
        let roundedEnd = roundedToMinute(max(draftEnd, roundedStart.addingTimeInterval(minimumFootprintDuration)))
        let didChangeStart = minuteKey(oldStart) != minuteKey(roundedStart)
        let didChangeEnd = minuteKey(oldEnd) != minuteKey(roundedEnd)

        guard didChangeStart || didChangeEnd else {
            dismiss()
            return
        }

        let start = didChangeStart ? roundedStart : oldStart
        let end = didChangeEnd ? max(roundedEnd, start.addingTimeInterval(minimumFootprintDuration)) : max(oldEnd, start.addingTimeInterval(minimumFootprintDuration))

        footprint.startTime = start
        footprint.endTime = end
        footprint.date = Calendar.current.startOfDay(for: start)
        footprint.status = .manual
        if footprint.locationHash == "ONGOING_STAY" || footprint.locationHash.hasPrefix("GAP_STAY") {
            footprint.locationHash = "MANUAL_STAY"
        }

        let coordinates = rawPoints
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map(\.coordinate)
            .filter(\.isRawPointsRenderable)
        if !coordinates.isEmpty {
            footprint.footprintLocations = coordinates
        }

        adjustAdjacentTransports(
            oldStart: oldStart,
            oldEnd: oldEnd,
            newStart: start,
            newEnd: end,
            didChangeStart: didChangeStart,
            didChangeEnd: didChangeEnd
        )
        try? modelContext.save()
        invalidateCaches(oldStart: oldStart, oldEnd: oldEnd, newStart: start, newEnd: end)
        onSave()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func adjustAdjacentTransports(
        oldStart: Date,
        oldEnd: Date,
        newStart: Date,
        newEnd: Date,
        didChangeStart: Bool,
        didChangeEnd: Bool
    ) {
        if didChangeStart, let previous = adjacentTransport(endingAtFootprintStart: oldStart) {
            previous.endTime = newStart
            previous.day = Calendar.current.startOfDay(for: previous.startTime)
            refreshTransportMetrics(previous)
        }

        if didChangeEnd, let next = adjacentTransport(startingAtFootprintEnd: oldEnd) {
            next.startTime = newEnd
            next.day = Calendar.current.startOfDay(for: next.startTime)
            refreshTransportMetrics(next)
        }
    }

    private func adjacentTransport(endingAtFootprintStart date: Date) -> TransportRecord? {
        let lower = date.addingTimeInterval(-30 * 60)
        let upper = date.addingTimeInterval(60)
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.startTime < date && $0.endTime >= lower && $0.endTime <= upper && $0.statusRaw != "ignored"
            },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func adjacentTransport(startingAtFootprintEnd date: Date) -> TransportRecord? {
        let lower = date.addingTimeInterval(-60)
        let upper = date.addingTimeInterval(30 * 60)
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate {
                $0.endTime > date && $0.startTime >= lower && $0.startTime <= upper && $0.statusRaw != "ignored"
            },
            sortBy: [SortDescriptor(\.startTime)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func refreshTransportMetrics(_ record: TransportRecord) {
        guard record.endTime > record.startTime else {
            record.statusRaw = "ignored"
            return
        }

        if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: record.pointsData) {
            let filtered = decoded.filter { point in
                guard let timestamp = point.timestamp else { return point.isSyntheticPadding == true }
                return timestamp >= record.startTime && timestamp <= record.endTime
            }
            if !filtered.isEmpty, let data = try? JSONEncoder().encode(filtered) {
                record.pointsData = data
                record.distance = TimelineBuilder.calculatePathDistance(filtered)
            }
        }

        let duration = record.endTime.timeIntervalSince(record.startTime)
        if duration > 0 {
            record.averageSpeed = record.distance / duration
        }
    }

    private func invalidateCaches(oldStart: Date, oldEnd: Date, newStart: Date, newEnd: Date) {
        var dates = Set<Date>()
        dates.formUnion(touchedDates(start: oldStart, end: oldEnd))
        dates.formUnion(touchedDates(start: newStart, end: newEnd))
        dates.formUnion(touchedDates(start: rangeStart, end: rangeEnd))

        for date in dates {
            TimelineBuilder.timelineCache.removeValue(forKey: date)
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": Calendar.current.startOfDay(for: newStart)]
        )
    }

    private func touchedDates(start: Date, end: Date) -> Set<Date> {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = max(start, end.addingTimeInterval(-0.001))
        let endDay = calendar.startOfDay(for: effectiveEnd)
        var result: Set<Date> = []
        var cursor = startDay

        while cursor <= endDay {
            result.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded())
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct FootprintSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]

    @Bindable var footprint: Footprint

    @State private var splitTime: Date = Date()
    @State private var rawPoints: [CLLocation] = []
    @State private var isLoadingRawPoints = true
    @State private var firstActivityTypeValue: String?
    @State private var secondActivityTypeValue: String?
    @State private var hasInitializedActivityDrafts = false

    private var minimumFootprintDuration: TimeInterval {
        max(60, ceil(AppConfig.shared.stayDurationThreshold / 60) * 60)
    }

    private var canSplit: Bool {
        footprint.endTime.timeIntervalSince(footprint.startTime) >= minimumFootprintDuration * 2
    }

    private var boundedSplitTime: Date {
        let minSplit = footprint.startTime.addingTimeInterval(minimumFootprintDuration)
        let maxSplit = footprint.endTime.addingTimeInterval(-minimumFootprintDuration)
        return min(max(splitTime, minSplit), maxSplit)
    }

    private var selectedPoints: [CLLocation] {
        rawPoints.filter { $0.timestamp >= footprint.startTime && $0.timestamp <= footprint.endTime }
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        if !selectedPoints.isEmpty {
            return selectedPoints.map(\.coordinate).filter(\.isRawPointsRenderable)
        }
        return footprint.footprintLocations.filter(\.isRawPointsRenderable)
    }

    private var splitCoordinate: CLLocationCoordinate2D? {
        coordinate(at: boundedSplitTime)
    }

    private var firstSegmentCoordinates: [CLLocationCoordinate2D] {
        coordinates(from: footprint.startTime, to: boundedSplitTime, fallbackStartRatio: 0, fallbackEndRatio: splitRatio)
    }

    private var secondSegmentCoordinates: [CLLocationCoordinate2D] {
        coordinates(from: boundedSplitTime, to: footprint.endTime, fallbackStartRatio: splitRatio, fallbackEndRatio: 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { proxy in
                    if proxy.size.width > 1 && proxy.size.height > 1 {
                        FootprintTimeAdjustmentMapView(
                            coordinates: selectedCoordinates,
                            leadingCoordinates: firstSegmentCoordinates,
                            trailingCoordinates: secondSegmentCoordinates,
                            markerCoordinate: splitCoordinate
                        )
                        .frame(minWidth: 1, minHeight: 1)
                    }
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomLeading) {
                    Text(isLoadingRawPoints ? "加载轨迹点..." : "\(selectedPoints.count) 个原始点")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                            .padding(12)
                    }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("分割点")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(timeText(boundedSplitTime))
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(.dfkMainText)
                    }

                    FootprintSplitSlider(
                        rangeStart: footprint.startTime,
                        rangeEnd: footprint.endTime,
                        split: $splitTime,
                        minimumDuration: minimumFootprintDuration
                    )
                    .frame(height: 34)

                    HStack {
                        Text(timeText(footprint.startTime))
                        Spacer()
                        Text(timeText(footprint.endTime))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))

                VStack(spacing: 12) {
                    SplitPreviewFootprintCard(
                        segmentTitle: "新足迹",
                        title: previewTitle,
                        borderColor: .blue,
                        start: boundedSplitTime,
                        end: footprint.endTime,
                        activities: allActivities,
                        activityTypeValue: $secondActivityTypeValue
                    )
                    SplitPreviewFootprintCard(
                        segmentTitle: "原足迹",
                        title: previewTitle,
                        borderColor: .green,
                        start: footprint.startTime,
                        end: boundedSplitTime,
                        activities: allActivities,
                        activityTypeValue: $firstActivityTypeValue
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("拆分足迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveSplit()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .disabled(!canSplit)
                }
            }
        }
        .onAppear {
            splitTime = midpointDate
            initializeActivityDraftsIfNeeded()
            loadRawPoints()
        }
    }

    private var midpointDate: Date {
        footprint.startTime.addingTimeInterval(footprint.endTime.timeIntervalSince(footprint.startTime) / 2)
    }

    private var previewTitle: String {
        footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? footprint.address! : "未知地点"
    }

    private func initializeActivityDraftsIfNeeded() {
        guard !hasInitializedActivityDrafts else { return }
        firstActivityTypeValue = footprint.activityTypeValue
        secondActivityTypeValue = footprint.activityTypeValue
        hasInitializedActivityDrafts = true
    }

    private func loadRawPoints() {
        isLoadingRawPoints = true
        let dates = touchedDates(start: footprint.startTime, end: footprint.endTime)
        Task {
            let points = await Task.detached {
                dates.flatMap { RawLocationStore.shared.loadAllDevicesLocations(for: $0) }
                    .sorted { $0.timestamp < $1.timestamp }
            }.value
            await MainActor.run {
                rawPoints = points
                isLoadingRawPoints = false
            }
        }
    }

    private func coordinate(at date: Date) -> CLLocationCoordinate2D? {
        let points = selectedPoints
        if let nearest = points.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) {
            return nearest.coordinate.isRawPointsRenderable ? nearest.coordinate : nil
        }

        let coordinates = footprint.footprintLocations.filter(\.isRawPointsRenderable)
        guard !coordinates.isEmpty else { return nil }
        let ratio = date.timeIntervalSince(footprint.startTime) / max(1, footprint.endTime.timeIntervalSince(footprint.startTime))
        let index = min(max(0, Int((Double(coordinates.count - 1) * ratio).rounded())), coordinates.count - 1)
        return coordinates[index]
    }

    private func saveSplit() {
        guard canSplit else { return }

        let split = roundedToMinute(boundedSplitTime)
        let oldStart = footprint.startTime
        let oldEnd = footprint.endTime
        let firstEnd = max(split, oldStart.addingTimeInterval(minimumFootprintDuration))
        let secondStart = min(split, oldEnd.addingTimeInterval(-minimumFootprintDuration))
        let ratio = split.timeIntervalSince(oldStart) / max(1, oldEnd.timeIntervalSince(oldStart))

        let firstCoordinates = coordinates(from: oldStart, to: firstEnd, fallbackStartRatio: 0, fallbackEndRatio: splitRatio)
        let secondCoordinates = coordinates(from: secondStart, to: oldEnd, fallbackStartRatio: splitRatio, fallbackEndRatio: 1)

        footprint.endTime = firstEnd
        footprint.date = Calendar.current.startOfDay(for: oldStart)
        footprint.status = .manual
        footprint.activityTypeValue = firstActivityTypeValue
        if !firstCoordinates.isEmpty {
            footprint.footprintLocations = firstCoordinates
        }
        if footprint.locationHash == "ONGOING_STAY" || footprint.locationHash.hasPrefix("GAP_STAY") {
            footprint.locationHash = "MANUAL_STAY"
        }

        let newFootprint = Footprint(
            date: Calendar.current.startOfDay(for: secondStart),
            startTime: secondStart,
            endTime: oldEnd,
            footprintLocations: secondCoordinates.isEmpty ? footprint.footprintLocations : secondCoordinates,
            locationHash: "MANUAL_SPLIT",
            duration: oldEnd.timeIntervalSince(secondStart),
            reason: footprint.reason,
            status: .manual,
            aiScore: footprint.aiScore,
            isHighlight: footprint.isHighlight,
            placeID: footprint.placeID,
            photoAssetIDs: [],
            address: footprint.address,
            isPlaceSuggestionIgnored: footprint.isPlaceSuggestionIgnored,
            aiAnalyzed: footprint.aiAnalyzed,
            isAddressEditedByHand: footprint.isAddressEditedByHand,
            activityTypeValue: secondActivityTypeValue,
            stepCount: splitMetric(footprint.stepCount, ratio: ratio, second: true),
            walkingDistance: splitMetric(footprint.walkingDistance, ratio: ratio, second: true),
            floorsAscended: splitMetric(footprint.floorsAscended, ratio: ratio, second: true)
        )
        newFootprint.photoMetadata = []

        footprint.stepCount = splitMetric(footprint.stepCount, ratio: ratio, second: false)
        footprint.walkingDistance = splitMetric(footprint.walkingDistance, ratio: ratio, second: false)
        footprint.floorsAscended = splitMetric(footprint.floorsAscended, ratio: ratio, second: false)

        modelContext.insert(newFootprint)
        try? modelContext.save()
        invalidateCaches(oldStart: oldStart, oldEnd: oldEnd)
        Aptabase.shared.trackEvent("footprint_split")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private var splitRatio: Double {
        boundedSplitTime.timeIntervalSince(footprint.startTime) / max(1, footprint.endTime.timeIntervalSince(footprint.startTime))
    }

    private func coordinates(from start: Date, to end: Date, fallbackStartRatio: Double, fallbackEndRatio: Double) -> [CLLocationCoordinate2D] {
        let rawCoordinates = selectedPoints
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map(\.coordinate)
            .filter(\.isRawPointsRenderable)
        if !rawCoordinates.isEmpty {
            return rawCoordinates
        }

        let coordinates = footprint.footprintLocations.filter(\.isRawPointsRenderable)
        guard !coordinates.isEmpty else { return [] }
        let lastIndex = coordinates.count - 1
        let startIndex = min(max(0, Int((Double(lastIndex) * fallbackStartRatio).rounded())), lastIndex)
        let endIndex = min(max(startIndex, Int((Double(lastIndex) * fallbackEndRatio).rounded())), lastIndex)
        return Array(coordinates[startIndex...endIndex])
    }

    private func splitMetric(_ value: Int?, ratio: Double, second: Bool) -> Int? {
        guard let value else { return nil }
        let first = Int((Double(value) * ratio).rounded())
        return second ? max(0, value - first) : first
    }

    private func splitMetric(_ value: Double?, ratio: Double, second: Bool) -> Double? {
        guard let value else { return nil }
        let first = value * ratio
        return second ? max(0, value - first) : first
    }

    private func invalidateCaches(oldStart: Date, oldEnd: Date) {
        let dates = touchedDates(start: oldStart, end: oldEnd)
        for date in dates {
            TimelineBuilder.timelineCache.removeValue(forKey: date)
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": Calendar.current.startOfDay(for: oldStart)]
        )
        if Calendar.current.isDateInToday(oldStart) || Calendar.current.isDateInToday(oldEnd) {
            locationManager.triggerNotificationSummaryRefresh()
        }
    }

    private func touchedDates(start: Date, end: Date) -> Set<Date> {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = max(start, end.addingTimeInterval(-0.001))
        let endDay = calendar.startOfDay(for: effectiveEnd)
        var result: Set<Date> = []
        var cursor = startDay

        while cursor <= endDay {
            result.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct FootprintSplitSlider: View {
    let rangeStart: Date
    let rangeEnd: Date
    @Binding var split: Date
    let minimumDuration: TimeInterval

    var body: some View {
        NativeTimeSlider(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            value: $split,
            allowedStart: rangeStart.addingTimeInterval(minimumDuration),
            allowedEnd: rangeEnd.addingTimeInterval(-minimumDuration),
            step: 60,
            minimumTrackTintColor: .systemGreen,
            maximumTrackTintColor: .systemBlue,
            accessibilityLabel: "分割点"
        )
    }
}

private struct SplitPreviewFootprintCard: View {
    let segmentTitle: String
    let title: String
    let borderColor: Color
    let start: Date
    let end: Date
    let activities: [ActivityType]
    @Binding var activityTypeValue: String?

    var body: some View {
        Menu {
            Button {
                activityTypeValue = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label("无", systemImage: "circle.slash")
            }

            ForEach(activities) { type in
                Button {
                    activityTypeValue = type.id.uuidString
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(type.name, systemImage: type.icon)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(iconColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(segmentTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(borderColor)
                        Text(title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.dfkMainText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        Text("\(timeText(start))-\(timeText(end))")
                            .font(.system(size: 12, design: .monospaced))
                        Text("·")
                        Text(durationText)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.65))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor.opacity(0.75), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var selectedActivity: ActivityType? {
        guard let activityTypeValue else { return nil }
        return activities.first { $0.id.uuidString == activityTypeValue || $0.name == activityTypeValue }
    }

    private var icon: String {
        selectedActivity?.icon ?? FootprintIconDefaults.card
    }

    private var iconColor: Color {
        selectedActivity?.color ?? .secondary.opacity(0.45)
    }

    private var durationText: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder > 0 ? "\(hours) 小时 \(remainder) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct FootprintTimeRangeSlider: UIViewRepresentable {
    let rangeStart: Date
    let rangeEnd: Date
    @Binding var start: Date
    @Binding var end: Date
    private let minimumDuration = max(60, ceil(AppConfig.shared.stayDurationThreshold / 60) * 60)

    func makeUIView(context: Context) -> NativeTimeRangeSliderView {
        NativeTimeRangeSliderView()
    }

    func updateUIView(_ view: NativeTimeRangeSliderView, context: Context) {
        view.configure(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            start: start,
            end: end,
            minimumDuration: minimumDuration,
            step: 60,
            accentColor: UIColor(Color.dfkAccent),
            onStartChange: { start = $0 },
            onEndChange: { end = $0 }
        )
    }
}

private final class NativeTimeRangeSliderView: UIView {
    private let trackLayer = CALayer()
    private let selectedTrackLayer = CALayer()
    private let startSlider = ThumbHitTestSlider(frame: .zero)
    private let endSlider = ThumbHitTestSlider(frame: .zero)

    private var rangeStart = Date()
    private var rangeEnd = Date()
    private var start = Date()
    private var end = Date()
    private var minimumDuration: TimeInterval = 60
    private var step: TimeInterval = 60
    private var onStartChange: ((Date) -> Void)?
    private var onEndChange: ((Date) -> Void)?
    private var isConfiguring = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        trackLayer.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.15).cgColor
        trackLayer.cornerRadius = 3
        selectedTrackLayer.cornerRadius = 3
        layer.addSublayer(trackLayer)
        layer.addSublayer(selectedTrackLayer)

        [startSlider, endSlider].forEach { slider in
            slider.isContinuous = true
            slider.minimumTrackTintColor = .clear
            slider.maximumTrackTintColor = .clear
            addSubview(slider)
        }
        startSlider.accessibilityLabel = "开始时间"
        endSlider.accessibilityLabel = "结束时间"
        startSlider.addTarget(self, action: #selector(startChanged(_:)), for: .valueChanged)
        endSlider.addTarget(self, action: #selector(endChanged(_:)), for: .valueChanged)
    }

    func configure(
        rangeStart: Date,
        rangeEnd: Date,
        start: Date,
        end: Date,
        minimumDuration: TimeInterval,
        step: TimeInterval,
        accentColor: UIColor,
        onStartChange: @escaping (Date) -> Void,
        onEndChange: @escaping (Date) -> Void
    ) {
        let duration = rangeEnd.timeIntervalSince(rangeStart)
        guard duration >= minimumDuration else {
            isConfiguring = true
            [startSlider, endSlider].forEach { slider in
                slider.minimumValue = 0
                slider.maximumValue = Float(max(step, minimumDuration))
                slider.setValue(0, animated: false)
            }
            isConfiguring = false
            setNeedsLayout()
            return
        }

        isConfiguring = true
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.minimumDuration = minimumDuration
        self.step = step
        self.onStartChange = onStartChange
        self.onEndChange = onEndChange
        selectedTrackLayer.backgroundColor = accentColor.cgColor

        let clampedEnd = clamp(rounded(end), minDate: rangeStart.addingTimeInterval(minimumDuration), maxDate: rangeEnd)
        let clampedStart = clamp(rounded(start), minDate: rangeStart, maxDate: clampedEnd.addingTimeInterval(-minimumDuration))
        self.start = clampedStart
        self.end = clampedEnd

        let maximumValue = Float(max(step, duration))
        [startSlider, endSlider].forEach { slider in
            slider.minimumValue = 0
            slider.maximumValue = maximumValue
        }
        startSlider.setValue(Float(clampedStart.timeIntervalSince(rangeStart)), animated: false)
        endSlider.setValue(Float(clampedEnd.timeIntervalSince(rangeStart)), animated: false)
        isConfiguring = false

        if clampedStart != start {
            DispatchQueue.main.async { onStartChange(clampedStart) }
        }
        if clampedEnd != end {
            DispatchQueue.main.async { onEndChange(clampedEnd) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        startSlider.frame = bounds
        endSlider.frame = bounds
        updateTrackLayers()
    }

    private func updateTrackLayers() {
        let minX = thumbCenterX(for: startSlider, value: startSlider.minimumValue)
        let maxX = thumbCenterX(for: startSlider, value: startSlider.maximumValue)
        let startX = thumbCenterX(for: startSlider, value: startSlider.value)
        let endX = thumbCenterX(for: endSlider, value: endSlider.value)
        let trackY = bounds.midY - 3

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = CGRect(x: minX, y: trackY, width: max(0, maxX - minX), height: 6)
        selectedTrackLayer.frame = CGRect(x: min(startX, endX), y: trackY, width: abs(endX - startX), height: 6)
        CATransaction.commit()
    }

    private func thumbCenterX(for slider: UISlider, value: Float) -> CGFloat {
        let track = slider.trackRect(forBounds: slider.bounds)
        return slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: value).midX
    }

    @objc private func startChanged(_ sender: UISlider) {
        guard !isConfiguring else { return }
        let proposed = rangeStart.addingTimeInterval(TimeInterval(sender.value))
        let newStart = clamp(rounded(proposed), minDate: rangeStart, maxDate: end.addingTimeInterval(-minimumDuration))
        start = newStart
        sender.setValue(Float(newStart.timeIntervalSince(rangeStart)), animated: false)
        onStartChange?(newStart)
        updateTrackLayers()
    }

    @objc private func endChanged(_ sender: UISlider) {
        guard !isConfiguring else { return }
        let proposed = rangeStart.addingTimeInterval(TimeInterval(sender.value))
        let newEnd = clamp(rounded(proposed), minDate: start.addingTimeInterval(minimumDuration), maxDate: rangeEnd)
        end = newEnd
        sender.setValue(Float(newEnd.timeIntervalSince(rangeStart)), animated: false)
        onEndChange?(newEnd)
        updateTrackLayers()
    }

    private func rounded(_ date: Date) -> Date {
        guard step > 0 else { return date }
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded() * step)
    }

    private func clamp(_ date: Date, minDate: Date, maxDate: Date) -> Date {
        guard minDate <= maxDate else { return minDate }
        return min(max(date, minDate), maxDate)
    }
}

private struct NativeTimeSlider: UIViewRepresentable {
    let rangeStart: Date
    let rangeEnd: Date
    @Binding var value: Date
    let allowedStart: Date
    let allowedEnd: Date
    let step: TimeInterval
    let minimumTrackTintColor: UIColor
    let maximumTrackTintColor: UIColor
    let accessibilityLabel: String

    func makeUIView(context: Context) -> UISlider {
        let slider = ThumbHitTestSlider(frame: .zero)
        slider.isContinuous = true
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.accessibilityLabel = accessibilityLabel
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self

        slider.minimumValue = 0
        slider.maximumValue = Float(max(step, rangeEnd.timeIntervalSince(rangeStart)))
        slider.minimumTrackTintColor = minimumTrackTintColor
        slider.maximumTrackTintColor = maximumTrackTintColor
        slider.accessibilityLabel = accessibilityLabel

        let clampedDate = clamped(value)
        if clampedDate != value {
            DispatchQueue.main.async {
                self.value = clampedDate
            }
        }

        let sliderValue = Float(clampedDate.timeIntervalSince(rangeStart))
        if !slider.isTracking || abs(slider.value - sliderValue) > Float(step) {
            slider.setValue(sliderValue, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func clamped(_ date: Date) -> Date {
        min(max(rounded(date), allowedStart), allowedEnd)
    }

    private func rounded(_ date: Date) -> Date {
        guard step > 0 else { return date }
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded() * step)
    }

    final class Coordinator: NSObject {
        var parent: NativeTimeSlider

        init(_ parent: NativeTimeSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: UISlider) {
            let rawDate = parent.rangeStart.addingTimeInterval(TimeInterval(sender.value))
            let newValue = parent.clamped(rawDate)
            sender.setValue(Float(newValue.timeIntervalSince(parent.rangeStart)), animated: false)
            parent.value = newValue
        }
    }
}

private final class ThumbHitTestSlider: UISlider {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let track = trackRect(forBounds: bounds)
        let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
        return thumb.insetBy(dx: -22, dy: -22).contains(point)
    }
}

private struct FootprintTimeAdjustmentMapView: UIViewRepresentable {
    private static let maxRenderedPoints = 1_200

    let coordinates: [CLLocationCoordinate2D]
    var leadingCoordinates: [CLLocationCoordinate2D]? = nil
    var trailingCoordinates: [CLLocationCoordinate2D]? = nil
    var markerCoordinate: CLLocationCoordinate2D? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = SafeMKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        context.coordinator.mapView = mapView
        return mapView
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.pendingMapUpdate?.cancel()
        coordinator.mapView = nil
        coordinator.dataKey = ""
        mapView.delegate = nil
        let overlays = mapView.overlays
        let annotations = mapView.annotations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak mapView] in
            guard let mapView else { return }
            mapView.removeOverlays(overlays)
            mapView.removeAnnotations(annotations)
        }
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard let safeMap = mapView as? SafeMKMapView else { return }
        context.coordinator.parent = self
        
        let updateBlock = { [weak coordinator = context.coordinator, weak safeMap] in
            guard let safeMap, let coordinator else { return }
            coordinator.updateMap(on: safeMap)
        }
        
        safeMap.onLayoutSubviews = { [weak safeMap] in
            guard let safeMap else { return }
            if safeMap.bounds.width > 10 && safeMap.bounds.height > 10 {
                updateBlock()
            }
        }
        
        if safeMap.bounds.width > 10 && safeMap.bounds.height > 10 {
            updateBlock()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FootprintTimeAdjustmentMapView
        weak var mapView: MKMapView?
        var dataKey = ""
        var fitKey = ""
        weak var leadingPolyline: MKPolyline?
        weak var trailingPolyline: MKPolyline?
        var pendingMapUpdate: DispatchWorkItem?

        init(_ parent: FootprintTimeAdjustmentMapView) {
            self.parent = parent
        }

        func updateMap(on mapView: MKMapView) {
            let shouldThrottle = parent.leadingCoordinates != nil || parent.trailingCoordinates != nil || parent.markerCoordinate != nil
            guard shouldThrottle else {
                applyMapUpdate(on: mapView)
                return
            }

            guard pendingMapUpdate == nil else { return }
            let workItem = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.pendingMapUpdate = nil
                self.applyMapUpdate(on: mapView)
            }
            pendingMapUpdate = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }

        private func applyMapUpdate(on mapView: MKMapView) {
            let coordinates = Self.sample(parent.coordinates.filter(\.isRawPointsRenderable), maxCount: FootprintTimeAdjustmentMapView.maxRenderedPoints)
            let leadingCoordinates = Self.sample(parent.leadingCoordinates?.filter(\.isRawPointsRenderable) ?? [], maxCount: FootprintTimeAdjustmentMapView.maxRenderedPoints)
            let trailingCoordinates = Self.sample(parent.trailingCoordinates?.filter(\.isRawPointsRenderable) ?? [], maxCount: FootprintTimeAdjustmentMapView.maxRenderedPoints)
            let markerKey = parent.markerCoordinate?.rawPointsCoordinateKey ?? ""
            let baseKey = "\(coordinates.count)|\(coordinates.first?.rawPointsCoordinateKey ?? "")|\(coordinates.last?.rawPointsCoordinateKey ?? "")"
            let leadingKey = "\(leadingCoordinates.count)|\(leadingCoordinates.first?.rawPointsCoordinateKey ?? "")|\(leadingCoordinates.last?.rawPointsCoordinateKey ?? "")"
            let trailingKey = "\(trailingCoordinates.count)|\(trailingCoordinates.first?.rawPointsCoordinateKey ?? "")|\(trailingCoordinates.last?.rawPointsCoordinateKey ?? "")"
            let key = "\(baseKey)|\(leadingKey)|\(trailingKey)|\(markerKey)"
            guard key != dataKey else { return }
            dataKey = key

            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations)

            leadingPolyline = nil
            trailingPolyline = nil
            if !leadingCoordinates.isEmpty || !trailingCoordinates.isEmpty {
                if !leadingCoordinates.isEmpty {
                    mapView.addOverlay(FootprintTimeDotOverlay(coordinates: leadingCoordinates, color: .systemGreen, diameter: 7))
                }
                if !trailingCoordinates.isEmpty {
                    mapView.addOverlay(FootprintTimeDotOverlay(coordinates: trailingCoordinates, color: .systemBlue, diameter: 7))
                }
            } else if !coordinates.isEmpty {
                mapView.addOverlay(FootprintTimeDotOverlay(coordinates: coordinates, color: UIColor(Color.dfkAccent), diameter: 7))
            }

            if let marker = parent.markerCoordinate, marker.isRawPointsRenderable {
                let annotation = MKPointAnnotation()
                annotation.coordinate = marker
                mapView.addAnnotation(annotation)
            }
            if baseKey != fitKey {
                fitKey = baseKey
                scheduleFit(on: mapView, key: key)
            }
        }

        private func scheduleFit(on mapView: MKMapView, key: String, attempt: Int = 0) {
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, self.dataKey == key else { return }
                if !self.fit(coordinates: Self.sample(self.parent.coordinates.filter(\.isRawPointsRenderable), maxCount: FootprintTimeAdjustmentMapView.maxRenderedPoints), on: mapView), attempt < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        self.scheduleFit(on: mapView, key: key, attempt: attempt + 1)
                    }
                }
            }
        }

        @discardableResult
        private func fit(coordinates: [CLLocationCoordinate2D], on mapView: MKMapView) -> Bool {
            guard let first = coordinates.first else { return false }
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return false }
            if coordinates.count == 1 {
                mapView.setRegion(MKCoordinateRegion(center: first, latitudinalMeters: 500, longitudinalMeters: 500), animated: true)
                return true
            }

            let rect = coordinates.reduce(MKMapRect.null) { partial, coordinate in
                let point = MKMapPoint(coordinate)
                return partial.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32), animated: true)
            return true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let dotOverlay = overlay as? FootprintTimeDotOverlay {
                return FootprintTimeDotOverlayRenderer(overlay: dotOverlay)
            }

            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            if polyline === leadingPolyline {
                renderer.strokeColor = .systemGreen
            } else if polyline === trailingPolyline {
                renderer.strokeColor = .systemBlue
            } else {
                renderer.strokeColor = UIColor(Color.dfkAccent)
            }
            renderer.lineWidth = 2
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "split-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
            view.backgroundColor = .clear
            view.layer.cornerRadius = 11
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.25
            view.layer.shadowRadius = 4
            view.layer.shadowOffset = CGSize(width: 0, height: 2)
            view.image = Self.splitMarkerImage
            view.centerOffset = .zero
            return view
        }

        private static func sample(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
            guard coordinates.count > maxCount, maxCount > 2 else { return coordinates }
            let step = Double(coordinates.count - 1) / Double(maxCount - 1)
            return (0..<maxCount).map { coordinates[Int((Double($0) * step).rounded())] }
        }

        private static var splitMarkerImage: UIImage {
            let size = CGSize(width: 22, height: 22)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                UIColor.systemRed.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
            }
        }
    }
}

private final class FootprintTimeDotOverlay: NSObject, MKOverlay {
    let coordinates: [CLLocationCoordinate2D]
    let color: UIColor
    let diameter: CGFloat
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(coordinates: [CLLocationCoordinate2D], color: UIColor, diameter: CGFloat) {
        self.coordinates = coordinates
        self.color = color
        self.diameter = diameter

        let points = coordinates.map(MKMapPoint.init)
        if let first = points.first {
            var rect = MKMapRect(x: first.x, y: first.y, width: 1, height: 1)
            for point in points.dropFirst() {
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            boundingMapRect = rect
            coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        } else {
            boundingMapRect = .null
            coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }
}

private final class FootprintTimeDotOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let dotOverlay = overlay as? FootprintTimeDotOverlay else { return }
        context.setFillColor(dotOverlay.color.withAlphaComponent(0.72).cgColor)

        // Keep dot size visually stable across zoom while avoiding extreme GPU workloads
        // at very small zoomScale values.
        let scale = max(CGFloat(zoomScale), 0.01)
        let unclampedDiameter = dotOverlay.diameter / scale
        let diameter = min(max(unclampedDiameter, 3), 120)
        let radius = diameter / 2

        for coordinate in dotOverlay.coordinates {
            let mapPoint = MKMapPoint(coordinate)
            guard mapRect.contains(mapPoint) else { continue }
            let point = self.point(for: mapPoint)
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: diameter,
                height: diameter
            )
            context.fillEllipse(in: rect)
        }
    }
}

private extension CLLocationCoordinate2D {
    var rawPointsCoordinateKey: String {
        String(format: "%.7f,%.7f", latitude, longitude)
    }

    var isRawPointsRenderable: Bool {
        CLLocationCoordinate2DIsValid(self) &&
        latitude.isFinite &&
        longitude.isFinite &&
        abs(latitude) <= 90 &&
        abs(longitude) <= 180
    }
}

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onCapture(image)
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            picker.dismiss(animated: true)
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            parent.onPick(identifiers)
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Add To Favorite Place Modal

struct AddToFavoriteModal: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var footprint: Footprint
    
    @Query(sort: \Place.name) private var savedPlaces: [Place]
    
    @State private var placeName: String = ""
    @State private var radius: Float = 80
    @State private var address: String = "正在解析地址..."
    
    private let importantTypes = ["家", "公司", "学校"]
    
    var body: some View {
        NavigationStack {
            Form {
                previewSection
                Section(header: Text("地点名称")) {
                    TextField("输入地点名称", text: $placeName)
                        .font(.body)
                }
                presetSection
                radiusSection
            }
            .navigationTitle("添加重要地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        savePlace()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(.dfkAccent)
                }
            }
        }
        .onAppear { 
            setupInitialData()
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section(header: Text("位置预览")) {
            MiniMapView(
                coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
                title: placeName.isEmpty ? (footprint.address ?? "新地点") : placeName,
                radius: Double(radius)
            )
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            
            Text("\(address)")
                .font(.caption)
                .foregroundColor(.secondary)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        Section(header: Text("快速预设")) {
            FlowLayout(spacing: 8) {
                ForEach(importantTypes, id: \.self) { type in
                    let isSelected = placeName.trimmingCharacters(in: .whitespaces) == type
                    
                    Button {
                        placeName = type
                    } label: {
                        Text(type)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.orange : Color.orange.opacity(0.1))
                            .foregroundColor(isSelected ? .white : .orange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var radiusSection: some View {
        Section(header: Text("感知半径"), footer: Text("进入该范围内时自动识别为此地点")) {
            HStack {
                Text("\(Int(radius)) 米")
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 52, alignment: .leading)
                    .foregroundColor(.orange)
                Slider(value: $radius, in: 30...300, step: 10).tint(Color.orange)
            }
        }
    }

    private func setupInitialData() {
        placeName = footprint.address ?? ""
        
        // Resolve address
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            if let pm = placemarks?.first {
                let poiOrName = pm.areasOfInterest?.first ?? pm.name
                
                let addr = [pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    .compactMap { $0 }
                    .joined(separator: "")
                
                // 如果 poiOrName 和地址的前半部分（如路名）不同，可以结合显示 or 优先显示
                if let poi = poiOrName, !addr.contains(poi) {
                    self.address = addr + poi
                } else {
                    self.address = addr.isEmpty ? (pm.name ?? "") : addr
                }
            }
        }
    }

    private func savePlace() {
        Aptabase.shared.trackEvent("place_added")
        let finalName = placeName.trimmingCharacters(in: .whitespaces).isEmpty ? (footprint.address ?? "未知地点") : placeName.trimmingCharacters(in: .whitespaces)
        
        // (Exclusive category logic removed: user can have multiple Home/Work/School places)
        

        let newPlace = Place(
            name: finalName,
            coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
            radius: radius,
            address: address
        )
        modelContext.insert(newPlace)
        footprint.address = finalName
        footprint.placeID = newPlace.placeID
        footprint.isAddressEditedByHand = true
        footprint.status = .manual
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }
}

private struct MiniMapView: View {
    let coordinate: CLLocationCoordinate2D
    let title: String
    var radius: Double = 80
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var interactiveMapReady = false
    
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > 0 && geometry.size.height > 0 && interactiveMapReady {
                Map(position: $cameraPosition) {
                    Marker("", coordinate: coordinate).tint(Color.orange)
                    MapCircle(center: coordinate, radius: radius)
                        .foregroundStyle(Color.orange.opacity(0.15))
                        .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                }
                .mapStyle(.standard)
                .disabled(true)
                .frame(minWidth: 1, minHeight: 1)
            } else {
                Color.clear
            }
        }
        .onChange(of: radius) { _, newRadius in
            let span = newRadius * 6
            cameraPosition = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span))
        }
        .onAppear {
            let span = radius * 6
            cameraPosition = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                interactiveMapReady = true
            }
        }
    }
}

struct AssetThumbnailView: View {
    let assetID: String
    var showsTime: Bool = true
    var onAssetMissing: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var isLoading = true
    @State private var isMissing = false
    @State private var creationDate: Date?
    
    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6) // 用实色代替半透明
            
            if let img = image {
                Color.clear
                    .overlay(
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
            } else if !isLoading {
                Group {
                    if authStatus == .denied || authStatus == .restricted {
                        Image(systemName: "lock.fill").font(.caption2)
                    } else if authStatus == .notDetermined {
                        Image(systemName: "photo.badge.plus").font(.caption2)
                    } else if isMissing {
                        Image(systemName: "photo").font(.caption2)
                    } else {
                        Image(systemName: "hand.raised.fill").font(.caption2)
                    }
                }
                .foregroundColor(Color(uiColor: .systemGray)) // 用实色代替半透明
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleStateTap()
                }
            } else {
                Image(systemName: "photo").font(.caption2).foregroundColor(Color(uiColor: .systemGray))
            }
        }
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if showsTime, let date = creationDate {
                Text(date, format: .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .darkGray)) // 用实色代替半透明
                    .cornerRadius(4)
                    .padding(4)
            }
        }
        .onAppear {
            loadImage()
        }
        .task(id: assetID) {
            loadImage()
        }
    }
    
    private func handleStateTap() {
        if authStatus == .notDetermined {
            PhotoService.shared.requestPermission { granted in
                if granted { loadImage() }
            }
        } else if authStatus == .denied || authStatus == .restricted {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
    
    private func loadImage() {
        self.image = nil
        self.isLoading = true
        self.isMissing = false
        
        PhotoService.shared.loadImage(for: assetID, targetSize: CGSize(width: 400, height: 400)) { img, exists, status, isDegraded in
            self.authStatus = status
            
            if exists {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                self.creationDate = result.firstObject?.creationDate
            }
            
            if !exists {
                self.isLoading = false
                self.isMissing = true
                onAssetMissing?()
            }
            
            if let img = img {
                self.image = img
                if !isDegraded {
                    self.isLoading = false
                }
            } else if !isDegraded {
                self.isLoading = false
            }
        }
    }
}

struct IdentifiableString: Identifiable {
    var id: String { value }
    let value: String
}

struct PhotoFullscreenView: View {
    let assetIDs: [String]
    @State var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentCreationDate: Date?
    
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $currentIndex) {
                ForEach(0..<assetIDs.count, id: \.self) { index in
                    FullscreenImageItem(assetID: assetIDs[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .ignoresSafeArea()
            
            // Custom Title Bar
            HStack {
                Spacer()
                
                if let date = currentCreationDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .onAppear {
            fetchCurrentDate()
        }
        .onChange(of: currentIndex) { _, _ in
            fetchCurrentDate()
        }
    }
    
    private func fetchCurrentDate() {
        guard currentIndex < assetIDs.count else { return }
        let assetID = assetIDs[currentIndex]
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        currentCreationDate = result.firstObject?.creationDate
    }
}

struct FullscreenImageItem: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var downloadProgress: Double = 0
    @State private var isDownloading: Bool = false
    @State private var isDegraded: Bool = true
    @State private var loadFailed: Bool = false
    @State private var creationDate: Date?
    
    var body: some View {
        ZStack(alignment: .top) {
            if let image = image {
                ZoomableImageView(image: image)
                    .overlay {
                        if isDownloading && isDegraded {
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
                                    .frame(width: 32, height: 32)
                                Circle()
                                    .trim(from: 0, to: CGFloat(downloadProgress))
                                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .frame(width: 32, height: 32)
                                    .rotationEffect(.degrees(-90))
                            }
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(radius: 5)
                        }
                    }
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                    Text("照片加载失败")
                        .font(.system(size: 14))
                    Button("重试") {
                        loadFailed = false
                        loadImage()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            loadImage()
        }
        .task(id: assetID) {
            loadImage()
        }
    }
    
    private func loadImage() {
        PhotoService.shared.loadImage(for: assetID, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, progressHandler: { progress in
            // Only show download UI if we are actually downloading (progress < 1.0)
            if progress < 1.0 {
                withAnimation(.linear) {
                    self.isDownloading = true
                    self.downloadProgress = progress
                }
            }
        }) { img, exists, _, degraded in
            if exists {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                self.creationDate = result.firstObject?.creationDate
            }

            if let img = img {
                withAnimation(.easeInOut) {
                    self.image = img
                    self.isDegraded = degraded
                    // If we got the high quality image, or if it was never downloading, hide the ring
                    if !degraded {
                        self.isDownloading = false
                    }
                }
            } else if !degraded {
                self.loadFailed = true
                self.isDownloading = false
            }
        }
    }
}

// SwiftUI wrap for UIScrollView to support native zoom & pan
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)

        // Add double tap to zoom

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if let imageView = uiView.viewWithTag(100) as? UIImageView {
            if imageView.image != image {
                imageView.image = image
                // Reset zoom scale when image changes (e.g. from low-res to high-res)
                uiView.zoomScale = 1.0
            }
            // Ensure the image view fills the scroll view bounds initially
            if uiView.zoomScale == 1.0 {
                imageView.frame = uiView.bounds
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView = scrollView.viewWithTag(100) else { return }
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            imageView.center = CGPoint(x: scrollView.contentSize.width * 0.5 + offsetX, y: scrollView.contentSize.height * 0.5 + offsetY)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: scrollView.viewWithTag(100))
                let size = CGSize(width: scrollView.frame.size.width / 3, height: scrollView.frame.size.height / 3)
                let rect = CGRect(origin: CGPoint(x: point.x - size.width/2, y: point.y - size.height/2), size: size)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}


struct FootprintDetailMapView: View {
    let footprint: Footprint
    var photoAssets: [PHAsset] = []
    var isInteractive: Bool = false
    var showsStandalonePhotos: Bool = true
    var prefersActivityIcons: Bool = true
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoAsset: IdentifiableString?

    var body: some View {
        DFKMapView(
            cameraPosition: $cameraPosition,
            isInteractive: isInteractive,
            showsUserLocation: true,
            points: footprint.coordinates,
            timelineItems: [.footprint(footprint)],
            photoAssets: photoAssets,
            showsStandalonePhotos: showsStandalonePhotos,
            prefersActivityIcons: prefersActivityIcons,
            onPhotoTap: { asset in
                self.selectedPhotoAsset = IdentifiableString(value: asset.localIdentifier)
            }
        )
        .onAppear {
            if let region = footprint.calculateRegion(with: photoAssets) {
                cameraPosition = .region(region)
            }
        }
        .onChange(of: photoAssets) { _, newAssets in
             if let region = footprint.calculateRegion(with: newAssets) {
                withAnimation {
                    cameraPosition = .region(region)
                }
            }
        }
        .sheet(item: $selectedPhotoAsset) { item in
            let assetIDs = photoAssets.map { $0.localIdentifier }
            let index = assetIDs.firstIndex(of: item.value) ?? 0
            PhotoFullscreenView(assetIDs: assetIDs, currentIndex: index)
        }
    }
}

extension Footprint {
    func calculateRegion(with photoAssets: [PHAsset] = []) -> MKCoordinateRegion? {
        var allCoords = coordinates
        
        // Include photo locations (using gcj02 for mainland China)
        for asset in photoAssets {
            if let loc = asset.location?.gcj02.coordinate {
                allCoords.append(loc)
            }
        }
        
        guard !allCoords.isEmpty else { return nil }
        
        let lats = allCoords.map { $0.latitude }
        let lons = allCoords.map { $0.longitude }
        
        let maxLat = lats.max()!
        let minLat = lats.min()!
        let maxLon = lons.max()!
        let minLon = lons.min()!
        
        let center = CLLocationCoordinate2D(latitude: (maxLat + minLat) / 2, longitude: (maxLon + minLon) / 2)
        
        // 使用更紧凑的边距，尽可能放大
        let latDelta = (maxLat - minLat) * 1.15
        let lonDelta = (maxLon - minLon) * 1.15
        
        // 减小最小跨度，允许更近的缩放
        let finalLatDelta = max(latDelta, 0.0015)
        let finalLonDelta = max(lonDelta, 0.0015)
        
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: finalLatDelta, longitudeDelta: finalLonDelta))
    }
}

struct SpringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
