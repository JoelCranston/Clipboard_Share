import Foundation
import SystemConfiguration

/// Advertises this Mac as `_omaclip._tcp` and finds omaclip peers that share the passphrase.
///
/// Must be used from the main thread (NetService callbacks arrive on the main run loop).
public final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    public static let serviceType = "_omaclip._tcp."
    public static let protocolVersion = "2"

    /// Called on the main thread whenever the set of usable peers changes.
    public var onChange: (([Peer]) -> Void)?

    private let shortHash: String
    private var published: NetService?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var peers: [String: Peer] = [:]
    private var refreshTimer: Timer?

    public init(shortHash: String) {
        self.shortHash = shortHash
        super.init()
    }

    /// The machine's Bonjour host name without `.local`, e.g. `Joels-MacBook-Pro`.
    public static var localHostName: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
    }

    public func start(port: Int) {
        let service = NetService(domain: "local.", type: Self.serviceType, name: "\(Self.localHostName)-\(port)", port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "version": Data(Self.protocolVersion.utf8),
            "ph": Data(shortHash.utf8),
        ]))
        service.delegate = self
        service.publish()
        published = service

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = browser

        // omaclip picks a new random port on restart, so re-resolve periodically to notice moves.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.services.values.forEach { $0.resolve(withTimeout: 5) }
        }
    }

    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        browser?.stop()
        browser = nil
        published?.stop()
        published = nil
        services.values.forEach { $0.stop() }
        services.removeAll()
        peers.removeAll()
    }

    private func notify() {
        onChange?(peers.values.sorted { $0.name < $1.name })
    }

    // MARK: NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != published?.name else { return }
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services[service.name]?.stop()
        services[service.name] = nil
        if peers.removeValue(forKey: service.name) != nil { notify() }
    }

    // MARK: NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender !== published, services[sender.name] != nil else { return }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let version = txt["version"].map { String(decoding: $0, as: UTF8.self) }
        let hash = txt["ph"].map { String(decoding: $0, as: UTF8.self) }

        var host: String?
        for address in sender.addresses ?? [] {
            host = address.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                return IPv4.string(from: base.assumingMemoryBound(to: sockaddr.self))
            }
            if host != nil { break }
        }

        let previous = peers[sender.name]
        if version == Self.protocolVersion, hash == shortHash, let host, sender.port > 0 {
            peers[sender.name] = Peer(name: sender.name, host: host, port: sender.port)
        } else {
            peers[sender.name] = nil
        }
        if peers[sender.name] != previous { notify() }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
}
