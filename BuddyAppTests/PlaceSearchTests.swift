import XCTest
@testable import BuddyApp

/// Búsqueda de Inicio: tildes, mayúsculas, todas las palabras y productos.
final class PlaceSearchTests: XCTestCase {
    struct P: Equatable { let name: String; let category: String; var product = false }
    private let places = [
        P(name: "Tienda Rosal", category: "Tienda"),
        P(name: "Café Mirador", category: "Cafetería"),
        P(name: "El Puente", category: "Restaurante", product: true),
    ]
    private func search(_ q: String) -> [String] {
        PlaceSearch.results(places, query: q, text: { "\($0.name) \($0.category)" },
                            hasProductHit: { $0.product }).map(\.name)
    }

    func test_emptyQuery_returnsNothing() {
        XCTAssertEqual(search(""), [])
        XCTAssertEqual(search("   "), [])
    }

    func test_ignoresAccentsAndCase() {
        XCTAssertEqual(search("CAFE").first, "Café Mirador")
        XCTAssertEqual(search("cafeteria").first, "Café Mirador")
    }

    func test_allWordsMustMatch() {
        XCTAssertEqual(search("tienda rosal").first, "Tienda Rosal")
        XCTAssertFalse(search("tienda mirador").contains("Tienda Rosal"))
    }

    func test_matchesCategory() {
        XCTAssertEqual(search("restaurante"), ["El Puente"])
    }

    func test_productHitsComeAfterNameHits_withoutDuplicates() {
        XCTAssertEqual(search("rosal"), ["Tienda Rosal", "El Puente"])
        XCTAssertEqual(search("puente"), ["El Puente"])
    }

    func test_words_trimsAndSplits() {
        XCTAssertEqual(PlaceSearch.words("  Café  Rosal "), ["cafe", "rosal"])
    }
}
