// An incremental `multipart/form-data` parser (RFC 7578, framing per RFC 2046 §5.1).
//
// Incremental because that is the whole point: it is fed one chunk at a time off the request body reader and
// emits events as it resolves them, so a 2 GB upload never exists in memory. `MultiPartSender` next door
// already streams multipart *out*; this is the other direction.
//
// **Boundary detection across chunks is the hard part, and the classic vulnerability.** A delimiter can be
// split across two reads, so the parser must retain a tail of bytes it cannot yet classify, and must not
// emit them as part data in the meantime. The tests for this live in `MultipartParserTests` and drive the
// same input at every chunk size, because a parser that is correct on whole-message input and wrong on a
// split is exactly the bug that ships.

/// What the parser resolves, in order: one `partBegan` per part, zero or more `partData`, one `partEnded`.
public enum MultipartEvent {
    case partBegan(headers: [(name: String, value: String)])
    /// A run of body bytes. Not necessarily a whole part, and never spanning parts.
    case partData(ArraySlice<UInt8>)
    case partEnded
}

public enum MultipartError: Error, Equatable {
    /// No `boundary=` parameter on the request's `Content-Type`.
    case missingBoundary
    /// The body ended before the closing `--boundary--`.
    case truncated
    /// A part's headers exceeded ``MultipartParser/maximumHeaderBytes`` without a blank line — either
    /// malformed, or an attempt to make the parser buffer without bound.
    case headersTooLarge
    /// A header line that is not `name: value`.
    case malformedHeader(String)
}

/// Feeds on chunks, emits events. One per request body.
///
/// A struct with an explicit `consume`/`finish` pair rather than an `AsyncSequence`: it is driven from
/// inside `WireMVCRequest.streamBody`'s callback, which hands over a borrowed `Span` per chunk, and an
/// async iterator would require that span to escape.
public struct MultipartParser {
    /// The cap on one part's header block. A part whose headers never terminate would otherwise grow
    /// `pending` for as long as the client keeps sending.
    public static let maximumHeaderBytes = 16 * 1024

    /// `\r\n--boundary`. The CRLF is **part of the delimiter**, not of the body before it: RFC 2046 defines
    /// the delimiter as including the preceding line break, so a part body's final bytes are whatever comes
    /// before that CRLF. Emitting the CRLF as data is a two-byte corruption of every part.
    private let delimiter: [UInt8]
    private var pending: [UInt8] = []
    private var state: State = .seekingBoundary
    private var finished = false

    private enum State {
        /// Before the first boundary (the RFC's "preamble", which is discarded), or just after one.
        case seekingBoundary
        /// Just past a delimiter, waiting on the two bytes that say whether it was the final one.
        case afterDelimiter
        case headers
        case body
    }

    public init(boundary: String) {
        // The parser always searches for `\r\n--boundary`, including for the *first* delimiter — which in a
        // well-formed body with no preamble sits at offset zero with no CRLF before it. Seeding `pending`
        // with a synthetic CRLF makes that case identical to every other, rather than a special path that
        // gets tested less.
        self.delimiter = Array("\r\n--\(boundary)".utf8)
        self.pending = Array("\r\n".utf8)
    }

    /// Feed one chunk. `emit` may be called any number of times, including zero.
    public mutating func consume(
        _ bytes: some Collection<UInt8>,
        emit: (MultipartEvent) throws -> Void
    ) throws {
        pending.append(contentsOf: bytes)
        try drain(emit: emit)
    }

    /// The overload the streaming tier calls. `WireMVCRequest.streamBody` hands over a borrowed `Span`,
    /// which is `~Escapable` and so cannot be a `Collection`; the bytes are copied into `pending` here
    /// because they must outlive the borrow — a delimiter straddling two chunks is precisely a case where
    /// this chunk's tail is needed after the span is gone.
    public mutating func consume(
        _ span: Span<UInt8>,
        emit: (MultipartEvent) throws -> Void
    ) throws {
        pending.reserveCapacity(pending.count + span.count)
        for index in 0..<span.count { pending.append(span[index]) }
        try drain(emit: emit)
    }

    /// Called once the body ends. A body that stopped mid-part is truncated, which is a failure rather than
    /// a short read: accepting it would mean handing a handler a half-uploaded file as though it were whole.
    public mutating func finish() throws {
        guard finished else { throw MultipartError.truncated }
    }

    private mutating func drain(emit: (MultipartEvent) throws -> Void) throws {
        while !finished {
            switch state {
            case .seekingBoundary:
                guard let index = firstIndexOfDelimiter() else {
                    // Discard everything that cannot begin a delimiter, keeping a possible partial one.
                    dropAllButTrailing(delimiter.count - 1)
                    return
                }
                pending.removeFirst(index + delimiter.count)
                state = .afterDelimiter

            case .afterDelimiter:
                // `--` closes the message; CRLF starts the next part's headers.
                guard pending.count >= 2 else { return }
                let pair = Array(pending.prefix(2))
                pending.removeFirst(2)
                if pair == Array("--".utf8) {
                    finished = true
                } else {
                    state = .headers
                }

            case .headers:
                guard let blankLine = firstIndex(of: Array("\r\n\r\n".utf8)) else {
                    guard pending.count <= Self.maximumHeaderBytes else {
                        throw MultipartError.headersTooLarge
                    }
                    return
                }
                let block = Array(pending.prefix(blankLine))
                pending.removeFirst(blankLine + 4)
                try emit(.partBegan(headers: Self.parseHeaders(block)))
                state = .body

            case .body:
                guard let index = firstIndexOfDelimiter() else {
                    // Everything except a possible partial delimiter is settled body data. Emitting it now
                    // rather than at the end of the part is what keeps memory flat.
                    let settled = pending.count - (delimiter.count - 1)
                    if settled > 0 {
                        try emit(.partData(pending[0..<settled]))
                        pending.removeFirst(settled)
                    }
                    return
                }
                if index > 0 { try emit(.partData(pending[0..<index])) }
                try emit(.partEnded)
                pending.removeFirst(index + delimiter.count)
                state = .afterDelimiter
            }
        }
    }

    // MARK: - Searching

    private func firstIndexOfDelimiter() -> Int? { firstIndex(of: delimiter) }

    /// Plain search. Deliberately not Boyer–Moore or similar: `pending` holds one chunk plus a delimiter's
    /// worth of tail, so the scan is bounded by the read size, and a clever matcher is where an off-by-one
    /// would hide.
    private func firstIndex(of needle: [UInt8]) -> Int? {
        guard pending.count >= needle.count else { return nil }
        let last = pending.count - needle.count
        for start in 0...last where Array(pending[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }

    private mutating func dropAllButTrailing(_ count: Int) {
        let excess = pending.count - count
        if excess > 0 { pending.removeFirst(excess) }
    }

    private static func parseHeaders(_ block: [UInt8]) -> [(name: String, value: String)] {
        String(decoding: block, as: UTF8.self)
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[line.startIndex..<colon])
                let value = String(line[line.index(after: colon)...]).trimmingLeadingSpaces()
                return (name, value)
            }
    }
}

extension String {
    fileprivate func trimmingLeadingSpaces() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
