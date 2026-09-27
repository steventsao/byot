import SwiftUI
import UIKit

/// What OpenCode is running with for one project: branch and uncommitted changes, MCP
/// servers (switchable), language servers, formatters, plugins, configuration and paths.
/// Mirrors the TUI's `/status` dialog and the web app's status popover.
struct OpenCodeProjectStatusScreen: View {
    let route: OpenCodeProjectStatusRoute
    @StateObject private var store: OpenCodeServerContextStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    init(client: OpenCodeClient, route: OpenCodeProjectStatusRoute) {
        self.init(service: OpenCodeServerContextService(client: client, route: route), route: route)
    }

    init(service: any OpenCodeServerContextServicing, route: OpenCodeProjectStatusRoute) {
        self.route = route
        _store = StateObject(wrappedValue: OpenCodeServerContextStore(service: service))
    }

    var body: some View {
        List {
            if store.connectionError == nil {
                if let message = store.refreshError {
                    Section {
                        Label("Couldn’t refresh. \(message.agentDisplayErrorText)", systemImage: "exclamationmark.triangle")
                            .font(.cleanCaption)
                            .foregroundStyle(BYOTBrand.diffDeletion)
                            .accessibilityIdentifier("status-refresh-error")
                    }
                }
                OpenCodeStatusVersionControlSection(store: store)
                OpenCodeStatusMCPSection(store: store)
                OpenCodeStatusLanguageServerSection(store: store, directory: route.directory)
                OpenCodeStatusFormatterSection(store: store)
                OpenCodeStatusConfigurationSections(store: store)
                OpenCodeStatusPathsSection(store: store)
            }
        }
        .overlay { stateOverlay }
        .refreshable { await store.load() }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Status").font(.cleanBodySemibold)
                    Text(route.projectName)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .task { await store.load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: scenePhase) { _, phase in
            // Servers, branches and MCP state change while the app is in the background.
            if phase == .active && isOnScreen { Task { await store.load() } }
        }
        .accessibilityIdentifier("project-status")
    }

    @ViewBuilder private var stateOverlay: some View {
        if let message = store.connectionError {
            ContentUnavailableView {
                Label("Couldn’t load status", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message.agentDisplayErrorText)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(BYOTBrand.accentInk)
            }
        } else if store.hasNothingToShow {
            ContentUnavailableView("No status available", systemImage: "gauge.with.dots.needle.0percent",
                                   description: Text("This OpenCode server doesn’t report project status yet."))
        }
    }
}

// MARK: - Version control

private struct OpenCodeStatusVersionControlSection: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        if store.branch.isVisible || store.changes.isVisible {
            Section("Version control") {
                switch store.branch {
                case .loading: OpenCodeStatusLoadingRow()
                case .failed(let message): OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let branch): branchRow(branch)
                case .unsupported: EmptyView()
                }
                if store.branch.value?.isRepository != false {
                    changesRows
                }
            }
        }
    }

    @ViewBuilder private func branchRow(_ branch: OpenCodeVcsBranch) -> some View {
        if branch.isRepository {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                OpenCodeStatusIcon(systemName: "arrow.triangle.branch", tint: BYOTBrand.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(branch.current ?? String(localized: "Detached HEAD"))
                        .font(.cleanBodySemibold)
                        .textSelection(.enabled)
                    if let detail = Self.branchDetail(branch) {
                        Text(detail)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.branchAccessibilityLabel(branch))
            .accessibilityIdentifier("status-branch")
        } else {
            Label("Not a Git repository", systemImage: "folder")
                .font(.cleanBody)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("status-branch")
        }
    }

    static func branchDetail(_ branch: OpenCodeVcsBranch) -> String? {
        guard let base = branch.defaultBranch else { return nil }
        return base == branch.current ? String(localized: "Default branch") : String(localized: "Default branch: \(base)")
    }

    static func branchAccessibilityLabel(_ branch: OpenCodeVcsBranch) -> String {
        let current = branch.current.map { String(localized: "Branch \($0)") } ?? String(localized: "Detached HEAD")
        return [current, branchDetail(branch)].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private var changesRows: some View {
        switch store.changes {
        case .loading:
            OpenCodeStatusLoadingRow()
        case .failed(let message):
            OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
        case .loaded(let files) where files.isEmpty:
            Label("No uncommitted changes", systemImage: "checkmark.circle")
                .font(.cleanBody)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("status-changes")
        case .loaded(let files):
            DisclosureGroup {
                ForEach(files) { file in OpenCodeStatusFileChangeRow(file: file) }
            } label: {
                OpenCodeStatusChangesSummary(files: files)
            }
            .accessibilityIdentifier("status-changes")
        case .unsupported:
            EmptyView()
        }
    }
}

private struct OpenCodeStatusChangesSummary: View {
    let files: [OpenCodeProjectFileChange]

    var body: some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                OpenCodeDiffCounts(additions: additions, deletions: deletions, showsBar: true)
                    .font(.cleanCaptionBold)
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                OpenCodeDiffCounts(additions: additions, deletions: deletions)
                    .font(.cleanCaptionBold)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.count(files.count)) uncommitted, \(additions) additions, \(deletions) deletions")
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            OpenCodeStatusIcon(systemName: "plusminus", tint: BYOTBrand.mutedInk)
            Text(Self.count(files.count)).font(.cleanBody).foregroundStyle(BYOTBrand.ink)
        }
    }

    static func count(_ count: Int) -> String { count == 1 ? String(localized: "1 changed file") : String(localized: "\(count) changed files") }
}

private struct OpenCodeStatusFileChangeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let file: OpenCodeProjectFileChange

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                OpenCodeStatusIcon(systemName: file.status.symbol, tint: BYOTBrand.diffInk(file.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.cleanBody)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let folder = file.folder {
                        Text(folder)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .truncationMode(.head)
                    }
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            OpenCodeDiffCounts(additions: file.additions, deletions: file.deletions)
                .font(.cleanCaptionBold)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([file.name, file.status.title, file.folder.map { String(localized: "in \($0)") },
                             String(localized: "\(file.additions) additions, \(file.deletions) deletions")]
            .compactMap { $0 }.joined(separator: ", "))
        .contextMenu {
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
        }
    }
}

// MARK: - MCP servers

private struct OpenCodeStatusMCPSection: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        if store.mcpServers.isVisible {
            Section {
                switch store.mcpServers {
                case .loading:
                    OpenCodeStatusLoadingRow()
                case .failed(let message):
                    OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let servers) where servers.isEmpty:
                    OpenCodeStatusEmptyRow(text: String(localized: "No MCP servers configured"))
                case .loaded(let servers):
                    ForEach(servers) { server in
                        OpenCodeMCPServerRow(
                            server: server,
                            isSwitching: store.switchingMCP.contains(server.name),
                            actionError: store.mcpErrors[server.name],
                            canControl: store.canControlMCP
                        ) { connected in
                            Task { await toggle(server, connected: connected) }
                        }
                    }
                case .unsupported:
                    EmptyView()
                }
            } header: {
                OpenCodeStatusSectionHeader(title: String(localized: "MCP servers"), detail: connectedSummary)
            } footer: {
                if let footer { Text(footer).font(.cleanCaption) }
            }
        }
    }

    private var connectedSummary: String? {
        guard let servers = store.mcpServers.value, !servers.isEmpty else { return nil }
        return String(localized: "\(servers.filter(\.isConnected).count) of \(servers.count) connected")
    }

    private var footer: String? {
        guard let servers = store.mcpServers.value else { return nil }
        if servers.isEmpty { return String(localized: "Add MCP servers to opencode.json on the server.") }
        return store.canControlMCP
            ? String(localized: "Switching a server applies until OpenCode restarts. Its configuration is unchanged.")
            : nil
    }

    private func toggle(_ server: OpenCodeMCPServer, connected: Bool) async {
        await store.setMCPServer(server, connected: connected)
        let message: String
        if let error = store.mcpErrors[server.name] {
            message = "\(server.name): \(error)"
        } else if let updated = store.mcpServer(named: server.name) {
            message = String(localized: "\(server.name) \(updated.state.title.lowercased())")
        } else {
            return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

struct OpenCodeMCPServerRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let server: OpenCodeMCPServer
    let isSwitching: Bool
    let actionError: String?
    let canControl: Bool
    let setConnected: (Bool) -> Void

    var body: some View {
        Group {
            if canControl && server.canToggle && !isSwitching {
                if dynamicTypeSize.isAccessibilitySize {
                    // Beside a switch, large text leaves the status a few letters per line.
                    VStack(alignment: .leading, spacing: 8) {
                        label.accessibilityHidden(true)
                        toggle { Text(server.name) }
                            .labelsHidden()
                            .accessibilityValue(server.isConnected ? "On" : "Off")
                            .accessibilityHint([server.state.title, detail].compactMap { $0 }.joined(separator: ". "))
                    }
                } else {
                    toggle { label }
                }
            } else {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    if isSwitching || server.state == .pending {
                        ProgressView()
                            .accessibilityLabel(isSwitching ? "Updating" : "Connecting")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("mcp-\(server.name)")
    }

    private func toggle(@ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { server.isConnected }, set: setConnected), label: label)
            .tint(BYOTBrand.accent)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            OpenCodeStatusIcon(systemName: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.cleanBodySemibold)
                Text(server.state.title)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(actionError == nil && server.state == .needsAuthentication
                                         ? BYOTBrand.mutedInk : BYOTBrand.diffDeletion)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// The failed request first, then what the server reports about the connection.
    private var detail: String? {
        if let actionError { return actionError.agentDisplayErrorText }
        switch server.state {
        case .needsAuthentication:
            return String(localized: "Sign in on the server’s computer with “opencode mcp auth \(server.name)”.")
        case .failed, .needsClientRegistration, .other:
            return server.error?.agentDisplayErrorText
        case .connected, .pending, .disabled:
            return nil
        }
    }

    private var symbol: String {
        switch server.state {
        case .connected: "checkmark.circle.fill"
        case .pending: "circle.dotted"
        case .disabled: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .needsAuthentication: "key.fill"
        case .needsClientRegistration: "exclamationmark.circle.fill"
        case .other: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch server.state {
        case .connected: BYOTBrand.accent
        case .failed: BYOTBrand.diffDeletion
        case .needsAuthentication, .needsClientRegistration: Color(uiColor: .systemOrange)
        case .pending, .disabled, .other: BYOTBrand.mutedInk
        }
    }
}

// MARK: - Language servers and formatters

private struct OpenCodeStatusLanguageServerSection: View {
    @ObservedObject var store: OpenCodeServerContextStore
    let directory: String

    var body: some View {
        if store.languageServers.isVisible {
            Section {
                switch store.languageServers {
                case .loading:
                    OpenCodeStatusLoadingRow()
                case .failed(let message):
                    OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let servers) where servers.isEmpty:
                    OpenCodeStatusEmptyRow(text: String(localized: "No language servers running"))
                case .loaded(let servers):
                    ForEach(servers) { server in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            OpenCodeStatusIcon(
                                systemName: server.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tint: server.isConnected ? BYOTBrand.accent : BYOTBrand.diffDeletion)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).font(.cleanBodySemibold)
                                Text(server.displayRoot(relativeTo: directory))
                                    .font(.cleanMono)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.head)
                                if !server.isConnected {
                                    Text("Error").font(.cleanCaption).foregroundStyle(BYOTBrand.diffDeletion)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("lsp-\(server.id)")
                    }
                case .unsupported:
                    EmptyView()
                }
            } header: {
                OpenCodeStatusSectionHeader(title: String(localized: "Language servers"), detail: nil)
            } footer: {
                Text("OpenCode starts language servers as the agent opens matching files.")
                    .font(.cleanCaption)
            }
        }
    }
}

private struct OpenCodeStatusFormatterSection: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        if store.formatters.isVisible {
            Section {
                switch store.formatters {
                case .loading:
                    OpenCodeStatusLoadingRow()
                case .failed(let message):
                    OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let formatters):
                    let enabled = formatters.filter(\.enabled)
                    let available = formatters.filter { !$0.enabled }
                    if enabled.isEmpty {
                        OpenCodeStatusEmptyRow(text: String(localized: "No formatters enabled for this project"))
                    }
                    ForEach(enabled) { formatter in formatterRow(formatter) }
                    if !available.isEmpty {
                        DisclosureGroup {
                            ForEach(available) { formatter in formatterRow(formatter) }
                        } label: {
                            Text("\(available.count) not enabled")
                                .font(.cleanBody)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("status-formatters-disabled")
                    }
                case .unsupported:
                    EmptyView()
                }
            } header: {
                OpenCodeStatusSectionHeader(title: String(localized: "Formatters"), detail: nil)
            } footer: {
                Text("OpenCode formats the files it edits with the enabled formatter for each file type.")
                    .font(.cleanCaption)
            }
        }
    }

    private func formatterRow(_ formatter: OpenCodeFormatterStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            OpenCodeStatusIcon(systemName: formatter.enabled ? "checkmark.circle.fill" : "circle",
                               tint: formatter.enabled ? BYOTBrand.accent : BYOTBrand.mutedInk)
            VStack(alignment: .leading, spacing: 3) {
                Text(formatter.name)
                    .font(formatter.enabled ? .cleanBodySemibold : .cleanBody)
                    .foregroundStyle(formatter.enabled ? BYOTBrand.ink : BYOTBrand.mutedInk)
                if !formatter.extensions.isEmpty {
                    Text(formatter.extensions.joined(separator: " "))
                        .font(.cleanMono)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatter.enabled ? "\(formatter.name), enabled" : "\(formatter.name), not enabled")
        .accessibilityValue(formatter.extensions.joined(separator: ", "))
        .accessibilityIdentifier("formatter-\(formatter.name)")
    }
}

// MARK: - Configuration

private struct OpenCodeStatusConfigurationSections: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        if store.configuration.isVisible {
            Section {
                switch store.configuration {
                case .loading:
                    OpenCodeStatusLoadingRow()
                case .failed(let message):
                    OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let configuration):
                    summary(configuration)
                case .unsupported:
                    EmptyView()
                }
            } header: {
                OpenCodeStatusSectionHeader(title: String(localized: "Configuration"), detail: nil)
            } footer: {
                Text("Read-only. Change settings in opencode.json on the server. Secrets such as API keys are hidden.")
                    .font(.cleanCaption)
            }
            if let plugins = store.configuration.value?.plugins, !plugins.isEmpty {
                Section {
                    ForEach(plugins) { plugin in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            OpenCodeStatusIcon(systemName: "puzzlepiece.extension", tint: BYOTBrand.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.name).font(.cleanBodySemibold)
                                if let version = plugin.version {
                                    Text(version).font(.cleanMono).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    OpenCodeStatusSectionHeader(title: String(localized: "Plugins"), detail: "\(plugins.count)")
                }
            }
        }
    }

    @ViewBuilder private func summary(_ configuration: OpenCodeServerConfiguration) -> some View {
        let rows = Self.rows(configuration)
        if rows.isEmpty {
            OpenCodeStatusEmptyRow(text: String(localized: "Using OpenCode’s defaults"))
        }
        ForEach(rows, id: \.title) { row in
            OpenCodeStatusValueRow(title: row.title, value: row.value, monospaced: row.monospaced)
        }
        if !configuration.sources.isEmpty {
            DisclosureGroup {
                ForEach(configuration.sources) { source in
                    OpenCodeStatusValueRow(title: source.kind.title, value: source.path ?? String(localized: "Built in"),
                                           monospaced: source.path != nil, stacked: true)
                }
            } label: {
                Text(configuration.sources.count == 1 ? "1 source" : "\(configuration.sources.count) sources")
                    .font(.cleanBody)
                    .frame(minHeight: 44)
            }
        }
        if !configuration.documents.isEmpty {
            NavigationLink {
                OpenCodeConfigurationDocumentView(documents: configuration.documents)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    OpenCodeStatusIcon(systemName: "curlybraces", tint: BYOTBrand.mutedInk)
                    Text("View configuration").font(.cleanBody)
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("status-configuration-json")
        }
    }

    struct Row: Equatable {
        let title: String
        let value: String
        var monospaced = false
    }

    static func rows(_ configuration: OpenCodeServerConfiguration) -> [Row] {
        var rows: [Row] = []
        if let model = configuration.model { rows.append(Row(title: String(localized: "Model"), value: model, monospaced: true)) }
        if let model = configuration.smallModel { rows.append(Row(title: String(localized: "Small model"), value: model, monospaced: true)) }
        if let agent = configuration.defaultAgent { rows.append(Row(title: String(localized: "Default agent"), value: agent)) }
        if !configuration.providers.isEmpty {
            rows.append(Row(title: configuration.providers.count == 1 ? String(localized: "Provider") : String(localized: "Providers"),
                            value: configuration.providers.map(\.name).joined(separator: ", ")))
        }
        if let share = configuration.share { rows.append(Row(title: String(localized: "Sharing"), value: share)) }
        if let updates = configuration.updates { rows.append(Row(title: String(localized: "Updates"), value: updates)) }
        if let shell = configuration.shell { rows.append(Row(title: String(localized: "Shell"), value: shell, monospaced: true)) }
        if let username = configuration.username { rows.append(Row(title: String(localized: "Username"), value: username)) }
        if !configuration.instructions.isEmpty {
            rows.append(Row(title: String(localized: "Instructions"), value: configuration.instructions.joined(separator: "\n"), monospaced: true))
        }
        return rows
    }
}

/// The configuration as JSON, with credentials removed, for reading and copying.
struct OpenCodeConfigurationDocumentView: View {
    let documents: [OpenCodeServerConfiguration.Document]
    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BYOTBrand.Space.md) {
                Label("Secrets such as API keys, tokens, headers and environment values are hidden.",
                      systemImage: "lock")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(documents) { document in
                    VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
                        if documents.count > 1 || document.path != nil {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).font(.cleanBodySemibold)
                                if let path = document.path {
                                    Text(path).font(.cleanMono).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                        }
                        ScrollView(.horizontal) {
                            Text(OpenCodeServerConfiguration.text(document.json))
                                .font(.cleanMono)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(BYOTBrand.Space.md)
                        }
                        .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: BYOTBrand.panelRadius).stroke(BYOTBrand.hairline, lineWidth: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, BYOTBrand.Space.md)
            .padding(.vertical, BYOTBrand.Space.sm)
        }
        .background(BYOTBrand.canvas)
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") { copy() }
                    .tint(BYOTBrand.chromeTint)
                    .accessibilityHint("Copies the configuration without secrets")
                    .accessibilityIdentifier("status-configuration-copy")
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = documents
            .map { document in
                let json = OpenCodeServerConfiguration.text(document.json)
                return documents.count > 1 ? "// \(document.path ?? document.title)\n\(json)" : json
            }
            .joined(separator: "\n\n")
        withAnimation(reduceMotion ? nil : .snappy(duration: BYOTBrand.Motion.quick)) { didCopy = true }
        AccessibilityNotification.Announcement(String(localized: "Configuration copied")).post()
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(reduceMotion ? nil : .snappy(duration: BYOTBrand.Motion.quick)) { didCopy = false }
        }
    }
}

