import SwiftUI
import PhotosUI

// MARK: – YO (PROFILE)

enum IdentityMode: Identifiable {
    case newUser, login
    var id: Self { self }
}

struct YoView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var routeStore: RouteStore
    @State private var user: APIUser? = nil
    @State private var stickers: [APIUserSticker] = []
    @State private var journeys: [APIJourney] = []
    @State private var tripsNextCursor: String? = nil
    @State private var tripsHasMore: Bool = false
    @State private var isLoadingMoreTrips: Bool = false
    @State private var selectedStory: APIJourney? = nil   // detalle de publicación
    @State private var isLoading = true
    @State private var editingBio = false
    @State private var bioText = ""
    @State private var isSavingBio = false
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var buddyMe: APIBuddyMe? = nil
    @State private var destinations: [APIDestination] = []
    @State private var showBecomeBuddyConfirm = false
    @State private var isBecomingBuddy = false
    @State private var identityMode: IdentityMode? = nil
    // Guardia de logout: si hay apoyo activo no se puede cerrar sesión sin confirmar
    @State private var showActiveHelpLogoutAlert = false
    // Caché en memoria: evita recargar el perfil en cada cambio de tab
    @State private var lastFetchedAt: Date? = nil

    var body: some View {
        NavigationStack {
            Group {
                // ── Estado anónimo ──
                if !authState.isLoggedIn {
                    anonymousState
                } else if isLoading {
                    ZStack {
                        Color.canvas.ignoresSafeArea()
                        ProgressView().tint(Color.inkMuted)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Apertura editorial
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TU PERFIL")
                                        .font(BT.eyebrow).tracking(2)
                                        .foregroundStyle(Color.inkMuted)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("Tu")
                                            .font(BT.title1).foregroundStyle(Color.ink)
                                        Text("historia.")
                                            .font(BT.displayLarge).foregroundStyle(Color.sand)
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button {
                                        Haptic.light()
                                        requestLogout()
                                    } label: {
                                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                                    }
                                    Button(role: .destructive) {
                                        Haptic.medium()
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Eliminar mi cuenta", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(Color.inkMuted)
                                        .frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                            }
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)

                            // 1 — Identidad
                            profileHeader
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)

                            // 2 — Bio
                            bioSection
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.md)

                            // 3 — Rol buddy (fila nav o CTA), antes de la colección
                            buddyRow
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.xl)

                            if buddyMe?.isBuddy != true {
                                becomeBuddyCTA
                                    .padding(.horizontal, Spacing.edge)
                                    .padding(.top, Spacing.md)
                            }

                            // 4 — Colección (historia del viajero)
                            stickerSection
                                .padding(.top, Spacing.xl)

                            tripsSection
                                .padding(.top, Spacing.xl)
                        }
                        .padding(.bottom, 100)
                    }
                    .refreshable { await loadProfile(forceRefresh: true) }
                    .background(Color.canvas)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // Detalle de la publicación — mismo visor que en Home
            .sheet(item: $selectedStory) { journey in
                StoryViewerSheet(journey: journey)
            }
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    performLogout()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Tendrás que volver a verificar tu número de teléfono. Puedes regresar cuando quieras.")
            }
            .alert("Tienes un apoyo activo", isPresented: $showActiveHelpLogoutAlert) {
                Button("Cerrar sesión de todas formas", role: .destructive) { performLogout() }
                Button("Quedarse", role: .cancel) {}
            } message: {
                Text("Hay un buddy ayudándote ahora mismo. Si cierras sesión puedes regresar verificando el mismo número de teléfono.")
            }
            .sheet(item: $identityMode) { mode in
                IdentitySheet(skipName: mode == .login) { Task { await loadProfile(forceRefresh: true) } }
                    .environmentObject(authState)
            }
            .confirmationDialog("¿Eliminar tu cuenta?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Eliminar cuenta permanentemente", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se eliminarán todos tus datos personales. Esta acción no se puede deshacer.")
            }
            .confirmationDialog("Alguien está llegando a tu ciudad.", isPresented: $showBecomeBuddyConfirm, titleVisibility: .visible) {
                Button("Ser Buddy en mi ciudad") {
                    Task { await becomeBuddy() }
                }
                Button("Ahora no", role: .cancel) {}
            } message: {
                Text("Los Buddies son personas locales que eligen estar cuando alguien llega por primera vez. Tú sabes cosas que ningún mapa puede mostrar.")
            }
            .overlay {
                if isDeletingAccount {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().tint(.white)
                            Text("Eliminando cuenta…").foregroundStyle(.white).font(BT.callout)
                        }
                    }
                }
            }
            .task { await loadProfile() }
            .onReceive(NotificationCenter.default.publisher(for: .stickerUnlocked)) { _ in
                Task { await loadProfile(forceRefresh: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
                Task { await loadProfile(forceRefresh: true) }
            }
        }
    }

    // MARK: – Profile Header (avatar + stats)

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            // Avatar — tapeable para cambiar foto
            PhotosPicker(selection: $avatarItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.sandLight)
                        .frame(width: 88, height: 88)
                    CachedImage(urlString: user?.avatarUrl) { img in
                        img.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.sand)
                            .frame(width: 88, height: 88) // ancla el placeholder al mismo tamaño
                    }
                    if isUploadingAvatar {
                        Circle().fill(.black.opacity(0.4)).frame(width: 88, height: 88)
                        ProgressView().tint(.white)
                    }
                    // Badge editar
                    ZStack {
                        Circle().fill(Color.ink).frame(width: 26, height: 26)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.inkInverse)
                    }
                    .offset(x: 2, y: 2)
                }
                .frame(width: 96, height: 96) // ancla el ZStack entero para que el badge no desplace el layout
            }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item: item) }
            }

            // Identidad — el nombre lidera, luego la narrativa
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.fullName ?? "Tú")
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(metaLine)
                    .font(BT.subhead)
                    .foregroundStyle(Color.inkMuted)
                if let since = user?.memberSince {
                    Text("Viajando desde \(memberSinceLabel(date: since))")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        let trips = journeys.count
        let tripsLabel = trips == 1 ? "1 trip" : "\(trips) trips"
        let stickersLabel = stickers.isEmpty ? nil
            : (stickers.count == 1 ? "1 sticker" : "\(stickers.count) stickers")
        return [tripsLabel, stickersLabel].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: – Bio

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingBio {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    TextField("Cuéntanos algo sobre ti…", text: $bioText, axis: .vertical)
                        .font(BT.callout)
                        .foregroundStyle(Color.ink)
                        .lineLimit(3...5)
                        .padding(Spacing.sm)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.sand, lineWidth: 1.5))

                    HStack(spacing: Spacing.sm) {
                        Button("Cancelar") {
                            bioText = user?.bio ?? ""
                            editingBio = false
                        }
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)

                        Spacer()

                        Button {
                            saveBio()
                        } label: {
                            if isSavingBio {
                                ProgressView().scaleEffect(0.7).tint(.white)
                            } else {
                                Text("Guardar")
                                    .font(BT.footnoteBold)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 7)
                        .background(Color.ink)
                        .foregroundStyle(Color.inkInverse)
                        .clipShape(Capsule())
                        .disabled(isSavingBio)
                    }
                }
            } else {
                // Toda la fila es tappeable — target ≥ 44pt
                Button {
                    bioText = user?.bio ?? ""
                    editingBio = true
                } label: {
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        if let bio = user?.bio, !bio.isEmpty {
                            Text(bio)
                                .font(BT.callout)
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("Cuéntale al mundo quién eres…")
                                .font(BT.callout)
                                .foregroundStyle(Color.inkMuted.opacity(0.7))
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.inkMuted)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Buddy row (fila única de navegación — patrón Settings.app)

    @ViewBuilder
    private var buddyRow: some View {
        if let bm = buddyMe, bm.isBuddy, let p = bm.profile {
            // IS BUDDY — fila navegable hacia BuddyProfileView
            NavigationLink {
                BuddyProfileView(profile: p, destinations: destinations) { updated in
                    buddyMe = updated
                }
            } label: {
                BuddyNavRow(profile: p, destinations: destinations)
            }
            .buttonStyle(.plain)
        }
        // Si no es buddy no se muestra nada aquí — el CTA está al fondo
    }

    // MARK: – CTA "Quiero ser Buddy" — al fondo, sin competir con el perfil

    private var becomeBuddyCTA: some View {
        Button {
            showBecomeBuddyConfirm = true
        } label: {
            HStack(spacing: 10) {
                Text("Ser Buddy en mi ciudad")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.inkMuted.opacity(0.5))
            }
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBecomingBuddy)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: – Sticker Section (colección con slots de progresión)

    private var stickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("STICKERS", count: stickers.count)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(stickers, id: \.id) { s in
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.sandLight)
                                    .frame(width: 64, height: 64)
                                if let urlStr = s.stickerCatalog?.imageUrl {
                                    CachedImage(urlString: urlStr) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(Color.sand)
                                            .font(.system(size: 24))
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                                } else {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(Color.sand)
                                        .font(.system(size: 24))
                                }
                            }
                            Text(s.stickerCatalog?.name ?? "Sticker")
                                .font(BT.caption1)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Text(shortDateFromDate(s.unlockedAt))
                                .font(BT.caption2)
                                .foregroundStyle(Color.inkMuted)
                        }
                        .frame(width: 72)
                    }

                    // Slots vacíos punteados — muestran que hay más por coleccionar
                    ForEach(0..<max(0, 3 - stickers.count), id: \.self) { _ in
                        Circle()
                            .strokeBorder(Color.inkMuted.opacity(0.25),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .frame(width: 64, height: 64)
                            .overlay(
                                Image(systemName: "questionmark")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(Color.inkMuted.opacity(0.3))
                            )
                            .frame(width: 72, alignment: .top)
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }

            Text("Cada sticker guarda un lugar que te recibió.")
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
        }
    }

    // MARK: – Section header (consistente entre secciones)

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(BT.eyebrow)
                .tracking(1.5)
                .foregroundStyle(Color.ink)
            if count > 0 {
                Text("· \(count)")
                    .font(BT.eyebrow)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(.horizontal, Spacing.edge)
    }

    // MARK: – Trips grid

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("TRIPS", count: journeys.count)

            if journeys.isEmpty {
                // Empty state — invita a la acción, no lamenta el vacío
                Button {
                    NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                    userInfo: ["tab": AppTab.trips.rawValue])
                } label: {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Color.inkMuted)
                        Text("Tu primer trip te espera")
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.edge)
            } else {
                let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(journeys, id: \.id) { journey in
                        TripGridCell(journey: journey)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            .onTapGesture {
                                Haptic.light()
                                selectedStory = journey
                            }
                    }
                    // Celdas fantasma — completan la fila e invitan al próximo trip
                    let remainder = journeys.count % 3
                    let ghosts = remainder == 0 ? 0 : 3 - remainder
                    ForEach(0..<ghosts, id: \.self) { _ in
                        Button {
                            NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                            userInfo: ["tab": AppTab.trips.rawValue])
                        } label: {
                            Color.surface
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundStyle(Color.inkMuted.opacity(0.6))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, Spacing.edge)

                // Cargar más páginas cuando hay resultados adicionales en el servidor
                if tripsHasMore {
                    Button {
                        Haptic.light()
                        Task { await loadMoreTrips() }
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingMoreTrips {
                                ProgressView().scaleEffect(0.8)
                            }
                            Text(isLoadingMoreTrips ? "Cargando…" : "Ver más trips")
                                .font(BT.footnoteBold)
                                .foregroundStyle(Color.ink)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.edge)
                    .disabled(isLoadingMoreTrips)
                }
            }
        }
    }

    // MARK: – Helpers

    // Verifica si hay un apoyo activo antes de cerrar sesión.
    private func requestLogout() {
        let hasActiveHelp = ChatStore.shared.connections.contains {
            ["accepted", "active"].contains($0.match.status) && !$0.isBuddyRole
        }
        if hasActiveHelp {
            showActiveHelpLogoutAlert = true
        } else {
            showLogoutConfirm = true
        }
    }

    private func performLogout() {
        AuthService.shared.signOut()
        // `userDidLogOut` ya fue emitido por signOut(); AuthState lo escucha y
        // pone isLoggedIn = false. Limpiamos el estado local de la vista.
        user         = nil
        stickers     = []
        journeys     = []
        buddyMe      = nil
        isLoading    = true
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await APIClient.shared.deleteAccount()
            AuthService.shared.signOut()
        } catch {
            print("[YoView] deleteAccount error:", error.localizedDescription)
        }
    }

    // MARK: – Vista anónima

    private var anonymousState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TU PERFIL")
                            .font(BT.eyebrow).tracking(2)
                            .foregroundStyle(Color.inkMuted)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Tu")
                                .font(BT.title1).foregroundStyle(Color.ink)
                            Text("historia.")
                                .font(BT.displayLarge).foregroundStyle(Color.sand)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)

                // Tarjeta de invitación
                VStack(alignment: .leading, spacing: 0) {

                    // Encabezado de tarjeta
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.sandLight)
                                .frame(width: 44, height: 44)
                            Image(systemName: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Color.sand)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tu historia viaja contigo")
                                .font(BT.footnoteBold)
                                .foregroundStyle(Color.ink)
                            Text("Crea tu perfil para que Buddy recuerde cada parte del camino.")
                                .font(BT.caption1)
                                .foregroundStyle(Color.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, Spacing.lg)

                    Divider().overlay(Color.border)
                        .padding(.bottom, Spacing.lg)

                    // Beneficios
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        anonymousBenefit(icon: "mappin",
                                         title: "Tus viajes",
                                         subtitle: "Cada destino pasa a ser parte de tu historia.")
                        anonymousBenefit(icon: "camera",
                                         title: "Tus momentos",
                                         subtitle: "Las fotos y recuerdos que guardaste te siguen a donde vayas.")
                        anonymousBenefit(icon: "sparkles",
                                         title: "Tus stickers",
                                         subtitle: "Recuerdos de los lugares que te recibieron.")
                        anonymousBenefit(icon: "person.2",
                                         title: "Tu perfil de Buddy",
                                         subtitle: "Si decides ayudar a otros viajeros, puedes configurarlo desde aquí.")
                    }
                    .padding(.bottom, Spacing.xl)

                    // CTA primario
                    Button {
                        Haptic.medium()
                        identityMode = .newUser
                    } label: {
                        Text("Crear mi perfil")
                            .font(BT.footnoteBold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color.ink)
                            .foregroundStyle(Color.inkInverse)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.bottom, Spacing.sm)

                    // CTA secundario
                    Button {
                        Haptic.light()
                        identityMode = .login
                    } label: {
                        Text("Ya tengo una cuenta")
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.lg)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.border, lineWidth: 1))
                .padding(.horizontal, Spacing.edge)

                // Microcopy tranquilizador
                Text("Nombre y teléfono. Nada más.")
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.sm)
            }
        }
        .background(Color.canvas)
    }

    private func anonymousBenefit(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.canvas)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sand)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
        }
    }

    private func saveBio() {
        guard let userId = Session.travelerId else { return }
        isSavingBio = true
        Task {
            do {
                try await APIClient.shared.updateUserBio(userId: userId, bio: bioText)
                await MainActor.run {
                    user = user.map { u in var copy = u; copy.bio = bioText; return copy }
                    editingBio = false
                    isSavingBio = false
                    Haptic.success()
                }
            } catch {
                await MainActor.run { isSavingBio = false }
            }
        }
    }

    private func uploadAvatar(item: PhotosPickerItem) async {
        print("🖼️ [uploadAvatar] iniciando…")

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            print("🖼️ [uploadAvatar] ❌ loadTransferable falló — formato no soportado")
            return
        }
        print("🖼️ [uploadAvatar] imagen original: \(data.count / 1024) KB")

        guard let uiImg = UIImage(data: data),
              let jpegData = uiImg.limitedToMaxDimension(400).jpegData(compressionQuality: 0.85) else {
            print("🖼️ [uploadAvatar] ❌ compresión JPEG falló")
            return
        }
        print("🖼️ [uploadAvatar] JPEG comprimido: \(jpegData.count / 1024) KB — enviando a backend…")

        await MainActor.run { isUploadingAvatar = true }
        do {
            let url = try await APIClient.shared.uploadAvatar(imageData: jpegData)
            print("🖼️ [uploadAvatar] ✅ \(url.suffix(60))")
            await MainActor.run {
                user = user.map { u in var copy = u; copy.avatarUrl = url; return copy }
                isUploadingAvatar = false
                Haptic.success()
            }
        } catch {
            print("🖼️ [uploadAvatar] ❌ \(error)")
            await MainActor.run { isUploadingAvatar = false }
        }
    }

    private func loadProfile(forceRefresh: Bool = false) async {
        let tid  = TravelerService.shared.travelerId?.prefix(8) ?? "nil"
        let ttok = TravelerService.shared.token.map { String($0.prefix(16)) + "…" } ?? "nil"
        let atok = AuthService.shared.accessToken.map { String($0.prefix(16)) + "…" } ?? "nil"
        print("👤 [YoView] loadProfile — travelerId=\(tid) travelerToken=\(ttok) authToken=\(atok) hasSession=\(Session.hasSession) isVerified=\(Session.isVerified) forceRefresh=\(forceRefresh)")

        guard Session.hasSession else {
            print("👤 [YoView] sin sesión — saliendo")
            isLoading = false; return
        }

        // Cache: si los datos tienen menos de 60 s y no hay forzado, no recargar.
        if !forceRefresh, let fetchedAt = lastFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 60, user != nil {
            print("👤 [YoView] perfil en caché (\(Int(Date().timeIntervalSince(fetchedAt)))s) — omitiendo recarga")
            isLoading = false; return
        }

        if user == nil { isLoading = true }

        // ── Fase 1: header ─────────────────────────────────────────────────────
        // Carga /users/me primero y muestra el header inmediatamente.
        // El contenido inferior (stickers, trips) se carga en fase 2.
        print("👤 [YoView] fetchCurrentUser → /users/me…")
        guard let me = try? await APIClient.shared.fetchCurrentUser() else {
            print("👤 [YoView] ❌ fetchCurrentUser falló — token inválido, sin red, o sin perfil en DB")
            isLoading = false; return
        }
        print("👤 [YoView] fetchCurrentUser ✅ → id=\(me.id.prefix(8)) name=\(me.fullName ?? "nil") role=\(me.role ?? "nil")")

        // Header visible: el usuario ve nombre, avatar y buddy card antes de que
        // terminen de cargar los stickers y los trips.
        user      = me
        isLoading = false

        // ── Fase 2: contenido inferior (paralelo) ──────────────────────────────
        print("👤 [YoView] cargando stickers/trips/buddy para id=\(me.id.prefix(8))…")
        async let stickersTask = try? APIClient.shared.fetchUserStickers(userId: me.id)
        async let tripsTask    = try? APIClient.shared.fetchUserTrips(userId: me.id)
        async let buddyTask    = try? APIClient.shared.fetchBuddyMe()
        async let destsTask    = try? APIClient.shared.fetchDestinations()

        let (s, tp, b, d) = await (stickersTask, tripsTask, buddyTask, destsTask)
        print("👤 [YoView] datos cargados — stickers=\(s?.count ?? 0) trips=\(tp?.items.count ?? 0) hasMore=\(tp?.hasMore ?? false) buddy=\(b?.isBuddy == true ? "sí" : "no") isBuddy=\(b?.profile?.verificationStatus ?? "no-profile")")

        stickers        = s ?? []
        journeys        = tp?.items ?? []
        tripsNextCursor = tp?.nextCursor
        tripsHasMore    = tp?.hasMore ?? false
        buddyMe         = b
        destinations    = d ?? []
        lastFetchedAt   = Date()

        await routeStore.syncCollectedStickers(userStickers: stickers)
    }

    private func loadMoreTrips() async {
        guard tripsHasMore, !isLoadingMoreTrips, let userId = user?.id else { return }
        print("👤 [YoView] loadMoreTrips — cursor=\(tripsNextCursor ?? "nil")")
        isLoadingMoreTrips = true
        defer { isLoadingMoreTrips = false }
        guard let page = try? await APIClient.shared.fetchUserTrips(userId: userId, cursor: tripsNextCursor) else { return }
        journeys        += page.items
        tripsNextCursor  = page.nextCursor
        tripsHasMore     = page.hasMore
        print("👤 [YoView] loadMoreTrips ✅ — +\(page.items.count) trips totalNow=\(journeys.count)")
    }

    /// Crea el perfil de buddy del usuario y refresca la sección.
    private func becomeBuddy() async {
        guard !isBecomingBuddy else { return }
        isBecomingBuddy = true
        defer { isBecomingBuddy = false }
        do {
            let result = try await APIClient.shared.becomeBuddy()
            await MainActor.run {
                buddyMe = result
                Haptic.success()
            }
        } catch {
            await MainActor.run { Haptic.error() }
        }
    }

    private func memberSinceLabel(date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_PE")
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date)
    }

    private func shortDateFromDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_PE")
        df.dateFormat = "d MMM"
        return df.string(from: date)
    }
}

