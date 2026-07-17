public import Synchronization
public import Wire
public import WireMVC

/// A concrete dependency the `RequireAPIKey` gate injects — the set of accepted API keys. An ordinary
/// `@Singleton`, resolved into every runtime's graph. A real one would read a secret store.
@Singleton
public struct APIKeyStore: Sendable {
    let accepted: Set<String> = ["secret"]
    public func isValid(_ key: String) -> Bool { accepted.contains(key) }
}

/// Factory-key namespace for the `RequireAPIKey` gate. A generic type can't host a `static let` key,
/// so the key lives on a small non-generic namespace; the middleware is `@Factory(RequireAPIKeyKeys
/// .factory)` and consumed `@Middleware(RequireAPIKeyKeys.factory)`.
public enum RequireAPIKeyKeys {
    public static let factory = FactoryKey()
}

/// A global request counter the `LogRequests` middleware bumps. Public so each runtime's test can
/// assert the middleware ran (a real one would log or emit a metric).
public let requestObservations = Atomic<Int>(0)

/// A global counter the `AuditGate` middleware bumps. Public so each runtime's test can assert it ran.
public let auditObservations = Atomic<Int>(0)

/// A concrete dependency the `AuditGate` middleware injects — an ordinary `@Singleton`.
@Singleton
public struct AuditLog: Sendable {
    public func record() { auditObservations.add(1, ordering: .relaxed) }
}

/// Factory-key namespace for the `AuditGate` middleware.
public enum AuditKeys {
    public static let factory = FactoryKey()
}

/// A generic-with-deps middleware over the box roles, declared in a **non-canonical order** —
/// `<Sender, Reader, Ctx>` — with `@MiddlewareFactory(.responseSender, .reader, .requestContext)` mapping
/// them positionally, plus an **injected** `Repository`: it shares the controller's `TodoRepository`
/// backend, resolved once and threaded to both through the same lifted generic (the injected axis).
/// Behaviourally a dep-carrying observer: counts each request, forwards the box.
@Factory(AuditKeys.factory)
@MiddlewareFactory(.responseSender, .reader, .requestContext)
public struct AuditGate<
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Repository: TodoRepository
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var log: AuditLog
    @Inject var repository: Repository

    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        log.record()
        return try await next(input)
    }
}

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

/// Route-scope gate middleware, now **generic-with-deps**: it `@Inject`s an `APIKeyStore` to validate
/// the `x-api-key` header, rather than hard-coding the key. `@Factory` makes it a factory template the
/// build plugin synthesises and lifts onto the controller (referenced `@Middleware(RequireAPIKeyKeys
/// .factory)`). Model B: if the key is invalid it writes a 401 itself (consuming the sender), the box
/// becomes `.responded`, and the handler is skipped — it still calls `next`, every middleware runs.
@Factory(RequireAPIKeyKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the box roles in order (canonical)
public struct RequireAPIKey<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var keys: APIKeyStore

    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let presented = input.peekedRequest.headerFields[HTTPField.Name("x-api-key")!] ?? ""
        let authorized = keys.isValid(presented)
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
