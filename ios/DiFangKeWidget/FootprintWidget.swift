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
    private let snapshotFileVersion = "v14"

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
@available(iOS 18.0, *)
struct TripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLiveActivityContent(context: context)
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
                            Text(formatTripDistance(context.state.currentDistance))
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
        .supplementalActivityFamilies([.small])
    }
}

@available(iOS 16.1, *)
private struct TripLiveActivityContent: View {
    let context: ActivityViewContext<TripActivityAttributes>

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *) {
            TripLiveActivityAdaptiveContent(context: context)
        } else {
            TripLiveActivityLockScreenContent(context: context)
        }
    }
}

@available(iOS 18.0, *)
private struct TripLiveActivityAdaptiveContent: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<TripActivityAttributes>

    @ViewBuilder
    var body: some View {
        switch activityFamily {
        case .small:
            // The Watch Smart Stack is intentionally glanceable: name first,
            // then the two details that matter while travelling.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: context.state.icon)
                        .foregroundColor(.blue)
                    Text(context.state.placeName)
                        .font(.headline)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text("距离 \(formatTripDistance(context.state.currentDistance))")
                    if context.state.hasArrivalTime {
                        Text("·")
                        Text(context.state.arrivalDate, style: .time)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .widgetURL(URL(string: "difangke://trip/detail?id=\(context.attributes.tripId)"))
        case .medium:
            TripLiveActivityLockScreenContent(context: context)
        @unknown default:
            TripLiveActivityLockScreenContent(context: context)
        }
    }
}

@available(iOS 16.1, *)
private struct TripLiveActivityLockScreenContent: View {
    let context: ActivityViewContext<TripActivityAttributes>

    var body: some View {
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
                        Text(formatTripDistance(context.state.currentDistance))
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
        }
    }

private func formatTripDistance(_ distance: Double) -> String {
    if distance < 1000 {
        return String(format: "%.0f米", distance)
    } else {
        return String(format: "%.1f公里", distance / 1000)
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

@available(iOS 16.1, *)
struct CurrentTrackingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CurrentTrackingActivityAttributes.self) { context in
            CurrentTrackingLockScreenContent(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.icon)
                            .foregroundStyle(currentActivityColor(context.state.colorHex))
                        Text(context.state.title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CurrentActivityDuration(startedAt: context.state.startedAt, compact: false)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CurrentTrackingIslandBottomContent(context: context)
                }
            } compactLeading: {
                Image(systemName: context.state.icon)
                    .foregroundStyle(currentActivityColor(context.state.colorHex))
            } compactTrailing: {
                CurrentActivityDuration(startedAt: context.state.startedAt, compact: true)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.icon)
                    .foregroundStyle(currentActivityColor(context.state.colorHex))
            }
            .keylineTint(currentActivityColor(context.state.colorHex))
            .widgetURL(currentActivityDetailURL(for: context.state))
        }
    }
}

@available(iOS 16.1, *)
private struct CurrentTrackingLockScreenContent: View {
    let context: ActivityViewContext<CurrentTrackingActivityAttributes>

