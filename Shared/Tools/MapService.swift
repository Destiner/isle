import CoreLocation
import Foundation
import MapKit

nonisolated struct PlaceDTO: Codable, Equatable, Sendable {
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
    let phoneNumber: String?
    let url: String?
    let category: String?
}

nonisolated struct MapEndpointDTO: Codable, Equatable, Sendable {
    let name: String
    let address: String?
}

nonisolated struct ETASummaryDTO: Codable, Equatable, Sendable {
    let origin: MapEndpointDTO
    let destination: MapEndpointDTO
    let transport: String
    let expectedTravelTimeSeconds: TimeInterval
    let distanceMeters: CLLocationDistance
    let expectedDepartureDate: String
    let expectedArrivalDate: String
}

nonisolated enum MapToolError: LocalizedError, Sendable {
    case emptyQuery
    case noResults(String)
    case invalidLimit(Int)
    case invalidRadius(Double)
    case invalidTransport(String)
    case invalidDate(String)
    case conflictingDates
    case conflictingOrigin
    case missingOrigin
    case locationAccessDenied
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "The place query can't be empty."
        case .noResults(let query):
            "Apple Maps found no places matching \"\(query)\"."
        case .invalidLimit(let limit):
            "limit must be between 1 and 10 (got \(limit))."
        case .invalidRadius(let radius):
            "radius_km must be between 0.1 and 100 (got \(radius))."
        case .invalidTransport(let transport):
            "Unsupported transport \"\(transport)\"; use driving, walking, transit, or cycling."
        case .invalidDate(let value):
            "Couldn't parse \"\(value)\" as a date (use ISO 8601)."
        case .conflictingDates:
            "Provide departure_date or arrival_date, not both."
        case .conflictingOrigin:
            "Provide origin or use_current_location, not both."
        case .missingOrigin:
            "Provide origin or set use_current_location to true."
        case .locationAccessDenied:
            "Location access hasn't been granted to Isle."
        case .locationUnavailable:
            "Isle couldn't determine the current location."
        }
    }
}

@MainActor
protocol MapServicing: Sendable {
    func searchPlaces(
        query: String,
        nearCurrentLocation: Bool,
        radiusKilometers: Double,
        limit: Int
    ) async throws -> [PlaceDTO]

    func estimateTravelTime(
        origin: String?,
        destination: String,
        useCurrentLocation: Bool,
        transport: String,
        departureDate: String?,
        arrivalDate: String?
    ) async throws -> ETASummaryDTO
}

@MainActor
final class MapService: MapServicing {
    private let locationProvider: CurrentLocationProvider

    init() {
        locationProvider = CurrentLocationProvider()
    }

    init(locationProvider: CurrentLocationProvider) {
        self.locationProvider = locationProvider
    }

