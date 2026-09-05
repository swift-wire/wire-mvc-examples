// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

public import Wire
public import WireMVC

// A config endpoint, which is where YAML actually earns its place: a document a human edits and a machine
// reads. `GET /config` renders the current settings as YAML; `PUT /config` accepts an edited document back.
//
// Read as an example of the extension point rather than of YAML, the interesting line is `replace`: one
// handler whose request body is decoded by a binding WireMVC does not know and whose response is encoded by
// a mode WireMVC does not know. Neither required a framework change, and the generated typed client carries
// both — `YAMLBody<Settings>.sendBody` out, `YAMLCodec<Settings>.decodeResponseBody` back.

/// The document. Ordinary `Codable`; the codec is what makes it YAML, not anything about the type.
public struct Settings: Sendable, Codable, Equatable {
    public var serviceName: String
    public var replicas: Int
    public var features: [String]

    public init(serviceName: String, replicas: Int, features: [String]) {
        self.serviceName = serviceName
        self.replicas = replicas
        self.features = features
    }

    /// What a fresh deployment starts from.
    public static let defaults = Settings(
        serviceName: "todos",
        replicas: 2,
        features: ["metrics", "tracing"]
    )
}

public struct InvalidSettings: Error {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Holds the current document. A `@Singleton` actor rather than a store binding: this example is about the
/// codec, and a real backend would only put a database between the two interesting lines.
@Singleton
public actor SettingsStore {
    private var current: Settings = .defaults

    public func read() -> Settings { current }

    public func replace(with settings: Settings) throws -> Settings {
        guard settings.replicas > 0 else {
            throw InvalidSettings(reason: "replicas must be at least 1")
        }
        current = settings
        return current
    }
}

@Singleton
@Controller("/config")
public struct ConfigController: Sendable {
    @Inject private var store: SettingsStore

    /// YAML out. `@YAMLResponse` is a mode declared in this module — the generated terminal encodes through
    /// `YAMLCodec` and takes the content type from it.
    @Get
    @YAMLResponse
    public func current() async -> Settings {
        await store.read()
    }

    /// YAML in *and* out, through one generated method on each side. `@YAMLBody` collects and decodes the
    /// request body because its `@RequestBinding(.body)` says to; `@YAMLResponse` encodes the result.
    ///
    /// `@ErrorResponse` covers both failure paths, and they are not the same kind: a body that is not valid
    /// YAML fails in the binding, before the handler runs, while `InvalidSettings` is the handler rejecting a
    /// document it could read. Both are pre-head failures on a buffered route, so both map to a status.
    @Put
    @YAMLResponse
    @ErrorResponse(InvalidSettings.self, .badRequest)
    @ErrorResponse(YAMLError.self, .badRequest)
    public func replace(@YAMLBody settings: Settings) async throws -> Settings {
        try await store.replace(with: settings)
    }

    /// The same mode with an annotated status, read through the generic `status:` path rather than a
    /// per-annotation one.
    @Post("/reset")
    @YAMLResponse(status: .created)
    public func reset() async throws -> Settings {
        try await store.replace(with: .defaults)
    }
}
