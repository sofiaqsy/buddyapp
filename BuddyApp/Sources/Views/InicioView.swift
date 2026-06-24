import SwiftUI
import CoreLocation
import UIKit

// MARK: – INICIO
// Calm, trustworthy dashboard. The user's home base between adventures.

struct InicioView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var locationService: LocationService
    @State private var navPath = NavigationPath()
    @State private var showContactSheet         = false
    @State private var showPendingContactSheet  = false
    @State private var isFindingBuddy           = false   // creando/reusando trip en background
    @State private var homeBuddyCount           = 0       // buddies cerca, para el composer de la Home
    @State private var homeHelpSeed: (category: String, description: String?)? = nil  // categoría elegida en Home
    /// Prompt ligero cuando el GPS detecta un destino distinto al trip activo.
    @State private var locationPromptDestination: APIDestination? = nil
    @State private var dismissedPromptDestId: String? = nil   // "Ahora no" → no re-preguntar
    @State private var destinations: [APIDestination] = []
    @State private var pendingJourney: APIJourney? = nil
    @State private var activeJourney: APIJourney? = nil
    @State private var activeMatch: APIMatch? = nil
    @State private var isLoadingData = true
    @State private var publicJourneys: [APIJourney] = []
    @State private var feedCursor: String? = nil
    @State private var feedHasMore = true
    @State private var isLoadingMoreFeed = false
    @State private var seenStoryIds = Set<String>()
    @State private var recentHelp: [APIRecentHelp] = []   // comunidad viva
    @State private var isLoadingRecentHelp = false        // anti re-entrada
    @State private var recentHelpDestId: String? = nil    // último destino cargado
    @State private var recentHelpLoadedAt: Date? = nil    // throttle de refetch
    @State private var pendingNavToDetail = false
    @State private var hasLoaded = false
    @State private var skipNextRefresh = false
    @State private var isLoadingFeed = true
    @State private var feedFailed = false
    @ObservedObject private var chatStore = ChatStore.shared
    @ObservedObject private var placeDeepLink = PlaceDeepLink.shared

    private var pendingReply: Bool {
        chatStore.connections
            .first { ["accepted","active"].contains($0.match.status) }?
            .pendingReply ?? false
    }

    // Destino activo → para pedir el head de afinidad al feed (ranking en servidor)
    private var myDestinationId: String? {
        let j = activeJourney ?? pendingJourney
        return j?.destination?.id ?? j?.destinationId
    }

    var body: some View {
        NavigationStack(path: $navPath) {
          ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("inicioTop")   // ancla para volver arriba

                    Group {
                        if isLoadingData {
                            SkeletonBox(cornerRadius: 20)
                                .frame(height: 200)
                        } else if let journey = activeJourney {
                            // La card del trip activo SIEMPRE se muestra;
                            // solo el detalle del mapa depende de la ubicación/ruta
                            NavigationLink(destination: TripDetailGate(journey: journey, match: activeMatch, unreadCount: pendingReply ? 1 : 0)
                                .environmentObject(routeStore)) {
                                ActiveTripCard(journey: journey, match: activeMatch, pendingReply: pendingReply) {
                                    showContactSheet = true
                                }
                            }
                            .buttonStyle(.plain)
                        } else if let journey = pendingJourney {
                            PendingTripCard(
                                journey: journey,
                                destination: destinations.first { $0.id == (journey.destination?.id ?? journey.destinationId) },
                                unreadCount: pendingReply ? 1 : 0,
                                onTap: { navPath.append(journey) },
                                onContactBuddy: {
                                    showPendingContactSheet = true
                                }
                            )
                        } else {
                            VStack(alignment: .leading, spacing: Spacing.lg) {
                                // 1. Contexto — ubicación detectada, o invitación a activarla.
                                locationContext
                                // 2. Ayuda — el composer ES la Home: "¿En qué te ayudamos?".
                                // El Trip se crea/reusa automáticamente al enviar.
                                CategoryPickerView(buddyCount: homeBuddyCount) { cat, desc in
                                    await submitHelpFromHome(category: cat, description: desc)
                                }
                                .padding(.horizontal, -Spacing.edge)   // el composer maneja su propio margen
                                .opacity(isFindingBuddy ? 0.5 : 1)
                                .disabled(isFindingBuddy)

                                // 5. Planear un viaje — secundario, opcional.
                                RegisterCTACard(destinations: destinations) {
                                    navPath.append("register")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

                    // Comunidad viva — con trip activo o en planificación
                    if (activeJourney != nil || pendingJourney != nil), !recentHelp.isEmpty {
                        comunidadVivaSection
                            .padding(.top, Spacing.xl)
                    }

                    communitySection
                        .padding(.top, Spacing.xl)
                }
                .padding(.bottom, 100)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: APIJourney.self) { journey in
                TripDetailGate(journey: journey, match: activeMatch, unreadCount: 0)
                    .environmentObject(routeStore)
            }
            .navigationDestination(for: String.self) { route in
                if route == "register" {
                    // Reemplaza el formulario por el confirm → "atrás" vuelve al tab, no al form
                    RegisterTripView { journey in
                        navPath = NavigationPath()
                        navPath.append(journey)
                    }
                } else if route == "tripDetail", let journey = activeJourney {
                    TripDetailView(
                        route: routeStore.route,
                        match: activeMatch,
                        journey: journey,
                        unreadCount: pendingReply ? 1 : 0
                    )
                    .environmentObject(routeStore)
                }
            }
            // Carga UNA sola vez; los eventos (activar/publicar trip) y el
            // pull-to-refresh disparan las recargas — no cada visita al tab
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await loadData()
            }
            // Revalidación ligera por visita: SOLO el estado del trip
            // (1 request de ~150ms) — el hero card nunca queda obsoleto.
            // Destinos y feed siguen en política de carga única.
            .onAppear {
                if hasLoaded {
                    if skipNextRefresh { skipNextRefresh = false; return }
                    Task { await refreshTripState() }
                }
            }
            // Deep-link desde chat: reactive al cambio de pending (la vista queda
            // viva en el TabView, así que .onAppear ya no vuelve a dispararse)
            .onChange(of: placeDeepLink.pending != nil) { _, hasPending in
                if hasPending, let journey = activeJourney ?? pendingJourney {
                    navPath = NavigationPath()
                    navPath.append(journey)
                }
            }
            .refreshable { await loadData() }
            // Al volver del flujo de registro (pop a raíz), un refresh dirigido
            .onChange(of: navPath.count) { old, new in
                if new == 0 && old > 0 { Task { await loadData() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
                Task { await loadData() }
            }
            // Se cerró un apoyo → refresca "Comunidad Viva" + estado del trip
            .onReceive(NotificationCenter.default.publisher(for: .helpCompleted)) { _ in
                Task { await loadRecentHelp(force: true); await refreshTripState() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .journeyCancelled)) { _ in
                skipNextRefresh = true   // evita que .onAppear sobreescriba el estado
                activeJourney  = nil
                pendingJourney = nil
                navPath = NavigationPath()
                Task { await loadData() }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    (Text("BU").foregroundColor(Color.ink)
                     + Text("DDY").foregroundColor(Color.sand))
                        .font(BT.eyebrow)
                        .tracking(4)
                }
            }
            // Re-tap del tab Inicio → vuelve arriba + recarga
            .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
                guard note.object as? Int == AppTab.inicio.rawValue else { return }
                if !navPath.isEmpty { navPath = NavigationPath() }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("inicioTop", anchor: .top) }
                Task { await loadData() }
            }
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyActivated)) { _ in
            navPath = NavigationPath()
            pendingNavToDetail = true
            Task { await quickLoadForDetail() }
        }
        .onChange(of: routeStore.isReady) { _, ready in
            guard ready, pendingNavToDetail, activeJourney != nil else { return }
            pendingNavToDetail = false
            NotificationCenter.default.post(name: .switchToTab, object: nil,
                                            userInfo: ["tab": AppTab.inicio.rawValue])
            navPath.append("tripDetail")
        }
        .sheet(isPresented: $showContactSheet, onDismiss: { homeHelpSeed = nil }) {
            if let journey = activeJourney {
                ContactarBuddyView(journey: journey, initialRequest: homeHelpSeed)
            }
        }
        .sheet(isPresented: $showPendingContactSheet) {
            if let journey = pendingJourney {
                ContactarBuddyView(journey: journey, preselectedCategory: "transport")
            }
        }
        // GPS cambió y el destino detectado difiere del trip activo → prompt ligero.
        // NUNCA se crea un trip en silencio: solo si el usuario confirma.
        .onChange(of: locationService.userLocation) { _, _ in
            evaluateLocationPrompt()
            Task { await refreshHomeBuddyCount() }
        }
        .alert(
            locationPromptDestination.map { "Parece que estás en \($0.city)" } ?? "",
            isPresented: Binding(
                get: { locationPromptDestination != nil },
                set: { if !$0 { locationPromptDestination = nil } }
            )
        ) {
            Button("Buscar ayuda aquí") {
                if let d = locationPromptDestination {
                    locationPromptDestination = nil
                    Task { await openHelp(forDestinationId: d.id) }
                }
            }
            Button("Ahora no", role: .cancel) {
                dismissedPromptDestId = locationPromptDestination?.id
                locationPromptDestination = nil
            }
        }
    }

    /// Decide si mostrar el prompt de cambio de ubicación (sin crear nada).
    private func evaluateLocationPrompt() {
        guard let near = nearestDestination, let active = activeJourney else { return }
        let activeDestId = active.destination?.id ?? active.destinationId
        guard near.id != activeDestId,                 // destino distinto al trip activo
              near.id != dismissedPromptDestId,         // no descartado ya
              locationPromptDestination == nil,
              !showContactSheet
        else { return }
        locationPromptDestination = near
    }

    // MARK: – Contexto de ubicación

    /// Muestra "ESTÁS EN {ciudad}" si hay ubicación; si no, ofrece activarla.
    @ViewBuilder
    private var locationContext: some View {
        if let city = nearestDestination?.city {
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("ESTÁS EN \(city.uppercased())")
                    .font(BT.eyebrow).tracking(1.5)
            }
            .foregroundStyle(Color.sand)
        } else {
            // Sin ubicación → invitación discreta a activarla (no bloquea pedir ayuda).
            Button {
                Haptic.light()
                switch locationService.authorizationStatus {
                case .denied, .restricted:
                    // Ya negado: solo se puede reactivar desde Ajustes.
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                default:
                    locationService.requestPermission()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Activa tu ubicación para ver ayuda cerca de ti")
                        .font(BT.caption1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.sand.opacity(0.6))
                }
                .foregroundStyle(Color.sand)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Find a Buddy (trip automático)

    /// Destino conocido más cercano a la ubicación actual, dentro de su radio.
    /// nil si no hay GPS o estás fuera de cobertura de cualquier destino.
    private var nearestDestination: APIDestination? {
        guard let loc = locationService.userLocation else { return nil }
        return destinations
            .map { ($0, loc.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))) }
            .filter { $0.1 <= Double($0.0.radiusMeters ?? 50_000) }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    /// CTA principal: el usuario toca "Buscar un buddy" sin crear un trip a mano.
    /// Resuelve el destino por GPS, asegura el Trip (reusa o crea) y abre el flujo
    /// de ayuda. Si no hay destino detectable, cae al registro manual existente.
    private func findABuddy() async {
        guard let dest = nearestDestination else {
            navPath.append("register"); return
        }
        await openHelp(forDestinationId: dest.id)
    }

    /// Asegura el Trip para el destino y presenta el flujo de ayuda.
    private func openHelp(forDestinationId destId: String) async {
        await MainActor.run { isFindingBuddy = true }
        defer { Task { @MainActor in isFindingBuddy = false } }
        do {
            let journey = try await APIClient.shared.ensureActiveTrip(destinationId: destId)
            await MainActor.run {
                activeJourney = journey
                pendingJourney = nil
                showContactSheet = true
            }
        } catch {
            // Fallback seguro: registro manual si algo falla
            await MainActor.run { navPath.append("register") }
        }
    }

    /// El usuario eligió categoría/texto DIRECTO en la Home → asegura el Trip y
    /// abre el flujo de ayuda ya en "buscando" (sin repetir el selector).
    private func submitHelpFromHome(category: String, description: String?) async {
        guard let dest = nearestDestination else {
            await MainActor.run { navPath.append("register") }   // sin GPS → registro manual
            return
        }
        await MainActor.run { isFindingBuddy = true }
        defer { Task { @MainActor in isFindingBuddy = false } }
        do {
            let journey = try await APIClient.shared.ensureActiveTrip(destinationId: dest.id)
            await MainActor.run {
                activeJourney  = journey
                pendingJourney = nil
                homeHelpSeed   = (category, description)
                showContactSheet = true
            }
        } catch {
            await MainActor.run { navPath.append("register") }
        }
    }

    /// Cuenta de buddies cerca, para el composer de la Home.
    private func refreshHomeBuddyCount() async {
        guard activeJourney == nil, pendingJourney == nil,
              let dest = nearestDestination else { return }
        if let count = try? await APIClient.shared.fetchBuddyCount(destinationId: dest.id) {
            await MainActor.run { homeBuddyCount = count }
        }
    }

    /// Revalida solo el estado del trip (activo/pendiente) — barato y frecuente
    private func refreshTripState() async {
        guard let userId = AuthService.shared.userId,
              let journeys = try? await APIClient.shared.fetchUserJourneys(userId: userId) else { return }
        // Anti cross-account: descarta si la sesión cambió de usuario en vuelo
        guard AuthService.shared.userId == userId else { return }
        let active   = journeys.first(where: { $0.status == "active" })
        let planning = journeys.first(where: { $0.status == "planning" })
        await MainActor.run {
            activeJourney  = active
            pendingJourney = active == nil ? planning : nil
        }
        await loadRecentHelp()
        // Ruta en background — activos y planning la necesitan para el mapa
        if let active, !routeStore.isReady {
            let destId = active.destination?.id ?? active.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        } else if active == nil, let planning = journeys.first(where: { $0.status == "planning" }), !routeStore.isReady {
            let destId = planning.destination?.id ?? planning.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        }
    }

    /// Fetch ligero para navegar al detalle rápido tras "Ya llegué"
    private func quickLoadForDetail() async {
        guard let userId = AuthService.shared.userId else { return }
        guard let journeys = try? await APIClient.shared.fetchUserJourneys(userId: userId) else { return }
        let active = journeys.first(where: { $0.status == "active" })

        // Asegura que routeStore tenga la ruta
        if let active, !routeStore.isReady {
            let destId = active.destination?.id ?? active.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        }

        // Cargar match si hay viaje activo
        if let active {
            let matches = try? await APIClient.shared.fetchMatches(userId: userId)
            await MainActor.run {
                activeJourney = active
                activeMatch = matches?.first(where: { ["accepted", "active"].contains($0.status) })
            }
        }

        // Navegar cuando routeStore esté listo (onChange lo maneja si aún no está)
        if routeStore.isReady, active != nil {
            await MainActor.run {
                guard pendingNavToDetail else { return }
                pendingNavToDetail = false
                NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                userInfo: ["tab": AppTab.inicio.rawValue])
                navPath.append("tripDetail")
            }
        }
    }

    private func loadData() async {
        async let dests = APIClient.shared.fetchDestinations()
        destinations = (try? await dests) ?? []
        ImagePrefetcher.prefetch(destinations.compactMap { $0.coverUrl })

        guard let userId = AuthService.shared.userId else { isLoadingData = false; return }

        do {
            let journeys = try await APIClient.shared.fetchUserJourneys(userId: userId)
            // Anti cross-account: descarta si la sesión cambió de usuario en vuelo
            guard AuthService.shared.userId == userId else {
                print("⚠️ [InicioView] userId cambió durante loadData — descarto resultado")
                isLoadingData = false; return
            }
            let active   = journeys.first(where: { $0.status == "active" })
            let planning = journeys.first(where: { $0.status == "planning" })

            if let active, !routeStore.isReady {
                let destId = active.destination?.id ?? active.destinationId
                await routeStore.fetchDestinationFromAPI(id: destId)
            } else if active == nil, let planning, !routeStore.isReady {
                // Cargar mapa también para trips en planificación
                let destId = planning.destination?.id ?? planning.destinationId
                await routeStore.fetchDestinationFromAPI(id: destId)
            }

            // El trip activo se muestra exista o no la ruta — el mapa es lo
            // único que depende de la ubicación
            activeJourney  = active
            pendingJourney = activeJourney == nil ? planning : nil

            // Cargar match activo y mensajes no leídos
            if activeJourney != nil {
                let matches = try await APIClient.shared.fetchMatches(userId: userId)
                activeMatch = matches.first(where: { ["accepted", "active"].contains($0.status) })
                // ChatStore carga y calcula pendingReply reactivamente
                await chatStore.load()
            }
            await loadRecentHelp(force: true)
        } catch { }
        isLoadingData = false

        // Si viene de "Ya llegué", navegar directo al mapa
        if pendingNavToDetail, activeJourney != nil, routeStore.isReady {
            pendingNavToDetail = false
            navPath.append("tripDetail")
        }

        // Feed de trips publicados — con un reintento: un timeout puntual
        // no puede dejar la comunidad vacía en silencio
        await loadFeed()

        // Buddies cerca para el composer de la Home (si no hay trip)
        await refreshHomeBuddyCount()
    }

    private var feedLat: Double? { locationService.userLocation?.coordinate.latitude }
    private var feedLng: Double? { locationService.userLocation?.coordinate.longitude }

    // Primera página del feed (cursor pagination + ranking servidor)
    private func loadFeed() async {
        feedFailed = false
        for attempt in 0..<2 {
            do {
                let page = try await APIClient.shared.fetchStories(
                    destinationId: myDestinationId, lat: feedLat, lng: feedLng, cursor: nil)
                publicJourneys = page.items
                seenStoryIds = Set(page.items.map(\.id))
                feedCursor = page.nextCursor
                feedHasMore = page.hasMore
                isLoadingFeed = false
                return
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        isLoadingFeed = false
        feedFailed = publicJourneys.isEmpty
    }

    // Carga incremental — se dispara al acercarse al final (scroll infinito)
    private func loadMoreFeed() async {
        guard feedHasMore, !isLoadingMoreFeed, let cursor = feedCursor else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        guard let page = try? await APIClient.shared.fetchStories(
            destinationId: myDestinationId, lat: feedLat, lng: feedLng, cursor: cursor) else { return }
        // Append + dedupe (los items de afinidad pueden reaparecer en la cola global)
        let fresh = page.items.filter { seenStoryIds.insert($0.id).inserted }
        publicJourneys.append(contentsOf: fresh)
        feedCursor = page.nextCursor
        feedHasMore = page.hasMore
    }

    private func activatePendingJourney(_ journey: APIJourney) async {
        try? await APIClient.shared.updateJourneyStatus(journeyId: journey.id, status: "active")
        await MainActor.run {
            pendingJourney = nil
            activeJourney = journey
            NotificationCenter.default.post(name: .journeyActivated, object: nil)
        }
        await loadData()
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "EEEE · d 'de' MMMM"
        return f.string(from: Date()).uppercased()
    }

    // MARK: Comunidad viva — ayudas recién terminadas en tu destino
    /// - Parameter force: ignora el throttle (para pull-to-refresh / eventos reales)
    private func loadRecentHelp(force: Bool = false) async {
        let journey = activeJourney ?? pendingJourney
        guard let journey else {
            recentHelp = []; recentHelpDestId = nil; return
        }
        guard let destId = journey.destination?.id ?? journey.destinationId else {
            recentHelp = []; recentHelpDestId = nil; return
        }

        // Anti re-entrada: una sola petición en vuelo a la vez
        if isLoadingRecentHelp { return }

        // Throttle: no refetchar el mismo destino en < 30 s (salvo force).
        // Esto corta el loop de llamadas idénticas disparadas por re-renders.
        if !force,
           recentHelpDestId == destId,
           let at = recentHelpLoadedAt,
           Date().timeIntervalSince(at) < 30 {
            return
        }

        isLoadingRecentHelp = true
        defer { isLoadingRecentHelp = false }
        do {
            let result = try await APIClient.shared.fetchRecentHelp(destinationId: destId)
            recentHelp = result
            recentHelpDestId = destId
            recentHelpLoadedAt = Date()
        } catch {
            recentHelp = []
        }
    }

    private func timeAgo(_ date: Date?) -> String {
        guard let d = date else { return "recién" }
        let s = max(0, Date().timeIntervalSince(d))
        if s < 90    { return "hace un momento" }
        if s < 3600  { return "hace \(Int(s / 60)) min" }
        if s < 86400 { return "hace \(Int(s / 3600)) h" }
        return "hace \(Int(s / 86400)) d"
    }

    private func helpAvatar(_ user: APIUserRef?, size: CGFloat, online: Bool = false) -> some View {
        Circle().fill(Color.sandLight).frame(width: size, height: size)
            .overlay {
                CachedImage(urlString: user?.avatarUrl) { img in
                    img.resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45)).foregroundStyle(Color.sand)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if online {
                    Circle().fill(Color.onlineGreen).frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(Color.surface, lineWidth: 2))
                }
            }
            .overlay(Circle().strokeBorder(Color.surface, lineWidth: 2))
    }

    private var comunidadVivaSection: some View {
        let first = recentHelp.first
        let firstName = (first?.buddy?.fullName ?? "Un buddy")
            .components(separatedBy: " ").first?.capitalized ?? "Un buddy"
        let cluster = Array(recentHelp.prefix(3))
        let extra = max(0, recentHelp.count - cluster.count)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 6) {
                Text("COMUNIDAD VIVA").font(BT.eyebrow).tracking(1.5).foregroundStyle(Color.ink)
            }
            .padding(.horizontal, Spacing.edge)

            HStack(spacing: 12) {
                helpAvatar(first?.buddy, size: 44, online: false)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(firstName).font(BT.footnoteBold).foregroundStyle(Color.ink)
                     + Text(" ayudó a un viajero").font(BT.footnote).foregroundStyle(Color.inkMuted))
                        .lineLimit(2)
                    Text(timeAgo(first?.completedAt)).font(BT.caption1).foregroundStyle(Color.teal)
                }
                Spacer(minLength: 8)
                HStack(spacing: -8) {
                    ForEach(cluster) { h in helpAvatar(h.buddy, size: 28) }
                    if extra > 0 {
                        Text("+\(extra)")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                            .frame(width: 28, height: 28)
                            .background(Color.sandLight, in: Circle())
                            .overlay(Circle().strokeBorder(Color.surface, lineWidth: 2))
                    }
                }
            }
            .padding(Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .cardShadow()
            .padding(.horizontal, Spacing.edge)
        }
    }

    private var communitySection: some View {
        Group {
            if isLoadingFeed && publicJourneys.isEmpty {
                // Skeleton de publicación: header + foto, mismo layout que la real
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow)
                        .tracking(1.5)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            SkeletonBox(cornerRadius: 18).frame(width: 36, height: 36)
                            SkeletonBox(cornerRadius: 6).frame(width: 140, height: 14)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        SkeletonBox(cornerRadius: 0).frame(height: 480)
                    }
                }
            } else if feedFailed {
                // El feed falló tras reintentos — se dice y se ofrece reintentar
                VStack(spacing: Spacing.sm) {
                    Text("No pudimos cargar la comunidad")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Button {
                        isLoadingFeed = true
                        Task { await loadFeed() }
                    } label: {
                        Text("Reintentar")
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, 10)
                            .background(Color.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
            } else if !publicJourneys.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow)
                        .tracking(1.5)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)

                    // Biblioteca de viajes — orden y ranking vienen del servidor.
                    // Scroll infinito: al acercarse al final, carga el siguiente lote.
                    ForEach(publicJourneys) { journey in
                        PublishedTripCard(journey: journey)
                            .onAppear {
                                if journey.id == publicJourneys.suffix(4).first?.id {
                                    Task { await loadMoreFeed() }
                                }
                            }
                    }
                    if isLoadingMoreFeed {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                    }
                }
            } else {
                // Estado vacío — diario, no feed
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow).tracking(1.5).foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Color.inkMuted.opacity(0.5))
                        Text("Aún nadie ha contado su paso por aquí")
                            .font(BT.callout).foregroundStyle(Color.ink)
                        Text("Cuando termines tu trip, tu historia será la primera.")
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .padding(.horizontal, Spacing.edge)
                }
            }
        }
    }
}

