// Unconditional, deliberately. Elsewhere in this package a `#if canImport(FoundationEssentials)` guard is
// fine because those files use only APIs present in both modules (`JSONEncoder`). `CharacterSet` and the
// percent-encoding string APIs are full-Foundation only, so the same guard compiles on macOS and fails on
// Linux. Percent-encoding is security-adjacent — over-decoding, double-decoding, malformed escapes — and is
// exactly the work a standard library should be doing rather than this file.
import Foundation
public import HTTPTypes
public import WireMVC

// `@FormBody` — an `application/x-www-form-urlencoded` request binding, declared **entirely outside
// WireMVC**. Nothing in the framework names it.
//
// This is the point of the repo more than the point of the binding: WireMVC's codegen used to hardcode the
// four wrappers it ships with, in five places, so a form body was not writable without changing the
// framework. It now reads `@RequestBinding` off this declaration — which the build plugin already parses,
// because `Controllers` is a Wire-aware module — and everything else follows:
//
//   - `.body` tells the route terminal to collect the request body for it.
//   - `RequestBound` decodes it on the server.
//   - `RequestBodySendable` encodes it in the generated typed client, with its own content type.
//
// Three conformances and one attribute. No fork, no upstream change, no macro of its own.

/// A type that can be built from decoded form fields.
///
/// Deliberately not `Decodable`. A full `Decodable` bridge for form encoding is a keyed decoder of its own —
/// worth writing, and orthogonal to what this example demonstrates. Keeping the contract explicit means the
/// binding is readable end to end, which is the thing being shown.
public protocol FormDecodable {
    /// Repeated keys arrive in order, so a multi-select (`tags=a&tags=b`) is not silently reduced to one.
    init(formFields: [(name: String, value: String)]) throws
}

/// A type that can be written back out as form fields — the client half.
public protocol FormEncodable {
    var formFields: [(name: String, value: String)] { get }
}

public enum FormBodyError: Error {
    case missingBody
    case malformedEncoding(String)
    case missingField(String)
}

/// `@FormBody input: T` — decodes an `application/x-www-form-urlencoded` request body.
///
/// A property wrapper so the attribute is legal on a handler parameter, plus the conformances that carry the
/// behaviour — the same two halves WireMVC's own `@Path`/`@JSONBody` are built from. `@RequestBinding(.body)`
/// is the third thing: what the *code generator* must do, which neither half can tell it.
@RequestBinding(.body)
@propertyWrapper
public struct FormBody<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }
}

extension FormBody: RequestBound where Value: FormDecodable {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Value {
        guard let body else { throw FormBodyError.missingBody }
        return try Value(formFields: try parseFormFields(String(decoding: body, as: UTF8.self)))
    }
}

extension FormBody: RequestBodySendable where Value: FormDecodable & FormEncodable {
    public static func sendBody(
        name: String,
        value: Value,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        let encoded = value.formFields
            .map { "\(formEscape($0.name))=\(formEscape($0.value))" }
            .joined(separator: "&")
        return ([UInt8](encoded.utf8), "application/x-www-form-urlencoded")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The codec
// ─────────────────────────────────────────────────────────────────────────────

/// Split `a=1&b=2` into ordered pairs, decoding `+` as a space and `%XX` escapes.
///
/// Order and repetition are preserved: form encoding has no notion of a unique key, and collapsing to a
/// dictionary here would silently drop every value but the last of a multi-select.
public func parseFormFields(_ raw: String) throws -> [(name: String, value: String)] {
    try raw.split(separator: "&", omittingEmptySubsequences: true).compactMap { pair in
        let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = halves.first else { return nil }
        let name = try formUnescape(String(first))
        guard !name.isEmpty else { return nil }
        return (name, halves.count > 1 ? try formUnescape(String(halves[1])) : "")
    }
}

/// `+` is a space in form encoding — the one place it differs from ordinary percent-encoding.
///
/// **Throws** on a malformed escape rather than absorbing it. `removingPercentEncoding` returns `nil` for the
/// *entire string* if any escape is bad, so the obvious `?? raw` means one stray `%` silently disables
/// decoding for the whole value — `a%40b%zz` would come back with its `%40` still undecoded. Failing closed
/// is the right posture for a decoder handling untrusted input, and the route already maps `FormBodyError`
/// to a 400.
func formUnescape(_ raw: String) throws -> String {
    let spaced = raw.replacingOccurrences(of: "+", with: " ")
    guard let decoded = spaced.removingPercentEncoding else {
        throw FormBodyError.malformedEncoding(raw)
    }
    return decoded
}

func formEscape(_ raw: String) -> String {
    // RFC 3986 unreserved, and *not* Foundation's `.urlQueryAllowed`: that set leaves `&`, `=` and `+`
    // legal, so a value containing one would reshape the body it is part of.
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
}
