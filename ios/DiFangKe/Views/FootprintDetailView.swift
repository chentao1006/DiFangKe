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
    @FocusState private var titleFocused: Bool
    @FocusState private var reasonFocused: Bool
    var autoFocus: Bool = false
    @State private var showingDeleteAlert = false
    @State private var selectedItems: [PhotosPickerItem] = []
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
    
    init(footprint: Footprint, allPlaces: [Place] = [], autoFocus: Bool = false, onDismiss: ((Bool) -> Void)? = nil) {
        self._footprint = Bindable(footprint)
        self.allPlaces = allPlaces
        self.autoFocus = autoFocus
        self.onDismiss = onDismiss
    }
    
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var isGeneratingAI = false
    @State private var showingAINotEnabledAlert = false
    @State private var showingAIErrorAlert = false
    @State private var aiErrorMessage = ""
    @State private var isAIPerformingUpdate = false
    
    private func ensureFootprintManaged() {
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
                    titleFocused = false
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
                            try? modelContext.save()
                        }
                    } label: {
                        Image(systemName: (footprint.isHighlight ?? false) ? "star.fill" : "star")
                            .foregroundColor((footprint.isHighlight ?? false) ? Color.dfkHighlight : .secondary)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { 
                        checkAndGenerateAIContent()
                        try? modelContext.save()
                        onDismiss?(hasChanged)
                        dismiss() 
                    }.fontWeight(.bold)
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
                        titleFocused = true
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
                
                // 为地图获取照片，并应用每个足迹最多 10 张的显示策略
                PhotoService.shared.fetchAssets(startTime: footprint.startTime, endTime: footprint.endTime) { assets in
                    let filtered = assets.filter { $0.location != nil }
                    self.mapPhotos = Array(filtered.suffix(10))
                }
                
                // 第一次进入足迹详情且状态为“未定义”时，强提示授权
                if !hasSeenPhotoPermissionGuide && PhotoService.shared.authorizationStatus == .notDetermined {
                    // 我们可以在这里简单打个标记，页面底部的大按钮（原本就有的引导位）已经能承担说明作用。
                    // 为了满足用户说的“说明并请求”，我们可以考虑在这里触发一个弹窗或者在该页面显式滚动到该区域（当前卡片已有按钮）。
                    hasSeenPhotoPermissionGuide = true
                }
            }
            .onChange(of: selectedItems) { _, newValue in
                Task {
                    for item in newValue {
                        // Load image data from the picker item
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            var localID: String?
                            try? await PHPhotoLibrary.shared().performChanges {
                                let req = PHAssetCreationRequest.forAsset()
                                req.addResource(with: .photo, data: data, options: nil)
                                localID = req.placeholderForCreatedAsset?.localIdentifier
                            }
                            if let id = localID {
                                await MainActor.run {
                                    withAnimation {
                                        ensureFootprintManaged()
                                        var ids = footprint.photoAssetIDs
                                        ids.append(id)
                                        footprint.photoAssetIDs = ids
                                        hasChanged = true
                                    }
                                    try? modelContext.save()
                                }
                            }
                            _ = uiImage // suppress unused warning
                        }
                    }
                    selectedItems = []
                }
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
                            await MainActor.run {
                                ensureFootprintManaged()
                                withAnimation {
                                    var ids = footprint.photoAssetIDs
                                    ids.append(id)
                                    footprint.photoAssetIDs = ids
                                    hasChanged = true
                                }
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItems, matching: .images)
            .sheet(isPresented: $showingSearchSheet) {
                LocationSearchSheet(locationManager: locationManager, 
                                    coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), 
                                    forOngoing: false, 
                                    footprint: footprint)
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
                    // 开启后立即触发一次生成
                    regenerateAIContent()
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
            try? modelContext.save()
            onDismiss?(hasChanged)
        }
    }
}
}

extension FootprintModalView {
    private func deletePhoto() {
        guard let assetID = photoToDelete else { return }
        ensureFootprintManaged()
        withAnimation {
            var ids = footprint.photoAssetIDs
            ids.removeAll(where: { $0 == assetID })
            footprint.photoAssetIDs = ids
            footprint.status = .manual // 标记为人工修改，防止被重置
            hasChanged = true
            try? modelContext.save()
        }
        photoToDelete = nil
    }
    
