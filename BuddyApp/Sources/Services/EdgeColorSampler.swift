import SwiftUI
import UIKit

/// Color dominante del TERCIO INFERIOR de una foto — la franja donde apoya el
/// degradado de la card de exploración y donde vive el texto.
///
/// Dominante y no promedio: promediar cielo azul, vegetación, pared beige y una
/// figura oscura da un gris verdoso que no existe en la foto. Lo que hace que la
/// imagen se integre es un color que el ojo YA vio ahí, y eso solo lo devuelve
/// un algoritmo de agrupamiento. Acá es k-means con k=3 sobre una versión
/// diminuta de la franja, que es lo mismo que hacen las apps que resuelven esto
/// bien, en su versión más barata.
@MainActor
enum EdgeColorSampler {

    /// Cacheado por URL: el carrusel re-renderiza estas cards en cada frame del
    /// drag, y recalcular ahí convertiría un cálculo corto en jank sostenido.
    private static var cache: [String: Color] = [:]

    /// Alto de la franja muestreada. 30% y no 15%: el texto se apoya justo ahí,
    /// y una franja más fina suele caer entera sobre el borde de una cama, una
    /// pared o el piso — se pierde el color que de verdad acompaña la escena.
    private static let stripFraction = 0.30

    /// Lado del bitmap sobre el que corre el agrupamiento. 24×24 = 576 muestras:
    /// suficiente para que un color con presencia real aparezca, lo bastante
    /// chico para que k-means termine en un pestañeo.
    private static let gridSide = 24

    /// Porción mínima de la franja para considerar un color "presente". Por
    /// debajo de esto es un detalle —una planta, un reflejo— y teñir la card
    /// entera con él sería describir mal la foto.
    private static let minimumPresence = 0.15

    static func cached(_ urlString: String?) -> Color? {
        guard let urlString else { return nil }
        return cache[urlString]
    }

    /// Devuelve el color ya corregido para usarse de fondo. El trabajo pesado va
    /// en una tarea detached; solo el cacheo vuelve al main.
    static func sample(_ image: UIImage, for urlString: String?) async -> Color? {
        guard let urlString else { return nil }
        if let hit = cache[urlString] { return hit }

        let dominant = await Task.detached(priority: .utility) { dominantBottomColor(of: image) }.value
        guard let dominant else { return nil }

        let color = temper(dominant)
        cache[urlString] = color
        return color
    }

    // MARK: – Muestreo

    private struct RGB {
        var r: Double, g: Double, b: Double
        /// Luminancia percibida (Rec. 601): el verde pesa más que el azul para
        /// el ojo, y un promedio plano elegiría mal cuál de dos colores es "el
        /// más claro".
        var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }
        static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
        func distance(to o: RGB) -> Double {
            let dr = r - o.r, dg = g - o.g, db = b - o.b
            return dr * dr + dg * dg + db * db
        }
    }

    private nonisolated static func dominantBottomColor(of image: UIImage) -> UIColor? {
        guard let pixels = bottomStripPixels(of: image), !pixels.isEmpty else { return nil }

        let clusters = kMeans(pixels, k: 3, iterations: 8)
        guard !clusters.isEmpty else { return nil }

        // El más CLARO con presencia suficiente, no el más grande: el degradado
        // tiene que terminar entregándole la foto al papel, y un dominante
        // oscuro obligaría a un salto de luminosidad justo debajo del texto.
        let present = clusters.filter { $0.weight >= minimumPresence }
        let chosen = (present.isEmpty ? clusters : present).max { $0.center.luma < $1.center.luma }
        guard let center = chosen?.center else { return nil }

        return UIColor(red: center.r, green: center.g, blue: center.b, alpha: 1)
    }

    private nonisolated static func bottomStripPixels(of image: UIImage) -> [RGB]? {
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
        // pie de la foto son las últimas filas.
        let stripHeight = max(1, Int(Double(cg.height) * stripFraction))
        let strip = CGRect(x: 0, y: cg.height - stripHeight, width: cg.width, height: stripHeight)
        guard let cropped = cg.cropping(to: strip) else { return nil }

        let side = gridSide
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &buffer,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        return stride(from: 0, to: buffer.count, by: 4).map { i in
            RGB(r: Double(buffer[i]) / 255, g: Double(buffer[i + 1]) / 255, b: Double(buffer[i + 2]) / 255)
        }
    }

    // MARK: – Agrupamiento

    private struct Cluster { var center: RGB; var weight: Double }

    private nonisolated static func kMeans(_ pixels: [RGB], k: Int, iterations: Int) -> [Cluster] {
        // Semillas repartidas por luminancia y no al azar: con k tan chico, dos
        // semillas vecinas colapsan en el mismo grupo y se pierde un color real
        // de la foto. Además hace el resultado determinista — la misma foto
        // devuelve siempre el mismo tinte, que importa porque se cachea.
        let sorted = pixels.sorted { $0.luma < $1.luma }
        var centers: [RGB] = (0..<k).map { sorted[min(sorted.count - 1, sorted.count * (2 * $0 + 1) / (2 * k))] }

        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<iterations {
            var moved = false
            for (i, p) in pixels.enumerated() {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = p.distance(to: center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[i] != best { assignment[i] = best; moved = true }
            }

            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
            var counts = [Double](repeating: 0, count: k)
            for (i, p) in pixels.enumerated() {
                sums[assignment[i]] = sums[assignment[i]] + p
                counts[assignment[i]] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                centers[c] = RGB(r: sums[c].r / counts[c], g: sums[c].g / counts[c], b: sums[c].b / counts[c])
            }
            if !moved { break }
        }

        var counts = [Double](repeating: 0, count: k)
        for a in assignment { counts[a] += 1 }
        let total = Double(pixels.count)
        return (0..<k).compactMap { counts[$0] > 0 ? Cluster(center: centers[$0], weight: counts[$0] / total) : nil }
    }

    // MARK: – Corrección

    /// El objetivo no es que se note el color: es que nadie note por qué la foto
    /// y la card se llevan bien. Un tinte reconocible ("qué lindo el degradado
    /// verde") ya falló. Por eso el techo de saturación es bajo y el piso de
    /// luminosidad alto — lo que sobrevive es apenas la temperatura de la foto.
    private static func temper(_ color: UIColor) -> Color {
        var h: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &sat, brightness: &bri, alpha: &a) else { return .canvas }
        return Color(UIColor(
            hue: h,
            saturation: min(sat, 0.15),
            brightness: max(bri, 0.90),
            alpha: 1
        ))
    }
}
