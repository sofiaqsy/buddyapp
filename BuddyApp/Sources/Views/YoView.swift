import SwiftUI
import PhotosUI
import AuthenticationServices
import CoreLocation
import MapKit

// MARK: – YO (PROFILE)


struct YoView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var locationService: LocationService
    @State private var user: APIUser? = nil
    @State private var stickers: [APIUserSticker] = []
    @State private var journeys: [APIJourney] = []
    /// Lugares que recomienda — sección aparte de los viajes propios.
    @State private var shares: [APIPlaceCard] = []
    @State private var showCompartirLugar = false
    /// Journey creado por la sheet, en espera del onDismiss para recargar. El
    /// perfil no puede refrescar antes: la sheet sigue arriba y el usuario
    /// vería la lista moverse debajo.
    @State private var pendingShareJourney: APIJourney? = nil
    /// Recomendación recién creada que se abre en el editor para ponerle fotos.
    @State private var editingShareJourney: APIJourney? = nil
    @State private var tripsNextCursor: String? = nil
    @State private var tripsHasMore: Bool = false
    @State private var isLoadingMoreTrips: Bool = false
    @State private var selectedStory: APIJourney? = nil   // detalle de publicación
    /// Long-press en un trip del grid → confirmar eliminación de la publicación.
    @State private var deletePublicationTarget: APIJourney? = nil
    @State private var isLoading = true
    @State private var editingBio = false
    @State private var bioText = ""
    @State private var isSavingBio = false
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var bioSaveFailed      = false
    @State private var avatarUploadFailed = false
    @State private var buddyMe: APIBuddyMe? = nil
    @State private var destinations: [APIDestination] = []
    @State private var showBecomeBuddyConfirm = false
    @State private var isBecomingBuddy = false
    @State private var showNameSheet = false
    @State private var suggestedNameForProfile = ""
    @State private var profileSocialLoading = false
    @State private var profileSocialError: String? = nil
    // Guardia de logout: si hay apoyo activo no se puede cerrar sesión sin confirmar
    @State private var showActiveHelpLogoutAlert = false
    // Caché en memoria: evita recargar el perfil en cada cambio de tab
    @State private var lastFetchedAt: Date? = nil
    // Previene llamadas concurrentes y rapid-retries (Task restarts por cambios de layout)
    @State private var isLoadingProfile = false
    @State private var lastFetchAttemptedAt: Date? = nil
    // Demanda sin cubrir en la zona actual — invita a postular como buddy ahí.
    @State private var unattendedCount = 0
    @State private var unattendedPlaceName = ""

    /// Push, no modal: un push dentro de este stack respeta la barra de tabs
    /// de la app; un .fullScreenCover la tapa siempre.
    @State private var navPath = NavigationPath()
    @ObservedObject private var accounts = AccountStore.shared

    var body: some View {
        NavigationStack(path: $navPath) {
            Group {
                // ── Modo negocio (prototipo local) ──
                if authState.isLoggedIn, let biz = accounts.active {
                    BusinessHomeView(
                        business: biz,
                        onLinkBusiness: { navPath.append(LinkBusinessRoute()) },
                        onSwitchAccount: { navPath.append(AccountsRoute()) },
                        onLogout: { requestLogout() }
                    )
                // ── Estado anónimo ──
                } else if !authState.isLoggedIn {
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
                                    // Mismo encabezado que Trips y Conexiones.
                                    // Como Instagram: el título abre "Tus cuentas".
                                    if accounts.businesses.isEmpty {
                                        Text("Tu perfil")
                                            .font(.system(.largeTitle).weight(.bold))
                                            .foregroundStyle(Color.brand)
                                            .accessibilityAddTraits(.isHeader)
                                    } else {
                                        NavigationLink(value: AccountsRoute()) {
                                            HStack(spacing: 6) {
                                                Text("Tu perfil")
                                                    .font(.system(.largeTitle).weight(.bold))
                                                    .foregroundStyle(Color.brand)
                                                    .accessibilityAddTraits(.isHeader)
                                                Image(systemName: "chevron.down")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundStyle(Color.brand)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Cambiar de cuenta")
                                    }
                                }
                                Spacer()
                                Menu {
                                    // Keyla, 20 Nov 2026: crear/vincular vive en "⋯";
                                    // "Cambiar de cuenta" solo si hay otra cuenta.
                                    // Con cuentas de negocio, "Cambiar de cuenta" va primero
                                    // y "Crear o vincular" segundo (Keyla, 20 Nov 2026).
                                    if !accounts.businesses.isEmpty {
                                        Button {
                                            navPath.append(AccountsRoute())
                                        } label: {
                                            Label("Cambiar de cuenta", systemImage: "arrow.left.arrow.right")
                                        }
                                    }
                                    Button {
                                        navPath.append(LinkBusinessRoute())
                                    } label: {
                                        Label("Crear o vincular negocio", systemImage: "storefront")
                                    }
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
                                .accessibilityLabel("Opciones de cuenta")
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

                            // Mis trips: el registro y el trip en curso viven aquí
                            // (Keyla, 19 Nov 2026), no en la pestaña Comunidad.
                            MyTripsEntryCard()
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)

                            // Sin "Perfil de Buddy" ni invitaciones a ser buddy en Yo
                            // (Keyla, 20 Nov 2026: no es necesario).

                            // Visible si puede aportar (necesita la entrada) o
                            // si ya aportó (no se le esconde lo suyo aunque su
                            // verificación haya cambiado después).
                            if canRecommendPlaces || !shares.isEmpty {
                                sharesSection
                                    .padding(.top, Spacing.xl)
                            }

                            tripsSection
                                .padding(.top, Spacing.xl)
                        }
                        .padding(.bottom, Spacing.xl).safeAreaPadding(.bottom)
                    }
                    .refreshable { await loadProfile(forceRefresh: true) }
                    .background(Color.canvas)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // Detalle de la publicación — mismo visor que en Home
            .fullScreenCover(item: $selectedStory) { journey in
                StoryViewerSheet(journey: journey)
            }
            .confirmationDialog(
                "¿Eliminar esta publicación?",
                isPresented: Binding(
                    get: { deletePublicationTarget != nil },
                    set: { if !$0 { deletePublicationTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Eliminar publicación", role: .destructive) {
                    if let t = deletePublicationTarget { deletePublication(t) }
                    deletePublicationTarget = nil
                }
                Button("Cancelar", role: .cancel) { deletePublicationTarget = nil }
            } message: {
                Text("Se quitará de tu perfil y del feed de la comunidad. No se puede deshacer.")
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
            .sheet(isPresented: $showNameSheet) {
                IdentitySheet(purpose: .profile,
                              suggestedName: suggestedNameForProfile,
                              startAtName: true) {
                    Task { await loadProfile(forceRefresh: true) }
                }
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
            .alert("No se pudo guardar la bio", isPresented: $bioSaveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Tu bio no se guardó. Verifica tu conexión e inténtalo de nuevo.")
            }
            .alert("No se pudo subir la foto", isPresented: $avatarUploadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Tu foto de perfil no se actualizó. Verifica tu conexión e inténtalo de nuevo.")
            }
            .onChange(of: router.pendingMyTrips, initial: true) { _, pending in
                guard pending else { return }
                router.pendingMyTrips = false
                navPath = NavigationPath()
                navPath.append(MyTripsRoute())
            }
            .navigationDestination(for: AccountsRoute.self) { _ in
                AccountSwitcherView(personName: user?.fullName ?? "Tú",
                                    personAvatar: user?.avatarUrl) { navPath = NavigationPath() }
            }
            .navigationDestination(for: BusinessLocationRoute.self) { route in
                ScrollView {
                    BusinessProfileEditor(businessId: route.businessId, isLinked: true, hasProducts: true,
                                          locationId: route.locationId)
                        .padding(.horizontal, Spacing.edge).padding(.top, Spacing.md).padding(.bottom, 140)
                }
                .background(Color.canvas)
                .navigationTitle(AccountStore.shared.businesses.first { $0.id == route.businessId }?
                    .locations?.first { $0.id == route.locationId }?.name ?? "Sede")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: BusinessLocationPickRoute.self) { route in
                BusinessLocationPicker(businessId: route.businessId)
            }
            .navigationDestination(for: FincasProductRoute.self) { route in
                FincasProductEditView(route: route)
            }
            .navigationDestination(for: LinkBusinessRoute.self) { _ in
                LinkBusinessView { navPath = NavigationPath() }
            }
            .navigationDestination(for: RegisterBusinessRoute.self) { _ in
                RegisterBusinessView { navPath = NavigationPath() }
            }
            .navigationDestination(for: MyTripsRoute.self) { _ in
                TripsView(embedded: true, externalPath: $navPath)
                    .environmentObject(authState)
                    .environmentObject(routeStore)
            }
            .navigationDestination(for: APIPlaceCard.self) { place in
                PlaceGuideMapSheet(place: place)
            }
            .sheet(isPresented: $showCompartirLugar, onDismiss: {
                // El journey nace con trip_id=null y sin publicar; acá solo se
                // recarga para que el lugar aparezca en la sección. Publicarlo
                // sigue siendo cosa del editor, igual que desde Tu trip.
                // Antes solo recargaba el perfil: el lugar quedaba creado pero
                // sin fotos, así que no aparecía en "Lugares que recomiendas" y
                // parecía que no había pasado nada. Ahora se abre el editor,
                // igual que "Añadir foto" en el mapa. La recarga llega sola con
                // .journeyPublished cuando termina de subir las fotos.
                guard let nuevo = pendingShareJourney else { return }
                pendingShareJourney = nil
                editingShareJourney = nuevo
            }) {
                CompartirLugarSheet { journey in
                    dlog("🌍 [YoView] compartido creado journey=\(journey.id)")
                    pendingShareJourney = journey
                }
            }
        }
        .fullScreenCover(item: $editingShareJourney) { journey in
            // publishesOnSave: no hay un paso posterior de "publicar el trip";
            // guardar es lo que deja la recomendación visible.
            TripEditorSheet(journey: journey, initialPage: -1, publishesOnSave: true) {}
        }
        // El lugar ya se creó (CompartirLugarSheet ya cerró su propio spinner
        // al llamar onCreated), pero el editor todavía no se presenta: eso
        // pasa recién en el onDismiss de arriba, después de que la animación
        // de cierre de esa hoja termine. Sin nada acá, la pantalla de Yo
        // queda un instante sin decir nada — como si el toque no hubiera
        // hecho nada.
        .overlay {
            if pendingShareJourney != nil {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: pendingShareJourney != nil)
        .task { await loadProfile() }
        .task { await loadUnattendedDemand() }
        .onReceive(NotificationCenter.default.publisher(for: .stickerUnlocked)) { _ in
            Task { await loadProfile(forceRefresh: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
            Task { await loadProfile(forceRefresh: true) }
        }
        // forceRefresh porque el guard de 60s ignoraría la recarga: borrar una
        // foto y volver al perfil pasa en segundos.
        .onReceive(NotificationCenter.default.publisher(for: .placePhotosChanged)) { _ in
            Task { await loadProfile(forceRefresh: true) }
        }
    }

    // MARK: – Profile Header (avatar + stats)

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            // Avatar — tapeable para cambiar foto
            PhotosPicker(selection: $avatarItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.paleSage)
                        .frame(width: 88, height: 88)
                    CachedImage(urlString: user?.avatarUrl) { img in
                        img.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.brand)
                            .frame(width: 88, height: 88) // ancla el placeholder al mismo tamaño
                    }
                    if isUploadingAvatar {
                        Circle().fill(.black.opacity(0.4)).frame(width: 88, height: 88)
                        ProgressView().tint(.white)
                    }
                    // Badge editar
                    ZStack {
                        Circle().fill(Color.brand).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.canvas, lineWidth: 2))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.inkInverse)
                    }
                    .offset(x: 2, y: 2)
                }
                .frame(width: 96, height: 96) // ancla el ZStack entero para que el badge no desplace el layout
            }
            .accessibilityLabel("Cambiar foto de perfil")
            .accessibilityHint("Abre el selector de fotos")
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item: item) }
            }

            // Identidad — el nombre lidera, luego la narrativa
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.fullName ?? "Tú")
                    .font(.system(.title2).weight(.bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let since = user?.memberSince {
                    Text("Viajando desde \(memberSinceLabel(date: since))")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statPills: [String] {
        ProfileStatPills.make(trips: journeys.count, places: shares.count, helps: buddyMe?.profile?.totalHelps)
    }

    private var metaLine: String {
        let trips = journeys.count
        let tripsLabel = trips == 1 ? "1 trip" : "\(trips) trips"
        return [tripsLabel].compactMap { $0 }.joined(separator: " · ")
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
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.brand, lineWidth: 1.5))

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
                        .background(Color.brand)
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 32, height: 32)
                            .background(Color.sageTint, in: Circle())
                    }
                    .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .cardShadow()
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
            HStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 44, height: 44)
                    .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ser Buddy en mi ciudad")
                        .font(.system(.headline).weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text("Ayuda a quien llega por primera vez")
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 32, height: 32)
                    .background(Color.sageTint, in: Circle())
            }
            .padding(14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .cardShadow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(isBecomingBuddy)
    }

    // MARK: – CTA con demanda real — reemplaza a becomeBuddyCTA cuando hay
    // solicitudes recientes sin buddy en la zona actual del usuario.

    private var unattendedDemandCTA: some View {
        Button {
            showBecomeBuddyConfirm = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(unattendedCount == 1
                         ? "1 persona buscó un buddy en \(unattendedPlaceName)"
                         : "\(unattendedCount) personas buscaron un buddy en \(unattendedPlaceName)")
                        .font(BT.footnoteBold)
                        .foregroundStyle(.white)
                    Text("Sé el primer buddy aquí")
                        .font(BT.caption1)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.brand)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(isBecomingBuddy)
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
        SectionTitle(title: title, count: count)
            .padding(.horizontal, Spacing.edge)
    }

    // MARK: – Contribuciones como buddy (carrusel)
    // Lugares que documentó para la comunidad. Aparte de TRIPS a propósito: son
    // aportes al catálogo, no viajes suyos, y cada uno es un sitio concreto en
    // vez de la narración de un recorrido.
    /// Recomendar un lugar no es publicar: es meterlo al catálogo que ve toda
    /// la comunidad. El backend ya lo exige —POST /places/propose rechaza si
    /// verification_status != 'approved'— y acá se refleja esa misma regla, así
    /// que nadie llega al final del flujo para recibir un error. "approved" y
    /// no isBuddy a secas: is_buddy es true con el perfil creado aunque siga
    /// pendiente de revisión.
    /// Desde 20 Nov 2026 cualquier viajero con sesión recomienda lugares (el
    /// backend acepta a todo verificado; los lugares nuevos se revisan igual).
    private var canRecommendPlaces: Bool { authState.isLoggedIn }

    private var sharesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("LUGARES QUE RECOMIENDAS", count: shares.count)

            ScrollView(.horizontal, showsIndicators: false) {
                // 3 como la grilla de TRIPS, y no solo entre el "+" y su vecino:
                // una separación distinta en un único hueco se lee como error de
                // maquetado, no como intención. Con el mismo valor las dos
                // secciones del perfil se leen como una sola colección.
                HStack(spacing: 12) {
                    // Siempre primero: es la acción, no un elemento más de la
                    // colección. Al final habría que arrastrar toda la lista
                    // para encontrarla, y crece con cada lugar que se suma.
                    if canRecommendPlaces { addPlaceCard }

                    ForEach(shares, id: \.id) { place in
                        // En el perfil el pie es cuántas fotos aportó a ese
                        // lugar; los buddies del destino no vienen al caso aquí.
                        NearbyPlaceCard(place: place, subtitleOverride: place.photoLabel) {
                            navPath.append(place)
                        }
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    /// Card de alta, con las medidas de NearbyPlaceCard para que la fila no se
    /// desnivele. Blanca y con borde punteado: se lee como un hueco por llenar
    /// y no como un lugar más ya aportado.
    private var addPlaceCard: some View {
        Button {
            Haptic.medium()
            showCompartirLugar = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 44, height: 44)
                    .background(Color.sageTint, in: Circle())
                Text("Añadir lugar")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.brand)
            }
            .frame(width: 132, height: 158)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Color.sage, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Trips grid

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Trips publicados", count: journeys.count)

            if journeys.isEmpty {
                // Empty state — invita a la acción, no lamenta el vacío
                Button {
                    router.openMyTrips()
                } label: {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 48, height: 48)
                            .background(Color.paleSage, in: Circle())
                        Text("Tu primer trip te espera")
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .cardShadow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.edge)
            } else {
                ProfileTripsGrid(
                    journeys: journeys,
                    hasMore: tripsHasMore,
                    onTap: { selectedStory = $0 },
                    onDelete: { deletePublicationTarget = $0 },
                    onReachEnd: {
                        guard !isLoadingMoreTrips else { return }
                        Task { await loadMoreTrips() }
                    }
                )
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
        // Los negocios vinculados son de esta persona: no quedan en el teléfono.
        AccountStore.shared.activeBusinessId = nil
        AccountStore.shared.businesses = []
        FincasAuth.clear()
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
                        Text("Tu perfil")
                            .font(.system(.largeTitle).weight(.bold))
                            .foregroundStyle(Color.brand)
                            .accessibilityAddTraits(.isHeader)
                        Text("Tu perfil, tus viajes y tus momentos")
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted)
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
                        Image(systemName: "person")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.brand)
                            .frame(width: 44, height: 44)
                            .background(Color.paleSage, in: Circle())
                            .accessibilityHidden(true)
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
                        anonymousBenefit(icon: "suitcase",
                                         title: "Tus viajes",
                                         subtitle: "Cada destino pasa a ser parte de tu historia.")
                        anonymousBenefit(icon: "camera",
                                         title: "Tus momentos",
                                         subtitle: "Las fotos y recuerdos que guardaste te siguen a donde vayas.")
                        anonymousBenefit(icon: "person.2",
                                         title: "Tu perfil de Buddy",
                                         subtitle: "Si decides ayudar a otros viajeros, puedes configurarlo desde aquí.")
                    }
                    .padding(.bottom, Spacing.md)

                    Divider().overlay(Color.border)
                        .padding(.bottom, Spacing.md)

                    Text("Continúa con")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, Spacing.sm)

                    // Apple
                    SignInWithAppleButton(.signIn, onRequest: { req in
                        req.requestedScopes = [.fullName, .email]
                    }, onCompletion: { result in
                        handleProfileAppleResult(result)
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50).clipShape(Capsule())
                    .opacity(profileSocialLoading ? 0.5 : 1)
                    .disabled(profileSocialLoading)
                    .padding(.bottom, Spacing.sm)

                    // Google
                    Button(action: { handleProfileSignIn(provider: GoogleProvider()) }) {
                        ZStack {
                            if profileSocialLoading {
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
                        .background(Color.canvas).clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
                    .opacity(profileSocialLoading ? 0.7 : 1)
                    .disabled(profileSocialLoading)

                    if let err = profileSocialError {
                        Text(err).font(BT.caption1).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, Spacing.xs)
                    }

                    Text("Al continuar confirmas que tienes **18+ años** y aceptas nuestros **términos, privacidad** y **código de conducta**")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.sm)
                }
                .padding(Spacing.lg)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                .padding(.horizontal, Spacing.edge)
            }
        }
        .background(Color.canvas)
    }

    // MARK: – Inline auth (anonymousState)

    private func handleProfileAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            let nsErr = err as NSError
            if nsErr.code != ASAuthorizationError.canceled.rawValue {
                profileSocialError = "Error con Apple."
            }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                profileSocialError = "No se pudo leer el token de Apple."
                return
            }
            var name: String? = nil
            if let fn = cred.fullName {
                let j = [fn.givenName, fn.familyName].compactMap { $0 }
                    .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !j.isEmpty { name = j }
            }
            handleProfileSocialSignIn(credential: IdentityCredential(
                provider: .apple, identityToken: token, email: cred.email, fullName: name
            ))
        }
    }

    private func handleProfileSignIn(provider: IdentityProvider) {
        profileSocialLoading = true; profileSocialError = nil
        Task {
            do {
                let result = try await AuthService.shared.signIn(with: provider)
                await finishProfileAuth(result)
            } catch {
                let nsErr = error as NSError
                await MainActor.run {
                    profileSocialLoading = false
                    let cancelCodes = [ASAuthorizationError.canceled.rawValue, 1]
                    if !cancelCodes.contains(nsErr.code) {
                        profileSocialError = "No se pudo iniciar sesión."
                    }
                }
            }
        }
    }

    private func handleProfileSocialSignIn(credential: IdentityCredential) {
        profileSocialLoading = true; profileSocialError = nil
        Task {
            do {
                let result = try await AuthService.shared._postToBackend(credential)
                await finishProfileAuth(result)
            } catch {
                await MainActor.run {
                    profileSocialLoading = false
                    profileSocialError = "No se pudo iniciar sesión."
                }
            }
        }
    }

    @MainActor
    private func finishProfileAuth(_ result: AuthResult) {
        profileSocialLoading = false
        let destination = AuthCoordinator.shared.handle(result)
        switch destination {
        case .home:
            authState.didAuthenticate()
            Task { await loadProfile(forceRefresh: true) }
        case .needsProfileCompletion:
            let name = result.suggestedName ?? ""
            if name.trimmingCharacters(in: .whitespaces).count >= 2 {
                Task {
                    try? await AuthService.shared.completeProfileForSocialLogin(
                        fullName: name.trimmingCharacters(in: .whitespaces)
                    )
                    authState.didAuthenticate()
                    await loadProfile(forceRefresh: true)
                }
            } else {
                suggestedNameForProfile = name
                showNameSheet = true
            }
        }
    }

    private func anonymousBenefit(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Insignia de Inicio: forest sobre pale sage.
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.brand)
                .frame(width: 36, height: 36)
                .background(Color.paleSage, in: Circle())
                .accessibilityHidden(true)
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
                try await APIClient.shared.updateUserBio(travelerId: userId, bio: bioText)
                await MainActor.run {
                    user = user.map { u in var copy = u; copy.bio = bioText; return copy }
                    editingBio = false
                    isSavingBio = false
                    Haptic.success()
                }
            } catch {
                await MainActor.run { isSavingBio = false; bioSaveFailed = true }
            }
        }
    }

    private func uploadAvatar(item: PhotosPickerItem) async {
        dlog("🖼️ [uploadAvatar] iniciando…")

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            print("🖼️ [uploadAvatar] ❌ loadTransferable falló — formato no soportado")
            return
        }
        dlog("🖼️ [uploadAvatar] imagen original: \(data.count / 1024) KB")

        guard let uiImg = UIImage(data: data),
              let jpegData = uiImg.limitedToMaxDimension(400).jpegData(compressionQuality: 0.85) else {
            print("🖼️ [uploadAvatar] ❌ compresión JPEG falló")
            return
        }
        dlog("🖼️ [uploadAvatar] JPEG comprimido: \(jpegData.count / 1024) KB — enviando a backend…")

        await MainActor.run { isUploadingAvatar = true }
        do {
            let url = try await APIClient.shared.uploadAvatar(imageData: jpegData)
            dlog("🖼️ [uploadAvatar] ✅ \(url.suffix(60))")
            await MainActor.run {
                user = user.map { u in var copy = u; copy.avatarUrl = url; return copy }
                isUploadingAvatar = false
                Haptic.success()
            }
        } catch {
            print("🖼️ [uploadAvatar] ❌ \(error)")
            await MainActor.run { isUploadingAvatar = false; avatarUploadFailed = true }
        }
    }

    /// Elimina una publicación del perfil — optimista: se quita del grid al
    /// instante y el backend la despublica (cancelled + is_public=false),
    /// con lo que también desaparece del feed de la comunidad.
    private func deletePublication(_ journey: APIJourney) {
        journeys.removeAll { $0.id == journey.id }
        Haptic.success()
        Task {
            do { try await APIClient.shared.cancelJourney(journeyId: journey.id) }
            catch { print("❌ [deletePublication] \(error)") }
        }
    }

    /// Si el usuario no es buddy y tiene ubicación disponible, busca cuántas
    /// solicitudes recientes en su zona actual se quedaron sin buddy — para
    /// invitarlo a postular ahí mismo (unattendedDemandCTA).
    private func loadUnattendedDemand() async {
        guard buddyMe?.isBuddy != true else { return }
        guard let loc = locationService.userLocation else { return }
        do {
            let place = try await APIClient.shared.resolvePlace(
                lat: loc.coordinate.latitude, lng: loc.coordinate.longitude
            )
            guard let destinationId = place.destinationId else { return }
            let count = try await APIClient.shared.fetchUnattendedCount(destinationId: destinationId)
            guard count > 0 else { return }
            await MainActor.run {
                unattendedCount = count
                unattendedPlaceName = place.name
            }
        } catch {
            print("❌ [YoView] loadUnattendedDemand falló: \(error.localizedDescription)")
        }
    }

    private func loadProfile(forceRefresh: Bool = false) async {
        // Prevent concurrent calls and rapid-fire retries (SwiftUI may restart .task on layout changes)
        if !forceRefresh {
            if isLoadingProfile { return }
            if let lastAttempt = lastFetchAttemptedAt,
               Date().timeIntervalSince(lastAttempt) < 2 { return }
        }

        let tid  = TravelerService.shared.travelerId?.prefix(8) ?? "nil"
        // Solo si existe: ni siquiera el prefijo de un token va al log.
        let ttok = TravelerService.shared.token != nil ? "sí" : "no"
        let atok = AuthService.shared.accessToken != nil ? "sí" : "no"
        dlog("👤 [YoView] loadProfile — travelerId=\(tid) travelerToken=\(ttok) authToken=\(atok) hasSession=\(Session.hasSession) isVerified=\(Session.isVerified) forceRefresh=\(forceRefresh)")

        guard Session.hasSession else {
            dlog("👤 [YoView] sin sesión — saliendo")
            isLoading = false; return
        }

        // Cache: si los datos tienen menos de 60 s y no hay forzado, no recargar.
        if !forceRefresh, let fetchedAt = lastFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 60, user != nil {
            dlog("👤 [YoView] perfil en caché (\(Int(Date().timeIntervalSince(fetchedAt)))s) — omitiendo recarga")
            isLoading = false; return
        }

        isLoadingProfile = true
        lastFetchAttemptedAt = Date()
        defer { isLoadingProfile = false }

        if user == nil { isLoading = true }

        // ── Fase 1: header ─────────────────────────────────────────────────────
        // Carga /users/me primero y muestra el header inmediatamente.
        // El contenido inferior (stickers, trips) se carga en fase 2.
        // Retry once after a brief delay — backend may need a moment to create the user
        // record after social sign-in (Apple in particular has a propagation delay).
        dlog("👤 [YoView] fetchCurrentUser → /users/me…")
        var me: APIUser? = try? await APIClient.shared.fetchCurrentUser()
        if me == nil {
            dlog("👤 [YoView] fetchCurrentUser falló — reintentando en 1.5s…")
            try? await Task.sleep(for: .seconds(1.5))
            me = try? await APIClient.shared.fetchCurrentUser()
        }
        guard let me else {
            print("👤 [YoView] ❌ fetchCurrentUser falló — token inválido, sin red, o sin perfil en DB")
            isLoading = false; return
        }
        dlog("👤 [YoView] fetchCurrentUser ✅ → id=\(me.id.prefix(8)) name=\(me.fullName ?? "nil") role=\(me.role ?? "nil")")

        // Header visible: el usuario ve nombre, avatar y buddy card antes de que
        // terminen de cargar los stickers y los trips.
        user      = me
        isLoading = false

        // ── Fase 2: contenido inferior (paralelo) ──────────────────────────────
        dlog("👤 [YoView] cargando stickers/trips/buddy para id=\(me.id.prefix(8))…")
        async let stickersTask = try? APIClient.shared.fetchUserStickers(travelerId: me.id)
        async let tripsTask    = try? APIClient.shared.fetchUserTrips(travelerId: me.id)
        async let buddyTask    = try? APIClient.shared.fetchBuddyMe()
        async let destsTask    = try? APIClient.shared.fetchDestinations()
        async let sharesTask   = try? APIClient.shared.fetchUserShares(travelerId: me.id)

        let (s, tp, b, d, sh) = await (stickersTask, tripsTask, buddyTask, destsTask, sharesTask)
        dlog("👤 [YoView] datos cargados — stickers=\(s?.count ?? 0) shares=\(sh?.count ?? 0) trips=\(tp?.items.count ?? 0) hasMore=\(tp?.hasMore ?? false) buddy=\(b?.isBuddy == true ? "sí" : "no") isBuddy=\(b?.profile?.verificationStatus ?? "no-profile")")

        stickers        = s ?? []
        journeys        = tp?.items ?? []
        shares          = sh ?? []
        tripsNextCursor = tp?.nextCursor
        tripsHasMore    = tp?.hasMore ?? false
        buddyMe         = b
        destinations    = d ?? []
        lastFetchedAt   = Date()

        await routeStore.syncCollectedStickers(userStickers: stickers)
    }

    private func loadMoreTrips() async {
        guard tripsHasMore, !isLoadingMoreTrips, let userId = user?.id else { return }
        dlog("👤 [YoView] loadMoreTrips — cursor=\(tripsNextCursor ?? "nil")")
        isLoadingMoreTrips = true
        defer { isLoadingMoreTrips = false }
        // Con carga automática el indicador no puede quedar girando para
        // siempre: si falla o llega vacía, se deja de pedir.
        // El cursor ahora es cuántos trips ya llegaron (buddy-core, 19 Nov 2026).
        guard let page = try? await APIClient.shared.fetchUserTrips(travelerId: userId, cursor: tripsNextCursor) else {
            tripsHasMore = false
            return
        }
        let nuevos = page.items.filter { n in !journeys.contains { $0.id == n.id } }
        journeys        += nuevos
        tripsNextCursor  = page.nextCursor
        tripsHasMore     = page.hasMore && page.nextCursor != nil && !nuevos.isEmpty
        dlog("👤 [YoView] loadMoreTrips ✅ — +\(page.items.count) trips totalNow=\(journeys.count)")
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

    private static let memberSinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "MMMM yyyy"
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "d MMM"
        return f
    }()

    private func memberSinceLabel(date: Date) -> String {
        YoView.memberSinceFormatter.string(from: date)
    }

    private func shortDateFromDate(_ date: Date) -> String {
        YoView.shortDateFormatter.string(from: date)
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
        case "approved": return Color.brand
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
        // Mismo patrón que "Mis trips": icono en sage, título forest, flecha sage.
        HStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 44, height: 44)
                .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Perfil de Buddy")
                        .font(.system(.headline).weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text(badgeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(badgeColor.opacity(0.12), in: Capsule())
                }
                Text(sublabel)
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 32, height: 32)
                .background(Color.sageTint, in: Circle())
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
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
        ("transport", "Transporte"), ("food", "Comer"),
        ("shopping", "Compras"), ("activities", "Actividades"),
        ("accommodation", "Alojamiento"), ("recommendations", "Consejos"),
    ]

    private var verificationColor: Color {
        switch profile.verificationStatus {
        case "approved": return Color.brand
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
                    Task { await saveZone(picked) }
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

    private func saveZone(_ destination: APIDestination) async {
        savingZone = true
        selectedZoneName = destination.name  // optimistic
        defer { savingZone = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(
                coverage: BuddyCoverageInput(from: destination)
            )
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




// MARK: – Piezas compartidas del perfil (Yo y perfil de otro viajero)
// Keyla, 19 Nov 2026: el perfil que se abre desde Comunidad debe verse igual
// que Yo. Mismas piezas en los dos lados.

/// Cifras del perfil en pastillas sage ("12 trips", "12 lugares", "9 ayudas").
struct ProfileStatPills: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.paleSage, in: Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    static func make(trips: Int, places: Int, helps: Int?) -> [String] {
        var out = [trips == 1 ? "1 trip" : "\(trips) trips"]
        if places > 0 { out.append(places == 1 ? "1 lugar" : "\(places) lugares") }
        if let helps, helps > 0 { out.append(helps == 1 ? "1 ayuda" : "\(helps) ayudas") }
        return out
    }
}

/// Grilla de trips publicados (3 columnas, 8 pt, esquinas 14). Carga más sola
/// al llegar al final si `onReachEnd` no es nil.
struct ProfileTripsGrid: View {
    let journeys: [APIJourney]
    var hasMore: Bool = false
    var onTap: (APIJourney) -> Void
    var onDelete: ((APIJourney) -> Void)? = nil
    var onReachEnd: (() -> Void)? = nil

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(journeys, id: \.id) { journey in
                    TripGridCell(journey: journey)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                        .onTapGesture { Haptic.light(); onTap(journey) }
                        .contextMenu {
                            if let onDelete {
                                Button(role: .destructive) { onDelete(journey) } label: {
                                    Label("Eliminar publicación", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            if hasMore, let onReachEnd {
                ProgressView()
                    .tint(Color.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .onAppear { onReachEnd() }
            }
        }
        .padding(.horizontal, Spacing.edge)
    }
}

// MARK: – PROTOTIPO: modo negocio (Keyla, 19 Nov 2026)
// Solo para entender el flujo. NO está integrado con fincas: los negocios y
// productos se guardan en este teléfono (UserDefaults). Cuando se integre,
// AccountStore leerá y escribirá en fincas y esto se reemplaza.

struct ProtoProduct: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var price: Double
    var soldOut = false
}

struct ProtoBusiness: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var category: String
    var contact: String
    var products: [ProtoProduct] = []
    // Perfil del negocio en Buddy (Keyla, 20 Nov 2026). Opcionales para leer
    // lo ya guardado antes de existir estos campos.
    var hours: [DayHours]? = nil
    var photoFiles: [String]? = nil
    var videoFiles: [String]? = nil
    var about: String? = nil
    var locations: [BusinessLocation]? = nil
    /// Solicitud enviada, esperando aprobación (aún no es negocio vinculado).
    var pending: Bool? = nil

    /// Lo que se muestra bajo el nombre: sin nombrar a Apartalo (Keyla, 20 Nov 2026).
    /// Negocio ya aprobado y vinculado (sus productos viven en el servidor).
    var isLinkedAccount: Bool {
        pending != true && UUID(uuidString: id) != nil
            && (category == "Cuenta negocio" || category == "Negocio en Apartalo")
    }

    var kindLabel: String {
        if pending == true || !isLinkedAccount { return "En revisión" }
        return category == "Negocio en Apartalo" ? "Cuenta negocio" : category
    }
}

/// Una sede del negocio (Keyla, 20 Nov 2026: un negocio puede tener 2 o más).
/// spotId: el lugar de Buddy elegido en el mapa, o nil si es un punto nuevo.
struct BusinessLocation: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var lat: Double
    var lng: Double
    var spotId: String? = nil
    var address: String? = nil
    var isMain = false
    // Horario y contenido son de cada sede (Keyla, 20 Nov 2026).
    var hours: [DayHours]? = nil
    var photoFiles: [String]? = nil
    var videoFiles: [String]? = nil
}

struct BusinessLocationPickRoute: Hashable { let businessId: String }
/// Ficha de una sede: su horario y sus fotos/videos.
struct BusinessLocationRoute: Hashable { let businessId: String; let locationId: String }

/// Agregar una sede (Keyla, 20 Nov 2026): primero se buscan los lugares de
/// Buddy cercanos, porque un buddy o un turista pudo crearlo antes; el negocio
/// lo reclama como suyo en vez de duplicarlo. Si no está, el mismo mapa de
/// "Compartir un lugar". Antes de guardar un punto nuevo se revisa otra vez si
/// hay un lugar a pocos metros.
struct BusinessLocationPicker: View {
    let businessId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AccountStore.shared
    @State private var step: Step = .nearby
    @State private var nearby: [APINearbySpot] = []
    @State private var loadingNearby = true
    @State private var errorText: String?
    @State private var pendingNew: (name: String, lat: Double, lng: Double)?
    @State private var closeToNew: [APINearbySpot] = []
    @State private var mapPlaces: [MKMapItem] = []
    enum Step { case nearby, map, confirmNew }

    private var start: (lat: Double, lng: Double)? {
        LocationService.current?.userLocation.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    var body: some View {
        Group {
            switch step {
            case .nearby: nearbyStep
            case .map: mapStep
            case .confirmNew: confirmNewStep
            }
        }
        .navigationTitle("Agregar ubicación")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(step == .nearby ? "Cancelar" : "Atrás") {
                    if step == .nearby { dismiss() } else { withAnimation { step = .nearby } }
                }
            }
        }
        .task { await loadNearby() }
    }

    // MARK: Paso 1: ¿tu negocio ya está en Buddy?

    private var nearbyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("¿Tu negocio ya está en Buddy?").font(BT.title3).foregroundStyle(Color.brand)
                Text("Un viajero o un buddy pudo agregarlo antes. Si lo ves aquí, elígelo y será tuyo; así no queda repetido en el mapa.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                if loadingNearby {
                    HStack(spacing: 8) { ProgressView(); Text("Buscando lugares cerca de ti").font(BT.footnote).foregroundStyle(Color.inkMuted) }
                        .padding(.vertical, 12)
                } else if nearby.isEmpty && mapPlaces.isEmpty {
                    Text(start == nil ? "No tenemos tu ubicación. Busca tu negocio en el mapa." : "No encontramos lugares cerca de ti.")
                        .font(BT.footnote).foregroundStyle(Color.inkMuted).padding(.vertical, 8)
                } else if !nearby.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(nearby.prefix(8)) { spot in
                            Button { claim(spot) } label: { spotRow(spot) }.buttonStyle(.plain)
                            Divider().overlay(Color.hairline)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                }
                // Lugares del mapa cerca, aún sin dueño en Buddy (Keyla, 20 Nov 2026).
                if !loadingNearby && !mapPlaces.isEmpty {
                    Text("Lugares cerca de ti, aún sin dueño").font(BT.footnoteBold).foregroundStyle(Color.brand)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(mapPlaces, id: \.self) { item in
                            Button { claimMapPlace(item) } label: { mapPlaceRow(item) }.buttonStyle(.plain)
                            Divider().overlay(Color.hairline)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                }
                if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
                Button { withAnimation { step = .map } } label: {
                    Label("No está aquí · buscar en el mapa", systemImage: "map")
                        .font(BT.footnoteBold).foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity).frame(height: 48).background(Color.sageTint, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.edge)
        }
        .background(Color.canvas)
    }

    private func spotRow(_ spot: APINearbySpot) -> some View {
        HStack(spacing: 12) {
            LocationPin(size: 16)
                .frame(width: 40, height: 40)
                .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(2)
                Text(spot.isPendingApproval ? "\(spot.distanceLabel) · por revisar" : spot.distanceLabel)
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 4)
            Text("Es mío").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.sageTint, in: Capsule())
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func mapPlaceRow(_ item: MKMapItem) -> some View {
        let meters: Int? = {
            guard let s = start, let l = item.placemark.location else { return nil }
            return Int(CLLocation(latitude: s.lat, longitude: s.lng).distance(from: l))
        }()
        return HStack(spacing: 12) {
            LocationPin(size: 16)
                .frame(width: 40, height: 40)
                .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "").font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(2)
                Text(meters.map { "a \($0) m" } ?? "Cerca").font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 4)
            Text("Es mío").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.sageTint, in: Capsule())
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func claimMapPlace(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        Task { await checkBeforeNew(name: item.name ?? "Mi negocio", lat: c.latitude, lng: c.longitude) }
    }

    // MARK: Paso 2: mapa (mismo que Compartir un lugar)

    private var mapStep: some View {
        ElegirLugarEnMapaView(
            initialCoords: start,
            categories: [],   // una sede no necesita categoría de lugar
            isSubmitting: false,
            errorMessage: errorText,
            onPickSpot: { spot in add(name: spot.name, lat: spot.lat, lng: spot.lng, spotId: spot.id) },
            onPropose: { name, _, lat, lng in Task { await checkBeforeNew(name: name, lat: lat, lng: lng) } },
            pickTitle: "Es mi negocio",
            proposeTitle: "Guardar ubicación",
            newEyebrow: "NUEVA UBICACIÓN",
            namePlaceholder: "Nombre de la sede. Ej. Finca Rosal Centro",
            suggestMapPlaces: true
        )
    }

    // MARK: Paso 3: hay un lugar a pocos metros del punto nuevo

    private var confirmNewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("¿Es alguno de estos?").font(BT.title3).foregroundStyle(Color.brand)
                Text("Ya hay lugares de Buddy muy cerca del punto que elegiste. Si uno es tu negocio, elígelo.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                VStack(spacing: 0) {
                    ForEach(closeToNew.prefix(5)) { spot in
                        Button { claim(spot) } label: { spotRow(spot) }.buttonStyle(.plain)
                        Divider().overlay(Color.hairline)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                if let p = pendingNew {
                    Button { add(name: p.name, lat: p.lat, lng: p.lng, spotId: nil) } label: {
                        Text("No, \(p.name) es un lugar nuevo")
                            .font(BT.footnoteBold).foregroundStyle(Color.brand).lineLimit(1)
                            .frame(maxWidth: .infinity).frame(height: 48).background(Color.sageTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.edge)
        }
        .background(Color.canvas)
    }

    // MARK: Datos

    private func loadNearby() async {
        guard let c = start else { loadingNearby = false; return }
        async let spotsTask = try? await APIClient.shared.fetchNearbySpots(lat: c.lat, lng: c.lng, radius: 300)
        let center = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
        async let poisTask = try? await MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: center, radius: 150)).start().mapItems
        let (spots, pois) = await (spotsTask, poisTask)
        nearby = spots ?? []
        // Sin repetir: si ya hay un lugar de Buddy con el mismo nombre, no se muestra dos veces.
        let taken = Set(nearby.map { $0.name.lowercased() })
        let here = CLLocation(latitude: c.lat, longitude: c.lng)
        mapPlaces = Array((pois ?? [])
            .filter { !($0.name ?? "").isEmpty && !taken.contains(($0.name ?? "").lowercased()) }
            .sorted { here.distance(from: $0.placemark.location ?? here) < here.distance(from: $1.placemark.location ?? here) }
            .prefix(8))
        loadingNearby = false
    }

    private func checkBeforeNew(name: String, lat: Double, lng: Double) async {
        let close = (try? await APIClient.shared.fetchNearbySpots(lat: lat, lng: lng, radius: 60)) ?? []
        if close.isEmpty {
            add(name: name, lat: lat, lng: lng, spotId: nil)
        } else {
            pendingNew = (name, lat, lng)
            closeToNew = close
            withAnimation { step = .confirmNew }
        }
    }

    private func claim(_ spot: APINearbySpot) {
        guard let lat = spot.lat, let lng = spot.lng else {
            errorText = "Ese lugar no tiene coordenadas. Búscalo en el mapa."
            return
        }
        add(name: spot.name, lat: lat, lng: lng, spotId: spot.id)
    }

    private func add(name: String, lat: Double, lng: Double, spotId: String?) {
        guard var b = store.businesses.first(where: { $0.id == businessId }) else { return }
        var list = b.locations ?? []
        if list.contains(where: { (spotId != nil && $0.spotId == spotId) || (abs($0.lat - lat) < 0.00005 && abs($0.lng - lng) < 0.00005) }) {
            errorText = "Esta ubicación ya está en tu lista."
            return
        }
        var loc = BusinessLocation(name: name.trimmingCharacters(in: .whitespaces), lat: lat, lng: lng, spotId: spotId)
        loc.isMain = list.isEmpty
        list.append(loc)
        b.locations = list
        store.update(b)
        Haptic.success()
        let id = loc.id
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)) { marks, _ in
            guard let m = marks?.first else { return }
            let text = [m.thoroughfare.map { t in m.subThoroughfare.map { "\(t) \($0)" } ?? t }, m.locality]
                .compactMap { $0 }.joined(separator: ", ")
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                guard var bb = store.businesses.first(where: { $0.id == businessId }),
                      let k = bb.locations?.firstIndex(where: { $0.id == id }) else { return }
                bb.locations?[k].address = text
                store.update(bb)
            }
        }
        dismiss()
    }
}

