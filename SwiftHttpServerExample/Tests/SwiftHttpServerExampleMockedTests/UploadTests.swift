// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Controllers
import Foundation
import Testing
import WireMVCTesting

/// `POST /upload` over the wire: `@MultipartSummary` on the `.readerBody` tier.
///
/// The parser has its own suite in `Controllers`, driven at every chunk size. What is left to prove here is
/// the wiring — that the terminal hands the binding the reader, that a real HTTP body parses, and that the
/// binding's own errors reach `@ErrorResponse` — plus the property the whole tier exists for: the handler
/// never receives the file's bytes.
///
/// Driven mostly through the **untyped** client, because these tests need real file content and
/// `MultipartForm` deliberately does not keep any — the typed client encodes files as filler of the recorded
/// length. The typed method is exercised once below, for the half that does round-trip.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct UploadTests {

    private let boundary = "----WireMVCBoundary"

    /// Builds a well-formed body. `\r\n` throughout, including before the closing delimiter — the framing a
    /// real client emits, and what the parser's tests pin.
    private func multipart(
        fields: [(String, String)],
        files: [(name: String, filename: String, type: String, content: String)]
    ) -> Data {
        var body = ""
        for (name, value) in fields {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        for file in files {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n"
            body += "Content-Type: \(file.type)\r\n\r\n\(file.content)\r\n"
        }
        body += "--\(boundary)--\r\n"
        return Data(body.utf8)
    }

    private func upload(_ body: Data, contentType: String? = nil) async throws -> TestResponse {
        try await withClient { client in
            try await client.send(
                "POST",
                "/upload",
                body: body,
                headers: ["Content-Type": contentType ?? "multipart/form-data; boundary=\(boundary)"]
            )
        }
    }

    private func fnv1a(_ text: String) -> UInt64 {
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in Array(text.utf8) { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }

    @Test("fields and files are parsed off a real request body")
    func parsesAnUpload() async throws {
        let content = "the quick brown fox"
        let response = try await upload(
            multipart(
                fields: [("title", "Write M5"), ("tag", "server")],
                files: [(name: "attachment", filename: "notes.txt", type: "text/plain", content: content)]
            )
        )
        #expect(response.status == 200)
        let receipt = try response.json(UploadReceipt.self)
        #expect(receipt.fields == ["title": "Write M5", "tag": "server"])
        #expect(receipt.files.count == 1)

        let file = try #require(receipt.files.first)
        #expect(file.name == "attachment")
        #expect(file.filename == "notes.txt")
        #expect(file.contentType == "text/plain")
        // **The point.** The handler was given a size and a checksum, never the bytes — and they are the
        // right size and checksum, so the content did arrive intact on its way past.
        #expect(file.byteCount == content.utf8.count)
        #expect(file.checksum == fnv1a(content))
    }

    /// A body large enough to span many reads, so the delimiter search really does cross chunk boundaries on
    /// a live transport rather than only in the parser's own suite.
    @Test("a large file crosses many reads and still checksums correctly")
    func largeFile() async throws {
        let content = String(repeating: "0123456789abcdef", count: 8192)  // 128 KiB
        let response = try await upload(
            multipart(
                fields: [("title", "big")],
                files: [(name: "blob", filename: "blob.bin", type: "application/octet-stream", content: content)]
            )
        )
        #expect(response.status == 200)
        let file = try #require(try response.json(UploadReceipt.self).files.first)
        #expect(file.byteCount == content.utf8.count)
        #expect(file.checksum == fnv1a(content), "no chunk dropped, duplicated, or misaligned")
    }

    @Test("several files in one upload")
    func severalFiles() async throws {
        let response = try await upload(
            multipart(
                fields: [],
                files: [
                    (name: "a", filename: "a.txt", type: "text/plain", content: "alpha"),
                    (name: "b", filename: "b.txt", type: "text/plain", content: "beta"),
                ]
            )
        )
        let receipt = try response.json(UploadReceipt.self)
        #expect(receipt.files.map(\.filename) == ["a.txt", "b.txt"])
        #expect(receipt.files.map(\.byteCount) == [5, 4])
    }

    // MARK: - What the binding refuses

    @Test("a non-multipart content type is refused")
    func wrongContentType() async throws {
        let response = try await upload(Data("{}".utf8), contentType: "application/json")
        #expect(response.status == 400)
    }

    @Test("a body that ends mid-part is refused as truncated")
    func truncatedBody() async throws {
        var body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhalf"
        body.removeLast(0)  // no closing delimiter
        let response = try await upload(Data(body.utf8))
        #expect(response.status == 400)
    }

    /// The distinguishing case. The field cap is applied *while reading*, so this is refused before the
    /// request has finished arriving — a collecting binding could only reject it after holding all of it.
    @Test("an oversized field is refused during the read")
    func oversizedField() async throws {
        let huge = String(repeating: "x", count: 128 * 1024)  // twice the field cap
        let response = try await upload(multipart(fields: [("notes", huge)], files: []))
        #expect(response.status == 400)
    }

    /// The generated typed client, for the part of the type that round-trips. Fields survive exactly; the
    /// file's *length* survives and its content does not, which is what a value holding a checksum instead
    /// of bytes can honestly encode.
    @Test("the typed client round-trips fields, and a file's shape")
    func typedClientRoundTrip() async throws {
        try await withClient(for: UploadControllerClient.self) { upload in
            let sent = MultipartForm(
                fields: [("title", "Write M5")],
                files: [
                    MultipartFile(
                        name: "attachment",
                        filename: "notes.txt",
                        contentType: "text/plain",
                        byteCount: 19,
                        checksum: 0
                    )
                ]
            )
            let receipt = try await upload.receive(form: sent)
            #expect(receipt.fields == ["title": "Write M5"])
            #expect(receipt.files.map(\.filename) == ["notes.txt"])
            #expect(receipt.files.map(\.byteCount) == [19], "the length round-trips; the content cannot")
        }
    }
}
