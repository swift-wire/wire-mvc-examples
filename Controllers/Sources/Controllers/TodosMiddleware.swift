public import Synchronization
public import WireMVC

/// A global request counter the `LogRequests` middleware bumps. Public so each runtime's test can
/// assert the middleware ran (a real one would log or emit a metric).
public let requestObservations = Atomic<Int>(0)

/// Controller-scope observability middleware: it counts every request and forwards the box untouched.
/// It always runs — even for requests an inner gate short-circuits — which is the point of the model.
/// Generic and dep-free, so it's named `@Middleware(LogRequests<WireContext, WireReader, WireSender>.self)`.
public struct LogRequests<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public init() {}

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        requestObservations.add(1, ordering: .relaxed)
        return try await next(input)
    }
}

/// Route-scope gate middleware: if the `x-api-key` header isn't `secret`, it handles the request itself
/// by writing a 401 (consuming the sender); the box becomes `.responded`, so the route's handler is
/// skipped. It still calls `next` — every middleware runs — it just forwards an already-responded box.
public struct RequireAPIKey<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public init() {}

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let authorized = input.peekedRequest.headerFields[HTTPField.Name("x-api-key")!] == "secret"
        guard input.isPending, !authorized else {
            return try await next(input)
        }
        return try await next(
            input.responding { sender in
                var writer = sender
                try await writer.sendAndFinish(HTTPResponse(status: .unauthorized))
            }
        )
    }
}
