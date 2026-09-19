import Foundation

/// A JSON value. Tool inputs arrive from the model as arbitrary JSON and tool
/// schemas are handed back to it verbatim, so both need a representation that
/// survives a round trip without being modelled as a concrete Swift type.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Reading

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
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

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    // MARK: - Foundation bridging

    /// Wraps the output of `JSONSerialization`. `NSNumber` cannot be told apart
    /// from a boxed `Bool` by type alone, so booleans are detected by comparing
    /// against the CFBoolean type id — the usual `is Bool` check would report
    /// true for any number.
    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// A value `JSONSerialization` can encode.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // Emit whole numbers as integers so a tool argument of 10 does not
            // reach the model (or a shell) as "10.0".
            if value.rounded() == value, value.magnitude < 9.007e15 {
                return Int(value)
            }
            return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(any: object)
    }

    public static func parse(_ string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parse(data)
    }

    public func encoded() -> Data {
        (try? JSONSerialization.data(
            withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
    }

    public func encodedString() -> String {
        String(data: encoded(), encoding: .utf8) ?? ""
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
