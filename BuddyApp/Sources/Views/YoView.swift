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
    @State private var pendingRecommendPlace: APIPlaceCard?
    @State private var showCompartirLugar = false
    /// Journey creado por la sheet, en espera del onDismiss para recargar. El
    /// perfil no puede refrescar antes: la sheet sigue arriba y el usuario
    /// vería la lista moverse debajo.
    @State private var pendingShareJourney: APIJourney? = nil
    /// Recomendación recién creada que se abre en el editor para ponerle fotos.
    @State private var editingShareJourney: APIJourney? = nil
    @State private var pendingDraft: RecommendDraft? = nil
    @State private var editingDraft: RecommendDraft? = nil
    @State private var tripsNextCursor: String? = nil
    @State private var tripsHasMore: Bool = false
    @State private var isLoadingMoreTrips: Bool = false
    @State private var selectedStory: APIJourney? = nil   // detalle de publicación
    @Namespace private var photoZoom
    /// La publicación que se ve en el visor: al cerrar, la foto vuelve a su celda.
    @State private var zoomId: String? = nil
    /// Long-press en un trip del grid → confirmar eliminación de la publicación.
    @State private var deletePublicationTarget: APIJourney? = nil
    @State private var isLoading = true
    @State private var editingBio = false
    @State private var bioText = ""
    @State private var isSavingBio = false
    @State private var avatarCapture = false
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

                            // "Mis trips" ahora es la primera celda de Trips publicados
                            // ("Nuevo trip"), como "Añadir lugar" (Keyla, 25 Nov 2026).

                            // Entrada visible para negocios (antes solo en "⋯").
                            if accounts.businesses.isEmpty {
                                CreateBusinessEntryCard()
                                    .padding(.horizontal, Spacing.edge)
                                    .padding(.top, Spacing.md)
                            }

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
                // Deslizar pasa a la siguiente publicación del perfil.
                StoryViewerSheet(journeys: journeys, start: journey, systemDismiss: PhotoZoom.systemAvailable,
                                 onShowing: { zoomId = $0 })
                    .photoZoomDestination(id: zoomId ?? journey.id, in: photoZoom)
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
                                          locationId: route.locationId, startEditingHours: route.editHours)
                        .padding(.horizontal, Spacing.edge).padding(.top, Spacing.md).padding(.bottom, 140)
                }
                .background(Color.canvas)
                .navigationTitle(AccountStore.shared.businesses.first { $0.id == route.businessId }?
                    .locations?.first { $0.id == route.locationId }?.name ?? "Sede")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: BusinessPlaceRoute.self) { r in
                // Igual que tocar el lugar en Inicio, en modo edición (Keyla, 21 Nov 2026).
                BusinessPlaceScreen(route: r)
            }
            .navigationDestination(for: BusinessLocationPickRoute.self) { route in
                BusinessLocationPicker(businessId: route.businessId)
            }
            .navigationDestination(for: FincasProductRoute.self) { route in
                if route.product == nil { NewProductFlow(farmId: route.farmId) } else { FincasProductEditView(route: route) }
            }
            .navigationDestination(for: LinkBusinessRoute.self) { _ in
                LinkBusinessView { navPath = NavigationPath() }
            }
            .navigationDestination(for: RegisterBusinessRoute.self) { _ in
                // 3 pasos: dónde, qué ofreces, contacto (Keyla, 21 Nov 2026).
                AddBusinessFlow { navPath = NavigationPath() }
            }
            .navigationDestination(for: MyTripsRoute.self) { _ in
                TripsView(embedded: true, externalPath: $navPath)
                    .environmentObject(authState)
                    .environmentObject(routeStore)
            }
            .navigationDestination(for: APIPlaceCard.self) { place in
                PlaceGuideMapSheet(place: place)
            }
            // Recomendar: el mapa del lugar abre en Fotos con "Añadir foto".
            .navigationDestination(for: RecommendPlaceRoute.self) { route in
                PlaceGuideMapSheet(place: route.card)
                    .environment(\.recommendPhotosPlaceId, route.card.id)
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
                if let card = pendingRecommendPlace {
                    pendingRecommendPlace = nil
                    navPath.append(RecommendPlaceRoute(card: card))
                    return
                }
                if let d = pendingDraft { pendingDraft = nil; editingDraft = d; return }
                guard let nuevo = pendingShareJourney else { return }
                pendingShareJourney = nil
                editingShareJourney = nuevo
            }) {
                CompartirLugarSheet(onOpenPlace: { card in pendingRecommendPlace = card },
                                    onDraft: { d in pendingDraft = d }) { journey in
                    dlog("🌍 [YoView] compartido creado journey=\(journey.id)")
                    pendingShareJourney = journey
                }
            }
        }
        .fullScreenCover(item: $editingShareJourney) { journey in
            // publishesOnSave: no hay un paso posterior de "publicar el trip";
            // guardar es lo que deja la recomendación visible.
            // Solo fotos, sin editor (Keyla, 25 Nov 2026).
            RecomendarFotosView(journey: journey)
        }
        // Del mapa: el lugar y la recomendación se crean al publicar (Keyla, 26 Nov 2026).
        .fullScreenCover(item: $editingDraft) { d in RecomendarFotosView(draft: d) }
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
            Button { avatarCapture = true } label: {
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
            .buttonStyle(.plain)
            // Cámara al instante, con la galería en la misma pantalla (Keyla, 26 Nov 2026).
            .photoCapture(isPresented: $avatarCapture) { datas in
                if let d = datas.first { Task { await uploadAvatar(data: d) } }
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
                HStack(alignment: .top, spacing: 12) {
                    // Siempre primero: es la acción, no un elemento más de la
                    // colección. Al final habría que arrastrar toda la lista
                    // para encontrarla, y crece con cada lugar que se suma.
                    if canRecommendPlaces { addPlaceCard.frame(maxHeight: .infinity) }

                    // La misma tarjeta de "Cerca de ti" en Inicio (Keyla, 25 Nov 2026).
                    ForEach(shares, id: \.id) { place in
                        Button {
                            navPath.append(place)
                        } label: {
                            HomePlaceCard(card: place, large: false, tall: true, showsDistance: true, widthOverride: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
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
            // Mismo ancho que la tarjeta de lugar; el alto lo iguala la fila.
            .frame(maxHeight: .infinity)
            .frame(width: 120)
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

                ProfileTripsGrid(
                    journeys: journeys,
                    hasMore: tripsHasMore,
                    onTap: { zoomId = $0.id; selectedStory = $0 },
                    onDelete: { deletePublicationTarget = $0 },
                    onReachEnd: {
                        guard !isLoadingMoreTrips else { return }
                        Task { await loadMoreTrips() }
                    },
                    zoomNamespace: photoZoom,
                    visibleId: selectedStory == nil ? nil : zoomId,
                    onAdd: {
                        Haptic.medium()
                        navPath.append(MyTripsRoute())
                        // Sin trip en curso, "Nuevo trip" abre directo el registro
                        // (Keyla, 25 Nov 2026); al volver se ve el trip creado.
                        let enCurso = JourneysStore.shared.journeys.contains {
                            $0.tripId != nil && ["active", "planning"].contains($0.status ?? "")
                        }
                        if !enCurso { navPath.append("register") }
                    }
                )
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

    private func uploadAvatar(data: Data) async {
        dlog("🖼️ [uploadAvatar] iniciando…")
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

        // Volver a la pantalla (de un lugar, un mapa, una foto) NO recarga el
        // perfil: se movía todo cada vez (Keyla, 21 Nov 2026). Se recarga al
        // jalar hacia abajo o cuando algo cambió (publicar, iniciar sesión…),
        // que llaman con forceRefresh.
        if !forceRefresh, user != nil, lastFetchedAt != nil {
            dlog("👤 [YoView] perfil ya cargado — omitiendo recarga al volver")
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
            // Más alargadas, 4:5 como las tarjetas de lugar (Keyla, 25 Nov 2026).
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
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
    /// Pills en rojo de alerta (algo obligatorio falta; Keyla, 26 Nov 2026).
    var alerts: Set<String> = []
    /// Pills en ámbar: esperando algo (p. ej. revisión).
    var warnings: Set<String> = []
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { t in
                let alert = alerts.contains(t)
                let warn = warnings.contains(t)
                let tint: Color = alert ? .errorRed : (warn ? .warningAmber : .brand)
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(alert || warn ? tint.opacity(0.14) : Color.paleSage, in: Capsule())
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
    /// Para que la foto crezca desde su celda y vuelva a ella (zoom nativo, iOS 18+).
    var zoomNamespace: Namespace.ID? = nil
    /// La publicación que se ve en el visor: el perfil se desplaza detrás para
    /// tener su celda en pantalla, así al cerrar la foto vuelve a ella aunque
    /// no estuviera entre las primeras 9 (Keyla, 21 Nov 2026).
    var visibleId: String? = nil
    /// Primera celda "Nuevo trip" (abre Mis trips), como "Añadir lugar".
    var onAdd: (() -> Void)? = nil
    /// Con un trip en curso la celda muestra su vista previa y dice "Editar trip".
    @ObservedObject private var journeysStore = JourneysStore.shared
    private var currentTrip: APIJourney? {
        journeysStore.journeys.first { $0.tripId != nil && ["active", "planning"].contains($0.status ?? "") }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 8) {
                if let onAdd, let trip = currentTrip {
                    Button(action: onAdd) {
                        TripGridCell(journey: trip)
                            .overlay(alignment: .bottom) {
                                Text("Editar trip")
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(Color.inkInverse)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.brand, in: Capsule())
                                    .padding(.bottom, 10)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Editar trip en curso")
                } else if let onAdd {
                    Button(action: onAdd) {
                        Color.clear
                            .aspectRatio(4.0 / 5.0, contentMode: .fit)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Color.brand)
                                        .frame(width: 44, height: 44)
                                        .background(Color.sageTint, in: Circle())
                                    Text("Nuevo trip")
                                        .font(BT.footnoteBold)
                                        .foregroundStyle(Color.brand)
                                }
                            }
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.sage, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nuevo trip")
                }
                ForEach(journeys, id: \.id) { journey in
                    TripGridCell(journey: journey)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .modifier(OptionalZoomSource(id: journey.id, namespace: zoomNamespace))
                        .id(journey.id)
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
        // Sin animación: el visor tapa la pantalla; al cerrar ya está en su lugar.
        .onChange(of: visibleId) { _, id in
            guard let id, journeys.contains(where: { $0.id == id }) else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(id, anchor: .center) }
        }
        }
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
    /// Sin local físico (Keyla, 22 Nov 2026): solo entrega; no va al mapa.
    var noPlace: Bool? = nil
}

struct BusinessLocationPickRoute: Hashable { let businessId: String }
/// Ficha de una sede: su horario y sus fotos/videos.
struct BusinessLocationRoute: Hashable {
    let businessId: String; let locationId: String
    /// Desde "Siguiente: Agrega el horario…": abre con el horario ya en edición (Keyla, 26 Nov 2026).
    var editHours: Bool = false
}

/// Agregar una sede (Keyla, 20 Nov 2026): primero se buscan los lugares de
/// Buddy cercanos, porque un buddy o un turista pudo crearlo antes; el negocio
/// lo reclama como suyo en vez de duplicarlo. Si no está, el mismo mapa de
/// "Compartir un lugar". Antes de guardar un punto nuevo se revisa otra vez si
/// hay un lugar a pocos metros.
struct BusinessLocationPicker: View {
    let businessId: String
    /// Modo paso de "Agrega tu negocio" (Keyla, 21 Nov 2026): devuelve el lugar
    /// elegido en vez de guardarlo en un negocio que aún no existe.
    var onPicked: ((BusinessLocation) -> Void)? = nil
    /// Nombre de la sede = nombre del negocio (sin campo extra).
    var knownName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AccountStore.shared
    private var businessName: String? {
        knownName ?? store.businesses.first(where: { $0.id == businessId })?.name
    }
    // Primero las opciones de "Añadir lugar"; el mapa es una de ellas.
    @State private var step: Step = .nearby
    @State private var nearby: [APINearbySpot] = []
    @State private var loadingNearby = true
    @State private var errorText: String?
    @State private var pendingNew: (name: String, lat: Double, lng: Double)?
    @State private var closeToNew: [APINearbySpot] = []
    @State private var mapPlaces: [MKMapItem] = []
    enum Step { case coverFirst, nearby, map, confirmNew, noPlace, cover }
    /// Mi negocio: primero la foto de portada, después la ubicación (Keyla, 26 Nov 2026).
    private var coverFirst: Bool { onPicked == nil }
    @State private var pendingCover: Data?
    @State private var finishing = false
    /// Una sola pantalla: portada + ubicación + Guardar (Keyla, 26 Nov 2026).
    enum PendingPick { case place(name: String, lat: Double, lng: Double, spotId: String?), noPlace }
    @State private var pendingPick: PendingPick?
    @State private var committing = false
    /// Dirección del punto nuevo (calle), para mostrar en "Ubicación elegida".
    @State private var pendingAddress: String?
    private var previewCard: APIPlaceCard {
        APIPlaceCard(id: "preview", name: pendingPlaceName ?? businessName ?? "", destinationId: nil, destinationName: nil,
                     lat: 0, lng: 0, distanceMeters: nil, coverUrl: nil, coverUrls: nil, coverPhotos: nil,
                     coverAuthorName: nil, coverAuthorAvatarUrl: nil, category: nil,
                     photoCount: 0, isNew: false, buddyCount: 0, buddies: [])
    }
    private var pendingPlaceName: String? {
        if case .place(let name, _, _, _) = pendingPick { return name }
        return nil
    }
    private var pendingPickLabel: String? {
        switch pendingPick {
        case .place(let name, _, _, let spotId): return spotId == nil ? (pendingAddress ?? "Punto en el mapa") : name
        case .noPlace: return "No tengo local físico"
        case nil: return nil
        }
    }

    private var start: (lat: Double, lng: Double)? {
        LocationService.current?.userLocation.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    var body: some View {
        Group {
            switch step {
            case .coverFirst: coverFirstStep
            case .nearby: nearbyStep
            case .map: mapStep
            case .confirmNew: confirmNewStep
            case .noPlace: noPlaceStep
            case .cover: coverStep
            }
        }
        .modifier(PickerChrome(embedded: onPicked != nil, step: $step, hasList: !nearby.isEmpty || onPicked == nil,
                               coverFirst: coverFirst, dismiss: { dismiss() }))
        .task {
            await loadNearby()
            // Sin sugerencias de Buddy, una pantalla con un solo botón no sirve: directo al mapa.
            // En Mi negocio la lista también ofrece "No tengo local físico": no se salta.
            if nearby.isEmpty && step == .nearby && onPicked != nil { step = .map }
        }
    }

    // MARK: Paso 1: ¿tu negocio ya está en Buddy?

    private var nearbyStep: some View {
        // Misma experiencia que "Añadir lugar" (Lugares que recomiendas).
        ScrollView {
            VStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    if coverFirst { Text("Paso 1 de 2").font(BT.caption1).foregroundStyle(Color.inkMuted) }
                    Text("¿DÓNDE ESTÁ TU NEGOCIO?")
                        .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.lg)
                ForEach(nearby.prefix(5)) { spot in
                    Button { Haptic.medium(); claim(spot) } label: {
                        PlaceOptionRow(icon: "mappin.circle.fill", title: spot.name,
                                       subtitle: spot.isPendingApproval ? "\(spot.distanceLabel) · por revisar" : spot.distanceLabel)
                    }
                    .buttonStyle(.pressable)
                }
                // Solo lugares registrados en Buddy (Keyla, 21 Nov 2026).
                Button { focus = nil; focusSpotId = nil; withAnimation { step = .map } } label: {
                    PlaceOptionRow(icon: "map", title: "Buscar en el mapa", subtitle: nil)
                }
                .buttonStyle(.pressable)
                // Sin local físico (Keyla, 22 Nov 2026): solo eligen dónde entregan.
                if onPicked == nil {
                    Button {
                        // Pantalla única: "sin local" va directo al paso 2 con ciudades + portada (Keyla, 26 Nov 2026).
                        if coverFirst {
                            pendingPick = .noPlace
                            Task { await prefillCurrentCity() }
                            withAnimation { step = .coverFirst }
                        } else { withAnimation { step = .noPlace } }
                    } label: {
                        PlaceOptionRow(icon: "shippingbox", title: "No tengo local físico", subtitle: nil)
                    }
                    .buttonStyle(.pressable)
                }
                if let errorText {
                    Text(errorText).font(BT.caption1).foregroundStyle(Color.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Spacing.edge)
        }
        .background(Color.canvas)
    }

    private func useCurrentLocation() {
        guard let c = start else {
            errorText = "Activa tu ubicación o busca en el mapa."
            LocationService.current?.requestPermission()
            return
        }
        guard let name = businessName, !name.isEmpty else { withAnimation { step = .map }; return }
        Task { await checkBeforeNew(name: name, lat: c.lat, lng: c.lng) }
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

    // Tocar un lugar de la lista no guarda nada: abre el mapa ahí (Keyla, 21 Nov 2026).
    @State private var focus: (lat: Double, lng: Double)?
    @State private var focusSpotId: String?

    private func claimMapPlace(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        focus = (c.latitude, c.longitude); focusSpotId = nil
        withAnimation { step = .map }
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
            proposeTitle: coverFirst ? "Siguiente" : "Guardar ubicación",
            newEyebrow: "",
            namePlaceholder: "Nombre del lugar",
            suggestMapPlaces: true,
            fixedName: businessName,
            focus: focus,
            focusSpotId: focusSpotId,
            onSwipeBack: { if nearby.isEmpty && onPicked != nil { dismiss() } else { withAnimation { step = .nearby } } }
        )
    }

    // MARK: Sin local físico: dónde entrega

    @State private var noPlaceAreas: [CoverageDestination] = []
    @State private var savingNoPlace = false

    private var noPlaceStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    if coverFirst { Text("Paso 1 de 2").font(BT.caption1).foregroundStyle(Color.inkMuted) }
                    Text("¿EN QUÉ CIUDADES ATIENDES?")
                        .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                }
                .padding(.top, Spacing.lg)
                // Ya va la ciudad donde está; solo agrega otras si también atiende allí (Keyla, 26 Nov 2026).
                Text("Agrega otras si también atiendes allí.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                DestinationChipsPicker(selection: $noPlaceAreas, fieldColor: .surface)
                if let errorText { Text(errorText).font(BT.caption1).foregroundStyle(Color.errorRed) }
                Button {
                    if coverFirst { pendingPick = .noPlace; withAnimation { step = .coverFirst } }
                    else { Task { await saveNoPlace() } }
                } label: {
                    HStack(spacing: 8) {
                        if savingNoPlace { ProgressView().tint(Color.inkInverse) }
                        Text(coverFirst ? "Siguiente" : "Guardar").font(BT.headline)
                    }
                    .foregroundStyle(Color.inkInverse)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(noPlaceAreas.isEmpty ? Color.inkMuted.opacity(0.4) : Color.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(noPlaceAreas.isEmpty || savingNoPlace)
            }
            .padding(.horizontal, Spacing.edge)
        }
        .background(Color.canvas)
        .task { await prefillCurrentCity() }
    }

    /// La ciudad actual del dueño (misma resolución que Inicio), si aún no eligió ninguna.
    private func prefillCurrentCity() async {
        guard noPlaceAreas.isEmpty, let s = start,
              let r = try? await APIClient.shared.resolveLocation(lat: s.lat, lng: s.lng),
              noPlaceAreas.isEmpty else { return }
        noPlaceAreas = [CoverageDestination(id: r.destinationId, name: r.destinationName)]
    }

    private func saveNoPlace() async {
        guard let name = businessName, !name.isEmpty else { return }
        savingNoPlace = true
        defer { savingNoPlace = false }
        do {
            let spot = try await APIClient.shared.createAreaSpot(farmId: businessId, name: name,
                                                                 destinationIds: noPlaceAreas.map(\.id))
            guard var b = store.businesses.first(where: { $0.id == businessId }) else { return }
            var list = b.locations ?? []
            var loc = BusinessLocation(name: spot.name, lat: spot.lat, lng: spot.lng, spotId: spot.id)
            loc.noPlace = true
            loc.isMain = list.isEmpty
            list.append(loc)
            b.locations = list
            store.update(b)
            Haptic.success()
            // Sin foto no sale en Inicio: se pide la portada antes de cerrar.
            coverCtx = BusinessEditContext(businessId: businessId, locationId: loc.id, spotId: spot.id)
            if coverFirst { await uploadPendingCoverAndClose() } else { withAnimation { step = .cover } }
        } catch {
            errorText = "No pudimos guardar. Intenta de nuevo."
        }
    }

    // MARK: Último paso: la foto de portada (Keyla, 23 Nov 2026)
    // La misma tarjeta de Inicio del negocio, apagada con un "+", como la
    // tarjeta vacía de Ubicaciones. Al subirla se ve la portada real.

    @State private var coverCtx: BusinessEditContext?
    @State private var coverCapture = false
    @ObservedObject private var ownerPhotos = OwnerPhotoStore.shared

    /// Paso 1 en Mi negocio: la portada, guardada en memoria hasta elegir el lugar.
    @State private var coverFirstCapture = false
    private var coverFirstStep: some View {
        let img = pendingCover.flatMap { UIImage(data: $0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paso 2 de 2").font(BT.caption1).foregroundStyle(Color.inkMuted)
                    Text("UBICACIÓN ELEGIDA")
                        .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                }
                .padding(.top, Spacing.lg)
                Button { withAnimation { step = .nearby } } label: {
                    HStack(spacing: 12) {
                        LocationPin(size: 16)
                            .frame(width: 40, height: 40)
                            .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
                        Text(pendingPickLabel ?? "Elegir ubicación")
                            .font(BT.footnoteBold)
                            .foregroundStyle(pendingPickLabel == nil ? Color.brand : Color.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text(pendingPickLabel == nil ? "" : "Cambiar")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.brand)
                    }
                    .padding(12)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                }
                .buttonStyle(.plain)

                Text("FOTO DE PORTADA")
                    .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.sm)
                Text("Es la foto que verán los viajeros en Inicio.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { coverFirstCapture = true } label: {
                    // La misma tarjeta (y medidas) de los lugares en Inicio (Keyla, 26 Nov 2026).
                    HomePlaceCard(card: previewCard, large: false, localImage: img)
                        .overlay {
                            if img == nil {
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.white)
                                    .frame(width: 52, height: 52).background(Color.brand, in: Circle())
                                    .offset(y: -22)
                            }
                        }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(img == nil ? "Elegir foto de portada" : "Cambiar foto de portada")

                if case .noPlace = pendingPick {
                    Text("¿EN QUÉ CIUDADES ATIENDES?")
                        .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                        .padding(.top, Spacing.sm)
                    Text("Agrega otras si también atiendes allí.")
                        .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    DestinationChipsPicker(selection: $noPlaceAreas, fieldColor: .surface)
                }
                if let errorText { Text(errorText).font(BT.caption1).foregroundStyle(Color.errorRed) }
                if let e = ownerPhotos.errorText { Text(e).font(BT.caption1).foregroundStyle(Color.errorRed) }

                let citiesOK: Bool = { if case .noPlace = pendingPick { return !noPlaceAreas.isEmpty }; return true }()
                let ready = img != nil && pendingPick != nil && citiesOK && !finishing
                Button { Task { await saveAll() } } label: {
                    HStack(spacing: 8) {
                        if finishing { ProgressView().tint(Color.inkInverse) }
                        Text("Guardar ubicación").font(BT.headline)
                    }
                    .foregroundStyle(Color.inkInverse)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(ready ? Color.ink : Color.inkMuted.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .padding(.top, Spacing.sm)
            }
            .padding(.horizontal, Spacing.edge)
        }
        .background(Color.canvas)
        .photoCapture(isPresented: $coverFirstCapture) { datas in
            if let jpg = datas.first { pendingCover = jpg }
        }
    }

    private func saveAll() async {
        guard let pick = pendingPick, pendingCover != nil else { return }
        finishing = true
        committing = true
        defer { committing = false }
        switch pick {
        case .place(let name, let lat, let lng, let spotId):
            // Punto nuevo: se crea su ficha (queda en revisión) para poder guardar la portada,
            // y el negocio la reclama antes de subir la foto (Keyla, 26 Nov 2026).
            var id = spotId
            do {
                if id == nil {
                    id = try await APIClient.shared.proposeSpot(name: name, lat: lat, lng: lng).id
                }
                if let id { try await APIClient.shared.claimFincasSpot(spotId: id, farmId: businessId) }
            } catch {
                errorText = id == nil
                    ? "No pudimos crear el lugar. Revisa tu conexión e intenta de nuevo."
                    : "No pudimos confirmar este lugar como tuyo. Si ya pertenece a otro negocio, escríbenos."
                finishing = false
                return
            }
            add(name: name, lat: lat, lng: lng, spotId: id)
        case .noPlace:
            await saveNoPlace()
        }
        // add() sube la portada y cierra; si algo falló, se queda aquí con el error.
        if errorText != nil { finishing = false }
    }

    private func uploadPendingCoverAndClose() async {
        guard let ctx = coverCtx, let jpg = pendingCover else { dismiss(); return }
        finishing = true
        await ownerPhotos.add(ctx, images: [jpg])
        finishing = false
        if ownerPhotos.errorText != nil {
            // Falló la subida: se queda en el paso de portada para reintentar.
            withAnimation { step = .cover }
        } else {
            dismiss()
        }
    }

    private var coverStep: some View {
        let ctx = coverCtx
        let cover = ctx.flatMap { ownerPhotos.cover($0.spotId) }
        let uploading = ctx.map { ownerPhotos.uploading.contains($0.spotId) } ?? false
        let card = APIPlaceCard(id: ctx?.spotId ?? "new", name: businessName ?? "", destinationId: nil, destinationName: nil,
                                lat: 0, lng: 0, distanceMeters: nil, coverUrl: cover, coverUrls: nil, coverPhotos: nil,
                                coverAuthorName: nil, coverAuthorAvatarUrl: nil, category: nil,
                                photoCount: cover == nil ? 0 : 1, isNew: false, buddyCount: 0, buddies: [])
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("FOTO DE PORTADA")
                    .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.lg)
                Button { coverCapture = true } label: {
                    HomePlaceCard(card: card, large: true)
                        .id(cover ?? "none")
                        .opacity(cover == nil ? 0.5 : 1)
                        .overlay {
                            if uploading {
                                ProgressView().tint(Color.white)
                                    .frame(width: 52, height: 52).background(Color.brand, in: Circle())
                                    .offset(y: -30)
                            } else if cover == nil {
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.white)
                                    .frame(width: 52, height: 52).background(Color.brand, in: Circle())
                                    .offset(y: -30)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(uploading || ctx == nil)
                .accessibilityLabel(cover == nil ? "Elegir foto de portada" : "Cambiar foto de portada")
                if let e = ownerPhotos.errorText { Text(e).font(BT.caption1).foregroundStyle(Color.errorRed) }
                Button { dismiss() } label: {
                    Text("Listo").font(BT.headline)
                        .foregroundStyle(Color.inkInverse)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(cover == nil ? Color.inkMuted.opacity(0.4) : Color.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(cover == nil)
            }
            .padding(.horizontal, Spacing.edge)
        }
        .background(Color.canvas)
        .photoCapture(isPresented: $coverCapture) { datas in
            guard let jpg = datas.first, let ctx else { return }
            Task {
                let old = ownerPhotos.photos(ctx.spotId)
                await ownerPhotos.add(ctx, images: [jpg])
                // Cambiar la elegida: la nueva pasa a ser la portada.
                if !old.isEmpty, let new = ownerPhotos.photos(ctx.spotId).last { await ownerPhotos.makeCover(ctx, new) }
            }
        }
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
                        Button { if let lat = spot.lat, let lng = spot.lng { add(name: spot.name, lat: lat, lng: lng, spotId: spot.id) } } label: { spotRow(spot) }.buttonStyle(.plain)
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

    /// Solo lo útil (Keyla, 21 Nov 2026): lugares con un nombre parecido al del
    /// negocio, y los que están a pocos pasos. Nada de talleres a 200 m.
    private func loadNearby() async {
        guard let c = start else { loadingNearby = false; return }
        let here = CLLocation(latitude: c.lat, longitude: c.lng)
        let center = here.coordinate
        let name = businessName ?? ""
        async let spotsTask = try? await APIClient.shared.fetchNearbySpots(lat: c.lat, lng: c.lng, radius: 300)
        async let poisTask = try? await MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: center, radius: 60)).start().mapItems
        async let byNameTask: [MKMapItem]? = {
            guard !name.isEmpty else { return nil }
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = name
            r.region = MKCoordinateRegion(center: center, latitudinalMeters: 15_000, longitudinalMeters: 15_000)
            return try? await MKLocalSearch(request: r).start().mapItems
        }()
        let (spots, pois, byName) = await (spotsTask, poisTask, byNameTask)
        let dist: (CLLocation?) -> Double = { here.distance(from: $0 ?? here) }
        nearby = (spots ?? []).filter { spot in
            if NameMatch.similar(spot.name, name) { return true }
            guard let lat = spot.lat, let lng = spot.lng else { return false }
            return dist(CLLocation(latitude: lat, longitude: lng)) <= 60
        }
            .sorted { NameMatch.similar($0.name, name) && !NameMatch.similar($1.name, name) }
        let taken = Set(nearby.map { $0.name.lowercased() })
        var seen = Set<String>()
        let similar = (byName ?? []).filter { NameMatch.similar($0.name ?? "", name) }
        mapPlaces = Array((similar + (pois ?? []).sorted { dist($0.placemark.location) < dist($1.placemark.location) })
            .filter { item in
                let n = (item.name ?? "").lowercased()
                return !n.isEmpty && !taken.contains(n) && seen.insert(n).inserted
            }
            .prefix(5))
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
        focus = (lat, lng); focusSpotId = spot.id
        withAnimation { step = .map }
    }

    private func add(name: String, lat: Double, lng: Double, spotId: String?) {
        // En la pantalla única: elegir solo guarda la elección; "Guardar" la confirma.
        if coverFirst && !committing {
            pendingPick = .place(name: name.trimmingCharacters(in: .whitespaces), lat: lat, lng: lng, spotId: spotId)
            errorText = nil
            pendingAddress = nil
            if spotId == nil {
                // Punto nuevo: mostrar la calle, no el nombre del negocio (Keyla, 26 Nov 2026).
                CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)) { marks, _ in
                    guard let m = marks?.first else { return }
                    let text = [m.thoroughfare.map { t in m.subThoroughfare.map { "\(t) \($0)" } ?? t }, m.locality]
                        .compactMap { $0 }.joined(separator: ", ")
                    DispatchQueue.main.async { if !text.isEmpty { pendingAddress = text } }
                }
            }
            withAnimation { step = .coverFirst }
            return
        }
        if let onPicked {
            Haptic.success()
            onPicked(BusinessLocation(name: name.trimmingCharacters(in: .whitespaces), lat: lat, lng: lng, spotId: spotId, isMain: true))
            return
        }
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
        // La portada elegida al inicio se sube al lugar (Keyla, 26 Nov 2026).
        if let spotId {
            coverCtx = BusinessEditContext(businessId: businessId, locationId: id, spotId: spotId)
            if coverFirst { Task { await uploadPendingCoverAndClose() } } else { withAnimation { step = .cover } }
        } else {
            dismiss()
        }
    }
}

/// Barra del selector: sola (Agregar ubicación) o dentro de "Agrega tu negocio",
/// donde el flujo pone su propio encabezado y solo hace falta volver al paso 1.
private struct PickerChrome: ViewModifier {
    let embedded: Bool
    @Binding var step: BusinessLocationPicker.Step
    var hasList = true
    var coverFirst = false
    let dismiss: () -> Void
    private var atStart: Bool {
        step == .cover || step == .nearby || (step == .map && !hasList)
    }
    private func back() {
        if atStart { dismiss() }
        else if step == .coverFirst { withAnimation { step = .nearby } }
        else { withAnimation { step = step == .confirmNew ? .map : .nearby } }
    }
    func body(content: Content) -> some View {
        if embedded {
            content.safeAreaInset(edge: .top) {
                if !atStart {
                    HStack {
                        CircleBackButton { back() }
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.edge).padding(.vertical, 6)
                }
            }
        } else {
            content
                .navigationTitle("Agregar ubicación")
                .navigationBarTitleDisplayMode(.inline)
                // Barra sólida como en Compartir un lugar: el mapa empieza debajo.
                .toolbarBackground(Color.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ToolbarBackButton { back() }
                    }
                }
        }
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

    /// Trae del servidor los negocios aprobados de esta persona que aún no están
    /// en el teléfono (Keyla, 21 Nov 2026: "El encanto" aprobado no aparecía,
    /// porque la lista solo crecía al vincular o al aprobarse uno pedido aquí).
    /// Si había uno "en revisión" con el mismo nombre, se reemplaza por el aprobado.
    @MainActor
    func syncFromServer() async {
        guard let token = try? await FincasAuth.validIdToken(),
              let answer = try? await FincasAuth.session(idToken: token) else { return }
        let approved = (answer.businesses ?? []).filter { $0.farmId != nil }
        let missing = approved.filter { a in !businesses.contains { $0.id == a.farmId } }
        guard !missing.isEmpty else { return }
        _ = try? await APIClient.shared.linkFincasBusinesses(firebaseToken: token)
        for a in missing {
            guard let farmId = a.farmId else { continue }
            if let i = businesses.firstIndex(where: {
                $0.pending == true && $0.name.compare(a.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                var b = businesses[i]; b.id = farmId; b.pending = nil; b.category = "Cuenta negocio"
                if activeBusinessId == businesses[i].id { activeBusinessId = farmId }
                businesses[i] = b
            } else {
                businesses.append(ProtoBusiness(id: farmId, name: a.name, category: "Cuenta negocio", contact: ""))
            }
            dlog("🏪 [Accounts] negocio aprobado agregado: \(a.name)")
        }
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
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .cardShadow()

                // Negocios: la misma tarjeta de Inicio, con la misma foto que ve el
                // visitante (Keyla, 21 Nov 2026). En revisión: apagada, con su chip.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(store.businesses) { b in
                        Button { Haptic.select(); store.activeBusinessId = b.id; onDone() } label: {
                            HomePlaceCard(card: card(for: b), large: false)
                                .id(places[b.id]?.cover ?? b.id)
                                .opacity(b.pending == true ? 0.5 : 1)
                                .overlay(alignment: .topLeading) {
                                    if b.pending == true {
                                        Text("En revisión").font(BT.caption1.weight(.semibold)).foregroundStyle(Color.brand)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(Color.sageTint, in: Capsule())
                                            .padding(8)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: store.activeBusinessId == b.id ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(store.activeBusinessId == b.id ? Color.brand : Color.white)
                                        .background(Circle().fill(store.activeBusinessId == b.id ? Color.white : Color.black.opacity(0.25)))
                                        .padding(8)
                                }
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(b.name)
                        .accessibilityAddTraits(store.activeBusinessId == b.id ? .isSelected : [])
                    }
                }

                // Sin "Crear o vincular negocio" aquí: las cuentas ya están en la lista
                // y la opción vive en el menú "⋯" de Yo (Keyla, 20 Nov 2026).

            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
        .task {
            await store.syncFromServer()
            await loadCovers()
        }
    }

    /// Lugar de cada negocio y su portada. La portada es la primera foto de la
    /// visita más reciente: la misma regla del feed de Inicio (place_cards).
    @State private var places: [String: (spotId: String, cover: String?)] = [:]

    private func card(for b: ProtoBusiness) -> APIPlaceCard {
        let p = places[b.id]
        // Solo una categoría real del catálogo; nunca "Cuenta negocio" ni el nombre del socio.
        let category = b.isLinkedAccount || b.category == "Cuenta negocio" ? nil : b.category
        return APIPlaceCard(id: p?.spotId ?? b.id, name: b.name, destinationId: nil, destinationName: nil,
                            lat: 0, lng: 0, distanceMeters: nil,
                            coverUrl: p?.cover, coverUrls: nil, coverPhotos: nil,
                            coverAuthorName: nil, coverAuthorAvatarUrl: nil,
                            category: category, photoCount: 0, isNew: false, buddyCount: 0, buddies: [])
    }

    private func loadCovers() async {
        await withTaskGroup(of: (String, String, String?)?.self) { group in
            for b in store.businesses where places[b.id] == nil {
                group.addTask {
                    // Su ubicación principal; si no tiene, el lugar de Buddy con su mismo nombre.
                    var spotId = (b.locations ?? []).first(where: \.isMain)?.spotId ?? (b.locations ?? []).first?.spotId
                    if spotId == nil, let found = try? await APIClient.shared.searchCuratedSpots(query: b.name) {
                        spotId = found.first { $0.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
                    }
                    guard let spotId else { return nil }
                    if let owner = try? await APIClient.shared.fetchOwnerPhotos(spotId: spotId), let first = owner.first {
                        return (b.id, spotId, first.url)
                    }
                    let gallery = try? await APIClient.shared.fetchSpotGallery(spotId: spotId, limit: 1)
                    return (b.id, spotId, gallery?.visits.first?.coverPhoto)
                }
            }
            for await r in group { if let r { places[r.0] = (r.1, r.2) } }
        }
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
                              "Hospedaje", "Productos locales", "Artesanía y cultura",
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
    /// Ya se sabe cuántos productos hay: antes, el checklist mostraría un paso falso.
    @State private var remoteLoaded = false
    @State private var productToArchive: FincasProduct? = nil
    /// Producto que se está quitando: su tarjeta muestra un indicador (Keyla, 26 Nov 2026).
    @State private var archivingId: String? = nil
    @State private var remoteHasMore = false
    @State private var remoteLoading = false
    @State private var remoteError: String? = nil
    /// Solo cuando de verdad falta la sesión de Apartalo se ofrece entrar.
    @State private var remoteNeedsLogin = false
    /// "Invitar a mi equipo" (Keyla, 24 Nov 2026).
    @State private var showInvite = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                    .sheet(isPresented: $showInvite) {
                        InviteTeamSheet(farmId: live.id, businessName: live.name)
                            .presentationDetents([.medium, .large])
                    }
                if !isLinked { Color.clear.frame(height: 0).task { await checkApproval() } }  // el chip "En revisión" ya lo dice; se consulta solo (Keyla, 21 Nov 2026)
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
                                          checklistReady: !isLinked || remoteLoaded,
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
                // Sin flecha: cambiar de cuenta ya está en el menú "⋯" (Keyla, 24 Nov 2026).
                Text(live.name)
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    // "Cambiar de cuenta" primero (Keyla, 26 Nov 2026).
                    Button { onSwitchAccount() } label: {
                        Label("Cambiar de cuenta", systemImage: "arrow.left.arrow.right")
                    }
                    if isLinked {
                        Button { showInvite = true } label: {
                            Label("Invitar a mi equipo", systemImage: "person.badge.plus")
                        }
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
                        // Sin el conteo de productos (Keyla, 24 Nov 2026).
                        ? ["Vinculado", inicioStatus]
                        : ["En revisión"],
                        alerts: ["No visible en Inicio"],
                        warnings: isLinked ? ["En revisión"] : [])
                }
            }
        }
        // Ubicaciones nuevas esperan aprobación: "En revisión" hasta que se aprueben (Keyla, 26 Nov 2026).
        .task(id: (live.locations ?? []).compactMap(\.spotId).joined()) { await loadPendingSpots() }
    }

    @State private var pendingSpotIds: Set<String> = []
    /// nil = aún no se sabe; false = el negocio no tiene categoría (no sale en Inicio).
    @State private var headerHasCategory: Bool? = nil

    /// Estado del negocio en Inicio: sin ubicación, todas en revisión, o visible.
    private var inicioStatus: String {
        let locs = live.locations ?? []
        if locs.isEmpty || headerHasCategory == false { return "No visible en Inicio" }
        let ids = locs.compactMap(\.spotId)
        if !ids.isEmpty && ids.allSatisfy({ pendingSpotIds.contains($0) }) { return "En revisión" }
        return "Visible en Inicio"
    }

    private func loadPendingSpots() async {
        var pending: Set<String> = []
        for loc in live.locations ?? [] {
            guard let id = loc.spotId,
                  let near = try? await APIClient.shared.fetchNearbySpots(lat: loc.lat, lng: loc.lng, radius: 50),
                  let hit = near.first(where: { $0.id == id }) else { continue }
            if hit.isPendingApproval { pending.insert(id) }
        }
        pendingSpotIds = pending
        if isLinked, let cats = try? await APIClient.shared.fetchFarmCategories(farmId: live.id) {
            headerHasCategory = cats.main != nil
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
                        remoteCard(p)
                        .opacity(archivingId == p.id ? 0.5 : 1)
                        .overlay { if archivingId == p.id { ProgressView().tint(Color.brand) } }
                        .allowsHitTesting(archivingId != p.id)
                        .contextMenu {
                            if p.status != "archived" {
                                Button(role: .destructive) { productToArchive = p } label: { Label("Quitar producto", systemImage: "trash") }
                            }
                        }
                    }
                    if remoteHasMore {
                        ProgressView().tint(Color.brand).frame(maxWidth: .infinity).frame(height: 44)
                            .onAppear { Task { await loadRemote(reset: false) } }
                    }
                }
                Text("Toca un producto para editarlo. Mantén presionado para quitarlo.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
        }
        .confirmationDialog("¿Quitar este producto?", isPresented: Binding(get: { productToArchive != nil }, set: { if !$0 { productToArchive = nil } }),
                            titleVisibility: .visible) {
            Button("Quitar producto", role: .destructive) {
                if let p = productToArchive { Task { await archive(p) } }
                productToArchive = nil
            }
        } message: { Text("Deja de verse en Buddy. Queda como Oculto y puedes volver a mostrarlo.") }
    }

    private func archive(_ p: FincasProduct) async {
        archivingId = p.id
        defer { archivingId = nil }
        do {
            try await FincasAuth.archiveProduct(farmId: business.id, productId: p.id)
            Haptic.success()
            refreshInicioAfterOwnerChange("producto")
            await loadRemote(reset: true)
        } catch {
            remoteError = error.localizedDescription
        }
    }

    private func remoteCard(_ p: FincasProduct) -> some View {
        let photo = p.coverUrl
        let statusText: String = {
            switch p.status { case "active": return "En la tienda"; case "archived": return "Oculto"; default: return "Borrador" }
        }()
        // Agrupado por producto; cada presentación con SU foto (Keyla, 26 Nov 2026).
        // Filas separadas, precio en píldora, ocultas con ojo tachado y en gris.
        let pres = p.presentations ?? []
        return VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: FincasProductRoute(farmId: business.id, product: p)) {
            HStack(alignment: .top, spacing: 0) {
                // Nombre (sin ">", Keyla 26 Nov 2026) (se ve tocable) y la descripción en una línea
                // gris (Keyla, 26 Nov 2026).
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(BT.headline).foregroundStyle(Color.ink).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let d = p.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                        Text(d).font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(1)
                    }
                    // Estado después de la descripción: el nombre usa todo el ancho (Keyla, 26 Nov 2026).
                    Label(statusText, systemImage: p.status == "active" ? "storefront" : "eye.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.status == "active" ? Color.brand : Color.inkMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(p.status == "active" ? Color.sageTint : Color.surfaceRaised, in: Capsule())
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            ForEach(Array(pres.enumerated()), id: \.element.id) { i, pr in
                let oculta = pr.visible == false
                // Tocar una presentación abre el editor solo en ESA (Keyla, 26 Nov 2026).
                NavigationLink(value: FincasProductRoute(farmId: business.id, product: p, focusPresentationId: pr.id)) {
                HStack(spacing: 12) {
                    CachedImage(urlString: pr.photos?.first?.url ?? pr.photoUrl ?? photo) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "bag").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.brand)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.paleSage)
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(oculta ? 0.5 : 1)
                    if oculta {
                        Image(systemName: "eye.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.inkMuted)
                            .accessibilityHidden(true)
                    }
                    Text((pr.label.isEmpty ? "Presentación" : pr.label) + (oculta ? " · oculta" : ""))
                        .font(BT.footnote).foregroundStyle(oculta ? Color.inkMuted : Color.ink)
                    Spacer()
                    if let price = pr.price {
                        Text("S/ " + String(format: "%.2f", price)).font(BT.footnoteBold)
                            .foregroundStyle(oculta ? Color.inkMuted.opacity(0.6) : Color.brand)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            // Oculta: sin relleno, solo un borde tenue (Keyla, 26 Nov 2026).
                            .background(oculta ? Color.clear : Color.sageTint, in: Capsule())
                            .overlay { if oculta { Capsule().stroke(Color.inkMuted.opacity(0.2), lineWidth: 1) } }
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .overlay(alignment: .bottom) {
                    if i < pres.count - 1 {
                        Rectangle().fill(Color.inkMuted.opacity(0.15)).frame(height: 0.5)
                            .padding(.leading, 60).offset(y: 5)
                    }
                }
            }
            NavigationLink(value: FincasProductRoute(farmId: business.id, product: p, addPresentation: true)) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("Agregar presentación").font(BT.footnoteBold)
                }
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(Color.sageTint, in: Capsule())
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
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
            remoteLoaded = true
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
                    Text("¿Tienes un negocio?")
                        .font(.system(.headline).weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text("Agrégalo a Buddy en 3 pasos y muestra tus productos")
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
    /// Desde el lápiz de UNA presentación en el panel: el editor muestra solo esa
    /// (Keyla, 23 Nov 2026). Nil = todas.
    var focusPresentationId: String? = nil
    /// Desde "+ Agregar presentación" en la lista: abre con una presentación
    /// nueva vacía y solo esa (Keyla, 26 Nov 2026).
    var addPresentation: Bool = false
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
        /// url -> id de la foto en fincas (para poder quitarla).
        var photoIds: [String: String] = [:]
        var isNew: Bool { id.hasPrefix("new-") }
    }

    @State private var name = ""
    @State private var desc = ""
    @State private var status = "draft"
    @State private var pres: [PresDraft] = []
    @State private var focusId: String? = nil
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
                // Desde una presentación: título propio y sin el campo Nombre;
                // el producto se ve como subtítulo (Keyla, 26 Nov 2026).
                Text(focusId.map { $0.hasPrefix("new-") ? "Nueva presentación" : "Editar presentación" }
                     ?? (isNew ? "Nuevo producto" : "Editar producto"))
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                if focusId != nil {
                    Text(name).font(BT.subhead).foregroundStyle(Color.inkMuted)
                        .padding(.top, -12)
                } else {
                    field("Nombre", text: $name, placeholder: "Ej. Café tostado")
                }
                // Desde el lápiz de una presentación: solo nombre y esa presentación
                // (Keyla, 23 Nov 2026: descripción y estado sobran ahí).
                if focusId == nil {
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
                }

                if let focus = focusId, pres.contains(where: { $0.id == focus }) {
                    // Solo la presentación que se tocó; las demás no cambian.
                    ForEach($pres) { $p in if p.id == focus { presCard($p) } }
                } else {
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
        .fullScreenCover(item: $photoViewer) { v in PlacePhotoViewer(photos: v.photos, inicial: v.start) }
        .confirmationDialog("¿Quitar esta foto?", isPresented: Binding(get: { photoToRemove != nil }, set: { if !$0 { photoToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Quitar foto", role: .destructive) {
                if let r = photoToRemove { Task { await removePhoto(presId: r.pres, url: r.url) } }
                photoToRemove = nil
            }
        } message: { Text("Los visitantes ya no la verán.") }
        .confirmationDialog("¿Quitar esta presentación?", isPresented: Binding(get: { presToRemove != nil }, set: { if !$0 { presToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Quitar presentación", role: .destructive) {
                if let id = presToRemove { Task { await removePresentation(id) } }
                presToRemove = nil
            }
        } message: { Text("Deja de verse en Buddy. No se borra: queda como Oculta.") }
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
                          photos: ($0.photos ?? []).map(\.url),
                          photoIds: Dictionary(($0.photos ?? []).map { ($0.url, $0.id) }, uniquingKeysWith: { a, _ in a }))
            }
            original = pres
            focusId = route.focusPresentationId
            if route.addPresentation {
                let id = "new-\(UUID().uuidString)"
                pres.append(PresDraft(id: id, size: "", unit: "g", price: "", stock: "", visible: true))
                focusId = id
            }
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
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.lg))
        .contextMenu {
            if pres.count > 1 {
                Button(role: .destructive) { presToRemove = p.wrappedValue.id } label: { Label("Quitar presentación", systemImage: "trash") }
            }
        }
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
                    // Más grande (Keyla, 23 Nov 2026): 96 pt.
                    CachedImage(urlString: url) { img in img.resizable().scaledToFill() } placeholder: { Color.paleSage }
                        .frame(width: 96, height: 96)
                        .background(Color.paleSage.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { photoViewer = PresPhotoView(photos: d.photos, start: d.photos.firstIndex(of: url) ?? 0) }
                        .contextMenu {
                            Button(role: .destructive) {
                                if d.photoIds[url] != nil { photoToRemove = (d.id, url) }
                                else { errorText = "Esta foto todavía no se puede quitar desde Buddy. Pronto se podrá." }
                            } label: { Label("Quitar foto", systemImage: "trash") }
                        }
                }
                if uploadingPres == d.id {
                    ProgressView().tint(Color.brand)
                        .frame(width: 96, height: 96)
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

    @State private var photoToRemove: (pres: String, url: String)? = nil
    @State private var presToRemove: String? = nil
    struct PresPhotoView: Identifiable { let id = UUID(); let photos: [String]; let start: Int }
    @State private var photoViewer: PresPhotoView? = nil

    private func removePresentation(_ id: String) async {
        guard let k = pres.firstIndex(where: { $0.id == id }) else { return }
        if pres[k].isNew { pres.remove(at: k); return }
        guard let productId = route.product?.id else { return }
        errorText = nil
        do {
            try await FincasAuth.updatePresentation(farmId: route.farmId, productId: productId, presentationId: id, fields: ["visible": false])
            pres.remove(at: k)
            original.removeAll { $0.id == id }
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: route.farmId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func removePhoto(presId: String, url: String) async {
        guard let productId = route.product?.id, let k = pres.firstIndex(where: { $0.id == presId }),
              let photoId = pres[k].photoIds[url] else { return }
        errorText = nil
        // Mismo indicador que al subir: la foto tarda en quitarse con mala señal.
        uploadingPres = presId
        defer { uploadingPres = nil }
        do {
            try await FincasAuth.deletePresentationPhoto(farmId: route.farmId, productId: productId,
                                                         presentationId: presId, photoId: photoId)
            pres[k].photos.removeAll { $0 == url }
            pres[k].photoIds[url] = nil
            if let o = original.firstIndex(where: { $0.id == presId }) {
                original[o].photos = pres[k].photos; original[o].photoIds = pres[k].photoIds
            }
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: route.farmId)
        } catch {
            errorText = error.localizedDescription
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
            let up = try await FincasAuth.uploadPresentationPhoto(farmId: route.farmId, productId: productId,
                                                                   presentationId: p.wrappedValue.id,
                                                                   jpeg: jpeg, key: UUID().uuidString)
            if !up.url.isEmpty {
                p.wrappedValue.photos.append(up.url)
                if let id = up.id { p.wrappedValue.photoIds[up.url] = id }
            }
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
    /// Falso mientras cargan los productos: el checklist espera (Keyla, 26 Nov 2026).
    var checklistReady: Bool = true
    var onShowProducts: () -> Void = {}
    /// Con sede: la pantalla muestra solo el horario y el contenido de esa sede.
    var locationId: String? = nil
    var startEditingHours: Bool = false
    @ObservedObject private var store = AccountStore.shared
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var contactText = ""
    @State private var aboutText = ""
    @FocusState private var aboutFocused: Bool
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var hoursExpanded = false
    @State private var hoursSectionExpanded = true
    @State private var generalExpanded = true
    @State private var contentExpanded = false
    @State private var locationsExpanded = true
    /// Tocó la alerta "Obligatorio": la sección se marca en rojo hasta agregar una ubicación (Keyla, 26 Nov 2026).
    @State private var flagLocations = false
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
            // Sin "Contenido" (fotos y videos) en la sede (Keyla, 26 Nov 2026).
            if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
        }
        .onAppear {
            hoursExpanded = true; contentExpanded = true
            if startEditingHours && savedHours == nil && !hoursEditing { draftHours = hours; hoursEditing = true }
        }
        .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
        .onChange(of: videoItems) { _, items in Task { await importVideos(items) } }
    }

    private var businessBody: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Completo: el checklist desaparece (Keyla, 26 Nov 2026).
            if checklistReady && !checklistComplete { checklist(proxy) }
            group("Ubicaciones", icon: "safari",
                  summary: locationsSummary, expanded: $locationsExpanded) {
                locationsContent
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .stroke(Color.errorRed, lineWidth: 2)
                    .opacity(flagLocations && locations.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .id("locations")
            group("Información general", icon: "info.circle",
                  summary: generalSummary, expanded: $generalExpanded) {
                if isLinked {
                    categoryCard
                    Divider().overlay(Color.hairline)
                }
                aboutCard
                Divider().overlay(Color.hairline)
                contactCard
                generalSaveBar
            }
            .id("general")
            // Horario después de Información general (Keyla, 26 Nov 2026). Es de cada
            // sede: cada fila abre el horario de esa sede.
            group("Horario de atención", icon: "clock",
                  summary: hoursSectionSummary, expanded: $hoursSectionExpanded) {
                if locations.isEmpty {
                    Text("Agrega una ubicación para poner su horario.").font(BT.footnote).foregroundStyle(Color.inkMuted)
                } else {
                    ForEach(Array(locations.enumerated()), id: \.element.id) { i, loc in
                        if i > 0 { Divider().overlay(Color.hairline) }
                        NavigationLink(value: BusinessLocationRoute(businessId: businessId, locationId: loc.id, editHours: loc.hours == nil)) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if locations.count > 1 {
                                        Text(loc.name).font(BT.footnoteBold).foregroundStyle(Color.ink)
                                    }
                                    Text(loc.hours.map { HoursSummary.text($0) } ?? "Sin horario")
                                        .font(BT.footnote).foregroundStyle(loc.hours == nil ? Color.brand : Color.inkMuted)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 4)
                                Text(loc.hours == nil ? "Agregar" : "Editar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkMuted)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .id("hours")
            if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
            Text(isLinked ? "La descripción y el horario se ven en la página de tu lugar. Tu WhatsApp no se muestra." : "Por ahora se guarda en este teléfono. Pronto se publicará en tu página de Buddy.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
        }
        .onAppear { contactText = biz?.contact ?? ""; aboutText = biz?.about ?? ""; migrateToMainLocation() }
        // Los lugares reclamados se avisan al servidor: así el lugar muestra
        // los productos del negocio. Se repite sin daño (el servidor lo ignora
        // si ya es suyo).
        .task { await syncLocationsFromServer(); await syncProfileWithServer() }
        .task(id: locations.compactMap(\.spotId).joined()) {
            await findOwnPlace()
            await syncClaims()
            await loadLocationCovers()
        }
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
            case "locations":
                locationsExpanded = true
                if locations.isEmpty { flagLocations = true }
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    /// Sin fila de puntos (Keyla, 20 Nov 2026: "muchos puntitos"): barra de
    /// progreso + UN solo paso siguiente que lleva a su sección.
    private var checklistComplete: Bool {
        let spotIds = locations.compactMap(\.spotId)
        return ProfileChecklist.next(ProfileChecklist.items(about: biz?.about, contact: biz?.contact, locations: locations,
                                           isLinked: isLinked, hasProducts: hasProducts,
                                           hasPlacePhotos: spotIds.contains { !ownerPhotos.photos($0).isEmpty || feedCovers[$0] != nil },
                                           hasCategory: !categoriesLoaded || savedMain != nil)) == nil
    }

    private func checklist(_ proxy: ScrollViewProxy) -> some View {
        let spotIds = locations.compactMap(\.spotId)
        let items = ProfileChecklist.items(about: biz?.about, contact: biz?.contact, locations: locations,
                                           isLinked: isLinked, hasProducts: hasProducts,
                                           hasPlacePhotos: spotIds.contains { !ownerPhotos.photos($0).isEmpty || feedCovers[$0] != nil },
                                           hasCategory: !categoriesLoaded || savedMain != nil)
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
                // Sin ubicación: el "Siguiente" es la alerta obligatoria, en rojo (Keyla, 26 Nov 2026).
                let missingCategory = next.label == "Elige tu categoría"
                let required = (locations.isEmpty && next.target == "locations") || missingCategory
                let tint = required ? Color.errorRed : Color.brand
                let label = HStack(spacing: 8) {
                    if required {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(required ? "Obligatorio:" : "Siguiente:").font(BT.footnote)
                                .foregroundStyle(required ? tint : Color.inkMuted)
                            Text(next.label).font(BT.footnoteBold).foregroundStyle(tint)
                        }
                        if required {
                            Text(missingCategory ? "Sin categoría, tu negocio no aparece en Inicio." : "Sin ubicación, tu negocio no aparece en Inicio.")
                                .font(BT.footnote).foregroundStyle(tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                }
                .padding(.horizontal, 14).padding(.vertical, required ? 12 : 8).frame(minHeight: 44)
                .background(required ? Color.errorRed.opacity(0.10) : Color.sageTint,
                            in: RoundedRectangle(cornerRadius: required ? 16 : 22))
                // Horario: abre la primera sede sin horario, ya editándolo (Keyla, 26 Nov 2026).
                if next.label.contains("horario"), let sinHorario = locations.first(where: { $0.hours == nil }) {
                    NavigationLink(value: BusinessLocationRoute(businessId: businessId, locationId: sinHorario.id, editHours: true)) { label }
                        .buttonStyle(.plain)
                        .accessibilityHint("Abre el horario de \(sinHorario.name)")
                } else {
                    Button {
                        if next.target == "products" { onShowProducts() } else { go(next.target, proxy) }
                    } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ir a la sección")
                }
            } else {
                Text("Tu perfil está completo.").font(BT.footnote).foregroundStyle(Color.inkMuted)
            }
        }
    }

    private var hoursSectionSummary: String {
        if locations.isEmpty { return "Sin ubicaciones" }
        let sin = locations.filter { $0.hours == nil }.count
        if sin > 0 { return sin == locations.count ? "Falta el horario" : "Falta en \(sin) ubicación\(sin == 1 ? "" : "es")" }
        if locations.count == 1, let h = locations[0].hours { return HoursSummary.text(h) }
        return "Listo en \(locations.count) ubicaciones"
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
        case 0: return ""
        case 1: return locations[0].name
        default:
            let main = locations.first(where: \.isMain)?.name ?? locations[0].name
            return "\(locations.count) ubicaciones · Principal: \(main)"
        }
    }

    /// Cada sede se ve como la tarjeta de Inicio: lo que el visitante verá.
    /// Sin textos extra (Keyla, 21 Nov 2026: "no entiendo qué es Ubicaciones";
    /// la tarjeta conocida lo explica sola).
    /// Portada de cada sede con la regla del feed de Inicio: primera foto de la
    /// visita más reciente del lugar (Keyla, 21 Nov 2026: "como lo ve el visitante").
    @State private var feedCovers: [String: String] = [:]
    @ObservedObject private var ownerPhotos = OwnerPhotoStore.shared
    /// Destino de cada lugar: sin él no se abre el mapa con su panel.
    @State private var spotDestinations: [String: String] = [:]
    /// spotId -> ciudad del lugar ("Villa Rica"), bajo el nombre en Ubicaciones (Keyla, 26 Nov 2026).
    @State private var spotCities: [String: String] = [:]

    private func loadLocationCovers() async {
        for loc in locations where loc.spotId != nil && spotDestinations[loc.spotId!] == nil {
            if let found = try? await APIClient.shared.searchCuratedSpots(query: loc.name),
               let hit = found.first(where: { $0.id == loc.spotId }) {
                if let d = hit.destinationId { spotDestinations[loc.spotId!] = d }
                if let c = hit.destination?.name { spotCities[loc.spotId!] = c }
            }
        }
        for spotId in locations.compactMap(\.spotId) { await ownerPhotos.load(spotId) }
        for spotId in locations.compactMap(\.spotId) where feedCovers[spotId] == nil {
            do {
                let g = try await APIClient.shared.fetchSpotGallery(spotId: spotId, limit: 1)
                if let first = g.visits.first?.coverPhoto { feedCovers[spotId] = first }
            } catch { dlog("🏪 [Covers] error \(error)") }
        }
    }

    /// Negocio sin sedes cuyo lugar ya está en Buddy con su mismo nombre: ese lugar
    /// es su ubicación (lo que ya ve el visitante). Solo se guarda en este teléfono.
    /// Ubicaciones desde el servidor (Keyla, 23 Nov 2026): cada teléfono guardaba
    /// su propia lista y mostraban lugares distintos. Ahora manda el servidor:
    /// se agregan los lugares del negocio que falten y se quitan los que ya no son
    /// suyos. Lo propio de cada sede (horario, fotos locales) se conserva.
    /// Perfil y horarios con el servidor (Keyla, 26 Nov 2026). Lo del servidor
    /// gana; lo que solo estaba en este teléfono se sube una vez.
    private func syncProfileWithServer() async {
        guard isLinked, let server = try? await APIClient.shared.fetchFarmProfile(farmId: businessId) else { return }
        let local = biz
        if server.about != nil || server.contact != nil {
            update { $0.about = server.about; $0.contact = server.contact ?? "" }
            aboutText = server.about ?? ""; contactText = server.contact ?? ""
        } else if (local?.about ?? "").isEmpty == false || (local?.contact ?? "").isEmpty == false {
            await pushProfile(about: local?.about, contact: local?.contact)
        }
        let serverHours = server.hours ?? [:]
        for l in locations {
            guard let spotId = l.spotId else { continue }
            if let h = serverHours[spotId] {
                update { b in
                    if let k = b.locations?.firstIndex(where: { $0.id == l.id }) { b.locations![k].hours = h }
                }
            } else if let h = l.hours {
                await pushHours(spotId: spotId, hours: h)
            }
        }
    }

    private func pushProfile(about: String?, contact: String?) async {
        do { try await APIClient.shared.saveFarmProfile(farmId: businessId, about: about, contact: contact) }
        catch { errorText = "No pudimos publicar la descripción. Revisa tu conexión." }
    }

    private func pushHours(spotId: String, hours: [DayHours]) async {
        do {
            try await APIClient.shared.saveSpotHours(spotId: spotId, farmId: businessId, hours: hours)
            refreshInicioAfterOwnerChange("horario")
        } catch { errorText = "No pudimos publicar el horario. Revisa tu conexión." }
    }

    private func syncLocationsFromServer() async {
        guard isLinked, let server = try? await APIClient.shared.fetchFarmSpots(farmId: businessId) else { return }
        UserDefaults.standard.set(true, forKey: ownPlaceKey)
        let ids = Set(server.map(\.id))
        update { b in
            var list = (b.locations ?? []).filter { $0.spotId == nil || ids.contains($0.spotId!) }
            for s in server where !list.contains(where: { $0.spotId == s.id }) {
                var loc = BusinessLocation(name: s.name, lat: s.lat, lng: s.lng, spotId: s.id)
                loc.noPlace = s.noPlace == true ? true : nil
                list.append(loc)
            }
            if !list.isEmpty, !list.contains(where: \.isMain) { list[0].isMain = true }
            b.locations = list.isEmpty ? nil : list
        }
    }

    /// Solo una vez por negocio: si el dueño quita la ubicación, no vuelve sola.
    private var ownPlaceKey: String { "ownPlaceSearched.\(businessId)" }

    private func findOwnPlace() async {
        guard !UserDefaults.standard.bool(forKey: ownPlaceKey) else { return }
        guard locationId == nil, locations.isEmpty, let name = biz?.name, !name.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: ownPlaceKey)
        guard
              let found = try? await APIClient.shared.searchCuratedSpots(query: name),
              let spot = found.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }),
              let lat = spot.lat, let lng = spot.lng else { return }
        update { b in
            guard (b.locations ?? []).isEmpty else { return }
            b.locations = [BusinessLocation(name: spot.name, lat: lat, lng: lng, spotId: spot.id, isMain: true)]
        }
        dlog("🏪 [Locations] lugar propio encontrado: \(spot.name)")
    }

    /// Con lugar de Buddy: el mapa y su panel, como en Inicio. Sin él: la sede.
    private func placeRoute(_ loc: BusinessLocation) -> BusinessPlaceRoute? {
        guard let spotId = loc.spotId else { return nil }
        return BusinessPlaceRoute(businessId: businessId, locationId: loc.id, spotId: spotId,
                                  destinationId: spotDestinations[spotId], name: loc.name, lat: loc.lat, lng: loc.lng,
                                  noPlace: loc.noPlace == true)
    }

    private func locationCard(_ loc: BusinessLocation) -> some View {
        let c = placeCard(for: loc)
        // id con la portada: al llegar la foto la tarjeta se vuelve a pintar.
        return HomePlaceCard(card: c, large: false, city: loc.spotId.flatMap { spotCities[$0] })
            .id((c.coverUrl ?? loc.id) + (loc.spotId.flatMap { spotCities[$0] } ?? ""))
    }

    private func placeCard(for loc: BusinessLocation) -> APIPlaceCard {
        // Misma regla que Inicio: la foto del dueño primero, luego la última visita.
        let cover = loc.spotId.flatMap { ownerPhotos.cover($0) ?? feedCovers[$0] }
            ?? (loc.photoFiles ?? []).first.map { BusinessMedia.url($0).absoluteString }
        var card = APIPlaceCard(id: loc.id, name: loc.name, destinationId: nil, destinationName: nil,
                            lat: loc.lat, lng: loc.lng, distanceMeters: nil,
                            coverUrl: cover, coverUrls: nil, coverPhotos: nil,
                            coverAuthorName: nil, coverAuthorAvatarUrl: nil,
                            category: realCategory, photoCount: (loc.photoFiles ?? []).count,
                            isNew: false, buddyCount: 0, buddies: [])
        // Sin local: el mismo chip "A domicilio" que ve el visitante en Inicio.
        if loc.noPlace == true { card.delivers = true; card.noPlace = true }
        return card
    }

    private var ghostCard: APIPlaceCard {
        APIPlaceCard(id: "ghost", name: biz?.name ?? "", destinationId: nil, destinationName: nil,
                     lat: 0, lng: 0, distanceMeters: nil, coverUrl: nil, coverUrls: nil, coverPhotos: nil,
                     coverAuthorName: nil, coverAuthorAvatarUrl: nil, category: realCategory,
                     photoCount: 0, isNew: false, buddyCount: 0, buddies: [])
    }

    /// Solo una categoría real del catálogo; "Cuenta negocio" no lo es.
    private var realCategory: String? {
        guard let b = biz, !b.isLinkedAccount, b.category != "Cuenta negocio" else { return nil }
        return b.category
    }

    @ViewBuilder
    private var locationsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // La alerta de ubicación vive en "Siguiente"; al tocarla, la sección se marca en rojo (Keyla, 26 Nov 2026).
            if flagLocations && locations.isEmpty {
                Label("Agrega al menos una ubicación. Es obligatorio para aparecer en Inicio.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(BT.footnoteBold).foregroundStyle(Color.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(locations.sorted { $0.isMain && !$1.isMain }) { loc in
                        Group {
                            if let r = placeRoute(loc) {
                                NavigationLink(value: r) { locationCard(loc) }
                            } else {
                                NavigationLink(value: BusinessLocationRoute(businessId: businessId, locationId: loc.id)) { locationCard(loc) }
                            }
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            if !loc.isMain {
                                Button { setMain(loc.id) } label: { Label("Hacer principal", systemImage: "star") }
                            }
                            Button(role: .destructive) { removeLocation(loc.id) } label: { Label("Quitar ubicación", systemImage: "trash") }
                        }
                        .accessibilityHint("Abre su horario y fotos. Mantén presionado para más opciones.")
                    }
                    if locations.isEmpty {
                        // Sin sedes: la tarjeta de Inicio de tu negocio, apagada, con un "+".
                        // Así se ve que aparecerás en Inicio, sin palabras extra.
                        Button { showLocationPicker = true } label: {
                            HomePlaceCard(card: ghostCard, large: false)
                                .opacity(0.5)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.white)
                                        .frame(width: 52, height: 52).background(Color.brand, in: Circle())
                                        .offset(y: -18)
                                }
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Agregar ubicación")
                    }
                }
                .padding(.vertical, 4)
                // Centradas cuando caben (una sola sede queda al medio, Keyla 26 Nov 2026).
                .frame(minWidth: locationsRowWidth, alignment: .center)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { locationsRowWidth = $0 }
            // Otra sede: un botón con texto, no una tarjeta con "+" (se confundía
            // con agregar fotos, Keyla 26 Nov 2026).
            if !locations.isEmpty {
                Button { showLocationPicker = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Agregar otra ubicación").font(BT.footnoteBold)
                    }
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Color.sageTint, in: Capsule())
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }
            if let claimError {
                Text(claimError).font(BT.caption1).foregroundStyle(Color.errorRed)
            }
        }
    }

    @State private var claimError: String?
    @State private var locationsRowWidth: CGFloat = 0

    private func syncClaims() async {
        guard isLinked else { return }
        for loc in locations {
            guard let spotId = loc.spotId else { continue }
            do {
                try await APIClient.shared.claimFincasSpot(spotId: spotId, farmId: businessId)
            } catch {
                // Pedido cancelado (la pantalla se volvió a cargar): no es un rechazo.
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return }
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
        UserDefaults.standard.set(true, forKey: ownPlaceKey)
        if isLinked, let spotId = locations.first(where: { $0.id == id })?.spotId {
            Task {
                do {
                    try await APIClient.shared.releaseFincasSpot(spotId: spotId, farmId: businessId)
                    refreshInicioAfterOwnerChange("ubicación")
                } catch {
                    dlog("🏪 [Locations] no se pudo soltar \(spotId): \(error)")
                }
            }
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
                        if !summary.isEmpty { Text(summary).font(BT.footnote).foregroundStyle(Color.inkMuted) }
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

    // MARK: Categoría (Keyla, 22 Nov 2026): la misma cuadrícula de "Agrega tu
    // negocio"; una principal y hasta 2 adicionales, en todos los lugares.
    @State private var catalog: [APISpotCategory] = []
    @State private var mainCategory: String?
    @State private var extraCategories: [String] = []
    /// Lo guardado en el servidor: lo elegido solo cuenta al tocar "Guardar cambios"
    /// (una sola acción de guardar por sección, regla de diseño).
    @State private var savedMain: String?
    @State private var savedExtra: [String] = []
    @State private var categoriesLoaded = false
    @State private var categoryError: String?
    @State private var showAllCategories = false

    private var categoriesChanged: Bool { mainCategory != savedMain || extraCategories != savedExtra }

    private var categoryCard: some View {
        subsection("Categoría", icon: "square.grid.2x2") {
            if catalog.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                // Una sola categoría (Keyla, 26 Nov 2026): elegir la principal borra las extra.
                categoryCombo("Principal", selection: mainCategory, allowNone: false) { id in
                    mainCategory = id
                    extraCategories = []
                }
            }
            if let categoryError { Text(categoryError).font(BT.caption1).foregroundStyle(Color.errorRed) }
        }
        .task {
            guard !categoriesLoaded else { return }
            categoriesLoaded = true
            async let c = try? await APIClient.shared.fetchSpotCategories()
            async let f = try? await APIClient.shared.fetchFarmCategories(farmId: businessId)
            let (cats, farm) = await (c, f)
            catalog = cats ?? []
            savedMain = farm?.main; savedExtra = farm?.secondary ?? []
            mainCategory = savedMain; extraCategories = savedExtra
        }
    }

    private func categoryCombo(_ label: String, selection: String?, allowNone: Bool, onPick: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(BT.caption1).foregroundStyle(Color.inkMuted)
            Menu {
                if allowNone { Button("Ninguna") { onPick(nil) } }
                ForEach(catalog.filter { !allowNone || $0.id != mainCategory }, id: \.id) { c in Button(c.name) { onPick(c.id) } }
            } label: {
                HStack(spacing: 4) {
                    Text(catalog.first { $0.id == selection }?.name ?? "Elegir")
                        .foregroundStyle(selection == nil ? Color.inkMuted : Color.ink)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.brand)
                }
                .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                .background(Color.canvas, in: Capsule())
            }
        }
    }

    private func saveCategories() async {
        guard categoriesChanged, let main = mainCategory else { return }
        do {
            try await APIClient.shared.setFarmCategories(farmId: businessId, main: main, secondary: extraCategories)
            savedMain = main; savedExtra = extraCategories
            categoryError = nil
            showAllCategories = false
            refreshInicioAfterOwnerChange("categoría")
        } catch {
            categoryError = "No pudimos guardar la categoría. Intenta de nuevo."
        }
    }

    private var aboutCard: some View {
        return subsection("Descripción", icon: "text.alignleft") {
            ZStack(alignment: .topLeading) {
                // Crece con el texto: siempre se lee completo, sin cortarse (Keyla, 26 Nov 2026).
                TextField("Cuenta qué ofreces, qué te hace especial y qué puede vivir el visitante.",
                          text: $aboutText, axis: .vertical)
                    .lineLimit(4...)
                    .font(BT.callout).foregroundStyle(Color.ink)
                    .focused($aboutFocused)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .onChange(of: aboutText) { _, t in
                        if t.count > maxAbout { aboutText = String(t.prefix(maxAbout)) }
                    }
            }
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.errorRed, lineWidth: aboutText.count >= maxAbout ? 1.5 : 0))
            HStack {
                if aboutText.count >= maxAbout {
                    Text("Llegaste al máximo de \(maxAbout) caracteres.").font(BT.caption1).foregroundStyle(Color.errorRed)
                }
                Spacer()
                Text("\(aboutText.count) de \(maxAbout)").font(BT.caption1)
                    .foregroundStyle(aboutText.count >= maxAbout ? Color.errorRed : Color.inkMuted)
            }
        }
    }

    /// Un solo guardar para toda la Información general (Keyla, 20 Nov 2026).
    private var generalChanged: Bool {
        aboutText.trimmingCharacters(in: .whitespacesAndNewlines) != (biz?.about ?? "")
            || contactText.trimmingCharacters(in: .whitespaces) != (biz?.contact ?? "")
            || categoriesChanged
    }

    @ViewBuilder
    private var generalSaveBar: some View {
        if generalChanged {
            HStack(spacing: 8) {
                Button {
                    aboutText = biz?.about ?? ""
                    contactText = biz?.contact ?? ""
                    mainCategory = savedMain; extraCategories = savedExtra
                    showAllCategories = false
                    aboutFocused = false
                } label: {
                    Text("Cancelar").font(BT.footnoteBold).foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.sageTint, in: Capsule())
                }
                Button {
                    let about = aboutText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let contact = contactText.trimmingCharacters(in: .whitespaces)
                    update { $0.about = about.isEmpty ? nil : about; $0.contact = contact }
                    Task { await saveCategories() }
                    // Al servidor: la página del lugar muestra la descripción (Keyla, 26 Nov 2026).
                    if isLinked { Task { await pushProfile(about: about.isEmpty ? nil : about, contact: contact.isEmpty ? nil : contact) } }
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
                    if isLinked, let spotId = loc?.spotId {
                        Task { await pushHours(spotId: spotId, hours: saved) }
                    }
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
    @State private var showCapture = false
    var body: some View {
        // Cámara al instante, con la galería en la misma pantalla (Keyla, 26 Nov 2026).
        Button { showCapture = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("Foto").font(BT.caption1)
            }
            .foregroundStyle(Color.brand)
            .frame(width: 96, height: 96)
            .background(Color.sageTint, in: RoundedRectangle(cornerRadius: 12))
        }
        .photoCapture(isPresented: $showCapture) { datas in if let d = datas.first { onPicked(d) } }
        .accessibilityLabel("Agregar foto")
    }
}

/// ¿Se parecen dos nombres? Comparte una palabra de 3+ letras, sin tildes ni
/// palabras comunes ("Café Rosal" ~ "Finca Rosal").
enum NameMatch {
    private static let common: Set<String> = ["del", "las", "los", "the", "buddy", "prueba", "usar", "san", "santa"]
    static func words(_ s: String) -> Set<String> {
        Set(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !common.contains($0) })
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        !words(a).isDisjoint(with: words(b))
    }
}

/// El botón de volver de toda la app: círculo con chevron, como el detalle de un
/// lugar (Keyla, 21 Nov 2026: "el mismo botón en toda la app").
struct CircleBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(GlassCircleButtonStyle())
        .accessibilityLabel("Atrás")
    }
}

/// Lo mismo dentro de una barra de navegación: solo el chevron (iOS lo pinta en círculo).
struct ToolbarBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold))
        }
        .accessibilityLabel("Atrás")
    }
}