    private func checkAndGenerateAIContent() {
        // 如果用户手动修改过标题，我们不再认为它是“空”的需要被 AI 覆盖
        let isDefaultTitle = footprint.title == "地点记录" || footprint.title == "发现足迹" || footprint.title.trimmingCharacters(in: .whitespaces).isEmpty
        let isTitleNeedsAI = !footprint.isTitleEditedByHand && isDefaultTitle
        let isReasonEmpty = (footprint.reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        
        if isTitleNeedsAI || isReasonEmpty {
            // Auto generation should be silent if AI is off
            regenerateAIContent(forcePrompt: false)
        }
    }
    
    private func regenerateAIContent(forcePrompt: Bool = true) {
        guard isAiAssistantEnabled else {
            if forcePrompt {
                showingAINotEnabledAlert = true
            }
            return
        }
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // 加入分析队列，遵守统一的请求频率限制
        OpenAIService.shared.analyzeFootprint(footprint)
    }
    
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("有什么值得记住的", text: $footprint.title)
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundColor(Color.dfkMainText)
                            .submitLabel(.done)
                            .focused($titleFocused)
                            .lineLimit(1)
                            .onSubmit { 
                                titleFocused = false
                                ensureFootprintManaged()
                                footprint.aiAnalyzed = true
                                hasChanged = true
                                try? modelContext.save() 
                            }
                            .onChange(of: footprint.title) { _, _ in 
                                if !isAIPerformingUpdate {
                                    footprint.isTitleEditedByHand = true
                                    hasChanged = true
                                }
                                footprint.aiAnalyzed = true 
                            }
                    }
                    
