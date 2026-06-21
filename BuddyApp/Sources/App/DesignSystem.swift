import SwiftUI
import UIKit

// MARK: – COLOR TOKENS

extension Color {
    static let canvas        = Color(hex: "F5F0E8")
    static let surface       = Color(hex: "FFFFFF")
    static let surfaceRaised = Color(hex: "FDFAF6")
    static let ink           = Color(hex: "1C1410")
    static let inkMuted      = Color(hex: "6B5D50")   // AA ≥4.5:1 sobre canvas (antes 7C6F63 = 4.30:1)
    static let inkFaint      = Color(hex: "8A7D70")   // solo placeholders / texto grande — NO usar opacity sobre texto
    static let inkInverse    = Color(hex: "FDFAF6")
    static let teal          = Color(hex: "0F766E")
    static let tealDeep      = Color(hex: "0A3D38")
    static let sand          = Color(hex: "B08050")
    static let sandLight     = Color(hex: "E8DDD0")
    static let onlineGreen   = Color(hex: "22C55E")
    static let border        = Color(hex: "E8E0D5")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        self.init(
            red:   Double((n >> 16) & 0xFF) / 255,
            green: Double((n >>  8) & 0xFF) / 255,
            blue:  Double( n        & 0xFF) / 255
        )
    }
}

// MARK: – TYPOGRAPHY

// Escala anclada a text styles del sistema → escala con Dynamic Type (a11y)
// manteniendo el mismo tamaño por defecto que antes.
//   .largeTitle 34 · .title 28 · .title3 20 · headline/callout 16/17 · .caption 12
enum BT {
    // Display XL — 34 (heros a pantalla completa, p.ej. Confirmar trip)
    static let displayXL     = Font.system(.largeTitle).weight(.bold)

    // Hero — 28
    static let displayHero   = Font.system(.title).weight(.bold)
    static let displayLarge  = Font.system(.title).weight(.bold)
    static let title1        = Font.system(.title).weight(.bold)

    // Sección — 20
    static let displayMedium = Font.system(.title3).weight(.bold)
    static let title2        = Font.system(.title3).weight(.bold)
    static let title3        = Font.system(.title3).weight(.bold)

    // Subtítulo — 15 (peldaño intermedio real entre contenido y metadata)
    static let subhead       = Font.system(.subheadline)

    // Contenido — 16
    static let headline      = Font.system(.callout).weight(.semibold)
    static let body          = Font.system(.callout)
    static let callout       = Font.system(.callout)
    static let footnote      = Font.system(.callout)
    static let footnoteBold  = Font.system(.callout).weight(.semibold)

    // Metadata — 12
    static let caption1      = Font.system(.caption)
    static let caption2      = Font.system(.caption)
    static let eyebrow       = Font.system(.caption).weight(.semibold)
}

// MARK: – SPACING & RADIUS

enum Spacing {
    static let xs:   CGFloat =  4
    static let sm:   CGFloat =  8
    static let md:   CGFloat = 16
    static let lg:   CGFloat = 24
    static let xl:   CGFloat = 36
    static let xxl:  CGFloat = 52
    static let edge: CGFloat = 20
}

enum Radius {
    static let sm:  CGFloat = 10
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 22
    static let xl:  CGFloat = 28
}

// MARK: – SHADOWS

extension View {
    func cardShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.03), radius:  2, x: 0, y: 1)
    }
    func liftShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
            .shadow(color: .black.opacity(0.04), radius:  4, x: 0, y: 2)
    }
    func mapControlShadow() -> some View {
        self.shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
    }
}

// MARK: – LIQUID GLASS HELPERS
// Single source of truth for glass controls.
// Falls back to .regularMaterial on iOS < 26.

private struct GlassRoundedModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

private struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
        }
    }
}

// Full-width flat glass panel — bottom sheets floating over map content.
// glassEffect must be applied DIRECTLY to the view, not inside .background {}.
// Map bottom panel — clear glass with a clean hairline border at the top.
private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.clear, in: Rectangle())
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                }
        }
    }
}

// Tab bar — regular glass (opaque enough to separate from content below)
private struct GlassTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: Rectangle())
        } else {
            content
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Divider().opacity(0.4)
                }
        }
    }
}

extension View {
    /// Liquid Glass circle — circular floating buttons (back, share).
    func glassCircle() -> some View {
        modifier(GlassCircleModifier())
    }
    /// Liquid Glass rounded rect — map control buttons and pills.
    func glassRounded(_ radius: CGFloat = Radius.sm) -> some View {
        modifier(GlassRoundedModifier(cornerRadius: radius))
    }
    /// Liquid Glass full-width panel — bottom sheets over map content (clear, dissolving).
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }
    /// Liquid Glass tab bar — regular glass surface, separates content below.
    func glassTabBar() -> some View {
        modifier(GlassTabBarModifier())
    }
}

// MARK: – BUTTON STYLE
// Reemplaza a .plain dando feedback de presión nativo (atenuación + escala sutil).

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Botón custom con feedback de presión (úsalo en vez de `.plain`).
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: – HAPTICS

enum Haptic {
    static func light()   { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy()   { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
}
