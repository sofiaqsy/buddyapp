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

/// "L3" + "_" + foto → el lugar de una FotoFake (id "L31" = lugar L3, foto 1).
func lugarDe(_ idFoto: String) -> String { String(idFoto.dropLast()) }

// ── Mezcla comunidad + Google (FeedMix, Services/FeedRanking.swift) ──────────
//
// Verifica M1–M6 con casos fijos y un barrido exhaustivo de tamaños, y que las
// invariantes I1–I5 de FeedRanking siguen valiendo para la comunidad.

struct TarjetaFake { let id: String; let lugar: String; let placeId: String?; let esGoogle: Bool }

func comunidadFake(_ n: Int) -> [TarjetaFake] { (0..<n).map { TarjetaFake(id: "C\($0)", lugar: "C\($0)", placeId: nil, esGoogle: false) } }
func googleFake(_ n: Int) -> [TarjetaFake] { (0..<n).map { TarjetaFake(id: "G\($0)", lugar: "google:P\($0)", placeId: "P\($0)", esGoogle: true) } }
func ids(_ xs: [TarjetaFake]) -> [String] { xs.map(\.id) }

func revisarMezcla(_ caso: String, _ ok: Bool, _ detalle: @autoclosure () -> String = "") {
    if !ok { fallos += 1 }
    print("\(ok ? "OK  " : "FALLA") Mezcla — \(caso)\(ok ? "" : "  \(detalle())")")
}

revisarMezcla("M6 sin Google: el resultado es exactamente la comunidad", ids(FeedMix.mezclar(comunidad: comunidadFake(12), google: [])) == ids(comunidadFake(12)))
revisarMezcla("sin comunidad: Google llena el feed", ids(FeedMix.mezclar(comunidad: [], google: googleFake(5))) == ["G0", "G1", "G2", "G3", "G4"])
revisarMezcla("sin nada: vacío", FeedMix.mezclar(comunidad: [TarjetaFake](), google: []).isEmpty)
revisarMezcla("12 de comunidad + 8 de Google: prefijo C0 C1 C2, luego G C C", ids(FeedMix.mezclar(comunidad: comunidadFake(12), google: googleFake(8))).prefix(9).elementsEqual(["C0", "C1", "C2", "G0", "C3", "C4", "G1", "C5", "C6"]))
revisarMezcla("12 + 8: el tope de un tercio deja 6 de Google (18 en total)", { () -> Bool in
    let r = FeedMix.mezclar(comunidad: comunidadFake(12), google: googleFake(8)); return r.count == 18 && r.filter(\.esGoogle).count == 6 }())
revisarMezcla("12 + 8: ejemplo completo", ids(FeedMix.mezclar(comunidad: comunidadFake(12), google: googleFake(8))) == ["C0","C1","C2","G0","C3","C4","G1","C5","C6","G2","C7","C8","G3","C9","C10","G4","C11","G5"])
revisarMezcla("3 de comunidad + 5 de Google: caben 1, al final", ids(FeedMix.mezclar(comunidad: comunidadFake(3), google: googleFake(5))) == ["C0", "C1", "C2", "G0"])
revisarMezcla("2 de comunidad: caben 1 de Google, tras las 2", ids(FeedMix.mezclar(comunidad: comunidadFake(2), google: googleFake(4))) == ["C0", "C1", "G0"])
revisarMezcla("1 de comunidad: Google no cabe (1/3 de 2 = 0)", ids(FeedMix.mezclar(comunidad: comunidadFake(1), google: googleFake(4))) == ["C0"])
revisarMezcla("poca Google (2) con mucha comunidad (12): se usan las 2", ids(FeedMix.mezclar(comunidad: comunidadFake(12), google: googleFake(2))).filter { $0.hasPrefix("G") } == ["G0", "G1"])
revisarMezcla("M5 determinista: dos corridas iguales", ids(FeedMix.mezclar(comunidad: comunidadFake(9), google: googleFake(7))) == ids(FeedMix.mezclar(comunidad: comunidadFake(9), google: googleFake(7))))
revisarMezcla("no toca la entrada (la comunidad se pasa por valor)", { () -> Bool in
    let c = comunidadFake(6); let g = googleFake(3); _ = FeedMix.mezclar(comunidad: c, google: g); return ids(c) == ids(comunidadFake(6)) && ids(g) == ids(googleFake(3)) }())

