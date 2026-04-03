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
    @ObservedObject var photoService = PhotoService.shared
    @Bindable var footprint: Footprint
    var allPlaces: [Place] = []
    
    @Query private var savedPlaces: [Place]
    @Query(sort: \PlaceTag.name) private var availableTags: [PlaceTag]
    
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
    @State private var showingAddTagAlert = false
    @State private var newTagName = ""
    @State private var isUpdatingAddress = false
    
    @State private var showFullscreenMap = false
    @AppStorage("isAutoPhotoLinkEnabled") private var isAutoPhotoLinkEnabled = true
    @AppStorage("hasSeenPhotoPermissionGuide") private var hasSeenPhotoPermissionGuide = false
    
    @State private var showingPhotoDeleteAlert = false
    @State private var photoToDelete: String? = nil
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    titleSection.padding(.horizontal, 24).padding(.top, 16)
                    timeSection.padding(.horizontal, 24).padding(.top, 12)
                    tagsSection.padding(.horizontal, 24).padding(.top, 12)
                    
                    if showMap {
                        mapSection.padding(.horizontal, 24).padding(.top, 16).transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        mapSkeleton.padding(.horizontal, 24).padding(.top, 16)
                    }
                    
                    addToPlacesSection.padding(.horizontal, 24).padding(.top, 12)
                    
                    aiSection.padding(.horizontal, 24).padding(.top, 20).transition(.opacity.combined(with: .move(edge: .bottom)))
                    
                    photoSection.padding(.horizontal, 24).padding(.top, 16)
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
                            footprint.isHighlight = !(footprint.isHighlight ?? false)
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
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation(.easeOut(duration: 0.25)) { showMap = true } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(.easeOut(duration: 0.3)) { showAI = true } }
                
                if isAutoPhotoLinkEnabled && footprint.photoAssetIDs.isEmpty {
                    if PhotoService.shared.authorizationStatus == .authorized || PhotoService.shared.authorizationStatus == .limited {
                        PhotoService.shared.fetchAssets(startTime: footprint.startTime, endTime: footprint.endTime, near: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)) { assets in
                            if !assets.isEmpty {
                                withAnimation {
                                    footprint.photoAssetIDs = assets.map { $0.localIdentifier }
                                    try? modelContext.save()
                                }
                            }
                        }
                    }
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
                                        var ids = footprint.photoAssetIDs
                                        ids.append(id)
                                        footprint.photoAssetIDs = ids
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
                                withAnimation {
                                    var ids = footprint.photoAssetIDs
                                    ids.append(id)
                                    footprint.photoAssetIDs = ids
                                }
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItems, matching: .images)
            .sheet(item: Binding(get: { selectedPhotoID.map { IdentifiableString(value: $0) } }, set: { selectedPhotoID = $0?.value })) { item in
                let index = footprint.photoAssetIDs.firstIndex(of: item.value) ?? 0
                PhotoFullscreenView(assetIDs: footprint.photoAssetIDs, currentIndex: index)
            }
            .sheet(isPresented: $showAddPlaceModal) {
                AddToFavoriteModal(footprint: footprint)
            }
            .sheet(isPresented: $showFullscreenMap) {
                FullFrameMapView(footprint: footprint)
            }
            .alert("添加新标签", isPresented: $showingAddTagAlert) {
                TextField("输入标签名称", text: $newTagName)
                Button("确定") {
                    addNewTag(newTagName)
                }
                Button("取消", role: .cancel) { }
            }
            .alert("确认移除照片？", isPresented: $showingPhotoDeleteAlert) {
                Button("移除", role: .destructive) { deletePhoto() }
                Button("取消", role: .cancel) { photoToDelete = nil }
            } message: {
                Text("这张照片将从该足迹中移除。")
            }
        }
    }
    
    private func deletePhoto() {
        guard let assetID = photoToDelete else { return }
        withAnimation {
            var ids = footprint.photoAssetIDs
            ids.removeAll(where: { $0 == assetID })
            footprint.photoAssetIDs = ids
            try? modelContext.save()
        }
        photoToDelete = nil
    }
    
    private func checkAndGenerateAIContent() {
        let isTitleEmpty = footprint.title.trimmingCharacters(in: .whitespaces).isEmpty || footprint.title == "新足迹"
        let isReasonEmpty = (footprint.reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        
        if isTitleEmpty || isReasonEmpty {
            // Find matched place name for background context
            let matchedPlace = savedPlaces.first(where: { $0.placeID == footprint.placeID })
            
            OpenAIService.shared.analyzeFootprint(
                locations: zip(footprint.latitudeArray, footprint.longitudeArray).map { ($0, $1) },
                duration: footprint.duration,
                startTime: footprint.startTime,
                endTime: footprint.endTime,
                placeName: matchedPlace?.name,
                placeTags: footprint.tags, // Only footprint tags, place no longer has tags
                address: footprint.address,
                isOngoing: false
            ) { title, reason, score in
                DispatchQueue.main.async {
                    if isTitleEmpty {
                        footprint.title = title
                    }
                    if isReasonEmpty {
                        footprint.reason = reason
                    }
                    try? modelContext.save()
                }
            }
        }
    }
    
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("你在哪里做什么？", text: $footprint.title)
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundColor(Color.dfkMainText)
                        .submitLabel(.done)
                        .focused($titleFocused)
                        .lineLimit(1)
                        .onSubmit { titleFocused = false; try? modelContext.save() }
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
        }
    }
    
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                refreshAddress()
            } label: {
                HStack(alignment: .center, spacing: 6) { 
                    Image(systemName: isUpdatingAddress ? "arrow.triangle.2.circlepath" : "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundColor(Color.dfkAccent)
                        .symbolEffect(.bounce, value: isUpdatingAddress)
                    
                    if isUpdatingAddress {
                        Text("正在重新获取地址...")
                            .font(.subheadline)
                            .foregroundColor(Color.dfkMainText.opacity(0.5))
                    } else {
                        Text(footprint.address ?? (matchedPlace?.address ?? "未记录位置"))
                            .font(.subheadline)
                            .foregroundColor(Color.dfkMainText.opacity(0.8))
                            .lineLimit(2)
                    }
                    
                    if let place = matchedPlace {
                        Spacer(minLength: 8)
                        Text(place.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) { 
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(Color.dfkSecondaryText)
                Text(timeRangeString)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Color.dfkSecondaryText) 
            }
            HStack(spacing: 6) { 
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundColor(Color.dfkSecondaryText)
                Text("停留 \(durationString)")
                    .font(.subheadline)
                    .foregroundColor(Color.dfkSecondaryText) 
            }            
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.04)))
    }
    
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                // 1. Footprint Tags (Important Place now moved to address row)
                ForEach(footprint.tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                        Button {
                            toggleTag(tag)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .foregroundColor(.green)
                    .clipShape(Capsule())
                }
                
                // 3. Add Tag Menu
                Menu {
                    let candidates = availableTags
                        .filter { !footprint.tags.contains($0.name) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    
                    if !candidates.isEmpty {
                        Section("已有标签") {
                            ForEach(candidates) { tag in
                                Button(tag.name) {
                                    toggleTag(tag.name)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button {
                        newTagName = ""
                        showingAddTagAlert = true
                    } label: {
                        Label("创建新标签...", systemImage: "plus.circle")
                    }
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var matchedPlace: Place? {
        savedPlaces.first(where: { $0.placeID == footprint.placeID })
    }
    
    private func toggleTag(_ name: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            var currentTags = footprint.tags
            if currentTags.contains(name) {
                currentTags.removeAll(where: { $0 == name })
            } else {
                currentTags.append(name)
            }
            footprint.tags = currentTags
            try? modelContext.save()
        }
    }
    
    private func addNewTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        withAnimation(.easeInOut(duration: 0.2)) {
            if !availableTags.contains(where: { $0.name == trimmed }) {
                let tag = PlaceTag(name: trimmed)
                modelContext.insert(tag)
            }
            
            if !footprint.tags.contains(trimmed) {
                var currentTags = footprint.tags
                currentTags.append(trimmed)
                footprint.tags = currentTags
                try? modelContext.save()
            }
        }
    }

    
    private var timeRangeString: String {
        let startStr = footprint.startTime.formatted(.dateTime.hour().minute())
        let endStr = footprint.endTime.formatted(.dateTime.hour().minute())
        
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
            return "\(footprint.startTime.formatted(.dateTime.month().day().hour().minute()))-\(footprint.endTime.formatted(.dateTime.month().day().hour().minute()))"
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
                            footprint.address = result
                            try? modelContext.save()
                        }
                    }
                }
            }
        }
    }
    
    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("位置轨迹").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 8)
            Button {
                showFullscreenMap = true
            } label: {
                FootprintDetailMapView(footprint: footprint, isInteractive: false)
                    .frame(height: 220)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(SpringButtonStyle())
        }
    }
    
    private var mapSkeleton: some View { RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .tertiarySystemGroupedBackground)).frame(height: 220).overlay(ProgressView().scaleEffect(1.2)) }
    
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("足迹感悟与备注").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 8)
            
            HStack(alignment: .top, spacing: 6) {
                TextField("输入感悟...", text: Binding(
                    get: { footprint.reason ?? "" },
                    set: { footprint.reason = $0 }
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
    
    @ViewBuilder
    private var addToPlacesSection: some View {
        let alreadySaved = footprint.placeID.map { id in savedPlaces.contains(where: { $0.placeID == id }) } ?? false
        if !alreadySaved && !footprint.isPlaceSuggestionIgnored {
            HStack(spacing: 0) {
                Button {
                    showAddPlaceModal = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 16))
                        Text("添加到重要地点")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .foregroundColor(.orange)
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(SpringButtonStyle())
                
                Rectangle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 4)
                
                Button {
                    withAnimation {
                        footprint.isPlaceSuggestionIgnored = true
                        try? modelContext.save()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpringButtonStyle())
                .padding(.trailing, 2)
            }
            .background(Color.orange.opacity(0.12))
            .cornerRadius(12)
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
    
    private func ignoreFootprint() { withAnimation { footprint.status = .ignored }; try? modelContext.save(); dismiss() }
}

struct FullFrameMapView: View {
    let footprint: Footprint
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            FootprintDetailMapView(footprint: footprint, isInteractive: true)
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
            Marker(title, coordinate: coordinate).tint(Color.orange)
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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .onTapGesture {
                        // Optional: single tap to hide/show UI, but here we just dismiss if tapped?
                        // Usually TabView prevents tap events from propagating easily if not careful.
                    }
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

struct FootprintDetailMapView: View {
    let footprint: Footprint
    var isInteractive: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition, interactionModes: isInteractive ? .all : []) {
            MapPolyline(coordinates: footprint.coordinates)
                .stroke(Color.dfkAccent, lineWidth: 5)
            
            if let first = footprint.coordinates.first {
                Marker("", coordinate: first).tint(Color.dfkAccent)
            }
            if let last = footprint.coordinates.last {
                Marker("", coordinate: last).tint(Color.dfkAccent)
            }
        }
        .mapStyle(.standard)
        .onAppear {
            if let region = footprint.region {
                cameraPosition = .region(region)
            }
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

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > containerWidth {
                height += currentRowHeight + spacing
                currentRowWidth = size.width + spacing
                currentRowHeight = size.height
            } else {
                currentRowWidth += size.width + spacing
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        return CGSize(width: containerWidth, height: height + currentRowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += currentRowHeight + spacing
                currentRowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
