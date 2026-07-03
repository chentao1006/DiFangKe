import WidgetKit
import SwiftUI
import MapKit
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - App Intent for Manual Refresh
public struct RefreshWidgetIntent: AppIntent {
    public static var title: LocalizedStringResource = "刷新足迹小组件"
    public static var description = IntentDescription("重新加载今日足迹数据。")

    public init() {}

    public func perform() async throws -> some IntentResult {
        let groupID = "group.com.ct106.difangke"
        let defaults = UserDefaults(suiteName: groupID)
        defaults?.removeObject(forKey: "widgetDateOffset")

        let count = defaults?.integer(forKey: "widgetRefreshCount") ?? 0
        defaults?.set(count + 1, forKey: "widgetRefreshCount")
        defaults?.synchronize()

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

public struct SetOffsetIntent: AppIntent {
    public static var title: LocalizedStringResource = "设置日期偏移"

    @Parameter(title: "Offset")
    public var offset: Int

    public init() {}
    public init(offset: Int) {
        self.offset = offset
    }

    public func perform() async throws -> some IntentResult {
        let groupID = "group.com.ct106.difangke"
        let defaults = UserDefaults(suiteName: groupID)

        var targetOffset = offset
        if targetOffset > 0 { targetOffset = 0 }

        if targetOffset == 0 {
            defaults?.removeObject(forKey: "widgetDateOffset")
        } else {
            defaults?.set(targetOffset, forKey: "widgetDateOffset")
        }

        let count = defaults?.integer(forKey: "widgetRefreshCount") ?? 0
        defaults?.set(count + 1, forKey: "widgetRefreshCount")
        defaults?.synchronize()

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct DFKFootprintEntry: TimelineEntry {
    let date: Date
    let mapImageLight: UIImage?
    let mapImageDark: UIImage?
    let footprintCount: Int
    let displayTitle: String
    let targetDate: Date
    let isToday: Bool
    let dateOffset: Int
    let debugInfo: String
}

struct DFKFootprintProvider: TimelineProvider {
    let groupID = "group.com.ct106.difangke"
    // Must match WidgetDataSyncManager.snapshotFileVersion in the main app.
    // A mismatch makes the widget keep reading an old, still-present snapshot.
    private let snapshotFileVersion = "v11"

    private func loadSnapshotImage(containerURL: URL, sizeName: String, themeName: String, offset: Int) -> UIImage? {
        let candidateNames = [
            "widget_snapshot_\(sizeName)_\(themeName)_\(offset)_\(snapshotFileVersion).jpg"
        ]

        for fileName in candidateNames {
            let fileURL = containerURL.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                return image
            }
        }

        return nil
    }

    func placeholder(in context: Context) -> DFKFootprintEntry {
        DFKFootprintEntry(date: Date(), mapImageLight: nil, mapImageDark: nil, footprintCount: 0, displayTitle: "今日足迹", targetDate: Date(), isToday: true, dateOffset: 0, debugInfo: "Loading")
    }
    func getSnapshot(in context: Context, completion: @escaping (DFKFootprintEntry) -> ()) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DFKFootprintEntry>) -> ()) {
        let now = Date()
        let calendar = Calendar.current
        let defaults = UserDefaults(suiteName: groupID)
        let offset = (defaults?.value(forKey: "widgetDateOffset") as? Int) ?? 0
        let refreshCount = defaults?.integer(forKey: "widgetRefreshCount") ?? 0
        let isToday = (offset == 0)

        let startOfToday = calendar.startOfDay(for: now)
        let targetDate = calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday

        // 标题
        let displayTitle: String
        if isToday { displayTitle = "今日足迹" }
        else if calendar.isDateInYesterday(targetDate) { displayTitle = "昨日足迹" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            displayTitle = formatter.string(from: targetDate)
        }

        // 读取 App 预生成的图片和数据
        var finalImageLight: UIImage? = nil
        var finalImageDark: UIImage? = nil
        var footprintCount = 0
        var status = "NoSync"
        var lastSyncStr = "Never"

        // 根据小组件类型选择对应的图片
        let sizeName: String = {
            switch context.family {
            case .systemSmall: return "small"
            case .systemMedium: return "medium"
            case .systemLarge: return "large"
            default: return "small"
            }
        }()

        // 尝试从共享目录读取图片 (光色和暗色)
        let manager = FileManager.default
        if let containerURL = manager.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            finalImageLight = loadSnapshotImage(
                containerURL: containerURL,
                sizeName: sizeName,
                themeName: "light",
                offset: offset
            )
            if finalImageLight != nil {
                status = "Synced"
            }

            finalImageDark = loadSnapshotImage(
                containerURL: containerURL,
                sizeName: sizeName,
                themeName: "dark",
                offset: offset
            )
            if finalImageDark != nil {
                status = "Synced"
            }

            if status == "Synced" {
                let lastSync = defaults?.double(forKey: "widgetUpdate_\(offset)") ?? 0
                if lastSync > 0 {
                    let syncDate = Date(timeIntervalSince1970: lastSync)
                    let df = DateFormatter()
                    df.dateFormat = "HH:mm"
                    lastSyncStr = df.string(from: syncDate)
                }
            } else {
                status = "NoFile"
            }
        }
        footprintCount = defaults?.integer(forKey: "widgetCount_\(offset)") ?? 0

        if offset < -6 {
            status = "Hist"
        }

        let entry = DFKFootprintEntry(
            date: now,
            mapImageLight: finalImageLight,
            mapImageDark: finalImageDark,
            footprintCount: footprintCount,
            displayTitle: displayTitle,
            targetDate: targetDate,
            isToday: isToday,
            dateOffset: offset,
            debugInfo: "\(status) S:\(lastSyncStr) C:\(refreshCount)"
        )

        let timeline = Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900)))
        completion(timeline)
    }
}

