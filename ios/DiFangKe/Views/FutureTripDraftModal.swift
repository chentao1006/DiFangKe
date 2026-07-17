import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

private enum OrderedInsertionPosition: Equatable {
    case first
    case after(UUID)
    case end

    func isAvailable(in trips: [FutureTrip]) -> Bool {
        switch self {
        case .first, .end:
            return true
        case .after(let id):
            return trips.contains { $0.id == id }
        }
    }
}

struct FutureTripDraftModal: View {
    private let editingTrip: FutureTrip?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @StateObject private var placePicker = PlacePickerViewModel()
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    @Query(sort: \FutureTrip.arrivalDate) private var allFutureTrips: [FutureTrip]

    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPlaceName = ""
    @State private var searchText = ""
    @State private var isSkippingNextSearch = false
    @State private var currentCenterAddress = "正在解析位置..."
    @State private var centerTrigger = UUID()
    @State private var shouldSnapToUser = false
    @State private var radius: Float = 180
    @State private var radiusTrigger = UUID()
    @State private var inferredPlaceName: String?
    @State private var justPickedSearchResult = false
    @State private var arrivalDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var hasPlanDate = true
    @State private var hasArrivalTime = false
    @State private var scheduleMode: FutureTripScheduleMode = .timed
    @State private var orderedInsertionPosition = OrderedInsertionPosition.end
    @State private var selectedActivityTypeValue: String?
    @State private var notesState = IMETextState()
    @State private var pinLiftOffset: CGFloat = 0
    @State private var pinAnimationTask: Task<Void, Never>?
    @State private var hasLoadedInitialValues = false
    @State private var searchTask: Task<Void, Never>?

    init(editingTrip: FutureTrip? = nil) {
        self.editingTrip = editingTrip
    }

    private var selectedDisplayName: String {
        let explicitName = selectedPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitName.isEmpty { return explicitName }

        let address = currentCenterAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty && address != "正在解析位置..." { return address }
        return "未选择地点"
    }

