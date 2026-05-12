import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import Photos

struct TransportCardView: View {
    let transport: Transport
    let allPlaces: [Place]
    var isFirst: Bool = false
    var isLast: Bool = false
    var isToday: Bool = false
    var onSelect: ((Transport) -> Void)? = nil
    var onDelete: ((Transport) -> Void)? = nil
    
    var body: some View {
        Button {
            onSelect?(transport)
        } label: {
            HStack(alignment: .center, spacing: 0) {
                // 1. Timeline Indicator
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5)
                        .frame(height: 8) // Reduced from 12
                        .opacity(isFirst && !isToday ? 0 : 1)
                    
                    ZStack {
                        Image(systemName: transport.currentType.sfSymbol)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color.dfkAccent)
                            .frame(width: 32, height: 32)
                            .offset(y: -2) // Move icon up further
                    }.frame(width: 32, height: 32)
                    
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, -12)
                        .opacity(isLast ? 0 : 1)
                }.frame(width: 54)
                
                // 2. Minimalist Content
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) { // Narrowed slightly
                        // 时间范围
                        Text("\(transport.startTime.formatted(.dateTime.hour().minute()))-\(transport.endTime.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.3))
                        
                        // 总时长
                        Text(durationString)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.3))
                        
                        // 里程/距离
                        Text(distanceString)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.dfkAccent)
                        
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.3))
                        
                        // 速度
                        Text(String(format: "%.1fkm/h", transport.averageSpeed * 3.6))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        // 步数 (如果有)
                        if let steps = transport.stepCount, steps > 0 {
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.3))
                                
                            HStack(spacing: 2) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 11))
                                Text("\(steps)")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.orange.opacity(0.8))
                        }
                    }
                    .padding(.vertical, 8)
                }
                .padding(.leading, 4)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .padding(.bottom, 8)
            .contextMenu {
                Button {
                    onSelect?(transport)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .alert("确认删除此交通记录？", isPresented: $showingDeleteAlert) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    onDelete?(transport)
                }
            } message: {
                Text("删除后该段交通将从时间轴中隐藏。")
            }
        }
        .buttonStyle(.plain)
    }
    
    @State private var showingDeleteAlert = false
    
    @ViewBuilder
    private var transportIcon: some View {
        Image(systemName: transport.currentType.sfSymbol)
    }
    
    private var distanceString: String {
        if transport.distance < 1000 {
            return String(format: "%.0f米", transport.distance)
        } else {
            return String(format: "%.1f公里", transport.distance / 1000.0)
        }
    }
    
    private var durationString: String {
        let seconds = transport.duration
        if seconds < 60 {
            return "1分钟内"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)分钟"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)小时\(mins)分" : "\(hours)小时"
        }
    }
}

// MARK: - TransportModalView
struct TransportModalView: View {
    let transport: Transport
    var onUpdate: ((TransportType) -> Void)? = nil
    var onLocationUpdate: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var position: MapCameraPosition = .automatic
    @State private var localManualType: TransportType? = nil
    @State private var selectedMarker: LocationType? = nil
    @State private var showingMarkerDialog: LocationType? = nil
    
    @Environment(LocationManager.self) private var locationManager
    @State private var showingSearchSheet: LocationType? = nil
    @State private var localStartOverride: String? = nil
    @State private var localEndOverride: String? = nil
    @State private var mapPhotos: [PHAsset] = []
    @State private var selectedPhotoAsset: IdentifiableString?
    
    enum LocationType: Identifiable {
        case start, end
        var id: Int { self == .start ? 0 : 1 }
    }
    
    private var currentStartLocation: String {
        localStartOverride ?? transport.startLocation
    }
    
    private var currentEndLocation: String {
        localEndOverride ?? transport.endLocation
    }

    private var validTransportPoints: [CLLocationCoordinate2D] {
        transport.points.filter {
            $0.latitude.isFinite &&
            $0.longitude.isFinite &&
            CLLocationCoordinate2DIsValid($0)
        }
    }