// MARK: - Paths

private struct OpenCodeStatusPathsSection: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        if store.paths.isVisible {
            Section("Paths") {
                switch store.paths {
                case .loading:
                    OpenCodeStatusLoadingRow()
                case .failed(let message):
                    OpenCodeStatusErrorRow(message: message) { Task { await store.load() } }
                case .loaded(let paths):
                    ForEach(Self.rows(paths), id: \.title) { row in
                        OpenCodeStatusValueRow(title: row.title, value: row.value, monospaced: true, stacked: true,
                                               copyValue: row.copyValue)
                    }
                case .unsupported:
                    EmptyView()
                }
            }
        }
    }

    struct Row: Equatable {
        let title: String
        let value: String
        let copyValue: String
    }

    static func rows(_ paths: OpenCodeProjectPaths) -> [Row] {
        func row(_ title: String, _ path: String?) -> Row? {
            guard let path = path?.trimmedNonEmpty else { return nil }
            return Row(title: title, value: paths.abbreviated(path), copyValue: path)
        }
        let worktree = paths.worktree == paths.directory ? nil : paths.worktree
        return [
            row(String(localized: "Directory"), paths.directory),
            row(paths.projectID == nil ? String(localized: "Worktree") : String(localized: "Project"), worktree),
            paths.projectID.map { Row(title: String(localized: "Project ID"), value: $0, copyValue: $0) },
            paths.workspaceID.map { Row(title: String(localized: "Workspace"), value: $0, copyValue: $0) },
            row(String(localized: "Config"), paths.config),
            row(String(localized: "State"), paths.state),
            row(String(localized: "Home"), paths.home),
        ].compactMap { $0 }
    }
}

