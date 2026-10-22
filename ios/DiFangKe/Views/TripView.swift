import SwiftUI
import SwiftData
import MapKit
import Photos

struct TripView: View {
    var isActive = true
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.plannedStartDay, order: .reverse) private var trips: [Trip]
    @Query private var homeCities: [HomeCity]
    @Query private var tripDays: [TripDay]
    @Query private var tripCities: [TripDayCity]
    @Query private var tripItems: [TripItem]
    @State private var scanManager = TripScanManager.shared
    @State private var showingCreate = false
    @State private var showingOptions = false
    @State private var showingIntroduction = false
    @State private var selectedTrip: Trip?
    @State private var editingTrip: Trip?
    @State private var splittingTrip: Trip?
    @State private var deletingTrip: Trip?
    @State private var isSelecting = false
    @State private var selectedTripIDs = Set<UUID>()
    @State private var confirmingDelete = false
    @State private var confirmingMerge = false
    @State private var isPhotoImportRequested = false
    @State private var activeCardBottom: CGFloat = .greatestFiniteMagnitude
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var createActivityStyles: [TripActivityStyle] = []

    private var activeTrip: Trip? { trips.first { $0.state == .active } }
    private var remainingTrips: [Trip] {
        trips.filter { $0.state != .active }.sorted {
            if $0.state == .planned && $1.state != .planned { return true }
            if $0.state != .planned && $1.state == .planned { return false }
            return $0.state == .planned
                ? $0.plannedStartDay < $1.plannedStartDay
                : $0.plannedStartDay > $1.plannedStartDay
        }
    }
    private var yearSections: [TripYearSection] {
        let grouped = Dictionary(grouping: remainingTrips) {
            Calendar.autoupdatingCurrent.component(.year, from: $0.plannedStartDay)
        }
        return grouped.keys.sorted(by: >).map { TripYearSection(year: $0, trips: grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                if let activeTrip {
                    TripListCard(
                        trip: activeTrip,
                        homeCity: homeCities.first,
                        activityStyle: activityStyle(for: activeTrip),
                        allDays: tripDays,
                        allCities: tripCities,
                        allItems: tripItems,
                        prominent: true,
                        isSelecting: isSelecting,
                        isSelected: selectedTripIDs.contains(activeTrip.id)
                    ) {
                        selectOrOpen(activeTrip)
                    } onSelectionTap: {
                        toggleSelection(activeTrip)
                    }
                    .padding(.horizontal)
                    .contextMenu {
                        tripContextMenu(for: activeTrip)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ActiveTripBottomPreferenceKey.self,
                                value: proxy.frame(in: .named("tripScroll")).maxY
                            )
                        }
                    }
                }

                ForEach(yearSections) { section in
                    Section {
                        ForEach(section.trips) { trip in
                            TripListCard(
                                trip: trip,
                                homeCity: homeCities.first,
                                activityStyle: activityStyle(for: trip),
                                allDays: tripDays,
                                allCities: tripCities,
                                allItems: tripItems,
                                prominent: false,
                                isSelecting: isSelecting,
                                isSelected: selectedTripIDs.contains(trip.id)
                            ) {
                                selectOrOpen(trip)
                            } onSelectionTap: {
                                toggleSelection(trip)
                            }
                            .padding(.horizontal)
                            .contextMenu {
                                tripContextMenu(for: trip)
                            }
                        }
                    } header: {
                        Text(verbatim: "\(section.year)年")
                            .font(.title2.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .dfkDetailMaterial(in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                }

                if trips.isEmpty {
                    ContentUnavailableView(
                        "还没有行程",
                        systemImage: "map",
                        description: Text("从照片导入足迹，或点右上角创建第一段行程。")
                    )
                    .padding(.top, 80)
                }

                if scanManager.isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在整理行程…")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                }
            }
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await scanManager.scanMissingTrips()
        }
        .coordinateSpace(name: "tripScroll")
        .onPreferenceChange(ActiveTripBottomPreferenceKey.self) { activeCardBottom = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let activeTrip, activeCardBottom < 12, !isSelecting {
                Button {
                    selectedTrip = activeTrip
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(activeTrip.title).fontWeight(.semibold).lineLimit(1)
                        Text("· \(activeTripDayText(activeTrip))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.bold())
                    }
                    .padding(.horizontal)
                    .frame(height: 46)
                    .background(.regularMaterial)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .navigationTitle(isSelecting ? "已选择 \(selectedTripIDs.count) 项" : "出行")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if isSelecting {
                    Button(selectedTripIDs.count == trips.count ? "取消全选" : "全选") {
                        selectedTripIDs = selectedTripIDs.count == trips.count ? [] : Set(trips.map(\.id))
                    }
                } else {
                    Button { isPhotoImportRequested = true } label: {
                        Image(systemName: "square.and.arrow.down.badge.clock")
                    }
                    .accessibilityLabel("从照片导入足迹")
                    .disabled(scanManager.recordModelContainer == nil)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button("完成") { endSelection() }
                } else {
                    Button {
                        createActivityStyles = activityStyles
                        showingCreate = true
                    } label: {
                        Label("创建行程", systemImage: "plus")
                    }
                    Button { showingOptions = true } label: {
                        Label("出行设置", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                HStack(spacing: 12) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("删除", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedTripIDs.isEmpty)

                    Button { confirmingMerge = true } label: {
                        Label("合并", systemImage: "arrow.triangle.merge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTripIDs.count < 2)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateTripView(activityStyles: createActivityStyles)
        }
        .sheet(isPresented: $showingOptions) { TripOptionsView() }
        .sheet(item: $editingTrip) { trip in
            TripEditorView(trip: trip)
        }
        .sheet(item: $splittingTrip) { trip in
            TripSplitView(
                trip: trip,
                days: tripDays.filter { $0.tripID == trip.id },
                cities: tripCities
            ) { secondStartDay in
                splitTrip(trip, secondStartDay: secondStartDay)
            }
        }
        .photoImportFlow(
            isRequested: $isPhotoImportRequested,
            modelContainer: scanManager.recordModelContainer
        )
        .fullScreenCover(item: $selectedTrip) { trip in
            TripDetailView(trip: trip) {
                selectedTrip = nil
            }
        }
        .onChange(of: isActive) { _, isActive in
            // Deep links (including Live Activity taps) switch to Records
            // while this full-screen cover can still be presented. Dismiss it
            // with the tab transition so the Records timeline is never layered
            // over a stale trip detail.
            if !isActive {
                selectedTrip = nil
            }
        }
        .sheet(isPresented: $showingIntroduction) {
            TripIntroductionView {
                scanManager.scanIfNeeded(force: true)
            }
        }
        .alert(
            "删除所选的 \(selectedTripIDs.count) 个行程？",
            isPresented: $confirmingDelete
        ) {
            Button("删除行程", role: .destructive) { deleteSelectedTrips() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("所选行程将从出行列表中删除，原来的足迹、交通和照片仍会保留。")
        }
        .alert(
            "删除行程？",
            isPresented: Binding(
                get: { deletingTrip != nil },
                set: { if !$0 { deletingTrip = nil } }
            ),
            presenting: deletingTrip
        ) { trip in
            Button("删除行程", role: .destructive) {
                deleteTrips(ids: [trip.id])
                deletingTrip = nil
            }
            Button("取消", role: .cancel) { deletingTrip = nil }
        } message: { trip in
            Text("“\(trip.title)”将从出行列表中删除，原来的足迹、交通和照片仍会保留。")
        }
        .confirmationDialog(
            "合并所选的 \(selectedTripIDs.count) 个行程？",
            isPresented: $confirmingMerge,
            titleVisibility: .visible
        ) {
            Button("合并行程") { mergeSelectedTrips() }
        } message: {
            Text("所选行程将合成一段，日期、城市、照片和备注都会保留。")
        }
        .task {
            activityStyles = await TripScanManager.shared.activityStyles()
            if !UserDefaults.standard.bool(forKey: "tripIntroductionCompleted") {
                showingIntroduction = true
            } else {
                scanManager.scanIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            DFKMapSnapshotCache.shared.removeAllMemoryImages()
            PhotoService.shared.clearTransientCaches()
            scanManager.pauseForAppBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            scanManager.resumeAfterAppForeground()
        }
    }

    private func activityStyle(for trip: Trip) -> TripActivityStyle? {
        guard let value = trip.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }

    private func activeTripDayText(_ trip: Trip) -> String {
        let start = Calendar.current.startOfDay(for: trip.actualStartedAt ?? trip.plannedStartDay)
        let days = max(1, (Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0) + 1)
        return "第\(days)天"
    }

    private func selectOrOpen(_ trip: Trip) {
        guard isSelecting else {
            selectedTrip = trip
            return
        }
        if selectedTripIDs.contains(trip.id) { selectedTripIDs.remove(trip.id) }
        else { selectedTripIDs.insert(trip.id) }
    }

    private func beginSelection(with trip: Trip) {
        isSelecting = true
        selectedTripIDs = [trip.id]
    }

    @ViewBuilder
    private func tripContextMenu(for trip: Trip) -> some View {
        Button {
            beginSelection(with: trip)
        } label: {
            Label("选择", systemImage: "checkmark.circle")
        }

        Button {
            editingTrip = trip
        } label: {
            Label("编辑", systemImage: "pencil")
        }

        if canSplit(trip) {
            Button {
                splittingTrip = trip
            } label: {
                Label("拆分", systemImage: "scissors")
            }
        }

        Divider()

        Button(role: .destructive) {
            deletingTrip = trip
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func toggleSelection(_ trip: Trip) {
        if !isSelecting {
            beginSelection(with: trip)
        } else if selectedTripIDs.contains(trip.id) {
            selectedTripIDs.remove(trip.id)
        } else {
            selectedTripIDs.insert(trip.id)
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedTripIDs.removeAll()
    }

    private func deleteSelectedTrips() {
        deleteTrips(ids: selectedTripIDs)
        endSelection()
    }

    private func deleteTrips(ids tripIDs: Set<UUID>) {
        let selected = trips.filter { tripIDs.contains($0.id) }
        scanManager.suppressAutomaticRegeneration(for: selected)
        let selectedDays = fetchDays().filter { tripIDs.contains($0.tripID) }
        let dayIDs = Set(selectedDays.map(\.id))
        fetchItems().filter { dayIDs.contains($0.tripDayID) }.forEach { context.delete($0) }
        fetchCities().filter { dayIDs.contains($0.tripDayID) }.forEach { context.delete($0) }
        selectedDays.forEach { context.delete($0) }
        selected.forEach { context.delete($0) }
        try? context.save()
    }

    private func canSplit(_ trip: Trip) -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: trip.plannedStartDay)
        let end = calendar.startOfDay(for: trip.plannedEndDay)
        return start < end && tripDays.contains {
            $0.tripID == trip.id && calendar.startOfDay(for: $0.day) > start
        }
    }

    private func splitTrip(_ trip: Trip, secondStartDay: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let splitDay = calendar.startOfDay(for: secondStartDay)
        let days = fetchDays().filter { $0.tripID == trip.id }.sorted { $0.day < $1.day }
        let firstDays = days.filter { calendar.startOfDay(for: $0.day) < splitDay }
        let secondDays = days.filter { calendar.startOfDay(for: $0.day) >= splitDay }
        guard !firstDays.isEmpty, !secondDays.isEmpty,
              let firstEndDay = calendar.date(byAdding: .day, value: -1, to: splitDay) else { return }

        scanManager.suppressAutomaticRegeneration(for: [trip])
        let cities = fetchCities()
        let items = fetchItems()
        let originalTitle = trip.title
        let originalEndDay = trip.plannedEndDay
        let originalActualStartedAt = trip.actualStartedAt
        let originalActualEndedAt = trip.actualEndedAt
        let originalEndReasonRaw = trip.endReasonRaw
        let newTrip = Trip(
            title: originalTitle,
            notes: trip.notes,
            kind: trip.kind,
            state: trip.state,
            origin: .manual,
            plannedStartDay: splitDay,
            plannedEndDay: originalEndDay
        )
        newTrip.activityTypeValue = trip.activityTypeValue
        newTrip.homeCityKeyAtCreation = trip.homeCityKeyAtCreation
        newTrip.titleUserEdited = trip.titleUserEdited
        newTrip.datesUserEdited = true
        newTrip.citiesUserEdited = trip.citiesUserEdited
        newTrip.coverTypeRaw = trip.coverTypeRaw
        newTrip.coverPhotoIdentifier = trip.coverPhotoIdentifier
        newTrip.endReasonRaw = originalEndReasonRaw
        newTrip.createdAt = Date()
        newTrip.updatedAt = Date()
        context.insert(newTrip)

        secondDays.forEach { $0.tripID = newTrip.id }
        for (index, day) in firstDays.enumerated() { day.orderIndex = index }
        for (index, day) in secondDays.enumerated() { day.orderIndex = index }

        trip.plannedEndDay = firstEndDay
        trip.originRaw = TripOrigin.manual.rawValue
        trip.datesUserEdited = true
        trip.endReasonRaw = nil
        trip.updatedAt = Date()

        if !trip.titleUserEdited {
            trip.title = title(for: firstDays, cities: cities, fallback: originalTitle)
            newTrip.title = title(for: secondDays, cities: cities, fallback: originalTitle)
        }

        let firstDayIDs = Set(firstDays.map(\.id))
        let secondDayIDs = Set(secondDays.map(\.id))
        let firstItems = items.filter { firstDayIDs.contains($0.tripDayID) }
        let secondItems = items.filter { secondDayIDs.contains($0.tripDayID) }
        trip.actualStartedAt = originalActualStartedAt
        trip.actualEndedAt = firstItems.compactMap { $0.endTime ?? $0.startTime }.max()
            ?? originalActualEndedAt.flatMap { $0 < splitDay ? $0 : nil }
        newTrip.actualStartedAt = secondItems.compactMap(\.startTime).min()
            ?? originalActualStartedAt.flatMap { $0 >= splitDay ? $0 : nil }
        newTrip.actualEndedAt = originalActualEndedAt

        applyDateDerivedState(to: trip)
        applyDateDerivedState(to: newTrip)
        try? context.save()
    }

    private func title(for days: [TripDay], cities: [TripDayCity], fallback: String) -> String {
        let title = uniqueJoined(
            days.sorted { $0.day < $1.day }.flatMap { day in
                cities.filter { $0.tripDayID == day.id }
                    .sorted { $0.orderIndex < $1.orderIndex }
                    .map(\.cityName)
            },
            separator: "、"
        )
        return title.isEmpty ? fallback : title
    }

    private func mergeSelectedTrips() {
        let selected = trips.filter { selectedTripIDs.contains($0.id) }
            .sorted { $0.plannedStartDay < $1.plannedStartDay }
        guard let target = selected.first, selected.count > 1 else { return }
        let sources = Array(selected.dropFirst())
        let allDays = fetchDays()
        let allCities = fetchCities()
        let allItems = fetchItems()
        var targetDays = allDays.filter { $0.tripID == target.id }
        let calendar = Calendar.autoupdatingCurrent

        for source in sources {
            for sourceDay in allDays where sourceDay.tripID == source.id {
                if let existingDay = targetDays.first(where: { calendar.isDate($0.day, inSameDayAs: sourceDay.day) }) {
                    existingDay.notes = mergedText(existingDay.notes, sourceDay.notes)
                    var cityKeys = Set(allCities.filter { $0.tripDayID == existingDay.id }.map(cityKey))
                    for city in allCities where city.tripDayID == sourceDay.id {
                        if cityKeys.insert(cityKey(city)).inserted { city.tripDayID = existingDay.id }
                        else { context.delete(city) }
                    }
                    var itemKeys = Set(allItems.filter { $0.tripDayID == existingDay.id }.map(itemKey))
                    for item in allItems where item.tripDayID == sourceDay.id {
                        if itemKeys.insert(itemKey(item)).inserted { item.tripDayID = existingDay.id }
                        else { context.delete(item) }
                    }
                    context.delete(sourceDay)
                } else {
                    sourceDay.tripID = target.id
                    targetDays.append(sourceDay)
                }
            }
            context.delete(source)
        }

        target.title = mergedTripTitle(selected.map(\.title))
        target.notes = uniqueJoined(selected.map(\.notes), separator: "\n\n")
        target.activityTypeValue = selected.compactMap(\.activityTypeValue).first
        target.plannedStartDay = selected.map(\.plannedStartDay).min() ?? target.plannedStartDay
        target.plannedEndDay = selected.map(\.plannedEndDay).max() ?? target.plannedEndDay
        var cursor = calendar.startOfDay(for: target.plannedStartDay)
        let finalDay = calendar.startOfDay(for: target.plannedEndDay)
        while cursor <= finalDay {
            if !targetDays.contains(where: { calendar.isDate($0.day, inSameDayAs: cursor) }) {
                let day = TripDay(tripID: target.id, day: cursor, orderIndex: targetDays.count)
                context.insert(day)
                targetDays.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        target.actualStartedAt = selected.compactMap(\.actualStartedAt).min()
        target.actualEndedAt = selected.compactMap(\.actualEndedAt).max()
        target.originRaw = selected.contains { $0.originRaw == TripOrigin.manual.rawValue }
            ? TripOrigin.manual.rawValue : TripOrigin.automatic.rawValue
        target.titleUserEdited = selected.contains { $0.titleUserEdited }
        target.datesUserEdited = true
        target.citiesUserEdited = selected.contains { $0.citiesUserEdited }
        applyDateDerivedState(to: target)
        if target.state == .active, target.actualStartedAt == nil { target.actualStartedAt = target.plannedStartDay }
        target.updatedAt = Date()
        for (index, day) in targetDays.sorted(by: { $0.day < $1.day }).enumerated() { day.orderIndex = index }
        for day in targetDays {
            for (index, city) in allCities.filter({ $0.tripDayID == day.id }).sorted(by: { $0.orderIndex < $1.orderIndex }).enumerated() {
                city.orderIndex = index
            }
            for (index, item) in allItems.filter({ $0.tripDayID == day.id }).sorted(by: {
                ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
            }).enumerated() {
                item.orderIndex = index
            }
        }
        try? context.save()
        endSelection()
    }

    private func applyDateDerivedState(to trip: Trip) {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        if trip.plannedEndDay < today { trip.state = .historical; trip.kind = .historical }
        else if trip.plannedStartDay <= today { trip.state = .active; trip.kind = .historical }
        else { trip.state = .planned; trip.kind = .planned }
    }

    private func fetchDays() -> [TripDay] { (try? context.fetch(FetchDescriptor<TripDay>())) ?? [] }
    private func fetchCities() -> [TripDayCity] { (try? context.fetch(FetchDescriptor<TripDayCity>())) ?? [] }
    private func fetchItems() -> [TripItem] { (try? context.fetch(FetchDescriptor<TripItem>())) ?? [] }
    private func cityKey(_ city: TripDayCity) -> String { "\(city.countryCode)|\(city.cityName)".lowercased() }
    private func itemKey(_ item: TripItem) -> String {
        if let id = item.sourceFootprintID { return "f:\(id)" }
        if let id = item.sourceTransportRecordID { return "t:\(id)" }
        return "\(item.kindRaw)|\(item.startTime?.timeIntervalSince1970 ?? 0)|\(item.placeName ?? "")|\(item.lineName ?? "")"
    }
    private func uniqueJoined(_ values: [String], separator: String) -> String {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: separator)
    }
    private func mergedTripTitle(_ titles: [String]) -> String {
        let separators = CharacterSet(charactersIn: "、,，·")
        let parts = titles.flatMap { title in
            title.components(separatedBy: separators)
        }
        return uniqueJoined(parts, separator: "、")
    }
    private func mergedText(_ target: String, _ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !target.contains(value) else { return target }
        return target.isEmpty ? value : "\(target)\n\n\(value)"
    }
}

private struct TripSplitView: View {
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let days: [TripDay]
    let cities: [TripDayCity]
    let onSplit: (Date) -> Void
    @State private var secondStartDay: Date
    @State private var isSplitting = false

    private let calendar = Calendar.autoupdatingCurrent

    init(trip: Trip, days: [TripDay], cities: [TripDayCity], onSplit: @escaping (Date) -> Void) {
        self.trip = trip
        self.days = days
        self.cities = cities
        self.onSplit = onSplit
        let start = Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedStartDay)
        _secondStartDay = State(initialValue: Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    private var earliestDay: Date {
        let start = calendar.startOfDay(for: trip.plannedStartDay)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }

    private var latestDay: Date {
        calendar.startOfDay(for: trip.plannedEndDay)
    }

    private var firstSegmentDays: [TripDay] {
        days.filter { calendar.startOfDay(for: $0.day) < calendar.startOfDay(for: secondStartDay) }
    }

    private var secondSegmentDays: [TripDay] {
        days.filter { calendar.startOfDay(for: $0.day) >= calendar.startOfDay(for: secondStartDay) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "第二段开始日期",
                        selection: $secondStartDay,
                        in: earliestDay...latestDay,
                        displayedComponents: .date
                    )
                } footer: {
                    Text("这一天及之后的行程内容会移到第二段，原来的足迹、交通和照片不会改变。")
                }
                Section("拆分预览") {
                    segmentPreview(
                        title: "第一段",
                        start: calendar.startOfDay(for: trip.plannedStartDay),
                        end: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: secondStartDay)) ?? trip.plannedStartDay,
                        days: firstSegmentDays
                    )
                    segmentPreview(
                        title: "第二段",
                        start: calendar.startOfDay(for: secondStartDay),
                        end: calendar.startOfDay(for: trip.plannedEndDay),
                        days: secondSegmentDays
                    )
                }
            }
            .navigationTitle("拆分行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("拆分") {
                        guard !isSplitting else { return }
                        isSplitting = true
                        onSplit(calendar.startOfDay(for: secondStartDay))
                        dismiss()
                    }
                    .disabled(isSplitting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func segmentPreview(title: String, start: Date, end: Date, days: [TripDay]) -> some View {
        let cityNames = orderedCityNames(for: days)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(dateRangeText(start, end)).foregroundStyle(.secondary)
            }
            if cityNames.isEmpty {
                Text("暂无城市").font(.subheadline).foregroundStyle(.tertiary)
            } else {
                Text(cityNames.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func orderedCityNames(for days: [TripDay]) -> [String] {
        var seen = Set<String>()
        return days.sorted { $0.day < $1.day }.flatMap { day in
            cities.filter { $0.tripDayID == day.id }
                .sorted { $0.orderIndex < $1.orderIndex }
        }.map(\.cityName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func dateRangeText(_ start: Date, _ end: Date) -> String {
        let format = Date.FormatStyle.dateTime.year().month().day()
        return calendar.isDate(start, inSameDayAs: end)
            ? start.formatted(format)
            : "\(start.formatted(format))–\(end.formatted(format))"
    }
}

private struct ActiveTripBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TripYearSection: Identifiable {
    let year: Int
    let trips: [Trip]
    var id: Int { year }
}

private struct TripListCard: View {
    let trip: Trip
    let homeCity: HomeCity?
    let activityStyle: TripActivityStyle?
    let allDays: [TripDay]
    let allCities: [TripDayCity]
    let allItems: [TripItem]
    let prominent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onSelectionTap: () -> Void
    private var cityNames: [String] {
        let dayIDs = Set(allDays.filter { $0.tripID == trip.id }.map(\.id))
        var seen = Set<String>()
        return allCities
            .filter { dayIDs.contains($0.tripDayID) }
            .sorted { $0.orderIndex < $1.orderIndex }
            .compactMap { city in
                let name = city.cityName.trimmingCharacters(in: .whitespacesAndNewlines)
                return !name.isEmpty && seen.insert(name).inserted ? name : nil
            }
    }

    private var tripItems: [TripItem] {
        let dayIDs = Set(allDays.filter { $0.tripID == trip.id }.map(\.id))
        return allItems.filter { dayIDs.contains($0.tripDayID) }.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var tripCities: [TripDayCity] {
        let dayIDs = Set(allDays.filter { $0.tripID == trip.id }.map(\.id))
        return allCities.filter { dayIDs.contains($0.tripDayID) }.sorted { $0.orderIndex < $1.orderIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TripListCardHero(
                layoutSeed: trip.id.uuidString,
                items: tripItems,
                cities: tripCities,
                homeCity: homeCity,
                actualDayRequests: trip.state != .planned ? allDays.filter { $0.tripID == trip.id }.map {
                    TripActualDayRequest(id: $0.id, day: $0.day, timeZoneIdentifier: $0.timeZoneIdentifier)
                } : [],
                cardColor: cardColor
            )
                .frame(height: (prominent ? 154 : 132) + 36)
                .padding(.bottom, -36)
                .zIndex(0)
            VStack(alignment: .leading, spacing: prominent ? 12 : 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.title.isEmpty ? "未命名行程" : trip.title)
                        .font(prominent ? .title2.bold() : .headline)
                        .lineLimit(2)
                    Spacer()
                }
                if !cityNames.isEmpty || activityStyle != nil {
                    HStack(spacing: 10) {
                        if !cityNames.isEmpty {
                            Label(cityNames.joined(separator: " · "), systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let activityStyle {
                            Label(activityStyle.name, systemImage: activityStyle.icon)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color(hex: activityStyle.colorHex) ?? .secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                HStack {
                    Label(dateRangeText, systemImage: "calendar")
                    Spacer()
                    Text(dayCountText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if prominent {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.green.opacity(0.09))
                        .frame(height: 76)
                        .overlay {
                            HStack {
                                Image(systemName: "map.fill").foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text("行程进行中").fontWeight(.semibold)
                                    Text("查看路线和行程记录")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding()
                        }
                }
            }
            .padding()
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onSelect)
        .overlay(alignment: .topLeading) {
            if isSelecting {
                Button(action: onSelectionTap) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.dfkAccent : .primary)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消选择行程" : "选择行程")
                .padding(12)
            }
        }
    }

    private var cardColor: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var dateRangeText: String {
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "zh_CN")
        startFormatter.dateFormat = "M月d日"
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "zh_CN")
        endFormatter.dateFormat = "M月d日"
        if Calendar.current.isDate(trip.plannedStartDay, inSameDayAs: trip.plannedEndDay) {
            return startFormatter.string(from: trip.plannedStartDay)
        }
        return "\(startFormatter.string(from: trip.plannedStartDay))—\(endFormatter.string(from: trip.plannedEndDay))"
    }

    private var dayCountText: String {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: trip.plannedStartDay)
        let end = calendar.startOfDay(for: trip.plannedEndDay)
        let count = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        return "共\(count)天"
    }
}

private struct TripListCardHero: View {
    let layoutSeed: String
    let items: [TripItem]
    let cities: [TripDayCity]
    let homeCity: HomeCity?
    let actualDayRequests: [TripActualDayRequest]
    let cardColor: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var mapImage: UIImage?
    @State private var photos: [UIImage] = []
    @State private var renderSize: CGSize = .zero
    @State private var isVisible = false

    private var signature: String {
        let itemPart = items.map { "\($0.id)|\($0.latitude ?? 0)|\($0.longitude ?? 0)|\($0.activityTypeValue ?? "")|\($0.transportTypeRaw ?? "")|\($0.sourceFootprintID?.uuidString ?? "")|\($0.sourceTransportRecordID?.uuidString ?? "")" }.joined(separator: ";")
        let cityPart = cities.map { "\($0.id)|\($0.latitude ?? 0)|\($0.longitude ?? 0)" }.joined(separator: ";")
        let dayPart = actualDayRequests.map { "\($0.id)|\($0.day.timeIntervalSinceReferenceDate)|\($0.timeZoneIdentifier)" }.joined(separator: ";")
        let homePart = homeCity.map { "\($0.countryCode)|\($0.cityName)|\($0.latitude ?? 0)|\($0.longitude ?? 0)" } ?? ""
        return "\(itemPart)#\(cityPart)#\(dayPart)#\(homePart)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Group {
                    if let mapImage {
                        Image(uiImage: mapImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        cardColor.overlay {
                            Image(systemName: "map")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()

                LinearGradient(
                    colors: [.clear, cardColor.opacity(0.2), cardColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)

                if !photos.isEmpty {
                    TripListPhotoStack(images: photos, layoutSeed: layoutSeed)
                        .padding(.trailing, 12)
                        .padding(.top, 18)
                        .offset(y: -8)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                isVisible = true
                updateRenderSize(proxy.size)
            }
            .onDisappear {
                isVisible = false
            }
            .onChange(of: proxy.size) { _, size in updateRenderSize(size) }
        }
        .task(id: "\(signature)|\(colorScheme)|\(Int(renderSize.width.rounded()))x\(Int(renderSize.height.rounded()))") {
            guard renderSize.width > 1, renderSize.height > 1 else { return }
            let actualSnapshots: [TripActualItemSnapshot]
            if actualDayRequests.isEmpty { actualSnapshots = [] }
            else { actualSnapshots = await TripScanManager.shared.actualItems(for: actualDayRequests) }
            let footprintIDs: [UUID]
            let transportIDs: Set<UUID>
            let itemStops: [TripMapStopCoordinate]
            if actualDayRequests.isEmpty {
                footprintIDs = items.compactMap(\.sourceFootprintID)
                transportIDs = Set(items.compactMap(\.sourceTransportRecordID))
                itemStops = items.compactMap { item in
                    guard item.kindRaw == TripItemKind.stop.rawValue,
                          let latitude = item.latitude, let longitude = item.longitude else { return nil }
                    return TripMapStopCoordinate(cityName: item.cityName, countryCode: item.countryCode, latitude: latitude, longitude: longitude, activityTypeValue: item.activityTypeValue)
                }
            } else {
                footprintIDs = actualSnapshots.compactMap(\.sourceFootprintID)
                transportIDs = Set(actualSnapshots.compactMap(\.sourceTransportRecordID))
                itemStops = actualSnapshots.compactMap { item in
                    guard item.kind == .stop, let latitude = item.latitude, let longitude = item.longitude else { return nil }
                    return TripMapStopCoordinate(cityName: item.cityName, countryCode: item.countryCode, latitude: latitude, longitude: longitude, activityTypeValue: item.activityTypeValue)
                }
            }
            let nonHomeItemCoordinates = itemStops.compactMap { stop -> CLLocationCoordinate2D? in
                let coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return tripCityMatchesHome(cityName: stop.cityName, countryCode: stop.countryCode, homeCity: homeCity) ? nil : coordinate
            }
            let nonHomeCityCoordinates = cities.compactMap { city -> CLLocationCoordinate2D? in
                guard let latitude = city.latitude, let longitude = city.longitude else { return nil }
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return tripCityMatchesHome(cityName: city.cityName, countryCode: city.countryCode, homeCity: homeCity) ? nil : coordinate
            }
            // The card camera is city-level. Prefer standardized trip cities so
            // home-city stops and route endpoints cannot pull the framing home.
            let stopCoordinates = nonHomeCityCoordinates.isEmpty ? nonHomeItemCoordinates : nonHomeCityCoordinates
            async let routes = TripScanManager.shared.transportRoutes(for: transportIDs)
            async let activityStyles = TripScanManager.shared.activityStyles()
            let loadedAssetIDs: [String]
            if actualDayRequests.isEmpty {
                loadedAssetIDs = await TripScanManager.shared.tripCardPhotoAssetIDs(
                    for: footprintIDs,
                    perFootprintLimit: .max,
                    totalLimit: .max
                )
            } else {
                var seenAssetIDs = Set<String>()
                let snapshotAssetIDs = actualSnapshots
                    .flatMap(\.photoAssetIDs)
                    .filter { seenAssetIDs.insert($0).inserted }
                if snapshotAssetIDs.isEmpty {
                    loadedAssetIDs = await TripScanManager.shared.tripCardPhotoAssetIDs(
                        for: footprintIDs,
                        perFootprintLimit: .max,
                        totalLimit: .max
                    )
                } else {
                    loadedAssetIDs = snapshotAssetIDs
                }
            }
            let displayableAssetIDs = PhotoService.shared.displayableAssetIDs(loadedAssetIDs)
            let sampledAssetIDs = sampledPhotoAssetIDs(from: displayableAssetIDs, limit: 5)
            async let loadedPhotos = TripListPhotoLoader.images(for: sampledAssetIDs)
            let routeDictionary = await routes
            let loadedStyles = await activityStyles
            var styleByValue: [String: TripActivityStyle] = [:]
            for style in loadedStyles {
                styleByValue[style.id] = style
                styleByValue[style.name] = style
            }
            let stopMarkers = itemStops.compactMap { stop -> TripCardMapStopMarker? in
                let coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
                guard coordinate.isRenderableMapCoordinate,
                      !tripCityMatchesHome(cityName: stop.cityName, countryCode: stop.countryCode, homeCity: homeCity) else { return nil }
                let style = stop.activityTypeValue.flatMap { styleByValue[$0] }
                return TripCardMapStopMarker(
                    coordinate: coordinate,
                    icon: style?.icon ?? FootprintIconDefaults.card,
                    tint: Color(hex: style?.colorHex ?? "") ?? .gray
                )
            }
            let routeSegments = routeDictionary.flatMap { sourceID, points in
                TripMapRouteSegment.make(sourceID: sourceID, points: points)
            }
            var transportTypeByID: [UUID: String] = [:]
            if actualDayRequests.isEmpty {
                for item in items {
                    if let sourceID = item.sourceTransportRecordID { transportTypeByID[sourceID] = item.transportTypeRaw ?? "" }
                }
            } else {
                for item in actualSnapshots {
                    if let sourceID = item.sourceTransportRecordID { transportTypeByID[sourceID] = item.transportTypeRaw ?? "" }
                }
            }
            let transportMarkers = routeDictionary.compactMap { sourceID, points -> TripCardMapTransportMarker? in
                let coordinates = TripMapRouteSegment.make(sourceID: sourceID, points: points)
                    .flatMap(\.coordinates)
                    .filter(\.isRenderableMapCoordinate)
                guard let midpoint = coordinates.distanceMidpoint else { return nil }
                let icon = TransportType(rawValue: transportTypeByID[sourceID] ?? "")?.icon ?? "arrow.triangle.swap"
                return TripCardMapTransportMarker(coordinate: midpoint, icon: icon)
            }
            async let renderedMap = TripListCardMapRenderer.image(
                signature: signature,
                stopCoordinates: stopCoordinates,
                stopMarkers: stopMarkers,
                routeSegments: routeSegments,
                transportMarkers: transportMarkers,
                renderSize: renderSize,
                colorScheme: colorScheme
            )
            let resolvedPhotos = await loadedPhotos
            let resolvedMap = await renderedMap
            guard !Task.isCancelled else { return }
            photos = resolvedPhotos
            mapImage = resolvedMap
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, !isVisible else { return }
            // Foreground scrolling must not throw completed work away. Only
            // retained rows outside the viewport release images in background;
            // visible cards stay intact for the app-switcher snapshot.
            mapImage = nil
            photos.removeAll(keepingCapacity: false)
        }
    }

    private func updateRenderSize(_ size: CGSize) {
        guard abs(renderSize.width - size.width) > 1 || abs(renderSize.height - size.height) > 1 else { return }
        renderSize = size
    }

    private func sampledPhotoAssetIDs(from assetIDs: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let uniqueAssetIDs = assetIDs.filter { seen.insert($0).inserted }
        let candidates = uniqueAssetIDs
            .sorted { stablePhotoRank($0) < stablePhotoRank($1) }
        return Array(candidates.prefix(limit))
    }

    private func stablePhotoRank(_ assetID: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for scalar in "\(layoutSeed)|\(assetID)".unicodeScalars {
            value ^= UInt64(scalar.value)
            value &*= 1_099_511_628_211
        }
        return value
    }

}

private struct TripMapStopCoordinate {
    let cityName: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double
    let activityTypeValue: String?
}

private struct TripCardMapStopMarker {
    let coordinate: CLLocationCoordinate2D
    let icon: String
    let tint: Color
}

private struct TripCardMapTransportMarker {
    let coordinate: CLLocationCoordinate2D
    let icon: String
}

private func tripCityMatchesHome(cityName: String?, countryCode: String?, homeCity: HomeCity?) -> Bool {
    guard let homeCity else { return false }
    let normalizedCity = cityName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedHomeCity = homeCity.cityName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let normalizedCity, !normalizedCity.isEmpty, normalizedCity == normalizedHomeCity else { return false }
    let normalizedCountry = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let normalizedHomeCountry = homeCity.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalizedCountry == nil
        || normalizedCountry?.isEmpty == true
        || normalizedHomeCountry.isEmpty
        || normalizedCountry == normalizedHomeCountry
}

private struct TripListPhotoStack: View {
    let images: [UIImage]
    let layoutSeed: String

    var body: some View {
        let rows = imageRows
        VStack(alignment: .trailing, spacing: -28) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: -20) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, image in
                        let index = rowIndex * 3 + columnIndex
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipped()
                            .overlay {
                                Rectangle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                            }
                            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                            .rotationEffect(.degrees(rotation(for: index)))
                            .offset(offset(for: index))
                            .zIndex(Double(index))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 196, height: 148, alignment: .bottomTrailing)
    }

    private var imageRows: [[UIImage]] {
        stride(from: 0, to: min(images.count, 5), by: 3).map { start in
            Array(images[start..<min(start + 3, min(images.count, 5))])
        }
    }

    private func rotation(for index: Int) -> Double {
        Double(-15 + randomUnit(index: index, salt: 1) * 30)
    }

    private func offset(for index: Int) -> CGSize {
        CGSize(
            width: -14 + randomUnit(index: index, salt: 2) * 28,
            height: -10 + randomUnit(index: index, salt: 3) * 20
        )
    }

    private func randomUnit(index: Int, salt: UInt64) -> CGFloat {
        var value: UInt64 = 14_695_981_039_346_656_037
        for scalar in layoutSeed.unicodeScalars {
            value ^= UInt64(scalar.value)
            value &*= 1_099_511_628_211
        }
        value ^= UInt64(index + 1) &* 0x9E3779B97F4A7C15
        value ^= salt &* 0xBF58476D1CE4E5B9
        value ^= value >> 30
        value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27
        value &*= 0x94D049BB133111EB
        value ^= value >> 31
        return CGFloat(value % 10_000) / 9_999
    }
}

private enum TripListPhotoLoader {
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func images(
        for assetIDs: [String],
        limit: Int = 5,
        targetSize: CGSize = CGSize(width: 180, height: 228)
    ) async -> [UIImage] {
        guard !assetIDs.isEmpty else { return [] }
        var result: [UIImage] = []
        for id in assetIDs {
            guard result.count < max(0, limit) else { break }
            guard let image = await image(for: id, targetSize: targetSize) else { continue }
            result.append(image)
        }
        return result
    }

    private static func image(for assetID: String, targetSize: CGSize) async -> UIImage? {
        let cacheKey = "\(assetID)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            PhotoService.shared.loadImage(
                for: assetID,
                targetSize: targetSize,
                contentMode: .aspectFit
            ) { image, exists, _, isDegraded in
                guard !hasResumed else { return }
                if let image {
                    let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                    imageCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                    hasResumed = true
                    continuation.resume(returning: image)
                } else if !exists || !isDegraded {
                    hasResumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private enum TripListCardMapRenderer {
    @MainActor
    static func image(
        signature: String,
        stopCoordinates: [CLLocationCoordinate2D],
        stopMarkers: [TripCardMapStopMarker],
        routeSegments: [TripMapRouteSegment],
        transportMarkers: [TripCardMapTransportMarker],
        renderSize: CGSize,
        colorScheme: ColorScheme
    ) async -> UIImage? {
        let key = "trip-record-map-style-wide-left-focus|\(signature)|\(Int(renderSize.width.rounded()))x\(Int(renderSize.height.rounded()))|\(colorScheme)"
        if let cached = DFKMapSnapshotCache.shared.image(for: key) { return cached }
        let routeCoordinates = routeSegments.flatMap(\.coordinates)
        let cameraCoordinates = stopCoordinates.isEmpty ? routeCoordinates : stopCoordinates
        guard !cameraCoordinates.isEmpty else { return nil }
        var mapRect = MKMapRect.null
        for coordinate in cameraCoordinates {
            let point = MKMapPoint(coordinate)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let minimumSpan: Double = 3_000
        if mapRect.width < minimumSpan { mapRect = mapRect.insetBy(dx: -(minimumSpan - mapRect.width) / 2, dy: 0) }
        if mapRect.height < minimumSpan { mapRect = mapRect.insetBy(dx: 0, dy: -(minimumSpan - mapRect.height) / 2) }
        mapRect = mapRect.insetBy(dx: -mapRect.width * 0.26, dy: -mapRect.height * 0.32)
        // Photos occupy the right side of the card, so place the geographic
        // content in the unobscured left side of the rendered snapshot.
        mapRect = mapRect.offsetBy(dx: mapRect.width * 0.14, dy: 0)
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        options.size = renderSize
        let screenScale = min(UIScreen.main.scale, 2)
        options.scale = screenScale
        options.traitCollection = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderedStopMarkers = stopMarkers.compactMap { marker -> (CLLocationCoordinate2D, UIImage)? in
            let renderer = ImageRenderer(content: TimelineFootprintMarker(icon: marker.icon, tint: marker.tint).environment(\.colorScheme, colorScheme))
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage.map { (marker.coordinate, $0) }
        }
        let renderedTransportMarkers = transportMarkers.compactMap { marker -> (CLLocationCoordinate2D, UIImage)? in
            let renderer = ImageRenderer(content: TimelineTransportMarker(icon: marker.icon).environment(\.colorScheme, colorScheme))
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage.map { (marker.coordinate, $0) }
        }
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        let image = renderer.image { context in
            snapshot.image.draw(at: .zero)
            context.cgContext.setLineCap(.round)
            context.cgContext.setLineJoin(.round)
            for segment in routeSegments where segment.coordinates.count > 1 {
                let path = UIBezierPath()
                for (index, coordinate) in segment.coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.cgContext.setStrokeColor(UIColor(Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.65)).cgColor)
                context.cgContext.setLineWidth(segment.isDashed ? 1.1 : 2.5)
                context.cgContext.setLineDash(phase: 0, lengths: segment.isDashed ? [4, 4] : [])
                path.stroke()
            }
            context.cgContext.setLineDash(phase: 0, lengths: [])
            for (coordinate, markerImage) in renderedTransportMarkers {
                let point = snapshot.point(for: coordinate)
                markerImage.draw(at: CGPoint(x: point.x - markerImage.size.width / 2, y: point.y - markerImage.size.height / 2))
            }
            for (coordinate, markerImage) in renderedStopMarkers {
                let point = snapshot.point(for: coordinate)
                markerImage.draw(at: CGPoint(x: point.x - markerImage.size.width / 2, y: point.y - markerImage.size.height / 2))
            }
        }
        DFKMapSnapshotCache.shared.setImage(image, for: key)
        return image
    }
}

private struct CreateTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let activityStyles: [TripActivityStyle]
    @State private var title = ""
    @State private var notes = ""
    @State private var startDay = Calendar.current.startOfDay(for: Date())
    @State private var endDay = Calendar.current.startOfDay(for: Date())
    @State private var citiesByDay: [Date: [TripCitySelection]] = [:]
    @State private var citySearchDay: Date?
    @State private var importExistingFootprints = true
    @State private var isSaving = false
    @State private var activityTypeValue: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("备注", text: $notes, axis: .vertical)
                TripActivityTypePicker(styles: activityStyles, selection: $activityTypeValue)
                DatePicker("开始日期", selection: $startDay, displayedComponents: .date)
                    .onChange(of: startDay) { oldValue, newValue in
                        let calendar = Calendar.current
                        let oldStart = calendar.startOfDay(for: oldValue)
                        let oldEnd = max(oldStart, calendar.startOfDay(for: endDay))
                        let duration = calendar.dateComponents([.day], from: oldStart, to: oldEnd).day ?? 0
                        let newStart = calendar.startOfDay(for: newValue)
                        endDay = calendar.date(byAdding: .day, value: duration, to: newStart) ?? newStart
                    }
                DatePicker("结束日期", selection: $endDay, in: startDay..., displayedComponents: .date)
                Toggle("加入这段时间的足迹", isOn: $importExistingFootprints)
                if importExistingFootprints {
                    Text("已有足迹、交通和照片会显示在行程中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(tripDays, id: \.self) { day in
                    TripDayCitySection(
                        day: day,
                        cities: citiesByDay[day] ?? [],
                        onAdd: { citySearchDay = day },
                        onRemove: { remove($0, from: day) }
                    )
                }
            }
            .navigationTitle("创建行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { citySearchDay != nil },
            set: { if !$0 { citySearchDay = nil } }
        )) {
            if let selectedDay = citySearchDay {
                TripCitySearchView { city in
                var cities = citiesByDay[selectedDay] ?? []
                if !cities.contains(where: { $0.key == city.key }) { cities.append(city) }
                citiesByDay[selectedDay] = cities
                citySearchDay = nil
                }
            }
        }
    }

    private var tripDays: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDay)
        let end = max(start, calendar.startOfDay(for: endDay))
        var days: [Date] = []; var cursor = start
        while cursor <= end {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        return days
    }

    private func remove(_ city: TripCitySelection, from day: Date) {
        citiesByDay[day]?.removeAll { $0.key == city.key }
    }

    private func save() {
        let start = Calendar.current.startOfDay(for: startDay)
        let end = max(start, Calendar.current.startOfDay(for: endDay))
        isSaving = true
        Task {
            let imported = importExistingFootprints
                ? await TripScanManager.shared.importCities(from: start, through: end)
                : []
            let today = Calendar.current.startOfDay(for: Date())
            let state: TripState = end < today ? .historical : (start <= today ? .active : .planned)
            let kind: TripKind = state == .planned ? .planned : .historical
            let trip = Trip(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes, kind: kind, state: state, plannedStartDay: start, plannedEndDay: end)
            trip.activityTypeValue = activityTypeValue
            if state == .active { trip.actualStartedAt = start }
            context.insert(trip)
            var importedDays = Set<Date>()
            for importedDay in imported where !importedDay.cities.isEmpty {
                let day = TripDay(tripID: trip.id, day: importedDay.day)
                context.insert(day); importedDays.insert(importedDay.day)
                for (index, city) in importedDay.cities.enumerated() {
                    context.insert(TripDayCity(tripDayID: day.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, latitude: city.latitude, longitude: city.longitude, orderIndex: index, isUserEdited: false))
                }
            }
            let existingTripDays = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? []).filter { $0.tripID == trip.id }
            for dayDate in tripDays {
                let selectedCities = citiesByDay[dayDate] ?? []
                let existingDay = existingTripDays.first { Calendar.current.isDate($0.day, inSameDayAs: dayDate) }
                let day = existingDay ?? TripDay(tripID: trip.id, day: dayDate)
                if existingDay == nil { context.insert(day) }
                let existingKeys = Set(imported.first(where: { Calendar.current.isDate($0.day, inSameDayAs: dayDate) })?.cities.map { "\($0.countryCode)|\($0.cityName)".lowercased() } ?? [])
                for (index, city) in selectedCities.enumerated() where !existingKeys.contains(city.key) {
                    context.insert(TripDayCity(tripDayID: day.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, latitude: city.latitude, longitude: city.longitude, timeZoneIdentifier: city.timeZoneIdentifier, orderIndex: index, isUserEdited: true))
                }
            }
            try? context.save(); dismiss()
        }
    }
}

private struct TripActivityTypePicker: View {
    let styles: [TripActivityStyle]
    @Binding var selection: String?
    @State private var presentation: ActivityPickerPresentation?

    private var selected: TripActivityStyle? {
        guard let selection else { return nil }
        return styles.first { $0.id == selection || $0.name == selection }
    }

    var body: some View {
        Button {
            let items = styles.compactMap { style -> StableActivityPickerItem? in
                guard let id = UUID(uuidString: style.id) else { return nil }
                return StableActivityPickerItem(id: id, name: style.name, icon: style.icon)
            }
            presentation = ActivityPickerPresentation(suggestedItems: [], allItems: items)
        } label: {
            HStack(spacing: 12) {
                Text(selected?.name ?? "选择行程类型")
                    .foregroundStyle(selected == nil ? .secondary : .primary)
                Spacer(minLength: 12)
                Image(systemName: selected?.icon ?? FootprintIconDefaults.card)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected.flatMap { Color(hex: $0.colorHex) } ?? .secondary)
                    .frame(width: 24, height: 24)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("行程类型")
        .accessibilityValue(selected?.name ?? "未设置")
        .popover(item: $presentation) { value in
            StableActivityPickerPopover(
                suggestedItems: value.suggestedItems,
                allItems: value.allItems,
                onSelect: { id in
                    selection = id?.uuidString
                }
            )
        }
    }
}

private struct TripDayCitySection: View {
    let day: Date
    let cities: [TripCitySelection]
    let onAdd: () -> Void
    let onRemove: (TripCitySelection) -> Void

    var body: some View {
        Section(day.formatted(date: .complete, time: .omitted)) {
            ForEach(cities, id: \.key) { city in
                HStack {
                    Label(city.displayName, systemImage: "building.2")
                    Spacer()
                    Button(role: .destructive) { onRemove(city) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(action: onAdd) { Label("添加城市", systemImage: "plus.circle") }
        }
    }
}

private struct TripIntroductionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var homeCities: [HomeCity]
    @State private var selectedCity: TripCitySelection?
    @State private var showingCitySearch = false
    @State private var enableScanning = true
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("把去过的城市和沿途记录整理成行程。", systemImage: "map.fill")
                    Text("以后可以按旅程查看地图、足迹和照片。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("你的旅程，一目了然") }
                Section("设置常居地") {
                    Button { showingCitySearch = true } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text(selectedCity?.displayName ?? "选择城市")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                Section("自动整理") {
                    Toggle("自动生成行程", isOn: $enableScanning)
                    Text("离开常居地后自动开始，回来后结束；随时可以在设置中关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置出行")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    finishIntroduction()
                } label: {
                    Text("完成设置")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCity == nil)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            guard let home = homeCities.first else { return }
            selectedCity = TripCitySelection(home)
        }
        .sheet(isPresented: $showingCitySearch) {
            TripCitySearchView(showsCurrentLocation: true) { selectedCity = $0; showingCitySearch = false }
        }
    }

    private func finishIntroduction() {
        guard let city = selectedCity else { return }
        if let home = homeCities.first {
            city.apply(to: home)
            home.updatedAt = Date()
        } else {
            context.insert(city.makeHomeCity())
        }
        try? context.save()
        UserDefaults.standard.set(enableScanning, forKey: "tripAutomaticRecognitionEnabled")
        UserDefaults.standard.set(true, forKey: "tripIntroductionCompleted")
        dismiss()
        onFinished()
    }
}

private struct TripCitySelection: Hashable {
    let cityName: String
    let countryCode: String
    let countryName: String
    let administrativeArea: String?
    let latitude: Double
    let longitude: Double
    let timeZoneIdentifier: String?

    init(_ home: HomeCity) {
        cityName = home.cityName; countryCode = home.countryCode; countryName = home.countryName
        administrativeArea = nil
        latitude = home.latitude ?? 0; longitude = home.longitude ?? 0; timeZoneIdentifier = home.timeZoneIdentifier
    }

    init(_ city: ConfiguredTripCity) {
        cityName = city.cityName; countryCode = city.countryCode; countryName = city.countryName
        administrativeArea = city.group
        latitude = city.latitude; longitude = city.longitude; timeZoneIdentifier = city.timeZoneIdentifier
    }

    var displayName: String { countryName.isEmpty ? cityName : "\(cityName)，\(countryName)" }
    var key: String { "\(countryCode)|\(cityName)".lowercased() }

    func makeHomeCity() -> HomeCity {
        let home = HomeCity(cityName: cityName, countryCode: countryCode, countryName: countryName)
        apply(to: home)
        return home
    }

    func apply(to home: HomeCity) {
        home.cityName = cityName; home.countryCode = countryCode; home.countryName = countryName
        home.latitude = latitude; home.longitude = longitude; home.timeZoneIdentifier = timeZoneIdentifier
    }
}

private struct TripCitySearchView: View {
    private enum MajorCityScope: String, CaseIterable, Identifiable {
        case domestic
        case international

        var id: Self { self }
        var title: String { self == .domestic ? "国内" : "国外" }
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlacePickerViewModel()
    @State private var query = ""
    @State private var cityResults: [TripCitySelection] = []
    @State private var isNormalizingResults = false
    @State private var currentCity: TripCitySelection?
    @State private var isResolvingCurrentCity = false
    @State private var majorCityScope: MajorCityScope = .domestic
    @State private var normalizationRequestID = UUID()
    @State private var draggedCityInitial: String?
    var showsCurrentLocation = false
    let onSelect: (TripCitySelection) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    cityListContent
                }
                .overlay(alignment: .trailing) {
                    if trimmedQuery.isEmpty {
                        cityIndexOverlay(proxy)
                    }
                }
            }
            .onChange(of: query) { _, value in
                normalizationRequestID = UUID()
                cityResults = localCatalogMatches(value)
                isNormalizingResults = false
                search.search(query: value, userCoord: nil)
            }
            .onChange(of: search.searchResults) { _, results in
                let requestID = UUID()
                normalizationRequestID = requestID
                Task { await normalizeCityResults(results, query: query, requestID: requestID) }
            }
            .navigationTitle("选择城市")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索城市"
            )
            .task { await resolveCurrentCityIfNeeded() }
        }
    }

    @ViewBuilder
    private var cityListContent: some View {
        if showsCurrentLocation {
            currentLocationSection
        }
        if trimmedQuery.isEmpty {
            majorCitySections
        } else {
            searchResultSection
        }
    }

    @ViewBuilder
    private var currentLocationSection: some View {
        Section("当前位置") {
            if let currentCity {
                Button { onSelect(currentCity) } label: {
                    Label(currentCity.displayName, systemImage: "location.fill")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if isResolvingCurrentCity {
                HStack {
                    ProgressView()
                    Text("正在获取当前城市…").foregroundStyle(.secondary)
                }
            } else {
                Label("暂时无法获取当前城市", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var majorCitySections: some View {
        Picker("城市范围", selection: $majorCityScope) {
            Text("国内").tag(MajorCityScope.domestic)
            Text("国外").tag(MajorCityScope.international)
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
        .listRowBackground(Color.clear)
        ForEach(groupedMajorCities, id: \.name) { group in
            Section(group.name) {
                ForEach(group.cities, id: \.key) { city in cityButton(city) }
            }
            .id(majorCitySectionID(group.name))
        }
    }

    @ViewBuilder
    private var searchResultSection: some View {
        Section("搜索结果") {
            if cityResults.isEmpty {
                if isNormalizingResults || search.isSearching {
                    HStack {
                        ProgressView()
                        Text(isNormalizingResults ? "正在识别城市…" : "正在搜索…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("未找到匹配的城市")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(cityResults, id: \.key) { city in cityButton(city) }
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groupedMajorCities: [(name: String, cities: [TripCitySelection])] {
        let scope = majorCityScope.rawValue
        let configured = AppConfig.shared.tripMajorCities.filter { $0.scope == scope }
        var groups: [String: [TripCitySelection]] = [:]
        for item in configured {
            groups[cityInitial(item), default: []].append(TripCitySelection(item))
        }
        return groups.keys.sorted().map { initial in
            let cities = (groups[initial] ?? []).sorted {
                normalizedPlaceSearchKey($0.cityName) < normalizedPlaceSearchKey($1.cityName)
            }
            return (initial, cities)
        }
    }

    private func cityInitial(_ city: ConfiguredTripCity) -> String {
        let transliterated = city.cityName.applyingTransform(.toLatin, reverse: false) ?? city.cityName
        let latin = transliterated.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let scalar = latin.uppercased().unicodeScalars.first(where: {
            (65...90).contains(Int($0.value))
        }) else { return "#" }
        return String(scalar)
    }

    private func majorCitySectionID(_ initial: String) -> String {
        "trip-city-section-\(majorCityScope.rawValue)-\(initial)"
    }

    private func cityIndexOverlay(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .trailing) {
            if let draggedCityInitial {
                Text(draggedCityInitial)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.trailing, 44)
            }

            GeometryReader { _ in
                let initials = groupedMajorCities.map(\.name)
                VStack(spacing: 0) {
                    ForEach(initials, id: \.self) { initial in
                        Text(initial)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(draggedCityInitial == initial ? Color.primary : Color.accentColor)
                            .frame(width: 28, height: 14)
                    }
                }
                .frame(width: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            selectCityInitial(
                                at: value.location.y,
                                height: CGFloat(initials.count) * 14,
                                initials: initials,
                                proxy: proxy
                            )
                        }
                        .onEnded { _ in draggedCityInitial = nil }
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 28)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 1)
    }

    private func selectCityInitial(
        at y: CGFloat,
        height: CGFloat,
        initials: [String],
        proxy: ScrollViewProxy
    ) {
        guard height > 0, !initials.isEmpty else { return }
        let maximumY = max(height - 0.001, 0)
        let boundedY = min(max(y, 0), maximumY)
        let index = min(Int(boundedY / height * CGFloat(initials.count)), initials.count - 1)
        let initial = initials[index]
        guard draggedCityInitial != initial else { return }
        draggedCityInitial = initial
        proxy.scrollTo(majorCitySectionID(initial), anchor: .top)
    }

    private func localCatalogMatches(_ value: String) -> [TripCitySelection] {
        let queryKey = normalizedPlaceSearchKey(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !queryKey.isEmpty else { return [] }
        return AppConfig.shared.tripMajorCities.compactMap { item in
            let searchText = ([item.cityName, item.countryName, item.countryCode] + (item.searchAliases ?? []))
                .joined(separator: " ")
            return normalizedPlaceSearchKey(searchText).contains(queryKey)
                ? TripCitySelection(item)
                : nil
        }
    }

    @ViewBuilder
    private func cityButton(_ city: TripCitySelection) -> some View {
        Button { onSelect(city) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(city.cityName).foregroundStyle(.primary)
                let subtitle = city.countryCode.uppercased() == "CN"
                    ? city.administrativeArea
                    : city.countryName
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func resolveCurrentCityIfNeeded() async {
        guard showsCurrentLocation, currentCity == nil,
              let location = LocationManager.shared.lastLocation else { return }
        isResolvingCurrentCity = true
        let resolved = await citySelection(
            coordinate: location.coordinate,
            fallbackName: nil
        )
        currentCity = resolved
        if let resolved {
            cityResults.removeAll { $0.key == resolved.key }
        }
        isResolvingCurrentCity = false
    }

    @MainActor
    private func normalizeCityResults(_ results: [PlaceSearchResult], query: String, requestID: UUID) async {
        let expectedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedQuery.isEmpty else { cityResults = []; return }
        isNormalizingResults = true
        var normalized = localCatalogMatches(expectedQuery)
        var seen = Set(normalized.map(\.key))
        let foldedQuery = normalizedPlaceSearchKey(expectedQuery)
        for result in results.prefix(12) {
            guard requestID == normalizationRequestID, expectedQuery == trimmedQuery else { return }
            guard let city = await citySelection(
                coordinate: result.coordinate,
                fallbackName: supportedAdministrativeName(result.name, matching: expectedQuery),
                matchingQuery: expectedQuery
            ),
                  city.key != currentCity?.key else { continue }
            let searchableText = normalizedPlaceSearchKey("\(city.cityName) \(city.countryName) \(city.countryCode)")
            let resultAlias = normalizedPlaceSearchKey("\(result.name) \(result.address)")
            let matchesLocalizedCity = searchableText.contains(foldedQuery)
            let matchesForeignAlias = city.countryCode.uppercased() != "CN" && resultAlias.contains(foldedQuery)
            guard (matchesLocalizedCity || matchesForeignAlias), seen.insert(city.key).inserted else { continue }
            normalized.append(city)
        }
        guard requestID == normalizationRequestID, expectedQuery == trimmedQuery else { return }
        cityResults = normalized
        isNormalizingResults = false
    }

    private func citySelection(
        coordinate: CLLocationCoordinate2D,
        fallbackName: String?,
        matchingQuery: String? = nil
    ) async -> TripCitySelection? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let initialPlacemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let initialCountryCode = initialPlacemark?.isoCountryCode ?? ""
        let usesChineseNames = initialCountryCode.uppercased() == "CN"
        let hierarchyLanguage = usesChineseNames ? "zh" : "en"
        let fallback = await OpenStreetMapGeocoder.shared.lookupInternationalHierarchy(
            coordinate: coordinate,
            language: hierarchyLanguage
        )
        let countryCode = initialCountryCode.isEmpty ? (fallback?.countryCode ?? "") : initialCountryCode
        let locale = countryCode.uppercased() == "CN"
            ? Locale(identifier: "zh-Hans-CN")
            : Locale(identifier: "en-US")
        let localizedPlacemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location, preferredLocale: locale)
            .first
        let localizedCityCandidates = [
            localizedPlacemark?.locality,
            localizedPlacemark?.subAdministrativeArea,
            localizedPlacemark?.subLocality,
            localizedPlacemark?.administrativeArea
        ].compactMap { $0 }.filter { !$0.hasSuffix("街道") }
        let initialCityCandidates = [
            initialPlacemark?.locality,
            initialPlacemark?.subAdministrativeArea,
            initialPlacemark?.subLocality,
            initialPlacemark?.administrativeArea
        ].compactMap { $0 }.filter { !$0.hasSuffix("街道") }
        let localizedCity = localizedCityCandidates.first
        let initialCity = initialCityCandidates.first
        let city: String?
        let countryName: String
        if countryCode.uppercased() == "CN" {
            let candidates = localizedCityCandidates
                + [fallback?.cityName].compactMap { $0 }
                + initialCityCandidates
                + [fallbackName].compactMap { $0 }
            let queryKey = normalizedPlaceSearchKey(matchingQuery ?? "")
            city = candidates.first {
                let candidateKey = normalizedPlaceSearchKey($0)
                return !queryKey.isEmpty && (candidateKey.contains(queryKey) || queryKey.contains(candidateKey))
            } ?? candidates.first ?? fallbackName
            countryName = localizedPlacemark?.country ?? fallback?.countryName ?? initialPlacemark?.country ?? ""
        } else {
            let englishCity = [localizedCity, fallback?.cityName, initialCity]
                .compactMap { $0 }
                .first(where: containsLatinLetter)
            let englishCountry = [localizedPlacemark?.country, fallback?.countryName, initialPlacemark?.country]
                .compactMap { $0 }
                .first(where: containsLatinLetter)
            city = englishCity ?? localizedCity ?? fallback?.cityName ?? initialCity ?? fallbackName
            countryName = englishCountry ?? ""
        }
        guard let city, !city.isEmpty else { return nil }
        return TripCitySelection(
            cityName: city,
            countryCode: localizedPlacemark?.isoCountryCode ?? fallback?.countryCode ?? initialPlacemark?.isoCountryCode ?? "",
            countryName: countryName,
            administrativeArea: localizedPlacemark?.administrativeArea ?? initialPlacemark?.administrativeArea,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timeZoneIdentifier: localizedPlacemark?.timeZone?.identifier ?? initialPlacemark?.timeZone?.identifier
        )
    }

    private func supportedAdministrativeName(_ value: String, matching query: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedSuffixes = ["自治县", "自治旗", "民族乡", "民族苏木", "林区", "特区", "市", "县", "旗", "镇", "乡", "苏木"]
        guard let suffix = supportedSuffixes.first(where: name.hasSuffix) else { return nil }
        let nameKey = normalizedPlaceSearchKey(name)
        let baseNameKey = normalizedPlaceSearchKey(String(name.dropLast(suffix.count)))
        let queryKey = normalizedPlaceSearchKey(query)
        guard !queryKey.isEmpty, nameKey == queryKey || baseNameKey == queryKey else { return nil }
        return name
    }

    private func containsLatinLetter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }
}

private extension TripCitySelection {
    init(cityName: String, countryCode: String, countryName: String, administrativeArea: String?, latitude: Double, longitude: Double, timeZoneIdentifier: String?) {
        self.cityName = cityName; self.countryCode = countryCode; self.countryName = countryName
        self.administrativeArea = administrativeArea
        self.latitude = latitude; self.longitude = longitude; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

private struct TripOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var homeCities: [HomeCity]
    @AppStorage("tripAutomaticRecognitionEnabled") private var automaticRecognition = true
    @AppStorage("tripNotificationsEnabled") private var notificationsEnabled = true
    @State private var scanManager = TripScanManager.shared
    @State private var selectedCity: TripCitySelection?
    @State private var showingCitySearch = false
    @State private var confirmingRescan = false

    var body: some View {
        NavigationStack {
            Form {
                Section("常居地") {
                    Button { showingCitySearch = true } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text(selectedCity?.displayName ?? "选择城市")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    Text("离开这里时开始一段行程，回来后自动结束。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自动整理") {
                    Toggle("自动生成行程", isOn: $automaticRecognition)
                    Toggle("行程动态提醒", isOn: $notificationsEnabled)
                }
                Section {
                    Button("重新整理历史行程", role: .destructive) { confirmingRescan = true }
                        .disabled(scanManager.isScanning || !automaticRecognition || selectedCity == nil)
                } footer: {
                    Text("根据现有足迹重新生成自动行程。你创建或修改过的行程不会改变。")
                }
            }
            .navigationTitle("出行设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                selectedCity = homeCities.first.map(TripCitySelection.init)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
        .sheet(isPresented: $showingCitySearch) {
            TripCitySearchView(showsCurrentLocation: true) { selectedCity = $0; showingCitySearch = false }
        }
        .alert("重新整理历史行程？", isPresented: $confirmingRescan) {
            Button("取消", role: .cancel) {}
            Button("重新整理", role: .destructive) {
                save(dismissAfter: false)
                scanManager.rebuildHistoryFromSettings()
            }
        } message: {
            Text("将根据现有足迹重新生成自动行程。你创建或修改过的行程不会改变。")
        }
    }

    private func save(dismissAfter: Bool = true) {
        if let existing = homeCities.first {
            if let selectedCity { selectedCity.apply(to: existing); existing.updatedAt = Date() }
            else { context.delete(existing) }
        } else if let selectedCity {
            context.insert(selectedCity.makeHomeCity())
        }
        for duplicate in homeCities.dropFirst() { context.delete(duplicate) }
        try? context.save()
        if dismissAfter { dismiss() }
    }
}

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    let trip: Trip
    let onClose: () -> Void
    @Query private var homeCities: [HomeCity]
    @Query private var allDays: [TripDay]
    @Query private var allCities: [TripDayCity]
    @Query private var allItems: [TripItem]
    @State private var showingSheet = false
    @State private var detailDetent: PresentationDetent = .medium
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedTimelineItemID: UUID?
    @State private var transportRoutes: [UUID: [CodableCoordinate]] = [:]
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var mapViewportSize: CGSize = .zero
    @State private var actualItems: [TripItem] = []
    @State private var visibleTimelineItemIDs = Set<UUID>()
    @State private var renderedCameraCoordinateKey = ""
    @State private var visibleMapUpdateTask: Task<Void, Never>?
    @State private var recordRefreshVersion = 0
    @State private var mapRequestedTimelineItemID: UUID?

    private var days: [TripDay] { allDays.filter { $0.tripID == trip.id }.sorted { $0.day < $1.day } }
    private var cities: [TripDayCity] {
        let ids = Set(days.map(\.id))
        return allCities.filter { ids.contains($0.tripDayID) }.sorted { $0.orderIndex < $1.orderIndex }
    }
    private var items: [TripItem] {
        let ids = Set(days.map(\.id))
        return allItems.filter { ids.contains($0.tripDayID) }.sorted {
            let leftTime = $0.startTime ?? .distantPast
            let rightTime = $1.startTime ?? .distantPast
            return leftTime == rightTime ? $0.orderIndex < $1.orderIndex : leftTime < rightTime
        }
    }
    private var displayedItems: [TripItem] { trip.state != .planned ? actualItems : items }
    private var actualDaySignature: String {
        days.map { "\($0.id.uuidString)|\($0.day.timeIntervalSinceReferenceDate)|\($0.timeZoneIdentifier)" }
            .joined(separator: ";")
    }

    var body: some View {
        GeometryReader { detailViewport in
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition) {
            if stopItemsWithCoordinates.isEmpty {
                ForEach(cities) { city in
                    if let latitude = city.latitude, let longitude = city.longitude {
                        Marker(city.cityName, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                            .tint(trip.state == .planned ? .blue : .orange)
                    }
                }
            }
            ForEach(aggregatedStopItems) { group in
                Annotation("", coordinate: group.coordinate) {
                    Button {
                        selectedTimelineItemID = group.representative.id
                        mapRequestedTimelineItemID = group.representative.id
                    } label: {
                        TripFootprintMapMarker(
                            icon: activityStyle(for: group.representative)?.icon ?? FootprintIconDefaults.card,
                            tint: activityStyle(for: group.representative).flatMap { Color(hex: $0.colorHex) } ?? .gray,
                            duration: group.totalDuration,
                            photoAssetIDs: group.photoAssetIDs,
                            isSelected: selectedTimelineItemID.map(group.itemIDs.contains) ?? false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(routeSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        Color.dfkAccent.opacity(segment.isDashed ? 0.4 : 0.7),
                        style: StrokeStyle(lineWidth: segment.isDashed ? 1.3 : 3, lineCap: .round, lineJoin: .round, dash: segment.isDashed ? [5, 5] : [])
                    )
            }
            ForEach(transportMapMarkers) { marker in
                Annotation("", coordinate: marker.coordinate) {
                    TripTransportMapMarker(icon: marker.icon, isSelected: selectedTimelineItemID == marker.itemID)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        mapViewportSize = proxy.size
                        fitCamera(to: mapCoordinates)
                    }
                    .onChange(of: proxy.size) { _, size in
                        mapViewportSize = size
                        fitCamera(to: mapCoordinates)
                    }
            }
            .allowsHitTesting(false)
        }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .tripCloseButtonStyle()
                .padding(.leading, 16)
                .padding(
                    .top,
                    max(detailViewport.safeAreaInsets.top, currentTopSafeAreaInset) + 8
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(20)
            }
        }
        .ignoresSafeArea()
        .background {
            TripDetailEdgeDismissGesture(onDismiss: onClose)
        }
        .onAppear {
            fitCamera(to: mapCoordinates)
        }
        .onChange(of: selectedTimelineItemID) { _, selectedID in
            guard let selectedID, let item = displayedItems.first(where: { $0.id == selectedID }) else { return }
            if let sourceID = item.sourceTransportRecordID, let route = transportRoutes[sourceID] {
                fitCamera(to: route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            } else if let latitude = item.latitude, let longitude = item.longitude {
                fitCamera(to: [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)])
            }
        }
        .onChange(of: detailDetent) { _, _ in
            if let selectedID = selectedTimelineItemID,
               let item = displayedItems.first(where: { $0.id == selectedID }) {
                if let sourceID = item.sourceTransportRecordID, let route = transportRoutes[sourceID] {
                    fitCamera(to: route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                } else if let latitude = item.latitude, let longitude = item.longitude {
                    fitCamera(to: [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)])
                }
            } else {
                fitCamera(to: mapCoordinates)
            }
        }
        .onChange(of: visibleTimelineItemIDs) { _, itemIDs in
            guard !itemIDs.isEmpty else { return }
            selectedTimelineItemID = nil
            visibleMapUpdateTask?.cancel()
            let targetItemIDs = itemIDs
            visibleMapUpdateTask = Task { @MainActor in
                guard !Task.isCancelled, selectedTimelineItemID == nil else { return }
                let coordinates = mapCoordinates(for: targetItemIDs)
                guard !coordinates.isEmpty else { return }
                let coordinateKey = coordinates
                    .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
                    .sorted()
                    .joined(separator: "|")
                guard coordinateKey != renderedCameraCoordinateKey else { return }
                renderedCameraCoordinateKey = coordinateKey
                fitCamera(to: coordinates)
            }
        }
        .task(id: "\(actualDaySignature)#\(recordRefreshVersion)") {
            if trip.state != .planned {
                let requests = days.map { TripActualDayRequest(id: $0.id, day: $0.day, timeZoneIdentifier: $0.timeZoneIdentifier) }
                let snapshots = await TripScanManager.shared.actualItems(for: requests)
                actualItems = snapshots.enumerated().map { index, snapshot in
                    let item = TripItem(tripDayID: snapshot.dayID, kind: snapshot.kind, orderIndex: index)
                    item.countryCode = snapshot.countryCode; item.countryName = snapshot.countryName; item.cityName = snapshot.cityName
                    item.placeID = snapshot.placeID; item.placeName = snapshot.placeName; item.address = snapshot.address
                    item.latitude = snapshot.latitude; item.longitude = snapshot.longitude
                    item.startTime = snapshot.startTime; item.endTime = snapshot.endTime; item.activityTypeValue = snapshot.activityTypeValue
                    item.transportTypeRaw = snapshot.transportTypeRaw; item.startLocationName = snapshot.startLocationName; item.endLocationName = snapshot.endLocationName
                    item.notes = snapshot.notes; item.sourceFootprintID = snapshot.sourceFootprintID; item.sourceTransportRecordID = snapshot.sourceTransportRecordID
                    item.planStatusRaw = "actual"
                    item.actualPhotoAssetIDs = PhotoService.shared.displayableAssetIDs(snapshot.photoAssetIDs)
                    return item
                }
            }
            let ids = Set(displayedItems.compactMap(\.sourceTransportRecordID))
            async let loadedRoutes = TripScanManager.shared.transportRoutes(for: ids)
            async let loadedStyles = TripScanManager.shared.activityStyles()
            transportRoutes = await loadedRoutes
            activityStyles = await loadedStyles
            fitCamera(to: mapCoordinates)
            showingSheet = true
        }
        .sheet(isPresented: $showingSheet) {
            TripDetailSheet(
                trip: trip,
                days: days,
                cities: cities,
                items: displayedItems,
                transportRoutes: transportRoutes,
                detent: $detailDetent,
                selectedTimelineItemID: $selectedTimelineItemID,
                mapRequestedTimelineItemID: $mapRequestedTimelineItemID,
                visibleTimelineItemIDsChanged: { visibleTimelineItemIDs = $0 },
                onRecordChanged: { recordRefreshVersion &+= 1 }
            )
            .presentationDetents(
                [.height(collapsedTimelineDetentHeight), .medium, .large],
                selection: $detailDetent
            )
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
        }
        .onDisappear {
            visibleMapUpdateTask?.cancel()
        }
    }

    private var currentTopSafeAreaInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

    private var mapCoordinates: [CLLocationCoordinate2D] {
        let cityCoordinates = cities.compactMap { city -> CLLocationCoordinate2D? in
            guard let latitude = city.latitude, let longitude = city.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate),
                  !tripCityMatchesHome(cityName: city.cityName, countryCode: city.countryCode, homeCity: homeCities.first) else { return nil }
            return coordinate
        }
        let itemCoordinates = displayedItems.compactMap { item -> CLLocationCoordinate2D? in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate),
                  !tripCityMatchesHome(cityName: item.cityName, countryCode: item.countryCode, homeCity: homeCities.first) else { return nil }
            return coordinate
        }
        let routeCoordinates = transportRoutes.values.flatMap { route in
            route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let destinationCoordinates = cityCoordinates + itemCoordinates
        return destinationCoordinates.isEmpty ? routeCoordinates : destinationCoordinates
    }

    private var stopItemsWithCoordinates: [TripItem] {
        displayedItems.filter { $0.kindRaw == TripItemKind.stop.rawValue && $0.latitude != nil && $0.longitude != nil }
    }

    private var aggregatedStopItems: [TripAggregatedStop] {
        struct Bucket {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalWeight: TimeInterval
            var totalDuration: TimeInterval
            var representative: TripItem
            var items: [TripItem]
        }

        var buckets: [String: Bucket] = [:]
        var orderedKeys: [String] = []
        for item in stopItemsWithCoordinates {
            guard let latitude = item.latitude, let longitude = item.longitude else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard coordinate.isRenderableMapCoordinate else { continue }
            let key = item.placeID.map { "place:\($0.uuidString)" }
                ?? String(format: "coord:%.5f,%.5f", latitude, longitude)
            let duration = itemDuration(item)
            let weight = max(duration, 1)
            if var bucket = buckets[key] {
                bucket.weightedLatitude += latitude * weight
                bucket.weightedLongitude += longitude * weight
                bucket.totalWeight += weight
                bucket.totalDuration += duration
                bucket.items.append(item)
                if duration > itemDuration(bucket.representative) {
                    bucket.representative = item
                }
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = Bucket(
                    weightedLatitude: latitude * weight,
                    weightedLongitude: longitude * weight,
                    totalWeight: weight,
                    totalDuration: duration,
                    representative: item,
                    items: [item]
                )
            }
        }
        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let representative = selectedTimelineItemID.flatMap { selectedID in
                bucket.items.first { $0.id == selectedID }
            } ?? bucket.representative
            let divisor = max(bucket.totalWeight, 1)
            let coordinate: CLLocationCoordinate2D
            if selectedTimelineItemID == representative.id,
               let latitude = representative.latitude,
               let longitude = representative.longitude {
                coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            } else {
                coordinate = CLLocationCoordinate2D(
                    latitude: bucket.weightedLatitude / divisor,
                    longitude: bucket.weightedLongitude / divisor
                )
            }
            return TripAggregatedStop(
                id: key,
                coordinate: coordinate,
                totalDuration: bucket.totalDuration,
                representative: representative,
                itemIDs: Set(bucket.items.map(\.id)),
                photoAssetIDs: bucket.items
                    .sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
                    .first(where: { !$0.actualPhotoAssetIDs.isEmpty })?
                    .actualPhotoAssetIDs ?? []
            )
        }
    }

    private func mapCoordinates(for itemIDs: Set<UUID>) -> [CLLocationCoordinate2D] {
        displayedItems.filter { itemIDs.contains($0.id) }.flatMap { item -> [CLLocationCoordinate2D] in
            if item.kindRaw == TripItemKind.transport.rawValue,
               let sourceID = item.sourceTransportRecordID,
               let route = transportRoutes[sourceID] {
                return route.compactMap { point in
                    let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
                    return point.lat.isFinite && point.lon.isFinite && CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
                }
            }
            guard let latitude = item.latitude, let longitude = item.longitude else { return [] }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? [coordinate] : []
        }
    }

    private func activityStyle(for item: TripItem) -> TripActivityStyle? {
        guard let value = item.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }

    private func itemDuration(_ item: TripItem) -> TimeInterval {
        guard let start = item.startTime, let end = item.endTime else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    private var routeSegments: [TripMapRouteSegment] {
        displayedItems.compactMap(\.sourceTransportRecordID).flatMap { sourceID in
            TripMapRouteSegment.make(sourceID: sourceID, points: transportRoutes[sourceID] ?? [])
        }
    }

    private var transportMapMarkers: [TripTransportMapMarkerData] {
        displayedItems.compactMap { item in
            guard item.kindRaw == TripItemKind.transport.rawValue,
                  let sourceID = item.sourceTransportRecordID,
                  let points = transportRoutes[sourceID], points.count > 1 else { return nil }
            let displayedCoordinates = TripMapRouteSegment.make(sourceID: sourceID, points: points)
                .flatMap(\.coordinates)
                .filter(\.isRenderableMapCoordinate)
            guard let midpoint = displayedCoordinates.distanceMidpoint else { return nil }
            let icon = TransportType(rawValue: item.transportTypeRaw ?? "")?.icon ?? "arrow.triangle.swap"
            return TripTransportMapMarkerData(itemID: item.id, coordinate: midpoint, icon: icon)
        }
    }

    private func fitCamera(to coordinates: [CLLocationCoordinate2D]) {
        let valid = coordinates.filter { CLLocationCoordinate2DIsValid($0) }
        guard !valid.isEmpty, mapViewportSize.width > 1, mapViewportSize.height > 1 else { return }
        let visibleHeight: CGFloat
        if detailDetent == .height(collapsedTimelineDetentHeight) {
            visibleHeight = mapViewportSize.height - collapsedTimelineDetentHeight
        } else if detailDetent == .medium {
            visibleHeight = mapViewportSize.height * 0.5
        } else {
            visibleHeight = max(1, mapViewportSize.height * 0.12)
        }
        let topChromeHeight = currentTopSafeAreaInset + 60
        let unobscuredTop = min(topChromeHeight, visibleHeight * 0.25)
        let unobscuredHeight = max(1, visibleHeight - unobscuredTop)
        let visibleRect = CGRect(
            x: mapViewportSize.width * 0.08,
            y: unobscuredTop + unobscuredHeight * 0.10,
            width: mapViewportSize.width * 0.84,
            height: unobscuredHeight * 0.80
        )
        if let rect = FootprintCameraFraming.mapRect(
            coordinates: valid,
            viewport: mapViewportSize,
            visibleRect: visibleRect
        ) {
            withAnimation(.easeInOut(duration: 0.6)) {
                cameraPosition = .rect(rect)
            }
        }
    }
}

private struct TripDetailEdgeDismissGesture: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> EdgeGestureHostView {
        let view = EdgeGestureHostView()
        view.backgroundColor = .clear
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(in: window)
        }
        return view
    }

    func updateUIView(_ uiView: EdgeGestureHostView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.install(in: uiView.window)
    }

    static func dismantleUIView(_ uiView: EdgeGestureHostView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void
        private weak var installedWindow: UIWindow?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func install(in window: UIWindow?) {
            guard let window, installedWindow !== window else { return }
            uninstall()
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            recognizer.edges = .left
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer { installedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedWindow = nil
        }

        @objc private func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            if translation.x > 80 || velocity.x > 650 {
                onDismiss()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private final class EdgeGestureHostView: UIView {
    var windowDidChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowDidChange?(window)
    }
}

private extension View {
    @ViewBuilder
    func tripCloseButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.font(.body.weight(.semibold))
                .controlSize(.large)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            self.font(.body.weight(.semibold))
                .controlSize(.large)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }
}

private struct TripAggregatedStop: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let totalDuration: TimeInterval
    let representative: TripItem
    let itemIDs: Set<UUID>
    let photoAssetIDs: [String]
}

private struct TripMapRouteSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let isDashed: Bool

    static func make(sourceID: UUID, points: [CodableCoordinate]) -> [TripMapRouteSegment] {
        let valid = points.filter {
            $0.lat.isFinite && $0.lon.isFinite && CLLocationCoordinate2DIsValid(.init(latitude: $0.lat, longitude: $0.lon))
        }
        guard valid.count >= 2 else { return [] }
        var result: [TripMapRouteSegment] = []
        var chunk = [CLLocationCoordinate2D(latitude: valid[0].lat, longitude: valid[0].lon)]
        var currentDashed: Bool?
        for index in 0..<(valid.count - 1) {
            let first = valid[index]
            let second = valid[index + 1]
            let firstCoordinate = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)
            let secondCoordinate = CLLocationCoordinate2D(latitude: second.lat, longitude: second.lon)
            let distance = CLLocation(latitude: first.lat, longitude: first.lon).distance(from: CLLocation(latitude: second.lat, longitude: second.lon))
            let timeGap = first.timestamp.flatMap { start in second.timestamp.map { abs($0.timeIntervalSince(start)) } }
            let dashed = first.isSyntheticPadding == true || second.isSyntheticPadding == true || timeGap == nil || timeGap! > 180 || distance > 500
            if currentDashed == nil { currentDashed = dashed }
            if currentDashed == dashed {
                chunk.append(secondCoordinate)
            } else {
                result.append(.init(id: "\(sourceID)-\(result.count)", coordinates: chunk.smoothed(), isDashed: currentDashed!))
                chunk = [firstCoordinate, secondCoordinate]
                currentDashed = dashed
            }
        }
        if let currentDashed, chunk.count > 1 {
            result.append(.init(id: "\(sourceID)-\(result.count)", coordinates: chunk.smoothed(), isDashed: currentDashed))
        }
        return result
    }
}

private struct TripTransportMapMarkerData: Identifiable {
    let itemID: UUID
    let coordinate: CLLocationCoordinate2D
    let icon: String
    var id: UUID { itemID }
}

private struct TripTransportMapMarker: View {
    let icon: String
    let isSelected: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .systemBackground)).overlay(Circle().stroke(Color.dfkAccent, lineWidth: 1.2))
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dfkAccent)
        }
        .frame(width: 18, height: 18)
        .scaleEffect(isSelected ? 1.5 : 1, anchor: .center)
    }
}

private struct TripFootprintMapMarker: View {
    let icon: String
    let tint: Color
    let duration: TimeInterval
    let photoAssetIDs: [String]
    let isSelected: Bool

    var body: some View {
        let size: CGFloat = 33
        ZStack(alignment: .top) {
            MapPinTeardropShape()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
                .frame(width: size, height: size * 1.2)
            Circle()
                .fill(LinearGradient(colors: [tint, tint.darker(by: 0.20)], startPoint: .top, endPoint: .bottom))
                .frame(width: size - 5, height: size - 5)
                .offset(y: 2.5)
            if photoAssetIDs.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 13.2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
            } else {
                ContinuousTimelinePhotoThumbnail(assetIDs: photoAssetIDs, targetSide: size * 2)
                    .frame(width: size - 3, height: size - 3)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(tint, lineWidth: 1.5))
                    .offset(y: 1.5)
            }
            if duration >= AppConfig.shared.stayDurationThreshold {
                Text(durationLabel)
                    .font(.system(size: 8.6, weight: .bold, design: .rounded))
                    .foregroundStyle(tint.darker(by: 0.30))
                    .padding(.horizontal, 2).padding(.vertical, 1)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(y: size - 8)
            }
        }
        .padding(2.64)
        .frame(width: size + 5.28, height: size * 1.2 + 5.28)
        .scaleEffect(isSelected ? 1.5 : 1, anchor: .bottom)
    }

    private var durationLabel: String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(max(1, minutes))分钟" }
        let hours = Double(minutes) / 60
        return hours >= 10 ? "\(Int(round(hours)))小时" : "\(String(format: "%g", (hours * 10).rounded() / 10))小时"
    }
}

private struct TripDetailSheet: View {
    @Environment(\.modelContext) private var context
    let trip: Trip
    let days: [TripDay]
    let cities: [TripDayCity]
    let items: [TripItem]
    let transportRoutes: [UUID: [CodableCoordinate]]
    @Binding var detent: PresentationDetent
    @Binding var selectedTimelineItemID: UUID?
    @Binding var mapRequestedTimelineItemID: UUID?
    let visibleTimelineItemIDsChanged: (Set<UUID>) -> Void
    let onRecordChanged: () -> Void
    @State private var showingEditor = false
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var followsVisibleTimelineContent = false
    @State private var latestVisibleTimelineItemIDs = Set<UUID>()
    @State private var timelineScrollSettleTask: Task<Void, Never>?
    @State private var selectedFootprint: Footprint?
    @State private var selectedFootprintStartsExpanded = false
    @State private var selectedTransport: Transport?
    @State private var detentBeforeFootprintDetail: PresentationDetent?
    @State private var activityPickerPresentation: ActivityPickerPresentation?

    private var isCollapsed: Bool {
        detent == .height(collapsedTimelineDetentHeight)
    }

    private var visibleDayEntries: [(offset: Int, element: TripDay)] {
        days.enumerated().filter { entry in
            items.contains { $0.tripDayID == entry.element.id }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCollapsed {
                    Color.clear
                } else {
                    GeometryReader { viewport in
                        ScrollView {
                            detailContent
                                .padding()
                        }
                        .coordinateSpace(name: "tripTimelineScroll")
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                    followsVisibleTimelineContent = true
                                    timelineScrollSettleTask?.cancel()
                                }
                        )
                        .onPreferenceChange(TripTimelineItemFramePreferenceKey.self) { frames in
                            guard followsVisibleTimelineContent else { return }
                            let itemIDs = significantVisibleItemIDs(
                                in: frames,
                                viewportHeight: viewport.size.height
                            )
                            latestVisibleTimelineItemIDs = itemIDs
                            timelineScrollSettleTask?.cancel()
                            let settledItemIDs = itemIDs
                            timelineScrollSettleTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 120_000_000)
                                guard !Task.isCancelled,
                                      settledItemIDs == latestVisibleTimelineItemIDs else { return }
                                visibleTimelineItemIDsChanged(settledItemIDs)
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showActivityTypePicker) {
                        Image(systemName: tripActivityStyle?.icon ?? FootprintIconDefaults.card)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(
                                tripActivityStyle.flatMap { Color(hex: $0.colorHex) } ?? .secondary
                            )
                    }
                    .accessibilityLabel("修改行程类型")
                    .accessibilityValue(tripActivityStyle?.name ?? "未设置")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(trip.title).font(.headline).lineLimit(1)
                        Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingEditor = true } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("编辑行程")
                }
            }
        }
        .fullScreenCover(isPresented: $showingEditor) {
            TripEditorView(trip: trip)
        }
        .popover(item: $activityPickerPresentation) { value in
            StableActivityPickerPopover(
                suggestedItems: value.suggestedItems,
                allItems: value.allItems,
                onSelect: updateTripActivityType
            )
        }
        .sheet(item: $selectedFootprint) { footprint in
            if let container = TripScanManager.shared.recordModelContainer {
                FootprintModalView(
                    footprint: footprint,
                    autoFocus: false,
                    startsExpanded: selectedFootprintStartsExpanded,
                    scrollsToPhotosOnAppear: selectedFootprintStartsExpanded,
                    onDismiss: { changed in
                        if changed { onRecordChanged() }
                    }
                )
                .modelContainer(container)
            }
        }
        .sheet(item: $selectedTransport) { transport in
            if let container = TripScanManager.shared.recordModelContainer {
                TransportModalView(transport: transport) { newType in
                    updateTransport(transport, type: newType, in: container)
                } onLocationUpdate: {
                    onRecordChanged()
                    NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
                }
                .modelContainer(container)
            }
        }
        .onChange(of: selectedFootprint?.footprintID) { _, footprintID in
            if footprintID != nil {
                if detentBeforeFootprintDetail == nil {
                    detentBeforeFootprintDetail = detent
                }
                detent = .medium
            } else if let previousDetent = detentBeforeFootprintDetail {
                selectedFootprintStartsExpanded = false
                detentBeforeFootprintDetail = nil
                detent = previousDetent
            }
        }
        .task(id: mapRequestedTimelineItemID) {
            guard let itemID = mapRequestedTimelineItemID,
                  let item = items.first(where: { $0.id == itemID }) else { return }
            mapRequestedTimelineItemID = nil
            openRecordDetail(for: item)
        }
        .onDisappear {
            timelineScrollSettleTask?.cancel()
        }
    }

    private var detailContent: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                if !trip.notes.isEmpty { Text(trip.notes).foregroundStyle(.secondary) }
                ForEach(visibleDayEntries, id: \.element.id) { dayIndex, day in
                    let dayCities = cities.filter { $0.tripDayID == day.id }
                    let dayItems = items.filter { $0.tripDayID == day.id }
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.secondary.opacity(0.38))
                                .frame(height: 2)
                                .offset(y: ContinuousTimelineLayout.dateSeparatorOffset)
                            Rectangle()
                                .fill(ContinuousTimelineLayout.lineColor)
                                .frame(width: 2, height: 30)
                                .offset(x: ContinuousTimelineLayout.markerCenterX - 1)
                            Text(dayTitle(day))
                                .font(.caption.weight(.bold))
                                .frame(width: ContinuousTimelineLayout.dateColumnWidth, alignment: .leading)
                                .foregroundStyle(.secondary)
                            if !dayCities.isEmpty {
                                Text(dayCities.map(\.cityName).joined(separator: " · "))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(
                                        .leading,
                                        ContinuousTimelineLayout.markerCenterX
                                            + ContinuousTimelineLayout.markerSize / 2
                                            + ContinuousTimelineLayout.markerSpacing
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(height: 30)
                        ForEach(dayItems) { item in
                            TripTimelineRow(
                                item: item,
                                activityStyle: activityStyle(for: item),
                                transportDistance: transportDistance(for: item),
                                photoAssetIDs: item.actualPhotoAssetIDs,
                                onSelect: { openRecordDetail(for: item) },
                                onShowAllPhotos: { openRecordDetail(for: item, startsExpanded: true) }
                            )
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TripTimelineItemFramePreferenceKey.self,
                                        value: [item.id: geometry.frame(in: .named("tripTimelineScroll"))]
                                    )
                                }
                            }
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        Text("第\(dayIndex + 1)天")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .dfkDetailMaterial(in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                }
                if trip.state == .planned {
                    Button("开始行程") { startTrip() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                } else if trip.state == .active {
                    Button("结束行程", role: .destructive) { endTrip() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
        }
        .task {
            activityStyles = await TripScanManager.shared.activityStyles()
        }
    }

    private func dayTitle(_ day: TripDay) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"
        return formatter.string(from: day.day)
    }

    private func significantVisibleItemIDs(
        in frames: [UUID: CGRect],
        viewportHeight: CGFloat
    ) -> Set<UUID> {
        guard viewportHeight > 0 else { return [] }
        let bandTop: CGFloat = 52
        let bandBottom = max(bandTop, viewportHeight - 72)
        let centerY = viewportHeight * 0.5
        var result = Set<UUID>()
        for (id, frame) in frames {
            let visibleTop = max(frame.minY, bandTop)
            let visibleBottom = min(frame.maxY, bandBottom)
            let visibleHeight = max(0, visibleBottom - visibleTop)
            let minimumVisibleHeight = min(48, max(16, frame.height * 0.3))
            let containsCenter = frame.minY <= centerY && frame.maxY >= centerY
            if visibleHeight >= minimumVisibleHeight || containsCenter {
                result.insert(id)
            }
        }
        return result
    }

    private func openRecordDetail(for item: TripItem, startsExpanded: Bool = false) {
        selectedTimelineItemID = item.id
        guard let container = TripScanManager.shared.recordModelContainer else { return }
        if let footprintID = item.sourceFootprintID {
            let descriptor = FetchDescriptor<Footprint>(
                predicate: #Predicate { $0.footprintID == footprintID }
            )
            if detentBeforeFootprintDetail == nil {
                detentBeforeFootprintDetail = detent
            }
            detent = .medium
            selectedFootprintStartsExpanded = startsExpanded
            selectedFootprint = try? container.mainContext.fetch(descriptor).first
            return
        }
        guard let recordID = item.sourceTransportRecordID else { return }
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID == recordID }
        )
        guard let record = try? container.mainContext.fetch(descriptor).first else { return }
        let route = transportRoutes[recordID] ?? []
        let coordinates = route.compactMap { point -> CLLocationCoordinate2D? in
            let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            return point.lat.isFinite && point.lon.isFinite && CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
        let type = TransportType(rawValue: record.typeRaw) ?? .slow
        let manualType = record.manualTypeRaw.flatMap(TransportType.init(rawValue:))
        selectedTransport = Transport(
            id: record.recordID,
            startTime: record.startTime,
            endTime: record.endTime,
            startLocation: record.startLocation,
            endLocation: record.endLocation,
            type: type,
            distance: record.distance,
            averageSpeed: record.averageSpeed,
            points: coordinates,
            manualType: manualType,
            stepCount: record.stepCount
        )
    }

    private func updateTransport(_ transport: Transport, type: TransportType, in container: ModelContainer) {
        let recordID = transport.id
        let descriptor = FetchDescriptor<TransportRecord>(
            predicate: #Predicate { $0.recordID == recordID }
        )
        if let record = try? container.mainContext.fetch(descriptor).first {
            record.manualTypeRaw = type.rawValue
            record.typeRaw = type.rawValue
            try? container.mainContext.save()
            CloudSettingsManager.shared.triggerDataSyncPulse()
            onRecordChanged()
            NotificationCenter.default.post(name: NSNotification.Name("FootprintDataChanged"), object: nil)
        }
    }

    private var headerSubtitle: String {
        let calendar = Calendar.current
        let startYear = calendar.component(.year, from: trip.plannedStartDay)
        let endYear = calendar.component(.year, from: trip.plannedEndDay)
        let year = startYear == endYear ? "\(startYear)年" : "\(startYear)–\(endYear)年"
        let count = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.plannedStartDay), to: calendar.startOfDay(for: trip.plannedEndDay)).day ?? 0) + 1)
        return "\(year) · 共\(count)天"
    }

    private func activityStyle(for item: TripItem) -> TripActivityStyle? {
        guard let value = item.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }
    private func transportDistance(for item: TripItem) -> Double? {
        guard item.kindRaw == TripItemKind.transport.rawValue,
              let sourceID = item.sourceTransportRecordID,
              let points = transportRoutes[sourceID] else { return nil }
        let coordinates = points.compactMap { point -> CLLocation? in
            guard point.lat.isFinite, point.lon.isFinite else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return CLLocation(latitude: point.lat, longitude: point.lon)
        }
        guard coordinates.count > 1 else { return nil }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.distance(from: pair.1)
        }
    }
    private var tripActivityStyle: TripActivityStyle? {
        guard let value = trip.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }
    private func showActivityTypePicker() {
        let items = activityStyles.compactMap { style -> StableActivityPickerItem? in
            guard let id = UUID(uuidString: style.id) else { return nil }
            return StableActivityPickerItem(id: id, name: style.name, icon: style.icon)
        }
        activityPickerPresentation = ActivityPickerPresentation(suggestedItems: [], allItems: items)
    }
    private func updateTripActivityType(_ id: UUID?) {
        trip.activityTypeValue = id?.uuidString
        trip.updatedAt = Date()
        try? context.save()
    }
    private func startTrip() {
        trip.state = .active; trip.actualStartedAt = Date(); trip.updatedAt = Date(); try? context.save()
    }
    private func endTrip() {
        trip.state = .historical; trip.kind = .historical; trip.actualEndedAt = Date(); trip.endReasonRaw = TripEndReason.manual.rawValue; trip.updatedAt = Date(); try? context.save()
    }
}

private struct TripTimelineItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct TripPlaceSelection {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let cityName: String
    let countryCode: String
    let countryName: String
    let timeZoneIdentifier: String?
}

private struct TripPlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlacePickerViewModel()
    @State private var query = ""
    @State private var resolvingID: String?
    let onSelect: (TripPlaceSelection) -> Void

    var body: some View {
        NavigationStack {
            List(search.searchResults) { result in
                Button { resolve(result) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.name).foregroundStyle(.primary)
                            if !result.address.isEmpty { Text(result.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        if resolvingID == result.id { ProgressView() }
                    }
                }
                .disabled(resolvingID != nil)
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("搜索地点", systemImage: "magnifyingglass", description: Text("输入名称，选择你去过的地点。"))
                } else if search.isSearching && search.searchResults.isEmpty {
                    ProgressView("正在搜索…")
                }
            }
            .navigationTitle("选择地点")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索地点")
            .onChange(of: query) { _, value in search.search(query: value, userCoord: nil) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func resolve(_ result: PlaceSearchResult) {
        resolvingID = result.id
        Task {
            let location = CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let city = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
            guard let city, !city.isEmpty else { resolvingID = nil; return }
            onSelect(TripPlaceSelection(
                name: result.name, address: result.address,
                latitude: result.coordinate.latitude, longitude: result.coordinate.longitude,
                cityName: city, countryCode: placemark?.isoCountryCode ?? "",
                countryName: placemark?.country ?? "", timeZoneIdentifier: placemark?.timeZone?.identifier
            ))
            dismiss()
        }
    }
}

private struct TripEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let trip: Trip
    @Query private var allDays: [TripDay]
    @Query private var allCities: [TripDayCity]
    @Query private var allItems: [TripItem]
    @State private var title: String
    @State private var notes: String
    @State private var itemTarget: ItemTarget?
    @State private var placeTarget: PlaceTarget?
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var activityTypeValue: String?
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var draggedStopID: UUID?
    @State private var dragTargetID: UUID?
    @State private var dragOffset: CGFloat = 0

    init(trip: Trip) {
        self.trip = trip
        _title = State(initialValue: trip.title)
        _notes = State(initialValue: trip.notes)
        _activityTypeValue = State(initialValue: trip.activityTypeValue)
        _startDay = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedStartDay))
        _endDay = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedEndDay))
    }

    private var days: [TripDay] {
        allDays.filter { $0.tripID == trip.id }.sorted { $0.day < $1.day }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    tripInfoCard
                    if trip.kind == .historical {
                        historicalDateSummary
                    } else {
                        ForEach(days) { day in
                            daySection(for: day)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("编辑行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: save) }
            }
        }
        .sheet(item: $placeTarget) { target in
            TripPlaceSearchView { selection in
                save(selection, target: target)
                placeTarget = nil
            }
        }
        .sheet(item: $itemTarget) { target in
            TripItemEditorView(target: target) {
                markEdited()
                itemTarget = nil
            }
        }
        .task { activityStyles = await TripScanManager.shared.activityStyles() }
    }

    private var tripInfoCard: some View {
        VStack(spacing: 14) {
            TextField("标题", text: $title)
                .font(.headline)
            Divider()
            TextField("备注", text: $notes, axis: .vertical)
                .lineLimit(2...5)
            Divider()
            TripActivityTypePicker(styles: activityStyles, selection: $activityTypeValue)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var historicalDateSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("行程记录", systemImage: "calendar")
                .font(.headline)
            Text("这里会显示这段时间内的足迹、交通和照片，并随记录页的修改更新。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            DatePicker("开始日期", selection: $startDay, displayedComponents: .date)
            DatePicker("结束日期", selection: $endDay, in: startDay..., displayedComponents: .date)
            Text("调整日期后，行程内容会自动更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: startDay) { _, value in
            if endDay < value { endDay = value }
        }
    }

    @ViewBuilder
    private func daySection(for day: TripDay) -> some View {
        let items = dayItems(for: day)
        let groups = cityGroups(day: day, items: items)
        VStack(alignment: .leading, spacing: 12) {
            Text(day.day.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.title3.bold())
            ForEach(groups) { group in
                citySection(group, day: day, items: items)
            }
            if groups.isEmpty {
                addPlaceButton(for: day)
            }
        }
        .zIndex(items.contains(where: { $0.id == draggedStopID }) ? 400 : 0)
    }

    @ViewBuilder
    private func citySection(_ group: CityGroup, day: TripDay, items: [TripItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cityHeader(group.name)
            ForEach(group.stops) { stop in
                if draggedStopID != stop.id, dragTargetID == stop.id {
                    stopDropPlaceholder
                }
                stopContent(stop, group: group, day: day, items: items)
            }
            addPlaceButton(for: day)
        }
        .padding(.bottom, 8)
        .zIndex(group.stops.contains(where: { $0.id == draggedStopID }) ? 500 : 0)
    }

    private func cityHeader(_ name: String) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .padding(.top, 14)
    }

    private func addPlaceButton(for day: TripDay) -> some View {
        Button {
            placeTarget = PlaceTarget(day: day, item: nil)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.dfkAccent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加地点")
                        .font(.headline)
                    Text("搜索并选择去过的地点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Color.dfkAccent)
            .frame(minHeight: 64)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.42))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.dfkAccent.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
                    }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stopContent(_ stop: TripItem, group: CityGroup, day: TripDay, items: [TripItem]) -> some View {
        VStack(spacing: 6) {
            TripSwipeDeleteContainer(deleteLabel: "删除地点") {
                deleteStopAndFollowingTransports(stop, in: items)
            } content: {
                stopCard(
                    stop,
                    groupStops: group.stops,
                    dayItems: items,
                    onEdit: { placeTarget = PlaceTarget(day: day, item: stop) },
                    onDelete: { deleteStopAndFollowingTransports(stop, in: items) }
                )
            }
            .offset(y: draggedStopID == stop.id ? dragOffset : 0)
            .scaleEffect(draggedStopID == stop.id ? 1.025 : 1)
            .shadow(color: draggedStopID == stop.id ? .black.opacity(0.34) : .clear, radius: 18, y: 10)
            .zIndex(draggedStopID == stop.id ? 1_000 : 0)

            ForEach(transports(after: stop, in: items)) { transport in
                transportRow(transport, after: stop, day: day, items: items)
            }

            if nextStop(after: stop, in: items) != nil {
                Button {
                    itemTarget = ItemTarget(day: day, item: nil, kind: .transport, afterStopID: stop.id)
                } label: {
                    Label("添加交通", systemImage: "plus.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
        .zIndex(draggedStopID == stop.id ? 900 : 0)
    }

    private var stopDropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(height: 72)
            .overlay {
                Text("放到这里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private func stopCard(
        _ stop: TripItem,
        groupStops: [TripItem],
        dayItems: [TripItem],
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        let style = activityStyle(for: stop)
        let icon = style?.icon ?? FootprintIconDefaults.card
        let tint = style.flatMap { Color(hex: $0.colorHex) } ?? .secondary
        return HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(itemTitle(stop)).font(.headline).foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            if let startTime = stop.startTime {
                                Text(startTime.formatted(.dateTime.hour().minute()))
                            }
                            if let name = style?.name { Text(name) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let address = stop.address, !address.isEmpty, address != stop.placeName {
                            Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("删除地点", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("拖动地点排序")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(stopDragGesture(stop, groupStops: groupStops, dayItems: dayItems))
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stopDragGesture(_ stop: TripItem, groupStops: [TripItem], dayItems: [TripItem]) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if draggedStopID == nil { draggedStopID = stop.id }
                guard draggedStopID == stop.id,
                      let source = groupStops.firstIndex(where: { $0.id == stop.id }) else { return }
                dragOffset = value.translation.height
                let step = Int((value.translation.height / 80).rounded())
                let target = min(max(source + step, 0), groupStops.count - 1)
                dragTargetID = groupStops[target].id
            }
            .onEnded { _ in
                let draggedID = draggedStopID
                let targetID = dragTargetID
                withAnimation(.snappy(duration: 0.22)) {
                    dragOffset = 0
                    draggedStopID = nil
                    dragTargetID = nil
                }
                if let draggedID, let targetID, draggedID != targetID {
                    moveStop(draggedID: draggedID, before: targetID, in: groupStops, dayItems: dayItems)
                }
            }
    }

    private func transportRow(_ transport: TripItem, after stop: TripItem, day: TripDay, items: [TripItem]) -> some View {
        TripSwipeDeleteContainer(deleteLabel: "删除交通") {
            deleteTransport(transport, from: items)
        } content: {
            HStack(spacing: 4) {
                Button {
                    itemTarget = ItemTarget(day: day, item: transport, kind: .transport, afterStopID: stop.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: TransportType(rawValue: transport.transportTypeRaw ?? "")?.icon ?? "arrow.triangle.swap")
                            .frame(width: 24)
                        Text(transportTitle(transport)).lineLimit(1)
                        Spacer()
                        if let startTime = transport.startTime {
                            Text(startTime.formatted(.dateTime.hour().minute()))
                                .font(.caption)
                        }
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                Menu {
                    Button("删除交通", systemImage: "trash", role: .destructive) {
                        deleteTransport(transport, from: items)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func dayItems(for day: TripDay) -> [TripItem] {
        allItems
            .filter { $0.tripDayID == day.id }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    private func deleteTransport(_ transport: TripItem, from items: [TripItem]) {
        context.delete(transport)
        normalize(items.filter { $0.id != transport.id })
        markEdited()
    }

    private func itemTitle(_ item: TripItem) -> String {
        return item.placeName ?? item.address ?? item.cityName ?? "足迹"
    }

    private func activityStyle(for item: TripItem) -> TripActivityStyle? {
        guard let value = item.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }

    private func transportTitle(_ item: TripItem) -> String {
        let type = TransportType(rawValue: item.transportTypeRaw ?? "")?.localizedName ?? "交通"
        return item.lineName.flatMap { $0.isEmpty ? nil : "\(type) · \($0)" } ?? type
    }

    private func save(_ selection: TripPlaceSelection, target: PlaceTarget) {
        let previousCityKey = target.item.map { "\($0.countryCode ?? "")|\($0.cityName ?? "")".lowercased() }
        let item = target.item ?? TripItem(tripDayID: target.day.id, kind: .stop, orderIndex: allItems.filter { $0.tripDayID == target.day.id }.count)
        item.placeName = selection.name; item.address = selection.address
        item.latitude = selection.latitude; item.longitude = selection.longitude
        item.countryCode = selection.countryCode; item.countryName = selection.countryName
        item.cityName = selection.cityName; item.startTime = item.startTime ?? target.day.day
        if target.item == nil { context.insert(item) }
        ensureCity(for: selection, day: target.day)
        if let previousCityKey, previousCityKey != "\(selection.countryCode)|\(selection.cityName)".lowercased(),
           !allItems.contains(where: { $0.tripDayID == target.day.id && $0.id != item.id && "\($0.countryCode ?? "")|\($0.cityName ?? "")".lowercased() == previousCityKey }),
           let unused = allCities.first(where: { $0.tripDayID == target.day.id && "\($0.countryCode)|\($0.cityName)".lowercased() == previousCityKey }) {
            context.delete(unused)
        }
        markEdited()
    }

    private func ensureCity(for place: TripPlaceSelection, day: TripDay) {
        let key = "\(place.countryCode)|\(place.cityName)".lowercased()
        guard !allCities.contains(where: { $0.tripDayID == day.id && "\($0.countryCode)|\($0.cityName)".lowercased() == key }) else { return }
        let city = TripDayCity(tripDayID: day.id, countryCode: place.countryCode, countryName: place.countryName, cityName: place.cityName, latitude: place.latitude, longitude: place.longitude, timeZoneIdentifier: place.timeZoneIdentifier, orderIndex: allCities.filter { $0.tripDayID == day.id }.count)
        context.insert(city)
    }

    private func cityGroups(day: TripDay, items: [TripItem]) -> [CityGroup] {
        let stops = items.filter { $0.kindRaw == TripItemKind.stop.rawValue }
        var keys: [String] = []; var names: [String: String] = [:]; var grouped: [String: [TripItem]] = [:]
        for stop in stops {
            let name = stop.cityName.flatMap { $0.isEmpty ? nil : $0 } ?? "未识别城市"
            let key = "\(stop.countryCode ?? "")|\(name)".lowercased()
            if grouped[key] == nil { keys.append(key); names[key] = name }
            grouped[key, default: []].append(stop)
        }
        return keys.map { CityGroup(id: $0, name: names[$0] ?? "未识别城市", stops: grouped[$0] ?? []) }
    }

    private func transports(after stop: TripItem, in items: [TripItem]) -> [TripItem] {
        guard let index = items.firstIndex(where: { $0.id == stop.id }) else { return [] }
        return Array(items.dropFirst(index + 1).prefix { $0.kindRaw == TripItemKind.transport.rawValue })
    }

    private func nextStop(after stop: TripItem, in items: [TripItem]) -> TripItem? {
        guard let index = items.firstIndex(where: { $0.id == stop.id }) else { return nil }
        return items.dropFirst(index + 1).first { $0.kindRaw == TripItemKind.stop.rawValue }
    }

    private func deleteStopAndFollowingTransports(_ stop: TripItem, in items: [TripItem]) {
        transports(after: stop, in: items).forEach(context.delete)
        context.delete(stop); normalize(items.filter { $0.id != stop.id }); markEdited()
    }

    private func moveStops(_ groupStops: [TripItem], from source: IndexSet, to destination: Int, in items: [TripItem]) {
        var reordered = groupStops
        reordered.move(fromOffsets: source, toOffset: destination)
        var iterator = reordered.makeIterator()
        let orderedStops = items.filter { $0.kindRaw == TripItemKind.stop.rawValue }.map { stop in
            groupStops.contains(where: { $0.id == stop.id }) ? (iterator.next() ?? stop) : stop
        }
        var rebuilt: [TripItem] = []
        for stop in orderedStops { rebuilt.append(stop); rebuilt.append(contentsOf: transports(after: stop, in: items)) }
        normalize(rebuilt); markEdited()
    }

    @discardableResult
    private func moveStop(draggedID: UUID, before targetID: UUID, in groupStops: [TripItem], dayItems: [TripItem]) -> Bool {
        guard draggedID != targetID,
              let source = groupStops.firstIndex(where: { $0.id == draggedID }),
              let target = groupStops.firstIndex(where: { $0.id == targetID }) else { return false }
        var reordered = groupStops
        let moved = reordered.remove(at: source)
        reordered.insert(moved, at: min(target, reordered.count))
        var iterator = reordered.makeIterator()
        let orderedStops = dayItems.filter { $0.kindRaw == TripItemKind.stop.rawValue }.map { stop in
            groupStops.contains(where: { $0.id == stop.id }) ? (iterator.next() ?? stop) : stop
        }
        var rebuilt: [TripItem] = []
        for stop in orderedStops {
            rebuilt.append(stop)
            rebuilt.append(contentsOf: transports(after: stop, in: dayItems))
        }
        normalize(rebuilt)
        markEdited()
        return true
    }

    private func normalize(_ items: [TripItem]) { items.enumerated().forEach { $0.element.orderIndex = $0.offset } }

    private func markEdited() {
        trip.citiesUserEdited = true
        trip.updatedAt = Date()
        try? context.save()
    }

    private func save() {
        trip.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.notes = notes
        trip.activityTypeValue = activityTypeValue
        trip.titleUserEdited = true
        if trip.kind == .historical {
            updateHistoricalDateRange()
        }
        trip.updatedAt = Date()
        try? context.save()
        dismiss()
    }

    private func updateHistoricalDateRange() {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: startDay)
        let end = max(start, calendar.startOfDay(for: endDay))
        trip.plannedStartDay = start
        trip.plannedEndDay = end
        trip.datesUserEdited = true

        let existingDays = allDays.filter { $0.tripID == trip.id }
        let retainedDays = existingDays.filter { day in
            let value = calendar.startOfDay(for: day.day)
            return value >= start && value <= end
        }
        let removedDayIDs = Set(existingDays.filter { day in
            let value = calendar.startOfDay(for: day.day)
            return value < start || value > end
        }.map(\.id))
        allCities.filter { removedDayIDs.contains($0.tripDayID) }.forEach(context.delete)
        allItems.filter { removedDayIDs.contains($0.tripDayID) }.forEach(context.delete)
        existingDays.filter { removedDayIDs.contains($0.id) }.forEach(context.delete)

        var resultingDays = retainedDays
        var cursor = start
        while cursor <= end {
            if !resultingDays.contains(where: { calendar.isDate($0.day, inSameDayAs: cursor) }) {
                let day = TripDay(tripID: trip.id, day: cursor)
                context.insert(day)
                resultingDays.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for (index, day) in resultingDays.sorted(by: { $0.day < $1.day }).enumerated() {
            day.orderIndex = index
        }
    }

    struct CityGroup: Identifiable { let id: String; let name: String; let stops: [TripItem] }
    struct PlaceTarget: Identifiable { let id = UUID(); let day: TripDay; let item: TripItem? }

    struct ItemTarget: Identifiable {
        let id = UUID()
        let day: TripDay
        let item: TripItem?
        let kind: TripItemKind
        let afterStopID: UUID?
    }
}

private struct TripSwipeDeleteContainer<Content: View>: View {
    let deleteLabel: String
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var horizontalOffset: CGFloat = 0
    @State private var isHorizontalDrag = false
    @State private var dragStartOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: delete) {
                Label(deleteLabel, systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 52)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            content()
                .offset(x: horizontalOffset)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(horizontalSwipeGesture)
    }

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if horizontal, !isHorizontalDrag {
                    isHorizontalDrag = true
                    dragStartOffset = horizontalOffset
                }
                guard isHorizontalDrag else { return }
                horizontalOffset = min(0, max(-120, dragStartOffset + value.translation.width))
            }
            .onEnded { value in
                guard isHorizontalDrag else { return }
                isHorizontalDrag = false
                if value.translation.width < -150 {
                    delete()
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
                        horizontalOffset = horizontalOffset < -40 ? -82 : 0
                    }
                }
            }
    }

    private func delete() {
        withAnimation(.snappy(duration: 0.18)) { horizontalOffset = -160 }
        onDelete()
    }
}

private struct TripItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allItems: [TripItem]
    let target: TripEditorView.ItemTarget
    let onSave: () -> Void
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var transportTypeRaw: String
    @State private var lineName: String
    @State private var notes: String

    init(target: TripEditorView.ItemTarget, onSave: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        let item = target.item
        let base = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: target.day.day) ?? target.day.day
        _startTime = State(initialValue: item?.startTime ?? base)
        _endTime = State(initialValue: item?.endTime ?? base.addingTimeInterval(3600))
        _transportTypeRaw = State(initialValue: item?.transportTypeRaw ?? TransportType.slow.rawValue)
        _lineName = State(initialValue: item?.lineName ?? "")
        _notes = State(initialValue: item?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("交通方式", selection: $transportTypeRaw) {
                    ForEach(TransportType.allCases, id: \.rawValue) { type in Text(type.localizedName).tag(type.rawValue) }
                }
                TextField("线路（可选）", text: $lineName)
                DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $endTime, in: startTime..., displayedComponents: .hourAndMinute)
                TextField("备注", text: $notes, axis: .vertical)
            }
            .navigationTitle("编辑交通")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        let item = target.item ?? TripItem(tripDayID: target.day.id, kind: target.kind)
        item.kindRaw = target.kind.rawValue
        item.startTime = startTime
        item.endTime = endTime
        item.notes = notes
        item.transportTypeRaw = transportTypeRaw
        item.lineName = lineName
        if target.item == nil, let stopID = target.afterStopID {
            let dayItems = allItems.filter { $0.tripDayID == target.day.id }.sorted { $0.orderIndex < $1.orderIndex }
            if let stopIndex = dayItems.firstIndex(where: { $0.id == stopID }) {
                let insertionIndex = dayItems.dropFirst(stopIndex + 1).prefix { $0.kindRaw == TripItemKind.transport.rawValue }.count + stopIndex + 1
                dayItems.enumerated().filter { $0.offset >= insertionIndex }.forEach { $0.element.orderIndex += 1 }
                item.orderIndex = insertionIndex
            }
        }
        if target.item == nil { context.insert(item) }
        try? context.save()
        onSave()
        dismiss()
    }
}

private struct TripTimelineRow: View {
    let item: TripItem
    let activityStyle: TripActivityStyle?
    let transportDistance: Double?
    let photoAssetIDs: [String]
    let onSelect: () -> Void
    let onShowAllPhotos: () -> Void
    @State private var selectedPhotoID: IdentifiableString?

    private var isTransport: Bool { item.kindRaw == TripItemKind.transport.rawValue }
    private var transportType: TransportType? { TransportType(rawValue: item.transportTypeRaw ?? "") }
    private var icon: String { isTransport ? (transportType?.icon ?? "arrow.triangle.swap") : (activityStyle?.icon ?? FootprintIconDefaults.card) }
    private var tint: Color { activityStyle.flatMap { Color(hex: $0.colorHex) } ?? .gray }

    var body: some View {
        HStack(alignment: .top, spacing: ContinuousTimelineLayout.markerSpacing) {
            Text(item.startTime?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isTransport ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: ContinuousTimelineLayout.timeColumnWidth, alignment: .leading)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

            VStack(spacing: 0) {
                marker
                Rectangle()
                    .fill(ContinuousTimelineLayout.lineColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: ContinuousTimelineLayout.markerSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            Group {
                if isTransport {
                    Text(transportSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 5)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onSelect)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.placeName ?? item.address ?? item.cityName ?? "未知地点")
                                .font(.body.weight(.bold))
                                .lineLimit(2)
                            Text(stopDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !item.notes.isEmpty {
                                Text(item.notes)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(5)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onSelect)

                        if !photoAssetIDs.isEmpty {
                            TimelinePhotoGrid(
                                assetIDs: photoAssetIDs,
                                onPhotoTap: { assetID in
                                    selectedPhotoID = IdentifiableString(value: assetID)
                                },
                                onOverflowTap: onShowAllPhotos
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, bottomSpacing)
        }
        .frame(minHeight: 52, alignment: .top)
        .fullScreenCover(item: $selectedPhotoID) { selectedPhoto in
            let index = photoAssetIDs.firstIndex(of: selectedPhoto.value) ?? 0
            PhotoFullscreenView(assetIDs: photoAssetIDs, currentIndex: index)
        }
    }

    @ViewBuilder
    private var marker: some View {
        if isTransport {
            TimelineTransportMarker(icon: icon)
        } else {
            TimelineFootprintMarker(icon: icon, tint: tint)
        }
    }

    private var stopDetail: String {
        let activity = activityStyle?.name
        let duration = durationText
        return [activity, duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var transportSummary: String {
        return [transportDistance.map(formatTimelineDistance), durationText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func formatTimelineDistance(_ distance: Double) -> String {
        distance >= 1_000 ? String(format: "%.1f 公里", distance / 1_000) : "\(Int(distance.rounded())) 米"
    }

    private var durationText: String? {
        guard let start = item.startTime, let end = item.endTime else { return nil }
        return end.timeIntervalSince(start).formattedTimelineDuration
    }

    private var bottomSpacing: CGFloat {
        ContinuousTimelineLayout.minItemSpacing
    }

}
