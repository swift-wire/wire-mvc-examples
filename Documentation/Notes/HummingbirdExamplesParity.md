# hummingbird-examples parity — what's missing, and in what order

> **Status:** planning note, revised 2026-08-26. Assessed against `hummingbird-examples` @ 2026-08-15
> (28 examples). Records the gap list, the order of work, and the two framework limits that shape it.
> **Parity track: three of five done** — the bridge's request-body streaming, file serving over the
> fallback, and jobs. What remains is `auth-abac` and the `upload` half that belongs to the streaming
> track. Each item's entry carries what its implementation settled, including where the item as written
> turned out to be about something else.

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
| jobs | `@BackgroundService` `JobWorker` + a per-runtime `JobStore` + `POST /jobs`, on all three runtimes |

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
2. ~~**File serving / s3-file-provider**~~ — **done**, and worth restating as what it was always about:
   *a global `@Middleware` that answers the request itself over the `@NotFound` fallback*. "File serving"
   reads as done the moment a catch-all route serves a tree, which `AssetsController` (#57) now does — and
   that is a different seam. A route runs *inside* the router, after a match; this one runs outside it.

   `SwiftHttpServerExample`'s `StaticFileServing.swift` is the seam: `ServeStaticFiles` is a second global
   `@Middleware` on the composition root, injecting a `StaticFileStore` whose lookup is `async` because the
   example it stands in for is S3. It answers `GET`/`HEAD` under `/static/` — the box's `.responded` state
   (`wire-mvc/Sources/WireMVC/Middleware.swift:5-20`) plus the front layer wrapping every route including
   the fallback (`wire-mvc/Sources/WireMVCCodegen/BootstrapGeneration.swift:85-87`) — and **declines**
   everything else, which is the half that needed a counterpart: the app now authors a `@NotFound` with a
   `NoRoute` body, so `StaticFileServingTests` can assert *which* layer answered rather than only that a
   `404` came back. Native-path only, as stated: on the ServerTransport runtimes there is no generated
   `@main` and therefore no global tier at all, and the host's own file middleware holds this position.

   Two things the implementation settled that the item did not anticipate:

   - **The middleware has to be prefix-scoped, and that is structural.** The front layer runs *before* the
     router and cannot ask whether a route would have matched — by the time it could, the chain is already
     inside `inner.handle`. An unscoped file middleware would therefore shadow every route in the app.
     Hummingbird's `FileMiddleware` sits the other way round, running after the router declines; WireMVC's
     global tier has no such position, so a prefix is what stands in for one.
   - **`respondingWith`, not `responding`.** Raw `responding` hands over the sender and WireMVC never sees
     an outcome, so it cannot drain the response-header registry: CORS is the outer global middleware and
     has already *contributed* `Access-Control-Allow-Origin` by then, and it would be dropped on precisely
     the responses a browser fetches most. Pinned by `corsFieldsSurviveAFileAnsweredHere`.

   **One framework finding on the way — since fixed, in-house.** A `@RawRoute` could not declare its
   response sender `consuming sending Sender` when the sender was the **untransformed** one, which is
   every raw route not sitting behind a sender-transforming middleware and *always* a `@NotFound`, since
   `registerNotFound` folds no middleware and so can never be handed a transformed sender. `noRoute` in
   `SwiftHttpServerExample` now declares `consuming sending Sender`, and compiles.

   Measured by compiling each case against this app rather than reasoned about, because every step of the
   reasoning turned out to be wrong at least once:

   | slot | codegen passes | `sending`, before | after |
   |---|---|---|---|
   | reader | `reader` verbatim | compiles — including through a fold | unchanged |
   | transformed sender (`MultiPartSender<S>`) | `responseSender` verbatim | compiles | unchanged |
   | untransformed sender | `ResponseHeaderApplyingSender(wrapping:registry:)` | region-isolation error | **compiles** |

   **The cause was provenance, not the wrap and not aliasing.** Regions permit aliasing *within* a region;
   what decides the region is where a value came from. The proposal's `HTTPServerRequestHandler.handle`
   declares `reader` and `responseSender` as `consuming sending` but `requestContext` as plain
   `consuming`. So the `ResponseHeaderRegistry` — which travels inside the context, because `handle` takes
   exactly four values and the context is the only extension point among them — was task-isolated, and
   merging it into the wrapper tainted a composite that was otherwise disconnected. The reader was
   untouched because nothing is merged into it, which is why it took `sending` even then.

   **The in-house route was taken**, not the one-word-upstream one: `requestContext: consuming sending
   RequestContext` was never declined, because it was never asked — the API break was affordable while
   there are no consumers, and the in-house fix turned out to pay for itself. `ResponseHeaderRegistry` is
   now a `~Copyable` struct carried in `WireDisconnected` inside `WireMVCContext`, which is the treatment
   the reader and sender already got. Linearity is the load-bearing half: `WireDisconnected` alone, with
   the registry left a class, compiles and is **unsound**, since that type's precondition is that the
   stored value is never aliased — true of a linear reader or sender by construction, false of a class
   reference. wire-mvc's
   [`LinearResponseHeaderRegistry.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/LinearResponseHeaderRegistry.md)
   records the design, the four places the plan turned out to be wrong, and the measurement: **six
   allocations and 1536 bytes per request**, on a case where the registry genuinely escapes.

   The third option — making the registry `Sendable` with a `Mutex` and `@Sendable` `onSend` closures —
   was not taken, and the reason is still worth recording: it constrains what a middleware may capture to
   compute a deferred contribution, overturning a decision the type documents deliberately.

   **The public break landed here too.** Middleware wrote `input.responseHeaders.add(…)`, which worked
   only because a class reference mutates through a borrow; that is now
   `input.contributing { headers in … } then: { … }`. `ResponseDefaults` and `MultiPartExport` are the two
   call sites in this repo — `ServeStaticFiles`, named here as a casualty when this was written, never
   touched the registry at all.

   Two smaller things this turned up, both in wire-mvc, both now closed. The codegen test
   `notFoundHandlerRegistersAsFallback` spelled its fixture `consuming sending Sender` while asserting
   only on rendered source, so nothing compiled it — it was the only place in either repo advertising a
   spelling that could not work. It is now true, and compiled by two fixtures that spell it for real. And
   two comments — `Fixtures/Sources/WireMVCExample/UsersController.swift` and `WireMVCOutcome.send(on:)` —
   attributed the rule to the middleware fold handing the sender out as "a plain `consuming` value", where
   both box destructures in fact declare `consuming sending`. The rule was right; the reason given for it
   was not, and both now say why plain `consuming` is simply the permissive spelling.

3. ~~**jobs**~~ — **done**, in the shared `Controllers` package so all three runtimes serve it, and split
   across two bindings rather than one: a per-runtime `JobStore` holding the records, and a `JobWorker`
   that owns the in-process handoff, drains it, and *is* what the route talks to. `POST /jobs` /
   `GET /jobs/{id}` in `JobsController`.

   **Durability is not the one-line swap it looks like**, and that is the main thing this item settled. The
   obvious first cut keeps the records in the same in-memory type as the handoff, on the reasoning that
   making them durable changes only where `submit` writes. It does not. A real store added a startup sweep,
   a double-delivery bug and the conditional claim that fixes it, an explicit at-least-once contract, and a
   rule about which test substitution primitive can reach a background service at all. All of that hides
   behind an in-memory version, which is why this item earns its keep against three real backends rather
   than against a dictionary.

   **The shape.** `JobWorker` is bound `@Singleton(as: JobProcessor.self) @BackgroundService` and is
   generic over the opaque store — three things nothing had combined before (`@Singleton(as:)` with
   `@Contributes` is absent from every harness in swift-wire, where every contributor is a plain
   `@Singleton`). It composes exactly as wanted:

   ```swift
   let someJobProcessor = JobWorker(store: someJobStore)
   let jobsControllerOfSomeJobProcessor = JobsController(jobs: someJobProcessor)
   let anyServiceKeyedWireMVCKeysServices = [someJobProcessor] as [any Service]
   ```

   One construction, two consumers: the route talks to it and the `ServiceGroup` runs it. That is what
   makes the handoff private — there is only one object, so nothing has to be told where to find the
   stream. `JobsController` injects `some JobProcessor` and cannot tell that the thing answering its
   `submit` is also a running service, which is the claim worth making: **hosting work that outlives the
   request costs the route nothing.**

   What the implementation settled, in rough order of how much it changed:

   - **The sweep, and the bug it introduced.** With a durable store, `run()` can recover what a previous
     process left `queued` (accepted, never handed over) or `running` (started, then lost) before entering
     its loop. That immediately broke: a job submitted in the window *before* `run()` sweeps is written
     `queued`, handed to the loop by `submit`, **and** found by the sweep a moment later — and it ran
     twice. The window is not contrived: nothing on any of the three runtimes orders serving after the
     `ServiceGroup` starts, so a route is reachable before its own service has begun. The unit suite caught
     it on the first run, from the store's write log; from outside, a job run twice is indistinguishable
     from one run once — same terminal state, same summary.

     Fixed where a real queue fixes it, at the claim: `process` re-reads the record and skips it if it has
     already reached a terminal state. That works because the loop is serial — the second delivery cannot
     be claimed until the first has written its outcome. A record left `running` is deliberately *not*
     skipped, since that is the sweep's other case and re-running it is the contract working rather than
     the duplicate. `aJobSubmittedBeforeTheSweepIsNotRunTwice` pins it and fails without the fix.
   - **So the contract is at-least-once, and says so.** A job whose process died after the work but before
     the write is run again. That is the right default — the alternative is at-most-once, which drops work
     — and it is why `running` is a state rather than decoration: it is what a later sweep reads to tell
     "never started" from "started and lost". Distinguishing a *duplicate* from a *retry* without that
     would need a lease or an owner token, which is a real job queue's answer and more than this example
     should grow.
   - **`@BindType` cannot reach a background service, and `@Replaces` can.** `@BindType` sources its
     instance from a `doubles` value threaded into a scope at entry, so it reaches a binding built (or
     rebuilt, via `@TestScopable`) per request. `JobWorker` is app-scoped by necessity — the group runs one
     instance for the process's lifetime — and reads its store outside any request, since the sweep happens
     before a request has ever arrived. There is no request to hang a double off. So the mocked suite
     supersedes the CouchDB store with an `@Replaces` in-memory one, which is the first `@Replaces` in this
     repository, and the suite stays Docker-free. The general rule: **a background service's collaborators
     are `@Replaces` territory, not `@BindType` territory** — and the practical cost is that such a suite
     asserts on behaviour through the routes rather than on interactions through `verify`, which is the
     right level for a worker anyway.
   - **`submit` awaits its write, and that is the whole meaning of the `202`.** An enqueue that only put
     the job on the handoff would answer faster and promise less: the id would have to be minted in the
     process, `GET /jobs/{id}` could `404` for a job just accepted, and a crash between the yield and the
     worker's write would lose a job the caller was told was accepted — leaving the store a log of what the
     worker did rather than a record of what was accepted, with nothing for the sweep to find. All three
     runtime suites assert the durable version from outside, by re-reading the record immediately after the
     `202` and requiring `200`. They deliberately say nothing about *which* state comes back: asserting
     `queued` would be asserting that the worker had not got to it yet, which is a race.
   - **Vapor was discarding the collated services**, and had been since the collation existed. `configure`
     called `apply` for its side effect and dropped the return value, which cost nothing while that runtime
     bound no service — the manifest comment even said so. Vapor 4 has no ServiceLifecycle integration at
     all; nothing in it names `Service`, unlike Hummingbird's `Application(services:)` and unlike the
     generated `@main`. The app now supplies the group itself in a `WireGraphServices: LifecycleHandler`,
     registered **after** `WireGraphTeardown` (Vapor runs shutdown handlers in reverse, and the other order
     disconnects MongoDB out from under a service still draining) and implementing the **synchronous**
     `didBoot`, because `app.testing()` boots through the non-async `boot()` which calls only the sync
     variants. Measured, not reasoned: substituting `didBootAsync` leaves the `202` intact and the job
     never runs.
   - **Draining is why the worker is a `Service` rather than a `Task`.** `run()` wraps its loop in
     `withGracefulShutdownHandler` and the handler *finishes* the handoff instead of cancelling: new
     submissions are refused with `503`, everything already accepted still runs, and the group waits for
     `run()` to return. The one-line alternative, `cancelOnGracefulShutdown()`, means the opposite — it
     abandons the job in hand and the whole backlog behind it. Also measured: substituting it fails
     `gracefulShutdownDrainsWhatWasAlreadyAccepted` on 37–41 of the fifty accepted jobs across three runs,
     a range rather than a number because it is a race.
   - **A failure after acceptance is a record, not a status.** By the time the work throws, the caller's
     `202` has been written and the connection is gone, so `@ErrorResponse` cannot reach it however it is
     declared; `GET /jobs/{id}` answers `200` carrying `failed`. That asymmetry is why the two validation
     checks are deliberately split: `submit` refuses empty text at the boundary in constant time and before
     an id exists, while text that contains no *words* is only discovered by tokenising, which is the job.
     Every queue's boundary validation is the shallow half by construction.

   **The three stores are not interchangeable, and the differences are the interesting part of doing it
   three times.** Ids: Valkey's come from `INCR`, which is atomic across clients and is therefore the only
   one of the three where the *store* genuinely issues them; CouchDB and MongoDB use UUIDs, because neither
   has a server-side sequence and a counter held in a process is the assumption a durable store exists to
   remove. Updates: Mongo and Valkey write a whole record in one round trip, CouchDB needs two, since it
   rejects a `PUT` without the document's current `_rev` — document-level MVCC, paid for per write. And the
   sweep: Mongo *queries* for the unfinished states server-side, Valkey walks its index, and CouchDB scans
   `_all_docs` and filters client-side, where the real answer is a view emitting on `state`. Each is called
   out where it lands, so the example does not read as though one shape fits all three.

   Two smaller things, neither specific to the store. `services: .run` is not a `.wiremvc(…)` suite's
   default and should not be — starting a graph's services to test a `@Get` would start a database client —
   and the failure mode is worth knowing: with services skipped the `202` still comes back and the job
   stays `queued` forever, which is precisely what a deployment that never handed `apply`'s services to a
   group looks like, so a test asserting only on the `202` asserts nothing. And
   `ServiceGroup.triggerGracefulShutdown()` on a group still in `.initial` transitions it straight to
   `.finished`, after which the pending `run()` throws `alreadyFinished`; the unit tests therefore run a
   probe job to completion before triggering, which is proof the group reached `.running` and that the
   worker's loop is iterating.

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
