import Foundation
import Security

public enum PeerError: LocalizedError {
    case badStatus(Int)
    case missingChecksum
    case unsupportedContentType(String)
    case contentChecksumMismatch(String)
    case unresolvedHost(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(401): return "Passphrase mismatch (HTTP 401)"
        case .badStatus(let code): return "HTTP \(code)"
        case .missingChecksum: return "Peer sent no checksum"
        case .unsupportedContentType(let type): return "Unsupported content type \(type)"
        case .contentChecksumMismatch(let id): return "Checksum mismatch for entry \(id)"
        case .unresolvedHost(let host): return "Can't resolve \(host)"
        }
    }
}

/// A clipboard item downloaded from a peer.
public struct RemoteEntry: Sendable, Equatable {
    public let id: String
    public let checksum: String
    public let kind: ContentKind
    public let imageMimeType: String?
    public let timestamp: String
    public let date: Date
    public let payload: Data

    public var text: String? { kind == .text ? String(decoding: payload, as: UTF8.self) : nil }
}

/// HTTPS client that trusts only certificates signed by the passphrase-derived CA.
final class PeerHTTPClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let credentials: PeerCredentials
    private var session: URLSession!

    init(credentials: PeerCredentials) {
        self.credentials = credentials
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func get(_ peer: Peer, _ path: String) async throws -> Data {
        guard let url = URL(string: "https://\(peer.host):\(peer.port)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(credentials.key.hex, forHTTPHeaderField: "X-Omaclip-Pass")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PeerError.badStatus(status) }
        return data
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = Array(SecCertificateCopyData(leaf) as Data)
        guard credentials.verifyPeerCertificate(der: der, host: challenge.protectionSpace.host) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Pulls peers' histories with omaclip's v2 flow: checksum, then manifest, then only payloads
/// not already held, each verified against its SHA-256. A peer's history is replaced only once
/// every payload has arrived.
public actor RemoteFetcher {
    private struct PeerState {
        var committedChecksum = ""
        var entries: [RemoteEntry] = []
    }

    private let client: PeerHTTPClient
    private var states: [String: PeerState] = [:]
    private var resolved: [String: (addresses: [String], expires: Date)] = [:]
    /// The address that last answered for each peer, tried first next time.
    private var preferred: [String: String] = [:]

    public init(credentials: PeerCredentials) {
        client = PeerHTTPClient(credentials: credentials)
    }

    public func shutdown() {
        client.invalidate()
    }

    public func forget(peerNamed name: String) {
        states[name] = nil
        preferred[name] = nil
    }

    /// Drops cached name resolutions and preferred addresses, e.g. after waking from sleep or
    /// joining another network. History already downloaded is kept.
    public func resetAddresses() {
        resolved.removeAll()
        preferred.removeAll()
    }

    /// IPv4 addresses to try for a peer: the last one that worked, then advertised or resolved
    /// addresses on this Mac's own subnets, then the rest. Resolutions are cached for 30 seconds.
    private func candidates(for peer: Peer) async throws -> [String] {
        var addresses = peer.addresses
        if addresses.isEmpty {
            if IPv4.bytes(peer.host) != nil {
                addresses = [peer.host]
            } else if let cached = resolved[peer.host], cached.expires > Date() {
                addresses = cached.addresses
            } else {
                addresses = await IPv4.resolveAll(peer.host)
                guard !addresses.isEmpty else {
                    resolved[peer.host] = nil
                    throw PeerError.unresolvedHost(peer.host)
                }
                resolved[peer.host] = (addresses, Date().addingTimeInterval(30))
            }
        }
        addresses = IPv4.preferringLocalSubnets(addresses)
        if let last = preferred[peer.name], let index = addresses.firstIndex(of: last) {
            addresses.insert(addresses.remove(at: index), at: 0)
        }
        return addresses
    }

    /// Fetches the checksum from the first candidate address that answers. Transport failures
    /// move on to the next address; HTTP errors (such as a passphrase mismatch) do not.
    private func connect(_ named: Peer) async throws -> (peer: Peer, checksum: String) {
        var lastError: Error = PeerError.unresolvedHost(named.host)
        for address in try await candidates(for: named) {
            // Connect by IP so the certificate's IP address SANs can be checked, as omaclip does.
            let peer = Peer(name: named.name, host: address, port: named.port)
            do {
                let data = try await client.get(peer, "/api/clipboard/checksum")
                let checksum = try JSONDecoder().decode(ChecksumResponse.self, from: data).checksum
                preferred[named.name] = address
                return (peer, checksum)
            } catch let error as URLError {
                lastError = error
                if preferred[named.name] == address { preferred[named.name] = nil }
                // A peer advertised by name may have moved; look it up again next time.
                resolved[named.host] = nil
            }
        }
        throw lastError
    }

    /// Returns the peer's newest-first history if it changed since the last call, or nil if not.
    public func fetch(_ named: Peer) async throws -> [RemoteEntry]? {
        let (peer, checksum) = try await connect(named)
        var state = states[peer.name] ?? PeerState()
        guard !checksum.isEmpty else { throw PeerError.missingChecksum }
        if checksum == state.committedChecksum { return nil }

        let manifestData = try await client.get(peer, "/api/clipboard")
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let entries = manifest.entries ?? []
        if manifest.checksum == state.committedChecksum { return nil }

        var known: [String: Data] = [:]
        for entry in state.entries { known[entry.kind.rawValue + ":" + entry.checksum] = entry.payload }

        var fresh: [RemoteEntry] = []
        for entry in entries {
            guard let kind = ContentKind(rawValue: entry.contentType) else {
                throw PeerError.unsupportedContentType(entry.contentType)
            }
            let cacheKey = entry.contentType + ":" + entry.checksum
            var payload = known[cacheKey]
            if payload == nil {
                let escapedID = entry.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.id
                let data = try await client.get(peer, "/api/clipboard/\(escapedID)/content")
                guard sha256Hex(data) == entry.checksum else { throw PeerError.contentChecksumMismatch(entry.id) }
                known[cacheKey] = data
                payload = data
            }
            fresh.append(RemoteEntry(
                id: entry.id,
                checksum: entry.checksum,
                kind: kind,
                imageMimeType: entry.imageMimeType,
                timestamp: entry.timestamp,
                date: WireClock.date(from: entry.timestamp) ?? Date(),
                payload: payload!
            ))
        }

        state.committedChecksum = manifest.checksum
        state.entries = fresh
        states[peer.name] = state
        return fresh
    }
}
