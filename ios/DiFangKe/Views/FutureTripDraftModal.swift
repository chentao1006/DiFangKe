import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

struct FutureTripDraftModal: View {
    private let editingTrip: FutureTrip?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @StateObject private var placePicker = PlacePickerViewModel()
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]

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
    @State private var hasArrivalTime = false
    @State private var selectedActivityTypeValue: String?
    @State private var notes = ""
    @FocusState private var notesFocused: Bool
    @State private var pinLiftOffset: CGFloat = 0
    @State private var pinAnimationTask: Task<Void, Never>?
    @State private var hasLoadedInitialValues = false

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
            Form {
                mapSection
                selectedPlaceSection
                arrivalSection
                activitySection
                notesSection
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                if !placePicker.searchResults.isEmpty {
                    searchResultsOverlay
                }
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

                searchBarOverlay
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
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
        Section("计划到达时间") {
            DatePicker("日期", selection: $arrivalDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.compact)

            Toggle("设置具体时间", isOn: $hasArrivalTime)
                .tint(Color.dfkAccent)

            if hasArrivalTime {
                DatePicker("时间", selection: $arrivalDate, in: Date()..., displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
            }
        }
    }

    private var notesSection: some View {
        Section("备注") {
            TextField("添加备注...", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .focused($notesFocused)
        }
    }

    private var activitySection: some View {
        Section("活动类型") {
            Menu {
                Button {
                    selectedActivityTypeValue = nil
                } label: {
                    Label("未设置", systemImage: "circle.slash")
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

                    Text(selectedActivity?.name ?? "未设置")
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

    private var searchBarOverlay: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索行程目的地", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .task(id: searchText) {
                    if isSkippingNextSearch {
                        isSkippingNextSearch = false
                        return
                    }

                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard query.count > 1 else {
                        placePicker.searchResults = []
                        return
                    }

                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                    placePicker.search(query: query, userCoord: selectedCoordinate ?? locationManager.lastLocation?.coordinate)
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    placePicker.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.1), radius: 5)
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
        .padding(.top, 64)
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
            editingTrip.hasArrivalTime = hasArrivalTime
            editingTrip.activityTypeValue = selectedActivityTypeValue
            editingTrip.notes = normalizedNotes
            if matchingPlaceID != nil {
                editingTrip.placeID = matchingPlaceID
            }
            NotificationManager.shared.scheduleFutureTripNotification(for: editingTrip.id, placeName: selectedDisplayName, arrivalDate: normalizedArrivalDate, hasArrivalTime: hasArrivalTime)
        } else {
            let trip = FutureTrip(
                placeID: matchingPlaceID,
                placeName: selectedDisplayName,
                address: currentCenterAddress == "正在解析位置..." ? nil : currentCenterAddress,
                notes: normalizedNotes,
                coordinate: coordinate,
                arrivalDate: normalizedArrivalDate,
                hasArrivalTime: hasArrivalTime,
                activityTypeValue: selectedActivityTypeValue
            )
            modelContext.insert(trip)
            NotificationManager.shared.scheduleFutureTripNotification(for: trip.id, placeName: trip.placeName, arrivalDate: trip.arrivalDate, hasArrivalTime: trip.hasArrivalTime)
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
            hasArrivalTime = trip.hasArrivalTime
            selectedActivityTypeValue = trip.activityTypeValue
            notes = trip.notes ?? ""
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
        if hasArrivalTime { return arrivalDate }
        return calendar.startOfDay(for: arrivalDate)
    }

    private var normalizedNotes: String? {
        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