// MARK: – TRIP DETAIL GATE
// El mapa necesita la ruta cargada; esta puerta la obtiene al entrar
// (única parte del flujo que depende de la ubicación).

struct TripDetailGate: View {
    let journey: APIJourney
    var match: APIMatch? = nil
    var unreadCount: Int = 0
    @EnvironmentObject var routeStore: RouteStore
    @State private var failed = false

    var body: some View {
        Group {
            if routeStore.isReady {
                TripDetailView(route: routeStore.route, match: match,
                               journey: journey, unreadCount: unreadCount)
                    .environmentObject(routeStore)
            } else if failed {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "map")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.inkMuted)
                    Text("No pudimos cargar la ruta")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Button {
                        failed = false
                        Task { await loadRoute() }
                    } label: {
                        Text("Reintentar")
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, 10)
                            .background(Color.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
            } else {
                ZStack {
                    Color.canvas.ignoresSafeArea()
                    ProgressView().tint(Color.inkMuted)
                }
                .task { await loadRoute() }
            }
        }
    }

    private func loadRoute() async {
        let destId = journey.destination?.id ?? journey.destinationId
        await routeStore.fetchDestinationFromAPI(id: destId)
        if !routeStore.isReady { failed = true }
    }
}

// MARK: – ACTIVE VISIT CARD
// Calm teal gradient. Editorial typography. No gaming badges.

