import Foundation

/// OpenCode's instance-wide `share` config. Absent means `manual`; the
/// deprecated `autoshare: true` means `auto`. Only `disabled` hides publishing.
enum OpenCodeSessionSharePolicy: String, Equatable, Sendable {
    case manual, auto, disabled

    init(config: OpenCodeJSONValue) {
        let object = config.objectValue
        if let mode = object?["share"]?.stringValue.flatMap(Self.init(rawValue:)) {
            self = mode
        } else if case .bool(true)? = object?["autoshare"] {
            self = .auto
        } else {
            self = .manual
        }
    }
}

/// What the share sheet and its entry points may offer for one session.
/// Publishing and unpublishing are explicit: nothing here shares implicitly.
struct OpenCodeSessionSharePresentation: Equatable, Sendable {
    /// The server-returned public link, when the session is published.
    let link: URL?
    let isSupported: Bool
    /// Nil until the server's config is read; publishing stays offered meanwhile.
    let policy: OpenCodeSessionSharePolicy?
    let isUpdating: Bool

    var isPublished: Bool { link != nil }

    /// Hidden rather than failing: a server without the operation, or one
    /// configured never to share, shows no sharing controls for a private
    /// session. A published session always keeps its way back to private.
    var isAvailable: Bool {
        isSupported && (isPublished || policy != .disabled)
    }

    var canPublish: Bool {
        isSupported && !isPublished && policy != .disabled && !isUpdating
    }

    var canUnpublish: Bool {
        isSupported && isPublished && !isUpdating
    }

    var menuTitle: String { isPublished ? String(localized: "Share link") : String(localized: "Publish on web") }
    var menuSymbol: String { isPublished ? "square.and.arrow.up" : "globe" }
}
