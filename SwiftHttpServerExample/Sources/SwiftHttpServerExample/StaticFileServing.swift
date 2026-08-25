// Full Foundation, not the `canImport(FoundationEssentials)` guard used elsewhere in this package, for
// the same reason `AssetsController` states: `removingPercentEncoding` is not in FoundationEssentials,
// so the guard resolves to the lighter module on Linux and the API is absent — compiling on macOS and
// failing in CI.
import Foundation
package import HTTPAPIs
package import HTTPTypes
package import Wire
package import WireMVC

// **A global `@Middleware` that answers the request itself, over the `@NotFound` fallback** — the
// `s3-file-provider` shape, and the one seam in the middleware model that nothing else in this repo
// exercises end to end.
//
// Two framework facts meet here, and neither is visible from a route:
//
// 1. **The front layer wraps every request.** The composition root's `@Middleware` factories are folded
//    around the *finalized router* once, in the generated `@main` — so the chain runs for matched routes
//    and for the `@NotFound` fallback alike. A middleware therefore sees requests no route will ever
//    match, which is what makes answering one from here possible at all.
// 2. **`.responded` is how a middleware answers.** There is no short-circuit: every middleware still
//    calls `next`, and a middleware that wants to respond writes through the sender and moves the box to
//    `.responded`. The terminal then skips the handler — and here the "handler" is the whole router, so
//    skipping it skips the fallback too.
//
// **Native-path only**, and not by preference. On the `ServerTransport` runtimes WireMVC collates onto
// the host's router rather than owning it: there is no generated `@main`, so there is no global tier to
// fold into, and the host's own file middleware does this job. That is the honest story for a framework
// that collates rather than owns — the same position file serving sits in for the 404 itself.
//
// **What this is not.** `AssetsController` serves a tree through a catch-all *route*, which is the shape
// people expect from a file-serving example. It is a different seam: a route runs *inside* the router,
// after a match, and cannot answer for a path the router does not know. This middleware runs outside it.

/// One served file: bytes and the type they are.
package struct StaticFile: Sendable, Equatable {
    package let bytes: [UInt8]
    package let contentType: String

    package init(bytes: [UInt8], contentType: String) {
        self.bytes = bytes
        self.contentType = contentType
    }
}

/// The store the middleware serves out of — an ordinary `@Singleton`, injected like any other dependency.
///
/// **`async`, and deliberately so.** The tree is in memory, so nothing here suspends; the lookup is
/// declared `async` because the example it stands in for is `s3-file-provider`, where it is a network
/// call. Making that the shape of the *seam* is the part worth pinning: a global middleware may await
/// before deciding whether to answer, and the box survives the suspension because it is held across it
/// rather than escaping.
@Singleton
package struct StaticFileStore: Sendable {
    /// The prefix this store owns. Everything under it is the store's to answer or to decline; nothing
    /// outside it is ever looked at.
    ///
    /// **The scoping is load-bearing, not tidiness.** The front layer runs *before* the router and cannot
    /// ask whether a route would have matched — by the time the router could answer that, the chain is
    /// already inside `inner.handle`. A file middleware that considered every path would therefore shadow
    /// every route in the app, silently, and in registration-independent order. Hummingbird's own
    /// `FileMiddleware` sits the other way round (it runs after the router declines); WireMVC's global
    /// tier has no such position, so the prefix is what stands in for it.
    package static let mountPrefix = "/static/"

    /// Keyed by **path components**, for the reason `AssetsController` writes out at length: decoding
    /// turns `%2F` into `/`, so a key that is a joined string lets one component masquerade as two.
    /// Restated here rather than shared with that controller because the two do different things with a
    /// rejected path — the controller maps it to a `400` through `@ErrorResponse`, and this one declines
    /// (below), which is a different answer to the same question.
    private static let files: [[String]: StaticFile] = [
        ["site.css"]: StaticFile(bytes: [UInt8]("body { font: 1rem system-ui }".utf8), contentType: "text/css"),
        ["js", "app.js"]: StaticFile(bytes: [UInt8]("console.log('static')".utf8), contentType: "text/javascript"),
        ["robots.txt"]: StaticFile(bytes: [UInt8]("User-agent: *\nDisallow:\n".utf8), contentType: "text/plain"),
    ]

    @Inject package init() {}

    /// The remainder after ``mountPrefix``, resolved — or `nil` for anything this store will not serve,
    /// **including a traversal attempt**, which is declined rather than reported. A 404 for a path that
    /// resolves to nothing and a 404 for a path that resolves outside the tree are the same answer on
    /// purpose: the difference between them is information about the filesystem.
    package func file(at remainder: String) async -> StaticFile? {
        // Split first, then decode each component, and never join them back — see
        // `AssetsController.safeComponents(of:)` for why this order is the only safe one.
        let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else {
            return nil
        }
        return Self.files[components]
    }
}

