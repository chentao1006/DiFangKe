import SwiftUI
import CoreLocation
import MapKit
import SwiftData
import Aptabase

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
    
    @Environment(LocationManager.self) private var locationManager
    @State private var showingSearchSheet: LocationType? = nil
    @State private var localStartOverride: String? = nil
    @State private var localEndOverride: String? = nil
    @State private var interactiveMapReady = false
    @State private var showingTimeAdjustment = false
    @State private var localStartTime: Date? = nil
    @State private var localEndTime: Date? = nil
    @State private var refreshedTransport: Transport? = nil

    private var displayedTransport: Transport { refreshedTransport ?? transport }
    
    enum LocationType: Identifiable {
        case start, end
        var id: Int { self == .start ? 0 : 1 }
    }
    
    private var currentStartTime: Date { localStartTime ?? displayedTransport.startTime }
    private var currentEndTime: Date { localEndTime ?? displayedTransport.endTime }

    private static func isValidTransportPoint(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite &&
            coordinate.longitude.isFinite &&
            CLLocationCoordinate2DIsValid(coordinate)
    }

    /// First/last valid route points without filtering the whole route.
    private var validStartPoint: CLLocationCoordinate2D? {
        displayedTransport.points.first(where: { Self.isValidTransportPoint($0) })
    }

    private var validEndPoint: CLLocationCoordinate2D? {
        displayedTransport.points.last(where: { Self.isValidTransportPoint($0) })
    }

    // Use the effective type for display
    private var displayType: TransportType {
        localManualType ?? displayedTransport.currentType
    }

    /// Reconstructed sparse routes can know their endpoints and distance
    /// without knowing the real departure time. Never render the resulting
    /// physically impossible quotient as if it were a measured average.
    private var displayAverageSpeedKmh: Double? {
        let speed = Measurement(
            value: displayedTransport.averageSpeed,
            unit: UnitSpeed.metersPerSecond
        ).converted(to: .kilometersPerHour).value
        guard speed.isFinite, speed > 0 else { return nil }
        if let range = displayType.automaticSpeedRange, speed > range.upperBound {
            return nil
        }
        return speed
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
                            if let start = validStartPoint {
                                Marker("", systemImage: "play.fill", coordinate: start)
                                    .tint(.green)
                            }
                            
                            // End Marker (Physical Look & Title)
                            if let end = validEndPoint {
                                Marker("", systemImage: "stop.fill", coordinate: end)
                                    .tint(.blue)
                            }
                            
                            ForEach(displayedTransport.lineSegments) { segment in
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
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
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
                                            .foregroundStyle(Color.primary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.primary.opacity(0.5))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                }
                                .tint(.primary)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(distanceString)
                                        .foregroundColor(Color.dfkAccent)
                                    Text(durationString)
                                        .foregroundColor(.secondary)
                                }
                                .font(.headline)
                                Group {
                                    if let speed = displayAverageSpeedKmh {
                                        Text(String(format: "%.1f 千米/小时", speed))
                                    } else {
                                        Text("速度未知")
                                    }
                                }
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                
                                if let steps = displayedTransport.stepCount, steps > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "figure.walk")
                                        Text("\(steps) 步")
                                        Text("· 来自 Apple 健康")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .dfkDetailMaterial(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: -2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .sheet(item: $showingSearchSheet) { type in
                LocationSearchSheet(
                    locationManager: locationManager,
                    coordinate: type == .start ? displayedTransport.points.first : displayedTransport.points.last,
                    forOngoing: false
                ) { newName in
                    saveLocationOverride(type: type, name: newName)
                }
            }
            .sheet(isPresented: $showingTimeAdjustment) {
                TransportTimeAdjustmentView(transport: displayedTransport) { start, end in
                    localStartTime = start
                    localEndTime = end
                    reloadDisplayedTransport(for: start)
                    onLocationUpdate?()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    interactiveMapReady = true
                }
                
                // 默认范围不要变：显式设置 camera 为交通路径的范围，避免被 allPlaces 的 MapCircle 撑开
                let points = transport.points
                Task { @MainActor in
                    let region = await Task.detached(priority: .userInitiated) {
                        points.boundingRegion()
                    }.value
                    // A reload may already have framed the refreshed route.
                    guard refreshedTransport == nil, let region else { return }
                    position = .region(region)
                }

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

    private var distanceString: String {
        if displayedTransport.distance < 1000 {
            return String(format: "%.0f 米", displayedTransport.distance)
        } else {
            return String(format: "%.1f 公里", displayedTransport.distance / 1000.0)
        }
    }

    private func reloadDisplayedTransport(for date: Date) {
        let transportID = transport.id
        Task { @MainActor in
            let transports = await PersistentTimelineBuilder.fetchTimelineTransports(for: date, container: modelContext.container)
            let updated = transports.first { $0.id == transportID }
            guard let updated else { return }
            refreshedTransport = updated
            let points = updated.points
            let region = await Task.detached(priority: .userInitiated) {
                points.boundingRegion()
            }.value
            if let region {
                position = .region(region)
            }
        }
    }

    private var durationString: String {
        let minutes = max(1, Int(currentEndTime.timeIntervalSince(currentStartTime) / 60))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return hours > 0 ? "\(hours) 小时 \(remainingMinutes) 分钟" : "\(minutes) 分钟"
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

struct TransportSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transport: Transport
    var onSave: (() -> Void)? = nil

    @State private var splitTime = Date()
    @State private var routePoints: [CodableCoordinate] = []

    private let minimumDuration: TimeInterval = 60

    private var canSplit: Bool {
        transport.endTime.timeIntervalSince(transport.startTime) >= minimumDuration * 2
    }

    private var boundedSplitTime: Date {
        min(
            max(splitTime, transport.startTime.addingTimeInterval(minimumDuration)),
            transport.endTime.addingTimeInterval(-minimumDuration)
        )
    }

    private var splitTimeRange: ClosedRange<TimeInterval> {
        let lowerBound = transport.startTime.addingTimeInterval(minimumDuration).timeIntervalSince1970
        let upperBound = transport.endTime.addingTimeInterval(-minimumDuration).timeIntervalSince1970
        return lowerBound...upperBound
    }

    /// Split result for one slider value, computed off main. The body only
    /// reads this; the map redraws only when `revision` changes.
    private struct SplitPreview: @unchecked Sendable {
        let splitTime: Date
        let firstRoute: [CodableCoordinate]
        let secondRoute: [CodableCoordinate]
        /// Renderable coordinates of each half.
        let firstSegment: [CLLocationCoordinate2D]
        let secondSegment: [CLLocationCoordinate2D]
        let splitCoordinate: CLLocationCoordinate2D?
        let firstDistance: Double
        let secondDistance: Double
        let mapRect: MKMapRect?
        let revision: Int

        var hasPreviewCoordinates: Bool {
            !firstRoute.isEmpty || !secondRoute.isEmpty
        }

        static let empty = SplitPreview(
            splitTime: .distantPast, firstRoute: [], secondRoute: [], firstSegment: [], secondSegment: [],
            splitCoordinate: nil, firstDistance: 0, secondDistance: 0, mapRect: nil, revision: 0
        )
    }

    @State private var routeRevision = 0
    @State private var splitPreview = SplitPreview.empty

    private struct SplitPreviewKey: Equatable {
        let routeRevision: Int
        let splitTime: Date
    }

    nonisolated private static func splitRoutes(points: [CodableCoordinate], startTime: Date, splitTime: Date, endTime: Date) -> (first: [CodableCoordinate], second: [CodableCoordinate]) {
        TransportSplitRouteBuilder.segments(
            points: points,
            startTime: startTime,
            splitTime: splitTime,
            endTime: endTime
        )
    }

    nonisolated private static func makeSplitPreview(points: [CodableCoordinate], startTime: Date, splitTime: Date, endTime: Date, revision: Int) -> SplitPreview {
        let routes = splitRoutes(points: points, startTime: startTime, splitTime: splitTime, endTime: endTime)
        func renderable(_ route: [CodableCoordinate]) -> [CLLocationCoordinate2D] {
            route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }.filter { coordinate in
                coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
            }
        }
        let firstSegment = renderable(routes.first)
        let secondSegment = renderable(routes.second)
        let splitCoordinate = routes.first.last.flatMap { point -> CLLocationCoordinate2D? in
            let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            guard coordinate.latitude.isFinite,
                  coordinate.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return coordinate
        }
        let route = firstSegment + secondSegment
        let mapRect = route.first.map { initial in
            route.dropFirst().reduce(MKMapRect(origin: MKMapPoint(initial), size: MKMapSize(width: 1, height: 1))) { rect, coordinate in
                rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1)))
            }
        }
        return SplitPreview(
            splitTime: splitTime,
            firstRoute: routes.first,
            secondRoute: routes.second,
            firstSegment: firstSegment,
            secondSegment: secondSegment,
            splitCoordinate: splitCoordinate,
            firstDistance: TimelineBuilder.calculatePathDistance(routes.first),
            secondDistance: TimelineBuilder.calculatePathDistance(routes.second),
            mapRect: mapRect,
            revision: revision
        )
    }

    private func refreshSplitPreview() async {
        let points = routePoints
        let startTime = transport.startTime
        let endTime = transport.endTime
        let split = boundedSplitTime
        let revision = splitPreview.revision &+ 1
        let preview = await Task.detached(priority: .userInitiated) {
            Self.makeSplitPreview(points: points, startTime: startTime, splitTime: split, endTime: endTime, revision: revision)
        }.value
        guard !Task.isCancelled else { return }
        splitPreview = preview
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    GeometryReader { proxy in
                        if proxy.size.width > 1 && proxy.size.height > 1 && splitPreview.hasPreviewCoordinates {
                            TransportSplitMapView(
                                firstSegment: splitPreview.firstSegment,
                                secondSegment: splitPreview.secondSegment,
                                splitCoordinate: splitPreview.splitCoordinate,
                                mapRect: splitPreview.mapRect,
                                renderRevision: splitPreview.revision
                            )
                        } else {
                            Color.secondary.opacity(0.05)
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("拆分时间")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(timeText(boundedSplitTime))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                        }

                        if canSplit {
                            Slider(
                                value: Binding(
                                    get: { splitTime.timeIntervalSince1970 },
                                    set: { splitTime = Date(timeIntervalSince1970: $0) }
                                ),
                                in: splitTimeRange,
                                step: 60
                            )
                            .tint(.dfkAccent)
                        } else {
                            Text("交通时长不足 2 分钟，无法拆分")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(timeText(transport.startTime))
                            Spacer()
                            Text(timeText(transport.endTime))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.05)))

                    HStack(spacing: 12) {
                        SplitPreviewTransportCard(title: "前半段", start: transport.startTime, end: boundedSplitTime, distance: splitPreview.firstDistance, color: .green)
                        SplitPreviewTransportCard(title: "后半段", start: boundedSplitTime, end: transport.endTime, distance: splitPreview.secondDistance, color: .blue)
                    }
                }
                .padding(20)
            }
            .navigationTitle("拆分交通")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveSplit() } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon().fontWeight(.bold)
                    }
                    .disabled(!canSplit)
                }
            }
        }
        .onAppear {
            splitTime = roundedToMinute(
                transport.startTime.addingTimeInterval(
                    transport.endTime.timeIntervalSince(transport.startTime) / 2
                )
            )
            loadRoute()
        }
        .task(id: SplitPreviewKey(routeRevision: routeRevision, splitTime: boundedSplitTime)) {
            await refreshSplitPreview()
        }
    }

    private func loadRoute() {
        let fallback = [
            CodableCoordinate(lat: transport.points.first?.latitude ?? 0, lon: transport.points.first?.longitude ?? 0, timestamp: transport.startTime),
            CodableCoordinate(lat: transport.points.last?.latitude ?? 0, lon: transport.points.last?.longitude ?? 0, timestamp: transport.endTime)
        ]
        guard let pointsData = findRecord()?.pointsData else {
            routePoints = fallback
            routeRevision &+= 1
            return
        }
        Task { @MainActor in
            let decoded = await Task.detached(priority: .userInitiated) {
                try? JSONDecoder().decode([CodableCoordinate].self, from: pointsData)
            }.value
            routePoints = decoded ?? fallback
            routeRevision &+= 1
        }
    }

    private func saveSplit() {
        guard canSplit, findRecord() != nil else { return }
        // Persist exactly the same cut shown in the preview. Re-running route
        // interpolation here used to move the endpoints at save time.
        let split = boundedSplitTime
        let points = routePoints
        let startTime = transport.startTime
        let endTime = transport.endTime
        Task { @MainActor in
            let prepared = await Task.detached(priority: .userInitiated) {
                let routes = Self.splitRoutes(points: points, startTime: startTime, splitTime: split, endTime: endTime)
                return SplitSaveRoutes(
                    firstPoints: routes.first,
                    secondPoints: routes.second,
                    firstData: try? JSONEncoder().encode(routes.first),
                    secondData: try? JSONEncoder().encode(routes.second),
                    firstDistance: TimelineBuilder.calculatePathDistance(routes.first),
                    secondDistance: TimelineBuilder.calculatePathDistance(routes.second)
                )
            }.value
            guard let record = findRecord() else { return }
            applySplit(record: record, split: split, routes: prepared)
        }
    }

    private struct SplitSaveRoutes: @unchecked Sendable {
        let firstPoints: [CodableCoordinate]
        let secondPoints: [CodableCoordinate]
        let firstData: Data?
        let secondData: Data?
        let firstDistance: Double
        let secondDistance: Double
    }

    private func applySplit(record: TransportRecord, split: Date, routes: SplitSaveRoutes) {
        let oldEnd = record.endTime
        let oldEndLocation = record.endLocation
        let ratio = split.timeIntervalSince(record.startTime) / max(1, record.endTime.timeIntervalSince(record.startTime))
        let firstPoints = routes.firstPoints
        let secondPoints = routes.secondPoints
        let explicitlySelectedType = record.manualTypeRaw

        record.endTime = split
        record.day = Calendar.current.startOfDay(for: record.startTime)
        record.endLocation = "中途"
        record.pointsData = routes.firstData ?? record.pointsData
        record.distance = routes.firstDistance
        record.averageSpeed = record.distance / max(1, record.endTime.timeIntervalSince(record.startTime))
        record.stepCount = splitMetric(record.stepCount, ratio: ratio, second: false)
        record.typeRaw = explicitlySelectedType ?? inferredSplitType(for: record, points: firstPoints)
        record.manualTypeRaw = record.typeRaw // Keep the user-created split boundary stable during rebuilding.

        let newRecord = TransportRecord(
            day: Calendar.current.startOfDay(for: split),
            startTime: split,
            endTime: oldEnd,
            startLocation: "中途",
            endLocation: oldEndLocation,
            typeRaw: record.typeRaw,
            distance: routes.secondDistance,
            averageSpeed: 0,
            pointsData: routes.secondData ?? Data(),
            stepCount: splitMetric(transport.stepCount, ratio: ratio, second: true)
        )
        newRecord.averageSpeed = newRecord.distance / max(1, oldEnd.timeIntervalSince(split))
        newRecord.typeRaw = explicitlySelectedType ?? inferredSplitType(for: newRecord, points: secondPoints)
        newRecord.manualTypeRaw = newRecord.typeRaw
        modelContext.insert(newRecord)
        try? modelContext.save()
        TimelineBuilder.timelineCache.removeValue(forKey: Calendar.current.startOfDay(for: transport.startTime))
        NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
        CloudSettingsManager.shared.triggerDataSyncPulse()
        Aptabase.shared.trackEvent("transport_split")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSave?()
        dismiss()
    }

    private func inferredSplitType(for record: TransportRecord, points: [CodableCoordinate]) -> String {
        let observedCount = points.filter { $0.isSyntheticPadding != true && $0.timestamp != nil }.count
        return TransportType.from(
            speed: record.averageSpeed,
            stepCount: record.stepCount ?? 0,
            duration: record.endTime.timeIntervalSince(record.startTime),
            distanceMeters: record.distance,
            pointCount: points.count,
            observedPointCount: observedCount
        ).rawValue
    }

    private func findRecord() -> TransportRecord? {
        let id = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func splitMetric(_ value: Int?, ratio: Double, second: Bool) -> Int? {
        guard let value else { return nil }
        let first = Int((Double(value) * ratio).rounded())
        return second ? max(0, value - first) : first
    }

    private func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct SplitPreviewTransportCard: View {
    let title: String
    let start: Date
    let end: Date
    let distance: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
            Text(distance >= 1000 ? String(format: "%.1f 公里", distance / 1000) : String(format: "%.0f 米", distance))
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35), lineWidth: 1))
    }
}

