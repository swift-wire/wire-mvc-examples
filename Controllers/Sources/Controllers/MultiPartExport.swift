import AsyncStreaming
import BasicContainers
public import HTTPAPIs
public import HTTPTypes
public import Wire
public import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Multipart streaming, in **both** tiers — deliberately, because they answer different questions and the
// pair is what makes the difference legible.
//
// `GET /export` is on the streaming **producer tier**: the framing is a codec (`MultiPartProducer`), the
// terminal owns the sender, and the handler just returns the parts. That is what multipart framing *is*,
// and it is what the SSE route next door became.
//
// `GET /export/raw` keeps the original shape: a **sender-transforming** middleware wraps the runtime's
// response sender in a `MultiPartSender<S>`, and the `@RawRoute(.responseSender)` handler receives that
// transformed type — which constraint inference cannot name — and streams through a `MultiPartWriter`.
// Removing the middleware makes the handler's parameter type unsatisfiable, so that route is coupled to
// its transform at compile time.
//
// Why both survive: the producer tier does not compose with the sender transform, it *subsumes* it. The
// terminal calls `send` itself and hands the producer a plain writer, so `beginParts()` would never be
// reached and the transform would go inert. They are alternatives. Migrating `/export` outright would
// therefore have deleted the only running demonstration of a box-transforming middleware anywhere in
// either repo — every wire-mvc fixture declares `NextInput = Input` — and, with it, the last `@RawRoute`
// in this repo. A route that genuinely needs the whole sender is exactly what `@RawRoute` is for, so it
// keeps one.

/// The streaming writer the transform grants the handler: frames each part with the boundary and writes it
/// to the wrapped body writer *incrementally* (one `write` per part), then closes with the final boundary.
/// `~Copyable`, like the underlying body writer.
public struct MultiPartWriter<Wrapped: CallerAsyncWriter & ~Copyable>: ~Copyable
where Wrapped.WriteElement == UInt8, Wrapped.FinalElement == HTTPFields? {
    private var wrapped: Wrapped
    private let boundary: String

    init(wrapping wrapped: consuming Wrapped, boundary: String) {
        self.wrapped = wrapped
        self.boundary = boundary
    }

    /// Frame and stream one part, JSON-encoding `value` as the part body (`Content-Type: application/json`).
    /// Streaming: one `write` per call, so a large collection is never assembled in memory.
    public mutating func writePart<Value: Encodable>(name: String, _ value: Value) async throws {
        // The same framing the producer emits — one function, so the two tiers cannot drift apart.
        var buffer = UniqueArray<UInt8>(copying: try multiPartFrame(name: name, value))
        try await wrapped.write(buffer: &buffer)
    }

    /// Write the closing boundary and finish the response body.
    public consuming func finish() async throws {
        var closing = UniqueArray<UInt8>(copying: Array("--\(boundary)--\r\n".utf8))
        try await wrapped.finish(buffer: &closing, finalElement: nil)
    }
}

/// A transformed response sender — wraps the runtime's real sender `S` and grants the handler a
/// `beginParts()` API that streams a `multipart/mixed` body. `~Copyable`, like every response sender; its
/// `Writer` is the wrapped sender's, so the plain `HTTPResponseSender` surface passes straight through.
public struct MultiPartSender<Wrapped: HTTPResponseSender & ~Copyable>: HTTPResponseSender, ~Copyable
where Wrapped.Writer: ~Copyable {
    public typealias Writer = Wrapped.Writer
    private var wrapped: Wrapped
    private let boundary: String

    init(wrapping wrapped: consuming Wrapped, boundary: String = "wireboundary") {
        self.wrapped = wrapped
        self.boundary = boundary
    }

    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        try await wrapped.sendInformational(response)
    }

    public consuming func send(_ response: HTTPResponse) async throws -> Wrapped.Writer {
        try await wrapped.send(response)
    }

    /// Send the `multipart/mixed` head and return a `MultiPartWriter` that streams parts into the body.
    public consuming func beginParts() async throws -> MultiPartWriter<Wrapped.Writer> {
        let boundary = self.boundary
        var fields = HTTPFields()
        fields[.contentType] = "multipart/mixed; boundary=\(boundary)"
        let writer = try await self.wrapped.send(HTTPResponse(status: .ok, headerFields: fields))
        return MultiPartWriter(wrapping: writer, boundary: boundary)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The codec — multipart framing on the streaming producer tier
// ─────────────────────────────────────────────────────────────────────────────

/// The multipart boundary both tiers frame with. Named once: the two routes must agree, and the tests
/// assert on it.
public let multiPartBoundary = "wireboundary"

/// One named part of a `multipart/mixed` response, JSON-encoded as the part body.
public struct MultiPartPart<Value: Encodable & Sendable>: Sendable {
    /// The part's `name` in its `Content-Disposition`.
    public var name: String
    /// The part body, encoded as `application/json` when written.
    public var value: Value

    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }
}

