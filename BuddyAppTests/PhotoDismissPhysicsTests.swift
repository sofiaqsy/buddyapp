import XCTest
@testable import BuddyApp

/// Cerrar una foto arrastrando hacia abajo (Keyla, 21 Nov 2026, estilo Facebook).
final class PhotoDismissPhysicsTests: XCTestCase {
    func test_scale_shrinksWithDrag_neverBelowMin() {
        XCTAssertEqual(PhotoDismissPhysics.scale(forDrag: 0), 1)
        XCTAssertLessThan(PhotoDismissPhysics.scale(forDrag: 200), 1)
        XCTAssertEqual(PhotoDismissPhysics.scale(forDrag: 5000), PhotoDismissPhysics.minScale)
        XCTAssertEqual(PhotoDismissPhysics.scale(forDrag: -100), 1, "Hacia arriba no se achica")
    }
    func test_backdrop_fadesProgressively() {
        XCTAssertEqual(PhotoDismissPhysics.backdrop(forDrag: 0), 1)
        let mid = PhotoDismissPhysics.backdrop(forDrag: 200)
        XCTAssertTrue(mid > 0 && mid < 1)
        XCTAssertEqual(PhotoDismissPhysics.backdrop(forDrag: 900), 0)
    }
    func test_dismiss_byDistance_orByFastSwipe_elseReturns() {
        XCTAssertTrue(PhotoDismissPhysics.shouldDismiss(dy: 140, predictedDy: 140), "lejos")
        XCTAssertTrue(PhotoDismissPhysics.shouldDismiss(dy: 60, predictedDy: 400), "rápido")
        XCTAssertFalse(PhotoDismissPhysics.shouldDismiss(dy: 60, predictedDy: 80), "corto y lento: vuelve")
        XCTAssertFalse(PhotoDismissPhysics.shouldDismiss(dy: 10, predictedDy: 600), "casi sin mover")
    }
}
