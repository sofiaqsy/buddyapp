import SwiftUI

// MARK: – GalleryPhoto

/// Una foto de la galería de un lugar, ya aplanada.
///
/// El servidor devuelve `visits` —una por journey, cada una con varias fotos—
/// porque así es como están agrupadas en la base. La UI no necesita esa forma:
/// pinta una cuadrícula de fotos, no de visitas. Antes cada `body` volvía a
/// aplanar `visits`, así que el trabajo se repetía en cada render y la vista
/// tenía que saber qué es un journey, quién es su dueño y qué página ocupa cada
/// foto. Con esto la transformación ocurre UNA vez, al llegar del API.
struct GalleryPhoto: Identifiable, Equatable {
    let url: String
    let journeyId: String
    /// UUID de la página en el libro del cliente. Es por donde va el borrado.
    /// Nil en fotos publicadas antes de la migración, que solo tienen índice.
    let clientPageId: String?
    let pageIndex: Int?
    let buddyName: String?
    let isMine: Bool

    var id: String { "\(journeyId)#\(clientPageId ?? pageIndex.map(String.init) ?? url)" }
    /// Se puede borrar si el servidor dio con qué referirse a ella.
    var isDeletable: Bool { clientPageId != nil || pageIndex != nil }
}

// MARK: – Repositorio

/// Páginas ya traídas de un lugar, para no volver a pedir la primera al
/// reabrirlo. Guarda URLs y el cursor, nunca imágenes: las imágenes son cosa de
/// `ImageCache`, que ya tiene su propio límite de memoria y su copia en disco.
///
/// Sobrevive a la vista a propósito — cerrar la ficha y volver a abrirla es el
/// gesto más común del mapa, y volver a pedir la primera página en cada apertura
/// es una llamada de red por cada toque.
@MainActor
final class SpotGalleryRepository {
    static let shared = SpotGalleryRepository()
    private init() {}

    struct Snapshot {
        var photos: [GalleryPhoto]
        var nextCursor: String?
        var hasMore: Bool
        /// Se conserva porque cuenta el lugar entero, no la ventana cargada.
        var totalPhotos: Int
        /// La visita del propio buddy, si tiene una. Vive acá porque puede venir
        /// en cualquier página, y la vista necesita saberlo para ofrecer
        /// "Añadir foto" — no solo si aparece en las primeras 20.
        var myVisit: APIPlaceVisit?
    }

    private var cache: [String: Snapshot] = [:]

    func cached(_ spotId: String) -> Snapshot? { cache[spotId] }
    func store(_ snapshot: Snapshot, for spotId: String) { cache[spotId] = snapshot }
    func invalidate(_ spotId: String) { cache.removeValue(forKey: spotId) }

    /// Tras publicar o borrar una foto, cualquier lugar puede haber cambiado y
    /// no sabemos cuál: el journey no dice a qué spot pertenece desde acá.
    func invalidateAll() { cache.removeAll() }

    /// Aplana una respuesta del API a fotos, con LAS MÍAS PRIMERO dentro de la
    /// página. Un buddy entra a esta ficha a ver cómo quedó lo que aportó, y con
    /// orden estricto por recencia lo suyo se pierde entre lo de todos.
    static func flatten(_ gallery: APIPlaceGallery, travelerId: String?) -> [GalleryPhoto] {
        let expand: (APIPlaceVisit) -> [GalleryPhoto] = { visit in
            let mine = visit.travelerId != nil && visit.travelerId == travelerId
            let name = visit.traveler?.fullName
            // photoPages cuando el server la manda; si no, las URLs sueltas y
            // sin página — se ven igual, solo que no se pueden borrar.
            if let pages = visit.photoPages, !pages.isEmpty {
                return pages.map { GalleryPhoto(url: $0.url, journeyId: visit.journeyId,
                                                clientPageId: $0.clientPageId, pageIndex: $0.pageIndex,
                                                buddyName: name, isMine: mine) }
            }
            return visit.photos.map { GalleryPhoto(url: $0, journeyId: visit.journeyId,
                                                   clientPageId: nil, pageIndex: nil,
                                                   buddyName: name, isMine: mine) }
        }
        let visits = gallery.visits
        return visits.filter { $0.travelerId == travelerId }.flatMap(expand)
             + visits.filter { $0.travelerId != travelerId }.flatMap(expand)
    }
}

// MARK: – ViewModel

/// Lo que la galería de un lugar necesita para pintarse y para pedir más.
///
/// La vista solo lee `photos`, `hasMore` e `isLoadingMore`, y llama a
/// `photoAppeared(_:)`. No sabe qué es un cursor ni qué es una visita.
@MainActor
final class SpotGalleryViewModel: ObservableObject {

    @Published private(set) var photos: [GalleryPhoto] = []
    @Published private(set) var isLoadingFirstPage = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var totalPhotos = 0
    /// Mi propia recomendación de este lugar. Su journeyId es al que se le suma
    /// la foto: la recomendación existe, no hay que crear ninguna.
    @Published private(set) var myVisit: APIPlaceVisit?

    private let spotId: String
    private var nextCursor: String?
    private var loadTask: Task<Void, Never>?