private struct TransportSplitMapView: UIViewRepresentable {
    /// Already filtered to renderable coordinates.
    let firstSegment: [CLLocationCoordinate2D]
    let secondSegment: [CLLocationCoordinate2D]
    let splitCoordinate: CLLocationCoordinate2D?
    let mapRect: MKMapRect?
    /// Changes whenever the preview geometry changes.
    let renderRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard renderRevision != context.coordinator.renderRevision else { return }
        context.coordinator.renderRevision = renderRevision
        let first = firstSegment
        let second = secondSegment
        let marker = splitCoordinate

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        if first.count >= 2 {
            let overlay = MKPolyline(coordinates: first, count: first.count)
            overlay.title = "first"
            mapView.addOverlay(overlay)
        }
        if second.count >= 2 {
            let overlay = MKPolyline(coordinates: second, count: second.count)
            overlay.title = "second"
            mapView.addOverlay(overlay)
        }
        if let marker {
            let annotation = MKPointAnnotation()
            annotation.coordinate = marker
            annotation.title = "拆分点"
            mapView.addAnnotation(annotation)
        }

        guard let rect = mapRect else { return }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 34, left: 34, bottom: 34, right: 34), animated: context.coordinator.hasRendered)
        context.coordinator.hasRendered = true
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderRevision = -1
        var hasRendered = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = line.title == "first" ? .systemGreen : .systemBlue
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "transport-split-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "scissors")
            view.displayPriority = .required
            return view
        }
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
    @State private var rawPointIndex = RawPointTimeIndex.empty
    @State private var isLoadingRawPoints = true
    @State private var hasInitializedRange = false
    @State private var isRegenerating = false

    private let minimumDuration: TimeInterval = 60

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Raw points indexed off main when loaded. Drag updates then select the
    /// draft range by binary search over sorted timestamps instead of
    /// filtering every point on each slider change.
    private struct RawPointTimeIndex: Sendable {
        /// Chronological timestamps of all raw points.
        let timestamps: [Date]
        /// Renderable coordinates, in the same order as their points.
        let validCoordinates: [CLLocationCoordinate2D]
        /// `validPrefixCounts[i]` = renderable points among the first `i`.
        let validPrefixCounts: [Int]

        static let empty = RawPointTimeIndex(timestamps: [], validCoordinates: [], validPrefixCounts: [0])

        init(timestamps: [Date], validCoordinates: [CLLocationCoordinate2D], validPrefixCounts: [Int]) {
            self.timestamps = timestamps
            self.validCoordinates = validCoordinates
            self.validPrefixCounts = validPrefixCounts
        }

        init(points: [CLLocation]) {
            var timestamps: [Date] = []
            var validCoordinates: [CLLocationCoordinate2D] = []
            var validPrefixCounts: [Int] = [0]
            timestamps.reserveCapacity(points.count)
            validPrefixCounts.reserveCapacity(points.count + 1)
            for point in points {
                timestamps.append(point.timestamp)
                let coordinate = point.coordinate
                if coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate) {
                    validCoordinates.append(coordinate)
                }
                validPrefixCounts.append(validCoordinates.count)
            }
            self.init(timestamps: timestamps, validCoordinates: validCoordinates, validPrefixCounts: validPrefixCounts)
        }

        /// Indices of points with `start <= timestamp <= end`.
        func range(from start: Date, to end: Date) -> Range<Int> {
            var low = 0
            var high = timestamps.count
            while low < high {
                let mid = (low + high) / 2
                if timestamps[mid] < start { low = mid + 1 } else { high = mid }
            }
            let lower = low
            high = timestamps.count
            while low < high {
                let mid = (low + high) / 2
                if timestamps[mid] <= end { low = mid + 1 } else { high = mid }
            }
            return lower..<max(lower, low)
        }
    }

    private var selectedRange: Range<Int> {
        rawPointIndex.range(from: draftStart, to: draftEnd)
    }

    private var selectedPointCount: Int {
        selectedRange.count
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        let range = selectedRange
        let lower = rawPointIndex.validPrefixCounts[range.lowerBound]
        let upper = rawPointIndex.validPrefixCounts[range.upperBound]
        return Array(rawPointIndex.validCoordinates[lower..<upper])
    }

    private var canSave: Bool {
        hasInitializedRange && !isLoadingRawPoints && !isRegenerating &&
            draftEnd.timeIntervalSince(draftStart) >= minimumDuration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    GeometryReader { proxy in
                        let coordinates = selectedCoordinates
                        if proxy.size.width > 1 && proxy.size.height > 1 && !coordinates.isEmpty {
                            FootprintTimeAdjustmentMapView(coordinates: coordinates, dotDiameter: 14)
                                .frame(minWidth: 1, minHeight: 1)
                        } else {
                            Color.secondary.opacity(0.05)
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .bottomLeading) {
                        Text(isLoadingRawPoints ? "加载轨迹点..." : "\(selectedPointCount) 个原始点")
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
                    .disabled(isRegenerating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAdjustment() } label: {
                        if isRegenerating {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark").dfkToolbarConfirmIcon().fontWeight(.bold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            setupInitialRange()
            loadRawPoints()
        }
        .interactiveDismissDisabled(isRegenerating)
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
                let chronological = dates.flatMap {
                    RawLocationStore.shared.loadAllDevicesLocations(for: $0, filtered: false)
                }.sorted { $0.timestamp < $1.timestamp }
                return RawPointTimeIndex(points: RawLocationStore.filterRidiculousSpikes(chronological))
            }.value
            await MainActor.run {
                rawPointIndex = points
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
        guard !isLoadingRawPoints else { return }
        let oldStart = record.startTime
        let oldEnd = record.endTime
        record.updateTimeRangePreservingRoute(start: start, end: end)
        // Time boundaries are user-authored facts too.  Mark this record as
        // manual so periodic automatic consolidation cannot replace the
        // adjusted interval with a newly inferred one.
        record.manualTypeRaw = record.manualTypeRaw ?? transport.manualType?.rawValue ?? transport.type.rawValue
        let adjacentDates = adjustAdjacentItems(
            oldStart: oldStart,
            oldEnd: oldEnd,
            newStart: start,
            newEnd: end,
            didChangeStart: minuteKey(oldStart) != minuteKey(start),
            didChangeEnd: minuteKey(oldEnd) != minuteKey(end)
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            isRegenerating = false
            return
        }
        isRegenerating = true
        let affectedDates = touchedDates(start: oldStart, end: oldEnd)
            .union(touchedDates(start: start, end: end))
            .union(adjacentDates)
        invalidateCaches(oldStart: oldStart, oldEnd: oldEnd, newStart: start, newEnd: end, additionalDates: adjacentDates)
        Task { @MainActor in
            // Re-run one non-destructive reconstruction pass after the edited
            // boundaries and route have been committed. A full reset would
            // delete this manual edit and other user-authored records.
            for date in affectedDates.sorted() {
                var didSync = await PersistentTimelineBuilder.syncDay(
                    date: date, in: modelContext, runConsolidation: false
                )
                var retriesRemaining = 20
                while !didSync && retriesRemaining > 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    didSync = await PersistentTimelineBuilder.syncDay(
                        date: date, in: modelContext, runConsolidation: false
                    )
                    retriesRemaining -= 1
                }
                TimelineBuilder.timelineCache.removeValue(forKey: date)
            }
            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
            onSave(start, end)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isRegenerating = false
            dismiss()
        }
    }

    private func findRecord() -> TransportRecord? {
        let id = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == id })
        return try? modelContext.fetch(descriptor).first
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
            record.updateTimeRangePreservingRoute(start: record.startTime, end: end)
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
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
            record.updateTimeRangePreservingRoute(start: start, end: record.endTime)
            record.manualTypeRaw = record.manualTypeRaw ?? record.typeRaw
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
        Self.timeFormatter.string(from: date)
    }
}