/// What `@MultiPartResponse` resolves against: frames each part and writes it as its own chunk, so a large
/// collection is never assembled in memory.
///
/// The same framing `MultiPartWriter` does below — deliberately, so the two routes are byte-identical on
/// the wire and the only difference between them is which tier produced it.
public struct MultiPartProducer<Value: Encodable & Sendable>: WireMVCBodyProducer {
    public let parts: [MultiPartPart<Value>]

    /// The producer *is* the codec, so it is what knows the content type — including the boundary, which
    /// is why the migrated route no longer builds `HTTPFields` by hand.
    public var contentType: String? { "multipart/mixed; boundary=\(multiPartBoundary)" }

    public init(_ parts: [MultiPartPart<Value>]) {
        self.parts = parts
    }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        for part in parts {
            var buffer = UniqueArray<UInt8>(copying: try multiPartFrame(name: part.name, part.value))
            try await writer.write(buffer: &buffer)
        }
        // The closing boundary rides the terminating write, so the producer finishes the response itself —
        // the tier's contract.
        var closing = UniqueArray<UInt8>(copying: Array("--\(multiPartBoundary)--\r\n".utf8))
        try await writer.finish(buffer: &closing, finalElement: trailer)
    }
}

/// One part's bytes: the boundary, its headers, and the JSON body. Shared by both tiers so neither can
/// drift from the other.
func multiPartFrame<Value: Encodable>(name: String, _ value: Value) throws -> [UInt8] {
    let header =
        "--\(multiPartBoundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: application/json\r\n\r\n"
    var bytes = Array(header.utf8)
    bytes.append(contentsOf: try JSONEncoder().encode(value))
    bytes.append(contentsOf: Array("\r\n".utf8))
    return bytes
}

/// `@MultiPartResponse` — the route returns parts, streamed as `multipart/mixed`.
///
/// `client: .text` because there is nothing to decode back into: a multipart body is a container, not a
/// value, so the generated typed client hands back the undecoded body as it does for `@HTMLResponse`.
@ResponseMode(.streaming, codec: "MultiPartProducer", client: .text)
@attached(peer)
public macro MultiPartResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The `(status:)` overload, matching how WireMVC's own modes are declared.
@ResponseMode(.streaming, codec: "MultiPartProducer", client: .text)
@attached(peer)
public macro MultiPartResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// Factory-key namespace for the sender-transforming export middleware.
public enum MultiPartExport {
    public static let middleware = FactoryKey()
}

