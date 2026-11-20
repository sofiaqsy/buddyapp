import XCTest
@testable import BuddyApp

/// Orden del feed (copiado de Tools/main.swift; ese archivo se mantiene).
final class FeedRankingTests: XCTestCase {
    struct F: Equatable { let id: String; let lugar: String }
    struct T: Equatable { let id: String; let google: Bool }

    private func lugar(_ n: String, _ k: Int) -> [F] { (1...k).map { F(id: "\(n)\($0)", lugar: n) } }
    private func seq(_ p: [[F]], vistas: Set<String> = []) -> [String] {
        FeedRanking.secuencia(porLugar: p, id: \.id, lugar: \.lugar, recientes: vistas).map(\.id)
    }
    private func com(_ n: Int) -> [T] { (0..<n).map { T(id: "C\($0)", google: false) } }
    private func goo(_ n: Int) -> [T] { (0..<n).map { T(id: "G\($0)", google: true) } }

    func test_secuencia_empty() {
        XCTAssertEqual(seq([]), [])
        XCTAssertEqual(seq([[]]), [])
    }

    func test_secuencia_firstThreeAreNearestDistinctPlaces() {
        let r = seq([lugar("A", 5), lugar("B", 2), lugar("C", 2), lugar("D", 1)])
        XCTAssertEqual(Array(r.prefix(3)), ["A1", "B1", "C1"])
    }

    func test_secuencia_everyPhotoOnce() {
        let input = [lugar("A", 4), lugar("B", 3), lugar("C", 1)]
        let r = seq(input)
        XCTAssertEqual(r.count, 8)
        XCTAssertEqual(Set(r), Set(input.flatMap { $0 }.map(\.id)))
    }

    func test_secuencia_noSamePlaceNeighboursWhenAvoidable() {
        let r = seq([lugar("A", 3), lugar("B", 3), lugar("C", 3)])
        for i in 1..<r.count { XCTAssertNotEqual(r[i].prefix(1), r[i - 1].prefix(1), "\(r)") }
    }

    func test_maximoDeGoogle() {
        XCTAssertEqual(FeedMix.maximoDeGoogle(comunidad: 0), Int.max)
        XCTAssertEqual(FeedMix.maximoDeGoogle(comunidad: 1), 0)
        XCTAssertEqual(FeedMix.maximoDeGoogle(comunidad: 12), 6)
    }

    func test_mezclar_cases() {
        XCTAssertEqual(FeedMix.mezclar(comunidad: com(12), google: []).map(\.id), com(12).map(\.id))
        XCTAssertEqual(FeedMix.mezclar(comunidad: [], google: goo(3)).map(\.id), ["G0", "G1", "G2"])
        XCTAssertEqual(FeedMix.mezclar(comunidad: com(12), google: goo(8)).map(\.id),
                       ["C0","C1","C2","G0","C3","C4","G1","C5","C6","G2","C7","C8","G3","C9","C10","G4","C11","G5"])
        XCTAssertEqual(FeedMix.mezclar(comunidad: com(3), google: goo(5)).map(\.id), ["C0", "C1", "C2", "G0"])
        XCTAssertEqual(FeedMix.mezclar(comunidad: com(1), google: goo(4)).map(\.id), ["C0"])
    }

    func test_descartandoRepetidos_byPlaceIdOnly() {
        let r = FeedMix.descartandoRepetidos(google: ["P1", "P2", "P2", "", "P3"], placeId: { $0 }, enComunidad: ["P1"])
        XCTAssertEqual(r, ["P2", "P3"])
    }
}
