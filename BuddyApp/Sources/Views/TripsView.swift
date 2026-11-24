import SwiftUI

// MARK: - TripsView (feed)

struct TripsView: View {
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var router: AppRouter
    @State private var showIdentitySheet = false
    @State private var pendingPublishJourneyId: String? = nil   // espera auth para publicar
    @State private var journeys: [APIJourney] = []
    @State private var isLoading = true
    @State private var hasLoadedOnce = false
    @State private var navPath = NavigationPath()
    /// "Mis trips" vive en Yo (Keyla, 19 Nov 2026): se empuja dentro del stack
    /// de Yo con su path; la pestaña pasó a ser Comunidad.
    var embedded = false
    var externalPath: Binding<NavigationPath>? = nil
    private var pathB: Binding<NavigationPath> { externalPath ?? $navPath }
    /// Vuelve a esta pantalla: en Yo solo quita lo que se abrió encima.
    private func popToSelf() {
        if embedded {
            let n = pathB.wrappedValue.count
            if n > 1 { pathB.wrappedValue.removeLast(n - 1) }
        } else {
            pathB.wrappedValue = NavigationPath()
        }
    }
    @State private var editTarget: EditTarget? = nil
    /// Override local: el id del trip recién activado con "Ya llegué".
    /// El backend confirma el PATCH pero el GET puede devolver datos stale,
    /// así que forzamos el estado "active" localmente hasta que el server sincronice.
    @State private var locallyActivatedId: String? = nil
    /// Journeys publicados O cancelados → se excluyen del tab para volver al estado
    /// vacío de inmediato, aunque el GET del backend devuelva datos stale.
    @State private var dismissedJourneyIds: Set<String> = []
    /// Trip cancelado completo → excluye todos sus journeys aunque el GET devuelva stale.
    @State private var dismissedTripId: String? = nil
    /// Trip seleccionado en el selector horizontal — el editor se vincula a este.
    @State private var selectedTripId: String? = nil
    /// (journeys con tripId=nil) — selección independiente de la de trips.
    // Acciones a nivel de tab (operan sobre el trip seleccionado / una locación)
    @State private var showCancelTripConfirm = false
    @State private var deleteTarget: APIJourney? = nil
    @State private var activeMatch: APIMatch? = nil
    @State private var showPublishConfirmFromParent = false   // disparado tras auth
    // Fase 2 "Buddy Community Places" — mismo singleton y flag que ya usa
    // ConexionesView para gatear "Oportunidades para ayudar".
    @StateObject private var chatStore = ChatStore.shared

    struct EditTarget: Identifiable {
        let id = UUID()
        let journey: APIJourney
        let pageIndex: Int
    }

    // El tab es el taller del trip EN CURSO. Los publicados viven en el perfil.
    //
    // Los journeys de "Compartir un lugar" (trip_id=null) usan exactamente
    // este mismo flujo — misma tarjeta, mismo editor, mismo botón "Publicar".
    // No hay ninguna rama especial para ellos: la única diferencia real vive
    // en el backend (trip_id null → nunca participan del PATCH /trips/:id en
    // cascada), no en esta pantalla.
    private var activeJourney: APIJourney? {
        // Override local primero (trip recién activado, aunque el server diga planning)
        if let id = locallyActivatedId, !dismissedJourneyIds.contains(id),
           let j = journeys.first(where: { $0.id == id }) {
            return j.withStatus("active")
        }
        return journeys.first { $0.status == "active" && !dismissedJourneyIds.contains($0.id) }
    }
    private var planningJourney: APIJourney? {
        journeys.first { $0.status == "planning" && $0.id != locallyActivatedId && !dismissedJourneyIds.contains($0.id) }
    }

    /// Trips vivos del usuario: en curso (active) y por llegar (planning).
    /// Los completados/publicados salen del tab (viven en el perfil/comunidad).
    /// Solo journeys de un viaje real (tripId != nil). Los "compartidos"
    /// standalone (tripId=nil) no viven acá: este tab es únicamente tus viajes,
    /// y los lugares que recomiendas se ven en el perfil.
    private var visibleTrips: [APIJourney] {
        let rank: (String) -> Int = { s in s == "active" ? 0 : 1 }
        return journeys
            .filter {
                $0.tripId != nil
                && !dismissedJourneyIds.contains($0.id)
                // nil != nil es false en Swift — sin el guard de dismissedTripId != nil,
                // esto excluía SIEMPRE a los journeys standalone (tripId=nil, "Compartir
                // un lugar") porque su tripId coincidía "por defecto" con dismissedTripId=nil.
                && (dismissedTripId == nil || $0.tripId != dismissedTripId)
                && ["active", "planning"].contains($0.status ?? "")
            }
            .map { locallyActivatedId == $0.id ? $0.withStatus("active") : $0 }
            .sorted { a, b in
                let ra = rank(a.status ?? ""), rb = rank(b.status ?? "")
                if ra != rb { return ra < rb }
                return (a.arrivalAt ?? .distantPast) > (b.arrivalAt ?? .distantPast)
            }
    }

    /// El trip cuyo editor se muestra. Cae al primero si el seleccionado ya no existe.
    private var selectedTrip: APIJourney? {
        visibleTrips.first { $0.id == selectedTripId } ?? visibleTrips.first
    }

    /// Sube al arrastrar para refrescar: TravelerStoriesSection recarga con él.
    @State private var storiesReloadToken = 0

    var body: some View {
        if embedded {
            core
        } else {
            NavigationStack(path: $navPath) { core }
        }
    }