/// The key the composition root names in `@Middleware(GlobalMiddleware.serveStaticFiles)`.
///
/// A separate namespace because a generic type cannot host a `static let` — the same reason
/// `CORSMiddlewareKeys` and `Controllers`' `ControllerMiddleware`/`RouteMiddleware` are ones.
package enum GlobalMiddleware {
    package static let serveStaticFiles = FactoryKey()
}

/// Serves ``StaticFileStore``'s tree from the global tier, and **declines everything else**.
///
/// Declining is the interesting half. For a path under the prefix that the store does not hold, this
/// forwards the box still `pending`, so the router runs, finds nothing, and the app's `@NotFound`
/// fallback answers — the seam this example exists to exercise, observed from both sides in
/// `StaticFileServingTests`.
@Factory(GlobalMiddleware.serveStaticFiles)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the box roles in order (canonical)
package struct ServeStaticFiles<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var store: StaticFileStore

    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let request = input.peekedRequest
        // `isPending` first: an outer middleware may already have answered (a gate's 401), and the box has
        // no sender left to write through. `respondingWith` would return the box unchanged rather than
        // trap, so this is about not doing the *lookup* — first decision wins, and this is not it.
        guard input.isPending, let remainder = Self.remainder(under: request) else {
            return try await next(input)
        }
        // A `POST` to a file path is not a file request. It falls through to the router, which answers
        // `404` through the fallback rather than `405`: nothing is registered at that path, so there is no
        // `Allow` set to state, and claiming one would describe a route that does not exist.
        guard request.method == .get || request.method == .head else {
            return try await next(input)
        }
        guard let file = await store.file(at: remainder) else {
            return try await next(input)  // declined — the router and then `@NotFound` get their turn
        }

        var fields = HTTPFields()
        fields[.contentType] = file.contentType
        // Stated explicitly so the `HEAD` answer below carries the length its `GET` would have. For the
        // `GET`, `WireMVCOutcome.send` would state it anyway (`stateLengthIfAbsent`), and finding it
        // already present changes nothing.
        fields[.contentLength] = String(file.bytes.count)

        // **`respondingWith`, not `responding`** — and this is the choice worth reading twice. Raw
        // `responding` hands over the sender and WireMVC never sees an outcome, so it cannot drain the
        // response-header registry: every field a middleware *outside* this one contributed is discarded.
        // CORS is declared ahead of this middleware on the composition root, so it has already registered
        // `Access-Control-Allow-Origin` for a cross-origin request by the time we get here — and with raw
        // `responding` that field would vanish from exactly the responses a browser fetches most. Pinned
        // by `corsFieldsSurviveAFileAnsweredHere`.
        //
        // The trade `responding` exists for is a body too large to hold, which this outcome does hold. A
        // real large-file server streams and pays the drain instead; that tension is the API's, not this
        // example's, and it is documented on `RequestResponseMiddlewareBox.responding(_:)`.
        let outcome: WireMVCOutcome =
            request.method == .head
            ? .status(.ok, headerFields: fields)
            : .body(file.bytes, .ok, headerFields: fields)
        // Still calls `next` with the responded box, like every middleware in this model: the chain runs
        // to the end so always-run observers downstream still see the request. What they no longer get is
        // a sender — the box is `.responded`, and the terminal skips the router.
        return try await next(try await input.respondingWith(outcome))
    }

    /// The part of the request path under ``StaticFileStore/mountPrefix``, or `nil` if it is not under it.
    ///
    /// Strips the query the way the router does (`RouteTrie.resolve`) — a global middleware is handed the
    /// request line verbatim, so `/static/site.css?v=2` is a path with a query, not a path that misses.
    private static func remainder(under request: HTTPRequest) -> String? {
        guard let target = request.path else { return nil }
        let path = target.firstIndex(of: "?").map { String(target[target.startIndex..<$0]) } ?? target
        guard path.hasPrefix(StaticFileStore.mountPrefix) else { return nil }
        return String(path.dropFirst(StaticFileStore.mountPrefix.count))
    }
}

/// What the app's `@NotFound` fallback answers with — a body, so a test can tell *which* layer produced a
/// `404`. Three of them are reachable and they are not the same event: this one (no route matched), a
/// handler's own mapped `@ErrorResponse` (a route matched and said no), and the static middleware
/// declining into this one.
package struct NoRoute: Codable, Sendable, Equatable {
    package let unmatched: String
    package let method: String

    package init(unmatched: String, method: String) {
        self.unmatched = unmatched
        self.method = method
    }
}
