import Foundation

/// "Completa tu perfil" del negocio: barra + UN paso "Siguiente" (Keyla,
/// 20 Nov 2026). Sacada de BusinessProfileEditor sin cambiar las reglas.
enum ProfileChecklist {
    struct Item: Equatable {
        let label: String
        let done: Bool
        let target: String
    }

    static func items(about: String?, contact: String?, locations: [BusinessLocation],
                      isLinked: Bool, hasProducts: Bool) -> [Item] {
        var items = [
            Item(label: "Agrega una descripción", done: !(about ?? "").isEmpty, target: "general"),
            Item(label: "Agrega tu WhatsApp", done: !(contact ?? "").isEmpty, target: "general"),
            Item(label: "Agrega una ubicación", done: !locations.isEmpty, target: "locations"),
            Item(label: "Agrega el horario de tus ubicaciones",
                 done: !locations.isEmpty && locations.allSatisfy { $0.hours != nil }, target: "locations"),
            Item(label: "Sube fotos de tus ubicaciones",
                 done: locations.contains { !($0.photoFiles ?? []).isEmpty }, target: "locations"),
        ]
        // Productos cuenta solo cuando ya se pueden añadir (negocio aprobado).
        if isLinked { items.insert(Item(label: "Añade tus productos", done: hasProducts, target: "products"), at: 2) }
        return items
    }

    static func next(_ items: [Item]) -> Item? { items.first { !$0.done } }
}
