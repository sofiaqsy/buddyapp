import SwiftUI
import AuthenticationServices

// MARK: – ONBOARDING FLOW
// 01 Bienvenida → 02 Teléfono → 03 Código → 04 Identidad → 05 Conducta

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}

    @State private var step: OnboardingStep = .welcome
    @State private var phone       = ""
    @State private var fullName    = ""
    @State private var docType     = "dni"
    @State private var docNumber   = ""
    @State private var birthDate   = ""
    @State private var nationality = "Perú"

    enum OnboardingStep {
        case welcome, phone, code, identity, conduct, needsProfileCompletion
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep(
                    onContinue:        { advance(to: .phone) },
                    onSocialComplete:  { onComplete(); dismiss() },
                    onSocialNeedsName: { advance(to: .needsProfileCompletion) }
                )
            case .phone:
                PhoneStep(phone: $phone, onBack: { advance(to: .welcome) }) {
                    advance(to: .code)
                }
            case .code:
                CodeStep(phone: phone, onBack: { advance(to: .phone) }, onProfileExists: {
                    onComplete()
                    dismiss()
                }) {
                    advance(to: .identity)
                }
            case .identity:
                IdentityStep(
                    fullName:    $fullName,
                    docType:     $docType,
                    docNumber:   $docNumber,
                    birthDate:   $birthDate,
                    nationality: $nationality,
                    onBack: { advance(to: .code) }
                ) { advance(to: .conduct) }
            case .conduct:
                ConductStep(onBack: { advance(to: .identity) }) {
                    Task {
                        try? await AuthService.shared.completeProfile(
                            fullName:    fullName,
                            docType:     docType,
                            docNumber:   docNumber,
                            birthDate:   birthDate,
                            nationality: nationality
                        )
                        await MainActor.run { onComplete(); dismiss() }
                    }
                }
            case .needsProfileCompletion:
                SocialNameStep(onBack: { advance(to: .welcome) }) { name in
                    Task {
                        try? await AuthService.shared.completeProfileForSocialLogin(fullName: name)
                        await MainActor.run { onComplete(); dismiss() }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private func advance(to next: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}

// MARK: – 01 BIENVENIDA

struct WelcomeStep: View {
    var onContinue:        () -> Void
    var onSocialComplete:  (() -> Void)? = nil
    var onSocialNeedsName: (() -> Void)? = nil

    @State private var loading:      Bool   = false
    @State private var socialLoading: Bool  = false
    @State private var socialError:  String?

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Conecta con")
                            .font(BT.title1)
                            .foregroundStyle(Color.ink)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("un")
                            .font(BT.title1)
                            .foregroundStyle(Color.ink)
                        Text("buddy.")
                            .font(BT.displayLarge)
                            .foregroundStyle(Color.sand)
                    }
                }
                .padding(.horizontal, Spacing.edge)

                Text("Descárgate de dudas y empieza a\ndisfrutar tu trip.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

                Spacer()

                VStack(spacing: Spacing.sm) {
                    // ── Sign in with Apple ───────────────────────────────
                    SignInWithAppleButton(.signIn, onRequest: { request in
                        request.requestedScopes = [.fullName, .email]
                    }, onCompletion: { result in
                        switch result {
                        case .failure(let err):
                            let nsErr = err as NSError
                            if nsErr.code != ASAuthorizationError.canceled.rawValue {
                                socialError = "Error con Apple: \(err.localizedDescription)"
                            }
                        case .success:
                            handleSocialSignIn(provider: AppleProvider())
                        }
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(Capsule())
                    .padding(.horizontal, Spacing.edge)
                    .opacity(socialLoading ? 0.5 : 1)
                    .disabled(socialLoading || loading)

                    // ── Sign in with Google ───────────────────────────────
                    Button(action: { handleSocialSignIn(provider: GoogleProvider()) }) {
                        ZStack {
                            if socialLoading {
                                ProgressView().progressViewStyle(.circular).tint(Color.ink)
                            } else {
                                HStack(spacing: 10) {
                                    Image("google_logo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 20, height: 20)
                                    Text("Continuar con Google")
                                        .font(BT.footnoteBold)
                                        .foregroundStyle(Color.ink)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, Spacing.edge)
                    .opacity(socialLoading ? 0.7 : 1)
                    .disabled(socialLoading || loading)

                    if let err = socialError {
                        Text(err)
                            .font(BT.caption1)
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.edge)
                    }

                    // ── Separador ────────────────────────────────────────
                    HStack {
                        Rectangle().fill(Color.inkMuted.opacity(0.2)).frame(height: 1)
                        Text("o continúa con teléfono")
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize()
                        Rectangle().fill(Color.inkMuted.opacity(0.2)).frame(height: 1)
                    }
                    .padding(.horizontal, Spacing.edge)

                    // ── Botón teléfono ────────────────────────────────────
                    Button(action: {
                        guard !loading else { return }
                        Haptic.medium()
                        loading = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onContinue() }
                    }) {
                        ZStack {
                            if loading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(Color.inkInverse)
                            } else {
                                Text("Continuar con teléfono")
                                    .font(BT.footnoteBold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Color.ink)
                        .foregroundStyle(Color.inkInverse)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, Spacing.edge)

                    Text("Al pasar confirmas que tienes **18+ años** y aceptas nuestros\n**términos, privacidad** y **código de conducta**")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.bottom, Spacing.lg)
                }
            }
        }
    }

    private func handleSocialSignIn(provider: IdentityProvider) {
        socialLoading = true
        socialError   = nil
        Task {
            do {
                let result      = try await AuthService.shared.signIn(with: provider)
                let destination = AuthCoordinator.shared.handle(result)
                await MainActor.run {
                    socialLoading = false
                    switch destination {
                    case .home:                  onSocialComplete?()
                    case .needsProfileCompletion: onSocialNeedsName?()
                    }
                }
            } catch {
                await MainActor.run {
                    socialLoading = false
                    let nsErr = error as NSError
                    let cancelCodes = [ASAuthorizationError.canceled.rawValue, 1]
                    if !cancelCodes.contains(nsErr.code) {
                        socialError = "No se pudo iniciar sesión."
                    }
                }
            }
        }
    }
}

// MARK: – 01b NOMBRE (social login sin nombre)

struct SocialNameStep: View {
    var onBack:     () -> Void
    var onComplete: (String) -> Void

    @State private var name    = ""
    @State private var loading = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Back button
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
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("¿Cómo te llamamos?")
                        .font(BT.title2)
                        .foregroundStyle(Color.ink)

                    Text("Apple no compartió tu nombre. Dinos cómo quieres que te llamen los buddies.")
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)

                    TextField("Tu nombre", text: $name)
                        .font(BT.body)
                        .padding(Spacing.sm + 2)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.xl)

                Spacer()
            }

            // CTA fixed at bottom
            Button(action: {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !loading else { return }
                Haptic.medium()
                loading = true
                onComplete(trimmed)
            }) {
                ZStack {
                    if loading {
                        ProgressView().progressViewStyle(.circular).tint(Color.inkInverse)
                    } else {
                        Text("Continuar").font(BT.footnoteBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.ink.opacity(0.3) : Color.ink)
                .foregroundStyle(Color.inkInverse)
                .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.lg)
        }
    }
}

