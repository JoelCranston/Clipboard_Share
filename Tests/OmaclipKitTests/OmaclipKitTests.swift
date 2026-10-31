import Crypto
import Foundation
@testable import OmaclipKit
import XCTest

/// Vectors were produced with Go using the same code paths as omaclip v0.10
/// (golang.org/x/crypto argon2/hkdf, encoding/json).
final class OmaclipKitTests: XCTestCase {
    private func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    func testArgon2KeyMatchesOmaclip() throws {
        let key = try SyncKey.derive(from: "correct horse battery")
        XCTAssertEqual(key.hex, "4dbd6c61bd63d4c3a007e1d5423dbc6bf1bbe77463b6623b9829f516cf21cb1d")
        XCTAssertEqual(key.shortHash, "4dbd6c61bd63d4c3")
    }

    func testCAKeyMatchesOmaclip() throws {
        let key = SyncKey(bytes: bytes("4dbd6c61bd63d4c3a007e1d5423dbc6bf1bbe77463b6623b9829f516cf21cb1d"))
        let credentials = try PeerCredentials(key: key)
        XCTAssertEqual(hex(credentials.caPrivateKey.rawRepresentation), "5deddde25ead041d2a1c7e90e6cd3c6b3c5d73b7b82d98e0121c7eb503b7c63b")
        XCTAssertEqual(
            hex(credentials.caPublicKey.x963Representation),
            "04d042cbae38fa8476fb1e155d9086da9a3d47cb50f6faab55a03c0de0d26157a459ef49715bb49704f9b5768fe5155dcc97db3c41d62abaf5421785c531cb6861"
        )
    }

    func testScalarReductionWraps() {
        let input = bytes("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632555")
        XCTAssertEqual(hex(PeerCredentials.reduceToScalar(input)), "0000000000000000000000000000000000000000000000000000000000000006")
    }

    func testPassphraseValidation() {
        XCTAssertThrowsError(try SyncKey.validate("short"))
        XCTAssertThrowsError(try SyncKey.validate(" leading space"))
        XCTAssertThrowsError(try SyncKey.validate("trailing tab\t"))
        XCTAssertNoThrow(try SyncKey.validate("correct horse battery"))
    }

