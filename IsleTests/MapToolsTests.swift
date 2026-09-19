import Foundation
import MCP
import Testing
@testable import Isle

@MainActor
struct MapToolsTests {
    @Test func exposesExpectedToolNames() {
        #expect(MapTools.toolNames == ["search_places", "estimate_travel_time"])
    }

    @Test func searchUsesBoundedDefaults() async throws {
        let service = FakeMapService()
        let tools = MapTools(service: service)

        let result = await tools.call(name: "search_places", arguments: ["query": "coffee"])

        #expect(result.isError != true)
        #expect(service.lastSearch == .init(
            query: "coffee",
            nearCurrentLocation: false,
            radiusKilometers: 10,
            limit: 5))
        #expect(Self.text(from: result).contains("Coffee Shop"))
    }

    @Test func etaDefaultsToCurrentLocationWhenOriginIsOmitted() async throws {
        let service = FakeMapService()
        let tools = MapTools(service: service)

        let result = await tools.call(name: "estimate_travel_time", arguments: [
            "destination": "Heathrow Airport",
            "transport": "transit",
        ])

        #expect(result.isError != true)
        #expect(service.lastETA == .init(
            origin: nil,
            destination: "Heathrow Airport",
            useCurrentLocation: true,
            transport: "transit",
            departureDate: nil,
            arrivalDate: nil))
        #expect(Self.text(from: result).contains("expectedTravelTimeSeconds"))
    }

    @Test func ignoresEmptyOptionalETAArguments() async {
        let service = FakeMapService()
        let tools = MapTools(service: service)

        let result = await tools.call(name: "estimate_travel_time", arguments: [
            "origin": "",
            "destination": "Sunny Hill Cafe",
            "transport": "walking",
            "use_current_location": true,
            "departure_date": "",
            "arrival_date": "",
        ])

        #expect(result.isError != true)
        #expect(service.lastETA == .init(
            origin: nil,
            destination: "Sunny Hill Cafe",
            useCurrentLocation: true,
            transport: "walking",
            departureDate: nil,
            arrivalDate: nil))
    }

    @Test func reportsMissingRequiredArgumentsWithoutCallingService() async {
        let service = FakeMapService()
        let tools = MapTools(service: service)

        let result = await tools.call(name: "estimate_travel_time", arguments: [
            "transport": "walking"
        ])

        #expect(result.isError == true)
        #expect(Self.text(from: result) == "Missing required argument: destination")
        #expect(service.lastETA == nil)
    }

    @Test func rejectsWrongOptionalTypesInsteadOfUsingLocationDefaults() async {
        let service = FakeMapService()
        let tools = MapTools(service: service)

        let result = await tools.call(name: "estimate_travel_time", arguments: [
            "destination": "Heathrow Airport",
            "transport": "transit",
            "use_current_location": "false",
        ])

        #expect(result.isError == true)
        #expect(Self.text(from: result) == "Argument use_current_location must be a boolean.")
        #expect(service.lastETA == nil)
    }

    private static func text(from result: CallTool.Result) -> String {
        guard case let .text(text, _, _)? = result.content.first else { return "" }
        return text
    }
}

@MainActor
private final class FakeMapService: MapServicing {
    struct Search: Equatable {
        let query: String
        let nearCurrentLocation: Bool
        let radiusKilometers: Double
        let limit: Int
    }

    struct ETA: Equatable {
        let origin: String?
        let destination: String
        let useCurrentLocation: Bool
        let transport: String
        let departureDate: String?
        let arrivalDate: String?
    }

    var lastSearch: Search?
    var lastETA: ETA?

    func searchPlaces(
        query: String,
        nearCurrentLocation: Bool,
        radiusKilometers: Double,
        limit: Int
    ) async throws -> [PlaceDTO] {
        lastSearch = Search(
            query: query,
            nearCurrentLocation: nearCurrentLocation,
            radiusKilometers: radiusKilometers,
            limit: limit)
        return [PlaceDTO(
            name: "Coffee Shop",
            address: "1 Test Street",
            latitude: 51.5,
            longitude: -0.1,
            phoneNumber: nil,
            url: nil,
            category: "Cafe")]
    }

    func estimateTravelTime(
        origin: String?,
        destination: String,
        useCurrentLocation: Bool,
        transport: String,
        departureDate: String?,
        arrivalDate: String?
    ) async throws -> ETASummaryDTO {
        lastETA = ETA(
            origin: origin,
            destination: destination,
            useCurrentLocation: useCurrentLocation,
            transport: transport,
            departureDate: departureDate,
            arrivalDate: arrivalDate)
        return ETASummaryDTO(
            origin: MapEndpointDTO(name: "Current location", address: nil),
            destination: MapEndpointDTO(name: destination, address: destination),
            transport: transport,
            expectedTravelTimeSeconds: 1_800,
            distanceMeters: 12_000,
            expectedDepartureDate: "2026-09-19T10:00:00Z",
            expectedArrivalDate: "2026-09-19T10:30:00Z")
    }
}
