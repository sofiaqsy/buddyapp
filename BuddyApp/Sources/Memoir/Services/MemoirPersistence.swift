import SwiftUI

/// Handles all file-based persistence for trip memoirs.
///
/// Directory layout per borrador:
///   Documents/BuddyApp/memoirs/{draftId}/
///     book.json
///     images/
///     thumbs/
///     backgrounds/
///
/// EL IDENTIFICADOR ES UNA CLAVE DE DISCO, NO UN JOURNEY
///
/// Se llamaba `journeyId` y eso obligaba a que existiera un journey en el
/// servidor ANTES de que el usuario pusiera una sola foto: se creaba al elegir
/// el lugar y quedaba huérfano si se arrepentía. Acá el string nunca se
/// interpreta —solo se concatena a una ruta—, así que puede ser el id de un
/// borrador local mientras se edita y el del journey una vez publicado.
///
/// `book.json` guarda NOMBRES de archivo, no rutas: por eso la carpeta se puede
/// renombrar sin reescribir nada de su contenido (ver `rename`).
final class MemoirPersistence {

    static let shared = MemoirPersistence()
    private init() {
        setupDefaultBackgroundIfNeeded()
    }

    // MARK: - Per-draft paths

    private func root(for draftId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BuddyApp/memoirs/\(draftId)")
    }

