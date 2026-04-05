import SwiftUI
import SwiftData
import MapKit
import CoreLocation

// MARK: - Places Manager List

struct PlacesManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var allPlacesList: [Place]
    private var places: [Place] {
        allPlacesList.filter { $0.isUserDefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    @Query private var footprints: [Footprint]
    var startInAddMode: Bool = false
    
    @State private var showingAddPlace = false
    @State private var editingPlace: Place?
    @State private var placeToDelete: Place?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section {
                Text("重要地点用于识别您的常用位置。您可以设置“忽略足迹”，系统将不再自动记录发生在该地点的琐迹。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            ForEach(places) { place in
                placeRow(place)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            placeToDelete = place
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(.red)
                    }
            }

            if places.isEmpty {
                emptyState
            }
        }
        .navigationTitle("重要地点")
        .navigationBarTitleDisplayMode(.large)
        .tint(.dfkAccent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddPlace = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundColor(.dfkAccent)
                }
            }
        }
        .sheet(isPresented: $showingAddPlace) {
            AddPlaceSheet { newPlace in
                modelContext.insert(newPlace)
                try? modelContext.save()
            }
        }
        .sheet(item: $editingPlace) { place in
            EditPlaceSheet(place: place) {
                try? modelContext.save()
            } onDelete: {
                modelContext.delete(place)
                try? modelContext.save()
                editingPlace = nil
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
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
                Text("确定要删除“\(place.name)”及其关联配置吗？此操作不可撤销。")
            }
        }
        .onAppear {
            if startInAddMode {
                showingAddPlace = true
            }
        }
    }

    private func placeRow(_ place: Place) -> some View {
        Button {
            editingPlace = place
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: importantIcon(for: place.name))
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(place.name)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundColor(place.isIgnored ? .secondary.opacity(0.8) : .primary)
                        
                        if place.isIgnored {
                            Text("忽略足迹")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundColor(.secondary)
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(place.address ?? "未知地址")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func importantIcon(for name: String) -> String {
        switch name {
        case "家": return "house.fill"
        case "公司": return "building.2.fill"
        case "学校": return "graduationcap.fill"
        default: return "mappin.circle.fill"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.slash.circle")
                .font(.system(size: 52))
                .foregroundColor(.dfkCandidate)
            Text("还没有记录地点")
                .font(.headline)
                .foregroundColor(.dfkSecondaryText)
            Text("添加家、公司、餐厅等常用地点，\n地方客将帮你更精准地记录您的足迹。")
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
