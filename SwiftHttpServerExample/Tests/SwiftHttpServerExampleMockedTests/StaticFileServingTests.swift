// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Testing
import WireMVCTesting

@testable import SwiftHttpServerExample

/// **The middleware-answers-over-the-fallback seam**, driven end to end.
///
/// Every other middleware in these repos either observes (`LogRequests`, `AuditGate`), gates a route it
/// sits in front of (`RequireAPIKey`), or transforms the sender (`MultiPartSender`). This is the one that
/// answers a request the router would otherwise have to — so the assertions below are mostly about *which
/// layer produced the response*, which is why the app's `@NotFound` fallback carries a `NoRoute` body at
/// all. Without it every miss is an indistinguishable bare `404`.
///
/// Suite on the proposal runtime only, and not for want of effort: the Hummingbird and Vapor executables
/// mount through `WireMVCServerTransport` onto the host's own `Application`, so there is no generated
/// `@main`, no global tier, and nothing to fold a composition-root `@Middleware` into. The host's own file
/// middleware occupies this position there.
///
/// `.inProcess` calls the finalized handler, so the front layer, the real `FrozenTrieRouter` and the
/// registered fallback are all the production ones.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct StaticFileServingTests {
    /// The middleware answers, from outside the router. Nothing is registered at this path — the trie has
    /// never heard of `/static` — so a `200` here can only have come from the front layer.
    @Test func aFileUnderThePrefixIsAnsweredWithoutARoute() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/static/site.css")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.contentType] == "text/css")
            #expect(response.bodyText == "body { font: 1rem system-ui }")
        }
    }

    /// A remainder spanning separators, with no catch-all anywhere: the middleware never consults the
    /// router, so the shape `AssetsController` needs `@Get("/{path*}")` for is free here. That is the
    /// difference between the two examples, not a redundancy between them.
    @Test func aDeepRemainderNeedsNoCatchAll() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/static/js/app.js")
            #expect(response.status == 200)
            #expect(response.bodyText == "console.log('static')")
        }
    }

    /// **The seam, from the other side.** A path under the prefix the store does not hold is *declined* —
    /// the box stays `pending`, the router runs, matches nothing, and the app's `@NotFound` answers. The
    /// `NoRoute` body is how that is told apart from the middleware having answered `404` itself.
    @Test func aMissUnderThePrefixFallsThroughToTheFallback() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/static/nope.css")
            #expect(response.status == 404)
            #expect(try response.json(NoRoute.self) == NoRoute(unmatched: "/static/nope.css", method: "GET"))
        }
    }

    /// The third `404` this app can produce, for contrast: a route matched and *its handler* said no. It
    /// carries the controller's own error shape, not the fallback's — the fallback never ran.
    @Test func aRoutesOwnNotFoundIsNotTheFallbacks() async throws {
        try await withClient { client in
            // One component literally named `js/app.js`, which is not in `AssetsController`'s tree.
            let response = try await client.send("GET", "/assets/js%2Fapp.js")
            #expect(response.status == 404)
            #expect(throws: (any Error).self) { try response.json(NoRoute.self) }
        }
    }

    /// The middleware is prefix-scoped, and this is what that buys. It runs *before* the router on every
    /// request, so an unscoped file middleware would shadow every route in the app; `/assets/app.css` is a
    /// real route under a different prefix and is untouched.
    @Test func aPathOutsideThePrefixIsNeverConsidered() async throws {
        try await withClient { client in
            let routed = try await client.send("GET", "/assets/app.css")
            #expect(routed.status == 200, "the catch-all route still owns /assets")
            // A prefix match, not a component match: `/staticky` is not under `/static/`.
            let nearMiss = try await client.send("GET", "/staticky/site.css")
            #expect(nearMiss.status == 404)
            #expect(try nearMiss.json(NoRoute.self).unmatched == "/staticky/site.css")
        }
    }

    /// A write to a file path is not a file request, and the answer is `404` rather than `405`: nothing is
    /// registered at that path, so there is no `Allow` set to state. Compare `MethodMismatchTests`, where
    /// a wrong method on a path the trie *does* hold is a `405` that names the methods.
    @Test func aWriteMethodFallsThroughRatherThanBeingAnswered() async throws {
        try await withClient { client in
            let response = try await client.send("POST", "/static/site.css")
            #expect(response.status == 404)
            #expect(response.head?.headerFields[.allow] == nil)
            #expect(try response.json(NoRoute.self).method == "POST")
        }
    }

    /// `HEAD` gets the head its `GET` would have — including the length, which is why the middleware
    /// states `Content-Length` explicitly rather than letting the outcome derive it from bytes it is not
    /// sending.
    @Test func headCarriesTheHeadWithoutTheBody() async throws {
        try await withClient { client in
            let response = try await client.send("HEAD", "/static/site.css")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.contentType] == "text/css")
            #expect(response.head?.headerFields[.contentLength] == "29")
            #expect(response.body.isEmpty)
        }
    }

    /// **Why the middleware uses `respondingWith` and not raw `responding`.**
    ///
    /// CORS is the outer global middleware, and by the time the file middleware decides to answer it has
    /// already *contributed* `Access-Control-Allow-Origin` to the response-header registry rather than
    /// written it. Only something that produces a `WireMVCOutcome` drains that registry: raw `responding`
    /// hands the sender over and WireMVC never sees an outcome, so this field — on the responses a browser
    /// fetches most — would be silently dropped.
    @Test func corsFieldsSurviveAFileAnsweredHere() async throws {
        try await withClient { client in
            let response = try await client.send(
                "GET",
                "/static/site.css",
                headers: ["Origin": "https://allowed.example"]
            )
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.accessControlAllowOrigin] == "https://allowed.example")
            #expect(response.head?.headerFields[.contentType] == "text/css", "the answer's own field wins")
        }
    }

    /// A traversal is **declined**, not reported: it reaches the ordinary fallback, so a path that resolves
    /// outside the tree is indistinguishable from one that resolves to nothing. `AssetsController` answers
    /// the same question with a mapped `400`, which is the other defensible answer — the difference is that
    /// a route has an `@ErrorResponse` tier to say it with and a global middleware does not.
    @Test func traversalIsDeclinedRatherThanReported() async throws {
        try await withClient { client in
            let literal = try await client.send("GET", "/static/../secrets")
            #expect(literal.status == 404)
            #expect(try literal.json(NoRoute.self).unmatched == "/static/../secrets")
            // Decoded per component *before* the check, so an escaped `..` is caught too.
            let encoded = try await client.send("GET", "/static/js/%2E%2E/secrets")
            #expect(encoded.status == 404)
        }
    }

    /// The bare prefix names no file. `/static/` splits to no components at all, and `/static` is not
    /// under the prefix in the first place — both reach the fallback.
    @Test func theBarePrefixIsNotAFile() async throws {
        try await withClient { client in
            let trailing = try await client.send("GET", "/static/")
            #expect(trailing.status == 404)
            let bare = try await client.send("GET", "/static")
            #expect(bare.status == 404)
        }
    }

    /// A query is part of the request target, not part of the path — the middleware strips it exactly as
    /// `RouteTrie.resolve` does, so a cache-busted asset URL still resolves.
    @Test func aQueryStringDoesNotDefeatTheLookup() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/static/robots.txt?v=2")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.contentType] == "text/plain")
        }
    }
}