struct ActiveVisitCard: View {
    let route: Route
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(LinearGradient(
                    colors: [Color.tealDeep, Color.teal],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(height: 210)

            VStack(alignment: .leading, spacing: 0) {
                // City eyebrow
                Text(route.city.uppercased())
                    .font(BT.eyebrow)
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, Spacing.md)

                // Hero title
                Text(route.title)
                    .font(BT.displayLarge)
                    .foregroundStyle(.white)
                Text(route.subtitle)
                    .font(BT.displayLarge)
                    .foregroundStyle(.white.opacity(0.8))

                // Progress bar
                HStack(spacing: Spacing.sm) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.18))
                                .frame(height: 2)
                            Capsule()
                                .fill(.white)
                                .frame(
                                    width: appeared ? g.size.width * route.progress : 0,
                                    height: 2
                                )
                                .animation(.easeOut(duration: 0.9).delay(0.3), value: appeared)
                        }
                    }
                    .frame(height: 2)

                    Text("\(route.collectedCount) de \(route.places.count)")
                        .font(BT.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                        .monospacedDigit()
                }
                .padding(.top, Spacing.md)
            }
            .padding(Spacing.md)
        }
        .cardShadow()
        .onAppear { appeared = true }
    }
}

// MARK: – REGISTER CTA CARD

