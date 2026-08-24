import Foundation
import HTMLForm
import HTTPTypes
import Testing
import WireMVCTesting

/// The `html-form` port: a GET that renders a form, a POST that re-renders it with validation errors.
///
/// The interesting claim is not that HTML comes back — it is that **one generated client method** composes
/// two things WireMVC does not know about: `@FormBody` (declared in `Controllers`) writes the request body,
/// and `@HTMLResponse` streams an Elementary document back. Neither required a framework change; the
/// generated `submit(draft:)` takes a `ContactDraft` and returns the rendered page as `String`.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct ContactFormTests {

    @Test("the empty form renders its fields")
    func rendersTheForm() async throws {
        try await withClient(for: ContactControllerClient.self) { contact in
            let html = try await contact.form()
            #expect(html.contains(#"<form method="post" action="/contact""#))
            #expect(html.contains(#"enctype="application/x-www-form-urlencoded""#))
            for field in ["name", "email", "message"] {
                #expect(html.contains(#"name="\#(field)""#), "the \(field) input is present")
            }
            #expect(!html.contains(#"class="error""#), "an untouched form shows no errors")
        }
    }

    /// The whole point of a form example. An invalid submission comes back as the *form*, not a 400 — with
    /// the user's input still in the inputs, which is what distinguishes re-rendering from rejecting.
    @Test("an invalid submission re-renders with errors and preserved input")
    func reRendersWithErrors() async throws {
        try await withClient(for: ContactControllerClient.self) { contact in
            let html = try await contact.submit(
                draft: ContactDraft(name: "Ada Lovelace", email: "not-an-address", message: "hi")
            )
            #expect(html.contains("That does not look like an email address."))
            #expect(html.contains("A little more detail, please"))
            #expect(!html.contains("Please tell us your name."), "a valid field carries no error")
            // Round-tripped through `+`-encoding and back into the `value` attribute.
            #expect(html.contains(#"value="Ada Lovelace""#))
            #expect(html.contains(#"value="not-an-address""#))
        }
    }

    @Test("a valid submission renders the confirmation instead of the form")
    func confirmsOnSuccess() async throws {
        try await withClient(for: ContactControllerClient.self) { contact in
            let html = try await contact.submit(
                draft: ContactDraft(
                    name: "Ada",
                    email: "ada@example.com",
                    message: "Please send documentation."
                )
            )
            #expect(html.contains("Thanks, Ada — we will reply to ada@example.com."))
            #expect(!html.contains("<form"), "the form is gone once it has been accepted")
        }
    }

    /// HTML escaping is the view layer's job and Elementary does it — worth pinning, because a form that
    /// echoes user input straight back is exactly where a template that *didn't* would be exploitable.
    ///
    /// The two contexts escape differently, and both are right: text content escapes `<`/`>`, while an
    /// attribute value escapes the quote that would end it and leaves `<` alone. A bare `<` inside a
    /// double-quoted attribute cannot start a tag, so escaping it is not required — which is worth asserting
    /// rather than assuming, since the naive expectation ("everything is `&lt;`") fails here on correct code.
    @Test("submitted input is escaped when it is echoed back")
    func escapesEchoedInput() async throws {
        try await withClient(for: ContactControllerClient.self) { contact in
            // Invalid, so it comes back in the form's `value` attribute.
            let reRendered = try await contact.submit(
                draft: ContactDraft(name: #"<script>alert("x")</script>"#, email: "nope", message: "short")
            )
            #expect(
                reRendered.contains(#"value="<script>alert(&quot;x&quot;)</script>""#),
                "the quote that would close the attribute is escaped, so the payload stays one attribute"
            )

            // Valid, so the same input is rendered as text — where `<` *would* start a tag.
            let confirmed = try await contact.submit(
                draft: ContactDraft(
                    name: #"<script>alert("x")</script>"#,
                    email: "ada@example.com",
                    message: "Please send documentation."
                )
            )
            #expect(!confirmed.contains("<script>"))
            #expect(confirmed.contains("&lt;script&gt;"))
        }
    }

    /// Streamed, not buffered: `@HTMLResponse` is the streaming tier, so the response carries the producer's
    /// content type and arrives without a `Content-Length` the handler never computed.
    @Test("the response is served as streamed HTML")
    func servesStreamedHTML() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/contact")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.contentType] == "text/html; charset=utf-8")
        }
    }
}
