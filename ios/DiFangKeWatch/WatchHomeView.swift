import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var selectedPage = "current"
    @State private var showingMap = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                TabView(selection: $selectedPage) {
                    ForEach((store.snapshot.futureTrips ?? []).reversed()) { trip in
                        FutureTripPage(trip: trip)
                            .tag("future-\(trip.id)")
                    }
                    CurrentPlaceView()
                        .tag("current")
                    ForEach(store.snapshot.recentDays ?? []) { day in
                        DayTimelinePage(day: day)
                            .tag("day-\(day.date.timeIntervalSince1970)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))

                if selectedPage != "current" {
                    Button {
                        selectedPage = "current"
                    } label: {
                        Image(systemName: "location")
                    }
                    .padding(.leading, 6)
                    .padding(.bottom, 5)
                    .accessibilityLabel("返回当前停留")
                }
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
            Text(item.title)
                .font(.caption)
                .lineLimit(2)
        }
    }
}
