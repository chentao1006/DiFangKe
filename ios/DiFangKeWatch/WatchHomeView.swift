import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        TabView {
            CurrentPlaceView()
            TodayAndNextView()
        }
        .tabViewStyle(.verticalPage)
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

private func activityColor(_ hex: String?) -> Color {
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

private struct TodayAndNextView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        let snapshot = store.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("今天")
                    .font(.headline)
                Text("\(snapshot.todayFootprintCount) 个足迹")
                    .font(.title3.bold())
                Text(distanceText(snapshot.todayDistance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if let trip = snapshot.nextTrip {
                    Text("下一站").font(.caption).foregroundStyle(.secondary)
                    Text(trip.placeName).font(.headline).lineLimit(2)
                    Text(nextTripDetail(trip)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("下一站").font(.caption).foregroundStyle(.secondary)
                    Text("暂无计划").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding()
        }
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1_000 ? String(format: "%.0f 米", meters) : String(format: "%.1f 公里", meters / 1_000)
    }

    private func nextTripDetail(_ trip: WatchTripSnapshot) -> String {
        let distance = trip.distance.map { distanceText($0) } ?? "距离待更新"
        guard trip.hasArrivalTime else { return distance }
        return "\(distance) · \(trip.arrivalDate.formatted(date: .omitted, time: .shortened))"
    }
}
