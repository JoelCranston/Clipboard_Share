import Foundation
import SystemConfiguration

/// Advertises this Mac as `_omaclip._tcp` and finds omaclip peers that share the passphrase.
///
/// Peers are sticky: Bonjour can briefly report a service as gone, or resolve it without its TXT
/// record or IPv4 address, while the peer is still perfectly reachable. So a peer is only dropped
/// after it has gone unconfirmed for `staleAfter`, and known services keep being re-resolved
/// directly even after the browser reports them removed.
///
/// Must be used from the main thread (NetService callbacks arrive on the main run loop).
public final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    public static let serviceType = "_omaclip._tcp."
    public static let protocolVersion = "2"

    /// How long a peer survives without a successful resolve before it is dropped.
    public static let staleAfter: TimeInterval = 120

    /// Called on the main thread whenever the set of usable peers changes.
    public var onChange: (([Peer]) -> Void)?

    private struct Known {
        var service: NetService
        var peer: Peer?
        var lastConfirmed: Date?
    }

    private let shortHash: String
    private var port = 0
    private var published: NetService?
    private var browser: NetServiceBrowser?
    private var known: [String: Known] = [:]
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
        self.port = port
        publish()
        startBrowsing()
        // omaclip picks a new random port on restart, so re-resolve periodically to notice moves.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        browser?.stop()
        browser = nil
        published?.stop()
        published = nil
        known.values.forEach { $0.service.stop() }
        known.removeAll()
    }

    /// Re-advertises and restarts browsing, keeping known peers. Call after sleep or a network change.
    public func refresh() {
        published?.stop()
        publish()
        browser?.stop()
        startBrowsing()
        resolveAll()
    }

    private func publish() {
        let service = NetService(domain: "local.", type: Self.serviceType, name: "\(Self.localHostName)-\(port)", port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "version": Data(Self.protocolVersion.utf8),
            "ph": Data(shortHash.utf8),
        ]))
        service.delegate = self
        service.publish()
        published = service
    }

    private func startBrowsing() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = browser
    }

    private var ticks = 0

    private func tick() {
        resolveAll()
        dropStalePeers()
        ticks += 1
        // With no usable peer, restart the browse every minute: omaclip's mDNS responder only
        // answers queries, so a fresh query is how a returning peer gets noticed.
        if ticks % 4 == 0, !known.values.contains(where: { $0.peer != nil }) {
            browser?.stop()
            startBrowsing()
        }
    }

    private func resolveAll() {
        known.values.forEach { $0.service.resolve(withTimeout: 5) }
    }

    private func dropStalePeers() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        var changed = false
        for (name, entry) in known where (entry.lastConfirmed ?? .distantPast) < cutoff {
            entry.service.stop()
            known[name] = nil
            if entry.peer != nil { changed = true }
        }
        if changed { notify() }
    }

    private func notify() {
        onChange?(known.values.compactMap(\.peer).sorted { $0.name < $1.name })
    }

    // MARK: NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != published?.name else { return }
        if known[service.name] == nil {
            // Count discovery as confirmation so the stale timer starts now.
            known[service.name] = Known(service: service, peer: nil, lastConfirmed: Date())
        }
        known[service.name]?.service.delegate = self
        known[service.name]?.service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Keep the peer: it stays usable until it also stops resolving for `staleAfter`.
        known[service.name]?.service.resolve(withTimeout: 5)
    }

    // MARK: NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender !== published, var entry = known[sender.name] else { return }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let version = txt["version"].map { String(decoding: $0, as: UTF8.self) }
        let hash = txt["ph"].map { String(decoding: $0, as: UTF8.self) }

        // A resolve can arrive without a TXT record; only a TXT that says otherwise disqualifies a peer.
        if (version != nil && version != Self.protocolVersion) || (hash != nil && hash != shortHash) {
            known[sender.name] = nil
            if entry.peer != nil { notify() }
            return
        }

        var addresses: [String] = []
        for address in sender.addresses ?? [] {
            let text = address.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                return IPv4.string(from: base.assumingMemoryBound(to: sockaddr.self))
            }
            if let text, !addresses.contains(text) { addresses.append(text) }
        }
        // Incomplete answer (no IPv4 yet, or a brand-new peer without its TXT): keep what we had.
        guard !addresses.isEmpty, sender.port > 0, entry.peer != nil || (version != nil && hash != nil) else { return }

        let ordered = IPv4.preferringLocalSubnets(addresses)
        let peer = Peer(name: sender.name, host: ordered[0], port: sender.port, addresses: ordered)
        let changed = entry.peer?.port != peer.port || Set(entry.peer?.addresses ?? []) != Set(peer.addresses)
        entry.peer = peer
        entry.lastConfirmed = Date()
        known[sender.name] = entry
        if changed { notify() }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
}
