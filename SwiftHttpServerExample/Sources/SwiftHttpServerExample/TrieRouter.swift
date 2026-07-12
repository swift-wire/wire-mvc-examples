import AsyncStreaming
import HTTPAPIs
import HTTPTypes
import WireMVC

// A concrete `RoutableHTTPServerBuilder` for this runtime — a path-segment trie. It shows that
// WireMVC's registration contract carries a non-trivial router (vs. wire-mvc's linear `WireRouter`),
// and that the build → freeze → serve lifecycle lives entirely in the runtime: WireMVC stays
// router-agnostic, and `serve(on:)` is deliberately *not* a protocol requirement — it's a
// convenience on this concrete type.

/// A `{name}` parameter edge out of a trie node: the segment name and the child node it leads to.
struct ParameterEdge: Sendable {
    let name: String
    let child: Int
}

/// Build phase — a mutable `RoutableHTTPServerBuilder` that inserts each route into a trie keyed by
/// path segment. Nodes live in a flat array (indices, not pointers). `freeze()` compacts it into an
/// immutable `FrozenTrieRouter` for serving.
struct TrieRouteBuilder<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: RoutableHTTPServerBuilder
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    typealias Handler =
        @Sendable (
            HTTPRequest,
            [String: Substring],
            consuming sending Reader,
            consuming sending ResponseSender
        ) async throws -> Void

    private struct BuildNode {
        var literalChildren: [String: Int] = [:]
        var parameterChild: ParameterEdge?
        var handlers: [(method: HTTPRequest.Method, handler: Handler)] = []
    }

    private var nodes: [BuildNode] = [BuildNode()]

    init() {}

    /// Infer the router's associated types from the server it will serve on. The inverse
    /// (`~Copyable`) requirements are restated because they don't propagate across the generic
    /// boundary on their own.
    init<Server: HTTPServer>(for server: borrowing Server)
    where
        Server.RequestContext == RequestContext,
        Server.Reader == Reader,
        Server.ResponseSender == ResponseSender,
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        self.init()
    }

    mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler: @escaping Handler
    ) {
        var current = 0
        for segment in Self.segments(path) {
            if segment.hasPrefix("{"), segment.hasSuffix("}") {
                let name = String(segment.dropFirst().dropLast())
                if let existing = nodes[current].parameterChild {
                    current = existing.child
                } else {
                    nodes.append(BuildNode())
                    let child = nodes.count - 1
                    nodes[current].parameterChild = ParameterEdge(name: name, child: child)
                    current = child
                }
            } else if let child = nodes[current].literalChildren[String(segment)] {
                current = child
            } else {
                nodes.append(BuildNode())
                let child = nodes.count - 1
                nodes[current].literalChildren[String(segment)] = child
                current = child
            }
        }
        nodes[current].handlers.append((method, handler))
    }

    /// Compact the mutable trie into an immutable router: each node's literal children become a
    /// segment-sorted array (binary-searchable, no per-lookup hashing), and the whole thing is frozen
    /// into contiguous storage.
    consuming func freeze() -> FrozenTrieRouter<RequestContext, Reader, ResponseSender> {
        let frozen = nodes.map { node in
            FrozenTrieRouter<RequestContext, Reader, ResponseSender>.Node(
                literalChildren: node.literalChildren.sorted { $0.key < $1.key }
                    .map { (segment: $0.key, child: $0.value) },
                parameterChild: node.parameterChild,
                handlers: node.handlers
            )
        }
        return FrozenTrieRouter(nodes: frozen)
    }

    /// Freeze this builder and serve it on `server`, running until the surrounding task is cancelled.
    consuming func serve<Server: HTTPServer>(on server: borrowing Server) async throws
    where
        Server.RequestContext == RequestContext,
        Server.Reader == Reader,
        Server.ResponseSender == ResponseSender,
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        try await server.serve(handler: freeze())
    }

    fileprivate static func segments(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}

/// Serve phase — the immutable trie, which *is* the proposal's request handler. Walks the request's
/// path segments through the trie, collecting `{name}` parameters, then dispatches the method's
/// handler (or a 404).
struct FrozenTrieRouter<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: HTTPServerRequestHandler
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    typealias Handler = TrieRouteBuilder<RequestContext, Reader, ResponseSender>.Handler

    struct Node: Sendable {
        let literalChildren: [(segment: String, child: Int)]  // sorted by segment
        let parameterChild: ParameterEdge?
        let handlers: [(method: HTTPRequest.Method, handler: Handler)]
    }

    let nodes: [Node]

    func handle(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender
    ) async throws {
        // Walk the trie without consuming, so the reader and sender are consumed exactly once — by
        // the matched handler, or by the 404.
        var current = 0
        var parameters: [String: Substring] = [:]
        var matched = true
        for segment in Self.stripQuery(request.path ?? "/").split(separator: "/", omittingEmptySubsequences: true) {
            let node = nodes[current]
            if let child = Self.literalChild(of: node, segment: String(segment)) {
                current = child
            } else if let edge = node.parameterChild {
                parameters[edge.name] = segment
                current = edge.child
            } else {
                matched = false
                break
            }
        }
        if matched, let handler = nodes[current].handlers.first(where: { $0.method == request.method })?.handler {
            try await handler(request, parameters, reader, responseSender)
        } else {
            try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
        }
    }

    private static func literalChild(of node: Node, segment: String) -> Int? {
        var low = 0
        var high = node.literalChildren.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = node.literalChildren[mid].segment
            if candidate == segment {
                return node.literalChildren[mid].child
            } else if candidate < segment {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return nil
    }

    private static func stripQuery(_ path: String) -> Substring {
        if let index = path.firstIndex(of: "?") { return path[..<index] }
        return path[...]
    }
}
