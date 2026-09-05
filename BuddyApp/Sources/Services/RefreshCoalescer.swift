import Foundation

/// Une en una sola llamada de red los refreshes de token concurrentes.
///
/// El problema que resuelve: al arrancar, la app lanza todas sus peticiones a
/// la vez. Si el JWT ha caducado, TODAS reciben 401 a la vez y cada una pide
/// su propio refresh. En los logs de Heroku del 2026-09-05 se vieron tres
/// POST /v1/travelers/refresh idénticos en 1,3 s (564 + 292 + 576 ms) — dos
/// de ellos puro desperdicio, y una carrera real: con rotación de token, el
/// último refresh en llegar invalida los tokens que emitieron los otros.
///
/// Por qué un actor y no un `Task?` en la clase: el intento anterior guardaba
/// la tarea en una propiedad de una clase no aislada. Entre leer la propiedad
/// (nil) y asignarla, varios hilos entran a la vez, todos ven nil y todos
/// crean su tarea. El actor serializa ese leer-y-asignar, que es justamente
/// lo que hacía falta.
///
/// La reentrancia del actor juega a favor: mientras el primero espera a
/// `task.value`, los demás entran, ven la tarea en curso y se cuelgan de ella
/// en vez de crear otra.
actor RefreshCoalescer {

    private var inFlight: Task<String, Error>?

    /// Ejecuta `operation`, o se engancha a la que ya esté corriendo.
    /// Todos los que esperan reciben el mismo resultado — o el mismo error.
    func run(_ operation: @escaping () async throws -> String) async throws -> String {
        // Ya hay una en vuelo: esperar a esa. Ojo, sin `defer` aquí — quien
        // limpia `inFlight` es el que la creó, no los que se enganchan.
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
