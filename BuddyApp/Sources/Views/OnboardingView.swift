import SwiftUI
import AuthenticationServices

// MARK: – ONBOARDING FLOW
// Welcome → (social login) → NeedsProfileCompletion (si el backend lo indica)

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}

    enum Step { case welcome, needsProfileCompletion }
    @State private var step: Step = .welcome
    @State private var socialName = ""

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep(
                    onSocialComplete:  { onComplete(); dismiss() },
                    onSocialNeedsName: { name in
                        socialName = name ?? ""
                        advance(to: .needsProfileCompletion)
                    }
                )
            case .needsProfileCompletion:
                SocialNameStep(initialName: socialName, onBack: { advance(to: .welcome) }) { name in
                    Task {
                        try? await AuthService.shared.completeProfileForSocialLogin(fullName: name)
                        await MainActor.run { onComplete(); dismiss() }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private func advance(to next: Step) {
        print("🔀 [Onboarding] \(step) → \(next)")
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}

// MARK: – 01 BIENVENIDA

struct WelcomeStep: View {
    var onSocialComplete:  (() -> Void)?          = nil
    var onSocialNeedsName: ((String?) -> Void)?   = nil

    @State private var socialLoading = false
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
                            print("🍎 [Apple.onCompletion] failure code=\(nsErr.code)")
                            if nsErr.code != ASAuthorizationError.canceled.rawValue {
                                socialError = "Error con Apple: \(err.localizedDescription)"
                            }
                        case .success(let auth):
                            print("🍎 [Apple.onCompletion] success")
                            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                                  let tokenData = cred.identityToken,
                                  let token = String(data: tokenData, encoding: .utf8) else {
                                print("🍎 [Apple.onCompletion] ❌ no token")
                                socialError = "No se pudo leer el token de Apple."
                                return
                            }
                            var fullName: String? = nil
                            if let fn = cred.fullName {
                                let j = [fn.givenName, fn.familyName]
                                    .compactMap { $0 }.joined(separator: " ")
                                    .trimmingCharacters(in: .whitespaces)
                                if !j.isEmpty { fullName = j }
                            }
                            handleSocialSignIn(credential: IdentityCredential(
                                provider: .apple, identityToken: token,
                                email: cred.email, fullName: fullName
                            ))
                        }
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(Capsule())
                    .padding(.horizontal, Spacing.edge)
                    .opacity(socialLoading ? 0.5 : 1)
                    .disabled(socialLoading)

                    // ── Sign in with Google ───────────────────────────────
                    Button(action: { handleSocialSignIn(provider: GoogleProvider()) }) {
                        ZStack {
                            if socialLoading {
                                ProgressView().progressViewStyle(.circular).tint(Color.ink)
                            } else {
                                HStack(spacing: 10) {
                                    Image("google_logo")
                                        .resizable().scaledToFit()
                                        .frame(width: 20, height: 20)
                                    Text("Continuar con Google")
                                        .font(BT.footnoteBold)
                                        .foregroundStyle(Color.ink)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, Spacing.edge)
                    .opacity(socialLoading ? 0.7 : 1)
                    .disabled(socialLoading)

                    if let err = socialError {
                        Text(err)
                            .font(BT.caption1)
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.edge)
                    }

                    Text("Al continuar confirmas que tienes **18+ años** y aceptas nuestros **términos, privacidad** y **código de conducta**")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.bottom, Spacing.lg)
                }
            }
        }
    }

    // Apple: credencial ya lista desde SignInWithAppleButton.onCompletion
    private func handleSocialSignIn(credential: IdentityCredential) {
        print("🍎 [WelcomeStep] Apple credential — email=\(credential.email ?? "nil") name=\(credential.fullName ?? "nil")")
        socialLoading = true; socialError = nil
        Task {
            do {
                let result      = try await AuthService.shared._postToBackend(credential)
                let destination = AuthCoordinator.shared.handle(result)
                print("🍎 [WelcomeStep] ✅ status=\(result.status) destination=\(destination)")
                await MainActor.run {
                    socialLoading = false
                    switch destination {
                    case .home:                   onSocialComplete?()
                    case .needsProfileCompletion: onSocialNeedsName?(result.suggestedName)
                    }
                }
            } catch {
                print("🍎 [WelcomeStep] ❌ \(error)")
                await MainActor.run {
                    socialLoading = false
                    socialError = "No se pudo iniciar sesión con Apple."
                }
            }
        }
    }

    // Google: el proveedor obtiene la credencial internamente
    private func handleSocialSignIn(provider: IdentityProvider) {
        print("🌐 [WelcomeStep] Google sign in…")
        socialLoading = true; socialError = nil
        Task {
            do {
                let result      = try await AuthService.shared.signIn(with: provider)
                let destination = AuthCoordinator.shared.handle(result)
                print("🌐 [WelcomeStep] ✅ status=\(result.status) destination=\(destination)")
                await MainActor.run {
                    socialLoading = false
                    switch destination {
                    case .home:                   onSocialComplete?()
                    case .needsProfileCompletion: onSocialNeedsName?(result.suggestedName)
                    }
                }
            } catch {
                let nsErr = error as NSError
                print("🌐 [WelcomeStep] ❌ code=\(nsErr.code) \(error)")
                await MainActor.run {
                    socialLoading = false
                    let cancelCodes = [ASAuthorizationError.canceled.rawValue, 1]
                    if !cancelCodes.contains(nsErr.code) {
                        socialError = "No se pudo iniciar sesión."
                    }
                }
            }
        }
    }
}

