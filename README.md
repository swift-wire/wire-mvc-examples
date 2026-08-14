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
  sentinel. A binding that fails to build maps exactly like a handler throw; gates are reserved for
  authorization. The token→session-id mapping lives in each runtime's own database behind a
  `SessionManager` binding, so the same token yields the same identity across requests.
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
- **The persistence axis collapses to one binding.** The six `hummingbird-examples/todos-*`
  differ mainly in their database (DynamoDB / Fluent / Postgres / …). Here that's a single
  `@Singleton(as: TodoRepository.self)` swap, and each runtime demonstrates a *different* real
  backend through that one binding — Valkey (Hummingbird), MongoDB (Vapor), CouchDB (proposal) —
  without changing a line of the controller.
- **The graph can host services.** A backend that owns a `ServiceLifecycle` run loop (a client's
  connection pool) is contributed to WireMVC's `services` collation; `apply` returns the collated
  `[any Service]`, and the app runs them in its `ServiceGroup` alongside the server. The Hummingbird
  runtime's Valkey client is bound *and* run this way.

## Running

Each package is standalone; run its executable from its directory (it reads its backend's connection
from the environment — e.g. `VALKEY_HOST`/`VALKEY_PORT` for Hummingbird — against a real store you
provide):

```
cd HummingbirdExample && swift run HummingbirdExample
```

Route verification lives in each package's test target, which drives the full CRUD lifecycle — both
authoring styles, `/me`, `/export`, `/contact`, `/config`, `/upload`, `/upload/stream` and `/wiring` —
against a throwaway backend container it provisions
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
