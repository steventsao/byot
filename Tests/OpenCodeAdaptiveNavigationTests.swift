import Foundation
import Testing
@testable import byot

@Suite("iPad split view and keyboard shortcuts")
@MainActor
struct OpenCodeAdaptiveNavigationTests {
    private let mini = OpenCodeServerProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Mac mini",
        baseURL: "https://mini.example.test")
    private let windows = OpenCodeServerProfile(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Windows",
        baseURL: "https://windows.example.test")

    @Test("⌘] and ⌘[ move through the list and wrap at the ends, like OpenCode's web app")
    func stepWrapsAround() {
        let ids = ["a", "b", "c"]
        #expect(OpenCodeSessionStep.next.target(from: "a", in: ids) == "b")
        #expect(OpenCodeSessionStep.previous.target(from: "b", in: ids) == "a")
        #expect(OpenCodeSessionStep.next.target(from: "c", in: ids) == "a")
        #expect(OpenCodeSessionStep.previous.target(from: "a", in: ids) == "c")
        #expect(OpenCodeSessionStep.next.target(from: "only", in: ["only"]) == "only")
    }

    @Test("With nothing open, or the open session filtered out, switching starts from an end")
    func stepStartsFromAnEnd() {
        let ids = ["a", "b", "c"]
        #expect(OpenCodeSessionStep.next.target(from: nil, in: ids) == "a")
        #expect(OpenCodeSessionStep.previous.target(from: nil, in: ids) == "c")
        #expect(OpenCodeSessionStep.next.target(from: "hidden", in: ids) == "a")
        #expect(OpenCodeSessionStep.previous.target(from: "hidden", in: ids) == "c")
        #expect(OpenCodeSessionStep.next.target(from: nil, in: []) == nil)
        #expect(OpenCodeSessionStep.previous.target(from: "a", in: []) == nil)
    }

    @Test("Switching follows the grouped list and skips collapsed projects unless searching")
    func displayedOrder() {
        let groups = [
            (id: "/byot", sessions: [session("one", in: "/byot"), session("two", in: "/byot")]),
            (id: "/docs", sessions: [session("three", in: "/docs")]),
            (id: "/web", sessions: [session("four", in: "/web")]),
        ]
        #expect(OpenCodeSessionListOrder.displayed(groups: groups, collapsed: [], isSearching: false)
            .map(\.id) == ["one", "two", "three", "four"])
        #expect(OpenCodeSessionListOrder.displayed(groups: groups, collapsed: ["/docs"], isSearching: false)
            .map(\.id) == ["one", "two", "four"])
        // Search expands every project, so its matches stay reachable.
        #expect(OpenCodeSessionListOrder.displayed(groups: groups, collapsed: ["/docs"], isSearching: true)
            .map(\.id) == ["one", "two", "three", "four"])
    }

    @Test("A session listed under two projects is visited once")
    func displayedOrderSkipsDuplicates() {
        let shared = session("shared", in: "/byot")
        let groups = [(id: "/byot", sessions: [shared]), (id: "/byot-copy", sessions: [shared, session("x", in: "/x")])]
        #expect(OpenCodeSessionListOrder.displayed(groups: groups, collapsed: [], isSearching: false)
            .map(\.id) == ["shared", "x"])
    }

    @Test("The sidebar highlights only the open session on the same server and directory")
    func detailShowsSession() {
        let open = session("ses_1", in: "/byot")
        let detail = OpenCodeSplitDetail.session(selection(open, on: mini))
        #expect(detail.shows(open, on: mini.id))
        #expect(!detail.shows(open, on: windows.id))
        #expect(!detail.shows(session("ses_1", in: "/elsewhere"), on: mini.id))
        #expect(!detail.shows(session("ses_2", in: "/byot"), on: mini.id))
        #expect(detail.session?.id == "ses_1")
        #expect(detail.serverID == mini.id)

        let form = OpenCodeSplitDetail.newSession(OpenCodeNewSessionRoute(), serverID: mini.id)
        #expect(form.session == nil)
        #expect(!form.shows(open, on: mini.id))
        #expect(form.serverID == mini.id)
    }

    @Test("Switching servers clears a detail that belongs to the previous one")
    func detailRetainedForActiveServer() {
        let detail = OpenCodeSplitDetail.session(selection(session("ses_1", in: "/byot"), on: mini))
        #expect(detail.retained(forActiveServer: mini.id) == detail)
        #expect(detail.retained(forActiveServer: windows.id) == nil)
        #expect(detail.retained(forActiveServer: nil) == nil)

        let form = OpenCodeSplitDetail.newSession(OpenCodeNewSessionRoute(), serverID: windows.id)
        #expect(form.retained(forActiveServer: windows.id) == form)
        #expect(form.retained(forActiveServer: mini.id) == nil)
    }

    @Test("Each open is its own detail, so a notification for the open session reloads it")
    func detailIdentity() {
        let open = session("ses_1", in: "/byot")
        let first = OpenCodeSplitDetail.session(selection(open, on: mini))
        let again = OpenCodeSplitDetail.session(selection(open, on: mini))
        #expect(first == first)
        #expect(first != again)
        #expect(first.id != again.id)
    }

    @Test("Shortcuts need a server and no sheet; switching sessions needs the sidebar")
    func commandAvailability() {
        typealias Availability = OpenCodeAppCommandActions.Availability
        let split = Availability(hasServer: true, isSplit: true, isPresentingSheet: false)
        #expect(split.newSession && split.searchSessions && split.switchSessions)

        let compact = Availability(hasServer: true, isSplit: false, isPresentingSheet: false)
        #expect(compact.newSession && compact.searchSessions)
        #expect(!compact.switchSessions)

        for blocked in [
            Availability(hasServer: false, isSplit: true, isPresentingSheet: false),
            Availability(hasServer: true, isSplit: true, isPresentingSheet: true),
        ] {
            #expect(!blocked.newSession && !blocked.searchSessions && !blocked.switchSessions)
        }
    }

    @Test("The conversation on screen owns ⌘↩ and ⌘., whichever order screens report in")
    func keyboardRouterFollowsTheScreenOnTop() {
        let router = OpenCodeKeyboardRouter()
        let first = UUID(), second = UUID()
        #expect(router.top == nil)

        router.update(first, OpenCodeComposerCommandActions(send: {}, sendTitle: "Send Message"))
        #expect(router.top?.state == .init(canSend: true, canStop: false, sendTitle: "Send Message"))

        // A pushed conversation appears before the one beneath reports it left.
        router.update(second, OpenCodeComposerCommandActions(stop: {}, sendTitle: "Queue Message"))
        router.update(first, OpenCodeComposerCommandActions(send: {}, stop: {}))
        #expect(router.top?.state == .init(canSend: false, canStop: true, sendTitle: "Queue Message"))
        router.update(first, nil)
        #expect(router.top?.state.sendTitle == "Queue Message")

        // Popping back hands the shortcuts to the conversation beneath.
        router.update(second, nil)
        #expect(router.top == nil)
        router.update(first, OpenCodeComposerCommandActions(send: {}))
        #expect(router.top?.state.canSend == true)
        router.update(first, nil)
        router.update(first, nil)
        #expect(router.top == nil)
    }

    @Test("⌘↩ sends whenever the send button would")
    func keyboardSend() {
        typealias Composer = OpenCodeSessionComposerView
        #expect(Composer.sendsFromKeyboard(text: "Run the tests", hasAttachments: false, canSubmit: true, isImporting: false))
        #expect(Composer.sendsFromKeyboard(text: "  ", hasAttachments: true, canSubmit: true, isImporting: false))
        #expect(!Composer.sendsFromKeyboard(text: " \n ", hasAttachments: false, canSubmit: true, isImporting: false))
        #expect(!Composer.sendsFromKeyboard(text: "Run the tests", hasAttachments: false, canSubmit: false, isImporting: false))
        #expect(!Composer.sendsFromKeyboard(text: "Run the tests", hasAttachments: true, canSubmit: true, isImporting: true))
    }

    private func selection(_ session: OpenCodeSession, on profile: OpenCodeServerProfile) -> OpenCodeSessionSelection {
        OpenCodeSessionSelection(client: OpenCodeClient(profile: profile, password: "fixture"), session: session)
    }

    private func session(_ id: String, in directory: String) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: directory, workspaceID: nil, directory: directory, parentID: nil,
                        summary: nil, title: id, agent: nil, version: "1.18.29",
                        time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil))
    }
}
