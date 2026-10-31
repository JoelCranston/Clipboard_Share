import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The HTTPS endpoint omaclip peers poll to read this Mac's clipboard history.
///
/// Routes (all require `X-Omaclip-Pass: <sync key hex>`):
/// - `GET /api/clipboard/checksum`
/// - `GET /api/clipboard`
/// - `GET /api/clipboard/{id}/content`
public final class SyncServer: @unchecked Sendable {
    private let history: SharedHistory
    private let authHex: String
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var tlsContext: NIOSSLContext
    private var channel: Channel?

    public private(set) var port: Int = 0

    public init(history: SharedHistory, key: SyncKey, certificateDER: [UInt8], privateKeyPEM: String) throws {
        self.history = history
        self.authHex = key.hex
        self.tlsContext = try Self.makeContext(certificateDER: certificateDER, privateKeyPEM: privateKeyPEM)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    private static func makeContext(certificateDER: [UInt8], privateKeyPEM: String) throws -> NIOSSLContext {
        let certificate = try NIOSSLCertificate(bytes: certificateDER, format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        return try NIOSSLContext(configuration: configuration)
    }

    /// Swaps in a new certificate (e.g. after the Mac's IP addresses change). Existing connections keep the old one.
    public func updateCertificate(certificateDER: [UInt8], privateKeyPEM: String) throws {
        let context = try Self.makeContext(certificateDER: certificateDER, privateKeyPEM: privateKeyPEM)
        lock.lock()
        tlsContext = context
        lock.unlock()
    }

    private var currentContext: NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        return tlsContext
    }

    /// Binds on all IPv4 interfaces. Port 0 picks a free port; read `port` afterwards.
    public func start(port requestedPort: Int) throws {
        let history = self.history
        let authHex = self.authHex
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                let tls = NIOSSLServerHandler(context: self.currentContext)
                return channel.pipeline.addHandler(tls).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                }.flatMap {
                    channel.pipeline.addHandler(SyncHTTPHandler(history: history, authHex: authHex))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "0.0.0.0", port: requestedPort).wait()
        self.channel = channel
        port = channel.localAddress?.port ?? requestedPort
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
    }
}

private final class SyncHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let history: SharedHistory
    private let authHex: [UInt8]
    private var requestHead: HTTPRequestHead?

    init(history: SharedHistory, authHex: String) {
        self.history = history
        self.authHex = Array(authHex.utf8)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            respond(context: context, head: head)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func authorized(_ head: HTTPRequestHead) -> Bool {
        let given = Array((head.headers.first(name: "X-Omaclip-Pass") ?? "").utf8)
        guard given.count == authHex.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, authHex) { difference |= a ^ b }
        return difference == 0
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard head.method == .GET else {
            return send(context: context, head: head, status: .methodNotAllowed, contentType: "text/plain; charset=utf-8", body: Data("method not allowed\n".utf8))
        }
        guard authorized(head) else {
            return send(context: context, head: head, status: .unauthorized, contentType: "text/plain; charset=utf-8", body: Data("unauthorized\n".utf8))
        }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        let json = "application/json"

        if path == "/api/clipboard/checksum" {
            let body = "{\"checksum\":" + GoJSON.string(history.currentChecksum) + "}\n"
            return send(context: context, head: head, status: .ok, contentType: json, body: Data(body.utf8))
        }
        if path == "/api/clipboard" {
            return send(context: context, head: head, status: .ok, contentType: json, body: history.currentManifestBody)
        }
        let prefix = "/api/clipboard/", suffix = "/content"
        if path.hasPrefix(prefix), path.hasSuffix(suffix), path.count > prefix.count + suffix.count {
            let rawID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            let id = rawID.removingPercentEncoding ?? rawID
            if let item = history.item(id: id) {
                let contentType = item.entry.contentType == ContentKind.text.rawValue
                    ? "text/plain; charset=utf-8"
                    : (item.entry.imageMimeType ?? "application/octet-stream")
                return send(context: context, head: head, status: .ok, contentType: contentType, body: item.payload)
            }
        }
        send(context: context, head: head, status: .notFound, contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8))
    }

    private func send(context: ChannelHandlerContext, head: HTTPRequestHead, status: HTTPResponseStatus, contentType: String, body: Data) {
        let keepAlive = head.isKeepAlive
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        if !keepAlive { headers.add(name: "Connection", value: "close") }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { context.close(promise: nil) }
        }
    }
}
