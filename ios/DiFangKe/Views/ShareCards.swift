import SwiftUI
import UIKit
import Photos
import CoreLocation
import MapKit

private struct DFKAutoSelectingTextView: UIViewRepresentable {
    @Binding var text: String
    let selectionRequest: UUID

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        guard context.coordinator.lastSelectionRequest != selectionRequest else { return }
        context.coordinator.lastSelectionRequest = selectionRequest

        DispatchQueue.main.async {
            textView.becomeFirstResponder()
            textView.selectedTextRange = textView.textRange(
                from: textView.beginningOfDocument,
                to: textView.endOfDocument
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        var lastSelectionRequest: UUID?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

enum DFKShareCardTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case journal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .journal: return "手账"
        }
    }

    var background: Color {
        switch self {
        case .light: return Color(red: 0.97, green: 0.97, blue: 0.95)
        case .dark: return Color(red: 0.07, green: 0.08, blue: 0.09)
        case .journal: return Color(red: 0.98, green: 0.95, blue: 0.88)
        }
    }

    var foreground: Color {
        switch self {
        case .dark: return .white
        default: return Color(red: 0.12, green: 0.12, blue: 0.11)
        }
    }

    var secondary: Color {
        switch self {
        case .dark: return .white.opacity(0.68)
        default: return Color(red: 0.36, green: 0.36, blue: 0.34)
        }
    }

    var card: Color {
        switch self {
        case .dark: return .white.opacity(0.09)
        case .journal: return .white.opacity(0.58)
        default: return .white.opacity(0.72)
        }
    }

    var accent: Color {
        switch self {
        case .light: return Color.dfkAccent
        case .dark: return Color(red: 0.55, green: 0.78, blue: 1.0)
        case .journal: return Color(red: 0.66, green: 0.42, blue: 0.24)
        }
    }
}

enum DFKShareCardSize: String, CaseIterable, Identifiable {
    case square
    case portrait
    case longPortrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "方形"
        case .portrait: return "竖版"
        case .longPortrait: return "长竖版"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .square: return CGSize(width: 1080, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1440)
        case .longPortrait: return CGSize(width: 1080, height: 1920)
        }
    }
}

enum DFKShareCardKind {
    case moment
    case timeline
    case plan
    case stats
}

struct DFKShareCardPayload: Identifiable {
    var id = UUID()
    var version = UUID()
    var kind: DFKShareCardKind
    var title: String
    var subtitle: String
    var rangeText: String
    var heroImage: UIImage?
    var heroImages: [UIImage] = []
    var backgroundMapImage: UIImage?
    var backgroundMapLightImage: UIImage?
    var backgroundMapDarkImage: UIImage?
    var contentMapImage: UIImage?
    var contentMapLightImage: UIImage?
    var contentMapDarkImage: UIImage?
    var coordinates: [CLLocationCoordinate2D] = []
    var entries: [DFKShareEntry] = []
    var plans: [DFKSharePlanEntry] = []
    var stats: [DFKShareStatEntry] = []
    var summary: String?
    var isLoading: Bool = false
    var brandName: String = "地方客"
    var brandSlogan: String = "走过的地方，就是你的生活"
}

struct DFKShareEntry: Identifiable {
    let id = UUID()
    var time: String
    var title: String
    var detail: String?
    var tag: String?
    var activityIcon: String?
    var activityColor: Color?
    var coordinate: CLLocationCoordinate2D?
    var count: Int = 1
    var mergeText: String?
    var isIncluded: Bool = true
}

struct DFKSharePlanEntry: Identifiable {
    let id = UUID()
    var time: String
    var place: String
    var note: String?
    var status: String
}

struct DFKShareStatEntry: Identifiable {
    let id = UUID()
    var label: String
    var value: String
    var detail: String?
}

