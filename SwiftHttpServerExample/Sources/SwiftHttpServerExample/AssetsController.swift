// Full Foundation, not the `canImport(FoundationEssentials)` guard used elsewhere in this package:
// `removingPercentEncoding` is not in FoundationEssentials, so the guard resolves to the lighter module
// on Linux and the API is absent — which compiles on macOS and fails in CI.
import Foundation
package import Wire
package import WireMVC

// A **catch-all** route — `@Get("/{path*}")` — and the only controller in this repo that lives in a
// runtime's own package rather than in the shared `Controllers` library.
//
// That placement *is* the lesson. A catch-all is served by WireMVC's own router and refused by the
// `ServerTransport` bridge, which throws at registration: the path crosses `register` as an OpenAPI
// `{name}` template, and Hummingbird and Vapor each interpret a wildcard in it differently. Putting this
// controller in `Controllers` would therefore break the Hummingbird and Vapor executables at startup —
// so a native-only route shape lives with the native runtime, and the portability cliff is visible in
// the file layout rather than discovered at boot.
//
// Both hosts *do* have wildcards of their own; the gap is on the bridge's side. Whether it closes is
// measured by wire-mvc's `Documentation/Notes/CatchAllMountingProbe.md`.

/// Serves a small in-memory asset tree, keyed by the whole remaining path.
///
/// The interesting parts are what the *router* guarantees and what the handler must still do:
///
/// - `/assets/manifest` reaches `manifest()`, not this catch-all. A literal beats a parameter beats a
///   catch-all, and that precedence is structural rather than registration-ordered.
/// - `path` arrives **undecoded** — the one parameter WireMVC does not percent-decode, because a
///   remainder spans separators and decoding it would turn `%2F` into a real path boundary before this
///   handler ever saw it. Decoding per component, below, is the only order that keeps the structure.
// No `@TestScopable`: it injects no collaborator, so there is nothing for a keyed suite to substitute
// and no doubles struct to thread. App-scoped and built once, like any dependency-free controller.
@Singleton
@Controller("/assets")
package struct AssetsController: Sendable {
    /// The tree served, keyed by **path components** rather than by a joined string. A dictionary rather
    /// than a filesystem: this example is about *routing*, and a real file server is a different exercise —
    /// the parity plan serves that as a global `@Middleware` answering over the `@NotFound` fallback,
    /// which needs no catch-all at all.
    ///
    /// Components, not a string, for the reason the whole file is about. Decoding turns `%2F` into `/`,
    /// so joining decoded components back into a path re-creates exactly the separator the router
    /// preserved — and `js%2Fapp.js`, which is *one* component whose name contains a slash, would address
    /// the *two*-component `js/app.js`. Keyed this way, one component can never masquerade as two.
    private static let assets: [[String]: String] = [
        ["app.css"]: "body { margin: 0 }",
        ["js", "app.js"]: "console.log('hello')",
        ["img", "logo", "small.svg"]: "<svg/>",
        ["a b.txt"]: "spaces are legal in a path segment",
    ]

    @Inject package init() {}

    /// A literal under the same prefix, to show it wins.
    @Get("/manifest")
    @JSONResponse
    package func manifest() -> [String] {
        Self.assets.keys.map { $0.joined(separator: "/") }.sorted()
    }

    /// The catch-all. `path` is everything after `/assets/`, separators intact.
    @Get("/{path*}")
    @ErrorResponse(AssetError.self, .badRequest)
    @ErrorResponse(AssetNotFound.self, .notFound)
    @JSONResponse
    package func asset(@Path path: String) async throws -> Asset {
        let components = try Self.safeComponents(of: path)
        guard let body = Self.assets[components] else { throw AssetNotFound() }
        // Joined for *display* only. The lookup above never re-joins, which is the difference between
        // reporting a path and resolving one.
        return Asset(path: components.joined(separator: "/"), body: body)
    }

    /// Split first, then decode each component — and never join them back.
    ///
    /// The order is the point, and it is why the router hands the remainder over undecoded rather than
    /// helpfully cleaning it up. Decoding first would let `%2E%2E%2F` become `../` after the traversal
    /// check, and `%2F` become a separator the split never saw. Joining afterwards undoes the same
    /// protection from the other end — which is why the asset tree is keyed by components.
    static func safeComponents(of path: String) throws -> [String] {
        let decoded = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard !decoded.contains(where: { $0 == ".." || $0 == "." }) else {
            throw AssetError.traversalRejected
        }
        return decoded
    }
}

/// One served asset.
package struct Asset: Codable, Sendable, Equatable {
    package let path: String
    package let body: String

    package init(path: String, body: String) {
        self.path = path
        self.body = body
    }
}

// The controller's own failure vocabulary. Two *types* rather than two cases of one, because
// `@ErrorResponse` maps by type: a single enum could not carry both a 400 and a 404. Borrowing the todos
// domain's `TodoNotFound` would have been the other way to get a 404, and it would have been a lie —
// nothing here is a todo.

/// The request named something outside the tree.
package struct AssetNotFound: Error {
    package init() {}
}

/// The request named something the tree will not resolve, however it was spelled.
package enum AssetError: Error {
    case traversalRejected
}
