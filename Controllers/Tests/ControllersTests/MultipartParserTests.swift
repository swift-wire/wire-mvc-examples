// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import Controllers

/// The multipart parser, driven directly — no server, no route.
///
/// Every test runs its input at **every chunk size from 1 byte to whole**, because that is where the bugs
/// are. A parser is easy to get right on a single buffer and wrong the moment a delimiter straddles two
/// reads, and the streaming tier exists precisely so that reads are small and numerous. A suite that fed
/// whole messages would pass on a parser that corrupts every real upload.
@Suite("Multipart parser")
struct MultipartParserTests {

    /// One part, as the parser resolved it. Data is joined so a test asserts on content rather than on how
    /// the chunking happened to split it — which is the property that must *not* vary.
    struct Part: Equatable {
        var headers: [String: String] = [:]
        var body: [UInt8] = []
    }

    /// Run `input` through the parser in `chunkSize`-byte pieces.
    private func parse(_ input: [UInt8], boundary: String, chunkSize: Int) throws -> [Part] {
        var parser = MultipartParser(boundary: boundary)
        var parts: [Part] = []
        var current: Part?
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkSize, input.count)
            try parser.consume(input[offset..<end]) { event in
                switch event {
                case .partBegan(let headers):
                    current = Part(headers: Dictionary(headers, uniquingKeysWith: { _, last in last }))
                case .partData(let bytes):
                    current?.body.append(contentsOf: bytes)
                case .partEnded:
                    if let part = current { parts.append(part) }
                    current = nil
                }
            }
            offset = end
        }
        try parser.finish()
        return parts
    }

    /// Every chunk size must give the same answer. Returns it, so a caller asserts once.
    private func parseAtEveryChunkSize(
        _ text: String,
        boundary: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [Part] {
        let input = Array(text.utf8)
        let whole = try parse(input, boundary: boundary, chunkSize: input.count)
        for chunkSize in 1..<input.count {
            let chunked = try parse(input, boundary: boundary, chunkSize: chunkSize)
            #expect(chunked == whole, "chunk size \(chunkSize) parsed differently", sourceLocation: sourceLocation)
        }
        return whole
    }

    private func body(_ lines: String...) -> String { lines.joined(separator: "\r\n") }

    // MARK: - Well-formed input

    @Test("a single field")
    func singleField() throws {
        let parts = try parseAtEveryChunkSize(
            body(
                "--X",
                "Content-Disposition: form-data; name=\"title\"",
                "",
                "Write M5",
                "--X--",
                ""
            ),
            boundary: "X"
        )
        #expect(parts.count == 1)
        #expect(parts[0].headers["Content-Disposition"] == "form-data; name=\"title\"")
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "Write M5")
    }

    @Test("several parts, with headers each")
    func severalParts() throws {
        let parts = try parseAtEveryChunkSize(
            body(
                "--X",
                "Content-Disposition: form-data; name=\"title\"",
                "",
                "Write M5",
                "--X",
                "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"",
                "Content-Type: text/plain",
                "",
                "hello",
                "--X--",
                ""
            ),
            boundary: "X"
        )
        #expect(parts.count == 2)
        #expect(parts[1].headers["Content-Type"] == "text/plain")
        #expect(String(decoding: parts[1].body, as: UTF8.self) == "hello")
    }

    /// The CRLF before a delimiter belongs to the delimiter, not the body. Emitting it would append two
    /// bytes to every part — invisible in a text field, corruption in a file.
    @Test("the delimiter's leading CRLF is not part of the body")
    func trailingCRLFIsNotBodyData() throws {
        let parts = try parseAtEveryChunkSize(
            body("--X", "Content-Disposition: form-data; name=\"a\"", "", "data", "--X--", ""),
            boundary: "X"
        )
        #expect(parts[0].body == Array("data".utf8), "no trailing CRLF")
    }

    /// A body that *contains* CRLFs keeps them — only the final one before a delimiter is framing.
    @Test("CRLFs inside a body survive")
    func interiorCRLFs() throws {
        let parts = try parseAtEveryChunkSize(
            body("--X", "Content-Disposition: form-data; name=\"a\"", "", "one", "two", "three", "--X--", ""),
            boundary: "X"
        )
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "one\r\ntwo\r\nthree")
    }

    @Test("an empty part body")
    func emptyBody() throws {
        let parts = try parseAtEveryChunkSize(
            body("--X", "Content-Disposition: form-data; name=\"a\"", "", "", "--X--", ""),
            boundary: "X"
        )
        #expect(parts.count == 1)
        #expect(parts[0].body.isEmpty)
    }

    /// The RFC allows a preamble before the first boundary, and some clients emit one. It is discarded.
    @Test("a preamble is discarded")
    func preambleDiscarded() throws {
        let parts = try parseAtEveryChunkSize(
            body("ignore me", "--X", "Content-Disposition: form-data; name=\"a\"", "", "v", "--X--", ""),
            boundary: "X"
        )
        #expect(parts.count == 1)
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "v")
    }

    /// Text that looks like a delimiter but is not one — no CRLF before it — is data. Getting this wrong
    /// splits a part in half at attacker-chosen content.
    @Test("boundary-like text mid-line is data, not a delimiter")
    func boundaryLikeTextIsData() throws {
        let parts = try parseAtEveryChunkSize(
            body("--X", "Content-Disposition: form-data; name=\"a\"", "", "prefix--X suffix", "--X--", ""),
            boundary: "X"
        )
        #expect(parts.count == 1)
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "prefix--X suffix")
    }

    // MARK: - Malformed input

    @Test("a body that ends mid-part is truncated, not accepted")
    func truncatedBody() {
        let input = Array(body("--X", "Content-Disposition: form-data; name=\"a\"", "", "half").utf8)
        #expect(throws: MultipartError.truncated) {
            _ = try parse(input, boundary: "X", chunkSize: input.count)
        }
    }

    @Test("headers that never end are refused rather than buffered without bound")
    func headersTooLarge() {
        var input = Array("\r\n--X\r\n".utf8)
        input.append(contentsOf: Array(repeating: UInt8(ascii: "h"), count: MultipartParser.maximumHeaderBytes + 1))
        #expect(throws: MultipartError.headersTooLarge) {
            _ = try parse(input, boundary: "X", chunkSize: input.count)
        }
    }

    @Test("a header line with no colon is skipped, not fatal")
    func malformedHeaderLineSkipped() throws {
        let parts = try parseAtEveryChunkSize(
            body("--X", "not-a-header", "Content-Disposition: form-data; name=\"a\"", "", "v", "--X--", ""),
            boundary: "X"
        )
        #expect(parts[0].headers.count == 1)
        #expect(parts[0].headers["Content-Disposition"] != nil)
    }
}