                    if !titleFocused {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(titleFocused ? Color.dfkAccent.opacity(0.05) : Color.secondary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(titleFocused ? Color.dfkAccent.opacity(0.3) : Color.clear, lineWidth: 1))
                .onTapGesture { titleFocused = true }
                
                VStack(alignment: .trailing, spacing: 0) {
                    Menu {
                        Button {
                            withAnimation {
                                ensureFootprintManaged()
                                footprint.activityTypeValue = nil
                                hasChanged = true
                                try? modelContext.save()
                            }
                        } label: {
                            Label("无", systemImage: "circle.slash")
                        }
                        ForEach(allActivities) { type in
                            Button {
                                withAnimation {
                                    ensureFootprintManaged()
                                    footprint.activityTypeValue = type.id.uuidString
                                    hasChanged = true
                                    try? modelContext.save()
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
                                hasChanged = true
                                try? modelContext.save()
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
        var suggested: [ActivityType] = []
        let hour = Calendar.current.component(.hour, from: footprint.startTime)
        let weekday = Calendar.current.component(.weekday, from: footprint.startTime)
        let isWeekend = (weekday == 1 || weekday == 7)
        let durationHours = footprint.duration / 3600.0
        
        // 1. Unified Context (Title + Address + Place Name)
        let contextText = (footprint.title + (footprint.address ?? "") + (matchedPlace?.name ?? "")).lowercased()
        
        // 2. Category-based Mapping (High precision POI)
        if let category = matchedPlace?.category {
            let catMap: [String: String] = [
                "MKPOICategoryRestaurant": "美食", "MKPOICategoryCafe": "美食", "MKPOICategoryFoodMarket": "美食",
                "MKPOICategorySchool": "学习", "MKPOICategoryUniversity": "学习", "MKPOICategoryLibrary": "学习",
                "MKPOICategoryHospital": "医疗", "MKPOICategoryPharmacy": "医疗",
                "MKPOICategoryPark": "运动", "MKPOICategoryFitnessCenter": "运动",
                "MKPOICategoryMuseum": "旅游", "MKPOICategoryNationalPark": "旅游",
                "MKPOICategoryMovieTheater": "娱乐", "MKPOICategoryAmusementPark": "娱乐",
                "MKPOICategoryStore": "购物", "MKPOICategoryMall": "购物", "MKPOICategoryDepartmentStore": "购物"
            ]
            if let actName = catMap[category], let a = allActivities.first(where: { $0.name == actName }) {
                suggested.append(a)
            }
        }

        // 3. Dynamic Name Matching (Match any activity by its name)
        for activity in allActivities where activity.name.count >= 2 {
            if contextText.contains(activity.name.lowercased()) && !suggested.contains(where: { $0.id == activity.id }) {
                suggested.append(activity)
            }
        }
        
        // 4. Pattern-based Keywords
        let patterns: [(String, [String])] = [
            ("家庭", ["妈妈", "爸爸", "外婆", "奶奶", "爷爷", "亲戚", "父母", "老家", "儿子", "女儿", "父", "母"]),
            ("居家", ["家", "居", "屋", "公寓", "住宅", "苑", "府", "园", "里"]),
            ("工作", ["公司", "工作", "办公", "大厦", "写字楼", "研制", "软件", "厂", "局", "馆", "office"]),
            ("旅游", ["景点", "景区", "公园", "博物馆", "火车站", "机场", "酒店", "客栈", "游", "trip", "江", "湖", "山", "海", "岛", "古镇", "古村", "古城", "寺", "庙", "塔", "庄园", "庄"]),
            ("美食", ["餐厅", "餐饮", "饭店", "面馆", "火锅", "咖啡", "饮品", "食堂", "美味", "吃", "food", "eat"]),
            ("购物", ["商场", "购物", "超市", "中心", "广场", "便利店", "店", "城", "mall", "shop", "百货", "奥莱", "批发", "商业"]),
            ("运动", ["体育", "健身", "场馆", "跑道", "馆", "羽毛球", "篮球", "游泳", "操场", "gym", "run"]),
            ("娱乐", ["电影", "KTV", "游戏", "乐园", "影院", "游乐", "网吧", "play"]),
            ("学习", ["学校", "大学", "中学", "图书馆", "学院", "课堂", "教育", "校区", "study", "learn"]),
            ("医疗", ["医院", "门诊", "诊所", "药店", "大药房", "卫生院", "hospital", "clinic"])
        ]
        
        for (name, keywords) in patterns {
            if keywords.contains(where: { contextText.contains($0) }) {
                if let a = allActivities.first(where: { $0.name == name }), !suggested.contains(where: { $0.id == a.id }) {
                    suggested.append(a)
                }
            }
        }
        
        // 5. Time & Duration-based logic
        if durationHours > 3 && (hour >= 21 || hour <= 4) {
            if let a = allActivities.first(where: { $0.name == "睡眠" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
        }
        if (hour >= 11 && hour <= 13) || (hour >= 18 && hour <= 21) {
            if let a = allActivities.first(where: { $0.name == "美食" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
        }
        if !isWeekend && hour >= 9 && hour <= 17 && durationHours > 1.5 {
            if let a = allActivities.first(where: { $0.name == "工作" }), !suggested.contains(where: { $0.id == a.id }) { suggested.append(a) }
        }
        
        // 6. Stable Fallback
        if suggested.count < 4 {
            let existingIds = Set(suggested.map { $0.id })
            let others = allActivities.filter { !existingIds.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
            if !others.isEmpty {
                let seed = abs(footprint.footprintID.uuidString.hashValue)
                for i in 0..<(4 - suggested.count) {
                    let candidate = others[(seed + i) % others.count]
                    if !suggested.contains(where: { $0.id == candidate.id }) { suggested.append(candidate) }
                    if suggested.count >= 4 { break }
                }
            }
        }
        return Array(suggested.prefix(5))
    }
    
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Menu {
                    SuggestionsMenuContent(locationManager: locationManager, coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude), forOngoing: false, footprint: footprint) {
                        showingSearchSheet = true
                    }
                } label: {
                    HStack(alignment: .center, spacing: 6) { 
                        Image(systemName: isUpdatingAddress ? "arrow.triangle.2.circlepath" : "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundColor(Color.secondary)
                            .symbolEffect(.bounce, value: isUpdatingAddress)
                        
                        if isUpdatingAddress {
                            Text("正在重新获取地址...")
                                .font(.subheadline)
                                .foregroundColor(Color.dfkMainText.opacity(0.5))
                        } else {
                            HStack(spacing: 6) {
                                Text(footprint.address ?? (matchedPlace?.address ?? "未记录位置"))
                                    .font(.system(size: 16, design: .rounded))
                                    .foregroundColor(matchedPlace != nil ? .orange : Color.dfkMainText)
                                    .lineLimit(2)
                                
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.dfkSecondaryText.opacity(0.5))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if matchedPlace == nil {
                    Button {
                        showAddPlaceModal = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.orange.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            
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
        }
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
                    try? modelContext.save()
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
                            try? modelContext.save()
                        }
                    }
                }
            }
        }
    }
    
    private var headerContent: some View {
        Group {
            titleSection.padding(.horizontal, 24).padding(.top, 16)
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
                FootprintDetailMapView(footprint: footprint, photoAssets: mapPhotos, isInteractive: false)
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
                    set: { footprint.reason = $0; footprint.aiAnalyzed = true; hasChanged = true }
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
                    Button("从相册选择") { showPhotoPicker = true }
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
                                        withAnimation {
                                            footprint.photoAssetIDs = assets.map { $0.localIdentifier }
                                            hasChanged = true
                                            try? modelContext.save()
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
                        Button("从相册选择") { showPhotoPicker = true }
                        Button("取消", role: .cancel) { }
                    }
                }
            } else {
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(footprint.photoAssetIDs, id: \.self) { assetID in
                        AssetThumbnailView(assetID: assetID, onAssetMissing: {
                            withAnimation {
                                var ids = footprint.photoAssetIDs
                                ids.removeAll { $0 == assetID }
                                footprint.photoAssetIDs = ids
                                hasChanged = true
                                try? modelContext.save()
                            }
                        })
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { selectedPhotoID = assetID }
                            .contextMenu {
                                Button(role: .destructive) {
                                    photoToDelete = assetID
                                    showingPhotoDeleteAlert = true
                                } label: {
                                    Label("删除照片", systemImage: "trash")
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
            FootprintDetailMapView(footprint: footprint, photoAssets: photoAssets, isInteractive: true)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("查看地图")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                            .fontWeight(.bold)
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
                title: placeName.isEmpty ? footprint.title : placeName,
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
        placeName = footprint.title
        
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
                    self.address = addr.isEmpty ? (pm.name ?? "未知位置") : addr
                }
            }
        }
    }

    private func savePlace() {
        let finalName = placeName.trimmingCharacters(in: .whitespaces).isEmpty ? footprint.title : placeName.trimmingCharacters(in: .whitespaces)
        
        // (Exclusive category logic removed: user can have multiple Home/Work/School places)
        

        let newPlace = Place(
            name: finalName,
            coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude),
            radius: radius,
            address: address
        )
        modelContext.insert(newPlace)
        footprint.placeID = newPlace.placeID
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
        Map(position: $cameraPosition) {
            Marker("", coordinate: coordinate).tint(Color.orange)
            MapCircle(center: coordinate, radius: radius)
                .foregroundStyle(Color.orange.opacity(0.15))
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
        }
        .mapStyle(.standard)
        .disabled(true)
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
    var onAssetMissing: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var isLoading = true
    @State private var isMissing = false
    
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
                            VStack(spacing: 4) {
                                Image(systemName: "lock.fill").font(.caption2)
                                Text("无权限").font(.system(size: 8))
                            }
                        } else if authStatus == .notDetermined {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.badge.plus").font(.caption2)
                                Text("待授权").font(.system(size: 8))
                            }
                        } else if isMissing {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.badge.exclamationmark").font(.caption2)
                                Text("已丢失").font(.system(size: 8))
                            }
                        } else {
                            // Probably limited access and not selected
                            VStack(spacing: 4) {
                                Image(systemName: "hand.raised.fill").font(.caption2)
                                Text("未选择").font(.system(size: 8))
                            }
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
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: assetID) { _, _ in
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
        
        PhotoService.shared.loadImage(for: assetID, targetSize: CGSize(width: 400, height: 400)) { img, exists, status in
            self.authStatus = status
            self.isLoading = false
            
            if !exists {
                self.isMissing = true
                onAssetMissing?()
            }
            self.image = img
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
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $currentIndex) {
                ForEach(0..<assetIDs.count, id: \.self) { index in
                    FullscreenImageItem(assetID: assetIDs[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .ignoresSafeArea()
            
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
            .padding(16)
        }
    }
}

struct FullscreenImageItem: View {
    let assetID: String
    @State private var image: UIImage?
    
    var body: some View {
        ZStack {
            if let image = image {
                ZoomableImageView(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            PhotoService.shared.loadImage(for: assetID, targetSize: CGSize(width: 2000, height: 2000)) { img, _, _ in
                self.image = img
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

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100 // Use tag to find the view later
        scrollView.addSubview(imageView)

        // Setup constraints or frame
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        // Add double tap to zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

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
                let size = CGSize(width: scrollView.frame.size.width / 2.5, height: scrollView.frame.size.height / 2.5)
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
            onPhotoTap: { asset in
                self.selectedPhotoAsset = IdentifiableString(value: asset.localIdentifier)
            }
        )
        .onAppear {
            if let region = footprint.region {
                cameraPosition = .region(region)
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
    var region: MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        
        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }
        
        let maxLat = lats.max()!
        let minLat = lats.min()!
        let maxLon = lons.max()!
        let minLon = lons.min()!
        
        let center = CLLocationCoordinate2D(latitude: (maxLat + minLat) / 2, longitude: (maxLon + minLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.5 + 0.005, longitudeDelta: (maxLon - minLon) * 1.5 + 0.005)
        
        return MKCoordinateRegion(center: center, span: span)
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



