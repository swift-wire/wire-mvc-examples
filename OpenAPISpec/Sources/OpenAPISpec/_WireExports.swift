// Wire-aware opt-in marker, exactly as `Controllers` carries one. Its presence tells a consuming
// executable's build plugin to re-parse this library's sources — picking up the `@Singleton
// @OpenAPIController` operations and their `some TodoRepository` dependency — and merge them into that
// executable's graph. Presence-only.
//
// It matters more here than it does for `Controllers`: this package runs *only* the OpenAPI generator,
// so the aggregate proxy for this spec is emitted in the executable, from these sources.