    func testManifestJSONMatchesGo() {
        let entries = [
            ManifestEntry(id: "1793400907123456789", checksum: "aa", contentType: "text", timestamp: "2026-10-30T22:55:07.123456789Z"),
            ManifestEntry(id: "1793400901000000000", checksum: "bb", contentType: "image", imageMimeType: "image/png", timestamp: "2026-10-30T22:55:01Z"),
            ManifestEntry(id: "3", checksum: "cc", contentType: "text", timestamp: "2026-10-30T15:55:01.5-07:00"),
        ]
        XCTAssertEqual(
            GoJSON.entries(entries),
            #"[{"id":"1793400907123456789","checksum":"aa","contentType":"text","timestamp":"2026-10-30T22:55:07.123456789Z"},{"id":"1793400901000000000","checksum":"bb","contentType":"image","imageMimeType":"image/png","timestamp":"2026-10-30T22:55:01Z"},{"id":"3","checksum":"cc","contentType":"text","timestamp":"2026-10-30T15:55:01.5-07:00"}]"#
        )
        XCTAssertEqual(GoJSON.manifestChecksum(entries), "7a738558917f921e27457303646b83b80c8a6075ab87f34a47a4c81e818c167a")
        XCTAssertEqual(GoJSON.manifestChecksum([]), "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
    }

    func testGoStringEscaping() {
        XCTAssertEqual(GoJSON.string("a\"b\\c\n<>&\u{1}\u{2028}é"), #""a\"b\\c\n\u003c\u003e\u0026\u0001\u2028é""#)
    }

    func testTimestampFormatting() {
        XCTAssertEqual(WireClock.timestamp(nanos: 1_793_400_907_123_456_789), "2026-10-30T22:55:07.123456789Z")
        XCTAssertEqual(WireClock.timestamp(nanos: 1_793_400_901_000_000_000), "2026-10-30T22:55:01Z")
        XCTAssertEqual(WireClock.timestamp(nanos: 1_793_400_901_500_000_000), "2026-10-30T22:55:01.5Z")
        XCTAssertNotNil(WireClock.date(from: "2026-10-30T15:55:01.5-07:00"))
        XCTAssertNotNil(WireClock.date(from: "2026-10-30T22:55:01Z"))
    }

    func testLeafCertificateVerifiesOnlyWithSameCA() throws {
        let credentials = try PeerCredentials(key: SyncKey(bytes: Array(repeating: 7, count: 32)))
        let other = try PeerCredentials(key: SyncKey(bytes: Array(repeating: 8, count: 32)))
        let leaf = try credentials.makeLeafCertificate(ipv4Addresses: [[127, 0, 0, 1], [192, 168, 1, 20]])
        XCTAssertTrue(credentials.verifyPeerCertificate(der: leaf.certificateDER, host: "192.168.1.20"))
        XCTAssertFalse(credentials.verifyPeerCertificate(der: leaf.certificateDER, host: "10.0.0.1"))
        XCTAssertFalse(other.verifyPeerCertificate(der: leaf.certificateDER, host: "192.168.1.20"))
    }

    func testPeerListParsing() {
        let peers = Peer.parseList("omarchy@100.101.102.103:36742; 192.168.1.5:4000\nlaptop@omarchy.local:36742, box.tailnet.ts.net:1;bad@:1;x@host:99999;y@has space:5")
        XCTAssertEqual(peers, [
            Peer(name: "omarchy", host: "100.101.102.103", port: 36742),
            Peer(name: "192.168.1.5:4000", host: "192.168.1.5", port: 4000),
            Peer(name: "laptop", host: "omarchy.local", port: 36742),
            Peer(name: "box.tailnet.ts.net:1", host: "box.tailnet.ts.net", port: 1),
        ])
        XCTAssertEqual(Peer(name: "omarchy-41234", host: "1.2.3.4", port: 41234).displayName, "omarchy")
    }

    func testHostResolution() async {
        let literal = await IPv4.resolve("10.1.2.3")
        XCTAssertEqual(literal, "10.1.2.3")
        let localhost = await IPv4.resolve("localhost")
        XCTAssertEqual(localhost, "127.0.0.1")
    }

    /// Runs the real HTTPS server and pulls from it with the real client, as an omaclip peer would.
    func testServerAndFetcherRoundTrip() async throws {
        let credentials = try PeerCredentials(key: SyncKey(bytes: Array(repeating: 3, count: 32)))
        let leaf = try credentials.makeLeafCertificate(ipv4Addresses: [[127, 0, 0, 1]])
        let history = SharedHistory()
        let text = Data("hello from the mac".utf8)
        history.replace(with: [SharedItem(
            entry: ManifestEntry(id: "1", checksum: sha256Hex(text), contentType: "text", timestamp: "2026-10-30T22:55:01Z"),
            payload: text
        )])
        let server = try SyncServer(history: history, key: credentials.key, certificateDER: leaf.certificateDER, privateKeyPEM: leaf.privateKeyPEM)
        try server.start(port: 0)
        defer { server.stop() }

        let fetcher = RemoteFetcher(credentials: credentials)
        // A host name exercises resolution; the fetcher connects by IP so the IP SAN is checked.
        let peer = Peer(name: "self", host: "localhost", port: server.port)
        let entries = try await fetcher.fetch(peer)
        XCTAssertEqual(entries?.first?.text, "hello from the mac")
        let unchanged = try await fetcher.fetch(peer)
        XCTAssertNil(unchanged)

        let wrong = RemoteFetcher(credentials: try PeerCredentials(key: SyncKey(bytes: Array(repeating: 4, count: 32))))
        do {
            _ = try await wrong.fetch(peer)
            XCTFail("a different passphrase must not be able to read history")
        } catch {}
    }
}
