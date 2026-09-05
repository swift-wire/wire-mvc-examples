# wire-mvc-examples

Cross-runtime examples for [WireMVC](https://github.com/swift-wire/wire-mvc). The point of the
repo *is* the layout: one framework-free package of controllers, and a separate package per
runtime that assembles the **same** controller source onto a different HTTP stack.

## The packages

| Package | What it is |
|---|---|
| `Controllers/` | The shared, framework-free `@Controller` types — todos CRUD, `/me`, `/documents`, `/jobs`, multipart. WireMVC + Wire and nothing else. |
| `OpenAPISpec/` | The same todos API, authored from an OpenAPI document instead (`@OpenAPIController`). |
| `HTMLForm/` | An Elementary view and a `@FormBody` round trip — `GET`/`POST /contact`. |
| `YAMLConfig/` | Both halves of a codec declared outside the framework: `@YAMLBody` + `@YAMLResponse`. |
| `HummingbirdExample/` | The Hummingbird runtime. Todos in Valkey. |
| `VaporExample/` | The Vapor runtime. Todos in MongoDB. |
| `SwiftHttpServerExample/` | The proposal-native runtime. Todos in CouchDB, plus the global middleware tier and the mocked test suite. |

Each runtime is its **own Swift package**, so their dependency trees stay isolated (Hummingbird's
swift-nio pins against Vapor's). The controllers arrive by a **path dependency**, so every runtime
compiles the *identical* source — which is what makes this a cross-runtime proof rather than three
re-implementations.

The three runtimes reach WireMVC two ways. `SwiftHttpServerExample` serves the controllers
directly on a `swift-http-api-proposal` server; Hummingbird and Vapor serve the same controllers
on their own `Router` through the **`WireMVCServerTransport`** adapter. All seven packages are
Swift 6.4, which WireMVC's proposal-native core requires.

## What you can see here

Every runtime serves all of it unless the row says otherwise.

| | Where to look |
|---|---|
| Both authoring styles on one routing model | `/todos` and `/api/todos`, sharing one `TodoRepository` |
| A document's assertions enforced, not just its types | `OpenAPISpec` — `minLength` and friends become generated checks |
| The full annotation surface, including raw streaming | `GET /todos/stream`, a `@RawRoute` writing SSE itself |
| Middleware as a chain, controller- and route-scope | `TodosController`, and the API-key gate on `DELETE` |
| A global tier that answers over the fallback | `SwiftHttpServerExample` — CORS and `/static/` (native runtime only) |
| Error mapping shared across both authoring styles | `TodoNotFound` → `404`, from a `@Get` route and an operation alike |
| Request-scoped controllers, auth as scope construction | `/me` — a binding that throws at scope entry becomes a `401` |
| Authorization as a set of bindings, not a middleware | `/documents` — seven policies in one `CollectedKey`, ABAC |
| Multipart in and out, neither in the framework | `POST /upload` and `GET /export` |
| Acting on a body before it has arrived | `POST /upload/stream` — refuses mid-flight without reading the file |
| A sender-transforming middleware | `GET /export` — the handler binds its sender by role |
| A response mode declared outside the framework | `YAMLConfig` — `PUT /config` round trip |
| A request binding declared outside the framework | `@FormBody`, with `@HTMLResponse` as its other half |
| Coexisting with the host's own routes | `/health`, registered the framework's way (Hummingbird, Vapor) |
| Cross-module DI, and the persistence axis as one binding | `TodoRepository` — Valkey, MongoDB, CouchDB |
| Services, and work that outlives the request | `POST /jobs` — a `@BackgroundService` the route talks to |
| A mocked suite with no database | `SwiftHttpServerExample` — a `TestingKey` variant graph and smockable |

The reasoning behind each — why the arrangement is what it is, and what it rules out — is in
[Documentation/Notes/WhatTheExamplesShow.md](Documentation/Notes/WhatTheExamplesShow.md).

## Where the runtimes diverge

The identical controller source is the claim; identical *behaviour* is not, and the differences
are measured here rather than assumed. Each runtime's suite pins what its host's router does with
a wrong method and with a percent-escaped path parameter — see `MethodMismatchTests` and
`PathParameterDecodingTests` in each of the three.

The short version: Hummingbird and Vapor answer `404` where the native router answers `405`,
Hummingbird does not percent-decode path parameters, and a **catch-all route serves on the native
runtime only** — which is why `SwiftHttpServerExample` owns `AssetsController` rather than
`Controllers` doing so. The full matrix, and which differences are convention rather than
capability, is in
[wire-mvc's documentation](https://github.com/swift-wire/wire-mvc#what-differs-by-runtime).

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

## Licence

Apache-2.0. See [LICENSE](LICENSE).

**These samples are meant to be copied.** You may take this code into your own projects without
attribution and without reproducing the licence header. The Apache-2.0 terms cover the repository as
a whole; they are not intended to attach to a handful of lines lifted to get something started.
