import Foundation
import SwiftUI
import SwiftData
import MapKit
import WidgetKit

@MainActor
final class WidgetDataSyncManager {
    static let shared = WidgetDataSyncManager()
    
    private let groupID = "group.com.ct106.difangke"
    private var container: ModelContainer?
    
    private init() {}
    
    /// 更新数据库容器
    func updateContainer(_ newContainer: ModelContainer) {
        self.container = newContainer
    }
    
    /// 同步过去 7 天的数据到小组件
    func syncAll() async {
        print("[WidgetSync] Starting sync for last 7 days...")
        ensureContainer()
        
        // 优先同步 0 (今天)，然后往回同步到 -6
        for offset in ((-6)...0).reversed() {
            await syncData(forOffset: offset)
        }
        
        WidgetCenter.shared.reloadAllTimelines()
        print("[WidgetSync] Sync complete.")
    }
    
    /// 仅同步今日数据 (用于位置更新等高频场景)
    func syncTodayOnly() async {
        ensureContainer()
        await syncData(forOffset: 0)
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    private func ensureContainer() {
        if container == nil {
            let schema = Schema([Footprint.self, Place.self, TransportRecord.self, TransportManualSelection.self, ActivityType.self, DailyInsight.self])
            let config = ModelConfiguration("dfk_v5_stable", schema: schema, groupContainer: .identifier(groupID))
            self.container = try? ModelContainer(for: schema, configurations: [config])
        }
    }
    
    private func syncData(forOffset offset: Int) async {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let targetDate = calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
        let startOfTargetDay = targetDate
        let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: startOfTargetDay) ?? startOfTargetDay.addingTimeInterval(86400)
        
        guard let container = self.container else { return }
        let context = container.mainContext
        
        do {
            // 1. 获取数据
            let descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate<Footprint> { 
                    $0.startTime < endOfTargetDay && $0.endTime >= startOfTargetDay && $0.statusValue != "ignored"
                }
            )
            let footprints = try context.fetch(descriptor)
            
            let transportDescriptor = FetchDescriptor<TransportRecord>(
                predicate: #Predicate<TransportRecord> {
                    $0.startTime < endOfTargetDay && $0.endTime >= startOfTargetDay && $0.statusRaw != "ignored"
                }
            )
            let transports = (try? context.fetch(transportDescriptor)) ?? []
            let allActivities = (try? context.fetch(FetchDescriptor<ActivityType>())) ?? []
            
            let defaults = UserDefaults(suiteName: groupID)
            let lastLat = defaults?.double(forKey: "lastLat") ?? 39.9042
            let lastLon = defaults?.double(forKey: "lastLon") ?? 116.4074
            
            // 2. 为不同尺寸和主题生成图片
            let sizes: [(name: String, size: CGSize)] = [
                ("small", CGSize(width: 155, height: 155)),
                ("medium", CGSize(width: 329, height: 155)),
                ("large", CGSize(width: 329, height: 345))
            ]
            let themes: [UIUserInterfaceStyle] = [.light, .dark]
            