// MARK: – JOURNEY CARD (list style, kept for other views)

struct JourneyCard: View {
    let journey: APIJourney

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CachedImage(urlString: journey.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    gradientFallback
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let dest = journey.destination {
                        Text(dest.city)
                            .font(BT.displayMedium)
                            .foregroundStyle(.white)
                    }
                }
                .padding(Spacing.md)
            }
            .frame(height: 160)
            .clipped()

            HStack {
                Text(journey.title ?? "viaje sin título")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "heart").font(.system(size: 11))
                    Text("\(journey.likesCount ?? 0)").font(BT.caption1)
                }
                .foregroundStyle(Color.inkMuted)
            }
            .padding(Spacing.md)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.bottom, Spacing.md)
    }

    private var gradientFallback: some View {
        LinearGradient(colors: [Color.tealDeep, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: – STICKER CIRCLE (legacy)

struct StickerCircle: View {
    let symbol: String
    let unlocked: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(unlocked ? Color.sandLight : Color.canvas)
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(
                    unlocked ? Color.sand.opacity(0.35) : Color.inkMuted.opacity(0.12),
                    lineWidth: 1.5
                ))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(unlocked ? Color.sand : Color.inkMuted.opacity(0.25))
        }
    }
}

// MARK: - Trip grid cell (first memoir thumbnail)

