import SwiftUI
import CoreLocation
import MapKit
import SwiftData

// MARK: - Day Summary Card
struct DaySummaryCard: View {
    let date: Date
    let totalPoints: Int
    let footprintCount: Int
    let transportMileage: Double
    let points: [CLLocationCoordinate2D]
    var timelineItems: [TimelineItem] = []
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 1. Timeline Indicator (Summary Style)
            VStack(spacing: 0) {
                Spacer().frame(height: 18)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.dfkAccent)
                    .frame(width: 24, height: 24)
                Spacer()
            }.frame(width: 40)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top Section: Info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当日概览")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(Color.dfkMainText)
                        
                        HStack(spacing: 12) {
                            DayStatItem(value: "\(totalPoints)", label: "轨迹点")
                            DayStatSeparator()
                            DayStatItem(value: "\(footprintCount)", label: "足迹")
                            DayStatSeparator()
                            DayStatItem(value: formatDistance(transportMileage), label: "里程数")
                        }
                        .padding(.top, 2)
                    }
                    
                }
                .padding(.vertical, 16)
                .padding(.leading, 8)
                .padding(.trailing, 16)
                
                // Mini Map Section
                if !points.isEmpty {
                    DFKMapView(
                        cameraPosition: $cameraPosition,
                        isInteractive: false,
                        showsUserLocation: false,
                        points: points,
                        timelineItems: timelineItems,
                        onTimelineItemTap: onTimelineItemTap
                    )
                    .frame(height: 140)
                    .cornerRadius(12)
                    .onAppear {
                        if let region = points.boundingRegion() {
                            cameraPosition = .region(region)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                } else {
                    // Placeholder if no points but still showing card
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.05))
                        .frame(height: 140)
                        .overlay(
                            Text("暂无轨迹信息")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        )
                        .padding(.leading, 8)
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
            if !points.isEmpty {
                showFullscreenMap = true
            }
        }
        .sheet(isPresented: $showFullscreenMap) {
            FullFrameTrajectoryMapView(
                title: date.formatted(.dateTime.month().day()) + " 轨迹",
                points: points,
                timelineItems: timelineItems,
                onTimelineItemTap: onTimelineItemTap,
                showsUserLocation: false
            )
        }
    }
    
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000.0)
        }
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
    var showsUserLocation: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedFootprint: Footprint?
    @State private var selectedTransport: Transport?
    
    var body: some View {
        NavigationStack {
            DFKMapView(
                cameraPosition: $cameraPosition,
                isInteractive: true,
                showsUserLocation: showsUserLocation,
                points: points,
                timelineItems: timelineItems,
                onTimelineItemTap: { item in
                    switch item {
                    case .footprint(let footprint):
                        self.selectedFootprint = footprint
                    case .transport(let transport):
                        self.selectedTransport = transport
                    }
                    onTimelineItemTap?(item) // Still notify parent if needed
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
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                if let region = points.boundingRegion() {
                    cameraPosition = .region(region)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}

// MARK: - Recording Status Card
struct RecordingStatusCard: View {
    let locationManager: LocationManager
    let footprintCount: Int
    var timelineItems: [TimelineItem] = []
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    @State private var showFullscreenMap = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    private var displayTitle: String {
        let isStopped = !locationManager.isTracking
        if isStopped {
            return "定位记录已关闭"
        }
        
        // 探测实时移动状态
        if let location = locationManager.lastLocation, location.speed > 1.0 {
            let speedKmh = location.speed * 3.6
            if speedKmh > 90 {
                return "正在高速移动"
            } else if speedKmh > 30 {
                return "正在快速移动"
            } else if speedKmh > 5 {
                return "正在持续移动"
            }
        }
        
        if let ongoing = locationManager.ongoingTitle {
            return ongoing
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
            }.frame(width: 40)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top Section: Info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(!locationManager.isTracking ? .secondary : Color.dfkMainText)
                        
                        // 地址与地点行
                        HStack(spacing: 6) {
                            if locationManager.isTracking && !locationManager.currentAddress.isEmpty && locationManager.currentAddress != "正在解析位置..." {
                                Text(locationManager.currentAddress)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(Color.dfkMainText.opacity(0.85))
                                    .lineLimit(1)
                            }
                            
                            if let place = locationManager.matchedPlace, place.isUserDefined {
                                Text(place.name)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.orange.opacity(0.12))
                                    .foregroundColor(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 1)
                        
                        HStack(spacing: 4) {                            
                            if !locationManager.isTracking {
                                Text("点击开启或查看说明")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.orange.opacity(0.8))
                            } else if let durationStr = locationManager.stayDuration {
                                Text("已停留 \(durationStr)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .id("duration-\(durationStr)")
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 16)
                .padding(.leading, 8)
                .padding(.trailing, 16)
                
                // DFKMapView Section
                DFKMapView(
                    cameraPosition: $cameraPosition,
                    isInteractive: false,
                    showsUserLocation: true,
                    points: locationManager.allTodayPoints.map { $0.coordinate },
                    timelineItems: timelineItems,
                    onTimelineItemTap: onTimelineItemTap
                )
                .frame(height: 160)
                .cornerRadius(12)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .onAppear {
                    let todayPoints = locationManager.allTodayPoints.map { $0.coordinate }
                    if let region = todayPoints.boundingRegion() {
                        cameraPosition = .region(region)
                    } else if let newLoc = locationManager.lastLocation {
                        cameraPosition = .region(MKCoordinateRegion(center: newLoc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
                    }
                }
                .onChange(of: locationManager.allTodayPoints.count) { _, count in
                    // Only auto-adjust if the trajectory is growing and not already focused by user manual
                    let todayPoints = locationManager.allTodayPoints.map { $0.coordinate }
                    if let region = todayPoints.boundingRegion() {
                        withAnimation {
                            cameraPosition = .region(region)
                        }
                    }
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
                points: locationManager.allTodayPoints.map { $0.coordinate },
                timelineItems: timelineItems,
                onTimelineItemTap: onTimelineItemTap,
                showsUserLocation: true
            )
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
                 if showTimeline {
                     timelineIndicator
                 }
                 ZStack(alignment: .topTrailing) {
                     if let activity = footprint.getActivityType(from: allActivities) {
                         Image(systemName: activity.icon)
                             .font(.system(size: 18, weight: .bold))
                             .foregroundColor(activity.color)
                             .padding(.top, 14)
                             .padding(.trailing, 14)
                     }
                     
                     VStack(alignment: .leading, spacing: 4) {
                        if showDateAboveTitle && (contextDate == nil || !Calendar.current.isDate(footprint.date, inSameDayAs: contextDate!)) {
                            Text(footprint.date.formatted(.dateTime.year().month().day()))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.bottom, -2)
                        }
                        
                        HStack(spacing: 6) {
                            Text(footprint.title.isEmpty ? "地点记录" : footprint.title)
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(Color.dfkMainText)
                                .lineLimit(1)
                        }
                        

                        HStack(spacing: 6) {
                            if let addr = footprint.address, !addr.isEmpty {
                                Text(addr)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(Color.dfkMainText.opacity(0.85))
                                    .lineLimit(1)
                            }
                            
                            if let placeID = footprint.placeID,
                               let place = allPlaces.first(where: { $0.placeID == placeID && $0.isUserDefined }) {
                                Text(place.name)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.orange.opacity(0.12))
                                    .foregroundColor(.orange)
                                    .clipShape(Capsule())
                                    .fixedSize()
                            }
                        }
                        .padding(.top, 1)
                        
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
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(Color.dfkSecondaryText.opacity(0.8))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.leading, showTimeline ? 0 : 16)
                    .padding(.trailing, footprint.photoAssetIDs.isEmpty ? 16 : 60) // Add space for photo if present
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    
                    if let firstID = footprint.photoAssetIDs.first {
                        ZStack(alignment: .bottomTrailing) {
                            Color.clear // Expand to fill parent
                            
                            ZStack(alignment: .topTrailing) {
                                AssetThumbnailView(assetID: firstID, onAssetMissing: {
                                    withAnimation {
                                        var ids = footprint.photoAssetIDs
                                        ids.removeAll { $0 == firstID }
                                        footprint.photoAssetIDs = ids
                                        try? modelContext.save()
                                    }
                                })
                                    .id(firstID)
                                    .frame(width: 48, height: 48)
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
                            .padding(.bottom, 12)
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
            .contextMenu { longPressMenu }
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
                
                // 自动关联缺失的照片（针对首次入场或后台漏扫的情况）
                if footprint.photoAssetIDs.isEmpty {
                    locationManager.linkPhotos(to: footprint, context: modelContext)
                }
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
        VStack(spacing: 0) {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(height: 22)
                .opacity(isFirst && !isToday ? 0 : 1)
            
            ZStack {
                if footprint.isHighlight == true {
                    Image(systemName: "star.fill").font(.system(size: 14)).foregroundColor(Color.dfkHighlight).padding(4).background(Circle().fill(Color(uiColor: .systemBackground)))
                } else {
                    Circle().fill(Color.dfkAccent).frame(width: 10, height: 10)
                        .scaleEffect(confirmedAnimating ? 1.4 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: confirmedAnimating)
                }
            }.frame(width: 24, height: 24)
            
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .padding(.bottom, -12)
                .opacity(isLast ? 0 : 1)
        }.frame(width: 40)
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
    
    private func ignoreFootprint() { withAnimation { footprint.status = .ignored; try? modelContext.save() } }
}

// MARK: - Placeholder Footprint Card
struct PlaceholderFootprintCard: View {
    private let phrases = [
        "今日份回忆正在后台悄悄酝酿...",
        "正在捕捉第一段时光足迹...",
        "别急，这一天的故事正在落笔...",
        "时光正在被系统悉心收纳...",
        "正在为您打磨今日的轨迹线...",
        "第一段记忆正在慢慢发酵..."
    ]
    
    @State private var phrase: String = ""
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let phase = (now.truncatingRemainder(dividingBy: 3.5)) / 3.5
            let sinValue = sin(phase * .pi * 2)
            let opacity = 0.3 + (sinValue + 1.0) / 2.0 * 0.5
            
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5, height: 22)
                    
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                    }.frame(width: 24, height: 24)
                    
                    Spacer()
                }
                .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text(phrase)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.4))
                        .lineLimit(2)
                    
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
    let onAddAction: () -> Void
    
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
                    onAddAction()
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
