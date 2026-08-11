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
        let entry = loadEntry()
        // The relative duration refreshes even if no new phone snapshot arrives.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func loadEntry() -> ComplicationEntry {
        let data = UserDefaults(suiteName: groupID)?.data(forKey: snapshotKey)
        return ComplicationEntry(date: .now, snapshot: data.flatMap { try? JSONDecoder().decode(ComplicationSnapshot.self, from: $0) })
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
        let minutes = max(0, Int(Date().timeIntervalSince(startedAt) / 60))
        return minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分" : "\(minutes)分"
    }

    @ViewBuilder
    private var liveDuration: some View {
        if let startedAt = entry.snapshot?.currentTransportStartedAt ?? entry.snapshot?.startedAt {
            Text(startedAt, style: .timer)
                .monospacedDigit()
        } else {
            Text(duration)
        }
    }
    private var color: Color {
        guard let hex = activity?.colorHex else { return .blue }
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .blue }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 1) {
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                liveDuration.font(.caption2).lineLimit(1).minimumScaleFactor(0.65)
            }
            .widgetLabel(title)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    HStack(spacing: 2) { Text("已持续"); liveDuration }
                        .font(.caption2)
                    Text(todaySummary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .accessoryInline:
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(title)
                Text("·")
                liveDuration
            }
        case .accessoryCorner:
            liveDuration.widgetLabel { Label(title, systemImage: icon) }
        default:
            VStack(alignment: .leading) {
                Label(title, systemImage: icon).foregroundStyle(color)
                Text(duration).font(.headline.monospacedDigit())
            }
        }
    }

    private var todaySummary: String {
        guard let snapshot = entry.snapshot else { return "等待 iPhone 同步" }
        let distance = snapshot.todayDistance < 1_000 ? String(format: "%.0f米", snapshot.todayDistance) : String(format: "%.1f公里", snapshot.todayDistance / 1_000)
        return "今日 \(snapshot.todayFootprintCount) 个足迹 · \(distance)"
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
