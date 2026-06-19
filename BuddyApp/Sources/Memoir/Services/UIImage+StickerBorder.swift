import UIKit
import CoreImage

// Shared GPU context — CIContext creation takes ~50 ms and allocates a Metal
// pipeline. Reusing a single instance across all border renders is critical.
private let sharedBorderContext: CIContext = {
    CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .useSoftwareRenderer: false      // force GPU
    ])
}()

extension UIImage {

    /// Returns a new image with a solid-colour border hugging the subject's alpha edges.
    ///
    /// Uses a CIImage pipeline (GPU-accelerated, straight-alpha) so the alpha channel
    /// of VisionKit cutouts is handled correctly.
    ///
    /// The border is built by compositing 20 shifted copies of a coloured silhouette
    /// around a circle of exactly `pixelRadius` — the same geometric dilation used for
    /// photo strokes — so 7 pt on a sticker looks identical to 7 pt on a photo.
    func withStickerBorder(width: CGFloat, color: UIColor) -> UIImage {
        guard width > 0, let cgImage = cgImage else { return self }

        // Convert display-space pts → image pixels.
        // The canvas always displays items at 180 pt wide, so:
        //   pixelRadius = width_pts × (imagePixels / 180 pt)
        let displayFrameWidth: CGFloat = 180
        let pixelRadius = width * (size.width / displayFrameWidth) * max(scale, 1)

        let ciInput = CIImage(cgImage: cgImage)
        let extent  = ciInput.extent

        // ── Step 1: build a coloured silhouette (same alpha, RGB → border colour) ──
        let c = CIColor(color: color)
        let silhouette = ciInput.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),   // keep alpha as-is
            "inputBiasVector": CIVector(x: c.red, y: c.green, z: c.blue, w: 0)
        ])

        // ── Step 2: dilation — composite silhouette at 20 angular offsets ────────
        // Each copy is shifted by exactly pixelRadius, producing a border that is
        // exactly `width` display points wide — the same as a SwiftUI stroke.
        let steps = 20
        var borderLayer = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)

        for i in 0..<steps {
            let angle   = CGFloat(i) * (2 * .pi / CGFloat(steps))
            let dx      = cos(angle) * pixelRadius
            let dy      = sin(angle) * pixelRadius
            let shifted = silhouette
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: extent)
            borderLayer = shifted.composited(over: borderLayer)
        }

        // ── Step 3: composite original subject on top of the border layer ─────────
        let composite = ciInput.composited(over: borderLayer)

        guard let out = sharedBorderContext.createCGImage(composite, from: extent) else { return self }
        return UIImage(cgImage: out, scale: scale, orientation: imageOrientation)
    }
}