/// Horario de un día: abierto/cerrado y horas en minutos desde las 00:00.
struct DayHours: Codable, Hashable, Identifiable {
    var day: Int            // 0 = lunes … 6 = domingo
    var open: Bool
    var from: Int           // minutos
    var to: Int
    var id: Int { day }
    static let names = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"]
    static func defaults() -> [DayHours] {
        (0..<7).map { DayHours(day: $0, open: $0 < 6, from: 8 * 60, to: 18 * 60) }
    }
}

final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    @Published var businesses: [ProtoBusiness] = [] { didSet { save() } }
    @Published var activeBusinessId: String? = nil { didSet { save() } }

    var active: ProtoBusiness? { businesses.first { $0.id == activeBusinessId } }

    private let key = "proto.business.accounts"
    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            businesses = s.businesses; activeBusinessId = s.active
        }
    }
    private struct Saved: Codable { var businesses: [ProtoBusiness]; var active: String? }
    private func save() {
        let s = Saved(businesses: businesses, active: activeBusinessId)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
    func update(_ b: ProtoBusiness) {
        if let i = businesses.firstIndex(where: { $0.id == b.id }) { businesses[i] = b }
    }
}

struct AccountsRoute: Hashable {}
struct RegisterBusinessRoute: Hashable {}

/// "Tus cuentas": como Instagram, pero a pantalla completa.
struct AccountSwitcherView: View {
    let personName: String
    let personAvatar: String?
    var onDone: () -> Void
    @ObservedObject private var store = AccountStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Tus cuentas")
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                VStack(spacing: 0) {
                    row(title: personName, subtitle: "Cuenta personal", avatar: personAvatar,
                        icon: "person", selected: store.activeBusinessId == nil) {
                        store.activeBusinessId = nil; onDone()
                    }
                    ForEach(store.businesses) { b in
                        Divider().overlay(Color.hairline).padding(.leading, 74)
                        row(title: b.name, subtitle: b.kindLabel, avatar: nil,
                            icon: "storefront", selected: store.activeBusinessId == b.id) {
                            store.activeBusinessId = b.id; onDone()
                        }
                    }
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .cardShadow()

                // Sin "Crear o vincular negocio" aquí: las cuentas ya están en la lista
                // y la opción vive en el menú "⋯" de Yo (Keyla, 20 Nov 2026).

            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
    }

