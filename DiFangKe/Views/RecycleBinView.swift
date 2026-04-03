import SwiftUI
import SwiftData

struct RecycleBinView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Footprint> { $0.statusValue == "ignored" }, sort: \Footprint.endTime, order: .reverse) 
    private var ignoredFootprints: [Footprint]
    
    @State private var showingClearAlert = false
    
    var body: some View {
        List {
            if ignoredFootprints.isEmpty {
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
            } else {
                Section(header: Text("已删除的足迹 (\(ignoredFootprints.count))"), footer: Text("您可以恢复这些足迹，或将其永久删除。")) {
                    ForEach(ignoredFootprints) { footprint in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(footprint.title)
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
                                modelContext.delete(footprint)
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
    
    private func timeRangeString(for footprint: Footprint) -> String {
        let startStr = footprint.startTime.formatted(.dateTime.hour().minute())
        let endStr = footprint.endTime.formatted(.dateTime.hour().minute())
        return "\(startStr)-\(endStr)"
    }
    
    private func restoreFootprint(_ footprint: Footprint) {
        withAnimation {
            footprint.status = .confirmed
            try? modelContext.save()
        }
    }
    
    private func clearAll() {
        for footprint in ignoredFootprints {
            modelContext.delete(footprint)
        }
        try? modelContext.save()
    }
}
