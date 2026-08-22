import Foundation

enum OpenCodeV1ActionContract {
    static let permissionCollectionPath = ["permission"]
    static let questionCollectionPath = ["question"]

    static let pendingEventTypes: Set<String> = [
        "permission.asked",
        "permission.replied",
        "question.asked",
        "question.replied",
        "question.rejected",
    ]

    static func permissionReplyPath(requestID: String) -> [String] {
        permissionCollectionPath + [requestID, "reply"]
    }

    static func questionReplyPath(requestID: String) -> [String] {
        questionCollectionPath + [requestID, "reply"]
    }

    static func questionRejectPath(requestID: String) -> [String] {
        questionCollectionPath + [requestID, "reject"]
    }

    static func isPendingEvent(_ type: String) -> Bool {
        pendingEventTypes.contains(type)
    }
}
