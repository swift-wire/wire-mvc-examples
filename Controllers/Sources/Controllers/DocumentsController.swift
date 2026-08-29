public import HTTPTypes
import Synchronization
public import Wire
public import WireMVC

// The resource the policy set governs, and the three places a policy decision lands in a controller:
// screened at the gate (outside this file), enforced per item, and *filtered* over a collection.
//
// The store is in memory and synchronous, which is a deliberate narrowing rather than a shortcut. This
// repository already proves the persistence axis three times over — `TodoRepository`, `SessionManager` and
// `JobStore` are each declared here and satisfied against a different real database per runtime — and
// doing it a fourth time would add nothing except the thing that would obscure this file. What is being
// shown here is that the *authorisation* tier is portable, and it is: nothing below is bound per runtime,
// so all three executables serve `/documents` from this source with no assembly of their own.

// MARK: - The resource

/// A document, on the wire and in the store. Three of its fields are also its ``ResourceAttributes``,
/// which is what makes it a resource rather than a payload.
public struct Document: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let text: String
    public let owner: String
    public let department: String
    public let classification: Int

    public init(
        id: String,
        title: String,
        text: String,
        owner: String,
        department: String,
        classification: Int
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.owner = owner
        self.department = department
        self.classification = classification
    }

    /// The attributes a policy reads. Projected rather than stored so the document and the thing policies
    /// see cannot drift apart.
    public var attributes: ResourceAttributes {
        ResourceAttributes(owner: owner, department: department, classification: classification)
    }
}

/// The body of `POST /documents`. No `owner` and no `department`: both are the caller's, and letting a
/// request name them would be letting it choose which policy it is judged under.
public struct CreateDocument: Codable, Sendable {
    public let title: String
    public let text: String
    public let classification: Int

    public init(title: String, text: String, classification: Int) {
        self.title = title
        self.text = text
        self.classification = classification
    }
}

/// The body of `PATCH /documents/{id}` — a partial edit, matching ``EditTodo``.
///
/// Neither field is an attribute a policy reads, and that is on purpose: an edit that could raise its own
/// document's classification, or hand it to another owner, is a *re-authorisation* rather than an update,
/// and folding it into this route would mean one handler enforcing two different decisions.
public struct EditDocument: Codable, Sendable {
    public let title: String?
    public let text: String?

    public init(title: String?, text: String?) {
        self.title = title
        self.text = text
    }
}

/// `GET`/`PATCH`/`DELETE` for an id the store does not hold — mapped to `404` by ``DocumentsController``.
public struct DocumentNotFound: Error {
    public init() {}
}

/// The documents, in the process. An app `@Singleton` with no per-runtime binding, for the reason stated
/// at the top of the file.
///
/// A `final class` rather than a struct because `Mutex` is `~Copyable`: a struct holding one would itself
/// become noncopyable, which a graph binding cannot be.
@Singleton
public final class DocumentStore: Sendable {
    /// Ordered, so `list` has a stable answer, and the id counter rides in the same lock as the documents
    /// so a create cannot mint an id it then fails to use.
    private let state = Mutex<(documents: [Document], nextID: Int)>(([], 1))

    @Inject public init() {
        // Seeded, so every policy in the set has something to decide about without a test having to create
        // it first — and so the fixtures span the two attribute axes the rules read: `sequencing` is above
        // `bob`'s and `carol`'s clearance, and `runbook` is outside `alice`'s and `bob`'s department.
        state.withLock { state in
            state.documents = [
                Document(
                    id: "notes",
                    title: "Kickoff notes",
                    text: "who is doing what",
                    owner: "alice",
                    department: "research",
                    classification: 1
                ),
                Document(
                    id: "sequencing",
                    title: "Sequencing draft",
                    text: "the order and the argument for it",
                    owner: "alice",
                    department: "research",
                    classification: 3
                ),
                Document(
                    id: "runbook",
                    title: "Operations runbook",
                    text: "what to do at 3am",
                    owner: "dave",
                    department: "operations",
                    classification: 2
                ),
            ]
        }
    }

    /// Every document, unfiltered. Filtering is the controller's, because it is a policy decision and this
    /// type knows nothing about policies — the same separation `TodoRepository` keeps from `TodosController`.
    public func all() -> [Document] {
        state.withLock { $0.documents }
    }

