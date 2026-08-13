public import WireMVCElementary

/// The view. A concrete `HTMLDocument` rather than `some HTML`, because both routes return it and a
/// concrete type says so — an opaque return would make the two routes' types formally unrelated.
public struct ContactPage: HTMLDocument {
    public let draft: ContactDraft
    public let errors: [String: String]
    public let submitted: Bool

    public init(draft: ContactDraft, errors: [String: String], submitted: Bool) {
        self.draft = draft
        self.errors = errors
        self.submitted = submitted
    }

    public var title: String { submitted ? "Thank you" : "Contact us" }

    public var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1.0"))
    }

    public var body: some HTML {
        h1 { title }
        if submitted {
            p(.class("confirmation")) { "Thanks, \(draft.name) — we will reply to \(draft.email)." }
        } else {
            // `enctype` is a POST form's default, but stating it keeps the contract with `@FormBody` visible:
            // `application/x-www-form-urlencoded` is exactly what the binding decodes.
            form(.method(.post), .action("/contact"), .enctype("application/x-www-form-urlencoded")) {
                field("name", label: "Your name", value: draft.name)
                field("email", label: "Email", value: draft.email)
                field("message", label: "Message", value: draft.message)
                button(.type(.submit)) { "Send" }
            }
        }
    }

    /// One labelled input, its previous value preserved, and its error if it has one. Re-rendering with the
    /// user's input intact is the difference between a form and a 400.
    @ContentBuilder
    private func field(_ name: String, label: String, value: String) -> some HTML {
        div(.class("field")) {
            Elementary.label(.for(name)) { label }
            input(.type(.text), .id(name), .name(name), .value(value))
            if let error = errors[name] {
                span(.class("error")) { error }
            }
        }
    }
}

// Elementary ships typed attributes for the tags it covers, and `enctype` is not among them. The generic
// initialiser is public precisely so a caller can add one without a fork — the same shape of extension point
// `@FormBody` is on the request side.
extension HTMLAttribute where Tag == HTMLTag.form {
    static func enctype(_ value: String) -> Self {
        HTMLAttribute(name: "enctype", value: value)
    }
}
