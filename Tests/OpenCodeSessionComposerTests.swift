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
}
