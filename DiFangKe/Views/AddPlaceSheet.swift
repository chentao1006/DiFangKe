import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct AddPlaceSheet: View {
    var initialCoordinate: CLLocationCoordinate2D?
    var initialName: String?
    var onSave: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @StateObject private var vm = PlacePickerViewModel()

    @Query private var allPlaces: [Place]
    @State private var placeName = ""
    @State private var radius: Float = 80
    @State private var selectedCoord: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var isSkippingNextSearch = false
    @State private var currentCenterAddress = "正在解析位置..."
    @State private var centerTrigger = UUID()
    @State private var radiusTrigger = UUID()
    @State private var shouldSnapToUser = false
    @State private var showingCategoryManager = false
    @State private var isIgnored = false
    
    init(initialCoordinate: CLLocationCoordinate2D? = nil, initialName: String? = nil, onSave: @escaping (Place) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.initialName = initialName
        self.onSave = onSave
    }

    private let importantTypes = ["家", "公司", "学校"]

    private var presetHeader: some View {
        Text("快速预设")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Interactive Map Section (Now inside Form to allow scrolling)
                    ZStack {
                        MapPickerView(selectedCoord: $selectedCoord, radius: $radius, address: $currentCenterAddress, centerTrigger: centerTrigger, shouldSnapToUser: $shouldSnapToUser, userCoord: locationManager.lastLocation?.coordinate, radiusTrigger: radiusTrigger)

                        Circle()
                            .stroke(Color.orange.opacity(0.8), lineWidth: 3)
                            .background(Circle().fill(Color.orange.opacity(0.1)))
                            .frame(width: 120, height: 120)
                            .allowsHitTesting(false)
                        
                        locationHUD
                            .padding(.bottom, 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        
                        // Floating Search Bar at the top of the map
                        searchBarOverlay
                            .padding(.top, 12)
                            .padding(.horizontal, 16)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: 350)
                    .listRowInsets(EdgeInsets()) // Full-width
                    .onAppear {
                        if let name = initialName {
                            placeName = name
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if let initCoord = initialCoordinate {
                                selectedCoord = initCoord
                                centerTrigger = UUID()
                            } else if let loc = locationManager.lastLocation?.coordinate {
                                selectedCoord = loc
                            }
                            shouldSnapToUser = true
                        }
                    }
                }
                .listRowBackground(Color.clear)

                Section(header: Text("地点名称")) {
                    TextField("给这个地点起个名字", text: $placeName)
                        .font(.body)
                }

                Section(header: presetHeader) {
                    FlowLayout(spacing: 8) {
                        ForEach(importantTypes, id: \.self) { type in
                            presetBadge(type)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("感知半径"), footer: Text("进入该范围内时自动识别为此地点")) {
                    HStack {
                        Text("\(Int(radius)) 米")
                            .monospacedDigit()
                            .fixedSize()
                            .frame(minWidth: 52, alignment: .leading)
                            .foregroundColor(.orange)
                        Slider(value: Binding(
                            get: { radius },
                            set: { newValue in
                                radius = newValue
                                radiusTrigger = UUID()
                            }
                        ), in: 30...300, step: 10)
                            .tint(Color.orange)
                    }
                }

                Section(header: Text("记录设置"), footer: Text("开启后，系统将不再记录发生在此地点的足迹。")) {
                    Toggle("在此地点停止记录", isOn: $isIgnored)
                        .tint(.orange)
                }
            }
            .overlay(alignment: .top) {
                if !vm.searchResults.isEmpty {
                    VStack {
                        Spacer().frame(height: 68) // Below floating search bar
                        searchResultsOverlay
                    }
                    .allowsHitTesting(true)
                }
            }
            .navigationTitle("添加重要地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard canSave, let coord = selectedCoord else { return }
                        
                        let place = Place(name: placeName.trimmingCharacters(in: .whitespaces),
                                         coordinate: coord,
                                         radius: radius,
                                         address: currentCenterAddress)
                        place.isIgnored = isIgnored
                        onSave(place)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(canSave ? .dfkAccent : .gray)
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !placeName.trimmingCharacters(in: .whitespaces).isEmpty && selectedCoord != nil
    }

    private func presetBadge(_ name: String) -> some View {
        let isSelected = placeName.trimmingCharacters(in: .whitespaces) == name
        return Button {
            placeName = name
        } label: {
            Text(name)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.orange : Color.orange.opacity(0.1))
                .foregroundColor(isSelected ? .white : .orange)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchBarOverlay: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索地址", text: $searchText)
                .onChange(of: searchText) { oldValue, newValue in
                    if isSkippingNextSearch { isSkippingNextSearch = false; return }
                    if newValue.count > 1 {
                        vm.search(query: newValue, userCoord: locationManager.lastLocation?.coordinate)
                    } else if newValue.isEmpty {
                        vm.searchResults = []
                    }
                }
            if !searchText.isEmpty {
                Button { searchText = ""; vm.searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.1), radius: 5)
    }

    private var searchResultsOverlay: some View {
        Group {
            if !vm.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(vm.searchResults, id: \.self) { item in
                                Button {
                                    isSkippingNextSearch = true
                                    selectedCoord = item.placemark.coordinate
                                    centerTrigger = UUID()
                                    placeName = item.name ?? ""
                                    searchText = item.name ?? ""
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    vm.searchResults = []
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name ?? "").font(.subheadline.bold()).foregroundColor(.primary)
                                        Text(item.placemark.title ?? "").font(.caption).foregroundColor(.secondary)
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
                .padding(.top, 4)
            }
        }
    }

    private var locationHUD: some View {
        HStack {
            Text(currentCenterAddress)
                .font(.caption2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.leading, 12)
            Spacer()
            Button { shouldSnapToUser = true } label: {
                Image(systemName: "location.fill")
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }
            .padding(12)
        }
    }
}