// MARK: – 02 TELÉFONO

struct PhoneStep: View {
    @Binding var phone: String
    var onBack: () -> Void
    var onContinue: () -> Void

    @FocusState private var focused: Bool
    @State private var country   = Country.defaultCountry
    @State private var isSending = false
    @State private var errorMsg: String? = nil

    private var canContinue: Bool { phone.filter(\.isNumber).count >= 5 }

    var body: some View {
        OnboardingShell(
            step: "PASO 1 DE 4",
            onBack: onBack,
            cta: "Envíame el código",
            ctaEnabled: canContinue && !isSending,
            onCTA: sendOTP
        ) {
            VStack(alignment: .leading, spacing: 0) {
                stepHeadline(bold: "Tu", italic: "número.")

                Text("Te enviamos un código por mensaje de texto para verificar que eres tú.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xl)

                PhoneCountryField(phone: $phone, country: $country, focused: $focused)

                if let err = errorMsg {
                    Text(err)
                        .font(BT.caption1)
                        .foregroundStyle(.red)
                        .padding(.top, Spacing.sm)
                }

                if isSending {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().scaleEffect(0.8)
                        Text("Enviando código…")
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(.top, Spacing.sm)
                } else {
                    Text("Podrían aplicar tarifas de mensajería. Verificaremos tu número con un SMS de un solo uso.")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.top, Spacing.sm)
                }
            }
        }
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
                    isSending = false
                    phone = fullPhone
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMsg = "No pudimos enviar el código. Verifica tu número e intenta de nuevo."
                }
            }
        }
    }
}

