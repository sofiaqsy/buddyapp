import SwiftUI
import PhotosUI

// Guide lines that can be active during a drag
enum SnapGuide: Hashable {
    case verticalCenter    // x = canvasWidth  / 2
    case horizontalCenter  // y = canvasHeight / 2
}

@MainActor
class CanvasViewModel: ObservableObject {
    @Published var items: [CollageItem] = []
    @Published var selectedItemId: UUID?
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var canvasBackground: Color = .white
    /// Background strip image (nil = use solid canvasBackground color).
    @Published var backgroundImage: UIImage? = nil

    /// Active snap guides — shown in CanvasView while an item is being dragged.
    @Published var snapGuides: Set<SnapGuide> = []

    /// Updated by CanvasView so snap logic can reference the live canvas size.
    /// Tamaño real de la página publicada: full-bleed estilo IG —
    /// ancho completo de pantalla × 480. Editor y publicación son 1:1.
    static let pageSize = CGSize(width: UIScreen.main.bounds.width, height: 480)

    var canvasSize: CGSize = CanvasViewModel.pageSize


    private let snapThreshold: CGFloat = 10   // pt — how close before snapping
    private let liftService = SubjectLiftService()

    var selectedItem: CollageItem? {
        items.first { $0.id == selectedItemId }
    }

    /// Pre-sorted by zIndex so View bodies never call sorted() on every render.
    var sortedItems: [CollageItem] {
        items.sorted { $0.zIndex < $1.zIndex }
    }

    // MARK: - Adding items

    func addPhoto(_ image: UIImage, in canvasSize: CGSize) {
        guard items.count < Self.maxItems else {
            errorMessage = "Máximo \(Self.maxItems) elementos por página. Elimina alguno o crea una página nueva."
            return
        }
        // Downscale at import — keeps memory & disk usage predictable.
        let resized = image.limitedToMaxDimension(Self.maxImagePx)
        let item = CollageItem(type: .photo(resized), position: randomCenter(in: canvasSize), zIndex: nextZ())
        items.append(item)
        selectedItemId = item.id
    }

    // MARK: - Sticker toggle

