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
        #expect(capabilities.sessionDetails == .supported)
        #expect(capabilities.sessionRename == .supported)
        #expect(capabilities.sessionDelete == .supported)
        #expect(capabilities.sessionChildren == .supported)
        #expect(capabilities.sessionAbort == .supported)
        #expect(capabilities.sessionTodos == .supported)
        #expect(capabilities.sessionRevert == .supported)
        #expect(capabilities.sessionUnrevert == .supported)
        #expect(capabilities.sessionSummarize == .supported)
        #expect(capabilities.sessionFork == .supported)
        #expect(capabilities.sessionSummarizeRequiresModel)
        #expect(capabilities.fileTree == .supported)
        #expect(capabilities.fileRead == .supported)
        #expect(capabilities.fileStatus == .supported)
        #expect(capabilities.fileSearch == .supported)
        #expect(capabilities.commandCatalog == .supported)
        #expect(capabilities.commandExecution == .supported)
        #expect(capabilities.shellExecution == .supported)
        #expect(capabilities.agentCatalog == .supported)
        #expect(capabilities.agentSelection == .supported)
    }

    @Test("V2 records current upstream gaps instead of claiming parity")
    func v2Capabilities() {
        let capabilities = OpenCodeV2Adapter().capabilities

        #expect(!capabilities.sessionDiff.isSupported)
        #expect(!capabilities.symbolSearch.isSupported)
        #expect(!capabilities.providerConnectionState.isSupported)
        #expect(!capabilities.modelReasoningMetadata.isSupported)
        #expect(!capabilities.modelTemperatureMetadata.isSupported)
        #expect(capabilities.sessionDetails == .supported)
        #expect(!capabilities.sessionRename.isSupported)
        #expect(!capabilities.sessionDelete.isSupported)
        #expect(!capabilities.sessionChildren.isSupported)
        #expect(capabilities.sessionAbort == .supported)
        #expect(!capabilities.sessionTodos.isSupported)
        #expect(capabilities.sessionRevert == .supported)
        #expect(capabilities.sessionUnrevert == .supported)
        #expect(capabilities.sessionSummarize == .supported)
        #expect(!capabilities.sessionFork.isSupported)
        #expect(!capabilities.sessionSummarizeRequiresModel)
        #expect(!capabilities.fileTree.isSupported)
        #expect(!capabilities.fileRead.isSupported)
        #expect(!capabilities.fileStatus.isSupported)
        #expect(capabilities.fileSearch == .supported)
        #expect(capabilities.commandCatalog == .supported)
        #expect(!capabilities.commandExecution.isSupported)
        #expect(!capabilities.shellExecution.isSupported)
        #expect(capabilities.agentCatalog == .supported)
        #expect(capabilities.agentSelection == .supported)
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

    @Test("An unavailable route never replaces a live SSE diff snapshot")
    func unavailableSnapshotReconciliation() {
        #expect(
            !OpenCodeSessionDiffReconciliation.shouldApplyFetchedSnapshot(
                support: OpenCodeV2Adapter().capabilities.sessionDiff,
                mutationBaseline: 3,
                currentMutation: 3
            )
        )
    }

    @Test("A supported unchanged route can reconcile its diff snapshot")
    func supportedSnapshotReconciliation() {
        #expect(
            OpenCodeSessionDiffReconciliation.shouldApplyFetchedSnapshot(
                support: OpenCodeV1Adapter().capabilities.sessionDiff,
                mutationBaseline: 3,
                currentMutation: 3
            )
        )
        #expect(
            !OpenCodeSessionDiffReconciliation.shouldApplyFetchedSnapshot(
                support: OpenCodeV1Adapter().capabilities.sessionDiff,
                mutationBaseline: 3,
                currentMutation: 4
            )
        )
    }
}
