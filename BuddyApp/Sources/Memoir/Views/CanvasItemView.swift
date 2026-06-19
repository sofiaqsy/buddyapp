import SwiftUI

// Equatable conformance lets SwiftUI skip body entirely when neither the item
// data nor the selection state changed. This is the primary perf guard against
// the whole canvas re-rendering on every tap / snap-guide publish.
struct CanvasItemView: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }

    let item: CollageItem
    /// Passed from CanvasView so this view re-renders ONLY when selection
    /// changes for *this specific item* — not when any other vm property
    /// (e.g. snapGuides) publishes. Removing @ObservedObject on vm stops
    /// all-item re-renders on every drag-event publish.
    let isSelected: Bool
    /// Unobserved reference — only used to dispatch actions (writes).
    /// Reading vm properties for *rendering* is intentionally avoided here.
    let vm: CanvasViewModel

    @State private var dragDelta:  CGSize = .zero
    @State private var scaleDelta: CGFloat = 1.0
    @State private var rotDelta:   Angle = .zero

    /// Pre-allocated — allocating UIImpactFeedbackGenerator on every snap
    /// event creates unnecessary heap churn at 60-120 fps during a drag.
    @State private var snapHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Live scale clamped so the view never renders below a visible threshold.
    /// Also guards against NaN/infinite values that MagnificationGesture can emit
    /// during rapid multi-touch — scaleEffect(NaN) permanently drops the layer.
    private var liveScale: CGFloat {
        let s = item.scale * scaleDelta
        guard s.isFinite, s > 0 else { return CanvasViewModel.minScale }
        return s.clamped(to: CanvasViewModel.minScale...CanvasViewModel.maxScale)
    }

    var body: some View {
        imageContent
            .position(
                x: item.position.x + dragDelta.width,
                y: item.position.y + dragDelta.height
            )
            .transaction { $0.animation = nil }
            .gesture(dragGesture)
            .simultaneousGesture(scaleGesture)
            .simultaneousGesture(rotationGesture)
            .onTapGesture {
                // Single method = one objectWillChange publish instead of two.
                vm.selectAndBringToFront(id: item.id)
            }
    }

    // MARK: - Image layer

    @ViewBuilder
    private var imageContent: some View {
        if item.isSticker {
            stickerContent
        } else {
            photoContent
        }
    }

    // ── Photo: clip shape computed ONCE and reused for clip + two overlays ──
    private var photoContent: some View {
        // Compute shape once — avoids 3× AnyShape allocations per render cycle
        let shape = edgeClipShape
        // Alto explícito: sin él, el contenedor propone su altura y scaledToFit
        // ajusta por altura en imágenes verticales — geometría impredecible
        let h = 180 * item.image.size.height / max(item.image.size.width, 1)
        return Image(uiImage: item.image)
            .resizable()
            .frame(width: 180, height: h)
            .clipShape(shape)
            .overlay {
                if item.borderWidth > 0 {
                    shape.stroke(item.borderColor, lineWidth: item.borderWidth)
                }
            }
            .overlay {
                if isSelected {
                    shape.stroke(Color.accentColor, lineWidth: 2.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                deleteButton(scale: liveScale)
            }
            .scaleEffect(liveScale)
            .transaction { $0.animation = nil }
            .rotationEffect(item.rotation + rotDelta)
            .transaction { $0.animation = nil }
    }

    // ── Sticker: border is a pre-rendered UIImage — no drawingGroup needed.
    private var stickerContent: some View {
        let displayImage = item.cachedBorderedImage ?? item.image
        let h = 180 * displayImage.size.height / max(displayImage.size.width, 1)
        return Image(uiImage: displayImage)
            .resizable()
            .frame(width: 180, height: h)
            .overlay(alignment: .topTrailing) {
                deleteButton(scale: liveScale)
            }
            .scaleEffect(liveScale)
            .transaction { $0.animation = nil }
            .rotationEffect(item.rotation + rotDelta)
            .transaction { $0.animation = nil }
    }

    // Edge clip shape — only applies to photos
    private var edgeClipShape: AnyShape {
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

    // MARK: - Delete button — fixed visual size regardless of item scale

    @ViewBuilder
    private func deleteButton(scale: CGFloat) -> some View {
        if isSelected {
            Button { vm.deleteItem(id: item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            // Cancel out the parent scaleEffect so the button stays the same visual size
            .scaleEffect(1.0 / max(scale, 0.01))
            // Dentro de la esquina, no fuera: el lienzo recorta lo que sobresale
            // y en fotos a sangre completa la X quedaba cortada
            .offset(x: -2 / max(scale, 0.01), y: 2 / max(scale, 0.01))
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let raw = CGPoint(x: item.position.x + value.translation.width,
                                  y: item.position.y + value.translation.height)

                let (snapped, guides) = vm.snapPosition(raw)

                dragDelta = CGSize(width:  snapped.x - item.position.x,
                                   height: snapped.y - item.position.y)

                if guides != vm.snapGuides {
                    if !guides.isEmpty { snapHaptic.impactOccurred() }
                    vm.snapGuides = guides
                }
            }
            .onEnded { _ in
                vm.updatePosition(id: item.id, by: dragDelta)
                vm.selectedItemId = item.id
                dragDelta = .zero
                vm.snapGuides = []
            }
    }

    private var scaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard value.isFinite, value > 0 else { return }
                let minDelta = CanvasViewModel.minScale / max(item.scale, CanvasViewModel.minScale)
                let maxDelta = CanvasViewModel.maxScale / max(item.scale, 0.01)
                scaleDelta = value.clamped(to: minDelta...maxDelta)
            }
            .onEnded { v in
                guard v.isFinite, v > 0 else { scaleDelta = 1.0; return }
                vm.updateScale(id: item.id, multiplier: v)
                scaleDelta = 1.0
            }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard value.radians.isFinite else { return }
                rotDelta = value
            }
            .onEnded { v in
                guard v.radians.isFinite else { rotDelta = .zero; return }
                vm.updateRotation(id: item.id, delta: v)
                rotDelta = .zero
            }
    }
}
