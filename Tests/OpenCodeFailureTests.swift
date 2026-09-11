import Foundation
import Testing
@testable import byot

struct OpenCodeFailureTests {
    @Test func currentBetaRetainsRecoveryWhenItOmitsTheProviderBody() throws {
        let message = try #require(OpenCodeV2Normalization.message([
            "id": .string("assistant"), "type": .string("assistant"), "content": .array([]),
            "error": .object(["type": .string("provider.invalid-request"), "message": .string("Provider request failed with HTTP 410"), "status": .number(410)])
        ], sessionID: "session"))
        #expect(message.info.error?.displayMessage == "The selected model is no longer available.")
        #expect(message.info.error?.failure.isModelUnavailable == true)
    }

    @Test func reducesRetiredModelProblemEnvelope() {
        let raw = #"Gone: {"type":"about:blank","title":"Gone","status":410,"detail":"The model 'qwen/retired' has reached its end of life and is no longer available."}"#
        let error = OpenCodeMessageError(name: "APIError", data: ["message": .string(raw)])
        #expect(error.displayMessage == "The model 'qwen/retired' has reached its end of life and is no longer available.")
        #expect(error.failure.isModelUnavailable)
    }

    @Test func responseBodyBeatsGenericMessage() {
        let error = OpenCodeMessageError(name: "APIError", data: [
            "message": .string("API request failed"),
            "responseBody": .string(#"{"error":{"message":"Model old-model not found"}}"#)
        ])
        #expect(error.displayMessage == "Model old-model not found")
        #expect(error.failure.isModelUnavailable)
    }

    @Test func otherFailuresDoNotOfferModelRecovery() {
        for message in ["The server is unavailable", "Rate limit exceeded", "Invalid API key", "Gone: {\"detail\":\"File no longer available\"}"] {
            #expect(!OpenCodeFailure(message: message).isModelUnavailable)
        }
        #expect(OpenCodeFailure(message: "Timed out").message == "Timed out")
        #expect(OpenCodeFailure(message: "").message == "The request failed.")
    }
}
