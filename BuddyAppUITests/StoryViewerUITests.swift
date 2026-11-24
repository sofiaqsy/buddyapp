import XCTest

/// Publicaciones seguidas (Keyla, 21 Nov 2026): en el visor, deslizar después
/// de la última foto pasa a la siguiente publicación. Solo lectura.
final class StoryViewerUITests: XCTestCase {
    func test_swipePastLastPhoto_opensNextPublication() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let tab = app.buttons["Comunidad"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trip de '")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25), "Comunidad sin publicaciones")
        card.tap()
        let close = app.buttons["Cerrar"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "No se abrió el visor")
        func header() -> String {
            // Autor + "destino · n de m" de la publicación que se ve.
            app.staticTexts.allElementsBoundByIndex.prefix(6).map(\.label).joined(separator: "|")
        }
        let first = header()
        var changed = false
        for _ in 0..<25 {
            app.swipeLeft()
            if !close.exists { break }   // se cerró al final de la lista
            if header() != first { changed = true; break }
        }
        let a = XCTAttachment(string: "inicio: \(first)"); a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(changed, "Deslizar no pasó a otra publicación")
    }

    /// Deslizar hacia arriba salta al siguiente trip (idea de Keyla, 21 Nov 2026).
    func test_swipeUp_jumpsToNextTrip() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let tab = app.buttons["Comunidad"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trip de '")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25))
        card.tap()
        let close = app.buttons["Cerrar"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let before = app.staticTexts.allElementsBoundByIndex.prefix(2).map(\.label)
        app.swipeUp()
        sleep(1)
        XCTAssertTrue(close.exists, "Deslizar hacia arriba no debe cerrar")
        let after = app.staticTexts.allElementsBoundByIndex.prefix(2).map(\.label)
        XCTAssertNotEqual(before, after, "Arriba no pasó al siguiente trip")
    }
}

/// El mismo comportamiento en las fotos de un lugar (Keyla, 21 Nov 2026):
/// de lado cambia de foto y se puede hacer zoom. Solo lectura.
final class PlacePhotoViewerUITests: XCTestCase {
    /// Abre las fotos del lugar `index` de Inicio.
    private func openPlacePhotos(_ app: XCUIApplication, index: Int = 0, launch: Bool = true) -> Bool {
        if launch { app.launchArguments += ["-uiTesting"]; app.launch() }
        let cards = app.descendants(matching: .any).matching(identifier: "placeCard")
        guard cards.firstMatch.waitForExistence(timeout: 25), cards.count > index else { return false }
        let card = cards.element(boundBy: index)
        guard card.isHittable else { return false }   // solo tarjetas en pantalla
        card.tap()
        let fotos = app.buttons["Fotos"].firstMatch
        guard fotos.waitForExistence(timeout: 15) else { return false }
        fotos.tap()
        let photo = app.buttons.matching(identifier: "placePhoto").firstMatch
        guard photo.waitForExistence(timeout: 10) else { return false }
        photo.tap()
        return app.buttons["Cerrar"].firstMatch.waitForExistence(timeout: 10)
    }

    func test_swipeSideways_changesPhoto() throws {
        let app = XCUIApplication()
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ de [0-9]+$")).firstMatch
        // Busca un lugar con más de una foto entre los primeros de Inicio.
        var found = false
        for i in 0..<4 {
            if i > 0 { app.terminate() }
            app.launchArguments = []
            if openPlacePhotos(app, index: i), counter.waitForExistence(timeout: 4) { found = true; break }
        }
        guard found else { throw XCTSkip("Ningún lugar cercano tiene más de una foto") }
        let before = counter.label
        app.swipeLeft()
        sleep(1)
        XCTAssertNotEqual(counter.label, before, "Deslizar de lado no cambió la foto")
    }

    func test_pinch_zooms_andHidesBars() throws {
        let app = XCUIApplication()
        guard openPlacePhotos(app) else { throw XCTSkip("El primer lugar no tiene fotos") }
        let close = app.buttons["Cerrar"].firstMatch
        XCTAssertTrue(close.isHittable)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Foto")).firstMatch.pinch(withScale: 3, velocity: 2)
        sleep(1)
        XCTAssertFalse(close.isHittable, "Con zoom las barras se ocultan")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Foto")).firstMatch.doubleTap()   // vuelve al tamaño normal
        sleep(1)
        XCTAssertTrue(close.isHittable)
    }
}

/// Abajo siempre cierra, también después de pasar a otra publicación (Keyla, 21 Nov 2026).
final class StoryViewerCloseUITests: XCTestCase {
    func test_swipeDown_closes_evenOnALaterPublication() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let tab = app.buttons["Comunidad"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trip de '")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25))
        card.tap()
        let close = app.buttons["Cerrar"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        app.swipeUp()            // ahora en la segunda publicación
        sleep(1)
        XCTAssertTrue(close.exists)
        app.swipeDown()
        sleep(1)
        XCTAssertFalse(close.exists, "Deslizar hacia abajo debe cerrar el visor")
    }
}

/// Volver de un mapa no recarga Comunidad ni cambia el orden (Keyla, 21 Nov 2026).
final class CommunityStableUITests: XCTestCase {
    func test_backFromMap_keepsOrder() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let tab = app.buttons["Comunidad"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trip de '"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 25))
        sleep(4)   // deja terminar las páginas extra
        func order() -> [String] { cards.allElementsBoundByIndex.prefix(8).map(\.label) }
        let before = order()
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'En '")).firstMatch
        guard header.waitForExistence(timeout: 5) else { throw XCTSkip("Sin fila 'En <destino>'") }
        header.tap()
        sleep(3)
        app.navigationBars.buttons.element(boundBy: 0).exists
            ? app.navigationBars.buttons.element(boundBy: 0).tap()
            : app.swipeRight()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trip de '")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "No volvió a Comunidad")
        sleep(3)
        XCTAssertEqual(order(), before, "El orden de Comunidad cambió al volver del mapa")
    }
}
