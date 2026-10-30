import Crypto
import Foundation

/// The payload kinds omaclip protocol v2 understands.
public enum ContentKind: String, Sendable, Codable {
    case text
    case image
}

/// One item in a peer's shared history, without its payload.
///
/// `timestamp` is kept as the exact string the peer sent so the manifest checksum
/// can be recomputed byte-for-byte the way Go's `encoding/json` produced it.
public struct ManifestEntry: Sendable, Equatable, Codable {
    public var id: String
    public var checksum: String
    public var contentType: String
    public var imageMimeType: String?
    public var timestamp: String

    public init(id: String, checksum: String, contentType: String, imageMimeType: String? = nil, timestamp: String) {
        self.id = id
        self.checksum = checksum
        self.contentType = contentType
        self.imageMimeType = imageMimeType
        self.timestamp = timestamp
    }
}

/// A newest-first snapshot of a peer's shared history.
public struct Manifest: Sendable, Equatable, Codable {
    public var checksum: String
    public var entries: [ManifestEntry]?
}

struct ChecksumResponse: Codable {
    var checksum: String
}

/// Encodes values exactly the way Go's `encoding/json` does, which omaclip relies on
/// when it fingerprints a manifest.
public enum GoJSON {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Quotes and escapes a string with Go's default (HTML-safe) rules.
    public static func string(_ value: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(value.utf8.count + 2)
        out.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += Array("\\\"".utf8)
            case 0x5C: out += Array("\\\\".utf8)
            case 0x08: out += Array("\\b".utf8)
            case 0x0C: out += Array("\\f".utf8)
            case 0x0A: out += Array("\\n".utf8)
            case 0x0D: out += Array("\\r".utf8)
            case 0x09: out += Array("\\t".utf8)
            case 0x00..<0x20, 0x3C, 0x3E, 0x26, 0x2028, 0x2029:
                out += Array("\\u".utf8)
                let v = scalar.value
                out.append(hexDigits[Int((v >> 12) & 0xF)])
                out.append(hexDigits[Int((v >> 8) & 0xF)])
                out.append(hexDigits[Int((v >> 4) & 0xF)])
                out.append(hexDigits[Int(v & 0xF)])
            default:
                out += Array(String(scalar).utf8)
            }
        }
        out.append(UInt8(ascii: "\""))
        return String(decoding: out, as: UTF8.self)
    }

    /// Encodes manifest entries as Go would marshal `[]clipboard.ManifestEntry`.
    public static func entries(_ entries: [ManifestEntry]) -> String {
        let items = entries.map { entry -> String in
            var fields = [
                "\"id\":" + string(entry.id),
                "\"checksum\":" + string(entry.checksum),
                "\"contentType\":" + string(entry.contentType),
            ]
            if let mime = entry.imageMimeType, !mime.isEmpty {
                fields.append("\"imageMimeType\":" + string(mime))
            }
            fields.append("\"timestamp\":" + string(entry.timestamp))
            return "{" + fields.joined(separator: ",") + "}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// The fingerprint omaclip computes over a manifest's ordered metadata.
    public static func manifestChecksum(_ entries: [ManifestEntry]) -> String {
        sha256Hex(Data(GoJSON.entries(entries).utf8))
    }

    /// Encodes a whole manifest response body.
    public static func manifest(_ entries: [ManifestEntry]) -> (checksum: String, body: Data) {
        let checksum = manifestChecksum(entries)
        let body = "{\"checksum\":" + string(checksum) + ",\"entries\":" + GoJSON.entries(entries) + "}\n"
        return (checksum, Data(body.utf8))
    }
}

public func sha256Hex<D: DataProtocol>(_ data: D) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Wall-clock helpers that produce omaclip-style IDs and timestamps.
public enum WireClock {
    private static let lock = NSLock()
    private static var lastNanos: UInt64 = 0

    /// Returns a strictly increasing Unix time in nanoseconds.
    public static func nowNanos() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        var nanos = clock_gettime_nsec_np(CLOCK_REALTIME)
        if nanos <= lastNanos { nanos = lastNanos + 1 }
        lastNanos = nanos
        return nanos
    }

    /// Formats Unix nanoseconds the way Go marshals a UTC `time.Time` (RFC 3339 with trimmed nanoseconds).
    public static func timestamp(nanos: UInt64) -> String {
        var seconds = time_t(nanos / 1_000_000_000)
        let fraction = nanos % 1_000_000_000
        var parts = tm()
        gmtime_r(&seconds, &parts)
        var result = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
            parts.tm_hour, parts.tm_min, parts.tm_sec
        )
        if fraction > 0 {
            var digits = String(format: "%09llu", fraction)
            while digits.hasSuffix("0") { digits.removeLast() }
            result += "." + digits
        }
        return result + "Z"
    }

    /// Parses an RFC 3339 timestamp with or without fractional seconds.
    public static func date(from timestamp: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: timestamp) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: timestamp)
    }
}