// Barrido exhaustivo: comunidad 0…30 × Google 0…30.
var barridoOk = true
var barridoDetalle = ""
for n in 0...30 {
    for g in 0...30 {
        let c = comunidadFake(n), go = googleFake(g)
        let r = FeedMix.mezclar(comunidad: c, google: go)
        let usadasG = r.filter(\.esGoogle)
        let soloC = r.filter { !$0.esGoogle }
        var motivo = ""
        if ids(soloC) != ids(c) { motivo = "M2 comunidad alterada" }                                   // subsecuencia exacta y completa
        else if n > 0 && !(ids(r.prefix(min(3, n)).map { $0 }) == ids(Array(c.prefix(min(3, n))))) { motivo = "M1 prefijo" }
        else if n > 0 && usadasG.count * 3 > r.count { motivo = "M4 más de un tercio" }
        else if n == 0 && ids(r) != ids(go) { motivo = "sin comunidad" }
        else if ids(usadasG) != ids(Array(go.prefix(usadasG.count))) { motivo = "orden de Google alterado" }
        else if n > 0 && usadasG.count != min(g, FeedMix.maximoDeGoogle(comunidad: n)) { motivo = "uso de Google distinto del esperado" }
        else if Set(ids(r)).count != r.count { motivo = "tarjeta repetida" }
        if !motivo.isEmpty && barridoOk { barridoOk = false; barridoDetalle = "n=\(n) g=\(g): \(motivo)" }
    }
}
revisarMezcla("barrido 0…30 × 0…30: M1, M2, M4, orden de Google, sin repetidas", barridoOk, barridoDetalle)

// FeedRanking + FeedMix: I1–I5 para la comunidad se conservan con Google en medio.
func lugaresCercanos(_ n: Int, fotosPorLugar: Int) -> [[FotoFake]] { (0..<n).map { lugar("L\($0)", fotos: fotosPorLugar) } }
var invariantesOk = true
var invariantesDetalle = ""
for lugares in 1...8 {
    for fotos in 1...4 {
        let base = secuencia(lugaresCercanos(lugares, fotosPorLugar: fotos))
        let conLugar = base.map { TarjetaFake(id: $0, lugar: lugarDe($0), placeId: nil, esGoogle: false) }
        let mezcla = FeedMix.mezclar(comunidad: conLugar, google: googleFake(8))
        let soloC = mezcla.filter { !$0.esGoogle }
        if ids(soloC) != ids(conLugar) { invariantesOk = false; invariantesDetalle = "lugares=\(lugares) fotos=\(fotos): orden de comunidad alterado"; break }
        // I1: las primeras K son la primera foto de los K lugares más cercanos, en orden.
        let k = min(3, lugares)
        if ids(Array(mezcla.prefix(k))) != (0..<k).map({ "L\($0)1" }) { invariantesOk = false; invariantesDetalle = "lugares=\(lugares) fotos=\(fotos): I1 prefijo"; break }
        // I5 entre tarjetas vecinas de la comunidad: un Google en medio no puede crear vecinos iguales.
        for i in 1..<mezcla.count where mezcla[i].lugar == mezcla[i - 1].lugar && lugares > 1 && !base.isEmpty {
            // solo es válido si el original ya los tenía juntos (excepción documentada de FeedRanking)
            let a = mezcla[i - 1].id, b = mezcla[i].id
            if let ia = base.firstIndex(of: a), let ib = base.firstIndex(of: b), ib != ia + 1 {
                invariantesOk = false; invariantesDetalle = "lugares=\(lugares) fotos=\(fotos): vecinos del mismo lugar nuevos (\(a),\(b))"
            }
        }
    }
}
revisarMezcla("FeedRanking + FeedMix: la comunidad conserva orden, prefijo I1 y no aparecen vecinos del mismo lugar", invariantesOk, invariantesDetalle)

// Deduplicación por Place ID EXACTO.
let googleConIds = [
    TarjetaFake(id: "Ga", lugar: "google:PID1", placeId: "PID1", esGoogle: true),
    TarjetaFake(id: "Gb", lugar: "google:PID2", placeId: "PID2", esGoogle: true),
    TarjetaFake(id: "Gc", lugar: "google:PID3", placeId: "PID3", esGoogle: true),
    TarjetaFake(id: "Gd", lugar: "google:PID1", placeId: "PID1", esGoogle: true),   // repetida de Google
    TarjetaFake(id: "Ge", lugar: "google:", placeId: "", esGoogle: true),             // sin Place ID
]
let sinRepetidos = FeedMix.descartandoRepetidos(google: googleConIds, placeId: { $0.placeId ?? "" }, enComunidad: ["PID2"])
revisarMezcla("dedup: el Place ID que ya está en la comunidad se quita (PID2)", !ids(sinRepetidos).contains("Gb"))
revisarMezcla("dedup: los demás se quedan, en su orden, sin repetidas de Google ni ids vacíos", ids(sinRepetidos) == ["Ga", "Gc"])
let mismoNombre = [TarjetaFake(id: "G1", lugar: "google:PIDA", placeId: "PIDA", esGoogle: true)]
revisarMezcla("dedup: mismo nombre, distinto Place ID → NO se descarta (nunca por nombre)", ids(FeedMix.descartandoRepetidos(google: mismoNombre, placeId: { $0.placeId ?? "" }, enComunidad: ["PIDB"])) == ["G1"])
revisarMezcla("dedup: sin Place ID en la comunidad no descarta nada", ids(FeedMix.descartandoRepetidos(google: googleConIds, placeId: { $0.placeId ?? "" }, enComunidad: [])) == ["Ga", "Gb", "Gc"])

