import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import Photos
import Aptabase

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
    @State private var mapPhotoImages: [String: UIImage] = [:]
    @State private var selectedPhotoAsset: IdentifiableString?
    @State private var interactiveMapReady = false
    @State private var showingTimeAdjustment = false
    @State private var localStartTime: Date? = nil
    @State private var localEndTime: Date? = nil
    
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

    private var currentStartTime: Date { localStartTime ?? transport.startTime }
    private var currentEndTime: Date { localEndTime ?? transport.endTime }

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

    private var mapPhotoAssetCacheKey: String {
        validMapPhotos.map { $0.asset.localIdentifier }.sorted().joined(separator: "|")
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
                    if geometry.size.width > 1 && geometry.size.height > 1 && interactiveMapReady {
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
                                    .foregroundStyle(Color(uiColor: UIColor.orange.withAlphaComponent(0.1)))
                                    .stroke(Color(uiColor: UIColor.orange.withAlphaComponent(0.3)), lineWidth: 1)
                            }

                            // Start Marker (Physical Look & Title)
                            if let start = validTransportPoints.first {
                                Marker("", coordinate: start)
                                    .tint(.green)
                            }
                            
                            // End Marker (Physical Look & Title)
                            if let end = validTransportPoints.last {
                                Marker("", coordinate: end)
                                    .tint(.blue)
                            }
                            
                            ForEach(transport.lineSegments) { segment in
                                MapPolyline(coordinates: segment.coordinates)
                                    .stroke(
                                        Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.7),
                                        style: StrokeStyle(
                                            lineWidth: segment.isDashed ? 1.5 : 3,
                                            lineCap: .round,
                                            lineJoin: .round,
                                            dash: segment.isDashed ? [5, 5] : []
                                        )
                                    )
                            }
                            
                            // Photos along the route
                            ForEach(validMapPhotos, id: \.asset.localIdentifier) { entry in
                                Annotation("", coordinate: entry.coordinate) {
                                    ZStack {
                                        Color(uiColor: .systemGray6)
                                        if let image = mapPhotoImages[entry.asset.localIdentifier] {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Image(systemName: "photo")
                                                .font(.caption)
                                                .foregroundColor(Color(uiColor: .systemGray))
                                        }
                                    }
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
                        .mapStyle(.standard(elevation: .automatic, emphasis: .muted, pointsOfInterest: .excludingAll))
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
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Bottom Info Summary
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    showingTimeAdjustment = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(currentStartTime.formatted(.dateTime.hour().minute()) + " - " + currentEndTime.formatted(.dateTime.hour().minute()))
                                            .font(.headline)
                                        Image(systemName: "pencil")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.42))
                                    }
                                }
                                .buttonStyle(.plain)
                                
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
                                Text(String(format: "平均速度 %.1f 千米/小时", transport.averageSpeed * 3.6))
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
            .sheet(isPresented: $showingTimeAdjustment) {
                TransportTimeAdjustmentView(transport: transport) { start, end in
                    localStartTime = start
                    localEndTime = end
                    onLocationUpdate?()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    interactiveMapReady = true
                }
                
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
            .task(id: mapPhotoAssetCacheKey) {
                await loadMapPhotoImages()
            }

            .fullScreenCover(item: $selectedPhotoAsset) { item in
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
        Aptabase.shared.trackEvent("transport_edited")
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

    @MainActor
    private func loadMapPhotoImages() async {
        let assetIDs = validMapPhotos.map { $0.asset.localIdentifier }
        guard !assetIDs.isEmpty else {
            mapPhotoImages = [:]
            return
        }

        let neededIDs = assetIDs.filter { mapPhotoImages[$0] == nil }
        if !neededIDs.isEmpty {
            var loadedImages: [String: UIImage] = [:]
            for assetID in neededIDs {
                if Task.isCancelled { return }
                if let image = await loadMapAssetImage(assetID: assetID, targetSize: CGSize(width: 112, height: 112)) {
                    loadedImages[assetID] = image
                }
            }
            if !loadedImages.isEmpty {
                mapPhotoImages.merge(loadedImages, uniquingKeysWith: { _, latest in latest })
            }
        }

        let visibleIDs = Set(assetIDs)
        mapPhotoImages = mapPhotoImages.filter { visibleIDs.contains($0.key) }
    }

    private func loadMapAssetImage(assetID: String, targetSize: CGSize) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            func resumeOnce(with image: UIImage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                resumeOnce(with: image)
            }
        }
    }
    
    private var distanceString: String {
        if transport.distance < 1000 {
            return String(format: "%.0f 米", transport.distance)
        } else {
            return String(format: "%.1f 公里", transport.distance / 1000.0)
        }
    }
    
    private func saveChoice(_ type: TransportType) {
        Aptabase.shared.trackEvent("transport_edited")
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

private struct TransportTimeAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transport: Transport
    let onSave: (Date, Date) -> Void

    @State private var rangeStart = Date()
    @State private var rangeEnd = Date()
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @State private var rawPoints: [CLLocation] = []
    @State private var isLoadingRawPoints = true
    @State private var hasInitializedRange = false

    private let minimumDuration: TimeInterval = 60

    private var selectedPoints: [CLLocation] {
        rawPoints.filter { $0.timestamp >= draftStart && $0.timestamp <= draftEnd }
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        selectedPoints.map(\.coordinate).filter {
            $0.latitude.isFinite && $0.longitude.isFinite && CLLocationCoordinate2DIsValid($0)
        }
    }

    private var canSave: Bool {
        hasInitializedRange && draftEnd.timeIntervalSince(draftStart) >= minimumDuration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    GeometryReader { proxy in
                        if proxy.size.width > 1 && proxy.size.height > 1 && !selectedCoordinates.isEmpty {
                            FootprintTimeAdjustmentMapView(coordinates: selectedCoordinates)
                                .frame(minWidth: 1, minHeight: 1)
                        } else {
                            Color.secondary.opacity(0.05)
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
                            Text("\(timeText(hasInitializedRange ? draftStart : transport.startTime))-\(timeText(hasInitializedRange ? draftEnd : transport.endTime))")
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
                            Color.clear.frame(height: 34)
                        }

                        HStack {
                            Text(timeText(hasInitializedRange ? rangeStart : transport.startTime))
                            Spacer()
                            Text(timeText(hasInitializedRange ? rangeEnd : transport.endTime))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))
                }
                .padding(20)
            }
            .navigationTitle("调整时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAdjustment() } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon().fontWeight(.bold)
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
        let dayStart = calendar.startOfDay(for: transport.startTime)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        let latestAllowedTime = min(dayEnd, currentMinute())
        rangeStart = editableRangeStart(dayStart: dayStart)
        rangeEnd = min(editableRangeEnd(dayEnd: dayEnd), latestAllowedTime)
        if rangeEnd.timeIntervalSince(rangeStart) < minimumDuration {
            rangeStart = dayStart
            rangeEnd = latestAllowedTime
        }
        draftStart = min(max(transport.startTime, rangeStart), rangeEnd.addingTimeInterval(-minimumDuration))
        draftEnd = max(min(transport.endTime, rangeEnd), draftStart.addingTimeInterval(minimumDuration))
        hasInitializedRange = true
    }

    private func currentMinute() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    }

    /// A connected neighbor can donate up to the alignment threshold to this
    /// transport, while retaining its own minimum valid duration.  This lets a
    /// user correct a slightly too-short inferred trip instead of only shrinking it.
    private func editableRangeStart(dayStart: Date) -> Date {
        let threshold = AppConfig.shared.transportAlignmentThreshold
        guard let previous = nearestPreviousItem(near: transport.startTime, threshold: threshold) else {
            return max(previousItemEnd(defaultingTo: dayStart), dayStart)
        }
        let earliestByNeighbor = previous.startTime.addingTimeInterval(minimumDuration(for: previous))
        let earliestByThreshold = transport.startTime.addingTimeInterval(-threshold)
        return max(dayStart, max(earliestByNeighbor, earliestByThreshold))
    }

    private func editableRangeEnd(dayEnd: Date) -> Date {
        let threshold = AppConfig.shared.transportAlignmentThreshold
        guard let next = nearestNextItem(near: transport.endTime, threshold: threshold) else {
            return min(nextItemStart(defaultingTo: dayEnd), dayEnd)
        }
        let latestByNeighbor = next.endTime.addingTimeInterval(-minimumDuration(for: next))
        let latestByThreshold = transport.endTime.addingTimeInterval(threshold)
        return min(dayEnd, min(latestByNeighbor, latestByThreshold))
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

    private func previousItemEnd(defaultingTo fallback: Date) -> Date {
        let id = transport.id
        let transportStart = transport.startTime
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.endTime <= transportStart && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.endTime <= transportStart && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        return [
            (try? modelContext.fetch(transportDescriptor).first?.endTime),
            (try? modelContext.fetch(footprintDescriptor).first?.endTime),
            fallback
        ].compactMap { $0 }.max() ?? fallback
    }

    private func nextItemStart(defaultingTo fallback: Date) -> Date {
        let id = transport.id
        let transportEnd = transport.endTime
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.startTime >= transportEnd && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= transportEnd && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        return [
            (try? modelContext.fetch(transportDescriptor).first?.startTime),
            (try? modelContext.fetch(footprintDescriptor).first?.startTime),
            fallback
        ].compactMap { $0 }.min() ?? fallback
    }

    private func saveAdjustment() {
        guard let record = findRecord() else { dismiss(); return }
        let start = roundedToMinute(draftStart)
        let end = roundedToMinute(max(draftEnd, start.addingTimeInterval(minimumDuration)))
        guard minuteKey(record.startTime) != minuteKey(start) || minuteKey(record.endTime) != minuteKey(end) else {
            dismiss()
            return
        }
        let oldStart = record.startTime
        let oldEnd = record.endTime
        record.startTime = start
        record.endTime = end
        record.day = Calendar.current.startOfDay(for: start)
        // Time boundaries are user-authored facts too.  Mark this record as
        // manual so periodic automatic consolidation cannot replace the
        // adjusted interval with a newly inferred one.
        record.manualTypeRaw = record.manualTypeRaw ?? transport.manualType?.rawValue ?? transport.type.rawValue
        refreshMetrics(record)
        let adjacentDates = adjustAdjacentItems(
            oldStart: oldStart,
            oldEnd: oldEnd,
            newStart: start,
            newEnd: end,
            didChangeStart: minuteKey(oldStart) != minuteKey(start),
            didChangeEnd: minuteKey(oldEnd) != minuteKey(end)
        )
        try? modelContext.save()
        invalidateCaches(oldStart: oldStart, oldEnd: oldEnd, newStart: start, newEnd: end, additionalDates: adjacentDates)
        onSave(start, end)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func findRecord() -> TransportRecord? {
        let id = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func refreshMetrics(_ record: TransportRecord) {
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
        record.averageSpeed = record.distance / record.endTime.timeIntervalSince(record.startTime)
    }

    /// Keep a connected timeline connected when the edited transport originally
    /// touched its neighboring item (within the configured 20-minute threshold).
    /// Items separated by a larger gap are intentionally left untouched.
    private func adjustAdjacentItems(
        oldStart: Date,
        oldEnd: Date,
        newStart: Date,
        newEnd: Date,
        didChangeStart: Bool,
        didChangeEnd: Bool
    ) -> Set<Date> {
        var affectedDates: Set<Date> = []
        let threshold = AppConfig.shared.transportAlignmentThreshold

        if didChangeStart, let previous = nearestPreviousItem(near: oldStart, threshold: threshold) {
            affectedDates.formUnion(updateEnd(of: previous, to: newStart))
        }
        if didChangeEnd, let next = nearestNextItem(near: oldEnd, threshold: threshold) {
            affectedDates.formUnion(updateStart(of: next, to: newEnd))
        }
        return affectedDates
    }

    private enum AdjacentItem {
        case footprint(Footprint)
        case transport(TransportRecord)

        var startTime: Date {
            switch self {
            case .footprint(let record): record.startTime
            case .transport(let record): record.startTime
            }
        }

        var endTime: Date {
            switch self {
            case .footprint(let record): record.endTime
            case .transport(let record): record.endTime
            }
        }
    }

    private func nearestPreviousItem(near date: Date, threshold: TimeInterval) -> AdjacentItem? {
        let id = transport.id
        let lower = date.addingTimeInterval(-threshold)
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.endTime >= lower && $0.endTime <= date && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.endTime >= lower && $0.endTime <= date && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        let candidates = [
            (try? modelContext.fetch(transportDescriptor).first).map(AdjacentItem.transport),
            (try? modelContext.fetch(footprintDescriptor).first).map(AdjacentItem.footprint)
        ].compactMap { $0 }
        return candidates.max { $0.endTime < $1.endTime }
    }

    private func nearestNextItem(near date: Date, threshold: TimeInterval) -> AdjacentItem? {
        let id = transport.id
        let upper = date.addingTimeInterval(threshold)
        let transportDescriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID != id && $0.startTime >= date && $0.startTime <= upper && $0.statusRaw != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let footprintDescriptor = FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.startTime >= date && $0.startTime <= upper && $0.statusValue != "ignored" },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let candidates = [
            (try? modelContext.fetch(transportDescriptor).first).map(AdjacentItem.transport),
            (try? modelContext.fetch(footprintDescriptor).first).map(AdjacentItem.footprint)
        ].compactMap { $0 }
        return candidates.min { $0.startTime < $1.startTime }
    }

    private func updateEnd(of item: AdjacentItem, to end: Date) -> Set<Date> {
        guard end > item.startTime.addingTimeInterval(minimumDuration(for: item)) else { return [] }
        let oldEnd = item.endTime
        switch item {
        case .footprint(let record):
            record.endTime = end
            record.status = .manual
        case .transport(let record):
            record.endTime = end
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
            refreshMetrics(record)
        }
        return touchedDates(start: min(oldEnd, end), end: max(oldEnd, end))
    }

    private func updateStart(of item: AdjacentItem, to start: Date) -> Set<Date> {
        guard item.endTime > start.addingTimeInterval(minimumDuration(for: item)) else { return [] }
        let oldStart = item.startTime
        switch item {
        case .footprint(let record):
            record.startTime = start
            record.date = Calendar.current.startOfDay(for: start)
            record.status = .manual
        case .transport(let record):
            record.startTime = start
            record.day = Calendar.current.startOfDay(for: start)
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
            refreshMetrics(record)
        }
        return touchedDates(start: min(oldStart, start), end: max(oldStart, start))
    }

    private func minimumDuration(for item: AdjacentItem) -> TimeInterval {
        switch item {
        case .footprint:
            max(60, ceil(AppConfig.shared.stayDurationThreshold / 60) * 60)
        case .transport:
            minimumDuration
        }
    }

    private func invalidateCaches(oldStart: Date, oldEnd: Date, newStart: Date, newEnd: Date, additionalDates: Set<Date>) {
        for date in touchedDates(start: oldStart, end: oldEnd)
            .union(touchedDates(start: newStart, end: newEnd))
            .union(additionalDates) {
            TimelineBuilder.timelineCache.removeValue(forKey: date)
        }
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil, userInfo: ["date": Calendar.current.startOfDay(for: newStart)])
    }

    private func touchedDates(start: Date, end: Date) -> Set<Date> {
        let calendar = Calendar.current
        var dates: Set<Date> = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end.addingTimeInterval(-0.001)))
        while cursor <= last {
            dates.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
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
