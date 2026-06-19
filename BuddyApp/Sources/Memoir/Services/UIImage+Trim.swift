import UIKit

extension UIImage {

    /// Crops the image to the bounding box of all non-transparent pixels.
    /// For sticker cutouts this removes the large transparent margins left after
    /// background removal, so the resulting frame tightly fits the subject.
    func trimmingTransparentPixels(threshold: UInt8 = 10) -> UIImage {
        guard let cgImg = cgImage else { return self }

        let w = cgImg.width
        let h = cgImg.height
        guard w > 0, h > 0 else { return self }

        // Render into an RGBA8888 context
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }

        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return self }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var minX = w, maxX = 0, minY = h, maxY = 0

        for y in 0..<h {
            for x in 0..<w {
                let alpha = px[(y * w + x) * 4 + 3]
                if alpha > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return self }

        let cropRect = CGRect(x: minX, y: minY,
                              width:  maxX - minX + 1,
                              height: maxY - minY + 1)

        guard let cropped = cgImg.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
