import SwiftUI
import SwiftData
import CoreLocation

struct TagSelectionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Bindable var footprint: Footprint
    @Query(sort: \PlaceTag.name) private var allRegisteredTags: [PlaceTag]
    @Query private var allFootprints: [Footprint]
    
    @State private var searchText = ""
    @State private var recommendedTags: [String] = []
    
    var body: some View {
        NavigationStack {
            List {
                if !footprint.tags.isEmpty {
                    Section("当前已选") {
                        FlowLayout(spacing: 8) {
                            ForEach(footprint.tags, id: \.self) { tag in
                                tagButton(tag, isSelected: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if searchText.isEmpty {
                    if !recommendedTags.isEmpty {
                        Section("推荐标签") {
                            FlowLayout(spacing: 8) {
                                ForEach(recommendedTags.filter { !footprint.tags.contains($0) }, id: \.self) { tag in
                                    tagButton(tag, isSelected: false)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    if !frequentTags.isEmpty {
                        let filteredFreq = frequentTags.filter { 
                            !footprint.tags.contains($0) && !recommendedTags.contains($0) 
                        }
                        if !filteredFreq.isEmpty {
                            Section("常用标签") {
                                FlowLayout(spacing: 8) {
                                    ForEach(filteredFreq, id: \.self) { tag in
                                        tagButton(tag, isSelected: false)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                
                Section(searchText.isEmpty ? "所有标签" : "搜索结果") {
                    let filtered = sortedTags.filter { 
                        searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText)
                    }
                    
                    if filtered.isEmpty && !searchText.isEmpty {
                        Button {
                            addNewTag(searchText)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.dfkAccent)
                                Text("创建新标签 \"\(searchText)\"")
                                    .foregroundColor(.dfkAccent)
                            }
                        }
                    } else {
                        ForEach(filtered, id: \.self) { tag in
                            let isSelected = footprint.tags.contains(tag)
                            Button {
                                toggleTag(tag)
                            } label: {
                                HStack {
                                    Text(tag)
                                        .foregroundColor(Color.dfkMainText)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.dfkAccent)
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择标签")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索或创建新标签")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                loadRecommended()
            }
        }
    }
    
    private var sortedTags: [String] {
        allRegisteredTags.map { $0.name }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    
    private var frequentTags: [String] {
        // Calculate frequency from footprints
        let counts = allFootprints.flatMap { $0.tags }.reduce(into: [:]) { counts, tag in
            counts[tag, default: 0] += 1
        }
        return Array(counts.sorted { $0.value > $1.value }.map { $0.key }.prefix(12))
    }
    
    private func tagButton(_ name: String, isSelected: Bool) -> some View {
        Button {
            toggleTag(name)
        } label: {
            HStack(spacing: 4) {
                Text(name)
                if isSelected {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
            .foregroundColor(isSelected ? .green : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func toggleTag(_ name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3)) {
            var currentTags = footprint.tags
            if currentTags.contains(name) {
                currentTags.removeAll(where: { $0 == name })
            } else {
                currentTags.append(name)
                // Ensure it exists in global tags
                if !allRegisteredTags.contains(where: { $0.name == name }) {
                    modelContext.insert(PlaceTag(name: name))
                }
            }
            footprint.tags = currentTags
            try? modelContext.save()
        }
    }
    
    private func addNewTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        toggleTag(trimmed)
        searchText = ""
    }
    
    private func loadRecommended() {
        // Use the smarter frequency-based engine with time dimension
        let hist = TagService.shared.findHistoricalTags(
            for: footprint.latitude,
            longitude: footprint.longitude,
            targetDate: footprint.startTime,
            in: modelContext
        )
        
        withAnimation(.spring(response: 0.35)) {
            self.recommendedTags = hist
        }
    }
}
