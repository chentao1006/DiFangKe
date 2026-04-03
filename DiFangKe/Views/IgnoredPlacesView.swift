import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct IgnoredPlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var allPlacesList: [Place]
    
    private var ignoredPlaces: [Place] {
        allPlacesList.filter { $0.isIgnored }
    }
    
    @State private var placeToDelete: Place?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            ForEach(ignoredPlaces) { place in
                ignoredPlaceRow(place)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            placeToDelete = place
                            showDeleteConfirm = true
                        } label: {
                            Label("彻底删除", systemImage: "trash")
                        }
                        .tint(.red)
                        
                        Button {
                            restorePlace(place)
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                    }
            }

            if ignoredPlaces.isEmpty {
                emptyState
            }
        }
        .navigationTitle("已忽略地点")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认彻底删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let place = placeToDelete {
                    modelContext.delete(place)
                    try? modelContext.save()
                }
                placeToDelete = nil
            }
            Button("取消", role: .cancel) {
                placeToDelete = nil
            }
        } message: {
            if let place = placeToDelete {
                Text("确定要彻底删除“\(place.name)”吗？此操作不可撤销。")
            }
        }
    }

    private func ignoredPlaceRow(_ place: Place) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "mappin.slash.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("\(place.address ?? "未知地址")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            
            Button {
                restorePlace(place)
            } label: {
                Text("恢复")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func restorePlace(_ place: Place) {
        withAnimation {
            place.isIgnored = false
            try? modelContext.save()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.circle")
                .font(.system(size: 52))
                .foregroundColor(.dfkCandidate)
            Text("没有已忽略的地点")
                .font(.headline)
                .foregroundColor(.dfkSecondaryText)
            Text("长按足迹并选择“忽略地点”，\n该地点及其后续轨迹将不再记录。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.dfkSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
