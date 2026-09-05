// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
// Unconditional — see the note atop `MultipartParser.swift`.
import Foundation
public import HTTPTypes
public import WireMVC

// `@MultipartSummary` — the binding WireMVC's `.readerBody` tier was built for, declared outside WireMVC
// like every other binding in this repo.
//
// **Named for what it hands back, not for what it reads.** It reads every byte of the upload; it hands the
// handler a `MultipartForm` holding the small fields in full and, per file, a name, size and checksum —
// never the content. A name ending in `Body` would promise the handler the one thing it never receives.
//
// `@FormBody` and `@YAMLBody` take `body: [UInt8]?`: the terminal collects the whole request first. That is
// fine for a login form and wrong for an upload, which is the one shape of request whose size the server
// does not choose. This one conforms to `RequestBodyReading` instead, so it is handed the reader and
// walks it — peak memory is one chunk plus the fields it has decided to keep, whatever the upload's size.
//
// For the sibling that lets the handler act *before* the upload finishes, see `MultipartStream.swift`;
// `UploadController.swift` sets the two side by side.
//
// Multipart *out* already exists next door (`MultiPartSender`, a sender-transforming middleware). This
// closes the other direction, and neither required a change to WireMVC.

/// A file part, **without its bytes**.
///
/// This is where an example has to be honest about what it is not doing. A production binding would stream
/// each file part somewhere durable — a temporary file, an object store — and hand back a handle. The seam
/// for that is exactly `MultipartEvent.partData`, which arrives a chunk at a time; what changes is where
/// those chunks go. Retaining them in memory to build a `[UInt8]` would undo the entire point, so this
/// records what can be known without keeping them.
public struct MultipartFile: Sendable, Codable, Equatable {
    /// The form field name (`Content-Disposition: form-data; name="..."`).
    public let name: String
    /// The client-supplied filename. **Untrusted** — never use it as a path.
    public let filename: String?
    public let contentType: String?
    public let byteCount: Int
    /// FNV-1a over the part's bytes, folded chunk by chunk. Enough to prove in a test that the content
    /// arrived intact, without the content having been kept.
    public let checksum: UInt64

    public init(name: String, filename: String?, contentType: String?, byteCount: Int, checksum: UInt64) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.checksum = checksum
    }
}

/// A parsed `multipart/form-data` body: small fields in memory, file parts summarised.
public struct MultipartForm: Sendable, Codable, Equatable {
    /// Non-file fields, in order. An array rather than a dictionary because form encoding has no unique-key
    /// rule — the same reason `@FormBody` keeps its fields ordered.
    public let fields: [(name: String, value: String)]
    public let files: [MultipartFile]

    public init(fields: [(name: String, value: String)], files: [MultipartFile]) {
        self.fields = fields
        self.files = files
    }

    public func value(named name: String) -> String? {
        fields.first { $0.name == name }?.value
    }

    // Hand-written because a tuple array is not `Codable` on its own. Encoded as an array of objects so the
    // JSON says what it means and repetition survives.
    fileprivate struct Field: Codable, Equatable {
        let name: String
        let value: String
    }
    private enum CodingKeys: String, CodingKey { case fields, files }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = try container.decode([Field].self, forKey: .fields).map { ($0.name, $0.value) }
        files = try container.decode([MultipartFile].self, forKey: .files)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fields.map { Field(name: $0.name, value: $0.value) }, forKey: .fields)
        try container.encode(files, forKey: .files)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.files == rhs.files && lhs.fields.map(Field.init) == rhs.fields.map(Field.init)
    }
}

extension MultipartForm.Field {
    fileprivate init(_ pair: (name: String, value: String)) {
        self.init(name: pair.name, value: pair.value)
    }
}

/// What this binding refuses, in its **own** vocabulary.
///
/// Not the parser's `MultipartError` alone: a route maps failures with `@ErrorResponse(E.self, …)` and can
/// only name a type it can see. A binding that let another layer's error escape would make every such
/// failure an unmapped 500 — the lesson `YAMLBody` learned the hard way.
public enum MultipartBindingError: Error, Equatable {
    case notMultipart(contentType: String?)
    case malformed(MultipartError)
    /// A non-file field exceeded what this binding will hold in memory. Thrown **during** the walk: the
    /// request is refused before the rest of it has been read, which a collecting binding cannot do.
    case fieldTooLarge(name: String)
    case tooManyParts
}

/// `@MultipartSummary form: MultipartForm` — parses an upload without holding it.
@RequestBinding(.readerBody)
@propertyWrapper
public struct MultipartSummary<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }

    /// Caps, applied while reading rather than after. A field is a form input and has no business being
    /// large; the part count bounds a body made entirely of empty parts, which is otherwise cheap to send
    /// and unbounded to accumulate.
    public static var maximumFieldBytes: Int { 64 * 1024 }
    public static var maximumParts: Int { 256 }
}

extension MultipartSummary: RequestBodyReading where Value == MultipartForm {
    public static func bindReader<Reader: AsyncReader & ~Copyable>(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        reader: consuming Reader,
        coding: WireMVCCoding
    ) async throws -> MultipartForm
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
        let contentType = request.headerFields[.contentType]
        guard let boundary = multipartBoundary(from: contentType) else {
            throw MultipartBindingError.notMultipart(contentType: contentType)
        }

