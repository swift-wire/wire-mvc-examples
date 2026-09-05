// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import HTTPTypes
import Testing
import WireMVCTesting

/// The proposal-native half of the routing-miss contrast: this runtime serves through WireMVC's own
/// `FrozenTrieRouter`, so a path that exists under a different method is a **405 with `Allow`**, not a 404.
///
/// The counterpart tests live in `HummingbirdExample` and `VaporExample`, where the same request is a 404 —
/// those runtimes collate onto the host framework's router, and neither Hummingbird nor Vapor answers 405.
/// Together the three pin a deliberate divergence: the native path is stricter than the bridged ones, and
/// that is a property of whose router is in front, not of the app.
///
/// `.inProcess` renders the request and calls the *finalized* handler, so this is the real trie router
/// behind the real global-middleware front layer — not a stand-in.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct MethodMismatchTests {
    /// `/todos` is registered for `GET` and `POST`; `DELETE` lives on `/todos/{id}`, a different node.
    ///
    /// The `Allow` value also pins the two things the router promises about it: the methods are those of
    /// the node actually reached — not `{id}`'s — and they are sorted, so the header does not depend on
    /// the order the routes happened to be registered in.
    @Test func aWrongMethodOnARegisteredPathIs405WithAllow() async throws {
        try await withClient { client in
            let mismatch = try await client.send("DELETE", "/todos")
            #expect(mismatch.status == 405)
            #expect(mismatch.head?.headerFields[.allow] == "GET, POST")
        }
    }

    /// The contrast, in the same runtime: no path at all is still a 404, and carries no `Allow` — there is
    /// no resource whose methods could be listed.
    @Test func anUnknownPathIsStill404() async throws {
        try await withClient { client in
            let missing = try await client.send("DELETE", "/no/such/route")
            #expect(missing.status == 404)
            #expect(missing.head?.headerFields[.allow] == nil)
        }
    }

    /// An *interior* node is a 404 too, which is the distinction most easily got wrong: `/todos/{id}`
    /// registers routes at the parameter node, so `/todos/9/nested` walks off the end of the trie — and a
    /// path that names no resource cannot be "the wrong method on a resource".
    @Test func anInteriorMissIsStill404() async throws {
        try await withClient { client in
            let missing = try await client.send("GET", "/todos/9/nested")
            #expect(missing.status == 404)
            #expect(missing.head?.headerFields[.allow] == nil)
        }
    }
}
