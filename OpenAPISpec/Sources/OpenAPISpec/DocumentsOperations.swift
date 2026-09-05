// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

public import Controllers
import HTTPTypes
public import Wire
public import WireMVC
public import WireOpenAPI

/// **The authorisation example, from the document side** — and the point of it is that there is almost
/// nothing here.
///
/// `DocumentsController` serves `/documents/{id}` from a `@Get`; this serves `/api/documents/{id}` from
/// the OpenAPI document beside it. Same process, same `DocumentStore`, same `PolicyEngine`, same
/// ``Caller`` — and the same `@AuthorizedDocument` binding, declared once in `Controllers` and used from
/// both. That is the claim worth making concrete: a graph-aware request binding is a *WireMVC* binding,
/// not a route-authoring style's, so an app that adopts one does not have to adopt it twice.
///
/// **Request-scoped**, because the binding is. `@AuthorizedDocument` names `DocumentAuthorizer`, which is
/// `@Scoped(seed: HTTPRequest.self)`, so the worker arrives on *this* type's scope entry — the same
/// mechanism, on a type the document decided the shape of. Nothing below mentions the worker, and nothing
/// below mentions the scope.
///
/// The `401` is the controller's, and it is the same `401` ``DocumentsController`` gets: ``Caller`` fails
/// to construct for a request presenting no known principal, and the mapping answers it. Written at
/// controller scope because that is the only scope a scope-entry failure *can* be written at — one entry
/// serves every operation this type implements, so the refusal is not attributable to any one of them.
///
/// It briefly was not. WireOpenAPI enters the scope in the route terminal, outside the clauses its
/// conformer emits, so this file first shipped with a middleware answering `401` in front of the scope —
/// which meant the app stated authentication twice and the two halves agreed only by both calling
/// ``PrincipalDirectory/principal(presentedBy:)``. The terminal now matches controller-scope mappings
/// against a scope-entry throw, so the workaround is gone and the two halves refuse the same way for the
/// same reason.
///
/// The handler is the whole demonstration: it takes a `Document` and returns it. There is no `id`
/// parameter, no store read and no policy call, because a `Document` that failed either does not exist.
@Scoped(seed: HTTPRequest.self)
// Bare: the document beside this file — the same one `TodosOperations` implements the rest of. Operations
// are mounted individually, so a document is not one type's to serve, and the two collate onto one proxy.
@OpenAPIController
@ErrorResponse(Unauthenticated.self, .unauthorized)  // the scope failed to build — no known principal
public struct DocumentsOperations: Sendable {
    /// Both mappings catch a throw from ``DocumentAuthorizer/bind(name:request:pathParameters:body:)``
    /// rather than from anything written here, and both are answered as responses this operation declares.
    /// The three-argument form for the same reason `getTodo` uses it: the document gives each a body, and
    /// a bare status cannot construct one.
    ///
    /// The `403` is the interesting one. On the annotated route the same `AccessDenied` is answered
    /// bodiless, so the two halves of this app genuinely differ — not because the binding did anything
    /// different, but because one document asked for the denial and the other did not.
    @ErrorResponse(
        AccessDenied.self,
        .forbidden,
        { error in
            Schemas.AccessDenial(policy: error.denial.policy, reason: error.denial.reason)
        }
    )
    @ErrorResponse(
        DocumentNotFound.self,
        .notFound,
        { _ in Schemas.Problem(message: "no such document") }
    )
    @Operation
    public func getDocument(@AuthorizedDocument("read") document: Document) async throws -> Schemas.Document {
        .init(document)
    }
}

/// The boundary between the document's type and the domain's, crossed here for the reason
/// ``Components/Schemas/Todo`` states: `Controllers` owns one and must not depend on generated code to
/// know about the other.
extension Components.Schemas.Document {
    init(_ document: Controllers.Document) {
        self.init(
            id: document.id,
            title: document.title,
            text: document.text,
            owner: document.owner,
            department: document.department,
            classification: document.classification
        )
    }
}
