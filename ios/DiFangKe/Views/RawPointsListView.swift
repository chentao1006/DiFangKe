import SwiftUI
import CoreLocation
import MapKit

struct RawPointsListView: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager

    @State private var entries: [RawPointEntry] = []
    @State private var previousDistances: [Int: CLLocationDistance] = [:]
    @State private var suspiciousIndices: Set<Int> = []
    @State private var mapCoordinates: [CLLocationCoordinate2D] = []
    @State private var mapDriftCoordinates: [CLLocationCoordinate2D] = []
    @State private var isLoading = true
    @State private var isShowingDeleteConfirmation = false
    @State private var pointToDelete: CLLocation?
    @State private var showOnlySuspicious = false
    @State private var mapSelection = RawPointsMapSelection()
    @State private var selectedIndex: Int?
    @State private var scrollTargetIndex: Int?
    @State private var positionResetTrigger = 0
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?

    private var driftCount: Int {
        entries.filter { $0.isDriftPoint }.count
    }

    private var filteredEntries: [RawPointEntry] {
        if !showOnlySuspicious {
            return entries
        }
        return entries.filter { $0.isDriftPoint || suspiciousIndices.contains($0.originalIndex) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载原始轨迹...")
                } else if entries.isEmpty {
                    ContentUnavailableView("暂无轨迹点", systemImage: "mappin.slash", description: Text("该日期没有任何原始位置记录"))
                } else {
                    VStack(spacing: 0) {
                        RawPointsMapView(
                            coordinates: mapCoordinates,
                            driftCoordinates: mapDriftCoordinates,
                            selection: mapSelection,
                            recenterTrigger: positionResetTrigger,
                            onSelectCoordinate: selectNearestPoint(to:)
                        )
                        .frame(height: 220)
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                positionResetTrigger += 1
                            } label: {
                                Image(systemName: "scope")
                                    .padding(8)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                    .padding(10)
                            }
                        }

                        ScrollViewReader { scrollProxy in
                            List {
                                Section {
                                    HStack {
                                        if showOnlySuspicious {
                                            Text("发现 \(filteredEntries.count) 个疑似问题点")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        } else {
                                            Text("共 \(entries.count) 个记录点")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        if driftCount > 0 {
                                            Spacer()
                                            HStack(spacing: 3) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 9))
                                                Text("\(driftCount) 个漂移点")
                                                    .font(.caption2)
                                            }
                                            .foregroundColor(.gray)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.gray.opacity(0.12))
                                            .cornerRadius(4)
                                        }
                                    }
                                }

                                ForEach(filteredEntries, id: \.originalIndex) { entry in
                                    RawPointRow(
                                        entry: entry,
                                        previousDistance: previousDistances[entry.originalIndex],
                                        isSelected: selectedIndex == entry.originalIndex
                                    )
                                    .equatable()
                                        .id(entry.originalIndex)
                                        .listRowBackground(selectedIndex == entry.originalIndex ? Color.dfkAccent.opacity(0.1) : nil)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectPoint(entry.location, index: entry.originalIndex)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                pointToDelete = entry.location
                                                deletePoint(entry.location)
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                            .listStyle(.insetGrouped)
                            .onChange(of: scrollTargetIndex) { _, newValue in
                                if let newValue {
                                    scrollProxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                            .onChange(of: showOnlySuspicious) { _, _ in
                                if let selectedIndex = scrollTargetIndex {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        if filteredEntries.contains(where: { $0.originalIndex == selectedIndex }) {
                                            scrollProxy.scrollTo(selectedIndex, anchor: .center)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(date.formatted(.dateTime.month().day())) 原始轨迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            showOnlySuspicious.toggle()
                        }
                    } label: {
                        Label("过滤问题点", systemImage: showOnlySuspicious ? "line.3.horizontal.decrease.fill" : "line.3.horizontal.decrease")
                            .foregroundColor(showOnlySuspicious ? .orange : .accentColor)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        exportRawPoints()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出当天轨迹点")
                    .disabled(entries.isEmpty)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let exportURL {
                    ActivityView(activityItems: [exportURL])
                }
            }
            .alert("导出失败", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .onAppear {
                loadPoints()
            }
        }
    }

    private func selectPoint(_ point: CLLocation, index: Int) {
        selectedIndex = index
        DispatchQueue.main.async {
            mapSelection.select(point.coordinate, shouldCenter: true)
        }
    }

    private func selectNearestPoint(to coordinate: CLLocationCoordinate2D) {
        let tapLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // 只在当前可见（过滤后）的点中查找最近点
        var closestEntry: RawPointEntry?
        var minDistance: CLLocationDistance = Double.infinity

        for entry in filteredEntries {
            let dist = entry.location.distance(from: tapLocation)
            if dist < minDistance {
                minDistance = dist
                closestEntry = entry
            }
        }

        // 允许较大的点击误差，特别是在缩放级别较高时 (1000m)
        if let closest = closestEntry, minDistance < 1000 {
            selectedIndex = closest.originalIndex
            scrollTargetIndex = closest.originalIndex
            DispatchQueue.main.async {
                mapSelection.select(closest.location.coordinate, shouldCenter: true)
            }
        }
    }

    private func loadPoints() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let rawEntries = RawLocationStore.shared.loadAllDevicesLocationsWithDriftFlags(for: date)
            let loadResult = RawPointsLoadResult(entries: rawEntries)
            await MainActor.run {
                self.entries = loadResult.entries
                self.previousDistances = loadResult.previousDistances
                self.suspiciousIndices = loadResult.suspiciousIndices
                self.mapCoordinates = loadResult.mapCoordinates
                self.mapDriftCoordinates = loadResult.mapDriftCoordinates
                self.isLoading = false
            }
        }
    }

    private func deletePoint(_ point: CLLocation) {
        RawLocationStore.shared.deleteLocation(at: point.timestamp.timeIntervalSince1970, for: date)
        if let idx = entries.firstIndex(where: { $0.location.timestamp == point.timestamp }) {
            withAnimation(.spring()) {
                _ = entries.remove(at: idx)
            }
            let loadResult = RawPointsLoadResult(entries: entries)
            previousDistances = loadResult.previousDistances
            suspiciousIndices = loadResult.suspiciousIndices
            mapCoordinates = loadResult.mapCoordinates
            mapDriftCoordinates = loadResult.mapDriftCoordinates
        }
    }

    private func exportRawPoints() {
        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "DiFangKe_RawPoints_\(formatter.string(from: date)).csv"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try rawPointsCSVData().write(to: tempURL, options: .atomic)
            exportURL = tempURL
            showingShareSheet = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func rawPointsCSVData() throws -> Data {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let numberLocale = Locale(identifier: "en_US_POSIX")

        var rows = ["timestamp_iso,timestamp_unix,latitude,longitude,accuracy,speed,is_drift"]
        rows += entries.map { entry in
            let point = entry.location
            let timestamp = point.timestamp.timeIntervalSince1970
            return [
                isoFormatter.string(from: point.timestamp),
                String(format: "%.3f", locale: numberLocale, timestamp),
                String(format: "%.8f", locale: numberLocale, point.coordinate.latitude),
                String(format: "%.8f", locale: numberLocale, point.coordinate.longitude),
                String(format: "%.2f", locale: numberLocale, point.horizontalAccuracy),
                String(format: "%.2f", locale: numberLocale, point.speed),
                entry.isDriftPoint ? "1" : "0"
            ].joined(separator: ",")
        }

        guard let data = rows.joined(separator: "\n").appending("\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

}

private struct RawPointRow: View, Equatable {
    let entry: RawPointEntry
    let previousDistance: CLLocationDistance?
    let isSelected: Bool

    static func == (lhs: RawPointRow, rhs: RawPointRow) -> Bool {
        lhs.entry.originalIndex == rhs.entry.originalIndex &&
        lhs.entry.isDriftPoint == rhs.entry.isDriftPoint &&
        lhs.entry.location.timestamp == rhs.entry.location.timestamp &&
        lhs.entry.location.coordinate.rawPointsCoordinateKey == rhs.entry.location.coordinate.rawPointsCoordinateKey &&
        lhs.entry.location.horizontalAccuracy == rhs.entry.location.horizontalAccuracy &&
        lhs.previousDistance == rhs.previousDistance &&
        lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let point = entry.location
        let index = entry.originalIndex
        let isDrift = entry.isDriftPoint

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 3) {
                    Text("#\(index + 1)")
                        .font(.caption.monospaced())
                        .foregroundColor(isDrift ? .gray : .dfkAccent)
                        .strikethrough(isDrift, color: .gray)

                    if isDrift {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(isDrift ? Color.gray.opacity(0.1) : Color.dfkAccent.opacity(0.1))
                .cornerRadius(4)

                Text(point.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.subheadline.monospaced().bold())
                    .foregroundColor(isDrift ? .gray : .primary)
                    .strikethrough(isDrift, color: .gray)

                Spacer()

                if index > 0, let previousDistance {
                    Text(formatDistance(previousDistance))
                        .font(.caption.italic())
                        .foregroundColor(isDrift ? .gray.opacity(0.6) : (previousDistance > 1000 ? .red : .secondary))
                        .strikethrough(isDrift, color: .gray)
                }
            }

            HStack {
                Text("\(String(format: "%.6f", point.coordinate.latitude)), \(String(format: "%.6f", point.coordinate.longitude))")
                    .font(.caption2.monospaced())
                    .foregroundColor(isDrift ? .gray.opacity(0.5) : .secondary)
                    .strikethrough(isDrift, color: .gray.opacity(0.5))

                Spacer()

                HStack(spacing: 4) {
                    if isDrift {
                        Text("漂移")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.5))
                            .cornerRadius(3)
                    }

                    Image(systemName: "scope")
                    Text("\(Int(point.horizontalAccuracy))m")
                }
                .font(.system(size: 10))
                .foregroundColor(isDrift ? .gray.opacity(0.5) : (point.horizontalAccuracy > 100 ? .orange : .secondary))
            }
        }
        .padding(.vertical, 4)
        .opacity(isDrift ? 0.65 : 1.0)
    }

    private func formatDistance(_ d: Double) -> String {
        if d < 1000 { return "+\(Int(d))m" }
        return String(format: "+%.2fkm", d/1000)
    }
}