    private var core: some View {
          ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Ancla del re-tap del tab: volver arriba.
                    Color.clear.frame(height: 0).id("tripsTop")

                    // Encabezado como en Inicio (Villa Rica, 19 Nov 2026).
                    tripsHeader

                    // Selector horizontal de trips — navegación, no contenido.
                    // Solo aparece si hay más de un trip que recordar.
                    if visibleTrips.count > 1 {
                        tripSelector
                            .padding(.top, Spacing.md)
                    }

                    // Contenido según estado del trip SELECCIONADO
                    if !Session.hasSession {
                        anonymousTripState
                    } else if isLoading && !hasLoadedOnce {
                        SkeletonBox(cornerRadius: 16)
                            .frame(height: 480)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)
                    } else if let journey = selectedTrip {
                        // Las acciones del trip viven dentro de su propia
                        // tarjeta: sin cabecera, no hay dónde colgarlas fuera.
                        tripCard(for: journey)
                            .overlay(alignment: .topTrailing) {
                                tripActionsMenu(for: journey)
                                    .padding(.trailing, 4)
                                    .padding(.top, 4)
                            }
                            .id("\(journey.id)-\(journey.status ?? "")")
                            .transition(.opacity)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)
                    } else {
                        emptyState
                    }

                    // Historias de otros viajeros, después de lo propio (el trip
                    // en curso o la invitación a registrar uno).
                    // Las historias de otros viven en la pestaña Comunidad.
                    if !embedded {
                        storiesHeader
                            .padding(.top, Spacing.xl)
                        TravelerStoriesSection(reloadToken: storiesReloadToken)
                            .padding(.top, 12)
                    }

                    Spacer().frame(height: 100)
                }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(embedded ? .automatic : .hidden, for: .navigationBar)
            .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
                guard note.object as? Int == AppTab.trips.rawValue else { return }
                guard !embedded else { return }
                if !navPath.isEmpty { navPath = NavigationPath() }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("tripsTop", anchor: .top) }
            }
            .task { await loadJourneys(trigger: "task") }
            .refreshable {
                storiesReloadToken += 1
                await loadJourneys(trigger: "refreshable")
            }
            // Al volver del flujo de registro (pop a raíz), un refresh dirigido
            .onChange(of: pathB.wrappedValue.count) { old, new in
                if new == (embedded ? 1 : 0) && old > new { Task { await loadJourneys(trigger: "navPath") } }
            }
            .onChange(of: authState.isLoggedIn) { _, loggedIn in
                if !loggedIn {
                    // El store es compartido: si no se vacía, la cuenta
                    // siguiente vería los journeys de la anterior.
                    JourneysStore.shared.clear()
                    MatchingStore.shared.clear()
                    journeys            = []
                    hasLoadedOnce       = false
                    dismissedJourneyIds = []
                    dismissedTripId     = nil
                    selectedTripId      = nil
                    popToSelf()
                } else {
                    Task { await loadJourneys(trigger: "isLoggedIn") }
                }
            }
            // Mapa del destino de una historia: el mismo de Inicio.
            .navigationDestination(for: DestinationMapRoute.self) { route in
                PlaceGuideMapSheet(destinationId: route.destinationId, name: route.name)
            }
            .navigationDestination(for: StoriesListRoute.self) { route in
                StoriesListView(route: route)
            }
            .navigationDestination(for: TravelerProfileRoute.self) { route in
                TravelerProfileView(travelerId: route.travelerId,
                                    previewName: route.name, previewAvatarUrl: route.avatarUrl)
            }
            .navigationDestination(for: APIJourney.self) { journey in
                TripDetailGate(journey: journey)
                    .environmentObject(routeStore)
            }
            .navigationDestination(for: String.self) { route in
                if route == "register" {
                    RegisterTripView { creado in
                        // El trip ya existe: se muestra al instante y se
                        // selecciona, sin esperar a otra ida al servidor.
                        JourneysStore.shared.insertar(creado)
                        if !journeys.contains(where: { $0.id == creado.id }) {
                            journeys.insert(creado, at: 0)
                        }
                        selectedTripId = creado.id
                        popToSelf()
                        Task { await loadJourneys(trigger: "registerTrip") }
                    }
                }
            }
          }
        .onReceive(NotificationCenter.default.publisher(for: .journeyActivated)) { _ in
            popToSelf()
            // El trip pasó de "por llegar" a "en curso" — un solo refresh dirigido
            Task { await loadJourneys(trigger: "notif:journeyActivated") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { note in
            // Publicar saca el trip del tab (pasa a completado → vive en el perfil).
            // Se excluye de inmediato aunque el GET del backend devuelva stale.
            if let id = note.object as? String {
                dismissedJourneyIds.insert(id)
                if selectedTripId == id { selectedTripId = nil }
            }
            locallyActivatedId = nil
            Task { await loadJourneys(trigger: "notif:journeyPublished") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyCancelled)) { note in
            // Cancelar/eliminar SÍ borra del backend → se excluye de inmediato.
            if let id = note.object as? String {
                dismissedJourneyIds.insert(id)
            }
            locallyActivatedId = nil
            Task { await loadJourneys(trigger: "notif:journeyCancelled") }
        }
        .fullScreenCover(item: $editTarget) { target in
            TripEditorSheet(journey: target.journey, initialPage: target.pageIndex) {
                Task { await loadJourneys(trigger: "sheetDismiss:editor") }
            }
        }
        .sheet(isPresented: $showIdentitySheet, onDismiss: {
            // Si cerró sin autenticarse, descarta la intención de publicar
            if !authState.isLoggedIn { pendingPublishJourneyId = nil }
        }) {
            IdentitySheet(purpose: .publish) {
                // Autenticado → lanzar confirmación de publicación
                if pendingPublishJourneyId != nil {
                    showPublishConfirmFromParent = true
                }
                pendingPublishJourneyId = nil
            }
            .environmentObject(authState)
        }
        .confirmationDialog("¿Cancelar tu viaje?", isPresented: $showCancelTripConfirm, titleVisibility: .visible) {
            Button("Cancelar trip", role: .destructive) { cancelActiveTrip() }
            Button("Mantener", role: .cancel) {}
        } message: {
            Text("Se eliminarán todos los lugares de este viaje y sus momentos. No se puede deshacer.")
        }
        .confirmationDialog(
            "¿Eliminar este lugar?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar lugar", role: .destructive) {
                if let t = deleteTarget { deleteJourney(t) }
                deleteTarget = nil
            }
            Button("Cancelar", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Se quitará este lugar del viaje. El resto se mantiene.")
        }
    }

    @ViewBuilder private func tripCard(for journey: APIJourney) -> some View {
        if (journey.status ?? "") == "planning" {
            PlanningHubCard(journey: journey) {
                locallyActivatedId = journey.id
            }
        } else {
            TripFeedCard(
                journey: journey,
                onEdit: { pageIndex in
                    editTarget = EditTarget(journey: journey, pageIndex: pageIndex)
                },
                onMapTap: { pathB.wrappedValue.append(journey) },
                buddyAvatarUrl: (journey.status ?? "") == "active" ? activeMatch?.buddy?.avatarUrl : nil,
                buddyFirstName: (journey.status ?? "") == "active"
                    ? activeMatch?.buddy?.fullName?.components(separatedBy: " ").first?.capitalized
                    : nil,
                externalPublishTrigger: $showPublishConfirmFromParent,
                onPublishTap: authState.isLoggedIn ? nil : {
                    pendingPublishJourneyId = journey.id
                    showIdentitySheet = true
                },
                showBuddyHelp: journey.tripId != nil
            )
        }
    }

    // MARK: - Selector horizontal de trips (estilo Apple Journal/Memories)

    private var tripSelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(visibleTrips) { trip in
                        TripSelectorCard(
                            journey: trip,
                            isSelected: trip.id == (selectedTrip?.id),
                            onTap: {
                                Haptic.select()
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    selectedTripId = trip.id
                                }
                                withAnimation { proxy.scrollTo(trip.id, anchor: .center) }
                            },
                            onDelete: { deleteTarget = trip }
                        )
                        .id(trip.id)
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    // Menú de acciones del VIAJE — solo cancelar.
    @ViewBuilder
    private func tripActionsMenu(for trip: APIJourney) -> some View {
        Menu {
            Button(role: .destructive) {
                Haptic.medium()
                showCancelTripConfirm = true
            } label: {
                Label("Cancelar trip", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
    }

    /// Cancela el VIAJE completo (todos sus lugares + apoyos en curso).
    private func cancelActiveTrip() {
        guard let tripId = selectedTrip?.tripId else { return }
        // Optimista: saca YA de la UI todos los lugares de este viaje.
        let removed = Set(journeys.filter { $0.tripId == tripId }.map { $0.id })
        withAnimation {
            dismissedTripId = tripId
            dismissedJourneyIds.formUnion(removed)
            journeys.removeAll { removed.contains($0.id) }
            selectedTripId = nil
        }
        Haptic.success()
        Task {
            try? await APIClient.shared.cancelTrip(tripId: tripId)
            await MainActor.run {
                NotificationCenter.default.post(name: .journeyCancelled, object: tripId)
            }
        }
    }

    /// Elimina UN lugar (journey) del viaje, sin cerrar el resto.
    private func deleteJourney(_ trip: APIJourney) {
        let jId = trip.id
        // Optimista: saca el lugar de la UI al instante.
        withAnimation {
            dismissedJourneyIds.insert(jId)
            journeys.removeAll { $0.id == jId }
            if selectedTripId == jId { selectedTripId = nil }
        }
        Haptic.success()
        Task {
            try? await APIClient.shared.cancelJourney(journeyId: jId)
            await MainActor.run {
                NotificationCenter.default.post(name: .journeyCancelled, object: jId)
            }
        }
    }

    // MARK: – Encabezados (estilo Inicio)

    private var tripsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tus trips")
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                    .accessibilityAddTraits(.isHeader)
                Text("Tu bitácora de viaje")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 8)
            // Solo con trips: sin ninguno, la tarjeta vacía ya trae su botón
            // (una sola acción principal por pantalla).
            if Session.hasSession && selectedTrip != nil {
                Button {
                    Haptic.medium()
                    pathB.wrappedValue.append("register")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        Text("Nuevo trip").font(BT.footnoteBold)
                    }
                    .foregroundStyle(Color.inkInverse)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.brand))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.top, Spacing.md)
    }

    private var storiesHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "book")
                .font(.system(size: 18))
                .foregroundStyle(Color.brand)
                .frame(width: 40, height: 40)
                .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trips de viajeros")
                    .font(.system(.title3).weight(.bold))
                    .foregroundStyle(Color.brand)
                    .accessibilityAddTraits(.isHeader)
                Text("Lo que otros vivieron cerca de ti")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.edge)
    }

    /// Estado vacío con la insignia de Inicio y el botón forest.
    private func emptyCard(icon: String, title: String, text: String, button: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.brand)
                .frame(width: 56, height: 56)
                .background(Color.paleSage, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title3).weight(.bold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(text)
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button {
                Haptic.medium()
                pathB.wrappedValue.append("register")
            } label: {
                Label(button, systemImage: "plus")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 44)
                    .background(Color.brand)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
            .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .padding(.horizontal, Spacing.md)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.sm))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .padding(.horizontal, Spacing.edge)
        .padding(.top, Spacing.md)
    }

    // MARK: – Estado anónimo del tab Tu trip

    @ViewBuilder
    private var anonymousTripState: some View {
        emptyCard(icon: "suitcase",
                  title: "Tu bitácora de viajes",
                  text: "Registra un destino, agrega momentos y comparte tu historia.",
                  button: "Empezar")
    }

    @ViewBuilder
    private var emptyState: some View {
        emptyCard(icon: "map",
                  title: "Tu próximo trip te espera",
                  text: "Registra tu próximo destino y comparte tu trip.",
                  button: "Registrar trip")
    }

    /// `trigger` y `line` solo instrumentan: nueve sitios llaman a esta
    /// función y el log no distinguía cuál. Sin behavior change.
    private func loadJourneys(trigger: String, line: Int = #line) async {
        dlog("🧳 [TripsView.load] trigger=\(trigger) line=\(line)")
        guard Session.hasSession else { isLoading = false; return }
        if !hasLoadedOnce { isLoading = true }
        let snapshotId = Session.travelerId
        // Solo actualizamos en ÉXITO. Si la red falla (offline transitorio),
        // conservamos los journeys que ya teníamos → la info no desaparece.
        //
        // El store decide si hay que ir al servidor: aparecer en pantalla no es
        // motivo suficiente, y el .task de esta vista reaparece muchas veces
        // porque el TabView recrea la pestaña. Un pull-to-refresh sí lo es.
        let store = JourneysStore.shared
        let fresco = (trigger == "refreshable" || trigger == "registerTrip")
            ? try? await store.refresh(trigger: "trips:\(trigger)")
            : try? await store.load(trigger: "trips:\(trigger)")
        if let fetched = fresco {
            // Anti cross-account: descarta si la identidad cambió durante el fetch.
            if Session.travelerId == snapshotId {
                journeys = fetched
                // Limpia dismissed que ya están confirmados por el server
                let serverIds = Set(fetched.map { $0.id })
                dismissedJourneyIds = dismissedJourneyIds.intersection(serverIds)
                if let dtid = dismissedTripId,
                   fetched.allSatisfy({ $0.tripId != dtid || $0.status == "cancelled" }) {
                    dismissedTripId = nil
                }
                dlog("🧳 [TripsView.load] journeys=\(fetched.map { "\($0.destination?.name ?? $0.place?.name ?? "·"):\($0.status ?? "nil"):trip=\(($0.tripId ?? "nil").prefix(6))" })")
            } else {
                print("⚠️ [TripsView] travelerId cambió durante el fetch — descarto resultado")
            }
        }
        // Selección por defecto: el activo, o el primero de la lista ordenada.
        // Si el trip seleccionado ya no existe (publicado/cancelado), reasigna.
        if selectedTripId == nil || !visibleTrips.contains(where: { $0.id == selectedTripId }) {
            selectedTripId = visibleTrips.first?.id
        }
        if let t = visibleTrips.first(where: { $0.id == selectedTripId }) ?? visibleTrips.first {
            dlog("🧳 [TripsView] selectedTrip id=\(t.id.prefix(8)) dest=\(t.destination?.name ?? "nil") place=\(t.place?.name ?? "nil") title=\(t.title ?? "nil")")
        }
        // Cargar match activo para mostrar avatar del buddy
        let hasActive = journeys.contains { $0.status == "active" }
        if hasActive, let matches = try? await MatchingStore.shared.load(trigger: "trips:\(trigger)") {
            let myTravelerId = Session.travelerId
            activeMatch = matches.first { ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myTravelerId }
        } else if !hasActive {
            activeMatch = nil
        }
        isLoading = false
        hasLoadedOnce = true
    }
}