    private func row(title: String, subtitle: String, avatar: String?, icon: String,
                     selected: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptic.select(); action() } label: {
            HStack(spacing: 12) {
                Circle().fill(Color.paleSage).frame(width: 48, height: 48)
                    .overlay {
                        CachedImage(urlString: avatar) { img in
                            img.resizable().scaledToFill().frame(width: 48, height: 48).clipShape(Circle())
                        } placeholder: {
                            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.brand)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BT.headline).foregroundStyle(Color.ink).lineLimit(1)
                    Text(subtitle).font(BT.footnote).foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Color.brand : Color.border)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Formulario de alta de negocio (prototipo local).
struct RegisterBusinessView: View {
    var onDone: () -> Void
    @State private var name = ""
    @State private var category = "Fincas"
    @State private var contact = ""
    @State private var authorized = false
    @State private var city = "Villa Rica"
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var needsLogin = false
    private let categories = ["Fincas", "Tostadurías", "Cafeterías", "Restaurantes y comida local",
                              "Hospedaje", "Productos locales", "Artesanía y cultura Yanesha",
                              "Guías y actividades", "Transporte con conductor"]
    private var canSave: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 3 && city.trimmingCharacters(in: .whitespaces).count >= 2 && authorized && !busy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Nuevo negocio")
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                field("Nombre del negocio", text: $name, placeholder: "Ej. Finca Las Orquídeas")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Categoría").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    Menu {
                        ForEach(categories, id: \.self) { c in Button(c) { category = c } }
                    } label: {
                        HStack {
                            Text(category).foregroundStyle(Color.ink)
                            Spacer()
                            Image(systemName: "chevron.down").foregroundStyle(Color.brand)
                        }
                        .font(BT.callout)
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(Color.surface, in: Capsule())
                        .cardShadow()
                    }
                }
                field("Ciudad", text: $city, placeholder: "Ej. Villa Rica")
                field("Contacto (WhatsApp)", text: $contact, placeholder: "Ej. 987 654 321")
                Toggle(isOn: $authorized) {
                    Text("Autorizo que Buddy muestre mi negocio y mis productos")
                        .font(BT.footnote).foregroundStyle(Color.ink)
                }
                .tint(Color.brand)
                .padding(14)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .cardShadow()