struct TripGridCell: View {
    let journey: APIJourney
    @State private var thumbUrl: String? = nil
    @State private var localThumb: UIImage? = nil

    var body: some View {
        // Celda cuadrada: Color.clear define el layout, la imagen solo rellena
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = localThumb {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                } else {
                    CachedImage(urlString: thumbUrl ?? journey.destination?.coverUrl) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        LinearGradient(colors: [Color.tealDeep, Color.teal],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
            // Etiqueta para los viajes privados (no publicados a la comunidad)
            .overlay(alignment: .topLeading) {
                if journey.isPublic == false {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                        Text("Privado").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(6)
                }
            }
        .clipped()
        .contentShape(Rectangle())
        .task {
            // Usa los datos ya cargados por el endpoint de trips — sin requests adicionales.
            // pageThumbs viene de feed_trip_json; coverUrl es el fallback del destino.
            // fetchJourneyPages solo se llama al abrir el detalle del trip, no desde la grilla.
            if let first = journey.pageThumbs?.first {
                thumbUrl = first; return
            }
            if journey.coverUrl != nil {
                thumbUrl = journey.coverUrl; return
            }
            // Fallback local — disco, sin red
            let jId = journey.id
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let localPages = MemoirPersistence.shared.load(journeyId: jId)
                guard let filename = localPages.first?.thumbnailFileName else { return nil }
                return MemoirPersistence.shared.loadThumbnail(filename, journeyId: jId)
            }.value
            if let img { localThumb = img }
        }
    }
}

// MARK: – BuddyNavRow (fila compacta en el perfil)

private struct BuddyNavRow: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]

    @State private var resolvedZoneName: String? = nil

    private var badgeLabel: String {
        switch profile.verificationStatus {
        case "approved": return "Verificado"
        case "pending":  return "En revisión"
        default:         return "Revisión"
        }
    }
    private var badgeColor: Color {
        switch profile.verificationStatus {
        case "approved": return Color.teal
        case "pending":  return Color.warningAmber
        default:         return Color.inkMuted
        }
    }
    private var sublabel: String {
        var parts: [String] = []
        if profile.verificationStatus == "approved" {
            let n = profile.totalHelps ?? 0
            parts.append(n == 1 ? "1 ayuda" : "\(n) ayudas")
        } else {
            parts.append("Verificaremos tu perfil pronto")
        }
        if let zone = resolvedZoneName { parts.append(zone) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Perfil de Buddy")
                    .font(BT.callout)
                    .foregroundStyle(Color.ink)
                Text(sublabel)
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Badge de estado
            Text(badgeLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(badgeColor.opacity(0.1))
                .clipShape(Capsule())

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.inkMuted.opacity(0.5))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
        .onAppear { resolveZone() }
    }

    private func resolveZone() {
        guard let id = profile.activeZoneIds?.first ?? profile.destinationIds?.first else { return }
        if let local = destinations.first(where: { $0.id == id }) { resolvedZoneName = local.name; return }
        if let dest = profile.destination, dest.id == id { resolvedZoneName = dest.name; return }
        Task {
            let dest = try? await APIClient.shared.fetchDestination(id: id)
            await MainActor.run { resolvedZoneName = dest?.name }
        }
    }
}

