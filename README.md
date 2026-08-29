# wire-mvc-examples

Cross-runtime examples for [WireMVC](https://github.com/tachyonics/wire-mvc). The point of the
repo *is* the layout: one framework-free package of controllers, and a separate package per
runtime that assembles the **same** controller source onto a different HTTP stack.

```
Controllers/            # framework-free @Controller types, proposal-native (WireMVC + Wire, Swift 6.4)
HTMLForm/               # the html-form example: an Elementary view + a @FormBody round trip
YAMLConfig/             # both ends of the extension point around one codec: @YAMLBody + @YAMLResponse
OpenAPISpec/            # the same todos API, authored from an OpenAPI document (@OpenAPIController)
HummingbirdExample/     # Hummingbird runtime (Swift 6.4) — proposal-native via WireMVCServerTransport, both
VaporExample/           # Vapor runtime       (Swift 6.4) — proposal-native via WireMVCServerTransport, both
SwiftHttpServerExample/ # swift-http-api-proposal runtime (Swift 6.4) — path dep on both
```

WireMVC's core is proposal-native (it dispatches over `swift-http-api-proposal`'s `HTTPServer`, which
raises a **Swift 6.4** floor). The runtimes reach it two ways: `SwiftHttpServerExample` serves the
controllers *directly* on a proposal server, while `HummingbirdExample` and `VaporExample` serve the
same proposal-native controllers on their framework's `Router` via the **`WireMVCServerTransport`**
adapter (the wire-mvc `ServerTransport` trait, enabled in their manifests). All seven packages are
Swift 6.4, against the one `Controllers` package.

`OpenAPISpec` runs swift-openapi-generator with `accessModifier: public`, so its generated types cross
the package boundary into each runtime — the arrangement a shared document needs, and the reason a bare
`@OpenAPIController` resolves against the module it is *declared* in rather than the one compiling it.

