import Foundation

@MainActor
final class OpenCodeBonjourBrowser: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate,
    OpenCodeBonjourBrowsing
{
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var records: [String: OpenCodeBonjourServiceRecord] = [:]
    private var callbackGeneration = OpenCodeBonjourCallbackGeneration()
    private var onUpdate: ((OpenCodeDiscoveryUpdate) -> Void)?
    private var initialSearch = OpenCodeDiscoveryInitialSearch()
    private var emptyWindowTask: Task<Void, Never>?

    func start(onUpdate: @escaping (OpenCodeDiscoveryUpdate) -> Void) {
        stop()
        self.onUpdate = onUpdate
        let browser = NetServiceBrowser()
        self.browser = browser
        callbackGeneration.begin(browser: browser)
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }

    func stop() {
        emptyWindowTask?.cancel()
        emptyWindowTask = nil
        onUpdate = nil
        callbackGeneration.end()
        let stoppedBrowser = browser
        browser = nil
        stoppedBrowser?.delegate = nil
        stoppedBrowser?.stop()
        services.values.forEach {
            $0.delegate = nil
            $0.stop()
        }
        services.removeAll()
        records.removeAll()
        initialSearch = OpenCodeDiscoveryInitialSearch()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard callbackGeneration.accepts(browser: browser) else { return }
        emptyWindowTask?.cancel()
        emptyWindowTask = nil
        let isOpenCodeService = service.name.lowercased().hasPrefix("opencode-")
        let key = isOpenCodeService ? serviceKey(service) : nil
        if initialSearch.serviceFound(key: key, moreComing: moreComing) {
            publishSettled()
        }
        guard let key else { return }
        guard callbackGeneration.register(
            service: service,
            key: key,
            browser: browser
        ) else { return }
        let replacedService = services.updateValue(service, forKey: key)
        if let replacedService, replacedService !== service {
            replacedService.delegate = nil
            replacedService.stop()
        }
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        guard callbackGeneration.accepts(browser: browser) else { return }
        emptyWindowTask?.cancel()
        emptyWindowTask = Task { @MainActor [weak self, weak browser] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  let browser,
                  self.callbackGeneration.accepts(browser: browser),
                  self.initialSearch.emptyWindowElapsed()
            else { return }
            self.publishSettled()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        guard callbackGeneration.accepts(browser: browser) else { return }
        let key = serviceKey(service)
        guard callbackGeneration.remove(service: service, key: key) else { return }
        services.removeValue(forKey: key)?.stop()
        records.removeValue(forKey: key)
        publishRecords()
        finishInitialResolution(key: key)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        guard callbackGeneration.accepts(browser: browser) else { return }
        emptyWindowTask?.cancel()
        emptyWindowTask = nil
        onUpdate?(.failure("Bonjour discovery could not start. Check Local Network access and try again."))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let key = serviceKey(sender)
        guard callbackGeneration.accepts(service: sender, key: key) else { return }
        guard let host = OpenCodeBonjourAddressResolver.localHost(
            from: sender.addresses ?? []
        ) else {
            _ = callbackGeneration.remove(service: sender, key: key)
            services.removeValue(forKey: key)
            records.removeValue(forKey: key)
            publishRecords()
            finishInitialResolution(key: key)
            return
        }
        let txt: [String: String]
        if let data = sender.txtRecordData() {
            txt = NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, item in
                if let value = String(data: item.value, encoding: .utf8) {
                    result[item.key] = value
                }
            }
        } else {
            txt = [:]
        }
        records[key] = OpenCodeBonjourServiceRecord(
            name: sender.name,
            type: sender.type,
            domain: sender.domain,
            host: host,
            port: sender.port,
            txt: txt
        )
        publishRecords()
        finishInitialResolution(key: key)
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let key = serviceKey(sender)
        guard callbackGeneration.remove(service: sender, key: key) else { return }
        services.removeValue(forKey: key)
        records.removeValue(forKey: key)
        publishRecords()
        finishInitialResolution(key: key)
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)"
    }

    private func publishRecords() {
        onUpdate?(.services(Array(records.values)))
    }

    private func finishInitialResolution(key: String) {
        if initialSearch.resolutionFinished(key: key) {
            publishSettled()
        }
    }

    private func publishSettled() {
        emptyWindowTask?.cancel()
        emptyWindowTask = nil
        onUpdate?(.settled)
    }
}
