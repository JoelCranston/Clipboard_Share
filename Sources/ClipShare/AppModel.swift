import AppKit
import OmaclipKit

/// A clipboard item from this Mac or a peer, as shown in the history panel.
struct ClipItem: Identifiable, Equatable {
    enum Source: Hashable {
        case local
        case peer(String)
    }

    let entryID: String
    let source: Source
    let sourceName: String
    let kind: ContentKind
    let checksum: String
    let imageMimeType: String?
    let timestamp: String
    let date: Date
    let payload: Data

    var id: String {
        switch source {
        case .local: return "local/" + entryID
        case .peer(let name): return name + "/" + entryID
        }
    }

    var text: String? { kind == .text ? String(decoding: payload, as: UTF8.self) : nil }
    var isRemote: Bool { source != .local }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool { lhs.id == rhs.id && lhs.checksum == rhs.checksum }
}

/// Live status for one peer, shown in the menu and settings.
struct PeerStatus: Identifiable, Equatable {
    let peer: Peer
    var lastSync: Date?
    var lastError: String?
    var id: String { peer.name }
}

@MainActor
final class AppModel: ObservableObject {
    let preferences = Preferences()

    @Published private(set) var localItems: [ClipItem] = []
    @Published private(set) var remoteItems: [String: [ClipItem]] = [:]
    @Published private(set) var peerStatuses: [PeerStatus] = []
    @Published private(set) var networkStatus = "Not started"
    @Published private(set) var listeningPort: Int?
    @Published private(set) var keyFingerprint: String?

    private let monitor = PasteboardMonitor()
    private let shared = SharedHistory()
    private var server: SyncServer?
    private var discovery: BonjourDiscovery?
    private var fetcher: RemoteFetcher?
    private var credentials: PeerCredentials?
    private var pollTimer: Timer?
    private var addressTimer: Timer?
    private var certifiedAddresses: [String] = []
    private var inFlight: Set<String> = []
    private var generation = 0
    /// Newest entry per peer that auto-copy has already considered.
    private var autoCopySeen: [String: String] = [:]

    init() {
        monitor.onCapture = { [weak self] content in self?.record(content) }
    }

    func start() {
        monitor.start()
        if preferences.passphrase == nil, let imported = Preferences.omaclipConfigPassphrase(),
           (try? SyncKey.validate(imported)) != nil {
            preferences.setPassphrase(imported)
        }
        restartNetworking()
    }

    var hasPassphrase: Bool { preferences.passphrase != nil }

    /// All items, newest first.
    var allItems: [ClipItem] {
        (localItems + remoteItems.values.flatMap { $0 }).sorted { $0.date > $1.date }
    }

    var latestRemoteItem: ClipItem? {
        remoteItems.values.compactMap(\.first).max { $0.date < $1.date }
    }

    // MARK: Clipboard

    private func record(_ content: CapturedContent) {
        let nanos = WireClock.nowNanos()
        let item: ClipItem
        switch content {
        case .text(let text):
            let payload = Data(text.utf8)
            item = ClipItem(entryID: String(nanos), source: .local, sourceName: "This Mac", kind: .text,
                            checksum: sha256Hex(payload), imageMimeType: nil,
                            timestamp: WireClock.timestamp(nanos: nanos), date: Date(), payload: payload)
        case .png(let data):
            item = ClipItem(entryID: String(nanos), source: .local, sourceName: "This Mac", kind: .image,
                            checksum: sha256Hex(data), imageMimeType: "image/png",
                            timestamp: WireClock.timestamp(nanos: nanos), date: Date(), payload: data)
        }
        // Copying something that is already in history moves it to the top instead of duplicating it.
        localItems.removeAll { $0.kind == item.kind && $0.checksum == item.checksum }
        localItems.insert(item, at: 0)
        if localItems.count > max(preferences.maxHistory, 1) {
            localItems.removeLast(localItems.count - max(preferences.maxHistory, 1))
        }
        publishShared()
    }

    func publishShared() {
        let items = localItems.prefix(max(preferences.sharedCount, 0)).map { item in
            SharedItem(entry: ManifestEntry(id: item.entryID, checksum: item.checksum, contentType: item.kind.rawValue,
                                            imageMimeType: item.imageMimeType, timestamp: item.timestamp),
                       payload: item.payload)
        }
        shared.replace(with: Array(items))
    }

    func clearLocalHistory() {
        localItems.removeAll()
        publishShared()
    }

    /// Puts an item on the system clipboard without recording it as a new local copy.
    func copyToPasteboard(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let png = PasteboardMonitor.pngData(from: item.payload) {
                pasteboard.setData(png, forType: .png)
            }
            if let tiff = NSImage(data: item.payload)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        monitor.ignoreCurrentContents()
    }

    /// The "paste latest remote" shortcut: copy the newest peer entry and paste it into the front app.
    func pasteLatestRemote() {
        guard let item = latestRemoteItem else {
            NSSound.beep()
            return
        }
        copyToPasteboard(item)
        if Paster.isTrusted {
            Paster.pasteToFrontApp()
        } else {
            Paster.requestAccess()
        }
    }

    // MARK: Networking

