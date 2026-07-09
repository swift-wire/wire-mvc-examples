import Hummingbird
// Conformance-only import: provides `extension Router: ServerTransport`, which `WireMVC.apply`
// needs but no symbol here names, so the unused_import analyzer can't see it's required.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import WireMVC

// Cross-runtime demo, Hummingbird edition. `Wire.bootstrap()` constructs the SQLite backend and
// injects it into the collated (framework-free) TodosController; we build a Hummingbird router,
// register a native route AND apply the WireMVC controllers onto it — the two coexist — then
// hand the app to `verifyTodos` (Verification.swift) to drive every route in-process.

let graph = try await Wire.bootstrap()

let router = Router()
// A native Hummingbird route, registered the framework's own way — coexists with the
// WireMVC-applied /todos/* on the same router.
router.get("health") { _, _ in "OK" }
// The WireMVC controllers, applied onto the router (a ServerTransport via OpenAPIHummingbird).
try WireMVC.apply(graph, to: router)

let app = Application(router: router)
try await verifyTodos(app)

print(
    "wire-mvc-examples (Hummingbird) OK — the same WireMVC controllers, collated across modules and served on Hummingbird alongside a native route"
)
