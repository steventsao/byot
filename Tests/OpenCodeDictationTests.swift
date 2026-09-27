import Foundation
import SwiftUI
import Testing
@testable import byot

@Suite("Composer dictation")
@MainActor
struct OpenCodeDictationTests {
    // MARK: Draft merging

    @Test("Spoken words follow typed text with a single space")
    func mergesAfterTypedText() {
        #expect(OpenCodeDictationDraft.merge("Fix the build", after: "") == "Fix the build")
        #expect(OpenCodeDictationDraft.merge("fix the build", after: "Please") == "Please fix the build")
        #expect(OpenCodeDictationDraft.merge("Next line", after: "First line\n") == "First line\nNext line")
        #expect(OpenCodeDictationDraft.merge("the parser", after: "Look at (") == "Look at (the parser")
        #expect(OpenCodeDictationDraft.merge("  padded  ", after: "Note: ") == "Note: padded")
        #expect(OpenCodeDictationDraft.merge("   ", after: "Unchanged") == "Unchanged")
    }

    @Test("Mid-sentence dictation isn't capitalized like a new sentence")
    func continuesSentenceCase() {
        #expect(OpenCodeDictationDraft.merge("Fix the build", after: "Please") == "Please fix the build")
        #expect(OpenCodeDictationDraft.merge("Fix the build", after: "Done.") == "Done. Fix the build")
        #expect(OpenCodeDictationDraft.merge("Fix the build", after: "Why? ") == "Why? Fix the build")
        #expect(OpenCodeDictationDraft.merge("Fix the build", after: "Notes\n") == "Notes\nFix the build")
        #expect(OpenCodeDictationDraft.merge("I think so", after: "Well") == "Well I think so")
        #expect(OpenCodeDictationDraft.merge("OpenCode crashed", after: "Look,") == "Look, OpenCode crashed")
        #expect(OpenCodeDictationDraft.merge("API keys", after: "Rotate the") == "Rotate the API keys")
        #expect(OpenCodeDictationDraft.merge("Fix it", after: "") == "Fix it")
    }

    @Test("Each live transcript replaces only what dictation wrote")
    func replacesItsOwnWords() {
        var draft = OpenCodeDictationDraft(base: "Hi")
        #expect(!draft.hasDictatedText)
        let first = draft.apply("there", to: "Hi")
        #expect(first == "Hi there")
        let revised = draft.apply("there, friend.", to: "Hi there")
        #expect(revised == "Hi there, friend.")
        #expect(draft.hasDictatedText)
    }

    @Test("An edit by the person is never overwritten")
    func editWins() {
        var draft = OpenCodeDictationDraft(base: "")
        _ = draft.apply("Run tests", to: "")
        #expect(draft.apply("Run tests now", to: "Run tests!") == nil)
        #expect(!draft.owns("Run tests!"))
        #expect(draft.owns("Run tests"))
    }

    @Test("A recognizer that restarts after a pause keeps the words before it")
    func joinsSegmentsAfterPause() {
        var transcript = OpenCodeDictationTranscript()
        #expect(transcript.update("Fix the build", endsSegment: false) == "Fix the build")
        #expect(transcript.update("Fix the build.", endsSegment: true) == "Fix the build.")
        #expect(transcript.update("Then", endsSegment: false) == "Fix the build. Then")
        #expect(transcript.update("Then run the tests", endsSegment: false) == "Fix the build. Then run the tests")
        #expect(transcript.update("", endsSegment: true) == "Fix the build.", "An empty result never drops words")
    }

