import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import Photos

// MARK: - Day Summary Card
struct DaySummaryCard: View {
    let date: Date
    let dateOffset: Int
    let totalPoints: Int
    let footprintCount: Int
    let totalMileage: Double
    let points: [CLLocationCoordinate2D]
    var timelineItems: [TimelineItem] = []
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    var photoAssets: [PHAsset] = []
    var summary: String? = nil
    var isLoading: Bool = false
    var rendersLiveMap: Bool = true
    
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    private var hasDataForMap: Bool {
        !points.isEmpty || !photoAssets.isEmpty || !timelineItems.isEmpty
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. Timeline Indicator (Summary Style)
            VStack(spacing: 0) {
                Spacer().frame(height: 18)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.dfkAccent)
                    .frame(width: 32, height: 32)
                Spacer()
            }.frame(width: 54)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top Section: Info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        let isGenerating = OpenAIService.shared.currentlyProcessingDate != nil && 
                                          Calendar.current.isDate(OpenAIService.shared.currentlyProcessingDate!, inSameDayAs: date)
                        
                        Text(summary ?? "当日概览")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(Color.dfkMainText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .breathing(isActive: isGenerating)
                        
                        HStack(spacing: 12) {
                            DayStatItem(value: "\(footprintCount)", label: "足迹")
                            DayStatSeparator()
                            DayStatItem(value: formatDistance(totalMileage), label: "里程数")
                        }
                        .padding(.top, 2)
                    }
                    
                }
                .padding(.vertical, 16)
                .padding(.leading, 0)
                .padding(.trailing, 16)
                
                 // Mini Map Section
                if hasDataForMap {
                    DFKMapView(
                        cameraPosition: $cameraPosition,
                        rendersLiveMap: rendersLiveMap,
                        isInteractive: false,
                        points: points,
                        timelineItems: timelineItems,
                        photoAssets: photoAssets,
                        onTimelineItemTap: onTimelineItemTap
                    )
                    .frame(height: 140)
                    .cornerRadius(12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showFullscreenMap = true
                    }
                    .onAppear { updateCameraPosition() }
                    .onChange(of: points.count) { _, _ in updateCameraPosition() }
                    .onChange(of: photoAssets.count) { _, _ in updateCameraPosition() }
                    .onChange(of: timelineItems.count) { _, _ in updateCameraPosition() }
                    .padding(.leading, 0)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                } else {
                    // Placeholder if truly no data
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.05))
                        .frame(height: 140)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "map.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary.opacity(0.3))
                                Text(isLoading ? "正在加载..." : (totalPoints > 0 ? "正在分析路线轨迹..." : "本日无位置记录"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        )
                        .padding(.leading, 0)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .padding(.bottom, 14)
        .onTapGesture {
            if hasDataForMap {
                showFullscreenMap = true
            }
        }
        .sheet(isPresented: $showFullscreenMap) {
            FullFrameTrajectoryMapView(
                title: date.formatted(.dateTime.month().day()) + " 轨迹",
                points: points,
                timelineItems: timelineItems,
                onTimelineItemTap: onTimelineItemTap,
                photoAssets: photoAssets,
                showsUserLocation: true
            )
        }
    }
    
    private func updateCameraPosition() {
        var allCoords = points
        
        // 1. 加入足迹坐标与交通记录坐标
        for item in timelineItems {
            switch item {
            case .footprint(let fp):
                allCoords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
            case .transport(let transport):
                allCoords.append(contentsOf: transport.points)
            }
        }
        
        // 2. 加入照片坐标
        let photoCoords = photoAssets.compactMap { $0.location?.gcj02.coordinate }
        allCoords.append(contentsOf: photoCoords)
        
        if !allCoords.isEmpty {
            if let region = allCoords.boundingRegion(paddingFactor: 1.4) {
                withAnimation {
                    cameraPosition = .region(region)
                }
            }
        }
    }
}

// MARK: - Shared Utilities
private func formatDistance(_ meters: Double) -> String {
    if meters < 1000 {
        return "\(Int(meters))m"
    } else {
        return String(format: "%.1fkm", meters / 1000.0)
    }
}

struct DayStatItem: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color.dfkMainText)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

struct DayStatSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .frame(width: 1, height: 18)
            .padding(.top, 2)
    }
}

