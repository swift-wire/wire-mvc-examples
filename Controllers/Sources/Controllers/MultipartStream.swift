// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
import BasicContainers
public import HTTPTypes
public import WireMVC

// `@MultipartStream` — the same parser as `@MultipartSummary`, lent to the handler instead of run to
// completion. WireMVC's `.bodyStream` tier, against the sibling's `.readerBody`.
//
// **Not a memory optimisation.** `@MultipartSummary` is already flat — it folds each file into a size and a
// checksum and retains nothing. What it cannot do is stop: the parse runs to the last byte before the
// handler sees anything, so a request that was going to be rejected is read in full first.
//
// This one hands the handler the parts as they arrive, so it can reject after the first field and **never
// read the file at all** — the difference is decision latency, not peak memory. `UploadController.swift`
// sets the two routes side by side.
//
// Both drive `MultipartParser`, which is why it was written as a value fed chunks rather than a function
// over a body.

/// One part's headers. Ordinary escapable data, so a handler may keep it.
public struct MultipartPartHeaders: Sendable, Equatable {
    public let name: String
    /// Present iff this part is a file. **Untrusted** — never use it as a path.
    public let filename: String?
    public let contentType: String?
}

/// What a handler pulls on, inside `withParts`.
///
/// `~Copyable, ~Escapable`: the compiler, not a convention, stops a handler keeping this past the request.
/// It can be non-escapable — where the stream that vends it cannot — because it arrives as a **closure
/// parameter** rather than a property-wrapped function parameter, which is the shape both open compiler
/// bugs are about. See `UploadController.receiveStream`.
public protocol MultipartPartCursor: ~Copyable, ~Escapable {
    /// Advance to the next part, discarding any unread bytes of the current one. `nil` ends the body.
    mutating func nextPart() async throws -> MultipartPartHeaders?
    /// The next run of bytes of the *current* part, or `nil` at its end.
    mutating func nextChunk() async throws -> [UInt8]?
    /// Read the rest of the current part — for a small field, where that is what you want.
    mutating func collect(maximum: Int) async throws -> [UInt8]
}

/// What the binding hands the handler: a stream to be consumed exactly once.
///
/// Refines WireMVC's ``LentBodyStream``, which is where the validation step comes from: every stream the
/// `.bodyStream` tier lends has to be able to refuse a request it cannot be produced from, before the
/// terminal commits to a response. Nothing here re-states it — a conformer that has nothing to check
/// inherits the default and says nothing, and this one overrides it.
///
/// `~Copyable` but **not** `~Escapable`, which is the one place this design is weaker than intended. See
/// the note on `receiveStream` and swift-wire's ROADMAP.
public protocol MultipartPartStream: LentBodyStream, ~Copyable {
    associatedtype Cursor: MultipartPartCursor, ~Copyable, ~Escapable

    /// Consume the stream, pulling parts inside `body`. Consuming rather than mutating is what makes "read
    /// the body once" the only thing the API offers.
    consuming func withParts<T>(_ body: (inout Cursor) async throws -> T) async throws -> T
}

/// The stream the generated terminal builds. Holds the reader until the handler asks for parts.
public struct MultipartParts<Reader: AsyncReader & ~Copyable>: ~Copyable, MultipartPartStream
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    private var reader: Reader
    private let contentType: String?
    private let boundary: String?

    /// Built by the generated terminal, which spells `MultipartParts(request: request, reader: reader)`.
    ///
    /// **Non-throwing on purpose, and that is now a smaller claim than it was.** A throwing initialiser
    /// would make "the stream's init throws" a requirement on every future lent-stream type rather than
    /// this one's choice — the reason it reads the content type here and reports on it in
    /// `validateRequest()`, one statement later in the same generated terminal. What it no longer does is
    /// defer the check to the *handler*: that only worked while the handler ran before the head.
    public init(request: HTTPRequest, reader: consuming Reader) {
        self.reader = reader
        self.contentType = request.headerFields[.contentType]
        self.boundary = multipartBoundary(from: contentType)
    }

    /// The `LentBodyStream` step: a body that is not `multipart/form-data` with a boundary can never
    /// produce parts, and the request says so on its own.
    ///
    /// **It names the content type it saw**, which the old deferred check could not — `withParts` had only
    /// a `nil` boundary to report by then, so every wrong content type came back
    /// `notMultipart(contentType: nil)`. Matching what the sibling `.readerBody` binding already reports
    /// (`MultipartSummary.bindReader`) was not the point of moving the check, but it is what falls out of
    /// making it early rather than late.
    public borrowing func validateRequest() throws {
        guard boundary != nil else {
            throw MultipartBindingError.notMultipart(contentType: contentType)
        }
    }

    public consuming func withParts<T>(
        _ body: (inout MultipartCursor<Reader>) async throws -> T
    ) async throws -> T {
        // Kept, and now unreachable through a generated route: the terminal validated before the handler
        // was handed this. It stands for the direct caller — a test, or a hand-written builder — since the
        // alternative is force-unwrapping a boundary on the strength of a check made somewhere else.
        guard let boundary else {
            throw MultipartBindingError.notMultipart(contentType: contentType)
        }
        var cursor = MultipartCursor(reader: reader, boundary: boundary)
        return try await body(&cursor)
    }
}

