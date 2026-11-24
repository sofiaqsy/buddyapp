import XCTest

/// Deslizar a la derecha vuelve atrás en toda la app (Keyla, 21 Nov 2026).
final class SwipeBackUITests: XCTestCase {
    private func openPlace(_ app: XCUIApplication) -> Bool {
        app.launchArguments += ["-uiTesting"]
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "placeCard").firstMatch
        guard card.waitForExistence(timeout: 25) else { return false }
        card.tap()
        return app.buttons["Productos"].firstMatch.waitForExistence(timeout: 15)
    }
    private func backOnInicio(_ app: XCUIApplication) -> Bool {
        app.textFields["¿Qué quieres descubrir?"].waitForExistence(timeout: 5) && !app.buttons["Productos"].firstMatch.exists
    }

    func test_swipeFromLeftEdge_onMap_goesBack() {
        let app = XCUIApplication()
        XCTAssertTrue(openPlace(app))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75)))
        XCTAssertTrue(backOnInicio(app), "Deslizar desde el borde no volvió")
    }

    func test_swipeRight_onInfoPanel_goesBack() {
        let app = XCUIApplication()
        XCTAssertTrue(openPlace(app))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.72))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.72)))
        XCTAssertTrue(backOnInicio(app), "Deslizar en el panel de información no volvió")
    }
}
