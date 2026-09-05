// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import HTTPTypes
import Hummingbird
import HummingbirdTesting
// Conformance-only import: `extension Router: ServerTransport` is what makes `router.register(_:method:path:)`
// below resolve, and no symbol here names it.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import OpenAPIRuntime
import Testing

/// Does ambient task-local context set by a *host* middleware survive Hummingbird's dispatch into a
/// `ServerTransport`-registered handler?
///
/// This is the half of the tracing question wire-mvc's own suite cannot answer. There, a mock transport
/// calls the registered closure directly, which proves the bridge's unstructured `Task {}` inherits
/// task-locals but says nothing about the framework in front of it. Here the value is set by real
/// Hummingbird middleware and read inside the closure Hummingbird itself dispatches to, over a real
/// server.
///
/// `ServiceContext.current` — what an `open-telemetry`-style middleware propagates — is a task-local, so
/// this is the mechanism distributed tracing rides on. A plain `@TaskLocal` stands in for it: the same
/// mechanism, without taking a dependency on swift-distributed-tracing to test the framework's plumbing.
///
/// Registered directly on the transport rather than through a Wire graph on purpose. The graph adds
/// codegen and a backend container to a question that is entirely about Hummingbird's dispatch, and
/// wire-mvc already pins the bridge half; the two together cover the chain.
enum TracingProbe {
    @TaskLocal static var traceID: String?
}

/// Sets the task-local for the whole downstream chain, the way a tracing middleware does.
struct TracingMiddleware<Context: RequestContext>: RouterMiddleware {
    let traceID: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        try await TracingProbe.$traceID.withValue(traceID) {
            try await next(request, context)
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

@Suite("Ambient context across the Hummingbird transport")
struct AmbientContextTests {
    /// A one-shot response: the handler reads the task-local and answers within the register closure.
    @Test func taskLocalContextSetByHostMiddlewareReachesTheHandler() async throws {
        let router = Router()
        router.add(middleware: TracingMiddleware(traceID: "abc-123"))
        try router.register(
            { _, _, _ in
                (HTTPResponse(status: .ok), HTTPBody(TracingProbe.traceID ?? "<none>"))
            },
            method: .get,
            path: "/trace"
        )

        let app = Application(router: router)
        // `.live` rather than `.router`: a real server and real NIO dispatch, so nothing here is an
        // artifact of short-circuiting the transport.
        try await app.test(.live) { client in
            let response = try await client.execute(uri: "/trace", method: .get)
            #expect(response.status == .ok)
            #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "abc-123")
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
        let router = Router()
        router.add(middleware: TracingMiddleware(traceID: "abc-123"))
        try router.register(
            { _, _, _ in
                let body = HTTPBody(LazyTraceChunks(), length: .unknown, iterationBehavior: .single)
                return (HTTPResponse(status: .ok), body)
            },
            method: .get,
            path: "/trace-stream"
        )

        let app = Application(router: router)
        try await app.test(.live) { client in
            let response = try await client.execute(uri: "/trace-stream", method: .get)
            #expect(response.status == .ok)
            let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
            #expect(text == "1:<none>\n2:<none>\n3:<none>\n")
        }
    }

    /// The shape `WireMVCServerTransport` actually uses, and the reason the case above does not condemn
    /// it: the bytes are produced by an unstructured `Task` created *inside* the register closure, which
    /// copies the task-locals bound by the middleware, and pushed out. The framework still pulls the
    /// sequence in its own context, but the values were built in a context that had the trace.
    @Test func taskLocalContextSurvivesWhenTheHandlerProducesTheBytes() async throws {
        let router = Router()
        router.add(middleware: TracingMiddleware(traceID: "abc-123"))
        try router.register(
            { _, _, _ in
                let (stream, continuation) = AsyncStream<ArraySlice<UInt8>>.makeStream()
                Task {
                    for index in 1...3 {
                        continuation.yield(ArraySlice("\(index):\(TracingProbe.traceID ?? "<none>")\n".utf8))
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

        let app = Application(router: router)
        try await app.test(.live) { client in
            let response = try await client.execute(uri: "/trace-task", method: .get)
            let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
            #expect(text == "1:abc-123\n2:abc-123\n3:abc-123\n")
        }
    }
}
