// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing
import WireMVCTesting

@testable import SwiftHttpServerExample

/// The catch-all route, driven through the real router.
///
/// This suite exists on the proposal runtime only, because `AssetsController` does — a catch-all is served
/// by WireMVC's own router and refused by the `ServerTransport` bridge, so the controller lives in this
/// executable rather than in the shared `Controllers` library. There is deliberately no Hummingbird or
/// Vapor counterpart: the shape does not exist there.
///
/// `.inProcess` calls the finalized handler, so this is the real `FrozenTrieRouter` behind the real
/// global-middleware front layer.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct AssetRoutingTests {
    @Test func aCatchAllMatchesADeepPath() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets/img/logo/small.svg")
            #expect(response.status == 200)
            #expect(try response.json(Asset.self).path == "img/logo/small.svg")
        }
    }

    @Test func aCatchAllMatchesASingleSegmentToo() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets/app.css")
            #expect(try response.json(Asset.self).body == "body { margin: 0 }")
        }
    }

    /// Precedence, end to end: `/assets/manifest` is a literal under the same prefix and wins, even though
    /// the catch-all would also match it.
    @Test func aLiteralUnderTheSamePrefixBeatsTheCatchAll() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets/manifest")
            #expect(response.status == 200)
            #expect(try response.json([String].self).contains("js/app.js"))
        }
    }

    /// The remainder arrives undecoded, so a `%20` reaches the handler as an escape and its own decoding
    /// turns it into a space. Asserted through the served route because that is the whole chain: router,
    /// binding, and the handler's per-component decode.
    @Test func anEscapeInTheRemainderIsTheHandlersToDecode() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets/a%20b.txt")
            #expect(response.status == 200)
            #expect(try response.json(Asset.self).path == "a b.txt")
        }
    }

    /// The reason the remainder is *not* decoded by the router. `%2F` stays one component here, so the
    /// split sees a single segment and the traversal check runs on what the handler will actually use.
    /// Had the router decoded first, this would have arrived as two components and the check would have
    /// been looking at a path that no longer matched the one being resolved.
    @Test func anEncodedSeparatorDoesNotSmuggleASegment() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets/js%2Fapp.js")
            // One component named `js/app.js`, which is not a key in the tree — not the `js/app.js` entry,
            // which is two components.
            #expect(response.status == 404)
        }
    }

    @Test func traversalIsRejectedWithTheMappedStatus() async throws {
        try await withClient { client in
            // `@ErrorResponse(AssetError.self, .badRequest)` maps the handler's own error type.
            let literal = try await client.send("GET", "/assets/../secrets")
            #expect(literal.status == 400)
            let encoded = try await client.send("GET", "/assets/js/%2E%2E/secrets")
            #expect(encoded.status == 400)
        }
    }

    /// A catch-all matches one or more segments, so the bare prefix is not it.
    @Test func theBarePrefixDoesNotMatch() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/assets")
            #expect(response.status == 404)
        }
    }
}
