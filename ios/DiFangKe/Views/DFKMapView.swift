import SwiftUI
import MapKit
import SwiftData
import Photos

/// DiFangKe 统一地图组件，用于确保全应用地图表现一致
struct DFKMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    var isInteractive: Bool = false
    var showsUserLocation: Bool = true
    var points: [CLLocationCoordinate2D] = []
    var mainAnnotationCoordinate: CLLocationCoordinate2D? = nil
    var mainAnnotationTitle: String? = nil
    var timelineItems: [TimelineItem] = []
    var photoAssets: [PHAsset] = []
    
    // 热力图支持 (用于统计视图)
    struct HeatmapPoint: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let intensity: Int
        let maxIntensity: Int
    }
    var heatmapPoints: [HeatmapPoint] = []
    
    var onTimelineItemTap: ((TimelineItem) -> Void)? = nil
    var onPhotoTap: ((PHAsset) -> Void)? = nil
    
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    
    var body: some View {
        Map(position: $cameraPosition, interactionModes: isInteractive ? .all : []) {
            if showsUserLocation {
                UserAnnotation()
            }
            
            // 1. 轨迹线系统 (已修改为仅显示交通段路线，隐藏原始 GPS 噪点线)
            ForEach(timelineItems) { item in
                if case .transport(let transport) = item {
                    // 背景边框
                    MapPolyline(coordinates: transport.points)
                        .stroke(Color(uiColor: .systemBackground), style: StrokeStyle(lineWidth: (isInteractive ? 5 : 3) + 2.5, lineCap: .round, lineJoin: .round))
                    
                    // 交通轨迹线
                    MapPolyline(coordinates: transport.points)
                        .stroke(Color.dfkAccent, style: StrokeStyle(lineWidth: isInteractive ? 5 : 3, lineCap: .round, lineJoin: .round))
                }
            }
            
            if let mainCoord = mainAnnotationCoordinate {
                Marker("", coordinate: mainCoord)
                    .tint(Color.dfkAccent)
            }
            
            // 重要地点呈现
            ForEach(allPlaces.filter { $0.isUserDefined }) { place in
                MapCircle(center: place.coordinate, radius: Double(place.radius))
                    .foregroundStyle(Color.orange.opacity(0.1))
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            }
            
            // 每一个 TimelineItem 在地图上的标注 (放在最后以确保在顶层显示)
            ForEach(timelineItems) { item in
                if case .footprint(let fp) = item {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)) {
                        let scale = calculateScale(for: fp.duration)
                        let baseSize: CGFloat = 28
                        let size = baseSize * scale
                        
                        let footprintIcon = ZStack {
                            let activity = fp.getActivityType(from: allActivities)
                            let activityColor = activity?.color ?? Color.secondary.opacity(0.5)
                            
                            Circle()
                                .fill(activityColor)
                                .frame(width: size, height: size)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5 * scale))
                            
                            Image(systemName: activity?.icon ?? "questionmark.circle.dashed")
                                .font(.system(size: (activity?.icon == nil ? 18 : 13) * scale, weight: .bold))
                                .foregroundColor(Color(uiColor: .systemBackground))
                        }
                        .contentShape(Circle())
                        
                        Group {
                            if let onTimelineItemTap {
                                footprintIcon.onTapGesture { onTimelineItemTap(.footprint(fp)) }
                            } else {
                                footprintIcon
                            }
                        }
                    }
                } else if case .transport(let transport) = item {
                    // 获取更精确的中点：优先从主轨迹线中截取属于该交通段的子路段来计算中点
                    // 这样可以确保图标既在“路线上”，又处于“路程的中心”
                    let finalPoint: CLLocationCoordinate2D? = {
                        if !points.isEmpty, let start = transport.points.first, let end = transport.points.last {
                            let sub = points.subpath(from: start, to: end)
                            if sub.count >= 2 { return sub.distanceMidpoint }
                        }
                        return transport.points.distanceMidpoint
                    }()

                    if let coord = finalPoint {
                        Annotation("", coordinate: coord) {
                            let transportIcon = ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.dfkAccent)
                                    .frame(width: 20, height: 20)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .systemBackground), lineWidth: 1.2))
                                
                                Image(systemName: transport.currentType.sfSymbol)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(uiColor: .systemBackground))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            
                            Group {
                                if let onTimelineItemTap {
                                    transportIcon.onTapGesture { onTimelineItemTap(.transport(transport)) }
                                } else {
                                    transportIcon
                                }
                            }
                        }
                    }
                }
            }
            
            // 照片标注 (用真正在该地拍摄的照片做图标)
            ForEach(photoAssets, id: \.localIdentifier) { asset in
                if let coord = asset.location?.gcj02.coordinate {
                    Annotation("", coordinate: coord) {
                        let content = AssetThumbnailView(assetID: asset.localIdentifier)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                            .contentShape(Rectangle())
                        
                        // IMPORTANT: Only attach gesture if handler exists.
                        // If nil, touch passes through to Map, then to Card.
                        Group {
                            if let onPhotoTap {
                                content.onTapGesture { onPhotoTap(asset) }
                            } else {
                                content
                            }
                        }
                    }
                }
            }
            
            // 统计热力图点
            ForEach(heatmapPoints) { point in
                Annotation("", coordinate: point.coordinate) {
                    // 使用非线性缩放（如平方根或更低幂次），使热力图颜色分布更均匀。
                    // 解决因个别极高频地点（如家）导致其他所有地点都落在 0.2 以下变为橙色的问题。
                    let rawRatio = Double(point.intensity) / Double(max(1, point.maxIntensity))
                    let ratio = pow(rawRatio, 0.4) // 使用 0.4 次幂显著提升低频点权重
                    
                    let color: Color = {
                        if point.maxIntensity <= 1 {
                            return .orange
                        } else if ratio < 0.25 {
                            return .orange
                        } else if ratio < 0.85 {
                            return .red
                        } else {
                            return .dfkDeepRed
                        }
                    }()
                    
                    // 大地图模式下圆圈变大
                    let baseSize: CGFloat = isInteractive ? 24 : 14
                    let multiplier: CGFloat = isInteractive ? 6 : 3
                    let maxSize: CGFloat = isInteractive ? 60 : 30
                    let size = CGFloat(max(baseSize, min(maxSize, CGFloat(point.intensity) * multiplier)))
                    
                    Circle()
                        .fill(color.opacity(0.7).gradient)
                        .frame(width: size, height: size)
                        .blur(radius: size * 0.1)
                }
            }
        }
        .mapControls {
            if isInteractive {
                MapUserLocationButton()
                MapCompass()
                MapPitchToggle()
            }
        }
        .mapStyle(.standard)
    }

    private func calculateScale(for duration: TimeInterval) -> CGFloat {
        let minutes = duration / 60
        if minutes < 15 { return 0.8 }
        if minutes < 60 { return 1.0 }
        if minutes < 180 { return 1.15 }
        if minutes < 480 { return 1.25 }
        return 1.35
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// 计算包含所有坐标点的最佳矩形区域
    func boundingRegion(paddingFactor: Double = 1.3) -> MKCoordinateRegion? {
        guard !isEmpty else { return nil }
        
        var minLat = self[0].latitude
        var maxLat = self[0].latitude
        var minLon = self[0].longitude
        var maxLon = self[0].longitude
        
        for p in self {
            minLat = Swift.min(minLat, p.latitude)
            maxLat = Swift.max(maxLat, p.latitude)
            minLon = Swift.min(minLon, p.longitude)
            maxLon = Swift.max(maxLon, p.longitude)
        }
        
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        
        // 计算跨度并增加外边距
        let latDelta = (maxLat - minLat) * paddingFactor
        let lonDelta = (maxLon - minLon) * paddingFactor
        
        // 确保跨度不为0 (比如只有一个点的情况)
        let finalLatDelta = Swift.max(latDelta, 0.005) // 约 500m
        let finalLonDelta = Swift.max(lonDelta, 0.005)
        
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: finalLatDelta, longitudeDelta: finalLonDelta)
        )
    }
    
    /// 计算基于地理距离的中点，确保图标在路径的长度中点
    var distanceMidpoint: CLLocationCoordinate2D? {
        guard count >= 2 else { return first }
        
        // 1. 计算总距离和各段累计距离
        var totalDistance: Double = 0
        var segmentDistances: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDistance += d
            segmentDistances.append(totalDistance)
        }
        
        if totalDistance == 0 { return self[count / 2] }
        
        // 2. 找到距离上的中点
        let midDistance = totalDistance / 2
        
        for i in 0..<count-1 {
            if midDistance >= segmentDistances[i] && midDistance <= segmentDistances[i+1] {
                // 在这一段内进行插值
                let distInSegment = midDistance - segmentDistances[i]
                let segmentTotalDist = segmentDistances[i+1] - segmentDistances[i]
                let fraction = segmentTotalDist > 0 ? distInSegment / segmentTotalDist : 0
                
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * fraction,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * fraction
                )
            }
        }
        return self[count / 2]
    }
    
    /// 寻找给定坐标点在该数组中距离最近的元素索引
    func indexOfClosestPoint(to target: CLLocationCoordinate2D) -> Int {
        var minDistanceSq = Double.infinity
        var index = 0
        for (i, p) in enumerated() {
            let dLat = p.latitude - target.latitude
            let dLon = p.longitude - target.longitude
            let distSq = dLat * dLat + dLon * dLon
            if distSq < minDistanceSq {
                minDistanceSq = distSq
                index = i
            }
        }
        return index
    }
    
    /// 从当前轨迹中截取从 start 点到 end 点对应的子路段
    func subpath(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard count >= 2 else { return [] }
        let startIndex = self.indexOfClosestPoint(to: start)
        let endIndex = self.indexOfClosestPoint(to: end)
        
        let lower = Swift.min(startIndex, endIndex)
        let upper = Swift.max(startIndex, endIndex)
        
        guard upper - lower >= 1 else { return [] }
        return Array(self[lower...upper])
    }
}
