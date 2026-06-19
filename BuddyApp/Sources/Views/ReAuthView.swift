import SwiftUI

// MARK: – RE-AUTH VIEW
// Shown when the session expires for an existing user.
// Only asks for phone + OTP — skips identity/conduct steps.

struct ReAuthView: View {
    /// Called when auth succeeds. `profileComplete` = false means show identity onboarding.
    var onComplete: (_ profileComplete: Bool) -> Void

    @State private var phone = ""
    @State private var step: Step = .phone

    enum Step { case phone, code }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            switch step {
            case .phone:
                ReAuthPhoneStep(phone: $phone) {
                    withAnimation(.easeInOut(duration: 0.25)) { step = .code }
                }
            case .code:
                ReAuthCodeStep(phone: phone,
                               onBack: { withAnimation { step = .phone } },
                               onComplete: onComplete)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

// MARK: – Phone step

private struct ReAuthPhoneStep: View {
    @Binding var phone: String
    var onContinue: () -> Void

    @State private var isSending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 80)

            Text("Bienvenido")
                .font(BT.title1)
                .foregroundStyle(Color.ink)
            Text("de vuelta.")
                .font(BT.displayLarge)
                .foregroundStyle(Color.sand)
                .padding(.bottom, Spacing.lg)

            Text("Confirma tu número para continuar.")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .padding(.bottom, Spacing.xl)

            // Phone field
            HStack(spacing: Spacing.sm) {
                Text("+51")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.leading, Spacing.md)

                TextField("9XX XXX XXX", text: $phone)
                    .font(BT.callout)
                    .keyboardType(.phonePad)
                    .focused($focused)
                    .onChange(of: phone) { _, v in
                        phone = String(v.filter(\.isNumber).prefix(9))
                    }
                    .padding(.trailing, Spacing.md)
            }
            .frame(height: 52)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))

            if let error {
                Text(error)
                    .font(BT.caption1)
                    .foregroundStyle(Color.red)
                    .padding(.top, Spacing.sm)
            }

            Spacer()

            Button {
                Haptic.medium()
                sendCode()
            } label: {
                HStack {
                    if isSending { ProgressView().tint(Color.inkInverse) }
                    else { Text("Continuar").font(BT.footnoteBold) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(phone.count == 9 ? Color.ink : Color.inkMuted.opacity(0.25))
                .foregroundStyle(Color.inkInverse)
                .clipShape(Capsule())
            }
            .disabled(phone.count < 9 || isSending)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, Spacing.edge)
        .onAppear { focused = true }
    }

    private func sendCode() {
        isSending = true
        error = nil
        Task {
            do {
                try await AuthService.shared.sendOTP(phone: "+51\(phone)")
                await MainActor.run { isSending = false; onContinue() }
            } catch {
                await MainActor.run {
                    self.error = "No pudimos enviar el código. Intenta de nuevo."
                    isSending = false
                }
            }
        }
    }
}

// MARK: – Code step

private struct ReAuthCodeStep: View {
    let phone: String
    var onBack: () -> Void
    var onComplete: (_ profileComplete: Bool) -> Void

    @State private var code = ""
    @State private var isVerifying = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.surface)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
                    .foregroundStyle(Color.ink)
            }
            .buttonStyle(.plain)
            .padding(.top, 60)

            Spacer().frame(height: Spacing.xl)

            Text("Código enviado.")
                .font(BT.title1)
                .foregroundStyle(Color.ink)
            Text("revisa tu SMS.")
                .font(BT.displayLarge)
                .foregroundStyle(Color.sand)
                .padding(.bottom, Spacing.lg)

            Text("Enviamos un código a +51\(phone)")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .padding(.bottom, Spacing.xl)

            // OTP boxes using shared OTPInput
            OTPInput(code: $code, isFocused: $focused)

            if let error {
                Text(error)
                    .font(BT.caption1)
                    .foregroundStyle(Color.red)
                    .padding(.top, Spacing.sm)
            }

            Spacer()

            Button {
                Haptic.medium()
                verify()
            } label: {
                HStack {
                    if isVerifying { ProgressView().tint(Color.inkInverse) }
                    else { Text("Verificar").font(BT.footnoteBold) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(code.count == 6 ? Color.ink : Color.inkMuted.opacity(0.25))
                .foregroundStyle(Color.inkInverse)
                .clipShape(Capsule())
            }
            .disabled(code.count < 6 || isVerifying)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, Spacing.edge)
        .onAppear { focused = true }
        .onChange(of: code) { _, v in if v.count == 6 { verify() } }
    }

    private func verify() {
        guard !isVerifying else { return }
        isVerifying = true
        error = nil
        Task {
            do {
                let profileComplete = try await AuthService.shared.verifyOTP(phone: "+51\(phone)", code: code)
                await MainActor.run { onComplete(profileComplete) }
            } catch {
                await MainActor.run {
                    self.error = "Código incorrecto o expirado."
                    isVerifying = false
                }
            }
        }
    }
}
