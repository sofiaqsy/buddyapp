import Foundation

/// Log de diagnóstico: solo en builds de Debug.
///
/// Durante la estabilización se instrumentó medio cliente —cada foto del
/// cache, cada fix del GPS, cada petición y quién la pidió—. Eso sirvió para
/// encontrar la tormenta de peticiones del arranque, pero es instrumentación,
/// no comportamiento de la app: en release no tiene por qué estar.
///
/// Lo que NO pasa por acá y se sigue imprimiendo siempre: errores (❌),
/// advertencias (⚠️) y el bloque de arranque. Una release muda es tan difícil
/// de diagnosticar como una que lo grita todo.
@inline(__always)
func dlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}


// MARK: – Cronómetro
//
// Para responder "¿cuánto tarda el Home en estar listo?" con números y no con
// impresiones. Todo esto vive en Debug: en Release dlog no imprime y las
// medidas no se toman.

enum Cronometro {
    /// Momento en que arrancó la app. Sirve de cero para "desde el arranque".
    static let arranque = Date()

    static func desdeArranque() -> Int { ms(desde: arranque) }

    static func ms(desde inicio: Date) -> Int { Int(Date().timeIntervalSince(inicio) * 1000) }

    /// Mide un tramo y lo deja en el log con su nombre.
    @discardableResult
    static func medir<T>(_ nombre: String, _ cuerpo: () throws -> T) rethrows -> T {
        let t0 = Date()
        let r = try cuerpo()
        dlog("⏱️ [tiempo] \(nombre) \(ms(desde: t0))ms")
        return r
    }
}
