import SwiftUI
import SwiftData

struct TagManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaceTag.name) private var tags: [PlaceTag]
    @Query private var footprints: [Footprint]
    
    @State private var newTagName = ""
    @State private var tagToDelete: PlaceTag?
    @State private var showDeleteConfirm = false
    @State private var showBatchDeleteConfirm = false
    
    // Selection state
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<PersistentIdentifier>()
    
    // Focus & Editing State
    enum FocusField: Hashable {
        case newTag
        case editingTag(PersistentIdentifier)
    }
    @FocusState private var focusedField: FocusField?
    @State private var editingTagID: PersistentIdentifier?
    @State private var editingTagOriginalName: String?
    @State private var editingTagName = ""
    
    private var sortedTags: [PlaceTag] {
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    
    private var tagCounts: [String: Int] {
        footprints.flatMap { $0.tags }.reduce(into: [:]) { counts, tag in
            counts[tag, default: 0] += 1
        }
    }
    
    var body: some View {
        List(selection: $selection) {
            if editMode == .inactive {
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
            }
            
            Section(header: Text("全部标签")) {
                let list = sortedTags
                if list.isEmpty {
                    Text("当前还没有自定义标签").foregroundColor(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(list) { tag in
                        Group {
                            if editingTagID == tag.persistentModelID && editMode == .inactive {
                                TextField("", text: $editingTagName)
                                    .focused($focusedField, equals: .editingTag(tag.persistentModelID))
                                    .submitLabel(.done)
                                    .onSubmit {
                                        finishEditingTag(tag)
                                    }
                            } else {
                                HStack {
                                    Text(tag.name)
                                        .foregroundColor(Color.dfkMainText)
                                    Spacer()
                                    if let count = tagCounts[tag.name], count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if editMode == .inactive {
                                        startEditingTag(tag)
                                    } else {
                                        toggleSelection(tag.persistentModelID)
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if editMode == .inactive {
                                Button(role: .destructive) {
                                    tagToDelete = tag
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                        .tag(tag.persistentModelID)
                    }
                }
            }
        }
        .navigationTitle("常用标签管理")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if editMode == .active {
                        Button(role: .destructive) {
                            if !selection.isEmpty {
                                showBatchDeleteConfirm = true
                            }
                        } label: {
                            Text("删除(\(selection.count))")
                                .foregroundColor(selection.isEmpty ? .secondary : .red)
                        }
                        .disabled(selection.isEmpty)
                    }
                    
                    Button {
                        withAnimation {
                            if editMode == .active {
                                editMode = .inactive
                                selection.removeAll()
                            } else {
                                editMode = .active
                            }
                        }
                    } label: {
                        Text(editMode == .active ? "完成" : "管理")
                    }
                }
            }
        }
        .onTapGesture {
            if editMode == .inactive {
                focusedField = nil
                if let tagID = editingTagID {
                    if let tag = tags.first(where: { $0.persistentModelID == tagID }) {
                        finishEditingTag(tag)
                    }
                }
            }
        }
        .onAppear {
            TagService.shared.mergeDuplicateTags(in: modelContext)
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let tag = tagToDelete {
                    deleteTag(tag)
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
        .alert("确认批量删除", isPresented: $showBatchDeleteConfirm) {
            Button("删除 \(selection.count) 个标签", role: .destructive) {
                deleteSelectedTags()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除选中的 \(selection.count) 个标签吗？此操作不可撤销。")
        }
    }
    
    private func deleteTag(_ tag: PlaceTag) {
        TagService.shared.deleteTag(tag, in: modelContext, allFootprints: footprints)
    }
    
    private func deleteSelectedTags() {
        for id in selection {
            if let tag = tags.first(where: { $0.persistentModelID == id }) {
                TagService.shared.deleteTag(tag, in: modelContext, allFootprints: footprints)
            }
        }
        selection.removeAll()
        editMode = .inactive
    }
    
    private func toggleSelection(_ id: PersistentIdentifier) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
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
        editingTagID = tag.persistentModelID
        editingTagOriginalName = tag.name
        editingTagName = tag.name
        focusedField = .editingTag(tag.persistentModelID)
    }
    
    private func finishEditingTag(_ tag: PlaceTag) {
        let newName = editingTagName.trimmingCharacters(in: .whitespaces)
        let oldName = editingTagOriginalName ?? tag.name
        
        TagService.shared.renameTag(oldName: oldName, newName: newName, in: tag, allFootprints: footprints, in: modelContext)
        
        editingTagID = nil
        editingTagOriginalName = nil
        focusedField = nil
    }
}
