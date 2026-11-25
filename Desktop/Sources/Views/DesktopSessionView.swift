import SwiftUI

struct DesktopSessionView: View {
    let projectName: String
    let onOpenDiffs: () -> Void

    @StateObject private var store: OpenCodeSessionStore
    @State private var draft = ""
    @State private var questionDrafts: [String: [Int: Set<String>]] = [:]
    @State private var customAnswers: [String: [Int: String]] = [:]
    @Environment(\.colorScheme) private var colorScheme

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        projectName: String,
        onOpenDiffs: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.onOpenDiffs = onOpenDiffs
        _store = StateObject(wrappedValue: OpenCodeSessionStore(client: client, session: session, directory: directory))
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()

            if let error = store.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { store.errorMessage = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                Divider()
            }

            transcriptArea

            if !store.permissions.isEmpty || !store.questions.isEmpty {
                Divider()
                pendingActionsBar
            }

            Divider()
            composerArea
        }
        .background(DesktopBrand.canvas)
        .task { await store.start() }
        .onDisappear { store.stop() }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.session.title.isEmpty ? "Untitled Session" : store.session.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(projectName)
                    Text("·")
                    Text(store.directory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let context = store.usage.context, let percent = context.percent {
                Text("\(percent)% ctx")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DesktopBrand.surface, in: Capsule())
                    .foregroundStyle(context.level == .critical ? .red : .secondary)
            }

            if store.usage.cost > 0 {
                Text(String(format: "$%.3f", store.usage.cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            statusBadge

            if !store.diffs.isEmpty {
                Button {
                    onOpenDiffs()
                } label: {
                    Label("\(store.diffs.count) files", systemImage: "doc.badge.ellipsis")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DesktopBrand.surface.opacity(0.6))
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            if store.status.isActive {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(store.isEventConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
            }
            Text(store.status.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(store.status.isActive ? DesktopBrand.selectedSurface : DesktopBrand.surface, in: Capsule())
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.isLoadingTranscript && store.messages.isEmpty {
                        ProgressView("Loading transcript…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if store.messages.isEmpty {
                        ContentUnavailableView(
                            "Ready to code",
                            systemImage: "sparkles",
                            description: Text("Send a prompt below to start streaming from your OpenCode server.")
                        )
                        .padding(.top, 48)
                    } else {
                        ForEach(store.messages) { message in
                            if OpenCodeTranscriptLayout.rendersRow(message) {
                                DesktopMessageRow(message: message, colorScheme: colorScheme)
                                    .id(message.id)
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.transcriptRevision) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var pendingActionsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.permissions) { permission in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Permission Request · \(permission.permission)", systemImage: "hand.raised.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    if !permission.patterns.isEmpty {
                        Text(permission.patterns.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesktopBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack(spacing: 8) {
                        Button("Allow Once") {
                            Task { await store.reply(to: permission, with: .once) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if !permission.always.isEmpty {
                            Button("Always Allow") {
                                Task { await store.reply(to: permission, with: .always) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Reject", role: .destructive) {
                            Task { await store.reply(to: permission, with: .reject) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
            }

            ForEach(store.questions) { request in
                questionCard(request)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DesktopBrand.surface)
    }

    private func questionCard(_ request: OpenCodeQuestionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OpenCode has a question", systemImage: "questionmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question)
                        .font(.callout.weight(.medium))

                    if !question.options.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(question.options) { option in
                                let selected = questionDrafts[request.id]?[index]?.contains(option.label) == true
                                Button {
                                    var byQuestion = questionDrafts[request.id] ?? [:]
                                    var picks = byQuestion[index] ?? []
                                    if question.multiple == true {
                                        if picks.contains(option.label) { picks.remove(option.label) }
                                        else { picks.insert(option.label) }
                                    } else {
                                        picks = [option.label]
                                    }
                                    byQuestion[index] = picks
                                    questionDrafts[request.id] = byQuestion
                                } label: {
                                    Text(option.label)
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .tint(selected ? .primary : .secondary)
                                .controlSize(.small)
                            }
                        }
                    }

                    if question.allowsCustomAnswer {
                        TextField(
                            "Or type a custom answer…",
                            text: Binding(
                                get: { customAnswers[request.id]?[index] ?? "" },
                                set: { value in
                                    var byQuestion = customAnswers[request.id] ?? [:]
                                    byQuestion[index] = value
                                    customAnswers[request.id] = byQuestion
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Submit Answer") {
                    let answers: [[String]] = request.questions.indices.map { idx in
                        var values = Array(questionDrafts[request.id]?[idx] ?? [])
                        if let custom = customAnswers[request.id]?[idx]?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !custom.isEmpty {
                            values.append(custom)
                        }
                        return values
                    }
                    Task { await store.answer(request, answers: answers) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Dismiss", role: .cancel) {
                    Task { await store.reject(request) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopBrand.strongHairline))
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            if !store.queuedPrompts.isEmpty {
                HStack {
                    Label("\(store.queuedPrompts.count) queued", systemImage: "tray.full")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 140)
                    .padding(8)
                    .background(DesktopBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopBrand.hairline))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask OpenCode… (⌘↩ to send)")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }

                if store.canStopTurn {
                    Button {
                        Task { await store.stopTurn() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop running turn")
                }

                Button {
                    submitDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSubmitPrompt)
                .help("Send prompt (⌘↩)")
            }

            HStack(spacing: 10) {
                if !store.composerCatalog.agents.isEmpty {
                    Menu {
                        ForEach(store.composerCatalog.agents) { agent in
                            Button(agent.displayName) {
                                store.selectAgent(agent.id)
                            }
                        }
                    } label: {
                        Label(store.currentAgentName, systemImage: OpenCodeAgentOption.systemImage(for: store.currentAgentID))
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if !store.providerModels.isEmpty {
                    Menu {
                        Button("Server Default") { store.selectModel(nil) }
                        Divider()
                        ForEach(store.providerModels) { provider in
                            Section(provider.providerName) {
                                ForEach(provider.models) { model in
                                    Button(model.modelName) {
                                        store.selectModel(model)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(store.selectedModel?.modelName ?? "Default Model", systemImage: "cpu")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if !store.availableVariants.isEmpty {
                    Menu {
                        Button("Default") { store.selectVariant(nil) }
                        ForEach(store.availableVariants, id: \.self) { variant in
                            Button(variant) { store.selectVariant(variant) }
                        }
                    } label: {
                        Label(store.variantLabel, systemImage: "slider.horizontal.3")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Spacer()

                Text("⌘↩ Send")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DesktopBrand.surface.opacity(0.6))
    }

    private func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if store.send(text) {
            draft = ""
        }
    }
}

private struct DesktopMessageRow: View {
    let message: OpenCodeMessageEnvelope
    let colorScheme: ColorScheme

    private var isUser: Bool { message.info.role == "user" }

    var body: some View {
        let items = OpenCodeTranscriptLayout.items(for: message.parts, inPrompt: isUser)
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            ForEach(items) { item in
                switch item {
                case .part(let part):
                    partView(part)
                case .images(let parts):
                    HStack(spacing: 6) {
                        ForEach(parts) { part in
                            Label(part.filename ?? "Image", systemImage: "photo")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if let error = message.info.error {
                Label(error.displayMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func partView(_ part: OpenCodePart) -> some View {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                if isUser {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(DesktopBrand.selectedSurface, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 640, alignment: .trailing)
                } else {
                    Text(LocalizedStringKey(text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                DisclosureGroup {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Label("Reasoning", systemImage: "brain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        case "tool":
            if let state = part.state {
                DesktopToolCard(name: part.tool ?? "tool", state: state, colorScheme: colorScheme)
            }
        case "patch":
            if let files = part.files, !files.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(.primary)
                    Text("Modified \(files.count) file\(files.count == 1 ? "" : "s"): \(files.prefix(3).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 7))
            }
        default:
            EmptyView()
        }
    }
}

private struct DesktopToolCard: View {
    let name: String
    let state: OpenCodeToolState
    let colorScheme: ColorScheme
    @State private var isExpanded = false

    private var presentation: OpenCodeToolPresentation {
        OpenCodeToolPresentation(name: name, state: state)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let code = presentation.inputCode {
                    codeBlock(code)
                } else if let input = presentation.input {
                    Text(input)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if let outCode = presentation.outputCode {
                    codeBlock(outCode)
                } else if let output = presentation.output {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(output.prefix(4000))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesktopBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 6))
                }

                if let error = presentation.error {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                if let summary = presentation.summary {
                    Text(summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(presentation.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopBrand.hairline, lineWidth: 1))
    }

    private func codeBlock(_ code: OpenCodeToolCode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(DesktopSyntaxTheme.attributedCode(String(code.text.prefix(6000)), language: code.language, colorScheme: colorScheme))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusSymbol: String {
        switch state.status.lowercased() {
        case "completed": "checkmark.circle.fill"
        case "error": "xmark.circle.fill"
        case "running": "circle.dotted"
        default: "clock"
        }
    }

    private var statusColor: Color {
        switch state.status.lowercased() {
        case "completed": DesktopBrand.statusLive
        case "error": .red
        case "running": .orange
        default: .secondary
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
