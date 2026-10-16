import WidgetKit
import SwiftUI

private struct ComplicationActivity: Codable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
}

private struct ComplicationSnapshot: Codable {
    let currentFootprintID: String?
    let placeName: String
    let address: String?
    let startedAt: Date?
    let isTracking: Bool
    let currentActivityID: String?
    let currentTransportType: String?
    let currentTransportStartedAt: Date?
    let todayFootprintCount: Int
    let todayDistance: Double
    let activities: [ComplicationActivity]
    let todayTimeline: [ComplicationTimelineItem]?
}

private struct ComplicationTimelineItem: Codable {
    let id: String
    let startTime: Date
    let endTime: Date
    let colorHex: String?
    let isTransport: Bool?
}

private struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot?
}

private struct ComplicationProvider: TimelineProvider {
    private let groupID = "group.com.ct106.difangke"
    private let snapshotKey = "watchComplicationSnapshot"

    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let now = Date()
        let entry = ComplicationEntry(date: now, snapshot: loadSnapshot())
        // State changes explicitly reload this timeline from WatchStore. This
        // hourly request is only a low-frequency fallback for missed delivery.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func loadEntry() -> ComplicationEntry {
        ComplicationEntry(date: .now, snapshot: loadSnapshot())
    }

    private func loadSnapshot() -> ComplicationSnapshot? {
        let data = UserDefaults(suiteName: groupID)?.data(forKey: snapshotKey)
        return data.flatMap { try? JSONDecoder().decode(ComplicationSnapshot.self, from: $0) }
    }
}

private struct WatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ComplicationEntry

    private var activity: ComplicationActivity? {
        guard let snapshot = entry.snapshot else { return nil }
        return snapshot.activities.first { $0.id == snapshot.currentActivityID }
    }

    private var transport: (name: String, icon: String)? {
        switch entry.snapshot?.currentTransportType {
        case "moving": return ("移动", "location.north.line.fill")
        case "slow": return ("步行", "figure.walk")
        case "running": return ("跑步", "figure.run")
        case "bicycle": return ("自行车", "bicycle")
        case "ebike": return ("电动车", "moped.fill")
        case "motorcycle": return ("摩托车", "motorcycle.fill")
        case "bus": return ("公交", "bus.fill")
        case "car": return ("驾车", "car.fill")
        case "subway": return ("地铁", "tram.fill")
        case "train": return ("火车", "train.side.front.car")
        case "airplane": return ("飞行", "airplane")
        case "ship": return ("轮船", "ferry.fill")
        default: return nil
        }
    }
    private var icon: String {
        transport?.icon ?? activity?.icon
            ?? (entry.snapshot?.isTracking == true ? "questionmark.circle.dashed" : "location.slash")
    }
    private var title: String { transport?.name ?? activity?.name ?? (entry.snapshot?.isTracking == true ? "记录中" : "未记录") }
    private var color: Color {
        if transport != nil { return Color.accentColor }
        guard let hex = activity?.colorHex else { return .secondary.opacity(0.4) }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .secondary.opacity(0.4) }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    private var dayTimelineRing: some View {
        DayTimelineRing(
            items: entry.snapshot?.todayTimeline ?? [],
            date: entry.date
        )
    }

    @ViewBuilder
    var body: some View {
        if redactionReasons.contains(.privacy) || redactionReasons.contains(.placeholder) {
            privacyPlaceholder
                .unredacted()
        } else {
            switch family {
            case .accessoryCircular:
                ZStack {
                    dayTimelineRing
                    Image(systemName: icon)
                        .preservingTransportAccentColor(transport != nil)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(color)
                }
                .padding(1)
                .widgetLabel(title)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .preservingTransportAccentColor(transport != nil)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline).lineLimit(1)
                            Text(todaySummary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    DayTimelineBar(
                        items: entry.snapshot?.todayTimeline ?? [],
                        currentFootprintID: entry.snapshot?.currentFootprintID,
                        date: entry.date
                    )
                    .frame(height: 6)
                }
            case .accessoryInline:
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .preservingTransportAccentColor(transport != nil)
                        .foregroundStyle(color)
                    Text(title)
                }
            case .accessoryCorner:
                Image(systemName: icon)
                    .preservingTransportAccentColor(transport != nil)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(color)
                    .widgetLabel(title)
            default:
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .preservingTransportAccentColor(transport != nil)
                        .foregroundStyle(color)
                    Text(title)
                }
            }
        }
    }

    /// watchOS may keep accessory artwork visible while privacy-redacting text.
    /// Render a data-free view ourselves so the current activity/transport state
    /// cannot leak through the locked watch face.
    @ViewBuilder
    private var privacyPlaceholder: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.45), lineWidth: 3.8)
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(2)
            .widgetLabel("地方客")
        case .accessoryRectangular:
            Label("地方客", systemImage: "location.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .accessoryInline:
            Label("地方客", systemImage: "location.fill")
                .foregroundStyle(.secondary)
        case .accessoryCorner:
            Image(systemName: "location.fill")
                .foregroundStyle(.secondary)
                .widgetLabel("地方客")
        default:
            Label("地方客", systemImage: "location.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var todaySummary: String {
        guard let snapshot = entry.snapshot else { return "等待 iPhone 同步" }
        return "今日 \(snapshot.todayFootprintCount) 个足迹"
    }

}

