import SwiftUI

// MARK: – IDENTITY SHEET
// Registro progresivo en 2 o 3 pasos según el contexto:
//   Nuevo usuario  → Nombre → Teléfono → OTP  (3 pasos)
//   Ya tengo cuenta → Teléfono → OTP           (2 pasos)
// Tras la verificación llama a `onAuthenticated` y el flujo original continúa.

struct IdentitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authState: AuthState

    var contextMessage: String = "Para conectarte con un buddy necesitamos saber quién eres."
    /// `true` → salta el paso de nombre (usuario con cuenta existente).
    var skipName: Bool = false
    var onAuthenticated: () -> Void = {}

    private enum Step { case name, phone, code }
    @State private var step:     Step   = .name
    @State private var fullName: String = ""
    @State private var phone:    String = ""

    private var totalSteps: Int { skipName ? 2 : 3 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.inkMuted.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            ZStack {
                switch step {
                case .name:  nameStep
                case .phone: phoneStep
                case .code:  codeStep
                }
            }
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        .background(Color.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.light)
        .onAppear { if skipName { step = .phone } }
    }

    // MARK: – Pasos

    private var nameStep: some View {
        IdentityStepShell(
            eyebrow:    "PASO 1 DE 3",
            title:      "¿Cómo te\nllamamos?",
            subtitle:   contextMessage,
            cta:        "Continuar",
            ctaEnabled: fullName.trimmingCharacters(in: .whitespaces).count >= 2,
            content:    { IdentityNameField(fullName: $fullName) },
            onCTA:      { Haptic.medium(); withAnimation { step = .phone } }
        )
    }

    private var phoneStep: some View {
        IdentityPhoneStep(
            phone:      $phone,
            eyebrow:    skipName ? "PASO 1 DE 2" : "PASO 2 DE 3",
            onContinue: { withAnimation { step = .code } },
            onBack:     skipName ? nil : { withAnimation { step = .name } }
        )
    }

    private var codeStep: some View {
        IdentityCodeStep(
            phone:       phone,
            fullName:    fullName,
            eyebrow:     skipName ? "PASO 2 DE 2" : "PASO 3 DE 3",
            onBack:      { withAnimation { step = .phone } },
            onAuthenticated: {
                authState.didAuthenticate()
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onAuthenticated()
                }
            }
        )
    }
}

// MARK: – Shell compartido

private struct IdentityStepShell<Content: View>: View {
    let eyebrow:    String
    let title:      String
    let subtitle:   String
    let cta:        String
    let ctaEnabled: Bool
    let content:    Content
    let onCTA:      () -> Void
    let onBack:     (() -> Void)?

    init(
        eyebrow:    String,
        title:      String,
        subtitle:   String,
        cta:        String,
        ctaEnabled: Bool,
        @ViewBuilder content: () -> Content,
        onCTA:  @escaping () -> Void,
        onBack: (() -> Void)? = nil
    ) {
        self.eyebrow    = eyebrow
        self.title      = title
        self.subtitle   = subtitle
        self.cta        = cta
        self.ctaEnabled = ctaEnabled
        self.content    = content()
        self.onCTA      = onCTA
        self.onBack     = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let back = onBack {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.surface)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
                            .foregroundStyle(Color.ink)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(eyebrow)
                    .font(BT.eyebrow)
                    .tracking(1)
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Spacing.edge)

            Text(title)
                .font(BT.title1)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)

            Text(subtitle)
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.lg)

            content
                .padding(.horizontal, Spacing.edge)

            Spacer()

            Button(action: onCTA) {
                Text(cta)
                    .font(BT.footnoteBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(ctaEnabled ? Color.ink : Color.inkMuted.opacity(0.25))
                    .foregroundStyle(ctaEnabled ? Color.inkInverse : Color.inkMuted)
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(!ctaEnabled)
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, 36)
        }
    }
}

// MARK: – Campo nombre

private struct IdentityNameField: View {
    @Binding var fullName: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOMBRE")
                .font(BT.eyebrow).tracking(1)
                .foregroundStyle(Color.inkMuted)
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person")
                    .foregroundStyle(Color.inkMuted)
                    .font(.system(size: 14))
                TextField("Sarah Whitman", text: $fullName)
                    .font(BT.callout)
                    .textContentType(.givenName)
                    .autocapitalization(.words)
                    .focused($focused)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
                focused ? Color.sand : Color.border,
                lineWidth: focused ? 1.5 : 1
            ))
        }
        .onAppear { focused = true }
    }
}

// MARK: – Paso teléfono

