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

// M5.4R — a real *streaming* multipart response. A sender-transforming middleware wraps the runtime's
// response sender in a `MultiPartSender<S>`; the `@RawRoute(.responseSender)` handler receives that
// transformed type (which constraint inference can't name) and streams one part per todo through a
// `MultiPartWriter` — incrementally, not buffered. Removing the middleware makes the handler's parameter
// type unsatisfiable, so the export route is coupled to its transform at compile time.

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
        let header =
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: application/json\r\n\r\n"
        var bytes = Array(header.utf8)
        bytes.append(contentsOf: try JSONEncoder().encode(value))
        bytes.append(contentsOf: Array("\r\n".utf8))
        var buffer = UniqueArray<UInt8>(copying: bytes)
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
        switch consume input {
        case .pending(let request, let requestContext, let reader, let responseSender):
            return try await next(
                .pending(
                    request: request,
                    requestContext: requestContext,
                    reader: reader,
                    responseSender: MultiPartSender(wrapping: responseSender)
                )
            )
        case .responded(let request):
            return try await next(.responded(request: request))
        }
    }
}

/// Streams the todos as a `multipart/mixed` response — one part per todo, written incrementally. Generic
/// over the opaque-lifted `TodoRepository` (the same portable shape as `TodosController`); the route-scope
/// `MultiPartExportMiddleware` transforms the sender, and the raw handler streams through it.
@Singleton
@Controller("/export")
public struct ExportController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    @Get
    @RawRoute(.responseSender)  // bind the transformed sender by role — its type isn't inferable
    @Middleware(MultiPartExport.middleware)  // route-scope: wraps the sender into MultiPartSender<S>
    public func todos<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
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
