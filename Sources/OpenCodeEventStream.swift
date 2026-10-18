import Foundation
import os

enum OpenCodeEventStream {
    static let bufferLimit = 16

    static func yieldEvent(
        _ event: OpenCodeEvent,
        to continuation: AsyncThrowingStream<OpenCodeEvent, Error>.Continuation
    ) throws -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            throw OpenCodeConnectionError.eventBufferOverflow
        case .terminated:
            return false
        @unknown default:
            throw OpenCodeConnectionError.eventBufferOverflow
        }
    }

    static func validateEventResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeConnectionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeConnectionError.httpStatus(http.statusCode, nil)
        }
        guard http.mimeType?.lowercased() == "text/event-stream" else {
            throw OpenCodeConnectionError.unexpectedEventContentType
        }
    }

}

/// OpenCode 1 sends a `server.heartbeat` event every 10 s and OpenCode 2 a
/// `: heartbeat` comment every 15 s. Once a stream has sent one, a silence of
/// `timeout` means the connection died without closing (the computer slept,
/// or the phone changed networks), so the request is cancelled and the caller
/// reconnects instead of waiting out the day-long request timeout. A stream
/// that never sends a heartbeat is left alone.
final class OpenCodeEventStallWatchdog: Sendable {
    static let standardTimeout: Duration = .seconds(45)

    private struct State {
        var lastHeard = ContinuousClock.now
        var armed = false
        var stalled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let watcher: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    init(timeout: Duration, cancelling request: URLSessionTask) {
        let state = state
        let task = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: timeout / 4)
                let stalled = state.withLock { state in
                    guard !Task.isCancelled, state.armed, ContinuousClock.now - state.lastHeard >= timeout
                    else { return false }
                    state.stalled = true
                    return true
                }
                if stalled {
                    request.cancel()
                    return
                }
            }
        }
        watcher.withLock { $0 = task }
    }

    /// True once the watchdog cancelled the request.
    var stalled: Bool { state.withLock { $0.stalled } }

    func heard(heartbeat: Bool = false) {
        state.withLock { state in
            state.lastHeard = .now
            if heartbeat { state.armed = true }
        }
    }

    func stop() {
        watcher.withLock { $0?.cancel() }
    }
}

struct OpenCodeSSEParser: Sendable {
    static let defaultMaxEventBytes = 8 * 1_024 * 1_024

    private var data = Data()
    private var hasDataField = false
    private var eventBytes = 0
    private let maxEventBytes: Int

    init(maxEventBytes: Int = Self.defaultMaxEventBytes) {
        precondition(maxEventBytes > 0)
        self.maxEventBytes = maxEventBytes
    }

    mutating func ingest(line: String) throws -> Data? {
        if line.isEmpty {
            return dispatch()
        }
        let normalizedLineBytes = line.utf8.count + 1
        guard normalizedLineBytes <= maxEventBytes - eventBytes else {
            discard()
            throw OpenCodeConnectionError.eventRecordTooLarge(maxBytes: maxEventBytes)
        }
        eventBytes += normalizedLineBytes

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        guard field == "data" else {
            return nil
        }
        if hasDataField { data.append(0x0A) }
        data.append(contentsOf: value.utf8)
        hasDataField = true
        return nil
    }

    mutating func discard() {
        data.removeAll(keepingCapacity: true)
        hasDataField = false
        eventBytes = 0
    }

    private mutating func dispatch() -> Data? {
        let result = hasDataField ? data : nil
        defer { discard() }
        return result
    }
}

struct OpenCodeSSELineFramer: Sendable {
    static let defaultMaxLineBytes = 2 * 1_024 * 1_024

    private var lineBytes: [UInt8] = []
    private var bomProbe: [UInt8] = []
    private var checkingBOM = true
    private var swallowLF = false
    private let maxLineBytes: Int

    init(maxLineBytes: Int = Self.defaultMaxLineBytes) {
        precondition(maxLineBytes > 0)
        self.maxLineBytes = maxLineBytes
    }

    mutating func ingest(byte: UInt8) throws -> String? {
        if checkingBOM {
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if byte == bom[bomProbe.count] {
                bomProbe.append(byte)
                if bomProbe.count == bom.count {
                    bomProbe.removeAll(keepingCapacity: false)
                    checkingBOM = false
                }
                return nil
            }
            checkingBOM = false
            for prefixByte in bomProbe {
                try appendLineByte(prefixByte)
            }
            bomProbe.removeAll(keepingCapacity: false)
        }

        if swallowLF {
            swallowLF = false
            if byte == 0x0A { return nil }
        }

        switch byte {
        case 0x0D:
            swallowLF = true
            return takeLine()
        case 0x0A:
            return takeLine()
        default:
            try appendLineByte(byte)
            return nil
        }
    }

    mutating func discardIncompleteLine() {
        lineBytes.removeAll(keepingCapacity: true)
        bomProbe.removeAll(keepingCapacity: false)
        checkingBOM = false
        swallowLF = false
    }

    private mutating func appendLineByte(_ byte: UInt8) throws {
        guard lineBytes.count < maxLineBytes else {
            discardIncompleteLine()
            throw OpenCodeConnectionError.eventLineTooLong(maxBytes: maxLineBytes)
        }
        lineBytes.append(byte)
    }

    private mutating func takeLine() -> String {
        defer { lineBytes.removeAll(keepingCapacity: true) }
        return String(decoding: lineBytes, as: UTF8.self)
    }
}
