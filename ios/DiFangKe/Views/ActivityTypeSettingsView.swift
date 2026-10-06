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
    @State private var selectedColor: Color = .blue
    @State private var iconSearchText: String = ""
    
    struct IconCategory: Identifiable {
        let name: String
        let icons: [String]

        var id: String { name }
    }

    private static let allIconCategories: [IconCategory] = [
        IconCategory(name: "基础与生活", icons: [
            "tag.fill", "house.fill", "building.2.fill", "building.columns.fill", "storefront.fill",
            "briefcase.fill", "graduationcap.fill", "calendar", "calendar.badge.clock", "clock.fill",
            "alarm.fill", "moon.stars.fill", "sun.max.fill", "bed.double.fill", "sofa.fill",
            "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill", "wineglass.fill",
            "birthday.cake.fill", "gift.fill", "party.popper.fill", "balloon.2.fill", "cart.fill",
            "bag.fill", "basket.fill", "creditcard.fill", "banknote.fill", "wallet.pass.fill",
            "key.fill", "lock.fill", "bell.fill", "envelope.fill", "phone.fill", "message.fill",
            "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "face.smiling", "face.smiling.fill"
        ]),
        IconCategory(name: "运动与健身", icons: [
            "figure.walk", "figure.walk.motion", "figure.run", "figure.run.treadmill", "figure.hiking",
            "figure.outdoor.cycle", "figure.indoor.cycle", "figure.pool.swim", "figure.open.water.swim",
            "figure.strengthtraining.traditional", "figure.strengthtraining.functional", "figure.core.training",
            "figure.cross.training", "figure.yoga", "figure.pilates", "figure.cooldown", "figure.flexibility",
            "figure.climbing", "figure.badminton", "figure.table.tennis", "figure.basketball", "figure.soccer",
            "figure.baseball", "figure.softball", "figure.american.football", "figure.australian.football",
            "figure.rugby", "figure.tennis", "figure.squash", "figure.racquetball", "figure.pickleball",
            "figure.golf", "figure.bowling", "figure.cricket", "figure.lacrosse", "figure.handball",
            "figure.volleyball", "figure.waterpolo", "figure.archery", "figure.boxing", "figure.wrestling",
            "figure.martial.arts", "figure.fencing", "figure.dance", "figure.gymnastics", "figure.barre",
            "figure.skiing.downhill", "figure.skiing.crosscountry", "figure.snowboarding", "figure.skating",
            "figure.skateboarding", "figure.surfing", "figure.rower", "figure.sailing", "figure.fishing",
            "figure.equestrian.sports", "figure.hunting", "figure.track.and.field", "sportscourt.fill",
            "dumbbell.fill", "soccerball", "basketball.fill", "baseball.fill", "tennisball.fill",
            "football.fill", "volleyball.fill", "hockey.puck.fill", "medal.fill", "trophy.fill"
        ]),
        IconCategory(name: "交通与出行", icons: [
            "figure.walk", "bicycle", "scooter", "car.fill", "car.side.fill", "suv.side.fill",
            "truck.box.fill", "box.truck.fill", "bus.fill", "tram.fill", "lightrail.fill", "cablecar.fill",
            "ferry.fill", "sailboat.fill", "airplane", "airplane.departure", "airplane.arrival",
            "motorcycle.fill", "parkingsign.circle.fill", "fuelpump.fill", "ev.charger.fill",
            "steeringwheel", "road.lanes", "trafficlight", "point.topleft.down.to.point.bottomright.curvepath.fill",
            "map.fill", "map.circle.fill", "mappin", "mappin.circle.fill", "mappin.and.ellipse",
            "location.fill", "location.circle.fill", "signpost.right.and.left.fill", "suitcase.rolling.fill",
            "backpack.fill", "globe.asia.australia.fill", "binoculars.fill", "tent.2.fill"
        ]),
        IconCategory(name: "工作与学习", icons: [
            "briefcase.fill", "case.fill", "folder.fill", "tray.full.fill", "doc.fill", "doc.text.fill",
            "clipboard.fill", "list.clipboard.fill", "pencil", "pencil.and.outline", "highlighter",
            "paperclip", "link", "scissors", "ruler.fill", "paintbrush.fill", "hammer.fill",
            "wrench.adjustable.fill", "screwdriver.fill", "gearshape.fill", "shippingbox.fill",
            "books.vertical.fill", "book.fill", "text.book.closed.fill", "magazine.fill", "newspaper.fill",
            "graduationcap.fill", "studentdesk", "backpack.fill", "pencil.and.ruler.fill", "character.book.closed.fill",
            "laptopcomputer", "desktopcomputer", "display", "keyboard", "keyboard.fill", "computermouse.fill",
            "printer.fill", "scanner.fill", "externaldrive.fill", "server.rack", "network",
            "terminal.fill", "curlybraces", "chevron.left.forwardslash.chevron.right", "lightbulb.fill",
            "brain.head.profile", "brain.head.profile.fill", "puzzlepiece.fill", "function", "chart.bar.fill", "chart.line.uptrend.xyaxis"
        ]),
        IconCategory(name: "餐饮与购物", icons: [
            "fork.knife", "takeoutbag.and.cup.and.straw.fill", "cup.and.saucer.fill", "mug.fill",
            "waterbottle.fill", "wineglass.fill", "birthday.cake.fill", "carrot.fill", "fish.fill",
            "basket.fill", "cart.fill", "cart.badge.plus", "bag.fill", "bag.badge.plus", "tshirt.fill",
            "shoe.fill", "handbag.fill", "sunglasses.fill", "watch.analog", "gift.fill", "creditcard.fill",
            "banknote.fill", "dollarsign.circle.fill", "yensign.circle.fill", "eurosign.circle.fill",
            "barcode", "qrcode", "storefront.fill", "building.2.crop.circle.fill"
        ]),
        IconCategory(name: "休闲与娱乐", icons: [
            "gamecontroller.fill", "arcade.stick.console.fill", "dice.fill", "puzzlepiece.fill",
            "music.note", "music.mic", "headphones", "hifispeaker.fill", "radio.fill", "guitars.fill",
            "pianokeys", "metronome.fill", "mic.fill", "theatermasks.fill", "ticket.fill",
            "film.fill", "popcorn.fill", "play.rectangle.fill", "tv.fill", "photo.fill", "camera.fill",
            "camera.aperture", "paintpalette.fill", "paintbrush.pointed.fill", "scribble.variable",
            "book.fill", "newspaper.fill", "quote.bubble.fill", "sparkles", "wand.and.stars",
            "party.popper.fill", "balloon.2.fill", "fireworks", "beach.umbrella.fill"
        ]),
        IconCategory(name: "自然与户外", icons: [
            "leaf.fill", "tree.fill", "tree.circle.fill", "camera.macro", "camera.macro.circle.fill",
            "mountain.2.fill", "water.waves", "drop.fill", "flame.fill", "wind", "snowflake",
            "sun.max.fill", "sunrise.fill", "sunset.fill", "moon.fill", "moon.stars.fill", "cloud.fill",
            "cloud.rain.fill", "cloud.snow.fill", "cloud.bolt.rain.fill", "umbrella.fill", "rainbow",
            "globe.americas.fill", "globe.asia.australia.fill", "map.fill", "binoculars.fill", "tent.fill",
            "tent.2.fill", "campfire", "backpack.fill", "fossil.shell.fill", "ladybug.fill", "ant.fill",
            "bird.fill", "fish.fill", "hare.fill", "tortoise.fill", "lizard.fill", "pawprint.fill"
        ]),
        IconCategory(name: "家庭与人物", icons: [
            "person.fill", "person.circle.fill", "person.crop.circle.fill", "person.2.fill", "person.3.fill",
            "person.2.circle.fill", "figure.stand", "figure.arms.open", "figure.wave", "figure.2.arms.open",
            "figure.and.child.holdinghands", "figure.2.and.child.holdinghands", "figure.child", "figure.dress.line.vertical.figure",
            "heart.fill", "heart.circle.fill", "house.and.flag.fill", "shared.with.you", "hand.wave.fill",
            "hands.clap.fill", "hand.raised.fill", "hand.thumbsup.fill", "face.smiling.fill", "mustache.fill",
            "eyeglasses", "sunglasses.fill", "tshirt.fill", "shoe.fill", "crown.fill", "comb.fill"
        ]),
        IconCategory(name: "居家与家务", icons: [
            "house.fill", "house.lodge.fill", "building.2.fill", "bed.double.fill", "sofa.fill",
            "chair.lounge.fill", "table.furniture.fill", "cabinet.fill", "lamp.desk.fill", "lamp.floor.fill",
            "lightbulb.fill", "fan.fill", "air.conditioner.horizontal.fill", "heater.vertical.fill",
            "refrigerator.fill", "oven.fill", "stove.fill", "washer.fill", "dryer.fill", "dishwasher.fill",
            "microwave.fill", "toilet.fill", "bathtub.fill", "shower.fill", "sink.fill",
            "water.waves", "bubbles.and.sparkles.fill", "trash.fill", "shippingbox.fill", "door.left.hand.closed",
            "key.fill", "lock.fill", "wifi", "sensor.fill", "powerplug.fill"
        ]),
        IconCategory(name: "健康与医疗", icons: [
            "cross.fill", "cross.case.fill", "stethoscope", "medical.thermometer.fill", "syringe.fill",
            "pills.fill", "pill.fill", "bandage.fill", "facemask.fill", "allergens.fill", "ear.fill",
            "eye.fill", "brain.fill", "lungs.fill", "heart.fill", "heart.text.clipboard.fill",
            "waveform.path.ecg", "waveform.path.ecg.rectangle.fill", "bed.double.fill", "figure.mind.and.body",
            "figure.mixed.cardio", "figure.highintensity.intervaltraining", "scalemass.fill", "dumbbell.fill",
            "waterbottle.fill", "fork.knife", "moon.zzz.fill", "zzz", "staroflife.fill"
        ]),
        IconCategory(name: "沟通与社交", icons: [
            "message.fill", "bubble.left.fill", "bubble.left.and.bubble.right.fill", "quote.bubble.fill",
            "ellipsis.bubble.fill", "phone.fill", "phone.arrow.up.right.fill", "video.fill", "envelope.fill",
            "envelope.open.fill", "paperplane.fill", "megaphone.fill", "speaker.wave.3.fill", "bell.fill",
            "person.2.fill", "person.3.fill", "person.crop.circle.badge.plus", "at", "number",
            "link", "globe", "network", "antenna.radiowaves.left.and.right", "wifi"
        ]),
        IconCategory(name: "照片与创作", icons: [
            "camera.fill", "camera.circle.fill", "camera.aperture", "photo.fill", "photo.on.rectangle.angled",
            "photo.stack.fill", "rectangle.stack.fill", "film.fill", "video.fill", "play.rectangle.fill",
            "viewfinder", "scope", "flashlight.on.fill", "wand.and.rays", "wand.and.stars", "sparkles",
            "paintpalette.fill", "paintbrush.fill", "paintbrush.pointed.fill", "pencil", "pencil.and.outline",
            "highlighter", "scribble", "lasso", "crop", "slider.horizontal.3", "camera.filters"
        ]),
        IconCategory(name: "工具与维修", icons: [
            "hammer.fill", "wrench.adjustable.fill", "screwdriver.fill", "wrench.and.screwdriver.fill",
            "gearshape.fill", "gearshape.2.fill", "ruler.fill", "level.fill", "move.3d", "rotate.3d.fill",
            "scissors", "paperclip", "link", "pin.fill", "mappin", "magnifyingglass", "flashlight.on.fill",
            "battery.100percent", "bolt.fill", "powerplug.fill", "fuelpump.fill", "shippingbox.fill",
            "archivebox.fill", "tray.full.fill", "folder.fill", "doc.fill", "printer.fill"
        ]),
        IconCategory(name: "科技与设备", icons: [
            "iphone", "ipad", "laptopcomputer", "desktopcomputer", "display", "applewatch",
            "headphones", "airpodspro", "hifispeaker.fill", "homepodmini.fill", "tv.fill", "appletv.fill",
            "gamecontroller.fill", "keyboard.fill", "computermouse.fill", "printer.fill", "scanner.fill",
            "externaldrive.fill", "server.rack", "network", "wifi", "antenna.radiowaves.left.and.right",
            "sensor.fill", "memorychip.fill", "cpu.fill", "opticaldisc.fill", "battery.100percent",
            "bolt.fill", "powerplug.fill", "cable.connector", "terminal.fill"
        ]),
        IconCategory(name: "地点与建筑", icons: [
            "mappin", "mappin.circle.fill", "mappin.and.ellipse", "location.fill", "map.fill",
            "house.fill", "building.fill", "building.2.fill", "building.columns.fill", "storefront.fill",
            "house.lodge.fill", "tent.fill", "hospital.fill", "cross.fill", "graduationcap.fill",
            "studentdesk", "sportscourt.fill", "parkingsign.circle.fill", "fuelpump.fill", "ev.charger.fill",
            "tram.fill", "airplane", "ferry.fill", "water.waves", "mountain.2.fill", "tree.fill",
            "signpost.right.and.left.fill", "flag.fill"
        ]),
        IconCategory(name: "状态与标记", icons: [
            "circle.fill", "square.fill", "diamond.fill", "triangle.fill", "hexagon.fill", "seal.fill",
            "checkmark.circle.fill", "xmark.circle.fill", "plus.circle.fill", "minus.circle.fill",
            "questionmark.circle.fill", "exclamationmark.circle.fill", "info.circle.fill", "checkmark.seal.fill",
            "star.fill", "heart.fill", "flag.fill", "bookmark.fill", "pin.fill", "tag.fill",
            "bolt.fill", "flame.fill", "sparkles", "crown.fill", "medal.fill", "trophy.fill",
            "hourglass", "timer", "clock.fill", "calendar", "repeat", "arrow.triangle.2.circlepath"
        ])
    ]

    private var iconCategories: [IconCategory] {
        let query = iconSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return Self.allIconCategories.compactMap { category in
            let availableIcons = category.icons.filter { iconName in
                UIImage(systemName: iconName) != nil
                    && (query.isEmpty || iconName.localizedCaseInsensitiveContains(query))
            }
            guard !availableIcons.isEmpty else { return nil }
            return IconCategory(name: category.name, icons: availableIcons)
        }
    }
    
    let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
        .gray, Color(white: 0.2), Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 1.0, green: 0.4, blue: 0.4), Color(red: 0.4, green: 0.9, blue: 0.4), Color(red: 0.8, green: 0.6, blue: 1.0)
    ]
    
    init(activity: ActivityType? = nil) {
        self.activity = activity
        self._name = State(initialValue: activity?.name ?? "")
        self._icon = State(initialValue: activity?.icon ?? "tag.fill")
        self._selectedColor = State(initialValue: activity?.color ?? .blue)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基础信息").font(.caption)) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(selectedColor.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Image(systemName: icon)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(selectedColor)
                        }
                        
                        TextField("活动名称", text: $name)
                            .font(.body)
                    }
                }
                
                Section(header: Text("活动颜色").font(.caption)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { colorOption in
                            Button {
                                self.selectedColor = colorOption
                            } label: {
                                Circle()
                                    .fill(colorOption)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: selectedColor == colorOption ? 2 : 0)
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
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("搜索图标名称", text: $iconSearchText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !iconSearchText.isEmpty {
                                Button {
                                    iconSearchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

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
                                                .background(icon == iconName ? selectedColor.opacity(0.15) : Color.clear)
                                                .foregroundColor(icon == iconName ? selectedColor : .secondary.opacity(0.8))
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
                    Button { dismiss() } label: { Image(systemName: "xmark").dfkToolbarDismissIcon() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let activity = activity {
                    name = activity.name
                    icon = activity.icon
                    selectedColor = activity.color
                }
            }
        }
    }
    
    private func save() {
        if let activity = activity {
            activity.name = name
            activity.icon = icon
            activity.colorHex = selectedColor.toHex()
        } else {
            let newActivity = ActivityType(name: name, icon: icon, colorHex: selectedColor.toHex(), sortOrder: 99)
            modelContext.insert(newActivity)
        }
        try? modelContext.save()
        CloudSettingsManager.shared.triggerDataSyncPulse()
    }
}
