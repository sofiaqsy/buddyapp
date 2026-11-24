import XCTest
@testable import BuddyApp

/// Visor de publicaciones seguidas (Keyla, 21 Nov 2026): al deslizar después
/// de la última foto se pasa a la siguiente publicación.
final class StoryPagesTests: XCTestCase {
    private func pages(_ counts: [Int]) -> [StoryViewerSheet.Page] {
        StoryPages.make(counts: counts) { j, p in "j\(j)p\(p)" }
    }

    func test_photosOfAllPublicationsInOrder() {
        let r = pages([2, 3])
        XCTAssertEqual(r.map(\.url), ["j0p0", "j0p1", "j1p0", "j1p1", "j1p2"])
        // La foto que sigue a la última de la primera es la primera de la segunda.
        XCTAssertEqual(r[2].j, 1); XCTAssertEqual(r[2].p, 0)
    }

    func test_publicationWithoutPhotosStillHasOnePage() {
        let r = pages([1, 0, 2])
        XCTAssertEqual(r.count, 4)
        XCTAssertEqual(r[1].j, 1)
    }

    func test_singlePublication_unchanged() {
        XCTAssertEqual(pages([3]).map(\.p), [0, 1, 2])
    }

    func test_openAtTappedPublication_firstPhoto() {
        let r = pages([2, 3, 1])
        XCTAssertEqual(r.firstIndex { $0.j == 1 }, 2)
        XCTAssertEqual(r.firstIndex { $0.j == 2 }, 5)
    }
}
