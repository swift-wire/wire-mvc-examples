// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

public import Controllers
public import Wire
public import WireMVC
import WireMVCElementary

// The `html-form` shape: `GET /contact` renders a form, `POST /contact` binds it with `@FormBody` and
// re-renders — with per-field errors on failure, or a confirmation on success.
//
// Both halves are extension points rather than framework features. `@FormBody` is declared in `Controllers`
// and WireMVC names it nowhere; `@HTMLResponse` streams whatever `WireMVCHTMLProducer` wraps, which here is
// Elementary. Neither required a change to WireMVC to write.

/// What the form collects. The `FormDecodable` requirement is `throws`, and this conformance deliberately
/// does not — a form that re-renders its own errors needs the partial input back, not an exception. The
/// strict binding (`Signup`, in `Controllers`) throws on a missing field; that one is for APIs, this one is
/// for humans, and both are the same binding.
public struct ContactDraft: Sendable, FormDecodable, FormEncodable {
    public var name: String
    public var email: String
    public var message: String

    public init(name: String = "", email: String = "", message: String = "") {
        self.name = name
        self.email = email
        self.message = message
    }

    public init(formFields: [(name: String, value: String)]) {
        func field(_ key: String) -> String {
            formFields.first { $0.name == key }?.value ?? ""
        }
        self.init(name: field("name"), email: field("email"), message: field("message"))
    }

    public var formFields: [(name: String, value: String)] {
        [("name", name), ("email", email), ("message", message)]
    }

    /// Field name → message. Empty means valid.
    public var errors: [String: String] {
        var found: [String: String] = [:]
        if name.isEmpty { found["name"] = "Please tell us your name." }
        if !email.contains("@") { found["email"] = "That does not look like an email address." }
        if message.count < 10 {
            found["message"] = "A little more detail, please (10 characters or more)."
        }
        return found
    }
}

@Singleton
@Controller("/contact")
public struct ContactController: Sendable {

    /// The empty form.
    @Get
    @HTMLResponse
    public func form() -> ContactPage {
        ContactPage(draft: ContactDraft(), errors: [:], submitted: false)
    }

    /// The round trip. A valid draft renders a confirmation; an invalid one re-renders the form with the
    /// user's input still in it and the errors beside the fields they belong to — which is the whole reason
    /// this is a *form* example and not a POST endpoint.
    @Post
    @HTMLResponse
    public func submit(@FormBody draft: ContactDraft) -> ContactPage {
        let errors = draft.errors
        return ContactPage(draft: draft, errors: errors, submitted: errors.isEmpty)
    }
}
