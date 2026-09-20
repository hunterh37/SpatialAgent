import Foundation

/// Minimal `Codable` JSON value, so `state`, `args` and `payload` round-trip
/// `additionalProperties: true` without pulling in a dependency.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode(JSONObject.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case let .string(v) = self { return v }; return nil }
    public var boolValue: Bool? { if case let .bool(v) = self { return v }; return nil }
    public var doubleValue: Double? { if case let .number(v) = self { return v }; return nil }
    public var intValue: Int? { doubleValue.map(Int.init) }
}

public struct JSONObject: Codable, Hashable, Sendable, ExpressibleByDictionaryLiteral {
    public var fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue] = [:]) { self.fields = fields }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        fields = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    public subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var out: [String: JSONValue] = [:]
        for key in c.allKeys { out[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
        fields = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in fields {
            guard let key = DynamicKey(stringValue: k) else { continue }
            try c.encode(v, forKey: key)
        }
    }
}