private final class RawPointsMapSelection {
    var currentCoordinate: CLLocationCoordinate2D?
    var onSelect: ((CLLocationCoordinate2D?, Bool) -> Void)?

    func select(_ coordinate: CLLocationCoordinate2D?, shouldCenter: Bool = false) {
        currentCoordinate = coordinate
        onSelect?(coordinate, shouldCenter)
    }
}

private struct RawPointsLoadResult {
    private static let mapDisplayPointLimit = 1_000
    private static let maxDriftDisplayPoints = 200

    let entries: [RawPointEntry]
    let previousDistances: [Int: CLLocationDistance]
    let suspiciousIndices: Set<Int>
    let mapCoordinates: [CLLocationCoordinate2D]
    let mapDriftCoordinates: [CLLocationCoordinate2D]

    init(entries: [RawPointEntry]) {
        self.entries = entries

        let points = entries.map(\.location)
        var distances: [Int: CLLocationDistance] = [:]
        var suspicious: Set<Int> = []

        for entry in entries {
            let index = entry.originalIndex
            let point = entry.location

            if index > 0, index < points.count {
                distances[index] = point.distance(from: points[index - 1])
            }

            let isSuspicious = Self.isSuspicious(entry: entry, allPoints: points)
            if isSuspicious {
                suspicious.insert(index)
            }
        }

        let validCoordinates = entries
            .filter { !$0.isDriftPoint }
            .map(\.location.coordinate)
            .filter(\.isRawPointsRenderable)

        let driftCoordinates = entries
            .filter(\.isDriftPoint)
            .map(\.location.coordinate)
            .filter(\.isRawPointsRenderable)

        previousDistances = distances
        suspiciousIndices = suspicious
        let sampledDriftCoordinates = Self.sampleCoordinates(
            driftCoordinates,
            maxCount: min(Self.maxDriftDisplayPoints, Self.mapDisplayPointLimit)
        )
        let remainingLimit = max(2, Self.mapDisplayPointLimit - sampledDriftCoordinates.count)
        mapCoordinates = Self.sampleCoordinates(
            LocationManager.simplifyCoordinates(validCoordinates, tolerance: 0.00003),
            maxCount: remainingLimit
        )
        mapDriftCoordinates = sampledDriftCoordinates
    }

