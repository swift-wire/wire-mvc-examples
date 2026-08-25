import Foundation
import HTTPTypes
import Testing
import WireMVCTesting
import YAMLConfig

/// Both ends of the extension point around one codec, and the first route in this repo whose **response**
/// mode is declared outside WireMVC.
///
/// `@FormBody` proved the request half; `HTMLForm` used a built-in response mode on top of it. Here neither
/// half is WireMVC's: `@YAMLBody` carries `@RequestBinding(.body)` and `@YAMLResponse` carries
/// `@ResponseMode(.buffered, codec: "YAMLCodec")`, both read off their declarations in `YAMLConfig`.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct YAMLConfigTests {

    @Test("the response is YAML, with the codec's content type")
    func servesYAML() async throws {
        try await withClient { client in
            let response = try await client.send("GET", "/config")
            #expect(response.status == 200)
            #expect(
                response.head?.headerFields[.contentType] == "application/yaml",
                "the content type comes from the codec, not the codegen"
            )
            // Enough to show it is YAML and not JSON — no braces, and a key: value line.
            #expect(response.bodyText.contains("serviceName: todos"))
            #expect(!response.bodyText.contains("{"))
        }
    }

    /// The generated client decodes through `YAMLCodec`, so a test gets the handler's own return type back.
    @Test("the typed client decodes through the mode's codec")
    func theClientDecodes() async throws {
        try await withClient(for: ConfigControllerClient.self) { config in
            let settings = try await config.current()
            #expect(settings == Settings.defaults)
        }
    }

    /// One generated method carrying both halves: `YAMLBody.sendBody` out, `YAMLCodec.decodeResponseBody`
    /// back. This is the round trip the whole extension point exists to make writable.
    @Test("a YAML body goes out and a YAML body comes back")
    func roundTripsThroughBothHalves() async throws {
        try await withClient(for: ConfigControllerClient.self) { config in
            let edited = Settings(serviceName: "todos", replicas: 5, features: ["metrics"])
            let applied = try await config.replace(settings: edited)
            #expect(applied == edited)
            // …and it stuck, so the request body really was decoded rather than echoed.
            #expect(try await config.current().replicas == 5)
        }
    }

    /// Two different pre-head failures on one route. A body that is not YAML fails **in the binding**,
    /// before the handler runs; `InvalidSettings` is the handler rejecting a document it could read. Both map
    /// through `@ErrorResponse`, which is what "a user binding is not second-class" means concretely.
    @Test("both failure paths map to 400")
    func bothFailuresMap() async throws {
        try await withClient { client in
            let unparsable = try await client.send(
                "PUT",
                "/config",
                body: Data("this: [is: not: yaml".utf8),
                headers: ["Content-Type": "application/yaml"]
            )
            #expect(unparsable.status == 400, "a binding failure")

            let rejected = try await client.send(
                "PUT",
                "/config",
                body: Data("serviceName: todos\nreplicas: 0\nfeatures: []\n".utf8),
                headers: ["Content-Type": "application/yaml"]
            )
            #expect(rejected.status == 400, "a handler failure")
        }
    }

    @Test("a user mode carries an annotated status")
    func annotatedStatus() async throws {
        try await withClient { client in
            let response = try await client.send("POST", "/config/reset")
            #expect(response.status == 201, "the annotated status, not the default 200")
            #expect(response.head?.headerFields[.contentType] == "application/yaml")
        }
    }
}
