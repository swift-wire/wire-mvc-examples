import HTTPTypes
import Hummingbird
import HummingbirdTesting
// Conformance-only import: `extension Router: ServerTransport` is what makes `router.register` resolve.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import OpenAPIRuntime
import Testing

/// What Hummingbird does with a request whose **path matches but whose method does not**.
///
/// Pinned because WireMVC's own router now answers `405` with `Allow`, and Hummingbird does not — so the
/// same app answers differently depending on which runtime serves it. That divergence is accepted (on a
/// `ServerTransport` runtime WireMVC collates onto the host's router rather than owning it, the same
/// position as file serving), but it should be *asserted* rather than assumed: the framework's behaviour
/// is not ours to control, and this is the test that notices if it changes.
///
/// Hummingbird has the information to answer 405 and chooses not to. `RouterResponder.respond` resolves
/// the path and *then* looks up the method on the resulting responder chain — which knows its methods —
/// and routes both failures to the same not-found responder:
///
/// ```swift
/// guard let (responderChain, parameters) = trie.resolve(path),
///       let responder = responderChain.getResponder(for: request.method)
/// else { return try await self.notFoundResponder.respond(to: request, context: context) }
/// ```
@Suite("Method mismatch on the Hummingbird transport")
struct MethodMismatchTests {
    @Test func aWrongMethodOnARegisteredPathIs404NotAllowed() async throws {
        let router = Router()
        try router.register(
            { _, _, _ in (HTTPResponse(status: .ok), HTTPBody("ok")) },
            method: .get,
            path: "/only-get"
        )

        let app = Application(router: router)
        try await app.test(.live) { client in
            #expect(try await client.execute(uri: "/only-get", method: .get).status == .ok)

            // The divergence: WireMVC's native router would answer 405 with `Allow: GET` here.
            let mismatch = try await client.execute(uri: "/only-get", method: .delete)
            #expect(mismatch.status == .notFound)
            #expect(mismatch.headers[.allow] == nil)
        }
    }
}
