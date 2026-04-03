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
    }
    @Query private var footprints: [Footprint]
    var startInAddMode: Bool = false
    
    @State private var showingAddPlace = false
    @State private var editingPlace: Place?
    @State private var placeToDelete: Place?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
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
                            Text("已静默")
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

// MARK: - Tag Manager

struct TagManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaceTag.name) private var tags: [PlaceTag]
    @Query private var allPlaces: [Place]
    @Query private var footprints: [Footprint]
    
    @State private var newTagName = ""
    @State private var tagToDelete: PlaceTag?
    @State private var showDeleteConfirm = false
    
    // Focus & Editing State
    enum FocusField: Hashable {
        case newTag
        case editingTag(String)
    }
    @FocusState private var focusedField: FocusField?
    @State private var editingTagOriginalName: String?
    @State private var editingTagName = ""
    
    private var sortedTags: [PlaceTag] {
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    
    var body: some View {
        List {
            Section(header: Text("添加新标签")) {
                HStack {
                    TextField("输入标签名称", text: $newTagName)
                        .focused($focusedField, equals: .newTag)
                        .submitLabel(.done)
                        .onSubmit(addTag)
                    
                    Button {
                        addTag()
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(newTagName.isEmpty ? .gray : .green)
                    }
                    .disabled(newTagName.isEmpty)
                }
            }
            
            Section(header: Text("全部标签")) {
                let list = sortedTags
                if list.isEmpty {
                    Text("当前还没有自定义标签").foregroundColor(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(list) { tag in
                        Group {
                            if editingTagOriginalName == tag.name {
                                TextField("", text: $editingTagName)
                                    .focused($focusedField, equals: .editingTag(tag.name))
                                    .submitLabel(.done)
                                    .onSubmit {
                                        finishEditingTag(tag)
                                    }
                            } else {
                                Text(tag.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        startEditingTag(tag)
                                    }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                tagToDelete = tag
                                showDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("常用标签")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.immediately)
        .onTapGesture {
            focusedField = nil
            if editingTagOriginalName != nil {
                // If we were editing, cancel or save? Let's save.
                if let tag = tags.first(where: { $0.name == editingTagOriginalName }) {
                    finishEditingTag(tag)
                }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let tag = tagToDelete {
                    modelContext.delete(tag)
                    try? modelContext.save()
                }
                tagToDelete = nil
            }
            Button("取消", role: .cancel) {
                tagToDelete = nil
            }
        } message: {
            if let tag = tagToDelete {
                Text("确定要删除标签“\(tag.name)”吗？这将从所有关联地点中移除此标签。")
            }
        }
    }
    
    private func addSpecificTag(_ name: String) {
        if !tags.contains(where: { $0.name == name }) {
            let newTag = PlaceTag(name: name)
            modelContext.insert(newTag)
            try? modelContext.save()
        }
    }

    private func addTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        addSpecificTag(trimmed)
        newTagName = ""
        focusedField = nil
    }

    private func startEditingTag(_ tag: PlaceTag) {
        editingTagOriginalName = tag.name
        editingTagName = tag.name
        focusedField = .editingTag(tag.name)
    }

    private func finishEditingTag(_ tag: PlaceTag) {
        let newName = editingTagName.trimmingCharacters(in: .whitespaces)
        let oldName = editingTagOriginalName ?? tag.name
        
        if !newName.isEmpty && newName != oldName {
            // 1. Update the tag itself (since name is @Attribute(.unique), this might be tricky in SwiftData if we just change it)
            // In SwiftData, changing a unique attribute is okay if there's no conflict.
            tag.name = newName
            
            // 2. Sync rename across all Footprints
            for footprint in footprints {
                if let index = footprint.tags.firstIndex(of: oldName) {
                    footprint.tags[index] = newName
                }
            }
            try? modelContext.save()
        }
        
        editingTagOriginalName = nil
        focusedField = nil
    }
}


