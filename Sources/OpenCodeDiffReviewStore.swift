import Combine
import Foundation

/// Where a review was opened from: the session's Changes control, or one
/// turn's patch row in the transcript (which pins that turn and its files).
struct OpenCodeDiffReviewRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var messageID: String?
    var files: [String] = []

    init(messageID: String? = nil, files: [String] = []) {
        self.messageID = messageID
        self.files = files
    }
}

@MainActor
final class OpenCodeDiffReviewStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case unavailable(String)
    }

    @Published private(set) var sources: [OpenCodeDiffSource] = []
    @Published private(set) var source: OpenCodeDiffSource?
    @Published private(set) var files: [OpenCodeDiffFile] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var branch: OpenCodeVcsBranch?
    private(set) var turnMessageID: String?
    private(set) var isPinnedTurn = false
    private var availability: OpenCodeDiffAvailability?
    private var sessionDiffs: [OpenCodeDiff] = []
    private var lastOpen: (request: OpenCodeDiffReviewRequest, latestTurnMessageID: String?)?
    private let service: any OpenCodeDiffReviewServicing
    private let directory: String
    private var generation = 0

    init(service: any OpenCodeDiffReviewServicing, directory: String) {
        self.service = service
        self.directory = directory
    }

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// Negotiates what this server can compare, then loads the most relevant source:
    /// the pinned turn, else the latest turn, else the working copy.
    func open(_ request: OpenCodeDiffReviewRequest, latestTurnMessageID: String?, sessionDiffs: [OpenCodeDiff]) async {
        generation &+= 1
        let openGeneration = generation
        lastOpen = (request, latestTurnMessageID)
        isPinnedTurn = request.messageID != nil && request.messageID != latestTurnMessageID
        turnMessageID = request.messageID ?? latestTurnMessageID
        self.sessionDiffs = sessionDiffs
        files = []
        phase = .loading
        let availability: OpenCodeDiffAvailability
        do {
            availability = try await service.availability()
        } catch {
            guard openGeneration == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            // Sources from an earlier open no longer describe this server; hide the picker.
            sources = []
            source = nil
            branch = nil
            phase = .failed(error.localizedDescription)
            return
        }
        guard openGeneration == generation, !Task.isCancelled else { return }
        self.availability = availability
        branch = availability.branch
        sources = Self.sources(availability, hasTurn: turnMessageID != nil, hasSessionDiffs: !sessionDiffs.isEmpty)
        guard let first = Self.preferredSource(in: sources) else {
            source = nil
            phase = .unavailable(availability.unavailableReason
                ?? (availability.turn ? OpenCodeDiffReviewError.missingTurn.localizedDescription
                    : OpenCodeDiffAvailability.none.unavailableReason ?? ""))
            return
        }
        await load(first)
    }

    /// Whether the session's Changes controls should show. They hide only when the
    /// server positively offers nothing to compare (an OpenCode 2 schema without VCS
    /// diffs); an unreachable server keeps them so the reviewer can explain and retry.
    func isReviewAvailable() async -> Bool {
        guard let availability = try? await service.availability() else { return true }
        return availability.turn || availability.uncommitted || availability.branch?.comparesWithDefault == true
    }

    func select(_ source: OpenCodeDiffSource) async {
        guard sources.contains(source), source != self.source || phase != .loaded else { return }
        await load(source)
    }

    /// Pull to refresh keeps the current list visible until the new one arrives. It negotiates
    /// again when nothing loaded yet (unreachable server, no prompt) or a newer prompt was sent
    /// while the latest turn was shown; a turn pinned from the transcript stays pinned.
    func refresh(latestTurnMessageID latest: String? = nil) async {
        guard let lastOpen else { return }
        let latest = latest ?? lastOpen.latestTurnMessageID
        let followsNewTurn = !isPinnedTurn && latest != nil && latest != turnMessageID
            && source != .uncommitted && source != .branch
        guard let source, !followsNewTurn else {
            await open(lastOpen.request, latestTurnMessageID: latest, sessionDiffs: sessionDiffs)
            return
        }
        await load(source, keepingFiles: true)
    }

    /// `session.diff` events keep the legacy session snapshot live while the reviewer is open.
    func updateSessionDiffs(_ diffs: [OpenCodeDiff]) {
        sessionDiffs = diffs
        guard let availability else { return }
        let updated = Self.sources(availability, hasTurn: turnMessageID != nil,
                                   hasSessionDiffs: !diffs.isEmpty || source == .session)
        if updated != sources { sources = updated }
        if source == .session {
            generation &+= 1
            files = OpenCodeDiffFile.normalized(diffs, directory: directory)
            phase = .loaded
        }
    }

    func index(of fileID: String) -> Int? {
        files.firstIndex { $0.id == fileID }
    }

    private func load(_ source: OpenCodeDiffSource, keepingFiles: Bool = false) async {
        generation &+= 1
        let request = generation
        self.source = source
        if !keepingFiles {
            files = []
            phase = .loading
        }
        if source == .session {
            files = OpenCodeDiffFile.normalized(sessionDiffs, directory: directory)
            phase = .loaded
            return
        }
        do {
            let diffs = try await service.diffs(source, messageID: source == .turn ? turnMessageID : nil)
            let normalized = await Self.normalize(diffs, directory: directory)
            guard request == generation, !Task.isCancelled else { return }
            files = normalized
            phase = .loaded
        } catch is CancellationError {
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            if !keepingFiles || files.isEmpty { files = [] }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Branch diffs can carry hundreds of full patches; keep that work off the main actor.
    private nonisolated static func normalize(_ diffs: [OpenCodeDiff], directory: String) async -> [OpenCodeDiffFile] {
        OpenCodeDiffFile.normalized(diffs, directory: directory)
    }

    nonisolated static func sources(
        _ availability: OpenCodeDiffAvailability, hasTurn: Bool, hasSessionDiffs: Bool
    ) -> [OpenCodeDiffSource] {
        OpenCodeDiffSource.allCases.filter { source in
            switch source {
            case .turn: availability.turn && hasTurn
            case .session: hasSessionDiffs
            case .uncommitted: availability.uncommitted
            case .branch: availability.branch?.comparesWithDefault == true
            }
        }
    }

    nonisolated static func preferredSource(in sources: [OpenCodeDiffSource]) -> OpenCodeDiffSource? {
        [.turn, .session, .uncommitted, .branch].first(where: sources.contains)
    }
}
