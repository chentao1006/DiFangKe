import SwiftUI
import CoreLocation
import MapKit

struct RawPointsListView: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager

    @State private var points: [CLLocation] = []
    @State private var isLoading = true
    @State private var isShowingDeleteConfirmation = false
    @State private var pointToDelete: CLLocation?
    @State private var showOnlySuspicious = false
    @State private var selectedPoint: CLLocation? = nil
    @State private var position: MapCameraPosition = .automatic
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?

    private var allCoordinates: [CLLocationCoordinate2D] {
        points.map { $0.coordinate }
    }

    private var filteredPoints: [(index: Int, point: CLLocation)] {
        let enumerated = Array(points.enumerated())
        if !showOnlySuspicious {
            return enumerated.map { ($0.offset, $0.element) }
        }
        return enumerated.filter { index, point in
            isSuspicious(index: index, point: point)
        }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载原始轨迹...")
                } else if points.isEmpty {
                    ContentUnavailableView("暂无轨迹点", systemImage: "mappin.slash", description: Text("该日期没有任何原始位置记录"))
                } else {
                    VStack(spacing: 0) {
                        MapReader { mapProxy in
                            GeometryReader { geometry in
                                if geometry.size.width > 0 && geometry.size.height > 0 {
                                    Map(position: $position) {
                                        MapPolyline(coordinates: allCoordinates)
                                            .stroke(Color.dfkAccent.opacity(0.5), lineWidth: 3)

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
                                    Text(showOnlySuspicious ? "发现 \(filteredPoints.count) 个疑似问题点" : "共 \(points.count) 个记录点")
                                        .font(.caption)
                                        .foregroundColor(showOnlySuspicious ? .orange : .secondary)
                                }

                                ForEach(filteredPoints, id: \.index) { index, point in
                                    pointRow(index: index, point: point)
                                        .id(index) // Important for ScrollViewReader
                                        .listRowBackground(selectedPoint?.timestamp == point.timestamp ? Color.dfkAccent.opacity(0.1) : nil)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectPoint(point, index: index)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                pointToDelete = point
                                                deletePoint(point)
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                            .listStyle(.insetGrouped)
                            .onChange(of: selectedPoint) { _, newValue in
                                if let selected = newValue,
                                   let index = points.firstIndex(where: { $0.timestamp == selected.timestamp }) {
                                    withAnimation {
                                        scrollProxy.scrollTo(index, anchor: .center)
                                    }
                                }
                            }
                            .onChange(of: showOnlySuspicious) { _, _ in
                                // 切换过滤模式时，如果当前有选中点，自动滚动到该点
                                if let selected = selectedPoint {
                                    // 延迟一点点等待列表重新渲染
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        if let index = points.firstIndex(where: { $0.timestamp == selected.timestamp }) {
                                            // 检查该点是否在当前过滤后的列表中
                                            if filteredPoints.contains(where: { $0.index == index }) {
                                                withAnimation {
                                                    scrollProxy.scrollTo(index, anchor: .center)
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
                    .disabled(points.isEmpty)

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
        var closestPoint: CLLocation?
        var minDistance: CLLocationDistance = Double.infinity

        for item in filteredPoints {
            let dist = item.point.distance(from: tapLocation)
            if dist < minDistance {
                minDistance = dist
                closestPoint = item.point
            }
        }

        // 允许较大的点击误差，特别是在缩放级别较高时 (1000m)
        if let closest = closestPoint, minDistance < 1000 {
            selectedPoint = closest
            // 此时 onChange(of: selectedPoint) 会处理滚动
        }
    }

    private func pointRow(index: Int, point: CLLocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(index + 1)")
                    .font(.caption.monospaced())
                    .foregroundColor(.dfkAccent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.dfkAccent.opacity(0.1))
                    .cornerRadius(4)

                Text(point.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.subheadline.monospaced().bold())

                Spacer()

                if index > 0 {
                    let prev = points[index - 1]
                    let dist = point.distance(from: prev)
                    Text(formatDistance(dist))
                        .font(.caption.italic())
                        .foregroundColor(dist > 1000 ? .red : .secondary)
                }
            }

            HStack {
                Text("\(String(format: "%.6f", point.coordinate.latitude)), \(String(format: "%.6f", point.coordinate.longitude))")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "scope")
                    Text("\(Int(point.horizontalAccuracy))m")
                }
                .font(.system(size: 10))
                .foregroundColor(point.horizontalAccuracy > 100 ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadPoints() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            // 这里改为 filtered: false，加载真正的原始数据
            // 只有加载了原始数据，下方的“过滤问题点”功能才能识别并显示出那些有问题的点
            let rawPoints = RawLocationStore.shared.loadAllDevicesLocations(for: date, filtered: false)
            await MainActor.run {
                self.points = rawPoints
                self.isLoading = false
            }
        }
    }

    private func deletePoint(_ point: CLLocation) {
        RawLocationStore.shared.deleteLocation(at: point.timestamp.timeIntervalSince1970, for: date)
        if let idx = points.firstIndex(where: { $0.timestamp == point.timestamp }) {
            withAnimation(.spring()) {
                _ = points.remove(at: idx)
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

        var rows = ["timestamp_iso,timestamp_unix,latitude,longitude,accuracy,speed"]
        rows += points.map { point in
            let timestamp = point.timestamp.timeIntervalSince1970
            return [
                isoFormatter.string(from: point.timestamp),
                String(format: "%.3f", locale: numberLocale, timestamp),
                String(format: "%.8f", locale: numberLocale, point.coordinate.latitude),
                String(format: "%.8f", locale: numberLocale, point.coordinate.longitude),
                String(format: "%.2f", locale: numberLocale, point.horizontalAccuracy),
                String(format: "%.2f", locale: numberLocale, point.speed)
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

    private func isSuspicious(index: Int, point: CLLocation) -> Bool {
        // 1. 精度判定：只要精度超过 100米就视为潜在问题点（之前是300m，调低阈值以捕捉更多）
        if point.horizontalAccuracy > 100 { return true }

        // 2. 检查周边范围 (±5 个点)，判定异常跳变
        let checkRange = 5
        let start = max(0, index - checkRange)
        let end = min(points.count - 1, index + checkRange)

        for i in start...end {
            if i == index { continue }
            let other = points[i]
            let dist = point.distance(from: other)
            let time = max(0.1, abs(point.timestamp.timeIntervalSince(other.timestamp)))
            let speed = dist / time

            // --- 调低阈值以捕捉更多可能有问题的点 ---

            // A. 速度异常：超过 30m/s (108km/h) 且有一定距离
            if speed > 30 && dist > 200 { return true }

            // B. 距离跳变：单次跳跃超过 500m
            if dist > 500 { return true }

            // C. 精度与移动：精度稍差 (>50m) 且发生了较明显移动 (>300m)
            if dist > 300 && point.horizontalAccuracy > 50 { return true }
        }

        return false
    }
}
