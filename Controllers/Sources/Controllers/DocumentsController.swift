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
/// **The order of the two lines in each item handler is load-bearing, and it is load first.** There is no
/// other order available — the resource attributes are in the document — and it has a consequence worth
/// stating rather than discovering: a `403` from here confirms the document exists. The alternative, a
/// `404` for anything the caller may not see, closes that channel and costs the caller the ability to tell
/// "not there" from "not yours"; it is the right trade for a system where ids are guessable and the wrong
/// one here, where the enumeration channel it would protect is already closed by ``list()`` filtering.
/// Stated so that the choice is a choice.
@Scoped(seed: HTTPRequest.self)
@Controller("/documents")
@Middleware(ControllerMiddleware.screenAccess)  // the gate: refuses what the request alone can refuse
@ErrorResponse(Unauthenticated.self, .unauthorized)  // the scope failed to build — no known principal
@ErrorResponse(AccessDenied.self, .forbidden)  // a policy refused, with the resource in hand
@ErrorResponse(DocumentNotFound.self, .notFound)
public struct DocumentsController: Sendable {
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
    public func list() -> [Document] {
        documents.all().filter { policies.permits(caller.query(.read, on: $0.attributes)) }
    }

    /// The **enforce** tier, at its plainest: load, authorise, answer.
    @Get("/{id}")
    @JSONResponse
    public func read(@Path id: String) throws -> Document {
        let document = try find(id)
        try policies.authorize(caller.query(.read, on: document.attributes))
        return document
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
    public func edit(@Path id: String, @JSONBody input: EditDocument) throws -> Document {
        let document = try find(id)
        try policies.authorize(caller.query(.update, on: document.attributes))
        guard let updated = documents.update(id: id, with: input) else { throw DocumentNotFound() }
        return updated
    }

    /// The route the gate most often refuses before it runs — a `DELETE` from the external zone never
    /// reaches here. When it does reach here, the resource-reading rules get their turn.
    @Delete("/{id}")
    @ResponseStatus(.noContent)
    public func delete(@Path id: String) throws {
        let document = try find(id)
        try policies.authorize(caller.query(.delete, on: document.attributes))
        documents.delete(id: id)
    }

    private func find(_ id: String) throws -> Document {
        guard let document = documents.find(id: id) else { throw DocumentNotFound() }
        return document
    }
}