// MARK: – BuddyStatusCard (legacy — reemplazada por BuddyNavRow + BuddyProfileView)

private struct BuddyStatusCard: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]  // lista inicial (puede estar vacía; el picker busca on-demand)
    let onUpdated: (APIBuddyMe) -> Void

    @State private var specialties: Set<String>
    @State private var savingSpecs  = false
    @State private var savingZone   = false
    @State private var showZonePicker = false
    // Nombre de la zona seleccionada (se resuelve al mostrar la card)
    @State private var selectedZoneName: String? = nil

    init(profile: APIBuddyMeProfile, destinations: [APIDestination], onUpdated: @escaping (APIBuddyMe) -> Void) {
        self.profile      = profile
        self.destinations = destinations
        self.onUpdated    = onUpdated
        _specialties = State(initialValue: Set(profile.specialties ?? []))
    }

    private static let specialtyOptions: [(key: String, label: String)] = [
        ("transport", "Cómo llegar"), ("food", "Comer"),
        ("translation", "Traducir"), ("activities", "Qué hacer"),
        ("accommodation", "Alojamiento"), ("emergency", "Seguridad"),
    ]

    private var verificationColor: Color {
        switch profile.verificationStatus {
        case "approved": return Color.teal
        case "pending":  return Color.warningAmber
        default:         return Color.inkMuted
        }
    }
    private var verificationLabel: String {
        switch profile.verificationStatus {
        case "approved": return "Buddy verificado"
        case "pending":  return "Verificación pendiente"
        default:         return "En revisión"
        }
    }
    private var verificationIcon: String {
        switch profile.verificationStatus {
        case "approved": return "checkmark.seal.fill"
        case "pending":  return "hourglass"
        default:         return "shield"
        }
    }
    private var statusSubtitle: String {
        profile.verificationStatus == "pending"
            ? "Revisaremos tu perfil pronto"
            : "\(profile.totalHelps ?? 0) ayudas"
    }

    private var selectedZoneId: String? {
        profile.activeZoneIds?.first ?? profile.destinationIds?.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // ── Estado ──
            HStack(spacing: 10) {
                Image(systemName: verificationIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(verificationColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verificationLabel)
                        .font(BT.headline)
                        .foregroundStyle(verificationColor)
                    Text(statusSubtitle)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer()
            }
            .padding(Spacing.md)
            .background(verificationColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // ── En qué ayudas (especialidades editables) ──
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("EN QUÉ AYUDAS")
                        .font(BT.eyebrow).tracking(1.5)
                        .foregroundStyle(Color.inkMuted)
                    if savingSpecs { ProgressView().controlSize(.small) }
                }
                FlowLayout(spacing: 6) {
                    ForEach(BuddyStatusCard.specialtyOptions, id: \.key) { opt in
                        let on = specialties.contains(opt.key)
                        Button { toggleSpecialty(opt.key) } label: {
                            Text(opt.label)
                                .font(BT.caption1)
                                .fontWeight(on ? .semibold : .regular)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(on ? Color.teal.opacity(0.12) : Color.surface)
                                .foregroundStyle(on ? Color.teal : Color.inkMuted)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Color.teal : Color.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // ── Mi zona — botón que abre sheet de búsqueda ──
            Button { showZonePicker = true } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.1))
                            .frame(width: 34, height: 34)
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.teal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MI ZONA")
                            .font(BT.caption1).tracking(1)
                            .foregroundStyle(Color.inkMuted)
                        Text(selectedZoneName ?? "Elegir dónde operas")
                            .font(BT.callout)
                            .foregroundStyle(selectedZoneName == nil ? Color.inkMuted : Color.ink)
                            .lineLimit(1)
                    }
                    Spacer()
                    if savingZone {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(savingZone)
            .sheet(isPresented: $showZonePicker) {
                DestinationPickerSheet(selectedId: selectedZoneId) { picked in
                    Task { await saveZone(picked.id, name: picked.name) }
                }
            }
        }
        .onAppear { resolveZoneName() }
        .onChange(of: profile.activeZoneIds) { _, _ in resolveZoneName() }
    }

    // Intenta resolver el nombre desde la lista local; si no está, lo busca en la API.
    private func resolveZoneName() {
        guard let id = selectedZoneId else { selectedZoneName = nil; return }
        if let local = destinations.first(where: { $0.id == id }) {
            selectedZoneName = local.name; return
        }
        if let dest = profile.destination, dest.id == id {
            selectedZoneName = dest.name; return
        }
        Task {
            let dest = try? await APIClient.shared.fetchDestination(id: id)
            await MainActor.run { selectedZoneName = dest?.name }
        }
    }

    private func toggleSpecialty(_ key: String) {
        Haptic.select()
        let previous = specialties
        if specialties.contains(key) { specialties.remove(key) } else { specialties.insert(key) }
        Task { await saveSpecialties(revertTo: previous) }
    }

    private func saveSpecialties(revertTo previous: Set<String>) async {
        savingSpecs = true
        defer { savingSpecs = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(specialties: Array(specialties))
            onUpdated(updated)
        } catch {
            specialties = previous
            Haptic.error()
        }
    }

    private func saveZone(_ id: String, name: String) async {
        savingZone = true
        selectedZoneName = name  // optimistic
        defer { savingZone = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(destinationIds: [id], activeZoneIds: [id])
            onUpdated(updated)
            Haptic.success()
        } catch {
            resolveZoneName()  // revertir
            Haptic.error()
        }
    }
}

