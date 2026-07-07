import SwiftUI
import AuthenticationServices

// MARK: – Auth Purpose

enum AuthPurpose {
    case buddy    // "Conecta con un buddy." — InicioView, ConexionesView
    case publish  // "Publica tus lugares favoritos." — TripsView
    case profile  // "Tu historia viaja contigo." — YoView (name-only sheet)

    var titleLine1: String {
        switch self {
        case .buddy:   return "Conecta con"
        case .publish: return "Publica tus"
        case .profile: return "Tu historia"
        }
    }
    var titleLine2prefix: String? {
        switch self {
        case .buddy:   return "un"
        case .publish: return "lugares"
        case .profile: return nil
        }
    }
    var titleLine2accent: String {
        switch self {
        case .buddy:   return "buddy."
        case .publish: return "favoritos."
        case .profile: return "viaja contigo."
        }
    }
    var subtitle: String {
        switch self {
        case .buddy:   return "Para conectarte con un buddy necesitamos saber quién eres."
        case .publish: return "Para publicar necesitamos identificarte."
        case .profile: return "Para guardar tu historia necesitamos saber quién eres."
        }
    }
}

// MARK: – IDENTITY SHEET
// Flujo social único: Apple o Google → backend → done.
// Si el backend devuelve needs_profile y no hay nombre del proveedor, pide el nombre.
// Presentado desde InicioView, TripsView y ConexionesView.
// YoView embeds the social buttons directly; uses this sheet only for the name step.

struct IdentitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authState: AuthState

    var purpose: AuthPurpose
    var onAuthenticated: () -> Void

    enum Step { case social, name }
    @State private var step:         Step
    @State private var suggestedName: String
    @State private var socialLoading  = false
    @State private var socialError:   String? = nil

    init(purpose: AuthPurpose = .buddy,
         suggestedName: String = "",
         startAtName: Bool = false,
         onAuthenticated: @escaping () -> Void = {}) {
        self.purpose = purpose
        self.onAuthenticated = onAuthenticated
        self._step = State(initialValue: startAtName ? .name : .social)
        self._suggestedName = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.inkMuted.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10).padding(.bottom, 20)

            ZStack {
                switch step {
                case .social: socialStep
                case .name:   nameStep
                }
            }
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        .background(Color.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.light)
    }

    // MARK: – Social step

    private var socialStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(purpose.titleLine1)
                    .font(BT.title1).foregroundStyle(Color.ink)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let prefix = purpose.titleLine2prefix {
                        Text(prefix)
                            .font(BT.title1).foregroundStyle(Color.ink)
                    }
                    Text(purpose.titleLine2accent)
                        .font(BT.displayLarge).foregroundStyle(Color.sand)
                }
            }
            .padding(.horizontal, Spacing.edge)

            Text(purpose.subtitle)
                .font(BT.callout).foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)

            Spacer()

            VStack(spacing: Spacing.sm) {
                SignInWithAppleButton(.signIn, onRequest: { req in
                    req.requestedScopes = [.fullName, .email]
                }, onCompletion: { result in
                    switch result {
                    case .failure(let err):
                        let nsErr = err as NSError
                        if nsErr.code != ASAuthorizationError.canceled.rawValue {
                            socialError = "Error con Apple."
                        }
                    case .success(let auth):
                        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                              let tokenData = cred.identityToken,
                              let token = String(data: tokenData, encoding: .utf8) else {
                            socialError = "No se pudo leer el token de Apple."
                            return
                        }
                        var name: String? = nil
                        if let fn = cred.fullName {
                            let j = [fn.givenName, fn.familyName].compactMap { $0 }
                                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                            if !j.isEmpty { name = j }
                        }
                        handleSocialSignIn(credential: IdentityCredential(
                            provider: .apple, identityToken: token,
                            email: cred.email, fullName: name
                        ))
                    }
                })
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50).clipShape(Capsule())
                .padding(.horizontal, Spacing.edge)
                .opacity(socialLoading ? 0.5 : 1).disabled(socialLoading)

                Button(action: { handleSocialSignIn(provider: GoogleProvider()) }) {
                    ZStack {
                        if socialLoading {
                            ProgressView().progressViewStyle(.circular).tint(Color.ink)
                        } else {
                            HStack(spacing: 10) {
                                Image("google_logo").resizable().scaledToFit()
                                    .frame(width: 20, height: 20)
                                Text("Continuar con Google")
                                    .font(BT.footnoteBold).foregroundStyle(Color.ink)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Color.surface).clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, Spacing.edge)
                .opacity(socialLoading ? 0.7 : 1).disabled(socialLoading)

                if let err = socialError {
                    Text(err).font(BT.caption1).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.edge)
                }

                Text("Al continuar confirmas que tienes **18+ años** y aceptas nuestros **términos, privacidad** y **código de conducta**")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.bottom, Spacing.lg)
            }
        }
    }

    // MARK: – Name step (solo cuando el backend indica needs_profile y no hay nombre del proveedor)

    private var nameStep: some View {
        IdentityNameStep(
            name: $suggestedName,
            onBack: { withAnimation { step = .social } },
            onContinue: {
                let trimmed = suggestedName.trimmingCharacters(in: .whitespaces)
                Task {
                    try? await AuthService.shared.completeProfileForSocialLogin(fullName: trimmed)
                    await MainActor.run { finishAuth() }
                }
            }
        )
    }

    // MARK: – Social sign in handlers

    private func handleSocialSignIn(credential: IdentityCredential) {
        socialLoading = true; socialError = nil
        Task {
            do {
                let result      = try await AuthService.shared._postToBackend(credential)
                let destination = AuthCoordinator.shared.handle(result)
                await MainActor.run {
                    socialLoading = false
                    switch destination {
                    case .home:
                        finishAuth()
                    case .needsProfileCompletion:
                        suggestedName = result.suggestedName ?? ""
                        if suggestedName.trimmingCharacters(in: .whitespaces).count >= 2 {
                            // Nombre ya disponible — completar directo
                            Task {
                                try? await AuthService.shared.completeProfileForSocialLogin(
                                    fullName: suggestedName.trimmingCharacters(in: .whitespaces)
                                )
                                await MainActor.run { finishAuth() }
                            }
                        } else {
                            withAnimation { step = .name }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    socialLoading = false
                    socialError = "No se pudo iniciar sesión."
                }
            }
        }
    }

    private func handleSocialSignIn(provider: IdentityProvider) {
        socialLoading = true; socialError = nil
        Task {
            do {
                let result      = try await AuthService.shared.signIn(with: provider)
                let destination = AuthCoordinator.shared.handle(result)
                await MainActor.run {
                    socialLoading = false
                    switch destination {
                    case .home:
                        finishAuth()
                    case .needsProfileCompletion:
                        suggestedName = result.suggestedName ?? ""
                        if suggestedName.trimmingCharacters(in: .whitespaces).count >= 2 {
                            Task {
                                try? await AuthService.shared.completeProfileForSocialLogin(
                                    fullName: suggestedName.trimmingCharacters(in: .whitespaces)
                                )
                                await MainActor.run { finishAuth() }
                            }
                        } else {
                            withAnimation { step = .name }
                        }
                    }
                }
            } catch {
                let nsErr = error as NSError
                await MainActor.run {
                    socialLoading = false
                    let cancelCodes = [ASAuthorizationError.canceled.rawValue, 1]
                    if !cancelCodes.contains(nsErr.code) { socialError = "No se pudo iniciar sesión." }
                }
            }
        }
    }

    private func finishAuth() {
        authState.didAuthenticate()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onAuthenticated() }
    }
}

