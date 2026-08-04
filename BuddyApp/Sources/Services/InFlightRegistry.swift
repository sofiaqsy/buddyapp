import Foundation

/// Deduplicación de trabajo EN VUELO, por identidad de lo que se está pidiendo.
///
/// POR QUÉ NO ALCANZA UN THROTTLE
///
/// Un throttle por tiempo mide "cuánto pasó desde que la última llamada
/// TERMINÓ". No puede ver una llamada que todavía no terminó, así que tres
/// disparadores que caen dentro de la misma décima de segundo lo atraviesan
/// los tres:
///
///     t=0.00  A → pasa el guard (nadie terminó aún)
///     t=0.05  B → pasa el guard
///     t=0.10  C → pasa el guard
///     t=0.90  A termina y recién ahí escribe el reloj
///
/// Eso es exactamente lo que mostró el log del arranque: `recent-help` del
/// mismo destino pedido dos veces con 30s de throttle configurado.
///
/// POR QUÉ LA CLAVE, Y NO UNA SOLA TAREA
///
/// Guardar una única `refreshTask` deduplicaría de más: una petición para OTRO
/// destino es trabajo legítimamente distinto y quedaría absorbida por la que ya
/// está en vuelo, devolviendo el contexto equivocado. La clave separa "esto ya
/// se está pidiendo" de "esto es otra cosa".
///
/// Es también lo que hace que el arreglo sobreviva a un cambio rápido de
/// destino: las dos cargas conviven en vez de pisarse.
@MainActor
final class InFlightRegistry<Key: Hashable> {
    private var tasks: [Key: Task<Void, Never>] = [:]

    /// Ejecuta `work` para `key`, o se engancha a la ejecución que ya esté en
    /// vuelo para esa misma clave.
    ///
    /// - Parameter replaceExisting: para disparadores que saben que el mundo
    ///   cambió (pull-to-refresh, un apoyo recién cerrado). Sin esto, esos
    ///   casos se colgarían de una petición que salió ANTES del cambio y
    ///   devolvería datos ya viejos.
    func run(_ key: Key, replaceExisting: Bool = false, _ work: @escaping () async -> Void) async {
        if let existing = tasks[key] {
            if replaceExisting {
                existing.cancel()
            } else {
                await existing.value
                return
            }
        }

        let task = Task<Void, Never> { await work() }
        tasks[key] = task
        await task.value

        // Solo limpiar si la entrada sigue siendo LA MÍA: si mientras tanto un
        // `replaceExisting` puso otra tarea, borrarla dejaría a esa sin registrar
        // y volveríamos a tener llamadas duplicadas.
        if tasks[key] == task { tasks[key] = nil }
    }

    /// ¿Esta clave ya se está pidiendo? Para que un llamador que trae varias
    /// claves a la vez pueda saltarse las que otro ya tiene en vuelo.
    func enVuelo(_ key: Key) -> Bool { tasks[key] != nil }

    /// Cuántas claves están en vuelo. Solo para diagnóstico.
    var clavesEnVuelo: Int { tasks.count }
}

/// Identidad del contexto de comunidad del Home.
///
/// Lleva el `traveler` además del lugar: si la sesión cambia mientras una carga
/// vuela, la nueva no debe engancharse a la del usuario anterior.
enum HomeContextKey: Hashable {
    /// El contexto viene de un trip elegido.
    case trip(traveler: String?, destinationId: String?, placeId: String?)
    /// No hay trip: el contexto sale de resolver el GPS contra el backend.
    case ubicacion(traveler: String?)
}

/// Registros compartidos por la Home. Vive como `@StateObject` en la vista, así
/// que muere con ella y no filtra tareas entre sesiones.
@MainActor
final class HomeInFlight: ObservableObject {
    let contexto = InFlightRegistry<HomeContextKey>()
    /// Clave: destinationId. `recent-help` se pide por destino y es el que más
    /// se duplicaba: dos dueños distintos pedían el mismo id a la vez.
    let recentHelp = InFlightRegistry<String>()
}
