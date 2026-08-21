import HTTPTypes
import OpenAPIRuntime
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

/// Does ambient task-local context set by a *host* middleware survive Vapor's dispatch into a
/// `ServerTransport`-registered handler?
///
/// The Vapor half of the tracing question. wire-mvc's own suite proves the bridge's unstructured
/// `Task {}` inherits task-locals, but a mock transport calls the registered closure directly and says
/// nothing about the framework in front of it. Here the value is set by real Vapor middleware and read
/// inside the closure `VaporTransport` dispatches to.
///
/// Worth measuring rather than assuming on this runtime in particular: Vapor's request pipeline has an
/// `EventLoopFuture` heritage, and a hop that leaves the task context would drop task-locals silently —
/// the response would still be correct, only the trace would be missing. Vapor also binds no task-local
/// logger of its own (its request logger is a stored property on `Request`), so unlike Hummingbird there
/// is no existing feature whose breakage would reveal this.
///
/// `ServiceContext.current` — what an `open-telemetry`-style middleware propagates — is a task-local, so
/// this is the mechanism distributed tracing rides on. A plain `@TaskLocal` stands in for it, proving the
/// framework's plumbing without a dependency on swift-distributed-tracing.
enum TracingProbe {
    @TaskLocal static var traceID: String?
}

/// Sets the task-local for the whole downstream chain, the way a tracing middleware does.
struct TracingMiddleware: AsyncMiddleware {
    let traceID: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try await TracingProbe.$traceID.withValue(traceID) {
            try await next.respond(to: request)
        }
    }
}

/// Chunks whose bytes are built *when the consumer pulls them*, not when the sequence is constructed.
///
/// This distinction is the test. `AsyncStream { continuation in … }` runs its builder synchronously at
/// construction, so reading the task-local there would happen inside the register closure and prove
/// nothing about what survives it. Reading in `next()` runs when the framework pulls the body — after
/// the closure returned, and in whatever task context the framework does that pulling in, which is the
/// thing actually in question.
struct LazyTraceChunks: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>

    struct AsyncIterator: AsyncIteratorProtocol {
        var index = 0

        mutating func next() async -> ArraySlice<UInt8>? {
            index += 1
            guard index <= 3 else { return nil }
            return ArraySlice("\(index):\(TracingProbe.traceID ?? "<none>")\n".utf8)
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

@Suite("Ambient context across the Vapor transport")
struct AmbientContextTests {
    /// A one-shot response: the handler reads the task-local and answers within the register closure.
    @Test func taskLocalContextSetByHostMiddlewareReachesTheHandler() async throws {
        try await withApp { app in
            app.middleware.use(TracingMiddleware(traceID: "abc-123"))
            let transport = VaporTransport(routesBuilder: app)
            try transport.register(
                { _, _, _ in
                    (HTTPResponse(status: .ok), HTTPBody(TracingProbe.traceID ?? "<none>"))
                },
                method: .get,
                path: "/trace"
            )

            try await app.testing().test(.GET, "/trace") { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "abc-123")
            }
        }
    }

    /// A body the *framework* pulls after the register closure returned: context is **gone**.
    ///
    /// Measured, and initially a surprise — an earlier version of this test built the chunks eagerly with
    /// `AsyncStream { continuation in … }`, whose builder runs synchronously at construction, so the reads
    /// happened inside the closure and it passed while proving nothing. Pulling lazily is what asks the
    /// real question, and the answer is that the framework consumes the response body outside the task
    /// that had the value bound.
    ///
    /// Pinned as a boundary rather than filed as a defect: it is inherent to the body being an
    /// `AsyncSequence` the framework drives. It matters to anyone writing a raw `ServerTransport` handler
    /// that reads ambient context while generating bytes. It does **not** describe WireMVC's streaming
    /// path — see the next test for why.
    @Test func taskLocalContextIsLostWhenTheFrameworkPullsTheBody() async throws {
        try await withApp { app in
            app.middleware.use(TracingMiddleware(traceID: "abc-123"))
            let transport = VaporTransport(routesBuilder: app)
            try transport.register(
                { _, _, _ in
                    let body = HTTPBody(LazyTraceChunks(), length: .unknown, iterationBehavior: .single)
                    return (HTTPResponse(status: .ok), body)
                },
                method: .get,
                path: "/trace-stream"
            )

            try await app.testing().test(.GET, "/trace-stream") { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "1:<none>\n2:<none>\n3:<none>\n")
            }
        }
    }

    /// The shape `WireMVCServerTransport` actually uses, and the reason the case above does not condemn
    /// it: the bytes are produced by an unstructured `Task` created *inside* the register closure, which
    /// copies the task-locals bound by the middleware, and pushed out. The framework still pulls the
    /// sequence in its own context, but the values were built in a context that had the trace.
    @Test func taskLocalContextSurvivesWhenTheHandlerProducesTheBytes() async throws {
        try await withApp { app in
            app.middleware.use(TracingMiddleware(traceID: "abc-123"))
            let transport = VaporTransport(routesBuilder: app)
            try transport.register(
                { _, _, _ in
                    let (stream, continuation) = AsyncStream<ArraySlice<UInt8>>.makeStream()
                    Task {
                        for index in 1...3 {
                            continuation.yield(
                                ArraySlice("\(index):\(TracingProbe.traceID ?? "<none>")\n".utf8)
                            )
                        }
                        continuation.finish()
                    }
                    return (
                        HTTPResponse(status: .ok),
                        HTTPBody(stream, length: .unknown, iterationBehavior: .single)
                    )
                },
                method: .get,
                path: "/trace-task"
            )

            try await app.testing().test(.GET, "/trace-task") { response in
                #expect(String(buffer: response.body) == "1:abc-123\n2:abc-123\n3:abc-123\n")
            }
        }
    }
}
