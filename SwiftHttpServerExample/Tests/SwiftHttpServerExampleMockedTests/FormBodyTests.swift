import Controllers
import Foundation
import Testing
import WireMVC
import WireMVCTesting

/// The `@FormBody` codec — a binding declared outside WireMVC, so nothing in the framework tests it.
///
/// Worth unit-testing rather than only exercising through a route: form encoding differs from ordinary
/// percent-encoding in exactly one place (`+` is a space), has no notion of a unique key, and the obvious
/// Foundation escaping set is wrong for a body. All three are silent when got wrong.
@Suite("@FormBody codec")
struct FormBodyCodecTests {

    @Test("plus is a space, percent escapes decode")
    func decodesTheTwoEncodings() throws {
        let fields = try parseFormFields("display_name=Ada+Lovelace&email=ada%40example.com")
        #expect(fields.map(\.name) == ["display_name", "email"])
        #expect(fields.map(\.value) == ["Ada Lovelace", "ada@example.com"])
    }

    /// Form encoding has no unique-key rule. Collapsing to a dictionary would keep only the last value of a
    /// multi-select — silently, and only for users who pick more than one option.
    @Test("repeated keys are kept, in order")
    func repeatedKeysSurvive() throws {
        let fields = try parseFormFields("tags=swift&tags=server&tags=http")
        #expect(fields.count == 3)
        #expect(fields.map(\.value) == ["swift", "server", "http"])
    }

    @Test("an empty value is a present field, not an absent one")
    func emptyValueIsPresent() throws {
        let fields = try parseFormFields("email=&display_name=Ada")
        #expect(fields.first?.name == "email")
        #expect(fields.first?.value == "")
    }

    @Test("a value containing a separator does not reshape the body")
    func separatorsAreEscaped() throws {
        let signup = Signup(email: "a&b=c+d@example.com", displayName: "Ada")
        var request = WireMVCOutgoingRequest()
        let encoded = try FormBody<Signup>.sendBody(
            name: "form",
            value: signup,
            into: &request,
            coding: .default
        )
        #expect(encoded.contentType == "application/x-www-form-urlencoded")
        // Round-trips: the `&`, `=` and `+` inside the value survive as data rather than becoming structure.
        let reparsed = try Signup(formFields: try parseFormFields(String(decoding: encoded.bytes, as: UTF8.self)))
        #expect(reparsed.email == signup.email)
        #expect(reparsed.displayName == signup.displayName)
    }

    /// A malformed escape **fails closed**. `removingPercentEncoding` returns nil for the *entire string*
    /// when any escape is bad, so the obvious `?? raw` would silently disable decoding for the whole value —
    /// `a%40b%zz` coming back with its `%40` undecoded. Throwing makes it a 400 through the route's
    /// `@ErrorResponse` instead of quietly handing the handler half-decoded input.
    @Test("a malformed escape is rejected, not absorbed")
    func malformedEscapeThrows() throws {
        #expect(throws: FormBodyError.self) { try parseFormFields("note=50%+more") }
        #expect(throws: FormBodyError.self) { try parseFormFields("note=%zz") }
        // A *valid* escape of a percent sign is data, and still decodes.
        let decoded = try parseFormFields("note=100%25+off")
        #expect(decoded.first?.value == "100% off")
    }

    @Test("lower- and upper-case hex both decode")
    func hexCaseInsensitive() throws {
        #expect(try parseFormFields("a=%2f").first?.value == "/")
        #expect(try parseFormFields("a=%2F").first?.value == "/")
    }

    @Test("a missing required field throws, so the route can map it")
    func missingFieldThrows() {
        #expect(throws: FormBodyError.self) {
            try Signup(formFields: try parseFormFields("email=ada%40example.com"))
        }
    }
}

/// `/signup` end to end over the in-memory server, through the *generated* typed client.
///
/// This is the claim the whole extension point exists for: `FormBody` is declared in `Controllers`, WireMVC
/// names it nowhere, and yet the route collects its body on the server and the client sends
/// `application/x-www-form-urlencoded` — because `@RequestBinding(.body)` and two conformances said so.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct FormBodyRouteTests {

    @Test func theRouteRoundTripsAFormBody() async throws {
        try await withClient(for: SignupControllerClient.self) { signup in
            let accepted = try await signup.create(
                form: Signup(email: "ada@example.com", displayName: "Ada Lovelace")
            )
            #expect(accepted.email == "ada@example.com")
            #expect(accepted.displayName == "Ada Lovelace", "the space survived the +-encoding round trip")
        }
    }

    /// A binding failure is a pre-head failure, so it maps through the route's `@ErrorResponse` exactly as a
    /// `@JSONBody` decode failure would — a user-declared binding is not second-class here.
    @Test func aMissingFieldMapsToBadRequest() async throws {
        try await withClient { client in
            // `send` rather than `post`: the latter is the JSON convenience, and the point here is a body
            // that is not JSON — which is the whole reason this binding exists.
            let response = try await client.send(
                "POST",
                "/signup",
                body: Data("email=ada%40example.com".utf8),
                headers: ["Content-Type": "application/x-www-form-urlencoded"]
            )
            #expect(response.status == 400)
        }
    }
}
