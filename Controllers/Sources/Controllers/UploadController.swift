public import Wire
public import WireMVC

// An upload route bound with `@MultipartBody` — the streaming request tier, in a binding declared in this
// module rather than in WireMVC.
//
// The route is deliberately dull: it echoes what the binding parsed. The interesting property is not in the
// handler, it is in what the handler *never sees* — the file bytes. They passed through the binding a chunk
// at a time and were folded into a size and a checksum; a 2 GB upload leaves this method holding a few
// hundred bytes of summary.
//
// It also completes the pair with `MultiPartExport`: `GET /export` streams `multipart/mixed` **out** through
// a sender-transforming middleware, and this reads `multipart/form-data` **in** through a streaming binding.
// Neither direction required a change to WireMVC.

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
    @ErrorResponse(MultipartBodyError.self, .badRequest)
    public func receive(@MultipartBody form: MultipartForm) -> UploadReceipt {
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
    @ErrorResponse(MultipartBodyError.self, .badRequest)
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