                if let errorText {
                    Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed)
                }
                if needsLogin {
                    NavigationLink(value: LinkBusinessRoute()) {
                        Text("Entrar con Apple o Google").font(BT.footnoteBold).foregroundStyle(Color.brand)
                            .frame(maxWidth: .infinity).frame(height: 48).background(Color.sageTint, in: Capsule())
                    }
                }
                Button { Task { await create() } } label: {
                    HStack(spacing: 8) {
                    if busy { ProgressView().tint(Color.inkInverse) }
                    Text("Crear negocio")
                        .font(BT.footnoteBold)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(canSave ? Color.brand : Color.inkMuted.opacity(0.2), in: Capsule())
                        .foregroundStyle(canSave ? Color.inkInverse : Color.inkMuted)
                    }
                }
                .disabled(!canSave)
                Text("Tu negocio quedará \"En revisión\". Cuando lo aprobemos podrás añadir productos y ubicaciones.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
    }

    private func create() async {
        errorText = nil; needsLogin = false
        guard FincasAuth.hasSavedSession else {
            errorText = "Primero entra con tu cuenta de Apple o Google; así el negocio queda a tu nombre."
            needsLogin = true
            return
        }
        busy = true
        defer { busy = false }
        let n = name.trimmingCharacters(in: .whitespaces)
        let phone = contact.filter(\.isNumber)
        do {
            let token = try await FincasAuth.validIdToken()
            try await FincasAuth.requestBusiness(idToken: token, name: n, city: city.trimmingCharacters(in: .whitespaces),
                                                 phone: phone.isEmpty ? nil : phone)
            let b = ProtoBusiness(id: "pending-" + UUID().uuidString, name: n, category: category,
                                  contact: phone, pending: true)
            AccountStore.shared.businesses.append(b)
            AccountStore.shared.activeBusinessId = b.id
            Haptic.success()
            onDone()
        } catch let e as FincasAuth.FincasError {
            if case .signIn = e { needsLogin = true }
            errorText = e.localizedDescription
        } catch {
            errorText = "No pudimos enviar la solicitud. Revisa tu conexión e intenta de nuevo."
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(BT.footnoteBold).foregroundStyle(Color.ink)
            TextField(placeholder, text: text)
                .font(BT.callout)
                .padding(.horizontal, 16).frame(height: 50)
                .background(Color.surface, in: Capsule())
                .cardShadow()
        }
    }
}

/// 4.º tab en modo negocio: Resumen, Productos y Mi negocio.
struct BusinessHomeView: View {
    let business: ProtoBusiness
    /// Mismo menú "⋯" que Yo (Keyla, 20 Nov 2026).
    var onLinkBusiness: () -> Void = {}
    var onSwitchAccount: () -> Void = {}
    var onLogout: () -> Void = {}
    @ObservedObject private var store = AccountStore.shared
    @State private var section = 1   // 1 Mi negocio (primero) · 0 Productos (Keyla 20 Nov 2026)
    @State private var newName = ""
    @State private var newPrice = ""
    @State private var editing: ProtoProduct? = nil
    @State private var editPrice = ""

