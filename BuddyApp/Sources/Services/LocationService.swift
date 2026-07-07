import Foundation
import CoreLocation
import Combine

final class LocationService: NSObject, ObservableObject {
    @Published var userLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentCity: String?
    /// Distrito/barrio (subLocality) — en Lima el geocoder da locality="Lima" y
    /// subLocality="San Miguel"/"Cercado de Lima". Necesario para trips distritales.
    @Published var currentDistrict: String?

    // Weak static reference so views that only need the current location at
    // action time (e.g. sendLocation) can read it without subscribing to
    // objectWillChange and re-rendering on every GPS fix.
    static weak var current: LocationService?

    private let manager = CLLocationManager()
    private var hasFetchedCity = false
    private var lastGeocodedLocation: CLLocation?

    // place id -> triggered
    var onRegionEnter: ((String) -> Void)?

    override init() {
        super.init()
        LocationService.current = self
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startTracking() {
        manager.startUpdatingLocation()
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
    }

    func startMonitoring(places: [Place]) {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        for place in places where !place.isCollected {
            let region = CLCircularRegion(
                center: place.coordinate,
                radius: place.radiusMeters,
                identifier: place.id.uuidString
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            startTracking()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.last
        guard let loc = locations.last else { return }
        // Re-geocode si es la primera vez, o si el usuario se movió más de 5 km desde la última geocodificación
        let distanceMoved = lastGeocodedLocation.map { loc.distance(from: $0) } ?? .greatestFiniteMagnitude
        guard !hasFetchedCity || distanceMoved > 5_000 else { return }
        hasFetchedCity = true
        lastGeocodedLocation = loc
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            let city = placemarks?.first?.locality
            let district = placemarks?.first?.subLocality
            print("📍 [LocationService] currentCity=\(city ?? "nil") currentDistrict=\(district ?? "nil")")
            DispatchQueue.main.async {
                self?.currentCity = city
                self?.currentDistrict = district
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onRegionEnter?(region.identifier)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationService error: \(error.localizedDescription)")
    }
}
