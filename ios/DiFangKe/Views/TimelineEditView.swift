import SwiftUI
import MapKit
import SwiftData
import UIKit

struct BoundaryLongPressDragArea: UIViewRepresentable {
    let minimumPressDuration: TimeInterval
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        recognizer.minimumPressDuration = minimumPressDuration
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.parent.onEnded()
    }
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BoundaryLongPressDragArea
        private var startLocation: CGPoint = .zero
        
        init(parent: BoundaryLongPressDragArea) {
            self.parent = parent
        }
        
        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view?.window)
            
            switch recognizer.state {
            case .began:
                startLocation = location
                parent.onBegan()
            case .changed:
                parent.onChanged(location.y - startLocation.y)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct NavigationSwipeBackDisabler: UIViewControllerRepresentable {
    let isDisabled: Bool
    
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = !isDisabled
        }
    }
}

// A custom scroll view that allows precise, continuous two-way programmatic scrolling
struct ControllableScrollView<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGFloat
    var updateIdentifier: Int
    var viewportHeight: CGFloat
    var isScrollEnabled: Bool
    var content: () -> Content
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = UIColor.systemGray6 // 左侧无卡片的背景用灰色
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.isScrollEnabled = isScrollEnabled
        
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        
        context.coordinator.hostingController = host
        context.coordinator.lastUpdateIdentifier = updateIdentifier
        return scrollView
    }
    
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if uiView.isScrollEnabled != isScrollEnabled {
            uiView.isScrollEnabled = isScrollEnabled
        }
        
        if context.coordinator.lastUpdateIdentifier != updateIdentifier || context.coordinator.lastViewportHeight != viewportHeight {
            context.coordinator.hostingController?.rootView = content()
            context.coordinator.lastUpdateIdentifier = updateIdentifier
            context.coordinator.lastViewportHeight = viewportHeight
            context.coordinator.hostingController?.view.setNeedsLayout()
        }
        
        // Prevent recursive updates by checking if we are actively dragging
        if abs(uiView.contentOffset.y - contentOffset) > 1.0 && !uiView.isDragging && !uiView.isDecelerating {
            let maxOffset = max(0, uiView.contentSize.height - uiView.bounds.height)
            let safeOffset = min(max(0, contentOffset), maxOffset)
            uiView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ControllableScrollView
        var hostingController: UIHostingController<Content>?
        var lastUpdateIdentifier: Int = 0
        var lastViewportHeight: CGFloat = -1
        
        init(_ parent: ControllableScrollView) {
            self.parent = parent
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isDragging || scrollView.isDecelerating {
                DispatchQueue.main.async {
                    self.parent.contentOffset = scrollView.contentOffset.y
                }
            }
        }
    }
}