    private var live: ProtoBusiness { store.businesses.first { $0.id == business.id } ?? business }
    /// Negocio vinculado a fincas (id = farmId uuid): productos reales de Apartalo.
    private var isLinked: Bool { live.isLinkedAccount }
    @State private var remote: [FincasProduct] = []
    @State private var remoteTotal = 0
    @State private var remoteHasMore = false
    @State private var remoteLoading = false
    @State private var remoteError: String? = nil
    /// Solo cuando de verdad falta la sesión de Apartalo se ofrece entrar.
    @State private var remoteNeedsLogin = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                if !isLinked { pendingCard }
                Picker("", selection: $section) {
                    Text("Mi negocio").tag(1)
                    Text("Productos").tag(0)
                }
                .pickerStyle(.segmented)
                if section == 0 {
                    if isLinked { remoteProducts } else { productsLocked }
                } else {
                    BusinessProfileEditor(businessId: business.id, isLinked: isLinked,
                                          hasProducts: isLinked ? remoteTotal > 0 : !live.products.isEmpty,
                                          onShowProducts: { withAnimation { section = 0 } })
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 140)
        }
        .background(Color.canvas)
        // La carga va en un Task propio: si SwiftUI cancela la tarea de la vista
        // (cambio de pestaña o de cuenta), la petición no muere a medias
        // (antes salía "cancelled", Keyla 20 Nov 2026).
        .task(id: business.id) { if isLinked { await Task { await loadRemote(reset: true) }.value } }
        .onReceive(NotificationCenter.default.publisher(for: .fincasProductsChanged)) { note in
            if isLinked, (note.object as? String) == business.id { Task { await loadRemote(reset: true) } }
        }
        .refreshable { if isLinked { await Task { await loadRemote(reset: true) }.value } }
        .alert("Cambiar precio", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Precio", text: $editPrice).keyboardType(.decimalPad)
            Button("Guardar") {
                if var p = editing, let v = Double(editPrice.replacingOccurrences(of: ",", with: ".")) {
                    p.price = v; replace(p)
                }
                editing = nil
            }
            Button("Cancelar", role: .cancel) { editing = nil }
        }
    }

    /// Antes de la aprobación no se pueden añadir productos (Keyla, 20 Nov 2026).
    private var productsLocked: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock").foregroundStyle(Color.brand)
                .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("Productos disponibles al aprobar tu negocio").font(BT.headline).foregroundStyle(Color.ink)
                Text("Revisamos tu negocio y te avisamos. Mientras, completa tu perfil en Mi negocio.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    @State private var checkingApproval = false
    @State private var approvalNote: String? = nil

    /// Solicitud en revisión: se puede consultar si ya fue aprobada.
    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "hourglass").foregroundStyle(Color.brand)
                    .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("En revisión").font(BT.headline).foregroundStyle(Color.ink)
                    Text("Revisamos tu negocio y te avisamos. Mientras, puedes completar tu perfil.")
                        .font(BT.footnote).foregroundStyle(Color.inkMuted)
                }
            }
            if let approvalNote { Text(approvalNote).font(BT.footnote).foregroundStyle(Color.inkMuted) }
            Button { Task { await checkApproval() } } label: {
                HStack(spacing: 8) {
                    if checkingApproval { ProgressView().tint(Color.brand) }
                    Text("Revisar estado").font(BT.footnoteBold).foregroundStyle(Color.brand)
                }
                .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
            }
            .disabled(checkingApproval)
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private func checkApproval() async {
        checkingApproval = true
        defer { checkingApproval = false }
        approvalNote = nil
        do {
            let token = try await FincasAuth.validIdToken()
            let answer = try await FincasAuth.session(idToken: token)
            let match = (answer.businesses ?? []).first {
                $0.name.compare(live.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame && $0.farmId != nil
            }
            guard let match, let farmId = match.farmId else {
                approvalNote = "Aún está en revisión."
                return
            }
            _ = try await APIClient.shared.linkFincasBusinesses(firebaseToken: token)
            let st = AccountStore.shared
            var approved = live
            approved.id = farmId
            approved.pending = nil
            approved.category = "Cuenta negocio"
            st.businesses.removeAll { $0.id == live.id || $0.id == farmId }
            st.businesses.append(approved)
            st.activeBusinessId = farmId
            Haptic.success()
        } catch {
            approvalNote = "No pudimos revisar ahora. Intenta de nuevo."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top) {
                NavigationLink(value: AccountsRoute()) {
                    HStack(spacing: 6) {
                        Text(live.name)
                            .font(.system(.largeTitle).weight(.bold))
                            .foregroundStyle(Color.brand)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.brand)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Cambiar de cuenta")
                Spacer()
                Menu {
                    Button { onSwitchAccount() } label: {
                        Label("Cambiar de cuenta", systemImage: "arrow.left.arrow.right")
                    }
                    // Una cuenta de negocio no crea ni vincula otros negocios;
                    // eso se hace desde la cuenta personal (Keyla, 20 Nov 2026).
                    Button { Haptic.light(); onLogout() } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.inkMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Opciones de cuenta")
            }
            HStack(spacing: Spacing.md) {
                Image(systemName: "storefront")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 72, height: 72)
                    .background(Color.paleSage, in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(isLinked ? "Cuenta negocio" : live.category).font(BT.subhead).foregroundStyle(Color.inkMuted)
                    ProfileStatPills(items: isLinked
                        ? [remoteTotal == 1 ? "1 producto" : "\(remoteTotal) productos", "Vinculado"]
                        : ["En revisión"])
                }
            }
        }
    }

    private var resumen: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(title: "Esta semana")
            if isLinked {
                // Sin datos inventados: las visitas llegan cuando el negocio esté en el mapa.
                Text("Las visitas y los productos vistos aparecerán cuando tu negocio esté en el mapa de Buddy.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    stat("0", "visitas")
                    stat("0", "productos vistos")
                }
            }
            SectionTitle(title: "Te falta")
            VStack(alignment: .leading, spacing: 10) {
                check("Agregar productos", done: isLinked ? remoteTotal > 0 : !live.products.isEmpty)
                check("Agregar contacto", done: !live.contact.isEmpty)
                check("Agregar fotos y horario", done: false)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .cardShadow()
        }
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(.system(.title).weight(.bold)).foregroundStyle(Color.brand)
            Text(label).font(BT.footnote).foregroundStyle(Color.inkMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private func check(_ t: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.brand : Color.border)
            Text(t).font(BT.callout).foregroundStyle(done ? Color.inkMuted : Color.ink)
                .strikethrough(done)
        }
    }

    private var productos: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(title: "Productos", count: live.products.count)
            // Alta rápida
            HStack(spacing: 8) {
                TextField("Producto", text: $newName)
                    .font(BT.callout).padding(.horizontal, 14).frame(height: 46)
                    .background(Color.surface, in: Capsule()).cardShadow()
                TextField("S/", text: $newPrice)
                    .keyboardType(.decimalPad)
                    .font(BT.callout).padding(.horizontal, 14).frame(width: 80, height: 46)
                    .background(Color.surface, in: Capsule()).cardShadow()
                Button {
                    guard let v = Double(newPrice.replacingOccurrences(of: ",", with: ".")),
                          !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    var b = live
                    b.products.append(ProtoProduct(name: newName, price: v))
                    store.update(b)
                    newName = ""; newPrice = ""; Haptic.success()
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.inkInverse)
                        .frame(width: 46, height: 46).background(Color.brand, in: Circle())
                }
                .accessibilityLabel("Añadir producto")
            }
            if live.products.isEmpty {
                Text("Aún no tienes productos. Escribe el nombre y el precio arriba.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(live.products.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider().overlay(Color.hairline).padding(.leading, 14) }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(BT.headline)
                                    .foregroundStyle(p.soldOut ? Color.inkMuted : Color.ink)
                                Text(p.soldOut ? "Agotado" : "Disponible")
                                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
                            }
                            Spacer()
                            Button {
                                editPrice = String(format: "%.2f", p.price); editing = p
                            } label: {
                                Text("S/ " + String(format: "%.2f", p.price))
                                    .font(BT.footnoteBold).foregroundStyle(Color.brand)
                                    .padding(.horizontal, 12).frame(height: 34)
                                    .background(Color.sageTint, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            Toggle("", isOn: Binding(get: { !p.soldOut },
                                                     set: { var q = p; q.soldOut = !$0; replace(q) }))
                                .labelsHidden().tint(Color.brand)
                        }
                        .padding(14)
                    }
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .cardShadow()
                Text("Toca el precio para cambiarlo. El interruptor marca Disponible o Agotado.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
        }
    }

    // MARK: Productos reales (fincas)

    private var remoteProducts: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(title: "Productos", count: remoteTotal)
            NavigationLink(value: FincasProductRoute(farmId: business.id, product: nil)) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                    Text("Añadir producto").font(BT.footnoteBold)
                }
                .foregroundStyle(Color.inkInverse)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Color.brand, in: Capsule())
            }
            .buttonStyle(.pressable)
            if remoteLoading && remote.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.brand)
                    Text("Cargando tus productos…").font(BT.callout).foregroundStyle(Color.inkMuted)
                }
            } else if let remoteError, remote.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(remoteError).font(BT.footnote).foregroundStyle(Color.ink)
                    HStack(spacing: 8) {
                        if remoteNeedsLogin {
                        Button { onLinkBusiness() } label: {
                            Text("Volver a entrar").font(BT.footnoteBold).foregroundStyle(Color.inkInverse)
                                .padding(.horizontal, 16).frame(height: 40)
                                .background(Color.brand, in: Capsule())
                        }
                        }
                        Button { Task { await loadRemote(reset: true) } } label: {
                            Text("Reintentar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                                .padding(.horizontal, 16).frame(height: 40)
                                .background(Color.sageTint, in: Capsule())
                        }
                    }
                }
            } else if remote.isEmpty {
                Text("Este negocio aún no tiene productos.").font(BT.footnote).foregroundStyle(Color.inkMuted)
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(remote) { p in
                        NavigationLink(value: FincasProductRoute(farmId: business.id, product: p)) {
                            remoteCard(p)
                        }
                        .buttonStyle(.pressable)
                    }
                    if remoteHasMore {
                        ProgressView().tint(Color.brand).frame(maxWidth: .infinity).frame(height: 44)
                            .onAppear { Task { await loadRemote(reset: false) } }
                    }
                }
                Text("Toca un producto para editarlo.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
        }
    }

    private func remoteCard(_ p: FincasProduct) -> some View {
        let photo = p.coverUrl
        let statusText: String = {
            switch p.status { case "active": return "En la tienda"; case "archived": return "Oculto"; default: return "Borrador" }
        }()
        return HStack(alignment: .top, spacing: 12) {
            CachedImage(urlString: photo) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "bag").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.paleSage)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(p.name).font(BT.headline).foregroundStyle(Color.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(statusText).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.status == "active" ? Color.brand : Color.inkMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(p.status == "active" ? Color.sageTint : Color.surfaceRaised, in: Capsule())
                }
                ForEach(p.presentations ?? []) { pr in
                    HStack {
                        Text((pr.label.isEmpty ? "Presentación" : pr.label) + (pr.visible == false ? " · oculta" : ""))
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        Spacer()
                        if let price = pr.price {
                            Text("S/ " + String(format: "%.2f", price)).font(BT.footnoteBold).foregroundStyle(Color.brand)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private func loadRemote(reset: Bool) async {
        if remoteLoading { return }
        remoteLoading = true
        defer { remoteLoading = false }
        do {
            let page = try await FincasAuth.products(farmId: business.id, offset: reset ? 0 : remote.count)
            let fresh = page.items.filter { n in !remote.contains { $0.id == n.id } }
            remote = reset ? page.items : remote + fresh
            // Fotos subidas desde otra app: la lista del dueño a veces no las trae.
            if remote.contains(where: { $0.coverUrl == nil }) {
                let farm = business.id
                let pub = (try? await FincasAuth.publicProducts(farmId: farm)) ?? []
                let covers = Dictionary(pub.compactMap { p in p.coverUrl.map { (p.id, $0) } }, uniquingKeysWith: { a, _ in a })
                remote = remote.map { p in
                    guard p.coverUrl == nil, let u = covers[p.id] else { return p }
                    var q = p; q.photoUrl = u; return q
                }
            }
            remoteTotal = page.total ?? remote.count
            remoteHasMore = (page.hasMore ?? false) && !(reset ? page.items.isEmpty : fresh.isEmpty)
            remoteError = nil
            remoteNeedsLogin = false
        } catch is CancellationError {
            // cancelada: no es un error para mostrar
        } catch let e as URLError where e.code == .cancelled {
            // cancelada: no es un error para mostrar
        } catch FincasAuth.FincasError.signIn(let m) {
            remoteError = m
            remoteNeedsLogin = true
        } catch {
            remoteError = error.localizedDescription
            remoteNeedsLogin = false
        }
    }

    private var miNegocio: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Texto propio: SectionTitle pasa todo a minúscula y "Buddy" es un nombre.
            Text("Tu página en Buddy")
                .font(.system(.title3).weight(.bold))
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 10) {
                info("Nombre", live.name)
                info("Categoría", isLinked ? "Por elegir" : live.category)
                info("Contacto", live.contact.isEmpty ? "Por completar" : live.contact)
                info("Estado", isLinked ? "Vinculado" : "En revisión")
            }
            .padding(14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .cardShadow()
            Text("Próximamente: fotos, horario, ubicación, \"Ver como visitante\" y tu QR para imprimir.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(BT.footnote).foregroundStyle(Color.inkMuted)
            Spacer()
            Text(v).font(BT.footnoteBold).foregroundStyle(Color.ink)
        }
    }

    private func replace(_ p: ProtoProduct) {
        var b = live
        if let i = b.products.firstIndex(where: { $0.id == p.id }) { b.products[i] = p; store.update(b) }
    }
}


/// Tarjeta "Crear negocio" en Yo (mismo patrón que Mis trips).
struct CreateBusinessEntryCard: View {
    var body: some View {
        NavigationLink(value: RegisterBusinessRoute()) {
            HStack(spacing: 12) {
                Image(systemName: "storefront")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 44, height: 44)
                    .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crear negocio")
                        .font(.system(.headline).weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text("Muestra tus productos y precios en Buddy")
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 32, height: 32)
                    .background(Color.sageTint, in: Circle())
            }
            .padding(14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .cardShadow()
        }
        .buttonStyle(.pressable)
    }
}

// MARK: – Crear o vincular negocio (real, con fincas) — ADR-001
// Paso 1: la persona entra con la MISMA cuenta de Apple/Google que usa en
// Apartalo (Firebase apartalo-10146). Paso 2: Buddy pregunta a fincas qué
// negocios tiene. Paso 3: "Vincular" lo guarda en buddy-core (que vuelve a
// comprobarlo con fincas). Crear un negocio nuevo sigue en el prototipo local.

struct LinkBusinessRoute: Hashable {}

struct LinkBusinessView: View {
    var onDone: () -> Void
    @State private var phase: Phase = .start
    @State private var session: FincasAuth.Session? = nil
    @State private var answer: FincasAuth.SessionAnswer? = nil
    @State private var linking = false
    @State private var errorText: String? = nil

    enum Phase { case start, checking, result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Crear o vincular negocio")
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                switch phase {
                case .start: startCard
                case .checking:
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.brand)
                        Text("Buscando tus negocios…").font(BT.callout).foregroundStyle(Color.inkMuted)
                    }
                    .padding(.top, Spacing.md)
                case .result: resultView
                }
                if let errorText {
                    Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed)
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
        .task { await resumeSavedSession() }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Entra con la cuenta de Apple o Google de tu negocio. Así vemos si ya lo tienes y no se crea dos veces.")
                .font(BT.callout).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            providerButton("Continuar con Apple", icon: "apple.logo", provider: .apple)
            providerButton("Continuar con Google", icon: "g.circle", provider: .google)
        }
    }

    private func providerButton(_ title: String, icon: String, provider: IdentityCredential.Provider) -> some View {
        Button {
            Task { await check(provider) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(BT.footnoteBold)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Color.brand, in: Capsule())
            .foregroundStyle(Color.inkInverse)
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder private var resultView: some View {
        let list = (answer?.businesses ?? []).filter { $0.farmId != nil }
        if answer?.status == "business_pending" {
            infoCard(icon: "clock", title: "Tu negocio está en revisión",
                     text: "\(answer?.businessName ?? "Tu negocio") está en revisión. Te avisaremos cuando esté listo.")
        } else if !list.isEmpty {
            // Texto propio: SectionTitle pasa todo a minúscula y "Apartalo" es un nombre.
            HStack(spacing: 8) {
                Text("Tus negocios")
                    .font(.system(.title3).weight(.bold))
                    .foregroundStyle(Color.brand)
                Text("\(list.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.paleSage, in: Capsule())
            }
            VStack(spacing: Spacing.sm) {
                ForEach(list) { b in
                    HStack(spacing: 12) {
                        Image(systemName: "storefront")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.brand)
                            .frame(width: 44, height: 44)
                            .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).font(BT.headline).foregroundStyle(Color.ink)
                            Text((AccountStore.shared.businesses.contains { $0.id == b.farmId } ? "Ya vinculado · " : "")
                                 + (b.role == "owner" ? "Dueña o dueño" : "Equipo"))
                                .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .cardShadow()
                }
            }
            // Si todos ya están vinculados no hace falta el botón.
            if !list.allSatisfy({ b in AccountStore.shared.businesses.contains { $0.id == b.farmId } }) {
            Button { Task { await link() } } label: {
                HStack(spacing: 8) {
                    if linking { ProgressView().tint(Color.inkInverse) }
                    Text(list.count == 1 ? "Vincular este negocio" : "Vincular estos negocios").font(BT.footnoteBold)
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Color.brand, in: Capsule())
                .foregroundStyle(Color.inkInverse)
            }
            .disabled(linking)
            }
            NavigationLink(value: RegisterBusinessRoute()) {
                Text("Crear otro negocio").font(BT.footnoteBold).foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Color.sageTint, in: Capsule())
            }
        } else {
            infoCard(icon: "magnifyingglass", title: "No encontramos negocios con esta cuenta",
                     text: "¿Usaste otra cuenta? Puedes intentar con otra, o crear tu negocio.")
            Button { phase = .start; errorText = nil } label: {
                Text("Probar con otra cuenta").font(BT.footnoteBold).foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Color.sageTint, in: Capsule())
            }
            NavigationLink(value: RegisterBusinessRoute()) {
                Text("Crear negocio").font(BT.footnoteBold).foregroundStyle(Color.inkInverse)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.brand, in: Capsule())
            }
        }
    }

    private func infoCard(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.brand)
                .frame(width: 40, height: 40)
                .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BT.headline).foregroundStyle(Color.ink)
                Text(text).font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    /// Sesión de Apartalo ya guardada (se vinculó antes): no se pide entrar
    /// otra vez, se buscan los negocios directo (Keyla, 20 Nov 2026).
    private func resumeSavedSession() async {
        guard phase == .start, FincasAuth.hasSavedSession else { return }
        phase = .checking
        do {
            let token = try await FincasAuth.validIdToken()
            session = FincasAuth.Session(idToken: token, refreshToken: "", uid: "")
            answer = try await FincasAuth.session(idToken: token)
            phase = .result
        } catch {
            dlog("🏪 [LinkBusiness] sesión guardada no sirvió: \(error)")
            phase = .start   // se pide entrar como siempre
        }
    }

    private func check(_ provider: IdentityCredential.Provider) async {
        errorText = nil
        do {
            let s = try await FincasAuth.signIn(with: provider)
            session = s
            FincasAuth.save(s)
            phase = .checking
            answer = try await FincasAuth.session(idToken: s.idToken)
            phase = .result
        } catch let e as ASAuthorizationError where e.code == .canceled {
            phase = .start   // la persona cerró la ventana: sin mensaje
        } catch let e as ASAuthorizationError {
            phase = .start
            dlog("🏪 [LinkBusiness] Apple error \(e.code.rawValue)")
            errorText = "Apple no pudo iniciar sesión en este dispositivo. Prueba con Google, o revisa que haya una cuenta de Apple en Ajustes."
        } catch {
            phase = .start
            errorText = error.localizedDescription
        }
    }

    private func link() async {
        guard let s = session else { return }
        linking = true
        defer { linking = false }
        do {
            let r = try await APIClient.shared.linkFincasBusinesses(firebaseToken: s.idToken)
            let links = r.links ?? []
            let store = AccountStore.shared
            for l in links where !store.businesses.contains(where: { $0.id == l.farmId }) {
                store.businesses.append(ProtoBusiness(id: l.farmId, name: l.name, category: "Cuenta negocio", contact: ""))
            }
            if let first = links.first { store.activeBusinessId = first.farmId }
            Haptic.success()
            onDone()
        } catch {
            errorText = "No pudimos guardar el vínculo en Buddy. Puede que la integración aún no esté activada en el servidor."
            dlog("🏪 [LinkBusiness] link falló: \(error)")
        }
    }
}