// MARK: - Rows

/// A leading status glyph in a fixed, Dynamic Type–scaled column so row titles line up
/// whatever the symbol's width.
private struct OpenCodeStatusIcon: View {
    let systemName: String
    let tint: Color
    @ScaledMetric(relativeTo: .callout) private var width: CGFloat = 22

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(tint)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

private struct OpenCodeStatusSectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail) }
            }
        }
        .font(.cleanCaption)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A title and value side by side, or stacked when the value is long or text is large.
private struct OpenCodeStatusValueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String
    var monospaced = false
    var stacked = false
    var copyValue: String?

    var body: some View {
        Group {
            if stacked || dynamicTypeSize.isAccessibilitySize || value.contains("\n") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.cleanCaption).foregroundStyle(.secondary)
                    valueText
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title).font(.cleanBody)
                        Spacer(minLength: 8)
                        valueText.lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.cleanCaption).foregroundStyle(.secondary)
                        valueText
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = copyValue ?? value }
        }
    }

    private var valueText: some View {
        Text(value)
            .font(monospaced ? .cleanMono : .cleanBody)
            .foregroundStyle(stacked ? BYOTBrand.ink : BYOTBrand.mutedInk)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct OpenCodeStatusLoadingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading…").font(.cleanBody).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct OpenCodeStatusEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.cleanBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading)
    }
}

private struct OpenCodeStatusErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.agentDisplayErrorText, systemImage: "exclamationmark.triangle")
                .font(.cleanCaption)
                .foregroundStyle(BYOTBrand.diffDeletion)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", systemImage: "arrow.clockwise", action: retry)
                .font(.cleanCaptionBold)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }
}