    private var validMapPhotos: [(asset: PHAsset, coordinate: CLLocationCoordinate2D)] {
        mapPhotos.compactMap { asset in
            guard let coordinate = asset.location?.gcj02.coordinate,
                  coordinate.latitude.isFinite,
                  coordinate.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return (asset, coordinate)
        }
    }
    
    // Use the effective type for display
    private var displayType: TransportType {
        localManualType ?? transport.currentType
    }
    
    private var isStartImportantPlace: Bool {
        allPlaces.contains { place in
            guard place.isUserDefined else { return false }
            let addr = currentStartLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == addr || 
                   (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == addr)
        }
    }
    
    private var isEndImportantPlace: Bool {
        allPlaces.contains { place in
            guard place.isUserDefined else { return false }
            let addr = currentEndLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == addr || 
                   (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == addr)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // 1. Map View
                GeometryReader { geometry in
                    if geometry.size.width > 1 && geometry.size.height > 1 {
                        Map(position: $position) {
                            // Important Places Circles (isUserDefined)
                            ForEach(allPlaces.filter {
                                $0.isUserDefined &&
                                $0.radius.isFinite &&
                                $0.radius > 1 &&
                                $0.coordinate.latitude.isFinite &&
                                $0.coordinate.longitude.isFinite &&
                                CLLocationCoordinate2DIsValid($0.coordinate)
                            }) { place in
                                MapCircle(center: place.coordinate, radius: max(5, min(Double(place.radius), 10_000)))
                                    .foregroundStyle(Color.orange.opacity(0.1))
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            }

                            // Start Marker (Physical Look & Title)
                            if let start = validTransportPoints.first {
                                Marker(currentStartLocation, coordinate: start)
                                    .tint(.green)
                            }
                            
                            // Start Interaction Layer
                            if let start = validTransportPoints.first {
                                Annotation("", coordinate: start, anchor: .top) {
                                    Text(currentStartLocation)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(isStartImportantPlace ? .orange : .primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                                        .overlay(Capsule().stroke(Color.green, lineWidth: 1))
                                }
                            }
                            
                            // End Marker (Physical Look & Title)
                            if let end = validTransportPoints.last {
                                Marker(currentEndLocation, coordinate: end)
                                    .tint(.blue)
                            }
                            
                            // End Interaction Layer
                            if let end = validTransportPoints.last {
                                Annotation("", coordinate: end, anchor: .top) {
                                    Text(currentEndLocation)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(isEndImportantPlace ? .orange : .primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                                        .overlay(Capsule().stroke(Color.blue, lineWidth: 1))
                                }
                            }
                            
                            // Route
                            let smoothedPoints = validTransportPoints.smoothed()
                            
                            MapPolyline(coordinates: smoothedPoints)
                                .stroke(Color(uiColor: .systemBackground), style: StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round))
                            
                            // Route Polyline Main
                            MapPolyline(coordinates: smoothedPoints)
                                .stroke(Color.dfkAccent.opacity(0.7), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                            
                            // Photos along the route
                            ForEach(validMapPhotos, id: \.asset.localIdentifier) { entry in
                                Annotation("", coordinate: entry.coordinate) {
                                    AssetThumbnailView(assetID: entry.asset.localIdentifier, showsTime: false)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 1.5))
                                        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedPhotoAsset = IdentifiableString(value: entry.asset.localIdentifier)
                                        }
                                }
                            }
                        }
                        .mapStyle(.standard(emphasis: .muted))
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                            MapScaleView()
                        }
                    } else {
                        Color.clear
                    }
                }
            }
            .navigationTitle("交通详情")
            .navigationBarTitleDisplayMode(.inline)
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
            .safeAreaInset(edge: .bottom) {
                // Bottom Info Summary
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Start/End Locations Section
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.green)
                                
                                let matchedStart = allPlaces.first(where: { place in
                                    guard place.isUserDefined else { return false }
                                    let startAddr = currentStartLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                                    return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == startAddr || 
                                           (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == startAddr)
                                })
                                Text("起点: " + currentStartLocation)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(matchedStart != nil ? .orange : .primary)
                                    .lineLimit(1)
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.blue)
                                
                                let matchedEnd = allPlaces.first(where: { place in
                                    guard place.isUserDefined else { return false }
                                    let endAddr = currentEndLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                                    return place.name.trimmingCharacters(in: .whitespacesAndNewlines) == endAddr || 
                                           (place.address?.trimmingCharacters(in: .whitespacesAndNewlines) == endAddr)
                                })
                                Text("终点: " + currentEndLocation)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(matchedEnd != nil ? .orange : .primary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.bottom, 4)
                        
                        Divider().opacity(0.5)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(transport.startTime.formatted(.dateTime.hour().minute()) + " - " + transport.endTime.formatted(.dateTime.hour().minute()))
                                    .font(.headline)
                                
                                // 交通工具选择器
                                Menu {
                                    ForEach(TransportType.allCases, id: \.self) { type in
                                        Button {
                                            saveChoice(type)
                                        } label: {
                                            Label(type.localizedName, systemImage: type.sfSymbol)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: displayType.sfSymbol)
                                            .foregroundColor(Color.dfkAccent)
                                        Text(displayType.localizedName)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.secondary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                }
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(distanceString)
                                    .font(.headline)
                                    .foregroundColor(Color.dfkAccent)
                                Text(String(format: "平均速度 %.1f km/h", transport.averageSpeed * 3.6))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let steps = transport.stepCount, steps > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "figure.walk")
                                        Text("\(steps) 步")
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: -2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .sheet(item: $showingSearchSheet) { type in
                LocationSearchSheet(
                    locationManager: locationManager,
                    coordinate: type == .start ? transport.points.first : transport.points.last,
                    forOngoing: false
                ) { newName in
                    saveLocationOverride(type: type, name: newName)
                }
            }
            .onAppear {
                // 默认范围不要变：显式设置 camera 为交通路径的范围，避免被 allPlaces 的 MapCircle 撑开
                if let region = transport.points.boundingRegion() {
                    position = .region(region)
                }

                // 为交通路线地图获取照片，同样限制显示 10 张，避免图标堆叠
                PhotoService.shared.fetchAssets(startTime: transport.startTime, endTime: transport.endTime) { assets in
                    let filtered = assets.filter { $0.location != nil }
                    self.mapPhotos = Array(filtered.suffix(10))
                }
            }

            .sheet(item: $selectedPhotoAsset) { item in
                let assetIDs = mapPhotos.map { $0.localIdentifier }
                let index = assetIDs.firstIndex(of: item.value) ?? 0
                PhotoFullscreenView(assetIDs: assetIDs, currentIndex: index)
            }
        }
    }
    
    private func findRecord() -> TransportRecord? {
        let tid = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == tid })
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first
    }
    
    private func saveLocationOverride(type: LocationType, name: String) {
        withAnimation(.spring(response: 0.3)) {
            if type == .start {
                localStartOverride = name
            } else {
                localEndOverride = name
            }
        }
        
        if let record = findRecord() {
            if type == .start {
                record.startLocation = name
            } else {
                record.endLocation = name
            }
            
            // Preserve current type
            record.manualTypeRaw = (localManualType ?? transport.manualType ?? transport.type).rawValue
            
            try? modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
            onLocationUpdate?()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private var distanceString: String {
        if transport.distance < 1000 {
            return String(format: "%.0f 米", transport.distance)
        } else {
            return String(format: "%.1f 公里", transport.distance / 1000.0)
        }
    }
    
    private func saveChoice(_ type: TransportType) {
        // 1. Update local UI immediately
        withAnimation(.spring(response: 0.3)) {
            localManualType = type
        }
        
        // 2. Find record
        if let record = findRecord() {
            record.manualTypeRaw = type.rawValue
            
            try? modelContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
            
            // 3. Notify parent to update UI
            onUpdate?(type)
        }
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

