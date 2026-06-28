import SwiftUI

/// Handles all file-based persistence for trip memoirs.
///
/// Directory layout per journey:
///   Documents/BuddyApp/memoirs/{journeyId}/
///     book.json
///     images/
///     thumbs/
///     backgrounds/
final class MemoirPersistence {

    static let shared = MemoirPersistence()
    private init() {
        setupDefaultBackgroundIfNeeded()
    }

    // MARK: - Per-journey paths

    private func root(for journeyId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BuddyApp/memoirs/\(journeyId)")
    }

    private func imagesDir(for journeyId: String) -> URL {
        let dir = root(for: journeyId).appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func thumbsDir(for journeyId: String) -> URL {
        let dir = root(for: journeyId).appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bgDir(for journeyId: String) -> URL {
        let dir = root(for: journeyId).appendingPathComponent("backgrounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookFile(for journeyId: String) -> URL {
        let dir = root(for: journeyId)
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

    // MARK: - Save / Load pages

    func save(_ pages: [CollagePage], journeyId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pages) else { return }
        try? data.write(to: bookFile(for: journeyId), options: .atomic)
    }

    func load(journeyId: String) -> [CollagePage] {
        let url = bookFile(for: journeyId)
        guard let data = try? Data(contentsOf: url) else {
            print("📖 [MemoirPersistence.load] journeyId=\(journeyId) — book.json NOT FOUND at \(url.path)")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pages = (try? decoder.decode([CollagePage].self, from: data)) ?? []
        print("📖 [MemoirPersistence.load] journeyId=\(journeyId) — loaded \(pages.count) page(s)")
        for (i, p) in pages.enumerated() {
            print("📖 [MemoirPersistence.load]   page[\(i)] id=\(p.id) itemSnapshots=\(p.itemSnapshots.count) bgFile=\(p.backgroundImageFile ?? "nil") thumbFile=\(p.thumbnailFileName ?? "nil")")
        }
        return pages
    }

    // MARK: - CanvasViewModel ↔ CollagePage

    @MainActor
    func snapshot(from vm: CanvasViewModel, existing page: CollagePage, journeyId: String) -> CollagePage {
        var p = page
        p.backgroundRGBA = rgba(of: vm.canvasBackground)
        p.itemSnapshots = vm.items.map { item in
            let imgFile      = writeImage(item.image,         name: "\(item.id)_img",  journeyId: journeyId, force: true)
            let origFile     = writeImage(item.originalImage, name: "\(item.id)_orig", journeyId: journeyId, force: false)
            let borderedFile = item.cachedBorderedImage.map { writeImage($0, name: "\(item.id)_bordered", journeyId: journeyId, force: true) }
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
    func restoreVM(from page: CollagePage, journeyId: String) -> CanvasViewModel {
        let vm = CanvasViewModel()
        vm.canvasBackground = color(from: page.backgroundRGBA)
        vm.backgroundImage  = page.backgroundImageFile.flatMap { loadBackground($0, journeyId: journeyId) }
        vm.items = buildItems(from: page, journeyId: journeyId)
        return vm
    }

    func buildItems(from page: CollagePage, journeyId: String) -> [CollageItem] {
        page.itemSnapshots.compactMap { snap in
            guard let img  = readImage(snap.imageFile,         journeyId: journeyId),
                  let orig = readImage(snap.originalImageFile, journeyId: journeyId) else { return nil }
            let bordered = snap.cachedBorderedFile.flatMap { readImage($0, journeyId: journeyId) }
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
    func generateThumbnail(vm: CanvasViewModel, canvasSize: CGSize, pageId: UUID, journeyId: String) -> String? {
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
        try? data.write(to: thumbsDir(for: journeyId).appendingPathComponent(filename))
        return filename
    }

    func loadThumbnail(_ filename: String, journeyId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: thumbsDir(for: journeyId).appendingPathComponent(filename))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Background strips

    func loadBackground(_ filename: String, journeyId: String) -> UIImage? {
        // Try journey-specific first, then global
        let journeyUrl = bgDir(for: journeyId).appendingPathComponent(filename)
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
    private func writeImage(_ image: UIImage, name: String, journeyId: String, force: Bool = false) -> String {
        let ext      = image.hasAlpha ? "png" : "jpg"
        let filename = "\(name).\(ext)"
        let url      = imagesDir(for: journeyId).appendingPathComponent(filename)
        if force || !FileManager.default.fileExists(atPath: url.path) {
            let data = image.hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.82)
            try? data?.write(to: url)
        }
        return filename
    }

    private func readImage(_ filename: String, journeyId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: imagesDir(for: journeyId).appendingPathComponent(filename))
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
