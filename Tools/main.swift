// Pruebas deterministas del ranking del feed del Home.
//
// Se corren sin Xcode ni simulador, con el compilador a secas:
//
//     swiftc -O BuddyApp/Sources/Services/FeedRanking.swift Tools/main.swift -o /tmp/feedtests && /tmp/feedtests
//
// El archivo se llama main.swift porque Swift solo permite código suelto (sin
// función de entrada) en un archivo con ese nombre.
//
// FeedRanking no depende de SwiftUI ni de la red: recibe las fotos agrupadas
// por lugar (ya ordenados por cercanía) y devuelve la secuencia. Eso es lo que
// hace que estos casos se puedan fijar acá, sin datos reales de por medio.

struct FotoFake {
    let id: String
    let lugar: String
}

/// Un lugar con n fotos: A → A1, A2, A3…
func lugar(_ nombre: String, fotos n: Int) -> [FotoFake] {
    (1...n).map { FotoFake(id: "\(nombre)\($0)", lugar: nombre) }
}

func secuencia(_ porLugar: [[FotoFake]], vistas: Set<String> = []) -> [String] {
    FeedRanking.secuencia(
        porLugar: porLugar,
        id: { $0.id },
        lugar: { $0.lugar },
        recientes: vistas,
    ).map(\.id)
}

var fallos = 0

func revisar(_ caso: String, _ real: [String], primeros: [String]) {
    let inicio = Array(real.prefix(primeros.count))
    let ok = inicio == primeros
    if !ok { fallos += 1 }
    print("\(ok ? "OK  " : "FALLA") \(caso)")
    print("      esperado: \(primeros.joined(separator: " → "))")
    print("      real:     \(inicio.joined(separator: " → "))")
    print("      completa: \(real.joined(separator: " → "))")
}

func revisarInvariante(_ caso: String, _ real: [String], lugares: [[FotoFake]]) {
    // Ningún lugar repetido en las primeras posiciones protegidas.
    let protegidas = min(3, lugares.filter { !$0.isEmpty }.count)
    let inicio = real.prefix(protegidas).map { String($0.prefix(1)) }
    let distintos = Set(inicio).count == inicio.count
    // Y todas las fotos siguen estando.
    let total = lugares.flatMap { $0 }.count
    let completo = Set(real).count == total && real.count == total
    if !(distintos && completo) { fallos += 1 }
    print("\(distintos && completo ? "OK  " : "FALLA") \(caso): \(protegidas) lugares distintos al inicio, \(real.count)/\(total) fotos")
}

// Caso 1 — el lugar con muchas fotos no puede acaparar el arranque.
let caso1 = [lugar("A", fotos: 5), lugar("B", fotos: 1), lugar("C", fotos: 1), lugar("D", fotos: 5)]
revisar("Caso 1 (A 100m x5, B 200m, C 300m, D 500m x5)", secuencia(caso1), primeros: ["A1", "B1", "C1"])
revisarInvariante("Caso 1 invariante", secuencia(caso1), lugares: caso1)

// Caso 2 — lo lejano no se cuela antes de lo más cercano disponible.
let caso2 = [lugar("A", fotos: 5), lugar("B", fotos: 1), lugar("C", fotos: 1), lugar("D", fotos: 5)]
revisar("Caso 2 (A 100m, B 2km, C 3km, D 20km)", secuencia(caso2), primeros: ["A1", "B1", "C1"])

// Caso 3 — solo dos lugares: se protegen los dos.
let caso3 = [lugar("A", fotos: 1), lugar("B", fotos: 1)]
revisar("Caso 3 (A 100m, B 200m)", secuencia(caso3), primeros: ["A1", "B1"])

// Caso 4 — cuatro lugares con cinco fotos cada uno.
let caso4 = [lugar("A", fotos: 5), lugar("B", fotos: 5), lugar("C", fotos: 5), lugar("D", fotos: 5)]
// Protegidas son 3, pero el cuarto lugar —igual de cerca y sin salir aún— tiene
// que llegar antes que la SEGUNDA foto de los ya vistos.
revisar("Caso 4 (4 lugares x5 fotos)", secuencia(caso4), primeros: ["A1", "B1", "C1", "D1"])
revisarInvariante("Caso 4 invariante", secuencia(caso4), lugares: caso4)

// Caso 5 — tras moverse, los lugares llegan en otro orden de cercanía: la capa
// protegida sale del orden NUEVO, no de un recuerdo del anterior.
let caso5 = [lugar("D", fotos: 5), lugar("E", fotos: 1), lugar("F", fotos: 2), lugar("A", fotos: 3)]
revisar("Caso 5 (tras moverse: D, E, F, A)", secuencia(caso5), primeros: ["D1", "E1", "F1"])

// Caso 6 — lo ya visto empuja, pero NO puede romper la capa protegida.
let caso6 = [lugar("A", fotos: 3), lugar("B", fotos: 2), lugar("C", fotos: 2), lugar("D", fotos: 2)]
revisar("Caso 6 (A1, B1 y C1 ya vistas)", secuencia(caso6, vistas: ["A1", "B1", "C1"]), primeros: ["A1", "B1", "C1"])

// Caso 7 — un solo lugar, y ninguno.
revisar("Caso 7 (un lugar, 3 fotos)", secuencia([lugar("A", fotos: 3)]), primeros: ["A1"])
let vacio = secuencia([])
print("\(vacio.isEmpty ? "OK  " : "FALLA") Caso 8 (sin lugares): \(vacio.count) fotos")
if !vacio.isEmpty { fallos += 1 }

print(fallos == 0 ? "\nTODO OK" : "\n\(fallos) FALLA(S)")