struct FullFrameTrajectoryMapView: View {
    let title: String
    let points: [CLLocationCoordinate2D]
    var timelineItems: [TimelineItem] = []
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    var photoAssets: [PHAsset] = []
    var showsUserLocation: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedFootprint: Footprint?
    @State private var selectedTransport: Transport?
    @State private var selectedPhotoAsset: IdentifiableString?
    @State private var hasAutoCentered = false
    
    var body: some View {
        NavigationStack {
            DFKMapView(
                cameraPosition: $cameraPosition,
                isInteractive: true,
                showsUserLocation: showsUserLocation,
                points: points,
                timelineItems: timelineItems,
                photoAssets: photoAssets,
                showsStandalonePhotos: false,
                prefersActivityIcons: false,
                onTimelineItemTap: { item in
                    switch item {
                    case .footprint(let footprint):
                        self.selectedFootprint = footprint
                    case .transport(let transport):
                        self.selectedTransport = transport
                    }
                },
                onPhotoTap: { asset in
                    self.selectedPhotoAsset = IdentifiableString(value: asset.localIdentifier)
                }
            )
            .sheet(item: $selectedFootprint) { footprint in
                FootprintModalView(footprint: footprint)
            }
            .sheet(item: $selectedTransport) { transport in
                TransportModalView(transport: transport) { _ in
                    // In-map updates will reflect on reappear if needed, 
                    // but usually parents handle building the list.
                } onLocationUpdate: {
                    // Location update handled by parent via callbacks
                }
            }
            .sheet(item: $selectedPhotoAsset) { item in
                let assetIDs = photoAssets.map { $0.localIdentifier }
                let index = assetIDs.firstIndex(of: item.value) ?? 0
                PhotoFullscreenView(assetIDs: assetIDs, currentIndex: index)
            }
            .onAppear { updateCamera() }
            .onChange(of: points.count) { _, _ in updateCamera() }
            .onChange(of: photoAssets.count) { _, _ in updateCamera() }
            .onChange(of: timelineItems.count) { _, _ in updateCamera() }
            .navigationTitle(title)
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
    
    private func updateCamera(force: Bool = false) {
        if !force && hasAutoCentered && !points.isEmpty { return }
        
        var allCoords = points
        
        // 1. 加入足迹坐标与交通记录坐标
        for item in timelineItems {
            switch item {
            case .footprint(let fp):
                allCoords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
            case .transport(let transport):
                allCoords.append(contentsOf: transport.points)
            }
        }
        
        // 2. 加入照片坐标
        let photoCoords = photoAssets.compactMap { $0.location?.gcj02.coordinate }
        allCoords.append(contentsOf: photoCoords)
        
        if !allCoords.isEmpty {
            if let region = allCoords.boundingRegion(paddingFactor: 1.4) {
                withAnimation {
                    cameraPosition = .region(region)
                    hasAutoCentered = true
                }
            }
        } else if showsUserLocation, let lastLoc = LocationManager.shared.lastLocation {
            cameraPosition = .region(MKCoordinateRegion(center: lastLoc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
            hasAutoCentered = true
        }
    }
}

// MARK: - Recording Status Card
struct RecordingStatusCard: View {
    let locationManager: LocationManager
    let footprintCount: Int
    var timelineItems: [TimelineItem] = []
    var rendersLiveMap: Bool = true
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    var photoAssets: [PHAsset] = []
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showingGuide = false
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = true
    
    private var displayTitle: String {
        let isStopped = !locationManager.isTracking
        if isStopped {
            return "定位记录已关闭"
        }
        
        // 优先使用 LocationManager 的稳定移动判断（带滞回），避免走路时标题频繁切换“停留”
        if locationManager.uiIsMoving {
            if let location = locationManager.lastLocation, location.speed > 0 {
                let speedKmh = location.speed * 3.6
                if speedKmh > 90 {
                    return "正在高速移动"
                } else if speedKmh > 30 {
                    return "正在快速移动"
                } else if speedKmh > 5 {
                    return "正在持续移动"
                }
            }
            return "正在移动"
        }
        
        // 优先显示重要地点名称
        if let place = locationManager.matchedPlace, place.isUserDefined {
            return "正在\(place.name)停留"
        }
        
        if let ongoing = locationManager.ongoingTitle {
            return "正在\(ongoing)停留"
        } else {
            return "正在此处停留"
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. 时间轴指示器
            VStack(spacing: 0) {
                Spacer().frame(height: 22)
                
                // 呼吸圆点 (采用 TimelineView 彻底解决重绘导致的动画跳变)
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let duration = locationManager.pulseDuration
                    let progress = (now.truncatingRemainder(dividingBy: duration)) / duration
                    let scale = 1.0 + (progress * 2.5) // 1.0 -> 3.5
                    let opacity = (1.0 - progress) * 0.4
                    
                    ZStack {
                        Circle().stroke(Color.dfkAccent.opacity(opacity), lineWidth: 3)
                            .frame(width: 8, height: 8)
                            .scaleEffect(scale)
                        
                        Circle().fill(Color.dfkAccent).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 24, height: 24)
                
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, -20)
            }.frame(width: 54)
            
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    // Title Section
                    Group {
                        if !locationManager.isTracking {
                            Text(displayTitle)
                                .foregroundColor(.secondary)
                        } else if let place = locationManager.matchedPlace, place.isUserDefined {
                            Text("正在")
                                .foregroundColor(Color.dfkMainText) +
                            Text(place.name)
                                .foregroundColor(.orange) +
                            Text("停留")
                                .foregroundColor(Color.dfkMainText)
                        } else {
                            Text(displayTitle)
                                .foregroundColor(Color.dfkMainText)
                        }
                    }
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .breathing(isActive: OpenAIService.shared.currentlyProcessingDate != nil && Calendar.current.isDate(OpenAIService.shared.currentlyProcessingDate!, inSameDayAs: Date()))

                    // Duration/Status Section
                    HStack(spacing: 4) {
                        if !locationManager.isTracking {
                            Button {
                                if !isTrackingEnabled {
                                    isTrackingEnabled = true
                                    locationManager.startTracking()
                                }
                                showingGuide = true
                            } label: {
                                Text("点击开启位置记录")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.orange.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        } else {
                            TimelineView(.periodic(from: .now, by: 60)) { _ in
                                if let durationStr = locationManager.stayDuration {
                                    Text("已停留 \(durationStr)")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.leading, 0)
                .padding(.trailing, 16)
                
                // DFKMapView Section
                DFKMapView(
                    cameraPosition: $cameraPosition,
                    rendersLiveMap: rendersLiveMap,
                    isInteractive: false,
                    points: locationManager.allTodayCoordinates,
                    timelineItems: timelineItems,
                    photoAssets: photoAssets,
                    onTimelineItemTap: onTimelineItemTap
                )
                .frame(height: 140)
                .cornerRadius(12)
                .padding(.leading, 0)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    showFullscreenMap = true
                }
                .onAppear {
                    updateTodayCamera()
                }
                .onChange(of: locationManager.allTodayCoordinates.count) { _, _ in
                    updateTodayCamera()
                }
                .onChange(of: timelineItems.count) { _, _ in
                    updateTodayCamera()
                }
                .onChange(of: locationManager.lastLocation) { _, newLoc in
                    // If no points yet, keep tracking current position
                    if locationManager.allTodayPoints.isEmpty, let newLoc {
                        withAnimation {
                            cameraPosition = .region(MKCoordinateRegion(center: newLoc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
                        }
                    }
                }
            }
            .padding(.vertical, 0)
            .padding(.leading, 0)
            .padding(.trailing, 0)
            }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .padding(.bottom, 14)
        .onTapGesture {
            showFullscreenMap = true
        }
        .sheet(isPresented: $showFullscreenMap) {
            FullFrameTrajectoryMapView(
                title: "今日轨迹",
                points: locationManager.allTodayCoordinates,
                timelineItems: timelineItems,
                onTimelineItemTap: onTimelineItemTap,
                photoAssets: photoAssets,
                showsUserLocation: true
            )
        }
        .sheet(isPresented: $showingGuide) {
            TrackingGuideView()
        }
    }
    
    private func updateTodayCamera() {
        var allCoords = locationManager.allTodayCoordinates
        
        // 加入足迹坐标与交通记录坐标
        for item in timelineItems {
            switch item {
            case .footprint(let fp):
                allCoords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
            case .transport(let transport):
                allCoords.append(contentsOf: transport.points)
            }
        }
        
        let photoCoords = photoAssets.compactMap { $0.location?.gcj02.coordinate }
        allCoords.append(contentsOf: photoCoords)
        
        if let region = allCoords.boundingRegion() {
            withAnimation {
                cameraPosition = .region(region)
            }
        } else if let newLoc = locationManager.lastLocation {
            cameraPosition = .region(MKCoordinateRegion(center: newLoc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
        }
    }
}

// MARK: - Footprint Card View
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
    let onTap: (Footprint, Bool) -> Void
    
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @State private var highlightVisible: Bool = false
    @State private var showingDeleteConfirm = false
    @State private var showingIgnoreConfirm = false
    @State private var confirmedAnimating: Bool = false
    
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
                            let matchedPlace = allPlaces.first(where: { place in
                                if place.placeID == footprint.placeID && place.isUserDefined { return true }
                                guard place.isUserDefined else { return false }
                                let fpAddr = (footprint.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !fpAddr.isEmpty else { return false }
                                return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr || 
                                       (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == fpAddr)
                            })
                            let displayText = matchedPlace?.name ?? footprint.address ?? "未知地点"
                            
                            Text(displayText)
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(matchedPlace != nil ? .orange : Color.dfkMainText)
                                .lineLimit(1)
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
                        
                        if let reason = footprint.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(Color.dfkMainText.opacity(0.8))
                                .lineLimit(3)
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
                                AssetThumbnailView(assetID: firstID, showsTime: false)
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
            .onAppear {
                if footprint.isHighlight == true {
                    withAnimation(.easeOut(duration: 0.3).delay(0.2)) { highlightVisible = true }
                }
                geocodeAddress()
                
                // 自动关联缺失或无效的照片（针对首次入场或跨设备同步的情况）
                locationManager.linkPhotos(to: footprint, context: modelContext)
            }
        }
    }
    
    private func geocodeAddress() {
        guard (footprint.address ?? "").isEmpty else { return }
        
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: footprint.latitude, longitude: footprint.longitude)
        
        geocoder.reverseGeocodeLocation(location) { placemarks, error in

            guard let placemark = placemarks?.first, error == nil else { return }
            
            let name = placemark.name ?? ""
            let subLocality = placemark.subLocality ?? ""
            let thoroughfare = placemark.thoroughfare ?? ""
            
            let addressStr: String
            if !thoroughfare.isEmpty && name != thoroughfare {
                addressStr = "\(thoroughfare) \(name)"
            } else if !subLocality.isEmpty {
                addressStr = "\(subLocality) \(name)"
            } else {
                addressStr = name
            }
            
            if !addressStr.isEmpty {
                DispatchQueue.main.async {
                    footprint.address = addressStr
                    try? footprint.modelContext?.save()
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
        let iconName = activity?.icon ?? "mappin.circle.fill"
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
            
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                
                if footprint.isHighlight == true {
                    Image(systemName: "star.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color.dfkHighlight)
                        .padding(2)
                        .background(Circle().fill(Color(uiColor: .systemBackground)))
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 32, height: 32)
            
            if showTimeline {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, -12)
                    .opacity(isLast ? 0 : 1)
            } else {
                Spacer()
            }
        }.frame(width: 54)
    }
    
    @ViewBuilder
    private var longPressMenu: some View {
        Button { onTap(footprint, true) } label: { Label("编辑", systemImage: "pencil") }
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                footprint.isHighlight = !(footprint.isHighlight ?? false)
                try? modelContext.save()
                highlightVisible = (footprint.isHighlight == true)
            }
        } label: { Label(footprint.isHighlight == true ? "取消收藏" : "收藏", systemImage: footprint.isHighlight == true ? "star.slash" : "star.fill") }
        
        Divider()
        
        Button {
            showingIgnoreConfirm = true
        } label: { Label("忽略地点", systemImage: "mappin.slash") }
        
        Button(role: .destructive) { showingDeleteConfirm = true } label: { Label("删除", systemImage: "trash") }
    }
    
    private func confirmFootprint() {
        withAnimation(.spring(response: 0.3)) {
            footprint.status = .confirmed
            confirmedAnimating = true
            try? modelContext.save()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmedAnimating = false }
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

// MARK: - Placeholder Footprint Card
struct PlaceholderFootprintCard: View {
    private let phrases = [
        "新的足迹正在记录...",
        "新的足迹即将生成...",
    ]
    
    @Environment(LocationManager.self) private var locationManager
    @State private var phrase: String = ""
    
    private var contextTip: String? {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        
        // 2. 移动状态提示
        if let location = locationManager.lastLocation, location.speed > 1.0 {
            let speedKmh = location.speed * 3.6
            if speedKmh > 20 {
                return "正在飞驰中，注意安全"
            }
        }
        
        // 3. 时间维度提示
        if hour >= 23 || hour <= 4 {
            return "夜深了，早点休息"
        } else if hour >= 5 && hour <= 8 {
            return "早安！又是活力满满的一天"
        }
        
        // 1. 深度停留提示 (User's request)
        if let startLoc = locationManager.potentialStopStartLocation {
            let duration = now.timeIntervalSince(startLoc.timestamp)
            if duration > 48 * 3600 {
                return "要不出去走走？世界那么大，去看看"
            } else if duration > 15 * 3600 {
                return "你已经在这里停留好久了，想去探索新地方吗？"
            }
        }
        
        return nil
    }
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let phase = (now.truncatingRemainder(dividingBy: 3.5)) / 3.5
            let sinValue = sin(phase * .pi * 2)
            let opacity = 0.7 + (sinValue + 1.0) * 0.15
            
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5, height: 22)
                    
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                            .frame(width: 12, height: 12)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                    }.frame(width: 24, height: 24)
                    
                    Spacer()
                }
                .frame(width: 54)
                
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phrase)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        
                        if let tip = contextTip {
                            Text(tip)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.05))
                            .frame(width: 140, height: 8)
                        
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.03))
                                .frame(width: 60, height: 8)
                            Circle().fill(Color.secondary.opacity(0.03)).frame(width: 3, height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.03))
                                .frame(width: 40, height: 8)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 14)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
            )
            .opacity(opacity)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .onAppear {
            phrase = phrases.randomElement() ?? phrases[0]
        }
    }
}

