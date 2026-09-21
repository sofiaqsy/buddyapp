import Foundation

// MARK: – FeedRanking
//
// La capa que decide QUÉ se ve y en qué orden. El paginador vertical solo
// navega: recibe una secuencia ya resuelta y no sabe nada de cercanía.
//
// El orden de los LUGARES llega ya hecho (la RPC los trae del más cercano al
// más lejano y stableOrder los reafina en cubos de 10 m). Lo que falta acá es
// repartir las FOTOS: aplanar lugar por lugar ponía las tres fotos de "El
// encanto" en las tres primeras páginas, y el feed parecía un solo sitio.
//
//
// ESPECIFICACIÓN
//
// Esto es el contrato de secuencia(porLugar:id:lugar:recientes:). Está escrito
// como invariantes y no como pasos porque lo que no puede romperse es el
// RESULTADO: cualquier señal que se agregue después (popularidad, novedad,
// "lo recomendó alguien que conocés", personalización) tiene que operar
// DENTRO de estas reglas, nunca compitiendo contra ellas.
//
//   Dados
//     P            lugares distintos, YA ordenados por distancia (P[0] es el
//                  más cercano disponible)
//     fotos(p)     las fotos de p, en su orden de origen (la visita más
//                  reciente primero)
//     recientes    ids de fotos que el usuario acaba de ver
//     K            min(3, |P|)
//
//   I1 — PREFIJO PROTEGIDO
//        Para i < K: feed[i] ∈ fotos(P[i]) y, en concreto, es fotos(P[i])[0].
//        O sea: las primeras K páginas son los K lugares más cercanos
//        disponibles, uno cada uno y en orden de distancia.
//
//   I2 — LUGARES DISTINTOS AL ARRANQUE
//        Los lugares de feed[0..<K] son distintos entre sí. (Se deduce de I1,
//        pero se enuncia porque es LA razón de producto: el arranque dice
//        "esto es lo que hay alrededor tuyo", no "mirá este sitio".)
//
//   I3 — recientes NO TOCA EL PREFIJO
//        La memoria de lo ya visto no puede reordenar feed[0..<K]. Solo
//        empuja, dentro de su ronda, a partir de la posición K.
//
//   I4 — COBERTURA EXACTA
//        feed es una permutación de todas las fotos: cada una aparece
//        EXACTAMENTE UNA VEZ antes de que el ciclo vuelva a empezar. Ninguna
//        se descarta y ninguna se repite. (El feed es cíclico por índice
//        lógico: la repetición ocurre al dar la vuelta, no dentro de ella.)
//
//   I5 — SIN VECINOS DEL MISMO LUGAR, MIENTRAS SE PUEDA
//        Para i > 0, lugar(feed[i]) ≠ lugar(feed[i-1]); y por la costura del
//        ciclo, lugar(feed.last) ≠ lugar(feed.first).
//        Con dos excepciones, y las dos son imposibilidades, no permisos:
//          a) al final del feed, cuando ya solo queda un lugar con fotos
//             pendientes: no hay con qué alternar;
//          b) en la costura, cuando el lugar de la última foto es también el
//             de la primera y ninguna otra puede pasar al final sin romper
//             I5 donde estaba (pasa cuando el lugar más cercano es además el
//             que más fotos tiene: su cola es el final del feed). El prefijo
//             protegido no cuenta como arreglo posible: I1 manda sobre I5.
//
//   "MÁS CERCANO DISPONIBLE" ≠ "CERCA"
//        I1 ordena por distancia relativa. Si los tres primeros están a 3, 4 y
//        5 km siguen siendo los tres primeros; el feed no afirma en ningún
//        lado que estén cerca. Esa afirmación la hace la tarjeta, que dice la
//        distancia o el tiempo caminando reales.
//
//   FUERA DEL CONTRATO (puede cambiar sin romper nada)
//        El orden exacto de i >= K. Hoy es por rondas —la ronda k lleva la
//        k-ésima foto de cada lugar— con el empujón de `recientes` y la
//        separación de I5. Por esa separación, las fotos de un mismo lugar
//        pueden salir desordenadas entre sí al final del feed (D3 → D5 → D4).
//        Es cosmético y está aceptado: estabilizarlo es una mejora futura.
//
//   Las pruebas de Tools/main.swift fijan estas invariantes con casos
//   deterministas, sin Xcode ni simulador.
enum FeedRanking {

