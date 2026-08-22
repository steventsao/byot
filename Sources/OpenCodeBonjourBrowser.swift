import Foundation

@MainActor
final class OpenCodeBonjourBrowser: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate,
    OpenCodeBonjourBrowsing
{
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var records: [String: OpenCodeBonjourServiceRecord] = [:]
    private var onUpdate: ((OpenCodeDiscoveryUpdate) -> Void)?

    func start(onUpdate: @escaping (OpenCodeDiscoveryUpdate) -> Void) {
        stop()
        self.onUpdate = onUpdate
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.values.forEach { $0.stop() }
        services.removeAll()
        records.removeAll()
        onUpdate = nil
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard service.name.lowercased().hasPrefix("opencode-") else { return }
        let key = serviceKey(service)
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(service)
        services.removeValue(forKey: key)?.stop()
        records.removeValue(forKey: key)
        publishRecords()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        onUpdate?(.failure("Bonjour discovery could not start. Check Local Network access and try again."))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
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
        let key = serviceKey(sender)
        records[key] = OpenCodeBonjourServiceRecord(
            name: sender.name,
            type: sender.type,
            domain: sender.domain,
            host: host,
            port: sender.port,
            txt: txt
        )
        publishRecords()
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let key = serviceKey(sender)
        services.removeValue(forKey: key)
        records.removeValue(forKey: key)
        publishRecords()
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)"
    }

    private func publishRecords() {
        onUpdate?(.services(Array(records.values)))
    }
}
