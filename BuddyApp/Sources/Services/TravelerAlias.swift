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

    struct Alias {
        let name: String
        let emoji: String
        var label: String { "\(emoji) \(name)" }
    }

    // feminine = género gramatical, para que el color concuerde
    // ("Vicuña Dorada", no "Vicuña Dorado")
    private struct Noun {
        let word: String
        let emoji: String
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
        Noun(word: "Cóndor",     emoji: "🦅", feminine: false),
        Noun(word: "Llama",      emoji: "🦙", feminine: true),
        Noun(word: "Puma",       emoji: "🐆", feminine: false),
        Noun(word: "Vicuña",     emoji: "🦌", feminine: true),
        Noun(word: "Colibrí",    emoji: "🐦", feminine: false),
        Noun(word: "Alpaca",     emoji: "🦙", feminine: true),
        Noun(word: "Jaguar",     emoji: "🐅", feminine: false),
        Noun(word: "Delfín",     emoji: "🐬", feminine: false),
        Noun(word: "Tucán",      emoji: "🦜", feminine: false),
        Noun(word: "Zorro",      emoji: "🦊", feminine: false),
        Noun(word: "Nutria",     emoji: "🦦", feminine: true),
        Noun(word: "Búho",       emoji: "🦉", feminine: false),
        Noun(word: "Garza",      emoji: "🕊️", feminine: true),
        Noun(word: "Flamenco",   emoji: "🦩", feminine: false),
        Noun(word: "Tortuga",    emoji: "🐢", feminine: true),
        Noun(word: "Ballena",    emoji: "🐋", feminine: true),
        Noun(word: "Guanaco",    emoji: "🦙", feminine: false),
        Noun(word: "Pelícano",   emoji: "🦆", feminine: false),
        Noun(word: "Chinchilla", emoji: "🐹", feminine: true),
        Noun(word: "Anaconda",   emoji: "🐍", feminine: true),
        // Naturaleza — más neutro, para quien no conecta con la fauna
        Noun(word: "Río",        emoji: "🏞️", feminine: false),
        Noun(word: "Bosque",     emoji: "🌲", feminine: false),
        Noun(word: "Nevado",     emoji: "🏔️", feminine: false),
        Noun(word: "Brisa",      emoji: "🍃", feminine: true),
        Noun(word: "Océano",     emoji: "🌊", feminine: false),
        Noun(word: "Aurora",     emoji: "🌅", feminine: true),
        Noun(word: "Duna",       emoji: "🏜️", feminine: true),
        Noun(word: "Volcán",     emoji: "🌋", feminine: false),
        Noun(word: "Cascada",    emoji: "💧", feminine: true),
        Noun(word: "Selva",      emoji: "🌴", feminine: true),
        Noun(word: "Valle",      emoji: "⛰️", feminine: false),
        Noun(word: "Glaciar",    emoji: "🧊", feminine: false),
        Noun(word: "Arrecife",   emoji: "🪸", feminine: false),
        Noun(word: "Páramo",     emoji: "🌾", feminine: false),
        Noun(word: "Laguna",     emoji: "🪷", feminine: true),
        Noun(word: "Sendero",    emoji: "🧭", feminine: false),
        Noun(word: "Manglar",    emoji: "🌿", feminine: false),
        Noun(word: "Cráter",     emoji: "🌑", feminine: false),
        Noun(word: "Estepa",     emoji: "🏕️", feminine: true),
        Noun(word: "Cumbre",     emoji: "🗻", feminine: true),
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
    static func alias(for travelerId: String?) -> Alias {
        guard let id = travelerId, !id.isEmpty else {
            return Alias(name: "Viajero", emoji: "🧭")
        }

        let digest = Array(SHA256.hash(data: Data(id.utf8)))
        // Dos tramos independientes del hash para que sustantivo y color no se
        // correlacionen. Big-endian sobre 4 bytes = los 8 primeros hex chars
        // que lee el gemelo en JS.
        let noun  = nouns[Int(be32(digest, 0) % UInt32(nouns.count))]
        let color = colors[Int(be32(digest, 4) % UInt32(colors.count))]

        return Alias(name: "\(noun.word) \(color.form(feminine: noun.feminine))",
                     emoji: noun.emoji)
    }

    /// Cómo mostrar a una persona: su nombre real si lo dio, y si no su alias.
    static func displayName(realName: String?, id: String?) -> String {
        let real = realName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !real.isEmpty { return real }
        return alias(for: id).label
    }

    /// Igual que `displayName` pero solo el primer nombre — para encabezados de
    /// chat y listas donde el nombre completo no cabe. El alias no se parte:
    /// "Llama Coral" pierde todo su sentido reducido a "Llama".
    static func shortDisplayName(realName: String?, id: String?) -> String {
        let real = realName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !real.isEmpty {
            return real.components(separatedBy: " ").first?.capitalized ?? real
        }
        return alias(for: id).label
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset])     << 24) |
        (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) <<  8) |
         UInt32(bytes[offset + 3])
    }
}
