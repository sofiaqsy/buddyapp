import Foundation
import CryptoKit

// ════════════════════════════════════════════════════════════════════════════
// Alias de viajero — identidad estable sin pedir datos personales
//
// La mayoría de viajeros entra como invitado y no tiene nombre, nacionalidad ni
// avatar: para un buddy con dos solicitudes abiertas, ambas se ven como
// "Viajero" y son imposibles de distinguir. El alias resuelve eso sin meter un
// formulario en el peor momento posible (alguien pidiendo ayuda), y sin exponer
// el nombre real de nadie ante un desconocido.
//
// Se DERIVA del UUID, no viaja por la API: el servidor y cada cliente llegan al
// mismo alias por su cuenta, así que no hizo falta migración, backfill, columna
// nueva ni cambiar un solo endpoint.
//
// ⚠️  GEMELO de buddy-core/src/lib/travelerAlias.js. Las listas, su ORDEN y la
// forma de derivar los índices son un contrato: si divergen, el push diría un
// nombre y la tarjeta otro. Reordenar, insertar en medio o quitar una entrada
// le cambia el alias a gente que ya lo tenía — solo AÑADIR AL FINAL es seguro,
// y hay que hacerlo en ambos archivos a la vez.
// ════════════════════════════════════════════════════════════════════════════

enum TravelerAlias {

    // feminine = género gramatical, para que el color concuerde
    // ("Vicuña Dorada", no "Vicuña Dorado")
    private struct Noun {
        let word: String
        let feminine: Bool
    }

    private enum ColorWord {
        case invariable(String)
        case gendered(m: String, f: String)

        func form(feminine: Bool) -> String {
            switch self {
            case .invariable(let w):     return w
            case .gendered(let m, let f): return feminine ? f : m
            }
        }
    }

    private static let nouns: [Noun] = [
        // Fauna peruana — identidad local, fácil de recordar
        Noun(word: "Cóndor",        feminine: false),
        Noun(word: "Llama",         feminine: true),
        Noun(word: "Puma",          feminine: false),
        Noun(word: "Vicuña",        feminine: true),
        Noun(word: "Colibrí",       feminine: false),
        Noun(word: "Alpaca",        feminine: true),
        Noun(word: "Jaguar",        feminine: false),
        Noun(word: "Delfín",        feminine: false),
        Noun(word: "Tucán",         feminine: false),
        Noun(word: "Zorro",         feminine: false),
        Noun(word: "Nutria",        feminine: true),
        Noun(word: "Búho",          feminine: false),
        Noun(word: "Garza",         feminine: true),
        Noun(word: "Flamenco",      feminine: false),
        Noun(word: "Tortuga",       feminine: true),
        Noun(word: "Ballena",       feminine: true),
        Noun(word: "Guanaco",       feminine: false),
        Noun(word: "Pelícano",      feminine: false),
        Noun(word: "Chinchilla",    feminine: true),
        Noun(word: "Anaconda",      feminine: true),
        // Naturaleza — más neutro, para quien no conecta con la fauna
        Noun(word: "Río",           feminine: false),
        Noun(word: "Bosque",        feminine: false),
        Noun(word: "Nevado",        feminine: false),
        Noun(word: "Brisa",         feminine: true),
        Noun(word: "Océano",        feminine: false),
        Noun(word: "Aurora",        feminine: true),
        Noun(word: "Duna",          feminine: true),
        Noun(word: "Volcán",        feminine: false),
        Noun(word: "Cascada",       feminine: true),
        Noun(word: "Selva",         feminine: true),
        Noun(word: "Valle",         feminine: false),
        Noun(word: "Glaciar",       feminine: false),
        Noun(word: "Arrecife",      feminine: false),
        Noun(word: "Páramo",        feminine: false),
        Noun(word: "Laguna",        feminine: true),
        Noun(word: "Sendero",       feminine: false),
        Noun(word: "Manglar",       feminine: false),
        Noun(word: "Cráter",        feminine: false),
        Noun(word: "Estepa",        feminine: true),
        Noun(word: "Cumbre",        feminine: true),
    ]

    private static let colors: [ColorWord] = [
        .invariable("Azul"),      .invariable("Verde"),     .invariable("Coral"),
        .invariable("Ámbar"),     .invariable("Índigo"),    .invariable("Turquesa"),
        .invariable("Carmesí"),   .invariable("Esmeralda"), .invariable("Púrpura"),
        .invariable("Marfil"),    .invariable("Cobre"),     .invariable("Zafiro"),
        .invariable("Jade"),      .invariable("Violeta"),   .invariable("Magenta"),
        .invariable("Añil"),      .invariable("Ocre"),      .invariable("Lila"),
        .invariable("Escarlata"), .invariable("Gris"),      .invariable("Bronce"),
        .invariable("Perla"),     .invariable("Cian"),      .invariable("Malva"),
        .invariable("Salmón"),    .invariable("Vino"),
        .gendered(m: "Dorado",   f: "Dorada"),
        .gendered(m: "Plateado", f: "Plateada"),
    ]

    /// Alias determinístico para un traveler_id. El mismo id da siempre el
    /// mismo alias, en este dispositivo, en otro, y en el servidor.
    /// Solo texto — nada de emojis: tiene que leerse como el nombre de una
    /// persona, y aparece en sitios (títulos de push) donde un icono desentona.
    static func alias(for travelerId: String?) -> String {
        guard let id = travelerId, !id.isEmpty else { return "Viajero" }

        let digest = Array(SHA256.hash(data: Data(id.utf8)))
        // Dos tramos independientes del hash para que sustantivo y color no se
        // correlacionen. Big-endian sobre 4 bytes = los 8 primeros hex chars
        // que lee el gemelo en JS.
        let noun  = nouns[Int(be32(digest, 0) % UInt32(nouns.count))]
        let color = colors[Int(be32(digest, 4) % UInt32(colors.count))]

        return "\(noun.word) \(color.form(feminine: noun.feminine))"
    }

    /// Cómo mostrar a una persona: su nombre real si lo dio, y si no su alias.
    static func displayName(realName: String?, id: String?) -> String {
        let real = realName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !real.isEmpty { return real }
        return alias(for: id)
    }

    /// Igual que `displayName` pero solo el primer nombre — para encabezados de
    /// chat y listas donde el nombre completo no cabe. El alias no se parte:
    /// "Llama Coral" pierde todo su sentido reducido a "Llama".
    static func shortDisplayName(realName: String?, id: String?) -> String {
        let real = realName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !real.isEmpty {
            return real.components(separatedBy: " ").first?.capitalized ?? real
        }
        return alias(for: id)
    }

    /// Iniciales para el avatar sin foto. Con alias salen dos letras
    /// ("Tortuga Azul" → "TA"), que distinguen mejor que una sola.
    static func initials(realName: String?, id: String?) -> String {
        let name = displayName(realName: realName, id: id)
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset])     << 24) |
        (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) <<  8) |
         UInt32(bytes[offset + 3])
    }
}
