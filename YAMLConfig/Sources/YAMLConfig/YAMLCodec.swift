public import HTTPTypes
public import WireMVC
private import Yams

#if canImport(FoundationEssentials)
private import FoundationEssentials
#else
private import Foundation
#endif

// One codec, both directions, declared **entirely outside WireMVC** — the request binding and the response
// mode around a single `YAMLCodec`.
//
// `@FormBody` proved the request half of the extension point; this proves the pair. The two halves are
// deliberately kept symmetric so the asymmetry that remains is visible: a request binding is a *type*
// carrying `@RequestBinding`, because it attaches to a parameter and a property wrapper can do that; a
// response mode is a *macro* carrying `@ResponseMode`, because it attaches to a function and only a macro
// can. Everything else about them is the same shape.

/// The codec. Generic over the value, conforming **conditionally** in each direction, so a type that can
/// only travel one way implements only that way — the shape `FormBody<Value>` and WireMVC's own
/// `WireMVCJSONCodec<Value>` both have.
public enum YAMLCodec<Value> {}

/// `application/yaml` — registered by RFC 9512, which replaced the long-standing `text/yaml` and
/// `application/x-yaml` conventions. Named once here rather than at each use, since the request and response
/// halves must agree on it.
public let yamlContentType = "application/yaml"

/// The binding's **own** error vocabulary.
///
/// Deliberately not Yams'. A route maps failures with `@ErrorResponse(YAMLError.self, .badRequest)`, and it
/// can only name a type it can see — a controller should not have to import the parser to say "a malformed
/// document is a 400". Letting the codec's error escape means every such failure is an unmapped 500, which
/// is exactly what happened here before this type had a case for it. A binding declared outside the
/// framework owns the translation; `FormBody.malformedEncoding` in `Controllers` is the same call.
public enum YAMLError: Error {
    case missingBody
    case malformedDocument(String)
}

// ─────────────────────────────────────────────────────────────────────────────
// The response half — `@YAMLResponse`
// ─────────────────────────────────────────────────────────────────────────────

extension YAMLCodec: WireMVCResponseEncoding where Value: Encodable {
    public static func encodeResponseBody(
        _ value: Value,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        ([UInt8](try YAMLEncoder().encode(value).utf8), yamlContentType)
    }
}

extension YAMLCodec: WireMVCResponseDecoding where Value: Decodable {
    public static func decodeResponseBody(_ bytes: [UInt8], coding: WireMVCCoding) throws -> Value {
        do {
            return try YAMLDecoder().decode(Value.self, from: Data(bytes))
        } catch {
            throw YAMLError.malformedDocument("\(error)")
        }
    }
}

/// `@YAMLResponse` — the route returns a value encoded as YAML.
///
/// The whole declaration. `.buffered` says which terminal builds the response, `codec:` names what encodes
/// the return, and the client half falls out of the same name (`client:` defaults to `.decoded`, so the
/// generated typed client decodes the response back into the handler's own return type through
/// ``YAMLCodec``). WireMVC learns all of it by reading this attribute; nothing registers anything.
@ResponseMode(.buffered, codec: "YAMLCodec")
@attached(peer)
public macro YAMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The `(status:)` overload, matching how WireMVC's own modes are declared. The status is read off whichever
/// annotation a route writes, so a user mode is not second-class about it.
@ResponseMode(.buffered, codec: "YAMLCodec")
@attached(peer)
public macro YAMLResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ─────────────────────────────────────────────────────────────────────────────
// The request half — `@YAMLBody`
// ─────────────────────────────────────────────────────────────────────────────

/// `@YAMLBody input: T` — decodes an `application/yaml` request body.
///
/// `@YAMLBody`, not `@YAMLRequest`: the attribute goes on a *parameter* and names that parameter's source,
/// which is what `@JSONBody` and `@FormBody` say too. `@YAMLRequest` would read as naming the whole request.
@RequestBinding(.body)
@propertyWrapper
public struct YAMLBody<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }
}

extension YAMLBody: RequestBound where Value: Decodable {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Value {
        guard let body else { throw YAMLError.missingBody }
        do {
            return try YAMLDecoder().decode(Value.self, from: Data(body))
        } catch {
            throw YAMLError.malformedDocument("\(error)")
        }
    }
}

extension YAMLBody: RequestBodySendable where Value: Decodable & Encodable {
    public static func sendBody(
        name: String,
        value: Value,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        ([UInt8](try YAMLEncoder().encode(value).utf8), yamlContentType)
    }
}
