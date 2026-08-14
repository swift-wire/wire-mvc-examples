package import Controllers
import Foundation
import Testing
import WireMVCTesting

/// `POST /upload/stream` — the same multipart parser as `/upload`, but **lent** to the handler.
///
/// `/upload` streams the parse and hands back a finished `MultipartForm`; the handler cannot act until the
/// last byte has arrived. These tests are about the difference: acting on part *n* before part *n+1* exists,
/// and abandoning an upload without reading the rest of it.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct StreamedUploadTests {

    private let boundary = "----WireMVCBoundary"

    private func body(fields: [(String, String)], files: [(name: String, filename: String, content: String)]) -> Data {
        var text = ""
        for (name, value) in fields {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        for file in files {
            text += "--\(boundary)\r\n"
            text += "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n"
            text += "Content-Type: application/octet-stream\r\n\r\n\(file.content)\r\n"
        }
        return Data((text + "--\(boundary)--\r\n").utf8)
    }

    private func post(_ payload: Data) async throws -> TestResponse {
        try await withClient { client in
            try await client.send(
                "POST",
                "/upload/stream",
                body: payload,
                headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
            )
        }
    }

    @Test("fields and files arrive in order, and each file's bytes are counted as they stream")
    func readsEverything() async throws {
        let response = try await post(
            body(
                fields: [("token", "letmein"), ("title", "Write M5")],
                files: [(name: "blob", filename: "a.bin", content: String(repeating: "x", count: 5000))]
            )
        )
        #expect(response.status == 200)
        let receipt = try response.json(StreamedUploadReceipt.self)
        #expect(receipt.fields["title"] == "Write M5")
        #expect(receipt.read == ["a.bin": 5000], "counted a chunk at a time, never held whole")
    }

    /// **The claim no collecting binding can make.** The handler rejects on the first field, so the file that
    /// follows is never read — `read` is empty rather than containing a zero-length entry, which is the
    /// difference between "skipped it" and "read nothing".
    @Test("rejecting on the first field means the file is never read")
    func abandonsBeforeReadingTheFile() async throws {
        let response = try await post(
            body(
                fields: [("token", "wrong")],
                files: [(name: "blob", filename: "big.bin", content: String(repeating: "x", count: 200_000))]
            )
        )
        #expect(response.status == 401, "@ErrorResponse(UploadRejected.self, .unauthorized)")
    }

    /// A handler may ignore a file's bytes entirely and carry on to the next part. `nextPart` skips whatever
    /// is unread, so "I don't want this one" costs the read and nothing else — no draining to remember.
    @Test("an unread part is skipped, and later parts still arrive")
    func skipsUnreadParts() async throws {
        let response = try await post(
            body(
                fields: [("token", "letmein")],
                files: [
                    (name: "a", filename: "a.bin", content: "first"),
                    (name: "b", filename: "b.bin", content: "second"),
                ]
            )
        )
        let receipt = try response.json(StreamedUploadReceipt.self)
        #expect(receipt.read == ["a.bin": 5, "b.bin": 6], "both files reached, in order")
    }

    /// The binding's failures still map, because they are raised inside the handler's first pull — before
    /// any response head is written, which is what keeps a buffered response mode's `@ErrorResponse` in play.
    @Test("a non-multipart request is refused")
    func wrongContentType() async throws {
        let response = try await withClient { client in
            try await client.send(
                "POST",
                "/upload/stream",
                body: Data("{}".utf8),
                headers: ["Content-Type": "application/json"]
            )
        }
        #expect(response.status == 400)
    }

    @Test("a truncated body is refused rather than accepted as short")
    func truncated() async throws {
        let half = "--\(boundary)\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nletmein"
        let response = try await post(Data(half.utf8))
        #expect(response.status == 400)
    }
}
