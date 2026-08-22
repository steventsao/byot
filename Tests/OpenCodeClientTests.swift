import Foundation
import Security
import XCTest
@testable import byot

final class OpenCodeClientTests: XCTestCase {
    func testLargeJSONNumberDescriptionDoesNotOverflow() {
        XCTAssertEqual(
            OpenCodeJSONValue.number(1e100).compactDescription,
            String(1e100)
        )
        XCTAssertEqual(OpenCodeJSONValue.number(42).compactDescription, "42")
    }

    func testSecureProfileValidationRejectsPlainHTTP() {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "http://192.0.2.1:4096",
            username: "opencode"
        )

        XCTAssertThrowsError(try profile.validate(password: "secret")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Enter a complete HTTPS server URL."
            )
        }
    }

    func testRequestBoundaryRejectsPlainHTTPBeforeAttachingCredentials() {
        let profile = OpenCodeServerProfile(
            name: "Corrupted legacy profile",
            baseURL: "http://mac.example.test",
            username: "opencode"
        )
        let client = OpenCodeClient(profile: profile, password: "must-not-leak")

        XCTAssertThrowsError(
            try client.makeRequest(
                path: ["project"],
                query: [],
                method: "GET",
                body: nil
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Enter a complete HTTPS server URL."
            )
        }
    }

    func testKeychainDeleteStatusTreatsOnlySuccessAndNotFoundAsSuccess() {
        XCTAssertNoThrow(try KeychainStore.validateDeleteStatus(errSecSuccess))
        XCTAssertNoThrow(
            try KeychainStore.validateDeleteStatus(errSecItemNotFound)
        )
        XCTAssertThrowsError(
            try KeychainStore.validateDeleteStatus(errSecAuthFailed)
        )
    }

    func testSecureProfileValidationRejectsCredentialsInURL() {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://opencode:leaked-secret@mac.example.test",
            username: "opencode"
        )

        XCTAssertThrowsError(try profile.validate(password: "keychain-secret"))
    }

    func testRequestUsesBasicAuthAndDirectoryQuery() throws {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test/",
            username: "opencode"
        )
        let client = OpenCodeClient(profile: profile, password: "correct horse")
        let request = try client.makeRequest(
            path: ["session", "ses_123", "message"],
            query: [URLQueryItem(name: "directory", value: "/Users/me/My Project")],
            method: "GET",
            body: nil
        )

        XCTAssertEqual(request.url?.path, "/session/ses_123/message")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value,
            "/Users/me/My Project"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic \(Data("opencode:correct horse".utf8).base64EncodedString())"
        )
    }

    func testRedirectPolicyKeepsCredentialsOnExactHTTPSOrigin() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://mac.example.test"))
        let delegate = OpenCodeRedirectDelegate(baseURL: baseURL)

        XCTAssertTrue(delegate.allowsRedirect(to: URL(string: "https://mac.example.test/session")))
        XCTAssertTrue(delegate.allowsRedirect(to: URL(string: "https://mac.example.test:443/session")))
        XCTAssertFalse(delegate.allowsRedirect(to: URL(string: "http://mac.example.test/session")))
        XCTAssertFalse(delegate.allowsRedirect(to: URL(string: "https://other.example.test/session")))
        XCTAssertFalse(delegate.allowsRedirect(to: URL(string: "https://mac.example.test:444/session")))

        var original = URLRequest(url: baseURL)
        original.setValue("Basic c2VjcmV0", forHTTPHeaderField: "Authorization")
        let strippedRedirect = URLRequest(
            url: try XCTUnwrap(URL(string: "https://mac.example.test/session"))
        )
        let restored = try XCTUnwrap(
            delegate.redirectedRequest(strippedRedirect, originalRequest: original)
        )
        XCTAssertEqual(
            restored.value(forHTTPHeaderField: "Authorization"),
            "Basic c2VjcmV0"
        )
    }

    func testEventResponseValidatorAcceptsEventStreamWithCharset() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://mac.example.test/event")),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
            )
        )

        XCTAssertNoThrow(try OpenCodeClient.validateEventResponse(response))
    }

    func testEventResponseValidatorRejectsWrongContentTypeWithoutPayloadDetails() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(
                    URL(
                        string: "https://mac.example.test/event?debug=Authorization-Basic-sentinel-secret"
                    )
                ),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )
        )

        XCTAssertThrowsError(try OpenCodeClient.validateEventResponse(response)) { error in
            guard case OpenCodeConnectionError.unexpectedEventContentType = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                error.localizedDescription,
                "The OpenCode event endpoint did not return an event stream."
            )
            for confidentialMarker in ["Authorization", "Basic", "sentinel-secret"] {
                XCTAssertFalse(error.localizedDescription.contains(confidentialMarker))
            }
        }
    }

    func testEventResponseValidatorPreservesHTTPStatusRejectionPrecedence() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://mac.example.test/event")),
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )
        )

        XCTAssertThrowsError(try OpenCodeClient.validateEventResponse(response)) { error in
            guard case OpenCodeConnectionError.httpStatus(503, nil) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "OpenCode returned HTTP 503.")
        }
    }

    func testSSEParserHandlesCommentsAndMultilineData() throws {
        var parser = OpenCodeSSEParser()
        XCTAssertNil(try parser.ingest(line: ": heartbeat"))
        XCTAssertNil(try parser.ingest(line: "event: message"))
        XCTAssertNil(try parser.ingest(line: "data: {\"id\":\"evt_1\","))
        XCTAssertNil(try parser.ingest(line: "data: \"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_1\"}}"))
        let data = try XCTUnwrap(try parser.ingest(line: ""))
        let event = try JSONDecoder().decode(OpenCodeEvent.self, from: data)

        XCTAssertEqual(event.id, "evt_1")
        XCTAssertEqual(event.type, "session.idle")
        XCTAssertEqual(event.sessionID, "ses_1")
    }

    func testSSERawByteFramingPreservesBlankRecordBoundaries() throws {
        let payload =
            "data: {\"id\":\"evt_1\",\"type\":\"server.connected\",\"properties\":{}}\r\n"
            + "\r\n"
            + "data: {\"id\":\"evt_2\",\"type\":\"server.heartbeat\",\"properties\":{}}\n"
            + "\n"
        var framer = OpenCodeSSELineFramer()
        var parser = OpenCodeSSEParser()
        var events: [OpenCodeEvent] = []

        for byte in payload.utf8 {
            guard let line = try framer.ingest(byte: byte),
                  let data = try parser.ingest(line: line)
            else { continue }
            events.append(try JSONDecoder().decode(OpenCodeEvent.self, from: data))
        }
        framer.discardIncompleteLine()
        parser.discard()

        XCTAssertEqual(events.map(\.id), ["evt_1", "evt_2"])
        XCTAssertEqual(events.map(\.type), ["server.connected", "server.heartbeat"])
    }

    func testSSEFramingHandlesMixedLineEndingsAndTreatsCRLFAsOneBoundary() throws {
        let payload = Data("lf\ncrlf\r\ncr\r\r\nend\n".utf8)
        var framer = OpenCodeSSELineFramer()
        var lines: [String] = []

        for byte in payload {
            if let line = try framer.ingest(byte: byte) {
                lines.append(line)
            }
        }

        XCTAssertEqual(lines, ["lf", "crlf", "cr", "", "end"])
    }

    func testSSEFramingSupportsLFCRLFAndCROnlyWithLeadingBOM() throws {
        for separator in ["\n", "\r\n", "\r"] {
            let payload = "\u{FEFF}data: {\"id\":\"evt_1\",\"type\":\"server.connected\",\"properties\":{}}\(separator)\(separator)"
            let events = try decodedSSEEvents(from: Data(payload.utf8))

            XCTAssertEqual(events.map(\.id), ["evt_1"], "separator: \(separator.debugDescription)")
            XCTAssertEqual(events.map(\.type), ["server.connected"])
        }
    }

    func testSSEFramingStripsExactlyOneBOMAndExcludesItFromLineLimit() throws {
        let line = "data: x"
        var oneBOM = OpenCodeSSELineFramer(maxLineBytes: line.utf8.count)
        var framedLine: String?
        for byte in Data("\u{FEFF}\(line)\n".utf8) {
            if let value = try oneBOM.ingest(byte: byte) {
                framedLine = value
            }
        }
        XCTAssertEqual(framedLine, line)

        var doubleBOMFramer = OpenCodeSSELineFramer(maxLineBytes: 32)
        var doubleBOMParser = OpenCodeSSEParser()
        var dispatchedData: Data?
        for byte in Data("\u{FEFF}\u{FEFF}\(line)\n\n".utf8) {
            guard let framedLine = try doubleBOMFramer.ingest(byte: byte) else { continue }
            if let data = try doubleBOMParser.ingest(line: framedLine) {
                dispatchedData = data
            }
        }
        XCTAssertNil(dispatchedData, "A second BOM must remain part of the field name")
    }

    func testSSEFramingDiscardsIncompleteLineAndRecordAtEOF() throws {
        XCTAssertEqual(
            try decodedSSEDataRecords(from: Data("data: partial line".utf8)),
            []
        )
        XCTAssertEqual(
            try decodedSSEDataRecords(from: Data("data: terminated without blank\n".utf8)),
            []
        )
        XCTAssertEqual(
            try decodedSSEDataRecords(
                from: Data("data: complete\n\ndata: trailing partial".utf8)
            ),
            [Data("complete".utf8)]
        )
        XCTAssertEqual(
            try decodedSSEDataRecords(from: Data("data: cr dispatch\r\r".utf8)),
            [Data("cr dispatch".utf8)]
        )
    }

    func testSSEParserHandlesBareDataAndMultilineDataSemantics() throws {
        var parser = OpenCodeSSEParser()

        XCTAssertNil(try parser.ingest(line: "data"))
        XCTAssertNil(try parser.ingest(line: "data: first"))
        XCTAssertNil(try parser.ingest(line: "data:second"))

        XCTAssertEqual(
            try parser.ingest(line: ""),
            Data("\nfirst\nsecond".utf8)
        )
    }

    func testSSELineSafetyLimitAcceptsExactSizeAndRejectsOverflowWithoutPayload() throws {
        var exact = OpenCodeSSELineFramer(maxLineBytes: 4)
        for byte in "safe".utf8 {
            XCTAssertNil(try exact.ingest(byte: byte))
        }
        XCTAssertEqual(try exact.ingest(byte: 0x0A), "safe")

        let secretPayload = "Authorization Basic sentinel-secret"
        var overflow = OpenCodeSSELineFramer(maxLineBytes: 4)
        XCTAssertThrowsError(
            try secretPayload.utf8.forEach { byte in
                _ = try overflow.ingest(byte: byte)
            }
        ) { error in
            guard case OpenCodeConnectionError.eventLineTooLong(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 4)
            XCTAssertEqual(
                error.localizedDescription,
                "The OpenCode event stream sent a line larger than the 4-byte safety limit."
            )
            for confidentialMarker in ["Authorization", "Basic", "sentinel-secret"] {
                XCTAssertFalse(error.localizedDescription.contains(confidentialMarker))
            }
        }
    }

    func testSSELineSafetyLimitCountsUTF8BytesAtExactBoundary() throws {
        let multibyteLine = "é"
        XCTAssertEqual(multibyteLine.utf8.count, 2)
        var exact = OpenCodeSSELineFramer(maxLineBytes: 2)

        for byte in multibyteLine.utf8 {
            XCTAssertNil(try exact.ingest(byte: byte))
        }
        XCTAssertEqual(try exact.ingest(byte: 0x0A), multibyteLine)

        var oneByteShort = OpenCodeSSELineFramer(maxLineBytes: 1)
        XCTAssertThrowsError(
            try multibyteLine.utf8.forEach { byte in
                _ = try oneByteShort.ingest(byte: byte)
            }
        ) { error in
            guard case OpenCodeConnectionError.eventLineTooLong(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 1)
        }
    }

    func testSSERecordSafetyLimitAcceptsExactSizeAndRejectsOverflowWithoutPayload() throws {
        var exact = OpenCodeSSEParser(maxEventBytes: 8)
        XCTAssertNil(try exact.ingest(line: "data: x"))
        XCTAssertEqual(try exact.ingest(line: ""), Data("x".utf8))

        let secretPayload = "Authorization Basic sentinel-secret"
        var overflow = OpenCodeSSEParser(maxEventBytes: 8)
        XCTAssertThrowsError(
            try overflow.ingest(line: "data: \(secretPayload)")
        ) { error in
            guard case OpenCodeConnectionError.eventRecordTooLarge(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 8)
            XCTAssertEqual(
                error.localizedDescription,
                "The OpenCode event stream sent a record larger than the 8-byte safety limit."
            )
            for confidentialMarker in ["Authorization", "Basic", "sentinel-secret"] {
                XCTAssertFalse(error.localizedDescription.contains(confidentialMarker))
            }
        }
    }

    func testSSERecordAggregateAcceptsTwoDataLinesAt16BytesButRejects15() throws {
        var exact = OpenCodeSSEParser(maxEventBytes: 16)
        XCTAssertNil(try exact.ingest(line: "data: a"))
        XCTAssertNil(try exact.ingest(line: "data: b"))
        XCTAssertEqual(try exact.ingest(line: ""), Data("a\nb".utf8))

        var oneByteShort = OpenCodeSSEParser(maxEventBytes: 15)
        XCTAssertNil(try oneByteShort.ingest(line: "data: a"))
        XCTAssertThrowsError(try oneByteShort.ingest(line: "data: b")) { error in
            guard case OpenCodeConnectionError.eventRecordTooLarge(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 15)
        }
    }

    func testSSERecordAggregateCountsIgnoredAndCommentLines() throws {
        var parser = OpenCodeSSEParser(maxEventBytes: 18)

        XCTAssertNil(try parser.ingest(line: ": comment"))
        XCTAssertThrowsError(try parser.ingest(line: "event: x")) { error in
            guard case OpenCodeConnectionError.eventRecordTooLarge(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 18)
        }
    }

    func testSSERecordBlankLineResetAllowsConsecutiveExactLimitRecords() throws {
        var parser = OpenCodeSSEParser(maxEventBytes: 8)

        XCTAssertNil(try parser.ingest(line: "data: a"))
        XCTAssertEqual(try parser.ingest(line: ""), Data("a".utf8))
        XCTAssertNil(try parser.ingest(line: "data: b"))
        XCTAssertEqual(try parser.ingest(line: ""), Data("b".utf8))
    }

    func testEventDisconnectDiagnosticUsesOnlyLocalizedDescription() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [
                NSLocalizedDescriptionKey: "The network connection was lost.",
                "debug": "Authorization: Basic sentinel-secret",
            ]
        )

        let message = OpenCodeSessionStore.eventConnectionMessage(for: error)

        XCTAssertEqual(
            message,
            "Live updates disconnected: The network connection was lost. Reconnecting automatically."
        )
        XCTAssertFalse(message.contains("Authorization"))
        XCTAssertFalse(message.contains("sentinel-secret"))
    }

    func testPendingActionEventTypesIncludeCurrentV2Aliases() {
        let supported = [
            "permission.asked",
            "permission.replied",
            "permission.v2.asked",
            "permission.v2.replied",
            "question.asked",
            "question.replied",
            "question.rejected",
            "question.v2.asked",
            "question.v2.replied",
            "question.v2.rejected",
        ]

        XCTAssertTrue(supported.allSatisfy(OpenCodeSessionStore.isPendingActionEventType))
        XCTAssertFalse(OpenCodeSessionStore.isPendingActionEventType("message.updated"))
    }

    func testSSEBufferOverflowFailsStreamForReconciliation() throws {
        var capturedContinuation:
            AsyncThrowingStream<OpenCodeEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<OpenCodeEvent, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            capturedContinuation = continuation
        }
        let continuation = try XCTUnwrap(capturedContinuation)

        XCTAssertTrue(
            try OpenCodeClient.yieldEvent(
                messageUpdatedEvent(messageID: "msg_first"),
                to: continuation
            )
        )
        XCTAssertThrowsError(
            try OpenCodeClient.yieldEvent(
                messageUpdatedEvent(messageID: "msg_second"),
                to: continuation
            )
        ) { error in
            guard case OpenCodeConnectionError.eventBufferOverflow = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        continuation.finish()
        _ = stream
    }

    func testEventReconciliationCopyDistinguishesQueueOverflowFromSizeLimits() {
        let queueOverflow = OpenCodeSessionStore.eventReconciliationMessage(
            for: .eventBufferOverflow
        )
        let lineLimit = OpenCodeSessionStore.eventReconciliationMessage(
            for: .eventLineTooLong(maxBytes: 2_048)
        )
        let recordLimit = OpenCodeSessionStore.eventReconciliationMessage(
            for: .eventRecordTooLarge(maxBytes: 8_192)
        )

        XCTAssertEqual(
            queueOverflow,
            "Live updates fell behind. Reconnecting and reconciling with OpenCode."
        )
        XCTAssertEqual(
            lineLimit,
            "Live updates exceeded the safe event size. Reconnecting and reconciling with OpenCode."
        )
        XCTAssertEqual(recordLimit, lineLimit)
        XCTAssertNotEqual(queueOverflow, lineLimit)
    }

    func testPromptAsyncRequestIncludesWorkspaceAndAcceptsNoContent() throws {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        let client = OpenCodeClient(profile: profile, password: "secret")
        let request = try client.makeSendMessageRequest(
            sessionID: "ses_123",
            directory: "/repo/sandbox",
            workspace: "ws_456",
            text: "Run the tests"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/session/ses_123/prompt_async")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(query["directory"], "/repo/sandbox")
        XCTAssertEqual(query["workspace"], "ws_456")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertEqual(parts.first?["text"] as? String, "Run the tests")

        let noContent = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        XCTAssertNoThrow(
            try client.validateEmptyResponse(data: Data(), response: noContent)
        )
    }

    func testPromptAsyncRequestEncodesFileAttachmentsAsDataURLs() throws {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        let client = OpenCodeClient(profile: profile, password: "secret")
        let attachment = OpenCodePromptAttachment(
            filename: "screen.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        let request = try client.makeSendMessageRequest(
            sessionID: "ses_attachments",
            directory: "/repo",
            text: "Review this screenshot",
            attachments: [attachment]
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "Review this screenshot")
        XCTAssertEqual(parts[1]["type"] as? String, "file")
        XCTAssertEqual(parts[1]["mime"] as? String, "image/png")
        XCTAssertEqual(parts[1]["filename"] as? String, "screen.png")
        XCTAssertEqual(parts[1]["url"] as? String, "data:image/png;base64,iVBORw==")
    }

    func testPromptAsyncRequestAllowsAttachmentOnlyPrompt() throws {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        let client = OpenCodeClient(profile: profile, password: "secret")
        let attachment = OpenCodePromptAttachment(
            filename: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )

        let request = try client.makeSendMessageRequest(
            sessionID: "ses_attachments",
            directory: "/repo",
            text: "",
            attachments: [attachment]
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertNil(parts[0]["text"])
        XCTAssertEqual(parts[0]["filename"] as? String, "notes.txt")
    }

    func testPromptAttachmentValidationEnforcesCountAndSizeBudgets() throws {
        let tiny = OpenCodePromptAttachment(
            filename: "tiny.txt",
            mimeType: "text/plain",
            data: Data([0x41])
        )
        XCTAssertThrowsError(
            try OpenCodePromptAttachment.validate(
                Array(repeating: tiny, count: OpenCodePromptAttachment.maximumCount + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenCodePromptAttachmentError,
                .tooMany(maximum: OpenCodePromptAttachment.maximumCount)
            )
        }

        let oversized = OpenCodePromptAttachment(
            filename: "large.bin",
            mimeType: "application/octet-stream",
            data: Data(count: OpenCodePromptAttachment.maximumFileBytes + 1)
        )
        XCTAssertThrowsError(try OpenCodePromptAttachment.validate([oversized])) { error in
            XCTAssertEqual(
                error as? OpenCodePromptAttachmentError,
                .fileTooLarge(
                    filename: "large.bin",
                    maximumBytes: OpenCodePromptAttachment.maximumFileBytes
                )
            )
        }
    }

    func testSendMessageTransportAcceptsEmptyNoContentResponse() async throws {
        OpenCodeURLProtocolStub.reset(statusCode: 204)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        let client = OpenCodeClient(
            profile: profile,
            password: "transport-secret",
            session: session
        )

        try await client.sendMessage(
            sessionID: "ses_transport",
            directory: "/repo",
            workspace: "ws_transport",
            text: "Stream this turn"
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.url?.path, "/session/ses_transport/prompt_async")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic \(Data("opencode:transport-secret".utf8).base64EncodedString())"
        )
    }

    func testPermissionReplyDecodesLegacyBooleanResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: #"true"#)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let permission = OpenCodePermissionRequest(
            id: "per_transport",
            sessionID: "ses_transport",
            permission: "bash",
            patterns: ["swift test"],
            metadata: [:],
            always: ["swift *"]
        )

        try await client.reply(
            to: permission,
            directory: "/repo",
            workspace: "ws_transport",
            reply: .once
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.url?.path, "/permission/per_transport/reply")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(queryValues(for: request)["directory"], "/repo")
        XCTAssertEqual(queryValues(for: request)["workspace"], "ws_transport")
        XCTAssertEqual(
            try jsonObject(for: request)["reply"] as? String,
            "once"
        )
    }

    func testQuestionReplyDecodesLegacyBooleanResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: #"true"#)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let question = OpenCodeQuestionRequest(
            id: "que_transport",
            sessionID: "ses_transport",
            questions: [makeQuestion(multiple: false, custom: true)]
        )

        try await client.answer(
            question,
            directory: "/repo",
            workspace: "ws_transport",
            answers: [["App"]]
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.url?.path, "/question/que_transport/reply")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            try jsonObject(for: request)["answers"] as? [[String]],
            [["App"]]
        )
    }

    func testQuestionRejectDecodesLegacyBooleanResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: #"true"#)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let question = OpenCodeQuestionRequest(
            id: "que_transport",
            sessionID: "ses_transport",
            questions: [makeQuestion(multiple: false, custom: true)]
        )

        try await client.reject(
            question,
            directory: "/repo",
            workspace: "ws_transport"
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.url?.path, "/question/que_transport/reject")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.httpBody)
    }

    func testLegacyListRoutesOverridePayloadAPIVersionWithRouteProvenance() async throws {
        defer { OpenCodeURLProtocolStub.reset(statusCode: 204) }
        do {
            let response = #"""
            [{
              "id":"per_legacy",
              "sessionID":"ses_transport",
              "permission":"bash",
              "patterns":["git status"],
              "metadata":{},
              "always":["git *"],
              "apiVersion":"v2"
            }]
            """#
            let (client, session) = makeStubbedClient(responseBody: response)
            defer { session.invalidateAndCancel() }

            let permissions = try await client.permissions(
                directory: "/repo",
                workspace: "ws_transport"
            )

            XCTAssertEqual(permissions.first?.resolvedAPIVersion, .legacy)
        }
        do {
            let response = #"""
            [{
              "id":"que_legacy",
              "sessionID":"ses_transport",
              "questions":[{
                "question":"Which target?",
                "header":"Target",
                "options":[],
                "multiple":false,
                "custom":true
              }],
              "apiVersion":"v2"
            }]
            """#
            let (client, session) = makeStubbedClient(responseBody: response)
            defer { session.invalidateAndCancel() }

            let questions = try await client.questions(
                directory: "/repo",
                workspace: "ws_transport"
            )

            XCTAssertEqual(questions.first?.resolvedAPIVersion, .legacy)
        }
    }

    func testV2PermissionAndQuestionDTOsDecodeSourceAndTool() throws {
        let permissionPayload = #"""
        {
          "id": "per_v2",
          "sessionID": "ses_v2",
          "action": "bash",
          "resources": ["git status"],
          "save": ["git *"],
          "metadata": { "risk": "low" },
          "source": {
            "type": "tool",
            "messageID": "msg_permission",
            "callID": "call_permission"
          }
        }
        """#
        let questionPayload = #"""
        {
          "id": "que_v2",
          "sessionID": "ses_v2",
          "questions": [{
            "question": "Which target?",
            "header": "Target",
            "options": [{ "label": "App", "description": "Build the app." }],
            "multiple": false,
            "custom": true
          }],
          "tool": {
            "messageID": "msg_question",
            "callID": "call_question"
          }
        }
        """#

        let rawPermission = try JSONDecoder().decode(
            OpenCodePermissionV2Request.self,
            from: Data(permissionPayload.utf8)
        )
        let permission = rawPermission.normalized
        let question = try JSONDecoder().decode(
            OpenCodeQuestionRequest.self,
            from: Data(questionPayload.utf8)
        )

        XCTAssertEqual(permission.permission, "bash")
        XCTAssertEqual(permission.patterns, ["git status"])
        XCTAssertEqual(permission.always, ["git *"])
        XCTAssertEqual(permission.metadata["risk"]?.stringValue, "low")
        XCTAssertEqual(permission.source?.type, "tool")
        XCTAssertEqual(permission.source?.messageID, "msg_permission")
        XCTAssertEqual(permission.source?.callID, "call_permission")
        XCTAssertEqual(permission.resolvedAPIVersion, .v2)
        XCTAssertEqual(question.tool?.messageID, "msg_question")
        XCTAssertEqual(question.tool?.callID, "call_question")

        let minimalPayload = #"""
        {
          "id": "per_minimal",
          "sessionID": "ses_v2",
          "action": "edit",
          "resources": ["/repo/file.swift"]
        }
        """#
        let minimal = try JSONDecoder().decode(
            OpenCodePermissionV2Request.self,
            from: Data(minimalPayload.utf8)
        ).normalized
        XCTAssertEqual(minimal.always, [])
        XCTAssertEqual(minimal.metadata, [:])
        XCTAssertNil(minimal.source)
        XCTAssertEqual(minimal.resolvedAPIVersion, .v2)
    }

    func testV2PermissionListUsesExactSessionScopedWrapperRoute() async throws {
        let response = #"""
        {"data":[{
          "id":"per_v2",
          "sessionID":"ses_transport",
          "action":"read",
          "resources":["/repo/**"],
          "save":["/repo/**"],
          "source":{"type":"tool","messageID":"msg_1","callID":"call_1"}
        }]}
        """#
        let (client, session) = makeStubbedClient(responseBody: response)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }

        let permissions = try await client.v2Permissions(sessionID: "ses_transport")

        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions.first?.resolvedAPIVersion, .v2)
        XCTAssertEqual(permissions.first?.source?.callID, "call_1")
        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/session/ses_transport/permission")
        XCTAssertTrue(queryValues(for: request).isEmpty)
    }

    func testV2QuestionListUsesExactSessionScopedWrapperRoute() async throws {
        let response = #"""
        {"data":[{
          "id":"que_v2",
          "sessionID":"ses_transport",
          "questions":[{
            "question":"Which target?",
            "header":"Target",
            "options":[],
            "multiple":false,
            "custom":true
          }],
          "tool":{"messageID":"msg_1","callID":"call_1"}
        }]}
        """#
        let (client, session) = makeStubbedClient(responseBody: response)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }

        let questions = try await client.v2Questions(sessionID: "ses_transport")

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.resolvedAPIVersion, .v2)
        XCTAssertEqual(questions.first?.tool?.callID, "call_1")
        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/session/ses_transport/question")
        XCTAssertTrue(queryValues(for: request).isEmpty)
    }

    func testV2PermissionReplyUsesSessionScopedRouteAndNoContentResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: "", statusCode: 204)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let permission = OpenCodePermissionRequest(
            id: "per_transport",
            sessionID: "ses_transport",
            permission: "bash",
            patterns: ["swift test"],
            metadata: [:],
            always: ["swift *"],
            apiVersion: .v2
        )

        try await client.reply(
            to: permission,
            directory: "/must/not/be/sent",
            workspace: "must-not-be-sent",
            reply: .always
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path,
            "/api/session/ses_transport/permission/per_transport/reply"
        )
        XCTAssertTrue(queryValues(for: request).isEmpty)
        let body = try jsonObject(for: request)
        XCTAssertEqual(Set(body.keys), ["reply"])
        XCTAssertEqual(body["reply"] as? String, "always")
    }

    func testV2QuestionReplyUsesSessionScopedRouteAndNoContentResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: "", statusCode: 204)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let question = OpenCodeQuestionRequest(
            id: "que_transport",
            sessionID: "ses_transport",
            questions: [makeQuestion(multiple: true, custom: true)],
            apiVersion: .v2
        )

        try await client.answer(
            question,
            directory: "/must/not/be/sent",
            workspace: "must-not-be-sent",
            answers: [["App", "Tests"]]
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path,
            "/api/session/ses_transport/question/que_transport/reply"
        )
        XCTAssertTrue(queryValues(for: request).isEmpty)
        let body = try jsonObject(for: request)
        XCTAssertEqual(Set(body.keys), ["answers"])
        XCTAssertEqual(body["answers"] as? [[String]], [["App", "Tests"]])
    }

    func testV2QuestionRejectUsesSessionScopedRouteAndNoContentResponse() async throws {
        let (client, session) = makeStubbedClient(responseBody: "", statusCode: 204)
        defer {
            session.invalidateAndCancel()
            OpenCodeURLProtocolStub.reset(statusCode: 204)
        }
        let question = OpenCodeQuestionRequest(
            id: "que_transport",
            sessionID: "ses_transport",
            questions: [makeQuestion(multiple: false, custom: true)],
            apiVersion: .v2
        )

        try await client.reject(
            question,
            directory: "/must/not/be/sent",
            workspace: "must-not-be-sent"
        )

        let request = try XCTUnwrap(OpenCodeURLProtocolStub.recordedRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path,
            "/api/session/ses_transport/question/que_transport/reject"
        )
        XCTAssertTrue(queryValues(for: request).isEmpty)
        XCTAssertNil(request.httpBody)
    }

    func testV2ListRoutesFallBackOnlyForNotFoundAndMethodNotAllowed() async throws {
        defer { OpenCodeURLProtocolStub.reset(statusCode: 204) }
        for statusCode in [404, 405] {
            let (client, session) = makeStubbedClient(
                responseBody: #"{"message":"unsupported"}"#,
                statusCode: statusCode
            )
            let permissions = try await client.v2Permissions(sessionID: "ses_transport")
            let questions = try await client.v2Questions(sessionID: "ses_transport")
            XCTAssertTrue(permissions.isEmpty)
            XCTAssertTrue(questions.isEmpty)
            session.invalidateAndCancel()
        }

        let (client, session) = makeStubbedClient(
            responseBody: #"{"message":"do not swallow"}"#,
            statusCode: 500
        )
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.v2Permissions(sessionID: "ses_transport")
            XCTFail("Expected the v2 permission list to propagate HTTP 500")
        } catch let error as OpenCodeConnectionError {
            guard case .httpStatus(500, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "do not swallow")
        }
        do {
            _ = try await client.v2Questions(sessionID: "ses_transport")
            XCTFail("Expected the v2 question list to propagate HTTP 500")
        } catch let error as OpenCodeConnectionError {
            guard case .httpStatus(500, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "do not swallow")
        }
    }

    func testPendingActionMergeRetainsLegacyAndV2RequestsWithSameRawID() {
        let legacyPermission = OpenCodePermissionRequest(
            id: "per_same",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["git status"],
            metadata: [:],
            always: ["git *"]
        )
        let v2Permission = OpenCodePermissionRequest(
            id: "per_same",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["git status"],
            metadata: [:],
            always: ["git *"],
            apiVersion: .v2
        )
        let legacyQuestion = OpenCodeQuestionRequest(
            id: "que_same",
            sessionID: "ses_1",
            questions: [makeQuestion(multiple: false, custom: true)]
        )
        let v2Question = OpenCodeQuestionRequest(
            id: "que_same",
            sessionID: "ses_1",
            questions: [makeQuestion(multiple: false, custom: true)],
            apiVersion: .v2
        )

        let permissions = OpenCodeSessionStore.mergePermissions(
            legacy: [legacyPermission],
            v2: [v2Permission],
            sessionID: "ses_1"
        )
        let questions = OpenCodeSessionStore.mergeQuestions(
            legacy: [legacyQuestion],
            v2: [v2Question],
            sessionID: "ses_1"
        )

        XCTAssertEqual(permissions.map(\.id), ["per_same", "per_same"])
        XCTAssertEqual(permissions.map(\.resolvedAPIVersion), [.legacy, .v2])
        XCTAssertEqual(questions.map(\.id), ["que_same", "que_same"])
        XCTAssertEqual(questions.map(\.resolvedAPIVersion), [.legacy, .v2])
    }

    func testCapturedActionFamilyFailureRetainsFallbackAlongsideSuccessfulFamily() async {
        let refreshedLegacy = OpenCodePermissionRequest(
            id: "per_legacy_refreshed",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["git status"],
            metadata: [:],
            always: ["git *"]
        )
        let retainedV2 = OpenCodePermissionRequest(
            id: "per_v2_retained",
            sessionID: "ses_1",
            permission: "read",
            patterns: ["/repo/**"],
            metadata: [:],
            always: ["/repo/**"],
            apiVersion: .v2
        )

        let legacyResult: Result<[OpenCodePermissionRequest], Error> =
            await OpenCodeSessionStore.capture { [refreshedLegacy] }
        let v2Result: Result<[OpenCodePermissionRequest], Error> =
            await OpenCodeSessionStore.capture {
                throw OpenCodeConnectionError.httpStatus(503, nil)
            }
        let legacyOutcome = OpenCodeSessionStore.recoverActionValues(
            from: legacyResult,
            fallback: []
        )
        let v2Outcome = OpenCodeSessionStore.recoverActionValues(
            from: v2Result,
            fallback: [retainedV2]
        )
        let merged = OpenCodeSessionStore.mergePermissions(
            legacy: legacyOutcome.values,
            v2: v2Outcome.values,
            sessionID: "ses_1"
        )

        XCTAssertNil(legacyOutcome.error)
        guard let v2Error = v2Outcome.error as? OpenCodeConnectionError,
              case .httpStatus(503, nil) = v2Error
        else {
            return XCTFail("Expected the failed v2 family error to be preserved")
        }
        XCTAssertEqual(
            merged.map(\.presentationID),
            ["legacy:per_legacy_refreshed", "v2:per_v2_retained"]
        )
    }

    func testTranscriptReducerAppliesStreamingDeltasAndAuthoritativeUpdates() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_message",
          "type": "message.updated",
          "properties": {
            "sessionID": "ses_1",
            "info": {
              "id": "msg_1",
              "sessionID": "ses_1",
              "role": "assistant",
              "time": { "created": 1770000000000 }
            }
          }
        }
        """#)))
        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_part",
          "type": "message.part.updated",
          "properties": {
            "sessionID": "ses_1",
            "part": {
              "id": "part_1",
              "sessionID": "ses_1",
              "messageID": "msg_1",
              "type": "text",
              "text": ""
            }
          }
        }
        """#)))
        XCTAssertTrue(try reducer.apply(deltaEvent("Hello")))
        XCTAssertTrue(try reducer.apply(deltaEvent(" world")))
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "Hello world")

        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_final",
          "type": "message.part.updated",
          "properties": {
            "sessionID": "ses_1",
            "part": {
              "id": "part_1",
              "sessionID": "ses_1",
              "messageID": "msg_1",
              "type": "text",
              "text": "Hello world."
            }
          }
        }
        """#)))
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "Hello world.")

        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_part_removed",
          "type": "message.part.removed",
          "properties": {
            "sessionID": "ses_1",
            "messageID": "msg_1",
            "partID": "part_1"
          }
        }
        """#)))
        XCTAssertEqual(reducer.messages.first?.parts, [])
        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_message_removed",
          "type": "message.removed",
          "properties": {
            "sessionID": "ses_1",
            "messageID": "msg_1"
          }
        }
        """#)))
        XCTAssertTrue(reducer.messages.isEmpty)
    }

    func testTranscriptReducerBuffersOrphanDeltaAndClearsItOnSnapshot() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(try reducer.apply(deltaEvent("orphan")))
        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_orphan_part",
          "type": "message.part.updated",
          "properties": {
            "sessionID": "ses_1",
            "part": {
              "id": "part_1",
              "sessionID": "ses_1",
              "messageID": "msg_1",
              "type": "text",
              "text": ""
            }
          }
        }
        """#)))
        XCTAssertTrue(try reducer.apply(event(#"""
        {
          "id": "evt_orphan_message",
          "type": "message.updated",
          "properties": {
            "sessionID": "ses_1",
            "info": {
              "id": "msg_1",
              "sessionID": "ses_1",
              "role": "assistant",
              "time": { "created": 1770000000000 }
            }
          }
        }
        """#)))
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "orphan")

        reducer.replace(with: [])
        XCTAssertTrue(reducer.messages.isEmpty)
        XCTAssertFalse(try reducer.apply(event(#"""
        {
          "id": "evt_non_text",
          "type": "message.part.delta",
          "properties": {
            "sessionID": "ses_1",
            "messageID": "msg_1",
            "partID": "part_1",
            "field": "metadata",
            "delta": "ignored"
          }
        }
        """#)))
        XCTAssertTrue(reducer.messages.isEmpty)
    }

    func testTranscriptReducerReplaceDiscardsPendingOrphanDelta() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(try reducer.apply(deltaEvent("stale")))
        reducer.replace(with: [])

        XCTAssertTrue(try reducer.apply(partUpdatedEvent(text: "")))
        XCTAssertTrue(try reducer.apply(messageUpdatedEvent()))
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "")

        XCTAssertTrue(try reducer.apply(deltaEvent("fresh")))
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "fresh")
    }

    func testTranscriptReducerIgnoresNonTextDeltaWithoutMutation() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(try reducer.apply(messageUpdatedEvent()))
        XCTAssertTrue(try reducer.apply(partUpdatedEvent(text: "stable")))
        let originalMessages = reducer.messages

        XCTAssertFalse(
            try reducer.apply(
                deltaEvent("ignored", field: "metadata")
            )
        )
        XCTAssertEqual(reducer.messages, originalMessages)
    }

    func testTranscriptReducerPartRemovalClearsPendingAndBufferedOrphans() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(
            try reducer.apply(
                deltaEvent("stale pending", partID: "part_pending")
            )
        )
        XCTAssertTrue(
            try reducer.apply(
                partUpdatedEvent(partID: "part_buffered", text: "stale buffered")
            )
        )

        _ = try reducer.apply(partRemovedEvent(partID: "part_pending"))
        XCTAssertTrue(
            try reducer.apply(partRemovedEvent(partID: "part_buffered"))
        )

        XCTAssertTrue(
            try reducer.apply(
                partUpdatedEvent(partID: "part_pending", text: "")
            )
        )
        XCTAssertTrue(try reducer.apply(messageUpdatedEvent()))

        XCTAssertEqual(reducer.messages.first?.parts.map(\.id), ["part_pending"])
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "")
    }

    func testTranscriptReducerMessageRemovalClearsAllOrphanState() throws {
        var reducer = OpenCodeTranscriptReducer()

        XCTAssertTrue(
            try reducer.apply(
                deltaEvent("stale pending", partID: "part_pending")
            )
        )
        XCTAssertTrue(
            try reducer.apply(
                partUpdatedEvent(partID: "part_buffered", text: "stale buffered")
            )
        )

        _ = try reducer.apply(messageRemovedEvent())

        XCTAssertTrue(
            try reducer.apply(
                partUpdatedEvent(partID: "part_pending", text: "")
            )
        )
        XCTAssertTrue(try reducer.apply(messageUpdatedEvent()))

        XCTAssertEqual(reducer.messages.first?.parts.map(\.id), ["part_pending"])
        XCTAssertEqual(reducer.messages.first?.parts.first?.text, "")
    }

    func testTranscriptReducerOrdersEqualTimestampsByMessageID() throws {
        var reducer = OpenCodeTranscriptReducer()

        reducer.replace(
            with: [
                messageEnvelope(id: "msg_z", created: 1770000000000),
                messageEnvelope(id: "msg_a", created: 1770000000000),
            ]
        )
        XCTAssertEqual(reducer.messages.map(\.id), ["msg_a", "msg_z"])

        XCTAssertTrue(
            try reducer.apply(
                messageUpdatedEvent(
                    messageID: "msg_m",
                    created: 1770000000000
                )
            )
        )
        XCTAssertEqual(
            reducer.messages.map(\.id),
            ["msg_a", "msg_m", "msg_z"]
        )
    }

    func testSingleChoiceCustomAnswerReplacesAndOptionSelectionClearsCustom() {
        let question = makeQuestion(multiple: false, custom: true)
        var state = OpenCodeQuestionResponseState()

        state.toggle("App", at: 0, question: question)
        XCTAssertEqual(state.resolvedAnswers(for: [question]), [["App"]])

        state.setCustomAnswer("CLI", at: 0, question: question)
        XCTAssertEqual(state.resolvedAnswers(for: [question]), [["CLI"]])

        state.toggle("Tests", at: 0, question: question)
        XCTAssertEqual(state.resolvedAnswers(for: [question]), [["Tests"]])
    }

    func testMultipleChoiceCustomAnswerAppendsToSelections() {
        let question = makeQuestion(multiple: true, custom: true)
        var state = OpenCodeQuestionResponseState()

        state.toggle("Tests", at: 0, question: question)
        state.toggle("App", at: 0, question: question)
        state.setCustomAnswer("CLI", at: 0, question: question)

        XCTAssertEqual(
            state.resolvedAnswers(for: [question]),
            [["App", "Tests", "CLI"]]
        )
        XCTAssertTrue(state.canSubmit(questions: [question]))
    }

    func testAlwaysAllowUsesExactVersionedScopeCopy() {
        let scoped = OpenCodePermissionRequest(
            id: "per_scoped",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["dangerous fallback must not be shown"],
            metadata: [:],
            always: ["git status", "swift test"]
        )
        XCTAssertEqual(
            scoped.alwaysAllowConfirmationMessage,
            "While this OpenCode instance remains active, this allows bash requests matching: git status, swift test in this directory. The rule is kept in memory and is not persisted."
        )
        XCTAssertEqual(scoped.rememberedScopeTitle, "Always allow would remember for this directory")
        XCTAssertEqual(
            scoped.rememberedScopeFooter,
            "The rule is kept in memory while this OpenCode instance remains active and is not persisted."
        )

        let wildcard = OpenCodePermissionRequest(
            id: "per_wildcard",
            sessionID: "ses_1",
            permission: "read",
            patterns: ["/repo/**"],
            metadata: [:],
            always: ["*"]
        )
        XCTAssertEqual(
            wildcard.alwaysAllowConfirmationMessage,
            "While this OpenCode instance remains active, this allows every read request in this directory. The rule is kept in memory and is not persisted."
        )

        let persistent = OpenCodePermissionRequest(
            id: "per_persistent",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["git status"],
            metadata: [:],
            always: ["git *"],
            apiVersion: .v2
        )
        XCTAssertEqual(
            persistent.alwaysAllowConfirmationMessage,
            "This saves bash requests matching: git * in this OpenCode project. The rule applies across project sessions and server restarts until removed from saved permissions. Configured deny rules still take precedence."
        )
        XCTAssertEqual(persistent.rememberedScopeTitle, "Always allow would save this project permission")
        XCTAssertEqual(
            persistent.rememberedScopeFooter,
            "The saved rule applies across project sessions and server restarts until removed. Configured deny rules still take precedence."
        )

        let unscoped = OpenCodePermissionRequest(
            id: "per_unscoped",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["must not become remembered scope"],
            metadata: [:],
            always: []
        )
        XCTAssertNil(unscoped.alwaysAllowConfirmationMessage)
    }

    func testQuestionCustomAnswerDefaultsToEnabledWhenOmitted() throws {
        let payload = #"""
        {
          "question": "Which target?",
          "header": "Target",
          "options": [],
          "multiple": false
        }
        """#
        let question = try JSONDecoder().decode(
            OpenCodeQuestion.self,
            from: Data(payload.utf8)
        )

        XCTAssertTrue(question.allowsCustomAnswer)
        XCTAssertFalse(makeQuestion(multiple: false, custom: false).allowsCustomAnswer)
    }

    func testMessageFixtureDecodesTextReasoningAndToolActivity() throws {
        let payload = #"""
        {
          "info": {
            "id": "msg_assistant",
            "sessionID": "ses_1",
            "role": "assistant",
            "time": { "created": 1770000000000, "completed": 1770000001200 },
            "parentID": "msg_user",
            "modelID": "gpt-5",
            "providerID": "openai",
            "mode": "build",
            "agent": "build",
            "path": { "cwd": "/repo", "root": "/repo" },
            "cost": 0.01,
            "tokens": { "input": 4, "output": 8, "reasoning": 2, "cache": { "read": 0, "write": 0 } },
            "finish": "stop"
          },
          "parts": [
            {
              "id": "part_text",
              "sessionID": "ses_1",
              "messageID": "msg_assistant",
              "type": "text",
              "text": "Implemented the change."
            },
            {
              "id": "part_reasoning",
              "sessionID": "ses_1",
              "messageID": "msg_assistant",
              "type": "reasoning",
              "text": "Inspecting the tests.",
              "time": { "start": 1770000000000 }
            },
            {
              "id": "part_tool",
              "sessionID": "ses_1",
              "messageID": "msg_assistant",
              "type": "tool",
              "callID": "call_1",
              "tool": "bash",
              "state": {
                "status": "completed",
                "input": { "command": "swift test", "count": 2 },
                "output": "All tests passed",
                "title": "Run tests",
                "metadata": {},
                "time": { "start": 1770000000100, "end": 1770000001100 }
              }
            }
          ]
        }
        """#

        let message = try JSONDecoder().decode(
            OpenCodeMessageEnvelope.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(message.info.role, "assistant")
        XCTAssertEqual(message.parts.map(\.type), ["text", "reasoning", "tool"])
        XCTAssertEqual(message.parts.last?.state?.status, "completed")
        XCTAssertEqual(message.parts.last?.state?.input?["command"]?.stringValue, "swift test")
        XCTAssertEqual(message.parts.last?.state?.output, "All tests passed")
    }

    func testPermissionQuestionAndStatusFixturesDecode() throws {
        let permissionPayload = #"""
        [{
          "id": "per_1",
          "sessionID": "ses_1",
          "permission": "bash",
          "patterns": ["git status"],
          "metadata": { "risk": "low" },
          "always": ["git *"]
        }]
        """#
        let questionPayload = #"""
        [{
          "id": "que_1",
          "sessionID": "ses_1",
          "questions": [{
            "question": "Which target should I build?",
            "header": "Target",
            "options": [
              { "label": "App", "description": "Build the application." },
              { "label": "Tests", "description": "Build tests only." }
            ],
            "multiple": false,
            "custom": true
          }]
        }]
        """#
        let statusPayload = #"{"ses_1":{"type":"busy"},"ses_2":{"type":"retry","attempt":2,"message":"rate limited","next":1770000000000}}"#

        let permissions = try JSONDecoder().decode(
            [OpenCodePermissionRequest].self,
            from: Data(permissionPayload.utf8)
        )
        let questions = try JSONDecoder().decode(
            [OpenCodeQuestionRequest].self,
            from: Data(questionPayload.utf8)
        )
        let statuses = try JSONDecoder().decode(
            [String: OpenCodeSessionStatus].self,
            from: Data(statusPayload.utf8)
        )

        XCTAssertEqual(permissions.first?.permission, "bash")
        XCTAssertEqual(questions.first?.questions.first?.options.count, 2)
        XCTAssertEqual(statuses["ses_1"], .busy)
        XCTAssertEqual(statuses["ses_2"]?.label, "Retry 2")
    }

    private func decodedSSEEvents(from payload: Data) throws -> [OpenCodeEvent] {
        try decodedSSEDataRecords(from: payload).map {
            try JSONDecoder().decode(OpenCodeEvent.self, from: $0)
        }
    }

    private func decodedSSEDataRecords(from payload: Data) throws -> [Data] {
        var framer = OpenCodeSSELineFramer()
        var parser = OpenCodeSSEParser()
        var records: [Data] = []
        for byte in payload {
            guard let line = try framer.ingest(byte: byte),
                  let data = try parser.ingest(line: line)
            else { continue }
            records.append(data)
        }
        framer.discardIncompleteLine()
        parser.discard()
        return records
    }

    private func event(_ json: String) throws -> OpenCodeEvent {
        try JSONDecoder().decode(OpenCodeEvent.self, from: Data(json.utf8))
    }

    private func messageUpdatedEvent(
        messageID: String = "msg_1",
        created: Double = 1770000000000
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_message_\(messageID)",
            type: "message.updated",
            properties: [
                "sessionID": .string("ses_1"),
                "info": .object([
                    "id": .string(messageID),
                    "sessionID": .string("ses_1"),
                    "role": .string("assistant"),
                    "time": .object(["created": .number(created)]),
                ]),
            ]
        )
    }

    private func messageRemovedEvent(
        messageID: String = "msg_1"
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_message_removed_\(messageID)",
            type: "message.removed",
            properties: [
                "sessionID": .string("ses_1"),
                "messageID": .string(messageID),
            ]
        )
    }

    private func partUpdatedEvent(
        messageID: String = "msg_1",
        partID: String = "part_1",
        text: String
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_part_\(partID)",
            type: "message.part.updated",
            properties: [
                "sessionID": .string("ses_1"),
                "part": .object([
                    "id": .string(partID),
                    "sessionID": .string("ses_1"),
                    "messageID": .string(messageID),
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]
        )
    }

    private func partRemovedEvent(
        messageID: String = "msg_1",
        partID: String
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_part_removed_\(partID)",
            type: "message.part.removed",
            properties: [
                "sessionID": .string("ses_1"),
                "messageID": .string(messageID),
                "partID": .string(partID),
            ]
        )
    }

    private func deltaEvent(
        _ delta: String,
        messageID: String = "msg_1",
        partID: String = "part_1",
        field: String = "text"
    ) throws -> OpenCodeEvent {
        let properties: [String: OpenCodeJSONValue] = [
            "sessionID": .string("ses_1"),
            "messageID": .string(messageID),
            "partID": .string(partID),
            "field": .string(field),
            "delta": .string(delta),
        ]
        return OpenCodeEvent(
            id: "evt_delta_\(delta)",
            type: "message.part.delta",
            properties: properties
        )
    }

    private func messageEnvelope(
        id: String,
        created: Double
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(
                id: id,
                sessionID: "ses_1",
                role: "assistant",
                time: OpenCodeMessageTime(created: created, completed: nil),
                agent: nil,
                modelID: nil,
                providerID: nil,
                finish: nil,
                error: nil
            ),
            parts: []
        )
    }

    private func makeQuestion(multiple: Bool, custom: Bool) -> OpenCodeQuestion {
        OpenCodeQuestion(
            question: "Which target?",
            header: "Target",
            options: [
                OpenCodeQuestionOption(label: "App", description: "Application"),
                OpenCodeQuestionOption(label: "Tests", description: "Test suite"),
            ],
            multiple: multiple,
            custom: custom
        )
    }

    private func makeStubbedClient(
        responseBody: String,
        statusCode: Int = 200
    ) -> (OpenCodeClient, URLSession) {
        OpenCodeURLProtocolStub.reset(
            statusCode: statusCode,
            data: Data(responseBody.utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        return (
            OpenCodeClient(
                profile: profile,
                password: "transport-secret",
                session: session
            ),
            session
        )
    }

    private func queryValues(for request: URLRequest) -> [String: String] {
        let items = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        return Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
    }

    private func jsonObject(for request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }
}

private final class OpenCodeURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var statusCode = 204
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var lastRequest: URLRequest?

    static func reset(statusCode: Int, data: Data = Data()) {
        stateLock.lock()
        self.statusCode = statusCode
        responseData = data
        lastRequest = nil
        stateLock.unlock()
    }

    static func recordedRequest() -> URLRequest? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mac.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil,
           let bodyStream = recordedRequest.httpBodyStream {
            recordedRequest.httpBody = Self.readBody(from: bodyStream)
        }
        Self.stateLock.lock()
        Self.lastRequest = recordedRequest
        let statusCode = Self.statusCode
        let responseData = Self.responseData
        Self.stateLock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: OpenCodeConnectionError.invalidResponse
            )
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseData.isEmpty {
            client?.urlProtocol(self, didLoad: responseData)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(from stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let capacity = buffer.count
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: capacity)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func stopLoading() { }
}
