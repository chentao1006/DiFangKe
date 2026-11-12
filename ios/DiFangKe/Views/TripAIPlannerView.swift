import SwiftUI

/// Conversation sheet for refining a planned trip with AI. Answers stream in as
/// plain text; an answer that changes the itinerary carries a preview of the
/// changes and can be applied to the trip in one tap.
struct TripAIPlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: TripAIPlannerSession
    @State private var draft = TripAIPlanner.defaultPrompt
    @State private var draftWasEdited = false
    @State private var confirmingClear = false
    @State private var pendingRemovalApply: PendingApply?
    /// While an answer streams, the list follows the newest text until the
    /// answer's top reaches the top of the screen or the user scrolls.
    @State private var followsStreaming = true
    /// Top of the visible scroll area, in global coordinates.
    @State private var viewportTop: CGFloat = 0

    private static let bottomAnchorID = "trip-ai-bottom"
    private static let streamingAnchorID = "trip-ai-streaming"
    /// How close the answer's top may come to the top of the screen before
    /// following stops.
    private static let streamingTopMargin: CGFloat = 8

    private struct PendingApply: Identifiable {
        let id: UUID
        let removalCount: Int
    }

    init(session: TripAIPlannerSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if showsEmptyState {
                            emptyState
                                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.82 }
                        }
                        ForEach(session.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if session.isStreaming {
                            streamingRow
                                .id(Self.streamingAnchorID)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.onChange(of: geometry.frame(in: .global).minY, initial: true) { _, top in
                                            stopFollowingIfAnswerReachedTop(top, proxy: proxy)
                                        }
                                    }
                                }
                        }
                        if let error = session.errorMessage {
                            errorRow(error)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.immediately)
                // A tap anywhere in the conversation, including empty space,
                // ends editing; buttons still receive the same tap.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(
                            of: geometry.frame(in: .global).minY + geometry.safeAreaInsets.top,
                            initial: true
                        ) { _, top in
                            viewportTop = top
                        }
                    }
                }
                // Same pattern as the trip timeline: a drag marks a manual scroll.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in
                        if session.isStreaming { followsStreaming = false }
                    }
                )
                .onChange(of: session.isLoaded) { _, loaded in
                    guard loaded else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: session.messages.count) { _, _ in
                    // A sent message always comes into view; a finished answer
                    // only when the list was still following it.
                    guard session.messages.last?.role == .user || followsStreaming else { return }
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: session.isStreaming) { _, streaming in
                    guard streaming else { return }
                    followsStreaming = true
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: session.streamingText) { _, _ in
                    guard followsStreaming else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: session.errorMessage) { _, value in
                    guard value != nil, followsStreaming else { return }
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("智能优化行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if !session.messages.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            confirmingClear = true
                        } label: {
                            Image(systemName: "eraser")
                        }
                        .disabled(session.isStreaming || session.applyingMessageID != nil)
                        .accessibilityLabel("清空对话记录")
                        // Anchored to the eraser button so it opens where it was tapped.
                        .confirmationDialog("清空这个行程的对话记录？", isPresented: $confirmingClear, titleVisibility: .visible) {
                            Button("清空对话记录", role: .destructive) {
                                session.clearConversation()
                                // Start over like a new conversation, without touching text the user is typing.
                                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    draft = TripAIPlanner.defaultPrompt
                                    draftWasEdited = false
                                }
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("只删除当前行程的对话，其他行程的对话不受影响。删除后无法恢复，已经应用到行程的调整会保留。")
                        }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(session.applyingMessageID != nil)
        .sensoryFeedback(.success, trigger: session.appliedCount)
        .task { session.load() }
        .onAppear { session.refreshPreviews() }
        .onDisappear { session.cancelAll() }
        .onChange(of: session.isLoaded) { _, loaded in
            // A continuing conversation starts with an empty field; the default
            // prompt only fills a field the user has not touched.
            if loaded, !session.messages.isEmpty, !draftWasEdited, draft == TripAIPlanner.defaultPrompt {
                draft = ""
            }
        }
    }

    /// Once the streaming answer's top reaches the top of the screen, pin it
    /// there and stop following so the start of the answer stays readable.
    private func stopFollowingIfAnswerReachedTop(_ top: CGFloat, proxy: ScrollViewProxy) {
        guard session.isStreaming, followsStreaming, viewportTop > 0,
              top <= viewportTop + Self.streamingTopMargin else { return }
        followsStreaming = false
        proxy.scrollTo(Self.streamingAnchorID, anchor: .top)
    }

    private var showsEmptyState: Bool {
        session.isLoaded && session.messages.isEmpty && !session.isStreaming && session.errorMessage == nil
    }

    private var canSend: Bool {
        session.isLoaded
            && session.applyingMessageID == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.dfkAccent)
                .frame(width: 64, height: 64)
                .background(Color.dfkAccent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("想怎么优化这趟行程？")
                    .font(.title3.weight(.semibold))
                Text("说说你的偏好和要求，比如节奏、兴趣、预算或同行的人。AI 会结合当前安排给出建议，并能一键应用到行程。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            FlowLayout(spacing: 8) {
                ForEach(TripAIPlanner.suggestions, id: \.self) { suggestion in
                    Button {
                        send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.isLoaded)
                }
            }
            .padding(.top, 4)

            Text("AI 建议仅供参考，出发前请再核实开放时间与交通信息。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    // MARK: Messages

    @ViewBuilder
    private func messageRow(_ message: TripAIChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(verbatim: message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.dfkAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            assistantRow {
                VStack(alignment: .leading, spacing: 12) {
                    if let blocks = session.renderedBlocks[message.id] {
                        TripAIMarkdownView(blocks: blocks)
                    } else {
                        Text(verbatim: message.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if message.isInterrupted {
                        Text("已停止生成")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if message.planJSON != nil {
                        planCard(for: message)
                    }
                }
            }
        }
    }

    private func assistantRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dfkAccent)
                .frame(width: 28, height: 28)
                .background(Color.dfkAccent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            content()
                .padding(.top, 3)
        }
    }

    private var streamingRow: some View {
        assistantRow {
            VStack(alignment: .leading, spacing: 10) {
                if session.streamingText.isEmpty {
                    typingIndicator(session.isComposingPlan ? "正在整理行程调整…" : "正在思考…")
                } else {
                    TripAIMarkdownView(blocks: session.streamingBlocks)
                    if session.isComposingPlan {
                        typingIndicator("正在整理行程调整…")
                    }
                }
            }
        }
    }

    private func typingIndicator(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.canRetry {
                Button("重试") { session.retry() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Color.dfkAccent)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Plan card

    @ViewBuilder
    private func planCard(for message: TripAIChatMessage) -> some View {
        let isApplied = message.appliedAt != nil
        let preview = isApplied ? nil : session.previews[message.id]
        let changes = isApplied ? (message.appliedChanges ?? []) : (preview?.changes ?? [])
        let isApplying = session.applyingMessageID == message.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(isApplied ? "已应用的调整" : "建议的调整", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dfkAccent)
                Spacer()
                if !changes.isEmpty {
                    Text("\(changes.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isApplied {
                if changes.isEmpty {
                    Text("这些调整已应用到行程安排。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    changeList(changes)
                }
            } else if let preview {
                if preview.hasChanges {
                    changeList(changes)
                } else if preview.warnings.isEmpty {
                    Text("当前行程已经是这样安排的，无需调整。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在比对当前行程…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let notice = session.applyNotices[message.id] {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            planActions(message: message, preview: preview, isApplied: isApplied, isApplying: isApplying)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: isApplied)
        .animation(.snappy, value: isApplying)
    }

    private func changeList(_ changes: [TripAIPlanChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(changes) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: change.kind.symbol)
                        .font(.subheadline)
                        .foregroundStyle(color(for: change.kind))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(change.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func planActions(message: TripAIChatMessage, preview: TripAIPlanPreview?, isApplied: Bool, isApplying: Bool) -> some View {
        if isApplying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在应用到行程安排…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        } else if isApplied {
            HStack {
                Label("已应用到行程安排", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                Spacer()
                if session.undoableMessageID == message.id {
                    Button("撤销") { session.undo(message.id) }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
        } else if let preview, preview.hasChanges {
            Button {
                requestApply(message.id, preview: preview)
            } label: {
                Label("应用建议", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .tint(Color.dfkAccent)
            .disabled(session.isStreaming || session.applyingMessageID != nil)
            // Anchored to this card's apply button so it opens where it was tapped.
            .confirmationDialog(
                "应用这些调整？",
                isPresented: Binding(
                    get: { pendingRemovalApply?.id == message.id },
                    set: { if !$0 { pendingRemovalApply = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRemovalApply
            ) { pending in
                Button("应用建议") { session.apply(pending.id) }
                Button("取消", role: .cancel) { }
            } message: { pending in
                Text("这会从行程安排中删除 \(pending.removalCount) 个地点。")
            }
        }
    }

    private func requestApply(_ messageID: UUID, preview: TripAIPlanPreview) {
        let removalCount = preview.plan.removedItemIDs.count
        if removalCount > 0 {
            pendingRemovalApply = PendingApply(id: messageID, removalCount: removalCount)
        } else {
            session.apply(messageID)
        }
    }

    private func color(for kind: TripAIPlanChange.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .skipped: return .orange
        default: return Color.dfkAccent
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            DFKIMEMultilineTextField(
                placeholder: "输入你的偏好或要求",
                text: $draft,
                minHeight: 36,
                maxHeight: 132,
                showsInputBox: false
            )
            .padding(.leading, 14)
            .padding(.vertical, 4)
            .onChange(of: draft) { _, _ in draftWasEdited = true }

            Button {
                if session.isStreaming {
                    session.stop()
                } else {
                    // Ending editing first commits any in-progress IME
                    // composition into `draft`, so it is sent in full.
                    dismissKeyboard()
                    send(draft)
                }
            } label: {
                Image(systemName: session.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        session.isStreaming || canSend ? Color.dfkAccent : Color.secondary.opacity(0.4)
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!session.isStreaming && !canSend)
            .accessibilityLabel(session.isStreaming ? "停止生成" : "发送")
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func send(_ text: String) {
        guard session.isLoaded, !session.isStreaming, session.applyingMessageID == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissKeyboard()
        session.send(text)
        draft = ""
        draftWasEdited = true
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Markdown

/// Lays out Markdown blocks parsed off the main actor by `TripAIMarkdown`.
struct TripAIMarkdownView: View {
    let blocks: [TripAIMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                blockView(block)
                    .padding(.top, block.spacingBefore)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: TripAIMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph:
            Text(block.content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let depth):
            listRow(marker: depth == 0 ? "•" : "◦", depth: depth, content: block.content)
        case .ordered(let marker, let depth):
            listRow(marker: marker, depth: depth, content: block.content)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.dfkAccent.opacity(0.5))
                    .frame(width: 3)
                Text(block.content)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.content)
                    .font(.callout.monospaced())
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .divider:
            Divider()
                .padding(.vertical, 4)
        case .table(let rows, let hasHeader):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(rows[rowIndex].indices, id: \.self) { cellIndex in
                                Text(rows[rowIndex][cellIndex])
                                    .font(hasHeader && rowIndex == 0 ? .subheadline.weight(.semibold) : .subheadline)
                            }
                        }
                        if hasHeader && rowIndex == 0 {
                            Divider()
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func listRow(marker: String, depth: Int, content: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 18 + 2)
    }
}
