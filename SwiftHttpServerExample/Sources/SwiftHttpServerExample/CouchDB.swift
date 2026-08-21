import AsyncHTTPClient
import HTTPTypes
package import WireConfiguration
package import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Keyed handle for the CouchDB client. `ConfiguredHTTPClient` is a reusable type (any service can have
/// one), so a `BindingKey` names *this* app's CouchDB instance — the todo repository and the session store
/// both `@Bind(CouchDB.client)` it and share one configured client, each rooting it at its own database.
package enum CouchDB {
    package static let client = BindingKey<ConfiguredHTTPClient>()
}

/// Build the CouchDB client for the graph — a keyed `@Provides` returning a `ConfiguredHTTPClient` primed
/// with the endpoint + credentials (read from the environment, 12-factor). The underlying transport is the
/// async-http-client `.shared` instance: the proposal's default client is URLSession-backed on macOS and
/// currently hangs collecting keep-alive responses on the nightly toolchain, so pinning `.shared` keeps the
/// same call surface working on macOS and Linux with no explicit shutdown.
/// Connection settings come from the graph's shared `ConfigReader` — injected like any other dependency,
/// rather than this provider reaching for `ProcessInfo` on its own. swift-configuration maps each key to an
/// environment variable (`couchdb.host` → `COUCHDB_HOST`), so the deployment contract is unchanged; what
/// changes is that the reader is visible in the graph and substitutable in a test.
@Provides(CouchDB.client)
package func provideCouchDBClient(
    @ConfigProperty(forKey: "couchdb.host", default: "localhost") host: String,
    @ConfigProperty(forKey: "couchdb.port", default: 5984) port: Int,
    @ConfigProperty(forKey: "couchdb.user", default: "admin") user: String,
    // The one value worth marking: `isSecret` governs redaction in logging and debugging.
    @ConfigProperty(forKey: "couchdb.password", default: "password", isSecret: true) password: String
) -> ConfiguredHTTPClient {
    return ConfiguredHTTPClient(
        client: .shared,
        baseURL: "http://\(host):\(port)",
        authorization: "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    )
}

/// A non-success CouchDB response.
package struct CouchDBError: Error {
    package let status: HTTPResponse.Status
}