    func searchPlaces(
        query: String,
        nearCurrentLocation: Bool,
        radiusKilometers: Double,
        limit: Int
    ) async throws -> [PlaceDTO] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw MapToolError.emptyQuery }
        guard (1...10).contains(limit) else { throw MapToolError.invalidLimit(limit) }
        guard (0.1...100).contains(radiusKilometers) else {
            throw MapToolError.invalidRadius(radiusKilometers)
        }

        let request = MKLocalSearch.Request(naturalLanguageQuery: query)
        let center: CLLocation?
        if nearCurrentLocation {
            let location = try await locationProvider.currentLocation()
            let diameterMeters = radiusKilometers * 2_000
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: diameterMeters,
                longitudinalMeters: diameterMeters)
            request.regionPriority = .required
            center = location
        } else {
            center = nil
        }

        let response = try await MKLocalSearch(request: request).start()
        let radiusMeters = radiusKilometers * 1_000
        let items = center.map { center in
            response.mapItems.filter { $0.location.distance(from: center) <= radiusMeters }
        } ?? response.mapItems
        let places = items.prefix(limit).map(Self.placeDTO)
        guard !places.isEmpty else { throw MapToolError.noResults(query) }
        return places
    }

    func estimateTravelTime(
        origin: String?,
        destination: String,
        useCurrentLocation: Bool,
        transport: String,
        departureDate: String?,
        arrivalDate: String?
    ) async throws -> ETASummaryDTO {
        let destinationQuery = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationQuery.isEmpty else { throw MapToolError.emptyQuery }
        guard departureDate == nil || arrivalDate == nil else { throw MapToolError.conflictingDates }
        let requestedTransport = try Self.transportType(transport)
        let requestedDeparture = try departureDate.map(Self.parseDate)
        let requestedArrival = try arrivalDate.map(Self.parseDate)

        let originQuery = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if useCurrentLocation, let originQuery, !originQuery.isEmpty {
            throw MapToolError.conflictingOrigin
        }
        guard useCurrentLocation || !(originQuery ?? "").isEmpty else {
            throw MapToolError.missingOrigin
        }

        let source: MKMapItem
        let sourceDTO: MapEndpointDTO
        if useCurrentLocation {
            let location = try await locationProvider.currentLocation()
            source = MKMapItem(location: location, address: nil)
            source.name = "Current location"
            sourceDTO = MapEndpointDTO(name: "Current location", address: nil)
        } else {
            source = try await resolvePlace(originQuery!)
            sourceDTO = Self.endpointDTO(source)
        }
        let target = try await resolvePlace(destinationQuery, near: source.location)

        let request = MKDirections.Request()
        request.source = source
        request.destination = target
        request.transportType = requestedTransport
        request.departureDate = requestedDeparture
        request.arrivalDate = requestedArrival

        let response = try await MKDirections(request: request).calculateETA()
        return ETASummaryDTO(
            origin: sourceDTO,
            destination: Self.endpointDTO(response.destination),
            transport: Self.transportName(response.transportType),
            expectedTravelTimeSeconds: response.expectedTravelTime,
            distanceMeters: response.distance,
            expectedDepartureDate: Self.iso(response.expectedDepartureDate),
            expectedArrivalDate: Self.iso(response.expectedArrivalDate))
    }

    private func resolvePlace(_ query: String, near location: CLLocation? = nil) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(naturalLanguageQuery: query)
        if let location {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 100_000,
                longitudinalMeters: 100_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw MapToolError.noResults(query) }
        return item
    }

    private static func placeDTO(_ item: MKMapItem) -> PlaceDTO {
        let coordinate = item.location.coordinate
        return PlaceDTO(
            name: item.name ?? "Unnamed place",
            address: formattedAddress(item),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            phoneNumber: item.phoneNumber,
            url: item.url?.absoluteString,
            category: item.pointOfInterestCategory?.rawValue)
    }

    private static func endpointDTO(_ item: MKMapItem) -> MapEndpointDTO {
        MapEndpointDTO(
            name: item.name ?? formattedAddress(item) ?? "Unknown place",
            address: formattedAddress(item))
    }

    private static func formattedAddress(_ item: MKMapItem) -> String? {
        item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
    }

    private static func transportType(_ value: String) throws -> MKDirectionsTransportType {
        switch value.lowercased() {
        case "driving": .automobile
        case "walking": .walking
        case "transit": .transit
        case "cycling": .cycling
        default: throw MapToolError.invalidTransport(value)
        }
    }

    private static func transportName(_ value: MKDirectionsTransportType) -> String {
        if value == .walking { return "walking" }
        if value == .transit { return "transit" }
        if value == .cycling { return "cycling" }
        return "driving"
    }

    private static func parseDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        throw MapToolError.invalidDate(value)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

@MainActor
final class CurrentLocationProvider: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        guard continuation == nil else { throw MapToolError.locationUnavailable }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                beginRequest()
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        beginRequest()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(MapToolError.locationUnavailable))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .denied {
            finish(.failure(MapToolError.locationAccessDenied))
        } else {
            finish(.failure(MapToolError.locationUnavailable))
        }
    }

    private func beginRequest() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(MapToolError.locationAccessDenied))
        @unknown default:
            finish(.failure(MapToolError.locationUnavailable))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }
}
