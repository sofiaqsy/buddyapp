import XCTest
@testable import BuddyApp

/// Lectura de respuestas del servidor (paso 3, 20 Nov 2026). Los ejemplos
/// están en Fixtures/: public_products.json es una respuesta real de la
/// lectura pública (URLs cambiadas a example); los demás siguen la forma que
/// arma buddy-core (BusinessChatService, FincasIntegrationService). Sin datos
/// personales.
final class DecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "Falta \(name).json")
        return try Data(contentsOf: url)
    }

    // Lectura pública de productos: se lee con JSONDecoder() simple (IdentityProvider).
    func test_publicProducts_realShape_photoFromProductAndPresentation() throws {
        let page = try JSONDecoder().decode(FincasProductPage.self, from: fixture("public_products"))
        XCTAssertEqual(page.items.count, 1)
        let p = page.items[0]
        XCTAssertEqual(p.name, "Cafe Tostado Blend")
        XCTAssertNotNil(p.photoUrl)
        XCTAssertEqual(p.coverUrl, p.photoUrl)
        let pr = try XCTUnwrap(p.presentations?.first)
        XCTAssertEqual(pr.label, "250 g")
        XCTAssertEqual(pr.price, 10)
        XCTAssertNotNil(pr.photoUrl)
        XCTAssertEqual(page.hasMore, false)
    }

    // Productos de un lugar (buddy-core): decodificador .buddy.
    func test_spotProducts_coverFallsBackToPresentationPhoto() throws {
        let page = try JSONDecoder.buddy.decode(SpotProductsPage.self, from: fixture("spot_products"))
        XCTAssertEqual(page.linked, true)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].coverUrl, "https://example.com/miel.jpg")
        XCTAssertEqual(page.items[0].presentations?.first?.label, "0.5 kg")
        XCTAssertNil(page.items[1].coverUrl, "Producto sin fotos: sin portada, sin error")
        XCTAssertNil(page.items[1].presentations)
    }

    func test_spotProducts_unlinkedPlace() throws {
        let page = try JSONDecoder.buddy.decode(SpotProductsPage.self, from: fixture("spot_products_unlinked"))
        XCTAssertEqual(page.linked, false)
        XCTAssertTrue(page.items.isEmpty)
    }

    // Chat con el negocio: los mensajes llegan en snake_case.
    func test_bizThread_messagesWithAndWithoutCard() throws {
        let t = try JSONDecoder.buddy.decode(BizThread.self, from: fixture("biz_thread"))
        XCTAssertEqual(t.side, "traveler")
        XCTAssertEqual(t.messages.map(\.senderRole), ["traveler", "business"])
        let card = try XCTUnwrap(t.messages[0].card)
        XCTAssertEqual(card.kind, "product")
        XCTAssertEqual(card.productId, "p1")
        XCTAssertNil(t.messages[1].card)
        XCTAssertEqual(t.messages[0].createdAt, "2026-11-20T15:00:00.000Z")
    }

    // La lista de conversaciones llega en camelCase.
    func test_bizConversations_optionalFieldsMayBeNull() throws {
        let list = try JSONDecoder.buddy.decode([BizConversation].self, from: fixture("biz_conversations"))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].travelerName, "Ana")
        XCTAssertNil(list[1].businessName)
        XCTAssertNil(list[1].spotId)
    }

    func test_bizCard_asDictionary_onlyIncludesSetFields() {
        let d = BizCard(kind: "place", title: "Tienda Rosal", spotId: "s1").asDictionary
        XCTAssertEqual(Set(d.keys), ["kind", "title", "spotId"])
    }

    func test_productSearch_priceMayBeNull() throws {
        let hits = try JSONDecoder.buddy.decode([ProductSearchHit].self, from: fixture("product_search"))
        XCTAssertEqual(hits.first?.products.count, 2)
        XCTAssertNil(hits.first?.products[1].price)
    }

    // Tarjetas de lugar de Inicio: snake_case y campos opcionales nulos.
    func test_placeCards_snakeCaseAndNulls() throws {
        let r = try JSONDecoder.buddy.decode(APIPlaceCardsResponse.self, from: fixture("place_cards"))
        XCTAssertEqual(r.items.count, 2)
        let a = r.items[0]
        XCTAssertEqual(a.distanceMeters, 755)
        XCTAssertEqual(a.category, "Productos locales")
        XCTAssertFalse(a.isPendingApproval)
        XCTAssertEqual(a.photoLabel, "3 fotos")
        let b = r.items[1]
        XCTAssertNil(b.distanceMeters)
        XCTAssertNil(b.category)
        XCTAssertNil(b.status)
        XCTAssertEqual(b.buddies.first?.fullName, "Luis")
        XCTAssertEqual(b.buddyLabel, "2 buddies")
        XCTAssertEqual(b.photoLabel, "1 foto")
    }

    func test_brokenJSON_throwsInsteadOfCrashing() {
        XCTAssertThrowsError(try JSONDecoder.buddy.decode(SpotProductsPage.self, from: Data("{\"items\":5}".utf8)))
    }
}