            for s in sizes {
                for theme in themes {
                    let themeName = theme == .dark ? "dark" : "light"
                    
                    // 计算地图区域
                    let region: MKCoordinateRegion
                    let coords = footprints.map { $0.coordinates }.flatMap { $0 }
                    
                    if !coords.isEmpty {
                        var minLat = coords[0].latitude; var maxLat = coords[0].latitude
                        var minLon = coords[0].longitude; var maxLon = coords[0].longitude
                        for p in coords {
                            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
                            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
                        }
                        
                        let spanLat = max(0.005, (maxLat - minLat) * 1.6)
                        let spanLon = max(0.005, (maxLon - minLon) * 1.6)
                        let finalSpanLon = s.name == "medium" ? spanLon * 1.5 : spanLon
                        
                        region = MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: finalSpanLon)
                        )
                    } else {
                        region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lastLat, longitude: lastLon), span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
                    }
                    
                    let options = MKMapSnapshotter.Options()
                    options.region = region
                    options.size = s.size
                    options.scale = 2.0
                    options.traitCollection = UITraitCollection(userInterfaceStyle: theme)
                    
                    let snapshotter = MKMapSnapshotter(options: options)
                    if let snapshot = try? await snapshotter.start() {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 2.0
                        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
                        let image = renderer.image { ctx in
                            snapshot.image.draw(at: .zero)
                            
                            // 绘制路线
                            ctx.cgContext.setLineCap(.round)
                            ctx.cgContext.setLineJoin(.round)
                            let themeColor = UIColor(named: "AccentColor") ?? .systemTeal
                            let transportLineColor = themeColor.withAlphaComponent(0.8)
                            
                            for tr in transports {
                                if let decoded = try? JSONDecoder().decode([CodableCoordinate].self, from: tr.pointsData), !decoded.isEmpty {
                                    let clCoords = decoded.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                                    let points = clCoords.map { snapshot.point(for: $0) }
                                    
                                    if points.count >= 2 {
                                        ctx.cgContext.beginPath()
                                        ctx.cgContext.move(to: points[0])
                                        for i in 1..<points.count { ctx.cgContext.addLine(to: points[i]) }
                                        ctx.cgContext.setStrokeColor(transportLineColor.cgColor)
                                        ctx.cgContext.setLineWidth(4.0) // 尺寸调整，线稍微细一点
                                        ctx.cgContext.strokePath()
                                        
                                        if let midCoord = clCoords.widgetMidpoint {
                                            let midPoint = snapshot.point(for: midCoord)
                                            let iconSize: CGFloat = 20
                                            let rect = CGRect(x: midPoint.x - iconSize/2, y: midPoint.y - iconSize/2, width: iconSize, height: iconSize)
                                            
                                        let strokeColor = theme == .dark ? UIColor.black : UIColor.white
                                        
                                        // 背景框
                                        let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
                                        themeColor.setFill()
                                        path.fill()
                                        strokeColor.setStroke()
                                        path.lineWidth = 1.2
                                        path.stroke()
                                        
                                        // 图标
                                        let transportType = TransportType(rawValue: tr.manualTypeRaw ?? tr.typeRaw) ?? .slow
                                        if let iconImage = UIImage(systemName: transportType.sfSymbol) {
                                            let symbolSize: CGFloat = 12
                                            let symbolRect = CGRect(x: midPoint.x - symbolSize/2, y: midPoint.y - symbolSize/2, width: symbolSize, height: symbolSize)
                                            iconImage.withTintColor(strokeColor).draw(in: symbolRect)
                                        }
                                        }
                                    }
                                }
                            }
                            
                            // 绘制足迹
                            for fp in footprints {
                                let point = snapshot.point(for: CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
                                let activity = allActivities.first { $0.id.uuidString == fp.activityTypeValue || $0.name == fp.activityTypeValue }
                                let activityColor = UIColor(hex: activity?.colorHex ?? "#8E8E93") ?? .gray
                                let iconName = activity?.icon ?? "questionmark.circle.dashed"
                                
                                let hours = fp.duration / 3600.0
                                let dotScale: CGFloat = 1.0 + (1.5 - 1.0) * min(1.0, max(0.0, (hours - 0.5) / (12.0 - 0.5)))
                                let size = 28 * dotScale // 尺寸调整，适应小尺寸
                                
                                ctx.cgContext.setFillColor(activityColor.cgColor)
                                ctx.cgContext.addArc(center: point, radius: size/2, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                                ctx.cgContext.fillPath()
                                
                                let strokeColor = theme == .dark ? UIColor.black : UIColor.white
                                ctx.cgContext.setStrokeColor(strokeColor.cgColor)
                                ctx.cgContext.setLineWidth(1.5)
                                ctx.cgContext.addArc(center: point, radius: size/2, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                                ctx.cgContext.strokePath()
                                if let iconImage = UIImage(systemName: iconName) {
                                    let iconSize = (size * 0.55)
                                    let iconRect = CGRect(x: point.x - iconSize/2, y: point.y - iconSize/2, width: iconSize, height: iconSize)
                                    iconImage.withTintColor(strokeColor).draw(in: iconRect)
                                }
                            }
                        }
                        
                        // 保存图片
                        if let data = image.jpegData(compressionQuality: 0.8) {
                            let fileURL = getFileURL(forOffset: offset, sizeName: s.name, themeName: themeName)
                            try? data.write(to: fileURL)
                        }
                    }
                }
            }
            
            // 更新元数据
            defaults?.set(footprints.count, forKey: "widgetCount_\(offset)")
            defaults?.set(Date().timeIntervalSince1970, forKey: "widgetUpdate_\(offset)")
            defaults?.synchronize()
            
        } catch {
            print("[WidgetSync] Sync error for offset \(offset): \(error)")
        }
    }
    
    private func getFileURL(forOffset offset: Int, sizeName: String, themeName: String) -> URL {
        let manager = FileManager.default
        let containerURL = manager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let fileName = "widget_snapshot_\(sizeName)_\(themeName)_\(offset).jpg"
        return containerURL!.appendingPathComponent(fileName)
    }
}


// 辅助扩展
extension Array where Element == CLLocationCoordinate2D {
    var widgetMidpoint: CLLocationCoordinate2D? {
        guard !isEmpty else { return nil }
        if count == 1 { return first }
        
        var totalDist: Double = 0
        var segments: [Double] = [0]
        
        for i in 0..<count-1 {
            let p1 = CLLocation(latitude: self[i].latitude, longitude: self[i].longitude)
            let p2 = CLLocation(latitude: self[i+1].latitude, longitude: self[i+1].longitude)
            let d = p1.distance(from: p2)
            totalDist += d
            segments.append(totalDist)
        }
        
        if totalDist == 0 { return self[count/2] }
        let mid = totalDist / 2
        
        for i in 0..<count-1 {
            if mid >= segments[i] && mid <= segments[i+1] {
                let ratio = (mid - segments[i]) / (segments[i+1] - segments[i])
                return CLLocationCoordinate2D(
                    latitude: self[i].latitude + (self[i+1].latitude - self[i].latitude) * ratio,
                    longitude: self[i].longitude + (self[i+1].longitude - self[i].longitude) * ratio
                )
            }
        }
        return self[count/2]
    }
}

// 辅助方法：Hex 转 UIColor
extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