    func makeSticker(id: UUID) async {
        guard let i = index(of: id), case .photo = items[i].type else { return }
        isProcessing = true
        do {
            let cutout = try await liftService.liftSubject(from: items[i].originalImage)
            // Crop away transparent margins so the frame tightly fits the subject.
            // This makes the delete button land near the real content and gestures
            // hit the subject rather than the empty original bounding box.
            let trimmed = cutout.trimmingTransparentPixels()
            items[i].type = .sticker(trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }

    // MARK: - Layouts rápidos

    enum CanvasLayout: String, CaseIterable {
        case one, twoColumns, twoRows, grid4
    }

    /// Acomoda las fotos existentes (en orden de capa) en una plantilla:
    /// 1 a pantalla completa, 2 columnas, 2 filas o cuadrícula de 4.
    /// Cada foto se recorta al aspecto de su celda y se escala para llenarla.
    /// `size` se pasa explícito porque canvasSize puede ser .zero si el VM
    /// fue recreado al cambiar de página.
    func applyLayout(_ layout: CanvasLayout, in size: CGSize) {
        guard size != .zero else { return }
        canvasSize = size
        let photoIds = items
            .sorted { $0.zIndex < $1.zIndex }
            .filter { if case .photo = $0.type { return true }; return false }
            .map(\.id)
        guard !photoIds.isEmpty else { return }

        let W = size.width, H = size.height
        let slots: [CGRect]
        switch layout {
        case .one:
            slots = [CGRect(x: 0, y: 0, width: W, height: H)]
        case .twoColumns:
            slots = [CGRect(x: 0, y: 0, width: W/2, height: H),
                     CGRect(x: W/2, y: 0, width: W/2, height: H)]
        case .twoRows:
            slots = [CGRect(x: 0, y: 0, width: W, height: H/2),
                     CGRect(x: 0, y: H/2, width: W, height: H/2)]
        case .grid4:
            slots = [CGRect(x: 0, y: 0, width: W/2, height: H/2),
                     CGRect(x: W/2, y: 0, width: W/2, height: H/2),
                     CGRect(x: 0, y: H/2, width: W/2, height: H/2),
                     CGRect(x: W/2, y: H/2, width: W/2, height: H/2)]
        }

        // Asignación por cercanía: cada celda recibe la foto que el usuario
        // dejó más cerca de ella — el layout respeta la intención, no el orden.
        var slotsLeft = Array(slots.enumerated())
        var idsLeft   = photoIds
        var assignment: [(slotIndex: Int, slot: CGRect, id: UUID)] = []

        while !slotsLeft.isEmpty && !idsLeft.isEmpty {
            var best: (slotPos: Int, idPos: Int, dist: CGFloat)? = nil
            for (sPos, s) in slotsLeft.enumerated() {
                let center = CGPoint(x: s.element.midX, y: s.element.midY)
                for (iPos, id) in idsLeft.enumerated() {
                    guard let j = index(of: id) else { continue }
                    let p = items[j].position
                    let d = hypot(p.x - center.x, p.y - center.y)
                    if best == nil || d < best!.dist {
                        best = (sPos, iPos, d)
                    }
                }
            }
            guard let b = best else { break }
            let s = slotsLeft.remove(at: b.slotPos)
            let id = idsLeft.remove(at: b.idPos)
            assignment.append((s.offset, s.element, id))
        }

        for (slotIndex, slot, id) in assignment {
            cropPhoto(id: id, aspect: slot.width / slot.height)
            guard let j = index(of: id) else { continue }
            items[j].position  = CGPoint(x: slot.midX, y: slot.midY)
            // El fondo siempre queda alineado: si la foto quedó a medio girar,
            // se completa el giro al ángulo recto más cercano (0/90/180/270).
            let snapped = (items[j].rotation.degrees / 90).rounded() * 90
            items[j].rotation  = .degrees(snapped)
            // Escala de COBERTURA medida sobre la imagen recortada real:
            // el redondeo a pixel del recorte nunca deja líneas — se escala
            // por el eje que haga falta para llenar la celda completa.
            let imgSize  = items[j].image.size
            let aspect   = imgSize.height / max(imgSize.width, 1)
            let wScale   = slot.width / 180
            let hScale   = slot.height / (180 * aspect)
            items[j].scale     = max(wScale, hScale) * 1.001
            items[j].zIndex    = Double(slotIndex)
            items[j].edgeShape = .none
        }
        selectedItemId = nil
    }

    /// Reemplaza la imagen de una foto por su versión recortada a mano.
    /// El original se conserva en `originalImage` para poder restaurar.
    func setCroppedImage(id: UUID, image: UIImage) {
        guard let i = index(of: id), case .photo = items[i].type else { return }
        items[i].type = .photo(image)
    }

    // MARK: - Crop

    /// Recorta la foto al aspecto dado (ancho/alto), centrado. nil = restaurar original.
    /// Parte de la imagen ACTUAL — si el usuario ya recortó a mano, se respeta.
    func cropPhoto(id: UUID, aspect: CGFloat?) {
        guard let i = index(of: id), case .photo = items[i].type else { return }
        guard let aspect else {
            items[i].type = .photo(items[i].originalImage)
            return
        }
        let img = items[i].image.normalized()
        let w = img.size.width, h = img.size.height
        var cropW = w, cropH = w / aspect
        if cropH > h { cropH = h; cropW = h * aspect }
        let scale = img.scale
        let rect = CGRect(x: (w - cropW) / 2 * scale,
                          y: (h - cropH) / 2 * scale,
                          width: cropW * scale,
                          height: cropH * scale)
        guard let cg = img.cgImage?.cropping(to: rect) else { return }
        items[i].type = .photo(UIImage(cgImage: cg, scale: scale, orientation: .up).standardizedFormat())
    }

    func setEdgeShape(_ shape: PhotoEdgeShape, for id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].edgeShape = shape
    }

    func setBorder(width: CGFloat, color: Color, for id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].borderWidth = width
        items[i].borderColor = color

        // Border pre-rendering only applies to stickers — photos use a SwiftUI
        // stroke overlay that costs nothing extra, so skip the CIImage pipeline.
        guard items[i].isSticker else {
            items[i].cachedBorderedImage = nil
            return
        }

        if width > 0 {
            let sourceImage = items[i].image
            let uiColor     = UIColor(color)
            Task.detached(priority: .userInitiated) {
                let bordered = sourceImage.withStickerBorder(width: width, color: uiColor)
                await MainActor.run { [weak self] in
                    guard let self, let j = self.index(of: id) else { return }
                    self.items[j].cachedBorderedImage = bordered
                }
            }
        } else {
            items[i].cachedBorderedImage = nil
        }
    }

    func revertToPhoto(id: UUID) {
        guard let i = index(of: id), case .sticker = items[i].type else { return }
        items[i].type = .photo(items[i].originalImage)
        items[i].cachedBorderedImage = nil
        items[i].borderWidth = 0
    }

