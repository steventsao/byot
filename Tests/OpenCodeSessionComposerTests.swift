import Testing
@testable import byot

@Suite("OpenCode session composer")
struct OpenCodeSessionComposerTests {
    @Test(
        "Stop control shows only while a turn can be stopped and the composer is empty",
        .bug(id: "ASC-AJ_1RzAN0eTwQSmWi5NHhyk"),
        .bug(id: "ASC-ALuK6Dbfqxcyi8191d8B-ds")
    )
    func stopControlVisibility() {
        #expect(OpenCodeSessionComposerView.showsStopControl(canStop: true, text: ""))
        #expect(OpenCodeSessionComposerView.showsStopControl(canStop: true, text: "  \n"))
        #expect(!OpenCodeSessionComposerView.showsStopControl(canStop: true, text: "", hasAttachments: true))
        #expect(
            OpenCodeSessionComposerView.showsStopControl(canStop: true, text: "steer it") == false
        )
        #expect(
            OpenCodeSessionComposerView.showsStopControl(canStop: false, text: "") == false
        )
    }

    @Test(
        "The composer only carries its knobs while it holds focus or a draft",
        .bug(id: "ASC-AOZmN-SID8Bh11kUI4sRAT0")
    )
    func expandedControlVisibility() {
        #expect(OpenCodeSessionComposerView.showsExpandedControls(isFocused: true, text: ""))
        #expect(OpenCodeSessionComposerView.showsExpandedControls(isFocused: false, text: "draft"))
        #expect(OpenCodeSessionComposerView.showsExpandedControls(
            isFocused: false, text: "", hasAttachments: true))
        // Sending clears the draft and releases focus, which is what folds the
        // container back to a single row.
        #expect(OpenCodeSessionComposerView.showsExpandedControls(isFocused: false, text: "") == false)
        #expect(OpenCodeSessionComposerView.showsExpandedControls(
            isFocused: false, text: "  \n ") == false)
    }

    @Test(
        "Composer knobs trade their names for icons before the row can outgrow the input",
        .bug(id: "ASC-AL92ozHEMfBSiCvNBmFR3KQ")
    )
    func knobDensityOrder() {
        // The row shows the first of these that fits, so agent and effort give
        // up their names before the model does.
        #expect(OpenCodeComposerKnobDensity.allCases == [.names, .compact, .icons])
        let named = OpenCodeComposerKnobDensity.allCases.map {
            [$0.showsModelName, $0.showsAgentName, $0.showsVariantName]
        }
        #expect(named == [[true, true, true], [true, false, false], [false, false, false]])
    }

    @Test(
        "The conversation header names an unknown status so the composer needs no spinner",
        .bug(id: "ASC-AEk0EYWkKW0QGxg8A34z3r0"),
        .bug(id: "ASC-AJvs6pGkEt5k3xS1gTpvmDI")
    )
    func headerNamesUnknownStatus() {
        #expect(OpenCodeStatusLabel.title(status: .idle, eventConnected: true, isStatusKnown: false) == "Connecting")
        // A dropped event stream still comes first.
        #expect(OpenCodeStatusLabel.title(status: .idle, eventConnected: false, isStatusKnown: false) == "Reconnecting")
        #expect(OpenCodeStatusLabel.title(status: .busy, eventConnected: true, isStatusKnown: true) == "Working")
        // Session list rows only draw a status they have.
        #expect(OpenCodeStatusLabel.title(status: .idle, eventConnected: nil) == "Idle")
    }
}
