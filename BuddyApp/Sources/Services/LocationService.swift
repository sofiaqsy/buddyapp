import Foundation
import CoreLocation
import Combine

final class LocationService: NSObject, ObservableObject {
    @Published var userLocation: CLLocation?
    /// Última ubicación que pasó LocationFilter (precisión ≤ 20 m). Las
    /// distancias de la UI usan esta; userLocation sigue siendo el fix crudo
    /// para el resto de la app, que no necesita el filtro.
    @Published var stableLocation: CLLocation?
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

    /// La última ubicación que el sistema ya conoce, sin esperar un fix nuevo.
    /// Solo si es reciente: una vieja (otro barrio, otra ciudad) pediría los
    /// spots equivocados y luego habría que pedirlos otra vez.
    func ubicacionConocida(maxEdad: TimeInterval) -> CLLocation? {
        guard let loc = manager.location,
              Date().timeIntervalSince(loc.timestamp) < maxEdad else { return nil }
        return loc
    }
    private var hasFetchedCity = false
    private var lastGeocodedLocation: CLLocation?
    /// Fix anterior, solo para loguear cuánto se movió el viajero entre fixes.
    private var lastFixLogged: CLLocation?

    // place id -> triggered
    var onRegionEnter: ((String) -> Void)?

    override init() {
        super.init()
        LocationService.current = self
        manager.delegate = self
        // ±10 m y un fix cada 25 m. Antes era "la mejor precisión" cada 10 m:
        // quieto, el ruido del GPS ya daba "movido 10m" cada 20-30 s y el
        // chip no descansaba nunca — calor y batería. Las distancias de las
        // cards (buckets de 10 m, "Estás aquí" a 30/45 m) no necesitan más.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    private(set) var isTracking = false

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        dlog("📡 [gps] tracking ON")
        manager.startUpdatingLocation()
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        dlog("📡 [gps] tracking OFF")
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

        // Un log por fix: posición, precisión, cuánto se movió desde el
        // anterior y cada cuánto llegan. Sirve para distinguir "no me muevo"
        // de "el GPS no entrega fixes" cuando la UI no reacciona.
        let delta = lastFixLogged.map { Int(loc.distance(from: $0)) }
        let segs  = lastFixLogged.map { String(format: "%.0f", loc.timestamp.timeIntervalSince($0.timestamp)) }
        dlog("📡 [gps] fix \(String(format: "%.6f", loc.coordinate.latitude)),\(String(format: "%.6f", loc.coordinate.longitude)) ±\(Int(loc.horizontalAccuracy))m" +
              (delta.map { " · movido \($0)m" } ?? " · primer fix") +
              (segs.map { " en \($0)s" } ?? "") +
              (loc.speed >= 0 ? " · \(String(format: "%.1f", loc.speed))m/s" : ""))
        lastFixLogged = loc
        if LocationFilter.accept(loc, hasStable: stableLocation != nil) {
            stableLocation = loc
        } else {
            dlog("📡 [gps] descartado ±\(Int(loc.horizontalAccuracy))m (umbral \(Int(LocationFilter.maxAccuracy))m)")
        }
        // Re-geocode si es la primera vez, o si el usuario se movió más de 5 km desde la última geocodificación
        let distanceMoved = lastGeocodedLocation.map { loc.distance(from: $0) } ?? .greatestFiniteMagnitude
        guard !hasFetchedCity || distanceMoved > 5_000 else { return }
        hasFetchedCity = true
        lastGeocodedLocation = loc
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            let city = placemarks?.first?.locality
            let district = placemarks?.first?.subLocality
            dlog("📍 [LocationService] currentCity=\(city ?? "nil") currentDistrict=\(district ?? "nil")")
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
