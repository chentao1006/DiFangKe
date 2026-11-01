import SwiftUI
import SwiftData

struct RecycleBinView: View {
    @Environment(\.modelContext) private var modelContext
    // Loaded off main as value snapshots (same filter and order as the former @Query);
    // background deletes don't reliably refresh @Query on iOS 17.
    @State private var ignoredFootprints: [IgnoredFootprintSnapshot] = []
    @State private var dataRevision = 0
    @State private var hasLoaded = false
    
    @State private var showingClearAlert = false

    struct IgnoredFootprintSnapshot: Identifiable, Sendable {
        let id: PersistentIdentifier
        let address: String?
        let date: Date
        let startTime: Date
        let endTime: Date
    }

    nonisolated private static func ignoredFootprintsDescriptor() -> FetchDescriptor<Footprint> {
        FetchDescriptor<Footprint>(
            predicate: #Predicate { $0.statusValue == "ignored" },
            sortBy: [SortDescriptor(\Footprint.endTime, order: .reverse)]
        )
    }

    nonisolated private static func fetchIgnoredFootprints(in container: ModelContainer) -> [IgnoredFootprintSnapshot] {
        let context = ModelContext(container)
        return ((try? context.fetch(ignoredFootprintsDescriptor())) ?? []).map { footprint in
            IgnoredFootprintSnapshot(
                id: footprint.persistentModelID,
                address: footprint.address,
                date: footprint.date,
                startTime: footprint.startTime,
                endTime: footprint.endTime
            )
        }
    }

    nonisolated private static func deleteFootprints(_ ids: [PersistentIdentifier], in container: ModelContainer) {
        let context = ModelContext(container)
        for id in ids {
            if let footprint = context.model(for: id) as? Footprint {
                context.delete(footprint)
            }
        }
        try? context.save()
    }

    private func footprintModel(_ snapshot: IgnoredFootprintSnapshot) -> Footprint? {
        modelContext.model(for: snapshot.id) as? Footprint
    }
    
    var body: some View {
        List {
            if ignoredFootprints.isEmpty {
                if hasLoaded {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "trash.slash")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text("回收站空空如也")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                Section(header: Text("已删除的足迹 (\(ignoredFootprints.count))"), footer: Text("您可以恢复这些足迹，或将其永久删除。")) {
                    ForEach(ignoredFootprints) { footprint in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(footprint.address ?? "未知位置")
                                    .font(.headline)
                                    .lineLimit(1)
                                HStack {
                                    Text(footprint.date.formatted(.dateTime.month().day()))
                                    Text("·")
                                    Text(timeRangeString(for: footprint))
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                restoreFootprint(footprint)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.dfkAccent)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                if let model = footprintModel(footprint) {
                                    modelContext.delete(model)
                                    // Persist now so the off-main reload can't resurrect the row before autosave.
                                    try? modelContext.save()
                                }
                                ignoredFootprints.removeAll { $0.id == footprint.id }
                            } label: {
                                Label("永久删除", systemImage: "trash.fill")
                            }
                            
                            Button {
                                restoreFootprint(footprint)
                            } label: {
                                Label("恢复", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("足迹回收站")
        .task(id: dataRevision) {
            let container = modelContext.container
            let snapshots = await Task.detached(priority: .utility) {
                Self.fetchIgnoredFootprints(in: container)
            }.value
            guard !Task.isCancelled else { return }
            ignoredFootprints = snapshots
            hasLoaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FootprintDataChanged"))) { _ in
            dataRevision += 1
        }
        .toolbar {
            if !ignoredFootprints.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Text("全部清空")
                    }
                }
            }
        }
        .confirmationDialog("确定要清空回收站吗？", isPresented: $showingClearAlert, titleVisibility: .visible) {
            Button("永久删除所有足迹", role: .destructive) {
                clearAll()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作不可恢复。")
        }
    }
    
    private func timeRangeString(for footprint: IgnoredFootprintSnapshot) -> String {
        let startStr = footprint.startTime.formatted(.dateTime.hour().minute())
        let endStr = footprint.endTime.formatted(.dateTime.hour().minute())
        return "\(startStr)-\(endStr)"
    }
    
    private func restoreFootprint(_ footprint: IgnoredFootprintSnapshot) {
        withAnimation {
            if let model = footprintModel(footprint) {
                model.status = .confirmed
                try? modelContext.save()
            }
            ignoredFootprints.removeAll { $0.id == footprint.id }
        }
    }
    
    private func clearAll() {
        // Flush pending main-context edits (e.g. swipe deletes) before the background delete reads the store.
        try? modelContext.save()
        let ids = ignoredFootprints.map(\.id)
        let container = modelContext.container
        ignoredFootprints = []
        Task {
            await Task.detached(priority: .utility) {
                Self.deleteFootprints(ids, in: container)
            }.value
            dataRevision += 1
        }
    }
}
