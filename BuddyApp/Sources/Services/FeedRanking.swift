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
        let rondas = porLugar.map(\.count).max() ?? 0
        var salida: [Foto] = []
        for k in 0..<rondas {
            let ronda = porLugar.compactMap { $0.count > k ? $0[k] : nil }
            // Partición estable: lo no visto conserva su orden de cercanía y lo
            // visto lo sigue, también en orden de cercanía.
            salida += ronda.filter { !recientes.contains(id($0)) }
            salida += ronda.filter { recientes.contains(id($0)) }
        }
        return separandoLugaresIguales(salida, lugar: lugar)
    }

    /// Arregla el único punto donde las rondas pueden dejar dos fotos del mismo
    /// lugar juntas: la costura entre el final de una ronda y el principio de
    /// la siguiente (ambas empiezan por el lugar más cercano). Es una
    /// reparación LOCAL —se adelanta la siguiente foto de otro lugar— así que
    /// el orden por cercanía se conserva salvo por ese salto mínimo. El feed es
    /// cíclico, de modo que la última también se compara con la primera.
    private static func separandoLugaresIguales<Foto>(
        _ fotos: [Foto],
        lugar: (Foto) -> String,
    ) -> [Foto] {
        guard fotos.count > 2 else { return fotos }
        var salida = fotos
        for i in 1..<salida.count where lugar(salida[i]) == lugar(salida[i - 1]) {
            // El primero que venga después y sea de otro lugar (y que tampoco
            // choque con el que quedaría detrás) se adelanta a esta posición.
            guard let j = (i + 1..<salida.count).first(where: {
                lugar(salida[$0]) != lugar(salida[i - 1])
            }) else { continue }
            let movida = salida.remove(at: j)
            salida.insert(movida, at: i)
        }
        // Costura del ciclo: si la última y la primera son del mismo lugar, la
        // última se cambia por la anterior de otro lugar.
        if let ultima = salida.last, let primera = salida.first,
           lugar(ultima) == lugar(primera), salida.count > 2,
           let j = salida.indices.reversed().dropFirst().first(where: {
               lugar(salida[$0]) != lugar(primera)
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