// MARK: – FIND A BUDDY PRIMARY CTA
// Tarjeta principal de la home: pedir ayuda en un toque. El Trip se crea o
// reusa automáticamente — el usuario nunca ve una pantalla de "crear trip".

struct FindBuddyPrimaryCTA: View {
    let destinationName: String?     // ciudad detectada por GPS (si la hay)
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                // Contexto: ubicación detectada (si la hay) — sin pedir permiso.
                if let city = destinationName {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("ESTÁS EN \(city.uppercased())")
                            .font(BT.eyebrow).tracking(1.5)
                    }
                    .foregroundStyle(Color.sand)
                }
                Text("¿Necesitas ayuda?")
                    .font(BT.title1)
                    .foregroundStyle(Color.ink)
                Text("Un buddy local te ayuda en minutos.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
            }

            Button(action: { Haptic.medium(); onTap() }) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "person.wave.2.fill")
                        Text("Buscar un buddy")
                    }
                }
                .font(BT.footnoteBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(hex: "#2B8A7A"))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .disabled(isLoading)
        }
        .padding(Spacing.lg)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }
}

// Tarjeta SECUNDARIA: planear un viaje es opcional, no compite con pedir ayuda.
// Fila compacta, plana (sin sombra), con acción terciaria.
struct RegisterCTACard: View {
    let destinations: [APIDestination]   // conservado por compatibilidad
    let onTap: () -> Void

