import Testing
@testable import byot

struct OpenCodeProtocolCapabilitiesTests {
    @Test("V1 preserves feature-complete desktop metadata")
    func v1Capabilities() {
        let capabilities = OpenCodeV1Adapter().capabilities

        #expect(capabilities.sessionDiff == .supported)
        #expect(capabilities.symbolSearch == .supported)
        #expect(capabilities.providerConnectionState == .supported)
        #expect(capabilities.modelReasoningMetadata == .supported)
        #expect(capabilities.modelTemperatureMetadata == .supported)
    }

    @Test("V2 records current upstream gaps instead of claiming parity")
    func v2Capabilities() {
        let capabilities = OpenCodeV2Adapter().capabilities

        #expect(!capabilities.sessionDiff.isSupported)
        #expect(!capabilities.symbolSearch.isSupported)
        #expect(!capabilities.providerConnectionState.isSupported)
        #expect(!capabilities.modelReasoningMetadata.isSupported)
        #expect(!capabilities.modelTemperatureMetadata.isSupported)
    }

    @Test("Unavailable session diff remains explainable and presentable")
    func unavailableDiffPresentation() {
        let support = OpenCodeV2Adapter().capabilities.sessionDiff
        let presentation = OpenCodeSessionDiffPresentation(
            diffs: [],
            support: support
        )

        #expect(presentation.canPresent)
        #expect(presentation.diffs.isEmpty)
        #expect(presentation.unavailableReason == support.unavailableReason)
    }

    @Test("A delivered diff takes precedence over static route support")
    func deliveredDiffPresentation() {
        let diff = OpenCodeDiff(
            file: "Sources/App.swift",
            patch: "@@ -1 +1 @@",
            additions: 2,
            deletions: 1,
            status: "modified"
        )
        let presentation = OpenCodeSessionDiffPresentation(
            diffs: [diff],
            support: OpenCodeV2Adapter().capabilities.sessionDiff
        )

        #expect(presentation.canPresent)
        #expect(presentation.diffs == [diff])
        #expect(presentation.unavailableReason == nil)
    }
}
