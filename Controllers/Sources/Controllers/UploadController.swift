// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import Wire
public import WireMVC

// Two upload routes, and the one thing that separates them.
//
// `POST /upload` binds `@MultipartSummary` (WireMVC's `.readerBody` tier); `POST /upload/stream` binds
// `@MultipartStream` (the `.bodyStream` tier). Both are declared in this module rather than in WireMVC,
// both drive the same `MultipartParser`, and **neither ever holds the upload** — peak memory is one chunk
// plus the small fields either way. The difference is not memory.
//
// The difference is *when the handler can act*, and so whether the bytes are read at all.
// `@MultipartSummary` runs the parse to completion and hands back a finished `MultipartForm`: every byte is
// read and folded into a size and a checksum, none is retained, and the handler starts after the last one.
// A 2 GB upload leaves this method holding a few hundred bytes of summary — but the client still sent 2 GB.
// `@MultipartStream` lends the parts as they arrive, so the handler can decide on the first field and never
// read the file: `@ErrorResponse` turns that into a 401 while the upload is still in flight, and the server
// answers with `Connection: close` rather than draining it.
//
// So: the summary when the answer needs the whole form, the stream when the answer might be *no*. Both
// routes are otherwise deliberately dull — they echo what the binding produced.
//
// It also completes the pair with `MultiPartExport`: `GET /export` streams `multipart/mixed` **out** through
// a sender-transforming middleware, and these read `multipart/form-data` **in**. Neither direction required
// a change to WireMVC.

public struct UploadRejected: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// What the streaming endpoint reports: what it *chose* to read.
public struct StreamedUploadReceipt: Codable, Sendable, Equatable {
    public let fields: [String: String]
    /// Filename → bytes actually read. A file the handler skipped is absent entirely.
    public let read: [String: Int]

    public init(fields: [String: String], read: [String: Int]) {
        self.fields = fields
        self.read = read
    }
}

/// What the upload endpoint reports back.
public struct UploadReceipt: Codable, Sendable, Equatable {
    /// The text fields, echoed.
    public let fields: [String: String]
    /// One entry per file part — name, filename, type, size and checksum, but no content.
    public let files: [MultipartFile]

    public init(fields: [String: String], files: [MultipartFile]) {
        self.fields = fields
        self.files = files
    }
}

@Singleton
@Controller("/upload")
public struct UploadController: Sendable {

    /// `POST /upload` — `multipart/form-data` in, a JSON receipt out.
    ///
    /// Every `@ErrorResponse` here maps a failure the *binding* raises, in the binding's own vocabulary:
    /// a wrong content type, a malformed body, or a field that grew past what the binding will hold. The
    /// last two are decided **while reading**, so an oversized or malformed upload is refused before the
    /// client has finished sending it — the concrete thing streaming buys over collecting.
    @Post
    @JSONResponse
    @ErrorResponse(MultipartBindingError.self, .badRequest)
    public func receive(@MultipartSummary form: MultipartForm) -> UploadReceipt {
        UploadReceipt(
            fields: Dictionary(form.fields, uniquingKeysWith: { _, last in last }),
            files: form.files
        )
    }

    /// `POST /upload/stream` — the same parser, **lent** to the handler.
    ///
    /// The route above receives a finished `MultipartForm`: memory stays flat, but nothing can happen until
    /// the last byte has arrived. Here the handler pulls, so it decides on the first field and — when that
    /// decision is "no" — **never reads the file**. That is the property no collecting binding can express
    /// at any price, and the whole reason the streaming tier exists.
    ///
    /// **The signature carries two live compiler limitations, and it is worth knowing which is which.**
    ///
    /// `_stream.wrappedValue` rather than `stream`: referencing a property-wrapped non-copyable parameter
    /// crashes SILGen (swiftlang/swift#81624, open since May 2025 and still present on 6.3.3 and 6.4-dev).
    /// Reaching the backing store directly is that issue's documented workaround, and it is the only reason
    /// this compiles.
    ///
    /// `Stream` is `~Copyable` but **not** `~Escapable`, which is what this design wants. Adding it turns
    /// the crash into `copy of noncopyable typed value. This is a compiler bug.` — swiftlang/swift#91473, a
    /// second bug that defeats the first one's workaround. So a handler *could* move this stream into a
    /// class rather than consuming it here; nothing but this comment stops it. What that buys an attacker is a spent
    /// reader, not a dangling one — the stream owns its reader outright, with no heap box — and the safe
    /// path is the only one the API offers.
    ///
    /// The guarantee survives where it counts: `parts` below is `~Copyable, ~Escapable`, so **the thing
    /// that can read the socket provably cannot be kept**. It escapes both bugs by being a closure
    /// parameter rather than a property-wrapped one.
    ///
    /// `inout` would read better than `consuming` and is not available: SE-0293 defers property wrappers on
    /// `inout` parameters deliberately, on the grounds that mutations which look observable to the caller
    /// are not. That one is a design decision upstream, not a bug, and worth respecting.
    @Post("/stream")
    @JSONResponse
    @ErrorResponse(UploadRejected.self, .unauthorized)
    @ErrorResponse(MultipartBindingError.self, .badRequest)
    public func receiveStream<Stream: MultipartPartStream & ~Copyable>(
        @MultipartStream stream: consuming Stream
    ) async throws -> StreamedUploadReceipt {
        var fields: [String: String] = [:]
        var read: [String: Int] = [:]

        return try await _stream.wrappedValue.withParts { parts in
            while let part = try await parts.nextPart() {
                guard let filename = part.filename else {
                    let value = try await parts.collect(maximum: 64 * 1024)
                    fields[part.name] = String(decoding: value, as: UTF8.self)
                    // The decision, taken on a field that arrives *before* the file. Throwing here abandons
                    // the upload: the bytes still in flight are never read, and the server closes the
                    // connection rather than draining them.
                    if part.name == "token", fields[part.name] != "letmein" {
                        throw UploadRejected(reason: "bad token")
                    }
                    continue
                }
                // A real handler appends each chunk to a file or an object store. Counting is enough to
                // show the bytes arrived a chunk at a time and were never all held at once.
                var count = 0
                while let chunk = try await parts.nextChunk() { count += chunk.count }
                read[filename] = count
            }
            return StreamedUploadReceipt(fields: fields, read: read)
        }
    }
}
