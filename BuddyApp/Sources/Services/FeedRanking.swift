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

    /// Arregla el único punto donde las rondas pueden dejar dos fotos del mismo
    /// lugar juntas: la costura entre el final de una ronda y el principio de
    /// la siguiente (ambas empiezan por el lugar más cercano). Es una
    /// reparación LOCAL —se adelanta la siguiente foto de otro lugar— así que
    /// el orden por cercanía se conserva salvo por ese salto mínimo. El feed es
    /// cíclico, de modo que la última también se compara con la primera.
    private static func separandoLugaresIguales<Foto>(
        _ fotos: [Foto],
        lugar: (Foto) -> String,
        anterior: String? = nil,
        primeraDelCiclo: String? = nil,
    ) -> [Foto] {
        guard fotos.count > 2 else { return fotos }
        var salida = fotos
        // La costura con la capa protegida cuenta como un vecino más: el
        // último lugar protegido no puede repetirse en la primera de la cola.
        if let anterior, lugar(salida[0]) == anterior,
           let j = (1..<salida.count).first(where: { lugar(salida[$0]) != anterior }) {
            let movida = salida.remove(at: j)
            salida.insert(movida, at: 0)
        }
        for i in 1..<salida.count where lugar(salida[i]) == lugar(salida[i - 1]) {
            // El primero que venga después y sea de otro lugar se adelanta a
            // esta posición.
            guard let j = (i + 1..<salida.count).first(where: {
                lugar(salida[$0]) != lugar(salida[i - 1])
            }) else { continue }
            let movida = salida.remove(at: j)
            salida.insert(movida, at: i)
        }
        // Costura del ciclo: la última se compara con la PRIMERA de todo el
        // feed, que con capa protegida no es la primera de esta cola.
        let primera = primeraDelCiclo ?? salida.first.map(lugar)
        if let ultima = salida.last, let primera,
           lugar(ultima) == primera, salida.count > 2,
           let j = salida.indices.reversed().dropFirst().first(where: {
               lugar(salida[$0]) != primera
           }) {
            salida.swapAt(j, salida.count - 1)
        }
        return salida
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
