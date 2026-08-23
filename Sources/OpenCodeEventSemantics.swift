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
        switch type {
        case "permission.asked", "permission.replied",
             "permission.v2.asked", "permission.v2.replied",
             "question.asked", "question.replied", "question.rejected",
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
