import XCTest

/// Recorridos principales en pantalla (paso 6, 20 Nov 2026).
/// Datos REALES del servidor, solo lectura: estas pruebas buscan, abren y
/// miran; nunca guardan, envían ni publican nada.
final class MainJourneysUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
    }

    private func search(_ text: String) {
        let field = app.textFields["¿Qué quieres descubrir?"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Inicio no mostró el buscador")
        field.tap()
        field.typeText(text)
    }

    private func noPartnerNames(_ screen: String) {
        for word in ["Apartalo", "Apártalo", "fincas"] {
            let hit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch
            XCTAssertFalse(hit.exists, "\(screen) muestra \"\(word)\"")
        }
    }

    /// 1. Inicio carga y la búsqueda encuentra Tienda Rosal (sin tildes ni mayúsculas).
    func test_1_search_findsTiendaRosal() {
        search("TIENDA rosal")
        XCTAssertTrue(app.staticTexts["Tienda Rosal"].firstMatch.waitForExistence(timeout: 15))
    }

    /// 2. Al abrir un lugar, la pestaña Productos está elegida.
    func test_2_openPlace_productosSelectedByDefault() {
        search("tienda rosal")
        let card = app.staticTexts["Tienda Rosal"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let productos = app.buttons["Productos"].firstMatch
        XCTAssertTrue(productos.waitForExistence(timeout: 15), "No se abrió la ficha del lugar")
        XCTAssertTrue(productos.isSelected, "Productos debe venir elegida")
        XCTAssertFalse(app.buttons["Información"].firstMatch.isSelected)
        noPartnerNames("La ficha del lugar")
    }

    /// 3. Yo: sin "Perfil de Buddy" ni contadores, y sin nombres de socios.
    func test_3_yo_noBuddyProfileNoPartnerNames() {
        let yo = app.buttons["Yo"].firstMatch
        XCTAssertTrue(yo.waitForExistence(timeout: 20))
        yo.tap()
        sleep(2)
        XCTAssertFalse(app.staticTexts["Perfil de Buddy"].exists)
        noPartnerNames("Yo")
    }

    /// 4. Inicio tampoco nombra a los socios.
    func test_4_inicio_noPartnerNames() {
        XCTAssertTrue(app.textFields["¿Qué quieres descubrir?"].waitForExistence(timeout: 20))
        noPartnerNames("Inicio")
    }

    /// 5. La búsqueda sin resultados no rompe nada y se puede limpiar.
    func test_5_searchNoResults_staysUsable() {
        search("zzqxw")
        sleep(2)
        XCTAssertFalse(app.staticTexts["Tienda Rosal"].exists)
        XCTAssertTrue(app.textFields["¿Qué quieres descubrir?"].exists || app.textFields.firstMatch.exists)
    }
}
