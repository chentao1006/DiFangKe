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
                                .font(.system(size: 19, weight: .bold))
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
    
    struct IconCategory: Identifiable {
        let id = UUID()
        let name: String
        let icons: [String]
    }
    
    let iconCategories: [IconCategory] = [
        IconCategory(name: "基础与生活", icons: [
            "house.fill", "briefcase.fill", "graduationcap.fill", "airplane",
            "moon.stars.fill", "fork.knife", "bag.fill", "cart.fill",
            "cup.and.saucer.fill", "wineglass.fill", "pills.fill", "camera.fill",
            "gift.fill", "birthday.cake.fill", "face.smiling", "party.popper.fill",
            "star.fill", "heart.fill", "bell.fill", "envelope.fill", "phone.fill"
        ]),
        IconCategory(name: "运动与健身", icons: [
            "figure.run", "figure.walk", "figure.hiking", "figure.outdoor.cycle",
            "figure.pool.swim", "figure.strengthtraining.traditional", "figure.yoga", "figure.climbing", 
            "figure.badminton", "figure.table.tennis", "figure.basketball", "figure.soccer", 
            "figure.tennis", "figure.golf", "figure.bowling", "figure.dance",
            "figure.skiing.downhill", "figure.skateboarding", "figure.surfing", "figure.fishing"
        ]),
        IconCategory(name: "交通与出行", icons: [
            "car.fill", "bus.fill", "tram.fill", "ferry.fill", "bicycle", 
            "map.fill", "mappin.and.ellipse", "fuelpump.fill"
        ]),
        IconCategory(name: "工作与学习", icons: [
            "book.fill", "laptopcomputer", "desktopcomputer", "keyboard", "printer.fill",
            "tv.fill", "lightbulb.fill", "brain.head.profile", "puzzlepiece.fill", 
            "hammer.fill", "wrench.adjustable.fill", "stethoscope", "cross.fill"
        ]),
        IconCategory(name: "休闲与娱乐", icons: [
            "gamecontroller.fill", "music.note", "mic.fill", "theatermasks.fill", 
            "play.rectangle.fill", "camera.aperture", "paintpalette.fill"
        ]),
        IconCategory(name: "自然与居家", icons: [
            "leaf.fill", "pawprint.fill", "drop.fill", "bolt.fill", "flame.fill", 
            "sun.max.fill", "cloud.fill", "umbrella.fill", "mountain.2.fill",
            "bed.double.fill", "sofa.fill", "lamp.floor.fill", "toilet.fill", "shower.fill"
        ]),
        IconCategory(name: "人物与服饰", icons: [
            "person.fill", "person.2.fill", "person.3.fill", "figure.and.child.holdinghands",
            "facemask.fill", "tshirt.fill", "comb.fill", "scissors", "eyeglasses"
        ])
    ]
    
    let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
        .gray, Color(white: 0.2), Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 1.0, green: 0.4, blue: 0.4), Color(red: 0.4, green: 0.9, blue: 0.4), Color(red: 0.8, green: 0.6, blue: 1.0)
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
                                .font(.system(size: 28, weight: .bold))
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
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(iconCategories) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .padding(.leading, 2)
                                
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                                    ForEach(category.icons, id: \.self) { iconName in
                                        Button {
                                            self.icon = iconName
                                        } label: {
                                            Image(systemName: iconName)
                                                .font(.system(size: 21))
                                                .frame(width: 40, height: 40)
                                                .background(icon == iconName ? color.opacity(0.15) : Color.clear)
                                                .foregroundColor(icon == iconName ? color : .secondary.opacity(0.8))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .scrollDismissesKeyboard(.immediately)
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
