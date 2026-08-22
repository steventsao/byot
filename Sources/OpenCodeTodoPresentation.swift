import Foundation

struct OpenCodeTodo: Codable, Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
        case unknown

        var isResolved: Bool {
            self == .completed || self == .cancelled
        }

        var isActive: Bool { !isResolved }
    }

    let content: String
    let status: String
    let priority: String

    var resolvedStatus: Status {
        Status(rawValue: status) ?? .unknown
    }
}

struct OpenCodeTodoPresentation: Equatable, Sendable {
    let todos: [OpenCodeTodo]
    private let support: OpenCodeFeatureSupport?

    init(todos: [OpenCodeTodo], support: OpenCodeFeatureSupport?) {
        self.todos = todos
        self.support = support
    }

    var totalCount: Int { todos.count }
    var resolvedCount: Int { todos.lazy.filter { $0.resolvedStatus.isResolved }.count }
    var activeCount: Int { todos.lazy.filter { $0.resolvedStatus.isActive }.count }
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(resolvedCount) / Double(totalCount)
    }
    var progressAccessibilityValue: String {
        "\(resolvedCount) of \(totalCount) resolved"
    }
    var headline: String? {
        todos.first(where: { $0.resolvedStatus == .inProgress })?.content
            ?? todos.first(where: { $0.resolvedStatus == .pending })?.content
            ?? todos.first?.content
    }
    var canPresent: Bool { !todos.isEmpty || unavailableReason != nil }
    var unavailableReason: String? {
        guard todos.isEmpty else { return nil }
        return support?.unavailableReason
    }
}

enum OpenCodeTodoEventProjection {
    static func todos(from event: OpenCodeEvent) -> [OpenCodeTodo]? {
        guard event.type == "todo.updated",
              let value = event.properties["todos"],
              let data = try? JSONEncoder().encode(value)
        else { return nil }
        return try? JSONDecoder().decode([OpenCodeTodo].self, from: data)
    }
}

enum OpenCodeTodoReconciliation {
    static func shouldApplyFetchedSnapshot(
        support: OpenCodeFeatureSupport?,
        mutationBaseline: Int,
        currentMutation: Int
    ) -> Bool {
        support?.isSupported == true && mutationBaseline == currentMutation
    }
}