        var accumulator = MultipartAccumulator()
        var parser = MultipartParser(boundary: boundary)
        do {
            try await WireMVCRequest.streamBody(reader, into: &accumulator) { accumulator, span in
                try parser.consume(span) { try accumulator.handle($0) }
            }
            try parser.finish()
        } catch let error as MultipartError {
            throw MultipartBindingError.malformed(error)
        }
        return accumulator.form
    }
}

/// The client half: a `MultipartForm` encoded back into a `multipart/form-data` body.
///
/// Fields round-trip exactly. File parts cannot: this type records a size and a checksum and deliberately
/// never held the content, so it is sent as `byteCount` bytes of filler under the right name, filename and
/// content type. That is a faithful encoding of *what the value knows* rather than a pretence — and the
/// asymmetry is inherent to a parsed representation that discards content on purpose, not an oversight in
/// the encoder. A caller wanting to upload real content builds the body itself; this exists so the route is
/// reachable from the generated typed client at all, which without any send conformance it is not.
extension MultipartSummary: RequestBodySendable where Value == MultipartForm {
    /// Fixed rather than random, because the generated client is used from tests and a body that differs
    /// between runs is a bad default for anything that might be recorded or compared.
    private static var clientBoundary: String { "WireMVCMultipartBoundary" }

    public static func sendBody(
        name: String,
        value: MultipartForm,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        var bytes: [UInt8] = []
        func append(_ text: String) { bytes.append(contentsOf: text.utf8) }

        for field in value.fields {
            append("--\(clientBoundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append(field.value)
            append("\r\n")
        }
        for file in value.files {
            append("--\(clientBoundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.name)\"")
            if let filename = file.filename { append("; filename=\"\(filename)\"") }
            append("\r\n")
            if let contentType = file.contentType { append("Content-Type: \(contentType)\r\n") }
            append("\r\n")
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "\0"), count: file.byteCount))
            append("\r\n")
        }
        append("--\(clientBoundary)--\r\n")
        return (bytes, "multipart/form-data; boundary=\(clientBoundary)")
    }
}

/// Folds parser events into a form. Separate from the binding so the walk's state is one value with one
/// invariant, rather than a handful of `var`s captured by a closure.
private struct MultipartAccumulator {
    private var fields: [(name: String, value: String)] = []
    private var files: [MultipartFile] = []
    private var current: Current?

    private struct Current {
        let name: String
        let filename: String?
        let contentType: String?
        /// A file part keeps only a running digest; a field keeps its bytes, up to the cap.
        var bytes: [UInt8] = []
        var byteCount = 0
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var isFile: Bool { filename != nil }
    }

    var form: MultipartForm { MultipartForm(fields: fields, files: files) }

    mutating func handle(_ event: MultipartEvent) throws {
        switch event {
        case .partBegan(let headers):
            guard fields.count + files.count < MultipartSummary<MultipartForm>.maximumParts else {
                throw MultipartBindingError.tooManyParts
            }
            let disposition = headers.first { $0.name.lowercased() == "content-disposition" }?.value ?? ""
            current = Current(
                name: dispositionParameter("name", in: disposition) ?? "",
                filename: dispositionParameter("filename", in: disposition),
                contentType: headers.first { $0.name.lowercased() == "content-type" }?.value
            )

        case .partData(let bytes):
            guard var part = current else { return }
            part.byteCount += bytes.count
            for byte in bytes { part.checksum = (part.checksum ^ UInt64(byte)) &* 1_099_511_628_211 }
            if !part.isFile {
                guard part.byteCount <= MultipartSummary<MultipartForm>.maximumFieldBytes else {
                    throw MultipartBindingError.fieldTooLarge(name: part.name)
                }
                part.bytes.append(contentsOf: bytes)
            }
            current = part

        case .partEnded:
            guard let part = current else { return }
            if part.isFile {
                files.append(
                    MultipartFile(
                        name: part.name,
                        filename: part.filename,
                        contentType: part.contentType,
                        byteCount: part.byteCount,
                        checksum: part.checksum
                    )
                )
            } else {
                fields.append((part.name, String(decoding: part.bytes, as: UTF8.self)))
            }
            current = nil
        }
    }
}

/// `multipart/form-data; boundary=abc` → `abc`, quoted or not.
func multipartBoundary(from contentType: String?) -> String? {
    guard let contentType, contentType.lowercased().hasPrefix("multipart/") else { return nil }
    for parameter in contentType.split(separator: ";").dropFirst() {
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, pair[0].trimmingCharacters(in: httpWhitespace).lowercased() == "boundary" else {
            continue
        }
        let value = pair[1].trimmingCharacters(in: httpWhitespaceAndQuotes)
        return value.isEmpty ? nil : value
    }
    return nil
}

/// `form-data; name="file"; filename="a.txt"` → the named parameter's value.
func dispositionParameter(_ wanted: String, in disposition: String) -> String? {
    for parameter in disposition.split(separator: ";").dropFirst() {
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, pair[0].trimmingCharacters(in: httpWhitespace).lowercased() == wanted else {
            continue
        }
        return pair[1].trimmingCharacters(in: httpWhitespaceAndQuotes)
    }
    return nil
}
