import CoreFoundation
import Foundation

/// Keep dynamic measurement dictionaries away from NSJSONSerialization's ObjC exception path.
enum DeviceLabJSON {
    struct InvalidValue: LocalizedError {
        let path: String
        let detail: String
        var errorDescription: String? { "Invalid diagnostic JSON at \(path): \(detail)" }
    }

    static func encode(_ object: [String: Any], prettyPrinted: Bool = true) throws -> Data {
        let value = try Value(object, path: "$", depth: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }

    private indirect enum Value: Encodable {
        case null, boolean(Bool), string(String), signed(Int64), unsigned(UInt64), number(Double)
        case array([Value]), object([String: Value])

        init(_ value: Any, path: String, depth: Int) throws {
            guard depth <= 64 else { throw InvalidValue(path: path, detail: "nesting exceeds 64 levels") }
            // Refuse boxed optionals explicitly; never silently turn missing measurements into zero.
            guard Mirror(reflecting: value).displayStyle != .optional else {
                throw InvalidValue(path: path, detail: String(reflecting: type(of: value)))
            }
            if value is NSNull { self = .null }
            else if let text = value as? String { self = .string(text) }
            else if type(of: value) == CGFloat.self, let scalar = value as? CGFloat {
                let number = Double(scalar)
                guard number.isFinite else { throw InvalidValue(path: path, detail: "non-finite CGFloat") }
                self = .number(number)
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .boolean(number.boolValue) }
                else if ["f", "d"].contains(String(cString: number.objCType)) {
                    guard number.doubleValue.isFinite else { throw InvalidValue(path: path, detail: "non-finite number") }
                    self = .number(number.doubleValue)
                } else if number.stringValue.hasPrefix("-") { self = .signed(number.int64Value) }
                else { self = .unsigned(number.uint64Value) }
            } else if let values = value as? [String: Any] {
                var converted: [String: Value] = [:]
                for key in values.keys.sorted() {
                    converted[key] = try Value(values[key]!, path: path + "." + key, depth: depth + 1)
                }
                self = .object(converted)
            } else if let values = value as? [Any] {
                self = .array(try values.enumerated().map {
                    try Value($0.element, path: "\(path)[\($0.offset)]", depth: depth + 1)
                })
            } else { throw InvalidValue(path: path, detail: String(reflecting: type(of: value))) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .boolean(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .signed(let value): try container.encode(value)
            case .unsigned(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}
