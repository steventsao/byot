import Foundation

/// Request API versions are authoritative even on a hybrid v1 server.
struct OpenCodeActions: Sendable {
    let transport: any OpenCodeHTTPTransport

    func permissions(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodePermissionRequest] {
        let requests: [OpenCodePermissionRequest] = try await transport.get(
            ["permission"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func reply(
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String? = nil,
        reply: OpenCodePermissionReply
    ) async throws {
        struct Body: Encodable { let reply: OpenCodePermissionReply }
        switch permission.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await transport.post(
                ["permission", permission.id, "reply"],
                query: instanceQuery(directory: directory, workspace: workspace),
                body: Body(reply: reply)
            )
        case .v2:
            try await transport.postExpectingEmptyResponse(
                ["api", "session", permission.sessionID, "permission", permission.id, "reply"],
                body: Body(reply: reply)
            )
        }
    }

    func questions(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeQuestionRequest] {
        let requests: [OpenCodeQuestionRequest] = try await transport.get(
            ["question"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] {
        do {
            let response: OpenCodeDataResponse<[OpenCodePermissionV2Request]> = try await transport.get(
                ["api", "session", sessionID, "permission"],
                query: []
            )
            return response.data.map(\.normalized)
        } catch let error as OpenCodeConnectionError {
            if error.isUnsupportedV2ListRoute { return [] }
            throw error
        }
    }

    func v2Questions(sessionID: String, usesForms: Bool) async throws -> [OpenCodeQuestionRequest] {
        if usesForms {
            let response: OpenCodeDataResponse<[OpenCodeForm]> = try await transport.get(
                ["api", "session", sessionID, "form"], query: [])
            return response.data.map(\.normalized)
        }
        do {
            let response: OpenCodeDataResponse<[OpenCodeQuestionRequest]> = try await transport.get(
                ["api", "session", sessionID, "question"],
                query: []
            )
            return response.data.map { request in
                var request = request
                request.apiVersion = .v2
                return request
            }
        } catch let error as OpenCodeConnectionError {
            if error.isUnsupportedV2ListRoute { return [] }
            throw error
        }
    }

    func answer(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil,
        answers: [[String]]
    ) async throws {
        if let form = question.form {
            struct FormBody: Encodable { let answer: [String: OpenCodeJSONValue] }
            try await transport.postExpectingEmptyResponse(
                ["api", "session", question.sessionID, "form", question.id, "reply"],
                body: FormBody(answer: try form.answer(answers)))
            return
        }
        struct Body: Encodable { let answers: [[String]] }
        switch question.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await transport.post(
                ["question", question.id, "reply"],
                query: instanceQuery(directory: directory, workspace: workspace),
                body: Body(answers: answers)
            )
        case .v2:
            try await transport.postExpectingEmptyResponse(
                ["api", "session", question.sessionID, "question", question.id, "reply"],
                body: Body(answers: answers)
            )
        }
    }

    func reject(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil
    ) async throws {
        if question.form != nil {
            let request = try transport.makeRequest(
                path: ["api", "session", question.sessionID, "form", question.id, "cancel"], query: [],
                method: "POST", body: nil)
            try await transport.performExpectingEmptyResponse(request)
            return
        }
        switch question.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await transport.postWithoutBody(
                ["question", question.id, "reject"],
                query: instanceQuery(directory: directory, workspace: workspace)
            )
        case .v2:
            let request = try transport.makeRequest(
                path: ["api", "session", question.sessionID, "question", question.id, "reject"],
                query: [],
                method: "POST",
                body: nil
            )
            try await transport.performExpectingEmptyResponse(request)
        }
    }

}

private func instanceQuery(
    directory: String?,
    workspace: String? = nil
) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let directory, !directory.isEmpty {
        items.append(URLQueryItem(name: "directory", value: directory))
    }
    if let workspace, !workspace.isEmpty {
        items.append(URLQueryItem(name: "workspace", value: workspace))
    }
    return items
}

private struct OpenCodeDataResponse<Value: Decodable>: Decodable {
    let data: Value
}