struct DFKShareCardPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: DFKShareCardPayload

    @State private var editablePayload: DFKShareCardPayload
    @State private var selectedTheme: DFKShareCardTheme = .light
    @State private var selectedSize: DFKShareCardSize = .portrait
    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var showingShareSheet = false
    @State private var editingText = ""
    @State private var editingCommit: ((String) -> Void)?
    @State private var showingTextEditor = false
    @State private var timelineTitleWasEdited = false
    @State private var isGeneratingShareTitle = false
    @State private var editingSelectionRequest = UUID()
    @AppStorage("isAiAssistantEnabled") private var isAiAssistantEnabled = false
    @State private var showingAINotEnabledAlert = false
    @State private var hasRequestedAutomaticShareTitle = false
    @State private var isShareTitleBreathing = false

    init(payload: DFKShareCardPayload) {
        self.payload = payload
        _editablePayload = State(initialValue: payload)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let availableWidth = max(1, proxy.size.width - 28)
                    let availableHeight = max(1, proxy.size.height - 12)
                    let targetSize = selectedSize.pixelSize
                    let previewScale = min(availableWidth / targetSize.width, availableHeight / targetSize.height)
                    let previewWidth = targetSize.width * previewScale
                    let previewHeight = targetSize.height * previewScale

                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        if editablePayload.isLoading {
                            ProgressView("正在生成分享卡片...")
                                .controlSize(.large)
                                .foregroundStyle(.secondary)
                        } else {
                            ZStack(alignment: .topLeading) {
                                DFKShareCardView(
                                    payload: editablePayload,
                                    theme: selectedTheme,
                                    size: selectedSize,
                                    displayScale: 1
                                )
                                .frame(width: targetSize.width, height: targetSize.height, alignment: .topLeading)
                                .scaleEffect(previewScale, anchor: .topLeading)
                            }
                            .frame(width: previewWidth, height: previewHeight, alignment: .topLeading)
                            .clipped()
                            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(uiColor: .secondarySystemBackground))

                VStack(spacing: 12) {
                    titleEditorRow
                    timelineEntryPicker

                    Picker("主题", selection: $selectedTheme) {
                        ForEach(DFKShareCardTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("尺寸", selection: $selectedSize) {
                        ForEach(DFKShareCardSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        renderAndShare()
                    } label: {
                        Label(isRendering ? "生成中..." : "分享给朋友", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRendering || editablePayload.isLoading)
                }
                .padding(16)
                .background(.bar)
            }
            .navigationTitle("分享预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let renderedImage {
                    ActivityView(activityItems: [renderedImage])
                }
            }
            .sheet(isPresented: $showingTextEditor) {
                NavigationStack {
                    VStack(spacing: 12) {
                        DFKAutoSelectingTextView(
                            text: $editingText,
                            selectionRequest: editingSelectionRequest
                        )
                            .padding(.horizontal, 12)
                            .frame(height: 92)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        HStack {
                            Spacer()
                            Button {
                                generateShareTitle()
                            } label: {
                                Label(isGeneratingShareTitle ? "生成中..." : "AI 生成", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isGeneratingShareTitle)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .navigationTitle("修改文字")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                editingCommit = nil
                                showingTextEditor = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                editingCommit?(trimmed)
                                editingCommit = nil
                                showingTextEditor = false
                            }
                        }
                    }
                }
                .presentationDetents([.height(270)])
            }
            .alert("开启 AI 智能助手", isPresented: $showingAINotEnabledAlert) {
                Button("立刻开启") {
                    isAiAssistantEnabled = true
                }
                Button("暂时不用", role: .cancel) { }
            } message: {
                Text("请先在设置中开启 AI 智能辅助，才能生成分享标题。")
            }
            .onChange(of: payload.version) { _, _ in
                editablePayload = payload
                timelineTitleWasEdited = false
                requestAutomaticShareTitleIfNeeded()
            }
            .onAppear {
                requestAutomaticShareTitleIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var titleEditorRow: some View {
        if !editablePayload.isLoading {
            Button {
                beginEditing(editablePayload.title) { newText in
                    timelineTitleWasEdited = true
                    editablePayload.title = newText
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("标题")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(editablePayload.title.isEmpty ? "修改标题" : editablePayload.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .opacity(isGeneratingShareTitle && isShareTitleBreathing ? 0.42 : 1)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.dfkAccent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var timelineEntryPicker: some View {
        if editablePayload.kind == .timeline,
           !editablePayload.entries.isEmpty,
           !editablePayload.isLoading {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($editablePayload.entries) { $entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(entry.time)
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { entry.isIncluded },
                                set: { isIncluded in
                                    entry.isIncluded = isIncluded
                                    refreshAutomaticTimelineTitleIfNeeded()
                                }
                            ))
                                .labelsHidden()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if entry.id != editablePayload.entries.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .frame(maxHeight: 156)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func refreshAutomaticTimelineTitleIfNeeded() {
        guard editablePayload.kind == .timeline, !timelineTitleWasEdited else { return }
        let includedCount = editablePayload.entries.filter(\.isIncluded).count
        editablePayload.title = includedCount == 0 ? "这段时间还没有足迹" : "这段时间去了 \(includedCount) 个地方"
    }

    private func beginEditing(_ text: String, commit: @escaping (String) -> Void) {
        guard !editablePayload.isLoading else { return }
        editingText = text
        editingCommit = commit
        editingSelectionRequest = UUID()
        showingTextEditor = true
    }

    private func requestAutomaticShareTitleIfNeeded() {
        guard isAiAssistantEnabled,
              !editablePayload.isLoading,
              !hasRequestedAutomaticShareTitle else { return }
        hasRequestedAutomaticShareTitle = true
        generateShareTitle(applyDirectlyToPreview: true)
    }

    private func generateShareTitle(applyDirectlyToPreview: Bool = false) {
        guard isAiAssistantEnabled else {
            showingAINotEnabledAlert = true
            return
        }
        guard !isGeneratingShareTitle else { return }
        isGeneratingShareTitle = true
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            isShareTitleBreathing = true
        }

        let styles = ["轻松口语", "有画面感", "俏皮有梗", "简洁有力", "温暖治愈", "旅行感"]
        let facts = editablePayload.entries.map { entry in
            [entry.time, entry.title, entry.tag, entry.detail]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "｜")
        }.joined(separator: "\n")
        let plans = editablePayload.plans.map { plan in
            [plan.time, plan.place, plan.status, plan.note]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "｜")
        }.joined(separator: "\n")
        let prompt = """
        为一张地方客分享卡片写一个适合传播的中文标题。
        请随机采用“\(styles.randomElement()!)”风格，标题要自然、有记忆点，控制在 8 到 22 个字，只输出标题本身，不要引号、解释、标签或换行。标题绝对不要包含日期、年份、月份、几号、星期、今天、昨天、明天等任何日期表达。
        必须以提供的时间、地点、活动、交通等事实为依据；交通信息若没有明确提供，绝不能虚构交通方式或行程。不要编造心情、人物、事件或具体细节。不要罗列地点名称，要提炼行程的主线、最有代表性的行动或变化，用一句话概括重点。

        分享类型：\(shareKindName)
        行程时长：\(shareDurationDescription)
        行程范围（仅供判断跨度，绝不能写进标题）：\(editablePayload.rangeText)
        足迹与活动：
        \(facts.isEmpty ? "无" : facts)
        计划：
        \(plans.isEmpty ? "无" : plans)
        """

        OpenAIService.shared.getCustomSummary(prompt: prompt) { title in
            isGeneratingShareTitle = false
            isShareTitleBreathing = false
            guard let title else { return }
            let singleLineTitle = title
                .components(separatedBy: .newlines)
                .joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !singleLineTitle.isEmpty else { return }
            if applyDirectlyToPreview {
                timelineTitleWasEdited = true
                editablePayload.title = singleLineTitle
            } else {
                editingText = singleLineTitle
            }
        }
    }

    private var shareKindName: String {
        switch editablePayload.kind {
        case .moment: "单次足迹"
        case .timeline: "时间线"
        case .plan: "出行计划"
        case .stats: "生活统计"
        }
    }

    private var shareDurationDescription: String {
        let range = editablePayload.rangeText
        let isDateRange = range.contains(" - ") || range.contains("至") || range.contains("~")
        if !isDateRange {
            return "单日行程。标题必须围绕当天的主线，禁止使用“这段时间”“近期”“一段旅程”等跨日措辞。"
        }
        return "多日行程。标题应概括整段行程的主线，不能逐日或逐地点罗列。"
    }

    @MainActor
    private func renderAndShare() {
        guard !editablePayload.isLoading else { return }
        isRendering = true
        let targetSize = selectedSize.pixelSize
        let renderer = ImageRenderer(
            content: DFKShareCardView(payload: editablePayload, theme: selectedTheme, size: selectedSize)
                .frame(width: targetSize.width, height: targetSize.height)
        )
        renderer.proposedSize = ProposedViewSize(targetSize)
        renderer.scale = 1
        renderedImage = renderer.uiImage
        isRendering = false
        showingShareSheet = renderedImage != nil
    }
}

struct DFKTimelineShareRangePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    let onConfirm: (Date, Date) -> Void

    init(initialDate: Date, onConfirm: @escaping (Date, Date) -> Void) {
        let normalized = Calendar.current.startOfDay(for: min(initialDate, Date()))
        _startDate = State(initialValue: normalized)
        _endDate = State(initialValue: normalized)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "开始日期",
                        selection: $startDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束日期",
                        selection: $endDate,
                        in: startDate...Date(),
                        displayedComponents: .date
                    )
                } footer: {
                    Text("分享会包含所选日期范围内的全部足迹。")
                }
            }
            .navigationTitle("选择分享日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").dfkToolbarDismissIcon()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        let selectedStart = startDate
                        let selectedEnd = endDate
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onConfirm(selectedStart, selectedEnd)
                        }
                    } label: {
                        Image(systemName: "checkmark").dfkToolbarConfirmIcon()
                    }
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue {
                    endDate = newValue
                }
            }
        }
    }
}

struct DFKShareCardView: View {
    let payload: DFKShareCardPayload
    let theme: DFKShareCardTheme
    let size: DFKShareCardSize
    var displayScale: CGFloat = 1
    var onTextEdit: ((String, @escaping (String) -> Void) -> Void)? = nil
    var onPayloadChange: ((DFKShareCardPayload) -> Void)? = nil

    private var contentLimit: Int {
        switch size {
        case .square: return 3
        case .portrait: return 5
        case .longPortrait: return 7
        }
    }

    private var themedMapImage: UIImage? {
        switch theme {
        case .dark:
            return payload.backgroundMapDarkImage ?? payload.backgroundMapImage
        case .light, .journal:
            return payload.backgroundMapLightImage ?? payload.backgroundMapImage
        }
    }

    private var themedContentMapImage: UIImage? {
        switch theme {
        case .dark:
            return payload.contentMapDarkImage ?? payload.contentMapImage ?? themedMapImage
        case .light, .journal:
            return payload.contentMapLightImage ?? payload.contentMapImage ?? themedMapImage
        }
    }

