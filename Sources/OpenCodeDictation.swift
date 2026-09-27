import Foundation
import SwiftUI
import UIKit

// MARK: - Draft merging

/// Keeps dictated words in the composer draft. Text typed before dictation
/// stays put, each live transcript replaces only what dictation itself wrote,
/// and an edit by the person ends dictation instead of being overwritten.
struct OpenCodeDictationDraft: Equatable {
    let base: String
    private(set) var written: String

    init(base: String) {
        self.base = base
        written = base
    }

    /// Whether the field still holds exactly what dictation last wrote.
    func owns(_ text: String) -> Bool { text == written }

    /// Whether dictation has added any words to the draft.
    var hasDictatedText: Bool { written != base }

    /// The new field text, or nil when the person changed the field since the
    /// last write; their edit wins and dictation should stop.
    mutating func apply(_ transcript: String, to current: String) -> String? {
        guard owns(current) else { return nil }
        written = Self.merge(transcript, after: base)
        return written
    }

    /// Spoken words follow the typed text with one space, unless the text
    /// already ends in whitespace or an opening bracket.
    static func merge(_ transcript: String, after base: String) -> String {
        var spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        if continuesSentence(base) { spoken = lowercasingFirstWord(spoken) }
        guard let last = base.last, !last.isWhitespace, !"([{".contains(last) else { return base + spoken }
        return base + " " + spoken
    }

    /// Whether dictation picks up mid-sentence rather than after a full stop
    /// or on a new line.
    static func continuesSentence(_ base: String) -> Bool {
        guard let last = base.last(where: { !$0.isWhitespace }), base.last?.isNewline != true else { return false }
        return !".!?".contains(last)
    }

    /// Recognizers capitalize every result as if it began a sentence. Mid-
    /// sentence a plainly capitalized first word ("Fix") is lowered; "I",
    /// acronyms and names with inner capitals ("OpenCode", "iOS") are kept.
    static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix(while: \.isLetter)
        guard word.count > 1, let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy(\.isLowercase) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

// MARK: - Permissions

enum OpenCodeDictationPermission: Equatable, Sendable {
    case granted, denied, restricted, undetermined
}

/// What stands between a tap on the microphone and listening. Refusals are
/// checked before anything is requested, so a person who already said no to
/// one permission is not prompted for the other first.
enum OpenCodeDictationAccess: Equatable {
    case ready
    case requestMicrophone
    case requestSpeech
    case blocked(OpenCodeDictationBlock)

    static func resolve(microphone: OpenCodeDictationPermission,
                        speech: OpenCodeDictationPermission) -> Self {
        switch (microphone, speech) {
        case (.denied, _): .blocked(.microphoneDenied)
        case (.restricted, _), (_, .restricted): .blocked(.restricted)
        case (_, .denied): .blocked(.speechDenied)
        case (.undetermined, _): .requestMicrophone
        case (_, .undetermined): .requestSpeech
        case (.granted, .granted): .ready
        }
    }
}

enum OpenCodeDictationBlock: String, Identifiable, Equatable {
    case microphoneDenied, speechDenied, restricted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphoneDenied: "Allow Microphone Access"
        case .speechDenied: "Allow Speech Recognition"
        case .restricted: "Dictation Unavailable"
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied: "To dictate messages, turn on Microphone for byot in Settings."
        case .speechDenied: "To turn your speech into message text, turn on Speech Recognition for byot in Settings."
        case .restricted: "Speech recognition or the microphone is restricted on this device."
        }
    }

    /// Only a refusal the person made can be changed in the app's settings.
    var opensSettings: Bool { self != .restricted }
}

// MARK: - Engine events

enum OpenCodeDictationFailure: Error, Equatable, Sendable {
    /// Recognition heard nothing it could transcribe.
    case noSpeech
    /// The task was cancelled; nothing to report.
    case canceled
    /// The recognizer can't take requests right now, e.g. a network-only language offline.
    case unavailable
    /// No audio input exists, or another app holds it.
    case noMicrophone
    case failed

    init(_ error: Error) {
        if let failure = error as? OpenCodeDictationFailure {
            self = failure
            return
        }
        let error = error as NSError
        self.init(domain: error.domain, code: error.code)
    }

    /// Speech reports most outcomes through undocumented assistant error codes;
    /// the ones that mean "nothing was said" or "you cancelled" stay silent.
    init(domain: String, code: Int) {
        switch (domain, code) {
        case ("kAFAssistantErrorDomain", 203), ("kAFAssistantErrorDomain", 1110): self = .noSpeech
        case ("kAFAssistantErrorDomain", 216), ("kAFAssistantErrorDomain", 209),
             ("kAFAssistantErrorDomain", 1101), ("kLSRErrorDomain", 301): self = .canceled
        case ("kAFAssistantErrorDomain", 1700): self = .unavailable
        case (NSURLErrorDomain, _): self = .unavailable
        default: self = .failed
        }
    }

