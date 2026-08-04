import SwiftUI
import PhotosUI
import AuthenticationServices

// MARK: – YO (PROFILE)


struct YoView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var locationService: LocationService
    /// Todo el estado de datos vive en el ViewModel: perfil, trips, lugares,
    /// cachés por bloque y paginación. Acá solo queda lo que es de la vista —qué
    /// sheet está abierta, qué se está editando, a dónde navega.
    @StateObject private var vm = YoViewModel()
    @State private var showCompartirLugar = false
    /// Journey creado por la sheet, en espera del onDismiss para recargar. El
    /// perfil no puede refrescar antes: la sheet sigue arriba y el usuario
    /// vería la lista moverse debajo.
    @State private var pendingShareJourney: APIJourney? = nil
    /// Lugar que el buddy eligió y que YA recomendaba — se abre su ficha al
    /// cerrarse la hoja, en vez de crear una recomendación duplicada.
    @State private var pendingExistingShare: APIPlaceCard? = nil
    @State private var selectedStory: APIJourney? = nil   // detalle de publicación
    /// Long-press en un trip del grid → confirmar eliminación de la publicación.
    @State private var deletePublicationTarget: APIJourney? = nil
    @State private var editingBio = false
    @State private var bioText = ""
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var showBecomeBuddyConfirm = false
    @State private var isBecomingBuddy = false
    @State private var showNameSheet = false
    @State private var suggestedNameForProfile = ""
    @State private var profileSocialLoading = false
    @State private var profileSocialError: String? = nil
    // Guardia de logout: si hay apoyo activo no se puede cerrar sesión sin confirmar
    @State private var showActiveHelpLogoutAlert = false

    /// Push, no modal: un push dentro de este stack respeta la barra de tabs
    /// de la app; un .fullScreenCover la tapa siempre.
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            Group {
                // ── Estado anónimo ──
                if !authState.isLoggedIn {
                    anonymousState
                } else if vm.isLoadingProfile {
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

                            // 3 — Rol buddy (fila nav o CTA), antes de la colección
                            buddyRow
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.xl)

                            if vm.buddyMe?.isBuddy != true {
                                if vm.unattendedCount > 0 {
                                    unattendedDemandCTA
                                        .padding(.horizontal, Spacing.edge)
                                        .padding(.top, Spacing.md)
                                } else {
                                    becomeBuddyCTA
                                        .padding(.horizontal, Spacing.edge)
                                        .padding(.top, Spacing.md)
                                }
                            }

                            // 4 — Colección (historia del viajero)
                            stickerSection
                                .padding(.top, Spacing.xl)

                            // Visible si puede aportar (necesita la entrada) o
                            // si ya aportó (no se le esconde lo suyo aunque su
                            // verificación haya cambiado después).
                            if canRecommendPlaces || !vm.shares.isEmpty {
                                sharesSection
                                    .padding(.top, Spacing.xl)
                            }

                            tripsSection
                                .padding(.top, Spacing.xl)
                        }
                        .padding(.bottom, Spacing.xl).safeAreaPadding(.bottom)
                    }
                    .refreshable { await vm.load(force: true) }
                    .background(Color.canvas)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // Detalle de la publicación — mismo visor que en Home
            .sheet(item: $selectedStory) { journey in
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
                    if let t = deletePublicationTarget { vm.deletePublication(t) }
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
                    Task { await vm.load(force: true) }
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
            .alert("No se pudo guardar la bio", isPresented: $vm.bioSaveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Tu bio no se guardó. Verifica tu conexión e inténtalo de nuevo.")
            }
            .alert("No se pudo subir la foto", isPresented: $vm.avatarUploadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Tu foto de perfil no se actualizó. Verifica tu conexión e inténtalo de nuevo.")
            }
            .navigationDestination(for: APIPlaceCard.self) { place in
                PlaceGuideMapSheet(place: place)
            }
            .navigationDestination(for: TravelerProfileRoute.self) { r in
                UserProfileView(route: r)
            }
            // La navegación va en onDismiss y no en el callback: empujar en el
            // navPath mientras la hoja todavía se está cerrando encima hace que
            // el push se vea a medias o se pierda.
            .sheet(isPresented: $showCompartirLugar, onDismiss: {
                // Caso 1 — ya recomienda ese lugar: se va a su ficha, que es
                // donde vive "Añadir foto". Elegir un lugar que ya es tuyo es
                // pedir sumarle algo, no empezarlo de nuevo.
                if let existing = pendingExistingShare {
                    pendingExistingShare = nil
                    print("🌍 [YoView] lugar ya recomendado → abriendo su ficha")
                    navPath.append(existing)
                    return
                }
                // Caso 2 — lugar nuevo: el journey nace con trip_id=null y sin
                // publicar, así que todavía no puede aparecer en la sección
                // (place_cards_by_traveler exige is_public, completed y fotos).
                // La recarga sola no alcanza; falta encadenar el editor.
                guard pendingShareJourney != nil else { return }
                pendingShareJourney = nil
                Task { await vm.load(force: true) }
            }) {
                CompartirLugarSheet(
                    alreadyRecommended: Set(vm.shares.map { $0.id.lowercased() }),
                    onExisting: { spotId in
                        pendingExistingShare = vm.shares.first {
                            $0.id.caseInsensitiveCompare(spotId) == .orderedSame
                        }
                    }
                ) { journey in
                    print("🌍 [YoView] compartido creado journey=\(journey.id)")
                    pendingShareJourney = journey
                }
            }
        }
        .task { await vm.load() }
        .task { await vm.loadUnattendedDemand(location: locationService.userLocation) }
        // Cada aviso invalida SOLO el bloque que le corresponde. Antes los
        // tres forzaban la recarga entera: desbloquear un sticker volvía a pedir
        // los trips y los lugares sin ningún motivo.
        .onReceive(NotificationCenter.default.publisher(for: .stickerUnlocked)) { _ in
            vm.invalidateProfile()
            Task { await vm.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
            vm.invalidatePhotos()
            Task { await vm.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .placePhotosChanged)) { _ in
            vm.invalidatePhotos()
            Task { await vm.load() }
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
                    CachedImage(urlString: vm.user?.avatarUrl) { img in
                        img.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.sand)
                            .frame(width: 88, height: 88) // ancla el placeholder al mismo tamaño
                    }
                    if vm.isUploadingAvatar {
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
            .accessibilityLabel("Cambiar foto de perfil")
            .accessibilityHint("Abre el selector de fotos")
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item: item) }
            }

            // Identidad — el nombre lidera, luego la narrativa
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.user?.fullName ?? "Tú")
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(metaLine)
                    .font(BT.subhead)
                    .foregroundStyle(Color.inkMuted)
                if let since = vm.user?.memberSince {
                    Text("Viajando desde \(memberSinceLabel(date: since))")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        let trips = vm.journeys.count
        let tripsLabel = trips == 1 ? "1 trip" : "\(trips) trips"
        let stickersLabel = vm.stickers.isEmpty ? nil
            : (vm.stickers.count == 1 ? "1 sticker" : "\(vm.stickers.count) stickers")
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
                            bioText = vm.user?.bio ?? ""
                            editingBio = false
                        }
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)

                        Spacer()

                        Button {
                            saveBio()
                        } label: {
                            if vm.isSavingBio {
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
                        .disabled(vm.isSavingBio)
                    }
                }
            } else {
                // Toda la fila es tappeable — target ≥ 44pt
                Button {
                    bioText = vm.user?.bio ?? ""
                    editingBio = true
                } label: {
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        if let bio = vm.user?.bio, !bio.isEmpty {
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
        if let bm = vm.buddyMe, bm.isBuddy, let p = bm.profile {
            // IS BUDDY — fila navegable hacia BuddyProfileView
            NavigationLink {
                BuddyProfileView(profile: p, destinations: vm.destinations) { updated in
                    vm.setBuddyMe(updated)
                }
            } label: {
                BuddyNavRow(profile: p, destinations: vm.destinations)
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
                    Text(vm.unattendedCount == 1
                         ? "1 persona buscó un buddy en \(vm.unattendedPlaceName)"
                         : "\(vm.unattendedCount) personas buscaron un buddy en \(vm.unattendedPlaceName)")
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
            sectionHeader("STICKERS", count: vm.stickers.count)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(vm.stickers, id: \.id) { s in
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
                    ForEach(0..<max(0, 3 - vm.stickers.count), id: \.self) { _ in
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
    private var canRecommendPlaces: Bool {
        vm.buddyMe?.profile?.verificationStatus == "approved"
    }

    private var sharesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("LUGARES QUE RECOMIENDAS", count: vm.shares.count)

            ScrollView(.horizontal, showsIndicators: false) {
                // 3 como la grilla de TRIPS, y no solo entre el "+" y su vecino:
                // una separación distinta en un único hueco se lee como error de
                // maquetado, no como intención. Con el mismo valor las dos
                // secciones del perfil se leen como una sola colección.
                //
                // LazyHStack y no HStack: el normal construye TODAS las tarjetas
                // al aparecer, así que cada portada arranca su descarga aunque
                // esté fuera de pantalla. Con un lugar no se nota; con veinte, la
                // sección compite por ancho de banda con el resto del perfil.
                LazyHStack(spacing: 3) {
                    // Siempre primero: es la acción, no un elemento más de la
                    // colección. Al final habría que arrastrar toda la lista
                    // para encontrarla, y crece con cada lugar que se suma.
                    if canRecommendPlaces { addPlaceCard }

                    ForEach(vm.shares, id: \.id) { place in
                        // En el perfil el pie es cuántas fotos aportó a ese
                        // lugar; los buddies del destino no vienen al caso aquí.
                        NearbyPlaceCard(place: place, subtitleOverride: place.photoLabel) {
                            navPath.append(place)
                        }
                        .onAppear { vm.shareAppeared(place) }
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
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.brand)
                Text("Añadir lugar")
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(width: 132, height: 158)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Color.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Trips grid

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("TRIPS", count: vm.journeys.count)

            if vm.journeys.isEmpty {
                // Empty state — invita a la acción, no lamenta el vacío
                Button {
                    router.switchTo(.trips)
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
                // Sin celda de alta: con trips publicados, el grid es la
                // vitrina de lo hecho y crear vive en su propio tab. El vacío ya
                // tiene su invitación arriba, que es donde hace falta.
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(vm.journeys, id: \.id) { journey in
                        TripGridCell(journey: journey)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            .onTapGesture {
                                Haptic.light()
                                selectedStory = journey
                            }
                            // Long-press del dueño → eliminar la publicación
                            .contextMenu {
                                Button(role: .destructive) {
                                    deletePublicationTarget = journey
                                } label: {
                                    Label("Eliminar publicación", systemImage: "trash")
                                }
                            }
                            .onAppear { vm.tripAppeared(journey) }
                    }
                }
                .padding(.horizontal, Spacing.edge)

                // La siguiente página ya viene en camino desde el 80%; esto solo
                // ocupa el sitio mientras llega, para que el grid no dé un salto
                // al aparecer la fila nueva.
                if vm.tripsHasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
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
        vm.signedOut()
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
                            Image(systemName: "figure.walk.arrival")
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
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.border, lineWidth: 1))
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
            Task { await vm.load(force: true) }
        case .needsProfileCompletion:
            let name = result.suggestedName ?? ""
            if name.trimmingCharacters(in: .whitespaces).count >= 2 {
                Task {
                    try? await AuthService.shared.completeProfileForSocialLogin(
                        fullName: name.trimmingCharacters(in: .whitespaces)
                    )
                    authState.didAuthenticate()
                    await vm.load(force: true)
                }
            } else {
                suggestedNameForProfile = name
                showNameSheet = true
            }
        }
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
        Task {
            if await vm.saveBio(bioText) { editingBio = false }
        }
    }

    private func uploadAvatar(item: PhotosPickerItem) async {
        // Decodificar y comprimir es cosa de la vista: nace de un PhotosPicker,
        // que es UI. El VM recibe bytes ya listos y no sabe qué es un
        // PhotosPickerItem.
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            print("🖼️ [uploadAvatar] ❌ loadTransferable falló — formato no soportado")
            return
        }
        guard let uiImg = UIImage(data: data),
              let jpeg = uiImg.limitedToMaxDimension(400).jpegData(compressionQuality: 0.85) else {
            print("🖼️ [uploadAvatar] ❌ compresión JPEG falló")
            return
        }
        print("🖼️ [uploadAvatar] \(data.count / 1024) KB → \(jpeg.count / 1024) KB")
        await vm.uploadAvatar(jpegData: jpeg)
    }

    private func becomeBuddy() async {
        guard !isBecomingBuddy else { return }
        isBecomingBuddy = true
        defer { isBecomingBuddy = false }
        do { _ = try await vm.becomeBuddy(); Haptic.success() }
        catch { Haptic.error() }
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
        ("transport", "Transporte"), ("food", "Comer"),
        ("shopping", "Compras"), ("activities", "Actividades"),
        ("accommodation", "Alojamiento"), ("recommendations", "Consejos"),
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


