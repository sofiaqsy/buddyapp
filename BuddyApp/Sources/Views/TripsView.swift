import SwiftUI

// MARK: - TripsView (feed)

struct TripsView: View {
    @EnvironmentObject var routeStore: RouteStore
    @State private var journeys: [APIJourney] = []
    @State private var isLoading = true
    @State private var hasLoadedOnce = false
    @State private var navPath = NavigationPath()
    @State private var editTarget: EditTarget? = nil
    /// Override local: el id del trip recién activado con "Ya llegué".
    /// El backend confirma el PATCH pero el GET puede devolver datos stale,
    /// así que forzamos el estado "active" localmente hasta que el server sincronice.
    @State private var locallyActivatedId: String? = nil
    /// Trip recién publicado O cancelado → se excluye del tab para volver al estado
    /// vacío de inmediato, aunque el GET del backend devuelva datos stale.
    @State private var dismissedJourneyId: String? = nil

    struct EditTarget: Identifiable {
        let id = UUID()
        let journey: APIJourney
        let pageIndex: Int
    }

    // El tab es el taller del trip EN CURSO. Los publicados viven en el perfil.
    private var activeJourney: APIJourney? {
        // Override local primero (trip recién activado, aunque el server diga planning)
        if let id = locallyActivatedId, id != dismissedJourneyId,
           let j = journeys.first(where: { $0.id == id }) {
            return j.withStatus("active")
        }
        return journeys.first { $0.status == "active" && $0.id != dismissedJourneyId }
    }
    private var planningJourney: APIJourney? {
        journeys.first { $0.status == "planning" && $0.id != locallyActivatedId && $0.id != dismissedJourneyId }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Header
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
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

                    // Contenido según estado del trip
                    if isLoading && !hasLoadedOnce {
                        SkeletonBox(cornerRadius: 16)
                            .frame(height: 480)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)
                    } else if let journey = activeJourney {
                        // Trip en curso → el taller de portadas
                        TripFeedCard(journey: journey) { pageIndex in
                            editTarget = EditTarget(journey: journey, pageIndex: pageIndex)
                        }
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.md)
                    } else if let journey = planningJourney {
                        // Hub de planificación — mismo aspecto sin importar cuántos días falten
                        PlanningHubCard(journey: journey) {
                            // El PATCH ya confirmó status=active en el server. El GET puede devolver
                            // stale, así que marcamos el id como activado localmente — esto fuerza
                            // el re-render (String? distinto de nil) y muestra el editor de inmediato.
                            locallyActivatedId = journey.id
                        }
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
            .navigationDestination(for: String.self) { route in
                if route == "register" {
                    // Al crear desde Tu trip, volvemos al tab y recargamos → se muestra
                    // el PlanningHubCard del nuevo trip (no el hero "Ya llegué" de Inicio).
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
            if let id = note.object as? String { dismissedJourneyId = id }
            locallyActivatedId = nil
            Task { await loadJourneys() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyCancelled)) { note in
            if let id = note.object as? String { dismissedJourneyId = id }
            locallyActivatedId = nil
            Task { await loadJourneys() }
        }
        .fullScreenCover(item: $editTarget) { target in
            TripEditorSheet(journey: target.journey, initialPage: target.pageIndex) {
                Task { await loadJourneys() }
            }
        }
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
        if !hasLoadedOnce { isLoading = true }
        if let userId = AuthService.shared.userId {
            // Solo actualizamos en ÉXITO. Si la red falla (offline transitorio),
            // conservamos los journeys que ya teníamos → la info no desaparece.
            if let fetched = try? await APIClient.shared.fetchUserJourneys(userId: userId) {
                // Anti cross-account: si la sesión cambió de usuario mientras la
                // request estaba en vuelo (refresh/login), NO pisamos con datos
                // que ya no son de este usuario.
                if AuthService.shared.userId == userId {
                    journeys = fetched
                } else {
                    print("⚠️ [TripsView] userId cambió durante el fetch (\(userId) → \(AuthService.shared.userId ?? "nil")) — descarto resultado")
                }
            }
        }
        isLoading = false
        hasLoadedOnce = true
    }
}

// MARK: - TripFeedCard (Instagram-style)

struct TripFeedCard: View {
    let journey: APIJourney
    let onEdit: (Int) -> Void

    @State private var pages: [CollagePage] = []
    @State private var currentPage = 0
    @State private var tripStatus: String
    @State private var showPublishConfirm = false
    @State private var isPublishing = false
    @State private var deleteTarget: Int? = nil
    @StateObject private var chatStore = ChatStore.shared
    @State private var showContactBuddy = false
    @State private var showCancelConfirm = false
    @State private var isCanceling = false
    @State private var showBlankPublishAlert = false