    /// The composer's inline note, or nil when there is nothing worth saying.
    func message(capturedSpeech: Bool) -> String? {
        switch self {
        case .noSpeech: capturedSpeech ? nil : "Didn’t hear anything. Tap the microphone and try again."
        case .canceled: nil
        case .unavailable: "Speech recognition isn’t available right now. Check your connection and try again."
        case .noMicrophone: "No microphone is available. End any call or recording using it, then try again."
        case .failed: capturedSpeech
            ? "Dictation stopped early. The words so far are in your message."
            : "Dictation couldn’t start. Try again."
        }
    }
}

enum OpenCodeDictationEvent: Equatable, Sendable {
    case transcript(String, isFinal: Bool)
    case level(Float)
    case ended(OpenCodeDictationFailure?)
}

/// The platform side of dictation: permissions, audio and recognition. The
/// composer's flow is tested against a fake instead of audio hardware.
@MainActor
protocol OpenCodeDictationEngine: AnyObject {
    /// Whether speech recognition exists for the device's language at all.
    var isSupported: Bool { get }
    var microphonePermission: OpenCodeDictationPermission { get }
    var speechPermission: OpenCodeDictationPermission { get }
    func requestMicrophoneAccess() async
    func requestSpeechAccess() async
    /// Starts listening and returns whether recognition stays on this device.
    /// Events arrive on the main actor until the session ends or is cancelled.
    func start(vocabulary: [String], events: @escaping @MainActor (OpenCodeDictationEvent) -> Void) throws -> Bool
    /// Stops the microphone and lets recognition deliver its final result.
    func finish()
    /// Stops everything; no further events arrive for this session.
    func cancel()
}

// MARK: - Level meter

/// Input loudness for the listening indicator, kept apart from the controller
/// so twenty updates a second redraw only the meter, not the composer.
@MainActor
final class OpenCodeDictationMeter: ObservableObject {
    @Published var level: Float = 0

    /// Maps the RMS of a buffer onto 0...1 across a 50 dB window, which spans
    /// a quiet room to close speech.
    nonisolated static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let rms = meanSquare.squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }
}

// MARK: - Controller

/// Runs one dictation at a time for a composer: asks for permissions, writes
/// the live transcript into the draft, and stops on Done, silence, an edit,
/// sending, or the app leaving the foreground.
@MainActor
final class OpenCodeDictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting on permission prompts or audio start.
        case preparing
        case listening
        /// The microphone is off; the final transcript is on its way.
        case finishing
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var isOnDevice = false
    @Published var blocked: OpenCodeDictationBlock?
    @Published private(set) var notice: String?
    let meter = OpenCodeDictationMeter()

    private let engine: any OpenCodeDictationEngine
    private let silenceTimeout: Duration
    private let finishTimeout: Duration
    private let noticeDuration: Duration
    private let beforeListening: @MainActor () async -> Void
    private var text: Binding<String>?
    private var draft: OpenCodeDictationDraft?
    private var attempt = 0
    private var timer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?

    init(
        engine: (any OpenCodeDictationEngine)? = nil,
        silenceTimeout: Duration = .seconds(15),
        finishTimeout: Duration = .seconds(2),
        noticeDuration: Duration = .seconds(6),
        beforeListening: @escaping @MainActor () async -> Void = OpenCodeDictationController.letVoiceOverFinish
    ) {
        self.engine = engine ?? Self.platformEngine()
        self.silenceTimeout = silenceTimeout
        self.finishTimeout = finishTimeout
        self.noticeDuration = noticeDuration
        self.beforeListening = beforeListening
    }

    private static func platformEngine() -> any OpenCodeDictationEngine {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--dictation-fixture") {
            return OpenCodeScriptedDictationEngine()
        }