struct TimelineEditView: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let timelineItems: [TimelineItem]
    
    @Query(sort: [SortDescriptor(\ActivityType.sortOrder), SortDescriptor(\ActivityType.name)]) private var allActivities: [ActivityType]
    @Environment(\.modelContext) private var modelContext
    
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedTime: Date = Date()
    @State private var selectedCoordinate: CLLocationCoordinate2D? = nil
    @State private var coordinateUpdateTask: Task<Void, Never>? = nil
    @State private var lastDragMapFocusUpdate: Date = .distantPast
    @State private var timelineUpdateIdentifier: Int = 0
    @State private var timelineLayoutIdentifier: Int = 0
    @State private var editableTimelineItems: [TimelineItem] = []
    @State private var hasInitializedEditableItems: Bool = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var hasStagedStructuralChanges: Bool = false
    @State private var showsUnsavedExitConfirmation: Bool = false
    @State private var showsDeleteConfirmation: Bool = false
    @State private var showsResetConfirmation: Bool = false
    @State private var undoStack: [EditorSnapshot] = []
    @State private var redoStack: [EditorSnapshot] = []
    @State private var pendingDragSnapshot: EditorSnapshot? = nil
    
    @State private var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    // Viewport and layout
    @State private var viewportHeight: CGFloat = 0
    @State private var leftContentHeight: CGFloat = 0
    
    // Drag boundary state
    @State private var draggingBoundaryIndex: Int? = nil
    @State private var activeDragIndex: Int? = nil
    @State private var boundaryTimeOffsets: [Int: TimeInterval] = [:] // key: index of top item
    @State private var boundaryPixelOffsets: [Int: CGFloat] = [:] // visual offset for each editable boundary
    @State private var dragInitialPixelOffset: CGFloat = 0
    @State private var dragLastFocusedTime: Date? = nil
    
    // Pre-calculate heights for each item to map time <-> y-offset
    @State private var itemLayouts: [ItemLayout] = []
    
    struct ItemLayout: Identifiable {
        let item: TimelineItem
        let height: CGFloat
        let startY: CGFloat
        let endY: CGFloat      // startY + height
        let startTime: Date
        let endTime: Date
        
        var id: String { item.id }
    }

    struct EditorSnapshot {
        let items: [TimelineItem]
        let selectedItemIDs: Set<String>
        let boundaryTimeOffsets: [Int: TimeInterval]
        let boundaryPixelOffsets: [Int: CGFloat]
        let hasStagedStructuralChanges: Bool
    }
    
    // Initial rows keep a minimum readable height, then grow sublinearly with duration.
    // Dragging applies visual boundary offsets on top of those initial heights.
    private let minimumTimelineDuration: TimeInterval = 300.0
    private let minCardHeight: CGFloat = 120.0
    private let compressedHeightStartMinutes: CGFloat = 60.0
    private let compressedHeightGrowth: CGFloat = 14.0
    private let minimumTimelineRowHeight: CGFloat = 48.0
    private let cardHorizontalMargin: CGFloat = 16.0
    private let cardVerticalMargin: CGFloat = 16.0
    private let cardCornerRadius: CGFloat = 16.0
    private let boundaryHandleHeight: CGFloat = 36.0
    private let boundaryHorizontalMargin: CGFloat = 24.0
    private let minimumScrollOverflow: CGFloat = 96.0
    private let editorToolbarHeight: CGFloat = 58.0
    private let editorToolbarContentBottomPadding: CGFloat = 96.0
    private let dragMapFocusUpdateInterval: TimeInterval = 0.6
    
    private var displayedTimelineItems: [TimelineItem] {
        hasInitializedEditableItems ? editableTimelineItems : timelineItems
    }
    
    private var selectedLayouts: [ItemLayout] {
        itemLayouts
            .filter { selectedItemIDs.contains($0.id) }
            .sorted { $0.startY < $1.startY }
    }
    
    private var canSplitSelection: Bool {
        guard selectedLayouts.count == 1, let layout = selectedLayouts.first else { return false }
        return layout.endTime.timeIntervalSince(layout.startTime) >= 600
    }
    
    private var canMergeSelection: Bool {
        guard selectedLayouts.count >= 2 else { return false }
        let layouts = selectedLayouts
        guard Set(layouts.map { itemMergeKind($0.item) }).count == 1 else { return false }
        let allSelectedIndexes = layouts.compactMap { selectedLayout in
            itemLayouts.firstIndex { $0.id == selectedLayout.id }
        }
        guard allSelectedIndexes.count == layouts.count else { return false }
        let sortedIndexes = allSelectedIndexes.sorted()
        return sortedIndexes.enumerated().allSatisfy { offset, index in
            index == sortedIndexes[0] + offset
        }
    }

    private var canUndo: Bool {
        !undoStack.isEmpty
    }
    
    private var canRedo: Bool {
        !redoStack.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Map
            TimelineEditMapView(
                cameraPosition: $cameraPosition,
                timelineItems: displayedTimelineItems,
                selectedTimeCoordinate: selectedCoordinate,
                timelineUpdateIdentifier: timelineUpdateIdentifier
            )
            .equatable()
            .frame(height: 200)
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 3)
            .zIndex(1)
            
            // Bottom Area
            GeometryReader { geo in
                let mainHeight = geo.size.height
                
                ZStack(alignment: .bottom) {
                    ZStack {
                        Color(uiColor: .systemGroupedBackground)
                        
                        ScrollView(.vertical, showsIndicators: false) {
                            ZStack(alignment: .top) {
                                VStack(spacing: 0) {
                                    ForEach(Array(itemLayouts.enumerated()), id: \.element.id) { index, layout in
                                        cardView(for: layout, index: index)
                                            // This frame drives ScrollView content size, so it must stay
                                            // equal to the calculated visual timeline height.
                                            .frame(height: layout.height)
                                            .id(layout.id)
                                    }
                                }
                                
                                ForEach(Array(itemLayouts.indices.dropLast()), id: \.self) { index in
                                    boundaryHandleView(index: index)
                                        .offset(y: itemLayouts[index].endY - boundaryHandleHeight / 2)
                                        .zIndex(activeDragIndex == index ? 3 : 2)
                                }
                            }
                            .frame(minHeight: mainHeight + minimumScrollOverflow, alignment: .top)
                            .padding(.bottom, editorToolbarContentBottomPadding)
                        }
                        .scrollBounceBehavior(.always, axes: .vertical)
                        .scrollDisabled(activeDragIndex != nil)
                    }
                    
                    editorToolbar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                .onAppear {
                    if !hasInitializedEditableItems {
                        editableTimelineItems = draftCopies(of: timelineItems)
                        hasInitializedEditableItems = true
                    }
                    self.viewportHeight = mainHeight
                    calculateLayouts()
                    
                    var allCoords: [CLLocationCoordinate2D] = []
                    for item in displayedTimelineItems {
                        switch item {
                        case .footprint(let fp): allCoords.append(CLLocationCoordinate2D(latitude: fp.latitude, longitude: fp.longitude))
                        case .transport(let tp): allCoords.append(contentsOf: tp.points)
                        }
                    }
                    if let region = allCoords.boundingRegion(paddingFactor: 1.4) {
                        cameraPosition = .region(region)
                    }
                    
                    let now = Date()
                    if Calendar.current.isDate(date, inSameDayAs: now) {
                        self.selectedTime = now
                    } else {
                        let latest = displayedTimelineItems.first?.endTime ?? Calendar.current.startOfDay(for: date).addingTimeInterval(43200)
                        self.selectedTime = latest
                    }
                    updateSelectedCoordinate(movesCamera: true)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea(.container, edges: .bottom))
        .background(NavigationSwipeBackDisabler(isDisabled: hasUnsavedChanges))
        .navigationTitle("时间线编辑")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        requestExit()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("返回")
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveTimelineEdits()
                } label: {
                    Image(systemName: "checkmark").dfkToolbarConfirmIcon()
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("保存")
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .alert("有未保存的更改", isPresented: $showsUnsavedExitConfirmation) {
            Button("保存并退出") {
                saveTimelineEdits()
            }
            Button("不保存退出", role: .destructive) {
                discardTimelineEdits()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后未保存的编辑会丢失。")
        }
        .alert("删除选中的卡片？", isPresented: $showsDeleteConfirmation) {
            Button("删除", role: .destructive) {
                deleteSelectedItems()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会从当前时间线隐藏。")
        }
        .alert("还原当前编辑？", isPresented: $showsResetConfirmation) {
            Button("还原", role: .destructive) {
                resetEditorState()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还原会取消未保存的时间调整和选中状态。")
        }
    }
    
    // MARK: - Logic
    
    private func calculateLayouts() {
        var currentY: CGFloat = 0
        var layouts: [ItemLayout] = []
        
        let sortedItems = displayedTimelineItems.sorted { $0.startTime > $1.startTime }
        
        for (index, item) in sortedItems.enumerated() {
            var actualStart = item.startTime
            var actualEnd = item.endTime
            
            // Start time is influenced by the top boundary (index)
            if let offset = boundaryTimeOffsets[index] {
                actualStart = actualStart.addingTimeInterval(offset)
            }
            
            // End time is influenced by the bottom boundary (index - 1)
            if index > 0, let offset = boundaryTimeOffsets[index - 1] {
                actualEnd = actualEnd.addingTimeInterval(offset)
            }
            
            if actualEnd < actualStart { actualEnd = actualStart }
            
            let isTimeEdited = (index > 0 && boundaryTimeOffsets[index - 1] != nil) || boundaryTimeOffsets[index] != nil
            let height = isTimeEdited
                ? rowHeight(forDuration: actualEnd.timeIntervalSince(actualStart), keepsInitialMinimum: false)
                : initialRowHeight(for: item)
            
            let layout = ItemLayout(
                item: item,
                height: height,
                startY: currentY,
                endY: currentY + height,
                startTime: actualStart,
                endTime: actualEnd
            )
            layouts.append(layout)
            currentY += height
        }
        
        self.itemLayouts = layouts
        self.leftContentHeight = currentY
        self.timelineLayoutIdentifier += 1
    }

    private func initialRowHeight(for item: TimelineItem) -> CGFloat {
        rowHeight(forDuration: item.endTime.timeIntervalSince(item.startTime), keepsInitialMinimum: true)
    }

    private func rowHeight(forDuration duration: TimeInterval, keepsInitialMinimum: Bool) -> CGFloat {
        let durationMinutes = max(CGFloat(minimumTimelineDuration / 60.0), CGFloat(duration / 60.0))
        if keepsInitialMinimum && durationMinutes <= compressedHeightStartMinutes {
            return minCardHeight
        }
        
        if durationMinutes < compressedHeightStartMinutes {
            let minimumMinutes = CGFloat(minimumTimelineDuration / 60.0)
            let progress = (durationMinutes - minimumMinutes) / (compressedHeightStartMinutes - minimumMinutes)
            return minimumTimelineRowHeight + max(0, min(1, progress)) * (minCardHeight - minimumTimelineRowHeight)
        }
        
        let compressedMinutes = max(0, durationMinutes - compressedHeightStartMinutes)
        return minCardHeight + sqrt(compressedMinutes) * compressedHeightGrowth
    }

    private func duration(forRowHeight height: CGFloat) -> TimeInterval {
        let minimumMinutes = CGFloat(minimumTimelineDuration / 60.0)
        let clampedHeight = max(minimumTimelineRowHeight, height)
        
        if clampedHeight < minCardHeight {
            let progress = (clampedHeight - minimumTimelineRowHeight) / (minCardHeight - minimumTimelineRowHeight)
            let minutes = minimumMinutes + max(0, min(1, progress)) * (compressedHeightStartMinutes - minimumMinutes)
            return TimeInterval(minutes * 60.0)
        }
        
        let compressedMinutes = pow((clampedHeight - minCardHeight) / compressedHeightGrowth, 2)
        return TimeInterval((compressedHeightStartMinutes + compressedMinutes) * 60.0)
    }
    
    private func updateSelectedCoordinate(for time: Date? = nil, movesCamera: Bool) {
        coordinateUpdateTask?.cancel()
        coordinateUpdateTask = Task {
            do {
                try await Task.sleep(nanoseconds: 50_000_000) // 0.05s debounce
            } catch {
                return
            }
            let items = displayedTimelineItems
            let coord = PersistentTimelineBuilder.coordinate(at: time ?? selectedTime, in: items)
            await MainActor.run {
                self.selectedCoordinate = coord
                if movesCamera, let validCoord = coord {
                    self.cameraPosition = .camera(MapCamera(centerCoordinate: validCoord, distance: 1000))
                }
            }
        }
    }

    private func updateMapFocus(for time: Date, movesCamera: Bool) {
        coordinateUpdateTask?.cancel()
        let coord = PersistentTimelineBuilder.coordinate(at: time, in: displayedTimelineItems)
        selectedCoordinate = coord
        if movesCamera, let coord {
            cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 1000))
        }
    }

    private func updateDragMapFocusIfNeeded(for time: Date) {
        let now = Date()
        guard now.timeIntervalSince(lastDragMapFocusUpdate) >= dragMapFocusUpdateInterval else {
            dragLastFocusedTime = time
            return
        }
        lastDragMapFocusUpdate = now
        dragLastFocusedTime = time
        updateMapFocus(for: time, movesCamera: true)
    }

    private func draftCopies(of items: [TimelineItem]) -> [TimelineItem] {
        items.map { item in
            switch item {
            case .footprint(let footprint):
                return .footprint(copyFootprint(footprint, footprintID: footprint.footprintID))
            case .transport(let transport):
                return .transport(transport)
            }
        }
    }

    private func copyFootprint(_ footprint: Footprint, footprintID: UUID? = nil) -> Footprint {
        let copy = Footprint(
            footprintID: footprintID ?? UUID(),
            date: footprint.date,
            startTime: footprint.startTime,
            endTime: footprint.endTime,
            footprintLocations: footprint.footprintLocations,
            locationHash: footprint.locationHash,
            duration: footprint.duration,
            reason: footprint.reason,
            status: footprint.status,
            aiScore: footprint.aiScore,
            isHighlight: footprint.isHighlight,
            placeID: footprint.placeID,
            photoAssetIDs: footprint.photoAssetIDs,
            address: footprint.address,
            isPlaceSuggestionIgnored: footprint.isPlaceSuggestionIgnored,
            aiAnalyzed: footprint.aiAnalyzed,
            isAddressEditedByHand: footprint.isAddressEditedByHand,
            activityTypeValue: footprint.activityTypeValue,
            stepCount: footprint.stepCount,
            walkingDistance: footprint.walkingDistance,
            floorsAscended: footprint.floorsAscended
        )
        copy.photoMetadata = footprint.photoMetadata
        return copy
    }

    private func makeEditorSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            items: draftCopies(of: displayedTimelineItems),
            selectedItemIDs: selectedItemIDs,
            boundaryTimeOffsets: boundaryTimeOffsets,
            boundaryPixelOffsets: boundaryPixelOffsets,
            hasStagedStructuralChanges: hasStagedStructuralChanges
        )
    }
    
    private func restoreEditorSnapshot(_ snapshot: EditorSnapshot) {
        editableTimelineItems = draftCopies(of: snapshot.items)
        selectedItemIDs = snapshot.selectedItemIDs
        boundaryTimeOffsets = snapshot.boundaryTimeOffsets
        boundaryPixelOffsets = snapshot.boundaryPixelOffsets
        hasStagedStructuralChanges = snapshot.hasStagedStructuralChanges
        calculateLayouts()
        timelineUpdateIdentifier += 1
    }
    
    private func recordUndoSnapshot(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
        redoStack = []
    }
    
    private func performUndoableEdit(_ edit: () -> Void) {
        let snapshot = makeEditorSnapshot()
        edit()
        recordUndoSnapshot(snapshot)
    }
    
    private func undoLastEdit() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeEditorSnapshot())
        restoreEditorSnapshot(snapshot)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func redoLastEdit() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeEditorSnapshot())
        restoreEditorSnapshot(snapshot)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func pointsData(for transport: Transport) -> Data {
        let coordinates = transport.pathPoints.isEmpty
            ? transport.points.map { CodableCoordinate(lat: $0.latitude, lon: $0.longitude) }
            : transport.pathPoints.map { CodableCoordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, timestamp: $0.timestamp) }
        return (try? JSONEncoder().encode(coordinates)) ?? Data()
    }
    
    // MARK: - Views
    
    private var editorToolbar: some View {
        HStack(spacing: 10) {
            editorToolbarButton(systemImage: "arrow.uturn.backward", title: "撤销", isEnabled: canUndo) {
                undoLastEdit()
            }
            editorToolbarButton(systemImage: "arrow.uturn.forward", title: "重做", isEnabled: canRedo) {
                redoLastEdit()
            }
            editorToolbarButton(systemImage: "rectangle.split.2x1", title: "拆分", isEnabled: canSplitSelection) {
                splitSelectedItem()
            }
            editorToolbarButton(systemImage: "arrow.triangle.merge", title: "合并", isEnabled: canMergeSelection) {
                mergeSelectedItems()
            }
            editorToolbarButton(systemImage: "trash", title: "删除", isEnabled: !selectedItemIDs.isEmpty, tint: .red) {
                showsDeleteConfirmation = true
            }
            
            Divider()
                .frame(height: 26)
            
            editorToolbarButton(systemImage: "arrow.counterclockwise", title: "还原", isEnabled: hasUnsavedChanges, tint: .red) {
                showsResetConfirmation = true
            }
        }
        .frame(height: editorToolbarHeight)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
    
    private var hasUnsavedTimelineOffsets: Bool {
        !boundaryTimeOffsets.isEmpty || !boundaryPixelOffsets.isEmpty
    }
    
    private var hasUnsavedChanges: Bool {
        hasUnsavedTimelineOffsets || hasStagedStructuralChanges
    }
    
    private func editorToolbarButton(
        systemImage: String,
        title: String,
        isEnabled: Bool,
        tint: Color = .dfkAccent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 44, height: 42)
            .foregroundColor(isEnabled ? tint : Color.secondary.opacity(0.45))
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func cardView(for layout: ItemLayout, index: Int) -> some View {
        let item = layout.item
        let verticalMargin = cardVerticalMargin
        let visibleCardHeight = max(0, layout.height - verticalMargin * 2)
        let isSelected = selectedItemIDs.contains(layout.id)
        
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                
                if isSelected {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(Color.dfkAccent.opacity(0.18))
                }
                
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(isSelected ? Color.dfkAccent : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                
                HStack(spacing: 12) {
                    // Icon Menu
                    Menu {
                        compactMenuContent(for: item)
                    } label: {
                        switch item {
                        case .footprint(let fp):
                            let activity = fp.getActivityType(from: allActivities)
                            Image(systemName: activity?.icon ?? "questionmark.circle.dashed")
                                .font(.system(size: 22))
                                .foregroundColor(activity?.color ?? Color.secondary)
                                .frame(width: 40, height: 40)
                        case .transport(let tp):
                            Image(systemName: tp.currentType.sfSymbol)
                                .font(.system(size: 22))
                                .foregroundColor(Color.dfkAccent)
                                .frame(width: 40, height: 40)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Title
                    switch item {
                    case .footprint(let footprint):
                        Text(footprint.address ?? "未知地点")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    case .transport(let transport):
                        Text("\(transport.startLocation) → \(transport.endLocation)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Time
                    Text(timeRangeString(start: layout.startTime, end: layout.endTime))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(height: visibleCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
            .padding(.horizontal, cardHorizontalMargin)
            .padding(.vertical, verticalMargin)
        }
        // Keep the outer row height equal to the timeline layout height.
        .frame(height: layout.height)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection(for: layout.id)
        }
        .zIndex(1)
    }
    
    private func boundaryHandleView(index: Int) -> some View {
        let isActive = activeDragIndex == index
        let topLayout = itemLayouts[index]
        let displayTime = topLayout.item.startTime.addingTimeInterval(boundaryTimeOffsets[index] ?? 0)
        
        return ZStack {
            Rectangle()
                .fill(isActive ? Color.dfkAccent : Color.gray.opacity(0.55))
                .frame(height: isActive ? 4.0 : 1.5)
                .padding(.horizontal, boundaryHorizontalMargin)
            
            if isActive {
                Text(timeFormatter.string(from: displayTime))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.dfkAccent)
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: -28)
            }
            
            Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isActive ? .white : Color.secondary)
                .padding(4)
                .background(isActive ? Color.dfkAccent : Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.clear : Color.primary.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
                .frame(maxWidth: .infinity, alignment: .center)
            
            BoundaryLongPressDragArea(
                minimumPressDuration: 0.25,
                onBegan: {
                    beginBoundaryDrag(index: index)
                },
                onChanged: { translationY in
                    updateBoundaryDrag(index: index, translationY: translationY)
                },
                onEnded: {
                    endBoundaryDrag()
                }
            )
            .frame(width: 44, height: 44)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: boundaryHandleHeight)
    }
    
    private func beginBoundaryDrag(index: Int) {
        guard index < itemLayouts.count - 1 else { return }
        activeDragIndex = index
        draggingBoundaryIndex = index
        dragInitialPixelOffset = boundaryPixelOffsets[index] ?? 0
        lastDragMapFocusUpdate = .distantPast
        dragLastFocusedTime = nil
        pendingDragSnapshot = makeEditorSnapshot()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func updateBoundaryDrag(index: Int, translationY: CGFloat) {
        guard index < itemLayouts.count - 1 else { return }
        if draggingBoundaryIndex != index {
            beginBoundaryDrag(index: index)
        }
        
        // +dy pixels moves the boundary down: top row grows,
        // bottom row shrinks, and the shared time moves earlier.
        let requestedPixelOffset = dragInitialPixelOffset + translationY
        let constrained = constrainedBoundaryOffsets(index: index, requestedPixelOffset: requestedPixelOffset)
        
        if boundaryPixelOffsets[index] != constrained.pixel || boundaryTimeOffsets[index] != constrained.time {
            boundaryPixelOffsets[index] = constrained.pixel
            boundaryTimeOffsets[index] = constrained.time
            let boundaryTime = itemLayouts[index].item.startTime.addingTimeInterval(constrained.time)
            selectedTime = boundaryTime
            updateDragMapFocusIfNeeded(for: boundaryTime)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                calculateLayouts()
            }
        }
    }
    
    private func endBoundaryDrag() {
        if let snapshot = pendingDragSnapshot,
           snapshot.boundaryTimeOffsets != boundaryTimeOffsets || snapshot.boundaryPixelOffsets != boundaryPixelOffsets {
            recordUndoSnapshot(snapshot)
        }
        pendingDragSnapshot = nil
        activeDragIndex = nil
        draggingBoundaryIndex = nil
        if let dragLastFocusedTime {
            updateMapFocus(for: dragLastFocusedTime, movesCamera: true)
        }
        dragLastFocusedTime = nil
    }

    private func constrainedBoundaryOffsets(index: Int, requestedPixelOffset: CGFloat) -> (pixel: CGFloat, time: TimeInterval) {
        let topLayout = itemLayouts[index]
        let bottomLayout = itemLayouts[index + 1]
        let topItemOriginalStart = topLayout.item.startTime
        let topItemEnd = topLayout.endTime
        let maxOffset = topItemEnd.timeIntervalSince(topItemOriginalStart) - 300
        
        let bottomItemOriginalEnd = bottomLayout.item.endTime
        let bottomItemStart = bottomLayout.startTime
        let minOffset = bottomItemStart.timeIntervalSince(bottomItemOriginalEnd) + 300
        
        let rawTimeOffset = timeOffsetForBoundaryPixelOffset(index: index, pixelOffset: requestedPixelOffset)
        let constrainedTimeOffset = min(maxOffset, max(minOffset, rawTimeOffset))
        let constrainedPixelOffset = pixelOffsetForBoundaryTimeOffset(index: index, timeOffset: constrainedTimeOffset)
        
        return (constrainedPixelOffset, constrainedTimeOffset)
    }

    private func timeOffsetForBoundaryPixelOffset(index: Int, pixelOffset: CGFloat) -> TimeInterval {
        let item = itemLayouts[index].item
        let originalDuration = item.endTime.timeIntervalSince(item.startTime)
        let initialHeight = initialRowHeight(for: item)
        let targetDuration = duration(forRowHeight: initialHeight + pixelOffset)
        return originalDuration - targetDuration
    }

    private func pixelOffsetForBoundaryTimeOffset(index: Int, timeOffset: TimeInterval) -> CGFloat {
        let item = itemLayouts[index].item
        let originalDuration = item.endTime.timeIntervalSince(item.startTime)
        let targetDuration = originalDuration - timeOffset
        return rowHeight(forDuration: targetDuration, keepsInitialMinimum: false) - initialRowHeight(for: item)
    }
    
    private func toggleSelection(for id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
            if selectedItemIDs.isEmpty {
                selectedCoordinate = nil
            }
        } else {
            selectedItemIDs.insert(id)
            if let layout = itemLayouts.first(where: { $0.id == id }) {
                let middleTime = layout.startTime.addingTimeInterval(layout.endTime.timeIntervalSince(layout.startTime) / 2.0)
                selectedTime = middleTime
                updateMapFocus(for: middleTime, movesCamera: true)
            }
        }
        timelineLayoutIdentifier += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func itemMergeKind(_ item: TimelineItem) -> String {
        switch item {
        case .footprint:
            return "footprint"
        case .transport:
            return "transport"
        }
    }
    
    private func splitSelectedItem() {
        guard canSplitSelection, let layout = selectedLayouts.first else { return }
        let snapshot = makeEditorSnapshot()
        let middleTime = layout.startTime.addingTimeInterval(layout.endTime.timeIntervalSince(layout.startTime) / 2.0)
        let originalID = layout.id
        
        switch layout.item {
        case .footprint(let footprint):
            let originalEnd = footprint.endTime
            footprint.endTime = middleTime
            footprint.status = .manual
            
            let newFootprint = copyFootprint(footprint)
            newFootprint.footprintID = UUID()
            newFootprint.date = Calendar.current.startOfDay(for: middleTime)
            newFootprint.startTime = middleTime
            newFootprint.endTime = originalEnd
            newFootprint.status = .manual
            newFootprint.photoAssetIDs = []
            replaceItem(id: originalID, with: [.footprint(footprint), .footprint(newFootprint)])
            
        case .transport(let transport):
            let first = transport.updatingTimes(start: transport.startTime, end: middleTime)
            let second = Transport(
                id: UUID(),
                startTime: middleTime,
                endTime: transport.endTime,
                startLocation: transport.startLocation,
                endLocation: transport.endLocation,
                type: transport.type,
                distance: transport.distance / 2.0,
                averageSpeed: transport.averageSpeed,
                points: transport.points,
                pathPoints: transport.pathPoints,
                manualType: transport.manualType,
                stepCount: transport.stepCount
            )
            replaceItem(id: originalID, with: [.transport(first), .transport(second)])
        }
        
        selectedItemIDs = []
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        hasStagedStructuralChanges = true
        refreshAfterStructureChange()
        recordUndoSnapshot(snapshot)
    }

    private func makePersistentFootprint(from footprint: Footprint, startTime: Date, endTime: Date) -> Footprint {
        let persistent = Footprint(
            footprintID: footprint.footprintID,
            date: Calendar.current.startOfDay(for: startTime),
            startTime: startTime,
            endTime: endTime,
            footprintLocations: footprint.footprintLocations,
            locationHash: footprint.locationHash,
            duration: endTime.timeIntervalSince(startTime),
            reason: footprint.reason,
            status: .manual,
            aiScore: footprint.aiScore,
            isHighlight: footprint.isHighlight,
            placeID: footprint.placeID,
            photoAssetIDs: footprint.photoAssetIDs,
            address: footprint.address,
            isPlaceSuggestionIgnored: footprint.isPlaceSuggestionIgnored,
            aiAnalyzed: footprint.aiAnalyzed,
            isAddressEditedByHand: footprint.isAddressEditedByHand,
            activityTypeValue: footprint.activityTypeValue,
            stepCount: footprint.stepCount,
            walkingDistance: footprint.walkingDistance,
            floorsAscended: footprint.floorsAscended
        )
        persistent.photoMetadata = footprint.photoMetadata
        return persistent
    }

    private func makePersistentTransportRecord(from transport: Transport, startTime: Date, endTime: Date) -> TransportRecord {
        let record = TransportRecord(
            recordID: transport.id,
            day: Calendar.current.startOfDay(for: startTime),
            startTime: startTime,
            endTime: endTime,
            startLocation: transport.startLocation,
            endLocation: transport.endLocation,
            typeRaw: transport.type.rawValue,
            distance: transport.distance,
            averageSpeed: transport.averageSpeed,
            pointsData: pointsData(for: transport),
            statusRaw: "active",
            stepCount: transport.stepCount
        )
        record.manualTypeRaw = transport.manualType?.rawValue
        return record
    }
    
    private func mergeSelectedItems() {
        guard canMergeSelection else { return }
        let snapshot = makeEditorSnapshot()
        let layouts = selectedLayouts
        let items = layouts.map(\.item)
        let startTime = items.map(\.startTime).min() ?? Date()
        let endTime = items.map(\.endTime).max() ?? Date()
        let selectedIDs = Set(items.map(\.id))
        
        switch items[0] {
        case .footprint(let base):
            base.startTime = startTime
            base.endTime = endTime
            base.date = Calendar.current.startOfDay(for: startTime)
            base.status = .manual
            editableTimelineItems = displayedTimelineItems.filter { !selectedIDs.contains($0.id) || $0.id == base.footprintID.uuidString }
            
        case .transport(let baseTransport):
            let merged = baseTransport.updatingTimes(start: startTime, end: endTime)
            editableTimelineItems = displayedTimelineItems
                .filter { !selectedIDs.contains($0.id) }
                + [.transport(merged)]
        }
        
        selectedItemIDs = []
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        hasStagedStructuralChanges = true
        refreshAfterStructureChange()
        recordUndoSnapshot(snapshot)
    }
    
    private func replaceItem(id: String, with replacement: [TimelineItem]) {
        var nextItems: [TimelineItem] = []
        for item in displayedTimelineItems {
            if item.id == id {
                nextItems.append(contentsOf: replacement)
            } else {
                nextItems.append(item)
            }
        }
        editableTimelineItems = nextItems
    }
    
    private func refreshAfterStructureChange() {
        editableTimelineItems.sort { $0.startTime > $1.startTime }
        timelineUpdateIdentifier += 1
        calculateLayouts()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func deleteSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }
        let snapshot = makeEditorSnapshot()
        let deletingIDs = selectedItemIDs
        editableTimelineItems = displayedTimelineItems.filter { !deletingIDs.contains($0.id) }
        selectedItemIDs = []
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        hasStagedStructuralChanges = true
        refreshAfterStructureChange()
        recordUndoSnapshot(snapshot)
    }
    
    private func resetEditorState() {
        let snapshot = makeEditorSnapshot()
        editableTimelineItems = draftCopies(of: timelineItems)
        selectedItemIDs = []
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        hasStagedStructuralChanges = false
        calculateLayouts()
        recordUndoSnapshot(snapshot)
    }
    
    private func discardTimelineEdits() {
        selectedItemIDs = []
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        hasStagedStructuralChanges = false
        undoStack = []
        redoStack = []
        pendingDragSnapshot = nil
    }
    
    private func requestExit() {
        if hasUnsavedChanges {
            showsUnsavedExitConfirmation = true
        } else {
            dismiss()
        }
    }
    
    private func saveTimelineEdits() {
        let finalIDs = Set(itemLayouts.map(\.id))
        
        for item in timelineItems where !finalIDs.contains(item.id) {
            switch item {
            case .footprint(let footprint):
                modelContext.delete(footprint)
            case .transport(let transport):
                let recordID = transport.id
                let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == recordID })
                if let record = try? modelContext.fetch(descriptor).first {
                    modelContext.delete(record)
                }
            }
        }
        
        for layout in itemLayouts {
            switch layout.item {
            case .footprint(let draft):
                if let footprint = timelineItems.compactMap({ item -> Footprint? in
                    if case .footprint(let original) = item, original.footprintID == draft.footprintID {
                        return original
                    }
                    return nil
                }).first {
                    footprint.startTime = layout.startTime
                    footprint.endTime = layout.endTime
                    footprint.date = Calendar.current.startOfDay(for: layout.startTime)
                    footprint.status = .manual
                    footprint.activityTypeValue = draft.activityTypeValue
                } else {
                    modelContext.insert(makePersistentFootprint(from: draft, startTime: layout.startTime, endTime: layout.endTime))
                }
            case .transport(let transport):
                let recordID = transport.id
                let descriptor = FetchDescriptor<TransportRecord>(predicate: #Predicate { $0.recordID == recordID })
                if let record = try? modelContext.fetch(descriptor).first {
                    record.startTime = layout.startTime
                    record.endTime = layout.endTime
                    record.day = Calendar.current.startOfDay(for: layout.startTime)
                    record.startLocation = transport.startLocation
                    record.endLocation = transport.endLocation
                    record.typeRaw = transport.type.rawValue
                    record.distance = transport.distance
                    record.averageSpeed = transport.averageSpeed
                    record.pointsData = pointsData(for: transport)
                    record.manualTypeRaw = transport.manualType?.rawValue
                    record.statusRaw = "active"
                } else {
                    modelContext.insert(makePersistentTransportRecord(from: transport, startTime: layout.startTime, endTime: layout.endTime))
                }
            }
        }
        
        try? modelContext.save()
        invalidateTimelineCachesAfterSave()
        hasStagedStructuralChanges = false
        boundaryTimeOffsets = [:]
        boundaryPixelOffsets = [:]
        undoStack = []
        redoStack = []
        pendingDragSnapshot = nil
        timelineUpdateIdentifier += 1
        NotificationCenter.default.post(
            name: NSNotification.Name("FootprintDataChanged"),
            object: nil,
            userInfo: ["date": Calendar.current.startOfDay(for: date)]
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func invalidateTimelineCachesAfterSave() {
        var dates = Set<Date>()
        for item in timelineItems {
            dates.formUnion(touchedDates(start: item.startTime, end: item.endTime))
        }
        for layout in itemLayouts {
            dates.formUnion(touchedDates(start: layout.startTime, end: layout.endTime))
        }
        dates.insert(Calendar.current.startOfDay(for: date))
        
        for date in dates {
            TimelineBuilder.timelineCache.removeValue(forKey: date)
        }
    }

    private func touchedDates(start: Date, end: Date) -> Set<Date> {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = max(start, end.addingTimeInterval(-0.001))
        let endDay = calendar.startOfDay(for: effectiveEnd)
        var result: Set<Date> = []
        var cursor = startDay
        
        while cursor <= endDay {
            result.insert(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        
        return result
    }

    private func timeRangeString(start: Date, end: Date) -> String {
        return "\(timeFormatter.string(from: start)) - \(timeFormatter.string(from: end))"
    }
    
    @ViewBuilder
    private func compactIconView(for item: TimelineItem) -> some View {
        switch item {
        case .footprint(let fp):
            let activity = fp.getActivityType(from: allActivities)
            Image(systemName: activity?.icon ?? "questionmark.circle.dashed")
                .font(.system(size: 14))
                .foregroundColor(activity?.color ?? Color.secondary)
                .frame(width: 22, height: 22)
        case .transport(let tp):
            Image(systemName: tp.currentType.sfSymbol)
                .font(.system(size: 14))
                .foregroundColor(Color.dfkAccent)
                .frame(width: 22, height: 22)
        }
    }
    
    @ViewBuilder
    private func compactMenuContent(for item: TimelineItem) -> some View {
        switch item {
        case .footprint(let fp):
            Button {
                withAnimation {
                    fp.activityTypeValue = nil
                    fp.status = .manual
                    hasStagedStructuralChanges = true
                    self.timelineUpdateIdentifier += 1
                    self.timelineLayoutIdentifier += 1
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } label: { Label("无", systemImage: "circle.slash") }
            
            ForEach(allActivities) { type in
                Button {
                    withAnimation {
                        fp.activityTypeValue = type.id.uuidString
                        fp.status = .manual
                        hasStagedStructuralChanges = true
                        self.timelineUpdateIdentifier += 1
                        self.timelineLayoutIdentifier += 1
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } label: { Label(type.name, systemImage: type.icon) }
            }
        case .transport(let tp):
            ForEach(TransportType.allCases, id: \.self) { tType in
                Button {
                    withAnimation {
                        replaceItem(id: tp.id.uuidString, with: [.transport(tp.updatingType(tType))])
                        hasStagedStructuralChanges = true
                        self.timelineUpdateIdentifier += 1
                        self.timelineLayoutIdentifier += 1
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } label: { Label(tType.localizedName, systemImage: tType.sfSymbol) }
            }
        }
    }
}

struct TimelineEditMapView: View, Equatable {
    @Binding var cameraPosition: MapCameraPosition
    let timelineItems: [TimelineItem]
    let selectedTimeCoordinate: CLLocationCoordinate2D?
    let timelineUpdateIdentifier: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.timelineUpdateIdentifier == rhs.timelineUpdateIdentifier &&
               lhs.selectedTimeCoordinate?.latitude == rhs.selectedTimeCoordinate?.latitude &&
               lhs.selectedTimeCoordinate?.longitude == rhs.selectedTimeCoordinate?.longitude
    }
    
    var body: some View {
        DFKMapView(
            cameraPosition: $cameraPosition,
            rendersLiveMap: true,
            isInteractive: true,
            showsUserLocation: false,
            timelineItems: timelineItems,
            isMiniTimelineMode: true,
            selectedTimeCoordinate: selectedTimeCoordinate,
            timelineUpdateIdentifier: timelineUpdateIdentifier
        )
    }
}
