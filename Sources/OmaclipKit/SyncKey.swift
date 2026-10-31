import CArgon2
import Crypto
import Foundation
import SwiftASN1
import X509

public enum PassphraseError: LocalizedError, Equatable {
    case tooShort
    case tooLong
    case leadingWhitespace
    case trailingWhitespace
    case derivationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "The passphrase must be at least 8 characters."
        case .tooLong: return "The passphrase must be at most 128 characters."
        case .leadingWhitespace: return "The passphrase must not start with whitespace."
        case .trailingWhitespace: return "The passphrase must not end with whitespace."
        case .derivationFailed(let code): return "Argon2 key derivation failed (\(code))."
        }
    }
}

/// The 32-byte Argon2id key every omaclip peer derives from the shared passphrase.
public struct SyncKey: Sendable, Equatable {
    public let bytes: [UInt8]

    /// Sent as the `X-Omaclip-Pass` header on every request.
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Advertised in mDNS TXT records as `ph=` so peers can skip mismatched meshes.
    public var shortHash: String { String(hex.prefix(16)) }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Applies omaclip's passphrase rules (lengths are in UTF-8 bytes, like Go's `len`).
    public static func validate(_ passphrase: String) throws {
        let length = passphrase.utf8.count
        if length < 8 { throw PassphraseError.tooShort }
        if length > 128 { throw PassphraseError.tooLong }
        if let first = passphrase.unicodeScalars.first, first == " " || first == "\t" {
            throw PassphraseError.leadingWhitespace
        }
        if let last = passphrase.unicodeScalars.last, last == " " || last == "\t" {
            throw PassphraseError.trailingWhitespace
        }
    }

    /// Argon2id(passphrase, salt: passphrase reversed by code point, t=1, m=64 MiB, p=4, 32 bytes).
    /// This is slow on purpose (tens to hundreds of milliseconds), so call it off the main thread.
    public static func derive(from passphrase: String) throws -> SyncKey {
        try validate(passphrase)
        let password = Array(passphrase.utf8)
        var reversed = String.UnicodeScalarView()
        reversed.append(contentsOf: passphrase.unicodeScalars.reversed())
        let salt = Array(String(reversed).utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = argon2id_hash_raw(1, 64 * 1024, 4, password, password.count, salt, salt.count, &output, output.count)
        guard result == 0 else { throw PassphraseError.derivationFailed(result) }
        return SyncKey(bytes: output)
    }
}

public enum PeerCredentialsError: Error {
    case invalidScalar
}

/// TLS material shared by everyone who knows the passphrase.
///
/// omaclip derives a deterministic P-256 CA key from the sync key; each peer signs a
/// random leaf certificate with it, and peers trust only leaves signed by that CA.
public struct PeerCredentials: @unchecked Sendable {
    public let key: SyncKey
    public let caPrivateKey: P256.Signing.PrivateKey

    public var caPublicKey: P256.Signing.PublicKey { caPrivateKey.publicKey }

    public init(key: SyncKey) throws {
        self.key = key
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key.bytes),
            salt: Data("omaclip-ca-v1".utf8),
            info: Data(),
            outputByteCount: 32
        )
        let raw = seed.withUnsafeBytes { Array($0) }
        let scalar = PeerCredentials.reduceToScalar(raw)
        do {
            caPrivateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        } catch {
            throw PeerCredentialsError.invalidScalar
        }
    }

    /// Order of the P-256 group minus one, big-endian.
    private static let orderMinusOne: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x50,
    ]

    /// Computes `(x mod (n - 1)) + 1` for a 32-byte big-endian `x`, matching omaclip's Go code.
    /// Because 2^256 < 2(n - 1), the modulo is at most one subtraction.
    static func reduceToScalar(_ x: [UInt8]) -> [UInt8] {
        precondition(x.count == 32)
        var value = x
        if !value.lexicographicallyPrecedes(orderMinusOne) {
            var borrow = 0
            for i in stride(from: 31, through: 0, by: -1) {
                var digit = Int(value[i]) - Int(orderMinusOne[i]) - borrow
                borrow = digit < 0 ? 1 : 0
                if digit < 0 { digit += 256 }
                value[i] = UInt8(digit)
            }
        }
        var carry = 1
        for i in stride(from: 31, through: 0, by: -1) where carry > 0 {
            let sum = Int(value[i]) + carry
            value[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        return value
    }

    private static func name(_ commonName: String) throws -> DistinguishedName {
        // Go encodes printable common names as PrintableString; match it so issuer bytes line up.
        let attribute = try RelativeDistinguishedName.Attribute(type: .RDNAttributeType.commonName, printableString: commonName)
        return DistinguishedName([RelativeDistinguishedName(attribute)])
    }

    /// Creates a fresh server certificate signed by the shared CA, valid for the given IPv4 addresses.
    public func makeLeafCertificate(ipv4Addresses: [[UInt8]], now: Date = Date()) throws -> (certificateDER: [UInt8], privateKeyPEM: String) {
        let leafKey = P256.Signing.PrivateKey()
        var names: [GeneralName] = ipv4Addresses.map { .ipAddress(ASN1OctetString(contentBytes: ArraySlice($0))) }
        names.append(.dnsName("localhost"))
        let extensions = try Certificate.Extensions {
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames(names)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(365 * 24 * 3600),
            issuer: try Self.name("omaclip-ca"),
            subject: try Self.name("omaclip"),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(caPrivateKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return (serializer.serializedBytes, leafKey.pemRepresentation)
    }

    /// Accepts a peer's certificate only if the shared CA signed it, it is in date,
    /// and (when a host is given) it names that IPv4 address.
    public func verifyPeerCertificate(der: [UInt8], host: String?, now: Date = Date()) -> Bool {
        guard let certificate = try? Certificate(derEncoded: der) else { return false }
        guard Certificate.PublicKey(caPublicKey).isValidSignature(certificate.signature, for: certificate) else { return false }
        guard certificate.notValidBefore <= now.addingTimeInterval(300), now <= certificate.notValidAfter else { return false }
        guard let host, let wanted = IPv4.bytes(host) else { return true }
        guard let sans = try? certificate.extensions.subjectAlternativeNames else { return false }
        return sans.contains { name in
            if case .ipAddress(let octets) = name { return Array(octets.bytes) == wanted }
            return false
        }
    }
}
