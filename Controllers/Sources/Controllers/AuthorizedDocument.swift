// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes
public import Wire
public import WireMVC

/// The **enforce** tier as an argument rather than as two lines in a handler.
///
/// `DocumentsController` used to restate `load, then authorise` in each item handler, and said so:
/// "the order of the two lines is load-bearing, and it is load first". Restating it is the problem. Any
/// one of them could get the order wrong, and — worse — a *new* item route that simply omitted the second
/// line would compile, serve, and be unauthorised, with nothing but review to catch it.
///
/// Binding the document is what closes that. A route taking a ``Document`` cannot skip the check, because
/// the check is how a `Document` comes into existence: there is no other way to get one from an id. An
/// unauthorised item route stops being *writable*, which is categorically stronger than a convention, and
/// it is this design's own idiom one level in — authentication is already a precondition of the ``Caller``
/// scope existing rather than something each handler asks about.
///
/// **Two types, because a parameter attribute and a graph binding cannot be one.** Only a property wrapper
/// attaches to a parameter, and its instance holds the value the call site supplies; a binding that reads
/// a store and consults a policy holds the dependencies the graph supplied. Neither initialiser could be
/// total on one type. So this is the wrapper, and it names its worker.
///
/// The **action** is the attribute's argument — `@AuthorizedDocument("read")`. Stringly, and deliberately
/// so for now: `bind` receives the argument as `name`, and ``AccessAction`` is `String`-backed, so the two
/// meet without a channel for annotation arguments that WireMVC does not yet have.
@RequestBinding(DocumentAuthorizer.self)
@propertyWrapper
public struct AuthorizedDocument {
    public var wrappedValue: Document
    public init(wrappedValue: Document) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: Document, _ name: String) { self.wrappedValue = wrappedValue }
}

/// The worker: an ordinary request-scoped binding, injecting exactly what the handlers used to.
///
/// It is in the **same scope** `DocumentsController` is, which is what makes the instance arrive on the
/// controller's own scope entry — a route parameter naming ``AuthorizedDocument`` is the whole of the
/// request. Nothing here or on the controller declares the connection.
///
/// It does **both halves** of the decision, and `bind` says why in the order it does them. Splitting them
/// across layers is possible and buys a refusal before the request scope is built; it is not required, and
/// ``DocumentsController`` weighs it. What is not optional is the order: resource-independent rules first,
/// because they are the ones that can be answered without touching the store.
@Scoped(seed: HTTPRequest.self)
public struct DocumentAuthorizer: ScopedRequestBound {
    public typealias Value = Document

    @Inject var documents: DocumentStore
    @Inject var policies: PolicyEngine
    @Inject var caller: Caller

    public func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Document {
        guard let action = AccessAction(rawValue: name) else { throw UnknownAction(name: name) }
        // **Both halves of the decision, in the order the attributes arrive.** First the rules that need
        // no resource — a suspended account, a mutation from the external zone — which is why this runs
        // before the store is read. Then the load, then the rules that read the document.
        //
        // ``PolicyEngine/screen(subject:action:environment:)`` answers deny-or-undecided and *cannot*
        // return a permit, which is the one thing here that would be a security bug if it were relaxed:
        // every resource-reading rule abstains without a resource, so a permit at this point is missing an
        // unknown number of the rules that would have denied. Treating it as final would wave through
        // exactly what ``ClearanceRule`` exists to stop.
        if let denial = policies.screen(
            subject: caller.principal,
            action: action,
            environment: caller.environment
        ) {
            throw AccessDenied(denial: denial)
        }
        guard let id = pathParameters["id"].map(String.init),
            let document = documents.find(id: id)
        else { throw DocumentNotFound() }
        // A `403` from here confirms the document exists, which is the trade ``DocumentsController``
        // argues for: the enumeration channel a `404` would close is already closed by ``list()``
        // filtering.
        try policies.authorize(caller.query(action, on: document.attributes))
        return document
    }
}

/// An `@AuthorizedDocument("…")` naming something that is not an ``AccessAction``.
///
/// Reachable only from a typo in an annotation, and a `500` rather than a `403`: the caller did nothing
/// wrong, and answering `403` would tell them they were refused when in fact the app cannot say.
public struct UnknownAction: Error, Sendable {
    public let name: String
}

// MARK: - The collection, bound the same way

/// The **filter** tier as an argument — the collection's counterpart to ``AuthorizedDocument``.
///
/// A collection is not an item, and the difference is real: a caller asking for a list of things they may
/// not see is not making a request that can be refused, so the answer is the shorter list rather than a
/// `403`. That is why this binds `[Document]` rather than refusing per document.
///
/// **Except when a rule refuses the request itself.** A suspended account asking for the collection is not
/// owed a filtered view of it — the rules that need no resource apply to the *request*, and the honest
/// answer is a refusal. Screening here and filtering after is what draws that line in one place; a version
/// that only filtered would answer `200 []` and quietly call "you may see nothing" the same thing as "you
/// are refused".
@RequestBinding(DocumentLister.self)
@propertyWrapper
public struct AuthorizedDocuments {
    public var wrappedValue: [Document]
    public init(wrappedValue: [Document]) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: [Document], _ name: String) { self.wrappedValue = wrappedValue }
}

/// The worker behind ``AuthorizedDocuments``. Same scope, same policy set, same two halves as
/// ``DocumentAuthorizer`` — and, crucially, the same **decision function** for the resource-reading half.
///
/// `permits` is `authorize` with the throw turned into a `Bool`, so the collection and the item route
/// cannot disagree about a document. A list that computed "visible" its own way is how an authorisation
/// model comes apart, and it comes apart silently, because the two answers only differ for the callers
/// nobody tested.
@Scoped(seed: HTTPRequest.self)
public struct DocumentLister: ScopedRequestBound {
    public typealias Value = [Document]

    @Inject var documents: DocumentStore
    @Inject var policies: PolicyEngine
    @Inject var caller: Caller

    public func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> [Document] {
        guard let action = AccessAction(rawValue: name) else { throw UnknownAction(name: name) }
        if let denial = policies.screen(
            subject: caller.principal,
            action: action,
            environment: caller.environment
        ) {
            throw AccessDenied(denial: denial)
        }
        return documents.all().filter { policies.permits(caller.query(action, on: $0.attributes)) }
    }
}