    func restartNetworking() {
        stopNetworking()
        generation += 1
        let currentGeneration = generation
        guard let passphrase = preferences.passphrase else {
            networkStatus = "Set the omaclip passphrase in Settings to start syncing"
            return
        }
        networkStatus = "Deriving key…"
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> PeerCredentials in
                try PeerCredentials(key: SyncKey.derive(from: passphrase))
            }
            await MainActor.run {
                guard currentGeneration == self.generation else { return }
                switch result {
                case .success(let credentials): self.startNetworking(with: credentials)
                case .failure(let error): self.networkStatus = error.localizedDescription
                }
            }
        }
    }

    private func startNetworking(with credentials: PeerCredentials) {
        self.credentials = credentials
        keyFingerprint = credentials.key.shortHash
        do {
            let addresses = IPv4.localAddresses()
            let leaf = try credentials.makeLeafCertificate(ipv4Addresses: addresses.compactMap(IPv4.bytes))
            let server = try SyncServer(history: shared, key: credentials.key,
                                        certificateDER: leaf.certificateDER, privateKeyPEM: leaf.privateKeyPEM)
            try server.start(port: preferences.syncPort)
            self.server = server
            certifiedAddresses = addresses
            listeningPort = server.port
        } catch {
            networkStatus = "Could not start sync server: \(error.localizedDescription)"
            return
        }
        fetcher = RemoteFetcher(credentials: credentials)
        publishShared()

        let manual = Peer.parseList(preferences.manualPeers)
        if manual.isEmpty {
            let discovery = BonjourDiscovery(shortHash: credentials.key.shortHash)
            discovery.onChange = { [weak self] peers in
                MainActor.assumeIsolated { self?.setPeers(peers) }
            }
            discovery.start(port: server?.port ?? 0)
            self.discovery = discovery
            networkStatus = "Listening on port \(listeningPort ?? 0), looking for peers via Bonjour"
        } else {
            setPeers(manual)
            networkStatus = "Listening on port \(listeningPort ?? 0), using manual peers"
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPeers() }
        }
        addressTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCertificateIfAddressesChanged() }
        }
        pollPeers()
    }

    func stopNetworking() {
        pollTimer?.invalidate()
        pollTimer = nil
        addressTimer?.invalidate()
        addressTimer = nil
        discovery?.stop()
        discovery = nil
        server?.stop()
        server = nil
        if let fetcher { Task { await fetcher.shutdown() } }
        fetcher = nil
        credentials = nil
        listeningPort = nil
        peerStatuses = []
        remoteItems = [:]
        inFlight = []
        autoCopySeen = [:]
    }

    private func setPeers(_ peers: [Peer]) {
        let previous = Dictionary(uniqueKeysWithValues: peerStatuses.map { ($0.peer.name, $0) })
        peerStatuses = peers.map { peer in
            var status = previous[peer.name] ?? PeerStatus(peer: peer)
            if status.peer != peer { status = PeerStatus(peer: peer, lastSync: status.lastSync) }
            return status
        }
        let names = Set(peers.map(\.name))
        for name in remoteItems.keys where !names.contains(name) {
            remoteItems[name] = nil
            autoCopySeen[name] = nil
            if let fetcher { Task { await fetcher.forget(peerNamed: name) } }
        }
        pollPeers()
    }

    private func refreshCertificateIfAddressesChanged() {
        let addresses = IPv4.localAddresses()
        guard Set(addresses) != Set(certifiedAddresses), let credentials, let server else { return }
        do {
            let leaf = try credentials.makeLeafCertificate(ipv4Addresses: addresses.compactMap(IPv4.bytes))
            try server.updateCertificate(certificateDER: leaf.certificateDER, privateKeyPEM: leaf.privateKeyPEM)
            certifiedAddresses = addresses
        } catch {
            NSLog("ClipShare: certificate refresh failed: \(error)")
        }
    }

    private func pollPeers() {
        guard let fetcher else { return }
        for status in peerStatuses where !inFlight.contains(status.peer.name) {
            let peer = status.peer
            inFlight.insert(peer.name)
            let currentGeneration = generation
            Task {
                let outcome: Result<[RemoteEntry]?, Error>
                do { outcome = .success(try await fetcher.fetch(peer)) } catch { outcome = .failure(error) }
                guard currentGeneration == self.generation else { return }
                self.inFlight.remove(peer.name)
                self.apply(outcome, from: peer)
            }
        }
    }

    private func apply(_ outcome: Result<[RemoteEntry]?, Error>, from peer: Peer) {
        guard let index = peerStatuses.firstIndex(where: { $0.peer.name == peer.name }) else { return }
        switch outcome {
        case .failure(let error):
            peerStatuses[index].lastError = error.localizedDescription
        case .success(let entries):
            peerStatuses[index].lastError = nil
            peerStatuses[index].lastSync = Date()
            guard let entries else { return }
            let items = entries.map { entry in
                ClipItem(entryID: entry.id, source: .peer(peer.name), sourceName: peer.displayName, kind: entry.kind,
                         checksum: entry.checksum, imageMimeType: entry.imageMimeType, timestamp: entry.timestamp,
                         date: entry.date, payload: entry.payload)
            }
            remoteItems[peer.name] = items
            autoCopyIfNeeded(items.first, from: peer)
        }
    }

    private func autoCopyIfNeeded(_ newest: ClipItem?, from peer: Peer) {
        guard let newest else { return }
        let key = newest.kind.rawValue + ":" + newest.checksum
        let firstSync = autoCopySeen[peer.name] == nil
        defer { autoCopySeen[peer.name] = key }
        // Only react to copies made after we connected, and never bounce back what this Mac just shared.
        guard preferences.autoCopyRemote, !firstSync, autoCopySeen[peer.name] != key else { return }
        if localItems.first.map({ $0.kind == newest.kind && $0.checksum == newest.checksum }) == true { return }
        copyToPasteboard(newest)
    }
}
