import AppIntents
import SwiftUI

/// Starts a session and sends a prompt without opening byot, so it works from
/// Siri, the Action button and Shortcuts automations. Sending asks OpenCode to
/// act on your machine, so it needs an unlocked iPhone, like the notification
/// actions do.
struct AskOpenCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OpenCode"
    static let description = IntentDescription(
        "Starts a new OpenCode session and sends it your prompt. Uses the model and agent you last picked on that server.",
        categoryName: "Sessions")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What should OpenCode do?")
    var prompt: String

    @Parameter(title: "Server", description: "Defaults to the server byot last showed.")
    var server: OpenCodeServerEntity?

    @Parameter(title: "Project", description: "Defaults to the server’s working directory, or its only project.",
               requestValueDialog: "Which project should OpenCode work in?")
    var project: OpenCodeProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask OpenCode \(\.$prompt)") {
            \.$server
            \.$project
        }
    }

    init() {}

    init(prompt: String, server: OpenCodeServerEntity? = nil, project: OpenCodeProjectEntity? = nil) {
        self.prompt = prompt
        self.server = server
        self.project = project
    }

    func perform() async throws -> some IntentResult & ReturnsValue<OpenCodeSessionEntity> & ProvidesDialog {
        let service = BYOTIntentService.live
        let serverID = server?.id ?? project?.project.serverID
        if let project, let server, project.project.serverID != server.id {
            throw BYOTIntentError.projectOnOtherServer
        }
        var result: BYOTAskResult
        do {
            result = try await service.ask(prompt: prompt, serverID: serverID, directory: project?.project.directory)
        } catch BYOTIntentError.needsProject {
            throw $project.needsValueError("Which project should OpenCode work in?")
        }
        if let project { result.session.projectName = project.project.name }
        await BYOTIntentEntityCache.remember([result.session])
        return .result(value: OpenCodeSessionEntity(result.session), dialog: "\(result.dialog)")
    }
}

/// Opens byot on a session, like tapping it in the widget.
struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Session"
    static let description = IntentDescription("Opens an OpenCode session in byot.", categoryName: "Sessions")
    static let openAppWhenRun = true

    @Parameter(title: "Session", requestValueDialog: "Which session?")
    var session: OpenCodeSessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$session)")
    }

    init() {}

    init(session: OpenCodeSessionEntity) {
        self.session = session
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let route = BYOTPushRoute(serverID: session.session.serverID, sessionID: session.session.sessionID,
                                  directory: session.session.directory, workspace: session.session.workspace)
        guard route.isValid else { throw BYOTIntentError.serverRemoved }
        BYOTPushNotifications.shared.pendingDestination = BYOTPushDestination(route: route, origin: .shortcut)
        return .result()
    }
}

/// Answers "what needs me?" across servers: sessions waiting on an approval or
/// a question, and turns that stopped with an error. Read-only, so it works
/// from the Lock Screen like the widget.
struct SessionsNeedingAttentionIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Sessions Needing Attention"
    static let description = IntentDescription(
        "Lists OpenCode sessions waiting for your approval or answer, and sessions whose last turn failed.",
        categoryName: "Sessions")

    @Parameter(title: "Server", description: "Leave empty to check every server saved in byot.")
    var server: OpenCodeServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check sessions needing attention") {
            \.$server
        }
    }

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<[OpenCodeSessionEntity]> & ProvidesDialog & ShowsSnippetView {
        let report = try await BYOTIntentService.live.attention(serverID: server?.id)
        await BYOTIntentEntityCache.remember(report.sessions)
        return .result(value: report.sessions.map(OpenCodeSessionEntity.init), dialog: "\(report.dialog)",
                       view: BYOTAttentionSnippet(report: report))
    }
}

extension BYOTIntentError: CustomLocalizedStringResourceConvertible {
    /// What Siri says and Shortcuts shows when an intent can't finish.
    var localizedStringResource: LocalizedStringResource { "\(errorDescription ?? "Something went wrong.")" }
}

struct BYOTAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .grayBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOpenCodeIntent(),
            phrases: [
                "Ask OpenCode in \(.applicationName)",
                "Start an OpenCode session in \(.applicationName)",
                "New \(.applicationName) session",
                "Ask OpenCode on \(\.$server) in \(.applicationName)",
            ],
            shortTitle: "Ask OpenCode",
            systemImageName: "text.bubble")
        AppShortcut(
            intent: SessionsNeedingAttentionIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "Check \(.applicationName) sessions",
                "Which \(.applicationName) sessions need attention",
                "Check \(.applicationName) sessions on \(\.$server)",
            ],
            shortTitle: "Needs Attention",
            systemImageName: "hand.raised")
        AppShortcut(
            intent: OpenSessionIntent(),
            phrases: [
                "Open a session in \(.applicationName)",
                "Open an OpenCode session in \(.applicationName)",
            ],
            shortTitle: "Open Session",
            systemImageName: "arrow.up.forward.app")
    }
}

/// The card Siri and Shortcuts show under the spoken answer.
struct BYOTAttentionSnippet: View {
    static let rowLimit = 4
    let report: BYOTAttentionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.sessions.isEmpty {
                summaryRow(symbol: "checkmark.circle.fill", tint: BYOTBrand.accent,
                           title: report.checkedServers == 0 ? "Couldn’t check sessions" : "Nothing needs you",
                           detail: report.runningCount > 0
                               ? (report.runningCount == 1 ? "1 session is running" : "\(report.runningCount) sessions are running")
                               : nil)
            } else {
                ForEach(report.sessions.prefix(Self.rowLimit)) { session in
                    sessionRow(session)
                }
                let remaining = report.sessions.count - Self.rowLimit
                if remaining > 0 {
                    Text("\(remaining) more in byot")
                        .font(.cleanCaption)
                        .foregroundStyle(BYOTBrand.mutedInk)
                }
            }
            if !report.unreachable.isEmpty {
                Label("Couldn’t fully check \(BYOTAttentionReport.list(report.unreachable))",
                      systemImage: "wifi.exclamationmark")
                    .font(.cleanCaption)
                    .foregroundStyle(BYOTBrand.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BYOTBrand.Space.md)
    }

    private func sessionRow(_ session: BYOTIntentSession) -> some View {
        let state = session.state ?? .needsResponse
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.cleanBodySemibold)
                .foregroundStyle(state.tint)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(BYOTBrand.ink)
                    .lineLimit(2)
                Text("\(state.title) · \(session.projectName) · \(session.serverName)")
                    .font(.cleanCaption)
                    .foregroundStyle(BYOTBrand.mutedInk)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(state.title), \(session.projectName) on \(session.serverName)")
    }

    private func summaryRow(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.cleanBodySemibold)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(BYOTBrand.ink)
                if let detail {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(BYOTBrand.mutedInk)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
