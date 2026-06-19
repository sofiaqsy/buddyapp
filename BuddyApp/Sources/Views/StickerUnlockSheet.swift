import SwiftUI

// MARK: – STICKER UNLOCK SHEET
// A quiet micro-celebration. Calm delight, not a confetti explosion.
// The place is the star — not the interface.

struct StickerUnlockSheet: View {
    let place: Place
    let onDismiss: () -> Void
    @State private var appeared = false
    @State private var stickerScale: CGFloat = 0.4

    var body: some View {
        ZStack {
            // Native material dimming — not a flat dark overlay
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { Haptic.light(); onDismiss() }

            VStack {
                Spacer()

                VStack(spacing: Spacing.lg) {
                    // Sticker
                    ZStack {
                        Circle()
                            .fill(Color.sandLight)
                            .frame(width: 96, height: 96)
                            .scaleEffect(appeared ? 1 : 0.7)
                            .animation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.05), value: appeared)

                        Text(place.stickerEmoji)
                            .font(.system(size: 50))
                            .scaleEffect(stickerScale)
                            .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.15), value: stickerScale)
                    }

                    // Text content
                    VStack(spacing: Spacing.xs) {
                        Text("Sticker conseguido")
                            .font(BT.eyebrow)
                            .tracking(2)
                            .foregroundStyle(Color.teal)

                        Text(place.name)
                            .font(BT.title2)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)

                        Text(place.description)
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // CTA
                    Button(action: { Haptic.light(); onDismiss() }) {
                        Text("Continuar explorando")
                            .font(BT.footnoteBold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.ink)
                            .foregroundStyle(Color.inkInverse)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    }
                }
                .padding(Spacing.xl)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .padding(.horizontal, Spacing.edge)
                .padding(.bottom, Spacing.lg)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 40)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appeared)
            }
        }
        .onAppear {
            appeared = true
            stickerScale = 1
        }
    }
}