// MARK: – Paso nombre (privado al sheet)

private struct IdentityNameStep: View {
    @Binding var name: String
    var onBack:     () -> Void
    var onContinue: () -> Void

    @FocusState private var focused: Bool
    @State private var loading = false

    private var canContinue: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.surface).clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
                        .foregroundStyle(Color.ink)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("PASO 1 DE 1")
                    .font(BT.eyebrow).tracking(1).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Spacing.edge)

            Text("¿Cómo te\nllamamos?")
                .font(BT.title1).foregroundStyle(Color.ink)
                .padding(.horizontal, Spacing.edge).padding(.top, Spacing.md)

            Text("Para conectarte con un buddy necesitamos saber quién eres.")
                .font(BT.callout).foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.sm).padding(.bottom, Spacing.lg)

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
                        .focused($focused)
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, 14)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(focused ? Color.sand : Color.border,
                                  lineWidth: focused ? 1.5 : 1))
            }
            .padding(.horizontal, Spacing.edge)

            Spacer()

            Button(action: {
                guard canContinue, !loading else { return }
                Haptic.medium(); loading = true; onContinue()
            }) {
                ZStack {
                    if loading {
                        ProgressView().progressViewStyle(.circular).tint(Color.inkInverse)
                    } else {
                        Text("Continuar").font(BT.footnoteBold)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(canContinue ? Color.ink : Color.inkMuted.opacity(0.25))
                .foregroundStyle(canContinue ? Color.inkInverse : Color.inkMuted)
                .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(!canContinue || loading)
            .padding(.horizontal, Spacing.edge).padding(.bottom, 36)
        }
        .onAppear { focused = true }
    }
}