// MARK: – 03 CÓDIGO

struct CodeStep: View {
    let phone: String
    var onBack: () -> Void
    var onProfileExists: () -> Void = {}
    var onContinue: () -> Void

    @State private var code = ""
    @FocusState private var otpFocused: Bool
    @State private var isVerifying = false
    @State private var errorMsg: String? = nil
    @State private var resendCooldown = 0
    @State private var cooldownTimer: Timer? = nil

    private var canVerify: Bool { code.count == 6 }

    private var displayPhone: String {
        // Mostrar el número E.164 con espacios cada 3 dígitos para legibilidad
        guard phone.hasPrefix("+") else { return phone }
        let parts = phone.dropFirst() // quitar el +
        let digits = parts.filter(\.isNumber)
        guard digits.count >= 6 else { return phone }
        // Separar código de país (hasta 3 dígitos) del número local
        let countryDigits = String(digits.prefix(min(3, digits.count - 6)))
        let local = String(digits.dropFirst(countryDigits.count))
        let chunks = stride(from: 0, to: local.count, by: 3).map {
            let start = local.index(local.startIndex, offsetBy: $0)
            let end   = local.index(start, offsetBy: min(3, local.count - $0))
            return String(local[start..<end])
        }
        return "+\(countryDigits) \(chunks.joined(separator: " "))"
    }

