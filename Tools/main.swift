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

/// Comprueba las invariantes de la especificación (ver FeedRanking.swift).
func revisarInvariante(_ caso: String, _ real: [String], lugares: [[FotoFake]]) {
    let conFotos = lugares.filter { !$0.isEmpty }
    let k = min(3, conFotos.count)
    let lugarDe: (String) -> String = { String($0.prefix(1)) }

    // I1 — el prefijo es la primera foto de los k lugares más cercanos.
    let esperado = conFotos.prefix(k).map(\.first!.id)
    let i1 = Array(real.prefix(k)) == esperado

    // I2 — esos k son lugares distintos.
    let i2 = Set(real.prefix(k).map(lugarDe)).count == k

    // I4 — cobertura exacta: cada foto, una sola vez.
    let todas = lugares.flatMap { $0 }.map(\.id)
    let i4 = real.count == todas.count && Set(real) == Set(todas)

    // I5 — sin vecinos del mismo lugar, salvo cuando ya solo queda un lugar
    // con fotos pendientes.
    var i5 = true
    for i in 1..<max(1, real.count) where lugarDe(real[i]) == lugarDe(real[i - 1]) {
        let quedan = Set(real[i...].map(lugarDe))
        if quedan.count > 1 { i5 = false }
    }
    // Costura del ciclo: solo es falla si EXISTÍA forma de arreglarla, o sea
    // si alguna foto de otro lugar podía pasar al final sin crear un vecino
    // igual donde estaba. Con el lugar más cercano acaparando la cola (tiene
    // más fotos que nadie), la repetición en la costura es inevitable.
    if let u = real.last, let p = real.first, real.count > 2, lugarDe(u) == lugarDe(p) {
        let habiaArreglo = real.indices.dropLast().contains { j in
            // El prefijo protegido (I1) es intocable: no cuenta como arreglo.
            guard j >= k, lugarDe(real[j]) != lugarDe(p) else { return false }
            let anterior = j > 0 ? lugarDe(real[j - 1]) : nil
            let siguiente = j + 1 < real.count - 1 ? lugarDe(real[j + 1]) : nil
            let entrante = lugarDe(real[real.count - 1])
            return entrante != anterior && entrante != siguiente
        }
        if habiaArreglo { i5 = false }
    }

    let ok = i1 && i2 && i4 && i5
    if !ok { fallos += 1 }
    print("\(ok ? "OK  " : "FALLA") \(caso) — I1:\(i1 ? "✓" : "✗") I2:\(i2 ? "✓" : "✗") I4:\(i4 ? "✓" : "✗") (\(real.count)/\(todas.count)) I5:\(i5 ? "✓" : "✗")")
}

// Caso 1 — el lugar con muchas fotos no puede acaparar el arranque.
let caso1 = [lugar("A", fotos: 5), lugar("B", fotos: 1), lugar("C", fotos: 1), lugar("D", fotos: 5)]
revisar("Caso 1 (A 100m x5, B 200m, C 300m, D 500m x5)", secuencia(caso1), primeros: ["A1", "B1", "C1"])
revisarInvariante("Caso 1 invariantes", secuencia(caso1), lugares: caso1)

// Caso 2 — lo lejano no se cuela antes de lo más cercano disponible.
let caso2 = [lugar("A", fotos: 5), lugar("B", fotos: 1), lugar("C", fotos: 1), lugar("D", fotos: 5)]
revisar("Caso 2 (A 100m, B 2km, C 3km, D 20km)", secuencia(caso2), primeros: ["A1", "B1", "C1"])

// Caso 3 — solo dos lugares: se protegen los dos.
let caso3 = [lugar("A", fotos: 1), lugar("B", fotos: 1)]
revisar("Caso 3 (A 100m, B 200m)", secuencia(caso3), primeros: ["A1", "B1"])
revisarInvariante("Caso 3 invariantes", secuencia(caso3), lugares: caso3)

// Caso 4 — cuatro lugares con cinco fotos cada uno.
let caso4 = [lugar("A", fotos: 5), lugar("B", fotos: 5), lugar("C", fotos: 5), lugar("D", fotos: 5)]
// Protegidas son 3, pero el cuarto lugar —igual de cerca y sin salir aún— tiene
// que llegar antes que la SEGUNDA foto de los ya vistos.
revisar("Caso 4 (4 lugares x5 fotos)", secuencia(caso4), primeros: ["A1", "B1", "C1", "D1"])
revisarInvariante("Caso 4 invariantes", secuencia(caso4), lugares: caso4)

// Caso 5 — tras moverse, los lugares llegan en otro orden de cercanía: la capa
// protegida sale del orden NUEVO, no de un recuerdo del anterior.
let caso5 = [lugar("D", fotos: 5), lugar("E", fotos: 1), lugar("F", fotos: 2), lugar("A", fotos: 3)]
revisar("Caso 5 (tras moverse: D, E, F, A)", secuencia(caso5), primeros: ["D1", "E1", "F1"])
revisarInvariante("Caso 5 invariantes", secuencia(caso5), lugares: caso5)

// Caso 6 — lo ya visto empuja, pero NO puede romper la capa protegida.
let caso6 = [lugar("A", fotos: 3), lugar("B", fotos: 2), lugar("C", fotos: 2), lugar("D", fotos: 2)]
revisar("Caso 6 (A1, B1 y C1 ya vistas)", secuencia(caso6, vistas: ["A1", "B1", "C1"]), primeros: ["A1", "B1", "C1"])
revisarInvariante("Caso 6 invariantes (I3: recientes no toca el prefijo)", secuencia(caso6, vistas: ["A1", "B1", "C1"]), lugares: caso6)

// Caso 7 — un solo lugar, y ninguno.
revisar("Caso 7 (un lugar, 3 fotos)", secuencia([lugar("A", fotos: 3)]), primeros: ["A1"])
let vacio = secuencia([])
print("\(vacio.isEmpty ? "OK  " : "FALLA") Caso 8 (sin lugares): \(vacio.count) fotos")
if !vacio.isEmpty { fallos += 1 }

print(fallos == 0 ? "\nTODO OK" : "\n\(fallos) FALLA(S)")
