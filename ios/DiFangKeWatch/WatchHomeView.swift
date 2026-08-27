import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var selectedPage = "current"
    @State private var showingMap = false
    @State private var showingStatistics = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    TabView(selection: $selectedPage) {
                        CurrentPlaceView()
                            .tag("current")
                        ForEach(store.snapshot.recentDays ?? []) { day in
                            DayTimelinePage(day: day)
                                .tag("day-\(day.date.timeIntervalSince1970)")
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))

                    VStack {
                        Spacer()
                        HStack {
                            if selectedPage != "current" {
                                CornerButton(systemImage: "location", accessibilityLabel: "回到当下") {
                                    selectedPage = "current"
                                }
                            }
                            Spacer()
                            CornerButton(systemImage: "chart.bar", accessibilityLabel: "统计") {
                                showingStatistics = true
                            }
                        }
                        .padding(.horizontal, 14)
                        // .page's automatic dot indicator reserves its own bottom inset;
                        // this negative padding cancels it out so the buttons sit at the
                        // same physical inset as the top-left toolbar button.
                        .padding(.bottom, -18)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingMap = true
                    } label: {
                        Image(systemName: "map")
                    }
                }
            }
            .navigationDestination(isPresented: $showingMap) {
                WatchMapView(day: selectedDaySnapshot)
            }
            .navigationDestination(isPresented: $showingStatistics) {
                WatchStatisticsView()
            }
        }
    }

    private var selectedDaySnapshot: WatchDaySnapshot? {
        if selectedPage.hasPrefix("day-"),
           let day = store.snapshot.recentDays?.first(where: { "day-\($0.date.timeIntervalSince1970)" == selectedPage }) {
            return day
        }
        if let today = store.snapshot.recentDays?.first(where: { Calendar.current.isDateInToday($0.date) }) {
            return today
        }
        return WatchDaySnapshot(date: Calendar.current.startOfDay(for: Date()), timeline: store.snapshot.todayTimeline ?? [])
    }
}

private struct CornerButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .modifier(GlassCircleBackground())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(Circle().fill(.thinMaterial))
        }
    }
}

private struct CurrentPlaceView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var showingActivityPicker = false

    var body: some View {
        let snapshot = store.snapshot
        VStack(spacing: 8) {
            Image(systemName: "location.fill")
                .foregroundStyle(.blue)
            Text(snapshot.placeName)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !store.hasReceivedSnapshot {
                Text(snapshot.address ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let startedAt = snapshot.startedAt {
                Text("已停留 \(startedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let address = snapshot.address, !address.isEmpty {
                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if store.hasReceivedSnapshot {
                Button {
                    showingActivityPicker = true
                } label: {
                    Label(store.currentActivity?.name ?? "选择活动", systemImage: store.currentActivity?.icon ?? "figure.walk")
                }
                .tint(activityColor(store.currentActivity?.colorHex))
            }
        }
        .scenePadding()
        .sheet(isPresented: $showingActivityPicker) {
            ActivityPickerView()
        }
        .onChange(of: store.requestedActivityPickerFootprintID) { _, footprintID in
            guard footprintID == snapshot.currentFootprintID else { return }
            showingActivityPicker = true
        }
    }
}

func activityColor(_ hex: String?) -> Color {
    guard let hex else { return .blue }
    let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return .blue }
    return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
}

private struct ActivityPickerView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("现在在做什么？") {
                ForEach(store.snapshot.activities) { activity in
                    Button {
                        store.selectActivity(activity)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: activity.icon)
                                .foregroundStyle(activityColor(activity.colorHex))
                                .frame(width: 20)
                            Text(activity.name)
                            Spacer()
                            if store.snapshot.currentActivityID == activity.id { Image(systemName: "checkmark").foregroundStyle(activityColor(activity.colorHex)) }
                        }
                    }
                }
            }
        }
    }
}

private struct DayTimelinePage: View {
    @EnvironmentObject private var store: WatchStore
    let day: WatchDaySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text(dayTitle)
                    .font(.headline)
                if !day.timeline.isEmpty {
                    ForEach(day.timeline) { item in
                        WatchTimelineRow(item: item)
                    }
                } else {
                    Text(store.hasReceivedSnapshot ? "没有记录" : "等待 iPhone 同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding()
        }
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.date) { return "今天" }
        if calendar.isDateInYesterday(day.date) { return "昨天" }
        return day.date.formatted(.dateTime.month().day())
    }
}

private struct FutureTripPage: View {
    let trip: WatchTripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未来计划")
                .font(.headline)
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(trip.placeName)
                .font(.title3.bold())
                .lineLimit(3)
            if trip.hasArrivalTime {
                Text(trip.arrivalDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scenePadding()
    }
}

private struct WatchStatisticsView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var range: Range = .last7Days

    private enum Range: String, CaseIterable, Identifiable {
        case last7Days = "最近7天"
        case synced = "已同步"

