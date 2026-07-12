# wire-mvc-examples

Cross-runtime examples for [WireMVC](https://github.com/tachyonics/wire-mvc). The point of the
repo *is* the layout: one framework-free package of controllers, and a separate package per
runtime that assembles the **same** controller source onto a different HTTP stack.

```
Controllers/            # framework-free @Controller types, proposal-native (WireMVC + Wire, Swift 6.4)
HummingbirdExample/     # Hummingbird runtime (Swift 6.4) — proposal-native via WireMVCServerTransport, ../Controllers
VaporExample/           # Vapor runtime       (Swift 6.4) — proposal-native via WireMVCServerTransport, ../Controllers
SwiftHttpServerExample/ # swift-http-api-proposal runtime (Swift 6.4) — path dep on ../Controllers
```

WireMVC's core is proposal-native (it dispatches over `swift-http-api-proposal`'s `HTTPServer`, which
raises a **Swift 6.4** floor). The runtimes reach it two ways: `SwiftHttpServerExample` serves the
controllers *directly* on a proposal server, while `HummingbirdExample` and `VaporExample` serve the
same proposal-native controllers on their framework's `Router` via the **`WireMVCServerTransport`**
adapter (the wire-mvc `ServerTransport` trait, enabled in their manifests). All four packages are
Swift 6.4, against the one `Controllers` package.

Each runtime is its **own Swift package** so their dependency trees stay isolated (Hummingbird's vs
Vapor's swift-nio pins). The
controllers are pulled in by a **path dependency**, so each runtime compiles the *identical*
controller source — that's what makes it a genuine cross-runtime proof rather than a re-implementation.

## What each example demonstrates

- **Cross-runtime portability.** The controllers (`@Singleton @Controller` todos CRUD) in
  `Controllers/` are byte-identical across every executable. Only the *assembly* differs: each app
  builds its runtime's router and registers the collated routes onto it — `WireMVCServerTransport.apply`
  onto a `some ServerTransport` for Hummingbird/Vapor, `WireMVC.apply` onto a `some
  RoutableHTTPServerBuilder` (a trie router) for the proposal runtime. WireMVC stays
  router/transport-agnostic.
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

Route verification lives in each package's test target, which drives the full CRUD lifecycle against a
throwaway backend container it provisions via swift-local-containers — so `swift test` needs a
container runtime (Docker); the suites skip themselves when none is available. Validated on macOS and
Linux (see CI).

## Status

- **Hummingbird** — current, proposal-native (Swift 6.4, real Valkey via swift-local-containers). Serves
  the proposal-native `Controllers` on Hummingbird's `Router` via the `WireMVCServerTransport` adapter
  (the wire-mvc `ServerTransport` trait, `swift-openapi-hummingbird` providing the `Router:
  ServerTransport` conformance). Todos are stored in Valkey — a key-value store (each todo a JSON
  string, insertion order in a list, ids from `INCR`) — reached with the `valkey-swift` client. The
  client is a `ServiceLifecycle.Service`: it's `@Contributes(to: WireMVCKeys.services)`, so WireMVC
  collates it into the graph's services and `Application(services:)` runs its connection pool alongside
  the server. The integration test provisions a throwaway Valkey container and drives the routes via
  HummingbirdTesting's `.live` mode (which runs the app's ServiceGroup).
- **Vapor** — current, proposal-native (Swift 6.4, real MongoDB via swift-local-containers). Serves the
  proposal-native `Controllers` on Vapor's transport via the `WireMVCServerTransport` adapter
  (`swift-openapi-vapor` providing `VaporTransport: ServerTransport`); todos are stored in MongoDB
  (MongoKitten, a document store — distinct from Hummingbird's embedded SQL), and the integration test
  provisions a throwaway Mongo container and disconnects it on shutdown via the graph's `@Teardown`.
- **SwiftHttpServerExample** (proposal) — current (Swift 6.4, real CouchDB via swift-local-containers).
  Serves the controllers directly over `swift-http-api-proposal`'s `HTTPServer` (swift-server's
  `NIOHTTPServer`): `@Controller`'s generated witnesses register onto a trie `RoutableHTTPServerBuilder`,
  which freezes into the server's request handler. Todos are stored in CouchDB — a document store with a
  pure HTTP/JSON API — reached with the *proposal's own* `HTTPClient` (the async-http-client backend), so
  this runtime exercises the proposal on both ends: serving on its server and calling out through its
  client. The integration test provisions a throwaway CouchDB container.