    private static func isSuspicious(entry: RawPointEntry, allPoints: [CLLocation]) -> Bool {
        let point = entry.location
        let index = entry.originalIndex

        if point.horizontalAccuracy > 100 { return true }
        guard !allPoints.isEmpty else { return false }

        let checkRange = 5
        let start = max(0, index - checkRange)
        let end = min(allPoints.count - 1, index + checkRange)

        for i in start...end {
            if i == index { continue }
            let other = allPoints[i]
            let dist = point.distance(from: other)
            let time = max(0.1, abs(point.timestamp.timeIntervalSince(other.timestamp)))
            let speed = dist / time

            if speed > 30 && dist > 200 { return true }
            if dist > 500 { return true }
            if dist > 300 && point.horizontalAccuracy > 50 { return true }
        }

        return false
    }

    private static func sampleCoordinates(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxCount, maxCount > 2 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { coordinates[Int((Double($0) * step).rounded())] }
    }
}

private struct RawPointsMapView: UIViewRepresentable {
    private static let maxRenderedPathPoints = 1_000
    private static let maxRenderedDriftPoints = 200

    let coordinates: [CLLocationCoordinate2D]
    let driftCoordinates: [CLLocationCoordinate2D]
    let selection: RawPointsMapSelection
    let recenterTrigger: Int
    let onSelectCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView
        selection.onSelect = { [weak coordinator = context.coordinator, weak mapView] coordinate, shouldCenter in
            guard let mapView else { return }
            coordinator?.setSelectedCoordinate(coordinate, on: mapView, shouldCenter: shouldCenter)
        }