    var body: some View {
        OnboardingShell(
            step: "PASO 2 DE 4",
            onBack: onBack,
            cta: isVerifying ? "Verificando…" : "Verificar",
            ctaEnabled: canVerify && !isVerifying,
            onCTA: verifyOTP
        ) {
            VStack(alignment: .leading, spacing: 0) {
                stepHeadline(bold: "Código", italic: nil, line2bold: "de verificación.")

                (Text("Acaba de llegarte un SMS al **\(displayPhone)**. ")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                + Text("Cambiar")
                    .font(BT.callout)
                    .foregroundStyle(Color.sand)
                    .underline())
                .onTapGesture { onBack() }

                // OTP input — single field, 6 visual boxes, SMS AutoFill
                OTPInput(code: $code, isFocused: $otpFocused)
                    .padding(.top, Spacing.xl)
                    .padding(.bottom, Spacing.lg)

                if let err = errorMsg {
                    Text(err)
                        .font(BT.caption1)
                        .foregroundStyle(.red)
                        .padding(.bottom, Spacing.sm)
                }

                // Resend button
                Button {
                    resendOTP()
                } label: {
                    if resendCooldown > 0 {
                        Text("Reenviar en \(resendCooldown)s")
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                    } else {
                        Text("Reenviar código")
                            .font(BT.callout)
                            .foregroundStyle(Color.sand)
                            .underline()
                    }
                }
                .disabled(resendCooldown > 0)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            otpFocused = true
            startCooldown(30)
        }
        .onDisappear { cooldownTimer?.invalidate() }
    }

    private func verifyOTP() {
        guard canVerify else { return }
        Haptic.medium()
        isVerifying = true
        errorMsg = nil

        Task {
            do {
                let profileComplete = try await AuthService.shared.verifyOTP(phone: phone, code: code)
                await MainActor.run {
                    isVerifying = false
                    Haptic.success()
                    if profileComplete {
                        onProfileExists()
                    } else {
                        onContinue()
                    }
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
        Task {
            try? await AuthService.shared.sendOTP(phone: phone)
            await MainActor.run { startCooldown(60) }
        }
    }

    private func startCooldown(_ seconds: Int) {
        cooldownTimer?.invalidate()
        resendCooldown = seconds
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if resendCooldown > 0 {
                resendCooldown -= 1
            } else {
                t.invalidate()
            }
        }
    }
}

// MARK: – 04 IDENTIDAD

struct IdentityStep: View {
    @Binding var fullName:    String
    @Binding var docType:     String
    @Binding var docNumber:   String
    @Binding var birthDate:   String
    @Binding var nationality: String
    var onBack: () -> Void
    var onContinue: () -> Void

    enum DocKind { case dni, passport }
    @State private var docKind: DocKind = .dni
    @State private var birthDay:   Int = 1
    @State private var birthMonth: Int = 1
    @State private var birthYear:  Int = Calendar.current.component(.year, from: Date()) - 18
    @State private var birthDateSet = false

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var daysInMonth: Int {
        let cal = Calendar.current
        let comps = DateComponents(year: birthYear, month: birthMonth)
        return cal.range(of: .day, in: .month, for: cal.date(from: comps) ?? Date())?.count ?? 31
    }
    private var isAdult: Bool { (currentYear - birthYear) >= 18 }

    private var canContinue: Bool {
        !fullName.isEmpty && !docNumber.isEmpty && birthDateSet && isAdult
    }

    private var ctaHint: String? {
        if fullName.isEmpty || docNumber.isEmpty { return "Completa tu nombre y documento" }
        if !birthDateSet { return "Selecciona tu fecha de nacimiento" }
        if !isAdult { return "Debes ser mayor de 18 años" }
        return nil
    }

    var body: some View {
        OnboardingShell(
            step: "PASO 3 DE 4",
            onBack: onBack,
            cta: "Continuar",
            ctaEnabled: canContinue,
            onCTA: { Haptic.medium(); onContinue() },
            ctaHint: ctaHint
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("VERIFICACIÓN · LEY 29571")
                    .font(BT.eyebrow)
                    .tracking(1)
                    .foregroundStyle(Color.sand)
                    .padding(.bottom, Spacing.sm)

                stepHeadline(bold: "Tu", italic: "identidad.")

                Text("Queremos saber a quién recibimos. Confirmar quién eres nos cuida a todos — a quien llega y a quien abre la puerta.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.lg)

                HStack(spacing: 0) {
                    docTypeTab("DNI · Peruanos", type: .dni)
                    docTypeTab("Pasaporte · Extranjeros", type: .passport)
                }
                .onChange(of: docKind) { _, v in docType = v == .dni ? "dni" : "passport" }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.border, lineWidth: 1))
                .padding(.bottom, Spacing.lg)

                identityField(label: "NOMBRE COMPLETO", icon: "person", placeholder: "Sarah J. Whitman", value: $fullName)
                identityField(label: docKind == .dni ? "NÚMERO DE DNI" : "NÚMERO DE PASAPORTE",
                              icon: "doc.text",
                              placeholder: docKind == .dni ? "12345678" : "G2•···42",
                              value: $docNumber)
                    .padding(.top, Spacing.md)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("FECHA DE NACIMIENTO")
                            .font(BT.eyebrow)
                            .tracking(1)
                            .foregroundStyle(Color.inkMuted)
                        Spacer()
                        if birthDateSet && isAdult {
                            Label("18+", systemImage: "checkmark.circle.fill")
                                .font(BT.caption2)
                                .foregroundStyle(Color.teal)
                        }
                    }

                    HStack(spacing: 0) {
                        // Día
                        Picker("Día", selection: $birthDay) {
                            ForEach(1...daysInMonth, id: \.self) { d in
                                Text(String(format: "%02d", d)).tag(d)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .onChange(of: birthDay) { _, _ in birthDateSet = true; syncBirthDate() }

                        // Mes
                        Picker("Mes", selection: $birthMonth) {
                            ForEach(1...12, id: \.self) { m in
                                Text(DateFormatter().monthSymbols[m - 1]
                                    .prefix(3).capitalized).tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .onChange(of: birthMonth) { _, _ in
                            birthDay = min(birthDay, daysInMonth)
                            birthDateSet = true
                            syncBirthDate()
                        }

                        // Año
                        Picker("Año", selection: $birthYear) {
                            ForEach((currentYear - 100)...(currentYear - 18), id: \.self) { y in
                                Text(String(y)).tag(y)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .onChange(of: birthYear) { _, _ in
                            birthDay = min(birthDay, daysInMonth)
                            birthDateSet = true
                            syncBirthDate()
                        }
                    }
                    .frame(height: 120)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                }
                .padding(.top, Spacing.md)

                VStack(alignment: .leading, spacing: 6) {
                    Text("NACIONALIDAD")
                        .font(BT.eyebrow)
                        .tracking(1)
                        .foregroundStyle(Color.inkMuted)
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(Color.inkMuted)
                            .font(.system(size: 14))
                        TextField("Perú", text: $nationality)
                            .font(BT.callout)
                            .foregroundStyle(Color.ink)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                }
                .padding(.top, Spacing.md)

                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkMuted)
                        .padding(.top, 2)
                    Text("Guardamos **solo el número**, no una imagen de tu documento. Cifrado y nunca compartido con terceros.")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
                .padding(Spacing.sm)
                .background(Color.sandLight.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .padding(.top, Spacing.md)
            }
        }
    }

    private func syncBirthDate() {
        birthDate = String(format: "%04d-%02d-%02d", birthYear, birthMonth, birthDay)
    }

    @ViewBuilder
    private func docTypeTab(_ label: String, type: DocKind) -> some View {
        Button {
            withAnimation(.spring(response: 0.2)) { docKind = type }
        } label: {
            Text(label)
                .font(BT.caption2)
                .foregroundStyle(docKind == type ? Color.ink : Color.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(docKind == type ? Color.sandLight.opacity(0.6) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm - 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func identityField(label: String, icon: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(BT.eyebrow)
                .tracking(1)
                .foregroundStyle(Color.inkMuted)
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(Color.inkMuted)
                    .font(.system(size: 14))
                TextField(placeholder, text: value)
                    .font(BT.callout)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
        }
    }
}

// MARK: – 05 CÓDIGO DE CONDUCTA

struct ConductStep: View {
    var onBack: () -> Void
    var onContinue: () -> Void

    @State private var accepted = false

    private let rules: [(String, String, String)] = [
        ("heart", "Respeto mutuo",            "Trato amable con buddies y viajeros, sin discriminación."),
        ("nosign", "Sin dinero de por medio",  "Acompañar es gratis. Ningún buddy cobra, pide propina ni transferencias."),
        ("exclamationmark.triangle", "Cero contenido ilegal", "Sin acoso, fraude ni actividades prohibidas por ley."),
    ]

    var body: some View {
        OnboardingShell(
            step: "PASO 4 DE 4",
            onBack: onBack,
            cta: "Acepto el código",
            ctaEnabled: accepted,
            onCTA: { Haptic.medium(); onContinue() },
            ctaHint: accepted ? nil : "Marca la casilla para continuar"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("CÓDIGO DE CONDUCTA")
                    .font(BT.eyebrow)
                    .tracking(1)
                    .foregroundStyle(Color.sand)
                    .padding(.bottom, Spacing.sm)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Cómo nos")
                        .font(BT.title1)
                        .foregroundStyle(Color.ink)
                    Text("cuidamos.")
                        .font(BT.displayLarge)
                        .foregroundStyle(Color.sand)
                }

                Text("Tres acuerdos que mantienen este lugar amable para todos. Al aceptarlos, te haces parte de cómo nos cuidamos.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xl)

                VStack(spacing: Spacing.sm) {
                    ForEach(rules, id: \.1) { icon, title, desc in
                        HStack(alignment: .top, spacing: Spacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.sandLight.opacity(0.5))
                                    .frame(width: 44, height: 44)
                                Image(systemName: icon)
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(Color.sand)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(Color.ink)
                                Text(desc)
                                    .font(BT.callout)
                                    .foregroundStyle(Color.inkMuted)
                            }
                            Spacer()
                        }
                        .padding(Spacing.md)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                    }
                }

                Button {
                    Haptic.select()
                    withAnimation(.spring(response: 0.2)) { accepted.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(accepted ? Color.sand : Color.border, lineWidth: accepted ? 2 : 1)
                                .frame(width: 22, height: 22)
                            if accepted {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.sand)
                            }
                        }
                        Group {
                            Text("He leído y acepto los ") +
                            Text("Términos y Condiciones").foregroundColor(Color.sand).fontWeight(.semibold) +
                            Text(", la ") +
                            Text("Política de Privacidad").foregroundColor(Color.sand).fontWeight(.semibold) +
                            Text(" y el ") +
                            Text("Código de Conducta").foregroundColor(Color.sand).fontWeight(.semibold) +
                            Text(" de Buddy. Confirmo que tengo 18 años o más.")
                        }
                        .font(BT.callout)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(Spacing.md)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
                        accepted ? Color.sand : Color.border,
                        lineWidth: accepted ? 1.5 : 1
                    ))
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.md)
            }
        }
    }
}

// MARK: – SHARED SHELL

struct OnboardingShell<Content: View>: View {
    let step: String
    let onBack: () -> Void
    let cta: String
    let ctaEnabled: Bool
    let onCTA: () -> Void
    var ctaHint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
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
                        Spacer()
                        Text(step)
                            .font(BT.eyebrow)
                            .tracking(1)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.md)

                    content
                        .padding(.horizontal, Spacing.edge)

                    Spacer().frame(height: 120)
                }
            }

            VStack(spacing: 4) {
                LinearGradient(colors: [Color.canvas.opacity(0), Color.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)

                if let hint = ctaHint, !ctaEnabled {
                    Text(hint)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }

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
                .padding(.bottom, Spacing.lg)
                .background(Color.canvas)
            }
        }
    }
}

