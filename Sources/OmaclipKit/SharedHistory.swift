import Foundation

/// One local clipboard item offered to peers.
public struct SharedItem: Sendable {
    public var entry: ManifestEntry
    public var payload: Data

    public init(entry: ManifestEntry, payload: Data) {
        self.entry = entry
        self.payload = payload
    }
}

/// Thread-safe snapshot of what the sync server hands out. The UI replaces it whenever
/// local history changes; server threads only read it.
public final class SharedHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var checksum: String
    private var manifestBody: Data
    private var items: [String: SharedItem] = [:]

    public init() {
        let empty = GoJSON.manifest([])
        checksum = empty.checksum
        manifestBody = empty.body
    }

    /// Replaces the shared history. Items must be newest first.
    public func replace(with newItems: [SharedItem]) {
        let encoded = GoJSON.manifest(newItems.map(\.entry))
        var byID: [String: SharedItem] = [:]
        for item in newItems { byID[item.entry.id] = item }
        lock.lock()
        checksum = encoded.checksum
        manifestBody = encoded.body
        items = byID
        lock.unlock()
    }

    public var currentChecksum: String {
        lock.lock()
        defer { lock.unlock() }
        return checksum
    }

    public var currentManifestBody: Data {
        lock.lock()
        defer { lock.unlock() }
        return manifestBody
    }

    public func item(id: String) -> SharedItem? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }
}
