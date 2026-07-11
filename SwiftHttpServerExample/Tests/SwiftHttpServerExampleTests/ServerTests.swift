import Foundation
import NIOHTTPServer
import Testing

@testable import SwiftHttpServerExample

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("SwiftHttpServerExample")
struct ServerTests {
    /// Starts the server on an ephemeral port, reads the bound port back via `listeningAddresses`,
    /// makes a real HTTP request through the loopback, and asserts the 200 OK — then cancels the
    /// serving task. The whole thing runs in-process; no container or external infra needed.
    @Test
    @available(anyAppleOS 26.0, *)
    func servesHelloWorld200() async throws {
        let server = try makeHelloWorldServer(port: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await serveHelloWorld(on: server) }

            let addresses = try await server.listeningAddresses
            let port = try #require(addresses.first?.port)

            let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
            let (data, response) = try await URLSession.shared.data(from: url)

            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "Well, hello!")

            group.cancelAll()
        }
    }
}