private extension Image {
    /// `widgetAccentable` assigns content to the watch face's accent group; it
    /// does not preserve this extension's own AccentColor and can still render
    /// an SF Symbol white. Full-colour image rendering keeps the explicit
    /// `Color.accentColor` foreground style used by transport icons.
    @ViewBuilder
    func preservingTransportAccentColor(_ preserve: Bool) -> some View {
        if preserve {
            if #available(watchOS 11.0, *) {
                widgetAccentedRenderingMode(.fullColor)
            } else {
                self
            }
        } else {
            self
        }
    }
}

/// A clock-face day: midnight is at 12 o'clock and each segment is clipped to
/// the displayed calendar day.  Footprints sit above transport so an activity
/// remains legible when records overlap.
private struct DayTimelineRing: View {
    let items: [ComplicationTimelineItem]
    let date: Date

    private let calendar = Calendar.current
    // Circle() sizes itself to fill the whole view and .stroke centers its line on
    // that edge, so half of every stroke's width would otherwise fall outside the
    // widget's bounds — exactly where accessoryCircular's system clip mask crops it,
    // leaving only the inner half of the ring and a lopped-off rounded cap. Insetting
    // by half the thickest stroke keeps every segment's outer edge inside the mask.
    private let maxLineWidth: CGFloat = 4.0

    var body: some View {
        GeometryReader { geometry in
            let circumference = max(1, min(geometry.size.width, geometry.size.height)) * .pi
            ZStack {
                Circle()
                    .stroke(.gray.opacity(0.16), lineWidth: 3.8)
                Circle()
                    .trim(from: 0, to: elapsedDayFraction)
                    .stroke(.gray.opacity(0.42), lineWidth: 3.8)

                // Transport uses the watch face's complication accent colour as a
                // solid segment. A hollow white center made short periods white.
                ForEach(items.filter { $0.isTransport == true }, id: \.id) { item in
                    segment(for: item, color: Color.accentColor, lineWidth: 3.6, circumference: circumference)
                        .widgetAccentable()
                }
                ForEach(items.filter { $0.isTransport != true }, id: \.id) { item in
                    segment(
                        for: item,
                        color: color(from: item.colorHex),
                        lineWidth: 4.0,
                        circumference: circumference
                    )
                }
            }
        }
        .padding(maxLineWidth / 2)
        .rotationEffect(.degrees(-90))
    }

