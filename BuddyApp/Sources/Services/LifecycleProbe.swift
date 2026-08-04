import SwiftUI

/// Sonda TEMPORAL de ciclo de vida, para distinguir cuatro cosas que en SwiftUI
/// se confunden fácil y llevan a diagnósticos opuestos:
///
///   1. re-evaluación de `body`      — barata y normal, puede pasar cientos de veces
///   2. identidad nueva de la vista  — se pierde el @State/@StateObject: caro y grave
///   3. `onAppear` repetido          — vuelve a disparar efectos
///   4. `.task` repetido             — vuelve a disparar cargas
///
/// La diferencia importa: SwiftUI puede reevaluar un `body` sin volver a llamar
/// `onAppear` ni `.task`. Si `onAppear` SÍ se repite, el problema es mayor que un
/// simple re-render.
///
/// Se usa como @StateObject: sobrevive a las re-evaluaciones de body y muere con
/// la identidad de la vista, así que su INIT/DEINIT marcan exactamente cuándo el
/// árbol se reconstruye de verdad.
///
/// `renders` se incrementa desde `body`. Es una mutación durante el render, sí,
/// pero sobre una propiedad que NO es @Published: no dispara invalidación y por
/// tanto no altera lo que venimos a medir.
///
/// BORRAR cuando el diagnóstico esté cerrado.
final class LifecycleProbe: ObservableObject {
    private let nombre: String
    private var renders = 0

    init(_ nombre: String) {
        self.nombre = nombre
        print("🧬 [\(nombre)] INIT — identidad NUEVA (se perdió el estado anterior)")
    }

    deinit {
        print("🧬 [\(nombre)] DEINIT — identidad destruida")
    }

    /// Llamar desde `body`.
    ///
    /// `detalle` es el estado del que depende ese body. Sin él, un contador de
    /// renders dice CUÁNTOS pero no POR QUÉ: si el detalle no cambia entre dos
    /// renders consecutivos, algo invalidó la vista sin que cambiara nada que
    /// esa vista use — que es justo el caso que queda por explicar.
    func render(_ detalle: String? = nil) {
        renders += 1
        let d = detalle.map { "  ·  \($0)" } ?? ""
        print("🧬 [\(nombre)] body #\(renders)\(d)")
    }

    func evento(_ que: String) {
        print("🧬 [\(nombre)] \(que) — tras \(renders) render(s)")
    }
}

/// Medición TEMPORAL de coste de render por tipo de vista.
///
/// Nació de un error de lectura que conviene no repetir: en el log, un mismo
/// StoryCard imprimía 5–6 líneas y de ahí se concluyó "el body se evalúa 5–6
/// veces". Falso. Esa línea vivía en la propiedad computada `thumbs`, que el
/// body consulta 5–7 veces por evaluación — así que 5–6 líneas eran UNA sola
/// evaluación. Contar líneas de log no es medir renders.
///
/// Acá se separan las dos cosas explícitamente:
///   `render`   — el body se evaluó (una vez por evaluación, con su tiempo)
///   `derivado` — una propiedad computada se recalculó (varias por render)
@MainActor
enum RenderMetrics {
    private static var renders: [String: Int] = [:]
    private static var nanos: [String: UInt64] = [:]
    private static var derivados: [String: Int] = [:]

    /// - Parameter nanos: solo el tiempo de CONSTRUIR el árbol de vistas. No
    ///   incluye layout ni dibujado, que es donde suele estar el coste real de
    ///   una tarjeta con imágenes. Sirve para comparar tarjetas entre sí, no
    ///   para afirmar cuánto cuesta pintarlas.
    static func render(_ tipo: String, _ id: String, _ ns: UInt64) {
        let k = "\(tipo)/\(id)"
        renders[k, default: 0] += 1
        nanos[k, default: 0] += ns
        let n = renders[k]!
        let der = derivados[k] ?? 0
        print(String(format: "⏱ [%@ %@] render #%d — %.2f ms (acum %.2f ms) · derivadas=%d",
                     tipo, id, n, Double(ns) / 1_000_000, Double(nanos[k]!) / 1_000_000, der))
    }

    static func derivado(_ tipo: String, _ id: String) {
        derivados["\(tipo)/\(id)", default: 0] += 1
    }

