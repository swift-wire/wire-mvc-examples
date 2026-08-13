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
}
