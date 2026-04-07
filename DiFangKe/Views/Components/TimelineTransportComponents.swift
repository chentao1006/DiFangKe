import SwiftUI
import CoreLocation
import MapKit
import SwiftData

struct TransportCardView: View {
    let transport: Transport
    var isFirst: Bool = false
    var isLast: Bool = false
    var isToday: Bool = false
    var onSelect: ((Transport) -> Void)? = nil
    var onDelete: ((Transport) -> Void)? = nil
    
    var body: some View {
        Button {
            onSelect?(transport)
        } label: {
            HStack(alignment: .top, spacing: 0) {
                // 1. Timeline Indicator (Aligned with FootprintCardView)
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5)
                        .frame(height: 22)
                        .opacity(isFirst && !isToday ? 0 : 1)
                    
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(Color.blue.opacity(0.2)))
                    }.frame(width: 24, height: 24)
                    
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, -12)
                        .opacity(isLast ? 0 : 1)
                }.frame(width: 40)
                
                // 2. Card Content
                VStack(alignment: .center, spacing: 0) {
                    HStack(alignment: .center, spacing: 2) {
                        // Left: Start
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transport.startLocation)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            
                            Text(transport.startTime.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Middle: Icon & Distance
                        VStack(spacing: 4) {
                            transportIcon
                                .font(.system(size: 18))
                                .foregroundColor(.dfkAccent)
                            
                            Text(distanceString)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .frame(width: 80)
                        
                        // Right: End
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(transport.endLocation)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            
                            Text(transport.endTime.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, 16)
                    .padding(.trailing, 16)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 3)
            )
            .padding(.bottom, 12)
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
}

// MARK: - TransportModalView
struct TransportModalView: View {
    let transport: Transport
    var onUpdate: ((TransportType) -> Void)? = nil
    var onLocationUpdate: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var position: MapCameraPosition = .automatic
    @State private var localManualType: TransportType? = nil
    @State private var selectedMarker: LocationType? = nil
    @State private var showingMarkerDialog: LocationType? = nil
    
    @Environment(LocationManager.self) private var locationManager
    @State private var showingSearchSheet: LocationType? = nil
    @State private var localStartOverride: String? = nil
    @State private var localEndOverride: String? = nil
    
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
    
    // Use the effective type for display
    private var displayType: TransportType {
        localManualType ?? transport.currentType
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // 1. Map View
                Map(position: $position) {
                    // Start Marker (Physical Look & Title)
                    if let start = transport.points.first {
                        Marker(currentStartLocation, coordinate: start)
                            .tint(.green)
                    }
                    
                    // Start Interaction Layer
                    if let start = transport.points.first {
                        Annotation("", coordinate: start, anchor: .top) {
                            Menu {
                                SuggestionsMenuContent(locationManager: locationManager, coordinate: start, forOngoing: false) {
                                    showingSearchSheet = .start
                                } onCustomSelection: { newName in
                                    saveLocationOverride(type: .start, name: newName)
                                }
                            } label: {
                                Text(currentStartLocation)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                                    .overlay(Capsule().stroke(Color.green, lineWidth: 1))
                            }
                        }
                    }
                    
                    // End Marker (Physical Look & Title)
                    if let end = transport.points.last {
                        Marker(currentEndLocation, coordinate: end)
                            .tint(.blue)
                    }
                    
                    // End Interaction Layer
                    if let end = transport.points.last {
                        Annotation("", coordinate: end, anchor: .top) {
                            Menu {
                                SuggestionsMenuContent(locationManager: locationManager, coordinate: end, forOngoing: false) {
                                    showingSearchSheet = .end
                                } onCustomSelection: { newName in
                                    saveLocationOverride(type: .end, name: newName)
                                }
                            } label: {
                                Text(currentEndLocation)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                                    .overlay(Capsule().stroke(Color.blue, lineWidth: 1))
                            }
                        }
                    }
                    
                    // Route Polyline
                    MapPolyline(coordinates: transport.points)
                        .stroke(Color.dfkAccent, lineWidth: 5)
                }
                .mapStyle(.standard(emphasis: .muted))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
            }
            .navigationTitle("交通详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
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
                                
                                Menu {
                                    SuggestionsMenuContent(locationManager: locationManager, coordinate: transport.points.first, forOngoing: false) {
                                        showingSearchSheet = .start
                                    } onCustomSelection: { newName in
                                        saveLocationOverride(type: .start, name: newName)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("起点: " + currentStartLocation)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Image(systemName: "pencil")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.blue)
                                
                                Menu {
                                    SuggestionsMenuContent(locationManager: locationManager, coordinate: transport.points.last, forOngoing: false) {
                                        showingSearchSheet = .end
                                    } onCustomSelection: { newName in
                                        saveLocationOverride(type: .end, name: newName)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("终点: " + currentEndLocation)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Image(systemName: "pencil")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                }
                                .buttonStyle(.plain)
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
        }
    }
    
    private func findOrCreateSelection() -> TransportManualSelection {
        let startTime = transport.startTime
        let endTime = transport.endTime
        let midTime = startTime.addingTimeInterval(transport.duration / 2)
        
        // Always fetch fresh from context to avoid stale snapshots from parent view
        let descriptor = FetchDescriptor<TransportManualSelection>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        
        // Use midpoint matching (same logic as TimelineBuilder) to find the relevant override
        // This is much more robust than exact bound matching, especially if segments shift slightly.
        if let existing = all.first(where: { midTime >= $0.startTime && midTime <= $0.endTime }) {
            // Update the existing record's bounds to match the current segment for better future matching
            existing.startTime = startTime
            existing.endTime = endTime
            return existing
        }
        
        let newSelection = TransportManualSelection(startTime: startTime, endTime: endTime)
        modelContext.insert(newSelection)
        return newSelection
    }
    
    private func saveLocationOverride(type: LocationType, name: String) {
        withAnimation(.spring(response: 0.3)) {
            if type == .start {
                localStartOverride = name
            } else {
                localEndOverride = name
            }
        }
        
        let selection = findOrCreateSelection()
        if type == .start {
            selection.startLocationOverride = name
        } else {
            selection.endLocationOverride = name
        }
        
        // Preserve current type
        selection.vehicleType = (localManualType ?? transport.manualType ?? transport.type).rawValue
        
        try? modelContext.save()
        onLocationUpdate?()
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
        
        // 2. Find or Create selection
        let selection = findOrCreateSelection()
        selection.vehicleType = type.rawValue
        
        try? modelContext.save()
        
        // 3. Notify parent to update UI
        onUpdate?(type)
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

extension TransportType {
    var localizedName: String {
        switch self {
        case .slow: return "步行"
        case .bicycle: return "自行车"
        case .motorcycle: return "摩托车/电动车"
        case .bus: return "公交/大巴"
        case .car: return "汽车"
        case .train: return "火车/高铁"
        case .airplane: return "飞机"
        }
    }
}
