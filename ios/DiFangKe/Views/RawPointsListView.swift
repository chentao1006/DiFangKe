import SwiftUI
import CoreLocation
import MapKit

struct RawPointsListView: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager

    @State private var entries: [RawPointEntry] = []
    @State private var isLoading = true
    @State private var isShowingDeleteConfirmation = false
    @State private var pointToDelete: CLLocation?
    @State private var showOnlySuspicious = false
    @State private var selectedPoint: CLLocation? = nil
    @State private var position: MapCameraPosition = .automatic
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?

    /// 所有有效（非漂移）的坐标，用于地图轨迹线
    private var validCoordinates: [CLLocationCoordinate2D] {
        entries.filter { !$0.isDriftPoint }.map { $0.location.coordinate }
    }

    /// 漂移点坐标，用于地图上灰色显示
    private var driftCoordinates: [CLLocationCoordinate2D] {
        entries.filter { $0.isDriftPoint }.map { $0.location.coordinate }
    }

    private var driftCount: Int {
        entries.filter { $0.isDriftPoint }.count
    }

    private var filteredEntries: [RawPointEntry] {
        if !showOnlySuspicious {
            return entries
        }
        return entries.filter { entry in
            entry.isDriftPoint || isSuspicious(entry: entry)
        }
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
                        MapReader { mapProxy in
                            GeometryReader { geometry in
                                if geometry.size.width > 0 && geometry.size.height > 0 {
                                    Map(position: $position) {
                                        // 有效轨迹线（正常颜色）
                                        MapPolyline(coordinates: validCoordinates)
                                            .stroke(Color.dfkAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                                        // 漂移点用灰色圆点标注
                                        ForEach(Array(driftCoordinates.enumerated()), id: \.offset) { _, coord in
                                            Annotation("", coordinate: coord, anchor: .center) {
                                                Circle()
                                                    .fill(Color.gray.opacity(0.5))
                                                    .frame(width: 6, height: 6)
                                                    .accessibilityHidden(true)
                                            }
                                        }

                                        if let selected = selectedPoint {
                                            Annotation("选中点", coordinate: selected.coordinate, anchor: .bottom) {
                                                VStack(spacing: 0) {
                                                    Image(systemName: "mappin.circle.fill")
                                                        .font(.title2)
                                                        .foregroundColor(.red)
                                                    Image(systemName: "arrowtriangle.down.fill")
                                                        .font(.caption2)
                                                        .foregroundColor(.red)
                                                        .offset(y: -4)
                                                }
                                            }
                                        }
                                    }
                                    .mapStyle(.standard(emphasis: .muted))
                                    .onTapGesture { screenPoint in
                                        if let coordinate = mapProxy.convert(screenPoint, from: .local) {
                                            selectNearestPoint(to: coordinate)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Button {
                                            withAnimation {
                                                position = .automatic
                                            }
                                        } label: {
                                            Image(systemName: "scope")
                                                .padding(8)
                                                .background(.ultraThinMaterial)
                                                .cornerRadius(8)
                                                .padding(10)
                                        }
                                    }
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(height: 220)
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
                                    pointRow(entry: entry)
                                        .id(entry.originalIndex)
                                        .listRowBackground(selectedPoint?.timestamp == entry.location.timestamp ? Color.dfkAccent.opacity(0.1) : nil)
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
                            .onChange(of: selectedPoint) { _, newValue in
                                if let selected = newValue,
                                   let entry = entries.first(where: { $0.location.timestamp == selected.timestamp }) {
                                    withAnimation {
                                        scrollProxy.scrollTo(entry.originalIndex, anchor: .center)
                                    }
                                }
                            }
                            .onChange(of: showOnlySuspicious) { _, _ in
                                if let selected = selectedPoint {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        if let entry = entries.first(where: { $0.location.timestamp == selected.timestamp }) {
                                            if filteredEntries.contains(where: { $0.originalIndex == entry.originalIndex }) {
                                                withAnimation {
                                                    scrollProxy.scrollTo(entry.originalIndex, anchor: .center)
                                                }
                                            }
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
        selectedPoint = point
        withAnimation(.easeInOut) {
            position = .camera(MapCamera(centerCoordinate: point.coordinate, distance: 500))
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
            selectedPoint = closest.location
        }
    }

    @ViewBuilder
    private func pointRow(entry: RawPointEntry) -> some View {
        let point = entry.location
        let index = entry.originalIndex
        let isDrift = entry.isDriftPoint
        
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // 序号标签
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

                if index > 0 {
                    let prevEntry = entries.first(where: { $0.originalIndex == index - 1 })
                    if let prevEntry {
                        let dist = point.distance(from: prevEntry.location)
                        Text(formatDistance(dist))
                            .font(.caption.italic())
                            .foregroundColor(isDrift ? .gray.opacity(0.6) : (dist > 1000 ? .red : .secondary))
                            .strikethrough(isDrift, color: .gray)
                    }
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

    private func loadPoints() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let rawEntries = RawLocationStore.shared.loadAllDevicesLocationsWithDriftFlags(for: date)
            await MainActor.run {
                self.entries = rawEntries
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

    private func formatDistance(_ d: Double) -> String {
        if d < 1000 { return "+\(Int(d))m" }
        return String(format: "+%.2fkm", d/1000)
    }

    /// 判定可疑点（漂移点以外的其他异常）
    private func isSuspicious(entry: RawPointEntry) -> Bool {
        let point = entry.location
        let index = entry.originalIndex
        
        // 1. 精度判定
        if point.horizontalAccuracy > 100 { return true }

        // 2. 检查周边范围 (±5 个点)，判定异常跳变
        let checkRange = 5
        let allPoints = entries.map { $0.location }
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
}
