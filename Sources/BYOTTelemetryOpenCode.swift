import Foundation

/// The OpenCode half of the usage-data contract: how a server, a prompt, a
/// finished turn or an error becomes the fixed vocabulary in
/// docs/features/telemetry.md. Every function here returns enum-like values
/// or counts; none returns anything a person typed or named.
enum BYOTTelemetryOpenCode {
    enum Delivery: String {
        /// Sent to the server right away.
        case now
        /// Held in byot's local queue behind a running turn.
        case queued
        /// Handed to the paired computer's queue.
        case computerQueue = "computer_queue"
    }

    enum Surface: String {
        case connection
        case sessionList = "session_list"
        case send
        case turn
        case shell
    }

    /// Provider ids OpenCode ships. Anything else, including a self-named
    /// custom provider, reports as `other`, and so does its model id.
    static let knownProviders: Set<String> = [
        "anthropic", "openai", "google", "google-vertex", "google-vertex-anthropic", "openrouter",
        "github-copilot", "amazon-bedrock", "azure", "azure-cognitive-services", "groq", "xai", "mistral",
        "deepseek", "togetherai", "fireworks-ai", "cerebras", "ollama", "lmstudio", "llama", "opencode",
        "zai", "zhipuai", "moonshotai", "alibaba", "vercel", "huggingface", "perplexity", "cohere",
        "deepinfra", "baseten", "v0", "morph", "inception", "venice", "requesty", "minimax", "nvidia",
        "sambanova", "upstage", "cloudflare-workers-ai", "cortecs", "nebius", "io-net", "scaleway",
        "vultr", "gitlab", "zenmux", "iflowcn", "synthetic", "chutes",
    ]

    /// OpenCode's built-in primary agents. Custom agent names are the user's.
    static let primaryAgents: Set<String> = ["build", "plan"]

    // MARK: Servers

    static func transport(of url: URL?) -> String {
        url?.scheme?.lowercased() == "http" ? "http" : "https"
    }

    /// The kind of address, never the address: a tailnet name or address, a
    /// numeric private address, a bare or `.local` name, or a public name.
    static func hostKind(of url: URL?) -> String {
        guard var host = url?.host?.lowercased() else { return "unknown" }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasSuffix(".ts.net") || isTailnetAddress(host) { return "tailscale" }
        if OpenCodeLocalEndpointPolicy.isLocalHost(host) { return "local_address" }
        if host.hasSuffix(".local") || host.contains(".") == false { return "local_name" }
        return "public"
    }

    /// Tailscale hands out 100.64.0.0/10.
    private static func isTailnetAddress(_ host: String) -> Bool {
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        guard pieces.count == 4, pieces[0] == 100, (64...127).contains(pieces[1]) else { return false }
        return true
    }

    /// `major.minor` of the server's reported version, or `unknown`.
    static func serverVersion(_ raw: String?) -> String {
        guard let raw, let version = OpenCodeServerVersion(parsing: raw) else { return "unknown" }
        return "\(version.major).\(version.minor)"
    }

    static func serverConnected(profile: OpenCodeServerProfile,
                                serverProtocol: OpenCodeServerProtocol) -> BYOTTelemetry.Properties {
        let url = profile.normalizedURL
        return [
            "transport": transport(of: url),
            "host_kind": hostKind(of: url),
            "server_protocol": serverProtocol.rawValue,
            "server_version": serverVersion(profile.compatibility?.serverVersion),
            "compatibility": profile.compatibility?.state.rawValue ?? "unknown",
        ]
    }

    // MARK: Prompts and turns

    static func provider(_ id: String?) -> String {
        guard let id = id?.lowercased(), !id.isEmpty else { return "none" }
        return knownProviders.contains(id) ? id : "other"
    }

    /// The catalog model id when its provider is known; a model under a
    /// custom provider is the user's and reports as `other`.
    static func model(_ option: OpenCodeModelOption?) -> String {
        guard let option else { return "none" }
        guard knownProviders.contains(option.providerID.lowercased()) else { return "other" }
        let id = option.modelID.lowercased()
        return id.isEmpty ? "other" : String(id.prefix(BYOTTelemetry.maximumStringLength))
    }

    static func agent(_ id: String?) -> String {
        guard let id = id?.lowercased(), !id.isEmpty else { return "none" }
        return primaryAgents.contains(id) ? id : "other"
    }

    static func kind(of prompt: OpenCodeQueuedPrompt) -> String {
        switch prompt.command?.kind {
        case .skill: "skill"
        case .command: "command"
        case nil: "prompt"
        }
    }

    static func turnRequested(_ prompt: OpenCodeQueuedPrompt, delivery: Delivery) -> BYOTTelemetry.Properties {
        [
            "kind": kind(of: prompt),
            "delivery": delivery.rawValue,
            "agent": agent(prompt.agent),
            "provider": provider(prompt.model?.providerID),
            "model": model(prompt.model),
            "variant_set": prompt.variant != nil,
            "attachment_count": prompt.attachments.count,
            "file_reference_count": prompt.remoteReferences.count,
        ]
    }