    /// Cuánto de la colección hay que haber visto para pedir la siguiente página.
    /// A 0.8 la petición sale con cuatro fotos por delante (de 20), que a
    /// velocidad de scroll normal alcanza para que la página llegue antes de que
    /// el usuario toque el final. Esperar a la última foto garantiza el spinner.
    private let prefetchThreshold = 0.8

    /// Cuántas de las siguientes se descargan por adelantado. No todas: bajar 20
    /// imágenes que quizá nadie mire gasta datos del usuario y compite con las
    /// que sí están en pantalla.
    private let prefetchWindow = 6

    init(spotId: String) {
        self.spotId = spotId
    }

    deinit { loadTask?.cancel() }

    // MARK: Carga

    /// Primera página. Si el lugar ya se abrió antes, pinta lo cacheado y no
    /// toca la red.
    func loadFirstPageIfNeeded() {
        guard photos.isEmpty else { return }

        if let snap = SpotGalleryRepository.shared.cached(spotId) {
            apply(snap)
            isLoadingFirstPage = false
            print("🖼️ [SpotGallery] \(spotId.prefix(8)) desde caché — \(snap.photos.count) foto(s), hasMore=\(snap.hasMore)")
            return
        }
        fetch(cursor: nil, isFirst: true)
    }

    /// Pull-to-refresh: tira la caché y vuelve a la primera página.
    func refresh() {
        SpotGalleryRepository.shared.invalidate(spotId)
        loadTask?.cancel()
        photos = []
        nextCursor = nil
        hasMore = false
        isLoadingFirstPage = true
        fetch(cursor: nil, isFirst: true)
    }

    /// La vista avisa qué foto acaba de aparecer. Es el único gancho de
    /// paginación: cuando la que aparece está pasado el umbral, se pide más.
    func photoAppeared(_ photo: GalleryPhoto) {
        guard let idx = photos.firstIndex(of: photo) else { return }
        prefetchAhead(from: idx)
        guard hasMore, !isLoadingMore, !photos.isEmpty else { return }
        guard Double(idx + 1) / Double(photos.count) >= prefetchThreshold else { return }
        fetch(cursor: nextCursor, isFirst: false)
    }

    private func fetch(cursor: String?, isFirst: Bool) {
        guard loadTask == nil || isFirst else { return }
        if !isFirst { isLoadingMore = true }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            do {
                let page = try await APIClient.shared.fetchSpotGallery(spotId: self.spotId, cursor: cursor)
                guard !Task.isCancelled else { return }
                self.append(page)
            } catch {
                guard !Task.isCancelled else { return }
                // Sin página nueva se conserva lo que ya está en pantalla; el
                // umbral volverá a dispararse al seguir desplazando.
                print("❌ [SpotGallery] \(self.spotId.prefix(8)) cursor=\(cursor?.prefix(12) ?? "primera"): \(error)")
            }
            self.isLoadingFirstPage = false
            self.isLoadingMore = false
        }
    }

    private func append(_ page: APIPlaceGallery) {
        let incoming = SpotGalleryRepository.flatten(page, travelerId: Session.travelerId)
        // Por id y no a ciegas: dos páginas pueden solaparse si alguien publica
        // mientras se pagina, y una foto repetida rompe la identidad de la grilla.
        let known = Set(photos.map(\.id))
        photos += incoming.filter { !known.contains($0.id) }

        nextCursor  = page.nextCursor
        hasMore     = page.hasMore && page.nextCursor != nil
        totalPhotos = page.totalPhotos

        if myVisit == nil, let me = Session.travelerId {
            myVisit = page.visits.first { $0.travelerId == me && $0.isBuddy == true }
        }

        SpotGalleryRepository.shared.store(
            .init(photos: photos, nextCursor: nextCursor, hasMore: hasMore,
                  totalPhotos: totalPhotos, myVisit: myVisit),
            for: spotId)

        print("🖼️ [SpotGallery] \(spotId.prefix(8)) +\(incoming.count) → \(photos.count)/\(totalPhotos) hasMore=\(hasMore)")
    }

    private func apply(_ snap: SpotGalleryRepository.Snapshot) {
        photos      = snap.photos
        nextCursor  = snap.nextCursor
        hasMore     = snap.hasMore
        totalPhotos = snap.totalPhotos
        myVisit     = snap.myVisit
    }

    /// Descarga por adelantado las siguientes de la lista, para que entren a
    /// pantalla ya decodificadas. `ImageCache` deduplica y respeta su propio
    /// límite de memoria, así que esto no puede inflarla.
    private func prefetchAhead(from index: Int) {
        let start = index + 1
        guard start < photos.count else { return }
        let slice = photos[start..<min(start + prefetchWindow, photos.count)]
        ImagePrefetcher.prefetch(slice.map(\.url))
    }

    // MARK: Mutaciones

    /// Quita una foto de la lista sin refetchear. Borrar es un gesto puntual: si
    /// se recargara la galería entera, la paginación volvería a la primera
    /// página y el usuario perdería el sitio donde estaba.
    func removeLocally(_ photo: GalleryPhoto) {
        photos.removeAll { $0.id == photo.id }
        totalPhotos = max(0, totalPhotos - 1)
        SpotGalleryRepository.shared.store(
            .init(photos: photos, nextCursor: nextCursor, hasMore: hasMore,
                  totalPhotos: totalPhotos, myVisit: myVisit),
            for: spotId)
    }
}
