import Combine
import Foundation

/// The server-wide defaults BYOT can change: the global configuration behind
/// `GET/PATCH /global/config`, which every project on the server starts from.
///
/// Only these keys are ever written, and only the ones that changed. The document the
/// server returns carries provider keys and MCP headers; it's never sent back, so an
/// edit can't copy or clobber secrets. (v1 `PATCH /config` is no alternative: it merges
/// into a `config.json` in the project directory, which project loading doesn't read.)
struct OpenCodeServerSettings: Equatable, Sendable {
    /// `share`. Unset means manual, or automatic for configs with the legacy `autoshare`.
    enum Sharing: String, CaseIterable, Identifiable, Sendable {
        case manual, auto, disabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .manual: String(localized: "Manual")
            case .auto: String(localized: "Automatic")
            case .disabled: String(localized: "Off")
            }
        }
    }

    /// `autoupdate`: `true`, `"notify"` or `false`. Unset means automatic.
    enum Updates: String, CaseIterable, Identifiable, Sendable {
        case automatic, notify, off

        var id: String { rawValue }

        init(_ value: OpenCodeJSONValue?) {
            switch value {
            case .bool(false): self = .off
            case .string("notify"): self = .notify
            default: self = .automatic
            }
        }

        var json: OpenCodeJSONValue {
            switch self {
            case .automatic: .bool(true)
            case .notify: .string("notify")
            case .off: .bool(false)
            }
        }

        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .notify: String(localized: "Notify only")
            case .off: String(localized: "Off")
            }
        }
    }

    /// `provider/model`; `nil` lets OpenCode choose.
    var model: String?
    var smallModel: String?
    /// `nil` falls back to the build agent.
    var defaultAgent: String?
    var sharing: Sharing = .manual
    var updates: Updates = .automatic
    /// `snapshot`: file snapshots that make undo and revert possible. On by default.
    var snapshots = true
    /// Empty uses the server user's login shell.
    var shell = ""

    init(model: String? = nil, smallModel: String? = nil, defaultAgent: String? = nil, sharing: Sharing = .manual,
         updates: Updates = .automatic, snapshots: Bool = true, shell: String = "") {
        self.model = model
        self.smallModel = smallModel
        self.defaultAgent = defaultAgent
        self.sharing = sharing
        self.updates = updates
        self.snapshots = snapshots
        self.shell = shell
    }

    /// Reads a v1 `Config.Info` object, as `GET` and `PATCH /global/config` return it.
    init(_ object: [String: OpenCodeJSONValue]) {
        model = object["model"]?.stringValue?.trimmedNonEmpty
        smallModel = object["small_model"]?.stringValue?.trimmedNonEmpty
        defaultAgent = object["default_agent"]?.stringValue?.trimmedNonEmpty
        sharing = object["share"]?.stringValue.flatMap(Sharing.init(rawValue:))
            ?? (object["autoshare"] == .bool(true) ? .auto : .manual)
        updates = Updates(object["autoupdate"])
        snapshots = object["snapshot"] != .bool(false)
        shell = object["shell"]?.stringValue?.trimmedNonEmpty ?? ""
    }

    /// The `PATCH /global/config` body that turns `saved` into these settings: changed
    /// keys only. The server deep-merges it into its global opencode.json(c), so
    /// untouched settings, comments and secrets stay as they are. `null` removes a
    /// model or agent so OpenCode chooses again, and an empty shell removes the shell,
    /// which is how the server expects a shell to go back to the default.
    func patch(from saved: Self) -> [String: OpenCodeJSONValue] {
        var patch: [String: OpenCodeJSONValue] = [:]
        func optional(_ key: String, _ value: String?, _ old: String?) {
            let value = value?.trimmedNonEmpty
            if value != old { patch[key] = value.map(OpenCodeJSONValue.string) ?? .null }
        }
        optional("model", model, saved.model)
        optional("small_model", smallModel, saved.smallModel)
        optional("default_agent", defaultAgent, saved.defaultAgent)
        if sharing != saved.sharing { patch["share"] = .string(sharing.rawValue) }
        if updates != saved.updates { patch["autoupdate"] = updates.json }
        if snapshots != saved.snapshots { patch["snapshot"] = .bool(snapshots) }
        let shell = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        if shell != saved.shell { patch["shell"] = .string(shell) }
        return patch
    }
}

/// Choices for the settings pickers: connected providers' models and primary agents.
struct OpenCodeServerSettingsOptions: Equatable, Sendable {
    var providers: [OpenCodeProviderModels] = []
    var agents: [OpenCodeAgentOption] = []

    func model(_ qualifiedID: String?) -> OpenCodeModelOption? {
        guard let qualifiedID else { return nil }
        return providers.lazy.flatMap(\.models).first { $0.qualifiedID == qualifiedID }
    }

    func agent(_ id: String?) -> OpenCodeAgentOption? {
        guard let id else { return nil }
        return agents.first { $0.id == id || $0.name == id }
    }
}

// MARK: - Store

/// Loads the server's global settings, keeps an editable draft, and saves only what changed.
@MainActor
final class OpenCodeServerSettingsStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
        case unsupported
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var saved = OpenCodeServerSettings()
    @Published var draft = OpenCodeServerSettings()
    @Published private(set) var options = OpenCodeServerSettingsOptions()
    /// Set when models or agents couldn't load. The pickers still offer what's set.
    @Published private(set) var optionsError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    private let service: any OpenCodeServerContextServicing
    private var didLoad = false

    init(service: any OpenCodeServerContextServicing) {
        self.service = service
    }

    var patch: [String: OpenCodeJSONValue] { draft.patch(from: saved) }
    var hasChanges: Bool { phase == .loaded && !patch.isEmpty }

    /// The first load only: the form reappears after every pushed picker, and reloading
    /// then would throw away the draft.
    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func load() async {
        didLoad = true
        phase = .loading
        saveError = nil
        let service = service
        async let settings = Self.result { try await service.serverSettings() }
        async let options = Self.result { try await service.serverSettingsOptions() }
        switch await settings {
        case .success(let value):
            saved = value
            draft = value
            phase = .loaded
        case .failure(let error):
            if (error as? OpenCodeServerContextError) == .unsupported {
                phase = .unsupported
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
        switch await options {
        case .success(let value):
            self.options = value
            optionsError = nil
        case .failure(let error):
            optionsError = (error as? OpenCodeServerContextError) == .unsupported ? nil : error.localizedDescription
        }
    }

    /// Sends the changed settings. The server answers with its merged global config, which
    /// becomes the saved state, so anything it normalized reads back as it stored it.
    @discardableResult
    func save() async -> Bool {
        let patch = patch
        guard phase == .loaded, !patch.isEmpty, !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let updated = try await service.updateServerSettings(patch)
            saved = updated
            draft = updated
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func discardChanges() {
        draft = saved
        saveError = nil
    }

    private nonisolated static func result<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