private struct IdentityPhoneStep: View {
    @Binding var phone: String
    var eyebrow:    String
    var onContinue: () -> Void
    var onBack:     (() -> Void)?

    @FocusState private var focused: Bool
    @State private var country   = Country.defaultCountry
    @State private var isSending = false
    @State private var errorMsg:  String? = nil

    private var canContinue: Bool { phone.filter(\.isNumber).count >= 5 }

    var body: some View {
        IdentityStepShell(
            eyebrow:    eyebrow,
            title:      "Tu número.",
            subtitle:   "Te enviamos un código por SMS para verificar que eres tú.",
            cta:        isSending ? "Enviando…" : "Envíame el código",
            ctaEnabled: canContinue && !isSending,
            content: {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    PhoneCountryField(phone: $phone, country: $country, focused: $focused)

                    if let err = errorMsg {
                        Text(err).font(BT.caption1).foregroundStyle(.red)
                    }
                }
            },
            onCTA:  sendOTP,
            onBack: onBack
        )
        .onAppear { focused = true }
    }

    private func sendOTP() {
        guard canContinue else { return }
        Haptic.medium()
        isSending = true
        errorMsg  = nil
        let fullPhone = country.e164(rawInput: phone)
        Task {
            do {
                try await AuthService.shared.sendOTP(phone: fullPhone)
                await MainActor.run {
                    phone     = fullPhone
                    isSending = false
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMsg  = "No pudimos enviar el código. Verifica tu número."
                }
            }
        }
    }
}

// MARK: – Paso OTP

private struct IdentityCodeStep: View {
    let phone:    String
    let fullName: String
    var eyebrow:  String = "PASO 3 DE 3"
    var onBack:   () -> Void
    var onAuthenticated: () -> Void

    @State private var code            = ""
    @FocusState private var focused:   Bool
    @State private var isVerifying     = false
    @State private var errorMsg:       String? = nil
    @State private var resendCooldown  = 0
    @State private var cooldownTimer:  Timer?  = nil

    private var canVerify: Bool { code.count == 6 }

    var body: some View {
        IdentityStepShell(
            eyebrow:    eyebrow,
            title:      "Código de\nverificación.",
            subtitle:   "Acaba de llegarte un SMS al \(formattedPhone).",
            cta:        isVerifying ? "Verificando…" : "Verificar",
            ctaEnabled: canVerify && !isVerifying,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    OTPInput(code: $code, isFocused: $focused)

                    if let err = errorMsg {
                        Text(err).font(BT.caption1).foregroundStyle(.red)
                    }

                    Button { resendOTP() } label: {
                        if resendCooldown > 0 {
                            Text("Reenviar en \(resendCooldown)s")
                                .font(BT.callout).foregroundStyle(Color.inkMuted)
                        } else {
                            Text("Reenviar código")
                                .font(BT.callout).foregroundStyle(Color.sand).underline()
                        }
                    }
                    .disabled(resendCooldown > 0)
                }
            },
            onCTA:  verify,
            onBack: onBack
        )
        .onAppear { focused = true; startCooldown(30) }
        .onDisappear { cooldownTimer?.invalidate() }
        .onChange(of: code) { _, v in if v.count == 6 { verify() } }
    }

    private var formattedPhone: String {
        let d = phone.replacingOccurrences(of: "+51", with: "").filter(\.isNumber)
        guard d.count == 9 else { return phone }
        return "+51 \(d.prefix(3)) \(d.dropFirst(3).prefix(3)) \(d.dropFirst(6))"
    }

    private func verify() {
        guard canVerify, !isVerifying else { return }
        Haptic.medium()
        isVerifying = true
        errorMsg    = nil
        Task {
            do {
                let hasProfile = try await AuthService.shared.verifyOTP(phone: phone, code: code)
                if !hasProfile {
                    let name = fullName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        try await AuthService.shared.completeProfileMinimal(fullName: name)
                    }
                }
                await MainActor.run {
                    isVerifying = false
                    Haptic.success()
                    onAuthenticated()
                }
            } catch {
                await MainActor.run {
                    isVerifying = false
                    errorMsg = "Código incorrecto o expirado. Intenta de nuevo."
                }
            }
        }
    }

    private func resendOTP() {
        guard resendCooldown == 0 else { return }
        Haptic.light()
        Task { try? await AuthService.shared.sendOTP(phone: phone) }
        startCooldown(60)
    }

    private func startCooldown(_ seconds: Int) {
        cooldownTimer?.invalidate()
        resendCooldown = seconds
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if resendCooldown > 0 { resendCooldown -= 1 } else { t.invalidate() }
        }
    }
}
