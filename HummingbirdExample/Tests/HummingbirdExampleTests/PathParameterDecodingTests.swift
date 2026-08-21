import HTTPTypes
import Hummingbird
import HummingbirdTesting
// Conformance-only import: `extension Router: ServerTransport` is what makes `router.register` resolve.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import OpenAPIRuntime
import Testing

/// Whether a `%`-escaped path parameter reaches a handler decoded, on this runtime.
///
/// WireMVC's own router decodes (`/users/a%20b` binds `a b`). On a `ServerTransport` runtime the parameter
/// does not come from that router at all — the host framework matches the path and hands the values over as
/// `ServerRequestMetadata.pathParameters` — so what arrives is the framework's choice.
///
/// Pinned for the same reason as the 405 divergence: not ours to control, so it should be measured rather
/// than assumed, and this is the test that notices if Hummingbird changes its mind.
@Suite("Path-parameter decoding on the Hummingbird transport")
struct PathParameterDecodingTests {
    @Test func aPercentEscapedParameterArrivesUndecoded() async throws {
        let router = Router()
        try router.register(
            { _, _, metadata in
                (HTTPResponse(status: .ok), HTTPBody(metadata.pathParameters["name"].map(String.init) ?? ""))
            },
            method: .get,
            path: "/echo/{name}"
        )

        let app = Application(router: router)
        try await app.test(.live) { client in
            let response = try await client.execute(uri: "/echo/a%20b", method: .get)
            #expect(response.status == .ok)
            // Hummingbird does not percent-decode: nothing in its router calls `removingPercentEncoding`,
            // so the handler is handed the escape verbatim. WireMVC's native router would bind `a b` here,
            // and Vapor's RoutingKit decodes too — Hummingbird is the odd one of the three.
            #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "a%20b")
        }
    }
}
