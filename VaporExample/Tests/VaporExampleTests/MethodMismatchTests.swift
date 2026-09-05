// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import OpenAPIRuntime
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

/// What Vapor does with a request whose **path matches but whose method does not**.
///
/// Pinned for the same reason as the Hummingbird counterpart: WireMVC's own router now answers `405` with
/// `Allow`, and Vapor does not, so the same app answers differently depending on which runtime serves it.
/// Accepted — on a `ServerTransport` runtime WireMVC collates onto the host's router rather than owning it
/// — but asserted rather than assumed.
///
/// Vapor differs from Hummingbird in *why*. Its router cannot distinguish the two cases at all: the method
/// is the first path component of the lookup, so a wrong method is an ordinary trie miss.
///
/// ```swift
/// return self.router.route(path: [method.rawValue] + pathComponents, parameters: &request.parameters)
/// ```
///
/// A 405 there would need a second lookup, which is why this is a design property rather than an oversight.
@Suite("Method mismatch on the Vapor transport")
struct MethodMismatchTests {
    @Test func aWrongMethodOnARegisteredPathIs404NotAllowed() async throws {
        try await withApp { app in
            let transport = VaporTransport(routesBuilder: app)
            try transport.register(
                { _, _, _ in (HTTPResponse(status: .ok), HTTPBody("ok")) },
                method: .get,
                path: "/only-get"
            )

            try await app.testing().test(.GET, "/only-get") { response in
                #expect(response.status == .ok)
            }

            // The divergence: WireMVC's native router would answer 405 with `Allow: GET` here.
            try await app.testing().test(.DELETE, "/only-get") { response in
                #expect(response.status == .notFound)
                #expect(response.headers.first(name: "Allow") == nil)
            }
        }
    }
}
