import XCTest

/// Fluidez de las funciones principales (Keyla, 20 Nov 2026: "test the
/// smoothness"). Mide arranque, desplazamiento (tirones / hitches) y el tiempo
/// de cada acción. Solo lectura: nunca guarda ni envía nada.
/// OJO: en el simulador los números sirven para COMPARAR versiones, no son los
/// del iPhone real.
final class SmoothnessUITests: XCTestCase {
    private var app: XCUIApplication!
    private func options(_ n: Int = 3, manual: Bool = false) -> XCTMeasureOptions {
        let o = XCTMeasureOptions(); o.iterationCount = n
        if manual { o.invocationOptions = [.manuallyStop] }
        return o
    }
    /// La medida de tirones al desplazar solo existe en un iPhone real.
    private func requireDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Los tirones al desplazar solo se miden en un iPhone real")
        #endif
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
    }
    private func launchReady() {
        app.launch()
        XCTAssertTrue(app.textFields["¿Qué quieres descubrir?"].waitForExistence(timeout: 25))
        sleep(2)   // deja terminar la primera carga de fotos
    }

    /// Primer lugar que muestra Inicio, esté donde esté el teléfono
    /// (Keyla prueba desde Lima; el simulador está en Villa Rica).
    private func firstPlaceName() -> String {
        let card = app.descendants(matching: .any).matching(identifier: "placeCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Inicio no mostró lugares")
        let parts = card.label.components(separatedBy: ", ")
        return parts.first { p in !(p.hasSuffix(" m") || p.hasSuffix(" km")) && !p.isEmpty } ?? card.label
    }
    private func cards(containing name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "placeCard")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }
    private func openFirstPlace() {
        let card = app.descendants(matching: .any).matching(identifier: "placeCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
    }

    /// Tiempo simple con reloj (para acciones que no se repiten solas).
    private func timed(_ label: String, _ block: () -> Void) {
        let t0 = Date(); block()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("SMOOTHNESS \(label): \(ms) ms")
        let a = XCTAttachment(string: "\(label): \(ms) ms"); a.lifetime = .keepAlways; add(a)
    }

    /// 1. Arranque de la app hasta que Inicio se puede usar (3 veces, en frío).
    /// La métrica de Apple fallaba a veces en el iPhone: se mide con reloj.
    func test_1_launch() {
        for i in 1...3 {
            app.terminate()
            timed("arranque \(i)") {
                app.launch()
                XCTAssertTrue(app.textFields["¿Qué quieres descubrir?"].waitForExistence(timeout: 25))
            }
        }
    }

    /// 2. Desplazar Inicio: tiempo de tirones durante el scroll.
    func test_2_scrollInicio() throws {
        try requireDevice()
        launchReady()
        let scroll = app.scrollViews.firstMatch
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options(manual: true)) {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeUp(velocity: .fast)
            stopMeasuring()
            scroll.swipeDown(velocity: .fast); scroll.swipeDown(velocity: .fast); scroll.swipeDown(velocity: .fast)
        }
    }

    /// 3. Desplazar una fila de categoría hacia el costado.
    func test_3_scrollCategoryRow() throws {
        try requireDevice()
        launchReady()
        let row = app.scrollViews.firstMatch.scrollViews.element(boundBy: 1)
        guard row.exists else { return XCTFail("No hay fila horizontal") }
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options(manual: true)) {
            row.swipeLeft(velocity: .fast)
            stopMeasuring()
            row.swipeRight(velocity: .fast); row.swipeRight(velocity: .fast)
        }
    }

    /// 4. Buscar: desde escribir hasta ver el resultado.
    func test_4_search() {
        launchReady()
        let name = firstPlaceName()
        let field = app.textFields["¿Qué quieres descubrir?"]
        measure(metrics: [XCTClockMetric()], options: options(manual: true)) {
            field.tap()
            field.typeText(name)
            XCTAssertTrue(cards(containing: name).waitForExistence(timeout: 15), "No apareció \(name)")
            stopMeasuring()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count))
        }
    }

    /// 5. Abrir un lugar hasta ver la pestaña Productos (3 veces, volviendo).
    /// measure() repetía el bloque con la ficha ya abierta: se mide con reloj.
    func test_5_openPlace() {
        for i in 1...3 {
            launchReady()
            timed("abrir lugar \(i)") {
                openFirstPlace()
                XCTAssertTrue(app.buttons["Productos"].firstMatch.waitForExistence(timeout: 15))
            }
            app.terminate()
        }
    }

    /// 6. Cambiar de pestaña en la ficha del lugar (Productos → Información → Fotos).
    func test_6_placeTabs() {
        launchReady()
        openFirstPlace()
        XCTAssertTrue(app.buttons["Productos"].firstMatch.waitForExistence(timeout: 15))
        measure(metrics: [XCTClockMetric()], options: options()) {
            app.buttons["Información"].firstMatch.tap()
            app.buttons["Fotos"].firstMatch.tap()
            app.buttons["Productos"].firstMatch.tap()
        }
    }

    /// 7. Cambiar de pestaña principal: Inicio → Comunidad → Conexiones → Yo.
    func test_7_mainTabs() {
        launchReady()
        measure(metrics: [XCTClockMetric()], options: options()) {
            for t in ["Comunidad", "Conexiones", "Yo", "Inicio"] {
                app.buttons[t].firstMatch.tap()
            }
            XCTAssertTrue(app.textFields["¿Qué quieres descubrir?"].waitForExistence(timeout: 10))
        }
    }

    /// 8. Desplazar Yo.
    func test_8_scrollYo() throws {
        try requireDevice()
        launchReady()
        app.buttons["Yo"].firstMatch.tap()
        sleep(2)
        let scroll = app.scrollViews.firstMatch
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options(manual: true)) {
            scroll.swipeUp(velocity: .fast)
            stopMeasuring()
            scroll.swipeDown(velocity: .fast); scroll.swipeDown(velocity: .fast)
        }
    }
}
