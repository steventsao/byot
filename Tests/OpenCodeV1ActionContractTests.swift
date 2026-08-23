import Foundation
import Testing
@testable import byot

struct OpenCodeV1ActionContractTests {
    @Test("Current v1 action routes are one non-deprecated family")
    func currentPaths() {
        let paths = [
            OpenCodeV1ActionContract.permissionCollectionPath,
            OpenCodeV1ActionContract.permissionReplyPath(requestID: "per_1"),
            OpenCodeV1ActionContract.questionCollectionPath,
            OpenCodeV1ActionContract.questionReplyPath(requestID: "que_1"),
            OpenCodeV1ActionContract.questionRejectPath(requestID: "que_1"),
        ]

        #expect(paths == [
            ["permission"],
            ["permission", "per_1", "reply"],
            ["question"],
            ["question", "que_1", "reply"],
            ["question", "que_1", "reject"],
        ])
        #expect(paths.allSatisfy { !$0.contains("api") })
        #expect(paths.allSatisfy { !$0.contains("session") })
    }

    @Test("Current v1 SSE action events are exhaustive")
    func currentSSETypes() {
        #expect(OpenCodeV1ActionContract.pendingEventTypes == [
            "permission.asked",
            "permission.replied",
            "question.asked",
            "question.replied",
            "question.rejected",
        ])
    }

    @Test("Current permission asked event carries session provenance")
    func permissionAskedEvent() throws {
        let event = try JSONDecoder().decode(
            OpenCodeEvent.self,
            from: Data(#"{"id":"evt_1","type":"permission.asked","properties":{"id":"per_1","sessionID":"ses_1","permission":"bash","patterns":["git status"],"metadata":{},"always":[],"tool":{"messageID":"msg_1","callID":"call_1"}}}"#.utf8)
        )

        #expect(event.sessionID == "ses_1")
        #expect(OpenCodeV1ActionContract.isPendingEvent(event.type))
        #expect(OpenCodeEventSemantics.effect(for: event.type) == .pendingActions)
    }

    @Test("Current question terminal events carry session provenance")
    func questionTerminalEvents() throws {
        for type in ["question.replied", "question.rejected"] {
            let data = Data(
                #"{"id":"evt_2","type":"\#(type)","properties":{"sessionID":"ses_1","requestID":"que_1"}}"#.utf8
            )
            let event = try JSONDecoder().decode(OpenCodeEvent.self, from: data)

            #expect(event.sessionID == "ses_1")
            #expect(OpenCodeV1ActionContract.isPendingEvent(event.type))
            #expect(OpenCodeEventSemantics.effect(for: event.type) == .pendingActions)
        }
    }

    @Test("Unrelated events do not enter the v1 action contract")
    func unrelatedEvent() {
        #expect(!OpenCodeV1ActionContract.isPendingEvent("message.updated"))
        #expect(!OpenCodeV1ActionContract.isPendingEvent("permission.v2.asked"))
    }
}
