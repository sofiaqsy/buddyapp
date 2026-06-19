import UIKit

extension UIImage {

    /// Downscales the image so its longest side ≤ `maxDimension` points.
    /// Returns `self` unchanged if already within the limit.
    ///
    /// Why 1200 px as the default?
    ///   • Canvas items display at 180 pt. At the maximum allowed scale (6×)
    ///     that is 1 080 px — so 1 200 px gives a 1.1× safety margin.
    ///   • A typical 12 MP camera frame is ~4 032 px wide (≈ 46 MB RGBA).
    ///     Downscaling to 1 200 px reduces uncompressed size by ~11×.
    func limitedToMaxDimension(_ maxDimension: CGFloat = 1200) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }

        let ratio   = maxDimension / longest
        let newSize = CGSize(width:  (size.width  * ratio).rounded(),
                             height: (size.height * ratio).rounded())

        // Render at scale 1 — the pixel dimensions are already final.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha

        return UIGraphicsImageRenderer(size: newSize, format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    var hasAlpha: Bool {
        guard let info = cgImage?.alphaInfo else { return false }
        return info != .none && info != .noneSkipFirst && info != .noneSkipLast
    }

    /// Re-dibuja en formato de pixel estándar (sRGB/RGBA8).
    /// `cgImage.cropping` conserva el formato fuente (HEIC / wide-color),
    /// que el encoder JPEG rechaza con kCMPhotoError_UnsupportedPixelFormat.
    func standardizedFormat() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale  = scale
        fmt.opaque = !hasAlpha
        fmt.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: fmt)
            .image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Returns the image re-drawn at .up orientation.
    /// Required before `cgImage.cropping(to:)`, which ignores EXIF orientation.
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale  = scale
        fmt.opaque = !hasAlpha
        return UIGraphicsImageRenderer(size: size, format: fmt)
            .image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
