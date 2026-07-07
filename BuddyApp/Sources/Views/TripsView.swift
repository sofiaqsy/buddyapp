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
    // Acciones a nivel de tab (operan sobre el trip seleccionado / una locación)
    @State private var showCancelTripConfirm = false
    @State private var deleteTarget: APIJourney? = nil
    @State private var activeMatch: APIMatch? = nil
    @State private var showPublishConfirmFromParent = false   // disparado tras auth

    struct EditTarget: Identifiable {
        let id = UUID()
        let journey: APIJourney
        let pageIndex: Int
    }

    // El tab es el taller del trip EN CURSO. Los publicados viven en el perfil.
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
    private var visibleTrips: [APIJourney] {
        let rank: (String) -> Int = { s in s == "active" ? 0 : 1 }
        return journeys
            .filter {
                !dismissedJourneyIds.contains($0.id)
                && $0.tripId != dismissedTripId
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

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Header — título + acciones del trip seleccionado
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TU BITÁCORA")
                                .font(BT.eyebrow)
                                .tracking(2)
                                .foregroundStyle(Color.inkMuted)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Tu")
                                    .font(BT.title1)
                                    .foregroundStyle(Color.ink)
                                Text("trip.")
                                    .font(BT.displayLarge)
                                    .foregroundStyle(Color.sand)
                            }
                        }
                        Spacer()
                        if let trip = selectedTrip {
                            tripActionsMenu(for: trip)
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

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
                        tripCard(for: journey)
                            .id("\(journey.id)-\(journey.status ?? "")")
                            .transition(.opacity)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)
                    } else {
                        emptyState
                    }

                    Spacer().frame(height: 100)
                }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    (Text("BU").foregroundColor(Color.ink)
                     + Text("DDY").foregroundColor(Color.sand))
                        .font(BT.eyebrow)
                        .tracking(4)
                }
            }
            .task { await loadJourneys() }
            .refreshable { await loadJourneys() }
            // Al volver del flujo de registro (pop a raíz), un refresh dirigido
            .onChange(of: navPath.count) { old, new in
                if new == 0 && old > 0 { Task { await loadJourneys() } }
            }
            .onChange(of: authState.isLoggedIn) { _, loggedIn in
                if !loggedIn {
                    journeys            = []
                    hasLoadedOnce       = false
                    dismissedJourneyIds = []
                    dismissedTripId     = nil
                    selectedTripId      = nil
                    navPath             = NavigationPath()
                } else {
                    Task { await loadJourneys() }
                }
            }
            .navigationDestination(for: APIJourney.self) { journey in
                TripDetailGate(journey: journey)
                    .environmentObject(routeStore)
            }
            .navigationDestination(for: String.self) { route in
                if route == "register" {
                    RegisterTripView { _ in
                        navPath = NavigationPath()
                        Task { await loadJourneys() }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyActivated)) { _ in
            navPath = NavigationPath()
            // El trip pasó de "por llegar" a "en curso" — un solo refresh dirigido
            Task { await loadJourneys() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { note in
            // Publicar saca el trip del tab (pasa a completado → vive en el perfil).
            // Se excluye de inmediato aunque el GET del backend devuelva stale.
            if let id = note.object as? String {
                dismissedJourneyIds.insert(id)
                if selectedTripId == id { selectedTripId = nil }
            }
            locallyActivatedId = nil
            Task { await loadJourneys() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyCancelled)) { note in
            // Cancelar/eliminar SÍ borra del backend → se excluye de inmediato.
            if let id = note.object as? String { dismissedJourneyIds.insert(id) }
            locallyActivatedId = nil
            Task { await loadJourneys() }
        }
        .fullScreenCover(item: $editTarget) { target in
            TripEditorSheet(journey: target.journey, initialPage: target.pageIndex) {
                Task { await loadJourneys() }
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
                onMapTap: { navPath.append(journey) },
                buddyAvatarUrl: (journey.status ?? "") == "active" ? activeMatch?.buddy?.avatarUrl : nil,
                buddyFirstName: (journey.status ?? "") == "active"
                    ? activeMatch?.buddy?.fullName?.components(separatedBy: " ").first?.capitalized
                    : nil,
                externalPublishTrigger: $showPublishConfirmFromParent,
                onPublishTap: authState.isLoggedIn ? nil : {
                    pendingPublishJourneyId = journey.id
                    showIdentitySheet = true
                }
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

    // MARK: – Estado anónimo del tab Tu trip

    @ViewBuilder
    private var anonymousTripState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "map")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("Tu bitácora de viajes")
                .font(BT.title3)
                .foregroundStyle(Color.ink)
            Text("Registra un destino, agrega momentos\ny comparte tu historia.")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)

            Button {
                Haptic.medium()
                navPath.append("register")
            } label: {
                Label("Empezar", systemImage: "plus")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 13)
                    .background(Color.ink)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "map")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("Tu próximo trip te espera")
                .font(BT.title3)
                .foregroundStyle(Color.ink)
            Text("Registra tu próximo destino\ny conecta con un buddy.")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)

            Button { Haptic.medium(); navPath.append("register") } label: {
                Label("Registrar trip", systemImage: "plus")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 13)
                    .background(Color.ink)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func loadJourneys() async {
        guard Session.hasSession else { isLoading = false; return }
        if !hasLoadedOnce { isLoading = true }
        let snapshotId = Session.travelerId
        // Solo actualizamos en ÉXITO. Si la red falla (offline transitorio),
        // conservamos los journeys que ya teníamos → la info no desaparece.
        if let fetched = try? await APIClient.shared.fetchTravelerJourneys() {
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
                print("🧳 [TripsView.load] journeys=\(fetched.map { "\($0.destination?.name ?? $0.place?.name ?? "·"):\($0.status ?? "nil"):trip=\(($0.tripId ?? "nil").prefix(6))" })")
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
            print("🧳 [TripsView] selectedTrip id=\(t.id.prefix(8)) dest=\(t.destination?.name ?? "nil") place=\(t.place?.name ?? "nil") title=\(t.title ?? "nil")")
        }
        // Cargar match activo para mostrar avatar del buddy
        let hasActive = journeys.contains { $0.status == "active" }
        if hasActive, let matches = try? await APIClient.shared.fetchMatches() {
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
        pages.contains { !$0.itemSnapshots.isEmpty || $0.backgroundImageFile != nil }
    }

    init(journey: APIJourney, onEdit: @escaping (Int) -> Void, onMapTap: (() -> Void)? = nil, buddyAvatarUrl: String? = nil, buddyFirstName: String? = nil, externalPublishTrigger: Binding<Bool>? = nil, onPublishTap: (() -> Void)? = nil) {
        self.journey = journey
        self.onEdit = onEdit
        self.onMapTap = onMapTap
        self.buddyAvatarUrl = buddyAvatarUrl
        self.buddyFirstName = buddyFirstName
        self.externalPublishTrigger = externalPublishTrigger
        self.onPublishTap = onPublishTap
        _tripStatus = State(initialValue: journey.status ?? "planning")
    }

    private var isActive: Bool    { tripStatus == "active" }
    private var isCompleted: Bool { tripStatus == "completed" }
    /// Total de slides incluyendo la de "agregar momento" (si es editable).
    private var dotCount: Int { pages.count + (isCompleted ? 0 : 1) }
    private var destName: String  { journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Trip" }
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
            if isActive && hasBuddies {
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
        print("🧳 [TripFeedCard] buddyContext id=\(id.prefix(8)) total=\(ctx.totalBuddies) status=\(ctx.status)")
        await MainActor.run { hasBuddies = ctx.totalBuddies > 0 }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch tripStatus {
            case "active":
                let days = journey.arrivalAt.map {
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
        print("📤 [publishTrip] journeyId=\(jId) pages.count=\(pages.count)")
        guard hasPublishableContent else {
            print("📤 [publishTrip] BLOQUEADO: hasPublishableContent=false — no hay páginas con items ni bgFile")
            showBlankPublishAlert = true
            return
        }
        // Solo se publican las portadas con contenido real; las vacías se descartan
        let currentPages: [CollagePage]
        do {
            print("📤 [publishTrip] BEFORE filter: \(pages.count) page(s)")
            for (i, p) in pages.enumerated() {
                let kept = !p.itemSnapshots.isEmpty || p.backgroundImageFile != nil
                print("📤 [publishTrip]   page[\(i)] id=\(p.id) items=\(p.itemSnapshots.count) bgFile=\(p.backgroundImageFile ?? "nil") thumb=\(p.thumbnailFileName ?? "nil") → \(kept ? "KEPT" : "DISCARDED")")
            }
            currentPages = pages.filter { !$0.itemSnapshots.isEmpty || $0.backgroundImageFile != nil }
            print("📤 [publishTrip] AFTER filter: \(currentPages.count) page(s)")
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
        !page.itemSnapshots.isEmpty || page.backgroundImageFile != nil
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
    let onDismiss: () -> Void

    @StateObject private var bookVM: TripBookViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var didStart = false

    init(journey: APIJourney, initialPage: Int, onDismiss: @escaping () -> Void) {
        self.journey = journey
        self.initialPage = initialPage
        self.onDismiss = onDismiss
        _bookVM = StateObject(wrappedValue: TripBookViewModel(journeyId: journey.id))
    }

    var body: some View {
        TripCanvasEditorView(vm: bookVM.editingVM, bookVM: bookVM)
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
                        && bookVM.pages[0].itemSnapshots.isEmpty
                        && bookVM.pages[0].backgroundImageFile == nil
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

            Text("Lo que dejes pendiente, un buddy puede ayudarte cuando llegues.")
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)

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