        var id: Self { self }
    }

    private var days: [WatchDaySnapshot] {
        let snapshots = store.snapshot.recentDays ?? []
        guard range == .last7Days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) else {
            return snapshots
        }
        return snapshots.filter { $0.date >= cutoff }
    }

    private var items: [WatchTimelineItem] {
        days.flatMap(\.timeline)
    }

    private var footprintItems: [WatchTimelineItem] {
        items.filter { $0.isTransport != true }
    }

    private var transportItems: [WatchTimelineItem] {
        items.filter { $0.isTransport == true }
    }

    private var rankedPlaces: [(name: String, duration: TimeInterval, count: Int)] {
        let grouped = Dictionary(grouping: footprintItems.filter { !$0.title.isEmpty }, by: \.title)
        var ranked: [(name: String, duration: TimeInterval, count: Int)] = []
        for (name, items) in grouped {
            var duration: TimeInterval = 0
            for item in items {
                duration += max(0, item.endTime.timeIntervalSince(item.startTime))
            }
            ranked.append((name: name, duration: duration, count: items.count))
        }
        ranked.sort { lhs, rhs in
            lhs.duration == rhs.duration ? lhs.count > rhs.count : lhs.duration > rhs.duration
        }
        return Array(ranked.prefix(3))
    }

    private var rankedActivities: [(name: String, icon: String, colorHex: String?, duration: TimeInterval, count: Int)] {
        let activityItems = footprintItems.filter {
            guard let name = $0.activityName?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !name.isEmpty
        }
        let grouped = Dictionary(grouping: activityItems, by: { $0.activityName!.trimmingCharacters(in: .whitespacesAndNewlines) })
        var ranked: [(name: String, icon: String, colorHex: String?, duration: TimeInterval, count: Int)] = []
        for (name, items) in grouped {
            let duration = items.reduce(0) { total, item in
                total + max(0, item.endTime.timeIntervalSince(item.startTime))
            }
            ranked.append((
                name: name,
                icon: items.first?.icon ?? "figure.walk",
                colorHex: items.first?.colorHex,
                duration: duration,
                count: items.count
            ))
        }
        ranked.sort { lhs, rhs in
            lhs.duration == rhs.duration ? lhs.count > rhs.count : lhs.duration > rhs.duration
        }
        return Array(ranked.prefix(3))
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("概览") {
                WatchStatisticRow(title: "活跃天数", value: "\(days.filter { !$0.timeline.isEmpty }.count) 天", icon: "calendar")
                WatchStatisticRow(title: "足迹", value: "\(footprintItems.count) 个", icon: "mappin.and.ellipse")
                WatchStatisticRow(title: "交通", value: "\(transportItems.count) 段", icon: "car")
                if range == .last7Days {
                    WatchStatisticRow(title: "今日里程", value: distanceText(store.snapshot.todayDistance), icon: "figure.walk")
                }
            }

            Section("常去地点") {
                if rankedPlaces.isEmpty {
                    Text("暂无足迹数据")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rankedPlaces.enumerated()), id: \.offset) { index, place in
                        HStack(spacing: 7) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.tint)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.name).lineLimit(1)
                                Text("\(place.count) 次 · \(durationText(place.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("活动偏好") {
                if rankedActivities.isEmpty {
                    Text("暂无活动数据")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rankedActivities.enumerated()), id: \.offset) { index, activity in
                        HStack(spacing: 7) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.tint)
                                .frame(width: 14)
                            Image(systemName: activity.icon)
                                .foregroundStyle(activityColor(activity.colorHex))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(activity.name).lineLimit(1)
                                Text("\(activity.count) 次 · \(durationText(activity.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("统计")
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时\(minutes % 60 > 0 ? " \(minutes % 60) 分" : "")"
    }

    private func distanceText(_ distance: Double) -> String {
        distance >= 1_000 ? String(format: "%.1f 公里", distance / 1_000) : "\(Int(distance.rounded())) 米"
    }
}

private struct WatchStatisticRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WatchTimelineRow: View {
    let item: WatchTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(item.startTime.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 34, alignment: .leading)
            Image(systemName: item.icon)
                .foregroundStyle(item.isTransport == true ? .accentColor : activityColor(item.colorHex))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        let duration = timelineDurationText(item.endTime.timeIntervalSince(item.startTime))
        if item.isTransport == true {
            guard let distance = item.distance else { return duration }
            return "\(timelineDistanceText(distance)) · \(duration)"
        }
        guard let activityName = item.activityName, !activityName.isEmpty else { return duration }
        return "\(activityName) · \(duration)"
    }
}

private func timelineDurationText(_ duration: TimeInterval) -> String {
    let totalMinutes = max(1, Int(duration / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
}

private func timelineDistanceText(_ distance: Double) -> String {
    distance >= 1_000 ? String(format: "%.1f 公里", distance / 1_000) : "\(Int(distance.rounded())) 米"
}
