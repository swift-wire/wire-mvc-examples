// Wire-aware opt-in marker. Its presence tells a consuming target's build plugin to re-parse this
// module's sources — so a same-package test target that depends on this app can re-compose its graph
// (the `@WireMVCBootstrap` root, the `@Singleton(as:)` CouchDB backends, and the `@Provides` bindings)
// and supersede a binding with `@Replaces`, or thread per-request doubles through a `TestingKey`.
// Presence-only.
