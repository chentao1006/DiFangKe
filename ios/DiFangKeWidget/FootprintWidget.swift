import WidgetKit
import SwiftUI
import MapKit
import SwiftData

struct DFKFootprintEntry: TimelineEntry {
    let date: Date
    let mapImage: UIImage?
    let daySummary: String
}

struct DFKFootprintProvider: TimelineProvider {
    func placeholder(in context: Context) -> DFKFootprintEntry {
        DFKFootprintEntry(date: Date(), mapImage: nil, daySummary: "读取中...")
    }
    func getSnapshot(in context: Context, completion: @escaping (DFKFootprintEntry) -> ()) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DFKFootprintEntry>) -> ()) {
        Task { @MainActor in
            let groupID = AppConfig.shared.appGroupID
            let schema = Schema([Footprint.self, TransportRecord.self])
            let config = ModelConfiguration(groupContainer: .identifier(groupID))
            guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
                completion(Timeline(entries: [DFKFootprintEntry(date: Date(), mapImage: nil, daySummary: "配置错误")], policy: .atEnd))
                return
            }
            let footprints = (try? container.mainContext.fetch(FetchDescriptor<Footprint>())) ?? []
            let lastLat = UserDefaults(suiteName: groupID)?.double(forKey: "lastLat") ?? 39.9
            let lastLon = UserDefaults(suiteName: groupID)?.double(forKey: "lastLon") ?? 116.4
            
            // 核心：使用 context.displaySize 获取系统分配的精确尺寸
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lastLat, longitude: lastLon), span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
            options.size = context.displaySize
            options.scale = 2.0
            
            let snapshotter = MKMapSnapshotter(options: options)
            let snapshot = try? await snapshotter.start()
            
            let entry = DFKFootprintEntry(date: Date(), mapImage: snapshot?.image, daySummary: "今日: \(footprints.count) | 刷新: \(Date().description.suffix(13).prefix(8))")
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        }
    }
}

struct DFKFootprintWidgetView: View {
    var entry: DFKFootprintEntry
    var body: some View {
        ZStack(alignment: .topLeading) {
            // 背景地图：全屏铺满
            if let image = entry.mapImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.blue.opacity(0.05)
            }
            
            // 悬浮文字卡片
            VStack(alignment: .leading, spacing: 2) {
                Text("今日足迹")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.blue)
                Text(entry.daySummary)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding(10)
        }
        .widgetURL(URL(string: "difangke://home"))
        .containerBackground(.background, for: .widget)
    }
}

struct DFKFootprintWidget: Widget {
    let kind: String = "DFKFootprintWidget_Final_V2"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DFKFootprintProvider()) { entry in
            DFKFootprintWidgetView(entry: entry)
        }
        .configurationDisplayName("今日足迹")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
