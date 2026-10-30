import Darwin
import Foundation

public enum IPv4 {
    /// Parses dotted-quad text into four bytes.
    public static func bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address.s_addr) { Array($0) }
    }

    /// IPv4 addresses on interfaces that are up, plus 127.0.0.1, like omaclip's leaf certificate SANs.
    public static func localAddresses() -> [String] {
        var result = ["127.0.0.1"]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            if let text = string(from: address), !result.contains(text) {
                result.append(text)
            }
        }
        return result
    }

    /// Formats an IPv4 sockaddr as text, or returns nil for other families.
    public static func string(from address: UnsafePointer<sockaddr>) -> String? {
        guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var addr = pointer.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }
}

/// A remote omaclip instance to pull history from.
public struct Peer: Hashable, Sendable, Identifiable {
    public let name: String
    public let host: String
    public let port: Int

    public var id: String { name }

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }

    /// A short label: mDNS names look like `hostname-port`, so the port suffix is dropped.
    public var displayName: String {
        if name.contains(":") { return name }
        let base = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        let suffix = "-\(port)"
        if base.hasSuffix(suffix), base.count > suffix.count { return String(base.dropLast(suffix.count)) }
        return base
    }

    /// Parses omaclip's `--peers-list` syntax: `[name@]ip:port`, separated by `;`, `,` or newlines.
    public static func parseList(_ text: String) -> [Peer] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isNewline })
            .compactMap { parse(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    public static func parse(_ text: String) -> Peer? {
        guard !text.isEmpty else { return nil }
        var name = ""
        var address = text
        if let at = text.firstIndex(of: "@") {
            name = String(text[..<at])
            address = String(text[text.index(after: at)...])
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, IPv4.bytes(String(parts[0])) != nil,
              let port = Int(parts[1]), (1...65535).contains(port)
        else { return nil }
        if name.isEmpty { name = address }
        return Peer(name: name, host: String(parts[0]), port: port)
    }
}
