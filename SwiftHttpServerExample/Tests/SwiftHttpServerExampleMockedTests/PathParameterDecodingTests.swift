import Controllers
import Smockable
import Testing
import WireMVCTesting

/// The proposal-native half of the path-parameter decoding picture: this runtime serves through WireMVC's
/// own router, which percent-decodes a bound parameter before the handler sees it.
///
/// The counterparts live in `VaporExample` (decodes, via RoutingKit) and `HummingbirdExample` (does **not**
/// decode). On those runtimes the parameter comes from the host framework as
/// `ServerRequestMetadata.pathParameters`, so it is their choice rather than WireMVC's — which makes
/// Hummingbird the one runtime where a `%`-escaped id reaches a handler still escaped.
///
/// These are **round-trip** tests, which is what driving through the generated typed client makes them:
/// the client percent-encodes the id into the request line, and the router decodes it back out. That is
/// the property an app actually depends on — an id survives being put in a URL — and it is stronger than
/// asserting on a hand-written escape, because it fails if either half is wrong or if the two disagree.
/// The escape-by-escape behaviour (`%2F`, malformed input, non-UTF-8 bytes) is pinned directly against the
/// trie in wire-mvc's `RouteTrieTests`.
///
/// The mock is the observable: it records the id it was asked for, so the assertion is on the value itself
/// rather than on a status code that could be right for the wrong reason.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct PathParameterDecodingTests {
    /// An id containing spaces survives the round trip. Encoded as `%20` on the wire; without decoding the
    /// handler would look up `does%20not%20exist` — an identifier no client ever sent.
    @Test func anIdWithSpacesRoundTrips() async throws {
        var expectations = MockMockableTodoRepository.Expectations()
        when(expectations.find(id: .any), return: nil)
        let todoMock = MockMockableTodoRepository(expectations: expectations)

        try await withClient(supplying: TodosControllerDoubles(todoRepository: todoMock)) { todos in
            // 404, since the mock finds nothing — incidental. What matters is what it was asked for.
            _ = try? await todos.get(id: "does not exist")
        }
        verify(todoMock, times: 1).find(id: "does not exist")
    }

    /// An id containing a literal `%` survives too — the case that catches a decoder applied twice, or one
    /// that treats an already-decoded value as still encoded. The client sends `a%25zz`; exactly one
    /// decode returns `a%zz`, and a second would leave `azz` or fail.
    @Test func anIdWithALiteralPercentRoundTrips() async throws {
        var expectations = MockMockableTodoRepository.Expectations()
        when(expectations.find(id: .any), return: nil)
        let todoMock = MockMockableTodoRepository(expectations: expectations)

        try await withClient(supplying: TodosControllerDoubles(todoRepository: todoMock)) { todos in
            _ = try? await todos.get(id: "a%zz")
        }
        verify(todoMock, times: 1).find(id: "a%zz")
    }

    /// An id containing a slash. `/` must be encoded as `%2F` by the client, and decoding runs *after* the
    /// path is split, so it binds one parameter containing a slash rather than reintroducing a path
    /// boundary and routing somewhere else entirely.
    @Test func anIdWithASlashStaysOneParameter() async throws {
        var expectations = MockMockableTodoRepository.Expectations()
        when(expectations.find(id: .any), return: nil)
        let todoMock = MockMockableTodoRepository(expectations: expectations)

        try await withClient(supplying: TodosControllerDoubles(todoRepository: todoMock)) { todos in
            _ = try? await todos.get(id: "a/b")
        }
        verify(todoMock, times: 1).find(id: "a/b")
    }
}
