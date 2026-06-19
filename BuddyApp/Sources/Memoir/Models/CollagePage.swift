import Foundation

/// Fully serialisable snapshot of one canvas page.
/// UIImages are stored as JPEG files on disk; this struct only holds filenames.
struct CollagePage: Identifiable, Codable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var backgroundRGBA: [Double] = [1, 1, 1, 1]   // white
    var itemSnapshots: [CollageItemSnapshot] = []
    var thumbnailFileName: String? = nil
    /// Incremented on every save so SwiftUI recreates PageDisplayView,
    /// clearing stale @State thumbnail cache.
    var editVersion: Int = 0
    /// Filename of the background strip image (e.g. "bg_strip_0.jpg").
    /// nil = use solid backgroundRGBA color instead.
    var backgroundImageFile: String? = nil
}

struct CollageItemSnapshot: Identifiable, Codable {
    var id: UUID
    var imageFile: String
    var originalImageFile: String
    var cachedBorderedFile: String?
    var isSticker: Bool
    var x, y, scale, rotationRadians, zIndex: Double
    var edgeShape: PhotoEdgeShape
    var borderWidth: Double
    var borderRGBA: [Double]
}