#endif
        return OpenCodeSpeechDictationEngine()
    }

    var isSupported: Bool { engine.isSupported }

    var isActive: Bool { phase != .idle }

    /// The microphone button: starts dictation, or ends it keeping the words so far.
    func toggle(text: Binding<String>, vocabulary: [String] = []) {
        switch phase {
        case .idle: start(text: text, vocabulary: vocabulary)
        case .preparing: cancel()
        case .listening: finish()
        case .finishing: break
        }
    }

    func start(text: Binding<String>, vocabulary: [String] = []) {
        guard phase == .idle, engine.isSupported else { return }
        attempt &+= 1
        let attempt = attempt
        phase = .preparing
        blocked = nil
        clearNotice()
        Task { await begin(attempt, text: text, vocabulary: vocabulary) }
    }

    /// Ends listening; the recognizer's final wording still lands in the draft.
    func finish() {
        guard phase == .listening else { return }
        phase = .finishing
        meter.level = 0
        engine.finish()
        let attempt = attempt
        // Without a final result in time, the recognizer is released and the
        // partial words already in the draft stand.
        schedule(after: finishTimeout) { controller in
            guard controller.attempt == attempt else { return }
            controller.cancel()
        }
    }

    /// Stops immediately. Words already written stay in the draft.
    func cancel() {
        guard phase != .idle else { return }
        engine.cancel()
        end(attempt)
    }

    /// Called for every change to the draft. Anything dictation didn't write
    /// (typing, clearing on send, a restored message) ends dictation.
    func noteEdit(_ text: String) {
        guard let draft, !draft.owns(text) else { return }
        cancel()
    }

    private func begin(_ attempt: Int, text: Binding<String>, vocabulary: [String]) async {
        guard await authorize(attempt) else { return }
        await beforeListening()
        guard attempt == self.attempt, phase == .preparing else { return }
        do {
            isOnDevice = try engine.start(vocabulary: vocabulary) { [weak self] event in
                self?.handle(event, attempt: attempt)
            }
        } catch {
            engine.cancel()
            end(attempt)
            show(OpenCodeDictationFailure(error).message(capturedSpeech: false))
            return
        }
        self.text = text
        draft = OpenCodeDictationDraft(base: text.wrappedValue)
        phase = .listening
        armSilenceTimer()
    }

    /// Requests whatever is still undecided, one prompt at a time, and stops
    /// at the first refusal.
    private func authorize(_ attempt: Int) async -> Bool {
        var requested: Set<String> = []
        while true {
            // A cancel while a prompt was up ends this attempt quietly.
            guard attempt == self.attempt, phase == .preparing else { return false }
            let access = OpenCodeDictationAccess.resolve(microphone: engine.microphonePermission,
                                                         speech: engine.speechPermission)
            switch access {
            case .ready:
                return true
            case .blocked(let block):
                end(attempt)
                blocked = block
                return false
            case .requestMicrophone:
                // A prompt that leaves the status undecided is treated as a no.
                guard requested.insert("microphone").inserted else {
                    end(attempt)
                    blocked = .microphoneDenied
                    return false
                }
                await engine.requestMicrophoneAccess()
            case .requestSpeech:
                guard requested.insert("speech").inserted else {
                    end(attempt)
                    blocked = .speechDenied
                    return false
                }
                await engine.requestSpeechAccess()
            }
        }
    }

    private func handle(_ event: OpenCodeDictationEvent, attempt: Int) {
        guard attempt == self.attempt, phase == .listening || phase == .finishing else { return }
        switch event {
        case .level(let level):
            if phase == .listening { meter.level = level }
        case .transcript(let transcript, let isFinal):
            guard var draft, let text else { return }
            guard let merged = draft.apply(transcript, to: text.wrappedValue) else {
                cancel()
                return
            }
            self.draft = draft
            if merged != text.wrappedValue { text.wrappedValue = merged }
            if isFinal {
                engine.cancel()
                end(attempt)
            } else if phase == .listening {
                armSilenceTimer()
            }
        case .ended(let failure):
            let captured = draft?.hasDictatedText ?? false
            engine.cancel()
            end(attempt)
            if let failure { show(failure.message(capturedSpeech: captured)) }
        }
    }

    private func end(_ attempt: Int) {
        guard attempt == self.attempt else { return }
        self.attempt &+= 1
        timer?.cancel()
        timer = nil
        text = nil
        draft = nil
        meter.level = 0
        phase = .idle
    }

    /// A forgotten microphone doesn't stay open: a stretch with no new words ends dictation.
    private func armSilenceTimer() {
        let attempt = attempt
        schedule(after: silenceTimeout) { controller in
            guard controller.attempt == attempt else { return }
            controller.finish()
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor (OpenCodeDictationController) -> Void) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func show(_ message: String?) {
        guard let message else { return }
        notice = message
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self, noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTimer?.cancel()
        noticeTimer = nil
        notice = nil
    }

    /// VoiceOver's own speech would otherwise be transcribed into the message,
    /// so listening starts once a short cue has been spoken.
    static func letVoiceOverFinish() async {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement("Listening").post()
        try? await Task.sleep(for: .milliseconds(900))
    }
}