// MARK: – DestinationPickerSheet

struct DestinationPickerSheet: View {
    let selectedId: String?
    let onSelected: (APIDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query    = ""
    @State private var results  : [APIDestination] = []
    @State private var total    = 0
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>? = nil

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Barra de búsqueda
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkMuted)
                        .font(.system(size: 15))
                    TextField("Buscar ciudad o destino…", text: $query)
                        .font(BT.callout)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)

                Divider()

                if isLoading && results.isEmpty {
                    Spacer()
                    ProgressView().tint(Color.inkMuted)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Color.inkMuted)
                        Text(query.isEmpty ? "Sin destinos disponibles" : "Sin resultados para \"\(query)\"")
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(results) { dest in
                            Button {
                                onSelected(dest)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color.teal.opacity(0.1)).frame(width: 36, height: 36)
                                        Image(systemName: "location.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.teal)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dest.name)
                                            .font(BT.callout)
                                            .foregroundStyle(Color.ink)
                                        if dest.city != dest.name {
                                            Text(dest.city)
                                                .font(BT.caption1)
                                                .foregroundStyle(Color.inkMuted)
                                        }
                                    }
                                    Spacer()
                                    if dest.id == selectedId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.teal)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Carga más al llegar al final
                            .onAppear {
                                if dest.id == results.last?.id && results.count < total {
                                    loadMore()
                                }
                            }
                        }
                        if isLoading {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Elegir zona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .onAppear { search() }
        .onChange(of: query) { _, _ in scheduleSearch() }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // debounce 300ms
            guard !Task.isCancelled else { return }
            await MainActor.run { search() }
        }
    }

    private func search() {
        Task {
            isLoading = true
            let (items, t) = (try? await APIClient.shared.searchDestinations(query: query, limit: pageSize, offset: 0)) ?? ([], 0)
            results = items
            total   = t
            isLoading = false
        }
    }

    private func loadMore() {
        guard !isLoading, results.count < total else { return }
        Task {
            isLoading = true
            let (items, t) = (try? await APIClient.shared.searchDestinations(query: query, limit: pageSize, offset: results.count)) ?? ([], total)
            results.append(contentsOf: items)
            total   = t
            isLoading = false
        }
    }
}


