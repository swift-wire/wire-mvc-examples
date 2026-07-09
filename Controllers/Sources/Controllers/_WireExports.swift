// Wire-aware opt-in marker. Its presence tells a consuming executable's build plugin to
// re-parse this library's sources — picking up the `@Singleton @Controller` todos controller
// and its `some TodoRepository` dependency — and merge them into that executable's graph.
// Presence-only.