// MARK: - TripSelectorCard
// Card compacta del selector horizontal. Reutiliza CachedImage + tipografía + badge.

struct TripSelectorCard: View {
    let journey: APIJourney
    let isSelected: Bool
    let onTap: () -> Void
    var onDelete: (() -> Void)? = nil

    private var name: String { journey.destination?.name ?? journey.title ?? "Trip" }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 116, height: 70)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))

                Text(name)
                    .font(BT.caption1.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .frame(width: 116)
            .padding(4)
            .background(isSelected ? Color.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md + 2))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md + 2)
                    .strokeBorder(isSelected ? Color.teal : Color.clear, lineWidth: 2)
            )
            .opacity(isSelected ? 1 : 0.7)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            if let onDelete {
                Button(role: .destructive) {
                    Haptic.medium()
                    onDelete()
                } label: {
                    Label("Eliminar lugar", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - TripFeedCard (Instagram-style)

struct TripFeedCard: View {
    let journey: APIJourney
    var onEdit: (Int) -> Void
    var onMapTap: (() -> Void)? = nil
    var buddyAvatarUrl: String? = nil
    var buddyFirstName: String? = nil
    var externalPublishTrigger: Binding<Bool>? = nil   // padre activa publicación tras auth
    var onPublishTap: (() -> Void)? = nil              // nil = publicar directo; non-nil = pedir auth primero
    /// false para journeys "Compartir un lugar" (tripId=nil) — no tienen buddy
    /// asignado ni match activo, así que la fila "¿Una duda en X?" no aplica.
    var showBuddyHelp: Bool = true

    @State private var pages: [CollagePage] = []
    @State private var currentPage = 0
    @State private var tripStatus: String
    @State private var isPublishing = false
    @State private var showPublishConfirm = false
    @State private var deleteTarget: Int? = nil
    @StateObject private var chatStore = ChatStore.shared
    @State private var showContactBuddy = false
    @State private var showCancelConfirm = false
    @State private var isCanceling = false
    @State private var showBlankPublishAlert = false
    @State private var hasBuddies: Bool = true

    /// Hay al menos una portada con contenido real (no en blanco)
    private var hasPublishableContent: Bool {
        pages.contains(where: MemoirPersistence.isPublishable)
    }

    init(journey: APIJourney, onEdit: @escaping (Int) -> Void, onMapTap: (() -> Void)? = nil, buddyAvatarUrl: String? = nil, buddyFirstName: String? = nil, externalPublishTrigger: Binding<Bool>? = nil, onPublishTap: (() -> Void)? = nil, showBuddyHelp: Bool = true) {
        self.journey = journey
        self.onEdit = onEdit
        self.onMapTap = onMapTap
        self.buddyAvatarUrl = buddyAvatarUrl
        self.buddyFirstName = buddyFirstName
        self.externalPublishTrigger = externalPublishTrigger
        self.onPublishTap = onPublishTap
        self.showBuddyHelp = showBuddyHelp
        _tripStatus = State(initialValue: journey.status ?? "planning")
    }

    private var isActive: Bool    { tripStatus == "active" }
    private var isCompleted: Bool { tripStatus == "completed" }
    /// Total de slides incluyendo la de "agregar momento" (si es editable).
    private var dotCount: Int { pages.count + (isCompleted ? 0 : 1) }
    // Compartidos (tripId=nil) documentan un local CONCRETO: el spot curado que
    // el buddy eligió ("Aneczú"), no la ciudad. Si no hay spot, el geocoding se
    // quedó a nivel ciudad y se avisa en vez de mostrar "Lima" como si fuera el
    // lugar compartido. Ver APIPlaceRef.isSpecificPlace.
    private var destName: String {
        if journey.tripId == nil {
            if let spot = journey.spot { return spot.name }
            if let place = journey.place, place.isSpecificPlace { return place.name }
            return "Lugar pendiente de designar"
        }
        return journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Trip"
    }
    private var destCity: String { journey.destination?.city ?? journey.place?.city ?? "" }
    /// Altura del preview de portada — relativa a la pantalla para que toda la
    /// tarjeta quepa sin scroll.
    // Mismo aspect ratio que el canvas del editor (ancho_pantalla × 480), medido
    // sobre el ancho real de la tarjeta → el preview muestra EXACTAMENTE lo que se
    // editó: sin recorte y sin barras laterales.
    private var previewHeight: CGFloat {
        let cardWidth = UIScreen.main.bounds.width - 2 * Spacing.edge
        let canvas = CanvasViewModel.pageSize
        return cardWidth * canvas.height / canvas.width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // — Trip header — tapping photo or name goes to the map
            Button(action: { onMapTap?() }) {
                HStack(spacing: 10) {
                    CachedImage(urlString: journey.destination?.coverUrl) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image("AppIconImage")
                            .resizable()
                            .scaledToFill()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(destName)
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                        statusBadge
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .disabled(onMapTap == nil)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            // — Pages carousel —
            if pages.isEmpty && !isActive {
                // Completado sin fotos — no mostrar nada
                EmptyView()
            } else if pages.isEmpty {
                emptyCanvasCard
            } else {
                // El carrusel LLENA la tarjeta (sin Spacer blanco debajo); dots como overlay
                ZStack(alignment: .bottom) {
                    TabView(selection: $currentPage) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            TripPageThumbnailFeed(page: page, journeyId: journey.id,
                                                  coverUrl: journey.destination?.coverUrl)
                                .tag(index)
                                .contentShape(Rectangle())
                                .onTapGesture { if !isCompleted { onEdit(index) } }
                                .contextMenu {
                                    if !isCompleted {
                                        Button { Haptic.light(); onEdit(-1) } label: {
                                            Label("Nuevo momento", systemImage: "plus")
                                        }
                                        if pages.count > 1 {
                                            Button(role: .destructive) { deleteTarget = index } label: {
                                                Label("Eliminar momento", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                        }
                        // Slide final: agregar otro momento (solo si editable)
                        if !isCompleted {
                            addMomentSlide
                                .tag(pages.count)
                                .contentShape(Rectangle())
                                .onTapGesture { Haptic.light(); onEdit(-1) }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if dotCount > 1 {
                        HStack(spacing: 6) {
                            ForEach(0..<dotCount, id: \.self) { i in
                                Circle()
                                    .fill(i == currentPage ? Color.white : Color.white.opacity(0.5))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(Capsule().fill(.black.opacity(0.25)))
                        .padding(.bottom, 12)
                    }
                }
                .frame(height: previewHeight)
            }

            // — La promesa sigue viva en destino: ayuda a un toque —
            if HomeRowsView.showsBuddyTools && isActive && hasBuddies && showBuddyHelp {
                Divider().padding(.leading, 56).padding(.horizontal, Spacing.md)
                Button { showContactBuddy = true } label: {
                    HStack(spacing: Spacing.sm) {
                        ZStack {
                            if let avatarUrl = buddyAvatarUrl {
                                CachedImage(urlString: avatarUrl) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Circle().fill(Color.teal.opacity(0.10))
                                        .overlay(Image(systemName: "person.wave.2.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.teal))
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                            } else {
                                Circle().fill(Color.teal.opacity(0.10)).frame(width: 36, height: 36)
                                Image(systemName: "person.wave.2.fill")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.teal)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            let count = chatStore.travelerUnread
                            if count > 0 {
                                Text("\(min(count, 99))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, count > 9 ? 3 : 0)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Color.errorRed)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                                    .offset(x: 3, y: -3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("¿Una duda en \(destName)?")
                                .font(BT.footnoteBold).foregroundStyle(Color.ink)
                            Text(buddyFirstName.map { "\($0) sigue disponible" } ?? "Tu buddy sigue disponible")
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, Spacing.md).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }

            // — Publicar historia — acción primaria, visible cuando hay contenido listo
            if isActive && hasPublishableContent {
                Divider().padding(.leading, Spacing.md)
                Button {
                    if let onPublishTap {
                        onPublishTap()
                    } else {
                        showPublishConfirm = true
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: 3) {
                            if isPublishing {
                                ProgressView().tint(Color.teal).scaleEffect(0.8)
                            } else {
                                Text("Publicar esta historia")
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(Color.ink)
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.teal)
                                Text("Tu historia está lista")
                                    .font(BT.caption1)
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(isPublishing)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showContactBuddy) {
            ContactarBuddyView(journey: journey)
        }
        .confirmationDialog(
            "¿Eliminar esta portada?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar portada", role: .destructive) {
                if let i = deleteTarget { deletePage(at: i) }
                deleteTarget = nil
            }
            Button("Cancelar", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Las fotos de esta portada se quitarán del trip.")
        }
        .confirmationDialog("¿Publicar esta historia?", isPresented: $showPublishConfirm, titleVisibility: .visible) {
            Button("Publicar") { publishTrip() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tu historia quedará visible para la comunidad. Después no podrás editarla.")
        }
        .alert("Tu portada está en blanco", isPresented: $showBlankPublishAlert) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Agrega al menos una foto a tu portada antes de publicar tu trip.")
        }
        .confirmationDialog("¿Cancelar este trip?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancelar trip", role: .destructive) { cancelTrip() }
            Button("Mantener", role: .cancel) {}
        } message: {
            Text("No podrás recuperar este trip ni sus momentos después de cancelarlo.")
        }
        .onAppear { loadPages() }
        .task { await fetchBuddyAvailability() }
        .onChange(of: externalPublishTrigger?.wrappedValue ?? false) { _, triggered in
            if triggered {
                showPublishConfirm = true
                externalPublishTrigger?.wrappedValue = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoirPageSaved)) { note in
            if let id = note.object as? String, id == journey.id {
                loadPages()
            }
        }
    }

    private func fetchBuddyAvailability() async {
        let destId  = journey.destination?.id ?? journey.destinationId
        let placeId = journey.placeId
        let (id, source): (String, String)
        if let d = destId       { id = d; source = "destination" }
        else if let p = placeId { id = p; source = "place" }
        else { await MainActor.run { hasBuddies = false }; return }
        guard let ctx = try? await APIClient.shared.fetchPlaceContext(id: id, source: source) else { return }
        dlog("🧳 [TripFeedCard] buddyContext id=\(id.prefix(8)) total=\(ctx.totalBuddies) status=\(ctx.status)")
        await MainActor.run { hasBuddies = ctx.totalBuddies > 0 }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch tripStatus {
            case "active":
                // Sin arrival_at (trips creados por matching/pioneer) el badge
                // caía siempre en "Desde hoy" — created_at como respaldo real.
                let days = (journey.arrivalAt ?? journey.createdAt).map {
                    Calendar.current.dateComponents([.day],
                        from: Calendar.current.startOfDay(for: $0),
                        to:   Calendar.current.startOfDay(for: Date())).day ?? 0
                } ?? 0
                let text: String = {
                    if days <= 0 { return "Desde hoy" }
                    if days == 1 { return "Desde hace 1 día" }
                    return "Desde hace \(days) días"
                }()
                return (text, Color.teal)
            case "completed": return ("COMPLETADO", Color.sand)
            default:
                if let arrival = journey.arrivalAt {
                    let days = Calendar.current.dateComponents([.day],
                        from: Calendar.current.startOfDay(for: Date()),
                        to:   Calendar.current.startOfDay(for: arrival)).day ?? 0
                    if days == 0 { return ("Llega hoy", Color.inkMuted) }
                    if days == 1 { return ("Llega mañana", Color.inkMuted) }
                    return ("En \(days) días", Color.inkMuted)
                }
                return ("POR LLEGAR", Color.inkMuted)
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(BT.eyebrow)
                .tracking(0.4)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    // Slide final del carrusel: invita a agregar otro momento (foto del lugar de fondo).
    private var addMomentSlide: some View {
        Color.clear
            .frame(minHeight: previewHeight, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .overlay {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(colors: [Color.tealDeep, Color.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(Color.black.opacity(0.4))
            .overlay {
                VStack(spacing: Spacing.sm) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(0.8),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .frame(width: 56, height: 56)
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.white)
                    }
                    Text("Agregar otro momento")
                        .font(BT.footnoteBold)
                        .foregroundStyle(.white)
                }
            }
            .clipped()
    }

    @ViewBuilder
    private var emptyCanvasCard: some View {
        Color.clear
            .frame(minHeight: previewHeight, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .overlay {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(colors: [Color.tealDeep, Color.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(Color.black.opacity(0.35))
            .overlay {
                VStack(spacing: Spacing.md) {
                    // + button goes to editor
                    Button { onEdit(-1) } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                .frame(width: 64, height: 64)
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("Tu historia empieza aquí")
                            .font(BT.headline)
                            .foregroundStyle(.white)
                        Text("Guarda los momentos mientras vives \(destName)")
                            .font(BT.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(Spacing.lg)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if !isCompleted { Haptic.light(); onEdit(-1) } else { onMapTap?() } }
    }

    // MARK: - Logic

    private func deletePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        var updated = pages
        updated.remove(at: index)
        pages = updated
        currentPage = min(currentPage, max(0, updated.count - 1))
        Haptic.success()
        let jId = journey.id
        Task.detached(priority: .utility) {
            MemoirPersistence.shared.save(updated, journeyId: jId)
        }
    }

    private func loadPages() {
        let jId = journey.id
        Task.detached(priority: .userInitiated) {
            let loaded = MemoirPersistence.shared.load(journeyId: jId)
            await MainActor.run { pages = loaded }
        }
    }

    private func publishTrip() {
        let jId = journey.id
        dlog("📤 [publishTrip] journeyId=\(jId) pages.count=\(pages.count)")
        guard hasPublishableContent else {
            dlog("📤 [publishTrip] BLOQUEADO: hasPublishableContent=false — no hay páginas con items ni bgFile")
            showBlankPublishAlert = true
            return
        }
        // Solo se publican las portadas con contenido real; las vacías se descartan
        let currentPages: [CollagePage]
        do {
            dlog("📤 [publishTrip] BEFORE filter: \(pages.count) page(s)")
            for (i, p) in pages.enumerated() {
                let kept = MemoirPersistence.isPublishable(p)
                dlog("📤 [publishTrip]   page[\(i)] id=\(p.id) items=\(p.itemSnapshots.count) bgFile=\(p.backgroundImageFile ?? "nil") thumb=\(p.thumbnailFileName ?? "nil") → \(kept ? "KEPT" : "DISCARDED")")
            }
            currentPages = pages.filter(MemoirPersistence.isPublishable)
            dlog("📤 [publishTrip] AFTER filter: \(currentPages.count) page(s)")
        }
        isPublishing = true
        Task {
            try? await APIClient.shared.publishJourney(journeyId: jId, tripId: journey.tripId, pages: currentPages)
            await MainActor.run {
                tripStatus = "completed"
                isPublishing = false
                Haptic.success()
                NotificationCenter.default.post(name: .journeyPublished, object: jId)
                AppRouter.shared.switchTo(.inicio)
            }
        }
    }

    private func cancelTrip() {
        let jId = journey.id
        isCanceling = true
        Task {
            try? await APIClient.shared.cancelJourney(journeyId: jId)
            await MainActor.run {
                isCanceling = false
                Haptic.success()
                // Cancelado → se excluye del tab de inmediato (evita stale del backend)
                NotificationCenter.default.post(name: .journeyCancelled, object: jId)
            }
        }
    }
}

// MARK: - Thumbnail for feed (no tap zone interference)

struct TripPageThumbnailFeed: View {
    let page: CollagePage
    let journeyId: String
    var coverUrl: String? = nil          // foto del destino → fallback, nunca blanco
    @State private var thumbnail: UIImage? = nil
    @State private var bgImage: UIImage? = nil

    /// Una página con thumbnail pero SIN items ni fondo es una portada en blanco
    /// (no contenido real) → la tratamos como vacía.
    private var pageHasContent: Bool {
        MemoirPersistence.isPublishable(page)
    }
    /// Página sin contenido propio → mostramos la foto del destino de fondo
    private var showsCoverFallback: Bool {
        !pageHasContent && (coverUrl?.isEmpty == false)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let bg = bgImage {
                    Image(uiImage: bg).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                    Color.white.opacity(0.45)
                } else if showsCoverFallback {
                    // Sin imagen aún → foto del destino + scrim (jamás pantalla en blanco)
                    CachedImage(urlString: coverUrl) { img in
                        img.resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    } placeholder: {
                        LinearGradient(colors: [Color.tealDeep, Color.teal],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    Color.black.opacity(0.35)
                } else {
                    Color(red: page.backgroundRGBA[safe: 0] ?? 0.93,
                          green: page.backgroundRGBA[safe: 1] ?? 0.93,
                          blue:  page.backgroundRGBA[safe: 2] ?? 0.93)
                }

                if pageHasContent, let thumb = thumbnail {
                    // scaledToFit: la portada JAMÁS se recorta — lo que se guardó en
                    // el editor es EXACTAMENTE lo que se ve. El preview ya tiene el
                    // mismo aspect ratio que el canvas, así que no quedan barras.
                    Image(uiImage: thumb).resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if page.itemSnapshots.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(showsCoverFallback ? .white : Color.secondary)
                        Text("Toca para agregar tu primer momento")
                            .font(BT.footnote)
                            .foregroundStyle(showsCoverFallback ? .white.opacity(0.95) : Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .shadow(color: showsCoverFallback ? .black.opacity(0.3) : .clear, radius: 4)
                    .padding(.horizontal, Spacing.lg)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { loadAssets() }
        .onChange(of: page.editVersion) { _, _ in thumbnail = nil; loadAssets() }
    }

    private func loadAssets() {
        let jId = journeyId
        let tFile = page.thumbnailFileName
        let bFile = page.backgroundImageFile
        let hasContent = pageHasContent
        Task.detached(priority: .userInitiated) {
            // Solo cargamos el thumbnail si la página tiene contenido real
            let thumb = hasContent ? tFile.flatMap { MemoirPersistence.shared.loadThumbnail($0, journeyId: jId) } : nil
            let bg    = bFile.flatMap { MemoirPersistence.shared.loadBackground($0, journeyId: jId) }
            await MainActor.run { thumbnail = thumb; bgImage = bg }
        }
    }
}

// MARK: - TripEditorSheet (editor directo sin book view)

struct TripEditorSheet: View {
    let journey: APIJourney
    let initialPage: Int
    /// Sumar una foto a una recomendación publica en el mismo gesto: el lugar la
    /// muestra recién cuando el journey está publicado, así que dejarla guardada
    /// sin publicar sería trabajo que el usuario cree hecho y no se ve.
    let publishesOnSave: Bool
    let onDismiss: () -> Void

    @StateObject private var bookVM: TripBookViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var didStart = false

    init(journey: APIJourney, initialPage: Int, publishesOnSave: Bool = false, onDismiss: @escaping () -> Void) {
        self.journey = journey
        self.initialPage = initialPage
        self.publishesOnSave = publishesOnSave
        self.onDismiss = onDismiss
        _bookVM = StateObject(wrappedValue: TripBookViewModel(journeyId: journey.id))
    }

    private func publish() {
        // Mismo filtro que el resto de las publicaciones: las páginas vacías no
        // llegan al servidor.
        let pages = bookVM.pages.filter(MemoirPersistence.isPublishable)
        let jId = journey.id
        Task {
            try? await APIClient.shared.publishJourney(journeyId: jId, tripId: journey.tripId, pages: pages)
            await MainActor.run {
                Haptic.success()
                NotificationCenter.default.post(name: .journeyPublished, object: jId)
            }
        }
    }

    var body: some View {
        TripCanvasEditorView(vm: bookVM.editingVM, bookVM: bookVM,
                             onPublish: publishesOnSave ? publish : nil)
            .onAppear {
                // Guard: onAppear puede dispararse 2x (fullScreenCover/NavigationStack)
                // → sin esto, "Nueva portada" creaba 2 páginas.
                guard !didStart else { return }
                didStart = true
                if initialPage == -1 {
                    // "Nuevo momento": si el libro solo tiene la página vacía que
                    // crea el init, edítala en vez de añadir otra (evita una página
                    // default fantasma antes de la foto recién subida).
                    let onlyEmptyPage = bookVM.pages.count == 1
                        && !MemoirPersistence.isPublishable(bookVM.pages[0])
                    if onlyEmptyPage {
                        bookVM.enterEdit(at: 0)
                    } else {
                        bookVM.addPage()      // crea página nueva y entra al editor
                    }
                } else {
                    bookVM.enterEdit(at: initialPage)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: bookVM.isEditing) { _, editing in
                if !editing { dismiss() }
            }
    }
}

// MARK: - Planning Hub Card
// Shown in Tu Trip when journey is planning and arrival is >1 day away

struct PlanningHubCard: View {
    let journey: APIJourney
    let onUpdate: () -> Void

    @StateObject private var chatStore = ChatStore.shared
    @State private var knowsHowToGet: Bool
    @State private var hasLodging: Bool
    @State private var showDatePicker = false
    @State private var newArrivalDate: Date
    @State private var displayedArrival: Date?   // fecha mostrada (refresca local sin recargar)
    @State private var showCancelConfirm = false
    @State private var isSaving = false
    @State private var isActivating = false
    @State private var buddyCount: Int? = nil
    @State private var showContactBuddy = false

    init(journey: APIJourney, onUpdate: @escaping () -> Void) {
        self.journey = journey
        self.onUpdate = onUpdate
        _knowsHowToGet = State(initialValue: journey.knowsHowToGet ?? false)
        _hasLodging    = State(initialValue: journey.hasLodging ?? false)
        _newArrivalDate = State(initialValue: journey.arrivalAt ?? Date())
        _displayedArrival = State(initialValue: journey.arrivalAt)
    }

    private var destName: String { journey.destination?.name ?? "Tu destino" }
    private var days: Int {
        guard let date = displayedArrival else { return 0 }
        return Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // — Hero compartido (mismo objeto que en Home) —————————
            TripHeroBanner(
                coverUrl: journey.destination?.coverUrl,
                title: destName,
                dateLine: tripArrivalLine(displayedArrival),
                statusText: "TE ESPERAMOS",
                height: 200,
                trailing: {
                    AnyView(
                        Button { Haptic.light(); showContactBuddy = true } label: {
                            ZStack {
                                Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44)
                                Image(systemName: "person.wave.2.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .overlay(alignment: .topTrailing) {
                                let count = chatStore.travelerUnread
                                if count > 0 {
                                    Text("\(min(count, 99))")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, count > 9 ? 4 : 0)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Color.errorRed)
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

            // — Readiness humano — la promesa, antes que la logística —————
            if buddyCount != nil {
                BuddyReadinessRow(count: buddyCount, placeName: destName)
                    .padding(.top, Spacing.md)
            }

            // — Countdown / llegada ——————————————————
            if days >= 1 {
                // Faltan días → contador + cambiar fecha
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(days)")
                            .font(.system(size: 40, weight: .bold)).foregroundStyle(Color.ink)
                            .monospacedDigit()
                        Text(days == 1 ? "día para llegar" : "días para llegar")
                            .font(BT.subhead).foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    changeDateButton
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.lg)
            } else {
                // Día de llegada → estado arriba; la acción "Ya llegué" vive al pie
                HStack(alignment: .firstTextBaseline) {
                    Text("Hoy es el día")
                        .font(BT.title3).foregroundStyle(Color.ink)
                    Spacer()
                    changeDateButton
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.lg)
            }

            if showDatePicker {
                DatePicker("", selection: $newArrivalDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Color.teal)
                    .padding(.horizontal, Spacing.md)

                Button {
                    Haptic.medium()
                    saveDate()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().scaleEffect(0.8).tint(Color.inkInverse) }
                        else { Text("Guardar fecha").font(BT.footnoteBold) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.ink).foregroundStyle(Color.inkInverse)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                }
                .disabled(isSaving)
                .buttonStyle(.pressable)
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.sm)
            }

            // — Checklist — no es una lista de tareas, es dónde alguien te apoya —
            Text("PARA TU LLEGADA")
                .font(BT.eyebrow).tracking(1.5).foregroundStyle(Color.ink)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.lg).padding(.bottom, Spacing.xs)

            checklistRow(icon: "bus.fill", label: "Cómo llegar", isOn: $knowsHowToGet) {
                saveChecklist()
            }
            Divider().padding(.leading, 56).padding(.horizontal, Spacing.md)
            checklistRow(icon: "house.fill", label: "Dónde hospedarte", isOn: $hasLodging) {
                saveChecklist()
            }

            if HomeRowsView.showsBuddyTools {
            Text("Lo que dejes pendiente, un buddy puede ayudarte cuando llegues.")
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
            }

            // — Acción principal del día de llegada — al pie, alcanzable con el pulgar —
            if days < 1 {
                Button {
                    Haptic.medium()
                    activateTrip()
                } label: {
                    HStack(spacing: 6) {
                        if isActivating {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Text("Ya llegué").font(BT.headline)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(.white)
                    .background(Color.teal)
                    .clipShape(Capsule())
                }
                .disabled(isActivating)
                .buttonStyle(.pressable)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
            }

            // — Cancelar — texto destructivo discreto (no es la acción principal) —
            Button {
                Haptic.light()
                showCancelConfirm = true
            } label: {
                Text("Cancelar trip")
                    .font(BT.subhead)
                    .foregroundStyle(Color.errorRed.opacity(0.85))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.pressable)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.sm)
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .task { await loadBuddyCount() }
        .sheet(isPresented: $showContactBuddy) {
            ContactarBuddyView(journey: journey)
        }
        .confirmationDialog("¿Cancelar tu trip a \(destName)?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancelar trip", role: .destructive) { cancelTrip() }
            Button("No cancelar", role: .cancel) {}
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
    }

    @ViewBuilder
    private func checklistRow(icon: String, label: String, isOn: Binding<Bool>, onChange: @escaping () -> Void) -> some View {
        Button {
            Haptic.select()
            isOn.wrappedValue.toggle()
            onChange()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isOn.wrappedValue ? Color.teal : Color.inkMuted)
                    .frame(width: 32)
                Text(label)
                    .font(BT.callout).foregroundStyle(Color.ink)
                Spacer()
                // Estado legible — nunca un anillo vacío ambiguo
                if isOn.wrappedValue {
                    Label("Listo", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.teal)
                } else {
                    Text("Pendiente")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.canvas)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, Spacing.md).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityValue(isOn.wrappedValue ? "Listo" : "Pendiente")
    }

    private var changeDateButton: some View {
        Button {
            Haptic.light()
            withAnimation { showDatePicker.toggle() }
        } label: {
            Label("Cambiar fecha", systemImage: "calendar")
                .font(BT.subhead.weight(.semibold))
                .foregroundStyle(Color.teal)
        }
        .buttonStyle(.pressable)
    }

    private func activateTrip() {
        isActivating = true
        Task {
            try? await APIClient.shared.updateJourneyStatus(journeyId: journey.id, status: "active")
            await MainActor.run {
                isActivating = false
                Haptic.success()
                onUpdate()
            }
        }
    }

    private func loadBuddyCount() async {
        guard buddyCount == nil else { return }
        let destId = journey.destination?.id ?? journey.destinationId
        guard let destId else { return }
        if let c = try? await APIClient.shared.fetchBuddyCount(destinationId: destId) {
            await MainActor.run { buddyCount = c }
        }
    }

    private func saveDate() {
        isSaving = true
        let newDate = newArrivalDate
        Task {
            _ = try? await APIClient.shared.updateJourney(journeyId: journey.id, arrivalAt: newDate)
            await MainActor.run {
                isSaving = false
                Haptic.success()
                // NO usar onUpdate() (eso activa el trip y abre el editor).
                // La fecha se refleja con el estado local → el countdown se actualiza.
                displayedArrival = newDate
                withAnimation { showDatePicker = false }
            }
        }
    }

    private func saveChecklist() {
        Task {
            _ = try? await APIClient.shared.updateJourney(
                journeyId: journey.id,
                knowsHowToGet: knowsHowToGet,
                hasLodging: hasLodging
            )
        }
    }

    private func cancelTrip() {
        let jId = journey.id
        Task {
            try? await APIClient.shared.cancelJourney(journeyId: jId)
            await MainActor.run {
                Haptic.success()
                // NO usar onUpdate() (eso activa el trip y abre el editor).
                // Postear cancelación → TripsView excluye el trip → estado vacío.
                NotificationCenter.default.post(name: .journeyCancelled, object: jId)
            }
        }
    }
}

// MARK: - Legacy structs (kept for compatibility)

struct TripEntry: Identifiable {
    let id = UUID()
    let title: String
    let city: String
    let country: String
    let date: String
    let photoCount: Int
    let likes: Int
    let status: Status
    let privacy: Privacy
    let gradientStart: String
    let gradientEnd: String

    enum Status {
        case inProgress, published
        var label: String { self == .inProgress ? "EN CURSO" : "PUBLICADO" }
    }
    enum Privacy: Equatable {
        case `private`, `public`
        var label: String { self == .private ? "privado" : "público" }
        var icon:  String { self == .private ? "lock.fill" : "globe" }
    }
    static let samples: [TripEntry] = []
}

// MARK: – GPS Place Map Gate

// MARK: – Historias de viajeros
// Antes vivía en el Home. Se mudó al tab Trips: el Home queda para lugares
// cerca y consultar buddies, y deja de cargar el feed más pesado de la app.
// Carga su propio contenido (cerca de la ubicación actual) con paginación.

struct TravelerStoriesSection: View {
    /// Cambia al refrescar el tab: vuelve a pedir la primera página.
    var reloadToken: Int

    @State private var stories: [APIJourney] = []
    @State private var cursor: String? = nil
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var failed = false
    @State private var seenIds = Set<String>()
    /// El reloadToken con el que ya se cargó: aparecer de nuevo no recarga.
    @State private var loadedToken: Int? = nil

    private var lat: Double? { LocationService.current?.userLocation?.coordinate.latitude }
    private var lng: Double? { LocationService.current?.userLocation?.coordinate.longitude }

    var body: some View {
        Group {
            if isLoading && stories.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonBox(cornerRadius: 0).frame(height: 300)
                        HStack(spacing: 8) {
                            SkeletonBox(cornerRadius: 12).frame(width: 24, height: 24)
                            SkeletonBox(cornerRadius: 4).frame(width: 100, height: 13)
                            Spacer(minLength: 4)
                            SkeletonBox(cornerRadius: 4).frame(width: 50, height: 12)
                        }
                        .padding(14)
                    }
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .cardShadow()
                    .padding(.horizontal, Spacing.edge)
                }
                .skeletonPulse()
            } else if failed {
                VStack(spacing: Spacing.sm) {
                    Text("No pudimos cargar los trips")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Button {
                        Task { await load() }
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
            } else if !stories.isEmpty {
                // Filas tipo Inicio (Keyla, 19 Nov 2026): carruseles por tema.
                StoriesRowsView(stories: stories)
            } else {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    VStack(spacing: 8) {
                        Text("Aún nadie ha contado su paso por aquí")
                            .font(BT.callout).foregroundStyle(Color.ink)
                        Text("Cuando termines tu trip, el tuyo será el primero.")
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .padding(.horizontal, Spacing.edge)
                }
            }
        }
        // Solo al aparecer la PRIMERA vez o al refrescar (reloadToken). Volver de
        // un mapa o un perfil hacía aparecer la vista otra vez, se pedía todo
        // de nuevo y el orden se movía un poco (Keyla, 21 Nov 2026).
        .task(id: reloadToken) {
            guard loadedToken != reloadToken else { return }
            loadedToken = reloadToken
            await load()
        }
    }

    /// Primera página, con un reintento: un timeout puntual no puede dejar la
    /// sección vacía en silencio.
    private func load() async {
        if stories.isEmpty { isLoading = true }
        for attempt in 0..<2 {
            do {
                let page = try await APIClient.shared.fetchStories(
                    destinationId: nil, lat: lat, lng: lng, cursor: nil)
                dlog("🗞️ [TravelerStories] items=\(page.items.count)")
                stories = page.items
                seenIds = Set(page.items.map(\.id))
                cursor = page.nextCursor
                hasMore = page.hasMore
                failed = false
                isLoading = false
                // Las filas agrupan por destino: dos páginas más dan filas llenas.
                for _ in 0..<2 where hasMore { await loadMore() }
                return
            } catch {
                if Task.isCancelled { return }
                print("❌ [TravelerStories] intento \(attempt + 1) falló: \(error)")
                if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
        }
        isLoading = false
        failed = stories.isEmpty
    }

    /// Siguiente página. Una página puede volver ENTERA repetida (el servidor
    /// mezcla una cabecera de trips cercanos en la primera página y luego no la
    /// excluye), y entonces no se agrega ninguna tarjeta nueva: sin tarjeta
    /// nueva no hay onAppear que dispare la página siguiente y el listado se
    /// queda clavado. Por eso se sigue pidiendo mientras el servidor diga que
    /// hay más y no llegue nada nuevo, con un tope para no encadenar llamadas.
    private func loadMore() async {
        guard hasMore, !isLoadingMore, cursor != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        for intento in 0..<3 {
            guard hasMore, let cursorActual = cursor else { return }
            do {
                let page = try await APIClient.shared.fetchStories(
                    destinationId: nil, lat: lat, lng: lng, cursor: cursorActual)
                let fresh = page.items.filter { seenIds.insert($0.id).inserted }
                cursor  = page.nextCursor
                hasMore = page.hasMore && page.nextCursor != nil
                if !fresh.isEmpty {
                    stories.append(contentsOf: fresh)
                    return
                }
                dlog("🗞️ [TravelerStories] página \(intento + 1) sin novedades (\(page.items.count) repetidos) — sigo")
            } catch {
                if Task.isCancelled { return }
                print("❌ [TravelerStories] loadMore: \(error)")
                return
            }
        }
    }
}


// MARK: – Historias en filas (como Inicio)
//
// Orden pensado para el visitante (Keyla, 19 Nov 2026):
//   1. Viajeros: avatares de quienes publicaron (abren su perfil).
//   2. Recientes: lo último publicado, primero.
//   3. Una fila por destino, en el orden de cercanía que da el servidor
//      (el destino donde está el visitante sale primero).
//   4. Más historias: destinos con una sola historia, juntos al final.
// Cada fila tiene "Ver todos" → lista completa con la misma tarjeta grande.

struct StoriesListRoute: Hashable {
    let title: String
    let journeys: [APIJourney]
}

struct StoriesRowsView: View {
    let stories: [APIJourney]

    /// Publicación abierta en el visor, con su fila (Keyla, 21 Nov 2026).
    struct Presented: Identifiable { let id = UUID(); let row: String; let list: [APIJourney]; let start: APIJourney }
    @State private var presented: Presented? = nil
    @Namespace private var rowsZoom
    /// "<fila>|<id>" de la publicación que se ve: su tarjeta se pone en pantalla y
    /// al cerrar la foto vuelve a ella.
    @State private var zoomKey: String = ""

    private func destName(_ j: APIJourney) -> String {
        j.destination?.name ?? j.place?.name ?? "Otros lugares"
    }

    private func mapRoute(_ items: [APIJourney], name: String) -> DestinationMapRoute? {
        guard let id = items.lazy.compactMap({ $0.destination?.id ?? $0.destinationId }).first else { return nil }
        return DestinationMapRoute(destinationId: id, name: name)
    }

    private var recent: [APIJourney] {
        Array(stories.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(10))
    }

    /// (destino, historias) en orden de primera aparición = cercanía.
    private var groups: [(String, [APIJourney])] {
        var order: [String] = []; var map: [String: [APIJourney]] = [:]
        for j in stories {
            let k = destName(j)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(j)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var travelers: [APIUserRef] {
        var seen = Set<String>(); var out: [APIUserRef] = []
        for j in stories { if let u = j.users, let id = u.id, seen.insert(id).inserted { out.append(u) } }
        return out
    }

    var body: some View {
        let big = groups.filter { $0.1.count > 1 }
        let singles = groups.filter { $0.1.count == 1 }.flatMap(\.1)
        LazyVStack(alignment: .leading, spacing: Spacing.xl) {
            if travelers.count > 1 { travelersRow }
            row(title: "Recientes", subtitle: "Lo último que compartieron", items: recent, all: stories)
            ForEach(big, id: \.0) { name, items in
                row(title: "En \(name)", subtitle: "\(items.count) trips", items: items, all: items, showsPlace: false,
                    map: mapRoute(items, name: name))
            }
            if !singles.isEmpty {
                row(title: "Más trips", subtitle: "Otros destinos de viajeros", items: singles, all: singles)
            }
        }
        .fullScreenCover(item: $presented) { p in
            StoryViewerSheet(journeys: p.list, start: p.start, systemDismiss: PhotoZoom.systemAvailable,
                             onShowing: { zoomKey = "\(p.row)|\($0)" })
                .photoZoomDestination(id: zoomKey, in: rowsZoom)
        }
    }

    private var travelersRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Viajeros", count: travelers.count)
                .padding(.horizontal, Spacing.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(travelers, id: \.id) { u in
                        NavigationLink(value: TravelerProfileRoute(travelerId: u.id ?? "", name: u.fullName, avatarUrl: u.avatarUrl)) {
                            VStack(spacing: 6) {
                                let name = (u.fullName ?? "Viajero").capitalized
                                Circle().fill(Color.paleSage).frame(width: 64, height: 64)
                                    .overlay {
                                        CachedImage(urlString: u.avatarUrl) { img in
                                            img.resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
                                        } placeholder: {
                                            Text(String(name.prefix(1))).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.brand)
                                        }
                                    }
                                    .overlay(Circle().strokeBorder(Color.brand, lineWidth: 2).padding(-3))
                                Text(name.components(separatedBy: " ").first ?? name)
                                    .font(BT.caption1).foregroundStyle(Color.ink).lineLimit(1)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 4)
            }
        }
    }

    private func row(title: String, subtitle: String, items: [APIJourney], all: [APIJourney], showsPlace: Bool = true, map: DestinationMapRoute? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                let header = VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.title3).weight(.bold))
                            .foregroundStyle(Color.brand)
                            .accessibilityAddTraits(.isHeader)
                        if map != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.brand)
                        }
                    }
                    Text(subtitle).font(BT.footnote).foregroundStyle(Color.inkMuted)
                }
                // "En <destino>" abre el mapa de Inicio (Keyla, 19 Nov 2026).
                if let map {
                    NavigationLink(value: map) { header }
                        .buttonStyle(.plain)
                        .accessibilityHint("Abre el mapa de \(map.name)")
                } else {
                    header
                }
                Spacer(minLength: 8)
                // Sin "Ver todos" (Keyla, 19 Nov 2026): el carrusel ya muestra todo.
            }
            .padding(.horizontal, Spacing.edge)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(all) { j in
                            let key = "\(title)|\(j.id)"
                            StoryCarouselCard(journey: j, showsPlace: showsPlace, siblings: all,
                                              onOpen: { zoomKey = key; presented = Presented(row: title, list: all, start: j) },
                                              zoomNamespace: rowsZoom, zoomKey: key)
                                .id(key)
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.vertical, 6)
                }
                // La tarjeta de la publicación que se ve, en pantalla (sin animar: el visor la tapa).
                .onChange(of: zoomKey) { _, key in
                    guard presented != nil, key.hasPrefix("\(title)|") else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(key, anchor: .center) }
                }
            }
        }
    }
}

/// Tarjeta vertical del carrusel: foto, destino, autor. Abre el visor a
/// pantalla completa (el mismo de las historias).
struct StoryCarouselCard: View {
    let journey: APIJourney
    /// En una fila "En <destino>" el destino ya está en el título.
    var showsPlace: Bool = true
    /// La fila entera: el visor sigue con la siguiente publicación al deslizar.
    var siblings: [APIJourney] = []
    /// Con estos, la FILA abre el visor (Comunidad): al cerrar, la foto vuelve a la
    /// tarjeta de la publicación que se está viendo, no solo a la tocada.
    var onOpen: (() -> Void)? = nil
    var zoomNamespace: Namespace.ID? = nil
    var zoomKey: String? = nil
    @State private var showStory = false
    @Namespace private var photoZoom

    private var cover: String? { journey.pageThumbs?.first ?? journey.coverUrl ?? journey.destination?.coverUrl }
    private var place: String { journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Trip" }
    private var author: String { (journey.users?.fullName ?? "Viajero").capitalized }
    private var photos: Int { journey.pageThumbs?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { Haptic.light(); if let onOpen { onOpen() } else { showStory = true } } label: {
                CachedImage(urlString: cover) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.paleSage }
                .frame(width: 200, height: 250)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if showsPlace {
                    HStack(spacing: 5) {
                        LocationPin(size: 13)
                        Text(place).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color.surface, in: Capsule())
                    .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if photos > 1 {
                        Text("\(photos) fotos")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(.top, 12).padding(.trailing, 10)
                    }
                }
            }
            .buttonStyle(.pressable)
            // La transición de zoom va en el botón y no dentro: dentro, el botón
            // perdía su etiqueta para VoiceOver (y las pruebas no lo encontraban).
            .modifier(OptionalZoomSource(id: zoomKey ?? journey.id, namespace: zoomNamespace ?? photoZoom))
            .accessibilityLabel("Trip de \(author) en \(place)")
            // El autor abre su perfil, a pantalla completa.
            if let id = journey.users?.id {
                NavigationLink(value: TravelerProfileRoute(travelerId: id, name: journey.users?.fullName,
                                                           avatarUrl: journey.users?.avatarUrl)) {
                HStack(spacing: 8) {
                    Circle().fill(Color.paleSage).frame(width: 26, height: 26)
                        .overlay {
                            CachedImage(urlString: journey.users?.avatarUrl) { img in
                                img.resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                            } placeholder: {
                                Text(String(author.prefix(1))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brand)
                            }
                        }
                    Text(author).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Abre el perfil")
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color.paleSage).frame(width: 26, height: 26)
                        .overlay {
                            CachedImage(urlString: journey.users?.avatarUrl) { img in
                                img.resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                            } placeholder: {
                                Text(String(author.prefix(1))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brand)
                            }
                        }
                    Text(author).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
                }
                .padding(12)
            }
        }
        .frame(width: 200)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .fullScreenCover(isPresented: $showStory) {
            StoryViewerSheet(journeys: siblings, start: journey, systemDismiss: PhotoZoom.systemAvailable)
                .photoZoomDestination(id: journey.id, in: photoZoom)
        }
    }
}

/// "Ver todos" de una fila: la tarjeta grande de siempre, en lista.
struct StoriesListView: View {
    let route: StoriesListRoute
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                Text(route.title)
                    .font(.system(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, Spacing.edge)
                ForEach(route.journeys) { PublishedTripCard(journey: $0, siblings: route.journeys).equatable() }
            }
            .padding(.bottom, 40)
        }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }
}
// MARK: – Comunidad (pestaña)
//
// Antes "Trips" (Keyla, 19 Nov 2026): la pestaña es para ver lo que viven
// otros viajeros. Los trips propios ("Tu próximo trip", registrar, editar)
// viven ahora en Yo → "Mis trips".

struct MyTripsRoute: Hashable {}

struct CommunityView: View {
    @State private var navPath = NavigationPath()
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("communityTop")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Comunidad")
                                .font(.system(.largeTitle).weight(.bold))
                                .foregroundStyle(Color.brand)
                                .accessibilityAddTraits(.isHeader)
                            Text("Trips de viajeros cerca de ti")
                                .font(BT.footnote)
                                .foregroundStyle(Color.inkMuted)
                        }
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.md)

                        TravelerStoriesSection(reloadToken: reloadToken)
                            .padding(.top, Spacing.lg)

                        Spacer().frame(height: 100)
                    }
                }
                .background(Color.canvas)
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { reloadToken += 1 }
                .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
                    guard note.object as? Int == AppTab.trips.rawValue else { return }
                    if !navPath.isEmpty { navPath = NavigationPath() }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("communityTop", anchor: .top) }
                }
                .navigationDestination(for: DestinationMapRoute.self) { route in
                    PlaceGuideMapSheet(destinationId: route.destinationId, name: route.name)
                }
                .navigationDestination(for: StoriesListRoute.self) { route in
                    StoriesListView(route: route)
                }
                .navigationDestination(for: APIPlaceCard.self) { place in
                    PlaceGuideMapSheet(place: place)
                }
                .navigationDestination(for: TravelerProfileRoute.self) { route in
                    TravelerProfileView(travelerId: route.travelerId,
                                        previewName: route.name, previewAvatarUrl: route.avatarUrl)
                }
            }
        }
    }
}

/// Entrada a "Mis trips" en Yo: mismo estilo de tarjeta que Inicio.
struct MyTripsEntryCard: View {
    var body: some View {
        NavigationLink(value: MyTripsRoute()) {
            HStack(spacing: 12) {
                Image(systemName: "suitcase")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 44, height: 44)
                    .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mis trips")
                        .font(.system(.headline).weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text("Registra tu próximo trip y sigue el que está en curso")
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