    /// Round caps extend half a line width past each trim end. Inset by that
    /// overhang plus a hairline so adjacent periods stay separate; a period too
    /// short for the inset is still drawn as a single cap-sized dot.
    @ViewBuilder
    private func segment(
        for item: ComplicationTimelineItem,
        color: Color,
        lineWidth: CGFloat,
        circumference: CGFloat
    ) -> some View {
        let range = clippedFractionRange(for: item)
        let inset = (lineWidth / 2 + 0.5) / circumference
        if range.length > 0 {
            let middle = range.start + range.length / 2
            let start = range.length > inset * 2 ? range.start + inset : middle
            let end = range.length > inset * 2 ? range.start + range.length - inset : middle + 0.0001
            Circle()
                .trim(from: start, to: end)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private func clippedFractionRange(for item: ComplicationTimelineItem) -> (start: Double, length: Double) {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return (0, 0) }
        let start = max(item.startTime, startOfDay)
        let end = min(item.endTime, endOfDay)
        guard end > start else { return (0, 0) }
        let dayDuration = endOfDay.timeIntervalSince(startOfDay)
        return (
            max(0, start.timeIntervalSince(startOfDay) / dayDuration),
            min(1, end.timeIntervalSince(start) / dayDuration)
        )
    }

    private var elapsedDayFraction: Double {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return 0 }
        return min(1, max(0, date.timeIntervalSince(startOfDay) / endOfDay.timeIntervalSince(startOfDay)))
    }

    private func color(from hex: String?) -> Color {
        // Unlabelled stays sit on the gray elapsed-time baseline; a translucent
        // gray would be indistinguishable from time without any footprint.
        guard let hex = hex else { return .secondary }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .secondary }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// The rectangular family has room for a linear day clock.  The faint tail is
/// time that has not arrived yet; the stronger gray baseline is elapsed time
/// without a recorded footprint.
private struct DayTimelineBar: View {
    let items: [ComplicationTimelineItem]
    let currentFootprintID: String?
    let date: Date

    private let calendar = Calendar.current

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.16))
                Capsule()
                    .fill(.gray.opacity(0.42))
                    .frame(width: geometry.size.width * elapsedDayFraction)

                ForEach(items.filter { $0.isTransport == true }, id: \.id) { item in
                    segment(for: item, in: geometry.size, color: Color.accentColor, height: 3, isAccent: true)
                }
                ForEach(items.filter { $0.isTransport != true }, id: \.id) { item in
                    segment(
                        for: item,
                        in: geometry.size,
                        color: color(from: item.colorHex),
                        height: item.id == currentFootprintID ? 6 : 4,
                        isAccent: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func segment(
        for item: ComplicationTimelineItem,
        in size: CGSize,
        color: Color,
        height: CGFloat,
        isAccent: Bool
    ) -> some View {
        let range = clippedFractionRange(for: item)
        let fullWidth = size.width * range.length
        let gap: CGFloat = min(1.25, fullWidth * 0.12)
        if range.length > 0 {
            Capsule()
                .fill(color)
                // Keep a just-started period visible on the compact bar.
                .frame(width: max(1.5, fullWidth - gap * 2), height: height)
                .offset(x: size.width * range.start + gap)
                .widgetAccentable(isAccent)
        }
    }

    private func clippedFractionRange(for item: ComplicationTimelineItem) -> (start: Double, length: Double) {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return (0, 0) }
        let start = max(item.startTime, startOfDay)
        let end = min(item.endTime, endOfDay)
        guard end > start else { return (0, 0) }
        let dayDuration = endOfDay.timeIntervalSince(startOfDay)
        return (
            max(0, start.timeIntervalSince(startOfDay) / dayDuration),
            min(1, end.timeIntervalSince(start) / dayDuration)
        )
    }

    private var elapsedDayFraction: CGFloat {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(startOfDay) / endOfDay.timeIntervalSince(startOfDay))))
    }

    private func color(from hex: String?) -> Color {
        // Unlabelled stays sit on the gray elapsed-time baseline; a translucent
        // gray would be indistinguishable from time without any footprint.
        guard let hex = hex else { return .secondary }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .secondary }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

struct DiFangKeWatchComplication: Widget {
    let kind = "DiFangKeWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            WatchComplicationView(entry: entry)
                .privacySensitive()
                .widgetURL(URL(string: "difangke://watch/current"))
        }
        .configurationDisplayName("地方客此刻")
        .description("显示当前活动或交通状态图标。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct DiFangKeWatchWidgetBundle: WidgetBundle {
    var body: some Widget { DiFangKeWatchComplication() }
}
