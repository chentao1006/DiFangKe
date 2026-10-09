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
                        Image(systemName: currentTrackingIcon(context.state))
                            .foregroundStyle(currentTrackingAccent(context.state))
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
                Image(systemName: currentTrackingIcon(context.state))
                    .foregroundStyle(currentTrackingAccent(context.state))
            } compactTrailing: {
                CurrentActivityDuration(startedAt: context.state.startedAt, compact: true)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                CurrentTrackingMinimalIslandIcon(state: context.state)
            }
            .keylineTint(currentTrackingAccent(context.state))
            .widgetURL(currentActivityDetailURL(for: context.state))
        }
    }
}

@available(iOS 16.1, *)
private struct CurrentTrackingMinimalIslandIcon: View {
    let state: CurrentTrackingActivityAttributes.ContentState

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: currentTrackingIcon(state))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(currentTrackingAccent(state))
                .offset(y: -3)

            CurrentActivityDurationBadge(startedAt: state.startedAt, color: currentTrackingAccent(state))
                .offset(y: -1)
        }
        .frame(width: 36, height: 36)
    }
}

/// The compact number/unit badge mirrors the duration tag on map footprint pins.
private struct CurrentActivityDurationBadge: View {
    let startedAt: Date
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: nextMinuteBoundary, by: 60)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            let (number, unit) = mapFootprintDurationParts(elapsed)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(number)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                Text(unit)
                    .font(.system(size: 5, weight: .bold, design: .rounded))
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 0.5))
        }
    }

    private var nextMinuteBoundary: Date {
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let completedMinutes = floor(elapsed / 60)
        return startedAt.addingTimeInterval((completedMinutes + 1) * 60)
    }
}

private func mapFootprintDurationParts(_ elapsed: Int) -> (String, String) {
    let totalMinutes = elapsed / 60
    guard totalMinutes >= 60 else { return ("\(max(1, totalMinutes))", "分钟") }

    let hours = Double(totalMinutes) / 60
    if hours >= 10 {
        return ("\(Int(hours.rounded()))", "小时")
    }
    return (String(format: "%g", (hours * 10).rounded() / 10), "小时")
}

@available(iOS 16.1, *)
private struct CurrentTrackingLockScreenContent: View {
    let context: ActivityViewContext<CurrentTrackingActivityAttributes>

    private var state: CurrentTrackingActivityAttributes.ContentState { context.state }
    private var accent: Color { currentTrackingAccent(state) }
    private var usesDarkMap: Bool { state.prefersDarkMap ?? false }
    private var primaryForeground: Color { usesDarkMap ? .white : .black }
    private var secondaryForeground: Color { primaryForeground.opacity(0.72) }
    private var contentHeight: CGFloat { state.kind == .footprint ? 160 : 140 }

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
                        .frame(width: 22, alignment: .leading)
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
                    HStack(alignment: .center, spacing: 12) {
                        HStack(spacing: 7) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.headline)
                                .foregroundStyle(secondaryForeground)
                                .frame(width: 22, alignment: .leading)
                            Text(state.placeName)
                                .font(.title3.bold())
                                .lineLimit(1)
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
                }
            }
            .foregroundStyle(primaryForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, state.kind == .transport ? 6 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) {
            if state.kind == .footprint {
                CurrentFootprintTodaySummary(
                    placeCount: state.todayPlaceCount,
                    distance: state.todayDistance,
                    foreground: secondaryForeground,
                    showsBrand: true
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
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
    private var accent: Color { currentTrackingAccent(state) }
    // The system adds the sensor-safe top region and the leading/trailing row.
    // Keep the bottom region at 112pt so the complete expanded island reaches
    // its intended height without turning that reserved area into a huge band.
    private let expandedBottomHeight: CGFloat = 112

    var body: some View {
        VStack(spacing: 6) {
            CurrentActivityMapImage(
                sessionID: context.attributes.sessionID,
                revision: state.mapRevision,
                prefersDarkMap: true
            )
            .frame(
                maxWidth: .infinity,
                minHeight: expandedBottomHeight,
                maxHeight: expandedBottomHeight
            )
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
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.78))
                        Text(state.placeName)
                            .font(.title3.bold())
                            .lineLimit(1)
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
                    .padding(.top, 18)
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
                        foreground: .white.opacity(0.78),
                        showsBrand: true
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
        .frame(
            maxWidth: .infinity,
            minHeight: expandedBottomHeight,
            maxHeight: expandedBottomHeight,
            alignment: .top
        )
        .widgetURL(currentActivityDetailURL(for: state))
    }
}

private struct CurrentFootprintTodaySummary: View {
    let placeCount: Int?
    let distance: Double?
    let foreground: Color
    var showsBrand = false

    var body: some View {
        if let placeCount, let distance {
            HStack(spacing: 5) {
                Text("今日停留 \(placeCount) 个地点")
                    .foregroundStyle(foreground)
                Text("·")
                    .foregroundStyle(foreground)
                Text("里程 \(formatCurrentTodayDistance(distance))")
                    .foregroundStyle(foreground)
                if showsBrand {
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text("地方客")
                            .foregroundStyle(foreground)
                    }
                }
            }
            .font(.caption2.weight(.semibold))
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

private func currentTrackingAccent(
    _ state: CurrentTrackingActivityAttributes.ContentState
) -> Color {
    if state.kind == .footprint, state.colorHex == nil {
        return .gray
    }
    return currentActivityColor(state.colorHex)
}

private func currentTrackingIcon(
    _ state: CurrentTrackingActivityAttributes.ContentState
) -> String {
    guard state.kind == .footprint, state.colorHex == nil else { return state.icon }
    return "questionmark.circle.dashed"
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