    static func shellRequested() -> BYOTTelemetry.Properties {
        ["kind": "shell", "delivery": Delivery.now.rawValue]
    }

    /// Token totals come from the replies after the turn's own user message,
    /// as far as the transcript has loaded when the turn settles. A reply
    /// that has not arrived yet is simply not counted.
    static func turnCompleted(_ turn: BYOTTelemetryTurn, result: String,
                              messages: [OpenCodeMessageEnvelope], now: Date) -> BYOTTelemetry.Properties {
        let replies = replies(in: messages, after: turn.prompt.messageID)
        let tokens = replies.compactMap { OpenCodeReplyUsage($0)?.tokens }.reduce(.zero, +)
        return [
            "result": result,
            "duration_ms": Int(max(0, now.timeIntervalSince(turn.startedAt)) * 1_000),
            "agent": agent(turn.prompt.agent),
            "provider": provider(turn.prompt.model?.providerID),
            "model": model(turn.prompt.model),
            "input_tokens": Int(tokens.input + tokens.cacheRead + tokens.cacheWrite),
            "output_tokens": Int(tokens.output),
            "reasoning_tokens": Int(tokens.reasoning),
            "reply_count": replies.count,
        ]
    }

    /// True when a reply to this turn carries a provider or server error.
    static func replyFailed(in messages: [OpenCodeMessageEnvelope], after messageID: String) -> Bool {
        replies(in: messages, after: messageID).contains { $0.info.error != nil }
    }

    private static func replies(in messages: [OpenCodeMessageEnvelope], after messageID: String) -> [OpenCodeMessageEnvelope] {
        let start = messages.lastIndex { $0.info.id == messageID }
            ?? messages.lastIndex { $0.info.role.lowercased() == "user" }
        guard let start else { return [] }
        return messages.suffix(from: messages.index(after: start)).filter { $0.info.role.lowercased() == "assistant" }
    }

    // MARK: Errors

    /// A coarse class for a thrown error. Messages, hosts and paths stay out.
    static func errorClass(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? OpenCodeConnectionError {
            switch error {
            case .invalidProfile: return "invalid_profile"
            case .httpStatus(let status, _):
                switch status {
                case 401, 403: return "authentication"
                case 404, 405: return "not_found"
                case 408, 429: return "throttled"
                case 500...: return "server_error"
                default: return "http_error"
                }
            case .server(let message):
                return OpenCodeFailure(message: message).isModelUnavailable ? "model_unavailable" : "server_message"
            case .invalidResponse, .unexpectedContentType, .unexpectedEventContentType, .emptyResponse:
                return "invalid_response"
            case .eventBufferOverflow, .eventLineTooLong, .eventRecordTooLarge:
                return "event_stream"
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "other" }
        switch nsError.code {
        case NSURLErrorTimedOut: return "timeout"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "unreachable"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return "tls"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "app_transport_security"
        default: return "network"
        }
    }

    /// A class for a failed turn from the server's error envelope.
    static func failureClass(_ error: OpenCodeMessageError) -> String {
        if error.failure.isModelUnavailable { return "model_unavailable" }
        switch error.name {
        case "MessageAbortedError": return "aborted"
        case "ProviderAuthError": return "provider_auth"
        case "MessageOutputLengthError": return "output_length"
        case "APIError", "APICallError": return "provider_api"
        case "ContextOverflowError": return "context_overflow"
        default: return "turn_failed"
        }
    }

    static func errorOccurred(_ error: any Error, surface: Surface) -> BYOTTelemetry.Properties {
        ["error_class": errorClass(error), "surface": surface.rawValue]
    }

    static func turnFailed(_ error: OpenCodeMessageError) -> BYOTTelemetry.Properties {
        ["error_class": failureClass(error), "surface": Surface.turn.rawValue]
    }

    static func turnFailed(details: [String: OpenCodeJSONValue]?) -> BYOTTelemetry.Properties {
        turnFailed(OpenCodeMessageError(name: details?["type"]?.stringValue ?? details?["name"]?.stringValue ?? "unknown",
                                        data: details))
    }
}

/// The turn byot asked for most recently in one conversation.
struct BYOTTelemetryTurn: Sendable {
    let prompt: OpenCodeQueuedPrompt
    let startedAt: Date
}

extension BYOTTelemetry {
    func recordServerConnected(profile: OpenCodeServerProfile, serverProtocol: OpenCodeServerProtocol) {
        recordServerConnected(serverID: profile.id,
                              BYOTTelemetryOpenCode.serverConnected(profile: profile, serverProtocol: serverProtocol))
    }
}