    public func find(id: String) -> Document? {
        state.withLock { $0.documents.first { $0.id == id } }
    }

    public func create(
        title: String,
        text: String,
        owner: String,
        department: String,
        classification: Int
    ) -> Document {
        state.withLock { state in
            let document = Document(
                id: "doc-\(state.nextID)",
                title: title,
                text: text,
                owner: owner,
                department: department,
                classification: classification
            )
            state.nextID += 1
            state.documents.append(document)
            return document
        }
    }

    /// Replace a document's editable fields, returning the new value — or `nil` if the id is gone, which
    /// the caller maps to ``DocumentNotFound``.
    public func update(id: String, with edit: EditDocument) -> Document? {
        state.withLock { state in
            guard let index = state.documents.firstIndex(where: { $0.id == id }) else { return nil }
            let existing = state.documents[index]
            let updated = Document(
                id: existing.id,
                title: edit.title ?? existing.title,
                text: edit.text ?? existing.text,
                owner: existing.owner,
                department: existing.department,
                classification: existing.classification
            )
            state.documents[index] = updated
            return updated
        }
    }

    public func delete(id: String) {
        state.withLock { $0.documents.removeAll { $0.id == id } }
    }
}

// MARK: - The controller

/// `/documents` — every route authorised against the same policy set, at the tier that has the attributes
/// it needs.
///
/// **Request-scoped**, like ``MeController``: the ``Caller`` binding resolves the subject and environment
/// attributes at scope entry and throws when there is no known principal, which
/// `@ErrorResponse(Unauthenticated.self, .unauthorized)` maps to `401`. Every handler below therefore has
/// a caller by construction and never checks for one.
///
/// **No item handler authorises, and none can forget to.** Each one takes an already-authorised
/// ``Document`` as an argument; loading it and deciding about it is ``DocumentAuthorizer``'s, once. What
/// each handler used to carry was two lines whose *order* was load-bearing — load first, because the
/// resource attributes are in the document — restated three times, with a fourth route's worth of nothing
/// stopping a future handler from restating them wrongly or not at all. The argument is that stopped: a
/// route that wants a `Document` gets one the only way there is.
///
/// The consequence of load-first is unchanged by moving it, and is still worth stating rather than
/// discovering: a `403` from here confirms the document exists. The alternative, a `404` for anything the
/// caller may not see, closes that channel and costs the caller the ability to tell "not there" from "not
/// yours"; it is the right trade for a system where ids are guessable and the wrong one here, where the
/// enumeration channel it would protect is already closed by ``list()`` filtering. Stated so that the
/// choice is a choice.
///
/// ``list(documents:)`` binds too, and differently, because a collection is not an item: it filters where
/// an item route refuses. ``create(input:)`` is the one route that still authorises in the handler, and
/// the reason is that it has nothing to bind — it decides about a document that does not exist yet,
/// against the attributes it *would* have.
///
/// ## What is required, and what is only faster
///
/// **The whole decision is in the bindings, and that is all correctness needs.** Each one screens the
/// rules that need no resource, then loads, then applies the rules that read it — see
/// ``DocumentAuthorizer``. One place per route shape, one policy set, no ordering for a handler to get
/// wrong.
///
/// An earlier version of this file also folded a **controller-scope middleware** that ran
/// ``PolicyEngine/screen(subject:action:environment:)`` from the request alone and answered `403` before
/// anything else happened. It is not here, and it was not removed because it was wrong. Deleting it and
/// measuring changed no status on any route: the bindings refuse the same requests, because they consult
/// the same set. What it bought was *earlier*:
///
/// - **A refusal skipped scope construction entirely.** A middleware that answers puts the box in
///   `.responded`, and `withPendingContents` is a no-op in that state, so ``Caller`` was never built. Here
///   that is one dictionary read; against a real identity provider it is a round trip, on every request
///   that was going to be refused anyway.
/// - **It applied to routes that had not been written yet**, since a fold is per controller rather than
///   per route. A new route inherits a gate; it does not inherit a binding it forgot to take.
///
/// Both are worth having under load, and neither is worth showing first: an example that ships the
/// optimisation teaches the optimisation as the requirement. If you want it back, it is a `@Factory` +
/// `@MiddlewareFactory` injecting ``PolicyEngine`` and ``PrincipalDirectory``, answering
/// `input.respondingWith(try .json(denial, status: .forbidden))` on a denial and forwarding otherwise —
/// and the bindings stay exactly as they are, because it can only refuse *earlier*, never differently.
///
/// Two things to know before adding it. It must answer **deny or undecided, never permit**, for the reason
/// ``PolicyEngine/screen(subject:action:environment:)`` gives. And it resolves the subject a second time —
/// a middleware's dependencies are app-scoped, so it cannot reach ``Caller`` — which is a cost the
/// binding-only shape does not pay at all, and the reason this file no longer has a paragraph explaining
/// how the two resolutions are kept from diverging.
@Scoped(seed: HTTPRequest.self)
@Controller("/documents")
@ErrorResponse(Unauthenticated.self, .unauthorized)  // the scope failed to build — no known principal
// Bodied, so a refusal names the rule that produced it. A `403` that does not is unactionable for the
// caller and unauditable for the operator, and — concretely — it is what lets a test assert that the
// *intended* rule refused rather than that something did.
@ErrorResponse(AccessDenied.self, .forbidden, { $0.denial })
@ErrorResponse(DocumentNotFound.self, .notFound)
public struct DocumentsController: Sendable {
    // Only `create` still needs these, for the reason its own comment gives: it authorises a document
    // that does not exist yet, so there is nothing to bind. Every other route takes its decision as an
    // argument and injects nothing.
    @Inject var caller: Caller
    @Inject var documents: DocumentStore
    @Inject var policies: PolicyEngine

