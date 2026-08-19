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
        #expect(
            OpenCodeSessionComposerView.showsStopControl(canStop: true, text: "steer it") == false
        )
        #expect(
            OpenCodeSessionComposerView.showsStopControl(canStop: false, text: "") == false
        )
    }
}