extension APIPlaceVisit {
    /// Primera foto de la visita (la portada del feed): la lista con páginas si
    /// el servidor la manda, si no la lista simple.
    var coverPhoto: String? { photoPages?.first?.url ?? photos.first }
}

// MARK: – Equipo: invitar con un enlace y unirse (Keyla, 24 Nov 2026)
// Usa las invitaciones de Apartalo (join-codes): un código de un solo uso que
// vence en 48 h. Si el negocio tiene "unirse sin aprobación" en Apartalo, abrir
// el enlace da acceso al instante; si no, la solicitud espera al dueño.

extension FincasAuth {
    struct JoinCode: Decodable { let code: String; let expiresAt: String? }
    struct JoinAnswer: Decodable { let status: String; let businessName: String? }

    static func authPost<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let token = try await validIdToken()
        var req = URLRequest(url: URL(string: fincasBase + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw FincasError.signIn("Tu sesión venció. Vuelve a entrar con tu cuenta.") }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw FincasError.server((json?["error"] as? String) ?? "No pudimos completar esto (\(code)). Intenta de nuevo.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func createJoinCode(businessId: String) async throws -> JoinCode {
        try await authPost("/api/auth/join-codes", body: ["businessId": businessId])
    }

    static func join(code: String) async throws -> JoinAnswer {
        try await authPost("/api/auth/join", body: ["code": code])
    }

    /// buddyapp.biz/unirse/<código>: la página abre la app, o lleva a instalarla.
    static func inviteLink(_ code: String) -> String { "https://www.buddyapp.biz/unirse/\(code)" }
}

/// Código de invitación que llegó por enlace (buddyvr://unirse/<código>).
struct JoinInvite: Identifiable, Equatable {
    let code: String
    var id: String { code }

