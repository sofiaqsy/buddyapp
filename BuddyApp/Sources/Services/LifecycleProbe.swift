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