    private var canSave: Bool {
        selectedCoordinate != nil && selectedDisplayName != "未选择地点"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Form {
                    mapSection
                    selectedPlaceSection
                    arrivalSection
                    activitySection
                    notesSection
                }
                .scrollDismissesKeyboard(.interactively)
                
                VStack(spacing: 8) {
                    searchBarOverlay
                    searchResultsOverlay
                        .opacity(placePicker.searchResults.isEmpty ? 0 : 1)
                        .allowsHitTesting(!placePicker.searchResults.isEmpty)
                }
                .padding(.top, 12)
            }
            .navigationTitle(editingTrip == nil ? "行程计划" : "修改行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveTrip()
                    } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                loadInitialValuesIfNeeded()
            }
        }
    }

    private var mapSection: some View {
        Section {
            ZStack {
                MapPickerView(
                    selectedCoord: $selectedCoordinate,
                    radius: $radius,
                    address: $currentCenterAddress,
                    inferredPlaceName: $inferredPlaceName,
                    centerTrigger: centerTrigger,
                    shouldSnapToUser: $shouldSnapToUser,
                    userCoord: locationManager.lastLocation?.coordinate,
                    radiusTrigger: radiusTrigger,
                    initialRegionMeters: 4_000
                )

                Image(systemName: "mappin")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.dfkAccent)
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                    .offset(y: pinLiftOffset - 16)
                    .allowsHitTesting(false)

                locationHUD
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 280)
            .listRowInsets(EdgeInsets())
            .onChange(of: selectedCoordinate?.latitude) { _, _ in
                playPinDropAnimation()
            }
            .onChange(of: selectedCoordinate?.longitude) { _, _ in
                playPinDropAnimation()
            }
            .onChange(of: inferredPlaceName) { _, newName in
                guard let newName = newName, !newName.isEmpty else { return }
                if justPickedSearchResult {
                    justPickedSearchResult = false
                } else {
                    selectedPlaceName = newName
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private var selectedPlaceSection: some View {
        Section("选定地点") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Color.dfkAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDisplayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selectedDisplayName == "未选择地点" ? .secondary : .primary)
                    if selectedDisplayName != currentCenterAddress,
                       currentCenterAddress != "正在解析位置...",
                       !currentCenterAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(currentCenterAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var arrivalSection: some View {
        Section("计划时间") {
            Toggle("设定计划日期", isOn: $hasPlanDate)
                .tint(Color.dfkAccent)

            if hasPlanDate {
                DatePicker("日期", selection: $arrivalDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)

                Toggle("设置具体时间", isOn: $hasArrivalTime)
                    .tint(Color.dfkAccent)

                if hasArrivalTime {
                    DatePicker("时间", selection: $arrivalDate, in: Date()..., displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                } else {
                    orderedInsertionMenu
                }
            } else {
                orderedInsertionMenu
                Text("未设日期的计划会排在所有已设日期计划之后。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: hasPlanDate) { _, hasDate in
            guard !hasDate else { return }
            hasArrivalTime = false
            scheduleMode = .ordered
            orderedInsertionPosition = .end
        }
        .onChange(of: hasArrivalTime) { _, hasTime in
            scheduleMode = hasTime ? .timed : .ordered
            if !hasTime && !orderedInsertionPosition.isAvailable(in: insertionCandidateTripsForSelectedDay) {
                orderedInsertionPosition = .end
            }
        }
        .onChange(of: arrivalDate) { _, _ in
            if !orderedInsertionPosition.isAvailable(in: insertionCandidateTripsForSelectedDay) {
                orderedInsertionPosition = .end
            }
        }
    }

    private var orderedInsertionMenu: some View {
        Menu {
            Button {
                orderedInsertionPosition = .first
            } label: {
                Label("安排在最前", systemImage: orderedInsertionPosition == .first ? "checkmark" : "arrow.up.to.line")
            }

            ForEach(insertionCandidateTripsForSelectedDay) { trip in
                Button {
                    orderedInsertionPosition = .after(trip.id)
                } label: {
                    Label("安排在“\(insertionCandidateTitle(for: trip))”之后", systemImage: orderedInsertionPosition == .after(trip.id) ? "checkmark" : insertionCandidateIcon(for: trip))
                }
            }

            Button {
                orderedInsertionPosition = .end
            } label: {
                Label("安排在最后", systemImage: orderedInsertionPosition == .end ? "checkmark" : "arrow.down.to.line")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.number")
                    .foregroundStyle(Color.dfkAccent)
                    .frame(width: 24)

                Text(orderedInsertionTitle)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notesSection: some View {
        Section("备注") {
            ZStack(alignment: .topLeading) {
                if notesState.text.isEmpty {
                    Text("添加备注...")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                IMESafeTextView(textState: notesState)
                    .frame(minHeight: 44, maxHeight: 132)
            }
        }
    }

    private var activitySection: some View {
        Section("活动类型") {
            Menu {
                Button {
                    selectedActivityTypeValue = nil
                } label: {
                    Label("无", systemImage: "circle.slash")
                }

                ForEach(allActivities) { activity in
                    Button {
                        selectedActivityTypeValue = activity.id.uuidString
                    } label: {
                        Label(activity.name, systemImage: activity.icon)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedActivity?.icon ?? "tag")
                        .foregroundStyle(selectedActivity?.color ?? .secondary)
                        .frame(width: 24)

                    Text(selectedActivity?.name ?? "无")
                        .foregroundStyle(selectedActivity == nil ? .secondary : .primary)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var selectedActivity: ActivityType? {
        guard let selectedActivityTypeValue else { return nil }
        return allActivities.first { $0.id.uuidString == selectedActivityTypeValue || $0.name == selectedActivityTypeValue }
    }

    private var normalizedTripDay: Date {
        Calendar.current.startOfDay(for: arrivalDate)
    }

    private var insertionCandidateTripsForSelectedDay: [FutureTrip] {
        if !hasPlanDate {
            return undatedTrips
                .filter { $0.id != editingTrip?.id && !$0.isCompleted }
        }
        return orderedDayTrips(for: normalizedTripDay)
            .filter { $0.id != editingTrip?.id && !$0.isCompleted }
    }

    private var undatedTrips: [FutureTrip] {
        FutureTrip.dayOrdered(allFutureTrips.filter { !$0.hasPlanDate })
    }

    private var orderedInsertionTitle: String {
        if insertionCandidateTripsForSelectedDay.isEmpty {
            return hasPlanDate ? "当天第 1 个计划" : "第 1 个计划"
        }

        switch orderedInsertionPosition {
        case .first:
            return "安排在最前"
        case .after(let id):
            if let trip = insertionCandidateTripsForSelectedDay.first(where: { $0.id == id }) {
                return "安排在“\(insertionCandidateTitle(for: trip))”之后"
            }
            return "安排在最后"
        case .end:
            return "安排在最后"
        }
    }

    private func insertionCandidateTitle(for trip: FutureTrip) -> String {
        if trip.isOrdered {
            return trip.placeName
        }

        let calendar = Calendar.current
        if trip.hasArrivalTime {
            return "\(trip.arrivalDate.formatted(date: .omitted, time: .shortened)) \(trip.placeName)"
        }

        if calendar.isDate(trip.arrivalDate, inSameDayAs: normalizedTripDay) {
            return "计划 \(trip.placeName)"
        }

        return trip.placeName
    }

    private func insertionCandidateIcon(for trip: FutureTrip) -> String {
        guard let activityTypeValue = trip.activityTypeValue,
              let activity = allActivities.first(where: { $0.id.uuidString == activityTypeValue || $0.name == activityTypeValue }) else {
            return trip.hasArrivalTime ? "clock" : "calendar"
        }

        return activity.icon
    }

    private func orderedDayTrips(for day: Date) -> [FutureTrip] {
        let calendar = Calendar.current
        let trips = allFutureTrips.filter { $0.hasPlanDate && calendar.isDate($0.arrivalDate, inSameDayAs: day) }
        return FutureTrip.dayOrdered(trips)
    }

    private var searchBarOverlay: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索行程目的地", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    if isSkippingNextSearch {
                        isSkippingNextSearch = false
                        return
                    }

                    let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard query.count > 1 else {
                        placePicker.searchResults = []
                        return
                    }

                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if Task.isCancelled { return }
                        placePicker.search(query: query, userCoord: selectedCoordinate ?? locationManager.lastLocation?.coordinate)
                    }
                }

            Button {
                searchText = ""
                placePicker.searchResults = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .opacity(searchText.isEmpty ? 0 : 1)
            .allowsHitTesting(!searchText.isEmpty)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.1), radius: 5)
        .padding(.horizontal, 16)
    }

    private var searchResultsOverlay: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(placePicker.searchResults, id: \.self) { item in
                        Button {
                            applySearchResult(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name ?? "位置")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.primary)
                                Text(item.placemark.title ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.clear)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 16)
    }

    private var locationHUD: some View {
        HStack {
            Text(currentCenterAddress)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.leading, 12)

            Spacer()

            Button {
                shouldSnapToUser = true
            } label: {
                Image(systemName: "location.fill")
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private func applySearchResult(_ item: MKMapItem) {
        isSkippingNextSearch = true
        justPickedSearchResult = true
        selectedCoordinate = item.placemark.coordinate
        selectedPlaceName = item.name ?? "位置"
        searchText = item.name ?? ""
        currentCenterAddress = item.placemark.title ?? currentCenterAddress
        centerTrigger = UUID()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        placePicker.searchResults = []
    }

    private func playPinDropAnimation() {
        pinAnimationTask?.cancel()
        pinAnimationTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.08)) {
                pinLiftOffset = -9
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.interpolatingSpring(stiffness: 520, damping: 18)) {
                pinLiftOffset = 0
            }
        }
    }

    private func saveTrip() {
        guard canSave, let coordinate = selectedCoordinate else { return }
        let previousDay = editingTrip.flatMap { $0.hasPlanDate ? Calendar.current.startOfDay(for: $0.arrivalDate) : nil }
        let wasUndated = editingTrip.map { !$0.hasPlanDate } ?? false
        let isOrderedTrip = !hasPlanDate || !hasArrivalTime

        var matchingPlaceID: UUID?
        if let places = try? modelContext.fetch(FetchDescriptor<Place>()) {
            matchingPlaceID = places.first(where: {
                $0.name == selectedDisplayName &&
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 200
            })?.placeID
        }

        if let editingTrip {
            editingTrip.placeName = selectedDisplayName
            editingTrip.address = currentCenterAddress == "正在解析位置..." ? nil : currentCenterAddress
            editingTrip.coordinate = coordinate
            editingTrip.arrivalDate = normalizedArrivalDate
            editingTrip.hasPlanDate = hasPlanDate
            editingTrip.hasArrivalTime = isOrderedTrip ? false : hasArrivalTime
            editingTrip.scheduleMode = isOrderedTrip ? .ordered : .timed
            editingTrip.activityTypeValue = selectedActivityTypeValue
            editingTrip.notes = normalizedNotes
            if matchingPlaceID != nil {
                editingTrip.placeID = matchingPlaceID
            }
            if !hasPlanDate {
                NotificationManager.shared.cancelFutureTripNotification(for: editingTrip.id)
                reindexUndatedTrips(movingTrip: editingTrip, position: orderedInsertionPosition)
            } else if isOrderedTrip {
                NotificationManager.shared.cancelFutureTripNotification(for: editingTrip.id)
                reindexDayTrips(in: normalizedTripDay, movingTrip: editingTrip, position: orderedInsertionPosition)
            } else {
                reindexTimedTrip(in: normalizedTripDay, movingTrip: editingTrip)
                NotificationManager.shared.scheduleFutureTripNotification(for: editingTrip.id, placeName: selectedDisplayName, arrivalDate: normalizedArrivalDate, hasArrivalTime: hasArrivalTime)
            }
        } else {
            let trip = FutureTrip(
                placeID: matchingPlaceID,
                placeName: selectedDisplayName,
                address: currentCenterAddress == "正在解析位置..." ? nil : currentCenterAddress,
                notes: normalizedNotes,
                coordinate: coordinate,
                arrivalDate: normalizedArrivalDate,
                hasPlanDate: hasPlanDate,
                hasArrivalTime: isOrderedTrip ? false : hasArrivalTime,
                scheduleMode: isOrderedTrip ? .ordered : .timed,
                activityTypeValue: selectedActivityTypeValue
            )
            modelContext.insert(trip)
            if !hasPlanDate {
                reindexUndatedTrips(movingTrip: trip, position: orderedInsertionPosition)
            } else if isOrderedTrip {
                reindexDayTrips(in: normalizedTripDay, movingTrip: trip, position: orderedInsertionPosition)
            } else {
                reindexTimedTrip(in: normalizedTripDay, movingTrip: trip)
                NotificationManager.shared.scheduleFutureTripNotification(for: trip.id, placeName: trip.placeName, arrivalDate: trip.arrivalDate, hasArrivalTime: trip.hasArrivalTime)
            }
        }

        if let previousDay, (!hasPlanDate || previousDay != normalizedTripDay) {
            reindexDayTrips(in: previousDay, movingTrip: nil, position: .end)
        }
        if wasUndated && hasPlanDate {
            reindexUndatedTrips(movingTrip: nil, position: .end)
        }

        try? modelContext.save()
        FutureTrip.postDidChangeNotification()
        dismiss()
    }

    private func loadInitialValuesIfNeeded() {
        guard !hasLoadedInitialValues else { return }
        hasLoadedInitialValues = true

        if let trip = editingTrip {
            selectedCoordinate = trip.coordinate
            selectedPlaceName = trip.placeName
            inferredPlaceName = trip.placeName
            currentCenterAddress = trip.address ?? trip.placeName
            arrivalDate = trip.arrivalDate
            hasPlanDate = trip.hasPlanDate
            hasArrivalTime = trip.hasArrivalTime
            scheduleMode = trip.hasArrivalTime ? .timed : .ordered
            orderedInsertionPosition = trip.hasPlanDate ? insertionPositionForExistingTrip(trip) : insertionPositionForExistingUndatedTrip(trip)
            selectedActivityTypeValue = trip.activityTypeValue
            notesState.text = trip.notes ?? ""
            justPickedSearchResult = true
            
            centerTrigger = UUID()
            return
        }

        if selectedCoordinate == nil, let coordinate = locationManager.lastLocation?.coordinate {
            selectedCoordinate = coordinate
            shouldSnapToUser = true
        }
    }

    private var normalizedArrivalDate: Date {
        let calendar = Calendar.current
        guard hasPlanDate else { return arrivalDate }
        if hasArrivalTime { return arrivalDate }
        return endOfSelectedDay(using: calendar)
    }

    private func endOfSelectedDay(using calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: arrivalDate)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(24 * 3600)
        return nextDay.addingTimeInterval(-1)
    }

    private var normalizedNotes: String? {
        let value = notesState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func insertionPositionForExistingTrip(_ trip: FutureTrip) -> OrderedInsertionPosition {
        let day = Calendar.current.startOfDay(for: trip.arrivalDate)
        let trips = orderedDayTrips(for: day)
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return .end }
        if index == 0 { return .first }
        return .after(trips[index - 1].id)
    }

    private func reindexDayTrips(in day: Date, movingTrip: FutureTrip?, position: OrderedInsertionPosition) {
        var trips = orderedDayTrips(for: day)
            .filter { $0.id != movingTrip?.id && !$0.isCompleted }

        if let movingTrip {
            let targetIndex: Int
            switch position {
            case .first:
                targetIndex = 0
            case .after(let id):
                if let anchorIndex = trips.firstIndex(where: { $0.id == id }) {
                    targetIndex = anchorIndex + 1
                } else {
                    targetIndex = trips.count
                }
            case .end:
                targetIndex = trips.count
            }
            trips.insert(movingTrip, at: min(max(targetIndex, 0), trips.count))
        }

        for (index, trip) in trips.enumerated() {
            trip.orderIndex = index + 1
        }
    }

    private func insertionPositionForExistingUndatedTrip(_ trip: FutureTrip) -> OrderedInsertionPosition {
        let trips = undatedTrips
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return .end }
        if index == 0 { return .first }
        return .after(trips[index - 1].id)
    }

    private func reindexUndatedTrips(movingTrip: FutureTrip?, position: OrderedInsertionPosition) {
        var trips = FutureTrip.dayOrdered(allFutureTrips.filter { !$0.hasPlanDate && $0.id != movingTrip?.id && !$0.isCompleted })
        if let movingTrip {
            let targetIndex: Int
            switch position {
            case .first:
                targetIndex = 0
            case .after(let id):
                targetIndex = (trips.firstIndex(where: { $0.id == id }) ?? (trips.count - 1)) + 1
            case .end:
                targetIndex = trips.count
            }
            trips.insert(movingTrip, at: min(max(targetIndex, 0), trips.count))
        }
        for (index, trip) in trips.enumerated() {
            trip.orderIndex = index + 1
        }
    }

    private func reindexTimedTrip(in day: Date, movingTrip: FutureTrip) {
        let allTrips = orderedDayTrips(for: day)
        let sortTimes = futureTripSortTimes(for: allTrips, on: day)
        
        var trips = allTrips.filter { $0.id != movingTrip.id && !$0.isCompleted }
        
        let targetIndex = trips.firstIndex { trip in
            (sortTimes[trip.id] ?? trip.arrivalDate) > movingTrip.arrivalDate
        } ?? trips.count

        trips.insert(movingTrip, at: targetIndex)
        for (index, trip) in trips.enumerated() {
            trip.orderIndex = index + 1
        }
    }

    private func futureTripSortTimes(for trips: [FutureTrip], on date: Date) -> [UUID: Date] {
        var sortTimes: [UUID: Date] = [:]
        var anchorTime = Calendar.current.startOfDay(for: date)
        var orderedOffset = 1

        for trip in trips {
            if trip.isOrdered {
                sortTimes[trip.id] = anchorTime.addingTimeInterval(TimeInterval(orderedOffset))
                orderedOffset += 1
            } else {
                sortTimes[trip.id] = trip.arrivalDate
                anchorTime = trip.arrivalDate
                orderedOffset = 1
            }
        }

        return sortTimes
    }
}

extension Image {
    func dfkToolbarDismissIcon() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
    }

    func dfkToolbarConfirmIcon() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.dfkAccent)
            .frame(width: 28, height: 28)
    }
}
