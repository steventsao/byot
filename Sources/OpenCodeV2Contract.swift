import Foundation

// Negotiate from the server's own schema: beta wire contracts have changed
// independently of their 0.0.0 version strings. No user protocol switch needed.
struct OpenCodeV2Contract: Equatable, Sendable {
    let schema: OpenCodeJSONValue
    let flatPrompts: Bool
    let forms: Bool
    let projectList: Bool
    let sessionTitle: Bool

    init(schema: OpenCodeJSONValue) throws {
        self.schema = schema
        guard let paths = schema.objectValue?["paths"]?.objectValue,
              let prompt = paths["/api/session/{sessionID}/prompt"]?.objectValue?["post"]?.objectValue,
              let properties = prompt["requestBody"]?.objectValue?["content"]?.objectValue?["application/json"]?.objectValue?["schema"]?.objectValue?["properties"]?.objectValue,
              properties["text"] != nil || properties["prompt"] != nil else {
            throw OpenCodeConnectionError.server("This OpenCode 2 server exposes an unsupported prompt API. Update the server or byot.")
        }
        flatPrompts = properties["text"] != nil
        forms = paths["/api/session/{sessionID}/form"] != nil
        projectList = paths["/api/project"] != nil
        sessionTitle = paths["/api/session"]?.objectValue?["post"]?.objectValue?["requestBody"]?.objectValue?["content"]?.objectValue?["application/json"]?.objectValue?["schema"]?.objectValue?["properties"]?.objectValue?["title"] != nil
    }
}
