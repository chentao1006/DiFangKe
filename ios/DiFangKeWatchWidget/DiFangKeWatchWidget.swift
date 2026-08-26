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
        let snapshot = loadSnapshot()
        // The compact label is not a system .timer, so provide minute-by-minute
        // entries to keep it advancing even while the iPhone has no new data.
        let entries = (0...60).map { offset in
            ComplicationEntry(date: now.addingTimeInterval(TimeInterval(offset * 60)), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
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
    let entry: ComplicationEntry

    private var activity: ComplicationActivity? {
        guard let snapshot = entry.snapshot else { return nil }
        return snapshot.activities.first { $0.id == snapshot.currentActivityID }
    }

    private var transport: (name: String, icon: String)? {
        switch entry.snapshot?.currentTransportType {
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
    private var icon: String { transport?.icon ?? activity?.icon ?? (entry.snapshot?.isTracking == true ? "location.fill" : "location.slash") }
    private var title: String { transport?.name ?? activity?.name ?? (entry.snapshot?.isTracking == true ? "记录中" : "未记录") }
    private var duration: String {
        guard let startedAt = entry.snapshot?.currentTransportStartedAt ?? entry.snapshot?.startedAt else { return "--" }
        let minutes = max(0, Int(entry.date.timeIntervalSince(startedAt) / 60))
        if minutes < 60 {
            return "\(max(1, minutes))分钟"
        }

        let hours = Double(minutes) / 60
        if hours >= 10 {
            return "\(Int(hours.rounded()))小时"
        }
        return "\(String(format: "%g", (hours * 10).rounded() / 10))小时"
    }

    private var durationLabel: some View {
        Text(duration)
            .monospacedDigit()
    }
    private var color: Color {
        if transport != nil { return Color.accentColor }
        guard let hex = activity?.colorHex else { return .blue }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .blue }
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
        switch family {
        case .accessoryCircular:
            ZStack {
                dayTimelineRing
                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                    durationLabel
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(1)
            .widgetLabel(title)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline).lineLimit(1)
                        HStack(spacing: 2) { Text("已持续"); durationLabel }
                            .font(.caption2)
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
                Text(title)
                Text("·")
                durationLabel
            }
        case .accessoryCorner:
            durationLabel.widgetLabel { Label(title, systemImage: icon) }
        default:
            VStack(alignment: .leading) {
                Label(title, systemImage: icon).foregroundStyle(color)
                Text(duration).font(.headline.monospacedDigit())
            }
        }
    }

    private var todaySummary: String {
        guard let snapshot = entry.snapshot else { return "等待 iPhone 同步" }
        return "今日 \(snapshot.todayFootprintCount) 个足迹"
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
        ZStack {
            Circle()
                .stroke(.gray.opacity(0.16), lineWidth: 3.8)
            Circle()
                .trim(from: 0, to: elapsedDayFraction)
                .stroke(.gray.opacity(0.42), lineWidth: 3.8)

            ForEach(items.filter { $0.isTransport == true }, id: \.id) { item in
                transportSegment(for: item)
            }
            ForEach(items.filter { $0.isTransport != true }, id: \.id) { item in
                segment(
                    for: item,
                    color: color(from: item.colorHex),
                    lineWidth: 4.0
                )
            }
        }
        .padding(maxLineWidth / 2)
        .rotationEffect(.degrees(-90))
    }

    @ViewBuilder
    private func segment(for item: ComplicationTimelineItem, color: Color, lineWidth: CGFloat) -> some View {
        let range = clippedFractionRange(for: item)
        // Rounded caps otherwise close a tiny trim gap on the compact dial.
        let gap = min(0.030, range.length * 0.18)
        if range.length > gap * 2 {
            Circle()
                .trim(from: range.start + gap, to: range.start + range.length - gap)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    /// Transport is intentionally hollow so it reads as movement rather than
    /// a stay: white center, thin theme-colour outline.
    @ViewBuilder
    private func transportSegment(for item: ComplicationTimelineItem) -> some View {
        let range = clippedFractionRange(for: item)
        let gap = min(0.030, range.length * 0.18)
        if range.length > gap * 2 {
            let start = range.start + gap
            let end = range.start + range.length - gap
            Circle()
                .trim(from: start, to: end)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
            Circle()
                .trim(from: start, to: end)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
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
        guard let hex = hex else { return Color.accentColor }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return Color.accentColor }
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
                    segment(for: item, in: geometry.size, color: Color.accentColor, height: 2)
                }
                ForEach(items.filter { $0.isTransport != true }, id: \.id) { item in
                    segment(
                        for: item,
                        in: geometry.size,
                        color: color(from: item.colorHex),
                        height: item.id == currentFootprintID ? 6 : 4
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func segment(for item: ComplicationTimelineItem, in size: CGSize, color: Color, height: CGFloat) -> some View {
        let range = clippedFractionRange(for: item)
        if range.length > 0 {
            Capsule()
                .fill(color)
                .frame(width: max(1.5, size.width * range.length), height: height)
                .offset(x: size.width * range.start)
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
        guard let hex = hex else { return Color.accentColor }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return Color.accentColor }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

struct DiFangKeWatchComplication: Widget {
    let kind = "DiFangKeWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            WatchComplicationView(entry: entry)
                .widgetURL(URL(string: "difangke://watch/current"))
        }
        .configurationDisplayName("地方客此刻")
        .description("显示当前活动或交通及持续时间。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct DiFangKeWatchWidgetBundle: WidgetBundle {
    var body: some Widget { DiFangKeWatchComplication() }
}