// MARK: – OTP INPUT (single hidden field + 6 visual boxes)
// Uses one TextField so iOS SMS AutoFill fills all 6 digits at once.

struct OTPInput: View {
    @Binding var code: String          // always up to 6 numeric chars
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        ZStack {
            // Hidden real TextField — captures input + SMS AutoFill
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .onChange(of: code) { _, v in
                    // Keep only digits, max 6
                    let filtered = v.filter(\.isNumber)
                    if filtered != v || v.count > 6 {
                        code = String(filtered.prefix(6))
                    }
                }

            // Visual boxes
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let char: String = i < code.count
                        ? String(code[code.index(code.startIndex, offsetBy: i)])
                        : ""
                    let filled = !char.isEmpty

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(filled ? Color.ink : Color.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        isFocused && code.count == i ? Color.sand : Color.border,
                                        lineWidth: isFocused && code.count == i ? 2 : 1
                                    )
                            )
                        Text(char)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(filled ? Color.inkInverse : Color.ink)
                    }
                    .frame(width: 46, height: 56)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
    }
}

// Keep OTPBox for any legacy references
struct OTPBox: View {
    @Binding var text: String
    let isFocused: Bool
    let onFilled: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(text.isEmpty ? Color.surface : Color.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isFocused ? Color.sand : Color.border, lineWidth: isFocused ? 2 : 1)
                )
            TextField("", text: $text)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(text.isEmpty ? Color.ink : Color.inkInverse)
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .onChange(of: text) { _, v in
                    if v.count > 1 { text = String(v.last ?? Character("")) }
                    if v.count == 1 { onFilled() }
                }
        }
        .frame(width: 46, height: 56)
    }
}

// MARK: – HEADLINE HELPER

@ViewBuilder
func stepHeadline(bold: String, italic: String?, line2bold: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(bold)
                .font(BT.title1)
                .foregroundStyle(Color.ink)
            if let it = italic {
                Text(it)
                    .font(BT.displayLarge)
                    .foregroundStyle(Color.sand)
            }
        }
        if let l2 = line2bold {
            Text(l2)
                .font(BT.title1)
                .foregroundStyle(Color.ink)
        }
    }
    .padding(.bottom, Spacing.sm)
}