/// A **sender-transforming** middleware: `Box<Ctx, R, S>` → `Box<Ctx, R, MultiPartSender<S>>`. Wraps the
/// response sender so the `@RawRoute(.responseSender)` export handler receives a `MultiPartSender<S>`.
@Factory(MultiPartExport.middleware)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the box roles in order (canonical)
public struct MultiPartExportMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = RequestResponseMiddlewareBox<Ctx, Reader, MultiPartSender<Sender>>

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        // The registry and the matched route come out of the `pending` destructure and are threaded into
        // the rebuilt box. Both are required parameters precisely so a transforming middleware cannot
        // forget: dropping the registry would silently discard every header field contributed upstream of
        // here, and dropping the route would unname the route for everything further in. Taking the
        // registry from the destructure rather than off the box beforehand is also what keeps it
        // disconnected — a captured local would be task-isolated, and the rebuilt box could not then be
        // handed on.
        return try await input.withContents(
            pending: { request, requestContext, route, reader, responseSender, responseHeaders in
                try await next(
                    .pending(
                        request: request,
                        requestContext: requestContext,
                        route: route,
                        reader: reader,
                        responseSender: MultiPartSender(wrapping: responseSender),
                        responseHeaders: responseHeaders
                    )
                )
            },
            responded: { request, route in
                // The registry is the one thing not threaded: a `responded` box carries none, because the
                // response is already written and nothing would ever drain one. The route is, for the same
                // reason the request is — an observer further in still wants to know what was gated.
                try await next(.responded(request: request, route: route))
            }
        )
    }
}

/// Streams the todos as a `multipart/mixed` response — one part per todo, written incrementally. Generic
/// over the opaque-lifted `TodoRepository`, the same portable shape as `TodosController`.
///
/// Two routes, one body format, one per tier. Both frame through the same `multiPartFrame`, so they serve
/// the same parts and differ only in *how the response is produced* — which is what makes the pair worth
/// keeping.
///
/// The suites assert each route's framing separately rather than comparing the two responses. Two
/// independently-produced bodies are not comparable byte-for-byte: `all()` promises no part ordering, and
/// `JSONEncoder` promises no key ordering within a part — both were observed to vary between adjacent
/// requests. Equality would have been asserting what neither the app nor Foundation guarantees.
@TestScopable  // app-scoped, but rebuilt per-request under a keyed suite so `/export` is mock-testable
@Singleton
@Controller("/export")
public struct ExportController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    /// The **producer tier**. The handler returns parts; `MultiPartProducer` frames them and the terminal
    /// owns the sender. Multipart framing is a codec, and this is what saying so looks like.
    ///
    /// What it gains over the raw route below: the status and the boundary-bearing `Content-Type` come
    /// from the annotation and the producer rather than hand-built `HTTPFields`; the handler call sits
    /// inside the terminal's mapped region, so a repository failure becomes a status instead of an empty
    /// 200 with a truncated body; and the handler is no longer generic over the router's sender type.
    @Get
    @MultiPartResponse
    public func todos() async throws -> [MultiPartPart<Todo>] {
        try await repository.all().map { MultiPartPart(name: $0.id, value: $0) }
    }

    /// The **raw tier**, kept deliberately. A route-scope sender-transforming middleware rebuilds the box
    /// as `Box<Ctx, R, MultiPartSender<S>>`, and `@RawRoute(.responseSender)` binds that transformed type
    /// by role because constraint inference cannot name it.
    ///
    /// This is the only running demonstration of a box-transforming middleware in either repo — every
    /// wire-mvc fixture declares `NextInput = Input` — and the only remaining `@RawRoute` here. The
    /// producer tier cannot host it: the terminal calls `send` itself and hands the producer a plain
    /// writer, so `beginParts()` would never be reached and the transform would go inert. A route that
    /// genuinely needs the whole sender is what `@RawRoute` is for, and this is one.
    @Get("/raw")
    @RawRoute(.responseSender)  // bind the transformed sender by role — its type isn't inferable
    @Middleware(MultiPartExport.middleware)  // route-scope: wraps the sender into MultiPartSender<S>
    public func todosRaw<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming MultiPartSender<Sender>
    ) async throws where Sender.Writer: ~Copyable {
        let todos = try await repository.all()
        var parts = try await responseSender.beginParts()
        for todo in todos {
            try await parts.writePart(name: todo.id, todo)  // JSON-encode the whole todo as the part body
        }
        try await parts.finish()
    }
}