    var body: some View {
        Button(action: { Haptic.light(); onTap() }) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle().fill(Color.sandLight).frame(width: 40, height: 40)
                    Image(systemName: "map")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.sand)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿Planeas un viaje?")
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                    Text("Regístralo y prepara tu llegada.")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkMuted.opacity(0.5))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }
}

// MARK: – DESTINATION THUMB CARD
// Photo card matching design reference: rounded rect photo + name below

struct DestinationThumbCard: View {
    let destination: APIDestination

    // Fallback gradient per destination index
    private let gradients: [[Color]] = [
        [Color(hex: "0A3D38"), Color(hex: "0F766E")],
        [Color(hex: "1e3a5f"), Color(hex: "2a6b7a")],
        [Color(hex: "4a2a0a"), Color(hex: "7C4A1E")],
        [Color(hex: "4a3200"), Color(hex: "B45309")],
    ]

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                // Background: real photo or gradient fallback
                CachedImage(urlString: destination.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    gradientFallback
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(destination.city)
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .lineLimit(1)
        }
        .frame(width: 80)
    }

    private var gradientFallback: some View {
        let idx = abs(destination.name.hashValue) % gradients.count
        return LinearGradient(
            colors: gradients[idx],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: – PUBLISHED TRIP CARD

// MARK: – TRIP STORY CARD (álbum de viaje)
// La unidad es un trip finalizado, presentado como ÁLBUM. Carrusel estilo IG:
// cada momento se ve COMPLETO (sin recortar) y se desliza ←/→.

struct PublishedTripCard: View {
    let journey: APIJourney
    var featured: Bool = false
    var matchesMyDestination: Bool = false
    var nearby: Bool = false

    @State private var showStory = false
    @State private var page = 0

    private var destName: String { journey.destination?.name ?? journey.title ?? "Trip" }
    private var authorName: String { (journey.users?.fullName ?? "Buddy").capitalized }
    private var thumbs: [String] { (journey.pageThumbs ?? []).filter { !$0.isEmpty } }
    private var durationLine: String? {
        guard let d = journey.durationDays else { return nil }
        return "en \(d) \(d == 1 ? "día" : "días")"
    }
    /// Alto = ancho de la tarjeta a la PROPORCIÓN real de un momento → se ve completo
    private var carouselHeight: CGFloat {
        let w = UIScreen.main.bounds.width - Spacing.edge * 2
        return w * CanvasViewModel.pageSize.height / max(1, CanvasViewModel.pageSize.width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            carousel
            footer
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.horizontal, Spacing.edge)
        .sheet(isPresented: $showStory) { StoryViewerSheet(journey: journey) }
    }

    private var carousel: some View {
        ZStack(alignment: .bottom) {
            if thumbs.isEmpty {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(colors: [Color.tealDeep, Color.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .frame(maxWidth: .infinity).frame(height: carouselHeight).clipped()
                .contentShape(Rectangle())
                .onTapGesture { Haptic.light(); showStory = true }
            } else {
                TabView(selection: $page) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { i, url in
                        // scaledToFit → el momento NUNCA se recorta
                        CachedImage(urlString: url) { img in
                            img.resizable().scaledToFit()
                        } placeholder: { Color(white: 0.96) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { Haptic.light(); showStory = true }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: carouselHeight)

                if thumbs.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<thumbs.count, id: \.self) { i in
                            Circle()
                                .fill(i == page ? Color.white : Color.white.opacity(0.5))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: page)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color(white: 0.96))
    }

    // Pie minimalista: solo viajero + duración (sin destino ni "Ver álbum")
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.tealDeep).frame(width: 24, height: 24)
                .overlay {
                    CachedImage(urlString: journey.users?.avatarUrl) { img in
                        img.resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
                    } placeholder: {
                        Text(String(authorName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            Text(authorName).font(BT.footnote).foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            if let d = durationLine {
                Text(d).font(BT.subhead).foregroundStyle(Color.inkMuted)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { Haptic.light(); showStory = true }
    }
}

// MARK: – STORY VIEWER (pantalla completa de las páginas del trip)

struct StoryViewerSheet: View {
    let journey: APIJourney
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [APIJourneyPage] = []
    @State private var current = 0

    private var destName: String { journey.destination?.name ?? journey.title ?? "Trip" }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if pages.isEmpty {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    LinearGradient(colors: [Color.tealDeep, Color.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $current) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        CachedImage(urlString: page.thumbnailUrl) { img in
                            img.resizable().scaledToFit()
                        } placeholder: { Color(white: 0.1) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
            }

            // Solo el botón de cerrar — sin conteos
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.edge).padding(.top, 8)
        }
        .task {
            pages = (try? await APIClient.shared.fetchJourneyPages(journeyId: journey.id)) ?? []
            ImagePrefetcher.prefetch(pages.map(\.thumbnailUrl))
        }
    }
}

// MARK: – COMMUNITY POST

struct CommunityPost: Identifiable {
    let id = UUID()
    let authorName: String
    let authorAvatar: String
    let location: String
    let timeAgo: String
    let coverEmoji: String
    let gradientColors: [Color]
    let likes: Int

    // Real posts loaded from API — empty until backend provides data
    static let live: [CommunityPost] = []
}

// MARK: – COMMUNITY POST CARD
// Editorial photo card. Apple Journal–inspired. No floating badges.

struct CommunityPostCard: View {
    let post: CommunityPost

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: post.gradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(height: 240)
                .overlay {
                    Text(post.coverEmoji).font(.system(size: 72))
                }

                // Author — subtle frosted pill
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(.black.opacity(0.22))
                        .frame(width: 32, height: 32)
                        .overlay { Text(post.authorAvatar).font(.system(size: 14)) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.authorName)
                            .font(BT.footnoteBold)
                            .foregroundStyle(.white)
                        Text("\(post.location) · \(post.timeAgo)")
                            .font(BT.caption1)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(Spacing.md)
            }
            .frame(height: 240)
            .clipped()

            HStack {
                Button { Haptic.light() } label: {
                    Label("\(post.likes)", systemImage: "heart")
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkMuted.opacity(0.5))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.bottom, Spacing.md)
    }
}

// MARK: – ACTIVE TRIP CARD
// Shown in Inicio when user has a journey with status "active"

struct ActiveTripCard: View {
    let journey: APIJourney
    var match: APIMatch? = nil
    var pendingReply: Bool = false
    var onContactBuddy: (() -> Void)? = nil

    private var coverURL: URL? {
        guard let s = journey.destination?.coverUrl else { return nil }
        return URL(string: s)
    }
    private var tripTitle: String {
        journey.destination?.name ?? journey.title ?? "Tu trip"
    }
    private var buddyName: String {
        match?.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Buddy"
    }
    private var buddyAvatarURL: URL? {
        guard let s = match?.buddy?.avatarUrl else { return nil }
        return URL(string: s)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // Foto de fondo
                CachedImage(url: coverURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: { fallback }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // Gradiente inferior
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )

                // Badge EN CURSO — top right
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.onlineGreen).frame(width: 6, height: 6)
                        Text("EN CURSO")
                            .font(BT.eyebrow)
                            .tracking(1)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Título + panel inferior en un solo flujo — nunca se superponen
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(tripTitle)
                        .font(BT.title1)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                if match != nil {
                    // ── Buddy asignado ─────────────────────────────
                    HStack(spacing: 12) {
                        // Avatar
                        ZStack(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Color.sandLight)
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if let url = buddyAvatarURL {
                                        AsyncImage(url: url) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: { Color.sandLight }
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(Color.sand)
                                    }
                                }
                            Circle().fill(Color.onlineGreen).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5))
                                .offset(x: 1, y: 1)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("TU BUDDY")
                                .font(BT.eyebrow)
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.65))
                            Text(buddyName)
                                .font(BT.headline)
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        // Botón chat + indicador de pendiente
                        Button {
                            Haptic.medium()
                            onContactBuddy?()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "message.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())

                                if pendingReply {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // ── Sin buddy aún ──────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        Text("¿Tienes alguna duda?")
                            .font(BT.headline)
                            .foregroundStyle(.white)
                        Text("Un buddy se conectará contigo para ayudarte en unos minutos.")
                            .font(BT.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            Haptic.medium()
                            onContactBuddy?()
                        } label: {
                            Label("Contactar buddy", systemImage: "person.2.fill")
                                .font(BT.footnoteBold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.white)
                                .foregroundStyle(.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                }
                .padding(Spacing.md)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.78)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .frame(height: min(360, UIScreen.main.bounds.height * 0.44))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    private var fallback: some View {
        LinearGradient(colors: [Color.tealDeep, Color.teal],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: – Shared trip arrival phrasing
// Una sola fórmula de fecha para todos los tabs (cohesión).
func tripArrivalLine(_ date: Date?) -> String {
    guard let date else { return "Fecha por confirmar" }
    let cal = Calendar.current
    if cal.isDateInToday(date)    { return "Llegas hoy" }
    if cal.isDateInTomorrow(date) { return "Llegas mañana" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_PE")
    f.dateFormat = "d 'de' MMM"
    return "Llegas el \(f.string(from: date))"
}

// MARK: – TRIP HERO BANNER (compartido: Home + Tu trip)
// Foto + scrim superior e inferior + badge + título + fecha. Mismo objeto en todos
// los tabs → la tarjeta del trip se siente "la misma cosa" donde aparezca.

struct TripHeroBanner: View {
    let coverUrl: String?
    let title: String
    let dateLine: String
    var statusText: String? = "PLANIFICADO"
    var statusColor: Color = Color(hex: "6EE7B7")
    var topEyebrow: String? = nil
    var height: CGFloat = 200
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        CachedImage(urlString: coverUrl) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [Color.tealDeep, Color.teal],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        // Scrims como overlays acotados al alto de la foto (no se desbordan
        // sobre la tarjeta blanca de abajo).
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .clear,               location: 0.0),
                    .init(color: .black.opacity(0.22), location: 0.5),
                    .init(color: .black.opacity(0.60), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        // Eyebrow + estado
        .overlay(alignment: .top) {
            HStack(alignment: .top) {
                if let topEyebrow {
                    Text(topEyebrow)
                        .font(BT.eyebrow).tracking(1.5)
                        .foregroundStyle(.white)
                }
                Spacer()
                if let statusText {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText)
                            .font(BT.eyebrow).tracking(1).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                }
            }
            .padding(.horizontal, Spacing.md).padding(.top, Spacing.md)
        }
        // Título + fecha + acción opcional
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BT.title1).foregroundStyle(.white).lineLimit(1)
                    Text(dateLine)
                        .font(BT.footnoteBold).foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                if let trailing { trailing() }
            }
            .padding(Spacing.md)
        }
        .clipped()
    }
}

// MARK: – BUDDY READINESS ROW (compartido: Home + Tu trip)
// El corazón del producto: alguien ya está listo para recibirte.

struct BuddyReadinessRow: View {
    let count: Int?
    let placeName: String

    var text: String? {
        guard let c = count else { return nil }
        if c <= 0 { return "Siempre que tengas una duda, puedes contactar a un buddy." }
        return c == 1
            ? "1 buddy en \(placeName) disponible si tienes dudas"
            : "\(c) buddies en \(placeName) disponibles si tienes dudas"
    }

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                Circle().fill(Color.onlineGreen).frame(width: 7, height: 7)
                Text(text)
                    .font(BT.subhead.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)
        }
    }
}

// MARK: – PENDING TRIP CARD

struct PendingTripCard: View {
    let journey: APIJourney
    var destination: APIDestination? = nil
    var unreadCount: Int = 0
    var onTap: () -> Void = {}
    var onContactBuddy: () -> Void = {}

    @State private var expandedType: PlanSuggType? = nil
    @State private var buddyCount: Int? = nil

    enum PlanSuggType: CaseIterable { case howToGet, lodging }

    private var destName: String { journey.destination?.name ?? "Tu destino" }
    private var arrivalToday: Bool {
        guard let date = journey.arrivalAt else { return true }
        return Calendar.current.isDateInToday(date)
    }
    private var suggestions: [PlanSuggType] {
        var list: [PlanSuggType] = []
        // Show if user needs help OR destination has info configured
        let hasTransport = destination?.transportInfo != nil || (destination?.howToGetThere?.isEmpty == false)
        if !(journey.knowsHowToGet ?? true) || hasTransport { list.append(.howToGet) }
        let hasLodging = destination?.lodgingTips?.isEmpty == false
        if !(journey.hasLodging ?? true) || hasLodging { list.append(.lodging) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Photo area — tappable → navigates to map
            photoArea
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            // Readiness humano — la promesa del producto, antes que la logística
            if buddyCount != nil {
                BuddyReadinessRow(count: buddyCount, placeName: destName)
            }

            // Suggestion rows inside the card — un respiro más bajo la foto
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { type in
                        Divider().padding(.leading, 56)
                        suggestionRow(type)
                    }
                }
                .padding(.top, Spacing.sm)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .task { await loadBuddyCount() }
    }

    private func loadBuddyCount() async {
        guard buddyCount == nil else { return }
        let destId = journey.destination?.id ?? journey.destinationId
        guard let destId else { return }
        if let c = try? await APIClient.shared.fetchBuddyCount(destinationId: destId) {
            await MainActor.run { buddyCount = c }
        }
    }

    // MARK: – Photo section

    private var photoArea: some View {
        TripHeroBanner(
            coverUrl: journey.destination?.coverUrl,
            title: destName,
            dateLine: tripArrivalLine(journey.arrivalAt),
            statusText: arrivalToday ? "POR LLEGAR" : "TE ESPERAMOS",
            statusColor: arrivalToday ? Color(hex: "F59E0B") : Color(hex: "6EE7B7"),
            topEyebrow: "TU TRIP · \(arrivalToday ? "HOY" : "PRÓXIMO")",
            height: 200,
            trailing: {
                AnyView(
                    Button { onContactBuddy() } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44)
                            Image(systemName: "person.wave.2.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .overlay(alignment: .topTrailing) {
                            if unreadCount > 0 {
                                Text("\(min(unreadCount, 99))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, unreadCount > 9 ? 4 : 0)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                )
            }
        )
    }

    // MARK: – Suggestion row

    private func suggestionRow(_ type: PlanSuggType) -> some View {
        let isExpanded = expandedType == type
        return Button {
            Haptic.light()
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedType = isExpanded ? nil : type
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    ZStack {
                        Circle().fill(Color.teal.opacity(0.10)).frame(width: 36, height: 36)
                        Image(systemName: type == .howToGet ? "bus.fill" : "house.fill")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.teal)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(type == .howToGet ? "Cómo llegar" : "Dónde hospedarte")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        Text(type == .howToGet
                             ? (destination.map { "Tips para llegar a \($0.name)" } ?? "Opciones de transporte")
                             : "Hospedaje recomendado")
                            .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, 12)

                if isExpanded {
                    Divider().padding(.horizontal, Spacing.md)
                    expandedContent(for: type)
                        .padding(Spacing.md)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func expandedContent(for type: PlanSuggType) -> some View {
        if type == .lodging {
            if let text = destination?.lodgingTips, !text.isEmpty {
                Text(text).font(BT.callout).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Próximamente agregaremos esta info.")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
            }
        } else {
            transportContent
        }
    }

    @ViewBuilder
    private var transportContent: some View {
        if let info = destination?.transportInfo {
            VStack(alignment: .leading, spacing: 12) {
                // Bus
                if let bus = info.bus, bus.enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("En bus", systemImage: "bus.fill")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        if let companies = bus.companies, !companies.isEmpty {
                            Text(companies.joined(separator: " · "))
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let duration = bus.duration {
                            Label(duration, systemImage: "clock").font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let notes = bus.notes, !notes.isEmpty {
                            Text(notes).font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let urlStr = bus.ticketUrl, let url = URL(string: urlStr) {
                            Button { UIApplication.shared.open(url) } label: {
                                Label("Comprar pasaje", systemImage: "ticket.fill")
                                    .font(BT.footnoteBold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color.teal).foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Auto
                if let car = info.car, car.enabled, let routes = car.routes, !routes.isEmpty {
                    if info.bus?.enabled == true { Divider() }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("En auto", systemImage: "car.fill")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        ForEach(routes, id: \.name) { route in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Color.teal).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(route.name).font(BT.footnoteBold).foregroundStyle(Color.ink)
                                    Text(route.description).font(BT.caption1).foregroundStyle(Color.inkMuted)
                                }
                            }
                        }
                    }
                }

                // Buddy help
                if info.buddyHelp == true {
                    if info.bus?.enabled == true || info.car?.enabled == true { Divider() }
                    HStack(spacing: 8) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.teal)
                        Text("¿Necesitas ayuda? Chatea con un buddy")
                            .font(BT.footnoteBold).foregroundStyle(Color.teal)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                    }
                }
            }
        } else if let text = destination?.howToGetThere, !text.isEmpty {
            Text(text).font(BT.callout).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Próximamente agregaremos esta info.")
                .font(BT.callout).foregroundStyle(Color.inkMuted)
        }
    }
}



// MARK: – REGISTER TRIP SHEET

struct RegisterTripSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("¿A dónde vas?")
                    .font(BT.displayLarge)
                    .foregroundStyle(Color.ink)
                Text("Cuéntanos tu destino y te conectamos con un buddy antes de que llegues.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                Spacer()
            }
            .padding(Spacing.edge)
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Nuevo destino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
