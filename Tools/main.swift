// Pruebas deterministas del ranking del feed del Home y del enlace a la ficha
// de Google Maps (GoogleMapsLink) y las reglas de las fotos de Google (GooglePhotoSupport).
//
// Se corren sin Xcode ni simulador, con el compilador a secas:
//
//     swiftc -O BuddyApp/Sources/Services/FeedRanking.swift BuddyApp/Sources/Models/Place.swift Tools/main.swift -o /tmp/feedtests && /tmp/feedtests
//
// El archivo se llama main.swift porque Swift solo permite código suelto (sin
// función de entrada) en un archivo con ese nombre.
//
// FeedRanking no depende de SwiftUI ni de la red: recibe las fotos agrupadas
// por lugar (ya ordenados por cercanía) y devuelve la secuencia. Eso es lo que
// hace que estos casos se puedan fijar acá, sin datos reales de por medio.

import Foundation

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

// ── Enlace a la ficha de Google Maps (GoogleMapsLink, Models/Place.swift) ─────
//
// La URL la arma el backend con datos de una persona (nombre, Place ID). El
// cliente solo abre una búsqueda de Google Maps por https con query_place_id;
// todo lo demás es "sin ficha" y no se abre.

func revisarEnlace(_ caso: String, _ raw: String?, abre: Bool) {
    let real = GoogleMapsLink.openableURL(raw) != nil
    let ok = real == abre
    if !ok { fallos += 1 }
    print("\(ok ? "OK  " : "FALLA") Enlace — \(caso): \(real ? "abre" : "no abre") (esperado: \(abre ? "abre" : "no abre"))")
}

let fichaValida = "https://www.google.com/maps/search/?api=1&query=Cafeter%C3%ADa%20Rosal&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4"
revisarEnlace("URL del backend para un spot vinculado", fichaValida, abre: true)
revisarEnlace("spot sin vínculo (nil)", nil, abre: false)
revisarEnlace("spot sin vínculo (cadena vacía)", "", abre: false)
revisarEnlace("http en vez de https", fichaValida.replacingOccurrences(of: "https://", with: "http://"), abre: false)
revisarEnlace("otro host", "https://evil.example.com/maps/search/?api=1&query=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("host que solo empieza igual", "https://www.google.com.evil.example.com/maps/search/?api=1&query=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("otra ruta de google.com", "https://www.google.com/search?q=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("sin query_place_id", "https://www.google.com/maps/search/?api=1&query=Cafeter%C3%ADa%20Rosal", abre: false)
revisarEnlace("query_place_id vacío", "https://www.google.com/maps/search/?api=1&query=x&query_place_id=", abre: false)
revisarEnlace("puerto distinto en www.google.com", "https://www.google.com:8443/maps/search/?api=1&query=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("credenciales en la URL", "https://user:pass@www.google.com/maps/search/?api=1&query=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("usuario@host engañoso", "https://www.google.com@evil.example.com/maps/search/?api=1&query=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("esquema personalizado", "comgooglemaps://?q=x&query_place_id=ChIJN1t_tDeuEmsRUsoyG83frY4", abre: false)
revisarEnlace("texto que no es URL", "no es una url", abre: false)

// Place sin vínculo: el campo es nil por defecto y no hay nada que abrir.
let sinVinculo = Place(id: UUID(), name: "X", description: "", stickerSymbol: "mappin", stickerEmoji: "",
                       category: .culture, latitude: 0, longitude: 0, radiusMeters: 50)
revisarEnlace("Place sin vínculo (valor por defecto)", sinVinculo.googleMapsUrl, abre: false)

// ── Fotos de Google en el Home (GooglePhotoSupport, Models/Place.swift) ───────

func revisar(_ caso: String, _ real: Bool, esperado: Bool = true) {
    let ok = real == esperado
    if !ok { fallos += 1 }
    print("\(ok ? "OK  " : "FALLA") Fotos de Google — \(caso)")
}

let rutaBuena = "/v1/places/google/photo-media?token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhYmMifQ.c2lnLW5hbWU_-x"
revisar("ruta de descarga del backend: válida", GooglePhotoSupport.isValidImagePath(rutaBuena))
revisar("nil: no válida", GooglePhotoSupport.isValidImagePath(nil), esperado: false)
revisar("vacía: no válida", GooglePhotoSupport.isValidImagePath(""), esperado: false)
revisar("URL absoluta de otro host: NO se pide con la sesión", GooglePhotoSupport.isValidImagePath("https://evil.example.com/v1/places/google/photo-media?token=abc"), esperado: false)
revisar("URL de Google: tampoco (la app solo habla con el backend)", GooglePhotoSupport.isValidImagePath("https://lh3.googleusercontent.com/p/abc"), esperado: false)
revisar("otra ruta del backend: no válida", GooglePhotoSupport.isValidImagePath("/v1/travelers/me?token=abc"), esperado: false)
revisar("sin token: no válida", GooglePhotoSupport.isValidImagePath("/v1/places/google/photo-media?token="), esperado: false)
revisar("parámetros extra (&): no válida", GooglePhotoSupport.isValidImagePath(rutaBuena + "&redirect=https://evil.example.com"), esperado: false)
revisar("token con '/': no válida", GooglePhotoSupport.isValidImagePath("/v1/places/google/photo-media?token=a/b"), esperado: false)
revisar("token con '#': no válida", GooglePhotoSupport.isValidImagePath(rutaBuena + "#frag"), esperado: false)
revisar("ruta absurdamente larga: no válida", GooglePhotoSupport.isValidImagePath(GooglePhotoSupport.imagePathPrefix + String(repeating: "a", count: 3000)), esperado: false)

revisar("enlace de autor de Google (https): abre", GooglePhotoSupport.openableAuthorURL("https://maps.google.com/maps/contrib/1001") != nil)
revisar("enlace de autor www.google.com: abre", GooglePhotoSupport.openableAuthorURL("https://www.google.com/maps/contrib/1") != nil)
revisar("autor nil: no abre", GooglePhotoSupport.openableAuthorURL(nil) != nil, esperado: false)
revisar("autor http: no abre", GooglePhotoSupport.openableAuthorURL("http://www.google.com/maps/contrib/1") != nil, esperado: false)
revisar("autor en otro dominio: no abre", GooglePhotoSupport.openableAuthorURL("https://evil.example.com/x") != nil, esperado: false)
revisar("autor con host engañoso (google.com.evil...): no abre", GooglePhotoSupport.openableAuthorURL("https://www.google.com.evil.example.com/x") != nil, esperado: false)
revisar("autor con credenciales: no abre", GooglePhotoSupport.openableAuthorURL("https://www.google.com@evil.example.com/x") != nil, esperado: false)
revisar("autor con puerto: no abre", GooglePhotoSupport.openableAuthorURL("https://www.google.com:8443/x") != nil, esperado: false)
revisar("autor javascript: no abre", GooglePhotoSupport.openableAuthorURL("javascript:alert(1)") != nil, esperado: false)

revisar("crédito de un autor", GooglePhotoSupport.creditLine(["Ana"]) == "Foto: Ana")
revisar("crédito de dos autores", GooglePhotoSupport.creditLine(["Ana", "Beto"]) == "Foto: Ana y Beto")
revisar("sin autores: sin línea de crédito", GooglePhotoSupport.creditLine([]) == nil)
revisar("autores en blanco: sin línea de crédito", GooglePhotoSupport.creditLine(["  ", ""]) == nil)

print(fallos == 0 ? "\nTODO OK" : "\n\(fallos) FALLA(S)")