// MARK: – COMPLETAR PERFIL (nombre para usuarios sociales sin nombre)

struct SocialNameStep: View {
    var initialName: String = ""
    var onBack:      () -> Void
    var onComplete:  (String) -> Void

    @State private var loading = false
    @State private var name: String

    init(initialName: String = "", onBack: @escaping () -> Void, onComplete: @escaping (String) -> Void) {
        self.initialName = initialName
        self.onBack      = onBack
        self.onComplete  = onComplete
        _name = State(initialValue: initialName)
    }

    private var canContinue: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.canvas.ignoresSafeArea()

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
                    Text("PASO 1 DE 3")
                        .font(BT.eyebrow).tracking(1)
                        .foregroundStyle(Color.inkMuted)
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.lg)

                VStack(alignment: .leading, spacing: 8) {
                    Text("¿Cómo te")
                        .font(BT.title1).foregroundStyle(Color.ink)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("llamamos?")
                            .font(BT.displayLarge).foregroundStyle(Color.sand)
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)

                Text("Para conectarte con un buddy necesitamos saber quién eres.")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.lg)

                VStack(alignment: .leading, spacing: 6) {
                    Text("NOMBRE")
                        .font(BT.eyebrow).tracking(1).foregroundStyle(Color.inkMuted)
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "person").foregroundStyle(Color.inkMuted)
                            .font(.system(size: 14))
                        TextField("Sarah Whitman", text: $name)
                            .font(BT.callout)
                            .textContentType(.givenName)
                            .autocapitalization(.words)
                    }
                    .padding(.horizontal, Spacing.md).padding(.vertical, 14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Color.border, lineWidth: 1))
                }
                .padding(.horizontal, Spacing.edge)

                Spacer()
            }

            VStack(spacing: 4) {
                Button(action: {
                    guard canContinue, !loading else { return }
                    Haptic.medium()
                    loading = true
                    onComplete(name.trimmingCharacters(in: .whitespaces))
                }) {
                    ZStack {
                        if loading {
                            ProgressView().progressViewStyle(.circular).tint(Color.inkInverse)
                        } else {
                            Text("Continuar")
                                .font(BT.footnoteBold)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(canContinue ? Color.ink : Color.inkMuted.opacity(0.25))
                    .foregroundStyle(canContinue ? Color.inkInverse : Color.inkMuted)
                    .clipShape(Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(!canContinue || loading)
                .padding(.horizontal, Spacing.edge)
                .padding(.bottom, Spacing.lg)
            }
        }
    }
}