Each runtime is its **own Swift package** so their dependency trees stay isolated (Hummingbird's vs
Vapor's swift-nio pins). The
controllers are pulled in by a **path dependency**, so each runtime compiles the *identical*
controller source — that's what makes it a genuine cross-runtime proof rather than a re-implementation.
The same goes for `OpenAPISpec`: one document, one `@OpenAPIController`, three runtimes.

## Where the runtimes diverge

The identical controller source is the claim; identical *behaviour* is not, and the differences are
measured here rather than assumed. Each runtime's suite pins what its host's router does with a wrong
method and with a percent-escaped path parameter — see `MethodMismatchTests` and
`PathParameterDecodingTests` in each of the three.

The matrix, with what is convention and what is a capability gap, is in
[wire-mvc's README](https://github.com/tachyonics/wire-mvc#what-differs-by-runtime). The short version:
Hummingbird and Vapor answer `404` where the native router answers `405`, Hummingbird does not
percent-decode path parameters, and a **catch-all route serves on the native runtime only** — which is why
`SwiftHttpServerExample` owns `AssetsController` instead of `Controllers` doing so. A catch-all controller
in the shared package would break the other two executables at startup.

## What each example demonstrates

- **Both authoring styles, one routing model.** Every runtime serves `/todos` from `@Get`/`@Post`
  controllers *and* `/api/todos` from an OpenAPI document, on the same router, from the **same
  `TodoRepository` binding** — so an operation reads what a `@Post` route wrote, and a todo created
  through the document is read back through the annotation-driven route. Each suite asserts exactly
  that. Nothing in any app's assembly mentions OpenAPI: `apply` already registers every collated
  contributor, because after M6d an operation *is* a WireMVC route. The `/api` prefix comes from the
  document's `servers:` block, not from the app.

  Two consequences worth copying. The executables use the **decomposed three-plugin form**
  (`WireBuildPlugin` + `WireMVCRouteGenPlugin` + `WireOpenAPIGenPlugin`) rather than the bundled
  `WireMVCBuildPlugin`, which runs WireGen and WireMVC's route codegen together and would silently
  leave the second adapter's witnesses ungenerated. And `OpenAPISpec` is a **sibling** of `Controllers`
  rather than part of it: it depends on a code generator (on a fork, pinned to a revision until upstream
  takes the access-modifier change), and `Controllers` stays lean — WireMVC + Wire and nothing else — so
  a runtime can take the controllers without inheriting any of that.
- **The document enforced, not just translated.** swift-openapi-generator turns a schema's *structure*
  into types and drops every *assertion* — `minLength`, `pattern`, `maxItems` — so a document can say
  `minLength: 1` and nothing check it. `OpenAPISpec` now declares assertions and WireOpenAPI generates
  the checks, before the handler is entered. Nothing in `TodosOperations` checks a title.

  Three answers, and which one you get is the document's decision rather than a handler's. A **body**
  violation is 422 and a **parameter** violation is 400 — the split `WireMVCBindingError` already draws
  for a `@Get` route, so both authoring styles answer alike. A body the *deserializer* refused outright
  (`title` missing, so the forwarder is never entered) arrives as the same error as one a generated
  check refused, which is why `createTodo` needs only one `@ErrorResponse` to cover both; unmapped, it
  would answer 422 naming the field rather than a bare 400 with no body.

  `wire-openapi.yaml` beside the document turns on **response** validation, which is off by default —
  a contract-violating 200 becoming a 500 is a runtime behaviour change worth asking for. It is a file
  of the adapter's rather than a key in `openapi-generator-config.yaml`, because that config rejects
  unknown keys outright. `Todo` is only ever a response here, so its bounds are checked only because
  this document opted in; `CreateTodo` is only ever a request. The two sides are separate errors on
  purpose — a bad request is the caller's fault and says which field, a bad response is the service's
  and says nothing, because the caller can do nothing about it.
- **Cross-runtime portability.** The controllers (`@Singleton @Controller` todos CRUD) in
  `Controllers/` are byte-identical across every executable. Only the *assembly* differs: each app
  builds its runtime's router and registers the collated routes onto it — `WireMVCServerTransport.apply`
  onto a `some ServerTransport` for Hummingbird/Vapor, `WireMVC.apply` onto a `some
  HTTPServerRouteBuilder` (a trie router) for the proposal runtime. WireMVC stays
  router/transport-agnostic.
- **The full annotation surface, including raw streaming.** The shared controller exercises the typed
  surface — `@Path`/`@Query`/`@JSONBody`/`@Header`, `@JSONResponse`/`@ResponseStatus` — plus one
  **`@RawRoute`** route (`GET /todos/stream`) that is handed the response sender verbatim and writes
  server-sent events itself (no decode/encode). It streams natively on the proposal server and through
  the `WireMVCServerTransport` bridge on Hummingbird and Vapor, so the raw/streaming path is exercised
  on every runtime.
- **Middleware, as a chain.** The shared controller carries two controller-scope entries —
  **`@Middleware(ControllerMiddleware.logRequests)`** (observability, on every route) and
  **`@Middleware(ControllerMiddleware.audit)`** (generic-with-deps, declared with a non-canonical
  parameter order) — and a route-scope **`@Middleware(RouteMiddleware.requireAPIKey)`** gate on
  `DELETE /todos/{id}`. They name **`FactoryKey`s**, not types: a middleware generic over the box roles
  is lifted by key through `@MiddlewareFactory`, which is what lets one component serve every runtime's
  differently-shaped box. Without an `x-api-key` header the gate *handles the request itself* — writes a
  401, and the route handler is skipped — while the controller-scope middleware still runs (every
  middleware runs; the "decision" is state carried in the box, not a control-flow short-circuit).
- **The global tier, and a middleware that answers over the fallback.** `SwiftHttpServerExample`'s
  composition root carries two `@Middleware` entries that wrap *every* request — matched routes and the
  `@NotFound` fallback alike, because the generated `@main` folds them around the finalized router.
  `CORSMiddleware` *contributes* header fields and answers only preflights; `ServeStaticFiles` answers
  `GET`/`HEAD` under `/static/` itself, from outside the router, for paths no route is registered at — and
  **declines** everything else, so the app's authored `@NotFound` gets its turn. Two properties fall out and
  are pinned by `StaticFileServingTests`: the middleware must be prefix-scoped, because the front layer runs
  before the router and cannot ask whether a route would have matched; and it must answer via
  `respondingWith` rather than raw `responding`, or CORS's contributed fields are dropped on exactly the
  responses a browser fetches most. Native-runtime only — Hummingbird and Vapor mount onto the host's own
  `Application`, so there is no generated `@main`, no global tier, and the host's file middleware holds this
  position instead.
- **Error mapping, one model across both authoring styles.** `TodosController` declares
  `@ErrorResponse(TodoNotFound.self, .notFound)`, so a handler *throw* becomes a 404 rather than the
  baseline 500 — and `TodosOperations` maps the same domain error at operation scope, where the document
  declares a `Problem` body for its 404 and so forces the body-providing form. Same error type, same
  vocabulary, two route kinds.
- **Request-scoped controllers, and authentication as scope construction.**
  `@Scoped(seed: HTTPRequest.self) @Controller("/me")` is built fresh per request from the request that
  opened the scope, alongside the app-`@Singleton` `TodosController` in one graph. Its request-scoped
  `Session` *throws* `Unauthenticated` at scope entry when the request carries no session cookie, and
  `@ErrorResponse(Unauthenticated.self, .unauthorized)` maps that to 401 — no gate, no double-read, no
  sentinel. A binding that fails to build maps exactly like a handler throw — and authorization does not
  use a gate either, so the only gate left in the repository is the API-key toy above, which is there to
  be contrasted with. The token→session-id mapping lives in each runtime's own database behind a
  `SessionManager` binding, so the same token yields the same identity across requests.
- **Authorization as a set of bindings, not as where you put the annotation.** `/documents` is governed by
  attribute-based access control: seven rules, each an ordinary `@Singleton` contributed to one
  `CollectedKey<any AccessPolicy>`, combined by a `PolicyEngine` that knows none of them individually
  (deny-overrides, then permit-required). Adding a rule to the app is adding a `@Contributes` annotation —
  there is no registry to edit and no route to change. A role is an *attribute* rather than a permission,
  which is what makes the model ABAC rather than RBAC: `AdministratorGrant` permits every action, and an
  administrator is still refused a document above her clearance, because a grant is not an override.

  **The decision does not fit in one tier**, and that is structural. A route-scope middleware is handed the
  request and the route it is folded onto, but not a request-scoped binding — a `@Factory` template
  resolves its dependencies once into an app `@Singleton`, and the fold is entered before the scope is.
  Above all it is not handed the **resource**, which has not been loaded. So the set is consulted twice —
  once for the rules that need no resource (a suspended account, a mutation from the external network
  zone), once with the document in hand — and **both calls happen in the same place**: the binding that
  produces the route's argument.

  **The decision is an argument, not a line in a handler.** `GET`, `PATCH` and `DELETE` on
  `/documents/{id}` take an already-authorised `Document`, bound by `@AuthorizedDocument("read")` — a
  property wrapper naming a request-scoped worker that screens, loads, and authorises while producing it.
  An item route that forgot to authorise used to compile and serve; now it cannot be written, because the
  check is how a `Document` comes into existence. `GET /documents` binds too and *filters* rather than
  refusing, on the same decision function, which is what stops a list from disagreeing with a read.
  `POST /documents` is the one route that still authorises inline, and should: it decides about attributes
  a document does not have yet, so there is nothing to bind.

  A refusal names the rule that produced it, so the suites assert that `ClearanceRule` refused rather than
  that something did. Nothing under `/documents` is bound per runtime, which makes it the one feature here
  that costs a runtime nothing to serve.

  Notably **absent**: a screening middleware. An earlier pass had one, and removing it changed no status on
  any route — the bindings consult the same set. What it bought was a refusal *before* the request scope is
  built, which is worth having under load and is not what a reader should meet first, so
  `DocumentsController` documents it instead of shipping it.

  The same binding also serves `GET /api/documents/{id}`, which is an OpenAPI operation rather than a
  `@Get` route — one wrapper, declared once, used from both authoring styles. Its `403` carries the denial,
  because that operation's document declares a body for it.

- **Multipart, both directions, neither in the framework.** `GET /export` streams `multipart/mixed` **out**
  through a sender-transforming middleware (below); `POST /upload` reads `multipart/form-data` **in** through
  `@MultipartSummary`, a binding on WireMVC's `.readerBody` tier. The upload is parsed a chunk at a time,
  so the handler receives each file's name, size and checksum and never its bytes — peak memory is one chunk
  plus the small fields, whatever the upload's size. It is named for what it hands back rather than what it
  reads: it reads every byte and retains none. The parser is the one piece of pure logic in
  `Controllers` with its own unit suite, driven at **every chunk size**, because a boundary parser that is
  correct on a whole buffer and wrong on a split is the bug that ships.
- **Acting on a body before it has arrived.** `POST /upload/stream` uses the same parser through
  `@MultipartStream`, on the `.bodyStream` tier. **The difference from `@MultipartSummary` is not memory** —
  both are flat — it is *when the handler can act*, and so whether the bytes are read at all. It
  *lends* the handler the parts rather than handing back a finished value. The
  handler pulls, decides on the first field, and — when the answer is no — **never reads the file**:
  `@ErrorResponse` turns that into a 401 while hundreds of kilobytes are still in flight, and the server
  answers with `Connection: close` rather than draining them. No collecting binding can express that at any
  price. The cursor it pulls on is `~Copyable, ~Escapable`, so keeping it past the request is a compile
  error rather than a rule in a comment; the handler signature carries two live compiler limitations, named
  at the route with issue numbers.
- **A sender-transforming middleware.** `GET /export` streams a real `multipart/mixed` response: a
  route-scope middleware wraps the runtime's response sender in a `MultiPartSender<S>`, and the
  `@RawRoute(.responseSender)` handler receives that transformed type — which constraint inference
  cannot name, hence binding by *role*. Parts are written incrementally, one per todo, not buffered.
  Remove the middleware and the handler's parameter type becomes unsatisfiable, so the route is coupled
  to its transform at compile time.
- **A response mode declared outside the framework.** `YAMLConfig` declares `@YAMLResponse` — a macro
  carrying `@ResponseMode(.buffered, codec: "YAMLCodec")` — alongside `@YAMLBody`, so one package supplies
  both halves of a route around one codec and WireMVC names neither. `PUT /config` is the round trip:
  `YAMLBody<Settings>.sendBody` out, `YAMLCodec<Settings>.decodeResponseBody` back, in a single generated
  client method. WireMVC's own `@JSONResponse` and `@HTMLResponse` are declared exactly this way, which is
  the check that the seam is the right shape rather than a bolt-on.
- **Both ends of the framework are extension points.** `@FormBody` (in `Controllers`) is an
  `application/x-www-form-urlencoded` request binding **declared outside WireMVC** — nothing in the
  framework names it. It is an attribute (`@RequestBinding(.body)`, which tells the *generator* to collect
  the body) plus two conformances: `RequestBound` decodes it on the server, `RequestBodySendable` encodes it
  in the generated typed client. `@HTMLResponse` is the response half, streaming an Elementary document
  rather than buffering it. `HTMLForm`'s `/contact` composes the two in one generated client method:
  `submit(draft:) -> String` sends a form body and returns the rendered page.
- **A form, re-rendered.** The `html-form` port (`GET /contact` renders, `POST /contact` validates and
  re-renders with per-field errors and the user's input intact) lives in `HTMLForm`, a sibling package
  rather than part of `Controllers` — for the same reason `OpenAPISpec` is one: it depends on a view
  library, and `Controllers` is deliberately WireMVC + Wire and nothing else. All three runtimes serve it,
  so a streamed HTML response is proven over `WireMVCServerTransport` and not only on a native
  proposal server.
- **Coexistence.** The ServerTransport runtimes also register a *native* route the framework's own
  way (`/health`), on the same router — WireMVC registers *onto* the app's transport, it doesn't own
  the router (collation, not registration).
- **Cross-module DI.** `TodosController` depends on a `TodoRepository` protocol declared in
  `Controllers` but *not* satisfied there; each runtime binds its own
  `@Singleton(as: TodoRepository.self)` backend. So each graph proves a library declares a need
  and the app satisfies it across a package boundary. (`Hummingbird` → a real Valkey key-value
  store, its client run as a graph-hosted service; other runtimes → other backends.)
- **The persistence axis collapses to one binding — three times over.** The six
  `hummingbird-examples/todos-*` differ mainly in their database (DynamoDB / Fluent / Postgres / …). Here
  that's a single `@Singleton(as: TodoRepository.self)` swap, and each runtime demonstrates a *different*
  real backend through that one binding — Valkey (Hummingbird), MongoDB (Vapor), CouchDB (proposal) —
  without changing a line of the controller. `SessionManager` and `JobStore` are the same shape against the
  same three stores: three protocols declared in `Controllers` and satisfied by each app, so a runtime's
  database is named once per protocol and nowhere else.

  The three `JobStore`s are where the stores stop looking interchangeable, and the differences are
  commented where they land. Valkey's ids come from `INCR`, so it is the only one where the store
  genuinely issues them; CouchDB and MongoDB mint UUIDs, having no server-side sequence. A record update
  is one round trip on Valkey and MongoDB and two on CouchDB, which rejects a `PUT` without the current
  `_rev`. And recovering unfinished jobs is a server-side query on MongoDB, an index walk on Valkey, and a
  client-side filter over `_all_docs` on CouchDB, where the real answer is a view.
- **The graph can host services, and work can outlive the request.** A binding that owns a
  `ServiceLifecycle` run loop is contributed to WireMVC's `services` collation; `apply` returns the
  collated `[any Service]`, and the app runs them in its `ServiceGroup` alongside the server. Two kinds of
  binding arrive by that one route: a *backend's* plumbing (the Hummingbird runtime's Valkey client, whose
  connection pool is its run loop) and the application's *own work* — `Controllers`' `JobWorker`.

  The worker is bound `@Singleton(as: JobProcessor.self) @BackgroundService`, so **the route talks to the
  service**. `JobsController` injects `some JobProcessor` and cannot tell that the thing answering its
  `submit` is also running in the app's group; the graph constructs one instance and hands it to both.
  That is the claim: hosting work that outlives the request costs the *route* nothing.

  `POST /jobs` answers `202` with a record that can only say `queued`, and `Location` names where the
  answer will appear. It **awaits the store write before responding**, which is what makes the `202` a
  promise rather than a hope — the record is already durable when the response is written, so the job
  survives the process that accepted it.

  What makes the worker a `Service` rather than a detached `Task` is shutdown, in both directions. `run()`
  wraps its loop in `withGracefulShutdownHandler`, and the handler *finishes* the queue rather than
  cancelling it: new submissions are refused with `503`, everything already accepted still runs, and the
  group does not consider shutdown done until `run()` returns. Before the loop, it **sweeps** — anything a
  previous process left `queued` or `running` is recovered, which makes the contract explicitly
  at-least-once and is why `running` is a state rather than decoration. A detached task has none of this:
  nothing tells it shutdown began, nothing waits for it, and nothing picks up what it dropped.

  Two consequences the routes make visible. A job that **fails after acceptance** is a record, not a
  status: the caller's `202` was written long before, so `@ErrorResponse` cannot reach the failure and
  `GET /jobs/{id}` answers `200` carrying `failed`. And validation splits in two — `POST /jobs` refuses an
  empty body at the boundary (`400`, no id issued), while text that contains no *words* is only discovered
  by doing the work, which is the shape every queue's validation has.

  The runtimes reach the group three different ways, and only one of them is free: the proposal runtime's
  generated `@main` passes the services to `WireMVC.serve`, Hummingbird takes them into
  `Application(services:)`, and **Vapor has no ServiceLifecycle integration at all**, so `configure` builds
  the `ServiceGroup` itself in a `LifecycleHandler`.

## Running

Each package is standalone; run its executable from its directory. Configuration is read through
swift-configuration, which maps each key to an environment variable — the backend's connection
(`VALKEY_HOST`/`VALKEY_PORT` for Hummingbird, `COUCHDB_*`, `MONGO_*`), the bind address
(`SERVER_HOST`/`SERVER_PORT`, proposal runtime), and `LOG_LEVEL`. All have defaults, so this runs against
a real store you provide with nothing else exported:

```
cd HummingbirdExample && swift run HummingbirdExample
```

Route verification lives in each package's test target, which drives the full CRUD lifecycle — both
authoring styles, `/me`, `/export`, `/contact`, `/config`, `/upload`, `/upload/stream`, `/jobs` and
`/wiring` — against a throwaway backend container it provisions
via swift-local-containers. So `swift test` needs a container runtime (Docker); the suites skip
themselves when none is available. Validated on macOS and Linux (see CI).

`SwiftHttpServerExample` carries a **second, Docker-free suite** that is the testing story rather than
the routing one: `@Suite(.wiremvc(key, .inProcess))` bootstraps a **variant graph** for a `TestingKey`,
dropping the mocked eager bindings so no database is reached, and each test supplies its per-request
doubles with smockable. The controllers are annotated `@TestScopable` for it — app-scoped in
production, rebuilt per request under a keyed suite, which is what makes an app-scoped route mockable
per test. It keeps the bundled `WireMVCBuildPlugin`: with no OpenAPI dependency there is nothing for a
second adapter to generate.

## Status

- **Hummingbird** — current, proposal-native (Swift 6.4, real Valkey via swift-local-containers). Serves
  the proposal-native `Controllers` **and `OpenAPISpec`** on Hummingbird's `Router` via the
  `WireMVCServerTransport` adapter
  (the wire-mvc `ServerTransport` trait, `swift-openapi-hummingbird` providing the `Router:
  ServerTransport` conformance). Todos are stored in Valkey — a key-value store (each todo a JSON
  string, insertion order in a list, ids from `INCR`) — reached with the `valkey-swift` client. The
  client is a `ServiceLifecycle.Service`: it's `@Contributes(to: WireMVCKeys.services)`, so WireMVC
  collates it into the graph's services and `Application(services:)` runs its connection pool alongside
  the server. The integration test provisions a throwaway Valkey container and drives the routes via
  HummingbirdTesting's `.live` mode (which runs the app's ServiceGroup).
- **Vapor** — current, proposal-native (Swift 6.4, real MongoDB via swift-local-containers). Serves the
  proposal-native `Controllers` **and `OpenAPISpec`** on Vapor's transport via the
  `WireMVCServerTransport` adapter (`swift-openapi-vapor` providing `VaporTransport: ServerTransport`);
  todos are stored in MongoDB (MongoKitten, a document store — distinct from Hummingbird's key-value
  Valkey), and the integration test
  provisions a throwaway Mongo container and disconnects it on shutdown via the graph's `@Teardown`.
- **SwiftHttpServerExample** (proposal) — current (Swift 6.4, real CouchDB via swift-local-containers).
  Serves the controllers **and the document's operations** directly over `swift-http-api-proposal`'s
  `HTTPServer` (swift-server's `NIOHTTPServer`): the generated witnesses — `@Controller`'s and
  `@OpenAPIController`'s alike — register onto a trie `HTTPServerRouteBuilder`,
  which freezes into the server's request handler. Todos are stored in CouchDB — a document store with a
  pure HTTP/JSON API — reached with the *proposal's own* `HTTPClient` (the async-http-client backend), so
  this runtime exercises the proposal on both ends: serving on its server and calling out through its
  client. The integration test provisions a throwaway CouchDB container.
