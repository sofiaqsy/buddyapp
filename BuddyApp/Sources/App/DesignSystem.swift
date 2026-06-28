import SwiftUI
import UIKit

// MARK: – COLOR TOKENS
// Single source of truth. All views consume ONLY these tokens — never hardcoded hex.
//
// Buddy Brown (#6E3B2D) is the primary brand color.
// It replaces the old teal/sand system entirely.
// Soft sage green (#6F9885) is the only allowed accent (availability / success).

extension Color {
    // ── Backgrounds ────────────────────────────────────────────────
    static let canvas        = Color(hex: "F8F4EE")   // App background — warm off-white
    static let surface       = Color(hex: "FFFFFF")   // Cards — pure white
    static let surfaceRaised = Color(hex: "F3EEE8")   // Secondary bg / grouped rows
    static let groupedBg     = Color(hex: "ECE4DB")   // Sections, pickers

    // ── Text ────────────────────────────────────────────────────────
    static let ink           = Color(hex: "2B1C18")   // Primary text — dark brown, never black
    static let inkMuted      = Color(hex: "6F625D")   // Secondary text
    static let inkFaint      = Color(hex: "B8AEA8")   // Placeholders / hints
    static let inkInverse    = Color(hex: "FFFFFF")   // Text on dark (CTAs)

    // ── Brand ───────────────────────────────────────────────────────
    /// Buddy Brown — primary brand. CTAs, icons, active states, links.
    static let brand         = Color(hex: "6E3B2D")
    /// Pressed / hover state.
    static let brandHover    = Color(hex: "7B4435")
    /// Dark brown — dark backgrounds, deepest text.
    static let brandDeep     = Color(hex: "2B1C18")
    /// Disabled state.
    static let brandDisabled = Color(hex: "CFC6BF")

    // Legacy aliases so existing call-sites compile without renaming.
    // teal → brand,  tealDeep → brandDeep gradient anchor,  sand → brand,  sandLight → groupedBg
    static let teal          = Color.brand
    static let tealDeep      = Color(hex: "4A2820")   // dark end of brand gradient
    static let sand          = Color.brand
    static let sandLight     = Color.groupedBg

    // ── Accent ──────────────────────────────────────────────────────
    /// Soft sage — only for: available, success, location, buddy online.
    /// Never use for CTAs.
    static let accent        = Color(hex: "6F9885")
    /// Legacy alias
    static let onlineGreen   = Color.accent

    // ── Semantic ────────────────────────────────────────────────────
    static let warningAmber  = Color(hex: "C48A3A")
    static let errorRed      = Color(hex: "B65B55")

    // ── Borders / Lines ─────────────────────────────────────────────
    static let border        = Color(hex: "E6DDD5")
    static let hairline      = Color(hex: "EFE8E2")

    // ── Tab Bar ─────────────────────────────────────────────────────
    static let tabBarBg      = Color(hex: "FBF8F4")
    static let tabBarInactive = Color(hex: "8A7D76")

    // ── Init ────────────────────────────────────────────────────────
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

enum BT {
    static let displayXL     = Font.system(.largeTitle).weight(.bold)
    static let displayHero   = Font.system(.title).weight(.bold)
    static let displayLarge  = Font.system(.title).weight(.bold)
    static let title1        = Font.system(.title).weight(.bold)
    static let displayMedium = Font.system(.title3).weight(.bold)
    static let title2        = Font.system(.title3).weight(.bold)
    static let title3        = Font.system(.title3).weight(.bold)
    static let subhead       = Font.system(.subheadline)
    static let headline      = Font.system(.callout).weight(.semibold)
    static let body          = Font.system(.callout)
    static let callout       = Font.system(.callout)
    static let footnote      = Font.system(.callout)
    static let footnoteBold  = Font.system(.callout).weight(.semibold)
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
    static let sm:  CGFloat = 14
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24
}

// MARK: – SHADOWS
// Reduced, warm — opacity 0.06, radius 10, y 4

extension View {
    func cardShadow() -> some View {
        self.shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
    func liftShadow() -> some View {
        self.shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
    }
    func mapControlShadow() -> some View {
        self.shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

// MARK: – LIQUID GLASS HELPERS

private struct GlassRoundedModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

private struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.clear, in: Rectangle())
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
                }
        }
    }
}

private struct GlassTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content
                .background(Color.tabBarBg)
                .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }
}

extension View {
    func glassCircle() -> some View { modifier(GlassCircleModifier()) }
    func glassRounded(_ radius: CGFloat = Radius.sm) -> some View { modifier(GlassRoundedModifier(cornerRadius: radius)) }
    func glassPanel() -> some View { modifier(GlassPanelModifier()) }
    func glassTabBar() -> some View { modifier(GlassTabBarModifier()) }
}

// MARK: – BUTTON STYLE

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
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

// MARK: – BRAND GRADIENTS
// Warm earth-tone gradients. Use instead of teal/blue/green gradients.

enum BuddyGradient {
    /// Primary brand gradient — dark → Buddy Brown
    static let brand      = LinearGradient(colors: [Color.tealDeep, Color.brand],    startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Earthy warm — slightly lighter warm brown
    static let earth      = LinearGradient(colors: [Color(hex: "3D2B1A"), Color(hex: "6B4226")], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Muted taupe — neutral, calm
    static let taupe      = LinearGradient(colors: [Color(hex: "4A3D35"), Color(hex: "7A6558")], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Warm amber — golden accent
    static let amber      = LinearGradient(colors: [Color(hex: "5C3E1A"), Color(hex: "8B6428")], startPoint: .topLeading, endPoint: .bottomTrailing)
}