    private var state: CurrentTrackingActivityAttributes.ContentState { context.state }
    private var accent: Color { currentActivityColor(state.colorHex) }
    private var usesDarkMap: Bool { state.prefersDarkMap ?? false }
    private var primaryForeground: Color { usesDarkMap ? .white : .black }
    private var secondaryForeground: Color { primaryForeground.opacity(0.72) }
    private let contentHeight: CGFloat = 120

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                CurrentActivityMapImage(
                    sessionID: context.attributes.sessionID,
                    revision: state.mapRevision,
                    prefersDarkMap: state.prefersDarkMap ?? false
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: usesDarkMap
                            ? [.black.opacity(0.18), .clear, .black.opacity(0.28)]
                            : [.white.opacity(0.36), .clear, .white.opacity(0.46)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            VStack(spacing: state.kind == .transport ? 5 : 8) {
                HStack(spacing: 7) {
                    Image(systemName: state.icon)
                        .foregroundStyle(accent)
                        .font(.headline)
                    Text(state.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    CurrentActivityDuration(startedAt: state.startedAt, compact: false)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if state.kind == .transport {
                    CurrentTransportProgress(
                        start: state.startLocation ?? "起点",
                        accent: accent,
                        onDarkMap: usesDarkMap,
                        compact: true
                    )

                    HStack(alignment: .firstTextBaseline) {
                        CurrentMetric(
                            title: "里程",
                            value: formatCurrentDistance(state.distance),
                            onDarkMap: usesDarkMap
                        )
                        Spacer()
                        CurrentMetric(
                            title: "均速",
                            value: formatCurrentSpeed(state.averageSpeed),
                            onDarkMap: usesDarkMap
                        )
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.placeName)
                                    .font(.title3.bold())
                                    .lineLimit(1)
                                if let address = state.address, !address.isEmpty {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(secondaryForeground)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if state.photoThumbnailCount > 0 {
                                CurrentActivityPhotoStack(
                                    sessionID: context.attributes.sessionID,
                                    revision: state.photoRevision,
                                    thumbnailCount: state.photoThumbnailCount,
                                    totalCount: state.photoCount
                                )
                            }
                        }
                        CurrentFootprintTodaySummary(
                            placeCount: state.todayPlaceCount,
                            distance: state.todayDistance,
                            foreground: secondaryForeground
                        )
                    }
                }
            }
            .foregroundStyle(primaryForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, state.kind == .transport ? 6 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .top)
        .clipped()
        .widgetURL(currentActivityDetailURL(for: state))
    }
}

@available(iOS 16.1, *)
private struct CurrentTrackingIslandBottomContent: View {
    let context: ActivityViewContext<CurrentTrackingActivityAttributes>

    private var state: CurrentTrackingActivityAttributes.ContentState { context.state }
    private var accent: Color { currentActivityColor(state.colorHex) }
    private var mapHeight: CGFloat { state.kind == .transport ? 108 : 94 }

    var body: some View {
        VStack(spacing: 6) {
            CurrentActivityMapImage(
                sessionID: context.attributes.sessionID,
                revision: state.mapRevision,
                prefersDarkMap: true
            )
            .frame(maxWidth: .infinity, minHeight: mapHeight, maxHeight: mapHeight)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.16), .clear, .black.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .topLeading) {
                if state.kind == .footprint {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.placeName)
                            .font(.title3.bold())
                            .lineLimit(1)
                        if let address = state.address, !address.isEmpty {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.top, 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if state.kind == .footprint, state.photoThumbnailCount > 0 {
                    CurrentActivityPhotoStack(
                        sessionID: context.attributes.sessionID,
                        revision: state.photoRevision,
                        thumbnailCount: state.photoThumbnailCount,
                        totalCount: state.photoCount
                    )
                    .padding(.trailing, 8)
                    .padding(.top, 6)
                }
            }
            .overlay(alignment: .top) {
                if state.kind == .transport {
                    CurrentTransportProgress(
                        start: state.startLocation ?? "起点",
                        accent: accent,
                        onDarkMap: true
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 20)
                }
            }
            .overlay(alignment: .bottom) {
                if state.kind == .transport {
                    HStack(alignment: .firstTextBaseline) {
                        CurrentMetric(
                            title: "里程",
                            value: formatCurrentDistance(state.distance),
                            onDarkMap: true
                        )
                        Spacer()
                        CurrentMetric(
                            title: "均速",
                            value: formatCurrentSpeed(state.averageSpeed),
                            onDarkMap: true
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                } else {
                    CurrentFootprintTodaySummary(
                        placeCount: state.todayPlaceCount,
                        distance: state.todayDistance,
                        foreground: .white.opacity(0.78)
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 0)
        .padding(.top, 0)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .top)
        .widgetURL(currentActivityDetailURL(for: state))
    }
}

private struct CurrentFootprintTodaySummary: View {
    let placeCount: Int?
    let distance: Double?
    let foreground: Color

    var body: some View {
        if let placeCount, let distance {
            HStack(spacing: 8) {
                Text("今日停留 \(placeCount) 个地点")
                Spacer(minLength: 8)
                Text("今日里程 \(formatCurrentTodayDistance(distance))")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

private struct CurrentActivityPhotoStack: View {
    let sessionID: String
    let revision: Int
    let thumbnailCount: Int
    let totalCount: Int

    private var visibleCount: Int { min(3, thumbnailCount) }
    private var stackWidth: CGFloat { 34 + CGFloat(max(0, visibleCount - 1)) * 21 }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    if let image = currentActivityPhotoImage(
                        sessionID: sessionID,
                        revision: revision,
                        index: index
                    ) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(.white.opacity(0.9), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                            .rotationEffect(.degrees(Double(index - 1) * 3.5))
                            .offset(x: CGFloat(index) * 21)
                            .zIndex(Double(index))
                    }
                }
            }
            .frame(width: stackWidth, height: 36, alignment: .leading)

            if totalCount > visibleCount {
                Text("+\(totalCount - visibleCount)")
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.48), in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(totalCount) 张照片")
    }
}

@available(iOS 16.1, *)
private struct CurrentTransportProgress: View {
    let start: String
    let accent: Color
    let onDarkMap: Bool
    var compact = false

    private var foreground: Color { onDarkMap ? .white : .black }

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            GeometryReader { proxy in
                let leadingX: CGFloat = 7
                let currentX = proxy.size.width / 2
                let trailingX = proxy.size.width - 7
                ZStack(alignment: .leading) {
                    Path { path in
                        path.move(to: CGPoint(x: leadingX, y: 8))
                        path.addLine(to: CGPoint(x: trailingX, y: 8))
                    }
                    .stroke(foreground.opacity(0.34), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    Path { path in
                        path.move(to: CGPoint(x: leadingX, y: 8))
                        path.addLine(to: CGPoint(x: currentX, y: 8))
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    Circle().fill(accent).frame(width: 12, height: 12).position(x: leadingX, y: 8)
                    Circle().fill(accent).overlay(Circle().stroke(foreground, lineWidth: 2))
                        .frame(width: 16, height: 16).position(x: currentX, y: 8)
                    Circle().fill(foreground.opacity(0.18)).overlay(Circle().stroke(foreground.opacity(0.75), lineWidth: 2))
                        .frame(width: 12, height: 12).position(x: trailingX, y: 8)
                }
            }
            .frame(height: 16)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(start).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                Color.clear.frame(maxWidth: .infinity, minHeight: 1)
            }
            .font(.caption)
            .foregroundStyle(foreground)
        }
    }
}

private struct CurrentMetric: View {
    let title: String
    let value: String
    let onDarkMap: Bool

    private var foreground: Color { onDarkMap ? .white : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(foreground.opacity(0.68))
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
        .foregroundStyle(foreground)
    }
}

private struct CurrentActivityDuration: View {
    let startedAt: Date
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: nextMinuteBoundary, by: 60)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(compact
                 ? currentActivityCompactDurationText(elapsed)
                 : currentActivityDurationText(elapsed))
        }
    }

    private var nextMinuteBoundary: Date {
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let completedMinutes = floor(elapsed / 60)
        return startedAt.addingTimeInterval((completedMinutes + 1) * 60)
    }
}

/// Matches the duration shown inside the Watch circular complication.
private func currentActivityCompactDurationText(_ elapsed: Int) -> String {
    let minutes = max(0, elapsed / 60)
    if minutes < 60 {
        return "\(max(1, minutes))分钟"
    }

    let hours = Double(minutes) / 60
    if hours >= 10 {
        return "\(Int(hours.rounded()))小时"
    }
    return "\(String(format: "%g", (hours * 10).rounded() / 10))小时"
}

private func currentActivityDurationText(_ elapsed: Int) -> String {
    let totalMinutes = elapsed / 60
    if totalMinutes >= 1_440 {
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
    }
    if totalMinutes >= 60 {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
    }
    return "\(max(1, totalMinutes)) 分钟"
}

private struct CurrentActivityMapImage: View {
    let sessionID: String
    let revision: Int
    let prefersDarkMap: Bool

    var body: some View {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ct106.difangke"
        ) {
            let preferredSuffixes = prefersDarkMap
                ? ["dark", "light"]
                : ["light", "dark"]
            if let url = preferredSuffixes.lazy.compactMap({ suffix in
                currentActivityMapURL(
                    container: container,
                    sessionID: sessionID,
                    revision: revision,
                    suffix: suffix
                )
            }).first,
               let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image)
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

private func currentActivityMapURL(
    container: URL,
    sessionID: String,
    revision: Int,
    suffix: String
) -> URL? {
    let exactURL = container.appendingPathComponent(
        "current_activity_\(sessionID)_\(revision)_\(suffix).png"
    )
    if FileManager.default.fileExists(atPath: exactURL.path) {
        return exactURL
    }

    // A process restart can briefly restore an Activity state before the host
    // restores its in-memory revision. Reuse the newest snapshot for this same
    // Activity session instead of showing an empty background.
    let prefix = "current_activity_\(sessionID)_"
    let ending = "_\(suffix).png"
    return (try? FileManager.default.contentsOfDirectory(
        at: container,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ))?
    .filter {
        $0.lastPathComponent.hasPrefix(prefix)
            && $0.lastPathComponent.hasSuffix(ending)
            && !$0.lastPathComponent.contains("_photo_")
    }
    .max {
        let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return left < right
    }
}

private func currentActivityPhotoImage(
    sessionID: String,
    revision: Int,
    index: Int
) -> UIImage? {
    guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.ct106.difangke"
    ) else { return nil }
    let url = container.appendingPathComponent(
        "current_activity_\(sessionID)_photo_\(revision)_\(index).jpg"
    )
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
}

private func currentActivityColor(_ hex: String?) -> Color {
    guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return .teal
    }
    value = value.replacingOccurrences(of: "#", with: "")
    guard let number = UInt64(value, radix: 16), value.count == 6 else { return .teal }
    return Color(
        red: Double((number >> 16) & 0xff) / 255,
        green: Double((number >> 8) & 0xff) / 255,
        blue: Double(number & 0xff) / 255
    )
}

private func formatCurrentDistance(_ distance: Double?) -> String {
    guard let distance, distance > 0 else { return "—" }
    return distance < 1_000
        ? String(format: "%.0f 米", distance)
        : String(format: "%.1f 公里", distance / 1_000)
}

private func formatCurrentTodayDistance(_ distance: Double) -> String {
    let value = max(0, distance)
    return value < 1_000
        ? String(format: "%.0f 米", value)
        : String(format: "%.1f 公里", value / 1_000)
}

private func formatCurrentSpeed(_ speed: Double?) -> String {
    guard let speed, speed > 0 else { return "—" }
    return String(format: "%.0f km/h", speed * 3.6)
}

private func currentActivityDetailURL(
    for _: CurrentTrackingActivityAttributes.ContentState
) -> URL {
    URL(string: "difangke://timeline?offset=0")!
}
#endif