    @Test("A recognizer that keeps earlier words isn't doubled, even re-punctuated")
    func keepsContinuousTranscript() {
        var transcript = OpenCodeDictationTranscript()
        _ = transcript.update("hello world", endsSegment: true)
        #expect(transcript.update("Hello, world. Again", endsSegment: false) == "Hello, world. Again")
        #expect(OpenCodeDictationTranscript.join("Rename the", "Function") == "Rename the function",
                "A new segment mid-sentence isn't capitalized")
        #expect(OpenCodeDictationTranscript.join("Go to", "Tomorrow works") == "Go to tomorrow works",
                "Matching is by whole words")
    }

    // MARK: Permissions

    @Test("Refusals block before anything is requested; undecided permissions are asked one at a time")
    func resolvesAccess() {
        typealias Access = OpenCodeDictationAccess
        #expect(Access.resolve(microphone: .granted, speech: .granted) == .ready)
        #expect(Access.resolve(microphone: .undetermined, speech: .undetermined) == .requestMicrophone)
        #expect(Access.resolve(microphone: .granted, speech: .undetermined) == .requestSpeech)
        #expect(Access.resolve(microphone: .denied, speech: .undetermined) == .blocked(.microphoneDenied))
        #expect(Access.resolve(microphone: .undetermined, speech: .denied) == .blocked(.speechDenied),
                "Don't ask for the microphone when speech is already refused")
        #expect(Access.resolve(microphone: .granted, speech: .restricted) == .blocked(.restricted))
        #expect(OpenCodeDictationBlock.microphoneDenied.opensSettings)
        #expect(!OpenCodeDictationBlock.restricted.opensSettings)
    }

    @Test("Permission prompts run in order and dictation starts once both are granted")
    func requestsPermissions() async {
        let engine = FakeDictationEngine(microphone: .undetermined, speech: .undetermined)
        engine.grantOnRequest = true
        let controller = Self.controller(engine)
        let text = TextBox()
        controller.start(text: text.binding)
        #expect(controller.phase == .preparing)
        await Self.settle { controller.phase == .listening }
        #expect(engine.requests == ["microphone", "speech"])
        #expect(engine.starts == 1)
        #expect(controller.isOnDevice)
    }

    @Test("A refused permission shows the settings alert and never starts audio")
    func deniedPermission() async {
        let engine = FakeDictationEngine(microphone: .undetermined, speech: .granted)
        engine.grantOnRequest = false
        let controller = Self.controller(engine)
        controller.start(text: TextBox().binding)
        await Self.settle { controller.phase == .idle }
        #expect(controller.blocked == .microphoneDenied)
        #expect(engine.starts == 0)
    }

    @Test("A prompt that leaves the status undecided counts as a refusal instead of looping")
    func undecidedPrompt() async {
        let engine = FakeDictationEngine(microphone: .granted, speech: .undetermined)
        let controller = Self.controller(engine)
        controller.start(text: TextBox().binding)
        await Self.settle { controller.phase == .idle }
        #expect(engine.requests == ["speech"])
        #expect(controller.blocked == .speechDenied)
    }

    // MARK: Live transcript

    @Test("Partial results stream into the draft after the typed text")
    func streamsTranscript() async throws {
        let (engine, controller, text) = try await Self.listening(base: "Please")
        engine.emit(.transcript("fix", isFinal: false))
        #expect(text.value == "Please fix")
        engine.emit(.transcript("fix the failing test.", isFinal: false))
        #expect(text.value == "Please fix the failing test.")
        engine.emit(.level(0.6))
        #expect(controller.meter.level == 0.6)
        engine.emit(.transcript("Fix the failing test.", isFinal: true))
        #expect(text.value == "Please fix the failing test.")
        #expect(controller.phase == .idle)
        #expect(controller.meter.level == 0)
    }

    @Test("Typing during dictation stops it and keeps the edit")
    func typingStopsDictation() async throws {
        let (engine, controller, text) = try await Self.listening(base: "")
        engine.emit(.transcript("Rename the", isFinal: false))
        text.value = "Rename the file"
        controller.noteEdit(text.value)
        #expect(controller.phase == .idle)
        #expect(engine.cancels >= 1)
        engine.emit(.transcript("Rename the function", isFinal: false))
        #expect(text.value == "Rename the file", "Late results never overwrite the edit")
    }

    @Test("Clearing the draft on send ends dictation without re-adding words")
    func sendingStopsDictation() async throws {
        let (engine, controller, text) = try await Self.listening(base: "")
        engine.emit(.transcript("Ship it", isFinal: false))
        controller.noteEdit(text.value)
        #expect(controller.phase == .listening, "Dictation's own write is not an edit")
        text.value = ""
        controller.noteEdit("")
        #expect(controller.phase == .idle)
        engine.emit(.transcript("Ship it now", isFinal: false))
        #expect(text.value.isEmpty)
    }

    @Test("Done stops the microphone and still takes the final wording")
    func finishKeepsFinalResult() async throws {
        let (engine, controller, text) = try await Self.listening(base: "")
        engine.emit(.transcript("add a test", isFinal: false))
        controller.toggle(text: text.binding)
        #expect(controller.phase == .finishing)
        #expect(engine.finishes == 1)
        engine.emit(.transcript("Add a test.", isFinal: true))
        #expect(text.value == "Add a test.")
        #expect(controller.phase == .idle)
    }

    @Test("An audio interruption stops listening and still takes the final wording")
    func interruptionFinishes() async throws {
        let (engine, controller, text) = try await Self.listening(base: "")
        engine.emit(.transcript("call me", isFinal: false))
        engine.emit(.level(0.8))
        engine.emit(.interrupted)
        #expect(controller.phase == .finishing)
        #expect(controller.meter.level == 0)
        #expect(engine.finishes == 1)
        engine.emit(.transcript("Call me.", isFinal: true))
        #expect(text.value == "Call me.")
        #expect(controller.phase == .idle)
    }

    @Test("A final result that never comes doesn't leave dictation hanging")
    func finishTimesOut() async throws {
        let (engine, controller, _) = try await Self.listening(base: "")
        controller.finish()
        await Self.settle { controller.phase == .idle }
        #expect(engine.cancels >= 1)
    }

    @Test("A stretch of silence ends dictation")
    func silenceFinishes() async throws {
        let engine = FakeDictationEngine()
        let controller = OpenCodeDictationController(engine: engine, silenceTimeout: .milliseconds(30),
                                                     finishTimeout: .seconds(5), beforeListening: {})
        controller.start(text: TextBox().binding)
        await Self.settle { controller.phase == .finishing }
        #expect(engine.finishes == 1)
    }

    // MARK: Failures

    @Test("Hearing nothing says so; failures after speech keep the words quietly or explain")
    func failureNotices() async throws {
        let (engine, controller, _) = try await Self.listening(base: "")
        engine.emit(.ended(.noSpeech))
        #expect(controller.phase == .idle)
        #expect(controller.notice == "Didn’t hear anything. Tap the microphone and try again.")

        let (second, secondController, text) = try await Self.listening(base: "")
        second.emit(.transcript("Hello", isFinal: false))
        second.emit(.ended(.noSpeech))
        #expect(secondController.notice == nil)
        #expect(text.value == "Hello")
    }

    @Test("An engine that can't start reports why and returns to idle")
    func startFailure() async {
        let engine = FakeDictationEngine()
        engine.startError = OpenCodeDictationFailure.noMicrophone
        let controller = Self.controller(engine)
        controller.start(text: TextBox().binding)
        await Self.settle { controller.phase == .idle }
        #expect(controller.notice?.hasPrefix("No microphone") == true)
    }

    @Test("Speech's assistant error codes map to quiet or explained outcomes")
    func classifiesErrors() {
        #expect(OpenCodeDictationFailure(domain: "kAFAssistantErrorDomain", code: 1110) == .noSpeech)
        #expect(OpenCodeDictationFailure(domain: "kAFAssistantErrorDomain", code: 216) == .canceled)
        #expect(OpenCodeDictationFailure(domain: "kLSRErrorDomain", code: 301) == .canceled)
        #expect(OpenCodeDictationFailure(domain: NSURLErrorDomain, code: -1009) == .unavailable)
        #expect(OpenCodeDictationFailure(domain: "Other", code: 1) == .failed)
        #expect(OpenCodeDictationFailure.canceled.message(capturedSpeech: false) == nil)
        #expect(OpenCodeDictationFailure(NSError(domain: "kAFAssistantErrorDomain", code: 203)) == .noSpeech)
    }

    @Test("Cancelling while permissions are pending never starts audio")
    func cancelWhilePreparing() async {
        let engine = FakeDictationEngine(microphone: .undetermined, speech: .granted)
        engine.grantOnRequest = true
        engine.requestDelay = .milliseconds(30)
        let controller = Self.controller(engine)
        let text = TextBox()
        controller.start(text: text.binding)
        controller.toggle(text: text.binding)
        #expect(controller.phase == .idle)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(engine.starts == 0)
        #expect(controller.phase == .idle)
    }

    // MARK: Meter

    @Test("The level meter spans silence to loud speech")
    func meterLevels() {
        func level(_ samples: [Float]) -> Float {
            samples.withUnsafeBufferPointer { OpenCodeDictationMeter.level(of: $0) }
        }
        #expect(level([]) == 0)
        #expect(level([0, 0, 0]) == 0)
        #expect(level([1, -1, 1, -1]) == 1)
        #expect(level([0.001, -0.001]) < 0.1)
        let medium = level([0.05, -0.05])
        #expect(medium > 0.3 && medium < 0.6)
    }

    // MARK: Helpers

    private static func controller(_ engine: FakeDictationEngine) -> OpenCodeDictationController {
        OpenCodeDictationController(engine: engine, silenceTimeout: .seconds(30), finishTimeout: .milliseconds(30),
                                    noticeDuration: .seconds(30), beforeListening: {})
    }

    private static func listening(base: String) async throws
        -> (FakeDictationEngine, OpenCodeDictationController, TextBox) {
        let engine = FakeDictationEngine()
        let controller = controller(engine)
        let text = TextBox()
        text.value = base
        controller.start(text: text.binding)
        await settle { controller.phase == .listening }
        try #require(controller.phase == .listening)
        return (engine, controller, text)
    }

    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class TextBox {
    var value = ""
    var binding: Binding<String> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private final class FakeDictationEngine: OpenCodeDictationEngine {
    var microphonePermission: OpenCodeDictationPermission
    var speechPermission: OpenCodeDictationPermission
    var grantOnRequest: Bool?
    var requestDelay: Duration?
    var startError: Error?
    private(set) var requests: [String] = []
    private(set) var starts = 0
    private(set) var finishes = 0
    private(set) var cancels = 0
    private var events: (@MainActor (OpenCodeDictationEvent) -> Void)?

    init(microphone: OpenCodeDictationPermission = .granted, speech: OpenCodeDictationPermission = .granted) {
        microphonePermission = microphone
        speechPermission = speech
    }

    var isSupported: Bool { true }

    func requestMicrophoneAccess() async {
        requests.append("microphone")
        if let requestDelay { try? await Task.sleep(for: requestDelay) }
        if let grantOnRequest { microphonePermission = grantOnRequest ? .granted : .denied }
    }

    func requestSpeechAccess() async {
        requests.append("speech")
        if let requestDelay { try? await Task.sleep(for: requestDelay) }
        if let grantOnRequest { speechPermission = grantOnRequest ? .granted : .denied }
    }

    func start(vocabulary: [String], events: @escaping @MainActor (OpenCodeDictationEvent) -> Void) throws -> Bool {
        starts += 1
        if let startError { throw startError }
        self.events = events
        return true
    }

    func finish() { finishes += 1 }

    /// Keeps the sink so tests can prove the controller ignores late events itself.
    func cancel() { cancels += 1 }

    func emit(_ event: OpenCodeDictationEvent) { events?(event) }
}
