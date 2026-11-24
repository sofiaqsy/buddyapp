import XCTest

/// Recorrido del alta de negocio para revisión UX (Keyla, 21 Nov 2026).
/// Solo mira y saca capturas: NUNCA toca "Crear negocio" (crearía datos en el
/// sistema de negocios, que no es nuestro).
final class BusinessFlowTourUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func test_tour() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let yo = app.buttons["Yo"].firstMatch
        XCTAssertTrue(yo.waitForExistence(timeout: 25)); yo.tap(); sleep(3)
        shot(app, "1-yo")
        let menu = app.buttons["Opciones de cuenta"].firstMatch
        guard menu.waitForExistence(timeout: 10) else { shot(app, "x-no-menu"); return }
        menu.tap(); sleep(1); shot(app, "2-menu")
        let cambiar = app.buttons["Cambiar de cuenta"].firstMatch
        if cambiar.waitForExistence(timeout: 3) { cambiar.tap(); sleep(2); shot(app, "s-switcher")
            let personal = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'viajero' OR label CONTAINS[c] 'personal'")).firstMatch
            if personal.exists { personal.tap(); sleep(4) } else { return }
            let yo = app.buttons["Yo"].firstMatch; if yo.waitForExistence(timeout: 10) { yo.tap(); sleep(3) }
            for _ in 0..<2 { app.swipeUp(); sleep(1) }
            let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tienes un negocio'")).firstMatch
            guard entry.waitForExistence(timeout: 5) else { shot(app, "x-sin-entrada"); return }
            shot(app, "r-entrada"); entry.tap(); sleep(5); shot(app, "b-paso1")
            let noFijo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'No tengo local fijo'")).firstMatch
            if noFijo.waitForExistence(timeout: 5) { noFijo.tap(); sleep(2); shot(app, "c-paso2") }
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("Mi café")
            app.buttons["Cafeterías"].firstMatch.tap(); sleep(1); shot(app, "d-paso2-lleno")
            app.buttons["Continuar"].firstMatch.tap(); sleep(2); shot(app, "e-paso3")
            return
        }
        let crear = app.buttons["Crear o vincular negocio"].firstMatch
        guard crear.waitForExistence(timeout: 5) else { return }
        crear.tap(); sleep(4); shot(app, "3-link")
        // Siguientes pantallas que se vean (sin enviar nada)
        for label in ["Crear un negocio nuevo", "Crear negocio nuevo", "Crear negocio", "Nuevo negocio"] {
            let b = app.buttons[label].firstMatch
            if b.exists && label != "Crear negocio" { b.tap(); sleep(3); shot(app, "4-register"); break }
        }
        app.swipeUp(); sleep(1); shot(app, "5-register-bottom")
    }
}

/// Capturas del nuevo alta en 3 pasos y de "Ubicaciones" como tarjetas de Inicio.
/// Nunca toca "Crear negocio".
final class NewBusinessFlowTourUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func test_tour() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let tab = app.buttons["Negocio"].firstMatch.exists ? app.buttons["Negocio"].firstMatch : app.buttons["Yo"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25)); tab.tap(); sleep(3)
        for _ in 0..<3 { app.swipeUp(); sleep(1) }
        shot(app, "a-ubicaciones")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)
        let menu = app.buttons["Opciones de cuenta"].firstMatch.exists ? app.buttons["Opciones de cuenta"].firstMatch : app.buttons["Más opciones"].firstMatch
        if menu.exists { menu.tap(); sleep(1) }
        let crear = app.buttons["Crear o vincular negocio"].firstMatch
        guard crear.waitForExistence(timeout: 5) else { shot(app, "x-sin-menu"); return }
        crear.tap(); sleep(4)
        let otro = app.buttons["Crear otro negocio"].firstMatch
        guard otro.waitForExistence(timeout: 10) else { shot(app, "x-sin-otro"); return }
        otro.tap(); sleep(5); shot(app, "b-paso1")
        let noFijo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'No tengo local fijo'")).firstMatch
        if noFijo.exists { noFijo.tap(); sleep(2); shot(app, "c-paso2") }
        app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("Mi café")
        app.buttons["Cafeterías"].firstMatch.tap(); sleep(1); shot(app, "d-paso2-lleno")
        app.buttons["Continuar"].firstMatch.tap(); sleep(2); shot(app, "e-paso3")
    }
}

final class LocationPlusTourUITests: XCTestCase {
    func test_plusOpensMap() {
        let app = XCUIApplication(); app.launchArguments += ["-uiTesting"]; app.launch()
        let tab = app.buttons["Negocio"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 25)); tab.tap(); sleep(3)
        let plus = app.buttons["Agregar ubicación"].firstMatch
        for _ in 0..<4 where !plus.isHittable { app.swipeUp(); sleep(1) }
        guard plus.waitForExistence(timeout: 10) else { return }
        plus.tap(); sleep(6)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "lista"; a.lifetime = .keepAlways; add(a)
        let first = app.buttons.matching(NSPredicate(format: "label != 'Cancelar' AND label != 'Mi ubicación actual' AND NOT label BEGINSWITH 'Buscar'")).element(boundBy: 1)
        if first.exists { first.tap(); sleep(6) }
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "foco"; b.lifetime = .keepAlways; add(b)
    }
}