        return mapView
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.mapView = nil
        coordinator.mapDataKey = ""
        coordinator.selectedAnnotation = nil
        coordinator.selectedCoordinateKey = ""
        coordinator.isApplyingRegionProgrammatically = false

        mapView.delegate = nil
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        mapView.removeOverlays(mapView.overlays)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        selection.onSelect = { [weak coordinator = context.coordinator, weak mapView] coordinate, shouldCenter in
            guard let mapView else { return }
            coordinator?.setSelectedCoordinate(coordinate, on: mapView, shouldCenter: shouldCenter)
        }
        context.coordinator.updateMapDataIfNeeded(on: mapView)

        if context.coordinator.lastRecenterTrigger != recenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            context.coordinator.fitAllCoordinates(on: mapView, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let selectedReuseIdentifier = "RawPointsSelectedAnnotation"
        private static let driftReuseIdentifier = "RawPointsDriftAnnotation"

        var parent: RawPointsMapView
        weak var mapView: MKMapView?
        var lastRecenterTrigger = 0
        fileprivate var mapDataKey = ""
        fileprivate var selectedAnnotation: RawPointMapAnnotation?
        fileprivate var selectedCoordinateKey = ""
        fileprivate var isApplyingRegionProgrammatically = false
        private var pendingInitialFitKey = ""

        private var renderedCoordinates: [CLLocationCoordinate2D] {
            Self.sampleCoordinates(parent.coordinates, maxCount: RawPointsMapView.maxRenderedPathPoints)
        }

        private var renderedDriftCoordinates: [CLLocationCoordinate2D] {
            Self.sampleCoordinates(parent.driftCoordinates, maxCount: RawPointsMapView.maxRenderedDriftPoints)
        }

        init(_ parent: RawPointsMapView) {
            self.parent = parent
        }

        func updateMapDataIfNeeded(on mapView: MKMapView) {
            let newKey = dataKey
            guard newKey != mapDataKey else { return }
            mapDataKey = newKey

            mapView.removeOverlays(mapView.overlays)
            let removable = mapView.annotations.filter { !($0 is MKUserLocation) }
            mapView.removeAnnotations(removable)
            selectedAnnotation = nil
            selectedCoordinateKey = ""

            let pathCoordinates = renderedCoordinates
            if pathCoordinates.count >= 2 {
                let polyline = MKPolyline(coordinates: pathCoordinates, count: pathCoordinates.count)
                mapView.addOverlay(polyline)
            }

            let driftCoordinates = renderedDriftCoordinates
            if !driftCoordinates.isEmpty {
                mapView.addOverlay(RawPointDotOverlay(coordinates: driftCoordinates, color: .systemGray, diameter: 8))
            }
            #if DEBUG
            print("[RawPointsMapView] render path=\(pathCoordinates.count), drift=\(driftCoordinates.count), overlays=\(mapView.overlays.count)")
            #endif
            setSelectedCoordinate(parent.selection.currentCoordinate, on: mapView, shouldCenter: false)
            scheduleInitialFit(on: mapView, key: newKey)
        }

        func setSelectedCoordinate(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView, shouldCenter: Bool) {
            let newKey = coordinate?.rawPointsCoordinateKey ?? ""
            guard newKey != selectedCoordinateKey else { return }
            selectedCoordinateKey = newKey

            if let selectedAnnotation {
                mapView.removeAnnotation(selectedAnnotation)
                self.selectedAnnotation = nil
            }

            guard let coordinate, coordinate.isRawPointsRenderable else { return }
            let annotation = RawPointMapAnnotation(coordinate: coordinate, kind: .selected)
            selectedAnnotation = annotation
            mapView.addAnnotation(annotation)
            if shouldCenter {
                isApplyingRegionProgrammatically = true
                mapView.setCenter(coordinate, animated: true)
            }
        }

        private func scheduleInitialFit(on mapView: MKMapView, key: String, attempt: Int = 0) {
            pendingInitialFitKey = key
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                guard self.pendingInitialFitKey == key, self.mapDataKey == key else { return }
                if !self.fitAllCoordinates(on: mapView, animated: false), attempt < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        self.scheduleInitialFit(on: mapView, key: key, attempt: attempt + 1)
                    }
                }
            }
        }

        @discardableResult
        func fitAllCoordinates(on mapView: MKMapView, animated: Bool) -> Bool {
            let pathCoordinates = renderedCoordinates
            let fitSource = pathCoordinates.isEmpty ? renderedDriftCoordinates : pathCoordinates
            let allCoordinates = fitSource.filter(\.isRawPointsRenderable)
            guard !allCoordinates.isEmpty else { return false }
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return false }

            if allCoordinates.count == 1 {
                isApplyingRegionProgrammatically = true
                mapView.setRegion(MKCoordinateRegion(center: allCoordinates[0], latitudinalMeters: 800, longitudinalMeters: 800), animated: animated)
                return true
            }

            let rect = allCoordinates.reduce(MKMapRect.null) { partial, coordinate in
                let point = MKMapPoint(coordinate)
                let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
                return partial.union(pointRect)
            }
            isApplyingRegionProgrammatically = true
            mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28), animated: animated)
            return true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onSelectCoordinate(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let dotOverlay = overlay as? RawPointDotOverlay {
                return RawPointDotOverlayRenderer(overlay: dotOverlay)
            }

            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(Color.dfkAccent)
            renderer.lineWidth = 3
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isApplyingRegionProgrammatically = false
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? RawPointMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.selectedReuseIdentifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: Self.selectedReuseIdentifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.image = Self.selectedImage
            view.centerOffset = .zero
            view.zPriority = .max
            view.displayPriority = .required
            return view
        }

        private var dataKey: String {
            let pathCoordinates = renderedCoordinates
            let driftCoordinates = renderedDriftCoordinates
            let first = pathCoordinates.first
            let last = pathCoordinates.last
            return [
                "\(pathCoordinates.count)",
                "\(driftCoordinates.count)",
                first.map { "\($0.latitude),\($0.longitude)" } ?? "",
                last.map { "\($0.latitude),\($0.longitude)" } ?? ""
            ].joined(separator: "|")
        }

        private static let selectedImage: UIImage = {
            let size = CGSize(width: 12, height: 12)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.systemRed.setFill()
                context.cgContext.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
            }
        }()

        private static func sampleCoordinates(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
            guard coordinates.count > maxCount, maxCount > 2 else { return coordinates }
            let step = Double(coordinates.count - 1) / Double(maxCount - 1)
            return (0..<maxCount).map { coordinates[Int((Double($0) * step).rounded())] }
        }
    }
}

private final class RawPointDotOverlay: NSObject, MKOverlay {
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
            self.boundingMapRect = rect
            self.coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        } else {
            self.boundingMapRect = .null
            self.coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }
}

private final class RawPointDotOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let dotOverlay = overlay as? RawPointDotOverlay else { return }
        context.setFillColor(dotOverlay.color.withAlphaComponent(0.65).cgColor)

        for coordinate in dotOverlay.coordinates {
            let mapPoint = MKMapPoint(coordinate)
            guard mapRect.contains(mapPoint) else { continue }
            let point = self.point(for: mapPoint)
            let rect = CGRect(
                x: point.x - dotOverlay.diameter / 2,
                y: point.y - dotOverlay.diameter / 2,
                width: dotOverlay.diameter,
                height: dotOverlay.diameter
            )
            context.fillEllipse(in: rect)
        }
    }
}

private final class RawPointMapAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case drift
        case selected
    }

    let coordinate: CLLocationCoordinate2D
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
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
