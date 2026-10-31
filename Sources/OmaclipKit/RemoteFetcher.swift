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
    private var resolved: [String: (address: String, expires: Date)] = [:]

    public init(credentials: PeerCredentials) {
        client = PeerHTTPClient(credentials: credentials)
    }

    public func shutdown() {
        client.invalidate()
    }

    public func forget(peerNamed name: String) {
        states[name] = nil
    }

    /// Resolves host names, caching each answer for 30 seconds.
    private func address(for host: String) async throws -> String {
        if IPv4.bytes(host) != nil { return host }
        if let cached = resolved[host], cached.expires > Date() { return cached.address }
        guard let address = await IPv4.resolve(host) else {
            resolved[host] = nil
            throw PeerError.unresolvedHost(host)
        }
        resolved[host] = (address, Date().addingTimeInterval(30))
        return address
    }

    /// Returns the peer's newest-first history if it changed since the last call, or nil if not.
    public func fetch(_ named: Peer) async throws -> [RemoteEntry]? {
        // Connect by IP so the certificate's IP address SANs can be checked, as omaclip does.
        let peer = Peer(name: named.name, host: try await address(for: named.host), port: named.port)
        var state = states[peer.name] ?? PeerState()
        let checksumData = try await client.get(peer, "/api/clipboard/checksum")
        let checksum = try JSONDecoder().decode(ChecksumResponse.self, from: checksumData).checksum
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
