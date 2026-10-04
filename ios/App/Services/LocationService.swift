import CoreLocation
import Foundation

/// Ermittelt einmalig den aktuellen Standort.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum LocationError: LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: "Standortzugriff ist nicht erlaubt. Bitte in den Einstellungen aktivieren."
            case .unavailable: "Standort konnte nicht ermittelt werden."
            }
        }
    }

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorizationIfNeeded() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation() async throws -> CLLocation {
        await requestAuthorizationIfNeeded()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw LocationError.denied
        }
        if let location = manager.location, location.timestamp.timeIntervalSinceNow > -300 {
            return location
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation?.resume(throwing: LocationError.unavailable)
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            authorizationContinuation?.resume()
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: LocationError.unavailable)
            locationContinuation = nil
        }
    }
}
