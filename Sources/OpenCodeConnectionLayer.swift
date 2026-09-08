import Foundation

/// Construction is separate from use, like an Effect Layer's service inputs
/// and outputs. Tests can replace acquisition without emulating an HTTP server.
protocol OpenCodeConnectionSource: Sendable {
    func probe() async throws -> OpenCodeServerProbe
    func makeAdapter(for serverProtocol: OpenCodeServerProtocol) async throws -> any OpenCodeProtocolAdapting
}

struct OpenCodeLiveConnectionSource: OpenCodeConnectionSource {
    let transport: any OpenCodeHTTPTransport
    let profile: OpenCodeServerProfile

    func probe() async throws -> OpenCodeServerProbe {
        try await OpenCodeProtocolDetector(transport: transport).probe()
    }

    func makeAdapter(for serverProtocol: OpenCodeServerProtocol) async throws -> any OpenCodeProtocolAdapting
    {
        switch serverProtocol {
        case .v1:
            return OpenCodeV1Adapter(transport: transport, profile: profile)
        case .v2:
            let schema: OpenCodeJSONValue = try await transport.get(["openapi.json"], query: [])
            return OpenCodeV2Adapter(
                contract: try OpenCodeV2Contract(schema: schema),
                transport: transport,
                profile: profile
            )
        }
    }
}

/// One scope per configured server. Successful acquisition is shared by all
/// consumers. A refresh invalidates the whole adapter, including its schema.
actor OpenCodeConnection {
    private struct Work<Value: Sendable> {
        let id = UUID()
        let task: Task<Value, Error>
    }

    private let source: any OpenCodeConnectionSource
    private var serverProtocol: OpenCodeServerProtocol?
    private var cachedAdapter: (any OpenCodeProtocolAdapting)?
    private var probeWork: Work<OpenCodeServerProbe>?
    private var adapterWork: Work<any OpenCodeProtocolAdapting>?
    private var generation = 0

    init(source: any OpenCodeConnectionSource, serverProtocol: OpenCodeServerProtocol? = nil) {
        self.source = source
        self.serverProtocol = serverProtocol
    }

    deinit {
        probeWork?.task.cancel()
        adapterWork?.task.cancel()
    }

    /// Concurrent refreshes share an in-flight health probe. A later refresh
    /// starts a new generation, so an older schema cannot repopulate the cache.
    func probe() async throws -> OpenCodeServerProbe {
        try Task.checkCancellation()
        let work: Work<OpenCodeServerProbe>
        if let existing = probeWork {
            work = existing
        } else {
            generation &+= 1
            serverProtocol = nil
            cachedAdapter = nil
            adapterWork?.task.cancel()
            adapterWork = nil
            let source = source
            work = Work(task: Task { try await source.probe() })
            probeWork = work
        }
        do {
            let probe = try await work.task.value
            if probeWork?.id == work.id {
                serverProtocol = probe.protocol
                probeWork = nil
            }
            // Acquisition belongs to the connection, not a particular waiter.
            // Cancelling one screen must not cancel another screen's lookup.
            try Task.checkCancellation()
            return probe
        } catch {
            if probeWork?.id == work.id { probeWork = nil }
            try Task.checkCancellation()
            throw error
        }
    }

    func adapter() async throws -> any OpenCodeProtocolAdapting {
        while true {
            try Task.checkCancellation()
            if let cachedAdapter { return cachedAdapter }
            guard let serverProtocol else {
                _ = try await probe()
                continue
            }
            let currentGeneration = generation
            let work: Work<any OpenCodeProtocolAdapting>
            if let existing = adapterWork {
                work = existing
            } else {
                let source = source
                work = Work(task: Task { try await source.makeAdapter(for: serverProtocol) })
                adapterWork = work
            }
            do {
                let adapter = try await work.task.value
                if currentGeneration == generation, adapterWork?.id == work.id {
                    cachedAdapter = adapter
                    adapterWork = nil
                }
                try Task.checkCancellation()
                guard currentGeneration == generation else { continue }
                return adapter
            } catch {
                try Task.checkCancellation()
                guard currentGeneration == generation else { continue }
                if adapterWork?.id == work.id { adapterWork = nil }
                throw error
            }
        }
    }
}