struct DFKFootprintWidgetView: View {
    var entry: DFKFootprintEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let isSmall = family == .systemSmall
        let mainColor: Color = colorScheme == .dark ? .white : Color("AccentColor")
        let mapImage = colorScheme == .dark ? (entry.mapImageDark ?? entry.mapImageLight) : entry.mapImageLight

        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                if let image = mapImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ZStack {
                        Color.blue.opacity(0.05)
                        if entry.debugInfo.contains("Hist") {
                            Text("请在 App 中查看往日足迹")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            // 顶部信息栏
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(size: isSmall ? 13 : 15, weight: .bold, design: .rounded))
                    .foregroundColor(mainColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(10)

            // 导航按钮
            VStack {
                Spacer()
                HStack {
                    // 左侧：往日 (最多支持到 -6，即 7 天内)
                    if entry.dateOffset > -6 {
                        Button(intent: SetOffsetIntent(offset: entry.dateOffset - 1)) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: isSmall ? 10 : 12, weight: .bold))
                                .foregroundColor(mainColor)
                                .frame(width: isSmall ? 28 : 32, height: isSmall ? 28 : 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if !entry.isToday {
                        Button(intent: SetOffsetIntent(offset: entry.dateOffset + 1)) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: isSmall ? 10 : 12, weight: .bold))
                                .foregroundColor(mainColor)
                                .frame(width: isSmall ? 28 : 32, height: isSmall ? 28 : 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(intent: RefreshWidgetIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(mainColor)
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .widgetURL(URL(string: "difangke://timeline?offset=\(entry.dateOffset)"))
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

#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct TripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            // Lock screen / Banner UI
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: context.state.icon)
                        .foregroundColor(.blue)
                        .font(.title2)
                    (Text("下一站 ").font(.subheadline).foregroundColor(.secondary) + Text(context.state.placeName).font(.headline).bold())
                        .lineLimit(1)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("距离")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatDistance(context.state.currentDistance))
                            .font(.title3)
                            .bold()
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("计划到达")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if context.state.hasArrivalTime {
                            Text(context.state.arrivalDate, style: .time)
                                .font(.title3)
                                .bold()
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("今天")
                                .font(.title3)
                                .bold()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                // --- Action Buttons ---
                HStack(spacing: 12) {
                    if context.state.currentDistance < 500 {
                        Link(destination: URL(string: "difangke://trip/action?type=arrive&id=\(context.attributes.tripId)")!) {
                            Text("已到达")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        if !context.state.isOrdered && Date() > context.state.arrivalDate {
                            Link(destination: URL(string: "difangke://trip/action?type=delay&id=\(context.attributes.tripId)")!) {
                                Text("推迟")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }

                        Link(destination: URL(string: "difangke://trip/action?type=abandon&id=\(context.attributes.tripId)")!) {
                            Text("放弃")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    } else {
                        let actionType = context.state.shouldOfferCompletion ? "complete" : "navigate"
                        Link(destination: URL(string: "difangke://trip/action?type=\(actionType)&id=\(context.attributes.tripId)")!) {
                            Text(context.state.shouldOfferCompletion ? "已完成" : "导航")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        if !context.state.isOrdered && Date() > context.state.arrivalDate {
                            Link(destination: URL(string: "difangke://trip/action?type=delay&id=\(context.attributes.tripId)")!) {
                                Text("推迟")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }

                            Link(destination: URL(string: "difangke://trip/action?type=abandon&id=\(context.attributes.tripId)")!) {
                                Text("放弃")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding()
            .background {
                TripMapImageView(tripId: context.attributes.tripId, latitude: context.state.latitude, longitude: context.state.longitude)
                    .opacity(0.4)
            }
            .widgetURL(URL(string: "difangke://trip/detail?id=\(context.attributes.tripId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Image(systemName: context.state.icon)
                            .foregroundColor(.blue)
                    }
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Empty
                }
                DynamicIslandExpandedRegion(.center) {
                    // Empty
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        (Text("下一站 ").font(.subheadline).foregroundColor(.secondary) + Text(context.state.placeName).font(.headline).bold())
                            .lineLimit(2)
                            .padding(.horizontal, 8)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("距离")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatDistance(context.state.currentDistance))
                                .font(.subheadline.bold())

                            Spacer()

                            Text("计划到达")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if context.state.hasArrivalTime {
                                Text(context.state.arrivalDate, style: .time)
                                    .font(.subheadline.bold())
                            } else {
                                Text("今天")
                                    .font(.subheadline.bold())
                            }
                        }
                        .padding(.horizontal, 8)

                        HStack(spacing: 12) {
                            if context.state.currentDistance < 500 {
                                Link(destination: URL(string: "difangke://trip/action?type=arrive&id=\(context.attributes.tripId)")!) {
                                    Text("已到达")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }

                                if !context.state.isOrdered && Date() > context.state.arrivalDate {
                                    Link(destination: URL(string: "difangke://trip/action?type=delay&id=\(context.attributes.tripId)")!) {
                                        Text("推迟")
                                            .font(.subheadline.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(Color.orange)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                    }
                                }

                                Link(destination: URL(string: "difangke://trip/action?type=abandon&id=\(context.attributes.tripId)")!) {
                                    Text("放弃")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(Color.red)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            } else {
                                let actionType = context.state.shouldOfferCompletion ? "complete" : "navigate"
                                Link(destination: URL(string: "difangke://trip/action?type=\(actionType)&id=\(context.attributes.tripId)")!) {
                                    Text(context.state.shouldOfferCompletion ? "已完成" : "导航")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }

                                if !context.state.isOrdered && Date() > context.state.arrivalDate {
                                    Link(destination: URL(string: "difangke://trip/action?type=delay&id=\(context.attributes.tripId)")!) {
                                        Text("推迟")
                                            .font(.subheadline.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(Color.orange)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                    }

                                    Link(destination: URL(string: "difangke://trip/action?type=abandon&id=\(context.attributes.tripId)")!) {
                                        Text("放弃")
                                            .font(.subheadline.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(Color.red)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: context.state.icon)
                    .foregroundColor(.blue)
            } compactTrailing: {
                Text(String(format: "%.1fkm", context.state.currentDistance / 1000))
                    .font(.caption.bold())
            } minimal: {
                Image(systemName: context.state.icon)
                    .foregroundColor(.blue)
            }
            .widgetURL(URL(string: "difangke://trip/detail?id=\(context.attributes.tripId)"))
        }
    }

    func formatDistance(_ distance: Double) -> String {
        if distance < 1000 {
            return String(format: "%.0f米", distance)
        } else {
            return String(format: "%.1f公里", distance / 1000)
        }
    }
}

struct TripMapImageView: View {
    let tripId: String
    let latitude: Double
    let longitude: Double
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ct106.difangke") {
            let suffix = colorScheme == .dark ? "dark" : "light"
            let latStr = String(format: "%.3f", latitude)
            let lonStr = String(format: "%.3f", longitude)
            let hashStr = "\(latStr)_\(lonStr)"
            let url = container.appendingPathComponent("trip_\(tripId)_\(hashStr)_\(suffix).png")
            if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        } else {
            Color.clear
        }
    }
}
#endif