// MARK: – Editar / crear producto de fincas (pantalla completa)
// Los cambios van directo a Apartalo (mismos productos, sin copias).

struct FincasProductRoute: Hashable {
    let farmId: String
    let product: FincasProduct?   // nil = producto nuevo
}

private func parseNumber(_ s: String) -> Double? {
    var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    if t.contains(",") && t.contains(".") { t = t.replacingOccurrences(of: ",", with: "") }   // 1,000.50
    else { t = t.replacingOccurrences(of: ",", with: ".") }                                   // 25,90
    return Double(t)
}

struct FincasProductEditView: View {
    let route: FincasProductRoute
    @Environment(\.dismiss) private var dismiss

    struct PresDraft: Identifiable, Hashable {
        var id: String            // id de fincas, o "new-…" si es nueva
        var size: String
        var unit: String
        var price: String
        var stock: String
        var visible: Bool
        var photos: [String] = []
        var isNew: Bool { id.hasPrefix("new-") }
    }

    @State private var name = ""
    @State private var desc = ""
    @State private var status = "draft"
    @State private var pres: [PresDraft] = []
    @State private var original: [PresDraft] = []
    @State private var saving = false
    @State private var errorText: String? = nil
    // Llaves fijas por pantalla: si se reintenta "Guardar", no se crean duplicados.
    @State private var productKey = UUID().uuidString
    @State private var presKeys: [String: String] = [:]

    private var isNew: Bool { route.product == nil }
    private let units = ["g", "kg", "ml", "L", "unidad"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text(isNew ? "Nuevo producto" : "Editar producto")
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)

