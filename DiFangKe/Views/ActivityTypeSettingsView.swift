import SwiftUI
import SwiftData

struct ActivityTypeSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var activities: [ActivityType]
    
    @State private var showingDeleteAlert = false
    @State private var activityToDelete: ActivityType?
    
    // Using a wrapper to ensure fresh view on each sheet presentation
    struct EditorConfig: Identifiable {
        let id = UUID()
        let activity: ActivityType?
    }
    @State private var editorConfig: EditorConfig?
    
    var body: some View {
        List {
            Section(header: Text("拖动可以调整活动在选择菜单中的顺序。")) {
                ForEach(activities) { activity in
                    HStack {
                        ZStack {
                            Circle()
                                .fill(activity.color.opacity(0.12))
                                .frame(width: 38, height: 38)
                            Image(systemName: activity.icon)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(activity.color)
                        }
                        
                        Text(activity.name)
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editorConfig = EditorConfig(activity: activity)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            activityToDelete = activity
                            showingDeleteAlert = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: moveActivities)
            }
        }
        .alert("确定要删除吗？", isPresented: $showingDeleteAlert) {
            Button("删除", role: .destructive) {
                if let activity = activityToDelete {
                    modelContext.delete(activity)
                    try? modelContext.save()
                    CloudSettingsManager.shared.triggerDataSyncPulse()
                }
                activityToDelete = nil
            }
            Button("取消", role: .cancel) {
                activityToDelete = nil
            }
        } message: {
            if let activity = activityToDelete {
                Text("删除“\(activity.name)”后，已关联此类型的足迹将不再显示图标。此操作不可撤销。")
            }
        }
        .navigationTitle("管理活动类型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorConfig = EditorConfig(activity: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editorConfig) { config in
            ActivityTypeEditorView(activity: config.activity)
        }
    }
    
    private func deleteActivities(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(activities[index])
        }
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
    }
    
    private func moveActivities(from source: IndexSet, to destination: Int) {
        var revisedItems = activities
        revisedItems.move(fromOffsets: source, toOffset: destination)
        
        for reverseIndex in stride(from: revisedItems.count - 1, through: 0, by: -1) {
            revisedItems[reverseIndex].sortOrder = reverseIndex
        }
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
    }
}

struct ActivityTypeEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    let activity: ActivityType?
    
    @State private var name: String = ""
    @State private var icon: String = "tag.fill"
    @State private var color: Color = .blue
    
    let icons = [
        "house.fill", "briefcase.fill", "graduationcap.fill", "airplane",
        "moon.stars.fill", "fork.knife", "bag.fill", "figure.run",
        "gamecontroller.fill", "book.fill", "cross.fill", "car.fill",
        "bus.fill", "tram.fill", "map.fill", "mappin.and.ellipse",
        "star.fill", "heart.fill", "gift.fill", "cart.fill",
        "cup.and.saucer.fill", "wineglass.fill", "pills.fill", "camera.fill",
        "laptopcomputer", "desktopcomputer", "keyboard", "printer.fill",
        "tv.fill", "umbrella.fill", "sun.max.fill", "cloud.fill",
        "bicycle", "ferry.fill", "fuelpump.fill",
        "creditcard.fill", "cart.badge.plus", "shippingbox.fill", "hammer.fill",
        "wrench.adjustable.fill", "theatermasks.fill", "music.note", "mic.fill",
        "mountain.2.fill", "leaf.fill", "pawprint.fill", "drop.fill",
        "bolt.fill", "flame.fill", "stethoscope", "bed.double.fill",
        "sofa.fill", "lamp.floor.fill", "toilet.fill", "shower.fill",
        "facemask.fill", "tshirt.fill", "comb.fill", "scissors",
        "magnifyingglass", "bell.fill", "envelope.fill", "phone.fill",
        "dog.fill", "cat.fill", "hare.fill", "tortoise.fill",
        "birthday.cake.fill", "face.smiling", "eyeglasses", 
        "puzzlepiece.fill", "brain.head.profile", "lightbulb.fill", "calendar", "play.rectangle.fill",
        "person.fill", "person.2.fill", "person.3.fill", "party.popper.fill",
        "figure.2.and.child.holdinghands", "figure.and.child.holdinghands"
    ]
    
    let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown, .gray
    ]
    
    init(activity: ActivityType? = nil) {
        self.activity = activity
        self._name = State(initialValue: activity?.name ?? "")
        self._icon = State(initialValue: activity?.icon ?? "tag.fill")
        self._color = State(initialValue: activity?.color ?? .blue)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基础信息").font(.caption)) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(color.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Image(systemName: icon)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(color)
                        }
                        
                        TextField("活动名称", text: $name)
                            .font(.body)
                    }
                }
                
                Section(header: Text("活动颜色").font(.caption)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { colorOption in
                            Button {
                                self.color = colorOption
                            } label: {
                                Circle()
                                    .fill(colorOption)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: color == colorOption ? 2 : 0)
                                            .padding(-4)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                
                Section(header: Text("活动图标").font(.caption)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(icons, id: \.self) { iconName in
                            Button {
                                self.icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background(icon == iconName ? color.opacity(0.15) : Color.clear)
                                    .foregroundColor(icon == iconName ? color : .secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle(activity == nil ? "新增活动" : "编辑活动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let activity = activity {
                    name = activity.name
                    icon = activity.icon
                    color = activity.color
                }
            }
        }
    }
    
    private func save() {
        if let activity = activity {
            activity.name = name
            activity.icon = icon
            activity.colorHex = color.toHex()
        } else {
            let newActivity = ActivityType(name: name, icon: icon, colorHex: color.toHex())
            modelContext.insert(newActivity)
        }
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
    }
}
