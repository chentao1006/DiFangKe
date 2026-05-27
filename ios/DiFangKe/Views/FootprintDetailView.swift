import SwiftUI
import MapKit
import SwiftData
import Photos
import PhotosUI

// MARK: - FootprintModalView
// Replaces old FootprintDetailView content to ensure scope visibility

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
            .onAppear {
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
            if hasChanged {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Menu {
                        SuggestionsMenuContent(locationManager: locationManager, coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), forOngoing: false, footprint: footprint, isDraft: isDraft) {
                            showingSearchSheet = true
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if isUpdatingAddress {
                                Text("正在重新获取地址...")
                                    .font(.system(.title3, design: .rounded).bold())
                                    .foregroundColor(Color.dfkMainText.opacity(0.5))
                            } else {
                                let matchedPlace = savedPlaces.first(where: { place in
                                    if place.placeID == footprint.placeID && place.isUserDefined { return true }
                                    guard place.isUserDefined else { return false }
                                    let fpAddr = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !fpAddr.isEmpty else { return false }
                                    return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr || 
                                           (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr)
                                })
                                let displayText = matchedPlace?.name ?? footprint.address ?? "未知地点"
                                
                                HStack(spacing: 8) {
                                    Text(displayText)
                                        .font(.system(.title3, design: .rounded).bold())
                                        .foregroundColor(matchedPlace != nil ? .orange : Color.dfkMainText)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
                
                VStack(alignment: .trailing, spacing: 0) {
                    Menu {
                        Button {
                            withAnimation {
                                ensureFootprintManaged()
                                footprint.activityTypeValue = nil
                                footprint.status = .manual
                                hasChanged = true
                                if !isDraft { try? modelContext.save() }
                            }
                        } label: {
                            Label("无", systemImage: "circle.slash")
                        }
                        ForEach(allActivities) { type in
                            Button {
                                withAnimation {
                                    ensureFootprintManaged()
                                    footprint.activityTypeValue = type.id.uuidString
                                    footprint.status = .manual
                                    hasChanged = true
                                    if !isDraft { try? modelContext.save() }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            } label: {
                                Label(type.name, systemImage: type.icon)
                            }
                        }
                        
                        Divider()
                        
                        Button {
                            showingActivityTypeEditor = true
                        } label: {
                            Label("添加活动类型", systemImage: "plus")
                        }
                    } label: {
                        ZStack {
                            if isGeneratingAI {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                if let activity = footprint.getActivityType(from: allActivities) {
                                    Image(systemName: activity.icon)
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(activity.color)
                                } else {
                                    Image(systemName: "questionmark.circle.dashed")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(.secondary.opacity(0.7))
                                }
                            }
                        }
                        .frame(width: 45, height: 45)
                        .background(Circle().fill(Color.secondary.opacity(0.05)))
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    if footprint.activityTypeValue == nil {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color.secondary.opacity(0.04)) // Match bubble bg
                            .padding(.trailing, 15)
                            .offset(y: 5) // Move down to touch the bubble
                            .zIndex(1)
                    }
                }
            }
            
            if footprint.activityTypeValue == nil {
                activitySuggestionsRow
                    .padding(.top, -4) // Reduce gap to touch triangle
            }
        }
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
    
    private func getSuggestedActivities() -> [ActivityType] {
        let liteActivities = allActivities.map { $0.convertToLite() }
        let litePlaces = savedPlaces.map { $0.convertToLite() }
        let suggestions = ActivityType.getSuggestedActivities(for: footprint, allActivities: liteActivities, allPlaces: litePlaces)
        
        return suggestions.compactMap { lite in
            allActivities.first { $0.id == lite.id }
        }
    }
    
    private var timeSection: some View {
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
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.04)))
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
                TextField("输入感悟...", text: Binding(
                    get: { footprint.reason ?? "" },
                    set: {
                        ensureFootprintManaged()
                        footprint.reason = $0
                        footprint.aiAnalyzed = true
                        footprint.status = .manual
                        if footprint.locationHash == "ONGOING_STAY" {
                            footprint.locationHash = "MANUAL_STAY"
                        }
                        hasChanged = true
                        if !isDraft { try? modelContext.save() }
                    }
                ), axis: Axis.vertical)
                .font(.body)
                .foregroundColor(Color.dfkMainText.opacity(0.85))
                .focused($reasonFocused)
                
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
        withAnimation { 
            footprint.status = .ignored 
            hasChanged = true
        }
        if footprint.modelContext == nil {
            modelContext.insert(footprint)
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
    
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > 0 && geometry.size.height > 0 {
                Map(position: $cameraPosition) {
                    Marker("", coordinate: coordinate).tint(Color.orange)
                    MapCircle(center: coordinate, radius: radius)
                        .foregroundStyle(Color.orange.opacity(0.15))
                        .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                }
                .mapStyle(.standard)
                .disabled(true)
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
        GeometryReader { geo in
            ZStack {
                Color.secondary.opacity(0.08)
                
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
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
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleStateTap()
                    }
                } else {
                    ProgressView().scaleEffect(0.7)
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
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
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



