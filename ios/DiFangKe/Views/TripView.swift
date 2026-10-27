import SwiftUI
import SwiftData
import MapKit
import Photos
import CryptoKit
import UniformTypeIdentifiers

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
    @State private var showingCreatePurpose = false
    @State private var createPurpose: TripCreationPurpose?
    @State private var createdTripToOpen: Trip?
    @State private var showingOptions = false
    @State private var showingIntroduction = false
    @State private var selectedTrip: Trip?
    @State private var editorPresentation: TripEditorPresentation?
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
    private var plannedTrips: [Trip] {
        trips.filter { $0.state == .planned }.sorted {
            if $0.datesUserEdited != $1.datesUserEdited { return $0.datesUserEdited }
            return $0.plannedStartDay < $1.plannedStartDay
        }
    }
    private var remainingTrips: [Trip] {
        trips.filter { $0.state != .active && $0.state != .planned }
            .sorted { $0.plannedStartDay > $1.plannedStartDay }
    }
    private var yearSections: [TripYearSection] {
        let grouped = Dictionary(grouping: remainingTrips) {
            Calendar.autoupdatingCurrent.component(.year, from: $0.plannedStartDay)
        }
        return grouped.keys.sorted(by: >).map { TripYearSection(year: $0, trips: grouped[$0] ?? []) }
    }
    private var scheduledTripLifecycleSignature: String {
        trips.filter { $0.datesUserEdited }.map {
            "\($0.id)|\($0.kindRaw)|\($0.stateRaw)|\($0.plannedStartDay.timeIntervalSinceReferenceDate)|\($0.plannedEndDay.timeIntervalSinceReferenceDate)"
        }.joined(separator: ";")
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

                if !plannedTrips.isEmpty {
                    Section {
                        ForEach(plannedTrips) { trip in
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
                            .contextMenu { tripContextMenu(for: trip) }
                        }
                    } header: {
                        Text("计划行程")
                            .font(.title2.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .dfkDetailMaterial(in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
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
                        showingCreatePurpose = true
                    } label: {
                        Label("创建行程", systemImage: "plus")
                    }
                    .confirmationDialog("创建行程", isPresented: $showingCreatePurpose, titleVisibility: .visible) {
                        Button("规划一次出行") {
                            createPurpose = .planned
                            showingCreate = true
                        }
                        Button("补记过去行程") {
                            createPurpose = .historical
                            showingCreate = true
                        }
                        Button("取消", role: .cancel) { }
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
        .sheet(isPresented: $showingCreate, onDismiss: {
            createPurpose = nil
            if let trip = createdTripToOpen {
                createdTripToOpen = nil
                selectedTrip = trip
            }
        }) {
            if createPurpose == .planned {
                PlanTripCreateView { createdTripToOpen = $0 }
            } else {
                CreateTripView(activityStyles: createActivityStyles, forcesHistorical: true)
            }
        }
        .sheet(isPresented: $showingOptions) { TripOptionsView() }
        .sheet(item: $editorPresentation) { presentation in
            IsolatedTripEditorHost(
                container: context.container,
                tripID: presentation.trip.id,
                mode: presentation.mode
            )
                .presentationDetents(
                    presentation.mode == .itinerary
                        ? [.large]
                        : presentation.mode == .basic
                        ? [.fraction(0.72)]
                        : [.large]
                )
                .presentationDragIndicator(.visible)
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
        .fullScreenCover(item: $selectedTrip) { selected in
            let currentTrip = trips.first(where: { $0.id == selected.id }) ?? selected
            if currentTrip.state == .planned || currentTrip.state == .active {
                PlannedTripDetailView(trip: currentTrip) { selectedTrip = nil }
            } else {
                TripDetailView(trip: currentTrip) { selectedTrip = nil }
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
        .onAppear {
            openRequestedTripIfNeeded()
            scanManager.refreshActiveTripProgress()
        }
        .onChange(of: scanManager.requestedTripID) { _, _ in openRequestedTripIfNeeded() }
        .onChange(of: trips.map(\.id)) { _, _ in openRequestedTripIfNeeded() }
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
            refreshScheduledTripStates()
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
            refreshScheduledTripStates()
            scanManager.resumeAfterAppForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshScheduledTripStates()
        }
        .onChange(of: scheduledTripLifecycleSignature) { _, _ in
            refreshScheduledTripStates()
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

    private func refreshScheduledTripStates() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        var changed = false

        for trip in trips where trip.datesUserEdited && (trip.kind == .planned || trip.state == .planned) {
            if trip.state == .planned,
               trip.actualStartedAt == nil,
               trip.actualEndedAt != nil,
               trip.endReasonRaw == TripEndReason.corrected.rawValue {
                continue
            }
            let start = calendar.startOfDay(for: trip.plannedStartDay)
            let end = calendar.startOfDay(for: trip.plannedEndDay)
            let state: TripState
            let kind: TripKind

            if end < today {
                state = .historical
                kind = .historical
            } else if start <= today {
                state = .active
                kind = .planned
            } else {
                state = .planned
                kind = .planned
            }

            guard trip.state != state || trip.kind != kind else { continue }
            trip.state = state
            trip.kind = kind
            if state == .active, trip.actualStartedAt == nil {
                trip.actualStartedAt = start
            } else if state == .planned {
                trip.actualStartedAt = nil
                trip.actualEndedAt = nil
            }
            trip.updatedAt = Date()
            changed = true
        }

        if changed {
            try? context.save()
            scanManager.refreshActiveTripProgress()
        }
    }

    private func openRequestedTripIfNeeded() {
        guard isActive,
              let requestedID = scanManager.requestedTripID,
              let trip = trips.first(where: { $0.id == requestedID }) else { return }
        selectedTrip = trip
        scanManager.consumeRequestedTripID()
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

        if trip.state == .planned || trip.state == .active {
            Button {
                editorPresentation = TripEditorPresentation(trip: trip, mode: .basic)
            } label: {
                Label("基本信息", systemImage: "info.circle")
            }
            Button {
                editorPresentation = TripEditorPresentation(trip: trip, mode: .itinerary)
            } label: {
                Label("行程安排", systemImage: "list.bullet.rectangle")
            }
        } else {
            Button {
                editorPresentation = TripEditorPresentation(trip: trip, mode: nil)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
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
        selected.forEach { scanManager.endTripProgressActivity(for: $0.id) }
        selected.forEach { context.delete($0) }
        try? context.save()
    }

    private func canSplit(_ trip: Trip) -> Bool {
        guard trip.kind == .historical, trip.state == .historical else { return false }
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
        newTrip.datesUserEdited = trip.datesUserEdited
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
        trip.datesUserEdited = newTrip.datesUserEdited
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
    private func cityKey(_ city: TripDayCity) -> String {
        tripCityIdentityKey(identifier: city.cityIdentifier, countryCode: city.countryCode, cityName: city.cityName)
    }
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
    @State private var activeRoute: TripPlannedRoute?
    private var cityNames: [String] {
        let tripDays = allDays.filter { $0.tripID == trip.id }.sorted {
            $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day
        }
        var seen = Set<String>()
        return tripDays.flatMap { day in
            allCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
        }
            .compactMap { city in
                let name = city.cityName.trimmingCharacters(in: .whitespacesAndNewlines)
                return !name.isEmpty && seen.insert(name).inserted ? name : nil
            }
    }

    private var tripItems: [TripItem] {
        let tripDays = allDays.filter { $0.tripID == trip.id }.sorted {
            $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day
        }
        let dayOrder = Dictionary(uniqueKeysWithValues: tripDays.enumerated().map { ($0.element.id, $0.offset) })
        return allItems.filter { dayOrder[$0.tripDayID] != nil }.sorted {
            let leftDay = dayOrder[$0.tripDayID] ?? .max
            let rightDay = dayOrder[$1.tripDayID] ?? .max
            return leftDay == rightDay ? $0.orderIndex < $1.orderIndex : leftDay < rightDay
        }
    }

    private var tripCities: [TripDayCity] {
        allDays.filter { $0.tripID == trip.id }.sorted {
            $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day
        }.flatMap { day in
            allCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
        }
    }

    private var nextStop: TripItem? {
        guard prominent else { return nil }
        return tripItems.first {
            $0.kindRaw == TripItemKind.stop.rawValue && $0.planStatusRaw == "planned"
        }
    }

    private var previousStop: TripItem? {
        guard let nextStop,
              let index = tripItems.firstIndex(where: { $0.id == nextStop.id }),
              index > 0 else { return nil }
        return tripItems[..<index].last { $0.kindRaw == TripItemKind.stop.rawValue }
    }

    private var activeRouteOrigin: TripPlanOrigin? {
        if let previousStop,
           let latitude = previousStop.latitude,
           let longitude = previousStop.longitude {
            return TripPlanOrigin(
                name: previousStop.placeName ?? previousStop.address ?? previousStop.cityName ?? "上一站",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
        guard let homeCity,
              let latitude = homeCity.latitude,
              let longitude = homeCity.longitude else { return nil }
        return TripPlanOrigin(
            name: homeCity.cityName.isEmpty ? "常居地" : homeCity.cityName,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private var nextStopTitle: String {
        guard let nextStop else { return "行程进行中" }
        return nextStop.placeName ?? nextStop.address ?? nextStop.cityName ?? "地点"
    }

    private var activeRouteKey: String {
        guard let nextStop, let activeRouteOrigin else { return "none" }
        return "\(activeRouteOrigin.name)|\(activeRouteOrigin.coordinate.latitude),\(activeRouteOrigin.coordinate.longitude)|\(nextStop.id)|\(nextStop.transportTypeRaw ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TripListCardHero(
                layoutSeed: trip.id.uuidString,
                items: tripItems,
                cities: tripCities,
                homeCity: homeCity,
                usesPlannedStopMarkers: trip.kind == .planned,
                actualDayRequests: trip.kind == .historical ? allDays.filter { $0.tripID == trip.id }.map {
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
                if trip.kind != .planned || trip.datesUserEdited {
                    HStack {
                        Label(dateRangeText, systemImage: "calendar")
                        Spacer()
                        Text(dayCountText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if trip.state == .planned {
                    HStack {
                        if trip.datesUserEdited {
                            Text(plannedStatusText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.dfkAccent)
                        }
                        Spacer()
                    }
                }
                if prominent {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.green.opacity(0.09))
                        .frame(height: 76)
                        .overlay {
                            HStack(spacing: 10) {
                                Image(systemName: nextStop?.transportTypeRaw.flatMap(TransportType.init(rawValue:))?.icon ?? "mappin.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(nextStopTitle)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text(activeRouteText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
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
        .task(id: activeRouteKey) {
            guard prominent,
                  let origin = activeRouteOrigin,
                  let destination = nextStop,
                  let destinationLatitude = destination.latitude,
                  let destinationLongitude = destination.longitude,
                  destination.transportTypeRaw?.isEmpty == false else {
                activeRoute = nil
                return
            }
            let routes = await TencentTripDirections.routes(
                from: origin.coordinate,
                to: CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude),
                transportTypeRaw: destination.transportTypeRaw
            )
            let preferredIndex = TripRouteOptionSelectionStore.selectedIndex(
                for: destination.id,
                optionCount: routes.count
            )
            activeRoute = routes.indices.contains(preferredIndex) ? routes[preferredIndex] : nil
        }
    }

    private var activeRouteText: String {
        guard let nextStop else { return "查看地图与行程安排" }
        if let route = activeRoute {
            return tripRouteSummaryText(route, transportTypeRaw: nextStop.transportTypeRaw)
        }
        if let activeRouteOrigin {
            return tripPlanTransportSummary(destination: nextStop, origin: activeRouteOrigin)
        }
        return nextStop.address?.nilIfEmpty ?? nextStop.notes.nilIfEmpty ?? "查看地图与行程安排"
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

    private var tripDayCount: Int {
        allDays.filter { $0.tripID == trip.id }.count
    }

    private var arrangedDayCount: Int {
        let arrangedIDs = Set(tripItems.map(\.tripDayID))
        return allDays.filter { $0.tripID == trip.id && arrangedIDs.contains($0.id) }.count
    }

    private var plannedStatusText: String {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: trip.plannedStartDay)
        let offset = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        if offset > 0 { return "还有\(offset)天" }
        if offset == 0 { return "今天出发" }
        return "尚未开始"
    }
}

private struct TripListCardHero: View {
    let layoutSeed: String
    let items: [TripItem]
    let cities: [TripDayCity]
    let homeCity: HomeCity?
    let usesPlannedStopMarkers: Bool
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
        return "\(itemPart)#\(cityPart)#\(dayPart)#\(homePart)#plannedMarkers=\(usesPlannedStopMarkers)"
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
                var stopNumber = 0
                itemStops = items.compactMap { item in
                    guard item.kindRaw == TripItemKind.stop.rawValue else { return nil }
                    stopNumber += 1
                    guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                    return TripMapStopCoordinate(
                        cityName: item.cityName,
                        countryCode: item.countryCode,
                        latitude: latitude,
                        longitude: longitude,
                        activityTypeValue: item.activityTypeValue,
                        sequenceNumber: usesPlannedStopMarkers ? stopNumber : nil
                    )
                }
            } else {
                footprintIDs = actualSnapshots.compactMap(\.sourceFootprintID)
                transportIDs = Set(actualSnapshots.compactMap(\.sourceTransportRecordID))
                itemStops = actualSnapshots.compactMap { item in
                    guard item.kind == .stop, let latitude = item.latitude, let longitude = item.longitude else { return nil }
                    return TripMapStopCoordinate(cityName: item.cityName, countryCode: item.countryCode, latitude: latitude, longitude: longitude, activityTypeValue: item.activityTypeValue, sequenceNumber: nil)
                }
            }
            let itemCoordinates = itemStops.compactMap { stop -> CLLocationCoordinate2D? in
                let coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return coordinate
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
            // Planned trips must show the actual itinerary extent. Historical
            // cards retain their city-level framing and home-city filtering.
            let stopCoordinates = usesPlannedStopMarkers
                ? itemCoordinates
                : (nonHomeCityCoordinates.isEmpty ? nonHomeItemCoordinates : nonHomeCityCoordinates)
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
                      usesPlannedStopMarkers || !tripCityMatchesHome(cityName: stop.cityName, countryCode: stop.countryCode, homeCity: homeCity) else { return nil }
                let style = usesPlannedStopMarkers ? nil : stop.activityTypeValue.flatMap { styleByValue[$0] }
                return TripCardMapStopMarker(
                    coordinate: coordinate,
                    icon: usesPlannedStopMarkers ? FootprintIconDefaults.map : (style?.icon ?? FootprintIconDefaults.card),
                    tint: usesPlannedStopMarkers ? Color.dfkAccent : (Color(hex: style?.colorHex ?? "") ?? .gray),
                    sequenceNumber: stop.sequenceNumber
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
    let sequenceNumber: Int?
}

private struct TripCardMapStopMarker {
    let coordinate: CLLocationCoordinate2D
    let icon: String
    let tint: Color
    let sequenceNumber: Int?
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
        let key = "trip-record-map-style-wide-left-focus-marker-padding-v3|\(signature)|\(Int(renderSize.width.rounded()))x\(Int(renderSize.height.rounded()))|\(colorScheme)"
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
            let content = Group {
                if let sequenceNumber = marker.sequenceNumber {
                    TripPlanSequenceMarker(
                        number: sequenceNumber,
                        size: ContinuousTimelineLayout.markerSize,
                        isEmphasized: true
                    )
                } else {
                    TimelineFootprintMarker(icon: marker.icon, tint: marker.tint)
                }
            }
            .padding(6)
            .environment(\.colorScheme, colorScheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage.map { (marker.coordinate, $0) }
        }
        let renderedTransportMarkers = transportMarkers.compactMap { marker -> (CLLocationCoordinate2D, UIImage)? in
            let renderer = ImageRenderer(
                content: TimelineTransportMarker(icon: marker.icon)
                    .padding(6)
                    .environment(\.colorScheme, colorScheme)
            )
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

private enum TripCreationPurpose: String, Identifiable {
    case planned
    case historical
    var id: String { rawValue }
}

private struct TripPlanCityStay: Identifiable {
    let id = UUID()
    let city: TripCitySelection
    var arrivalDay: Date
    var departureDay: Date
}

private struct PlanTripCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let onCreated: (Trip) -> Void
    @State private var startDay = Calendar.current.startOfDay(for: Date())
    @State private var dayCount = 1
    @State private var hasPlannedDates = false
    @State private var cityStays: [TripPlanCityStay] = []
    @State private var showingCitySearch = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("什么时候") {
                    Toggle("设置日期", isOn: $hasPlannedDates)
                        .onChange(of: hasPlannedDates) { _, enabled in
                            guard !enabled else { return }
                            for index in cityStays.indices {
                                cityStays[index].arrivalDay = startDay
                                cityStays[index].departureDay = endDay
                            }
                        }
                    if hasPlannedDates {
                        DatePicker("开始日期", selection: $startDay, displayedComponents: .date)
                            .onChange(of: startDay) { oldValue, newValue in
                                shiftPlan(from: oldValue, to: newValue)
                            }
                    }
                    Stepper(value: $dayCount, in: 1...AppConfig.shared.tripMaximumDurationDays) {
                        LabeledContent("行程天数", value: "\(dayCount)天")
                    }
                    .onChange(of: dayCount) { _, _ in
                        if hasPlannedDates {
                            clampCityStays()
                        } else {
                            for index in cityStays.indices {
                                cityStays[index].arrivalDay = startDay
                                cityStays[index].departureDay = endDay
                            }
                        }
                    }
                    if hasPlannedDates {
                        LabeledContent("结束日期", value: endDay.formatted(.dateTime.year().month().day()))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach($cityStays) { $stay in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(stay.city.cityName, systemImage: "building.2")
                                    .font(.headline)
                                Spacer()
                                Button(role: .destructive) {
                                    cityStays.removeAll { $0.id == stay.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            if hasPlannedDates {
                                DatePicker("到达", selection: $stay.arrivalDay, in: startDay...endDay, displayedComponents: .date)
                                DatePicker("离开", selection: $stay.departureDay, in: stay.arrivalDay...endDay, displayedComponents: .date)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button { showingCitySearch = true } label: {
                        Label(cityStays.isEmpty ? "添加目的地" : "继续添加城市", systemImage: "plus.circle")
                    }
                } header: {
                    Text("去哪里")
                } footer: {
                    if hasPlannedDates {
                        Text("选择每座城市的停留日期，同一天可以安排多座城市。")
                    }
                }

                if !cityStays.isEmpty {
                    Section("行程预览") {
                        Text(generatedTitle)
                            .font(.headline)
                        ForEach(Array(planDays.enumerated()), id: \.offset) { index, day in
                            HStack(alignment: .firstTextBaseline) {
                                TripDayTitleBadge(
                                    dayNumber: index + 1,
                                    dateText: hasPlannedDates
                                        ? day.formatted(.dateTime.month().day().weekday(.abbreviated))
                                        : nil
                                )
                                Spacer()
                                Text(cities(on: day).map(\.cityName).joined(separator: " · ").nilIfEmpty ?? "待安排")
                                    .foregroundStyle(cities(on: day).isEmpty ? .tertiary : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("规划一次出行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: save)
                        .disabled(cityStays.isEmpty || isSaving)
                }
            }
        }
        .sheet(isPresented: $showingCitySearch) {
            TripCitySearchView { city in
                cityStays.append(TripPlanCityStay(city: city, arrivalDay: startDay, departureDay: endDay))
                showingCitySearch = false
            }
        }
        .alert("没有创建成功", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var planDays: [Date] { tripDates(from: startDay, through: endDay) }

    private var endDay: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .day, value: dayCount - 1, to: startDay) ?? startDay
    }

    private var generatedTitle: String {
        let orderedCities = cityStays.enumerated().sorted {
            if $0.element.arrivalDay == $1.element.arrivalDay { return $0.offset < $1.offset }
            return $0.element.arrivalDay < $1.element.arrivalDay
        }.map { $0.element.city.cityName }
        return tripAutomaticTitle(
            cityNames: orderedCities,
            dayCount: planDays.count
        )
    }

    private func cities(on day: Date) -> [TripCitySelection] {
        let calendar = Calendar.autoupdatingCurrent
        let value = calendar.startOfDay(for: day)
        var seen = Set<String>()
        return cityStays.filter {
            value >= calendar.startOfDay(for: $0.arrivalDay)
                && value <= calendar.startOfDay(for: $0.departureDay)
        }.compactMap { stay in
            seen.insert(stay.city.key).inserted ? stay.city : nil
        }
    }

    private func shiftPlan(from oldValue: Date, to newValue: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let oldStart = calendar.startOfDay(for: oldValue)
        let newStart = calendar.startOfDay(for: newValue)
        let offset = calendar.dateComponents([.day], from: oldStart, to: newStart).day ?? 0
        guard offset != 0 else { return }
        for index in cityStays.indices {
            cityStays[index].arrivalDay = calendar.date(byAdding: .day, value: offset, to: cityStays[index].arrivalDay) ?? newStart
            cityStays[index].departureDay = calendar.date(byAdding: .day, value: offset, to: cityStays[index].departureDay) ?? endDay
        }
    }

    private func clampCityStays() {
        for index in cityStays.indices {
            cityStays[index].arrivalDay = min(max(cityStays[index].arrivalDay, startDay), endDay)
            cityStays[index].departureDay = min(max(cityStays[index].departureDay, cityStays[index].arrivalDay), endDay)
        }
    }

    private func save() {
        guard !cityStays.isEmpty else { return }
        isSaving = true
        let trip = Trip(
            title: generatedTitle,
            kind: .planned,
            state: .planned,
            plannedStartDay: Calendar.autoupdatingCurrent.startOfDay(for: startDay),
            plannedEndDay: Calendar.autoupdatingCurrent.startOfDay(for: endDay)
        )
        trip.titleUserEdited = false
        trip.datesUserEdited = hasPlannedDates
        trip.citiesUserEdited = true
        context.insert(trip)
        var insertedDays: [TripDay] = []
        var insertedCities: [TripDayCity] = []
        for (dayIndex, dayDate) in planDays.enumerated() {
            let dayCities = cities(on: dayDate)
            let timeZone = dayCities.first?.timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier
            let day = TripDay(tripID: trip.id, day: dayDate, timeZoneIdentifier: timeZone, orderIndex: dayIndex)
            context.insert(day)
            insertedDays.append(day)
            for (cityIndex, city) in dayCities.enumerated() {
                let dayCity = TripDayCity(
                    tripDayID: day.id,
                    countryCode: city.countryCode,
                    countryName: city.countryName,
                    cityName: city.cityName,
                    latitude: city.latitude,
                    longitude: city.longitude,
                    timeZoneIdentifier: city.timeZoneIdentifier,
                    orderIndex: cityIndex,
                    isUserEdited: true
                )
                context.insert(dayCity)
                insertedCities.append(dayCity)
            }
        }
        do {
            try context.save()
            onCreated(trip)
            dismiss()
        } catch {
            insertedCities.forEach(context.delete)
            insertedDays.forEach(context.delete)
            context.delete(trip)
            isSaving = false
            saveError = "计划还没有创建，请稍后再试。"
        }
    }
}

private func tripDates(from start: Date, through end: Date) -> [Date] {
    let calendar = Calendar.autoupdatingCurrent
    let first = calendar.startOfDay(for: start)
    let last = max(first, calendar.startOfDay(for: end))
    var result: [Date] = []
    var cursor = first
    while cursor <= last {
        result.append(cursor)
        cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(1)
    }
    return result
}

private func tripAutomaticTitle(cityNames: [String], dayCount: Int) -> String {
    var seen = Set<String>()
    let names = cityNames.compactMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
        return trimmed.hasSuffix("市") ? String(trimmed.dropLast()) : trimmed
    }
    let destinations = names.count <= 2 ? names.joined() : names.prefix(2).joined() + "等"
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.numberStyle = .spellOut
    let days = formatter.string(from: NSNumber(value: max(1, dayCount))) ?? "\(max(1, dayCount))"
    return "\(destinations)\(days)日行"
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct CreateTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let activityStyles: [TripActivityStyle]
    var forcesHistorical = false
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
                DFKIMETextField(placeholder: "标题", text: $title)
                DFKIMEMultilineTextField(placeholder: "备注", text: $notes)
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
            var importedCityIdentifiers: [String: String] = [:]
            for importedDay in imported {
                for city in importedDay.cities {
                    guard let latitude = city.latitude, let longitude = city.longitude,
                          let identifier = await TripCityIdentityResolver.shared.identifier(
                            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                            cityName: city.cityName,
                            countryCode: city.countryCode
                          ) else { continue }
                    importedCityIdentifiers[tripCityIdentityKey(identifier: nil, countryCode: city.countryCode, cityName: city.cityName)] = identifier
                }
            }
            let today = Calendar.current.startOfDay(for: Date())
            let state: TripState = forcesHistorical ? .historical : (end < today ? .historical : (start <= today ? .active : .planned))
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
                    let legacyKey = tripCityIdentityKey(identifier: nil, countryCode: city.countryCode, cityName: city.cityName)
                    context.insert(TripDayCity(tripDayID: day.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, cityIdentifier: importedCityIdentifiers[legacyKey], latitude: city.latitude, longitude: city.longitude, orderIndex: index, isUserEdited: false))
                }
            }
            let existingTripDays = ((try? context.fetch(FetchDescriptor<TripDay>())) ?? []).filter { $0.tripID == trip.id }
            for dayDate in tripDays {
                let selectedCities = citiesByDay[dayDate] ?? []
                let existingDay = existingTripDays.first { Calendar.current.isDate($0.day, inSameDayAs: dayDate) }
                let day = existingDay ?? TripDay(tripID: trip.id, day: dayDate)
                if existingDay == nil { context.insert(day) }
                let importedCities = imported.first(where: { Calendar.current.isDate($0.day, inSameDayAs: dayDate) })?.cities ?? []
                for (index, city) in selectedCities.enumerated() where !importedCities.contains(where: {
                    tripCitiesMatch(
                        firstIdentifier: importedCityIdentifiers[
                            tripCityIdentityKey(identifier: nil, countryCode: $0.countryCode, cityName: $0.cityName)
                        ],
                        firstCountryCode: $0.countryCode,
                        firstCityName: $0.cityName,
                        secondIdentifier: city.cityIdentifier,
                        secondCountryCode: city.countryCode,
                        secondCityName: city.cityName
                    )
                }) {
                    context.insert(TripDayCity(tripDayID: day.id, countryCode: city.countryCode, countryName: city.countryName, cityName: city.cityName, cityIdentifier: city.cityIdentifier, latitude: city.latitude, longitude: city.longitude, timeZoneIdentifier: city.timeZoneIdentifier, orderIndex: index, isUserEdited: true))
                }
            }
            try? context.save(); dismiss()
        }
    }
}

private struct TripActivityTypePicker: View {
    let styles: [TripActivityStyle]
    @Binding var selection: String?
    var prompt = "选择行程类型"
    var accessibilityName = "行程类型"
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
                Text(selected?.name ?? prompt)
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
        .accessibilityLabel(accessibilityName)
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
    let cityIdentifier: String?
    let countryCode: String
    let countryName: String
    let administrativeArea: String?
    let latitude: Double
    let longitude: Double
    let timeZoneIdentifier: String?

    init(_ home: HomeCity) {
        cityName = home.cityName; countryCode = home.countryCode; countryName = home.countryName
        cityIdentifier = home.cityIdentifier
        administrativeArea = nil
        latitude = home.latitude ?? 0; longitude = home.longitude ?? 0; timeZoneIdentifier = home.timeZoneIdentifier
    }

    init(_ city: ConfiguredTripCity) {
        cityName = city.cityName; countryCode = city.countryCode; countryName = city.countryName
        cityIdentifier = nil
        administrativeArea = city.group
        latitude = city.latitude; longitude = city.longitude; timeZoneIdentifier = city.timeZoneIdentifier
    }

    var displayName: String { countryName.isEmpty ? cityName : "\(cityName)，\(countryName)" }
    var key: String { tripCityIdentityKey(identifier: cityIdentifier, countryCode: countryCode, cityName: cityName) }

    func makeHomeCity() -> HomeCity {
        let home = HomeCity(cityName: cityName, countryCode: countryCode, countryName: countryName, cityIdentifier: cityIdentifier)
        apply(to: home)
        return home
    }

    func apply(to home: HomeCity) {
        home.cityName = cityName; home.countryCode = countryCode; home.countryName = countryName
        home.cityIdentifier = cityIdentifier
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
    @State private var resolvingCityKey: String?
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
        Button {
            Task { await selectResolvedCity(city) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(city.cityName).foregroundStyle(.primary)
                    let subtitle = city.countryCode.uppercased() == "CN"
                        ? city.administrativeArea
                        : city.countryName
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if resolvingCityKey == city.key { ProgressView() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingCityKey != nil)
    }

    @MainActor
    private func selectResolvedCity(_ city: TripCitySelection) async {
        guard resolvingCityKey == nil else { return }
        resolvingCityKey = city.key
        let identifier: String?
        if let cityIdentifier = city.cityIdentifier {
            identifier = cityIdentifier
        } else {
            identifier = await TripCityIdentityResolver.shared.identifier(
                coordinate: CLLocationCoordinate2D(latitude: city.latitude, longitude: city.longitude),
                cityName: city.cityName,
                countryCode: city.countryCode
            )
        }
        resolvingCityKey = nil
        onSelect(city.withIdentifier(identifier))
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
        let resolvedCountryCode = localizedPlacemark?.isoCountryCode ?? fallback?.countryCode ?? initialPlacemark?.isoCountryCode ?? ""
        let cityIdentifier = await TripCityIdentityResolver.shared.identifier(
            coordinate: coordinate,
            cityName: city,
            countryCode: resolvedCountryCode
        )
        return TripCitySelection(
            cityName: city,
            cityIdentifier: cityIdentifier,
            countryCode: resolvedCountryCode,
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
    init(cityName: String, cityIdentifier: String?, countryCode: String, countryName: String, administrativeArea: String?, latitude: Double, longitude: Double, timeZoneIdentifier: String?) {
        self.cityName = cityName; self.countryCode = countryCode; self.countryName = countryName
        self.cityIdentifier = cityIdentifier
        self.administrativeArea = administrativeArea
        self.latitude = latitude; self.longitude = longitude; self.timeZoneIdentifier = timeZoneIdentifier
    }

    func withIdentifier(_ identifier: String?) -> TripCitySelection {
        TripCitySelection(
            cityName: cityName,
            cityIdentifier: identifier,
            countryCode: countryCode,
            countryName: countryName,
            administrativeArea: administrativeArea,
            latitude: latitude,
            longitude: longitude,
            timeZoneIdentifier: timeZoneIdentifier
        )
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

private struct PlannedTripDetailView: View {
    @Environment(\.modelContext) private var context
    @State private var scanManager = TripScanManager.shared
    let trip: Trip
    let onClose: () -> Void
    @Query private var allTrips: [Trip]
    @Query private var allDays: [TripDay]
    @Query private var allCities: [TripDayCity]
    @Query private var allItems: [TripItem]
    @Query private var homeCities: [HomeCity]
    @State private var editorMode: PlannedTripEditorMode?
    @State private var showingStartChoices = false
    @State private var showingEndConfirmation = false
    @State private var showingCancelActiveConfirmation = false
    @State private var activeTripConflict: Trip?
    @State private var routeSelection: TripPlanRouteSelection?
    @State private var placeSelection: TripPlaceDetailSelection?
    @State private var pendingPlanStatusItem: TripItem?
    @State private var requestedArrivalConfirmationItem: TripItem?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showingPlanSheet = false
    @State private var planDetent: PresentationDetent = .medium
    @State private var plannedRoutes: [UUID: TripPlannedRoute] = [:]
    @State private var routePreferenceVersion = 0
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var activityPickerPresentation: ActivityPickerPresentation?
    @State private var mapViewportSize: CGSize = .zero
    @State private var visiblePlanItemIDs = Set<UUID>()
    @State private var visibleCompactPlanItemIDs = Set<UUID>()
    @State private var compactPlanViewportWidth: CGFloat = 0
    @State private var renderedPlanCameraCoordinateKey = ""
    @State private var visiblePlanMapUpdateTask: Task<Void, Never>?
    @State private var latestVisiblePlanItemIDs = Set<UUID>()
    @State private var followsVisiblePlanTimelineContent = false

    private var plannedTimelineDetentHeight: CGFloat { collapsedTimelineDetentHeight + 82 }

    private var days: [TripDay] {
        allDays.filter { $0.tripID == trip.id }.sorted {
            $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day
        }
    }

    private var cityNames: [String] {
        var seen = Set<String>()
        return days.flatMap { cities(for: $0) }.compactMap {
            seen.insert($0.cityName.lowercased()).inserted ? $0.cityName : nil
        }
    }

    private var arrangedDayCount: Int {
        days.filter { !items(for: $0).isEmpty }.count
    }

    var body: some View {
        GeometryReader { detailViewport in
            ZStack(alignment: .bottom) {
                Map(position: $mapPosition) {
                    UserAnnotation()
                    if plannedMapStops.isEmpty {
                        ForEach(days.flatMap { cities(for: $0) }) { city in
                            if let latitude = city.latitude, let longitude = city.longitude {
                                Marker(city.cityName, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                                    .tint(Color.dfkAccent)
                            }
                        }
                    }
                    ForEach(plannedMapStops) { item in
                        if let latitude = item.latitude, let longitude = item.longitude {
                            Annotation(item.placeName ?? item.cityName ?? "地点", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                                Button { placeSelection = TripPlaceDetailSelection(item: item) } label: {
                                    TripPlanSequenceMarker(
                                        number: planSequenceNumber(for: item),
                                        size: ContinuousTimelineLayout.markerSize,
                                        isEmphasized: true,
                                        tint: item.id == nextDestinationID ? .blue : .dfkAccent
                                    )
                                    .scaleEffect(item.id == nextDestinationID ? 1.22 : 1)
                                    .padding(7)
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(plannedMapStops) { destination in
                        if let route = plannedRoutes[destination.id] {
                            MapPolyline(route.polyline)
                                .stroke(
                                    destination.id == nextDestinationID ? Color.blue : Color.dfkAccent.opacity(0.78),
                                    lineWidth: destination.id == nextDestinationID ? 5 : 4
                                )
                        } else if let pair = plannedRoutePair(endingAt: destination) {
                            MapPolyline(coordinates: [pair.0, pair.1])
                                .stroke(
                                    destination.id == nextDestinationID ? Color.blue.opacity(0.8) : Color.dfkAccent.opacity(0.5),
                                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [5, 5])
                                )
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .safeAreaPadding(.top, currentTopSafeAreaInset)
                .ignoresSafeArea()
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                mapViewportSize = proxy.size
                                fitPlannedMap()
                            }
                            .onChange(of: proxy.size) { _, size in
                                mapViewportSize = size
                                fitPlannedMap()
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
            .onChange(of: plannedMapCoordinateKey) { _, _ in fitPlannedMap() }
        }
        .ignoresSafeArea()
        .background {
            TripDetailEdgeDismissGesture(onDismiss: onClose)
        }
        .sheet(isPresented: $showingPlanSheet) {
            plannedTripSheet
                .presentationDetents(
                    [.height(plannedTimelineDetentHeight), .medium, .large],
                    selection: $planDetent
                )
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
        }
        .task {
            migrateLegacyPlannedTransports()
            activityStyles = await TripScanManager.shared.activityStyles()
            showingPlanSheet = true
        }
        .task(id: plannedRouteKey) { await loadPlannedRoutes() }
        .onChange(of: planDetent) { _, _ in
            visiblePlanMapUpdateTask?.cancel()
            if isPlanSheetCollapsed {
                renderedPlanCameraCoordinateKey = ""
                if followsVisiblePlanTimelineContent, !visibleCompactPlanItemIDs.isEmpty {
                    fitPlannedMap(to: visibleCompactPlanItemIDs)
                } else {
                    fitPlannedMap()
                }
            } else if isPlanSheetMedium {
                renderedPlanCameraCoordinateKey = ""
                if followsVisiblePlanTimelineContent, !visiblePlanItemIDs.isEmpty {
                    fitPlannedMap(to: visiblePlanItemIDs)
                } else {
                    fitPlannedMap()
                }
            }
        }
        .onChange(of: visiblePlanItemIDs) { _, itemIDs in
            guard followsVisiblePlanTimelineContent, !itemIDs.isEmpty, isPlanSheetMedium else { return }
            visiblePlanMapUpdateTask?.cancel()
            let targetItemIDs = itemIDs
            visiblePlanMapUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      isPlanSheetMedium,
                      targetItemIDs == latestVisiblePlanItemIDs else { return }
                fitPlannedMap(to: targetItemIDs)
            }
        }
        .onChange(of: visibleCompactPlanItemIDs) { _, itemIDs in
            guard followsVisiblePlanTimelineContent, !itemIDs.isEmpty, isPlanSheetCollapsed else { return }
            visiblePlanMapUpdateTask?.cancel()
            let targetItemIDs = itemIDs
            visiblePlanMapUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, targetItemIDs == visibleCompactPlanItemIDs else { return }
                fitPlannedMap(to: targetItemIDs)
            }
        }
        .onDisappear {
            visiblePlanMapUpdateTask?.cancel()
        }
        .onChange(of: scanManager.requestedTripArrivalStopID) { _, _ in
            presentRequestedArrivalConfirmationIfNeeded()
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

    private var isPlanSheetCollapsed: Bool {
        planDetent == .height(plannedTimelineDetentHeight)
    }

    private var isPlanSheetMedium: Bool {
        planDetent == .medium
    }

    private var plannedSheetSubtitle: String {
        if trip.datesUserEdited {
            let year = Calendar.autoupdatingCurrent.component(.year, from: trip.plannedStartDay)
            return "\(year)年 · 共\(max(1, days.count))天"
        }
        if !cityNames.isEmpty { return cityNames.joined(separator: " · ") }
        return "\(orderedPlanItems.filter { $0.kindRaw == TripItemKind.stop.rawValue }.count)个地点"
    }

    private var showsPlannedLifecycleActions: Bool {
        (trip.state == .planned && !trip.datesUserEdited) || trip.state == .active
    }

    @ViewBuilder
    private var plannedLifecycleActionBar: some View {
        if trip.state == .planned && !trip.datesUserEdited {
            Button { prepareToStart() } label: {
                Text("开始行程")
                    .font(.headline)
                    .padding(.horizontal, 28)
            }
            .dfkPrimaryActionButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(Color.dfkAccent)
        } else if trip.state == .active {
            HStack {
                Button("推迟行程") {
                    showingCancelActiveConfirmation = true
                }
                .tripFloatingActionButtonStyle()
                .tint(.orange)

                Spacer(minLength: 24)

                Button("结束行程", role: .destructive) {
                    showingEndConfirmation = true
                }
                .tripFloatingActionButtonStyle()
                .tint(.red)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var plannedTripSheet: some View {
        NavigationStack {
            Group {
                if isPlanSheetCollapsed {
                    compactPlanTimeline
                } else {
                    ScrollViewReader { proxy in
                        GeometryReader { viewport in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                                    if !trip.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(trip.notes)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                    }

                                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                                        plannedDaySection(day, index: index)
                                    }
                                }
                                .padding(.top, 30)
                                .padding(.horizontal, 16)
                            }
                            .contentMargins(
                                .bottom,
                                showsPlannedLifecycleActions ? 88 : 0,
                                for: .scrollContent
                            )
                            .ignoresSafeArea(.container, edges: .bottom)
                            .tripTimelineHiddenScrollEdges()
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                        followsVisiblePlanTimelineContent = true
                                    }
                            )
                            .background(Color.clear)
                            .coordinateSpace(name: "plannedTripList")
                            .onPreferenceChange(TripTimelineItemFramePreferenceKey.self) { frames in
                                let visibleIDs = significantVisiblePlanItemIDs(
                                    in: frames,
                                    viewportHeight: viewport.size.height
                                )
                                latestVisiblePlanItemIDs = visibleIDs
                                if visibleIDs != visiblePlanItemIDs {
                                    visiblePlanItemIDs = visibleIDs
                                }
                            }
                            // Keep timeline rows below the native title band,
                            // matching the footprint timeline sheet.
                            .clipped()
                        }
                        .task(id: nextDestinationID) {
                            guard trip.state == .active, let nextDestinationID else { return }
                            await Task.yield()
                            withAnimation(.snappy) {
                                proxy.scrollTo(nextDestinationID, anchor: .center)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showsPlannedLifecycleActions && !isPlanSheetCollapsed {
                    plannedLifecycleActionBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                        .offset(y: 6)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showPlannedTripActivityTypePicker) {
                        Image(systemName: plannedTripActivityStyle?.icon ?? FootprintIconDefaults.card)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(
                                plannedTripActivityStyle.flatMap { Color(hex: $0.colorHex) } ?? .secondary
                            )
                    }
                    .accessibilityLabel("修改行程类型")
                    .accessibilityValue(plannedTripActivityStyle?.name ?? "未设置")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(trip.title).font(.headline).lineLimit(1)
                        Text(plannedSheetSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        editorMode = .itinerary
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("编辑行程安排")

                    Button {
                        editorMode = .basic
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("编辑基本信息")
                }
            }
        }
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            DispatchQueue.main.async {
                presentRequestedArrivalConfirmationIfNeeded()
            }
        }
        .sheet(item: $editorMode) { mode in
            IsolatedTripEditorHost(container: context.container, tripID: trip.id, mode: mode)
                .presentationDetents(
                    mode == .itinerary
                        ? [.large]
                        : [.fraction(0.72)]
                )
                .presentationDragIndicator(.visible)
        }
        .popover(item: $activityPickerPresentation) { value in
            StableActivityPickerPopover(
                suggestedItems: value.suggestedItems,
                allItems: value.allItems,
                onSelect: updatePlannedTripActivityType
            )
        }
        .sheet(item: $routeSelection) { selection in
            TripPlanRouteSheet(
                selection: selection,
                onTransportTypeChange: { rawValue in
                    guard let destination = allItems.first(where: { $0.id == selection.id }) else { return }
                    setPlannedTransportType(rawValue.flatMap(TransportType.init(rawValue:)), for: destination)
                },
                onRouteOptionChange: { routePreferenceVersion += 1 }
            )
        }
        .sheet(item: $placeSelection) { selection in
            TripPlaceDetailSheet(selection: selection)
        }
        .confirmationDialog("计划日期与今天不同", isPresented: $showingStartChoices, titleVisibility: .visible) {
            Button("从今天开始并平移日程") { startTrip(shiftingToToday: true) }
            Button("保留原计划日期") { startTrip(shiftingToToday: false) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("原计划从\(trip.plannedStartDay.formatted(.dateTime.month().day()))开始。")
        }
        .confirmationDialog("结束行程？", isPresented: $showingEndConfirmation, titleVisibility: .visible) {
            Button("结束行程", role: .destructive) { endTrip() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("结束后会移到历史行程，计划内容和已有足迹都会保留。")
        }
        .confirmationDialog("推迟行程？", isPresented: $showingCancelActiveConfirmation, titleVisibility: .visible) {
            Button("推迟行程") { cancelActiveTrip() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("推迟后可稍后重新开始，日期和行程安排都会保留。")
        }
        .confirmationDialog(
            "确认已到达？",
            isPresented: Binding(
                get: { requestedArrivalConfirmationItem != nil },
                set: { isPresented in
                    if !isPresented { clearRequestedArrivalConfirmation() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("确认已到达") {
                if let item = requestedArrivalConfirmationItem {
                    setPlanCompletion(item, completed: true)
                }
                clearRequestedArrivalConfirmation()
            }
            Button("取消", role: .cancel) {
                clearRequestedArrivalConfirmation()
            }
        } message: {
            if let item = requestedArrivalConfirmationItem {
                Text("确认已经到达“\(plannedItemTitle(item))”？")
            }
        }
        .alert(
            "已有进行中的行程",
            isPresented: Binding(
                get: { activeTripConflict != nil },
                set: { if !$0 { activeTripConflict = nil } }
            ),
            presenting: activeTripConflict
        ) { _ in
            Button("知道了", role: .cancel) { activeTripConflict = nil }
        } message: { active in
            Text("请先结束“\(active.title)”，再开始这段行程。")
        }
    }

    private var plannedTripActivityStyle: TripActivityStyle? {
        guard let value = trip.activityTypeValue else { return nil }
        return activityStyles.first { $0.id == value || $0.name == value }
    }

    private func showPlannedTripActivityTypePicker() {
        let items = activityStyles.compactMap { style -> StableActivityPickerItem? in
            guard let id = UUID(uuidString: style.id) else { return nil }
            return StableActivityPickerItem(id: id, name: style.name, icon: style.icon)
        }
        activityPickerPresentation = ActivityPickerPresentation(suggestedItems: [], allItems: items)
    }

    private func updatePlannedTripActivityType(_ id: UUID?) {
        trip.activityTypeValue = id?.uuidString
        trip.updatedAt = Date()
        try? context.save()
    }

    @ViewBuilder
    private func plannedDaySection(_ day: TripDay, index: Int) -> some View {
        let dayItems = items(for: day)
        Section {
            if dayItems.isEmpty {
                Text("还没有安排")
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(dayItems) { item in
                    if let origin = plannedRouteOrigin(before: item) {
                        plannedTransportRow(to: item, from: origin)
                            .padding(.leading, 21)
                            .padding(.trailing, 12)
                    }
                    plannedItemRow(item, day: day)
                        .id(item.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TripTimelineItemFramePreferenceKey.self,
                                    value: [item.id: geometry.frame(in: .named("plannedTripList"))]
                                )
                            }
                        }
                }
            }

        } header: {
            TripDayTitleBadge(
                dayNumber: index + 1,
                dateText: trip.datesUserEdited
                    ? day.day.formatted(.dateTime.month().day().weekday(.abbreviated))
                    : nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .textCase(nil)
            .padding(.horizontal, 4)
        }
    }

    private func plannedItemRow(_ item: TripItem, day: TripDay) -> some View {
        let isCompleted = item.planStatusRaw == "completed"
        let isNext = item.id == nextDestinationID
        let tint = isNext ? Color.blue : Color.dfkAccent
        return HStack(spacing: 12) {
            if trip.state == .active {
                Button {
                    pendingPlanStatusItem = item
                } label: {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(isCompleted ? Color.green : (isNext ? Color.blue : Color.secondary))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? "标记为未到达" : "标记为已到达")
            } else {
                ZStack {
                    Circle()
                        .fill(tint.opacity(isNext ? 1 : 0.14))
                    Text("\(planSequenceNumber(for: item))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(isNext ? Color.white : tint)
                }
                .frame(width: 40, height: 40)
            }

            Button {
                placeSelection = TripPlaceDetailSelection(item: item)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plannedItemTitle(item))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCompleted ? .secondary : .primary)
                            .strikethrough(isCompleted)
                        if let location = plannedItemAddress(item) {
                            Text(location)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let time = item.startTime,
                           time != Calendar.current.startOfDay(for: day.day) {
                            Text("到达 \(time.formatted(.dateTime.hour().minute()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(item.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 76)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    if isNext {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.blue.opacity(0.7), lineWidth: 1.25)
                            }
                    }
                }
                .shadow(color: .black.opacity(isNext ? 0.12 : 0), radius: 8, y: 3)
        }
        .confirmationDialog(
            isCompleted ? "取消已到达状态？" : "确认已到达？",
            isPresented: Binding(
                get: { pendingPlanStatusItem?.id == item.id },
                set: { isPresented in
                    if !isPresented, pendingPlanStatusItem?.id == item.id {
                        pendingPlanStatusItem = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(isCompleted ? "取消已到达" : "确认已到达") {
                setPlanCompletion(item, completed: !isCompleted)
                pendingPlanStatusItem = nil
            }
            Button("取消", role: .cancel) {
                pendingPlanStatusItem = nil
            }
        } message: {
            Text(isCompleted
                 ? "将把“\(plannedItemTitle(item))”恢复为未到达。"
                 : "确认已经到达“\(plannedItemTitle(item))”？")
        }
    }

    private func setPlanCompletion(_ item: TripItem, completed: Bool) {
        item.planStatusRaw = completed ? "completed" : "planned"
        trip.updatedAt = Date()
        try? context.save()
        TripScanManager.shared.refreshActiveTripProgress()
    }

    private func presentRequestedArrivalConfirmationIfNeeded() {
        guard let stopID = scanManager.requestedTripArrivalStopID else { return }
        let tripDayIDs = Set(days.map(\.id))
        guard let item = allItems.first(where: {
            $0.id == stopID && tripDayIDs.contains($0.tripDayID) && $0.planStatusRaw != "completed"
        }) else {
            scanManager.consumeRequestedTripArrivalStopID()
            return
        }
        requestedArrivalConfirmationItem = item
    }

    private func clearRequestedArrivalConfirmation() {
        requestedArrivalConfirmationItem = nil
        scanManager.consumeRequestedTripArrivalStopID()
    }

    private func plannedTransportRow(to destination: TripItem, from origin: TripPlanOrigin) -> some View {
        let hasTransport = destination.transportTypeRaw?.isEmpty == false
        let icon = TransportType(rawValue: destination.transportTypeRaw ?? "")?.icon ?? "arrow.triangle.swap"
        return Button {
            routeSelection = makeRouteSelection(for: destination)
        } label: {
            HStack(spacing: 10) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(ContinuousTimelineLayout.lineColor)
                        .frame(width: 2, height: 8)
                    TimelineTransportMarker(icon: hasTransport ? icon : "plus")
                        .frame(width: 30, height: 26)
                    Rectangle()
                        .fill(ContinuousTimelineLayout.lineColor)
                        .frame(width: 2, height: 8)
                }
                Text(hasTransport ? plannedRouteSummary(to: destination, from: origin) : "选择交通方式")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func plannedRouteSummary(to destination: TripItem, from origin: TripPlanOrigin) -> String {
        guard let route = plannedRoutes[destination.id] else {
            return tripPlanTransportSummary(destination: destination, origin: origin)
        }
        let type = TransportType(rawValue: destination.transportTypeRaw ?? "")?.localizedName ?? "交通"
        let distance = route.distance < 1_000
            ? "\(max(1, Int(route.distance.rounded())))米"
            : String(format: "%.1f公里", route.distance / 1_000)
        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        return "\(type) · \(distance) · 约\(minutes)分钟"
    }

    private func setPlannedTransportType(_ type: TransportType?, for destination: TripItem) {
        destination.transportTypeRaw = type?.rawValue
        destination.lineName = nil
        trip.updatedAt = Date()
        plannedRoutes[destination.id] = nil
        try? context.save()
        scanManager.refreshActiveTripProgress()
    }

    private func cities(for day: TripDay) -> [TripDayCity] {
        allCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var compactPlanTimeline: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(orderedPlanItems.enumerated()), id: \.element.id) { index, item in
                            if let origin = plannedRouteOrigin(before: item) {
                                Button {
                                    routeSelection = makeRouteSelection(for: item)
                                } label: {
                                    TimelineTransportMarker(
                                        icon: item.transportTypeRaw.flatMap(TransportType.init(rawValue:))?.icon ?? "plus"
                                    )
                                        .frame(width: 34, height: 54)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tripPlanTransportSummary(destination: item, origin: origin))
                            }
                            compactPlannedItemCard(item, index: index)
                                .id(item.id)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: TripPlanCompactItemFramePreferenceKey.self,
                                            value: [item.id: geometry.frame(in: .named("compactPlanTimeline"))]
                                        )
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            followsVisiblePlanTimelineContent = true
                        }
                )
                .coordinateSpace(name: "compactPlanTimeline")
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { compactPlanViewportWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in
                                compactPlanViewportWidth = width
                            }
                    }
                }
                .onPreferenceChange(TripPlanCompactItemFramePreferenceKey.self) { frames in
                    let visibleIDs = significantVisibleCompactPlanItemIDs(
                        in: frames,
                        viewportWidth: compactPlanViewportWidth
                    )
                    if visibleIDs != visibleCompactPlanItemIDs {
                        visibleCompactPlanItemIDs = visibleIDs
                    }
                }
            }
            .task(id: nextDestinationID) {
                guard trip.state == .active, let nextDestinationID else { return }
                await Task.yield()
                withAnimation(.snappy) {
                    proxy.scrollTo(nextDestinationID, anchor: .center)
                }
            }
        }
    }

    private func compactPlannedItemCard(_ item: TripItem, index: Int) -> some View {
        let isCompleted = item.planStatusRaw == "completed"
        let isNext = item.id == nextDestinationID
        return HStack(spacing: 8) {
            if trip.state == .active {
                Button {
                    pendingPlanStatusItem = item
                } label: {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(isCompleted ? Color.green : (isNext ? Color.blue : Color.secondary))
                        .frame(width: 38, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? "标记为未到达" : "标记为已到达")
            } else {
                TripPlanSequenceMarker(
                    number: index + 1,
                    size: ContinuousTimelineLayout.markerSize,
                    isEmphasized: true,
                    tint: isNext ? .blue : .dfkAccent
                )
            }

            Button {
                placeSelection = TripPlaceDetailSelection(item: item)
            } label: {
                Text(plannedItemTitle(item))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCompleted ? .secondary : .primary)
                    .strikethrough(isCompleted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(width: 220, height: 62, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    if isNext {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.blue.opacity(0.7), lineWidth: 1.25)
                            }
                    }
                }
                .shadow(color: .black.opacity(isNext ? 0.12 : 0), radius: 8, y: 3)
        }
        .confirmationDialog(
            isCompleted ? "取消已到达状态？" : "确认已到达？",
            isPresented: Binding(
                get: { pendingPlanStatusItem?.id == item.id },
                set: { isPresented in
                    if !isPresented, pendingPlanStatusItem?.id == item.id {
                        pendingPlanStatusItem = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(isCompleted ? "取消已到达" : "确认已到达") {
                setPlanCompletion(item, completed: !isCompleted)
                pendingPlanStatusItem = nil
            }
            Button("取消", role: .cancel) {
                pendingPlanStatusItem = nil
            }
        }
    }

    private func migrateLegacyPlannedTransports() {
        let dayOrder = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = allItems.filter { dayOrder[$0.tripDayID] != nil }.sorted {
            let left = dayOrder[$0.tripDayID] ?? .max
            let right = dayOrder[$1.tripDayID] ?? .max
            return left == right ? $0.orderIndex < $1.orderIndex : left < right
        }
        let legacy = ordered.filter { $0.kindRaw == TripItemKind.transport.rawValue }
        for transport in legacy {
            if let index = ordered.firstIndex(where: { $0.id == transport.id }),
               let destination = ordered.dropFirst(index + 1).first(where: { $0.kindRaw == TripItemKind.stop.rawValue }) {
                destination.transportTypeRaw = transport.transportTypeRaw
                destination.lineName = transport.lineName
            }
            context.delete(transport)
        }
        guard !legacy.isEmpty else { return }
        for day in days {
            items(for: day).enumerated().forEach { $0.element.orderIndex = $0.offset }
        }
        try? context.save()
    }

    private func items(for day: TripDay) -> [TripItem] {
        allItems.filter { $0.tripDayID == day.id && $0.kindRaw == TripItemKind.stop.rawValue }.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var orderedPlanItems: [TripItem] {
        let dayOrder = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.id, $0.offset) })
        return allItems.filter { dayOrder[$0.tripDayID] != nil }.sorted {
            let leftDay = dayOrder[$0.tripDayID] ?? .max
            let rightDay = dayOrder[$1.tripDayID] ?? .max
            return leftDay == rightDay ? $0.orderIndex < $1.orderIndex : leftDay < rightDay
        }
    }

    private var plannedMapStops: [TripItem] {
        orderedPlanItems.filter { item in
            guard let latitude = item.latitude, let longitude = item.longitude else { return false }
            return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }

    private func plannedRoutePair(endingAt destination: TripItem) -> (CLLocationCoordinate2D, CLLocationCoordinate2D)? {
        guard let origin = plannedRouteOrigin(before: destination),
              let destinationLatitude = destination.latitude,
              let destinationLongitude = destination.longitude else { return nil }
        return (
            origin.coordinate,
            CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
        )
    }

    private var plannedMapCoordinateKey: String {
        plannedMapCoordinates.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";")
    }

    private var plannedRouteKey: String {
        plannedMapStops.map {
            "\($0.id)|\($0.latitude ?? 0),\($0.longitude ?? 0)|\($0.transportTypeRaw ?? "")"
        }.joined(separator: ";") + "|\(routePreferenceVersion)"
    }

    private var plannedMapCoordinates: [CLLocationCoordinate2D] {
        let stopCoordinates = plannedMapStops.compactMap { item -> CLLocationCoordinate2D? in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if !stopCoordinates.isEmpty { return stopCoordinates }
        return days.flatMap { cities(for: $0) }.compactMap { city in
            guard let latitude = city.latitude, let longitude = city.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }

    private var plannedCameraRoutes: [TripPlannedRoute] {
        guard let firstStopID = plannedMapStops.first?.id else { return [] }
        return plannedRoutes.compactMap { stopID, route in
            stopID == firstStopID ? nil : route
        }
    }

    private func fitPlannedMap(to itemIDs: Set<UUID> = []) {
        guard isPlanSheetCollapsed || isPlanSheetMedium else { return }
        let coordinates: [CLLocationCoordinate2D]
        if itemIDs.isEmpty {
            coordinates = plannedMapCoordinates + plannedCameraRoutes.flatMap(\.coordinates)
        } else {
            let stopCoordinates = orderedPlanItems.filter { itemIDs.contains($0.id) }.compactMap { item -> CLLocationCoordinate2D? in
                guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            let firstStopID = plannedMapStops.first?.id
            coordinates = stopCoordinates + itemIDs.compactMap { stopID in
                stopID == firstStopID ? nil : plannedRoutes[stopID]
            }.flatMap(\.coordinates)
        }
        let valid = coordinates.filter { CLLocationCoordinate2DIsValid($0) }
        guard !valid.isEmpty, mapViewportSize.width > 1, mapViewportSize.height > 1 else { return }

        let visibleHeight = isPlanSheetCollapsed
            ? max(1, mapViewportSize.height - plannedTimelineDetentHeight)
            : max(1, mapViewportSize.height * 0.5)
        let topChromeHeight = currentTopSafeAreaInset + 60
        let unobscuredTop = min(topChromeHeight, visibleHeight * 0.15)
        let unobscuredHeight = max(1, visibleHeight - unobscuredTop)
        let visibleRect = CGRect(
            x: mapViewportSize.width * 0.08,
            y: unobscuredTop,
            width: mapViewportSize.width * 0.84,
            height: unobscuredHeight * 0.72
        )
        guard let rect = FootprintCameraFraming.mapRect(
            coordinates: valid,
            viewport: mapViewportSize,
            visibleRect: visibleRect
        ) else { return }

        let coordinateKey = valid
            .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .sorted()
            .joined(separator: "|")
            + (isPlanSheetCollapsed ? "#collapsed" : "#medium")
            + String(format: "#%.0fx%.0f", mapViewportSize.width, mapViewportSize.height)
        guard coordinateKey != renderedPlanCameraCoordinateKey else { return }
        renderedPlanCameraCoordinateKey = coordinateKey
        withAnimation(.easeInOut(duration: 0.6)) {
            mapPosition = .rect(rect)
        }
    }

    private func significantVisiblePlanItemIDs(
        in frames: [UUID: CGRect],
        viewportHeight: CGFloat
    ) -> Set<UUID> {
        guard viewportHeight > 0 else { return [] }
        let bandTop: CGFloat = 8
        let bandBottom = max(bandTop, viewportHeight - 8)
        return Set(frames.compactMap { id, frame in
            let visibleHeight = max(0, min(frame.maxY, bandBottom) - max(frame.minY, bandTop))
            let minimumVisibleHeight = min(44, max(16, frame.height * 0.3))
            return visibleHeight >= minimumVisibleHeight ? id : nil
        })
    }

    private func significantVisibleCompactPlanItemIDs(
        in frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) -> Set<UUID> {
        guard viewportWidth > 0 else { return [] }
        let bandLeft: CGFloat = 8
        let bandRight = max(bandLeft, viewportWidth - 8)
        return Set(frames.compactMap { id, frame in
            let visibleWidth = max(0, min(frame.maxX, bandRight) - max(frame.minX, bandLeft))
            let minimumVisibleWidth = min(60, max(24, frame.width * 0.3))
            return visibleWidth >= minimumVisibleWidth ? id : nil
        })
    }

    @MainActor
    private func loadPlannedRoutes() async {
        var loaded: [UUID: TripPlannedRoute] = [:]
        for destination in plannedMapStops {
            guard !Task.isCancelled,
                  destination.transportTypeRaw?.isEmpty == false,
                  let pair = plannedRoutePair(endingAt: destination) else { continue }
            if let route = await requestPlannedRoute(
                from: pair.0,
                to: pair.1,
                transportTypeRaw: destination.transportTypeRaw,
                stopID: destination.id
            ) {
                loaded[destination.id] = route
            }
        }
        guard !Task.isCancelled else { return }
        plannedRoutes = loaded
        if followsVisiblePlanTimelineContent, isPlanSheetCollapsed, !visibleCompactPlanItemIDs.isEmpty {
            fitPlannedMap(to: visibleCompactPlanItemIDs)
        } else if followsVisiblePlanTimelineContent, isPlanSheetMedium, !visiblePlanItemIDs.isEmpty {
            fitPlannedMap(to: visiblePlanItemIDs)
        } else {
            fitPlannedMap()
        }
    }

    private func requestPlannedRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportTypeRaw: String?,
        stopID: UUID
    ) async -> TripPlannedRoute? {
        let routes = await TencentTripDirections.routes(
            from: origin,
            to: destination,
            transportTypeRaw: transportTypeRaw
        )
        guard !routes.isEmpty else { return nil }
        let selectedIndex = TripRouteOptionSelectionStore.selectedIndex(
            for: stopID,
            optionCount: routes.count
        )
        return routes[selectedIndex]
    }

    private var nextDestinationID: UUID? {
        guard trip.state == .active else { return nil }
        return orderedPlanItems.first {
            $0.kindRaw == TripItemKind.stop.rawValue &&
            $0.planStatusRaw == "planned"
        }?.id
    }

    private func makeRouteSelection(for item: TripItem) -> TripPlanRouteSelection {
        return TripPlanRouteSelection(
            item: item,
            origin: plannedRouteOrigin(before: item),
            destination: item,
            transportTypeRaw: plannedRouteOrigin(before: item) == nil ? nil : item.transportTypeRaw,
            route: plannedRoutes[item.id]
        )
    }

    private func plannedRouteOrigin(before item: TripItem) -> TripPlanOrigin? {
        guard let index = orderedPlanItems.firstIndex(where: { $0.id == item.id }) else { return nil }
        if index > 0,
           let latitude = orderedPlanItems[index - 1].latitude,
           let longitude = orderedPlanItems[index - 1].longitude {
            let previous = orderedPlanItems[index - 1]
            return TripPlanOrigin(
                name: previous.placeName ?? previous.address ?? previous.cityName ?? "上一站",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
        guard let home = homeCities.first,
              let latitude = home.latitude,
              let longitude = home.longitude else { return nil }
        return TripPlanOrigin(
            name: home.cityName.isEmpty ? "常居地" : home.cityName,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private func plannedItemTitle(_ item: TripItem) -> String {
        return item.placeName ?? item.address ?? item.cityName ?? "地点"
    }

    private func plannedItemAddress(_ item: TripItem) -> String? {
        let title = plannedItemTitle(item)
        if let address = item.address?.nilIfEmpty, address != title {
            return compactTripAddress(
                address,
                countryName: item.countryName,
                cityName: item.cityName
            )
        }
        if let city = item.cityName?.nilIfEmpty, city != title { return city }
        return nil
    }

    private func planSequenceNumber(for item: TripItem) -> Int {
        (orderedPlanItems.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
    }

    private var countdownText: String {
        if trip.state == .active { return "进行中" }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: trip.plannedStartDay)
        let days = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        if days > 0 { return "还有\(days)天" }
        if days == 0 { return "今天出发" }
        return "尚未开始"
    }

    private func prepareToStart() {
        if let active = allTrips.first(where: { $0.state == .active && $0.id != trip.id }) {
            activeTripConflict = active
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        if !trip.datesUserEdited {
            startTrip(shiftingToToday: true)
        } else if calendar.isDateInToday(trip.plannedStartDay) {
            startTrip(shiftingToToday: false)
        } else {
            showingStartChoices = true
        }
    }

    private func startTrip(shiftingToToday: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        if shiftingToToday {
            let today = calendar.startOfDay(for: Date())
            let originalStart = calendar.startOfDay(for: trip.plannedStartDay)
            let offset = calendar.dateComponents([.day], from: originalStart, to: today).day ?? 0
            trip.plannedStartDay = calendar.date(byAdding: .day, value: offset, to: trip.plannedStartDay) ?? today
            trip.plannedEndDay = calendar.date(byAdding: .day, value: offset, to: trip.plannedEndDay) ?? today
            for day in days {
                day.day = calendar.date(byAdding: .day, value: offset, to: day.day) ?? day.day
                for item in items(for: day) {
                    item.startTime = item.startTime.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) }
                    item.endTime = item.endTime.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) }
                }
            }
            trip.datesUserEdited = true
        }
        trip.state = .active
        trip.actualStartedAt = Date()
        trip.actualEndedAt = nil
        trip.endReasonRaw = nil
        trip.updatedAt = Date()
        try? context.save()
        TripScanManager.shared.refreshActiveTripProgress()
    }

    private func endTrip() {
        trip.state = .historical
        trip.kind = .historical
        trip.actualEndedAt = Date()
        trip.endReasonRaw = TripEndReason.manual.rawValue
        trip.updatedAt = Date()
        try? context.save()
        TripScanManager.shared.endTripProgressActivity(for: trip.id)
    }

    private func cancelActiveTrip() {
        trip.state = .planned
        trip.kind = .planned
        trip.actualStartedAt = nil
        trip.actualEndedAt = Date()
        trip.endReasonRaw = TripEndReason.corrected.rawValue
        trip.updatedAt = Date()
        try? context.save()
        TripScanManager.shared.endTripProgressActivity(for: trip.id)
    }
}

private struct TripPlanCompactItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct TripDayTitleBadge: View {
    let dayNumber: Int
    var dateText: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text("第\(dayNumber)天")
                .font(.headline)
            if let dateText, !dateText.isEmpty {
                Text(dateText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .dfkDetailMaterial(in: Capsule())
            .padding(.vertical, 2)
    }
}

private struct TripPlanSequenceMarker: View {
    let number: Int
    var size: CGFloat = ContinuousTimelineLayout.markerSize
    var isEmphasized = false
    var tint: Color = .dfkAccent

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 2)
            Circle()
                .fill(isEmphasized ? tint : tint.opacity(0.14))
                .padding(2.5)
            Text("\(number)")
                .font(.system(size: max(10, size * 0.42), weight: .bold, design: .rounded))
                .foregroundStyle(isEmphasized ? Color.white : tint)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .padding(4)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("第\(number)站")
    }
}

private struct TripPlanOrigin {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct TripPlannedRoute {
    let polyline: MKPolyline
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let instructions: [TripRouteInstruction]

    var coordinates: [CLLocationCoordinate2D] {
        var result = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&result, range: NSRange(location: 0, length: polyline.pointCount))
        return result
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        expectedTravelTime: TimeInterval,
        instructions: [TripRouteInstruction]
    ) {
        polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.instructions = instructions
    }
}

struct TripRouteCoordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TripRouteInstruction: Codable {
    let title: String
    let detail: String?
    let systemImage: String
    let startName: String?
    let endName: String?
    let latitude: Double?
    let longitude: Double?
    let segmentCoordinates: [TripRouteCoordinate]?

    init(
        title: String,
        detail: String?,
        systemImage: String,
        startName: String? = nil,
        endName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        segmentCoordinates: [TripRouteCoordinate]? = nil
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.startName = startName
        self.endName = endName
        self.latitude = latitude
        self.longitude = longitude
        self.segmentCoordinates = segmentCoordinates
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct CachedTripRoute: Codable {
    struct Coordinate: Codable {
        let latitude: Double
        let longitude: Double
    }

    let coordinates: [Coordinate]
    let distance: Double
    let expectedTravelTime: Double
    let instructions: [TripRouteInstruction]
}

private func tripRouteMetricText(distance: Double?, durationMinutes: Double?) -> String? {
    var parts: [String] = []
    if let distance, distance > 0 {
        parts.append(distance < 1_000
            ? "\(max(1, Int(distance.rounded())))米"
            : String(format: "%.1f公里", distance / 1_000))
    }
    if let durationMinutes, durationMinutes > 0 {
        parts.append("约\(max(1, Int(durationMinutes.rounded())))分钟")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func tripRouteGuidanceText(_ route: TripPlannedRoute) -> String? {
    guard !route.instructions.isEmpty else { return nil }
    return route.instructions.map { instruction in
        guard instruction.title != "步行", let detail = instruction.detail else {
            return instruction.title
        }
        let stations = detail.split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("上车") || $0.hasSuffix("下车") }
        return stations.isEmpty
            ? instruction.title
            : "\(instruction.title)：\(stations.joined(separator: " → "))"
    }.joined(separator: " → ")
}

private func tripRouteSummaryText(_ route: TripPlannedRoute, transportTypeRaw: String?) -> String {
    let type = TransportType(rawValue: transportTypeRaw ?? "")?.localizedName ?? "交通"
    let distance = route.distance < 1_000
        ? "\(max(1, Int(route.distance.rounded())))米"
        : String(format: "%.1f公里", route.distance / 1_000)
    let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
    return "\(type) · \(distance) · 约\(minutes)分钟"
}

/// Resolves a display city's stable administrative identity. Tencent's adcode
/// is authoritative where available; BigDataCloud's GeoNames/Wikidata identity
/// provides the same behavior for cities outside Tencent's administrative set.
actor TripCityIdentityResolver {
    static let shared = TripCityIdentityResolver()

    private var cache: [String: String?] = [:]

    func identifier(
        coordinate: CLLocationCoordinate2D,
        cityName: String,
        countryCode: String
    ) async -> String? {
        let cacheKey = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[cacheKey] { return cached }

        let tencent = await tencentIdentifier(at: coordinate)
        let resolved: String?
        if let tencent {
            resolved = tencent
        } else {
            resolved = await globalIdentifier(at: coordinate, cityName: cityName, countryCode: countryCode)
        }
        cache[cacheKey] = resolved
        return resolved
    }

    private func tencentIdentifier(at coordinate: CLLocationCoordinate2D) async -> String? {
        let key = AppConfig.shared.tencentMapKey
        let secret = AppConfig.shared.tencentMapSecret
        guard !key.isEmpty, !secret.isEmpty else { return nil }
        let path = "/geocoder/v1/"
        let parameters = [
            "get_poi": "0",
            "key": key,
            "location": String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude),
            "output": "json"
        ]
        let sorted = parameters.sorted { $0.key < $1.key }
        let query = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let source = "/ws\(path)?\(query)\(secret)"
        let signature = Insecure.MD5.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://apis.map.qq.com/ws\(path)")
        components?.queryItems = sorted.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "sig", value: signature)]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["status"] as? NSNumber)?.intValue == 0,
              let result = payload["result"] as? [String: Any],
              let adInfo = result["ad_info"] as? [String: Any] else { return nil }
        let nationCode = stringValue(adInfo["nation_code"])
        let cityCode = stringValue(adInfo["city_code"])
        let adcode = normalizedTencentCityCode(
            adcode: stringValue(adInfo["adcode"]),
            cityCode: cityCode,
            nationCode: nationCode
        )
        guard !adcode.isEmpty else { return nil }
        return "tencent:\(nationCode.lowercased()):\(adcode.lowercased())"
    }

    private func globalIdentifier(
        at coordinate: CLLocationCoordinate2D,
        cityName: String,
        countryCode: String
    ) async -> String? {
        var components = URLComponents(string: "https://api.bigdatacloud.net/data/reverse-geocode-client")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "localityLanguage", value: "en")
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let targetNames = [cityName, payload["city"] as? String, payload["locality"] as? String]
            .compactMap { $0 }
            .map { normalizedCityIdentityName($0) }
            .filter { !$0.isEmpty }
        let localityInfo = payload["localityInfo"] as? [String: Any]
        let areas = ((localityInfo?["administrative"] as? [[String: Any]]) ?? [])
            + ((localityInfo?["informative"] as? [[String: Any]]) ?? [])
        let matchingArea = areas.first { area in
            guard let name = area["name"] as? String else { return false }
            let normalized = normalizedCityIdentityName(name)
            return targetNames.contains(normalized)
        }
        guard let area = matchingArea else { return nil }
        if let geonameID = area["geonameId"] as? NSNumber {
            return "geonames:\(geonameID.int64Value)"
        }
        if let geonameID = area["geonameId"] as? String, !geonameID.isEmpty {
            return "geonames:\(geonameID.lowercased())"
        }
        if let wikidataID = area["wikidataId"] as? String, !wikidataID.isEmpty {
            return "wikidata:\(wikidataID.lowercased())"
        }
        if let isoCode = area["isoCode"] as? String, !isoCode.isEmpty {
            return "iso:\(countryCode.lowercased()):\(isoCode.lowercased())"
        }
        return nil
    }

    private func normalizedCityIdentityName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "市", with: "")
            .replacingOccurrences(of: "特别行政区", with: "")
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private func normalizedTencentCityCode(adcode: String, cityCode: String, nationCode: String) -> String {
        if !cityCode.isEmpty { return cityCode }
        guard nationCode == "156", adcode.count == 6 else { return adcode }
        let municipalityPrefixes = ["11", "12", "31", "50"]
        let prefix = municipalityPrefixes.contains(String(adcode.prefix(2)))
            ? String(adcode.prefix(2)) + "0000"
            : String(adcode.prefix(4)) + "00"
        return prefix
    }
}

enum TencentTripDirections {
    private static let baseURL = "https://apis.map.qq.com/ws"
    @MainActor private static var routeCache: [String: [TripPlannedRoute]] = [:]

    @MainActor
    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportTypeRaw: String?
    ) async -> TripPlannedRoute? {
        await routes(from: origin, to: destination, transportTypeRaw: transportTypeRaw).first
    }

    @MainActor
    static func routes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportTypeRaw: String?
    ) async -> [TripPlannedRoute] {
        let transportType = TransportType(rawValue: transportTypeRaw ?? "")
        let mode: String
        switch transportType {
        case .slow, .running:
            mode = "walking"
        case .bicycle:
            mode = "bicycling"
        case .ebike:
            mode = "ebicycling"
        case .bus, .subway, .train:
            mode = "transit"
        case .car, .motorcycle:
            mode = "driving"
        case .airplane, .ship, .none:
            return []
        }

        let cacheKey = [
            "v5",
            mode,
            transportType?.rawValue ?? "none",
            String(format: "%.6f,%.6f", origin.latitude, origin.longitude),
            String(format: "%.6f,%.6f", destination.latitude, destination.longitude)
        ].joined(separator: "|")
        if let cached = routeCache[cacheKey] { return cached }
        let storedRoutes = storedRoutes(for: cacheKey)

        let key = AppConfig.shared.tencentMapKey
        let secret = AppConfig.shared.tencentMapSecret
        guard !key.isEmpty, !secret.isEmpty else { return storedRoutes }

        let path = "/direction/v1/\(mode)/"
        var parameters = [
            "from": String(format: "%.6f,%.6f", origin.latitude, origin.longitude),
            "key": key,
            "output": "json",
            "to": String(format: "%.6f,%.6f", destination.latitude, destination.longitude)
        ]
        if mode == "transit" {
            parameters["policy"] = transportType == .bus
                ? "LEAST_TIME,NO_SUBWAY"
                : "LEAST_TIME"
        } else if mode == "driving" {
            parameters["get_mp"] = "1"
        }
        let sortedParameters = parameters.sorted { $0.key < $1.key }
        let signatureQuery = sortedParameters.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let signatureSource = "/ws\(path)?\(signatureQuery)\(secret)"
        let signature = Insecure.MD5.hash(data: Data(signatureSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var components = URLComponents(string: "\(baseURL)\(path)")
        components?.queryItems = sortedParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "sig", value: signature)]
        guard let url = components?.url else { return storedRoutes }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return storedRoutes
            }
            guard (payload["status"] as? NSNumber)?.intValue == 0 else {
                let status = (payload["status"] as? NSNumber)?.intValue ?? -1
                let message = payload["message"] as? String ?? "Unknown"
                print("Tencent route request failed: status=\(status), message=\(message), mode=\(mode)")
                return storedRoutes
            }
            guard
                  let result = payload["result"] as? [String: Any],
                  let responseRoutes = result["routes"] as? [[String: Any]] else { return storedRoutes }

            let plannedRoutes = responseRoutes.compactMap { responseRoute -> TripPlannedRoute? in
                let coordinates = routeCoordinates(from: responseRoute)
                guard coordinates.count >= 2 else { return nil }
                let distance = (responseRoute["distance"] as? NSNumber)?.doubleValue
                    ?? measuredDistance(of: coordinates)
                let durationMinutes = (responseRoute["duration"] as? NSNumber)?.doubleValue ?? 0
                return TripPlannedRoute(
                    coordinates: coordinates,
                    distance: distance,
                    expectedTravelTime: durationMinutes * 60,
                    instructions: routeInstructions(from: responseRoute)
                )
            }
            guard !plannedRoutes.isEmpty else { return storedRoutes }
            routeCache[cacheKey] = plannedRoutes
            for (index, route) in plannedRoutes.enumerated() {
                store(route, coordinates: route.coordinates, for: "\(cacheKey)|option:\(index)")
            }
            for index in min(plannedRoutes.count, 5)..<5 {
                try? FileManager.default.removeItem(
                    at: persistentCacheURL(for: "\(cacheKey)|option:\(index)")
                )
            }
            return plannedRoutes
        } catch {
            print("Tencent route request failed: \(error.localizedDescription), mode=\(mode)")
            return storedRoutes
        }
    }

    private static func storedRoutes(for cacheKey: String) -> [TripPlannedRoute] {
        let routes = (0..<5).compactMap { storedRoute(for: "\(cacheKey)|option:\($0)") }
        if !routes.isEmpty { return routes }
        return storedRoute(for: cacheKey).map { [$0] } ?? []
    }

    private static func storedRoute(for cacheKey: String) -> TripPlannedRoute? {
        guard let data = try? Data(contentsOf: persistentCacheURL(for: cacheKey)),
              let cached = try? JSONDecoder().decode(CachedTripRoute.self, from: data) else {
            return nil
        }
        let coordinates = cached.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard coordinates.count >= 2 else { return nil }
        return TripPlannedRoute(
            coordinates: coordinates,
            distance: cached.distance,
            expectedTravelTime: cached.expectedTravelTime,
            instructions: cached.instructions
        )
    }

    private static func store(
        _ route: TripPlannedRoute,
        coordinates: [CLLocationCoordinate2D],
        for cacheKey: String
    ) {
        let cached = CachedTripRoute(
            coordinates: coordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            instructions: route.instructions
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = persistentCacheURL(for: cacheKey)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var directory = url.deletingLastPathComponent()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        try? data.write(to: url, options: .atomic)
    }

    private static func persistentCacheURL(for cacheKey: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TripRoutes", isDirectory: true)
        return directory.appendingPathComponent("\(digest).json")
    }

    private static func routeCoordinates(from route: [String: Any]) -> [CLLocationCoordinate2D] {
        if let polyline = route["polyline"] as? [NSNumber] {
            return decodePolyline(polyline)
        }
        guard let steps = route["steps"] as? [[String: Any]] else { return [] }
        return steps.flatMap(coordinates(in:)).reduce(into: []) { result, coordinate in
            if let last = result.last,
               abs(last.latitude - coordinate.latitude) < 0.000001,
               abs(last.longitude - coordinate.longitude) < 0.000001 {
                return
            }
            result.append(coordinate)
        }
    }

    private static func routeInstructions(from route: [String: Any]) -> [TripRouteInstruction] {
        guard let steps = route["steps"] as? [[String: Any]] else { return [] }
        return steps.flatMap { step -> [TripRouteInstruction] in
            let mode = (step["mode"] as? String)?.uppercased()
            if mode == "TRANSIT",
               let line = (step["lines"] as? [[String: Any]])?.first {
                    let lineCoordinates = coordinates(in: line)
                    let coordinate = lineCoordinates.first ?? coordinates(in: step).first
                    let vehicle = (line["vehicle"] as? String)?.uppercased()
                    let icon: String
                    switch vehicle {
                    case "SUBWAY", "METRO", "LIGHT_RAIL", "TRAM":
                        icon = TransportType.subway.icon
                    case "TRAIN", "RAIL", "HIGH_SPEED_RAIL":
                        icon = TransportType.train.icon
                    default:
                        icon = TransportType.bus.icon
                    }
                    var details: [String] = []
                    let startName = ((line["geton"] as? [String: Any])?["title"] as? String)?.nilIfEmpty
                    let endName = ((line["getoff"] as? [String: Any])?["title"] as? String)?.nilIfEmpty
                    if let startName {
                        details.append("\(startName)上车")
                    }
                    if let endName {
                        details.append("\(endName)下车")
                    }
                    if let count = (line["station_count"] as? NSNumber)?.intValue, count > 0 {
                        details.append("\(count)站")
                    }
                    if let metric = tripRouteMetricText(
                        distance: (line["distance"] as? NSNumber)?.doubleValue,
                        durationMinutes: (line["duration"] as? NSNumber)?.doubleValue
                    ) {
                        details.append(metric)
                    }
                    return [TripRouteInstruction(
                        title: (line["title"] as? String)?.nilIfEmpty ?? "公共交通",
                        detail: details.isEmpty ? nil : details.joined(separator: " · "),
                        systemImage: icon,
                        startName: startName,
                        endName: endName,
                        latitude: coordinate?.latitude,
                        longitude: coordinate?.longitude,
                        segmentCoordinates: lineCoordinates.map(TripRouteCoordinate.init)
                    )]
            }

            if mode == "WALKING" {
                let stepCoordinates = coordinates(in: step)
                let coordinate = stepCoordinates.first
                return [TripRouteInstruction(
                    title: "步行",
                    detail: tripRouteMetricText(
                        distance: (step["distance"] as? NSNumber)?.doubleValue,
                        durationMinutes: (step["duration"] as? NSNumber)?.doubleValue
                    ),
                    systemImage: "figure.walk",
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    segmentCoordinates: stepCoordinates.map(TripRouteCoordinate.init)
                )]
            }

            if let instruction = (step["instruction"] as? String)?.nilIfEmpty {
                let stepCoordinates = coordinates(in: step)
                let coordinate = stepCoordinates.first
                return [TripRouteInstruction(
                    title: instruction,
                    detail: tripRouteMetricText(
                        distance: (step["distance"] as? NSNumber)?.doubleValue,
                        durationMinutes: (step["duration"] as? NSNumber)?.doubleValue
                    ),
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    segmentCoordinates: stepCoordinates.map(TripRouteCoordinate.init)
                )]
            }
            return []
        }
    }

    private static func coordinates(in object: [String: Any]) -> [CLLocationCoordinate2D] {
        if let polyline = object["polyline"] as? [NSNumber] {
            return decodePolyline(polyline)
        }
        var result: [CLLocationCoordinate2D] = []
        for key in ["steps", "walking", "routes"] {
            if let children = object[key] as? [[String: Any]] {
                let coordinates = children.flatMap(coordinates(in:))
                appendUnique(coordinates, to: &result)
            } else if let child = object[key] as? [String: Any] {
                let coordinates = coordinates(in: child)
                appendUnique(coordinates, to: &result)
            }
        }
        if let firstLine = (object["lines"] as? [[String: Any]])?.first {
            appendUnique(coordinates(in: firstLine), to: &result)
        } else if let line = object["lines"] as? [String: Any] {
            appendUnique(coordinates(in: line), to: &result)
        }
        return result
    }

    private static func appendUnique(
        _ coordinates: [CLLocationCoordinate2D],
        to result: inout [CLLocationCoordinate2D]
    ) {
        for coordinate in coordinates {
            if let last = result.last,
               abs(last.latitude - coordinate.latitude) < 0.000001,
               abs(last.longitude - coordinate.longitude) < 0.000001 {
                continue
            }
            result.append(coordinate)
        }
    }

    private static func decodePolyline(_ values: [NSNumber]) -> [CLLocationCoordinate2D] {
        guard values.count >= 2 else { return [] }
        var coordinates = values.map(\.doubleValue)
        if coordinates.count > 2 {
            for index in 2..<coordinates.count {
                coordinates[index] = coordinates[index - 2] + coordinates[index] / 1_000_000
            }
        }
        return stride(from: 0, to: coordinates.count - 1, by: 2).compactMap { index in
            let coordinate = CLLocationCoordinate2D(
                latitude: coordinates[index],
                longitude: coordinates[index + 1]
            )
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }

    private static func measuredDistance(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { distance, pair in
            distance + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
}

private struct TripPlaceDetailSelection: Identifiable {
    let id: UUID
    let title: String
    let address: String?
    let notes: String?
    let arrivalTime: Date?
    let coordinate: CLLocationCoordinate2D?

    init(item: TripItem) {
        id = item.id
        title = item.placeName ?? item.address ?? item.cityName ?? "地点"
        address = item.address?.nilIfEmpty.map {
            compactTripAddress($0, countryName: item.countryName, cityName: item.cityName)
        }
        notes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        arrivalTime = item.startTime
        coordinate = item.latitude.flatMap { latitude in
            item.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
        }
    }
}

private struct TripPlaceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: TripPlaceDetailSelection
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var publicInfo: TripPublicPlaceInfo?
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var isLoadingPublicInfo = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            VStack(spacing: 0) {
                Map(position: $cameraPosition) {
                    if let coordinate = selection.coordinate {
                        Marker(selection.title, coordinate: coordinate)
                            .tint(Color.dfkAccent)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .frame(maxWidth: .infinity)
                .frame(height: geometry.size.height * 0.4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(selection.title)
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let coordinate = selection.coordinate {
                            TripNavigationButton(
                                coordinate: coordinate,
                                title: selection.title,
                                transportType: nil
                            )
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("地点信息")
                                .font(.headline)
                            if let address = selection.address, address != selection.title {
                                Label(address, systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(.secondary)
                            }
                            if let arrivalTime = selection.arrivalTime {
                                Label("到达 \(arrivalTime.formatted(.dateTime.hour().minute()))", systemImage: "clock")
                                    .foregroundStyle(.secondary)
                            }
                            if let category = publicInfo?.category {
                                Label(category, systemImage: "tag")
                                    .foregroundStyle(.secondary)
                            }
                            if let phoneNumber = publicInfo?.phoneNumber {
                                if let phoneURL = tripPhoneURL(phoneNumber) {
                                    Link(destination: phoneURL) {
                                        HStack {
                                            Label(phoneNumber, systemImage: "phone")
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .foregroundStyle(Color.dfkAccent)
                                    .accessibilityHint("拨打电话")
                                } else {
                                    Label(phoneNumber, systemImage: "phone")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let website = publicInfo?.website {
                                Link(destination: website) {
                                    HStack {
                                        Label("官方网站", systemImage: "safari")
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .foregroundStyle(Color.dfkAccent)
                            }
                            if let notes = selection.notes {
                                Label(notes, systemImage: "note.text")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        if let lookAroundScene {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("街景")
                                    .font(.headline)
                                LookAroundPreview(
                                    initialScene: lookAroundScene,
                                    allowsNavigation: true,
                                    showsRoadLabels: true
                                )
                                .frame(height: 190)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }

                        if isLoadingPublicInfo {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在获取地点资料…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
            }
            .navigationTitle("地点详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task {
                guard let coordinate = selection.coordinate else { return }
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))
                isLoadingPublicInfo = true
                publicInfo = await TripPublicPlaceInfoService.load(
                    title: selection.title,
                    coordinate: coordinate
                )
                lookAroundScene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
                isLoadingPublicInfo = false
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct TripPublicPlaceInfo: Sendable {
    let category: String?
    let phoneNumber: String?
    let website: URL?
}

private enum TripPublicPlaceInfoService {
    static func load(title: String, coordinate: CLLocationCoordinate2D) async -> TripPublicPlaceInfo? {
        guard let map = await loadMapInfo(title: title, coordinate: coordinate) else { return nil }
        return TripPublicPlaceInfo(
            category: map.category,
            phoneNumber: map.phoneNumber,
            website: map.website
        )
    }

    private static func loadMapInfo(
        title: String,
        coordinate: CLLocationCoordinate2D
    ) async -> (category: String?, phoneNumber: String?, website: URL?)? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = title
        request.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let normalizedTitle = normalizedPlaceSearchKey(title)
        let item = response.mapItems.first {
            guard let name = $0.name else { return false }
            let normalizedName = normalizedPlaceSearchKey(name)
            return normalizedName == normalizedTitle
                || normalizedName.contains(normalizedTitle)
                || normalizedTitle.contains(normalizedName)
        }
        guard let item else { return nil }
        let category = item.pointOfInterestCategory.map(tripLocalizedPOICategory)
        return (category, item.phoneNumber?.nilIfEmpty, item.url)
    }

}

private func tripPhoneURL(_ phoneNumber: String) -> URL? {
    let allowedCharacters = CharacterSet(charactersIn: "+0123456789,;*#")
    let normalized = phoneNumber.unicodeScalars
        .filter { allowedCharacters.contains($0) }
        .map(String.init)
        .joined()
    guard !normalized.isEmpty else { return nil }
    return URL(string: "tel:\(normalized)")
}

private enum TripNavigationApp: String, CaseIterable, Identifiable {
    case appleMaps, amap, baiduMaps, tencentMaps, googleMaps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMaps: return "Apple 地图"
        case .amap: return "高德地图"
        case .baiduMaps: return "百度地图"
        case .tencentMaps: return "腾讯地图"
        case .googleMaps: return "Google 地图"
        }
    }

    var availabilityURL: URL? {
        switch self {
        case .appleMaps: return nil
        case .amap: return URL(string: "iosamap://")
        case .baiduMaps: return URL(string: "baidumap://")
        case .tencentMaps: return URL(string: "qqmap://")
        case .googleMaps: return URL(string: "comgooglemaps://")
        }
    }
}

private struct TripNavigationButton: View {
    let coordinate: CLLocationCoordinate2D
    let title: String
    let transportType: TransportType?
    @State private var isChoosingNavigationApp = false

    private var availableApps: [TripNavigationApp] {
        TripNavigationApp.allCases.filter { app in
            guard let url = app.availabilityURL else { return true }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    var body: some View {
        Button {
            isChoosingNavigationApp = true
        } label: {
            Label("开始导航", systemImage: "location.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Color.dfkAccent)
        .confirmationDialog("选择导航 App", isPresented: $isChoosingNavigationApp, titleVisibility: .visible) {
            ForEach(availableApps) { app in
                Button(app.title) {
                    openTripNavigation(
                        with: app,
                        to: coordinate,
                        title: title,
                        transportType: transportType
                    )
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private func openTripNavigation(
    with app: TripNavigationApp,
    to coordinate: CLLocationCoordinate2D,
    title: String,
    transportType: TransportType?
) {
    let openAppleMaps = {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = title
        let directionsMode: String
        switch transportType {
        case .slow, .running:
            directionsMode = MKLaunchOptionsDirectionsModeWalking
        case .bicycle, .ebike:
            directionsMode = MKLaunchOptionsDirectionsModeCycling
        case .bus, .subway, .train:
            directionsMode = MKLaunchOptionsDirectionsModeTransit
        default:
            directionsMode = MKLaunchOptionsDirectionsModeDriving
        }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode])
    }

    guard app != .appleMaps else {
        openAppleMaps()
        return
    }

    let latitude = String(coordinate.latitude)
    let longitude = String(coordinate.longitude)
    var components = URLComponents()
    switch app {
    case .appleMaps:
        return
    case .amap:
        components.scheme = "iosamap"
        components.host = "path"
        components.queryItems = [
            URLQueryItem(name: "sourceApplication", value: "地方客"),
            URLQueryItem(name: "dlat", value: latitude),
            URLQueryItem(name: "dlon", value: longitude),
            URLQueryItem(name: "dname", value: title),
            URLQueryItem(name: "dev", value: "0"),
            URLQueryItem(name: "t", value: tripAmapNavigationMode(transportType))
        ]
    case .baiduMaps:
        components.scheme = "baidumap"
        components.host = "map"
        components.path = "/direction"
        components.queryItems = [
            URLQueryItem(name: "destination", value: "latlng:\(latitude),\(longitude)|name:\(title)"),
            URLQueryItem(name: "mode", value: tripTextNavigationMode(transportType)),
            URLQueryItem(name: "coord_type", value: "gcj02")
        ]
    case .tencentMaps:
        components.scheme = "qqmap"
        components.host = "map"
        components.path = "/routeplan"
        components.queryItems = [
            URLQueryItem(name: "type", value: tripTencentNavigationMode(transportType)),
            URLQueryItem(name: "to", value: title),
            URLQueryItem(name: "tocoord", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "referer", value: "地方客")
        ]
    case .googleMaps:
        components.scheme = "comgooglemaps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "directionsmode", value: tripGoogleNavigationMode(transportType))
        ]
    }

    guard let url = components.url else {
        openAppleMaps()
        return
    }
    UIApplication.shared.open(url) { opened in
        guard !opened else { return }
        DispatchQueue.main.async(execute: openAppleMaps)
    }
}

private func tripTextNavigationMode(_ transportType: TransportType?) -> String {
    switch transportType {
    case .slow, .running: return "walking"
    case .bicycle, .ebike: return "riding"
    case .bus, .subway, .train: return "transit"
    default: return "driving"
    }
}

private func tripGoogleNavigationMode(_ transportType: TransportType?) -> String {
    switch transportType {
    case .bicycle, .ebike: return "bicycling"
    default: return tripTextNavigationMode(transportType)
    }
}

private func tripTencentNavigationMode(_ transportType: TransportType?) -> String {
    switch transportType {
    case .slow, .running: return "walk"
    case .bicycle, .ebike: return "bike"
    case .bus, .subway, .train: return "bus"
    default: return "drive"
    }
}

private func tripAmapNavigationMode(_ transportType: TransportType?) -> String {
    switch transportType {
    case .bus, .subway, .train: return "1"
    case .slow, .running: return "2"
    case .bicycle, .ebike: return "3"
    default: return "0"
    }
}

private func compactTripAddress(
    _ address: String,
    countryName: String?,
    cityName: String?
) -> String {
    var result = address.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in [countryName, "中华人民共和国", "中国"].compactMap({ $0?.nilIfEmpty }) {
        if result.hasPrefix(prefix) { result.removeFirst(prefix.count) }
    }
    if let cityName = cityName?.nilIfEmpty {
        for prefix in [cityName, cityName.hasSuffix("市") ? nil : "\(cityName)市"].compactMap({ $0 }) {
            if result.hasPrefix(prefix) { result.removeFirst(prefix.count) }
        }
    }
    if let range = result.range(
        of: #"^(?:.{2,8}省|.{2,12}(?:自治区|特别行政区))"#,
        options: .regularExpression
    ) {
        result.removeSubrange(range)
    }
    if let cityName = cityName?.nilIfEmpty {
        for prefix in [cityName, cityName.hasSuffix("市") ? nil : "\(cityName)市"].compactMap({ $0 }) {
            if result.hasPrefix(prefix) { result.removeFirst(prefix.count) }
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? address
}

private func tripLocalizedPOICategory(_ category: MKPointOfInterestCategory) -> String {
    let names: [String: String] = [
        "MKPOICategoryAirport": "机场",
        "MKPOICategoryAmusementPark": "游乐园",
        "MKPOICategoryAnimalService": "宠物服务",
        "MKPOICategoryAquarium": "水族馆",
        "MKPOICategoryATM": "自动取款机",
        "MKPOICategoryAutomotiveRepair": "汽车维修",
        "MKPOICategoryBakery": "烘焙店",
        "MKPOICategoryBank": "银行",
        "MKPOICategoryBaseball": "棒球场",
        "MKPOICategoryBasketball": "篮球场",
        "MKPOICategoryBeach": "海滩",
        "MKPOICategoryBeauty": "美容服务",
        "MKPOICategoryBowling": "保龄球馆",
        "MKPOICategoryBrewery": "啤酒厂",
        "MKPOICategoryCafe": "咖啡馆",
        "MKPOICategoryCampground": "露营地",
        "MKPOICategoryCarRental": "汽车租赁",
        "MKPOICategoryCastle": "城堡",
        "MKPOICategoryConventionCenter": "会展中心",
        "MKPOICategoryDistillery": "酒厂",
        "MKPOICategoryEVCharger": "充电站",
        "MKPOICategoryFairground": "展览场地",
        "MKPOICategoryFireStation": "消防站",
        "MKPOICategoryFishing": "垂钓场所",
        "MKPOICategoryFitnessCenter": "健身中心",
        "MKPOICategoryFoodMarket": "食品市场",
        "MKPOICategoryFortress": "古堡",
        "MKPOICategoryGasStation": "加油站",
        "MKPOICategoryGoKart": "卡丁车场",
        "MKPOICategoryGolf": "高尔夫球场",
        "MKPOICategoryHiking": "徒步地点",
        "MKPOICategoryHospital": "医院",
        "MKPOICategoryHotel": "酒店",
        "MKPOICategoryKayaking": "皮划艇地点",
        "MKPOICategoryLandmark": "地标",
        "MKPOICategoryLaundry": "洗衣服务",
        "MKPOICategoryLibrary": "图书馆",
        "MKPOICategoryMarina": "码头",
        "MKPOICategoryMiniGolf": "迷你高尔夫",
        "MKPOICategoryMovieTheater": "电影院",
        "MKPOICategoryMuseum": "博物馆",
        "MKPOICategoryMusicVenue": "音乐场所",
        "MKPOICategoryNationalMonument": "国家纪念地",
        "MKPOICategoryNationalPark": "国家公园",
        "MKPOICategoryNightlife": "夜生活",
        "MKPOICategoryPark": "公园",
        "MKPOICategoryParking": "停车场",
        "MKPOICategoryPharmacy": "药店",
        "MKPOICategoryPlanetarium": "天文馆",
        "MKPOICategoryPolice": "公安机关",
        "MKPOICategoryPostOffice": "邮局",
        "MKPOICategoryPublicTransport": "公共交通",
        "MKPOICategoryRestaurant": "餐厅",
        "MKPOICategoryRestroom": "洗手间",
        "MKPOICategoryRockClimbing": "攀岩场所",
        "MKPOICategoryRVPark": "房车营地",
        "MKPOICategorySchool": "学校",
        "MKPOICategorySkating": "滑冰场",
        "MKPOICategorySkiing": "滑雪场",
        "MKPOICategorySoccer": "足球场",
        "MKPOICategorySpa": "水疗中心",
        "MKPOICategoryStadium": "体育场",
        "MKPOICategoryStore": "商店",
        "MKPOICategorySurfing": "冲浪地点",
        "MKPOICategorySwimming": "游泳场所",
        "MKPOICategoryTennis": "网球场",
        "MKPOICategoryTheater": "剧院",
        "MKPOICategoryUniversity": "大学",
        "MKPOICategoryVolleyball": "排球场",
        "MKPOICategoryWinery": "酒庄",
        "MKPOICategoryZoo": "动物园"
    ]
    return names[category.rawValue] ?? "其他地点"
}

private struct TripPlanRouteSelection: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let originName: String?
    let origin: CLLocationCoordinate2D?
    let destinationName: String?
    let destination: CLLocationCoordinate2D?
    let transportTypeRaw: String?
    let route: TripPlannedRoute?

    init(
        item: TripItem,
        origin: TripPlanOrigin?,
        destination: TripItem?,
        transportTypeRaw: String?,
        route: TripPlannedRoute?
    ) {
        id = item.id
        title = item.placeName ?? item.address ?? item.cityName ?? "地点"
        if let origin, transportTypeRaw?.isEmpty == false {
            subtitle = tripPlanTransportSummary(destination: item, origin: origin)
        } else {
            subtitle = item.address
        }
        originName = origin?.name
        self.origin = origin?.coordinate
        destinationName = destination?.placeName ?? destination?.address ?? destination?.cityName
        if let latitude = destination?.latitude, let longitude = destination?.longitude {
            self.destination = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            self.destination = nil
        }
        self.transportTypeRaw = transportTypeRaw
        self.route = route
    }
}

private func tripPlanTransportSummary(destination: TripItem, origin: TripItem) -> String {
    guard let latitude = origin.latitude, let longitude = origin.longitude else {
        return TransportType(rawValue: destination.transportTypeRaw ?? "")?.localizedName ?? "前往"
    }
    return tripPlanTransportSummary(
        destination: destination,
        origin: TripPlanOrigin(
            name: origin.placeName ?? origin.address ?? origin.cityName ?? "上一站",
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    )
}

private func tripPlanTransportSummary(destination: TripItem, origin: TripPlanOrigin) -> String {
    let type = TransportType(rawValue: destination.transportTypeRaw ?? "")?.localizedName ?? "前往"
    let distance = tripPlanDirectDistanceText(
        originLatitude: origin.coordinate.latitude,
        originLongitude: origin.coordinate.longitude,
        destinationLatitude: destination.latitude,
        destinationLongitude: destination.longitude
    )
    return [type, distance].compactMap { $0 }.joined(separator: " · ")
}

private func tripPlanDirectDistanceText(
    originLatitude: Double?, originLongitude: Double?,
    destinationLatitude: Double?, destinationLongitude: Double?
) -> String? {
    guard let originLatitude, let originLongitude, let destinationLatitude, let destinationLongitude else { return nil }
    let distance = CLLocation(latitude: originLatitude, longitude: originLongitude)
        .distance(from: CLLocation(latitude: destinationLatitude, longitude: destinationLongitude))
    if distance < 1_000 { return "约\(max(1, Int(distance.rounded())))米" }
    return String(format: "约%.1f公里", distance / 1_000)
}

private struct TripPlanRouteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: TripPlanRouteSelection
    let onTransportTypeChange: (String?) -> Void
    let onRouteOptionChange: () -> Void
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var route: TripPlannedRoute?
    @State private var routeOptions: [TripPlannedRoute]
    @State private var selectedRouteIndex = 0
    @State private var isLoadingRoute = false
    @State private var routeLoadFailed = false
    @State private var selectedTransportTypeRaw: String?
    @State private var selectedInstructionIndex: Int?
    @State private var routeMapHeight: CGFloat?
    @State private var routeMapDragStartHeight: CGFloat?
    @State private var displayedRouteMapCamera: MapCamera?

    init(
        selection: TripPlanRouteSelection,
        onTransportTypeChange: @escaping (String?) -> Void,
        onRouteOptionChange: @escaping () -> Void
    ) {
        self.selection = selection
        self.onTransportTypeChange = onTransportTypeChange
        self.onRouteOptionChange = onRouteOptionChange
        let initialTransportType = TransportType(rawValue: selection.transportTypeRaw ?? "")
        let supportsRoutePlanning = initialTransportType != .airplane && initialTransportType != .ship
        _route = State(initialValue: supportsRoutePlanning ? selection.route : nil)
        _routeOptions = State(initialValue: supportsRoutePlanning ? selection.route.map { [$0] } ?? [] : [])
        _selectedTransportTypeRaw = State(initialValue: selection.transportTypeRaw)
    }

    private var transportType: TransportType? { selectedTransportTypeRaw.flatMap(TransportType.init(rawValue:)) }
    private var supportsRoutePlanning: Bool {
        guard let transportType else { return false }
        return transportType != .airplane && transportType != .ship
    }
    private var showsPublicTransitInstructions: Bool {
        switch transportType {
        case .bus, .subway, .train: return true
        default: return false
        }
    }
    private var supportsExternalNavigation: Bool {
        switch transportType {
        case .slow, .running, .bicycle, .ebike, .motorcycle, .car: return true
        default: return false
        }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            let minimumMapHeight = max(150, geometry.size.height * 0.2)
            let maximumMapHeight = max(minimumMapHeight, geometry.size.height * 0.6)
            let baseMapHeight = routeMapHeight ?? geometry.size.height * (supportsRoutePlanning ? 0.36 : 0.58)
            let resolvedMapHeight = min(maximumMapHeight, max(minimumMapHeight, baseMapHeight))
            VStack(spacing: 0) {
                Map(position: $cameraPosition) {
                    if let origin = effectiveOrigin {
                        Marker("", systemImage: "play.fill", coordinate: origin)
                            .tint(.green)
                    }
                    if let destination = selection.destination {
                        Marker("", systemImage: "stop.fill", coordinate: destination)
                            .tint(.blue)
                    }
                    if !supportsRoutePlanning,
                       let origin = effectiveOrigin,
                       let destination = selection.destination {
                        MapPolyline(coordinates: [origin, destination])
                            .stroke(
                                Color.dfkAccent.opacity(0.7),
                                style: StrokeStyle(
                                    lineWidth: 2,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: [8, 8]
                                )
                            )
                    }
                    if let route {
                        if route.instructions.contains(where: { ($0.segmentCoordinates?.count ?? 0) > 1 }) {
                            ForEach(route.instructions.indices, id: \.self) { index in
                                let coordinates = instructionCoordinates(at: index, in: route)
                                if coordinates.count > 1 {
                                    MapPolyline(coordinates: coordinates)
                                        .stroke(
                                            Color.dfkAccent.opacity(
                                                selectedInstructionIndex == nil || selectedInstructionIndex == index
                                                    ? 0.9
                                                    : 0.62
                                            ),
                                            style: StrokeStyle(
                                                lineWidth: selectedInstructionIndex == index ? 7 : 3,
                                                lineCap: .round,
                                                lineJoin: .round
                                            )
                                        )
                                    if index > route.instructions.startIndex,
                                       let boundary = coordinates.first {
                                        Annotation("", coordinate: boundary) {
                                            Circle()
                                                .fill(Color.dfkAccent)
                                                .frame(width: 8, height: 8)
                                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                        }
                                    }
                                    if selectedInstructionIndex == index,
                                       let start = coordinates.first,
                                       let startName = instructionEndpointName(
                                        instructionIndex: index,
                                        endpointIndex: 0,
                                        in: route
                                       )?.nilIfEmpty {
                                        Annotation("", coordinate: start, anchor: .bottom) {
                                            routeEndpointLabel(startName)
                                        }
                                    }
                                    if selectedInstructionIndex == index,
                                       let end = coordinates.last,
                                       let endName = instructionEndpointName(
                                        instructionIndex: index,
                                        endpointIndex: 1,
                                        in: route
                                       )?.nilIfEmpty {
                                        Annotation("", coordinate: end, anchor: .top) {
                                            routeEndpointLabel(endName)
                                        }
                                    }
                                }
                            }
                        } else {
                            MapPolyline(route.polyline)
                                .stroke(
                                    Color.dfkAccent.opacity(0.72),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                                )
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onMapCameraChange(frequency: .continuous) { context in
                    guard routeMapDragStartHeight == nil else { return }
                    displayedRouteMapCamera = context.camera
                }
                .frame(maxWidth: .infinity)
                .frame(height: resolvedMapHeight)

                routeMapResizeHandle(
                    baseHeight: baseMapHeight,
                    minimumHeight: minimumMapHeight,
                    maximumHeight: maximumMapHeight
                )

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                        Text(selection.title).font(.title2.bold())
                        transportTypeMenu
                        if routeOptions.count > 1 {
                            ScrollViewReader { routeProxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(routeOptions.indices, id: \.self) { index in
                                            Button {
                                                selectRoute(index)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("方案\(index + 1)")
                                                        .font(.subheadline.weight(.semibold))
                                                    Text(routeOptionSummary(routeOptions[index]))
                                                        .font(.caption)
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(index == selectedRouteIndex ? Color.dfkAccent : Color.secondary)
                                            .id("route-option-\(index)")
                                        }
                                    }
                                }
                                .task(id: "\(routeOptions.count)-\(selectedRouteIndex)") {
                                    await Task.yield()
                                    routeProxy.scrollTo("route-option-\(selectedRouteIndex)", anchor: .center)
                                }
                            }
                        }
                        if !supportsRoutePlanning, let transportType {
                            directTransportOverview(transportType)
                        } else if isLoadingRoute {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在规划路线…")
                            }
                            .foregroundStyle(.secondary)
                        } else if let routeSummary {
                            Text(routeSummary).foregroundStyle(.secondary)
                        } else if effectiveOrigin != nil, transportType == nil {
                            Text("请先在行程中选择交通方式")
                                .foregroundStyle(.secondary)
                        } else if routeLoadFailed {
                            HStack {
                                Text("暂时无法获取这段路线")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("重试") {
                                    Task { await loadRoute() }
                                }
                                .buttonStyle(.bordered)
                            }
                        } else if let subtitle = selection.subtitle {
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                        if showsPublicTransitInstructions,
                           let route,
                           route.instructions.contains(where: { $0.title != "步行" }) {
                            VStack(spacing: 0) {
                                ForEach(
                                    route.instructions.indices.filter {
                                        route.instructions[$0].title != "步行"
                                    },
                                    id: \.self
                                ) { index in
                                    let instruction = route.instructions[index]
                                    Button {
                                        selectInstruction(index)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: instruction.systemImage)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(Color.dfkAccent)
                                                .frame(width: 24, height: 24)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(instructionDisplayTitle(at: index, in: route))
                                                    .font(.body.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                if let detail = instruction.detail?.nilIfEmpty {
                                                    Text(detail)
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 10)
                                        .contentShape(Rectangle())
                                        .background(
                                            selectedInstructionIndex == index
                                                ? Color.dfkAccent.opacity(0.12)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .id("route-instruction-\(index)")
                                }
                            }
                        }
                        if supportsExternalNavigation,
                           let destination = selection.destination {
                            TripNavigationButton(
                                coordinate: destination,
                                title: selection.title,
                                transportType: transportType
                            )
                        }
                        }
                        .padding(.top, 14)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .onChange(of: selectedInstructionIndex) { _, index in
                        guard let index else { return }
                        withAnimation(.snappy) {
                            proxy.scrollTo("route-instruction-\(index)", anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial)
            }
            }
            .navigationTitle("路线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: "\(selection.id.uuidString)|\(selectedTransportTypeRaw ?? "none")") { await loadRoute() }
        }
        .presentationDetents([.large])
    }

    private func routeMapResizeHandle(
        baseHeight: CGFloat,
        minimumHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.35))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(.regularMaterial)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        let startHeight = routeMapDragStartHeight ?? baseHeight
                        if routeMapDragStartHeight == nil {
                            routeMapDragStartHeight = startHeight
                            if let displayedRouteMapCamera {
                                cameraPosition = .camera(displayedRouteMapCamera)
                            }
                        }
                        routeMapHeight = min(
                            maximumHeight,
                            max(minimumHeight, startHeight + value.translation.height)
                        )
                    }
                    .onEnded { _ in
                        routeMapDragStartHeight = nil
                        Task { @MainActor in
                            // 等最终高度完成布局后，仅按最终可见区域适配一次。
                            // 拖动期间固定相机，避免同一矩形被逐帧重复适配。
                            await Task.yield()
                            fitCameraToCurrentSelection()
                        }
                    }
            )
            .accessibilityLabel("调整地图高度")
            .accessibilityHint("上下拖动以调整地图和路线列表的高度")
    }

    private var effectiveOrigin: CLLocationCoordinate2D? {
        selection.origin
    }

    private var routeSummary: String? {
        guard let route else { return nil }
        let mode = transportType?.localizedName ?? "前往"
        let distance = route.distance < 1_000
            ? "\(max(1, Int(route.distance.rounded())))米"
            : String(format: "%.1f公里", route.distance / 1_000)
        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        return "\(mode) · \(distance) · 约\(minutes)分钟"
    }

    private var transportTypeMenu: some View {
        Menu {
            Button {
                selectTransportType(nil)
            } label: {
                Label("未设置", systemImage: "minus.circle")
            }
            ForEach(TransportType.allCases, id: \.rawValue) { type in
                Button {
                    selectTransportType(type)
                } label: {
                    Label(type.localizedName, systemImage: type.icon)
                }
            }
        } label: {
            HStack {
                Label(
                    transportType?.localizedName ?? "选择交通方式",
                    systemImage: transportType?.icon ?? "arrow.triangle.swap"
                )
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func directTransportOverview(_ transportType: TransportType) -> some View {
        if let origin = effectiveOrigin,
           let destination = selection.destination {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("出发")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selection.originName ?? "起点")
                            .font(.headline)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: transportType.icon)
                        .foregroundStyle(Color.dfkAccent)
                        .offset(y: 9)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("到达")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selection.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Divider()

                if let distance = tripPlanDirectDistanceText(
                    originLatitude: origin.latitude,
                    originLongitude: origin.longitude,
                    destinationLatitude: destination.latitude,
                    destinationLongitude: destination.longitude
                ) {
                    LabeledContent("直线距离", value: distance)
                }
            }
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            Text("没有可显示的起止位置信息")
                .foregroundStyle(.secondary)
        }
    }

    private func loadRoute() async {
        guard let origin = effectiveOrigin, let destination = selection.destination else {
            fitCamera()
            return
        }
        guard transportType != nil else {
            routeLoadFailed = false
            fitCamera()
            return
        }
        guard supportsRoutePlanning else {
            route = nil
            routeOptions = []
            selectedRouteIndex = 0
            selectedInstructionIndex = nil
            routeLoadFailed = false
            isLoadingRoute = false
            fitCamera()
            return
        }
        isLoadingRoute = true
        routeLoadFailed = false

        let plannedRoutes = await requestRoutes(
            from: origin,
            to: destination,
            transportTypeRaw: selectedTransportTypeRaw
        )
        if !plannedRoutes.isEmpty {
            let preferredIndex = TripRouteOptionSelectionStore.selectedIndex(
                for: selection.id,
                optionCount: plannedRoutes.count
            )
            routeOptions = plannedRoutes
            selectedRouteIndex = preferredIndex
            route = plannedRoutes[preferredIndex]
        } else {
            routeLoadFailed = route == nil
        }
        isLoadingRoute = false
        fitCamera()
    }

    private func selectTransportType(_ type: TransportType?) {
        let rawValue = type?.rawValue
        guard rawValue != selectedTransportTypeRaw else { return }
        selectedTransportTypeRaw = rawValue
        route = nil
        routeOptions = []
        selectedRouteIndex = 0
        routeLoadFailed = false
        selectedInstructionIndex = nil
        TripRouteOptionSelectionStore.clear(for: selection.id)
        onTransportTypeChange(rawValue)
    }

    private func selectInstruction(_ index: Int) {
        selectedInstructionIndex = index
        guard let route else { return }
        let coordinates = instructionCoordinates(at: index, in: route)
        guard coordinates.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .rect(instructionCameraRect(for: coordinates))
        }
    }

    private func selectRoute(_ index: Int) {
        guard routeOptions.indices.contains(index) else { return }
        selectedRouteIndex = index
        route = routeOptions[index]
        selectedInstructionIndex = nil
        TripRouteOptionSelectionStore.setSelectedIndex(index, for: selection.id)
        onRouteOptionChange()
        fitCamera()
    }

    private func routeOptionSummary(_ option: TripPlannedRoute) -> String {
        let distance = option.distance < 1_000
            ? "\(max(1, Int(option.distance.rounded())))米"
            : String(format: "%.1f公里", option.distance / 1_000)
        let minutes = max(1, Int((option.expectedTravelTime / 60).rounded()))
        return "\(distance) · 约\(minutes)分钟"
    }

    private func instructionDisplayTitle(at index: Int, in route: TripPlannedRoute) -> String {
        let instruction = route.instructions[index]
        guard instruction.title == "步行",
              let destination = instructionEndpointName(
                instructionIndex: index,
                endpointIndex: 1,
                in: route
              )?.nilIfEmpty else {
            return instruction.title
        }
        return "步行至\(destination)"
    }

    private func routeEndpointLabel(_ name: String) -> some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.dfkAccent.opacity(0.55), lineWidth: 1))
    }

    private func requestRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportTypeRaw: String?
    ) async -> [TripPlannedRoute] {
        guard supportsRoutePlanning else { return [] }
        return await TencentTripDirections.routes(
            from: origin,
            to: destination,
            transportTypeRaw: transportTypeRaw
        )
    }

    private func fitCamera() {
        if let route {
            cameraPosition = .rect(route.polyline.boundingMapRect.insetBy(dx: -route.polyline.boundingMapRect.width * 0.18, dy: -route.polyline.boundingMapRect.height * 0.18))
            return
        }
        let coordinates = [effectiveOrigin, selection.destination].compactMap { $0 }
        guard let first = coordinates.first else { return }
        let minLatitude = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? first.latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? first.longitude
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.015, (maxLatitude - minLatitude) * 1.4), longitudeDelta: max(0.015, (maxLongitude - minLongitude) * 1.4))
        ))
    }

    private func fitCameraToCurrentSelection() {
        if let selectedInstructionIndex, let route {
            let coordinates = instructionCoordinates(at: selectedInstructionIndex, in: route)
            if coordinates.count > 1 {
                cameraPosition = .rect(instructionCameraRect(for: coordinates))
                return
            }
        }
        fitCamera()
    }

    private func instructionCameraRect(
        for coordinates: [CLLocationCoordinate2D]
    ) -> MKMapRect {
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let rect = polyline.boundingMapRect
        return rect.insetBy(
            dx: -max(4_000, rect.width * 0.65),
            dy: -max(4_000, rect.height * 0.65)
        )
    }

    private func instructionCoordinates(
        at index: Int,
        in route: TripPlannedRoute
    ) -> [CLLocationCoordinate2D] {
        guard route.instructions.indices.contains(index) else { return [] }
        let instruction = route.instructions[index]
        let stored = instruction.segmentCoordinates?.map(\.coordinate)
            .filter(CLLocationCoordinate2DIsValid) ?? []
        if stored.count > 1 { return stored }
        guard let start = instruction.coordinate else { return [] }
        let end = route.instructions.dropFirst(index + 1).compactMap(\.coordinate).first
            ?? route.coordinates.last
        guard let end, CLLocationCoordinate2DIsValid(end) else { return [start] }
        return [start, end]
    }

    private func instructionEndpointName(
        instructionIndex: Int,
        endpointIndex: Int,
        in route: TripPlannedRoute
    ) -> String? {
        guard route.instructions.indices.contains(instructionIndex) else { return nil }
        let instruction = route.instructions[instructionIndex]
        if endpointIndex == 0 {
            return instruction.startName
                ?? route.instructions[..<instructionIndex].reversed().compactMap(\.endName).first
                ?? (instructionIndex == route.instructions.startIndex ? selection.originName : nil)
        }
        return instruction.endName
            ?? route.instructions.dropFirst(instructionIndex + 1).compactMap(\.startName).first
            ?? (instructionIndex == route.instructions.index(before: route.instructions.endIndex)
                ? selection.destinationName ?? selection.title
                : nil)
    }

}

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    let trip: Trip
    var showsLifecycleActions = true
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
            guard detailDetent != .large else { return }
            guard let selectedID, let item = displayedItems.first(where: { $0.id == selectedID }) else { return }
            if let sourceID = item.sourceTransportRecordID, let route = transportRoutes[sourceID] {
                fitCamera(to: route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            } else if let latitude = item.latitude, let longitude = item.longitude {
                fitCamera(to: [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)])
            }
        }
        .onChange(of: detailDetent) { _, _ in
            guard detailDetent != .large else { return }
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
            guard !itemIDs.isEmpty, detailDetent == .medium else { return }
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
                showsLifecycleActions: showsLifecycleActions,
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
        guard detailDetent != .large else { return }
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
        let unobscuredTop = min(topChromeHeight, visibleHeight * 0.15)
        let unobscuredHeight = max(1, visibleHeight - unobscuredTop)
        let visibleRect = CGRect(
            x: mapViewportSize.width * 0.08,
            y: unobscuredTop,
            width: mapViewportSize.width * 0.84,
            height: unobscuredHeight * 0.72
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

    @ViewBuilder
    func tripFloatingActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }

    /// Match the footprint timeline's native sheet rim. A scroll edge effect
    /// here otherwise paints over the top highlight when content is scrolled.
    @ViewBuilder
    func tripTimelineHiddenScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            self
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
    let showsLifecycleActions: Bool
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
    @State private var showingEndConfirmation = false

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
                        .tripTimelineHiddenScrollEdges()
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
            .overlay(alignment: .bottom) {
                if showsLifecycleActions && !isCollapsed {
                    tripLifecycleActionBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
            IsolatedTripEditorHost(container: context.container, tripID: trip.id)
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
        .confirmationDialog("结束行程？", isPresented: $showingEndConfirmation, titleVisibility: .visible) {
            Button("结束行程", role: .destructive) { endTrip() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("结束后会移到历史行程，计划内容和已有足迹都会保留。")
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
        .toolbar(removing: .sidebarToggle)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
        .presentationBackground(.clear)
    }

    private var detailContent: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                if !trip.notes.isEmpty { Text(trip.notes).foregroundStyle(.secondary) }
                ForEach(visibleDayEntries, id: \.element.id) { dayIndex, day in
                    let dayItems = items.filter { $0.tripDayID == day.id }
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
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
                        TripDayTitleBadge(dayNumber: dayIndex + 1, dateText: dayTitle(day))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        }
        .padding(.bottom, showsLifecycleActions ? 64 : 0)
        .task {
            activityStyles = await TripScanManager.shared.activityStyles()
        }
    }

    @ViewBuilder
    private var tripLifecycleActionBar: some View {
        if trip.state == .planned {
            Button { startTrip() } label: {
                Text("开始行程")
                    .font(.headline)
                    .padding(.horizontal, 28)
            }
            .dfkPrimaryActionButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(Color.dfkAccent)
        } else if trip.state == .active {
            Button("结束行程", role: .destructive) {
                showingEndConfirmation = true
            }
            .tripFloatingActionButtonStyle()
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
        TripScanManager.shared.refreshActiveTripProgress()
    }
    private func endTrip() {
        trip.state = .historical; trip.kind = .historical; trip.actualEndedAt = Date(); trip.endReasonRaw = TripEndReason.manual.rawValue; trip.updatedAt = Date(); try? context.save()
        TripScanManager.shared.endTripProgressActivity(for: trip.id)
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
    let cityIdentifier: String?
    let countryCode: String
    let countryName: String
    let timeZoneIdentifier: String?
}

private struct TripPlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlacePickerViewModel()
    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var resolvingID: String?
    @State private var resolutionError: String?
    let preferredCityName: String?
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(resolvingID != nil)
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("搜索地点", systemImage: "magnifyingglass", description: Text("输入名称，选择想去的地点。"))
                } else if search.isSearching && search.searchResults.isEmpty {
                    ProgressView("正在搜索…")
                }
            }
            .navigationTitle("选择地点")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索地点"
            )
            .task {
                await Task.yield()
                isSearchPresented = true
            }
            .onChange(of: query) { _, value in search.search(query: searchQuery(for: value), userCoord: nil) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("无法添加这个地点", isPresented: Binding(
                get: { resolutionError != nil },
                set: { if !$0 { resolutionError = nil } }
            )) {
                Button("知道了", role: .cancel) { resolutionError = nil }
            } message: {
                Text(resolutionError ?? "")
            }
        }
    }

    private func searchQuery(for value: String) -> String {
        let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              let city = preferredCityName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty else { return keyword }
        let cityStem = city.hasSuffix("市") ? String(city.dropLast()) : city
        guard !keyword.hasPrefix(city), !keyword.hasPrefix(cityStem) else { return keyword }
        return "\(city) \(keyword)"
    }

    private func resolve(_ result: PlaceSearchResult) {
        resolvingID = result.id
        Task {
            let location = CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let city = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
            guard let city, !city.isEmpty else {
                resolvingID = nil
                resolutionError = "暂时无法确定这个地点所在的城市，请稍后重试或选择其他结果。"
                return
            }
            let countryCode = placemark?.isoCountryCode ?? ""
            let cityIdentifier = await TripCityIdentityResolver.shared.identifier(
                coordinate: result.coordinate,
                cityName: city,
                countryCode: countryCode
            )
            onSelect(TripPlaceSelection(
                name: result.name, address: result.address,
                latitude: result.coordinate.latitude, longitude: result.coordinate.longitude,
                cityName: city, cityIdentifier: cityIdentifier, countryCode: countryCode,
                countryName: placemark?.country ?? "", timeZoneIdentifier: placemark?.timeZone?.identifier
            ))
            dismiss()
        }
    }
}

private struct TripPlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let day: TripDay
    let item: TripItem?
    let preferredCityName: String?
    let onSave: (TripPlaceSelection?, Date?, String) -> Void
    @State private var selection: TripPlaceSelection?
    @State private var notes: String
    @State private var hasArrivalTime: Bool
    @State private var arrivalTime: Date
    @State private var showingPlaceSearch = false

    init(
        day: TripDay,
        item: TripItem?,
        isPlanned: Bool,
        preferredCityName: String?,
        onSave: @escaping (TripPlaceSelection?, Date?, String) -> Void
    ) {
        self.day = day
        self.item = item
        self.preferredCityName = preferredCityName
        self.onSave = onSave
        _selection = State(initialValue: nil)
        _notes = State(initialValue: item?.notes ?? "")
        let storedTime = item?.startTime
        let isLegacyMidnight = isPlanned && storedTime.map { $0 == Calendar.current.startOfDay(for: day.day) } == true
        _hasArrivalTime = State(initialValue: storedTime != nil && !isLegacyMidnight)
        let defaultTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day.day) ?? day.day
        _arrivalTime = State(initialValue: isLegacyMidnight ? defaultTime : (storedTime ?? defaultTime))
    }

    private var placeName: String? {
        selection?.name ?? item?.placeName ?? item?.address
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("地点") {
                    Button {
                        showingPlaceSearch = true
                    } label: {
                        HStack {
                            Text(placeName ?? "选择地点")
                                .foregroundStyle(placeName == nil ? Color.dfkAccent : Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Toggle("到达时间", isOn: $hasArrivalTime)
                    if hasArrivalTime {
                        DatePicker("时间", selection: $arrivalTime, displayedComponents: .hourAndMinute)
                    }
                }

                Section("备注") {
                    DFKIMEMultilineTextField(placeholder: "备注", text: $notes, minHeight: 72)
                }
            }
            .navigationTitle(item == nil ? "添加地点" : "编辑地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "添加" : "保存") {
                        onSave(selection, hasArrivalTime ? arrivalTime : nil, notes)
                        dismiss()
                    }
                    .disabled(placeName == nil)
                }
            }
            .sheet(isPresented: $showingPlaceSearch) {
                TripPlaceSearchView(preferredCityName: selection?.cityName ?? preferredCityName) { selectedPlace in
                    selection = selectedPlace
                    showingPlaceSearch = false
                }
            }
        }
    }
}

private enum PlannedTripEditorMode: String, Identifiable {
    case basic
    case itinerary

    var id: String { rawValue }
}

private struct TripEditorPresentation: Identifiable {
    let trip: Trip
    let mode: PlannedTripEditorMode?

    var id: UUID { trip.id }
}

private struct IsolatedTripEditorHost: View {
    let tripID: UUID
    let mode: PlannedTripEditorMode?
    @State private var draftContext: ModelContext

    init(container: ModelContainer, tripID: UUID, mode: PlannedTripEditorMode? = nil) {
        self.tripID = tripID
        self.mode = mode
        let context = ModelContext(container)
        context.autosaveEnabled = false
        _draftContext = State(initialValue: context)
    }

    var body: some View {
        IsolatedTripEditorLoader(tripID: tripID, mode: mode)
            .modelContext(draftContext)
    }
}

private struct IsolatedTripEditorLoader: View {
    let tripID: UUID
    let mode: PlannedTripEditorMode?
    @Query private var trips: [Trip]

    var body: some View {
        if let trip = trips.first(where: { $0.id == tripID }) {
            TripEditorView(trip: trip, mode: mode)
        } else {
            ContentUnavailableView("无法打开行程", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct TripEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let trip: Trip
    let mode: PlannedTripEditorMode?
    @Query private var allDays: [TripDay]
    @Query private var allCities: [TripDayCity]
    @Query private var allItems: [TripItem]
    @Query private var homeCities: [HomeCity]
    @State private var title: String
    @State private var notes: String
    @State private var placeTarget: PlaceTarget?
    @State private var addPlaceDay: TripDay?
    @State private var routeSelection: TripPlanRouteSelection?
    @State private var activityStyles: [TripActivityStyle] = []
    @State private var activityTypeValue: String?
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var hasPlannedDates: Bool
    @State private var draggedItemID: UUID?
    @State private var swipingItemID: UUID?
    @State private var itemDragFrames: [UUID: CGRect] = [:]
    @State private var dropTargetDayID: UUID?
    @State private var dropTargetBeforeItemID: UUID?
    @State private var titleWasEdited = false
    @State private var confirmingShorterPlan = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(trip: Trip, mode: PlannedTripEditorMode? = nil) {
        self.trip = trip
        self.mode = mode
        _title = State(initialValue: trip.title)
        _notes = State(initialValue: trip.notes)
        _activityTypeValue = State(initialValue: trip.activityTypeValue)
        _startDay = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedStartDay))
        _endDay = State(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedEndDay))
        _hasPlannedDates = State(initialValue: trip.datesUserEdited)
    }

    private var editorTitle: String {
        switch mode {
        case .basic: return "基本信息"
        case .itinerary: return "行程安排"
        case nil: return editsPlan ? "编辑计划" : "编辑行程"
        }
    }

    private var days: [TripDay] {
        allDays.filter { $0.tripID == trip.id }.sorted { $0.day < $1.day }
    }

    private var editsPlan: Bool {
        trip.state == .planned || trip.state == .active
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if mode != .itinerary {
                        tripInfoCard
                        if !editsPlan {
                            historicalDateSummary
                        } else {
                            plannedDateSummary
                        }
                    }
                    if editsPlan, mode != .basic {
                        ForEach(Array(days.prefix(requestedPlanDayCount).enumerated()), id: \.element.id) { index, day in
                            daySection(
                                for: day,
                                dayNumber: index + 1,
                                displayedDate: hasPlannedDates ? (Calendar.autoupdatingCurrent.date(byAdding: .day, value: index, to: startDay) ?? day.day) : nil
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: attemptSave)
                        .disabled(isSaving)
                }
            }
        }
        .sheet(item: $addPlaceDay) { day in
            TripPlaceSearchView(preferredCityName: preferredCityName(for: day)) { selection in
                save(
                    selection,
                    arrivalTime: nil,
                    notes: "",
                    target: PlaceTarget(day: day, item: nil)
                )
            }
        }
        .sheet(item: $placeTarget) { target in
            TripPlaceEditorView(
                day: target.day,
                item: target.item,
                isPlanned: editsPlan,
                preferredCityName: target.item?.cityName ?? preferredCityName(for: target.day)
            ) { selection, arrivalTime, notes in
                save(selection, arrivalTime: arrivalTime, notes: notes, target: target)
                placeTarget = nil
            }
        }
        .sheet(item: $routeSelection) { selection in
            TripPlanRouteSheet(
                selection: selection,
                onTransportTypeChange: { rawValue in
                    guard let destination = allItems.first(where: { $0.id == selection.id }) else { return }
                    setTransportType(rawValue.flatMap(TransportType.init(rawValue:)), for: destination)
                },
                onRouteOptionChange: {}
            )
        }
        .task {
            await enrichMissingCityIdentifiers()
            migrateLegacyPlannedTransports()
            activityStyles = await TripScanManager.shared.activityStyles()
        }
        .alert("缩短行程？", isPresented: $confirmingShorterPlan) {
            Button("取消", role: .cancel) { }
            Button("缩短并保存", role: .destructive) { save() }
        } message: {
            Text(shortenedPlanMessage)
        }
        .alert("没有保存成功", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var tripInfoCard: some View {
        VStack(spacing: 14) {
            DFKIMETextField(placeholder: "标题", text: $title, textStyle: .headline)
                .onChange(of: title) { _, _ in titleWasEdited = true }
            Divider()
            DFKIMEMultilineTextField(placeholder: "备注", text: $notes, minHeight: 44)
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

    private var plannedDateSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("行程日期", systemImage: "calendar")
                .font(.headline)
            Toggle("设置日期", isOn: $hasPlannedDates)
            if hasPlannedDates {
                DatePicker("开始日期", selection: $startDay, displayedComponents: .date)
                    .onChange(of: startDay) { oldValue, newValue in
                        let calendar = Calendar.autoupdatingCurrent
                        let duration = calendar.dateComponents(
                            [.day],
                            from: calendar.startOfDay(for: oldValue),
                            to: calendar.startOfDay(for: endDay)
                        ).day ?? 0
                        endDay = calendar.date(byAdding: .day, value: max(0, duration), to: calendar.startOfDay(for: newValue)) ?? newValue
                    }
            }
            Stepper(value: planDayCountBinding, in: 1...AppConfig.shared.tripMaximumDurationDays) {
                LabeledContent("行程天数", value: "\(requestedPlanDayCount)天")
            }
            if hasPlannedDates {
                LabeledContent("结束日期", value: endDay.formatted(.dateTime.year().month().day()))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func daySection(for day: TripDay, dayNumber: Int, displayedDate: Date?) -> some View {
        let items = dayItems(for: day)
        let groups = cityGroups(day: day, items: items)
        let stops = items.filter { $0.kindRaw == TripItemKind.stop.rawValue }
        VStack(alignment: .leading, spacing: 12) {
            TripDayTitleBadge(
                dayNumber: dayNumber,
                dateText: displayedDate?.formatted(.dateTime.month().day().weekday(.wide))
            )
            ForEach(groups) { group in
                citySection(group, day: day, items: items)
            }
            if stops.isEmpty {
                Text("还没有安排，先添加一个想去的地点。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if draggedItemID != nil,
               dropTargetDayID == day.id,
               dropTargetBeforeItemID == nil {
                itemDropPlaceholder
                    .onDrop(
                        of: [UTType.text],
                        delegate: TripItemDropDelegate(
                            dayID: day.id,
                            beforeItemID: nil,
                            onTarget: setSystemDropTarget,
                            onDrop: performSystemItemDrop
                        )
                    )
            }
            addPlaceButton(for: day)
                .onDrop(
                    of: [UTType.text],
                    delegate: TripItemDropDelegate(
                        dayID: day.id,
                        beforeItemID: nil,
                        onTarget: setSystemDropTarget,
                        onDrop: performSystemItemDrop
                    )
                )
        }
    }

    @ViewBuilder
    private func citySection(_ group: CityGroup, day: TripDay, items: [TripItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cityHeader(group, day: day)
            ForEach(group.stops) { stop in
                if draggedItemID != nil,
                   dropTargetDayID == day.id,
                   dropTargetBeforeItemID == stop.id,
                   draggedItemID != stop.id {
                    itemDropPlaceholder
                        .onDrop(
                            of: [UTType.text],
                            delegate: TripItemDropDelegate(
                                dayID: day.id,
                                beforeItemID: stop.id,
                                onTarget: setSystemDropTarget,
                                onDrop: performSystemItemDrop
                            )
                        )
                }
                stopContent(stop, group: group, day: day, items: items)
                    .frame(
                        height: isCollapsedDragSource(stop) ? 0 : nil,
                        alignment: .top
                    )
                    .clipped()
                    .onDrop(
                        of: [UTType.text],
                        delegate: TripItemDropDelegate(
                            dayID: day.id,
                            beforeItemID: stop.id,
                            onTarget: setSystemDropTarget,
                            onDrop: performSystemItemDrop
                        )
                    )
            }
        }
        .padding(.bottom, 8)
    }

    private func cityHeader(_ group: CityGroup, day: TripDay) -> some View {
        HStack(spacing: 12) {
            Text(group.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
            if group.stops.isEmpty, let cityID = group.storedCityID {
                Button(role: .destructive) {
                    if let city = allCities.first(where: { $0.id == cityID && $0.tripDayID == day.id }) {
                        context.delete(city)
                        markEdited()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除城市")
            }
        }
        .padding(.top, 14)
    }

    private func addPlaceButton(for day: TripDay) -> some View {
        Button {
            addPlaceDay = day
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.dfkAccent.opacity(0.12), in: Circle())
                Text("添加地点")
                    .font(.headline)
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

    private func preferredCityName(for day: TripDay) -> String? {
        allCities
            .filter { $0.tripDayID == day.id }
            .max(by: { $0.orderIndex < $1.orderIndex })?
            .cityName
    }

    @ViewBuilder
    private func stopContent(_ stop: TripItem, group: CityGroup, day: TripDay, items: [TripItem]) -> some View {
        let isDragging = draggedItemID == stop.id
        ZStack {
            if isDragging {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dfkAccent.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.dfkAccent.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    }
            }

            VStack(spacing: 6) {
                if let origin = incomingOrigin(before: stop) {
                    incomingTransportRow(to: stop, from: origin)
                }
                TripSwipeDeleteContainer(
                    deleteLabel: "删除地点",
                    swipeEnabled: draggedItemID == nil && (swipingItemID == nil || swipingItemID == stop.id),
                    onSwipeStateChanged: { isActive in
                        if isActive {
                            swipingItemID = stop.id
                        } else if swipingItemID == stop.id {
                            swipingItemID = nil
                        }
                    }
                ) {
                    deleteStop(stop, in: items)
                } content: { selectionEnabled in
                    stopCard(
                        stop,
                        day: day,
                        isDragging: isDragging,
                        selectionEnabled: selectionEnabled,
                        onSelect: { placeTarget = PlaceTarget(day: day, item: stop) }
                    )
                }
            }
            .background {
                if isDragging {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .compositingGroup()
            .opacity(isDragging ? 0 : 1)
        }
        .zIndex(isDragging ? 100 : 0)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateItemDragFrame(stop.id, frame: proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        updateItemDragFrame(stop.id, frame: frame)
                    }
            }
        }
    }

    private var itemDropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.dfkAccent.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.dfkAccent.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.2, dash: [7, 5])
                    )
            }
        .frame(height: draggedItemID.flatMap { itemDragFrames[$0]?.height } ?? 80)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func incomingTransportRow(to destination: TripItem, from origin: TripPlanOrigin) -> some View {
        let hasTransport = destination.transportTypeRaw?.isEmpty == false
        let type = TransportType(rawValue: destination.transportTypeRaw ?? "")
        return Button {
            routeSelection = TripPlanRouteSelection(
                item: destination,
                origin: origin,
                destination: destination,
                transportTypeRaw: destination.transportTypeRaw,
                route: nil
            )
        } label: {
            HStack(spacing: 10) {
                TimelineTransportMarker(
                    icon: hasTransport ? (type?.icon ?? "arrow.triangle.swap") : "plus"
                )
                    .frame(width: 24)
                Text(hasTransport ? tripPlanTransportSummary(destination: destination, origin: origin) : "设置交通方式")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
            }
            .contentShape(Rectangle())
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.leading, 28)
    }

    private func setTransportType(_ type: TransportType?, for destination: TripItem) {
        destination.transportTypeRaw = type?.rawValue
        destination.lineName = nil
        markEdited()
    }

    private func stopCard(
        _ stop: TripItem,
        day: TripDay,
        isDragging: Bool,
        selectionEnabled: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                TripPlanSequenceMarker(
                    number: stopSequenceNumber(for: stop),
                    size: 36
                )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(itemTitle(stop)).font(.headline).foregroundStyle(.primary)
                    if let startTime = stop.startTime,
                       !editsPlan || startTime != Calendar.current.startOfDay(for: day.day) {
                        Text(startTime.formatted(.dateTime.hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let address = stop.address, !address.isEmpty, address != stop.placeName {
                        Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !stop.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(stop.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard selectionEnabled else { return }
                onSelect()
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("拖动地点排序")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .overlay {
                    TripReorderDragSource(
                        isEnabled: swipingItemID == nil && (draggedItemID == nil || draggedItemID == stop.id),
                        itemID: stop.id,
                        previewFrame: itemDragFrames[stop.id] ?? .zero,
                        onBegan: { beginSystemItemDrag(stop) },
                        onEnded: finishSystemItemDrag
                    )
                }
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color(uiColor: isDragging ? .systemBackground : .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func dayItems(for day: TripDay) -> [TripItem] {
        allItems
            .filter { $0.tripDayID == day.id && (!editsPlan || $0.kindRaw == TripItemKind.stop.rawValue) }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    private func itemTitle(_ item: TripItem) -> String {
        return item.placeName ?? item.address ?? item.cityName ?? "足迹"
    }

    private func stopSequenceNumber(for stop: TripItem) -> Int {
        let dayOrder = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.id, $0.offset) })
        let orderedStops = allItems
            .filter { $0.kindRaw == TripItemKind.stop.rawValue && dayOrder[$0.tripDayID] != nil }
            .sorted {
                let leftDay = dayOrder[$0.tripDayID] ?? .max
                let rightDay = dayOrder[$1.tripDayID] ?? .max
                return leftDay == rightDay ? $0.orderIndex < $1.orderIndex : leftDay < rightDay
            }
        return (orderedStops.firstIndex(where: { $0.id == stop.id }) ?? 0) + 1
    }

    private func save(
        _ selection: TripPlaceSelection?,
        arrivalTime: Date?,
        notes: String,
        target: PlaceTarget
    ) {
        let previousCityKey = target.item.map {
            tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName)
        }
        let item = target.item ?? TripItem(tripDayID: target.day.id, kind: .stop, orderIndex: allItems.filter { $0.tripDayID == target.day.id }.count)
        if let selection {
            item.placeName = selection.name; item.address = selection.address
            item.latitude = selection.latitude; item.longitude = selection.longitude
            item.countryCode = selection.countryCode; item.countryName = selection.countryName
            item.cityName = selection.cityName; item.cityIdentifier = selection.cityIdentifier
            ensureCity(for: selection, day: target.day)
        }
        item.startTime = arrivalTime
        item.endTime = nil
        item.activityTypeValue = nil
        item.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.item == nil { context.insert(item) }
        if let selection, let previousCityKey,
           previousCityKey != tripCityIdentityKey(identifier: selection.cityIdentifier, countryCode: selection.countryCode, cityName: selection.cityName),
           !allItems.contains(where: {
               $0.tripDayID == target.day.id && $0.id != item.id &&
               tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == previousCityKey
           }),
           let unused = allCities.first(where: {
               $0.tripDayID == target.day.id &&
               tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == previousCityKey
           }) {
            context.delete(unused)
        }
        markEdited()
    }

    private func ensureCity(for place: TripPlaceSelection, day: TripDay) {
        let key = tripCityIdentityKey(identifier: place.cityIdentifier, countryCode: place.countryCode, cityName: place.cityName)
        guard !allCities.contains(where: {
            $0.tripDayID == day.id &&
            tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == key
        }) else { return }
        let city = TripDayCity(tripDayID: day.id, countryCode: place.countryCode, countryName: place.countryName, cityName: place.cityName, cityIdentifier: place.cityIdentifier, latitude: place.latitude, longitude: place.longitude, timeZoneIdentifier: place.timeZoneIdentifier, orderIndex: allCities.filter { $0.tripDayID == day.id }.count)
        context.insert(city)
    }

    @MainActor
    private func enrichMissingCityIdentifiers() async {
        let dayIDs = Set(days.map(\.id))
        var changed = false
        for city in allCities where dayIDs.contains(city.tripDayID) && city.cityIdentifier?.isEmpty != false {
            guard let latitude = city.latitude, let longitude = city.longitude else { continue }
            city.cityIdentifier = await TripCityIdentityResolver.shared.identifier(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                cityName: city.cityName,
                countryCode: city.countryCode
            )
            changed = changed || city.cityIdentifier?.isEmpty == false
        }
        for item in allItems where dayIDs.contains(item.tripDayID) && item.cityIdentifier?.isEmpty != false {
            guard let latitude = item.latitude, let longitude = item.longitude,
                  let cityName = item.cityName, !cityName.isEmpty else { continue }
            item.cityIdentifier = await TripCityIdentityResolver.shared.identifier(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                cityName: cityName,
                countryCode: item.countryCode ?? ""
            )
            changed = changed || item.cityIdentifier?.isEmpty == false
        }
        if changed { try? context.save() }
    }

    private func cityGroups(day: TripDay, items: [TripItem]) -> [CityGroup] {
        let stops = items.filter { $0.kindRaw == TripItemKind.stop.rawValue }
        let storedCities = allCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
        var storedByKey: [String: TripDayCity] = [:]
        for city in storedCities {
            let key = tripCityIdentityKey(identifier: city.cityIdentifier, countryCode: city.countryCode, cityName: city.cityName)
            if storedByKey[key] == nil { storedByKey[key] = city }
        }
        var groups: [CityGroup] = []
        var representedKeys = Set<String>()
        for stop in stops {
            let name = stop.cityName.flatMap { $0.isEmpty ? nil : $0 } ?? "未识别城市"
            let key = tripCityIdentityKey(identifier: stop.cityIdentifier, countryCode: stop.countryCode, cityName: name)
            representedKeys.insert(key)
            if groups.last?.key == key {
                groups[groups.count - 1].stops.append(stop)
            } else {
                groups.append(CityGroup(
                    id: "\(key)#\(groups.count)", key: key, name: name,
                    storedCityID: storedByKey[key]?.id, stops: [stop]
                ))
            }
        }
        var appendedEmptyKeys = Set<String>()
        for city in storedCities {
            let key = tripCityIdentityKey(identifier: city.cityIdentifier, countryCode: city.countryCode, cityName: city.cityName)
            guard !representedKeys.contains(key), appendedEmptyKeys.insert(key).inserted else { continue }
            groups.append(CityGroup(
                id: "\(key)#empty", key: key, name: city.cityName,
                storedCityID: city.id, stops: []
            ))
        }
        return groups
    }

    private func incomingOrigin(before stop: TripItem) -> TripPlanOrigin? {
        let orderedDays = days.sorted { $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day }
        let order = Dictionary(uniqueKeysWithValues: orderedDays.enumerated().map { ($0.element.id, $0.offset) })
        let stops = allItems.filter { $0.kindRaw == TripItemKind.stop.rawValue && order[$0.tripDayID] != nil }.sorted {
            let left = order[$0.tripDayID] ?? .max
            let right = order[$1.tripDayID] ?? .max
            return left == right ? $0.orderIndex < $1.orderIndex : left < right
        }
        guard let index = stops.firstIndex(where: { $0.id == stop.id }) else { return nil }
        if index > 0,
           let latitude = stops[index - 1].latitude,
           let longitude = stops[index - 1].longitude {
            let previous = stops[index - 1]
            return TripPlanOrigin(
                name: previous.placeName ?? previous.address ?? previous.cityName ?? "上一站",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
        guard let home = homeCities.first,
              let latitude = home.latitude,
              let longitude = home.longitude else { return nil }
        return TripPlanOrigin(
            name: home.cityName.isEmpty ? "常居地" : home.cityName,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private func deleteStop(_ stop: TripItem, in items: [TripItem]) {
        context.delete(stop)
        normalize(items.filter { $0.id != stop.id })
        markEdited()
    }

    private func migrateLegacyPlannedTransports() {
        guard editsPlan else { return }
        let orderedDays = days.sorted { $0.day == $1.day ? $0.orderIndex < $1.orderIndex : $0.day < $1.day }
        let order = Dictionary(uniqueKeysWithValues: orderedDays.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = allItems.filter { order[$0.tripDayID] != nil }.sorted {
            let left = order[$0.tripDayID] ?? .max
            let right = order[$1.tripDayID] ?? .max
            return left == right ? $0.orderIndex < $1.orderIndex : left < right
        }
        let legacy = ordered.filter { $0.kindRaw == TripItemKind.transport.rawValue }
        guard !legacy.isEmpty else { return }
        for transport in legacy {
            guard let index = ordered.firstIndex(where: { $0.id == transport.id }),
                  let destination = ordered.dropFirst(index + 1).first(where: { $0.kindRaw == TripItemKind.stop.rawValue }) else {
                context.delete(transport)
                continue
            }
            destination.transportTypeRaw = transport.transportTypeRaw
            destination.lineName = transport.lineName
            context.delete(transport)
        }
        for day in orderedDays { normalize(dayItems(for: day)) }
        try? context.save()
    }

    private func updateItemDragFrame(_ id: UUID, frame: CGRect) {
        guard draggedItemID != id, frame.height > 1 else { return }
        itemDragFrames[id] = frame
    }

    private func isCollapsedDragSource(_ item: TripItem) -> Bool {
        draggedItemID == item.id && (
            dropTargetDayID != item.tripDayID || dropTargetBeforeItemID != item.id
        )
    }

    private func beginSystemItemDrag(_ item: TripItem) -> Bool {
        guard draggedItemID == nil, swipingItemID == nil else { return false }
        draggedItemID = item.id
        dropTargetDayID = item.tripDayID
        dropTargetBeforeItemID = item.id
        return true
    }

    private func setSystemDropTarget(dayID: UUID, beforeItemID: UUID?) {
        guard draggedItemID != nil else { return }
        if dropTargetDayID != dayID || dropTargetBeforeItemID != beforeItemID {
            withAnimation(.snappy(duration: 0.16)) {
                dropTargetDayID = dayID
                dropTargetBeforeItemID = beforeItemID
            }
        }
    }

    private func performSystemItemDrop(dayID: UUID, beforeItemID: UUID?) -> Bool {
        guard let targetDay = days.first(where: { $0.id == dayID }) else {
            finishSystemItemDrag()
            return false
        }
        let changed = performItemDrop(on: targetDay, before: beforeItemID)
        finishSystemItemDrag()
        return changed
    }

    private func finishSystemItemDrag() {
        dropTargetDayID = nil
        dropTargetBeforeItemID = nil
        draggedItemID = nil
    }

    @discardableResult
    private func performItemDrop(on targetDay: TripDay, before targetID: UUID?) -> Bool {
        defer { draggedItemID = nil }
        guard let draggedItemID,
              let draggedItem = allItems.first(where: { $0.id == draggedItemID }) else { return false }

        let sourceDayID = draggedItem.tripDayID
        let sourceItems = allItems.filter { $0.tripDayID == sourceDayID && $0.kindRaw == TripItemKind.stop.rawValue }.sorted { $0.orderIndex < $1.orderIndex }
        guard sourceItems.contains(where: { $0.id == draggedItemID }) else { return false }

        let movingItems = [draggedItem]
        let movingIDs = Set(movingItems.map(\.id))
        if let targetID, movingIDs.contains(targetID) { return true }

        let remainingSource = sourceItems.filter { !movingIDs.contains($0.id) }
        var targetItems = sourceDayID == targetDay.id
            ? remainingSource
            : allItems.filter { $0.tripDayID == targetDay.id && $0.kindRaw == TripItemKind.stop.rawValue }.sorted { $0.orderIndex < $1.orderIndex }

        var insertionIndex = targetID.flatMap { id in targetItems.firstIndex(where: { $0.id == id }) } ?? targetItems.count
        insertionIndex = min(insertionIndex, targetItems.count)
        movingItems.forEach { $0.tripDayID = targetDay.id }
        targetItems.insert(contentsOf: movingItems, at: insertionIndex)

        if sourceDayID != targetDay.id { normalize(remainingSource) }
        normalize(targetItems)
        ensureCity(for: draggedItem, day: targetDay)
        removeUnusedCity(for: draggedItem, fromDayID: sourceDayID, excluding: movingIDs)
        markEdited()
        return true
    }

    private func ensureCity(for item: TripItem, day: TripDay) {
        guard let cityName = item.cityName, !cityName.isEmpty else { return }
        let countryCode = item.countryCode ?? ""
        let key = tripCityIdentityKey(identifier: item.cityIdentifier, countryCode: countryCode, cityName: cityName)
        guard !allCities.contains(where: {
            $0.tripDayID == day.id &&
            tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == key
        }) else { return }
        context.insert(TripDayCity(
            tripDayID: day.id,
            countryCode: countryCode,
            countryName: item.countryName ?? "",
            cityName: cityName,
            cityIdentifier: item.cityIdentifier,
            latitude: item.latitude,
            longitude: item.longitude,
            orderIndex: allCities.filter { $0.tripDayID == day.id }.count
        ))
    }

    private func removeUnusedCity(for item: TripItem, fromDayID dayID: UUID, excluding movedIDs: Set<UUID>) {
        guard dayID != item.tripDayID, let cityName = item.cityName else { return }
        let key = tripCityIdentityKey(identifier: item.cityIdentifier, countryCode: item.countryCode, cityName: cityName)
        let stillUsed = allItems.contains {
            $0.tripDayID == dayID && !movedIDs.contains($0.id) &&
            tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == key
        }
        guard !stillUsed,
              let unused = allCities.first(where: {
                  $0.tripDayID == dayID &&
                  tripCityIdentityKey(identifier: $0.cityIdentifier, countryCode: $0.countryCode, cityName: $0.cityName) == key
              }) else { return }
        context.delete(unused)
    }

    private func normalize(_ items: [TripItem]) { items.enumerated().forEach { $0.element.orderIndex = $0.offset } }

    private func markEdited() {
        trip.citiesUserEdited = true
        trip.updatedAt = Date()
    }

    private var requestedPlanDayCount: Int {
        tripDates(from: startDay, through: endDay).count
    }

    private var planDayCountBinding: Binding<Int> {
        Binding(
            get: { requestedPlanDayCount },
            set: { count in
                let resolvedCount = max(1, count)
                if resolvedCount > days.count {
                    for index in days.count..<resolvedCount {
                        let date = Calendar.autoupdatingCurrent.date(
                            byAdding: .day,
                            value: index,
                            to: Calendar.autoupdatingCurrent.startOfDay(for: trip.plannedStartDay)
                        ) ?? trip.plannedStartDay
                        context.insert(TripDay(tripID: trip.id, day: date, orderIndex: index))
                    }
                }
                endDay = Calendar.autoupdatingCurrent.date(
                    byAdding: .day,
                    value: resolvedCount - 1,
                    to: Calendar.autoupdatingCurrent.startOfDay(for: startDay)
                ) ?? startDay
            }
        )
    }

    private var shortenedPlanMessage: String {
        let removedDays = Array(days.dropFirst(requestedPlanDayCount))
        let removedIDs = Set(removedDays.map(\.id))
        let cityCount = allCities.filter { removedIDs.contains($0.tripDayID) }.count
        let itemCount = allItems.filter { removedIDs.contains($0.tripDayID) }.count
        return "将移除最后\(removedDays.count)天、\(cityCount)座城市安排和\(itemCount)个地点或交通。原始足迹与交通不会改变。"
    }

    private func attemptSave() {
        guard !isSaving else { return }
        if editsPlan, requestedPlanDayCount < days.count {
            confirmingShorterPlan = true
        } else {
            save()
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .itinerary {
            trip.notes = notes
            trip.activityTypeValue = activityTypeValue
            if trimmedTitle.isEmpty {
                trip.titleUserEdited = false
            } else if titleWasEdited, trimmedTitle != trip.title {
                trip.titleUserEdited = true
            }
            trip.title = trimmedTitle.isEmpty ? trip.title : trimmedTitle
        }
        if !editsPlan {
            updateHistoricalDateRange()
        } else {
            let titleDayIDs = Set(days.prefix(requestedPlanDayCount).map(\.id))
            if mode != .itinerary {
                updatePlannedDateRange()
            }
            if !trip.titleUserEdited {
                let orderedCityNames = days.filter { titleDayIDs.contains($0.id) }.flatMap { day in
                    allCities.filter { $0.tripDayID == day.id }.sorted { $0.orderIndex < $1.orderIndex }
                }.map(\.cityName)
                trip.title = tripAutomaticTitle(cityNames: orderedCityNames, dayCount: requestedPlanDayCount)
            }
        }
        trip.updatedAt = Date()
        do {
            try context.save()
            dismiss()
        } catch {
            isSaving = false
            saveError = "你的修改还在当前页面，请稍后再试。"
        }
    }

    private func updatePlannedDateRange() {
        let calendar = Calendar.autoupdatingCurrent
        let oldStart = calendar.startOfDay(for: trip.plannedStartDay)
        let oldEnd = calendar.startOfDay(for: trip.plannedEndDay)
        let newStart = calendar.startOfDay(for: startDay)
        let newEnd = max(newStart, calendar.startOfDay(for: endDay))
        let offset = calendar.dateComponents([.day], from: oldStart, to: newStart).day ?? 0

        let existingDays = days
        for day in existingDays {
            day.day = calendar.date(byAdding: .day, value: offset, to: day.day) ?? day.day
            for item in allItems.filter({ $0.tripDayID == day.id }) {
                item.startTime = item.startTime.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) }
                item.endTime = item.endTime.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) }
            }
        }

        let newCount = tripDates(from: newStart, through: newEnd).count
        if newCount < existingDays.count {
            let removed = existingDays.dropFirst(newCount)
            let removedIDs = Set(removed.map(\.id))
            allCities.filter { removedIDs.contains($0.tripDayID) }.forEach(context.delete)
            allItems.filter { removedIDs.contains($0.tripDayID) }.forEach(context.delete)
            removed.forEach(context.delete)
        } else if newCount > existingDays.count {
            for index in existingDays.count..<newCount {
                let date = calendar.date(byAdding: .day, value: index, to: newStart) ?? newEnd
                context.insert(TripDay(tripID: trip.id, day: date, orderIndex: index))
            }
        }

        existingDays.prefix(newCount).enumerated().forEach { index, day in day.orderIndex = index }
        trip.plannedStartDay = newStart
        trip.plannedEndDay = newEnd
        trip.datesUserEdited = hasPlannedDates
        if oldStart != newStart || oldEnd != newEnd {
            trip.actualEndedAt = nil
            trip.endReasonRaw = nil
        }
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

    struct CityGroup: Identifiable {
        let id: String
        let key: String
        let name: String
        let storedCityID: UUID?
        var stops: [TripItem]
    }
    struct PlaceTarget: Identifiable { let id = UUID(); let day: TripDay; let item: TripItem? }

}

private struct TripSwipeDeleteContainer<Content: View>: View {
    let deleteLabel: String
    let swipeEnabled: Bool
    let onSwipeStateChanged: (Bool) -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var horizontalOffset: CGFloat = 0
    @State private var isHorizontalDrag = false
    @State private var suppressSelection = false
    @State private var dragStartOffset: CGFloat = 0

    private let deleteActionWidth: CGFloat = 78

    var body: some View {
        ZStack(alignment: .trailing) {
            content(!suppressSelection && !isHorizontalDrag && horizontalOffset == 0)
                .offset(x: horizontalOffset)
                .allowsHitTesting(horizontalOffset == 0 && !isHorizontalDrag)

            if horizontalOffset < 0, !isHorizontalDrag {
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.trailing, deleteActionWidth)
                    .onTapGesture { close() }
            }

            Button(role: .destructive, action: delete) {
                VStack(spacing: 5) {
                    Image(systemName: "trash.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 46)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text("删除")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: deleteActionWidth)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deleteLabel)
            .opacity(horizontalOffset < 0 && !isHorizontalDrag ? 1 : 0)
            .allowsHitTesting(horizontalOffset < 0 && !isHorizontalDrag)
        }
        .background {
            TripHorizontalSwipeRecognizer(
                isEnabled: swipeEnabled,
                currentOffset: horizontalOffset,
                onBegan: beginHorizontalSwipe,
                onChanged: updateHorizontalSwipe,
                onEnded: finishHorizontalSwipe
            )
        }
        .accessibilityAction(named: deleteLabel, onDelete)
    }

    private func beginHorizontalSwipe() {
        guard swipeEnabled else { return }
        isHorizontalDrag = true
        suppressSelection = true
        dragStartOffset = horizontalOffset
        onSwipeStateChanged(true)
    }

    private func updateHorizontalSwipe(translationX: CGFloat) {
        guard isHorizontalDrag else { return }
        horizontalOffset = min(0, max(-deleteActionWidth, dragStartOffset + translationX))
    }

    private func finishHorizontalSwipe(translationX: CGFloat, velocityX: CGFloat) {
        guard isHorizontalDrag else { return }
        isHorizontalDrag = false
        let projectedOffset = min(
            0,
            max(-deleteActionWidth, dragStartOffset + translationX + velocityX * 0.12)
        )
        let staysOpen = projectedOffset < -(deleteActionWidth / 2)
        withAnimation(.snappy(duration: 0.2)) {
            horizontalOffset = staysOpen ? -deleteActionWidth : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !staysOpen {
                suppressSelection = false
                onSwipeStateChanged(false)
            }
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) {
            horizontalOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            suppressSelection = false
            onSwipeStateChanged(false)
        }
    }

    private func delete() {
        onSwipeStateChanged(false)
        onDelete()
    }
}

private struct TripItemDropDelegate: DropDelegate {
    let dayID: UUID
    let beforeItemID: UUID?
    let onTarget: (UUID, UUID?) -> Void
    let onDrop: (UUID, UUID?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) {
        onTarget(dayID, beforeItemID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop(dayID, beforeItemID)
    }
}

private struct TripReorderDragSource: UIViewRepresentable {
    let isEnabled: Bool
    let itemID: UUID
    let previewFrame: CGRect
    let onBegan: () -> Bool
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            itemID: itemID,
            previewFrame: previewFrame,
            onBegan: onBegan,
            onEnded: onEnded
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.addInteraction(UIDragInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.itemID = itemID
        context.coordinator.previewFrame = previewFrame
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var isEnabled: Bool
        var itemID: UUID
        var previewFrame: CGRect
        var onBegan: () -> Bool
        var onEnded: () -> Void
        private var pendingPreview: UIView?
        private weak var previewWindow: UIWindow?
        private var floatingPreview: UIView?
        private var previewCenterOffset: CGPoint = .zero
        private var ownsDragState = false

        init(
            isEnabled: Bool,
            itemID: UUID,
            previewFrame: CGRect,
            onBegan: @escaping () -> Bool,
            onEnded: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.itemID = itemID
            self.previewFrame = previewFrame
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard isEnabled else { return [] }

            // Capture the complete rendered stop before SwiftUI hides the source row.
            pendingPreview = interaction.view.flatMap(makeFullCardPreview(from:))
            let provider = NSItemProvider(object: itemID.uuidString as NSString)
            let dragItem = UIDragItem(itemProvider: provider)
            dragItem.localObject = itemID
            dragItem.previewProvider = Self.invisibleSystemPreview
            // This is the first point at which the long press has been accepted
            // as a drag. Start both visual and haptic feedback before movement.
            guard beginOwnedDrag(interaction: interaction, session: session) else { return [] }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
            return [dragItem]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            willAnimateLiftWith animator: UIDragAnimating,
            session: UIDragSession
        ) {
            animator.addCompletion { [weak self, weak interaction] position in
                guard position == .end, let interaction else { return }
                _ = self?.beginOwnedDrag(interaction: interaction, session: session)
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            _ = beginOwnedDrag(interaction: interaction, session: session)
        }

        @discardableResult
        private func beginOwnedDrag(interaction: UIDragInteraction, session: UIDragSession) -> Bool {
            if ownsDragState { return true }
            guard !ownsDragState, onBegan() else {
                pendingPreview = nil
                return false
            }
            ownsDragState = true
            let window = interaction.view?.window
            let preview = pendingPreview
            let initialLocation = window.map { session.location(in: $0) }
            pendingPreview = nil
            // Give SwiftUI one update pass to replace the source card with its
            // placeholder before placing the full-size floating copy on top.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self,
                      self.ownsDragState,
                      let window,
                      let preview,
                      let initialLocation else { return }
                let liftOffsetY: CGFloat = -6
                self.previewCenterOffset = CGPoint(
                    x: preview.center.x - initialLocation.x,
                    y: preview.center.y - initialLocation.y + liftOffsetY
                )
                preview.layer.shadowColor = UIColor.black.cgColor
                preview.layer.shadowOpacity = 0.12
                preview.layer.shadowRadius = 4
                preview.layer.shadowOffset = CGSize(width: 0, height: 2)
                preview.alpha = 0.9
                preview.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
                preview.isUserInteractionEnabled = false
                window.addSubview(preview)
                self.previewWindow = window
                self.floatingPreview = preview
                UIView.animate(
                    withDuration: 0.2,
                    delay: 0,
                    usingSpringWithDamping: 0.78,
                    initialSpringVelocity: 0.5,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    preview.center.y += liftOffsetY
                    preview.alpha = 1
                    preview.transform = .identity
                    preview.layer.shadowOpacity = 0.38
                    preview.layer.shadowRadius = 18
                    preview.layer.shadowOffset = CGSize(width: 0, height: 10)
                }
            }
            return true
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            prefersFullSizePreviewsFor session: UIDragSession
        ) -> Bool {
            true
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
            guard let window = previewWindow, let preview = floatingPreview else { return }
            let location = session.location(in: window)
            preview.center = CGPoint(
                x: location.x + previewCenterOffset.x,
                y: location.y + previewCenterOffset.y
            )
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            session: UIDragSession,
            willEndWith operation: UIDropOperation
        ) {
            if operation == .cancel || operation == .forbidden {
                finishOwnedDrag()
            }
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            session: UIDragSession,
            didEndWith operation: UIDropOperation
        ) {
            finishOwnedDrag()
        }

        private func makeFullCardPreview(from sourceView: UIView) -> UIView? {
            guard let window = sourceView.window,
                  previewFrame.width > 1,
                  previewFrame.height > 1 else { return nil }
            let frameInWindow = window.convert(previewFrame, from: nil)
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: frameInWindow.size, format: format).image { context in
                context.cgContext.translateBy(x: -frameInWindow.minX, y: -frameInWindow.minY)
                window.layer.render(in: context.cgContext)
            }
            let preview = UIImageView(image: image)
            preview.frame = frameInWindow
            preview.contentMode = .scaleToFill
            return preview
        }

        private func removeFloatingPreview() {
            pendingPreview = nil
            floatingPreview?.removeFromSuperview()
            floatingPreview = nil
            previewWindow = nil
            previewCenterOffset = .zero
        }

        private func finishOwnedDrag() {
            removeFloatingPreview()
            guard ownsDragState else { return }
            ownsDragState = false
            onEnded()
        }

        private static func invisibleSystemPreview() -> UIDragPreview? {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.backgroundColor = .clear
            let parameters = UIDragPreviewParameters()
            parameters.visiblePath = UIBezierPath()
            return UIDragPreview(view: view, parameters: parameters)
        }
    }
}

private struct TripHorizontalSwipeRecognizer: UIViewRepresentable {
    let isEnabled: Bool
    let currentOffset: CGFloat
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            currentOffset: currentOffset,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    func makeUIView(context: Context) -> GestureAttachmentView {
        let view = GestureAttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: GestureAttachmentView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.currentOffset = currentOffset
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        uiView.installIfNeeded()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: GestureAttachmentView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ uiView: GestureAttachmentView, coordinator: Coordinator) {
        uiView.uninstall()
    }

    final class GestureAttachmentView: UIView {
        weak var coordinator: Coordinator?
        weak var installedView: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let coordinator else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scrollView = ancestor as? UIScrollView,
                  installedView !== scrollView else { return }
            uninstall()
            coordinator.attachmentView = self
            scrollView.addGestureRecognizer(coordinator.panGestureRecognizer)
            installedView = scrollView
        }

        func uninstall() {
            guard let coordinator else { return }
            installedView?.removeGestureRecognizer(coordinator.panGestureRecognizer)
            installedView = nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var currentOffset: CGFloat
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var attachmentView: UIView?
        lazy var panGestureRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        init(
            isEnabled: Bool,
            currentOffset: CGFloat,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.isEnabled = isEnabled
            self.currentOffset = currentOffset
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view,
                  let attachmentView else { return false }
            let location = pan.location(in: attachmentView)
            guard attachmentView.bounds.insetBy(dx: -2, dy: -2).contains(location) else { return false }
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) * 1.15 else { return false }
            return currentOffset < 0 || velocity.x < 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translationX = recognizer.translation(in: view).x
            switch recognizer.state {
            case .began:
                onBegan()
            case .changed:
                onChanged(translationX)
            case .ended:
                onEnded(translationX, recognizer.velocity(in: view).x)
            case .cancelled, .failed:
                onEnded(translationX, 0)
            default:
                break
            }
        }
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