    private func imagesDir(for draftId: String) -> URL {
        let dir = root(for: draftId).appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func thumbsDir(for draftId: String) -> URL {
        let dir = root(for: draftId).appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bgDir(for draftId: String) -> URL {
        let dir = root(for: draftId).appendingPathComponent("backgrounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookFile(for draftId: String) -> URL {
        let dir = root(for: draftId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("book.json")
    }

    // MARK: - Shared global background strips (same for all trips)

    private var globalBgDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("BuddyApp/memoir_backgrounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Borrador → journey

    /// Pasa la carpeta del borrador a llamarse como el journey recién creado.
    ///
    /// SOLO se llama cuando el servidor YA confirmó la publicación. Antes de
    /// eso el borrador es lo único que existe: renombrarlo apuntando a un
    /// journey que todavía puede fallar dejaría las fotos en una carpeta que
    /// nadie va a volver a abrir.
    ///
    /// Después del renombrado, todo lo que ya existía sigue funcionando sin
    /// enterarse de que hubo un borrador: la galería borra páginas por
    /// `journeyId`, el perfil carga miniaturas por `journeyId` y reabrir el
    /// editor de una recomendación publicada encuentra sus páginas. Las tres
    /// cosas resuelven contra esta carpeta.
    ///
    /// Si el destino ya existe no se pisa: sería el libro de un journey real.
    @discardableResult
    func rename(from draftId: String, to journeyId: String) -> Bool {
        guard draftId != journeyId else { return true }
        let origen  = root(for: draftId)
        let destino = root(for: journeyId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: origen.path) else {
            print("📓 [rename] no hay borrador \(draftId) que renombrar")
            return false
        }
        if fm.fileExists(atPath: destino.path) {
            print("📓 [rename] ⚠️ \(journeyId) ya tiene libro — el borrador se queda donde está")
            return false
        }
        do {
            try fm.moveItem(at: origen, to: destino)
            print("📓 [rename] borrador \(draftId) → journey \(journeyId)")
            return true
        } catch {
            print("📓 [rename] ❌ \(error)")
            return false
        }
    }

    /// Tira el borrador entero. Solo para el caso en que la publicación falló y
    /// ya no hay nada que reintentar — nunca en el camino feliz.
    func discardDraft(_ draftId: String) {
        try? FileManager.default.removeItem(at: root(for: draftId))
    }

    // MARK: - Save / Load pages

    func save(_ pages: [CollagePage], draftId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pages) else { return }
        try? data.write(to: bookFile(for: draftId), options: .atomic)
    }

    /// Quita una página del libro por su UUID, que es como la identifica el
    /// servidor desde la migración de client_page_id.
    ///
    /// Preferir SIEMPRE esta sobre la variante por índice: el id no cambia al
    /// reordenar ni al filtrarse una página vacía al publicar.
    func removePage(id: UUID, draftId: String) {
        var pages = load(draftId: draftId)
        guard let index = pages.firstIndex(where: { $0.id == id }) else {
            print("📓 [removePage] draftId=\(draftId) id=\(id) no está en el libro (páginas=\(pages.count))")
            return
        }
        pages.remove(at: index)
        save(pages, draftId: draftId)
        print("📓 [removePage] draftId=\(draftId) id=\(id) → quedan \(pages.count) página(s)")
    }

    /// Variante por posición, SOLO para fotos anteriores a client_page_id.
    ///
    /// Traduce el índice del servidor al del libro porque no son el mismo: al
    /// publicar se filtran las páginas vacías, así que basta una página sin
    /// contenido antes para desfasarlos. Sin esta traducción se borraba la
    /// página equivocada y la siguiente publicación resucitaba la foto.
    func removePublishedPage(at publishedIndex: Int, draftId: String) {
        var pages = load(draftId: draftId)
        let published = pages.indices.filter { MemoirPersistence.isPublishable(pages[$0]) }
        guard published.indices.contains(publishedIndex) else {
            print("📓 [removePublishedPage] draftId=\(draftId) page_index=\(publishedIndex) fuera de rango (publicables=\(published.count) de \(pages.count))")
            return
        }
        let index = published[publishedIndex]
        pages.remove(at: index)
        save(pages, draftId: draftId)
        print("📓 [removePublishedPage] draftId=\(draftId) page_index=\(publishedIndex) → local[\(index)] → quedan \(pages.count) página(s)")
    }

    /// Qué páginas llegan al servidor. Vive acá para que el mapeo de índices y
    /// el filtro de publicación no puedan divergir.
    static func isPublishable(_ page: CollagePage) -> Bool {
        !page.itemSnapshots.isEmpty || page.backgroundImageFile != nil
    }

    func load(draftId: String) -> [CollagePage] {
        let url = bookFile(for: draftId)
        guard let data = try? Data(contentsOf: url) else {
            print("📖 [MemoirPersistence.load] draftId=\(draftId) — book.json NOT FOUND at \(url.path)")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pages = (try? decoder.decode([CollagePage].self, from: data)) ?? []
        print("📖 [MemoirPersistence.load] draftId=\(draftId) — loaded \(pages.count) page(s)")
        for (i, p) in pages.enumerated() {
            print("📖 [MemoirPersistence.load]   page[\(i)] id=\(p.id) itemSnapshots=\(p.itemSnapshots.count) bgFile=\(p.backgroundImageFile ?? "nil") thumbFile=\(p.thumbnailFileName ?? "nil")")
        }
        return pages
    }

    // MARK: - CanvasViewModel ↔ CollagePage

    @MainActor
    func snapshot(from vm: CanvasViewModel, existing page: CollagePage, draftId: String) -> CollagePage {
        var p = page
        p.backgroundRGBA = rgba(of: vm.canvasBackground)
        p.itemSnapshots = vm.items.map { item in
            let imgFile      = writeImage(item.image,         name: "\(item.id)_img",  draftId: draftId, force: true)
            let origFile     = writeImage(item.originalImage, name: "\(item.id)_orig", draftId: draftId, force: false)
            let borderedFile = item.cachedBorderedImage.map { writeImage($0, name: "\(item.id)_bordered", draftId: draftId, force: true) }
            return CollageItemSnapshot(
                id: item.id,
                imageFile: imgFile,
                originalImageFile: origFile,
                cachedBorderedFile: borderedFile,
                isSticker: item.isSticker,
                x: item.position.x,
                y: item.position.y,
                scale: item.scale,
                rotationRadians: item.rotation.radians,
                zIndex: item.zIndex,
                edgeShape: item.edgeShape,
                borderWidth: item.borderWidth,
                borderRGBA: rgba(of: item.borderColor)
            )
        }
        return p
    }

    @MainActor
    func restoreVM(from page: CollagePage, draftId: String) -> CanvasViewModel {
        let vm = CanvasViewModel()
        vm.canvasBackground = color(from: page.backgroundRGBA)
        vm.backgroundImage  = page.backgroundImageFile.flatMap { loadBackground($0, draftId: draftId) }
        vm.items = buildItems(from: page, draftId: draftId)
        return vm
    }

    func buildItems(from page: CollagePage, draftId: String) -> [CollageItem] {
        page.itemSnapshots.compactMap { snap in
            guard let img  = readImage(snap.imageFile,         draftId: draftId),
                  let orig = readImage(snap.originalImageFile, draftId: draftId) else { return nil }
            let bordered = snap.cachedBorderedFile.flatMap { readImage($0, draftId: draftId) }
            let type: CollageItemType = snap.isSticker ? .sticker(img) : .photo(img)
            var item = CollageItem(
                id: snap.id,
                type: type,
                originalImage: orig,
                position: CGPoint(x: snap.x, y: snap.y),
                scale: snap.scale,
                rotation: Angle(radians: snap.rotationRadians),
                zIndex: snap.zIndex
            )
            item.edgeShape           = snap.edgeShape
            item.borderWidth         = snap.borderWidth
            item.borderColor         = color(from: snap.borderRGBA)
            item.cachedBorderedImage = bordered
            return item
        }
    }

    func backgroundColor(from page: CollagePage) -> Color {
        color(from: page.backgroundRGBA)
    }

    // MARK: - Thumbnails

    @MainActor
    func generateThumbnail(vm: CanvasViewModel, canvasSize: CGSize, pageId: UUID, draftId: String) -> String? {
        guard canvasSize != .zero else { return nil }
        let bgImage = vm.backgroundImage

        let renderer = ImageRenderer(content:
            ZStack {
                if let bg = bgImage {
                    Image(uiImage: bg).resizable().scaledToFill()
                    Color.white.opacity(0.55)
                } else {
                    vm.canvasBackground
                }
                ForEach(vm.sortedItems) { item in
                    self.thumbItemView(item)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
        )
        renderer.scale = 2
        renderer.isOpaque = true   // sin canal alpha: JPEG directo, sin warnings ni memoria extra

        guard let img = renderer.uiImage else { return nil }
        guard let data = img.jpegData(compressionQuality: 0.82) else { return nil }
        let filename = "\(pageId)_thumb.jpg"
        try? data.write(to: thumbsDir(for: draftId).appendingPathComponent(filename))
        return filename
    }

    func loadThumbnail(_ filename: String, draftId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: thumbsDir(for: draftId).appendingPathComponent(filename))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Background strips

    func loadBackground(_ filename: String, draftId: String) -> UIImage? {
        // Try journey-specific first, then global
        let journeyUrl = bgDir(for: draftId).appendingPathComponent(filename)
        if let data = try? Data(contentsOf: journeyUrl) { return UIImage(data: data) }
        let globalUrl = globalBgDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: globalUrl) else { return nil }
        return UIImage(data: data)
    }

    func backgroundStripExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: globalBgDir.appendingPathComponent(filename).path)
    }

    private func setupDefaultBackgroundIfNeeded() {
        guard !backgroundStripExists("bg_strip_0.jpg") else { return }
        for ext in ["jpg", "jpeg", "png"] {
            if let url  = Bundle.main.url(forResource: "book_background", withExtension: ext),
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                sliceBackground(image, strips: 3)
                return
            }
        }
        if let image = UIImage(named: "book_background") { sliceBackground(image, strips: 3) }
    }

    @discardableResult
    func sliceBackground(_ image: UIImage, strips: Int = 3) -> [String] {
        let src = image.normalized()
        guard let cg = src.cgImage else { return [] }
        let totalW = CGFloat(cg.width)
        let totalH = CGFloat(cg.height)
        let stripW = (totalW / CGFloat(strips)).rounded(.down)
        var filenames: [String] = []
        for i in 0..<strips {
            let rect = CGRect(x: CGFloat(i) * stripW, y: 0, width: stripW, height: totalH)
            guard let cropped = cg.cropping(to: rect) else { continue }
            let strip    = UIImage(cgImage: cropped, scale: 1, orientation: .up)
            let filename = "bg_strip_\(i).jpg"
            try? strip.jpegData(compressionQuality: 0.88)?
                .write(to: globalBgDir.appendingPathComponent(filename))
            filenames.append(filename)
        }
        return filenames
    }

    // MARK: - Image helpers

    @discardableResult
    private func writeImage(_ image: UIImage, name: String, draftId: String, force: Bool = false) -> String {
        let ext      = image.hasAlpha ? "png" : "jpg"
        let filename = "\(name).\(ext)"
        let url      = imagesDir(for: draftId).appendingPathComponent(filename)
        if force || !FileManager.default.fileExists(atPath: url.path) {
            let data = image.hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.82)
            try? data?.write(to: url)
        }
        return filename
    }

    private func readImage(_ filename: String, draftId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: imagesDir(for: draftId).appendingPathComponent(filename))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Color helpers

    func rgba(of color: Color) -> [Double] {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    func color(from rgba: [Double]) -> Color {
        Color(red: rgba[safe: 0] ?? 1, green: rgba[safe: 1] ?? 1,
              blue: rgba[safe: 2] ?? 1, opacity: rgba[safe: 3] ?? 1)
    }

    // MARK: - Thumbnail item renderer

    @MainActor @ViewBuilder
    func thumbItemView(_ item: CollageItem) -> some View {
        let shape        = thumbClipShape(for: item)
        let scaledBorder = CGFloat(item.borderWidth) * CGFloat(item.scale)
        let img          = item.cachedBorderedImage ?? item.image
        // Misma geometría explícita que el editor: ancho Y alto del aspecto real
        let w = 180 * item.scale
        let h = w * img.size.height / max(img.size.width, 1)
        Image(uiImage: img)
            .resizable()
            .frame(width: w, height: h)
            .clipShape(shape)
            .overlay {
                if item.borderWidth > 0, !item.isSticker {
                    shape.stroke(item.borderColor, lineWidth: scaledBorder)
                }
            }
            .rotationEffect(item.rotation)
            .position(item.position)
    }

    private func thumbClipShape(for item: CollageItem) -> AnyShape {
        guard !item.isSticker else { return AnyShape(Rectangle()) }
        switch item.edgeShape {
        case .none:       return AnyShape(Rectangle())
        case .tornBottom: return AnyShape(TornBottomShape())
        case .tornTop:    return AnyShape(TornTopShape())
        case .tornRight:  return AnyShape(TornRightShape())
        case .tornLeft:   return AnyShape(TornLeftShape())
        case .diagonalTR: return AnyShape(DiagonalTRShape())
        case .diagonalBL: return AnyShape(DiagonalBLShape())
        }
    }
}