    static func from(_ url: URL) -> JoinInvite? {
        guard url.scheme == "buddyvr", url.host == "unirse" else { return nil }
        let raw = url.lastPathComponent.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return raw.filter { $0 != "-" }.count == 8 ? JoinInvite(code: raw) : nil
    }
}

/// Negocio > ⋯ > "Invitar a mi equipo": crea el enlace y lo comparte.
struct InviteTeamSheet: View {
    let farmId: String
    let businessName: String
    @Environment(\.dismiss) private var dismiss
    @State private var link: String? = nil
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Envía este enlace a la persona que te ayudará con \(businessName). Al abrirlo y entrar con su cuenta, podrá administrar el negocio contigo.")
                    .font(BT.subhead).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Text(link)
                        .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.sageTint, in: RoundedRectangle(cornerRadius: Radius.lg))
                    ShareLink(item: "Te invito a administrar \(businessName) conmigo en Buddy. Abre este enlace: \(link)") {
                        Label("Compartir enlace", systemImage: "square.and.arrow.up")
                            .font(BT.footnoteBold)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.brand, in: Capsule())
                            .foregroundStyle(Color.inkInverse)
                    }
                    Text("Sirve para una sola persona y vence en 48 horas. Para invitar a alguien más, crea otro enlace.")
                        .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let errorText {
                    Text(errorText).font(BT.footnote).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { self.errorText = nil; Task { await create() } } label: {
                        Text("Intentar de nuevo").font(BT.footnoteBold).foregroundStyle(Color.brand)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.sageTint, in: Capsule())
                    }
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Creando el enlace").font(BT.footnote).foregroundStyle(Color.inkMuted) }
                }
                Spacer()
            }
            .padding(Spacing.edge)
            .background(Color.canvas)
            .navigationTitle("Invitar a mi equipo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .task { await create() }
        }
    }

    private func create() async {
        do {
            let token = try await FincasAuth.validIdToken()
            let answer = try await FincasAuth.session(idToken: token)
            guard let b = (answer.businesses ?? []).first(where: { $0.farmId == farmId }) else {
                errorText = "No encontramos este negocio en tu cuenta."; return
            }
            guard b.role == "owner", let businessId = b.businessId else {
                errorText = "Solo la dueña o el dueño del negocio puede invitar a otras personas."; return
            }
            let c = try await FincasAuth.createJoinCode(businessId: businessId)
            link = FincasAuth.inviteLink(c.code)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Se abre con el enlace de invitación: entra con Apple o Google y se une.
struct JoinBusinessView: View {
    let invite: JoinInvite
    let onClose: () -> Void
    private enum Phase: Equatable { case checking, signIn, joining, joined(String), pending(String), already, failed(String) }
    @State private var phase: Phase = .checking

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "person.2")
                    .font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.brand)
                    .frame(width: 72, height: 72)
                    .background(Color.paleSage, in: Circle())
                content
                Spacer()
            }
            .padding(Spacing.edge)
            .frame(maxWidth: .infinity)
            .background(Color.canvas)
            .toolbar { ToolbarItem(placement: .cancellationAction) { ToolbarBackButton { onClose() } } }
            .task { if phase == .checking { if FincasAuth.hasSavedSession { await join() } else { phase = .signIn } } }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .checking, .joining:
            title("Uniéndote al negocio")
            ProgressView()
        case .signIn:
            title("Te invitaron a un negocio")
            note("Entra con tu cuenta de Apple o Google para unirte.")
            providerButton("Continuar con Apple", icon: "apple.logo", dark: true) { await signIn(.apple) }
            providerButton("Continuar con Google", icon: "g.circle", dark: false) { await signIn(.google) }
        case .joined(let name):
            title("Ya eres parte de \(name)")
            note("Lo encuentras en Negocio. Para cambiar entre tus cuentas, usa el menú ⋯.")
            primary("Listo") { onClose() }
        case .pending(let name):
            title("Solicitud enviada")
            note("La dueña o el dueño de \(name.isEmpty ? "el negocio" : name) debe aprobarla. Te avisaremos cuando puedas entrar.")
            primary("Listo") { onClose() }
        case .already:
            title("Ya eres parte de este negocio")
            primary("Listo") { onClose() }
        case .failed(let msg):
            title("No pudimos unirte")
            note(msg)
            primary("Cerrar") { onClose() }
        }
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(.title2).weight(.bold)).foregroundStyle(Color.brand).multilineTextAlignment(.center)
    }
    private func note(_ t: String) -> some View {
        Text(t).font(BT.subhead).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func primary(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(BT.footnoteBold).frame(maxWidth: .infinity).frame(height: 52)
                .background(Color.brand, in: Capsule()).foregroundStyle(Color.inkInverse)
        }
    }
    private func providerButton(_ t: String, icon: String, dark: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(t, systemImage: icon).font(BT.footnoteBold)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(dark ? Color.black : Color.surface, in: Capsule())
                .foregroundStyle(dark ? Color.white : Color.ink)
                .overlay(Capsule().stroke(Color.border, lineWidth: dark ? 0 : 1))
        }
    }

    private func signIn(_ provider: IdentityCredential.Provider) async {
        do {
            let s = try await FincasAuth.signIn(with: provider)
            FincasAuth.save(s)
            await join()
        } catch let e as ASAuthorizationError where e.code == .canceled {
            phase = .signIn
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func join() async {
        phase = .joining
        do {
            let a = try await FincasAuth.join(code: invite.code)
            switch a.status {
            case "joined", "already_member":
                await AccountStore.shared.syncFromServer()
                let store = AccountStore.shared
                if let name = a.businessName,
                   let b = store.businesses.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                    store.activeBusinessId = b.id
                }
                Haptic.success()
                phase = a.status == "joined" ? .joined(a.businessName ?? "el negocio") : .already
            default:
                phase = .pending(a.businessName ?? "")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}



// MARK: - Recomendar: solo fotos (sin editor)

/// Después de elegir el lugar que recomienda, la persona solo agrega fotos
/// (Keyla, 25 Nov 2026: el editor confundía). Reusa la tarjeta "Añadir foto"
/// del dueño en Mi negocio (DashedAddTile + selector de fotos).
struct RecomendarFotosView: View {
    /// Journey ya creado (flujo antiguo) o un borrador que se crea al publicar.
    var journey: APIJourney? = nil
    var draft: RecommendDraft? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showCapture = false
    @State private var photos: [UIImage] = []
    @State private var loading = false
    private let maxPhotos = 10
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(draft?.title ?? journey?.spot?.name ?? journey?.title ?? "Tu recomendación")
                        .font(BT.title2).foregroundStyle(Color.ink)
                    Text("Agrega fotos de este lugar para recomendarlo.")
                        .font(BT.callout).foregroundStyle(Color.inkMuted)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(photos.indices, id: \.self) { i in
                            Image(uiImage: photos[i])
                                .resizable().scaledToFill()
                                .frame(width: 115, height: 115)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button { photos.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .padding(4)
                                    .accessibilityLabel("Quitar foto")
                                }
                        }
                        if photos.count < maxPhotos {
                            Button { showCapture = true } label: {
                                DashedAddTile(title: "Añadir foto", loading: loading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.edge)
            }
            .background(Color.canvas)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptic.medium()
                    publish()
                } label: {
                    Text("Publicar")
                        .font(BT.footnoteBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(photos.isEmpty ? Color.inkMuted : Color.ink)
                        .foregroundStyle(Color.inkInverse)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(photos.isEmpty)
                .padding(.horizontal, Spacing.edge)
                .padding(.bottom, Spacing.sm)
                .background(Color.canvas)
            }
            .navigationTitle("Recomendar lugar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                        .accessibilityLabel("Atrás")
                }
            }
        }
        .photoCapture(isPresented: $showCapture, maxCount: max(1, maxPhotos - photos.count)) { datas in
            let added = datas.compactMap { UIImage(data: $0) }
            photos.append(contentsOf: added.prefix(maxPhotos - photos.count))
        }
    }

    /// Guarda cada foto como página y publica en segundo plano: el aviso de
    /// subida (UploadStatusBanner) muestra el avance y permite reintentar.
    private func publish() {
        let imgs = photos
        guard !imgs.isEmpty else { return }
        let existing = journey; let d = draft
        dismiss()
        Task {
            // Recién aquí se crean el lugar (si es nuevo) y la recomendación.
            var j = existing
            if j == nil, let d {
                var spotId = d.spotId
                if spotId == nil, let name = d.newName {
                    spotId = try? await APIClient.shared.proposeSpot(name: name, lat: d.lat, lng: d.lng, categoryId: d.categoryId).id
                }
                guard let spotId else { return }
                j = try? await APIClient.shared.createJourney(spotId: spotId, attachToTrip: false)
            }
            guard let j else { return }
            let jId = j.id
            let pages = imgs.compactMap { MemoirPersistence.shared.photoPage($0, journeyId: jId) }
            guard !pages.isEmpty else { return }
            MemoirPersistence.shared.save(pages, journeyId: jId)
            try? await APIClient.shared.publishJourney(journeyId: jId, tripId: j.tripId, pages: pages)
            await MainActor.run {
                Haptic.success()
                NotificationCenter.default.post(name: .journeyPublished, object: jId)
            }
        }
    }
}


/// Ruta al mapa de un lugar para recomendarlo con fotos.
struct RecommendPlaceRoute: Hashable { let card: APIPlaceCard }


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
