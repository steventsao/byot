import AVFoundation
import Foundation
import Speech

/// Dictation through the Speech framework and the microphone.
///
/// Recognition stays on the device whenever the recognizer supports it for the
/// current language; otherwise Apple's servers transcribe, and the composer
/// says so while listening. Audio runs only between start and finish or cancel.
///
/// Speech and AVFoundation call back on their own threads, so every callback is
/// created in a nonisolated function and hops to the main queue itself; a
/// closure formed on the main actor would trap when called from the audio thread.
@MainActor
final class OpenCodeSpeechDictationEngine: OpenCodeDictationEngine {
    private let recognizer = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var observers: [NSObjectProtocol] = []
    private var isSessionActive = false
    private var session = 0
    private var events: (@MainActor (OpenCodeDictationEvent) -> Void)?

    var isSupported: Bool { recognizer != nil }

    var microphonePermission: OpenCodeDictationPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    var speechPermission: OpenCodeDictationPermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .undetermined
        }
    }

    func requestMicrophoneAccess() async {
        _ = await Self.requestMicrophone()
    }

    func requestSpeechAccess() async {
        _ = await Self.requestSpeechAuthorization()
    }

    func start(vocabulary: [String], events: @escaping @MainActor (OpenCodeDictationEvent) -> Void) throws -> Bool {
        cancel()
        guard let recognizer else { throw OpenCodeDictationFailure.unavailable }
        guard recognizer.isAvailable else { throw OpenCodeDictationFailure.unavailable }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        isSessionActive = true

        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateSession()
            throw OpenCodeDictationFailure.noMicrophone
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(50))
        let onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice

        session &+= 1
        let deliver = Self.deliverer(to: self, session: session)
        Self.installTap(on: input, format: format, request: request, deliver: deliver)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            deactivateSession()
            throw OpenCodeDictationFailure.noMicrophone
        }

        self.audioEngine = audioEngine
        self.request = request
        self.events = events
        task = Self.recognize(request, with: recognizer, deliver: deliver)
        observers = Self.observeInterruptions(of: audioEngine, interrupt: Self.interrupter(for: self, session: session))
        return onDevice
    }

    func finish() {
        stopAudio()
        request?.endAudio()
    }

    func cancel() {
        session &+= 1
        events = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func receive(_ event: OpenCodeDictationEvent, session: Int) {
        guard session == self.session, let events else { return }
        switch event {
        case .ended, .transcript(_, isFinal: true):
            // Recognition is over; release the task before the controller hears about it.
            stopAudio()
            task = nil
            request = nil
            self.events = nil
        case .transcript, .level:
            break
        }
        events(event)
    }

    /// A call, Siri, or a new audio route (headphones in or out) ends the
    /// microphone; whatever was recognized so far still arrives.
    private func interrupted(session: Int) {
        guard session == self.session else { return }
        finish()
    }

    private func stopAudio() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        deactivateSession()
    }

    private func deactivateSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Callbacks created off the main actor

    nonisolated private static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func deliverer(
        to engine: OpenCodeSpeechDictationEngine, session: Int
    ) -> @Sendable (OpenCodeDictationEvent) -> Void {
        { [weak engine] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { engine?.receive(event, session: session) }
            }
        }
    }

    nonisolated private static func interrupter(
        for engine: OpenCodeSpeechDictationEngine, session: Int
    ) -> @Sendable () -> Void {
        { [weak engine] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { engine?.interrupted(session: session) }
            }
        }
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest,
        deliver: @escaping @Sendable (OpenCodeDictationEvent) -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            deliver(.level(OpenCodeDictationMeter.level(of: samples)))
        }
    }

    nonisolated private static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
        deliver: @escaping @Sendable (OpenCodeDictationEvent) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                deliver(.transcript(result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
            if let error {
                deliver(.ended(OpenCodeDictationFailure(error)))
            }
        }
    }

    nonisolated private static func observeInterruptions(
        of audioEngine: AVAudioEngine, interrupt: @escaping @Sendable () -> Void
    ) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init) == .began { interrupt() }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil) { _ in
                interrupt()
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
                interrupt()
            },
        ]
    }
}
