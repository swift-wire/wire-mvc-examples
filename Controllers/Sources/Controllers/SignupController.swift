public import Wire
public import WireMVC

// A route bound with `@FormBody` — a binding WireMVC has never heard of, declared in this module.
//
// Nothing here is special-cased anywhere in the framework: the plugin reads `@RequestBinding(.body)` off
// `FormBody`'s declaration, the terminal collects the request body because of it, and the generated typed
// client sends `application/x-www-form-urlencoded` because `RequestBodySendable` said so.

/// What an HTML sign-up form posts back.
public struct Signup: Sendable, FormDecodable, FormEncodable {
    public let email: String
    public let displayName: String

    public init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }

    public init(formFields: [(name: String, value: String)]) throws {
        func field(_ name: String) throws -> String {
            guard let value = formFields.first(where: { $0.name == name })?.value, !value.isEmpty else {
                throw FormBodyError.missingField(name)
            }
            return value
        }
        self.init(email: try field("email"), displayName: try field("display_name"))
    }

    public var formFields: [(name: String, value: String)] {
        [("email", email), ("display_name", displayName)]
    }
}

public struct SignupAccepted: Codable, Sendable {
    public let email: String
    public let displayName: String
    public init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }
}

@Singleton
@Controller("/signup")
public struct SignupController: Sendable {

    /// `POST /signup` with `email=…&display_name=…`.
    ///
    /// A missing field maps to a `400` through the ordinary `@ErrorResponse` tier — the binding throws before
    /// the response head is built, so a user-declared binding's failures behave exactly like `@JSONBody`'s.
    @Post
    @JSONResponse(status: .created)
    @ErrorResponse(FormBodyError.self, .badRequest)
    public func create(@FormBody form: Signup) async throws -> SignupAccepted {
        SignupAccepted(email: form.email, displayName: form.displayName)
    }
}
