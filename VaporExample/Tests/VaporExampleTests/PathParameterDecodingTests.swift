// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import OpenAPIRuntime
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

/// Whether a `%`-escaped path parameter reaches a handler decoded, on this runtime.
///
/// WireMVC's own router decodes (`/users/a%20b` binds `a b`), but on a `ServerTransport` runtime the
/// parameter comes from the host framework, not from that router — so what arrives is Vapor's choice.
///
/// It decodes, in RoutingKit's `Parameters.set`:
///
/// ```swift
/// self.values[name] = value.map { $0.removingPercentEncoding ?? $0 }
/// ```
///
/// The `?? $0` is the same leniency WireMVC's own decoder adopts: a malformed escape leaves the value
/// exactly as it arrived rather than failing the request.
///
/// Pinned because it is not ours to control, and because it makes the three-way picture explicit —
/// Hummingbird is the one runtime that does *not* decode.
@Suite("Path-parameter decoding on the Vapor transport")
struct PathParameterDecodingTests {
    @Test func aPercentEscapedParameterArrivesDecoded() async throws {
        try await withApp { app in
            let transport = VaporTransport(routesBuilder: app)
            try transport.register(
                { _, _, metadata in
                    (
                        HTTPResponse(status: .ok),
                        HTTPBody(metadata.pathParameters["name"].map(String.init) ?? "")
                    )
                },
                method: .get,
                path: "/echo/{name}"
            )

            try await app.testing().test(.GET, "/echo/a%20b") { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "a b")
            }
        }
    }
}