// ── Descubrimiento con Google (GoogleDiscoverSupport, Models/Place.swift) ─────

let t0 = Date(timeIntervalSince1970: 1_000_000)
revisar("primera vez: hay que buscar", GoogleDiscoverSupport.debeBuscar(ultima: nil, lat: -12.0464, lng: -77.0428, ahora: t0))
let ult = (lat: -12.0464, lng: -77.0428, fecha: t0)
revisar("misma zona y reciente (30 s): NO se vuelve a pedir", GoogleDiscoverSupport.debeBuscar(ultima: ult, lat: -12.0465, lng: -77.0429, ahora: t0.addingTimeInterval(30)), esperado: false)
revisar("misma zona a los 9 min: todavía no", GoogleDiscoverSupport.debeBuscar(ultima: ult, lat: -12.0464, lng: -77.0428, ahora: t0.addingTimeInterval(540)), esperado: false)
revisar("misma zona a los 10 min: sí", GoogleDiscoverSupport.debeBuscar(ultima: ult, lat: -12.0464, lng: -77.0428, ahora: t0.addingTimeInterval(601)))
revisar("se movió ~2 km (reciente): sí", GoogleDiscoverSupport.debeBuscar(ultima: ult, lat: -12.0644, lng: -77.0428, ahora: t0.addingTimeInterval(20)))
revisar("se movió ~500 m (reciente): no", GoogleDiscoverSupport.debeBuscar(ultima: ult, lat: -12.0509, lng: -77.0428, ahora: t0.addingTimeInterval(20)), esperado: false)

let rutaOk = "/v1/places/google/photo-media?token=abc.def_ghi-1"
revisar("tarjeta válida", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: rutaOk, distanciaMetros: 800))
revisar("sin prefijo google: se descarta", GoogleDiscoverSupport.esValida(id: "ChIJabc", name: "Café", primeraRuta: rutaOk, distanciaMetros: 800), esperado: false)
revisar("id vacío tras el prefijo: se descarta", GoogleDiscoverSupport.esValida(id: "google:", name: "Café", primeraRuta: rutaOk, distanciaMetros: 800), esperado: false)
revisar("nombre en blanco: se descarta", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "  ", primeraRuta: rutaOk, distanciaMetros: 800), esperado: false)
revisar("sin foto: se descarta", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: nil, distanciaMetros: 800), esperado: false)
revisar("foto con URL ajena (no del backend): se descarta", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: "https://lh3.googleusercontent.com/x", distanciaMetros: 800), esperado: false)
revisar("a 10.000 m: entra (límite inclusivo)", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: rutaOk, distanciaMetros: 10_000))
revisar("a 10.001 m: se descarta", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: rutaOk, distanciaMetros: 10_001), esperado: false)
revisar("sin distancia: entra (el servidor ya filtró)", GoogleDiscoverSupport.esValida(id: "google:ChIJabc", name: "Café", primeraRuta: rutaOk, distanciaMetros: nil))
revisar("segunda línea: categoría y crédito", GoogleDiscoverSupport.segundaLinea(categoria: "Cafetería", autores: ["Ana"]) == "Cafetería · Foto: Ana")
revisar("segunda línea: solo categoría", GoogleDiscoverSupport.segundaLinea(categoria: "Cafetería", autores: []) == "Cafetería")
revisar("segunda línea: solo crédito", GoogleDiscoverSupport.segundaLinea(categoria: nil, autores: ["Ana", "Beto"]) == "Foto: Ana y Beto")
revisar("segunda línea: nada", GoogleDiscoverSupport.segundaLinea(categoria: " ", autores: []) == "")

revisar("comunidad a 800 m: cerca", GoogleDiscoverSupport.estaCerca(distanciaMetros: 800))
revisar("comunidad a 10.000 m: cerca (límite inclusivo)", GoogleDiscoverSupport.estaCerca(distanciaMetros: 10_000))
revisar("comunidad a 10.001 m: lejos", GoogleDiscoverSupport.estaCerca(distanciaMetros: 10_001), esperado: false)
revisar("comunidad a 409 km: lejos", GoogleDiscoverSupport.estaCerca(distanciaMetros: 409_555), esperado: false)
revisar("comunidad a 7.265 km: lejos", GoogleDiscoverSupport.estaCerca(distanciaMetros: 7_265_000), esperado: false)
revisar("comunidad sin distancia: se conserva", GoogleDiscoverSupport.estaCerca(distanciaMetros: nil))

print(fallos == 0 ? "\nTODO OK" : "\n\(fallos) FALLA(S)")
