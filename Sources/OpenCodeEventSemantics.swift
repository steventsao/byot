import Foundation

enum OpenCodeEventEffect: Equatable, Sendable {
    case none
    case messages
    case busyAndMessages
    case idleAndMessages
    case pendingActions
}

enum OpenCodeEventSemantics {
    static func effect(for type: String) -> OpenCodeEventEffect {
        if OpenCodeV1ActionContract.isPendingEvent(type) {
            return .pendingActions
        }
        switch type {
        case "permission.v2.asked", "permission.v2.replied",
             "question.v2.asked", "question.v2.replied", "question.v2.rejected":
            return .pendingActions
        case "session.next.prompted", "session.next.prompt.admitted",
             "session.next.step.started", "session.next.shell.started":
            return .busyAndMessages
        default:
            return type.hasPrefix("session.next.") ? .messages : .none
        }
    }
}