// MARK: - Guides
struct ImportantPlaceGuide: View {
    @Binding var isGuideDismissed: Bool
    
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
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToImportantPlaces"), object: nil)
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

struct NotificationGuide: View {
    @Binding var isNotificationGuideDismissed: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.dfkHighlight.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "bell.badge.fill").font(.system(size: 14, weight: .bold)).foregroundColor(Color.dfkHighlight))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("开启每日足迹汇总").font(.system(size: 14, weight: .bold))
                Text("每日为您汇总今日精彩足迹与回忆").font(.system(size: 12)).foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button("立即开启") {
                    NotificationManager.shared.requestAuthorization { granted in
                        DispatchQueue.main.async {
                            withAnimation(.spring()) { 
                                isNotificationGuideDismissed = true 
                                if granted {
                                    UserDefaults.standard.set(true, forKey: "isDailyNotificationEnabled")
                                }
                            }
                        }
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color.dfkHighlight)
                
                Button {
                    withAnimation(.spring()) { isNotificationGuideDismissed = true }
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dfkHighlight.opacity(0.06)))
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
// MARK: - Animations
struct BreathingOpacityModifier: ViewModifier {
    let isActive: Bool
    @State private var opacity: Double = 1.0
    
    func body(content: Content) -> some View {
        content
            .opacity(isActive ? opacity : 1.0)
            .onAppear {
                if isActive {
                    startAnimation()
                }
            }
            .onChange(of: isActive) { oldValue, newValue in
                if newValue {
                    startAnimation()
                } else {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        opacity = 1.0
                    }
                }
            }
    }
    
    private func startAnimation() {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            opacity = 0.4
        }
    }
}

extension View {
    func breathing(isActive: Bool) -> some View {
        self.modifier(BreathingOpacityModifier(isActive: isActive))
    }
}

// MARK: - Tracking Guide View
struct TrackingGuideView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("如何确保记录成功？")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("地方客通过系统后台服务记录您的足迹，为了保证记录的连续性，请检查以下设置：")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 10)
                    
                    GuideItem(icon: "location.fill", color: .blue, title: "定位权限", description: "请确保定位权限设置为「始终」，否则在 App 退出后台后将无法记录。")
                    
                    GuideItem(icon: "scope", color: .orange, title: "精确位置", description: "开启「精确位置」开关，以获得更准确的停留点识别和路径。")
                    
                    GuideItem(icon: "arrow.clockwise", color: .green, title: "后台 App 刷新", description: "在系统设置中允许「后台 App 刷新」，确保应用能及时处理定位更新。")
                    
                    GuideItem(icon: "battery.100", color: .yellow, title: "电池优化", description: "请勿将应用设置为「低电量模式」，这可能会限制后台定位频率。")
                    
                    Spacer(minLength: 40)
                    
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("前往系统设置")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.dfkAccent)
                            .cornerRadius(14)
                    }
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

struct GuideItem: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(color)
                .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
