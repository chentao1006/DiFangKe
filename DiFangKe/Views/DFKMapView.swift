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
            
            if !points.isEmpty {
                // 背景边框: 稍微粗一点，使用系统背景色
                MapPolyline(coordinates: points)
                    .stroke(Color(uiColor: .systemBackground), style: StrokeStyle(lineWidth: (isInteractive ? 5 : 3) + 2.5, lineCap: .round, lineJoin: .round))
                
                // 主轨迹线
                MapPolyline(coordinates: points)
                    .stroke(Color.dfkAccent, style: StrokeStyle(lineWidth: isInteractive ? 5 : 3, lineCap: .round, lineJoin: .round))
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
                switch item {
                case .footprint(let fp):
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude)) {
                        let scale = calculateScale(for: fp.duration)
                        let baseSize: CGFloat = 28
                        let size = baseSize * scale
                        
                        let footprintIcon = ZStack {
                            let activity = fp.getActivityType(from: allActivities)
                            let activityColor = activity?.color ?? .dfkAccent
                            
                            Circle()
                                .fill(activityColor)
                                .frame(width: size, height: size)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5 * scale))
                            
                            Image(systemName: activity?.icon ?? "mappin.and.ellipse")
                                .font(.system(size: 13 * scale, weight: .bold))
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
                case .transport(let transport):
                    if let midPoint = transport.points.distanceMidpoint {
                        Annotation("", coordinate: midPoint) {
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
                    let ratio = Double(point.intensity) / Double(max(1, point.maxIntensity))
                    let color: Color = ratio < 0.3 ? .orange : (ratio < 0.7 ? .red : .purple)
                    
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
}
