import Foundation
import CoreLocation

struct Place: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let stickerSymbol: String   // SF Symbol name
    let stickerEmoji: String
    var stickerImageUrl: String? = nil
    var stickerId: String? = nil     // sticker_catalog.id, used to match QR unlocks
    var isCollected: Bool = false    // true after QR scan or geofence unlock
    var isFavorite: Bool = false     // marcado por el usuario (sincroniza con backend)
    let category: Category
    /// El símbolo REAL de la categoría del lugar (spot_category.icon: fork.knife,
    /// cup.and.saucer.fill, bed.double.fill…). `category` viene de place_type,
    /// que casi siempre llega vacío y caía en .culture: por eso todos los pines
    /// del mapa salían con el mismo icono de columnas.
    var categoryIcon: String? = nil
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    var coverUrl: String?
    var featured: Bool = false   // top community pick → featured marker tier
    /// URL de la ficha de Google Maps del lugar, ya armada por el backend
    /// (buddy-core/src/lib/googleMapsLink.js). nil si el spot no está vinculado
    /// a un Google Place ID. Usar SIEMPRE vía GoogleMapsLink.openableURL.
    var googleMapsUrl: String? = nil

    enum Category: String, Codable, CaseIterable {
        case cafe, nature, culture, market, viewpoint, hidden

        var label: String {
            switch self {
            case .cafe:      return "Café"
            case .nature:    return "Naturaleza"
            case .culture:   return "Cultura"
            case .market:    return "Mercado"
            case .viewpoint: return "Mirador"
            case .hidden:    return "Lugar secreto"
            }
        }
        var symbol: String {
            switch self {
            case .cafe:      return "cup.and.saucer"
            case .nature:    return "leaf"
            case .culture:   return "building.columns"
            case .market:    return "basket"
            case .viewpoint: return "mountain.2"
            case .hidden:    return "sparkles"
            }
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

extension Place {
    static func nearOrigin(_ origin: CLLocationCoordinate2D) -> [Place] {
        let data: [(String, String, String, Category, Double, Double)] = [
            ("Plaza Central",   "El corazón del pueblo, donde todo empieza.",
             "🏛️", .culture,    0.000, 0.000),
            ("Café Tunki",      "El mejor café de altura. Tostado a 1800 msnm.",
             "☕", .cafe,       0.002, 0.003),
            ("Mirador del Valle","Vista al volcán en días despejados.",
             "🌋", .viewpoint,  0.004, 0.005),
            ("La Catarata",     "Una cascada secreta a 40 minutos a pie.",
             "💧", .nature,     0.006, 0.007),
        ]
        return data.map { (name, desc, emoji, cat, dlat, dlon) in
            Place(
                id: UUID(),
                name: name,
                description: desc,
                stickerSymbol: cat.symbol,
                stickerEmoji: emoji,
                category: cat,
                latitude:  origin.latitude  + dlat,
                longitude: origin.longitude + dlon,
                radiusMeters: 80
            )
        }
    }

    static let villaRicaSamples: [Place] = nearOrigin(
        CLLocationCoordinate2D(latitude: -10.600, longitude: -75.348)
    )
}

// MARK: - Enlace a la ficha de Google Maps

/// Abrir la ficha de un spot en Google Maps NO requiere API key ni llamar a
/// Places: el backend entrega una URL de Google Maps y la app solo la abre.
///
/// Esa URL se arma con datos que escribió una persona (nombre del lugar, Place
/// ID), así que el cliente no abre cualquier cosa que llegue en el campo: solo
/// una búsqueda de Google Maps por https con un query_place_id. Cualquier otra
/// forma —otro host, otro esquema, otra ruta, sin id— se trata como "sin ficha".
enum GoogleMapsLink {
    static func openableURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme == "https",
              url.host == "www.google.com",
              // Sin puerto ni credenciales: el backend nunca los genera, así que
              // su presencia significa que la URL no es la que armó el backend.
              url.port == nil, url.user == nil, url.password == nil,
              url.path == "/maps/search/" || url.path == "/maps/search",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.contains(where: { $0.name == "query_place_id" && !($0.value ?? "").isEmpty })
        else { return nil }
        return url
    }
}

/// Reglas de las fotos de Google en el Home que no dependen de SwiftUI ni de la
/// red (por eso viven aquí y se prueban en Tools/main.swift).
enum GooglePhotoSupport {
    /// La ÚNICA ruta que la app descarga con su sesión: la que entrega el
    /// backend para una foto. Si el servidor devolviera otra cosa (otro host,
    /// otro camino), la app NO la pediría: el token de sesión no se manda a
    /// ningún sitio que no sea la API de BuddyApp.
    static let imagePathPrefix = "/v1/places/google/photo-media?token="

    static func isValidImagePath(_ raw: String?) -> Bool {
        guard let raw, raw.hasPrefix(imagePathPrefix), raw.count > imagePathPrefix.count, raw.count < 2400 else { return false }
        let token = raw.dropFirst(imagePathPrefix.count)
        // Un token firmado (JWT) solo usa estos caracteres; nada de "&", "/" ni "#".
        return token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.%".contains($0)) }
    }

    /// Enlace del autor de la foto: solo https hacia un dominio de Google, sin
    /// puerto ni credenciales. Cualquier otro se descarta (el nombre se muestra igual).
    static func openableAuthorURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, raw.count <= 500,
              let url = URL(string: raw),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              url.port == nil, url.user == nil, url.password == nil,
              host == "google.com" || host.hasSuffix(".google.com") || host == "maps.app.goo.gl" || host == "goo.gl"
        else { return nil }
        return url
    }

    /// "Foto: Ana" / "Foto: Ana y Beto" — el crédito del autor que exige Google.
    static func creditLine(_ names: [String]) -> String? {
        let limpios = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !limpios.isEmpty else { return nil }
        return "Foto: " + limpios.joined(separator: " y ")
    }
}