    /// Hay al menos una portada con contenido real (no en blanco)
    private var hasPublishableContent: Bool {
        pages.contains { !$0.itemSnapshots.isEmpty || $0.backgroundImageFile != nil }
    }

    init(journey: APIJourney, onEdit: @escaping (Int) -> Void) {
        self.journey = journey
        self.onEdit = onEdit
        _tripStatus = State(initialValue: journey.status ?? "planning")
    }

    private var isActive: Bool    { tripStatus == "active" }
    private var isCompleted: Bool { tripStatus == "completed" }
    private var destName: String  { journey.destination?.name ?? journey.title ?? "Trip" }
    private var destCity: String { journey.destination?.city ?? "" }
    /// Altura del preview de portada — relativa a la pantalla para que toda la
    /// tarjeta quepa sin scroll.
    private var previewHeight: CGFloat { min(440, UIScreen.main.bounds.height * 0.47) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // — Trip header —
            HStack(spacing: 10) {
                // Destination avatar / cover
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.tealDeep
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

                if isPublishing {
                    ProgressView().tint(Color.teal).scaleEffect(0.8)
                }

                // Todas las acciones del trip viven bajo los 3 puntitos
                Menu {
                    if isActive && !pages.isEmpty {
                        Button {
                            Haptic.medium()
                            if hasPublishableContent { showPublishConfirm = true }
                            else { showBlankPublishAlert = true }
                        } label: {
                            Label("Publicar", systemImage: "paperplane")
                        }
                    }
                    Button(role: .destructive) {
                        Haptic.medium()
                        showCancelConfirm = true
                    } label: {
                        Label("Cancelar trip", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)

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
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if pages.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(0..<pages.count, id: \.self) { i in
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
                .frame(minHeight: previewHeight, maxHeight: .infinity)
            }

            // — La promesa sigue viva en destino: ayuda a un toque —
            if isActive {
                Divider().padding(.leading, 56).padding(.horizontal, Spacing.md)
                Button { showContactBuddy = true } label: {
                    HStack(spacing: Spacing.sm) {
                        ZStack {
                            Circle().fill(Color.teal.opacity(0.10)).frame(width: 36, height: 36)
                            Image(systemName: "person.wave.2.fill")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.teal)
                        }
                        .overlay(alignment: .topTrailing) {
                            let count = chatStore.travelerUnread
                            if count > 0 {
                                Text("\(min(count, 99))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, count > 9 ? 3 : 0)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                                    .offset(x: 3, y: -3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("¿Una duda en \(destName)?")
                                .font(BT.footnoteBold).foregroundStyle(Color.ink)
                            Text("Tu buddy sigue disponible")
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
        .confirmationDialog("¿Publicar tu trip?", isPresented: $showPublishConfirm, titleVisibility: .visible) {
            Button("Publicar") { publishTrip() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tu trip quedará visible para la comunidad. Después no podrás editarlo.")
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
        .onReceive(NotificationCenter.default.publisher(for: .memoirPageSaved)) { note in
            if let id = note.object as? String, id == journey.id {
                loadPages()
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch tripStatus {
            case "active":    return ("EN CURSO", Color.teal)
            case "completed": return ("COMPLETADO", Color.sand)
            default:          return ("POR LLEGAR", Color.inkMuted)
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

    @ViewBuilder
    private var emptyCanvasCard: some View {
        Button { onEdit(-1) } label: {
            // Crece para llenar todo el espacio disponible
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
                        ZStack {
                            Circle()
                                .strokeBorder(.white.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                .frame(width: 64, height: 64)
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.white)
                        }
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
        }
        .buttonStyle(.plain)
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
        guard hasPublishableContent else { showBlankPublishAlert = true; return }
        // Solo se publican las portadas con contenido real; las vacías se descartan
        let currentPages = pages.filter { !$0.itemSnapshots.isEmpty || $0.backgroundImageFile != nil }
        isPublishing = true
        let jId = journey.id
        Task {
            try? await APIClient.shared.publishJourney(journeyId: jId, pages: currentPages)
            await MainActor.run {
                tripStatus = "completed"
                isPublishing = false
                Haptic.success()
                // El tab vuelve de inmediato al estado "crea tu próximo trip"
                NotificationCenter.default.post(name: .journeyPublished, object: jId)
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
                    // scaledToFit: la portada JAMÁS se recorta — lo que se guardó
                    // en el editor es exactamente lo que se ve
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
                    bookVM.addPage()          // crea página nueva y entra al editor
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
                    .foregroundStyle(Color.red.opacity(0.85))
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
