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
                        .frame(height: 220)
                        .mapStyle(.standard(emphasis: .muted))
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
                        
                        List {
                            Section {
                                Text(showOnlySuspicious ? "发现 \(filteredPoints.count) 个疑似问题点" : "共 \(points.count) 个记录点")
                                    .font(.caption)
                                    .foregroundColor(showOnlySuspicious ? .orange : .secondary)
                            }
                            
                            ForEach(filteredPoints, id: \.point.timestamp) { index, point in
                                pointRow(index: index, point: point)
                                    .listRowBackground(selectedPoint?.timestamp == point.timestamp ? Color.dfkAccent.opacity(0.1) : nil)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedPoint = point
                                        withAnimation(.easeInOut) {
                                            position = .camera(MapCamera(centerCoordinate: point.coordinate, distance: 500))
                                        }
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
                    }
                }
            }
            .navigationTitle("\(date.formatted(.dateTime.month().day())) 原始轨迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                
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
            }
            .onAppear {
                loadPoints()
            }
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
            // 加载未经过滤的原始点位，方便用户看见跳点并手动删除
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
    
    private func formatDistance(_ d: Double) -> String {
        if d < 1000 { return "+\(Int(d))m" }
        return String(format: "+%.2fkm", d/1000)
    }
    
    private func isSuspicious(index: Int, point: CLLocation) -> Bool {
        // 1. 精度极差
        if point.horizontalAccuracy > 500 { return true }
        
        // 2. 速度异常 (相比于记录中的上一个点)
        if index > 0 {
            let prev = points[index - 1]
            let dist = point.distance(from: prev)
            let time = max(0.1, point.timestamp.timeIntervalSince(prev.timestamp))
            let speed = dist / time // m/s
            
            if speed > 70 { return true } // 时速超过 250km/h
            if dist > 2000 && point.horizontalAccuracy > 200 { return true }
        }
        
        return false
    }
}
