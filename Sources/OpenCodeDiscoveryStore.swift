import Combine
import Foundation

@MainActor
final class OpenCodeDiscoveryStore: ObservableObject {
    @Published private(set) var servers: [OpenCodeDiscoveredServer] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private let browser: any OpenCodeBonjourBrowsing

    init(browser: any OpenCodeBonjourBrowsing = OpenCodeBonjourBrowser()) {
        self.browser = browser
    }

    func start() {
        guard !isSearching else { return }
        isSearching = true
        errorMessage = nil
        browser.start { [weak self] update in
            guard let self else { return }
            switch update {
            case .services(let records):
                servers = OpenCodeBonjourServiceResolver.resolve(records)
                errorMessage = nil
            case .settled:
                isSearching = false
                errorMessage = nil
            case .failure(let message):
                isSearching = false
                errorMessage = message
            }
        }
    }

    func stop() {
        browser.stop()
        isSearching = false
    }
}
