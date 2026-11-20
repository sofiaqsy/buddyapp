import Foundation

/// Búsqueda de Inicio (Keyla, 20 Nov 2026): sin tildes ni mayúsculas, todas
/// las palabras deben aparecer, y también encuentra lugares por sus productos.
/// Sacada de InicioView sin cambiar el comportamiento, para poder probarla.
enum PlaceSearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    static func words(_ query: String) -> [String] {
        fold(query.trimmingCharacters(in: .whitespaces)).split(separator: " ").map(String.init)
    }

    /// Primero los que coinciden por nombre o categoría; después los que solo
    /// coinciden por un producto.
    static func results<T: Equatable>(
        _ items: [T], query: String,
        text: (T) -> String, hasProductHit: (T) -> Bool
    ) -> [T] {
        let w = words(query)
        guard !w.isEmpty else { return [] }
        let byName = items.filter { item in
            let t = fold(text(item))
            return w.allSatisfy { t.contains($0) }
        }
        let byProduct = items.filter { hasProductHit($0) && !byName.contains($0) }
        return byName + byProduct
    }
}