    /// Reparte por RONDAS: la ronda k lleva la k-ésima foto de cada lugar, en
    /// el orden de cercanía que ya traen. Así el primer tramo del feed es una
    /// foto de cada lugar cercano, ningún sitio acapara las primeras páginas
    /// por tener muchas fotos, y no se descarta ninguna: las rondas siguientes
    /// las traen. La cercanía sigue mandando —dentro de cada ronda el orden es
    /// el de distancia— y un lugar vuelve a aparecer más adelante con otra foto.
    ///
    /// `recientes` es un empujón, no un veto: una foto ya vista se va al FINAL
    /// de su ronda, no fuera del feed. Sirve para que al recalcular el orden
    /// (el usuario se movió) no vuelva a salir de una lo que se acaba de ver.
    static func secuencia<Foto>(
        porLugar: [[Foto]],
        id: (Foto) -> String,
        lugar: (Foto) -> String,
        recientes: Set<String>,
    ) -> [Foto] {
        let conFotos = porLugar.filter { !$0.isEmpty }
        guard !conFotos.isEmpty else { return [] }

        // CAPA PROTEGIDA: las primeras páginas son los lugares MÁS CERCANOS
        // disponibles, uno cada uno, en orden de cercanía. Es una regla de
        // producto, no una preferencia de puntaje: el arranque del feed tiene
        // que decir "esto es lo que hay alrededor tuyo", y ningún otro
        // criterio —ni la variedad ni lo que ya se vio— puede colar antes un
        // lugar más lejano. "Más cercano disponible" no significa "cerca": si
        // los tres primeros están a 3, 4 y 5 km, siguen siendo los tres
        // primeros, pero el feed no afirma que estén cerca.
        let protegidas = conFotos.prefix(protegidos).map { $0[0] }

        // El resto: todas las fotos menos las ya usadas, repartidas por rondas
        // (la ronda k lleva la k-ésima foto de cada lugar, en orden de
        // cercanía). Así ningún sitio acapara por tener muchas fotos y no se
        // descarta ninguna. Acá sí pesa lo ya visto, como empujón.
        let usadas = Set(protegidas.map(id))
        let rondas = conFotos.map(\.count).max() ?? 0
        var cola: [Foto] = []
        for k in 0..<rondas {
            // Las rondas van por el índice ORIGINAL de la foto dentro de su
            // lugar, no por su posición tras sacar las protegidas. Si no, la
            // PRIMERA foto de un lugar que aún no salió (D1) quedaba detrás de
            // la SEGUNDA de uno que ya salió (A2), y un sitio igual de cerca
            // aparecía recién en la séptima página.
            let ronda = conFotos.compactMap { fotos -> Foto? in
                guard fotos.count > k, !usadas.contains(id(fotos[k])) else { return nil }
                return fotos[k]
            }
            // Partición estable: lo no visto conserva su orden de cercanía y lo
            // visto lo sigue, también en orden de cercanía.
            cola += ronda.filter { !recientes.contains(id($0)) }
            cola += ronda.filter { recientes.contains(id($0)) }
        }

        // La reparación de vecinos iguales no puede tocar la capa protegida:
        // solo reordena de ahí en adelante (y la costura con la protegida).
        return Array(protegidas) + separandoLugaresIguales(
            cola,
            lugar: lugar,
            anterior: protegidas.last.map(lugar),
            primeraDelCiclo: protegidas.first.map(lugar),
        )
    }

    /// Cuántas páginas protege la capa de cercanía. Tres porque es lo que se
    /// alcanza a ver en los primeros gestos: con menos lugares disponibles se
    /// protegen los que haya.
    private static let protegidos = 3

    /// Separa vecinos del mismo lugar (I5) SIN tocar la capa protegida: recorre
    /// la cola una sola vez y, en cada paso, toma la primera foto pendiente
    /// cuyo lugar no sea el que acaba de salir; si todas son de ese lugar
    /// —porque ya no queda otro con fotos—, toma la primera igual. Conserva el
    /// orden relativo salvo por esos adelantos mínimos.
    ///
    /// Antes esto era un bucle que recorría índices mientras removía e
    /// insertaba en el mismo array: los índices se corrían y algunos pares
    /// quedaban sin separar (se veía como D3 → D5 pegados con A3 todavía
    /// disponible para separarlos).
    private static func separandoLugaresIguales<Foto>(
        _ fotos: [Foto],
        lugar: (Foto) -> String,
        anterior: String? = nil,
        primeraDelCiclo: String? = nil,
    ) -> [Foto] {
        guard fotos.count > 1 else { return fotos }
        var pendientes = fotos
        var salida: [Foto] = []
        salida.reserveCapacity(fotos.count)
        var ultimo = anterior

        while !pendientes.isEmpty {
            let i = pendientes.firstIndex { lugar($0) != ultimo } ?? 0
            let elegida = pendientes.remove(at: i)
            ultimo = lugar(elegida)
            salida.append(elegida)
        }

        // Costura del ciclo: la última se compara con la PRIMERA de todo el
        // feed, que con capa protegida no es la primera de esta cola.
        if let ultima = salida.last, let primera = primeraDelCiclo ?? salida.first.map(lugar),
           lugar(ultima) == primera, salida.count > 2,
           let j = salida.indices.reversed().dropFirst().first(where: {
               lugar(salida[$0]) != primera && (j0(salida, $0, lugar) )
           }) {
            salida.swapAt(j, salida.count - 1)
        }
        return salida
    }

    /// El intercambio de la costura no puede crear un vecino igual en el sitio
    /// de donde sale la foto.
    private static func j0<Foto>(_ s: [Foto], _ j: Int, _ lugar: (Foto) -> String) -> Bool {
        let anterior = j > 0 ? lugar(s[j - 1]) : nil
        let siguiente = j + 1 < s.count ? lugar(s[j + 1]) : nil
        let entrante = lugar(s[s.count - 1])
        return entrante != anterior && entrante != siguiente
    }
}

// MARK: – FeedMemoria
//
// Lo último que el usuario vio de verdad (páginas asentadas, no las que
// cruzaron el visor). Solo se consulta al RECONSTRUIR la secuencia, nunca
// mientras se desliza: el feed no puede reordenarse bajo el dedo.
@MainActor
final class FeedMemoria {
    static let shared = FeedMemoria()
    private init() {}

    private var fotos: [String] = []

    /// Cuántas recordar. Es el tamaño del catálogo que pide el Home
    /// (/feed/place-shares?limit=12): con eso alcanza para no repetir dentro
    /// de una misma vuelta y, pasada una vuelta entera, todo vuelve a ser
    /// elegible. Nada queda excluido para siempre.
    private static let capacidad = 12

    var recientes: Set<String> { Set(fotos) }

    func registrar(fotoId: String) {
        fotos.removeAll { $0 == fotoId }
        fotos.append(fotoId)
        if fotos.count > Self.capacidad { fotos.removeFirst(fotos.count - Self.capacidad) }
    }
}