/// Reglas del descubrimiento con Google que no dependen de SwiftUI ni de la red.
enum GoogleDiscoverSupport {
    /// Radio de descubrimiento acordado (metros). El servidor ya lo impone; la app
    /// lo comprueba otra vez por si llegara algo fuera.
    static let radioMetros = 10_000
    /// Cuánto hay que moverse, o esperar, para volver a pedir.
    static let minMetrosParaRepetir = 1_000.0
    static let minSegundosParaRepetir = 600.0
    /// Espera tras pintar el Inicio antes de la primera petición: Google nunca
    /// compite con el arranque.
    static let esperaTrasPintarSegundos = 1.2

    /// ¿Hay que (volver a) pedir? Misma zona (< 1 km) y reciente (< 10 min) → no.
    /// Solo vive en memoria: no se persiste nada del descubrimiento.
    static func debeBuscar(
        ultima: (lat: Double, lng: Double, fecha: Date)?,
        lat: Double, lng: Double, ahora: Date
    ) -> Bool {
        guard let ultima else { return true }
        let metros = CLLocation(latitude: ultima.lat, longitude: ultima.lng)
            .distance(from: CLLocation(latitude: lat, longitude: lng))
        return metros >= minMetrosParaRepetir || ahora.timeIntervalSince(ultima.fecha) >= minSegundosParaRepetir
    }

    /// ¿Esta tarjeta de Google sirve? id con prefijo, nombre, ruta de foto del
    /// backend y dentro del radio. Lo que no cumpla se descarta sin ruido.
    static func esValida(id: String, name: String, primeraRuta: String?, distanciaMetros: Int?) -> Bool {
        guard id.hasPrefix("google:"), id.count > "google:".count,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              GooglePhotoSupport.isValidImagePath(primeraRuta) else { return false }
        if let d = distanciaMetros, d > radioMetros { return false }
        return true
    }

    /// "Cafetería · Foto: Ana" — segunda línea de la tarjeta de Google.
    static func segundaLinea(categoria: String?, autores: [String]) -> String {
        var partes: [String] = []
        if let c = categoria?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { partes.append(c) }
        if let credito = GooglePhotoSupport.creditLine(autores) { partes.append(credito) }
        return partes.joined(separator: " · ")
    }
}
