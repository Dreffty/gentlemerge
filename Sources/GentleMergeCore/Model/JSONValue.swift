import Foundation

/// Minimal `Any`-shaped JSON value so we can carry an agent's raw hook payload
/// around without knowing its schema. Agents change their payloads between
/// releases; we keep the original bytes and only reach for the keys we know.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public func string(_ key: String) -> String? { self[key]?.stringValue }

    /// Human-readable rendering used when we have no formatter for a payload.
    public var displayText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .string(let value): return value
        case .array(let values):
            return values.map(\.displayText).joined(separator: ", ")
        case .object(let dictionary):
            return dictionary.keys.sorted()
                .compactMap { key in dictionary[key].map { "\($0.displayText)" }.map { "\(key): \($0)" } }
                .joined(separator: "\n")
        }
    }
}