/// The cursor: owns the reader for the duration of `withParts`, and cannot escape it.
///
/// It **owns** rather than borrows because reading mutates and a borrow gives no mutable binding. Owning
/// means its lifetime depends on nothing external, which is what `@_lifetime(immortal)` states — the one
/// piece of underscored API this design needs.
public struct MultipartCursor<Reader: AsyncReader & ~Copyable>: ~Copyable, ~Escapable, MultipartPartCursor
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    private var reader: Reader
    private var parser: MultipartParser
    /// Events the parser has resolved but the handler has not yet asked for.
    private var pending: [MultipartEvent] = []
    private var readerEnded = false
    /// Whether a part is open — i.e. whether `nextChunk` may still yield for it.
    private var inPart = false

    @_lifetime(immortal)
    init(reader: consuming Reader, boundary: String) {
        self.reader = reader
        self.parser = MultipartParser(boundary: boundary)
    }

    public mutating func nextPart() async throws -> MultipartPartHeaders? {
        // Skip whatever is left of the current part, so a handler that ignores a file's bytes pays only the
        // read and never has to remember to drain.
        while inPart { _ = try await nextChunk() }
        while true {
            if let event = dequeue() {
                if case .partBegan(let headers) = event {
                    inPart = true
                    return Self.headers(from: headers)
                }
                continue
            }
            guard try await pump() else { return nil }
        }
    }

    public mutating func nextChunk() async throws -> [UInt8]? {
        guard inPart else { return nil }
        while true {
            if let event = dequeue() {
                switch event {
                case .partData(let bytes):
                    return Array(bytes)
                case .partEnded:
                    inPart = false
                    return nil
                case .partBegan:
                    // Unreachable: a part always ends before the next begins. Re-queued rather than dropped,
                    // because losing a part header here would silently skip a file.
                    pending.insert(event, at: 0)
                    inPart = false
                    return nil
                }
            }
            guard try await pump() else {
                inPart = false
                return nil
            }
        }
    }

    public mutating func collect(maximum: Int) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let chunk = try await nextChunk() {
            bytes.append(contentsOf: chunk)
            guard bytes.count <= maximum else { throw MultipartBindingError.fieldTooLarge(name: "") }
        }
        return bytes
    }

    private mutating func dequeue() -> MultipartEvent? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Read one chunk and feed the parser. Returns `false` once the body is exhausted.
    ///
    /// Every `MultipartError` the parser raises — a malformed delimiter, oversized headers, a body that
    /// stopped mid-part — is translated into this binding's own vocabulary before it leaves. A route maps
    /// failures with `@ErrorResponse(MultipartBindingError.self, …)` and can only name a type it can see, so
    /// letting the parser's type escape makes every parse failure an unmapped 500. That is exactly what it
    /// did until a truncated body came back 500 instead of 400.
    private mutating func pump() async throws -> Bool {
        do {
            return try await pumpUnwrapped()
        } catch let error as MultipartError {
            throw MultipartBindingError.malformed(error)
        }
    }

    private mutating func pumpUnwrapped() async throws -> Bool {
        guard !readerEnded else { return false }
        // The parser and the queue move into locals for the read: `reader.read` is a mutating call on one
        // stored property whose closure mutates two others, and taking them out of `self` for the duration
        // is what keeps that a disjoint access rather than an overlapping one.
        var parser = self.parser
        var events = self.pending
        defer {
            self.parser = parser
            self.pending = events
        }
        do {
            readerEnded = try await reader.read { buffer, finalElement in
                var index = buffer.startIndex
                while index != buffer.endIndex {
                    try parser.consume(buffer.nextSpan(after: &index, maximumCount: .max)) {
                        events.append($0)
                    }
                }
                return finalElement != nil
            }
        } catch {
            // `read` is the only throwing call in the `do` and declares
            // `EitherError<Reader.ReadFailure, any Error>`, so that is what `error` is bound as — naming it
            // in the pattern was a cast that could not fail.
            //
            // Unwrapped so the binding's own errors stay mappable by `@ErrorResponse`.
            try error.unwrap()
        }
        if readerEnded { try parser.finish() }
        return true
    }

    private static func headers(from raw: [(name: String, value: String)]) -> MultipartPartHeaders {
        let disposition = raw.first { $0.name.lowercased() == "content-disposition" }?.value ?? ""
        return MultipartPartHeaders(
            name: dispositionParameter("name", in: disposition) ?? "",
            filename: dispositionParameter("filename", in: disposition),
            contentType: raw.first { $0.name.lowercased() == "content-type" }?.value
        )
    }
}

/// The binding — a property wrapper like every other one here, so `@MultipartStream stream:` reads like
/// `@JSONBody todo:`.
///
/// It **names** its stream type rather than vending a factory. A wrapper is generic over the parameter's
/// type, so a static method on it cannot resolve that generic parameter (`generic parameter 'Value' could
/// not be inferred`); the declaration is the only place left to say it.
@RequestBinding(.bodyStream, stream: "MultipartParts")
@propertyWrapper
public struct MultipartStream<Value: ~Copyable>: ~Copyable {
    public var wrappedValue: Value
    public init(wrappedValue: consuming Value) { self.wrappedValue = wrappedValue }
}
