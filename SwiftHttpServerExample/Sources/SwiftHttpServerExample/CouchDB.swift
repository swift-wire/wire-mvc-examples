import AsyncHTTPClient
import HTTPTypes
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
@Provides(CouchDB.client)
package func provideCouchDBClient() -> ConfiguredHTTPClient {
    let environment = ProcessInfo.processInfo.environment
    let host = environment["COUCHDB_HOST"] ?? "localhost"
    let port = environment["COUCHDB_PORT"] ?? "5984"
    let user = environment["COUCHDB_USER"] ?? "admin"
    let password = environment["COUCHDB_PASSWORD"] ?? "password"
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
