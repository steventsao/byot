import Foundation

struct OpenCodeAgentOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?

    static func parse(_ value: OpenCodeJSONValue) -> Self? {
        guard let object = value.objectValue,
              object["hidden"] != .bool(true),
              let mode = object["mode"]?.stringValue,
              mode == "primary" || mode == "all",
              let name = object["name"]?.stringValue else { return nil }
        return Self(id: object["id"]?.stringValue ?? name, name: name,
                    description: object["description"]?.stringValue)
    }
}

struct OpenCodeSlashCommand: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case command, skill }
    let name: String
    let description: String?
    let kind: Kind
    var id: String { "\(kind.rawValue):\(name)" }
}

struct OpenCodeCommandInvocation: Equatable, Sendable {
    let name: String
    let arguments: String
    let kind: OpenCodeSlashCommand.Kind

    static func parse(_ text: String, catalog: [OpenCodeSlashCommand]) -> Self? {
        guard text.hasPrefix("/") else { return nil }
        let suffix = text.dropFirst()
        let boundary = suffix.firstIndex(where: \.isWhitespace) ?? suffix.endIndex
        let name = String(suffix[..<boundary])
        // Server commands take precedence over slash skills, as in OpenCode.
        guard let command = catalog.first(where: { $0.name == name && $0.kind == .command })
                ?? catalog.first(where: { $0.name == name }) else { return nil }
        return Self(name: name,
                    arguments: String(suffix[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: command.kind)
    }
}

struct OpenCodeComposerCatalog: Equatable, Sendable {
    var agents: [OpenCodeAgentOption] = []
    var commands: [OpenCodeSlashCommand] = []
    var inheritedAgent: String?
    var inheritedModelID: String?
    var inheritedVariant: String?
    var supportsVariants = false
    var unavailableReason: String?
}

extension OpenCodeFeatureContext {
    func composerQuery(directory: String, workspace: String?) -> [URLQueryItem] {
        let prefix = serverProtocol == .v2 ? "location[" : ""
        let suffix = serverProtocol == .v2 ? "]" : ""
        var query = [URLQueryItem(name: "\(prefix)directory\(suffix)", value: directory)]
        if let workspace, !workspace.isEmpty {
            query.append(URLQueryItem(name: "\(prefix)workspace\(suffix)", value: workspace))
        }
        return query
    }

    func composerSchemaProperties(_ path: String, method: String = "post") -> [String: OpenCodeJSONValue] {
        schema?.objectValue?["paths"]?.objectValue?[path]?.objectValue?[method]?.objectValue?["requestBody"]?
            .objectValue?["content"]?.objectValue?["application/json"]?.objectValue?["schema"]?
            .objectValue?["properties"]?.objectValue ?? [:]
    }

    var supportsModelVariants: Bool {
        serverProtocol == .v1 || schema?.objectValue?["components"]?.objectValue?["schemas"]?
            .objectValue?["Model.Ref"]?.objectValue?["properties"]?.objectValue?["variant"] != nil
    }
}

extension OpenCodeClient {
    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        let context = try await featureContext()
        return try await Self.loadComposerCatalog(context, sessionID: sessionID, directory: directory, workspace: workspace)
    }

    static func loadComposerCatalog(_ context: OpenCodeFeatureContext, sessionID: String,
                                   directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        var catalog = OpenCodeComposerCatalog(supportsVariants: context.supportsModelVariants)
        let isV2 = context.serverProtocol == .v2
        let prefix = isV2 ? ["api"] : []
        let query = context.composerQuery(directory: directory, workspace: workspace)
        func list(_ name: String) async throws -> [OpenCodeJSONValue] {
            let value: OpenCodeJSONValue = try await context.transport.get(prefix + [name], query: query)
            if isV2 { return value.objectValue?["data"]?.arrayValue ?? [] }
            return value.arrayValue ?? []
        }
        // Catalog failures are isolated: missing custom commands cannot hide agents.
        if !isV2 || (context.supports("/api/agent") && context.supports("/api/session/{sessionID}/agent", method: "post")) {
            do { catalog.agents = try await list("agent").compactMap(OpenCodeAgentOption.parse) }
            catch { catalog.unavailableReason = error.localizedDescription }
        }
        if !isV2 || (context.supports("/api/command") && context.supports("/api/session/{sessionID}/command", method: "post")) {
            do {
                catalog.commands = try await list("command").compactMap { raw in
                    guard let object = raw.objectValue, let name = object["name"]?.stringValue else { return nil }
                    return OpenCodeSlashCommand(name: name, description: object["description"]?.stringValue, kind: .command)
                }
            } catch { catalog.unavailableReason = error.localizedDescription }
        }
        // Only advertise skills explicitly marked slash-capable, with a supported attachment contract.
        if isV2, context.supports("/api/skill"),
           context.composerSchemaProperties("/api/session/{sessionID}/prompt")["skills"] != nil {
            do {
                catalog.commands += try await list("skill").compactMap { raw in
                    guard let object = raw.objectValue, object["slash"] == .bool(true),
                          let id = object["id"]?.stringValue else { return nil }
                    return OpenCodeSlashCommand(name: id, description: object["description"]?.stringValue, kind: .skill)
                }
            } catch { catalog.unavailableReason = error.localizedDescription }
        }
        if isV2, context.supports("/api/session/{sessionID}") {
            let raw: OpenCodeJSONValue = try await context.transport.get(["api", "session", sessionID], query: [])
            let session = raw.objectValue?["data"]?.objectValue
            catalog.inheritedAgent = session?["agent"]?.stringValue
            if let model = session?["model"]?.objectValue,
               let provider = model["providerID"]?.stringValue, let id = model["id"]?.stringValue {
                catalog.inheritedModelID = "\(provider)/\(id)"
                // Shipped v2 betas serialize an omitted switch-model variant as
                // the reserved "default" reference, not an advertised effort choice.
                catalog.inheritedVariant = model["variant"]?.stringValue.flatMap { $0 == "default" ? nil : $0 }
            }
        }
        catalog.agents.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        catalog.commands.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return catalog
    }
}
