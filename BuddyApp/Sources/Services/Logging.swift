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
