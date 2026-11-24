import XCTest

/// Alta real de UN negocio de prueba para revisar el camino (Keyla, 21 Nov 2026:
/// "just use a name that says it is a test"; ella lo borra después).
/// No se corre con el resto de pruebas: solo a pedido.
final class BusinessCreateTestUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func test_createTestBusiness_tour() throws {
        // Crea datos reales en el sistema de negocios: NUNCA en una corrida normal.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUDDY_CREATE_TEST_BUSINESS"] == "1",
                          "Solo a pedido: crea un negocio de prueba real")
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let yo = app.buttons["Yo"].firstMatch
        XCTAssertTrue(yo.waitForExistence(timeout: 25)); yo.tap(); sleep(2)
        app.buttons["Opciones de cuenta"].firstMatch.tap(); sleep(1)
        app.buttons["Crear o vincular negocio"].firstMatch.tap(); sleep(4)
        shot(app, "01-tus-negocios")
        let otro = app.buttons["Crear otro negocio"].firstMatch
        XCTAssertTrue(otro.waitForExistence(timeout: 10)); otro.tap(); sleep(2)
        shot(app, "02-formulario-vacio")
        let fields = app.textFields
        fields.element(boundBy: 0).tap(); fields.element(boundBy: 0).typeText("PRUEBA Buddy (no usar)")
        // Ciudad ya viene con "Villa Rica"; WhatsApp de mentira.
        let wa = fields.element(boundBy: fields.count - 1)
        wa.tap(); wa.typeText("900000000")
        app.swipeUp(); sleep(1)
        let toggle = app.switches.firstMatch
        if toggle.exists { toggle.tap() }
        shot(app, "03-formulario-lleno")
        let crear = app.buttons["Crear negocio"].firstMatch
        XCTAssertTrue(crear.isEnabled, "Crear negocio no se habilitó")
        crear.tap(); sleep(8)
        shot(app, "04-despues-de-crear")
        // Lo que sigue en pantalla (Mi negocio en revisión, etc.)
        app.swipeUp(); sleep(1); shot(app, "05-sigue")
        app.swipeUp(); sleep(1); shot(app, "06-sigue")
    }
}
