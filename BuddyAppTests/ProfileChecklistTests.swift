import XCTest
@testable import BuddyApp

/// "Completa tu perfil": orden de pasos y un solo "Siguiente".
final class ProfileChecklistTests: XCTestCase {
    private func loc(hours: Bool = false, photos: Bool = false) -> BusinessLocation {
        BusinessLocation(name: "Sede", lat: -10.74, lng: -75.27,
                         hours: hours ? DayHours.defaults() : nil,
                         photoFiles: photos ? ["a.jpg"] : nil)
    }
    private func items(about: String? = nil, contact: String? = nil, locs: [BusinessLocation] = [],
                       linked: Bool = false, products: Bool = false) -> [ProfileChecklist.Item] {
        ProfileChecklist.items(about: about, contact: contact, locations: locs, isLinked: linked, hasProducts: products)
    }

    func test_newPending_fiveSteps_firstIsLocation() {
        let i = items()
        XCTAssertEqual(i.count, 6)
        XCTAssertEqual(ProfileChecklist.next(i)?.label, "Agrega tu ubicación")
        XCTAssertFalse(i.contains { $0.target == "products" }, "Pendiente: Productos no cuenta")
    }

    func test_linked_addsProductsAfterContact() {
        let i = items(linked: true)
        XCTAssertEqual(i.count, 7)
        XCTAssertEqual(i[4].label, "Añade tus productos")
        XCTAssertEqual(i[4].target, "products")
    }

    func test_emptyStrings_countAsMissing() {
        XCTAssertEqual(ProfileChecklist.next(items(about: "", contact: ""))?.label, "Agrega tu ubicación")
    }

    func test_next_skipsDoneSteps() {
        XCTAssertEqual(ProfileChecklist.next(items(about: "x", contact: "999"))?.label, "Agrega tu ubicación")
        XCTAssertEqual(ProfileChecklist.next(items(about: "x", contact: "9", locs: [loc()], linked: true))?.label, "Añade tus productos")
    }

    func test_hours_needEveryLocation() {
        let i = items(locs: [loc(hours: true), loc(hours: false)])
        XCTAssertFalse(i.first { $0.label == "Agrega el horario de tus ubicaciones" }!.done)
        let j = items(locs: [loc(hours: true), loc(hours: true)])
        XCTAssertTrue(j.first { $0.label == "Agrega el horario de tus ubicaciones" }!.done)
    }

    func test_photos_anyLocationIsEnough() {
        let i = items(locs: [loc(), loc(photos: true)])
        XCTAssertTrue(i.first { $0.label == "Sube fotos de tus ubicaciones" }!.done)
    }

    func test_allDone_noNextStep() {
        let i = items(about: "x", contact: "9", locs: [loc(hours: true, photos: true)], linked: true, products: true)
        XCTAssertNil(ProfileChecklist.next(i))
        XCTAssertEqual(i.filter(\.done).count, i.count)
    }
}
