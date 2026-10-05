import CoreLocation
import Foundation
import MapKit
import WochenleichtCore

/// Sucht Supermärkte in der Umgebung über Apple Maps (MapKit).
enum SupermarketFinder {
    private static let queries = ["Supermarkt", "Discounter", "Lebensmittel"]

    static func nearby(_ location: CLLocation, radiusMeters: CLLocationDistance = 3000) async throws -> [Supermarket] {
        var found: [String: Supermarket] = [:]
        var lastError: Error?
        for query in queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.foodMarket])
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: radiusMeters * 2,
                                                longitudinalMeters: radiusMeters * 2)
            do {
                let response = try await MKLocalSearch(request: request).start()
                for item in response.mapItems {
                    guard let market = supermarket(from: item) else { continue }
                    found[market.id] = market
                }
            } catch {
                lastError = error
            }
        }
        if found.isEmpty, let lastError { throw lastError }
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        return found.values
            .filter { $0.distance(toLatitude: lat, longitude: lon) <= radiusMeters * 1.5 }
            .sorted { $0.distance(toLatitude: lat, longitude: lon) < $1.distance(toLatitude: lat, longitude: lon) }
    }

    private static func supermarket(from item: MKMapItem) -> Supermarket? {
        guard let name = item.name else { return nil }
        let coordinate = item.placemark.coordinate
        let placemark = item.placemark
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [placemark.postalCode, placemark.locality].compactMap { $0 }.joined(separator: " ")
        let address = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
        // Stabile ID aus Name und gerundeter Position (≈ 10 m)
        let id = String(format: "%@@%.4f,%.4f", name, coordinate.latitude, coordinate.longitude)
        return Supermarket(id: id, name: name, address: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