    private var usesDarkMapStyle: Bool {
        theme == .dark
    }

    private func s(_ value: CGFloat) -> CGFloat {
        value * displayScale
    }

    private func fs(_ value: CGFloat) -> CGFloat {
        s(value * 1.12)
    }

    private var includedEntries: [DFKShareEntry] {
        payload.entries.filter(\.isIncluded)
    }

    private func onPayloadUpdate(_ updated: DFKShareCardPayload) {
        onPayloadChange?(updated)
    }

    @ViewBuilder
    private func editableText<Content: View>(
        _ text: String,
        update: @escaping (String) -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let onTextEdit {
            Button {
                onTextEdit(text, update)
            } label: {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private func updateEntry(_ id: UUID, mutate: (inout DFKShareEntry) -> Void) {
        var updated = payload
        guard let index = updated.entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated.entries[index])
        onPayloadUpdate(updated)
    }

    private func updatePlan(_ id: UUID, mutate: (inout DFKSharePlanEntry) -> Void) {
        var updated = payload
        guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated.plans[index])
        onPayloadUpdate(updated)
    }

    private func updateStat(_ id: UUID, mutate: (inout DFKShareStatEntry) -> Void) {
        var updated = payload
        guard let index = updated.stats.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated.stats[index])
        onPayloadUpdate(updated)
    }

    var body: some View {
        let cardWidth = s(size.pixelSize.width)
        let cardHeight = s(size.pixelSize.height)
        let inset: CGFloat = s(size == .square ? 58 : 68)
        let verticalGap: CGFloat = s(size == .square ? 20 : 28)
        let qrSide: CGFloat = s(144)

        ZStack {
            theme.background
                .frame(width: cardWidth, height: cardHeight)
            mapBackground(cardWidth: cardWidth, cardHeight: cardHeight)
            subtleBackground
                .frame(width: cardWidth, height: cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                if size == .longPortrait {
                    Spacer(minLength: s(24))
                        .frame(height: s(24))
                } else {
                    Spacer(minLength: verticalGap)
                }
                mainContent
                Spacer(minLength: 0)
            }
            .padding(.top, inset)
            .padding(.horizontal, inset)
            // Keep share content above the footer and QR-code branding area.
            .padding(.bottom, inset + s(220))
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
            .clipped()

            VStack {
                Spacer()
                footer
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
            }
            .frame(width: cardWidth, height: cardHeight)

            qrCode
                .frame(width: qrSide, height: qrSide)
                .position(
                    x: cardWidth - inset - qrSide / 2,
                    y: cardHeight - inset - qrSide / 2
                )
                .zIndex(10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 0))
        .clipped()
    }

