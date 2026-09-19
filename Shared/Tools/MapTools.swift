import Foundation
import MCP

nonisolated struct MapTools: Sendable {
    let service: any MapServicing

    static let toolNames = Set(tools.map(\.name))

    static let tools: [Tool] = [
        Tool(
            name: "search_places",
            description: "Search Apple Maps for places, businesses, landmarks, or addresses. Set near_current_location for queries such as nearby coffee; location is requested only when this is true.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Natural-language place, business, category, landmark, or address query."],
                    "near_current_location": ["type": "boolean", "description": "Bias results to the device's current location (default false)."],
                    "radius_km": ["type": "number", "description": "Search radius around current location, 0.1-100 km (default 10). Used only with near_current_location."],
                    "limit": ["type": "integer", "description": "Maximum results, 1-10 (default 5)."],
                ],
                "required": ["query"],
            ]),
        Tool(
            name: "estimate_travel_time",
            description: "Estimate travel time and distance with Apple Maps. Returns an ETA summary, not turn-by-turn directions. Origin defaults to current location when omitted.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "origin": ["type": "string", "description": "Starting place or address. Omit to use current location."],
                    "destination": ["type": "string", "description": "Destination place or address."],
                    "use_current_location": ["type": "boolean", "description": "Use device location as origin. Defaults true when origin is omitted; don't combine with origin."],
                    "transport": ["type": "string", "enum": ["driving", "walking", "transit", "cycling"], "description": "Travel mode."],
                    "departure_date": ["type": "string", "description": "Optional ISO 8601 departure time. Don't combine with arrival_date."],
                    "arrival_date": ["type": "string", "description": "Optional ISO 8601 desired arrival time. Don't combine with departure_date."],
                ],
                "required": ["destination", "transport"],
            ]),
    ]

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        #if os(macOS)
        let start = Date()
        let result = await dispatch(name: name, arguments: arguments)
        let chars = result.content.reduce(0) { total, item in
            if case let .text(text, _, _) = item { return total + text.count }
            return total
        }
        await Log.tool(
            name: name,
            arguments: Self.jsonObject(arguments),
            isError: result.isError == true,
            resultChars: chars,
            durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
        #else
        return await dispatch(name: name, arguments: arguments)
        #endif
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "search_places":
                let query = try Self.requiredString("query", in: arguments)
                return Self.json(try await service.searchPlaces(
                    query: query,
                    nearCurrentLocation: try Self.optionalBool(
                        "near_current_location", in: arguments, default: false),
                    radiusKilometers: try Self.optionalNumber(
                        "radius_km", in: arguments, default: 10),
                    limit: try Self.optionalInt("limit", in: arguments, default: 5)))
            case "estimate_travel_time":
                let destination = try Self.requiredString("destination", in: arguments)
                let transport = try Self.requiredString("transport", in: arguments)
                let origin = try Self.optionalString("origin", in: arguments)
                return Self.json(try await service.estimateTravelTime(
                    origin: origin,
                    destination: destination,
                    useCurrentLocation: try Self.optionalBool(
                        "use_current_location", in: arguments, default: origin == nil),
                    transport: transport,
                    departureDate: try Self.optionalString("departure_date", in: arguments),
                    arrivalDate: try Self.optionalString("arrival_date", in: arguments)))
            default:
                return Self.error("Unknown tool: \(name)")
            }
        } catch {
            return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func requiredString(_ name: String, in arguments: [String: Value]?) throws -> String {
        guard let value = arguments?[name] else { throw MapArgumentError.missing(name) }
        guard let string = value.stringValue else { throw MapArgumentError.wrongType(name, "string") }
        return string
    }

    private static func optionalString(_ name: String, in arguments: [String: Value]?) throws -> String? {
        guard let value = arguments?[name] else { return nil }
        guard let string = value.stringValue else { throw MapArgumentError.wrongType(name, "string") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalBool(
        _ name: String, in arguments: [String: Value]?, default defaultValue: Bool
    ) throws -> Bool {
        guard let value = arguments?[name] else { return defaultValue }
        guard let bool = value.boolValue else { throw MapArgumentError.wrongType(name, "boolean") }
        return bool
    }

    private static func optionalInt(
        _ name: String, in arguments: [String: Value]?, default defaultValue: Int
    ) throws -> Int {
        guard let value = arguments?[name] else { return defaultValue }
        guard let int = value.intValue else { throw MapArgumentError.wrongType(name, "integer") }
        return int
    }

    private static func optionalNumber(
        _ name: String, in arguments: [String: Value]?, default defaultValue: Double
    ) throws -> Double {
        guard let value = arguments?[name] else { return defaultValue }
        if let double = value.doubleValue { return double }
        if let int = value.intValue { return Double(int) }
        throw MapArgumentError.wrongType(name, "number")
    }

    private static func jsonObject(_ arguments: [String: Value]?) -> Any {
        guard let arguments, !arguments.isEmpty,
              let data = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [String: Any]() }
        return object
    }

    private static func text(_ string: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: string, annotations: nil, _meta: nil)], isError: isError)
    }

    private static func error(_ message: String) -> CallTool.Result {
        text(message, isError: true)
    }

    private static func json<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return error("Failed to encode result.")
        }
        return text(string)
    }
}

nonisolated private enum MapArgumentError: LocalizedError {
    case missing(String)
    case wrongType(String, String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing required argument: \(name)"
        case .wrongType(let name, let expected): "Argument \(name) must be a \(expected)."
        }
    }
}
