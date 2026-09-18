import Foundation

/// Provider credentials travel only through the existing authenticated transport.
/// v2 routes and payloads are selected from the connected server's OpenAPI schema.
struct OpenCodeProviderAuthService: OpenCodeProviderConnectionServicing {
  let context: OpenCodeFeatureContext
  private var v2: Bool { context.serverProtocol == .v2 }

  func providerConnections(directory: String, workspace: String?) async throws
    -> [OpenCodeProviderConnection]
  {
    try require(v2 ? "/api/integration" : "/provider", "get")
    let value: OpenCodeJSONValue = try await get(
      v2 ? ["api", "integration"] : ["provider"], directory, workspace)
    let providers: [OpenCodeProviderConnection]
    if v2 {
      guard let rows = value.objectValue?["data"]?.arrayValue else {
        throw OpenCodeConnectionError.invalidResponse
      }
      providers = try rows.map { row in
        guard let o = row.objectValue, let id = o["id"]?.stringValue,
          let rawMethods = o["methods"]?.arrayValue
        else { throw OpenCodeConnectionError.invalidResponse }
        let methods = try rawMethods.enumerated().compactMap { index, raw in
          try normalizeMethod(raw, index: index, providerID: id)
        }
        return OpenCodeProviderConnection(
          id: id, name: o["name"]?.stringValue ?? id,
          isConnected: !(o["connections"]?.arrayValue ?? []).isEmpty,
          methods: methods.isEmpty && rawMethods.isEmpty
            && context.supports("/api/integration/{integrationID}/connect/key", method: "post")
            ? [.init(id: "key", kind: .key, label: "API key")] : methods)
      }
    } else {
      let auth: OpenCodeJSONValue = try await get(["provider", "auth"], directory, workspace)
      guard let all = value.objectValue?["all"]?.arrayValue, let methods = auth.objectValue else {
        throw OpenCodeConnectionError.invalidResponse
      }
      let connected = Set(
        value.objectValue?["connected"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      var names: [String: String] = [:]
      for row in all {
        if let o = row.objectValue, let id = o["id"]?.stringValue {
          names[id] = o["name"]?.stringValue ?? id
        }
      }
      providers = try Set(names.keys).union(methods.keys).map { id in
        let raw = methods[id]?.arrayValue ?? []
        let normalized = try raw.enumerated().compactMap {
          try normalizeMethod($0.element, index: $0.offset, providerID: id)
        }
        return OpenCodeProviderConnection(
          id: id, name: names[id] ?? id, isConnected: connected.contains(id),
          methods: raw.isEmpty ? [.init(id: "key", kind: .key, label: "API key")] : normalized)
      }
    }
    return providers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func connectProviderKey(providerID: String, key: String, directory: String, workspace: String?)
    async throws
  {
    try await connectProviderKey(
      providerID: providerID, key: key, inputs: [:], directory: directory, workspace: workspace)
  }

  func connectProviderKey(
    providerID: String, key: String, inputs: [String: String], directory: String, workspace: String?
  ) async throws {
    let route = v2 ? "/api/integration/{integrationID}/connect/key" : "/auth/{providerID}"
    try require(route, v2 ? "post" : "put")
    guard v2 || inputs.isEmpty else { throw OpenCodeProviderUnsupportedError() }
    var body: [String: OpenCodeJSONValue] = ["key": .string(key)]
    if v2 {
      if !inputs.isEmpty { body["answer"] = .object(inputs.mapValues(OpenCodeJSONValue.string)) }
    } else {
      body["type"] = .string("api")
    }
    try await mutate(
      v2 ? ["api", "integration", providerID, "connect", "key"] : ["auth", providerID],
      method: v2 ? "POST" : "PUT", body: .object(body), directory: directory, workspace: workspace)
    if !v2 { try await dispose(directory, workspace) }
  }

  func startProviderOAuth(
    providerID: String, methodID: String, inputs: [String: String], directory: String,
    workspace: String?
  ) async throws -> OpenCodeProviderOAuthAuthorization {
    let route =
      v2
      ? "/api/integration/{integrationID}/connect/oauth" : "/provider/{providerID}/oauth/authorize"
    try require(route, "post")
    var body: [String: OpenCodeJSONValue]
    if v2 {
      body = ["methodID": .string(methodID)]
      let props = requestProperties(route)
      if props["answer"] != nil {
        body["answer"] = .object(inputs.mapValues(OpenCodeJSONValue.string))
      } else if props["inputs"] != nil {
        body["inputs"] = .object(inputs.mapValues(OpenCodeJSONValue.string))
      } else if !inputs.isEmpty {
        throw OpenCodeProviderUnsupportedError()
      }
    } else {
      guard let method = Int(methodID), method >= 0 else {
        throw OpenCodeProviderConnectionError.invalidMethod
      }
      body = [
        "method": .number(Double(method)),
        "inputs": .object(inputs.mapValues(OpenCodeJSONValue.string)),
      ]
    }
    let path =
      v2
      ? ["api", "integration", providerID, "connect", "oauth"]
      : ["provider", providerID, "oauth", "authorize"]
    let value: OpenCodeJSONValue = try await perform(
      path, method: "POST", body: .object(body), directory: directory, workspace: workspace)
    guard let o = (v2 ? value.objectValue?["data"] : value)?.objectValue,
      let rawURL = o["url"]?.stringValue, let mode = o[v2 ? "mode" : "method"]?.stringValue,
      ["auto", "code"].contains(mode)
    else { throw OpenCodeConnectionError.invalidResponse }
    let attemptID = v2 ? o["attemptID"]?.stringValue : "\(providerID):\(methodID)"
    guard let attemptID else { throw OpenCodeConnectionError.invalidResponse }
    let url: URL
    do { url = try OpenCodeProviderAuthorizationURLPolicy.validate(rawURL) } catch {
      if v2 {
        try? await cancelProviderOAuth(
          providerID: providerID, attemptID: attemptID, directory: directory, workspace: workspace)
      }
      throw error
    }
    let now = Date().timeIntervalSince1970 * 1000
    return .init(
      attemptID: attemptID, url: url, instructions: o["instructions"]?.stringValue ?? "",
      mode: mode == "auto" ? .automatic : .code,
      createdAt: o["time"]?.objectValue?["created"]?.numberValue ?? now,
      expiresAt: o["time"]?.objectValue?["expires"]?.numberValue ?? now + 15 * 60 * 1000)
  }

  func completeProviderOAuth(
    providerID: String, attemptID: String, code: String?, directory: String, workspace: String?
  ) async throws {
    if v2 {
      let path = try attemptPath(providerID, attemptID, operation: "post", complete: true)
      try await mutate(
        path, method: "POST", body: .object(code.map { ["code": .string($0)] } ?? [:]),
        directory: directory, workspace: workspace)
    } else {
      try await callback(providerID, attemptID, code, directory, workspace)
    }
  }

  func providerOAuthStatus(
    providerID: String, attemptID: String, directory: String, workspace: String?
  ) async throws -> OpenCodeProviderOAuthStatus {
    if !v2 {
      try await callback(providerID, attemptID, nil, directory, workspace)
      return .complete
    }
    let path = try attemptPath(providerID, attemptID, operation: "get")
    let value: OpenCodeJSONValue = try await get(path, directory, workspace)
    switch value.objectValue?["data"]?.objectValue?["status"]?.stringValue {
    case "pending": return .pending
    case "complete": return .complete
    case "expired": return .expired
    case "failed":
      return .failed(message: "Authorization was denied or failed. Start sign-in again.")
    default: throw OpenCodeConnectionError.invalidResponse
    }
  }

  func cancelProviderOAuth(
    providerID: String, attemptID: String, directory: String, workspace: String?
  ) async throws {
    guard v2 else { throw OpenCodeProviderUnsupportedError() }
    try await mutate(
      try attemptPath(providerID, attemptID, operation: "delete"), method: "DELETE", body: nil,
      directory: directory, workspace: workspace)
  }

  private func callback(
    _ providerID: String, _ attemptID: String, _ code: String?, _ directory: String,
    _ workspace: String?
  ) async throws {
    guard let method = Int(attemptID.split(separator: ":").last ?? "") else {
      throw OpenCodeProviderConnectionError.invalidMethod
    }
    var body: [String: OpenCodeJSONValue] = ["method": .number(Double(method))]
    if let code { body["code"] = .string(code) }
    try await mutate(
      ["provider", providerID, "oauth", "callback"], method: "POST", body: .object(body),
      directory: directory, workspace: workspace, timeout: code == nil ? 15 * 60 : 60)
    try await dispose(directory, workspace)
  }

  private func dispose(_ directory: String, _ workspace: String?) async throws {
    try await mutate(
      ["instance", "dispose"], method: "POST", body: nil, directory: directory, workspace: workspace
    )
  }

  private func attemptPath(
    _ provider: String, _ attempt: String, operation: String, complete: Bool = false
  ) throws -> [String] {
    let suffix = complete ? "/complete" : ""
    if context.supports(
      "/api/integration/{integrationID}/connect/oauth/{attemptID}" + suffix, method: operation)
    {
      return ["api", "integration", provider, "connect", "oauth", attempt]
        + (complete ? ["complete"] : [])
    }
    if context.supports("/api/integration/attempt/{attemptID}" + suffix, method: operation) {
      return ["api", "integration", "attempt", attempt] + (complete ? ["complete"] : [])
    }
    throw OpenCodeProviderUnsupportedError()
  }

  private func normalizeMethod(_ value: OpenCodeJSONValue, index: Int, providerID: String) throws
    -> OpenCodeProviderAuthMethod?
  {
    guard let o = value.objectValue, let type = o["type"]?.stringValue,
      ["oauth", "api", "key"].contains(type)
    else { return nil }
    let kind: OpenCodeProviderAuthMethodKind = type == "oauth" ? .oauth : .key
    let id = v2 ? o["id"]?.stringValue ?? "key" : String(index)
    let normalizedPrompts = try? prompts(o)
    var method = OpenCodeProviderAuthMethod(
      id: id, kind: kind,
      label: o["label"]?.stringValue ?? (kind == .key ? "API key" : "Sign in"),
      prompts: normalizedPrompts ?? [])
    if normalizedPrompts == nil {
      method.unavailableReason =
        "This method requires a form that byot cannot display yet. Choose another method or connect on the server."
    }
    if !v2, kind == .key, !method.prompts.isEmpty {
      method.unavailableReason =
        "This key method requires additional server setup. Connect it on the server, then reload models."
    }
    if v2, kind == .oauth, o["id"]?.stringValue == nil {
      method.unavailableReason = OpenCodeProviderUnsupportedError().localizedDescription
    }
    if providerID == "openai", kind == .oauth,
      method.label.localizedCaseInsensitiveContains("browser")
    {
      method.unavailableReason =
        "Browser sign-in returns to localhost on the server computer. Use headless sign-in on this phone."
    }
    if v2,
      !context.supports(
        "/api/integration/{integrationID}/connect/" + (kind == .key ? "key" : "oauth"),
        method: "post")
    {
      method.unavailableReason = OpenCodeProviderUnsupportedError().localizedDescription
    }
    if v2, let fields = o["form"]?.arrayValue,
      fields.contains(where: { $0.objectValue?["type"]?.stringValue != "string" })
    {
      method.unavailableReason =
        "This method requires a form that byot cannot display yet. Choose another method or connect on the server."
    }
    return method
  }

  private func prompts(_ method: [String: OpenCodeJSONValue]) throws -> [OpenCodeProviderAuthPrompt]
  {
    if let raw = method["prompts"] {
      return try JSONDecoder().decode(
        [OpenCodeProviderAuthPrompt].self, from: JSONEncoder().encode(raw))
    }
    return try (method["form"]?.arrayValue ?? []).compactMap {
      value -> OpenCodeProviderAuthPrompt? in
      guard let o = value.objectValue, let key = o["key"]?.stringValue,
        o["type"]?.stringValue == "string"
      else { return nil }
      let options = (o["options"]?.arrayValue ?? []).compactMap {
        option -> OpenCodeProviderAuthPromptOption? in
        guard let v = option.objectValue?["value"]?.stringValue else { return nil }
        return .init(
          label: option.objectValue?["label"]?.stringValue ?? v, value: v,
          hint: option.objectValue?["description"]?.stringValue)
      }
      var prompt = OpenCodeProviderAuthPrompt(
        kind: options.isEmpty || o["custom"] == .bool(true) ? .text : .select, key: key,
        message: o["title"]?.stringValue ?? key, placeholder: o["placeholder"]?.stringValue,
        options: options)
      prompt.required = o["required"] == .bool(true)
      prompt.defaultValue = o["default"]?.stringValue
      prompt.conditions = try (o["when"]?.arrayValue ?? []).map {
        try JSONDecoder().decode(
          OpenCodeProviderAuthPromptCondition.self, from: JSONEncoder().encode($0))
      }
      return prompt
    }
  }

  private func require(_ route: String, _ method: String) throws {
    guard context.supports(route, method: method) else { throw OpenCodeProviderUnsupportedError() }
  }
  private func requestProperties(_ route: String) -> [String: OpenCodeJSONValue] {
    context.schema?.objectValue?["paths"]?.objectValue?[route]?.objectValue?["post"]?.objectValue?[
      "requestBody"]?.objectValue?["content"]?.objectValue?["application/json"]?.objectValue?[
        "schema"]?.objectValue?["properties"]?.objectValue ?? [:]
  }
  private func query(_ directory: String, _ workspace: String?) -> [URLQueryItem] {
    var result: [URLQueryItem] =
      directory.isEmpty
      ? [] : [URLQueryItem(name: v2 ? "location[directory]" : "directory", value: directory)]
    if let workspace {
      result.append(.init(name: v2 ? "location[workspace]" : "workspace", value: workspace))
    }
    return result
  }
  private func get<T: Decodable>(_ path: [String], _ directory: String, _ workspace: String?)
    async throws -> T
  {
    try await perform(path, method: "GET", body: nil, directory: directory, workspace: workspace)
  }
  private func perform<T: Decodable>(
    _ path: [String], method: String, body: OpenCodeJSONValue?, directory: String,
    workspace: String?, timeout: TimeInterval = 60
  ) async throws -> T {
    var request = try context.transport.makeRequest(
      path: path, query: query(directory, workspace), method: method,
      body: body.map { try JSONEncoder().encode($0) })
    request.timeoutInterval = timeout
    do { return try await context.transport.perform(request) } catch { throw safeError(error) }
  }
  private func mutate(
    _ path: [String], method: String, body: OpenCodeJSONValue?, directory: String,
    workspace: String?, timeout: TimeInterval = 60
  ) async throws {
    var request = try context.transport.makeRequest(
      path: path, query: query(directory, workspace), method: method,
      body: body.map { try JSONEncoder().encode($0) })
    request.timeoutInterval = timeout
    do {
      let (data, response) = try await context.transport.data(for: request)
      try context.transport.validateEmptyResponse(data: data, response: response)
      if v2 {
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
          throw OpenCodeConnectionError.invalidResponse
        }
      } else {
        guard (try? JSONDecoder().decode(Bool.self, from: data)) == true else {
          throw OpenCodeConnectionError.invalidResponse
        }
      }
    } catch { throw safeError(error) }
  }
  private func safeError(_ error: Error) -> Error {
    // Do not echo arbitrary server messages, which may contain keys or codes.
    if let error = error as? OpenCodeConnectionError {
      if error.isUnsupportedRoute { return OpenCodeProviderUnsupportedError() }
      if case .httpStatus(let status, _) = error {
        return OpenCodeConnectionError.httpStatus(status, nil)
      }
      return OpenCodeConnectionError.server(
        "Provider authentication could not be completed. Check the server and try again.")
    }
    return error
  }
}

extension OpenCodeClient {
  func providerConnections(directory: String, workspace: String?) async throws
    -> [OpenCodeProviderConnection]
  {
    try await OpenCodeProviderAuthService(context: featureContext()).providerConnections(
      directory: directory, workspace: workspace)
  }
  func connectProviderKey(providerID: String, key: String, directory: String, workspace: String?)
    async throws
  {
    try await OpenCodeProviderAuthService(context: featureContext()).connectProviderKey(
      providerID: providerID, key: key, directory: directory, workspace: workspace)
  }
  func connectProviderKey(
    providerID: String, key: String, inputs: [String: String], directory: String, workspace: String?
  ) async throws {
    try await OpenCodeProviderAuthService(context: featureContext()).connectProviderKey(
      providerID: providerID, key: key, inputs: inputs, directory: directory, workspace: workspace)
  }
  func startProviderOAuth(
    providerID: String, methodID: String, inputs: [String: String], directory: String,
    workspace: String?
  ) async throws -> OpenCodeProviderOAuthAuthorization {
    try await OpenCodeProviderAuthService(context: featureContext()).startProviderOAuth(
      providerID: providerID, methodID: methodID, inputs: inputs, directory: directory,
      workspace: workspace)
  }
  func completeProviderOAuth(
    providerID: String, attemptID: String, code: String?, directory: String, workspace: String?
  ) async throws {
    try await OpenCodeProviderAuthService(context: featureContext()).completeProviderOAuth(
      providerID: providerID, attemptID: attemptID, code: code, directory: directory,
      workspace: workspace)
  }
  func providerOAuthStatus(
    providerID: String, attemptID: String, directory: String, workspace: String?
  ) async throws -> OpenCodeProviderOAuthStatus {
    try await OpenCodeProviderAuthService(context: featureContext()).providerOAuthStatus(
      providerID: providerID, attemptID: attemptID, directory: directory, workspace: workspace)
  }
  func cancelProviderOAuth(
    providerID: String, attemptID: String, directory: String, workspace: String?
  ) async throws {
    try await OpenCodeProviderAuthService(context: featureContext()).cancelProviderOAuth(
      providerID: providerID, attemptID: attemptID, directory: directory, workspace: workspace)
  }
}
