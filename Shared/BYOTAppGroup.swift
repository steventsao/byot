import Foundation

/// State the app shares with its widget and share extensions. Without the App
/// Group entitlement (for example an unsigned simulator build) the suite still
/// works but stays private to the process that wrote it, and there is no
/// shared container.
enum BYOTAppGroup {
    static let identifier = "group.com.steventsao.byot"
    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
