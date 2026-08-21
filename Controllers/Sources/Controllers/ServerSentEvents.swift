public import AsyncStreaming
public import HTTPTypes
public import WireMVC

import BasicContainers

// Server-sent events as a **response mode**, declared entirely outside WireMVC — the third instance of the
// codec extension point, after `@FormBody`/`@YAMLResponse`, and the first on the *streaming* tier.
//
// It lives in `Controllers` rather than in a sibling package because it needs no third-party dependency:
// SSE is a byte framing, not a library. `HTMLForm` and `YAMLConfig` are separate packages because they pull
// in Elementary and Yams and this package is deliberately lean — that reason does not apply here.
//
// What it replaces is a `@RawRoute`. The old `/todos/stream` handler took the response sender verbatim,
// built the head itself, framed each event inline and terminated the body by hand. Everything in that list
// except the framing is what the tier already does, and the framing is what a codec is.

/// One server-sent event.
///
/// Only the fields the wire format defines, and all of them optional except `data` — a comment-only event
/// (a keep-alive) has no `data`, but nothing here needs one yet, so `data` is required and the rest are
/// spelled but unused by the current route. Modelling the format rather than the one field this app sends
/// is the difference between a codec and a string join.
public struct ServerSentEvent: Sendable, Equatable {
    /// The payload. A multi-line payload is emitted as one `data:` line per line, which is how the format
    /// says to carry a newline — a single line containing `\n` would terminate the event early.
    public var data: String
    /// The event name, dispatched to a matching listener rather than the default `message` one.
    public var event: String?
    /// The event id, which the browser echoes back as `Last-Event-ID` when it reconnects.
    public var id: String?
    /// The reconnection delay in milliseconds the client should adopt.
    public var retry: Int?

    public init(data: String, event: String? = nil, id: String? = nil, retry: Int? = nil) {
        self.data = data
        self.event = event
        self.id = id
        self.retry = retry
    }

    /// The event in wire form, including its terminating blank line.
    var framed: String {
        var text = ""
        if let event { text += "event: \(event)\n" }
        if let id { text += "id: \(id)\n" }
        if let retry { text += "retry: \(retry)\n" }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            text += "data: \(line)\n"
        }
        return text + "\n"
    }
}

/// The producer `@EventStreamResponse` resolves against — what the generated terminal wraps the handler's
/// return value in.
///
/// Generic over the sequence so a handler can return whatever it has: an array it already collected, or a
/// lazily-built sequence. Each event is written as its own chunk, so a client sees events as they are
/// produced rather than at the end.
///
/// No `Sendable` requirement on `Events`, matching the tier: the producer never escapes the terminal's
/// region, and requiring it would be the only reason a handler could not return a sequence over a
/// request-scoped model object.
public struct ServerSentEventProducer<Events: Sequence>: WireMVCBodyProducer where Events.Element == ServerSentEvent {
    public let events: Events

    /// The format's own media type. Seeded by the tier unless the route names one itself, which is why the
    /// migrated route no longer sets a `Content-Type` header by hand.
    public var contentType: String? { "text/event-stream" }

    public init(_ events: Events) {
        self.events = events
    }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        for event in events {
            var bytes = UniqueArray<UInt8>(copying: Array(event.framed.utf8))
            try await writer.write(buffer: &bytes)
        }
        // The producer terminates the response itself — the tier's contract, and the reason it can keep
        // every lifetime-dependent value inside one function body.
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

/// `@EventStreamResponse` — the route returns events, streamed as `text/event-stream`.
///
/// `.streaming` says which terminal builds the response; `codec:` names the producer as a *spelling*,
/// resolved in the controller's own module. `client: .text` because there is nothing to decode back into —
/// the generated typed client hands back the undecoded body, as it does for `@HTMLResponse`.
///
/// Named for the media type rather than the acronym, and suffixed `Response` like every other mode
/// (`@JSONResponse`, `@HTMLResponse`, `@YAMLResponse`).
@ResponseMode(.streaming, codec: "ServerSentEventProducer", client: .text)
@attached(peer)
public macro EventStreamResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The `(status:)` overload, matching how WireMVC's own modes are declared.
@ResponseMode(.streaming, codec: "ServerSentEventProducer", client: .text)
@attached(peer)
public macro EventStreamResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
