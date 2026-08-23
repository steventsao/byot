import Foundation

enum OpenCodeSessionMutationOwner: Equatable, Sendable {
    case history(OpenCodeSessionHistoryAction)
    case sharing
}

@MainActor
final class OpenCodeSessionMutationCoordinator {
    private(set) var owner: OpenCodeSessionMutationOwner?

    var isAvailable: Bool {
        owner == nil
    }

    func acquire(_ candidate: OpenCodeSessionMutationOwner) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }

    func release(_ candidate: OpenCodeSessionMutationOwner) {
        guard owner == candidate else { return }
        owner = nil
    }
}
