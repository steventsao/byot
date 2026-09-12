import Combine
import Foundation

@MainActor
final class OpenCodeRemoteFileStore: ObservableObject {
    @Published private(set) var capabilities: OpenCodeRemoteFileCapabilities?
    @Published private(set) var entries: [OpenCodeRemoteFileEntry] = []
    @Published private(set) var changedFiles: [OpenCodeRemoteFileChange] = []
    @Published private(set) var suggestions: [OpenCodeRemoteFileEntry] = []
    @Published private(set) var content: OpenCodeRemoteFileContent?
    @Published private(set) var isLoading = false
    @Published private(set) var isReading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var readErrorMessage: String?
    @Published private(set) var suggestionErrorMessage: String?
    let scope: OpenCodeRemoteFileScope
    private let service: any OpenCodeRemoteFileServicing
    private var generation = 0
    private var readGeneration = 0
    private var suggestionGeneration = 0

    init(service: any OpenCodeRemoteFileServicing) {
        self.service = service
        scope = service.scope
    }

    func loadCapabilities() async {
        do { capabilities = try await service.capabilities(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func load(path: String = "", query: String? = nil, changes: Bool = false) async {
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        entries = []
        changedFiles = []
        defer { if request == generation { isLoading = false } }
        do {
            if capabilities == nil { capabilities = try await service.capabilities() }
            if changes {
                let result = try await service.changes()
                guard request == generation, !Task.isCancelled else { return }
                changedFiles = result
            } else {
                let result = if let query, !query.isEmpty {
                    try await service.search(query: query)
                } else {
                    try await service.list(path: path)
                }
                guard request == generation, !Task.isCancelled else { return }
                entries = result
            }
        } catch is CancellationError {} catch {
            if request == generation, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func suggest(query: String?) async {
        suggestionGeneration += 1
        let request = suggestionGeneration
        suggestions = []
        suggestionErrorMessage = nil
        guard let query else { return }
        do {
            try await Task.sleep(for: .milliseconds(220))
            if capabilities == nil { capabilities = try await service.capabilities() }
            let result = try await service.search(query: query)
            guard request == suggestionGeneration, !Task.isCancelled else { return }
            suggestions = result
        } catch is CancellationError {} catch {
            if request == suggestionGeneration, !Task.isCancelled { suggestionErrorMessage = error.localizedDescription }
        }
    }

    func read(path: String) async {
        readGeneration += 1
        let request = readGeneration
        isReading = true
        content = nil
        readErrorMessage = nil
        defer { if request == readGeneration { isReading = false } }
        do {
            let result = try await service.read(path: path)
            guard request == readGeneration, !Task.isCancelled else { return }
            content = result
        } catch is CancellationError {} catch {
            if request == readGeneration, !Task.isCancelled { readErrorMessage = error.localizedDescription }
        }
    }

    func reference(path: String, selection: OpenCodeFileLineRange? = nil) -> OpenCodePromptFileReference {
        scope.reference(path: path, selection: selection)
    }
}

/// Only explicit @tokens invoke remote search; email addresses and ordinary prose do not.
enum OpenCodeFileMention {
    static func range(in text: String) -> Range<String.Index>? {
        guard let at = text.lastIndex(of: "@"), at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
        let tail = text[text.index(after: at)...]
        guard !tail.contains(where: \.isWhitespace) else { return nil }
        return at..<text.endIndex
    }
    static func query(in text: String) -> String? {
        guard let range = range(in: text) else { return nil }
        return String(text[text.index(after: range.lowerBound)..<range.upperBound])
    }
    static func removingQuery(from text: String) -> String {
        guard let range = range(in: text) else { return text }
        var updated = text
        updated.removeSubrange(range)
        return updated
    }
}