    /// Totales, para no tener que sumar líneas ⏱ a mano. Responde de una vez
    /// "¿cuántos renders hubo REALMENTE?" y "¿cuánto costaron?", que es la
    /// pregunta que el conteo de líneas de log respondía mal.
    static func resumen(_ momento: String, deUnTotalDe total: Int? = nil) {
        guard !renders.isEmpty else { return }
        let totalRenders = renders.values.reduce(0, +)
        let totalDerivadas = derivados.values.reduce(0, +)
        let totalMs = Double(nanos.values.reduce(0, +)) / 1_000_000
        let peor = nanos.max { $0.value < $1.value }
        print(String(format: "📊 [RenderMetrics] ── %@: %d tarjetas · %d renders · %.1f ms de construcción · %d derivadas ──",
                     momento, renders.count, totalRenders, totalMs, totalDerivadas))
        print(String(format: "📊 [RenderMetrics]   media %.2f renders/tarjeta · %.2f derivadas/render",
                     Double(totalRenders) / Double(renders.count),
                     totalDerivadas > 0 ? Double(totalDerivadas) / Double(totalRenders) : 0))
        if let peor {
            print(String(format: "📊 [RenderMetrics]   más cara: %@ con %.2f ms acumulados", peor.key, Double(peor.value) / 1_000_000))
        }
        // La cifra que valida LazyVStack: cuántas tarjetas se CONSTRUYERON
        // frente a cuántas hay en la lista. Con VStack eran todas.
        if let total, total > 0 {
            let pct = Double(renders.count) / Double(total) * 100
            print(String(format: "📊 [RenderMetrics]   construidas %d de %d del feed (%.0f%%)%@",
                         renders.count, total, pct,
                         renders.count < total ? " ✅ perezoso" : "  ⚠️ se construyó todo"))
        }
    }
}

/// Traza TEMPORAL del ciclo completo de `loadData`.
///
/// Responde cuatro preguntas que ningún log contestaba, y que hay que contestar
/// ANTES de tocar la estrategia de cancelación:
///
///   1. ¿quién dispara cada carga?
///   2. ¿qué carga cancela?
///   3. ¿en qué punto de ejecución la cancela?
///   4. ¿el nuevo llamador necesitaba de verdad una recarga completa?
///
/// La cuarta es la decisiva y es la que nadie mide: si la carga que cancela
/// produce EXACTAMENTE el mismo estado que la anterior, entonces no se estaba
/// "reemplazando trabajo obsoleto" —se estaba repitiendo trabajo idéntico— y el
/// problema es de coordinación entre dueños, no de cancelar mejor.
///
/// La firma se compara con la de la carga anterior COMPLETADA. Si son iguales,
/// la recarga no aportó nada observable.
@MainActor
enum LoadDataTrace {
    private struct EnCurso {
        let id: Int
        let caller: String
        let inicio: Date
        var fase: String
    }

    private static var siguienteId = 1
    private static var enCurso: EnCurso?
    private static var ultimaFirma: String?
    private static var completadas = 0
    private static var canceladas = 0

    /// Llamar al entrar en loadData, ANTES de cancelar la anterior.
    static func inicia(_ caller: String) -> Int {
        let id = siguienteId
        siguienteId += 1

        if let previa = enCurso {
            let ms = Date().timeIntervalSince(previa.inicio) * 1000
            canceladas += 1
            print(String(format: "🏠 [loadData #%d] ← %@  ⚠️ CANCELA #%d (← %@) en fase «%@» tras %.0f ms",
                         id, caller, previa.id, previa.caller, previa.fase, ms))
        } else {
            print("🏠 [loadData #\(id)] ← \(caller)")
        }

        enCurso = EnCurso(id: id, caller: caller, inicio: Date(), fase: "arranque")
        return id
    }

    /// Marca en qué punto va la carga. Es lo que convierte "se canceló" en
    /// "se canceló habiendo pagado ya journeys y matches".
    static func fase(_ id: Int, _ nombre: String) {
        guard enCurso?.id == id else { return }   // una carga vieja no pisa la actual
        enCurso?.fase = nombre
    }

    /// - Parameter firma: estado observable resultante. Si coincide con la de la
    ///   última carga completada, esta recarga no cambió nada.
    static func termina(_ id: Int, cancelada: Bool, firma: String) {
        guard enCurso?.id == id else {
            // Otra carga ya tomó el relevo: esta murió cancelada y su final no
            // dice nada del estado actual.
            return
        }
        let ms = Date().timeIntervalSince(enCurso!.inicio) * 1000
        let fase = enCurso!.fase
        enCurso = nil

        if cancelada {
            print(String(format: "🏠 [loadData #%d] ✂️ cancelada en fase «%@» tras %.0f ms", id, fase, ms))
            return
        }

        completadas += 1
        let igual = (firma == ultimaFirma)
        ultimaFirma = firma
        print(String(format: "🏠 [loadData #%d] ✅ completa en %.0f ms — %@",
                     id, ms,
                     igual ? "estado IDÉNTICO al anterior · la recarga no cambió nada ⚠️"
                           : "estado distinto · la recarga sí aportó"))
        print("🏠 [loadData] acumulado: \(completadas) completada(s), \(canceladas) cancelada(s)")
    }
}
