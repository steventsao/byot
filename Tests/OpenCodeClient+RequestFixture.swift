import Foundation

@testable import byot

// Wire-format assertions explicitly exercise the v1 adapter.
extension OpenCodeClient {
    func makeSendMessageRequest(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String,
        attachments: [OpenCodePromptAttachment] = []
    ) throws -> URLRequest {
        try OpenCodeV1Adapter(transport: transport, profile: profile).makeSendMessageRequest(
            sessionID: sessionID, directory: directory, workspace: workspace, model: model, text: text,
            attachments: attachments)
    }

}
