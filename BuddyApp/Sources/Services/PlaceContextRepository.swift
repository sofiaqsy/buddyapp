import Foundation

/// El contexto de comunidad de un lugar (cuántos buddies, cuántas historias),
/// compartido por todas las pantallas que lo muestran.
///
/// POR QUÉ EXISTE
///
/// `/places/:id/context` lo piden hoy la Home y la grilla de trips, cada una por
/// su cuenta. En el log del arranque el MISMO destino (190babeb) se pidió una vez
/// desde InicioView y otra desde TripsView con segundos de diferencia: dos
/// peticiones para pintar el mismo número.
///
/// La observación que ordena todo esto es que estas dos preguntas
///
///     ¿tengo que volver a pedir este contexto?
///     ¿alguien ya lo pidió?
///
/// son la misma pregunta contra la misma clave. Un repositorio las responde de
/// una sola vez, y deja de importar quién pregunta.
///
/// QUÉ NO HACE (todavía, a propósito)
///
/// No expira. Una vez cargado un lugar, ese valor se sirve durante toda la vida
/// de la sesión. Es deliberado para esta primera versión: la caché por identidad
/// y la política de frescura son decisiones distintas y se miden por separado.
///
/// La consecuencia hay que tenerla presente: si mientras usás la app aparece un
/// buddy nuevo en tu destino, el contador no lo va a reflejar hasta reabrir. El
/// TTL y las invalidaciones (p. ej. tras cerrar un apoyo) son el paso siguiente.
///
/// Los fallos NO se cachean: un timeout no debe convertirse en "este lugar no
/// tiene buddies" para el resto de la sesión.
@MainActor
final class PlaceContextRepository {
    static let shared = PlaceContextRepository()
    private init() {}

    /// La identidad de un contexto: qué lugar y bajo qué lectura. `source`
    /// forma parte de la clave porque el backend resuelve distinto un
    /// destination de un place — el mismo uuid por las dos vías no tiene por
    /// qué dar lo mismo.
    struct Key: Hashable {
        let id: String
        let source: String
    }

    private var cache: [Key: APIPlaceContext] = [:]
    private let inflight = InFlightRegistry<Key>("placeContext")

    /// Devuelve el contexto del lugar: de caché si ya se pidió, y si no, de red
    /// —una sola vez aunque lo pidan varias pantallas a la vez—.
    func context(id: String, source: String) async -> APIPlaceContext? {
        let key = Key(id: id, source: source)
        if let hit = cache[key] {
            print("🏘️ [PlaceContextRepo] \(id.prefix(8)) (\(source)) ← caché")
            return hit
        }

        // Dedupe en vuelo: dos pantallas que aparecen juntas piden el mismo
        // lugar en el mismo instante y la caché todavía está vacía para ambas.
        await inflight.run(key) { [self] in
            guard let ctx = try? await APIClient.shared.fetchPlaceContext(id: id, source: source) else {
                print("🏘️ [PlaceContextRepo] \(id.prefix(8)) (\(source)) ❌ falló — no se cachea")
                return
            }
            cache[key] = ctx
            print("🏘️ [PlaceContextRepo] \(id.prefix(8)) (\(source)) ← red · buddies=\(ctx.buddies) total=\(ctx.totalBuddies) status=\(ctx.status)")
        }

        return cache[key]
    }
}