    @ViewBuilder
    private func mapBackground(cardWidth: CGFloat, cardHeight: CGFloat) -> some View {
        if let image = themedMapImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: cardHeight)
                .opacity(theme == .journal ? 0.16 : (usesDarkMapStyle ? 0.30 : 0.38))
                .overlay(theme.background.opacity(theme == .journal ? 0.68 : (usesDarkMapStyle ? 0.54 : 0.42)))
                .blur(radius: s(1.2))
                .clipped()
        } else if !payload.coordinates.isEmpty {
            DFKShareMapFallbackView(coordinates: payload.coordinates, theme: theme)
                .frame(width: cardWidth, height: cardHeight)
                .opacity(theme == .journal ? 0.10 : (usesDarkMapStyle ? 0.18 : 0.22))
                .overlay(theme.background.opacity(theme == .journal ? 0.72 : (usesDarkMapStyle ? 0.64 : 0.52)))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: s(16)) {
            Text(payload.rangeText)
                .font(.system(size: fs(40), weight: .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            editableText(payload.title, update: { newText in
                var updated = payload
                updated.title = newText
                onPayloadUpdate(updated)
            }) {
                Text(payload.title)
                    .font(.system(size: fs(84), weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch payload.kind {
        case .moment:
            momentContent
        case .timeline:
            timelineContent
        case .plan:
            planContent
        case .stats:
            statsContent
        }
    }

    private var momentContent: some View {
        VStack(alignment: .leading, spacing: s(30)) {
            mediaBlock(height: s(size == .square ? 380 : 500))
            entryList(payload.entries.prefix(3).map { $0 })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: s(28)) {
            mediaBlock(height: s(timelineMediaHeight))
            entryList(Array(includedEntries.prefix(timelineEntryLimit)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineEntryLimit: Int {
        switch size {
        case .square: return 3
        case .portrait, .longPortrait: return 4
        }
    }

    private var timelineMediaHeight: CGFloat {
        switch size {
        case .square: return 260
        case .portrait: return 340
        case .longPortrait: return 480
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: s(20)) {
            ForEach(Array(payload.plans.prefix(contentLimit))) { plan in
                HStack(alignment: .top, spacing: s(20)) {
                    editableText(plan.time, update: { newText in
                        updatePlan(plan.id) { $0.time = newText }
                    }) {
                        Text(plan.time)
                            .font(.system(size: fs(27), weight: .medium).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                            .frame(width: s(118), alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: s(8)) {
                        HStack(alignment: .firstTextBaseline, spacing: s(12)) {
                            editableText(plan.place, update: { newText in
                                updatePlan(plan.id) { $0.place = newText }
                            }) {
                                Text(plan.place)
                                    .font(.system(size: fs(34), weight: .semibold))
                                    .foregroundStyle(theme.foreground)
                                    .lineLimit(2)
                            }
                            editableText(plan.status, update: { newText in
                                updatePlan(plan.id) { $0.status = newText }
                            }) {
                                Text(plan.status)
                                    .font(.system(size: fs(22), weight: .medium))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, s(14))
                                    .padding(.vertical, s(7))
                                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                            }
                        }
                        if let note = plan.note, !note.isEmpty {
                            editableText(note, update: { newText in
                                updatePlan(plan.id) { $0.note = newText }
                            }) {
                                Text(note)
                                    .font(.system(size: fs(27), weight: .regular))
                                    .foregroundStyle(theme.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(s(24))
                .background(RoundedRectangle(cornerRadius: s(18)).fill(theme.card))
            }
        }
    }

    private var statsContent: some View {
        VStack(alignment: .leading, spacing: s(28)) {
            if let summary = payload.summary {
                editableText(summary, update: { newText in
                    var updated = payload
                    updated.summary = newText
                    onPayloadUpdate(updated)
                }) {
                    Text(summary)
                        .font(.system(size: fs(42), weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineSpacing(s(8))
                        .padding(s(30))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: s(22)).fill(theme.card))
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: s(18)) {
                ForEach(payload.stats.prefix(contentLimit)) { stat in
                    VStack(alignment: .leading, spacing: s(10)) {
                        editableText(stat.label, update: { newText in
                            updateStat(stat.id) { $0.label = newText }
                        }) {
                            Text(stat.label)
                                .font(.system(size: fs(24), weight: .medium))
                                .foregroundStyle(theme.secondary)
                        }
                        editableText(stat.value, update: { newText in
                            updateStat(stat.id) { $0.value = newText }
                        }) {
                            Text(stat.value)
                                .font(.system(size: fs(48), weight: .bold))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        if let detail = stat.detail {
                            editableText(detail, update: { newText in
                                updateStat(stat.id) { $0.detail = newText }
                            }) {
                                Text(detail)
                                    .font(.system(size: fs(22)))
                                    .foregroundStyle(theme.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(s(24))
                    .background(RoundedRectangle(cornerRadius: s(18)).fill(theme.card))
                }
            }
        }
    }

    private func mediaBlock(height: CGFloat) -> some View {
        ZStack {
            if payload.heroImages.count > 1 {
                DFKSharePhotoStackView(images: Array(payload.heroImages.prefix(10)), theme: theme)
                    .frame(height: height)
            } else if let image = payload.heroImages.first ?? payload.heroImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            } else if let image = themedContentMapImage {
                shareMapImageLayer(image: image, height: height)
            } else {
                shareMapFallbackLayer(height: height)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: s(28)))
        .overlay(RoundedRectangle(cornerRadius: s(28)).stroke(.white.opacity(usesDarkMapStyle ? 0.08 : 0.35), lineWidth: max(1, s(1))))
        .clipped()
    }

    private func shareMapImageLayer(image: UIImage, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(height: height)
    }

    private func shareMapFallbackLayer(height: CGFloat) -> some View {
        DFKShareMapFallbackView(coordinates: payload.coordinates, theme: theme)
            .frame(height: height)
            .clipped()
    }

    private func entryList(_ entries: [DFKShareEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: s(20)) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(entry.activityColor ?? theme.accent)
                            .frame(width: s(36), height: s(36))
                            .overlay {
                                Image(systemName: entry.activityIcon ?? "mappin")
                                    .font(.system(size: fs(18), weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        Rectangle().fill(theme.accent.opacity(0.28)).frame(width: max(1, s(3)), height: s(66))
                    }
                    VStack(alignment: .leading, spacing: s(8)) {
                        HStack(alignment: .firstTextBaseline, spacing: s(12)) {
                            editableText(entry.time, update: { newText in
                                updateEntry(entry.id) { $0.time = newText }
                            }) {
                                Text(entry.time)
                                    .font(.system(size: fs(30), weight: .medium).monospacedDigit())
                                    .foregroundStyle(theme.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        editableText(entry.title, update: { newText in
                            updateEntry(entry.id) { $0.title = newText }
                        }) {
                            Text(entry.title)
                                .font(.system(size: fs(50), weight: .semibold))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let detail = entry.detail, !detail.isEmpty {
                            editableText(detail, update: { newText in
                                updateEntry(entry.id) { $0.detail = newText }
                            }) {
                                Text(detail)
                                    .font(.system(size: fs(36)))
                                    .foregroundStyle(theme.secondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.76)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, s(20))
            }
        }
        .padding(s(28))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: s(22)).fill(theme.card))
    }

    private var footer: some View {
        HStack(spacing: s(24)) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: s(92), height: s(92))
                .clipShape(RoundedRectangle(cornerRadius: s(22)))
            VStack(alignment: .leading, spacing: s(8)) {
                editableText(payload.brandName, update: { newText in
                    var updated = payload
                    updated.brandName = newText
                    onPayloadUpdate(updated)
                }) {
                    Text(payload.brandName)
                        .font(.system(size: fs(52), weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                editableText(payload.brandSlogan, update: { newText in
                    var updated = payload
                    updated.brandSlogan = newText
                    onPayloadUpdate(updated)
                }) {
                    Text(payload.brandSlogan)
                        .font(.system(size: fs(38), weight: .regular))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.trailing, s(164))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qrCode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: s(16))
                .fill(Color.white.opacity(0.98))
            if let image = UIImage(named: "ShareQRCode") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(s(9))
            } else {
                Image("ShareQRCode")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(s(9))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: s(16))
                .stroke(Color.black.opacity(0.08), lineWidth: max(1, s(1)))
        )
        .shadow(color: .black.opacity(usesDarkMapStyle ? 0.24 : 0.10), radius: s(10), x: 0, y: s(4))
    }

    private var subtleBackground: some View {
        ZStack {
            LinearGradient(
                colors: [theme.accent.opacity(usesDarkMapStyle ? 0.20 : 0.10), .clear],
                startPoint: .topTrailing,
                endPoint: .center
            )
            if theme == .journal {
                GeometryReader { proxy in
                    Path { path in
                        let step = max(1, s(54))
                        var y = step
                        while y < proxy.size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            y += step
                        }
                    }
                    .stroke(Color.black.opacity(0.045), lineWidth: max(1, s(1)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct DFKShareMapMarker {
    let coordinate: CLLocationCoordinate2D
    let tag: String?
    let title: String?
}

private struct DFKShareMapTraceOverlay: View {
    let coordinates: [CLLocationCoordinate2D]
    let markers: [DFKShareMapMarker]
    let theme: DFKShareCardTheme

    private var normalizedPoints: [CGPoint] {
        Self.normalizedPoints(for: coordinates)
    }

    private var normalizedMarkers: [CGPoint] {
        Self.normalizedPoints(for: markers.map(\.coordinate), reference: coordinates)
    }

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints.map {
                CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height)
            }
            let markerPoints = normalizedMarkers.map {
                CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height)
            }

            ZStack {
                if points.count > 1 {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(theme.accent.opacity(0.92), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .shadow(color: .white.opacity(theme == .dark ? 0.12 : 0.55), radius: 3, x: 0, y: 0)
                }

                ForEach(Array(markerPoints.enumerated()), id: \.offset) { index, point in
                    markerView(for: markers.indices.contains(index) ? markers[index] : nil)
                        .position(point)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private func markerView(for marker: DFKShareMapMarker?) -> some View {
        let style = markerStyle(for: marker)
        return ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground).opacity(theme == .dark ? 0.92 : 0.96))
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 2)
            Circle()
                .fill(style.color)
                .frame(width: 30, height: 30)
            Image(systemName: style.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme == .dark ? Color.black : Color.white)
        }
    }

    static func normalizedPoints(for coordinates: [CLLocationCoordinate2D]) -> [CGPoint] {
        normalizedPoints(for: coordinates, reference: coordinates)
    }

    static func normalizedPoints(for coordinates: [CLLocationCoordinate2D], reference: [CLLocationCoordinate2D]) -> [CGPoint] {
        guard !coordinates.isEmpty else {
            return [CGPoint(x: 0.28, y: 0.46), CGPoint(x: 0.58, y: 0.34), CGPoint(x: 0.72, y: 0.62)]
        }
        let validCoordinates = reference.filter { coordinate in
            CLLocationCoordinate2DIsValid(coordinate) &&
            abs(coordinate.latitude) > 0.000001 &&
            abs(coordinate.longitude) > 0.000001
        }
        let source = validCoordinates.isEmpty ? coordinates : validCoordinates
        let lats = source.map(\.latitude)
        let lons = source.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 1
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 1
        let latSpan = max(maxLat - minLat, 0.0001)
        let lonSpan = max(maxLon - minLon, 0.0001)
        return coordinates.prefix(40).map {
            CGPoint(
                x: 0.10 + (($0.longitude - minLon) / lonSpan) * 0.80,
                y: 0.10 + (1 - (($0.latitude - minLat) / latSpan)) * 0.80
            )
        }
    }

    private func markerStyle(for marker: DFKShareMapMarker?) -> (icon: String, color: Color) {
        let text = [marker?.tag, marker?.title]
            .compactMap { $0 }
            .joined(separator: " ")
        if text.contains("家") || text.contains("宅") || text.contains("居") {
            return ("house.fill", Color(red: 1.0, green: 0.80, blue: 0.05))
        }
        if text.contains("学") || text.contains("书") || text.contains("校") {
            return ("book.fill", Color(red: 0.14, green: 0.68, blue: 0.95))
        }
        if text.contains("食") || text.contains("餐") || text.contains("饭") {
            return ("fork.knife", Color(red: 1.0, green: 0.28, blue: 0.20))
        }
        if text.contains("车") || text.contains("交通") || text.contains("机场") || text.contains("站") {
            return ("car.fill", Color(red: 0.12, green: 0.78, blue: 0.86))
        }
        if text.contains("运动") || text.contains("走") || text.contains("跑") {
            return ("figure.walk", Color(red: 0.18, green: 0.78, blue: 0.38))
        }
        return ("mappin", theme.accent)
    }
}

private struct DFKShareMapFallbackView: View {
    let coordinates: [CLLocationCoordinate2D]
    let theme: DFKShareCardTheme

    private var normalizedPoints: [CGPoint] {
        DFKShareMapTraceOverlay.normalizedPoints(for: coordinates)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [theme.accent.opacity(0.20), theme.card.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Path { path in
                    let points = normalizedPoints.map { CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))

                ForEach(Array(normalizedPoints.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 24, height: 24)
                        .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                }
            }
        }
    }
}

private struct DFKSharePhotoStackView: View {
    let images: [UIImage]
    let theme: DFKShareCardTheme

    private let rotations: [Double] = [-7, 4.5, -3, 8, -5.5, 2, -8.5, 6, -1, 5]

    var body: some View {
        GeometryReader { proxy in
            let count = min(images.count, 10)
            let cardWidth = proxy.size.width * (count <= 2 ? 0.70 : (count <= 5 ? 0.56 : 0.28))
            let cardHeight = proxy.size.height * (count <= 5 ? 0.76 : 0.42)
            let positions = stackPositions(count: count, size: proxy.size)

            ZStack {
                theme.card.opacity(0.42)

                ForEach(Array(images.prefix(10).enumerated()), id: \.offset) { index, image in
                    let photoSize = fittedPhotoSize(
                        for: image,
                        maximumWidth: cardWidth,
                        maximumHeight: cardHeight
                    )
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: photoSize.width, height: photoSize.height)
                        .background(theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(theme == .dark ? 0.16 : 0.72), lineWidth: 8)
                        )
                        .shadow(color: .black.opacity(theme == .dark ? 0.30 : 0.16), radius: 18, x: 0, y: 12)
                        .rotationEffect(.degrees(rotations[index % rotations.count]))
                        .position(positions[index])
                        .zIndex(Double(index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    private func fittedPhotoSize(for image: UIImage, maximumWidth: CGFloat, maximumHeight: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maximumWidth, height: maximumHeight)
        }
        let aspectRatio = image.size.width / image.size.height
        let boundingRatio = maximumWidth / maximumHeight
        if aspectRatio > boundingRatio {
            return CGSize(width: maximumWidth, height: maximumWidth / aspectRatio)
        }
        return CGSize(width: maximumHeight * aspectRatio, height: maximumHeight)
    }

    private func stackPositions(count: Int, size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        switch count {
        case 1:
            return [center]
        case 2:
            return [
                CGPoint(x: size.width * 0.38, y: size.height * 0.52),
                CGPoint(x: size.width * 0.62, y: size.height * 0.46)
            ]
        case 3:
            return [
                CGPoint(x: size.width * 0.32, y: size.height * 0.52),
                CGPoint(x: size.width * 0.58, y: size.height * 0.44),
                CGPoint(x: size.width * 0.48, y: size.height * 0.60)
            ]
        default:
            if count > 5 {
                let scatteredPoints: [(CGFloat, CGFloat)] = [
                    (0.18, 0.24), (0.49, 0.17), (0.79, 0.31),
                    (0.32, 0.45), (0.67, 0.51), (0.13, 0.68),
                    (0.50, 0.67), (0.84, 0.73), (0.27, 0.87),
                    (0.68, 0.88)
                ]
                return scatteredPoints.prefix(count).map { point in
                    CGPoint(x: size.width * point.0, y: size.height * point.1)
                }
            }
            return [
                CGPoint(x: size.width * 0.30, y: size.height * 0.54),
                CGPoint(x: size.width * 0.52, y: size.height * 0.42),
                CGPoint(x: size.width * 0.70, y: size.height * 0.55),
                CGPoint(x: size.width * 0.42, y: size.height * 0.64),
                CGPoint(x: size.width * 0.62, y: size.height * 0.68)
            ]
        }
    }
}

enum DFKShareCardFactory {
    static func loadingPayload(kind: DFKShareCardKind, rangeText: String, coordinates: [CLLocationCoordinate2D] = []) -> DFKShareCardPayload {
        DFKShareCardPayload(
            kind: kind,
            title: "",
            subtitle: "",
            rangeText: rangeText,
            coordinates: coordinates,
            isLoading: true
        )
    }

    static func momentPayload(footprint: Footprint, activities: [ActivityType], images: [UIImage], mapImage: UIImage?, lightMapImage: UIImage? = nil, darkMapImage: UIImage? = nil) -> DFKShareCardPayload {
        let place = displayPlace(for: footprint)
        let activity = footprint.getActivityType(from: activities)
        let entry = DFKShareEntry(
            time: timeRange(footprint.startTime, footprint.endTime),
            title: place,
            detail: footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
            tag: activity?.name,
            activityIcon: activity?.icon,
            activityColor: activity?.color,
            coordinate: CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
        )
        return DFKShareCardPayload(
            kind: .moment,
            title: place,
            subtitle: "这一刻，被认真留了下来",
            rangeText: dateText(footprint.startTime),
            heroImage: images.first,
            heroImages: images,
            backgroundMapImage: mapImage,
            backgroundMapLightImage: lightMapImage,
            backgroundMapDarkImage: darkMapImage,
            coordinates: footprint.coordinates,
            entries: [entry],
            summary: nil
        )
    }

    static func timelinePayload(date: Date, items: [TimelineItem], activities: [ActivityType], images: [UIImage], mapImage: UIImage?, lightMapImage: UIImage? = nil, darkMapImage: UIImage? = nil) -> DFKShareCardPayload {
        let footprints = items.compactMap { item -> Footprint? in
            if case .footprint(let footprint) = item { return footprint }
            return nil
        }.sorted { $0.startTime < $1.startTime }
        return timelinePayload(rangeText: dateText(date), footprints: footprints, activities: activities, images: images, mapImage: mapImage, lightMapImage: lightMapImage, darkMapImage: darkMapImage)
    }

    static func timelinePayload(rangeText: String, footprints: [Footprint], activities: [ActivityType], images: [UIImage], mapImage: UIImage?, lightMapImage: UIImage? = nil, darkMapImage: UIImage? = nil) -> DFKShareCardPayload {
        let sortedFootprints = footprints.sorted { $0.startTime < $1.startTime }
        let entries = mergedEntries(from: sortedFootprints, activities: activities)
        let title = entries.isEmpty ? "这段时间还没有足迹" : "这段时间去了 \(entries.count) 个地方"
        return DFKShareCardPayload(
            kind: .timeline,
            title: title,
            subtitle: "我这一段时间去了哪里",
            rangeText: rangeText,
            heroImage: images.first,
            heroImages: images,
            backgroundMapImage: mapImage,
            backgroundMapLightImage: lightMapImage,
            backgroundMapDarkImage: darkMapImage,
            coordinates: sortedFootprints.flatMap(\.coordinates),
            entries: entries
        )
    }

    static func rangeText(from startDate: Date, to endDate: Date) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        if calendar.isDate(start, inSameDayAs: end) {
            return dateText(start)
        }
        return "\(dateText(start)) - \(dateText(end))"
    }

    static func planPayload(title: String, rangeText: String, trips: [FutureTrip]) -> DFKShareCardPayload {
        let sortedTrips = FutureTrip.dayOrdered(trips)
        return DFKShareCardPayload(
            kind: .plan,
            title: sortedTrips.isEmpty ? "暂时没有安排" : title,
            subtitle: "接下来准备做什么",
            rangeText: rangeText,
            backgroundMapImage: nil,
            coordinates: sortedTrips.map(\.coordinate),
            plans: sortedTrips.map { trip in
                DFKSharePlanEntry(
                    time: trip.hasArrivalTime ? trip.arrivalDate.formatted(date: .omitted, time: .shortened) : "计划",
                    place: trip.placeName,
                    note: trip.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: planStatus(for: trip)
                )
            }
        )
    }

    static func statsPayload(rangeText: String, footprints: [Footprint], places: [Place], activities: [ActivityType], aiSummary: String?) -> DFKShareCardPayload {
        let uniquePlaceKeys = Set(footprints.map { footprint in
            footprint.placeID?.uuidString ?? displayPlace(for: footprint)
        })
        let totalPhotos = footprints.reduce(0) { $0 + $1.photoAssetIDs.count }
        let totalHours = Int(footprints.reduce(0) { $0 + $1.duration } / 3600)
        let topPlace = topPlaceName(footprints: footprints, places: places)
        let topActivity = topActivityName(footprints: footprints, activities: activities)
        let streak = currentRecordingStreak(footprints: footprints)

        let fallbackSummary: String
        if footprints.isEmpty {
            fallbackSummary = "生活还在继续，新的足迹会慢慢留下来。"
        } else if let topPlace {
            fallbackSummary = "这段时间，你在 \(topPlace) 留下了不少生活的痕迹。"
        } else {
            fallbackSummary = "生活被一点一点留了下来。"
        }

        return DFKShareCardPayload(
            kind: .stats,
            title: "我的生活总结",
            subtitle: "每一次停留，都成为了生活的一部分",
            rangeText: rangeText,
            backgroundMapImage: nil,
            coordinates: footprints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
            stats: [
                DFKShareStatEntry(label: "足迹", value: "\(footprints.count)", detail: "次记录"),
                DFKShareStatEntry(label: "地点", value: "\(uniquePlaceKeys.count)", detail: "个生活节点"),
                DFKShareStatEntry(label: "照片", value: "\(totalPhotos)", detail: "张画面"),
                DFKShareStatEntry(label: "停留", value: "\(totalHours)", detail: "小时"),
                DFKShareStatEntry(label: "常去", value: topPlace ?? "暂无", detail: nil),
                DFKShareStatEntry(label: "偏好", value: topActivity ?? "日常", detail: nil),
                DFKShareStatEntry(label: "连续", value: "\(streak)", detail: "天记录")
            ],
            summary: aiSummary?.isEmpty == false ? aiSummary : fallbackSummary
        )
    }

    private static func displayPlace(for footprint: Footprint) -> String {
        let text = footprint.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "一个生活现场" : text
    }

    private static func mergedEntries(from footprints: [Footprint], activities: [ActivityType]) -> [DFKShareEntry] {
        struct Accumulator {
            var weightedLatitude: Double
            var weightedLongitude: Double
            var totalDuration: TimeInterval
            var firstStartTime: Date
            var lastEndTime: Date
            var representative: Footprint
            var count: Int
            var detail: String?
            var tag: String?
            var activityIcon: String?
            var activityColor: Color?
        }

        var buckets: [String: Accumulator] = [:]
        var orderedKeys: [String] = []

        for footprint in footprints.sorted(by: { $0.startTime < $1.startTime }) {
            let key = placeKey(for: footprint)
            let detail = footprint.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let activity = footprint.getActivityType(from: activities)
            let tag = activity?.name
            let weight = max(footprint.duration, 1)

            if var existing = buckets[key] {
                existing.weightedLatitude += footprint.latitude * weight
                existing.weightedLongitude += footprint.longitude * weight
                existing.totalDuration += weight
                existing.firstStartTime = min(existing.firstStartTime, footprint.startTime)
                existing.lastEndTime = max(existing.lastEndTime, footprint.endTime)
                existing.count += 1
                if footprint.duration > existing.representative.duration {
                    existing.representative = footprint
                }
                if existing.detail?.isEmpty ?? true {
                    existing.detail = detail
                }
                if existing.tag?.isEmpty ?? true {
                    existing.tag = tag
                }
                if existing.activityIcon?.isEmpty ?? true {
                    existing.activityIcon = activity?.icon
                    existing.activityColor = activity?.color
                }
                buckets[key] = existing
            } else {
                orderedKeys.append(key)
                buckets[key] = Accumulator(
                    weightedLatitude: footprint.latitude * weight,
                    weightedLongitude: footprint.longitude * weight,
                    totalDuration: weight,
                    firstStartTime: footprint.startTime,
                    lastEndTime: footprint.endTime,
                    representative: footprint,
                    count: 1,
                    detail: detail,
                    tag: tag,
                    activityIcon: activity?.icon,
                    activityColor: activity?.color
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard let item = buckets[key] else { return nil }
            let duration = max(item.totalDuration, 1)
            return DFKShareEntry(
                time: mergedTimeText(start: item.firstStartTime, end: item.lastEndTime),
                title: displayPlace(for: item.representative),
                detail: item.detail,
                tag: item.tag,
                activityIcon: item.activityIcon,
                activityColor: item.activityColor,
                coordinate: CLLocationCoordinate2D(
                    latitude: item.weightedLatitude / duration,
                    longitude: item.weightedLongitude / duration
                ),
                count: item.count
            )
        }
    }

    private static func placeKey(for footprint: Footprint) -> String {
        let normalizedName = displayPlace(for: footprint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        if !normalizedName.isEmpty, normalizedName != "一个生活现场" {
            return normalizedName
        }
        if let placeID = footprint.placeID {
            return placeID.uuidString
        }
        return String(format: "%.5f,%.5f", footprint.latitude, footprint.longitude)
    }

    private static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
    }

    private static func mergedTimeText(start: Date, end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            if abs(end.timeIntervalSince(start)) < 60 {
                return start.formatted(date: .omitted, time: .shortened)
            }
            return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(start.formatted(.dateTime.month().day().hour().minute())) - \(end.formatted(.dateTime.month().day().hour().minute()))"
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    private static func planStatus(for trip: FutureTrip) -> String {
        if trip.isCompleted { return "已完成" }
        let now = Date()
        if trip.hasArrivalTime, abs(trip.arrivalDate.timeIntervalSince(now)) < 3600 {
            return "进行中"
        }
        return "未开始"
    }

    private static func topPlaceName(footprints: [Footprint], places: [Place]) -> String? {
        var counts: [String: Int] = [:]
        for footprint in footprints {
            if let placeID = footprint.placeID, let place = places.first(where: { $0.placeID == placeID }) {
                counts[place.name, default: 0] += 1
            } else {
                let name = displayPlace(for: footprint)
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.first?.key
    }

    private static func topActivityName(footprints: [Footprint], activities: [ActivityType]) -> String? {
        var counts: [String: Int] = [:]
        for footprint in footprints {
            guard let name = footprint.getActivityType(from: activities)?.name else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.first?.key
    }

    private static func currentRecordingStreak(footprints: [Footprint]) -> Int {
        let days = Set(footprints.map { Calendar.current.startOfDay(for: $0.startTime) })
        guard !days.isEmpty else { return 0 }
        var cursor = Calendar.current.startOfDay(for: Date())
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}

struct DFKShareMedia {
    var images: [UIImage]
    var mapImage: UIImage?
    var lightMapImage: UIImage?
    var darkMapImage: UIImage?
    var backgroundMapImage: UIImage?
    var backgroundLightMapImage: UIImage?
    var backgroundDarkMapImage: UIImage?
}

private struct DFKShareMapSnapshotMarker {
    let coordinate: CLLocationCoordinate2D
    let iconName: String
    let color: UIColor
    let duration: TimeInterval
}

enum DFKShareImageLoader {
    static func loadShareMedia(
        assetIDs: [String],
        coordinates: [CLLocationCoordinate2D],
        footprints: [Footprint] = [],
        transports: [TransportRecord] = [],
        widgetDate: Date? = nil,
        activities: [ActivityType] = [],
        completion: @escaping (DFKShareMedia) -> Void
    ) {
        let selectedAssetIDs = Array(NSOrderedSet(array: assetIDs).array.compactMap { $0 as? String }.shuffled().prefix(10))
        let group = DispatchGroup()
        let lock = NSLock()
        var loadedImages: [(String, UIImage)] = []
        var mapImage: UIImage?
        var lightMapImage: UIImage?
        var darkMapImage: UIImage?
        var backgroundMapImage: UIImage?
        var backgroundLightMapImage: UIImage?
        var backgroundDarkMapImage: UIImage?

        for assetID in selectedAssetIDs {
            group.enter()
            var didFinish = false
            PhotoService.shared.loadImage(for: assetID, targetSize: CGSize(width: 1200, height: 1200)) { image, _, _, isDegraded in
                guard !isDegraded, !didFinish else { return }
                didFinish = true
                if let image {
                    lock.lock()
                    loadedImages.append((assetID, image))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.enter()
        loadMapImages(
            coordinates: coordinates,
            footprints: footprints,
            transports: transports,
            widgetDate: widgetDate,
            activities: activities
        ) { images in
            lightMapImage = images.light
            darkMapImage = images.dark
            mapImage = images.light ?? images.dark
            group.leave()
        }

        group.enter()
        loadUnmarkedMapImages(coordinates: coordinates) { images in
            backgroundLightMapImage = images.light
            backgroundDarkMapImage = images.dark
            backgroundMapImage = images.light ?? images.dark
            group.leave()
        }

        group.notify(queue: .main) {
            let imagesByID = Dictionary(uniqueKeysWithValues: loadedImages)
            let orderedImages = selectedAssetIDs.compactMap { imagesByID[$0] }
            completion(DFKShareMedia(
                images: orderedImages,
                mapImage: mapImage,
                lightMapImage: lightMapImage,
                darkMapImage: darkMapImage,
                backgroundMapImage: backgroundMapImage,
                backgroundLightMapImage: backgroundLightMapImage,
                backgroundDarkMapImage: backgroundDarkMapImage
            ))
        }
    }

    static func loadMapImage(coordinates: [CLLocationCoordinate2D], completion: @escaping (UIImage?) -> Void) {
        loadMapSnapshot(coordinates: coordinates, completion: completion)
    }

    private static func loadUnmarkedMapImages(
        coordinates: [CLLocationCoordinate2D],
        completion: @escaping ((light: UIImage?, dark: UIImage?)) -> Void
    ) {
        let validCoordinates = coordinates.filter { CLLocationCoordinate2DIsValid($0) && abs($0.latitude) > 0.000001 && abs($0.longitude) > 0.000001 }
        guard !validCoordinates.isEmpty else {
            completion((nil, nil))
            return
        }
        Task {
            async let light = makeMapSnapshot(coordinates: validCoordinates, markers: [], style: .light, drawsFootprintOverlays: false)
            async let dark = makeMapSnapshot(coordinates: validCoordinates, markers: [], style: .dark, drawsFootprintOverlays: false)
            let images = await (light, dark)
            await MainActor.run {
                completion(images)
            }
        }
    }

    static func loadMapImages(
        coordinates: [CLLocationCoordinate2D],
        footprints: [Footprint] = [],
        transports: [TransportRecord] = [],
        widgetDate: Date? = nil,
        activities: [ActivityType] = [],
        completion: @escaping ((light: UIImage?, dark: UIImage?)) -> Void
    ) {
        if let widgetDate, let offset = widgetOffset(for: widgetDate) {
            Task {
                let images = await WidgetDataSyncManager.shared.snapshotImagesForOffset(offset)
                if images.light != nil || images.dark != nil {
                    await MainActor.run {
                        completion(images)
                    }
                    return
                }

                let generated = await WidgetDataSyncManager.shared.makeShareMapSnapshots(
                    footprints: footprints,
                    transports: transports,
                    activities: activities
                )
                await MainActor.run {
                    completion(generated)
                }
            }
            return
        }

        if !footprints.isEmpty || !transports.isEmpty {
            Task {
                let images = await WidgetDataSyncManager.shared.makeShareMapSnapshots(
                    footprints: footprints,
                    transports: transports,
                    activities: activities
                )
                await MainActor.run {
                    completion(images)
                }
            }
            return
        }

        loadMapImages(
            coordinates: coordinates,
            markers: snapshotMarkers(from: footprints, activities: activities),
            completion: completion
        )
    }

    private static func widgetOffset(for date: Date) -> Int? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        guard let offset = calendar.dateComponents([.day], from: today, to: target).day,
              (-6 ... 0).contains(offset) else {
            return nil
        }
        return offset
    }

    private static func loadMapImages(
        coordinates: [CLLocationCoordinate2D],
        markers: [DFKShareMapSnapshotMarker],
        completion: @escaping ((light: UIImage?, dark: UIImage?)) -> Void
    ) {
        let validCoordinates = coordinates.filter { coordinate in
            CLLocationCoordinate2DIsValid(coordinate) &&
            abs(coordinate.latitude) > 0.000001 &&
            abs(coordinate.longitude) > 0.000001
        }
        guard !validCoordinates.isEmpty else {
            completion((nil, nil))
            return
        }

        Task {
            async let light = makeMapSnapshot(coordinates: validCoordinates, markers: markers, style: .light)
            async let dark = makeMapSnapshot(coordinates: validCoordinates, markers: markers, style: .dark)
            let images = await (light, dark)
            await MainActor.run {
                completion(images)
            }
        }
    }

    static func loadHeroImage(assetIDs: [String], coordinates: [CLLocationCoordinate2D], completion: @escaping (UIImage?) -> Void) {
        loadShareMedia(assetIDs: assetIDs, coordinates: coordinates) { media in
            completion(media.images.first ?? media.mapImage)
        }
    }

    static func loadFirstImage(assetIDs: [String], completion: @escaping (UIImage?) -> Void) {
        loadHeroImage(assetIDs: assetIDs, coordinates: [], completion: completion)
    }

    private static func loadMapSnapshot(coordinates: [CLLocationCoordinate2D], completion: @escaping (UIImage?) -> Void) {
        let validCoordinates = coordinates.filter { coordinate in
            CLLocationCoordinate2DIsValid(coordinate) &&
            abs(coordinate.latitude) > 0.000001 &&
            abs(coordinate.longitude) > 0.000001
        }
        guard !validCoordinates.isEmpty else {
            completion(nil)
            return
        }

        Task {
            let image = await makeMapSnapshot(coordinates: validCoordinates, markers: [])
            await MainActor.run {
                completion(image)
            }
        }
    }

    private static func makeMapSnapshot(
        coordinates: [CLLocationCoordinate2D],
        markers: [DFKShareMapSnapshotMarker],
        style: UIUserInterfaceStyle = .unspecified,
        drawsFootprintOverlays: Bool = true
    ) async -> UIImage? {
        guard let region = snapshotRegion(for: coordinates) else { return nil }

        let size = CGSize(width: 1200, height: 720)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = await MainActor.run { UIScreen.main.scale }
        options.mapType = .mutedStandard
        options.showsBuildings = true
        options.pointOfInterestFilter = .includingAll
        if style != .unspecified {
            options.traitCollection = UITraitCollection(userInterfaceStyle: style)
        }

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let format = UIGraphicsImageRendererFormat()
            format.scale = snapshot.image.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)

            return renderer.image { context in
                snapshot.image.draw(at: .zero)
                if drawsFootprintOverlays {
                    drawPath(coordinates: coordinates, snapshot: snapshot, in: context.cgContext)
                    if markers.isEmpty {
                        drawEndpointMarkers(coordinates: coordinates, snapshot: snapshot, in: context.cgContext)
                    } else {
                        drawFootprintMarkers(markers: markers, snapshot: snapshot, style: style, in: context.cgContext)
                    }
                }
            }
        } catch {
            return nil
        }
    }

    private static func snapshotMarkers(from footprints: [Footprint], activities: [ActivityType]) -> [DFKShareMapSnapshotMarker] {
        var seen = Set<String>()
        return footprints.sorted { $0.startTime < $1.startTime }.compactMap { footprint in
            let coordinate = CLLocationCoordinate2D(latitude: footprint.latitude, longitude: footprint.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate),
                  abs(coordinate.latitude) > 0.000001,
                  abs(coordinate.longitude) > 0.000001 else { return nil }
            let key = snapshotMarkerKey(for: footprint)
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            let activity = footprint.getActivityType(from: activities)
            return DFKShareMapSnapshotMarker(
                coordinate: coordinate,
                iconName: activity?.icon ?? FootprintIconDefaults.card,
                color: UIColor(activity?.color ?? Color.gray),
                duration: footprint.duration
            )
        }
    }

    private static func snapshotMarkerKey(for footprint: Footprint) -> String {
        if let placeID = footprint.placeID {
            return placeID.uuidString
        }
        let name = footprint.address?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased() ?? ""
        if !name.isEmpty {
            return name
        }
        return String(format: "%.5f,%.5f", footprint.latitude, footprint.longitude)
    }

    private static func snapshotRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: first,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )
        }

        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latDelta = max(0.012, (maxLat - minLat) * 2.2)
        let lonDelta = max(0.012, (maxLon - minLon) * 2.2)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private static func drawPath(coordinates: [CLLocationCoordinate2D], snapshot: MKMapSnapshotter.Snapshot, in context: CGContext) {
        guard coordinates.count > 1 else { return }
        let sampled = sample(coordinates, maxCount: 240)
        let points = sampled.map { snapshot.point(for: $0) }
        guard let first = points.first else { return }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(9)
        context.setStrokeColor(UIColor(Color.dfkAccent).withAlphaComponent(0.92).cgColor)
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawEndpointMarkers(coordinates: [CLLocationCoordinate2D], snapshot: MKMapSnapshotter.Snapshot, in context: CGContext) {
        let points: [CGPoint]
        if coordinates.count <= 2 {
            points = coordinates.map { snapshot.point(for: $0) }
        } else {
            points = [coordinates.first, coordinates.last].compactMap { coordinate in
                coordinate.map { snapshot.point(for: $0) }
            }
        }

        context.saveGState()
        for point in points {
            let outer = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
            let inner = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            context.setFillColor(UIColor.white.withAlphaComponent(0.95).cgColor)
            context.fillEllipse(in: outer)
            context.setFillColor(UIColor(Color.dfkAccent).cgColor)
            context.fillEllipse(in: inner)
        }
        context.restoreGState()
    }

    private static func drawFootprintMarkers(
        markers: [DFKShareMapSnapshotMarker],
        snapshot: MKMapSnapshotter.Snapshot,
        style: UIUserInterfaceStyle,
        in context: CGContext
    ) {
        let iconColor: UIColor = style == .dark ? .black : .white
        let scale: CGFloat = 2.2
        let markerSize = 20 * scale
        let iconSize = 23 * scale * 0.52
        let radius = markerSize / 2

        context.saveGState()
        for marker in markers.prefix(12) {
            let point = snapshot.point(for: marker.coordinate)
            let center = CGPoint(x: point.x, y: point.y - radius * 1.4)

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 3), blur: 5, color: UIColor.black.withAlphaComponent(0.22).cgColor)

            let pinPath = CGMutablePath()
            pinPath.addArc(center: center, radius: radius, startAngle: 125 * .pi / 180, endAngle: 55 * .pi / 180, clockwise: false)
            pinPath.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.4))
            pinPath.closeSubpath()

            context.setFillColor(marker.color.cgColor)
            context.addPath(pinPath)
            context.fillPath()
            context.restoreGState()

            if let iconImage = UIImage(systemName: marker.iconName) {
                let image = iconImage.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                image.draw(in: CGRect(
                    x: center.x - iconSize / 2,
                    y: center.y - iconSize / 2,
                    width: iconSize,
                    height: iconSize
                ))
            }

            if marker.duration >= AppConfig.shared.stayDurationThreshold {
                drawDurationBadge(
                    duration: marker.duration,
                    color: marker.color,
                    center: center,
                    radius: radius,
                    scale: scale,
                    in: context
                )
            }
        }
        context.restoreGState()
    }

    private static func drawDurationBadge(
        duration: TimeInterval,
        color: UIColor,
        center: CGPoint,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let minutes = max(1, Int(duration / 60))
        let text: String
        if minutes >= 60 {
            let hours = Double(minutes) / 60
            text = hours >= 10 ? "\(Int(hours))小时" : String(format: "%.1f小时", hours)
        } else {
            text = "\(minutes)分钟"
        }

        let darkerColor: UIColor = {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: min(s * 1.1, 1), brightness: max(b - 0.30, 0), alpha: a)
        }()
        let font = UIFont.systemFont(ofSize: 6.2 * scale, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: darkerColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let badgeWidth = textSize.width + 8
        let badgeHeight = textSize.height + 4
        let badgeY = center.y + radius - badgeHeight / 2 - 6 * scale
        let badgeRect = CGRect(x: center.x - badgeWidth / 2, y: badgeY, width: badgeWidth, height: badgeHeight)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 4)

        UIColor.systemBackground.setFill()
        badgePath.fill()
        color.setStroke()
        badgePath.lineWidth = 0.8 * scale
        badgePath.stroke()
        attributed.draw(in: CGRect(
            x: center.x - textSize.width / 2,
            y: badgeY + (badgeHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        ))
    }

    private static func sample(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxCount else { return coordinates }
        let stride = Double(coordinates.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { index in
            coordinates[min(coordinates.count - 1, Int((Double(index) * stride).rounded()))]
        }
    }
}
