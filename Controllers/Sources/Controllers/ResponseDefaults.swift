// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes
public import Wire
public import WireMVC

// What the two "always" and "unless the route said otherwise" verbs are for, on one middleware.
//
// Middleware contributions apply *after* a route's own — the resolve order is controller constants, then the
// handler's returned fields, then middleware — so a middleware's `.set` beats whatever the route returned.
// That is right for a field the middleware is authoritative about, and wrong for a default. `.setIfAbsent`
// is how a middleware supplies a default it is willing to lose: it lands only if nothing already answered.

extension ControllerMiddleware {
    public static let responseDefaults = FactoryKey()
}

/// Controller-scope, so it demonstrates on every runtime: a global `@Middleware` needs a `@WireMVCBootstrap`
/// to fold into, which only the proposal-native example has.
@Factory(ControllerMiddleware.responseDefaults)
@MiddlewareFactory
public struct ResponseDefaults<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        return try await input.contributing { headers in
            // `.set` — the middleware is authoritative. Telling a browser not to sniff the content type is
            // not something an individual route should be able to switch off by accident.
            headers.add(.set(.init("x-content-type-options")!, "nosniff"))
            // `.setIfAbsent` — a default the middleware is happy to lose. Most of these routes should not
            // be cached, but a route that knows better says so in its own response and wins.
            headers.add(.setIfAbsent(.cacheControl, "no-store"))
        } then: { input in
            try await next(input)
        }
    }
}