    /// The **filter** tier. A caller asking for the collection is not asking a question that can be
    /// refused — the answer is the subset they may read, and for a caller who may read none of it that is
    /// an empty list with a `200`.
    ///
    /// Same decision function as ``read(id:)``, per document, which is the property that matters: a list
    /// that computed "visible" its own way is how an authorisation model comes apart, and it comes apart
    /// silently, because the two answers only disagree for the callers nobody tested.
    @Get
    @JSONResponse
    public func list(@AuthorizedDocuments("read") documents: [Document]) -> [Document] {
        documents
    }

    /// The **enforce** tier, and there is nothing left of it to write. The document arrives already
    /// authorised, because ``AuthorizedDocument`` is how one comes into existence — see it for why that
    /// is stronger than the two lines this used to be.
    @Get("/{id}")
    @JSONResponse
    public func read(@AuthorizedDocument("read") document: Document) -> Document {
        document
    }

    /// Authorising a resource that does not exist yet, against the attributes it *would* have.
    ///
    /// This is why ``ResourceAttributes`` is a type of its own rather than a projection of ``Document``.
    /// The proposed attributes are the caller's own owner and department plus the classification they
    /// asked for, so ``ClearanceRule`` refuses a document its author could not then read — a create that
    /// authorised against nothing would happily produce one.
    @Post
    @JSONResponse(status: .created)
    public func create(@JSONBody input: CreateDocument) throws -> (headers: HTTPFields, body: Document) {
        let proposed = ResourceAttributes(
            owner: caller.principal.user,
            department: caller.principal.department,
            classification: input.classification
        )
        try policies.authorize(caller.query(.create, on: proposed))
        let document = documents.create(
            title: input.title,
            text: input.text,
            owner: proposed.owner,
            department: proposed.department,
            classification: proposed.classification
        )
        // Written out rather than derived, for the reason `TodosController.create` states: the
        // `@Controller("/documents")` prefix is compile-time text the handler cannot read back.
        return ([.location: "/documents/\(document.id)"], document)
    }

    /// Authorised against the document as it stands, not as it would stand: ``EditDocument`` carries no
    /// attribute a rule reads, so the two are the same set and there is no second decision to make.
    @Patch("/{id}")
    @JSONResponse
    public func edit(
        @AuthorizedDocument("update") document: Document,
        @JSONBody input: EditDocument
    ) throws -> Document {
        guard let updated = documents.update(id: document.id, with: input) else { throw DocumentNotFound() }
        return updated
    }

    /// The route the gate most often refuses before it runs — a `DELETE` from the external zone never
    /// reaches here. When it does reach here, the resource-reading rules get their turn.
    @Delete("/{id}")
    @ResponseStatus(.noContent)
    public func delete(@AuthorizedDocument("delete") document: Document) {
        documents.delete(id: document.id)
    }
}