    // MARK: - Snap guides

    /// Returns the snapped position and the set of guides that triggered.
    /// Call during drag `onChanged`; pass the raw (unsnapped) candidate position.
    func snapPosition(_ raw: CGPoint) -> (CGPoint, Set<SnapGuide>) {
        guard canvasSize != .zero else { return (raw, []) }
        var p = raw
        var guides = Set<SnapGuide>()

        let cx = canvasSize.width  / 2
        let cy = canvasSize.height / 2

        if abs(p.x - cx) < snapThreshold { p.x = cx; guides.insert(.verticalCenter)   }
        if abs(p.y - cy) < snapThreshold { p.y = cy; guides.insert(.horizontalCenter) }

        return (p, guides)
    }

    // MARK: - Transforms

    func updatePosition(id: UUID, by delta: CGSize) {
        guard let i = index(of: id) else { return }
        items[i].position.x += delta.width
        items[i].position.y += delta.height
    }

    static let minScale:    CGFloat = 0.35  // 63 pt minimum — always visible
    static let maxScale:    CGFloat = 6.0  // prevents SwiftUI render-budget drops
    static let maxItems:    Int     = 10   // memory guard: 10 × ~5 MB = ~50 MB peak
    static let maxImagePx:  CGFloat = 1200 // px — sharp at 6× zoom (1 080 px needed)

    func updateScale(id: UUID, multiplier: CGFloat) {
        guard let i = index(of: id) else { return }
        items[i].scale = min(Self.maxScale, max(Self.minScale, items[i].scale * multiplier))
    }

    func updateRotation(id: UUID, delta: Angle) {
        guard let i = index(of: id) else { return }
        items[i].rotation += delta
    }

    func bringToFront(id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].zIndex = nextZ()
    }

    /// Batches selection + zIndex bump into one synchronous mutation so only a
    /// single objectWillChange fires → one render pass instead of two.
    /// Las fotos que actúan como fondo (cubren gran parte del lienzo) se
    /// seleccionan pero NO suben de capa — taparían los stickers encima.
    func selectAndBringToFront(id: UUID) {
        guard let i = index(of: id) else { return }
        if !isBackgroundItem(items[i]) {
            items[i].zIndex = nextZ()   // mutate items first …
        }
        selectedItemId = id             // … then selection: Combine batches both
    }

    /// Una foto cuyo tamaño en pantalla cubre ≥ 40% del lienzo se considera
    /// fondo. Los stickers nunca son fondo.
    private func isBackgroundItem(_ item: CollageItem) -> Bool {
        guard canvasSize != .zero, case .photo = item.type else { return false }
        let imgAspect = item.image.size.height / max(item.image.size.width, 1)
        let w = 180 * item.scale
        let h = 180 * imgAspect * item.scale
        return (w * h) >= canvasSize.width * canvasSize.height * 0.4
    }

    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        if selectedItemId == id { selectedItemId = nil }
    }

    func duplicateItem(id: UUID) {
        guard items.count < Self.maxItems else {
            errorMessage = "Máximo \(Self.maxItems) elementos por página."
            return
        }
        guard let i = index(of: id) else { return }
        let original = items[i]
        let copy = CollageItem(
            type: original.type,
            position: CGPoint(x: original.position.x + 20, y: original.position.y + 20),
            scale: original.scale,
            rotation: original.rotation,
            zIndex: nextZ()
        )
        items.append(copy)
        selectedItemId = copy.id
    }

    // MARK: - Export

    func renderToImage(size: CGSize) -> UIImage? {
        let renderer = ImageRenderer(content:
            ZStack {
                canvasBackground.ignoresSafeArea()
                ForEach(items.sorted(by: { $0.zIndex < $1.zIndex })) { item in
                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180 * item.scale)
                        .rotationEffect(item.rotation)
                        .position(item.position)
                }
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 3
        return renderer.uiImage
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }

    private func nextZ() -> Double {
        (items.map(\.zIndex).max() ?? 0) + 1
    }

    private func randomCenter(in size: CGSize) -> CGPoint {
        let hPad: CGFloat = 100  // horizontal — half of 180pt item + margin
        let topPad: CGFloat = 160 // top — clears status bar + item half-height
        let botPad: CGFloat = 220 // bottom — clears toolbar
        let x = CGFloat.random(in: hPad...(max(size.width  - hPad,  hPad  + 1)))
        let y = CGFloat.random(in: topPad...(max(size.height - botPad, topPad + 1)))
        return CGPoint(x: x, y: y)
    }
}
