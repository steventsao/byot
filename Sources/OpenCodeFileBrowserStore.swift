import Combine
import Foundation

enum OpenCodeFileBrowserMode: String, CaseIterable, Identifiable, Sendable {
    case browse = "Browse"
    case changes = "Changes"

    var id: String { rawValue }
}

@MainActor
final class OpenCodeFileBrowserStore: ObservableObject {
    @Published private(set) var capabilities: OpenCodeProtocolCapabilities?
    @Published private(set) var entries: [OpenCodeFileEntry] = []
    @Published private(set) var searchResults: [OpenCodeFileEntry] = []
    @Published private(set) var statuses: [OpenCodeFileStatus] = []
    @Published private(set) var currentPath = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published var query = ""
    @Published var mode = OpenCodeFileBrowserMode.browse

    private let service: any OpenCodeFileBrowserServicing
    let directory: String
    let workspace: String?
    private var navigationVersion = OpenCodeFileBrowserRequestVersion()
    private var searchVersion = OpenCodeFileBrowserRequestVersion()
    private var loadingTracker = OpenCodeFileBrowserLoadingTracker()

    init(client: OpenCodeClient, directory: String, workspace: String?) {
        service = client
        self.directory = directory
        self.workspace = workspace
    }

    init(
        service: any OpenCodeFileBrowserServicing,
        directory: String,
        workspace: String?
    ) {
        self.service = service
        self.directory = directory
        self.workspace = workspace
    }

    var policy: OpenCodeFileBrowserPolicy? {
        capabilities.map(OpenCodeFileBrowserPolicy.init)
    }

    var isShowingBlockingLoader: Bool { isLoading }

    var visibleEntries: [OpenCodeFileEntry] {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return searchResults
        }
        switch mode {
        case .browse:
            return entries
        case .changes:
            return statuses.map { status in
                OpenCodeFileEntry(
                    name: status.path.split(separator: "/").last.map(String.init) ?? status.path,
                    path: status.path,
                    type: "file"
                )
            }
        }
    }

    var statusByPath: [String: OpenCodeFileStatus] {
        Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })
    }

    func start() async {
        let loadingOwner = beginLoading()
        defer { endLoading(loadingOwner) }
        do {
            let capabilities = try await service.protocolCapabilities()
            try Task.checkCancellation()
            self.capabilities = capabilities
            errorMessage = nil
            let policy = OpenCodeFileBrowserPolicy(capabilities: capabilities)
            if policy.canBrowseTree {
                await load(path: "", managesLoadingState: false)
                try Task.checkCancellation()
            }
            if policy.canListChanges {
                await loadStatuses()
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ entry: OpenCodeFileEntry) async {
        guard entry.isDirectory, policy?.canBrowseTree == true else { return }
        await load(path: entry.path)
    }

    func goUp() async {
        guard !currentPath.isEmpty else { return }
        await load(path: OpenCodeFileBrowserPath.parent(of: currentPath))
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = searchVersion.begin()
            searchResults = []
            isSearching = false
            errorMessage = nil
            return
        }
        guard policy?.canSearch == true else { return }
        let request = searchVersion.begin()
        searchResults = []
        isSearching = true
        defer {
            if searchVersion.accepts(request) { isSearching = false }
        }
        do {
            let results = try await service.findFiles(
                directory: directory,
                workspace: workspace,
                query: trimmed
            )
            guard searchVersion.accepts(request) else { return }
            searchResults = sort(results)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard searchVersion.accepts(request) else { return }
            searchResults = []
            errorMessage = error.localizedDescription
        }
    }

    private func load(path: String, managesLoadingState: Bool = true) async {
        let request = navigationVersion.begin()
        let loadingOwner = managesLoadingState ? beginLoading() : nil
        defer {
            if let loadingOwner { endLoading(loadingOwner) }
        }
        do {
            let entries = try await service.listFiles(
                directory: directory,
                workspace: workspace,
                path: path
            )
            guard navigationVersion.accepts(request) else { return }
            currentPath = path
            self.entries = sort(entries)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard navigationVersion.accepts(request) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadStatuses() async {
        do {
            statuses = try await service.fileStatuses(
                directory: directory,
                workspace: workspace
            ).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sort(_ entries: [OpenCodeFileEntry]) -> [OpenCodeFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func beginLoading() -> Int {
        let owner = loadingTracker.begin()
        isLoading = loadingTracker.isLoading
        return owner
    }

    private func endLoading(_ owner: Int) {
        loadingTracker.end(owner)
        isLoading = loadingTracker.isLoading
    }
}

@MainActor
final class OpenCodeFileReaderStore: ObservableObject {
    @Published private(set) var capabilities: OpenCodeProtocolCapabilities?
    @Published private(set) var content: OpenCodeFileContent?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: any OpenCodeFileBrowserServicing
    let directory: String
    let workspace: String?
    let path: String
    private var requestVersion = OpenCodeFileBrowserRequestVersion()

    init(
        client: OpenCodeClient,
        directory: String,
        workspace: String?,
        path: String
    ) {
        service = client
        self.directory = directory
        self.workspace = workspace
        self.path = path
    }

    init(
        service: any OpenCodeFileBrowserServicing,
        directory: String,
        workspace: String?,
        path: String
    ) {
        self.service = service
        self.directory = directory
        self.workspace = workspace
        self.path = path
    }

    var presentation: OpenCodeFileContentPresentation {
        OpenCodeFileContentPresentation(
            path: path,
            content: content,
            support: capabilities?.fileRead
        )
    }

    func load() async {
        let request = requestVersion.begin()
        isLoading = true
        defer {
            if requestVersion.accepts(request) { isLoading = false }
        }
        do {
            let capabilities = try await service.protocolCapabilities()
            guard requestVersion.accepts(request) else { return }
            self.capabilities = capabilities
            guard capabilities.fileRead.isSupported else { return }
            let content = try await service.readFile(
                directory: directory,
                workspace: workspace,
                path: path
            )
            guard requestVersion.accepts(request) else { return }
            self.content = content
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestVersion.accepts(request) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
