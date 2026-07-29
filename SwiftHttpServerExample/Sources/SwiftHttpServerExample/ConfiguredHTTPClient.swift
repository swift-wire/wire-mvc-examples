import AHCHTTPClient
import AsyncHTTPClient
import HTTPAPIs
import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An HTTP client pre-configured with a base URL and authorization: its verb methods apply both, so call
/// sites pass only a relative path (defaulting to the base itself) and a body — no repeated headers. Wraps
/// the process-wide async-http-client, so copies share one connection pool. `rooted(at:)` derives a client
/// scoped to a sub-path; each CouchDB backend roots the shared client at its own database.
package struct ConfiguredHTTPClient {
    private let client: AsyncHTTPClient.HTTPClient
    private let baseURL: String
    private let authorization: String

    init(client: AsyncHTTPClient.HTTPClient, baseURL: String, authorization: String) {
        self.client = client
        self.baseURL = baseURL
        self.authorization = authorization
    }

    /// A client rooted at `path` relative to this one's base — e.g. a specific CouchDB database.
    func rooted(at path: String) -> ConfiguredHTTPClient {
        ConfiguredHTTPClient(client: client, baseURL: "\(baseURL)/\(path)", authorization: authorization)
    }

    func get(_ path: String = "", collectUpTo: Int) async throws -> (HTTPResponse, Data) {
        var client = client
        return try await client.get(url: url(path), headerFields: headers(), collectUpTo: collectUpTo)
    }

    @discardableResult
    func put(
        _ path: String = "",
        bodyData: Data,
        collectUpTo: Int,
        json: Bool = false
    ) async throws -> (
        HTTPResponse, Data
    ) {
        var client = client
        return try await client.put(
            url: url(path),
            headerFields: headers(json: json),
            bodyData: bodyData,
            collectUpTo: collectUpTo
        )
    }

    @discardableResult
    func delete(_ path: String = "", collectUpTo: Int) async throws -> (HTTPResponse, Data) {
        var client = client
        return try await client.delete(url: url(path), headerFields: headers(), collectUpTo: collectUpTo)
    }

    private func url(_ path: String) -> URL {
        URL(string: path.isEmpty ? baseURL : "\(baseURL)/\(path)")!
    }

    private func headers(json: Bool = false) -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = authorization
        if json { fields[.contentType] = "application/json" }
        return fields
    }
}
