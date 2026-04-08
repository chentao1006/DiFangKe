import SwiftUI
import SwiftData

struct SavedPlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var allPlaces: [Place]
    
    private var savedPlaces: [Place] {
        allPlaces.filter { !$0.isUserDefined && !$0.isIgnored }
    }
    
    var body: some View {
        List {
            Section(header: Text("“已保存地点”是系统根据您的停留记录自动识别的位置。您可以将其忽略，或直接将其删除。")) {
                ForEach(savedPlaces) { place in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 44, height: 44)
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name)
                                .font(.headline)
                            Text(place.address ?? "未知地址")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(place)
                            try? modelContext.save()
                            CloudSettingsManager.shared.triggerDataSyncPulse()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        
                        Button {
                            place.isIgnored = true
                            try? modelContext.save()
                            CloudSettingsManager.shared.triggerDataSyncPulse()
                        } label: {
                            Label("忽略", systemImage: "mappin.slash")
                        }
                        .tint(.secondary)
                    }
                }
            }
            
            if savedPlaces.isEmpty {
                VStack(spacing: 20) {
                    Spacer().frame(height: 40)
                    Image(systemName: "clock")
                        .font(.system(size: 50))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("暂无自动识别的地点")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("已保存地点")
        .navigationBarTitleDisplayMode(.inline)
    }
}
