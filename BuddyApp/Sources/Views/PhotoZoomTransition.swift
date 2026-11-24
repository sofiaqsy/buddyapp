import SwiftUI

// Transición de foto "como Facebook" (Keyla, 21 Nov 2026): la foto crece
// desde su miniatura y, al cerrar (botón o deslizar hacia abajo siguiendo el
// dedo), vuelve encogiéndose a su lugar mientras el fondo negro se desvanece.
// En iOS 18+ es la transición nativa de Apple (.zoom), que ya trae el gesto
// interactivo, el regreso a la miniatura y respeta Reducir movimiento.
// En iOS 17 no hay transición nativa: el visor usa su propio arrastre
// (la foto sigue al dedo, se achica y el fondo se aclara) y un cierre suave.
extension View {
    /// En la miniatura que abre el visor.
    @ViewBuilder
    func photoZoomSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// En el visor (dentro del fullScreenCover).
    @ViewBuilder
    func photoZoomDestination<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// true cuando el sistema maneja abrir/cerrar con zoom (iOS 18+ y con miniatura).
enum PhotoZoom {
    static var systemAvailable: Bool {
        if #available(iOS 18.0, *) { return true } else { return false }
    }
}

/// Física del arrastre para cerrar (iOS 17, o sin miniatura de origen).
/// Probada en PhotoDismissPhysicsTests.
enum PhotoDismissPhysics {
    static let distance: CGFloat = 130        // pt hacia abajo para cerrar
    static let velocity: CGFloat = 1000       // pt/s hacia abajo para cerrar
    static let minScale: CGFloat = 0.75

    /// Escala de la foto mientras se arrastra hacia abajo.
    static func scale(forDrag dy: CGFloat) -> CGFloat { max(minScale, 1 - max(dy, 0) / 1200) }
    /// Opacidad del fondo negro mientras se arrastra.
    static func backdrop(forDrag dy: CGFloat) -> Double { Double(max(0, 1 - abs(dy) / 450)) }
    /// ¿Se cierra al soltar? Por distancia o por un deslizar rápido.
    static func shouldDismiss(dy: CGFloat, predictedDy: CGFloat) -> Bool {
        dy > distance || (dy > 30 && (predictedDy - dy) * 4 > velocity)
    }
}

/// Fuente de zoom solo si hay namespace (las celdas se usan también sin visor).
struct OptionalZoomSource<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.photoZoomSource(id: id, in: namespace) } else { content }
    }
}
