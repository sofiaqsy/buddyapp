import SwiftUI

enum CollageItemType {
    case photo(UIImage)
    case sticker(UIImage)
}

struct CollageItem: Identifiable {
    let id: UUID
    var type: CollageItemType
    let originalImage: UIImage  // always the full photo, used to revert
    var position: CGPoint
    var scale: CGFloat = 1.0
    var rotation: Angle = .zero
    var zIndex: Double = 0

    var edgeShape: PhotoEdgeShape = .none
    var borderWidth: CGFloat = 0
    var borderColor: Color  = .white
    var cachedBorderedImage: UIImage? = nil   // pre-rendered, rebuilt when border changes

    /// Standard init — originalImage is derived from the type image.
    init(type: CollageItemType, position: CGPoint, scale: CGFloat = 1.0, rotation: Angle = .zero, zIndex: Double = 0) {
        self.id = UUID()
        self.type = type
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.zIndex = zIndex
        switch type {
        case .photo(let img), .sticker(let img): self.originalImage = img
        }
    }

    /// Restoration init — preserves the original UUID and accepts a separate originalImage
    /// (needed when loading a saved page where the current image may differ from the original).
    init(id: UUID, type: CollageItemType, originalImage: UIImage,
         position: CGPoint, scale: CGFloat = 1.0, rotation: Angle = .zero, zIndex: Double = 0) {
        self.id = id
        self.type = type
        self.originalImage = originalImage
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.zIndex = zIndex
    }

    var image: UIImage {
        switch type {
        case .photo(let img), .sticker(let img): return img
        }
    }

    var isSticker: Bool {
        if case .sticker = type { return true }
        return false
    }
}

// MARK: - Equatable
// UIImage identity comparison (===) is intentional: images are replaced, never
// mutated in place, so pointer equality ↔ content equality for our use-case.
extension CollageItem: Equatable {
    static func == (lhs: CollageItem, rhs: CollageItem) -> Bool {
        guard lhs.id == rhs.id else { return false }
        return lhs.position    == rhs.position
            && lhs.scale       == rhs.scale
            && lhs.rotation    == rhs.rotation
            && lhs.zIndex      == rhs.zIndex
            && lhs.edgeShape   == rhs.edgeShape
            && lhs.borderWidth == rhs.borderWidth
            && lhs.borderColor == rhs.borderColor
            && lhs.isSticker   == rhs.isSticker
            && lhs.image               === rhs.image
            && lhs.cachedBorderedImage === rhs.cachedBorderedImage
    }
}