                field("Nombre", text: $name, placeholder: "Ej. Café tostado")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Descripción").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    TextField("Opcional", text: $desc, axis: .vertical)
                        .lineLimit(2...4)
                        .font(BT.callout)
                        .padding(14)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                        .cardShadow()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Estado").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    HStack(spacing: 8) {
                        chip("Borrador", "draft")
                        chip("En la tienda", "active")
                        chip("Oculto", "archived")
                    }
                    Text(status == "active" ? "Se ve en Buddy."
                         : status == "archived" ? "Nadie lo ve. No se borra." : "Solo tú lo ves mientras lo preparas.")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                }

                SectionTitle(title: "Presentaciones", count: pres.count)
                ForEach($pres) { $p in presCard($p) }
                Button {
                    pres.append(PresDraft(id: "new-\(UUID().uuidString)", size: "", unit: "g", price: "", stock: "", visible: true))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Agregar presentación").font(BT.footnoteBold)
                    }
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Color.sageTint, in: Capsule())
                }

                if let errorText {
                    Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed)
                }
                Button { Task { await save() } } label: {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(Color.inkInverse) }
                        Text(isNew ? "Crear producto" : "Guardar cambios").font(BT.footnoteBold)
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.brand, in: Capsule())
                    .foregroundStyle(Color.inkInverse)
                }
                .disabled(saving)
                Text("Los cambios se guardan al instante en tu tienda.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.canvas)
        .onAppear(perform: fill)
        .task { await fillMissingPhotos() }
    }

    private func fill() {
        guard name.isEmpty, pres.isEmpty else { return }
        if let p = route.product {
            name = p.name
            desc = p.description ?? ""
            status = p.status ?? "draft"
            pres = (p.presentations ?? []).map {
                PresDraft(id: $0.id,
                          size: $0.packSize.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0)) : String($0) } ?? "",
                          unit: $0.unit ?? "g",
                          price: $0.price.map { String(format: "%.2f", $0) } ?? "",
                          stock: $0.stock.map(String.init) ?? "",
                          visible: $0.visible ?? true,
                          photos: ($0.photos ?? []).map(\.url))
            }
            original = pres
        } else {
            pres = [PresDraft(id: "new-\(UUID().uuidString)", size: "250", unit: "g", price: "", stock: "", visible: true)]
        }
    }

    /// Si el dueño subió fotos desde otra app y la lista no las trae, se toman
    /// de la lectura pública (una por presentación).
    private func fillMissingPhotos() async {
        guard let pid = route.product?.id, pres.contains(where: { $0.photos.isEmpty && !$0.isNew }) else { return }
        let pub = (try? await FincasAuth.publicProducts(farmId: route.farmId)) ?? []
        guard let match = pub.first(where: { $0.id == pid }) else { return }
        for k in pres.indices where pres[k].photos.isEmpty {
            if let url = match.presentations?.first(where: { $0.id == pres[k].id })?.photoUrl, !url.isEmpty {
                pres[k].photos = [url]
            }
        }
    }

    private func chip(_ title: String, _ value: String) -> some View {
        Button { Haptic.select(); status = value } label: {
            Text(title).font(BT.footnoteBold)
                .foregroundStyle(status == value ? Color.inkInverse : Color.brand)
                .padding(.horizontal, 14).frame(height: 38)
                .background(status == value ? Color.brand : Color.sageTint, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func presCard(_ p: Binding<PresDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tamaño y unidad").frame(maxWidth: .infinity, alignment: .leading)
                Text("Precio (S/)").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(BT.caption1).foregroundStyle(Color.inkMuted)
            HStack(spacing: 8) {
                TextField("Tamaño", text: p.size).keyboardType(.decimalPad)
                    .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                    .background(Color.canvas, in: Capsule())
                Menu {
                    ForEach(units, id: \.self) { u in Button(u) { p.wrappedValue.unit = u } }
                } label: {
                    HStack(spacing: 4) {
                        Text(p.wrappedValue.unit).foregroundStyle(Color.ink)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.brand)
                    }
                    .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                    .background(Color.canvas, in: Capsule())
                }
                TextField("S/ precio", text: p.price).keyboardType(.decimalPad)
                    .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                    .background(Color.canvas, in: Capsule())
            }
            Text("Stock (unidades, opcional)").font(BT.caption1).foregroundStyle(Color.inkMuted)
            HStack(spacing: 8) {
                TextField("Stock", text: p.stock).keyboardType(.numberPad)
                    .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                    .background(Color.canvas, in: Capsule())
                Toggle(isOn: p.visible) {
                    Text(p.wrappedValue.visible ? "Visible" : "Oculta").font(BT.footnote).foregroundStyle(Color.ink)
                }
                .tint(Color.brand)
                .fixedSize()
            }
            photoRow(p)
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    // MARK: Fotos de la presentación (máx. 3; se suben al instante)
    @State private var uploadingPres: String? = nil

    @ViewBuilder
    private func photoRow(_ p: Binding<PresDraft>) -> some View {
        let d = p.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            Text("Fotos (\(d.photos.count) de 3)").font(BT.caption1).foregroundStyle(Color.inkMuted)
            HStack(spacing: 8) {
                ForEach(d.photos, id: \.self) { url in
                    AsyncImage(url: URL(string: url)) { img in img.resizable().scaledToFill() } placeholder: { Color.paleSage }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if uploadingPres == d.id {
                    ProgressView().tint(Color.brand)
                        .frame(width: 64, height: 64)
                        .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                } else if d.photos.count < 3 && !d.isNew && route.product != nil {
                    PresPhotoPicker { data in Task { await upload(data, to: p) } }
                }
                Spacer(minLength: 0)
            }
            if d.isNew || route.product == nil {
                Text("Guarda el producto para poder subir fotos.").font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
        }
    }

    private func upload(_ data: Data, to p: Binding<PresDraft>) async {
        guard let productId = route.product?.id, let img = UIImage(data: data) else { return }
        // Máx. 1600 px y JPEG 0.8: liviano para la señal de Villa Rica.
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
        uploadingPres = p.wrappedValue.id
        errorText = nil
        defer { uploadingPres = nil }
        do {
            let url = try await FincasAuth.uploadPresentationPhoto(farmId: route.farmId, productId: productId,
                                                                    presentationId: p.wrappedValue.id,
                                                                    jpeg: jpeg, key: UUID().uuidString)
            if !url.isEmpty { p.wrappedValue.photos.append(url) }
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: nil)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(BT.footnoteBold).foregroundStyle(Color.ink)
            TextField(placeholder, text: text)
                .font(BT.callout)
                .padding(.horizontal, 16).frame(height: 50)
                .background(Color.surface, in: Capsule())
                .cardShadow()
        }
    }

    /// Valida una presentación y la convierte al formato del API.
    private func payload(_ d: PresDraft) -> [String: Any]? {
        guard let size = parseNumber(d.size), size > 0 else { errorText = "El tamaño debe ser mayor que 0."; return nil }
        guard let price = parseNumber(d.price), price >= 0 else { errorText = "Escribe el precio en soles, por ejemplo 25.90."; return nil }
        var out: [String: Any] = ["packSize": size, "unit": d.unit, "price": (price * 100).rounded() / 100, "visible": d.visible]
        let stockText = d.stock.trimmingCharacters(in: .whitespaces)
        if !stockText.isEmpty {
            guard let st = Int(stockText), st >= 0 else { errorText = "El stock es un número entero."; return nil }
            out["stock"] = st
        }
        return out
    }

    private func save() async {
        errorText = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { errorText = "Escribe el nombre del producto."; return }
        var payloads: [(PresDraft, [String: Any])] = []
        for d in pres { guard let p = payload(d) else { return }; payloads.append((d, p)) }
        saving = true
        defer { saving = false }
        do {
            let farm = route.farmId
            var productId = route.product?.id ?? ""
            if isNew {
                productId = try await FincasAuth.createProduct(farmId: farm, name: trimmed, description: desc, key: productKey)
                if status != "draft" { try await FincasAuth.updateProduct(farmId: farm, productId: productId, fields: ["status": status]) }
            } else if let p = route.product,
                      trimmed != p.name || desc != (p.description ?? "") || status != (p.status ?? "draft") {
                try await FincasAuth.updateProduct(farmId: farm, productId: productId,
                                                   fields: ["name": trimmed, "description": desc, "status": status])
            }
            for (d, body) in payloads {
                if d.isNew {
                    let key = presKeys[d.id] ?? UUID().uuidString
                    presKeys[d.id] = key
                    try await FincasAuth.createPresentation(farmId: farm, productId: productId, fields: body, key: key)
                } else if original.first(where: { $0.id == d.id }) != d {
                    try await FincasAuth.updatePresentation(farmId: farm, productId: productId, presentationId: d.id, fields: body)
                }
            }
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: farm)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: – Mi negocio: completar el perfil (horario, contacto, fotos, videos)
// Keyla, 20 Nov 2026. Se guarda en este teléfono mientras se define dónde vive
// en el servidor (spot de Buddy o fincas).

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = BusinessMedia.folder().appendingPathComponent("video-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum BusinessMedia {
    static func folder() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("business-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func url(_ file: String) -> URL { folder().appendingPathComponent(file) }
}

struct BusinessProfileEditor: View {
    let businessId: String
    let isLinked: Bool
    let hasProducts: Bool
    var onShowProducts: () -> Void = {}
    /// Con sede: la pantalla muestra solo el horario y el contenido de esa sede.
    var locationId: String? = nil
    @ObservedObject private var store = AccountStore.shared
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var contactText = ""
    @State private var aboutText = ""
    @FocusState private var aboutFocused: Bool
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var hoursExpanded = false
    @State private var generalExpanded = true
    @State private var contentExpanded = false
    @State private var locationsExpanded = true
    @State private var showLocationPicker = false
    @State private var hoursEditing = false
    @State private var draftHours: [DayHours] = []

    private let maxPhotos = 10
    private let maxVideos = 3

    private var biz: ProtoBusiness? { store.businesses.first { $0.id == businessId } }
    private var loc: BusinessLocation? { biz?.locations?.first { $0.id == locationId } }
    private var savedHours: [DayHours]? { locationId == nil ? biz?.hours : loc?.hours }
    private var hours: [DayHours] { savedHours ?? DayHours.defaults() }
    private var photos: [String] { (locationId == nil ? biz?.photoFiles : loc?.photoFiles) ?? [] }
    private var videos: [String] { (locationId == nil ? biz?.videoFiles : loc?.videoFiles) ?? [] }

    /// Escribe en la sede abierta (o en el negocio, datos viejos).
    private func updateMedia(_ change: @escaping (inout [DayHours]?, inout [String]?, inout [String]?) -> Void) {
        update { b in
            if let locationId, let k = b.locations?.firstIndex(where: { $0.id == locationId }) {
                var l = b.locations![k]
                change(&l.hours, &l.photoFiles, &l.videoFiles)
                b.locations![k] = l
            } else {
                change(&b.hours, &b.photoFiles, &b.videoFiles)
            }
        }
    }

    /// Lo que se guardó antes por negocio pasa a la sede principal (una vez).
    private func migrateToMainLocation() {
        guard locationId == nil, let b = biz,
              b.hours != nil || !(b.photoFiles ?? []).isEmpty || !(b.videoFiles ?? []).isEmpty,
              let k = b.locations?.firstIndex(where: \.isMain) ?? (b.locations?.isEmpty == false ? 0 : nil) else { return }
        update { b in
            var l = b.locations![k]
            if l.hours == nil { l.hours = b.hours }
            l.photoFiles = (l.photoFiles ?? []) + (b.photoFiles ?? [])
            l.videoFiles = (l.videoFiles ?? []) + (b.videoFiles ?? [])
            b.locations![k] = l
            b.hours = nil; b.photoFiles = nil; b.videoFiles = nil
        }
    }

    private func update(_ change: (inout ProtoBusiness) -> Void) {
        guard var b = biz else { return }
        change(&b)
        store.update(b)
    }

    var body: some View {
        if locationId != nil { locationBody } else { businessBody }
    }

    /// Ficha de una sede: horario + contenido, abiertos.
    private var locationBody: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // El nombre ya está en el título; aquí solo la dirección.
            if let a = loc?.address {
                HStack(spacing: 8) {
                    LocationPin(size: 14)
                    Text(a).font(BT.footnote).foregroundStyle(Color.inkMuted)
                }
            }
            hoursCard
            group("Contenido", icon: "photo.on.rectangle.angled",
                  summary: contentSummary, expanded: $contentExpanded) {
                photosCard
                Divider().overlay(Color.hairline)
                videosCard
            }
            if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
        }
        .onAppear { hoursExpanded = true; contentExpanded = true }
        .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
        .onChange(of: videoItems) { _, items in Task { await importVideos(items) } }
    }

    private var businessBody: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: Spacing.lg) {
            checklist(proxy)
            group("Información general", icon: "info.circle",
                  summary: generalSummary, expanded: $generalExpanded) {
                aboutCard
                Divider().overlay(Color.hairline)
                contactCard
                generalSaveBar
            }
            .id("general")
            group("Ubicaciones", icon: "app.pin",
                  summary: locationsSummary, expanded: $locationsExpanded) {
                locationsContent
            }
            .id("locations")
            if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
            Text("Por ahora se guarda en este teléfono. Pronto se publicará en tu página de Buddy.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
        }
        .onAppear { contactText = biz?.contact ?? ""; aboutText = biz?.about ?? ""; migrateToMainLocation() }
        // Los lugares reclamados se avisan al servidor: así el lugar muestra
        // los productos del negocio. Se repite sin daño (el servidor lo ignora
        // si ya es suyo).
        .task(id: locations.compactMap(\.spotId).joined()) { await syncClaims() }
        // Pantalla completa (sin hoja que sube): tapa la barra de pestañas,
        // así el botón de guardar del mapa queda visible.
        .fullScreenCover(isPresented: $showLocationPicker) {
            NavigationStack { BusinessLocationPicker(businessId: businessId) }
        }
        .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
        .onChange(of: videoItems) { _, items in Task { await importVideos(items) } }
    }

    // Qué falta, para completar el perfil.
    // Cada punto abre y muestra su sección (Keyla, 20 Nov 2026).
    private func go(_ target: String, _ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch target {
            case "general": generalExpanded = true
            case "hours": hoursExpanded = true
            case "content": contentExpanded = true
            case "locations": locationsExpanded = true
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    /// Sin fila de puntos (Keyla, 20 Nov 2026: "muchos puntitos"): barra de
    /// progreso + UN solo paso siguiente que lleva a su sección.
    private func checklist(_ proxy: ScrollViewProxy) -> some View {
        let items = ProfileChecklist.items(about: biz?.about, contact: biz?.contact, locations: locations,
                                           isLinked: isLinked, hasProducts: hasProducts)
        let done = items.filter(\.done).count
        let next = ProfileChecklist.next(items)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Completa tu perfil").font(.system(.title3).weight(.bold)).foregroundStyle(Color.brand)
                Spacer()
                Text("\(done) de \(items.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Color.paleSage, in: Capsule())
            }
            ProgressView(value: Double(done), total: Double(items.count)).tint(Color.brand)
            if let next {
                Button {
                    if next.target == "products" { onShowProducts() } else { go(next.target, proxy) }
                } label: {
                    HStack(spacing: 8) {
                        Text("Siguiente:").font(BT.footnote).foregroundStyle(Color.inkMuted)
                        Text(next.label).font(BT.footnoteBold).foregroundStyle(Color.brand)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.brand)
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Color.sageTint, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ir a la sección")
            } else {
                Text("Tu perfil está completo.").font(BT.footnote).foregroundStyle(Color.inkMuted)
            }
        }
    }

    private var generalSummary: String {
        let hasAbout = !(biz?.about ?? "").isEmpty
        let hasContact = !(biz?.contact ?? "").isEmpty
        switch (hasAbout, hasContact) {
        case (true, true): return "Descripción y contacto listos"
        case (true, false): return "Falta el contacto"
        case (false, true): return "Falta la descripción"
        default: return "Agrega descripción y contacto"
        }
    }

    private var locations: [BusinessLocation] { biz?.locations ?? [] }

    private var locationsSummary: String {
        switch locations.count {
        case 0: return "Sin ubicación · agrega dónde te encuentran"
        case 1: return locations[0].name
        default:
            let main = locations.first(where: \.isMain)?.name ?? locations[0].name
            return "\(locations.count) ubicaciones · Principal: \(main)"
        }
    }

    @ViewBuilder
    private var locationsContent: some View {
        VStack(spacing: 0) {
            ForEach(locations) { loc in
                HStack(spacing: 12) {
                    NavigationLink(value: BusinessLocationRoute(businessId: businessId, locationId: loc.id)) {
                    HStack(spacing: 12) {
                    LocationPin(size: 18)
                        .frame(width: 40, height: 40)
                        .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.name).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(2)
                        if loc.isMain {
                            Text("Principal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brand)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Color.sageTint, in: Capsule())
                        }
                        Text([loc.address, loc.spotId != nil ? (isLinked ? "Lugar en Buddy · tus productos se ven aquí" : "Reclamado · por verificar") : "Lugar nuevo · por revisar"].compactMap { $0 }.joined(separator: " · "))
                            .font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(2)
                        // Lo que falta en esta sede.
                        Text(loc.hours.map { HoursSummary.text($0) } ?? "Sin horario")
                            .font(BT.caption1).foregroundStyle(loc.hours == nil ? Color.inkMuted : Color.brand).lineLimit(2)
                        Text("\((loc.photoFiles ?? []).count) fotos · \((loc.videoFiles ?? []).count) videos · Toca para editar")
                            .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        if !loc.isMain {
                            Button { setMain(loc.id) } label: { Label("Hacer principal", systemImage: "star") }
                        }
                        Button(role: .destructive) { removeLocation(loc.id) } label: { Label("Quitar ubicación", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.brand)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Opciones de \(loc.name)")
                }
                .padding(.vertical, 6)
                Divider().overlay(Color.hairline)
            }
            Button { showLocationPicker = true } label: {
                Label(locations.isEmpty ? "Agregar ubicación" : "Agregar otra ubicación", systemImage: "plus")
                    .font(BT.footnoteBold).foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            if let claimError {
                Text(claimError).font(BT.caption1).foregroundStyle(Color.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            Text("Si tu negocio ya está en Buddy, elígelo y será tuyo. Si tienes varias sedes, agrégalas todas.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    @State private var claimError: String?

    private func syncClaims() async {
        guard isLinked else { return }
        for loc in locations {
            guard let spotId = loc.spotId else { continue }
            do {
                try await APIClient.shared.claimFincasSpot(spotId: spotId, farmId: businessId)
            } catch {
                dlog("🏪 [Claim] \(spotId.prefix(8)) \(error)")
                await MainActor.run { claimError = "No pudimos confirmar \(loc.name) como tuyo. Si ya pertenece a otro negocio, escríbenos." }
            }
        }
    }

    private func setMain(_ id: String) {
        update { b in
            b.locations = b.locations?.map { var l = $0; l.isMain = (l.id == id); return l }
        }
        Haptic.success()
    }

    private func removeLocation(_ id: String) {
        if isLinked, let spotId = locations.first(where: { $0.id == id })?.spotId {
            Task { try? await APIClient.shared.releaseFincasSpot(spotId: spotId, farmId: businessId) }
        }
        update { b in
            var list = b.locations ?? []
            let wasMain = list.first(where: { $0.id == id })?.isMain ?? false
            list.removeAll { $0.id == id }
            if wasMain, !list.isEmpty { list[0].isMain = true }
            b.locations = list.isEmpty ? nil : list
        }
    }

    private var contentSummary: String {
        let p = photos.count, v = videos.count
        if p == 0 && v == 0 { return "Sin fotos ni videos" }
        return "\(p) \(p == 1 ? "foto" : "fotos") · \(v) \(v == 1 ? "video" : "videos")"
    }

    /// Grupo plegable (Keyla, 20 Nov 2026): Información general, Contenido.
    private func group<Content: View>(_ title: String, icon: String, summary: String,
                                      expanded: Binding<Bool>, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        // El mismo pin de Inicio en toda la app (Keyla, 19 Nov 2026).
                        if icon == "app.pin" { LocationPin(size: 15) }
                        else { Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand) }
                    }
                    .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(BT.headline).foregroundStyle(Color.ink)
                        Text(summary).font(BT.footnote).foregroundStyle(Color.inkMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.brand)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded.wrappedValue ? "Ocultar" : "Mostrar")
            if expanded.wrappedValue { content() }
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    /// Parte dentro de un grupo: título pequeño, sin tarjeta propia.
    private func subsection<Content: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(BT.footnoteBold).foregroundStyle(Color.brand)
            content()
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand)
                    .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(BT.headline).foregroundStyle(Color.ink)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private let maxAbout = 300

    private var aboutCard: some View {
        return subsection("Descripción", icon: "text.alignleft") {
            ZStack(alignment: .topLeading) {
                if aboutText.isEmpty {
                    Text("Cuenta qué ofreces, qué te hace especial y qué puede vivir el visitante.")
                        .font(BT.callout).foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $aboutText)
                    .font(BT.callout).foregroundStyle(Color.ink)
                    .scrollContentBackground(.hidden)
                    .focused($aboutFocused)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(minHeight: 110)
                    .onChange(of: aboutText) { _, t in
                        if t.count > maxAbout { aboutText = String(t.prefix(maxAbout)) }
                    }
            }
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 14))
            Text("\(aboutText.count) de \(maxAbout)").font(BT.caption1).foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Un solo guardar para toda la Información general (Keyla, 20 Nov 2026).
    private var generalChanged: Bool {
        aboutText.trimmingCharacters(in: .whitespacesAndNewlines) != (biz?.about ?? "")
            || contactText.trimmingCharacters(in: .whitespaces) != (biz?.contact ?? "")
    }

    @ViewBuilder
    private var generalSaveBar: some View {
        if generalChanged {
            HStack(spacing: 8) {
                Button {
                    aboutText = biz?.about ?? ""
                    contactText = biz?.contact ?? ""
                    aboutFocused = false
                } label: {
                    Text("Cancelar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
                }
                Button {
                    let about = aboutText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let contact = contactText.trimmingCharacters(in: .whitespaces)
                    update { $0.about = about.isEmpty ? nil : about; $0.contact = contact }
                    aboutText = about; contactText = contact
                    aboutFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Haptic.success()
                } label: {
                    Text("Guardar cambios").font(BT.footnoteBold).foregroundStyle(Color.inkInverse)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.brand, in: Capsule())
                }
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    private var contactCard: some View {
        subsection("Contacto", icon: "phone") {
            TextField("WhatsApp, ej. 987654321", text: $contactText)
                .keyboardType(.phonePad)
                .font(BT.callout).padding(.horizontal, 14).frame(height: 44)
                .background(Color.canvas, in: Capsule())
        }
    }

    // Horario en acordeón (Keyla, 20 Nov 2026): cerrado muestra un resumen;
    // abierto muestra los 7 días; "Editar horario" permite cambiarlo y se guarda una sola vez.
    private var hoursCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { hoursExpanded.toggle() }
                if !hoursExpanded { hoursEditing = false }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand)
                        .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Horario de atención").font(BT.headline).foregroundStyle(Color.ink)
                        Text(hoursEditing ? HoursSummary.text(draftHours) : (savedHours == nil ? "Sin horario · toca para agregarlo" : HoursSummary.text(hours)))
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.brand)
                        .rotationEffect(.degrees(hoursExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(hoursExpanded ? "Ocultar días" : "Ver días")

            if hoursExpanded {
                if hoursEditing { hoursEditor } else { hoursReadOnly }
            }
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private var hoursReadOnly: some View {
        VStack(spacing: 0) {
            ForEach(hours) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DayHours.names[d.day]).font(BT.footnoteBold).foregroundStyle(Color.ink)
                        Text(d.open ? "\(HoursSummary.time(d.from)) – \(HoursSummary.time(d.to))" : "Sin atención")
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    Text(d.open ? "Abierto" : "Cerrado").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(d.open ? Color.brand : Color.inkMuted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(d.open ? Color.sageTint : Color.surfaceRaised, in: Capsule())
                }
                .padding(.vertical, 8)
                if d.day < 6 { Divider().overlay(Color.hairline) }
            }
            Button {
                draftHours = hours
                withAnimation { hoursEditing = true }
            } label: {
                Text(savedHours == nil ? "Agregar horario" : "Editar horario").font(BT.footnoteBold).foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
            }
            .padding(.top, 8)
        }
    }

    private var firstOpenDraftDay: Int? { draftHours.first(where: \.open)?.day }

    private func copyHours(from src: DayHours) {
        withAnimation {
            for k in draftHours.indices where draftHours[k].open {
                draftHours[k].from = src.from
                draftHours[k].to = src.to
            }
        }
        Haptic.success()
    }

    private var hoursEditor: some View {
        VStack(spacing: 0) {
            ForEach($draftHours) { $d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(DayHours.names[d.day]).font(BT.footnoteBold).foregroundStyle(Color.ink)
                        Spacer()
                        Text(d.open ? "Abierto" : "Cerrado").font(BT.caption1).foregroundStyle(Color.inkMuted)
                        Toggle("", isOn: $d.open).labelsHidden().tint(Color.brand)
                    }
                    if d.open {
                        HStack(spacing: 8) {
                            Text("De").font(BT.caption1).foregroundStyle(Color.inkMuted)
                            timePicker(d.from) { m in d.from = m }
                            Text("a").font(BT.caption1).foregroundStyle(Color.inkMuted)
                            timePicker(d.to) { m in d.to = m }
                            Spacer(minLength: 0)
                        }
                        if d.day == firstOpenDraftDay {
                            Button { copyHours(from: d) } label: {
                                Label("Copiar este horario a los demás días abiertos", systemImage: "doc.on.doc")
                                    .font(BT.caption1).foregroundStyle(Color.brand)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(.vertical, 8)
                if d.day < 6 { Divider().overlay(Color.hairline) }
            }
            HStack(spacing: 8) {
                Button { withAnimation { hoursEditing = false } } label: {
                    Text("Cancelar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
                }
                Button {
                    if let bad = draftHours.first(where: { $0.open && $0.to <= $0.from }) {
                        errorText = "\(DayHours.names[bad.day]): la hora de cierre debe ser después de la de apertura."
                        return
                    }
                    errorText = nil
                    let saved = draftHours
                    updateMedia { h, _, _ in h = saved }
                    Haptic.success()
                    withAnimation { hoursEditing = false }
                } label: {
                    Text("Guardar horario").font(BT.footnoteBold).foregroundStyle(Color.inkInverse)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.brand, in: Capsule())
                }
            }
            .padding(.top, 8)
        }
    }

    private func timePicker(_ minutes: Int, _ set: @escaping (Int) -> Void) -> some View {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return DatePicker("", selection: Binding(get: { date }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set((c.hour ?? 0) * 60 + (c.minute ?? 0))
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .tint(Color.brand)
        .environment(\.locale, Locale(identifier: "es_PE"))   // 08:00, formato de 24 horas
    }

    private var photosCard: some View {
        subsection("Fotos del negocio", icon: "photo.on.rectangle") {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(photos, id: \.self) { f in
                    ZStack(alignment: .topTrailing) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if let img = UIImage(contentsOfFile: BusinessMedia.url(f).path) {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else { Color.paleSage }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button { removePhoto(f) } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink)
                                .frame(width: 26, height: 26).background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(6)
                        .accessibilityLabel("Quitar foto")
                    }
                }
                if photos.count < maxPhotos {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: maxPhotos - photos.count, matching: .images) {
                        // Mismo tamaño que las fotos de la grilla: cuadrado que llena la columna.
                        Color.sageTint
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                                    Text("Agregar").font(BT.caption1).lineLimit(1)
                                }
                                .foregroundStyle(Color.brand)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("\(photos.count) de \(maxPhotos). La primera será la portada.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
    }

    private var videosCard: some View {
        subsection("Videos", icon: "video") {
            ForEach(videos, id: \.self) { f in
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 22)).foregroundStyle(Color.brand)
                    Text("Video \((videos.firstIndex(of: f) ?? 0) + 1)").font(BT.footnote).foregroundStyle(Color.ink)
                    Spacer()
                    Button { removeVideo(f) } label: {
                        Text("Quitar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                            .padding(.horizontal, 12).frame(height: 32).background(Color.sageTint, in: Capsule())
                    }
                }
            }
            if videos.count < maxVideos {
                PhotosPicker(selection: $videoItems, maxSelectionCount: maxVideos - videos.count, matching: .videos) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Color.brand) } else { Image(systemName: "plus").font(.system(size: 14, weight: .bold)) }
                        Text("Agregar video").font(BT.footnoteBold)
                    }
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Color.sageTint, in: Capsule())
                }
                .disabled(busy)
            }
            Text("Hasta \(maxVideos) videos cortos: cómo llegar, tu finca, tu proceso.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var added: [String] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data),
                  let jpg = img.limitedToMaxDimension(1600).jpegData(compressionQuality: 0.82) else { continue }
            let name = "photo-\(UUID().uuidString).jpg"
            do { try jpg.write(to: BusinessMedia.url(name)); added.append(name) } catch { errorText = "No pudimos guardar una foto." }
        }
        updateMedia { _, p, _ in p = (p ?? []) + added }
        photoItems = []
    }

    private func importVideos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        busy = true
        defer { busy = false }
        var added: [String] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                added.append(movie.url.lastPathComponent)
            } else { errorText = "No pudimos agregar un video." }
        }
        updateMedia { _, _, v in v = (v ?? []) + added }
        videoItems = []
    }

    private func removePhoto(_ f: String) {
        try? FileManager.default.removeItem(at: BusinessMedia.url(f))
        updateMedia { _, p, _ in p = (p ?? []).filter { $0 != f } }
    }
    private func removeVideo(_ f: String) {
        try? FileManager.default.removeItem(at: BusinessMedia.url(f))
        updateMedia { _, _, v in v = (v ?? []).filter { $0 != f } }
    }
}


/// Resumen honesto del horario: agrupa días seguidos con el mismo horario.
/// Ej.: "Lun–Vie · 8:00 a. m. – 6:00 p. m. · Sáb · 9:00 a. m. – 1:00 p. m."
enum HoursSummary {
    static let short = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]

    static func time(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let suffix = h < 12 ? "a. m." : "p. m."
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, suffix)
    }

    static func text(_ days: [DayHours]) -> String {
        let sorted = days.sorted { $0.day < $1.day }
        let open = sorted.filter(\.open)
        if open.isEmpty { return "Cerrado todos los días" }
        var groups: [(Int, Int, DayHours)] = []   // (primer día, último día, horario)
        for d in sorted where d.open {
            if let last = groups.last, last.1 == d.day - 1, last.2.from == d.from, last.2.to == d.to {
                groups[groups.count - 1].1 = d.day
            } else {
                groups.append((d.day, d.day, d))
            }
        }
        if open.count == 7, groups.count == 1 { return "Todos los días · \(time(groups[0].2.from)) – \(time(groups[0].2.to))" }
        return groups.map { g in
            let days = g.0 == g.1 ? short[g.0] : "\(short[g.0])–\(short[g.1])"
            return "\(days) · \(time(g.2.from)) – \(time(g.2.to))"
        }.joined(separator: " · ")
    }
}


/// Botón "Agregar foto" con su propio estado del selector.
struct PresPhotoPicker: View {
    let onPicked: (Data) -> Void
    @State private var item: PhotosPickerItem? = nil
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("Foto").font(BT.caption1)
            }
            .foregroundStyle(Color.brand)
            .frame(width: 64, height: 64)
            .background(Color.sageTint, in: RoundedRectangle(cornerRadius: 12))
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self) { onPicked(data) }
                item = nil
            }
        }
        .accessibilityLabel("Agregar foto")
    }
}
