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
    @State private var dataVersion = 0
    
    // 过滤与排序选项
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?
    @State private var isSelecting = false
    @State private var selection = Set<Int>()
    @State private var selectionBox: CGRect?
    @State private var isBatchDeleting = false
    @State private var editMode: EditMode = .inactive

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
                                dataVersion: dataVersion,
                                selection: mapSelection,
                                multiSelectedCoordinates: entries.filter { selection.contains($0.originalIndex) }.map { $0.location.coordinate },
                                recenterTrigger: positionResetTrigger,
                                isSelecting: isSelecting,
                                selectionBox: $selectionBox,
                                onBoxSelect: { minLat, maxLat, minLon, maxLon in
                                    let newSelection = filteredEntries.filter { entry in
                                        let coord = entry.location.coordinate
                                        return coord.latitude >= minLat && coord.latitude <= maxLat &&
                                               coord.longitude >= minLon && coord.longitude <= maxLon
                                    }.map(\.originalIndex)
                                    for idx in newSelection {
                                        selection.insert(idx)
                                    }
                                },
                                onSelectCoordinate: selectNearestPoint(to:)
                            )
                        .overlay {
                            if let box = selectionBox {
                                Rectangle()
                                    .fill(Color.blue.opacity(0.2))
                                    .stroke(Color.blue, lineWidth: 1)
                                    .frame(width: box.width, height: box.height)
                                    .position(x: box.midX, y: box.midY)
                            }
                        }
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

                        HStack {
                            if showOnlySuspicious {
                                Text("发现 \(filteredEntries.count) 个问题点")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                            } else {
                                Text("共 \(entries.count) 个点")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            if driftCount > 0 && !isSelecting {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                    Text("\(driftCount)")
                                        .font(.caption)
                                }
                                .foregroundColor(.gray)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(4)
                            }
                            
                            Spacer()
                            
                            if isSelecting {
                                Button("全选") {
                                    if selection.count == filteredEntries.count {
                                        selection.removeAll()
                                    } else {
                                        selection = Set(filteredEntries.map(\.originalIndex))
                                    }
                                }
                                .font(.subheadline.bold())
                                .padding(.trailing, 12)
                                
                                Button("取消") {
                                    withAnimation {
                                        isSelecting = false
                                        selection.removeAll()
                                    }
                                }
                                .font(.subheadline)
                            } else {
                                Button {
                                    withAnimation {
                                        showOnlySuspicious.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "line.3.horizontal.decrease")
                                        Text(showOnlySuspicious ? "全部" : "过滤")
                                    }
                                    .foregroundColor(showOnlySuspicious ? .orange : .accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(showOnlySuspicious ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.1))
                                    .cornerRadius(6)
                                }
                                .font(.subheadline)
                                .padding(.trailing, 8)
                                
                                Button {
                                    withAnimation {
                                        isSelecting = true
                                        if showOnlySuspicious {
                                            selection = Set(filteredEntries.map(\.originalIndex))
                                        } else {
                                            selection.removeAll()
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checklist")
                                        Text("多选")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(6)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.systemGroupedBackground))
                        .overlay(Divider(), alignment: .bottom)
                        .zIndex(1)

                        ScrollViewReader { scrollProxy in
                            List(selection: $selection) {

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
                                        if isSelecting {
                                            if selection.contains(entry.originalIndex) {
                                                selection.remove(entry.originalIndex)
                                            } else {
                                                selection.insert(entry.originalIndex)
                                            }
                                        } else {
                                            selectPoint(entry.location, index: entry.originalIndex)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        if !isSelecting {
                                            Button(role: .destructive) {
                                                pointToDelete = entry.location
                                                deletePoint(entry.location)
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
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
                        .environment(\.editMode, $editMode)
                        .onChange(of: selection) { _, newSelection in
                            if !newSelection.isEmpty && !isSelecting {
                                isSelecting = true
                            }
                        }
                        .onChange(of: isSelecting) { _, isSel in
                            editMode = isSel ? .active : .inactive
                            if !isSel {
                                selection.removeAll()
                            }
                        }
                        .onChange(of: editMode) { _, newMode in
                            isSelecting = (newMode == .active)
                        }
                    }
                }
            }
            .navigationTitle("\(date.formatted(.dateTime.month().day())) 原始轨迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        exportRawPoints()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出当天轨迹点")
                    .disabled(entries.isEmpty || isSelecting)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                
                if isSelecting {
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                isShowingDeleteConfirmation = true
                            } label: {
                                if isBatchDeleting {
                                    ProgressView()
                                } else {
                                    Text("删除 (\(selection.count))")
                                        .foregroundColor(selection.isEmpty ? .gray : .red)
                                        .bold()
                                }
                            }
                            .disabled(selection.isEmpty || isBatchDeleting)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let exportURL {
                    ActivityView(activityItems: [exportURL])
                }
            }
            .alert("确认删除", isPresented: $isShowingDeleteConfirmation) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    deleteSelectedPoints()
                }
            } message: {
                Text("确定要删除这 \(selection.count) 个轨迹点吗？")
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

        if let closest = closestEntry, minDistance < 1000 {
            if isSelecting {
                if selection.contains(closest.originalIndex) {
                    selection.remove(closest.originalIndex)
                } else {
                    selection.insert(closest.originalIndex)
                }
            } else {
                selectedIndex = closest.originalIndex
                scrollTargetIndex = closest.originalIndex
                DispatchQueue.main.async {
                    mapSelection.select(closest.location.coordinate, shouldCenter: true)
                }
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
            dataVersion += 1
        }
    }

    private func deleteSelectedPoints() {
        isBatchDeleting = true
        let indicesToDelete = selection
        let timestampsToDelete = Set(entries.filter { indicesToDelete.contains($0.originalIndex) }.map { $0.location.timestamp.timeIntervalSince1970 })
        
        Task.detached(priority: .userInitiated) {
            RawLocationStore.shared.deleteLocations(at: timestampsToDelete, for: self.date)
            
            await MainActor.run {
                withAnimation(.spring()) {
                    self.entries.removeAll { indicesToDelete.contains($0.originalIndex) }
                }
                
                let loadResult = RawPointsLoadResult(entries: self.entries)
                self.previousDistances = loadResult.previousDistances
                self.suspiciousIndices = loadResult.suspiciousIndices
                self.mapCoordinates = loadResult.mapCoordinates
                self.mapDriftCoordinates = loadResult.mapDriftCoordinates
                self.dataVersion += 1
                
                self.isSelecting = false
                self.selection.removeAll()
                self.isBatchDeleting = false
            }
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

        for (arrayIndex, entry) in entries.enumerated() {
            let originalIndex = entry.originalIndex
            let point = entry.location

            if arrayIndex > 0 {
                distances[originalIndex] = point.distance(from: points[arrayIndex - 1])
            }

            let isSuspicious = Self.isSuspicious(entry: entry, arrayIndex: arrayIndex, allPoints: points)
            if isSuspicious {
                suspicious.insert(originalIndex)
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

    private static func isSuspicious(entry: RawPointEntry, arrayIndex: Int, allPoints: [CLLocation]) -> Bool {
        let point = entry.location

        if point.horizontalAccuracy > 100 { return true }
        guard !allPoints.isEmpty else { return false }

        let checkRange = 5
        let start = max(0, arrayIndex - checkRange)
        let end = min(allPoints.count - 1, arrayIndex + checkRange)

        for i in start...end {
            if i == arrayIndex { continue }
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
    let dataVersion: Int
    let selection: RawPointsMapSelection
    let multiSelectedCoordinates: [CLLocationCoordinate2D]
    let recenterTrigger: Int
    var isSelecting: Bool
    @Binding var selectionBox: CGRect?
    let onBoxSelect: (CLLocationDegrees, CLLocationDegrees, CLLocationDegrees, CLLocationDegrees) -> Void
    let onSelectCoordinate: (CLLocationCoordinate2D) -> Void

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
        coordinator.multiSelectedAnnotations.removeAll()

        mapView.delegate = nil
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        mapView.removeOverlays(mapView.overlays)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard let safeMap = mapView as? SafeMKMapView else { return }
        context.coordinator.parent = self
        selection.onSelect = { [weak coordinator = context.coordinator, weak safeMap] coordinate, shouldCenter in
            guard let safeMap else { return }
            coordinator?.setSelectedCoordinate(coordinate, on: safeMap, shouldCenter: shouldCenter)
        }
        
        let triggerValue = recenterTrigger
        let multiSelected = multiSelectedCoordinates
        let updateBlock = { [weak coordinator = context.coordinator, weak safeMap] in
            guard let safeMap, let coordinator else { return }
            coordinator.updateMapDataIfNeeded(on: safeMap)
            coordinator.updateMultiSelectionOverlay(multiSelected, on: safeMap)
            
            if coordinator.lastRecenterTrigger != triggerValue {
                coordinator.lastRecenterTrigger = triggerValue
                coordinator.fitAllCoordinates(on: safeMap, animated: false)
            }
        }
        
        if isSelecting {
            safeMap.isScrollEnabled = false
            if context.coordinator.panGesture == nil {
                let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
                pan.maximumNumberOfTouches = 1
                safeMap.addGestureRecognizer(pan)
                context.coordinator.panGesture = pan
            }
            context.coordinator.panGesture?.isEnabled = true
        } else {
            safeMap.isScrollEnabled = true
            context.coordinator.panGesture?.isEnabled = false
            DispatchQueue.main.async {
                self.selectionBox = nil
            }
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
        private static let selectedReuseIdentifier = "RawPointsSelectedAnnotation"
        private static let driftReuseIdentifier = "RawPointsDriftAnnotation"

        var parent: RawPointsMapView
        weak var mapView: MKMapView?
        var lastRecenterTrigger = 0
        var panGesture: UIPanGestureRecognizer?
        var startPoint: CGPoint = .zero
        fileprivate var mapDataKey = ""
        fileprivate var selectedAnnotation: RawPointMapAnnotation?
        fileprivate var selectedCoordinateKey = ""
        fileprivate var isApplyingRegionProgrammatically = false
        fileprivate var multiSelectedAnnotations: [RawPointMapAnnotation] = []
        private var pendingInitialFitKey = ""
        private var lastMultiSelectedKey = ""

        private var renderedCoordinates: [CLLocationCoordinate2D] {
            Self.sampleCoordinates(parent.coordinates, maxCount: RawPointsMapView.maxRenderedPathPoints)
        }

        private var renderedDriftCoordinates: [CLLocationCoordinate2D] {
            Self.sampleCoordinates(parent.driftCoordinates, maxCount: RawPointsMapView.maxRenderedDriftPoints)
        }

        init(_ parent: RawPointsMapView) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView = mapView else { return }
            let location = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                startPoint = location
                parent.selectionBox = CGRect(x: location.x, y: location.y, width: 1, height: 1)

            case .changed:
                let minX = min(startPoint.x, location.x)
                let minY = min(startPoint.y, location.y)
                let width = max(1.0, abs(location.x - startPoint.x))
                let height = max(1.0, abs(location.y - startPoint.y))
                parent.selectionBox = CGRect(x: minX, y: minY, width: width, height: height)

            case .ended, .cancelled:
                guard let boxFrame = parent.selectionBox, boxFrame.width > 0, boxFrame.height > 0 else {
                    parent.selectionBox = nil
                    return
                }
                
                let point1 = mapView.convert(CGPoint(x: boxFrame.minX, y: boxFrame.minY), toCoordinateFrom: mapView)
                let point2 = mapView.convert(CGPoint(x: boxFrame.maxX, y: boxFrame.maxY), toCoordinateFrom: mapView)
                
                let minLat = min(point1.latitude, point2.latitude)
                let maxLat = max(point1.latitude, point2.latitude)
                let minLon = min(point1.longitude, point2.longitude)
                let maxLon = max(point1.longitude, point2.longitude)

                parent.onBoxSelect(minLat, maxLat, minLon, maxLon)
                
                withAnimation(.easeOut(duration: 0.2)) {
                    self.parent.selectionBox = nil
                }

            default:
                break
            }
        }

        func updateMapDataIfNeeded(on mapView: MKMapView) {
            let newKey = dataKey
            guard newKey != mapDataKey else { return }
            mapDataKey = newKey

            mapView.removeOverlays(mapView.overlays)
            multiSelectedAnnotations.removeAll()
            lastMultiSelectedKey = ""
            
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
            let annotation = RawPointMapAnnotation(coordinate: coordinate, kind: .singleSelected)
            selectedAnnotation = annotation
            mapView.addAnnotation(annotation)
            if shouldCenter {
                isApplyingRegionProgrammatically = true
                mapView.setCenter(coordinate, animated: false)
            }
        }

        func updateMultiSelectionOverlay(_ coordinates: [CLLocationCoordinate2D], on mapView: MKMapView) {
            let key = "\(coordinates.count)_" + (coordinates.first.map { "\($0.latitude),\($0.longitude)" } ?? "")
            
            if lastMultiSelectedKey == key && (!coordinates.isEmpty || multiSelectedAnnotations.isEmpty) {
                return
            }
            
            if !multiSelectedAnnotations.isEmpty {
                mapView.removeAnnotations(multiSelectedAnnotations)
                multiSelectedAnnotations.removeAll()
            }
            
            lastMultiSelectedKey = key
            
            if !coordinates.isEmpty {
                let annotations = coordinates.map { RawPointMapAnnotation(coordinate: $0, kind: .selected) }
                multiSelectedAnnotations = annotations
                mapView.addAnnotations(annotations)
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
                mapView.setRegion(MKCoordinateRegion(center: allCoordinates[0], latitudinalMeters: 800, longitudinalMeters: 800), animated: false)
                return true
            }

            let rect = allCoordinates.reduce(MKMapRect.null) { partial, coordinate in
                let point = MKMapPoint(coordinate)
                let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
                return partial.union(pointRect)
            }
            isApplyingRegionProgrammatically = true
            mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28), animated: false)
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
            let reuseId = annotation.kind == .singleSelected ? "RawPointsSingleSelectedAnnotation" : Self.selectedReuseIdentifier
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
            view.annotation = annotation
            view.canShowCallout = false
            view.image = annotation.kind == .singleSelected ? Self.singleSelectedImage : Self.selectedImage
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
                "\(parent.dataVersion)",
                "\(parent.coordinates.count)",
                "\(parent.driftCoordinates.count)",
                "\(pathCoordinates.count)",
                "\(driftCoordinates.count)",
                first.map { "\($0.latitude),\($0.longitude)" } ?? "",
                last.map { "\($0.latitude),\($0.longitude)" } ?? ""
            ].joined(separator: "|")
        }

        private static let selectedImage: UIImage = {
            let size = CGSize(width: 12, height: 12)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                UIColor.systemRed.setFill()
                context.cgContext.fillEllipse(in: rect)
            }
        }()

        private static let singleSelectedImage: UIImage = {
            let size = CGSize(width: 16, height: 16)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                UIColor.systemOrange.setFill()
                context.cgContext.fillEllipse(in: rect)
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
        
        let scaledDiameter = dotOverlay.diameter / zoomScale

        for coordinate in dotOverlay.coordinates {
            let mapPoint = MKMapPoint(coordinate)
            guard mapRect.contains(mapPoint) else { continue }
            let point = self.point(for: mapPoint)
            let rect = CGRect(
                x: point.x - scaledDiameter / 2,
                y: point.y - scaledDiameter / 2,
                width: scaledDiameter,
                height: scaledDiameter
            )
            context.fillEllipse(in: rect)
        }
    }
}

private final class RawPointMapAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case drift
        case selected
        case singleSelected
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
