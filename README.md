# wire-mvc-examples

Cross-runtime examples for [WireMVC](https://github.com/tachyonics/wire-mvc). The point of the
repo *is* the layout: one framework-free package of controllers, and a separate package per
runtime that assembles the **same** controller source onto a different HTTP stack.

```
Controllers/         # framework-free @Controller types (depends only on WireMVC + Wire)
HummingbirdExample/  # Hummingbird runtime  — path dep on ../Controllers
VaporExample/        # Vapor runtime        — (planned)
ProposalExample/     # swift-http-api-proposal + a cross-runtime router — (planned, needs Swift 6.4)
```

Each runtime is its **own Swift package** so their dependency trees stay isolated (Hummingbird's
vs Vapor's swift-nio pins, and the proposal's Swift-6.4 floor can't contaminate the others). The
shared `Controllers` package is pulled in by a **path dependency**, so every runtime compiles the
*identical* controller source — that's what makes it a genuine cross-runtime proof rather than a
re-implementation.

## What each example demonstrates

- **Cross-runtime portability.** The controllers in `Controllers/` (`@Singleton @Controller`
  todos CRUD) are byte-identical across every executable. Only the *assembly* differs: each
  `main` builds its runtime's router, and `WireMVC.apply(graph, to: router)` registers the
  collated routes onto it (a `ServerTransport`).
- **Coexistence.** Each runtime also registers a *native* route the framework's own way
  (`/health`), on the same router — WireMVC registers *onto* the app's transport, it doesn't own
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

- **Hummingbird** — current.
- **Vapor** — planned (Vapor's `ServerTransport` via `swift-openapi-vapor`, a different backend).
- **Proposal** — planned; gated on a Swift 6.4 toolchain (the successor-bridge spike: a
  `ServerTransport` over `swift-http-api-proposal`'s `HTTPServer`).
