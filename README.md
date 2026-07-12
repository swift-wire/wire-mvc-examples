# wire-mvc-examples

Cross-runtime examples for [WireMVC](https://github.com/tachyonics/wire-mvc). The point of the
repo *is* the layout: one framework-free package of controllers, and a separate package per
runtime that assembles the **same** controller source onto a different HTTP stack.

```
Controllers/            # framework-free @Controller types, proposal-native (WireMVC + Wire, Swift 6.4)
ControllersLegacy/      # the same controllers, ServerTransport-era — for Hummingbird/Vapor (Swift 6.3)
HummingbirdExample/     # Hummingbird runtime (Swift 6.3, ServerTransport) — path dep on ../ControllersLegacy
VaporExample/           # Vapor runtime       (Swift 6.3, ServerTransport) — path dep on ../ControllersLegacy
SwiftHttpServerExample/ # swift-http-api-proposal runtime (Swift 6.4) — path dep on ../Controllers
```

WireMVC's core is now proposal-native (it dispatches over `swift-http-api-proposal`'s `HTTPServer`,
which raises a **Swift 6.4** floor), so the runtimes currently split in two: the ServerTransport-era
Hummingbird + Vapor examples stay on Swift 6.3 against `ControllersLegacy`, and the proposal runtime
(`SwiftHttpServerExample`) runs on Swift 6.4 against the new `Controllers`. Hummingbird/Vapor migrate
to proposal-native (via a ServerTransport-compatibility adapter) later.

Each runtime is its **own Swift package** so their dependency trees stay isolated (Hummingbird's vs
Vapor's swift-nio pins, and the proposal's Swift-6.4 floor can't contaminate the 6.3 runtimes). The
controllers are pulled in by a **path dependency**, so each runtime compiles the *identical*
controller source — that's what makes it a genuine cross-runtime proof rather than a re-implementation.

## What each example demonstrates

- **Cross-runtime portability.** The controllers (`@Singleton @Controller` todos CRUD) are
  byte-identical across every executable — the source in `Controllers/` and `ControllersLegacy/` is
  the same, differing only in which WireMVC it targets. Only the *assembly* differs: each app builds
  its runtime's router and `WireMVC.apply(graph, to: &router)` registers the collated routes onto it
  — a `some ServerTransport` for Hummingbird/Vapor, a `some RoutableHTTPServerBuilder` (a trie router)
  for the proposal runtime. WireMVC stays router/transport-agnostic.
- **Coexistence.** The ServerTransport runtimes also register a *native* route the framework's own
  way (`/health`), on the same router — WireMVC registers *onto* the app's transport, it doesn't own
  the router (collation, not registration).
- **Cross-module DI.** `TodosController` depends on a `TodoRepository` protocol declared in
  `Controllers` but *not* satisfied there; each runtime binds its own
  `@Singleton(as: TodoRepository.self)` backend. So each graph proves a library declares a need
  and the app satisfies it across a package boundary. (`Hummingbird` → an embedded SQLite
  database via GRDB; other runtimes → other backends.)
- **The persistence axis collapses to one binding.** The six `hummingbird-examples/todos-*`
  differ mainly in their database (DynamoDB / Fluent / Postgres / …). Here that's a single
  `@Singleton(as: TodoRepository.self)` swap — the heavyweight backends are absent only because
  they need external infra, not because they'd change a line of the controller.

## Running

Each package is standalone; run its executable from its directory:

```
cd HummingbirdExample && swift run HummingbirdExample
```

It self-tests every route in-process (via `HummingbirdTesting`) and prints `OK` or exits
non-zero. Validated on macOS and Linux (see CI).

## Status

- **Hummingbird** — current (Swift 6.3, `ServerTransport` via `swift-openapi-hummingbird`, SQLite/GRDB
  backend). On `ControllersLegacy` until it migrates to proposal-native WireMVC.
- **Vapor** — planned (Swift 6.3, `ServerTransport` via `swift-openapi-vapor`, Postgres backend). On
  `ControllersLegacy`.
- **SwiftHttpServerExample** (proposal) — current (Swift 6.4). Serves the controllers directly over
  `swift-http-api-proposal`'s `HTTPServer` (swift-server's `NIOHTTPServer`): `@Controller`'s generated
  witnesses register onto a trie `RoutableHTTPServerBuilder`, which freezes into the server's request
  handler, with an in-memory `TodoRepository` backend.
