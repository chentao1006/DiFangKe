import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct EditPlaceSheet: View {
    @Bindable var place: Place
    var onSave: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationManager.self) private var locationManager
    @StateObject private var vm = PlacePickerViewModel()

    @Query private var allPlaces: [Place]
    @State private var placeName = ""
    @State private var radius: Float = 100
    @State private var selectedCoord: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var isSkippingNextSearch = false
    @State private var currentCenterAddress = "正在解析位置..."
    @State private var centerTrigger = UUID()
    @State private var radiusTrigger = UUID()
    @State private var shouldSnapToUser = false
    @State private var showDeleteConfirm = false
    @State private var showingCategoryManager = false

    private let importantTypes = ["家", "公司", "学校"]

    private var presetHeader: some View {
        Text("快速预设")
    }

    init(place: Place, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.place = place
        self.onSave = onSave
        self.onDelete = onDelete
        self._placeName = State(initialValue: place.name)
        self._radius = State(initialValue: place.radius)
        self._selectedCoord = State(initialValue: place.coordinate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Interactive Map Section (Now inside Form to allow scrolling)
                    ZStack {
                        MapPickerView(selectedCoord: $selectedCoord, radius: $radius, address: $currentCenterAddress, centerTrigger: centerTrigger, shouldSnapToUser: $shouldSnapToUser, userCoord: selectedCoord, radiusTrigger: radiusTrigger)

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
                }
                .listRowBackground(Color.clear)

                Section(header: Text("地点名称"), footer: 
                    HStack(spacing: 8) {
                        ForEach(importantTypes, id: \.self) { type in
                            presetBadge(type)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                ) {
                    TextField("给这个地点起个名字", text: $placeName)
                        .font(.body)
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
                    Toggle("忽略此地点的足迹", isOn: $place.isIgnored)
                        .tint(.orange)
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除此地点", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                    }
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
            .navigationTitle("编辑重要地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        place.name = placeName.trimmingCharacters(in: .whitespaces)
                        if let coord = selectedCoord {
                            place.latitude = coord.latitude
                            place.longitude = coord.longitude
                        }
                        place.radius = radius
                        place.address = currentCenterAddress
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(canSave ? .dfkAccent : .gray)
                    .disabled(!canSave)
                }
            }
            .alert(isPresented: $showDeleteConfirm) {
                Alert(
                    title: Text("确认删除"),
                    message: Text("删除后不可恢复，历史足迹不会受影响。"),
                    primaryButton: .destructive(Text("删除")) {
                        onDelete()
                        dismiss()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
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
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.secondary.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundColor(isSelected ? .primary : .secondary)
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
                        vm.search(query: newValue, userCoord: selectedCoord)
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
