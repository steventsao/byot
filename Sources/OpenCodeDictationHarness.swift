#if DEBUG
import Foundation

/// UI tests can't speak into the simulator, so `--dictation-fixture` swaps in
/// an engine that "hears" a fixed sentence, word by word, with a moving level.
@MainActor
final class OpenCodeScriptedDictationEngine: OpenCodeDictationEngine {
    static let partials = ["Summarize", "Summarize the failing", "Summarize the failing tests"]
    static let final = "Summarize the failing tests."

    private var script: Task<Void, Never>?
    private var events: (@MainActor (OpenCodeDictationEvent) -> Void)?

    var isSupported: Bool { true }
    var microphonePermission: OpenCodeDictationPermission { .granted }
    var speechPermission: OpenCodeDictationPermission { .granted }
    func requestMicrophoneAccess() async {}
    func requestSpeechAccess() async {}

    func start(vocabulary: [String], events: @escaping @MainActor (OpenCodeDictationEvent) -> Void) throws -> Bool {
        self.events = events
        script = Task { [weak self] in
            var tick = 0
            var spoken = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.events?(.level(Float(0.35 + 0.3 * sin(Double(tick) * 0.9))))
                if tick % 4 == 0, spoken < Self.partials.count {
                    self.events?(.transcript(Self.partials[spoken], isFinal: false))
                    spoken += 1
                }
            }
        }
        return true
    }

    func finish() {
        script?.cancel()
        let events = events
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            events?(.transcript(Self.final, isFinal: true))
        }
    }

    func cancel() {
        script?.cancel()
        events = nil
    }
}
#endif
