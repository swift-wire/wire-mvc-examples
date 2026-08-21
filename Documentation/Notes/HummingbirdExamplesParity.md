# hummingbird-examples parity — what's missing, and in what order

> **Status:** planning note. Assessed against `hummingbird-examples` @ 2026-08-15 (28 examples).
> Records the gap list, the order of work, and the two framework limits that shape it.

## The two limits

**Catch-all path segments are not the blocker.** `RouteTrie` holds one parameter edge per node and no
wildcard (`wire-mvc/Sources/WireMVCRouter/RouteTrie.swift:22-61`), which is a real gap — backlog item #3
in `wire-mvc/Documentation/Notes/WireMVCRouter.md:63` — but nothing in hummingbird-examples registers a
catch-all route. A grep for `**` across all 28 route tables returns nothing. `s3-file-provider` and
`proxy-server`, the two examples usually attributed to it, are **middleware** with at most one real
route (`s3-file-provider/Sources/App/Application+build.swift:60-77`). Arbitrarily deep *fixed-arity*
templates (`/a/{b}/c/{d}`) already work; what's missing is a variable-arity remainder, which no example
needs.

Portability makes catch-all worse than it looks: `ServerTransport` carries OpenAPI's `{name}` template
convention, and a wildcard fails **silently and differently** per adapter — swift-openapi-vapor maps
anything that isn't `{name}` to a literal segment (`VaporTransport.swift:71-84`), while
swift-openapi-hummingbird hands it to `RouterPath`, where `{path*}` parses as a single-segment capture
named `path*` (`hummingbird/Sources/Hummingbird/Router/RouterPath.swift:34-42`). Any catch-all example
would work on `SwiftHttpServerExample` and be quietly broken on the other two.

**The `ServerTransport` ceiling is real but narrow.** `ServerRequestMetadata` is a struct whose entire
contents are `pathParameters: [String: Substring]`
(`swift-openapi-runtime/Sources/OpenAPIRuntime/Interface/CurrencyTypes.swift:24-33`). Unreachable
through it: connection metadata (remote address), protocol upgrade (websockets), the host's request
context, and non-`{name}` path syntax. Note that `WireOpenAPI` does **not** use `ServerTransport` — an
operation is a `RouteContributor` witness via direct dispatch — so the protocol's only job in this stack
is as a borrowed universal router-registration interface for Hummingbird/Vapor/Lambda. Dropping to a
native adapter would cost portability, not any OpenAPI capability.

Streaming request bodies were *not* part of that ceiling — see the first work item.

## Coverage today

| Already covered in kind | By what |
|---|---|
| hello, todos-fluent, todos-dynamodb, todos-postgres-tutorial | todos CRUD × 3 real backends through one `TodoRepository` binding |
| todos-mongokitten-openapi | `OpenAPISpec` on all three runtimes |
| html-form | `HTMLForm` `/contact` |
| server-sent-events | `@RawRoute GET /todos/stream` |
| multipart-form | `@MultipartBody` + `@MultipartStream` + `/export` |
| response-body-processing | the `MultiPartSender<S>` sender-transforming middleware |
| sessions (partly) | `@Scoped(seed: HTTPRequest.self)` `/me` + `SessionManager` |

## The order — parity track

1. ~~**Bridge request-body streaming**~~ (`wire-mvc`, not an example) — **done**. The bridge collected the
   whole request body up to 1 MB before the handler started, so "acting on a body before it has arrived"
   (`POST /upload/stream` answering 401 while bytes are still in flight) was native-path-only behaviour
   and anything over 1 MB threw. `BridgeReader` now pulls one chunk per `read` off the transport's
   `HTTPBody`, and the size limit is WireMVC's own again. Covered by three tests in
   `wire-mvc/Tests/WireMVCServerTransportTests/AdapterTests.swift`, and the Hummingbird and Vapor suites
   pass against it on real backends. **Still unverified:** the full-duplex case — a request body still
   being read after the route closure has returned a *streaming* response. The bridge's own suite pins it,
   but no example route does both at once (`/todos/stream` and `/export` are GETs), so neither framework's
   channel semantics have been exercised. Answering that is step 1 of the streaming track below.
2. **File serving / s3-file-provider.** A global `@Middleware` that answers the request itself over the
   `@NotFound` fallback — the box's `.responded` state (`wire-mvc/Sources/WireMVC/Middleware.swift:5-20`)
   plus the front layer wrapping every route including the fallback
   (`wire-mvc/Sources/WireMVCCodegen/BootstrapGeneration.swift:85-87`). Nothing in the repo exercises
   that seam end-to-end. Native-path only: on the ServerTransport runtimes the host's own file
   middleware does this, which is the honest story for a framework that collates rather than owns the
   router.
