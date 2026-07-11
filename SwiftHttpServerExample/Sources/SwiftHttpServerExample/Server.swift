import BasicContainers
import Logging
import NIOHTTPServer

/// Build a plaintext HTTP/1.1 `NIOHTTPServer` (the concrete server from swift-http-server that
/// conforms to the proposal's `HTTPServer`). Plaintext keeps the example — and its test — free of
/// TLS/certificate setup; port `0` binds an ephemeral port the test can read back.
@available(anyAppleOS 26.0, *)
func makeHelloWorldServer(host: String = "127.0.0.1", port: Int) throws -> NIOHTTPServer {
    NIOHTTPServer(
        logger: Logger(label: "SwiftHttpServerExample"),
        configuration: try .init(
            bindTarget: .hostAndPort(host: host, port: port),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
    )
}

/// Serve every request a `200 OK` with a fixed body — the proposal's server handler shape
/// (`send`/`sendAndFinish` on the response sender). Runs until the surrounding task is cancelled.
@available(anyAppleOS 26.0, *)
func serveHelloWorld(on server: NIOHTTPServer) async throws {
    try await server.serve { _, _, _, responseSender in
        var body = UniqueArray<UInt8>(copying: "Well, hello!".utf8)
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}
