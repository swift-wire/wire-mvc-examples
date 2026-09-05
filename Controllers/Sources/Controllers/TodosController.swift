// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import BasicContainers
import HTTPAPIs
import HTTPTypes
public import Wire
public import WireMVC

/// The portable todos controller — identical across every runtime executable. It depends only
/// on the `TodoRepository` protocol and WireMVC's declarative annotations; nothing
/// framework-specific. The repository is a **lifted generic parameter** (Wire's opaque-injection
/// shape — `some TodoRepository` on a stored property can't be assigned), resolved to whatever
/// backend the executable binds via `@Singleton(as: TodoRepository.self)`.
///
/// `@Singleton @Controller` makes it a graph binding whose routes `WireMVC.apply` registers onto a
/// `HTTPServerRouteBuilder` (the runtime's router).
@TestScopable  // app-scoped, but rebuilt per-request under a keyed suite so `/todos` is mock-testable
@Singleton
@Controller("/todos")
@Middleware(ControllerMiddleware.responseDefaults)  // controller-scope: .set + .setIfAbsent
@Middleware(ControllerMiddleware.logRequests)  // controller-scope: every route
@Middleware(ControllerMiddleware.audit)  // controller-scope, generic-with-deps, non-canonical parameter order
@ErrorResponse(TodoNotFound.self, .notFound)  // handler throw (use-case-2) → 404, not the baseline 500
public struct TodosController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    /// `@Query completed` filters and the `x-limit` `@Header` caps the count — both optional (via
    /// Swift-native defaults) and both `LosslessStringConvertible`-converted, so a bare `GET /todos`
    /// still returns everything.
    /// Returns its own `Cache-Control`, which the controller's `.setIfAbsent` default then defers to — the
    /// point of that verb. Every sibling route, saying nothing, gets `no-store` instead.
    @Get
    @JSONResponse
    public func list(
        @Query completed: Bool? = nil,
        @Header("x-limit") limit: Int? = nil
    ) async throws -> (headers: HTTPFields, body: [Todo]) {
        var todos = try await repository.all()
        if let completed { todos = todos.filter { $0.completed == completed } }
        if let limit { todos = Array(todos.prefix(limit)) }
        return ([.cacheControl: "no-cache"], todos)
    }

    @Get("/{id}")
    @JSONResponse
    public func get(@Path id: String) async throws -> Todo {
        guard let todo = try await repository.find(id: id) else { throw TodoNotFound() }
        return todo
    }

    /// `201 Created` with a `Location` naming what was created — the canonical answer to a POST that
    /// creates, and the reason a route needs to compute a header field rather than only declare one.
    ///
    /// The returned tuple names `headers` but not `status`, so `@JSONResponse(status: .created)` still owns
    /// the status: the annotation is the declared answer, and the tuple supplies only what the handler has
    /// to compute. Naming `status` here too would be rejected — the annotation's argument would then be
    /// dead, and the codegen refuses to let it silently be.
    @Post
    @JSONResponse(status: .created)
    public func create(@JSONBody input: CreateTodo) async throws -> (headers: HTTPFields, body: Todo) {
        let todo = try await repository.create(input)
        // The prefix is written out rather than derived: `@Controller("/todos")` is compile-time text the
        // handler has no runtime access to, so a route that builds a URL to itself restates it. Worth
        // knowing before someone reaches for a helper that does not exist.
        return ([.location: "/todos/\(todo.id)"], todo)
    }

    @Patch("/{id}")
    @JSONResponse
    public func edit(@Path id: String, @JSONBody input: EditTodo) async throws -> Todo {
        guard let todo = try await repository.update(id: id, with: input) else { throw TodoNotFound() }
        return todo
    }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    @Middleware(RouteMiddleware.requireAPIKey)  // route-scope gate — generic-with-deps, factory-lifted by key
    public func delete(@Path id: String) async throws {
        try await repository.delete(id: id)
    }

    /// A streaming route on the **producer tier** (`@EventStreamResponse`): the handler returns the
    /// events and `ServerSentEventProducer` writes them, one chunk each, as `text/event-stream`.
    ///
    /// This was a `@RawRoute` — the handler took the response sender verbatim, built the head, framed
    /// each event inline and terminated the body itself. Everything there except the framing is what the
    /// tier already does, and the framing is what a codec is. What the move buys: the status and the
    /// content type come from the annotation and the producer rather than from hand-built `HTTPFields`;
    /// `@ErrorResponse` covers the route up to the first byte, so a repository failure becomes a status
    /// instead of an empty 200 with a truncated body; the generated typed client gets a method; and the
    /// handler stops being generic over the router's sender type.
    ///
    /// What it does not buy is mapping *after* the first byte — inherent to streaming, and unchanged
    /// from the raw version, which had the same exposure without stating it.
    ///
    /// `/todos/stream` is a literal, so the router matches it here rather than `/todos/{id}`.
    @Get("/stream")
    @EventStreamResponse
    public func stream() async throws -> [ServerSentEvent] {
        try await repository.all().map { ServerSentEvent(data: $0.id) }
    }
}
