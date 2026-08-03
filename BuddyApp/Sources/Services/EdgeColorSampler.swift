import SwiftUI
import UIKit
import CoreImage

/// Color promedio del BORDE INFERIOR de una foto — el que toca el degradado de
/// la card de exploración.
///
/// Es el borde y no la foto entera a propósito: el promedio global de una foto
/// de hotel devuelve el verde del ventanal o la madera del cabecero, colores que
/// no están en la franja donde el degradado apoya. Muestrear solo lo que se ve
/// ahí es lo que hace que la transición se sienta continua y no teñida.
@MainActor
enum EdgeColorSampler {

    /// Cacheado por URL: el carrusel re-renderiza estas cards en cada frame del
    /// drag, y recalcular ahí convertiría un cálculo de 1ms en jank sostenido.
    private static var cache: [String: Color] = [:]

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    static func cached(_ urlString: String?) -> Color? {
        guard let urlString else { return nil }
        return cache[urlString]
    }

    /// Devuelve el color ya corregido para usarse de fondo. El trabajo pesado va
    /// en una tarea detached; solo el cacheo vuelve al main.
    static func sample(_ image: UIImage, for urlString: String?) async -> Color? {
        guard let urlString else { return nil }
        if let hit = cache[urlString] { return hit }

        let rgb = await Task.detached(priority: .utility) { averageBottomEdge(of: image) }.value
        guard let rgb else { return nil }

        let color = temper(rgb)
        cache[urlString] = color
        return color
    }

    // MARK: – Muestreo

    private nonisolated static func averageBottomEdge(of image: UIImage) -> UIColor? {
        // Normalizar primero: una foto con orientación EXIF tiene el cgImage
        // rotado respecto de lo que se ve en pantalla, y se terminaría
        // muestreando un lateral en vez del pie.
        let upright: UIImage
        if image.imageOrientation == .up {
            upright = image
        } else {
            upright = UIGraphicsImageRenderer(size: image.size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        guard let cg = upright.cgImage else { return nil }

        // En coordenadas de CGImage el origen es arriba-izquierda, así que el
        // pie de la foto es el último 15% de filas.
        let stripHeight = max(1, Int(Double(cg.height) * 0.15))
        let strip = CGRect(x: 0, y: cg.height - stripHeight, width: cg.width, height: stripHeight)
        guard let cropped = cg.cropping(to: strip) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return UIColor(
            red:   CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue:  CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    // MARK: – Corrección

    /// El promedio crudo sirve para pintar, no para leer encima. Una foto
    /// saturada devuelve un color que compite con el nombre del lugar, y una
    /// oscura devuelve uno sobre el que el texto en ink desaparece. Se le baja
    /// la saturación y se le sube el piso de luminosidad: queda un tinte, que es
    /// lo que hace falta para que la transición no se sienta gris.
    private static func temper(_ color: UIColor) -> Color {
        var h: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &sat, brightness: &bri, alpha: &a) else { return .canvas }
        return Color(UIColor(
            hue: h,
            saturation: min(sat, 0.22),
            brightness: max(bri, 0.88),
            alpha: 1
        ))
    }
}