3. **jobs.** A job queue as a graph-hosted `ServiceLifecycle` service plus a route that enqueues.
   Nothing currently shows work outliving the request.
4. **auth-abac / auth-permissions.** Policy objects as bindings, composed by route-scope middleware.
   The existing API-key gate is a toy next to this.
5. **upload.** An unbounded body streamed to disk — blocked until step 1 and now ordinary parity work.
   Small, and the one parity item that overlaps the streaming track: a large streamed upload answered with
   a streamed response is the echo's shape.

## The order — streaming track

Independent of the parity track: neither blocks the other, and they touch different seams. This one exists
because a route that reads its request body *while* writing its response cannot be expressed on any typed
tier — the producer runs after the handler returns, so it cannot hold a lent cursor. See
[wire-mvc's *The shape this tier does not reach: lending the writer*](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/StreamingResponseTier.md).

1. **The `response-body-processing` echo, as a `@RawRoute`.** The smallest item and the gating one. It
   answers the open runtime question above — whether Hummingbird and Vapor tolerate a request body being
   read after a streaming response head is out — and that answer is decision-relevant before anything else
   here: if either refuses, a lending tier's payoff shrinks to the native runtime.

   It also manufactures the evidence such a tier would need. The streaming-tier note makes this argument
   against itself: *"Streaming HTML needs a new response tier" is a weak case. "Two shipped example routes
   pay full `@RawRoute` cost for something that should be typed" is not.* A lending tier with no route
   asking for it is the weak case restated; one real read-and-write route is not.

2. **Migrate `/todos/stream` and `/export` onto the producer tier.** wire-mvc's own outstanding item, and it
   sharpens step 3 rather than competing with it: until `@RawRoute` shrinks to routes that genuinely need
   the whole sender, you cannot tell which routes are there for which reason. Afterwards the only ones left
   are the protocol-switching hatch and the echo — which makes the echo a precise statement of what is
   missing rather than an anecdote.

   **Do `/todos/stream` first.** `/export` streams through `MultiPartSender<S>`, a middleware that transforms
   the *sender*, while the producer tier's writer comes from the framework's own `send` — it is not obvious
   the two compose, and that migration may surface a real constraint rather than being mechanical. Ordering
   it second means a failure there doesn't also cost the tier its second client.

3. **Spike a lending tier** — in `swift-wire-spikes`, the way spike-14 proved the ServerTransport bridge, not
   in `wire-mvc`. Take the streaming-tier note's two open questions in the **opposite** order to how they are
   listed there: the ownership question (can a `~Escapable` writer cross into a user method while a lent
   cursor is live) before the ergonomic one (the user-written `W: CallerAsyncWriter & ~Copyable & ~Escapable`
   constraint). If the first fails the tier is dead and the tax is moot — being wrong about ergonomics is
   cheap, and being wrong about ownership is the failure that note keeps recording.

**Verify early, cheaply:** does tracing context cross the WireMVC boundary? It should — the bridge's
unstructured `Task {}` (`WireMVCServerTransport.swift:254`) inherits task-locals, so an `open-telemetry`
style host middleware's `ServiceContext` ought to reach a handler — but it is exactly the kind of thing
that silently doesn't. The answer changes how much a native adapter buys.

## Deferred

- **auth-jwt** — bearer-token scope construction beside the existing cookie one. Small delta, cheap,
  worth doing when convenient.
- **auth-cognito, auth-otp, auth-srp, webauthn, graphql-server, todos-auth-fluent, todos-lambda** —
  protocol/backend variety, low framework signal.
- **proxy-server** — needs connection metadata, absent from `ServerRequestMetadata` *and* from
  `NIOHTTPServer.RequestContext` (`swift-http-server/Sources/NIOHTTPServer/NIOHTTPServer.swift:66`).
  The proposal has a designed extension point for it (capability protocols on `RequestContext`, with
  `ConnectionInfo` as the worked example in `HTTPServerCapability+RequestContext.swift:20-40`), so this
  is an upstream gap with a known shape rather than a dead end.
- **websocket-echo, websocket-chat** — protocol upgrade; native adapter only. If one is ever written,
  name it against the existing `wire-hummingbird` (a Wire-DI-tier adapter where controllers hand-write
  Hummingbird routing) — a WireMVC-tier adapter would be a third, confusable product.
- **http2** — not a WireMVC concern; that's `Application` TLS configuration.
