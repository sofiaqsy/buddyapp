import SwiftUI
import MapKit
import PhotosUI

struct TripDetailView: View {
    let route: Route
    var match: APIMatch? = nil
    var journey: APIJourney? = nil
    var unreadCount: Int = 0
    /// Respaldo para el conteo de buddies cuando no hay un journey propio de
    /// por medio — al browsear un lugar de la comunidad desde el Home, no
    /// existe "tu trip" a este destino, pero igual queremos mostrar quién
    /// puede ayudar ahí.
    var destinationId: String? = nil
    /// Lugar a preseleccionar al entrar — el mismo spot que se tocó en la
    /// tarjeta que abrió este mapa. Sin esto, se entra al mapa completo del
    /// destino sin foco, y hay que buscar el pin entre todos los demás.
    var focusPlaceId: String? = nil
    /// Abierto desde una categoría de Inicio ("Productos locales"): el mapa y
    /// el carril muestran solo esos lugares. El usuario puede quitar el filtro.
    var categoryFilter: String? = nil
    @State private var filterCleared = false
    private var activeFilter: String? { filterCleared ? nil : categoryFilter }
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) var dismiss

    @State private var camera: MapCameraPosition
    @State private var selectedPlace: Place? = nil
    /// Lugar para el que se muestra el diálogo "Cómo llegar" (Google Maps / Waze / Apple Maps)
    @State private var navigationTarget: Place? = nil
    @State private var showChat = false
    @State private var showContactar = false
    @State private var showQRScanner = false
    @State private var showCancelConfirm = false
    @State private var shareItem: URL? = nil
    @State private var tripStatus: String = "active"
    @State private var buddyCount: Int? = nil
    @State private var resolvedDestinationId: String? = nil
    /// Carga progresiva: mostramos lotes de 10 (rail + mapa). Al deslizar el rail
    /// hasta el final se revelan los siguientes 10 y aparecen como markers.
    @State private var visibleCount = 10
    @State private var orderedIds: [UUID] = []   // orden congelado de la sesión
    /// Lugares que caen en la parte VISIBLE del mapa, de cualquier destino.
    /// Se rellena al terminar de mover o hacer zoom (estilo Airbnb).
    @State private var boundsPlaces: [Place] = []
    @State private var boundsTask: Task<Void, Never>? = nil
    /// Rectángulo ya pedido (con margen) y si vino recortado. Hacer zoom dentro
    /// de un área ya cargada no necesita red: los lugares ya están en memoria.
    @State private var fetchedBounds: SpotBounds? = nil

    init(route: Route, match: APIMatch? = nil, journey: APIJourney? = nil, unreadCount: Int = 0, destinationId: String? = nil, focusPlaceId: String? = nil, categoryFilter: String? = nil) {
        self.categoryFilter = categoryFilter
        self.route = route
        self.match = match
        self.journey = journey
        self.unreadCount = unreadCount
        self.destinationId = destinationId
        self.focusPlaceId = focusPlaceId
        // Si el destino no tiene spots curados, centrar el mapa en las coords explícitas
        // desde el inicio — sin esperar el delay de fitMap().
        if route.places.isEmpty, let center = route.explicitCenter {
            dlog("🗺️ [TripDetailView.init] places=0 explicitCenter=(\(center.latitude),\(center.longitude)) → camera centrada en destino")
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )))
        } else {
            dlog("🗺️ [TripDetailView.init] places=\(route.places.count) centerLat=\(route.centerLat.map{String($0)} ?? "nil") → camera=.automatic")
            _camera = State(initialValue: .automatic)
        }
    }

    private let pageSize = 10
    private var isPlanning: Bool { tripStatus == "planning" }

    /// Presencia humana en el mapa — lo único que Google Maps no puede mostrar.
    private var buddyPresenceText: String? {
        guard let c = buddyCount else { return nil }
        if c <= 0 { return "Un buddy puede ayudarte si tienes una duda" }
        return c == 1
            ? "1 buddy aquí, listo si tienes una duda"
            : "\(c) buddies aquí, listos si tienes una duda"
    }

    /// Always read live places from routeStore so isCollected updates reflect instantly
    /// Los del destino + los que están en pantalla y no son del destino.
    ///
    /// Antes solo los del destino: los spots cuelgan de UN destino, así que el
    /// mapa de Breña salía vacío aunque Cafetería Rosal y El encanto están ahí
    /// (pertenecen a "Lima"). Los del destino van primero porque traen
    /// favoritos y stickers; los de pantalla completan.
    private var livePlaces: [Place] {
        let propios = routeStore.route.places
        let ids = Set(propios.map(\.id))
        let todos = propios + boundsPlaces.filter { !ids.contains($0.id) }
        guard let filtro = activeFilter else { return todos }
        return todos.filter { $0.categoryName == filtro }
    }
    /// Orden: favoritos primero, luego featured, luego alfabético
    private var sortedPlaces: [Place] {
        livePlaces.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.featured   != b.featured   { return a.featured }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Orden CONGELADO mientras la pantalla está abierta: marcar favorito no
    /// reordena en vivo (evita la sensación de que el lugar "desaparece").
    /// El orden favoritos-primero se recalcula al abrir / cambiar de destino.
    private var orderedPlaces: [Place] {
        guard !orderedIds.isEmpty else { return sortedPlaces }
        let byId = Dictionary(uniqueKeysWithValues: livePlaces.map { ($0.id, $0) })
        let known = orderedIds.compactMap { byId[$0] }
        let extras = livePlaces.filter { !orderedIds.contains($0.id) }   // recién llegados
        return known + extras
    }
    private func refreshOrder() { orderedIds = sortedPlaces.map(\.id) }

    private func loadRouteContext() async {
        // PRIMERO (Keyla, 23 Nov 2026: tardaba 1-2 s): antes esperaba favoritos y
        // el conteo de buddies de la red antes de mostrar el lugar.
        // Foco explícito (se abrió este mapa desde la tarjeta de UN lugar):
        // seleccionarlo y centrar ahí en vez de esperar el fitMap() genérico,
        // que encuadraría TODOS los pines del destino.
        if let focusPlaceId, let match = livePlaces.first(where: { $0.id.uuidString.caseInsensitiveCompare(focusPlaceId) == .orderedSame }) {
            await MainActor.run {
                withAnimation(.easeInOut) { selectedPlace = match }
                focusCamera(on: match)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fitMap() }
        }

        if let jid = journey?.id { await routeStore.loadFavorites(journeyId: jid) }
        await MainActor.run { refreshOrder() }

        // /destinations/:id/context filtra por destination_ids — mismo criterio que Home.
        // Solo cuenta buddies que explícitamente atienden este destino.
        let destId = journey?.destinationId ?? journey?.destination?.id ?? destinationId
        if let destId {
            resolvedDestinationId = destId   // la pestaña "Buddies" del detalle lo necesita
            if let ctx = try? await APIClient.shared.fetchDestinationContext(id: destId) {
                await MainActor.run { buddyCount = ctx.buddies }
            }
        }

        // Deep-link desde chat: seleccionar lugar sugerido por el buddy
        if let dp = PlaceDeepLink.shared.consume() {
            await MainActor.run {
                let match = livePlaces.first { $0.name.localizedCaseInsensitiveCompare(dp.name) == .orderedSame }
                    ?? livePlaces.min(by: {
                        abs($0.latitude - dp.lat) + abs($0.longitude - dp.lng) <
                        abs($1.latitude - dp.lat) + abs($1.longitude - dp.lng)
                    })
                withAnimation(.easeInOut) { selectedPlace = match }
                let coord = match.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                } ?? CLLocationCoordinate2D(latitude: dp.lat, longitude: dp.lng)
                withAnimation(.easeInOut(duration: 0.6)) {
                    camera = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    ))
                }
            }
        }

        guard let userId = Session.travelerId else { return }
        if let userStickers = try? await APIClient.shared.fetchUserStickers(travelerId: userId) {
            await routeStore.syncCollectedStickers(userStickers: userStickers)
        }
    }

    /// Lo que está cargado/visible ahora (ventana de paginación cliente)
    private var displayedPlaces: [Place] { Array(orderedPlaces.prefix(visibleCount)) }
    private var hasMorePlaces: Bool { visibleCount < livePlaces.count }

    /// Estado de favorito en vivo (selectedPlace es una copia que puede quedar stale)
    private func isFav(_ place: Place) -> Bool {
        routeStore.route.places.first(where: { $0.id == place.id })?.isFavorite ?? place.isFavorite
    }

    private func loadMore() {
        guard hasMorePlaces else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            visibleCount = min(visibleCount + pageSize, livePlaces.count)
        }
    }

    /// Alto del panel con la lista: título + carril de tarjetas, sin franja
    /// vacía debajo (antes 265 dejaba un hueco blanco al cerrar un lugar).
    private let sheetHeight: CGFloat = 238
    /// Alto del panel con el detalle de un lugar. Menos que sheetHeight porque
    /// ahí no hay tarjetas: nombre, presencia, pestañas y una fila de fotos.
    /// Es el alto de ese contenido, medido en pantalla; las pestañas más largas
    /// (Info, Buddies) se desplazan por dentro, como ya hacían.
    private let detalleHeight: CGFloat = PlaceGuideDetailSheet.minHeight
    private let contentHeight: CGFloat = 188
    /// La tab bar vuelve a FLOTAR sobre el contenido (cápsula, 19 Nov 2026):
    /// el panel se extiende por debajo de ella para que las fotos queden por
    /// encima de la cápsula y no tapadas.
    private let bottomClearance: CGFloat = 76
    /// Ya se mostró el lugar con el que se abrió el mapa (focusPlaceId). Al
    /// cerrarlo, el panel pasa al alto de la lista; sin esto se quedaba con el
    /// alto del detalle y dejaba una franja blanca bajo las tarjetas.
    @State private var focusHandled = false

    /// Alto actual del panel (lista o detalle). Lo usan el panel y el botón de
    /// "mi ubicación", que debe quedar siempre por encima del panel.
    private var panelHeight: CGFloat {
        if panelMinimized && !detailExpanded && !listExpanded { return Self.peekHeight + bottomClearance }
        if detailExpanded && selectedPlace != nil { return expandedHeight }
        if listExpanded && selectedPlace == nil { return expandedHeight }
        return (selectedPlace != nil || (focusPlaceId != nil && !focusHandled)
            ? detalleHeight : sheetHeight) + bottomClearance
    }

    /// Detalle de un lugar a pantalla casi completa (Keyla, 20 Nov 2026): se
    /// jala hacia arriba y tapa el mapa; hacia abajo vuelve al alto normal.
    @State private var detailExpanded = false
    /// Tercer alto, abajo del todo: solo el título, para ver el mapa entero
    /// (Keyla, 24 Nov 2026). Deslizar hacia abajo desde el alto normal.
    @State private var panelMinimized = false
    static let peekHeight: CGFloat = 56
    /// La lista "Lugares en esta zona" también se abre a pantalla completa
    /// (Keyla, 23 Nov 2026), igual que el detalle con sus productos.
    @State private var listExpanded = false
    @State private var listDraggedAt: Date? = nil
    @State private var listTopY: CGFloat = 0
    @State private var listDragAtTop: Bool? = nil
    @State private var listVerticalDrag = false
    private var listJustDragged: Bool { listDraggedAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false }
    @State private var dragOffset: CGFloat = 0
    private var expandedHeight: CGFloat {
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
        // El panel termina por debajo del borde inferior (pasa bajo la tab
        // bar), así que se resta algo más para que la barrita quede bajo la isla.
        return UIScreen.main.bounds.height - max(top, 54) - 36
    }

    /// Barrita para jalar: arriba abre todo, abajo vuelve. Tocarla alterna.
    private var grabber: some View {
        Capsule().fill(Color.border).frame(width: 40, height: 5)
            .frame(maxWidth: .infinity).frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Self.panelSpring) {
                if panelMinimized { panelMinimized = false; return }
                if selectedPlace == nil { listExpanded.toggle() } else { detailExpanded.toggle() }
            } }
            .highPriorityGesture(panelDrag)
            .accessibilityLabel(detailExpanded ? "Mostrar el mapa" : "Ver todo el lugar")
            .accessibilityAddTraits(.isButton)
    }

    /// Resorte del panel (Keyla, 23 Nov 2026: "más suave"). Mismo en toda la app.
    static let panelSpring = Animation.spring(response: 0.26, dampingFraction: 0.92)

    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in dragOffset = v.translation.height }
            .onEnded { v in endPanelDrag(v.predictedEndTranslation.height) }
    }

    private func endPanelDrag(_ predicted: CGFloat) {
        // Más sensible: basta un deslizar corto hacia arriba o abajo.
        withAnimation(Self.panelSpring) {
            let expanded = selectedPlace == nil ? listExpanded : detailExpanded
            if predicted < -30 {
                // Arriba: de mínimo a normal, de normal a completo.
                if panelMinimized { panelMinimized = false }
                else if selectedPlace == nil { listExpanded = true } else { detailExpanded = true }
            } else if predicted > 30 {
                // Abajo: de completo a normal, de normal a mínimo.
                if expanded {
                    if selectedPlace == nil { listExpanded = false } else { detailExpanded = false }
                } else { panelMinimized = true }
            }
            dragOffset = 0
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                mapView
                    .ignoresSafeArea()

                backAndShareBar
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                bottomSection(geo: geo)
                    // Deslizar a la derecha sobre el panel de información vuelve
                    // atrás, como en el resto de la app (Keyla, 21 Nov 2026). Con
                    // .gesture (no simultáneo) las filas de fotos que se desplazan
                    // de lado siguen moviéndose sin volver.
                    .gesture(
                        DragGesture(minimumDistance: 25)
                            .onEnded { v in
                                let w = v.translation.width, h = v.translation.height
                                if w > 90, w > abs(h) * 2 || v.predictedEndTranslation.width > 220 && w > abs(h) * 2 {
                                    Haptic.light(); dismiss()
                                }
                            }
                    )
            }
            .ignoresSafeArea(edges: .top)
        }
        // Oculta la barra pero CONSERVA el swipe-back desde el borde (a diferencia
        // de navigationBarHidden, que lo desactiva).
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            tripStatus = journey?.status ?? "active"
            Task { await loadRouteContext() }
        }
        .onChange(of: routeStore.route.id) { _, _ in
            // Nuevo destino cargado por RouteStore: resetear todo el estado dependiente
            // y recargar en lugar de depender de onAppear que no re-dispara en reuso de vista.
            visibleCount = 10
            buddyCount = nil
            refreshOrder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fitMap() }
            Task { await loadRouteContext() }
        }
        .sheet(isPresented: $showChat) {
            if let match, let journey {
                BuddyChatView(match: match, journey: journey).equatable()
            }
        }
        .sheet(isPresented: $showContactar) {
            if let journey {
                ContactarBuddyView(journey: journey)
            }
        }
        .fullScreenCover(isPresented: $showQRScanner) {
            QRScannerView(
                onDismiss: { showQRScanner = false },
                onUnlocked: { stickerId in routeStore.markStickerCollected(stickerId: stickerId) }
            )
        }
    }

    // MARK: – Map

    private var mapView: some View {
        Map(position: $camera) {
            // Spots curados por la comunidad; featured al final → se dibujan encima
            // TODOS los lugares en el mapa, no solo el lote del rail: el rail pagina
            // de 10 en 10, pero un pin que existe y no se dibuja es justo el
            // "no veo ningún spot" que se quería arreglar.
            ForEach(orderedPlaces.sorted { !$0.featured && $1.featured }) { place in
                Annotation("", coordinate: place.coordinate) {
                    RecommendationPin(place: place, isSelected: selectedPlace?.id == place.id)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            Haptic.select()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedPlace = selectedPlace?.id == place.id ? nil : place
                            }
                        })
                        .accessibilityLabel(place.featured ? "\(place.name), recomendado" : place.name)
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(.hidden)
            }
            // Punto azul de "tu ubicación": el tinte verde del mapa lo volvía un
            // círculo oscuro que parecía un pin (Keyla, 24 Nov 2026).
            UserAnnotation {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.18)).frame(width: 44, height: 44)
                    Circle().fill(.white).frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    Circle().fill(Color(red: 0.0, green: 0.48, blue: 1.0)).frame(width: 16, height: 16)
                }
                .accessibilityLabel("Tu ubicación")
            }
        }
        // Mapa de contexto: sin comercios, pero con carreteras / ríos / nombres de ciudad.
        // .excludingAll elimina demasiadas referencias visuales y desorienta al usuario.
        .mapStyle(.standard(
            elevation: .flat,
            pointsOfInterest: .excluding([
                .restaurant, .cafe, .bakery, .brewery, .winery,
                .hotel, .store, .gasStation, .bank, .atm, .parking,
                .carRental, .laundry, .fitnessCenter, .nightlife,
                .movieTheater, .theater, .pharmacy
            ]),
            showsTraffic: false
        ))
        .mapControls { EmptyView() }
        // Al TERMINAR de mover o hacer zoom (no en cada frame): pedir lo que hay
        // en pantalla.
        .onMapCameraChange(frequency: .onEnd) { context in
            loadSpotsInBounds(region: context.region)
        }
        .onTapGesture {
            if selectedPlace != nil {
                withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = nil }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                MapIconButton(icon: "location.fill") { centerOnUser() }
                    .glassRounded(14)
                    .mapControlShadow()

                // buddyActive solo true cuando hay confirmación explícita (buddyCount > 0, match activo o mensajes sin leer).
                // Mientras buddyCount es nil (cargando) → deshabilitado por defecto para evitar tap prematuro.
                let buddyActive = (buddyCount ?? 0) > 0 || match != nil || unreadCount > 0
                // Villa Rica V1: solo "mi ubicación". Buddy y QR quedan en el
                // código, ocultos, hasta que vuelvan a tener sentido.
                if HomeRowsView.showsBuddyTools {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        MapIconButton(icon: "person.wave.2.fill") {
                            if match != nil { showChat = true }
                            else if journey != nil { showContactar = true }
                        }
                        .disabled(!buddyActive)
                        .opacity(buddyActive ? 1 : 0.38)
                        .grayscale(buddyActive ? 0 : 1)
                        .accessibilityHidden(!buddyActive)
                        if unreadCount > 0 {
                            Text("\(min(unreadCount, 99))")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, unreadCount > 9 ? 4 : 0)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Color.errorRed)
                                .clipShape(Capsule())
                                .offset(x: 5, y: -5)
                        }
                    }
                    if !isPlanning {
                        Divider().padding(.horizontal, 8).opacity(0.2)
                        MapIconButton(icon: "qrcode") { showQRScanner = true }
                    }
                }
                .frame(width: 44)
                .glassRounded(14)
                .mapControlShadow()
                }
            }
            .frame(width: 44)
            .padding(.trailing, 16)
            .padding(.bottom, panelHeight + 52)
            // Con el detalle abierto a pantalla completa no hay mapa que ubicar.
            .opacity(panelHeight == expandedHeight ? 0 : 1)
            .animation(Self.panelSpring, value: panelHeight)
        }
    }

    // MARK: – Header

    private var backAndShareBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassCircleButtonStyle())

            Spacer()

            Menu {
                Button {
                    let destName = journey?.destination?.name ?? route.title
                    let text = "Estoy explorando \(destName) con Buddy 🗺️"
                    shareItem = URL(string: "https://buddy.app")
                    let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        root.present(av, animated: true)
                    }
                } label: {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }

                // Solo tiene sentido cancelar TU trip — al browsear un lugar de
                // la comunidad (sin journey propio) no hay nada que cancelar.
                if journey != nil {
                    Divider()

                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        Label("Cancelar trip", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassCircleButtonStyle())
        }
        .padding(.horizontal, 16)
        .confirmationDialog(
            "¿Cancelar tu trip a \(journey?.destination?.name ?? route.title)?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancelar trip", role: .destructive) {
                Task {
                    if let id = journey?.id {
                        try? await APIClient.shared.cancelJourney(journeyId: id)
                    }
                    await MainActor.run {
                        routeStore.reset()
                        NotificationCenter.default.post(name: .journeyCancelled, object: journey?.id)
                        dismiss()
                    }
                }
            }
            Button("No cancelar", role: .cancel) {}
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
        // Cómo llegar — universal links: abren la app nativa si está instalada,
        // o el navegador si no. Sin necesidad de LSApplicationQueriesSchemes.
        .confirmationDialog(
            "Cómo llegar a \(navigationTarget?.name ?? "")",
            isPresented: Binding(
                get: { navigationTarget != nil },
                set: { if !$0 { navigationTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            // La ficha del lugar (no una ruta): solo si el spot está vinculado a
            // un Google Place ID. Sin vínculo la opción no aparece.
            if GoogleMapsLink.openableURL(navigationTarget?.googleMapsUrl) != nil {
                Button("Ver ficha en Google Maps") { openGoogleMapsListing() }
            }
            Button("Google Maps") { openInGoogleMaps() }
            Button("Waze") { openInWaze() }
            Button("Apple Maps") { openInAppleMaps() }
            Button("Cancelar", role: .cancel) { navigationTarget = nil }
        }
    }

    // MARK: – Navegación externa (Google Maps / Waze / Apple Maps)

    private func openInGoogleMaps() {
        guard let p = navigationTarget else {
            dlog("🧭 [ComoLlegar] googleMaps — navigationTarget=nil, no se abre nada")
            return
        }
        let url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(p.latitude),\(p.longitude)&travelmode=driving")!
        dlog("🧭 [ComoLlegar] googleMaps → place=\(p.name) lat=\(p.latitude) lng=\(p.longitude)")
        dlog("🧭 [ComoLlegar] googleMaps URL: \(url.absoluteString)")
        UIApplication.shared.open(url) { ok in
            print(ok ? "🧭 [ComoLlegar] googleMaps ✅ abierto" : "🧭 [ComoLlegar] googleMaps ❌ open falló")
        }
    }

    private func openGoogleMapsListing() {
        guard let p = navigationTarget else {
            dlog("🧭 [ComoLlegar] fichaGoogle — navigationTarget=nil, no se abre nada")
            return
        }
        guard let url = GoogleMapsLink.openableURL(p.googleMapsUrl) else {
            dlog("🧭 [ComoLlegar] fichaGoogle — \(p.name) sin ficha vinculada (o URL no válida), no se abre nada")
            return
        }
        dlog("🧭 [ComoLlegar] fichaGoogle → place=\(p.name) URL: \(url.absoluteString)")
        UIApplication.shared.open(url) { ok in
            print(ok ? "🧭 [ComoLlegar] fichaGoogle ✅ abierto" : "🧭 [ComoLlegar] fichaGoogle ❌ open falló")
        }
    }

    private func openInWaze() {
        guard let p = navigationTarget else {
            dlog("🧭 [ComoLlegar] waze — navigationTarget=nil, no se abre nada")
            return
        }
        let url = URL(string: "https://waze.com/ul?ll=\(p.latitude),\(p.longitude)&navigate=yes")!
        dlog("🧭 [ComoLlegar] waze → place=\(p.name) lat=\(p.latitude) lng=\(p.longitude)")
        dlog("🧭 [ComoLlegar] waze URL: \(url.absoluteString)")
        UIApplication.shared.open(url) { ok in
            print(ok ? "🧭 [ComoLlegar] waze ✅ abierto" : "🧭 [ComoLlegar] waze ❌ open falló")
        }
    }

    private func openInAppleMaps() {
        guard let p = navigationTarget else {
            dlog("🧭 [ComoLlegar] appleMaps — navigationTarget=nil, no se abre nada")
            return
        }
        let name = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? p.name
        let url = URL(string: "https://maps.apple.com/?daddr=\(p.latitude),\(p.longitude)&q=\(name)")!
        dlog("🧭 [ComoLlegar] appleMaps → place=\(p.name) lat=\(p.latitude) lng=\(p.longitude)")
        dlog("🧭 [ComoLlegar] appleMaps URL: \(url.absoluteString)")
        UIApplication.shared.open(url) { ok in
            print(ok ? "🧭 [ComoLlegar] appleMaps ✅ abierto" : "🧭 [ComoLlegar] appleMaps ❌ open falló")
        }
    }

    // MARK: – Bottom panel

    @ViewBuilder
    private func bottomSection(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if let place = selectedPlace {
                grabber
                    .padding(.bottom, -14)
                // Mismo panel, contenido reemplazado — nada se levanta encima
                // del mapa. Antes esto abría un .sheet modal; se sentía como
                // una interrupción en vez de una respuesta a tocar el lugar.
                PlaceGuideDetailSheet(
                    place: place,
                    destinationId: resolvedDestinationId,
                    buddyPresenceText: buddyPresenceText,
                    isFavorite: isFav(place),
                    onToggleFavorite: {
                        if let jid = journey?.id { routeStore.toggleFavorite(placeId: place.id, journeyId: jid) }
                    },
                    onNavigate: { navigationTarget = place },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = nil; detailExpanded = false } },
                    expanded: detailExpanded,
                    // Sin X (Keyla, 23 Nov 2026): la pantalla ya tiene su botón de
                    // volver arriba; un solo cierre. Tocar el pin de nuevo lo suelta.
                    showsClose: false,
                    onPanelDrag: { dragOffset = $0 },
                    onPanelDragEnd: { endPanelDrag($0) }
                )
            } else {
            grabber
                .padding(.bottom, -14)
            VStack(spacing: 0) {
            // Presencia humana — el corazón de Buddy, antes que los lugares
            if HomeRowsView.showsBuddyTools, let presence = buddyPresenceText {
                HStack(spacing: 7) {
                    Circle().fill(Color.onlineGreen).frame(width: 7, height: 7)
                    Text(presence)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            if livePlaces.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // — Título + descripción
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Sin explorar aún")
                            .font(BT.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Nadie ha agregado recomendaciones aquí todavía. La guía de este lugar la construye su comunidad.")
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    // — Separador
                    Divider()
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                    // — Fila accionable estilo Apple Maps (herramienta de buddies)
                    if HomeRowsView.showsBuddyTools {
                    Button {
                        router.switchTo(.yo)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.teal.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.teal)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ser el primer buddy aquí")
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(.primary)
                                Text("Ayuda a viajeros y construye esta guía")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.inkMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.inkMuted.opacity(0.6))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                }
            } else {
                // Mismo encabezado que las secciones de Inicio.
                HStack(alignment: .center, spacing: 12) {
                    if let filtro = activeFilter {
                        Image(systemName: CategoryIcon.symbol(for: filtro))
                            .font(.system(size: 17))
                            .foregroundStyle(Color.brand)
                            .frame(width: 38, height: 38)
                            .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeFilter ?? "Lugares en esta zona")
                            .font(.system(.title3).weight(.bold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        Text(activeFilter == nil
                             ? "Toca uno para ver fotos e información"
                             : (livePlaces.count == 1 ? "1 lugar en el mapa" : "\(livePlaces.count) lugares en el mapa"))
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer(minLength: 8)
                    if activeFilter != nil {
                        Button {
                            Haptic.select()
                            withAnimation(.easeInOut(duration: 0.2)) { filterCleared = true }
                        } label: {
                            Text("Ver todos")
                                .font(BT.footnoteBold)
                                .foregroundStyle(Color.brand)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color.sageTint, in: Capsule())
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Ver todos los lugares")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            }

            }
            // Todo el encabezado mueve el panel, como en el detalle del lugar.
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { v in
                    listDraggedAt = Date()
                    dragOffset = v.translation.height
                }
                .onEnded { v in listDraggedAt = Date(); endPanelDrag(v.predictedEndTranslation.height) })

            if listExpanded { placesGrid } else { cardScroll }
            }
        }
        // Glass más alto: el contenido (top-aligned) sube sobre la tab bar y el
        // glass sobrante queda detrás de ella → panel flush, sin hueco de mapa.
        //
        // Con la lista de lugares el alto es fijo (las tarjetas siempre miden
        // lo mismo). Con el detalle de un lugar es un TOPE: el panel mide lo
        // que ocupa su contenido y no más, así una pestaña con una sola fila
        // de fotos no deja una franja vacía debajo. Si el contenido pasa del
        // tope, el scroll de adentro se encarga.
        // Abierto desde la tarjeta de UN lugar (focusPlaceId), el panel nace ya
        // con el alto del detalle aunque el lugar tarde un instante en
        // resolverse: si no, el panel aparecía con el alto de la lista y un
        // segundo después bajaba a su sitio.
        .frame(
            width: geo.size.width,
            // Mientras se jala, el panel sigue al dedo (sin pasarse de los topes).
            height: selectedPlace == nil
                ? min(expandedHeight, max(Self.peekHeight + bottomClearance, panelHeight - dragOffset))
                : min(expandedHeight, max(Self.peekHeight + bottomClearance, panelHeight - dragOffset)),
            alignment: .top,
        )

        // Superficie blanca sólida con esquinas superiores redondeadas, como las
        // tarjetas de Inicio: el mapa ya no se transparenta detrás del texto.
        // En el alto mínimo solo se ve la barrita y el título con "Cómo
        // llegar": las pestañas y las fotos se esconden (Keyla, 24 Nov 2026).
        .mask(alignment: .top) {
            Rectangle().frame(height: panelMinimized && dragOffset == 0 ? 104 : 4000)
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color.surface)
                .shadow(color: .black.opacity(0.08), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.25), value: selectedPlace?.id)
        .onChange(of: selectedPlace?.id) { _, id in
            // Si el panel está al mínimo, sigue al mínimo al tocar otro lugar (Keyla, 24 Nov 2026).
            if id != nil { focusHandled = true; listExpanded = false } else { detailExpanded = false }
        }
    }

    // MARK: – Card scroll

    private var cardScroll: some View {
        // Cerrado: solo dos tarjetas fijas, sin fila que se mueva de lado
        // (Keyla, 23 Nov 2026: "para evitar movimientos raros"). Las demás se
        // ven deslizando el panel hacia arriba.
        HStack(spacing: 10) {
            ForEach(Array(orderedPlaces.prefix(2).enumerated()), id: \.element.id) { i, place in
                Button { selectPlace(place) } label: { placeCard(place, i) }
                    .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .frame(height: contentHeight)
        .contentShape(Rectangle())
        // Cerrado: deslizar hacia arriba sobre las tarjetas abre el panel;
        // la fila no se mueve de lado mientras tanto.
        .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                guard abs(v.translation.height) > abs(v.translation.width) * 1.3 else { return }
                if abs(v.translation.height) > 6 { listVerticalDrag = true }
                if abs(v.translation.height) > 8 { listDraggedAt = Date() }
                dragOffset = v.translation.height
            }
            .onEnded { v in
                let vertical = listVerticalDrag
                listVerticalDrag = false
                if abs(v.translation.height) > 8 { listDraggedAt = Date() }
                guard vertical else { withAnimation(Self.panelSpring) { dragOffset = 0 }; return }
                endPanelDrag(v.predictedEndTranslation.height)
            })
    }

    private func selectPlace(_ place: Place) {
        guard !listJustDragged else { return }
        Haptic.select()
        withAnimation(Self.panelSpring) { listExpanded = false }
        withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = place }
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            ))
        }
    }

    private func placeCard(_ place: Place, _ i: Int) -> some View {
        PlacePhotoCard(place: place, index: i,
                       isFavorite: isFav(place),
                       onToggleFavorite: {
                           if let jid = journey?.id {
                               routeStore.toggleFavorite(placeId: place.id, journeyId: jid)
                           }
                       })
    }

    /// Abierta: todos los lugares en cuadrícula, con el mismo tamaño de tarjeta
    /// que en la fila. Arriba del todo, jalar hacia abajo la cierra.
    private var placesGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(PlacePhotoCard.width), spacing: 10, alignment: .top), count: 2),
                      spacing: 12) {
                ForEach(Array(orderedPlaces.enumerated()), id: \.element.id) { i, place in
                    Button { selectPlace(place) } label: { placeCard(place, i) }
                        .buttonStyle(.pressable)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomClearance + 40)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("placesGrid")).minY } action: { listTopY = $0 }
            // Sin rebote arriba (Keyla, 23 Nov 2026): si el contenido se estira
            // hacia abajo, se queda en su sitio; lo que se mueve es el panel.
            .visualEffect { content, proxy in
                content.offset(y: -max(0, proxy.frame(in: .named("placesGrid")).minY))
            }
        }
        .coordinateSpace(name: "placesGrid")
        .scrollBounceBehavior(.basedOnSize)
        .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                if listDragAtTop == nil { listDragAtTop = listTopY >= -2 }
                if abs(v.translation.height) > 8 { listDraggedAt = Date() }
                // Arriba del todo y jalando hacia abajo: el panel sigue al dedo
                // en vez de rebotar el contenido (Keyla, 23 Nov 2026).
                if listDragAtTop == true { dragOffset = max(0, v.translation.height) }
            }
            .onEnded { v in
                let atTop = listDragAtTop ?? true
                listDragAtTop = nil
                if abs(v.translation.height) > 8 { listDraggedAt = Date() }
                if atTop, v.translation.height > 0 {
                    endPanelDrag(v.predictedEndTranslation.height)
                } else if dragOffset != 0 {
                    withAnimation(Self.panelSpring) { dragOffset = 0 }
                }
            })
    }

    private var loadMoreCard: some View {
        Button { Haptic.select(); loadMore() } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.teal)
                Text("Ver más")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.teal)
                Text(livePlaces.count - visibleCount == 1
                     ? "1 lugar" : "\(livePlaces.count - visibleCount) lugares")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .background(Color.teal.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.teal.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .frame(height: 90)
        // Carga automática al deslizar el rail hasta el final
        .onAppear { loadMore() }
    }

    // MARK: – Fit map

    // Centers on the trip's places. Uses destination radius as the max span
    // so pins are never shown more zoomed-out than the zone itself.
    /// Pide los lugares del rectángulo visible. Espera 350 ms y cancela la
    /// petición anterior: al arrastrar y soltar varias veces seguidas, solo
    /// la última posición llega a la red.
    private func loadSpotsInBounds(region: MKCoordinateRegion) {
        let visible = SpotBounds(region: region, scale: 1)
        // Zoom o arrastre DENTRO de lo ya cargado: nada que pedir. Antes cada
        // pellizco pedía otra vez el mismo sitio y cancelaba el anterior — la
        // mayoría de las peticiones de los logs acababan en "cancelled".
        if let ya = fetchedBounds, !ya.truncated, ya.contains(visible) {
            return
        }
        boundsTask?.cancel()
        boundsTask = Task {
            // 600 ms: un pellizco continuo manda varios "onEnd" seguidos.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            // Se pide el DOBLE de lo visible: el siguiente arrastre o zoom
            // corto cae dentro y no vuelve a la red.
            let pedido = SpotBounds(region: region, scale: 2)
            do {
                let res = try await APIClient.shared.fetchSpotsInBounds(
                    minLat: pedido.minLat, minLng: pedido.minLng,
                    maxLat: pedido.maxLat, maxLng: pedido.maxLng
                )
                guard !Task.isCancelled else { return }
                // Muy alejado: se conservan los que ya había en vez de vaciar.
                if res.tooWide == true { return }
                let nuevos = res.spots.map(\.asPlace)
                await MainActor.run {
                    fetchedBounds = SpotBounds(minLat: pedido.minLat, minLng: pedido.minLng,
                                               maxLat: pedido.maxLat, maxLng: pedido.maxLng,
                                               truncated: res.truncated == true)
                    // Sin animación y solo si cambió algo: reasignar la misma
                    // lista redibujaba todos los pins del mapa.
                    if nuevos.map(\.id) != boundsPlaces.map(\.id) {
                        boundsPlaces = nuevos
                    }
                }
                dlog("🗺️ [TripDetailView] en pantalla: \(nuevos.count) lugar(es) — \(nuevos.prefix(5).map(\.name).joined(separator: ", "))")
            } catch is CancellationError {
                // Reemplazada por un gesto más nuevo: no es un fallo.
            } catch let e as URLError where e.code == .cancelled {
                // Idem, cancelada a nivel de red.
            } catch {
                // Un fallo conserva los pins de antes: no dejar el mapa vacío.
                dlog("🗺️ [TripDetailView] spotsInBounds falló (\(error.localizedDescription)) — conservo \(boundsPlaces.count)")
            }
        }
    }

    private func fitMap() {
        // Encuadra los lugares cargados (primer lote en la carga inicial)
        let coords = displayedPlaces.map(\.coordinate)
        dlog("🗺️ [fitMap] places=\(livePlaces.count) displayed=\(displayedPlaces.count) route.center=\(route.centerLat.map{String($0)} ?? "nil") routeStore.center=\(routeStore.route.centerLat.map{String($0)} ?? "nil")")
        if coords.isEmpty {
            // Sin spots: centrar en la coordenada explícita. Preferir `route` (prop del view)
            // sobre `routeStore.route` porque este puede ser .placeholder si onChange dispara
            // antes de que termine el fetch.
            let center = route.explicitCenter ?? routeStore.route.explicitCenter
            dlog("🗺️ [fitMap] sin places → center=\(center.map { "(\($0.latitude),\($0.longitude))" } ?? "NIL — mapa no se mueve")")
            if let center {
                withAnimation(.easeInOut(duration: 0.6)) {
                    camera = .region(MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                    ))
                }
            }
            return
        }

        // 1° lat ≈ 111 km — radius as cap so we never zoom out past the zone
        let radiusKm  = Double(routeStore.route.radiusMeters ?? 5000) / 1000.0
        let maxDeg    = (radiusKm / 111.0) * 2.4   // full diameter + 20 % padding

        // Encuadre centrado donde están la mayoría de lugares: la mediana no se
        // deja arrastrar por un lugar lejano, que antes empujaba los pines hacia
        // arriba del mapa (Keyla, 24 Nov 2026). Los lugares fuera de la zona no
        // cuentan para el encuadre (siguen en el mapa).
        let lats = coords.map(\.latitude).sorted(), lons = coords.map(\.longitude).sorted()
        let midLat = lats[lats.count / 2], midLon = lons[lons.count / 2]
        let near = coords.filter { abs($0.latitude - midLat) <= maxDeg / 2 && abs($0.longitude - midLon) <= maxDeg / 2 }
        let fit = near.isEmpty ? coords : near
        let minLat = fit.map(\.latitude).min()!
        let maxLat = fit.map(\.latitude).max()!
        let minLon = fit.map(\.longitude).min()!
        let maxLon = fit.map(\.longitude).max()!

        // Fit actual pins with padding, capped at zone diameter
        let rawLat = (maxLat - minLat) * 1.6
        let rawLon = (maxLon - minLon) * 1.6
        let latDelta = min(max(rawLat, 0.015), maxDeg)
        let lonDelta = min(max(rawLon, 0.015), maxDeg)

        let sheetFraction = sheetHeight / UIScreen.main.bounds.height
        let centerLat = (minLat + maxLat) / 2 - latDelta * sheetFraction / 2

        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        ))
    }

    /// Centra el lugar en la parte VISIBLE del mapa, sobre el panel. Solo al
    /// abrirlo desde Inicio (Keyla, 23 Nov 2026: "just the first time").
    private func focusCamera(on place: Place, span: Double = 0.008) {
        let screenH = UIScreen.main.bounds.height
        let panelH = detalleHeight + bottomClearance
        // El centro del mapa baja la mitad del panel: el pin sube a la mitad del hueco libre.
        let shift = span * (panelH / screenH) / 2
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude - shift, longitude: place.longitude),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ))
        }
    }

    // The location button — centers on user's physical position
    private func centerOnUser() {
        if let coord = locationService.userLocation?.coordinate {
            withAnimation(.easeInOut(duration: 0.6)) {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }
}

// MARK: – DESTINATION PIN (pioneer: sin spots curados)

struct DestinationPin: View {
    let name: String

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.sand)
                    .frame(width: 46, height: 46)
                    .shadow(color: Color.sand.opacity(0.4), radius: 8, y: 3)
                LocationPin(size: 23)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.surface)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                )
                .fixedSize()
        }
    }
}

// MARK: – RECOMMENDATION PIN
// Jerarquía por fuerza de recomendación (no por sticker):
//   • Featured  → píldora con glifo + nombre SIEMPRE visible (top de la comunidad)
//   • Estándar  → pin circular con glifo de categoría; nombre solo al seleccionar
//   • Recuerdo desbloqueado → acento secundario (check sand), nunca el pin entero

struct RecommendationPin: View {
    let place: Place
    let isSelected: Bool

    /// El icono de su categoría cuando el lugar lo trae; si no, el genérico de
    /// la categoría gruesa. Sin esto todos los pines eran el mismo: place_type
    /// casi nunca llega y todo caía en "cultura" (las columnas).
    private var glyph: String {
        if let n = place.categoryName { return CategoryIcon.symbol(for: n) }
        return place.categoryIcon ?? place.category.symbol
    }

    var body: some View {
        if place.featured {
            featuredPin
        } else {
            standardPin
        }
    }

    // ── Featured: píldora etiquetada ───────────────
    private var featuredPin: some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .bold))
            Text(place.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.teal)
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Color.teal.opacity(0.35), radius: isSelected ? 10 : 5, y: 2)
        )
        .overlay(alignment: .topTrailing) { if place.isCollected { collectedBadge } }
        .scaleEffect(isSelected ? 1.08 : 1)
        .animation(.spring(response: 0.3), value: isSelected)
        .fixedSize()
    }

    // ── Estándar: pin circular con glifo ───────────
    private var standardPin: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color.surface)
                    .frame(width: isSelected ? 40 : 33, height: isSelected ? 40 : 33)
                    .overlay(Circle().strokeBorder(isSelected ? Color.terracotta : Color.brand.opacity(0.3),
                                                   lineWidth: isSelected ? 2.5 : 1.25))
                    .shadow(color: .black.opacity(0.18), radius: isSelected ? 8 : 3, y: 1.5)
                Image(systemName: glyph)
                    .font(.system(size: isSelected ? 17 : 14, weight: .regular))
                    .foregroundStyle(Color.brand)
            }
            .overlay(alignment: .topTrailing) { if place.isCollected { collectedBadge } }

            // El nombre solo aparece al seleccionar → mapa limpio por defecto
            if isSelected {
                Text(place.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.surface)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1))
                    .fixedSize()
            }
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }

    // ── Acento secundario: recuerdo desbloqueado ───
    private var collectedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.sand)
            .background(Circle().fill(.white).frame(width: 12, height: 12))
            .offset(x: 4, y: -4)
    }
}

// MARK: – PLACE PHOTO CARD

/// Tarjeta del carrusel de lugares del mapa. Sin corazón ni "Por visitar": el
/// estado de visita lo cuenta la línea teal sobre la foto, y el favorito ya no
/// se marca desde la app (ver la cabecera de la ficha del lugar).
struct PlacePhotoCard: View {
    let place: Place
    let index: Int
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}
    /// Dos tarjetas llenan el ancho de la pantalla (Keyla, 23 Nov 2026).
    static var width: CGFloat { floor((UIScreen.main.bounds.width - 40 - 10) / 2) }

    /// La foto sube de 90 a 115: sin la línea de "Por visitar" la tarjeta media
    /// menos que el alto del carril (160) y quedaba una franja vacía debajo del
    /// nombre. 115 + la banda del texto llena justo la fila.
    private let fotoAlto: CGFloat = 115

    private let palettes: [[Color]] = [
        [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
        [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
        [Color(hex: "4A3D35"), Color(hex: "7A6558")],
        [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
    ]

    /// Mismo estilo que las tarjetas de Inicio (HomePlaceCard): foto 4:3,
    /// nombre y la categoría con su ícono en un pie blanco. Sin "Top": no hay
    /// rankings en Villa Rica.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedImage(urlString: place.coverUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.groupedBg }
            .frame(width: Self.width, height: 140)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let cat = place.categoryName {
                    HStack(spacing: 5) {
                        Image(systemName: CategoryIcon.symbol(for: cat))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.brand)
                            .accessibilityHidden(true)
                        Text(cat)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: Self.width, alignment: .leading)
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }

    private var gradientFallback: some View {
        LinearGradient(
            colors: palettes[min(index, palettes.count - 1)].map { $0.opacity(0.82) },
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay { Text(place.stickerEmoji).font(.system(size: 32)) }
    }
}

// MARK: – GLASS CIRCLE BUTTON STYLE

struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassCircle()
            .mapControlShadow()
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: – MAP ICON BUTTON

struct MapIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Place detail sheet (Fotos / Info / Buddies)
//
// Reemplaza la tarjeta chica que se mostraba embebida en el panel del mapa:
// esto es una ficha aparte, con sus propias pestañas — no cabía ni tenía
// sentido forzarla dentro del panel horizontal de tarjetas. Reseñas queda
// fuera a propósito: no existe ese sistema (calificar/comentar) todavía.
struct PlaceGuideDetailSheet: View {
    let place: Place
    let destinationId: String?
    let buddyPresenceText: String?
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onNavigate: () -> Void
    /// Embebido en el panel del mapa (no como sheet): @Environment(\.dismiss)
    /// no tiene nada que cerrar ahí, así que quién lo contiene decide qué
    /// significa "cerrar" (volver a mostrar la lista).
    let onClose: () -> Void
    /// Panel jalado hacia arriba: las fotos se ven en cuadrícula, no en carrusel.
    var expanded: Bool = false
    /// Mismo panel para elegir la ubicación de un negocio (Keyla, 21 Nov 2026):
    /// abre en Fotos y el botón principal dice "Es mi negocio".
    var actionTitle: String = "Cómo llegar"
    var actionIcon: String = "arrow.triangle.turn.up.right.circle"
    var startOnPhotos: Bool = false
    /// Negocio sin local: el botón verde abre el chat con el negocio en vez de la ruta.
    var actionOpensChat: Bool = false
    /// Pantalla completa con su propio botón de volver: sin la X (un solo cierre).
    var showsClose: Bool = true
    /// Arrastre del panel desde su parte fija (nombre, categoría, pestañas), no solo
    /// desde la barrita (Keyla, 23 Nov 2026). Lo usa cada pantalla con mapa.
    var onPanelDrag: ((CGFloat) -> Void)? = nil
    @State private var pullClosing = false
    @State private var verticalPanelDrag = false
    /// Un deslizar que empieza sobre una pestaña o "Cómo llegar" mueve el panel y
    /// NO toca el botón (Keyla, 23 Nov 2026: "it opens that section").
    @State private var panelDraggedAt: Date = .distantPast
    private var justDragged: Bool { Date().timeIntervalSince(panelDraggedAt) < 0.4 }
    @State private var contentTopY: CGFloat = 0
    @State private var dragStartedAtTop: Bool? = nil
    var onPanelDragEnd: ((CGFloat) -> Void)? = nil
    /// Alto mínimo del detalle en el mapa: igual en todas las pestañas.
    static let minHeight: CGFloat = 258
    /// El dueño viendo SU lugar desde Mi negocio: mismo panel, con lo editable.
    @Environment(\.businessEdit) private var businessEdit
    private var editCtx: BusinessEditContext? {
        guard let e = businessEdit, e.spotId.lowercased() == place.id.uuidString.lowercased() else { return nil }
        return e
    }

    private enum Tab: String, CaseIterable {
        case productos = "Productos", info = "Información", fotos = "Fotos", buddies = "Buddies"
        /// Pestañas visibles: Buddies queda oculta en Villa Rica V1.
        static var visible: [Tab] { HomeRowsView.showsBuddyTools ? allCases : [.productos, .info, .fotos] }
        var icon: String {
            switch self {
            case .fotos:   return "photo.on.rectangle"
            case .info:    return "info.circle"
            case .productos: return "bag"
            case .buddies: return "person.2"
            }
        }
    }
    @State private var tab: Tab = .productos
    @State private var userPickedTab = false
    /// Sin productos, Fotos va primero y Productos al final (Keyla, 24 Nov 2026).
    private var noProducts: Bool { (productsState == .loaded || productsState == .notLinked || productsState == .failed) && products.isEmpty }
    private var visibleTabs: [Tab] {
        guard noProducts else { return Tab.visible }
        return [.fotos, .info, .productos] + Tab.visible.filter { $0 == .buddies }
    }
    @State private var products: [FincasProduct] = []
    @State private var productToRemove: FincasProduct? = nil
    @State private var productRemoveError: String? = nil
    @State private var productsState: ProductsState = .idle
    private enum ProductsState { case idle, loading, loaded, notLinked, failed }

    @State private var gallery: APIPlaceGallery?
    @State private var isLoadingGallery = true
    @State private var buddies: [APIPlaceBuddy] = []
    @State private var isLoadingBuddies = true
    @State private var showFullGallery = false
    /// La foto con la que se abrió el visor a pantalla completa.
    @State private var visorFoto: VisorFotoInicio? = nil
    @Namespace private var photoZoom
    /// La foto que se ve: al cerrar vuelve a su miniatura (zoom nativo, iOS 18+).
    @State private var zoomUrl: String? = nil
    /// Alto real del contenido de la pestaña abierta (ver el ScrollView).
    @State private var altoContenido: CGFloat = 0

    /// Una foto en la fila, sabiendo de quién es y qué página ocupa. La fila
    /// necesita las tres cosas juntas: la URL para pintarla, el dueño para
    /// ordenar y decidir si se puede borrar, y la página para pedir el borrado.
    struct GalleryPhoto: Identifiable {
        let url: String
        let journeyId: String
        let pageIndex: Int?
        /// UUID de la página en el libro. Estable; es por donde va el borrado.
        /// Nil en fotos publicadas antes de la migración, que solo tienen índice.
        let clientPageId: String?
        let isMine: Bool
        var id: String { "\(journeyId)#\(clientPageId ?? pageIndex.map(String.init) ?? url)" }
        /// Se puede borrar si el servidor dio con qué referirse a ella.
        var isDeletable: Bool { clientPageId != nil || pageIndex != nil }
    }

    /// Fotos del lugar con LAS MÍAS PRIMERO. Un buddy entra a esta ficha a ver
    /// cómo quedó lo que aportó, y con orden estricto por recencia lo suyo se
    /// pierde entre lo de todos. El resto conserva el orden que trae el server.
    private var galleryPhotos: [GalleryPhoto] {
        let me = Session.travelerId
        let visits = gallery?.visits ?? []
        let flatten: (APIPlaceVisit) -> [GalleryPhoto] = { visit in
            let mine = visit.travelerId != nil && visit.travelerId == me
            // photoPages cuando el server la manda; si no, las URLs sueltas y
            // sin página — se ven igual, solo que no se pueden borrar.
            if let pages = visit.photoPages, !pages.isEmpty {
                return pages.map { GalleryPhoto(url: $0.url, journeyId: visit.journeyId,
                                                pageIndex: $0.pageIndex, clientPageId: $0.clientPageId,
                                                isMine: mine) }
            }
            return visit.photos.map { GalleryPhoto(url: $0, journeyId: visit.journeyId,
                                                   pageIndex: nil, clientPageId: nil, isMine: mine) }
        }
        return visits.filter { $0.travelerId == me }.flatMap(flatten)
             + visits.filter { $0.travelerId != me }.flatMap(flatten)
    }

    /// Fotos del dueño primero (la portada), luego las de los visitantes: así el
    /// visor recorre todo en el mismo orden que la fila (Keyla, 22 Nov 2026).
    @ObservedObject private var ownerStore = OwnerPhotoStore.shared
    private var ownerUrls: [String] { ownerStore.photos(place.id.uuidString.lowercased()).map(\.url) }
    private var allPhotos: [String] {
        let gallery = galleryPhotos.map(\.url)
        return ownerUrls + gallery.filter { !ownerUrls.contains($0) }
    }
    private func openPhoto(_ url: String) {
        guard !justDragged else { return }
        zoomUrl = url
        visorFoto = VisorFotoInicio(indice: allPhotos.firstIndex(of: url) ?? 0)
    }

    @State private var photoPendingDeletion: GalleryPhoto? = nil
    @State private var isDeletingPhoto = false

    /// Mi propia recomendación de este lugar, si soy buddy aprobado.
    ///
    /// Sale de la galería y no de una llamada aparte: cada visita ya trae
    /// traveler_id y is_buddy —que el backend calcula contra buddy_profile con
    /// verification_status='approved'—, así que las dos condiciones se leen de
    /// datos que esta vista ya tenía cargados. Su journeyId es al que se le
    /// suma la foto: la recomendación existe, no hay que crear ninguna.
    private var myBuddyRecommendation: APIPlaceVisit? {
        guard let me = Session.travelerId else { return nil }
        return gallery?.visits.first { $0.travelerId == me && $0.isBuddy == true }
    }

    @State private var editingJourney: APIJourney? = nil
    @State private var isOpeningEditor = false

    var body: some View {
        // Mismo espacio que ocupaba la lista de tarjetas (~265pt) — nada
        // aquí puede darse el lujo de respirar como en una hoja aparte.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
            header

            tabBar
                .padding(.top, 14)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { v in
                        // Solo vertical: un toque o un deslizar de lado no mueve el panel.
                        guard abs(v.translation.height) > abs(v.translation.width) else { return }
                        if abs(v.translation.height) > 8 { panelDraggedAt = Date() }
                        onPanelDrag?(v.translation.height)
                    }
                    .onEnded { v in
                        if abs(v.translation.height) > 8 { panelDraggedAt = Date() }
                        onPanelDragEnd?(v.predictedEndTranslation.height)
                    },
                including: onPanelDrag == nil ? .subviews : .all
            )

            ScrollView {
                Group {
                    switch tab {
                    case .fotos:   fotosTab
                    case .info:    infoTab
                    case .productos: productosTab
                    case .buddies: buddiesTab
                    }
                }
                // Lo que mide el contenido de la pestaña. Con una sola fila de
                // fotos, el panel se quedaba con el alto de la lista de
                // lugares y abajo sobraba una franja vacía.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altoContenido = $0 }
                // Traspaso contenido -> panel (Keyla, 23 Nov 2026, estilo Apple Maps):
                // abierto y con el contenido arriba del todo, seguir jalando hacia
                // abajo (el rebote pasa de 60 pt) cierra el panel.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("panelScroll")).minY } action: { y in
                    contentTopY = y
                    guard expanded, onPanelDragEnd != nil, y > 60, !pullClosing else { return }
                    pullClosing = true
                    onPanelDragEnd?(200)
                }
            }
            .coordinateSpace(name: "panelScroll")
            // Las fotos del dueño se cargan al abrir el panel (Keyla, 23 Nov 2026):
            // antes solo las pedía la fila de fotos, que no se dibuja si no hay
            // fotos de visitantes, y Fotos decía "Todavía no hay fotos".
            .task(id: place.id) { await ownerStore.load(place.id.uuidString.lowercased()) }
            .onChange(of: expanded) { _, _ in pullClosing = false }
            // Cerrado: deslizar en vertical sobre los productos abre el panel
            // (antes solo la barrita y el encabezado). Las filas horizontales
            // siguen desplazándose de lado: solo cuenta un gesto vertical.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStartedAtTop == nil { dragStartedAtTop = contentTopY >= -2 }
                        guard !expanded, abs(v.translation.height) > abs(v.translation.width) * 1.3 else { return }
                        if !verticalPanelDrag, abs(v.translation.height) > 6 { verticalPanelDrag = true }
                        if abs(v.translation.height) > 8 { panelDraggedAt = Date() }
                        onPanelDrag?(v.translation.height)
                    }
                    .onEnded { v in
                        if verticalPanelDrag || abs(v.translation.height) > 8 { panelDraggedAt = Date() }
                        verticalPanelDrag = false
                        let atTop = dragStartedAtTop ?? true
                        dragStartedAtTop = nil
                        let vertical = abs(v.translation.height) > abs(v.translation.width) * 1.3
                        if expanded {
                            // Abierto: con el contenido ya arriba, jalar hacia abajo cierra.
                            // Si estaba desplazado, el mismo gesto solo sube el contenido.
                            if vertical, atTop, v.translation.height > 50, !pullClosing {
                                pullClosing = true
                                onPanelDragEnd?(max(200, v.predictedEndTranslation.height))
                            }
                            return
                        }
                        guard vertical else { onPanelDrag?(0); return }
                        onPanelDragEnd?(v.predictedEndTranslation.height)
                    },
                including: onPanelDrag == nil ? .subviews : .all
            )
            // maxHeight y no height: el scroll pide lo que ocupa su contenido,
            // pero si no entra (la pestaña Info con texto largo) se deja
            // comprimir por el tope del panel y desplaza por dentro.
            .frame(maxHeight: altoContenido > 0 ? altoContenido : nil)
            // Sin los márgenes que el scroll agrega solo por estar cerca del
            // borde de la pantalla (el hueco del indicador de inicio): el
            // panel ya termina sobre la tab bar, así que esa reserva quedaba
            // como una franja vacía debajo de las fotos.
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            // Cerrado, el contenido no se desplaza (Keyla, 23 Nov 2026): al deslizar
            // hacia arriba la primera vez, la fila de productos subia detras de las
            // pestanas mientras el panel abria. Cerrado, el gesto solo mueve el panel.
            .scrollDisabled(!expanded && onPanelDrag != nil)
            // El contenido primero; el espacio en blanco solo toma lo que sobra.
            .layoutPriority(1)

            // El espacio en blanco bajo el contenido también mueve el panel
            // (Keyla, 23 Nov 2026: "make swipeable the blank space").
            if onPanelDrag != nil {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .global)
                            .onChanged { v in
                                guard abs(v.translation.height) > abs(v.translation.width) else { return }
                                onPanelDrag?(v.translation.height)
                            }
                            .onEnded { v in onPanelDragEnd?(v.predictedEndTranslation.height) }
                    )
            }
        }
        .padding(.top, 10)
        // id: place.id — sin esto, tocar OTRO pin sin cerrar el panel
        // actualizaba el título (lee `place` directo) pero las fotos se
        // quedaban con las del lugar anterior: un .task sin id corre UNA sola
        // vez por instancia de vista, y bottomSection reusa la misma vista al
        // cambiar selectedPlace, así que nunca volvía a pedir la galería.
        .task(id: place.id) { userPickedTab = false; tab = (startOnPhotos || isRecommending) ? .fotos : .productos; await loadProducts() }
        .navigationDestination(item: $ownerEditRoute) { r in FincasProductEditView(route: r) }
        // Al guardar en el editor, las tarjetas muestran la foto y el precio nuevos.
        .onReceive(NotificationCenter.default.publisher(for: .fincasProductsChanged)) { _ in
            Task { await loadProducts() }
        }
        .fullScreenCover(item: $chatTarget) { t in BusinessChatView(target: t) }
        .confirmationDialog("¿Quitar este producto?", isPresented: Binding(get: { productToRemove != nil }, set: { if !$0 { productToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Quitar producto", role: .destructive) {
                if let p = productToRemove { Task { await archiveFromPanel(p) } }
                productToRemove = nil
            }
        } message: { Text("Deja de verse en Buddy. Queda como Oculto en tu lista y puedes volver a mostrarlo.") }
        .alert("No pudimos quitarlo", isPresented: Binding(get: { productRemoveError != nil }, set: { if !$0 { productRemoveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(productRemoveError ?? "") }
        .fullScreenCover(item: $productViewer) { set in
            // Al cerrar vuelve a la tarjeta de la foto que se ve, y la fila o la
            // cuadrícula se mueve hasta ella (regla 26, Keyla, 23 Nov 2026).
            // Arrastre propio para cerrar (Keyla, 24 Nov 2026): el del sistema
            // solo responde si el visor nació de una miniatura, y al abrirse
            // solo (producto tocado en Inicio) no se podía cerrar deslizando.
            PlacePhotoViewer(photos: set.photos, inicial: set.start, systemDismiss: false,
                             onShowing: { i in
                                 guard set.photos.indices.contains(i) else { return }
                                 if let id = entryFor(photo: set.photos[i]) { productShownId = id }
                             },
                             caption: { i in
                                 guard set.photos.indices.contains(i),
                                       let id = entryFor(photo: set.photos[i]),
                                       let e = productEntries.first(where: { $0.id == id }) else { return nil }
                                 var parts: [String] = []
                                 if let price = e.pres?.price { parts.append(Self.soles(price)) }
                                 if let label = e.pres?.label, !label.isEmpty { parts.append(label) }
                                 return (e.product.name, parts.isEmpty ? nil : parts.joined(separator: " · "))
                             })
                .photoZoomDestination(id: "product-\(productShownId ?? set.productId)", in: productZoom)
        }
        .task(id: place.id) {
            isLoadingGallery = true
            isLoadingBuddies = true
            async let galleryTask: APIPlaceGallery? = try? APIClient.shared.fetchSpotGallery(spotId: place.id.uuidString)
            async let buddiesTask: [APIPlaceBuddy]? = fetchBuddiesIfPossible()
            let (g, b) = await (galleryTask, buddiesTask)
            gallery = g
            isLoadingGallery = false
            buddies = b ?? []
            isLoadingBuddies = false
        }
        .sheet(isPresented: $showFullGallery) {
            PlaceFullGallerySheet(placeName: place.name, photos: allPhotos)
        }
        .fullScreenCover(item: $visorFoto) { inicio in
            PlacePhotoViewer(photos: allPhotos, inicial: inicio.indice, systemDismiss: PhotoZoom.systemAvailable,
                             onShowing: { i in if allPhotos.indices.contains(i) { zoomUrl = allPhotos[i] } })
                .photoZoomDestination(id: zoomUrl ?? (allPhotos.indices.contains(inicio.indice) ? allPhotos[inicio.indice] : ""), in: photoZoom)
        }
        .fullScreenCover(item: $editingJourney) { journey in
            // publishesOnSave: acá no existe el paso posterior de "publicar el
            // trip" — la foto se suma a algo que YA está publicado, así que el
            // único gesto disponible tiene que dejarla visible.
            TripEditorSheet(journey: journey, initialPage: -1, publishesOnSave: true) {}
        }
        // Recargar con .journeyPublished y no con onDisappear del editor: el
        // cover se cierra apenas termina la edición, mientras la subida de las
        // páginas sigue en vuelo. La recarga salía antes que el POST y traía la
        // galería vieja —la foto estaba guardada pero no se veía—. La
        // notificación se emite recién cuando publishJourney terminó de subir y
        // marcar el journey.
        .confirmationDialog("¿Eliminar esta foto?",
                            isPresented: Binding(get: { photoPendingDeletion != nil },
                                                 set: { if !$0 { photoPendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                if let photo = photoPendingDeletion { deletePhoto(photo) }
            }
            Button("Cancelar", role: .cancel) { photoPendingDeletion = nil }
        } message: {
            Text("Se quitará de este lugar para siempre.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
            Task {
                gallery = try? await APIClient.shared.fetchSpotGallery(spotId: place.id.uuidString)
            }
        }
    }

    private func fetchBuddiesIfPossible() async -> [APIPlaceBuddy]? {
        guard let destinationId else { return nil }
        return try? await APIClient.shared.fetchDestinationBuddies(id: destinationId)
    }

    // MARK: Productos (solo lectura, desde Apartalo vía buddy-core)

    @ViewBuilder
    private var productosTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch productsState {
            case .idle, .loading:
                HStack(spacing: 8) { ProgressView(); Text("Cargando productos").font(BT.footnote).foregroundStyle(Color.inkMuted) }
                    .padding(.vertical, 16)
            case .notLinked, .failed where products.isEmpty && editCtx != nil:
                productCardsRow
            case .notLinked, .failed where products.isEmpty:
                productsEmpty(productsState == .failed
                    ? "No pudimos cargar los productos. Intenta más tarde."
                    : "Este lugar aún no muestra sus productos en Buddy.")
            default:
                if products.isEmpty && editCtx == nil {
                    productsEmpty("Este negocio aún no tiene productos visibles.")
                } else {
                    productCardsRow
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @State private var chatTarget: BusinessChatTarget? = nil

    /// "Preguntar al negocio": abre el chat con una tarjeta del lugar.
    private func openBusinessChat() {
        chatTarget = BusinessChatTarget(spotId: place.id.uuidString.lowercased(), title: place.name,
                                        card: BizCard(kind: "place", title: place.name,
                                                      subtitle: place.categoryName,
                                                      spotId: place.id.uuidString.lowercased()))
    }

    private var askBusinessButton: some View {
        Button {
            openBusinessChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 30, height: 30)
                    .background(Color.paleSage, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pregúntale al negocio").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    Text("Horario, precios o lo que necesites saber").font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func askAbout(_ p: FincasProduct) {
        let shown = (p.presentations ?? []).filter { $0.visible != false }
        let first = shown.first
        chatTarget = BusinessChatTarget(
            spotId: place.id.uuidString.lowercased(), title: place.name,
            card: BizCard(kind: "product", title: p.name, subtitle: first?.label,
                          price: first?.price.map { String(format: "S/ %.2f", $0) },
                          imageUrl: p.coverUrl, productId: p.id))
    }

    private func productsEmpty(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bag").foregroundStyle(Color.brand)
                .frame(width: 34, height: 34).background(Color.paleSage, in: RoundedRectangle(cornerRadius: 10))
            Text(text).font(BT.footnote).foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    /// Toda la tarjeta pregunta por el producto; el ícono de chat va junto al
    /// nombre, como parte de la tarjeta (Keyla, 20 Nov 2026: el botón suelto
    /// se veía "fuera de lugar").
    /// Productos como tarjetas en fila, del tamaño de "Añadir producto" (Keyla, 21 Nov
    /// 2026): foto y precio debajo; la burbuja en la esquina abre el chat.
    // Abierto a pantalla completa: los productos llenan la pantalla en una
    // cuadrícula de 3 (Keyla, 23 Nov 2026); cerrado, la fila de siempre.
    @ViewBuilder
    private var productCardsRow: some View {
        if expanded {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardSide), spacing: 8, alignment: .top), count: 3),
                      alignment: .leading, spacing: 14) {
                if let ctx = editCtx {
                    NavigationLink(value: FincasProductRoute(farmId: ctx.businessId, product: nil)) {
                        DashedAddTile(title: "Añadir producto", side: cardSide)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(productEntries, id: \.id) { e in productCard(e.product, pres: e.pres).id(e.id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(FollowProductViewer(shownId: productShownId, active: productViewer != nil))
        } else {
            productCardsScroll
        }
    }

    private var productCardsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                if let ctx = editCtx {
                    NavigationLink(value: FincasProductRoute(farmId: ctx.businessId, product: nil)) {
                        DashedAddTile(title: "Añadir producto", side: cardSide)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(productEntries, id: \.id) { e in productCard(e.product, pres: e.pres).id(e.id) }
            }
            .modifier(FollowProductViewer(shownId: productShownId, active: productViewer != nil))
        }
        .scrollClipDisabled()
        // Al deslizar hacia arriba la fila no se mueve de lado (Keyla, 23 Nov 2026):
        // si las tarjetas caben no rebota, y durante un gesto vertical se queda quieta.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDisabled(verticalPanelDrag)
    }

    /// Precio de la tarjeta: el de la presentación visible; con varias, "desde" el menor.
    private func priceText(_ p: FincasProduct) -> String? {
        let prices = (p.presentations ?? []).filter { $0.visible != false }.compactMap(\.price)
        guard let low = prices.min() else { return nil }
        let txt = Self.soles(low)
        return Set(prices).count > 1 ? "Desde \(txt)" : txt
    }

    /// "S/ 20" si es entero, "S/ 25.90" si no: corto para la tarjeta de 115 pt.
    static func soles(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? "S/ \(Int(v))" : String(format: "S/ %.2f", v)
    }

    /// Precio de la tarjeta en dos tamaños (Keyla, 23 Nov 2026: "Desde S/ 20...." se cortaba).
    @ViewBuilder
    private func priceLabel(_ p: FincasProduct) -> some View {
        let prices = (p.presentations ?? []).filter { $0.visible != false }.compactMap(\.price)
        if let low = prices.min() {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if Set(prices).count > 1 {
                    Text("Desde").font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
                Text(Self.soles(low)).font(BT.footnoteBold).foregroundStyle(Color.brand)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// Una tarjeta por PRESENTACIÓN (Keyla, 23 Nov 2026: "show each presentation"):
    /// 250 g y 1 kg del mismo café son dos tarjetas con su foto y su precio.
    private struct ProductEntry { let id: String; let product: FincasProduct; let pres: FincasProduct.Presentation? }
    private var productEntries: [ProductEntry] {
        let all = products.flatMap { p -> [ProductEntry] in
            let shown = (p.presentations ?? []).filter { $0.visible != false }
            if shown.isEmpty { return [ProductEntry(id: p.id, product: p, pres: nil)] }
            return shown.map { ProductEntry(id: "\(p.id)-\($0.id)", product: p, pres: $0) }
        }
        // El producto tocado en Inicio va primero (Keyla, 23 Nov 2026).
        guard let f = focusEntryId, let i = all.firstIndex(where: { $0.id == f }) else { return all }
        var out = all; out.insert(out.remove(at: i), at: 0); return out
    }

    /// Producto que se tocó en "Productos locales" para abrir este lugar.
    @State private var focusEntryId: String? = ProductFocus.take()
    @State private var focusViewerOpened = false

    /// Tocar un producto en Inicio abre el lugar con ese producto primero y,
    /// encima, su foto a pantalla completa (Keyla, 24 Nov 2026). Una sola vez:
    /// al cerrar el visor queda la ficha con el producto primero.
    private func openFocusedProductViewer() {
        guard !focusViewerOpened, let f = focusEntryId,
              let e = productEntries.first(where: { $0.id == f }) else { return }
        focusViewerOpened = true
        let all = allProductPhotos
        guard !all.isEmpty else { return }
        let cover = presCover(e.product, e.pres)
        let start = cover.flatMap { c in all.firstIndex(of: c) } ?? 0
        // Un instante para que la tarjeta exista y el visor crezca desde ella.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            productShownId = entryId(e.product, e.pres)
            productViewer = ProductPhotoSet(photos: all, productId: e.product.id, start: start)
        }
    }

    private func presCover(_ p: FincasProduct, _ pr: FincasProduct.Presentation?) -> String? {
        guard let pr else { return p.coverUrl }
        let own = pr.photos?.first?.url ?? pr.photoUrl
        return (own?.isEmpty == false ? own : nil) ?? p.coverUrl
    }

    /// Cerrado, la tarjeta es un poco más chica para que nombre y precio entren sin
    /// agrandar el panel (Keyla, 23 Nov 2026: espacio de más en Fotos).
    /// Mismo tamaño abierto y cerrado (Keyla, 23 Nov 2026).
    private var cardSide: CGFloat { 114 }
    /// La fila de fotos usa el mismo alto que una tarjeta de producto con su
    /// nombre y precio: así el panel no deja espacio vacío en Fotos.
    private var photoRowHeight: CGFloat { 160 }

    private func productCard(_ p: FincasProduct, pres: FincasProduct.Presentation? = nil) -> some View {
        let photos = productPhotos(p)
        let cover = presCover(p, pres)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                // Un deslizar que empezó sobre la foto mueve el panel, no la abre.
                guard !justDragged else { return }
                // La foto siempre abre el visor, también para el dueño; editar es
                // solo con el lápiz (Keyla, 23 Nov 2026).
                if !photos.isEmpty {
                    // Como en un perfil (Keyla, 23 Nov 2026): el visor sigue con los
                    // demás productos al pasar la última foto de este. Abre en la
                    // foto de esta presentación.
                    let all = allProductPhotos
                    let start = cover.flatMap { c in all.firstIndex(of: c) } ?? 0
                    productShownId = entryId(p, pres)
                    productViewer = ProductPhotoSet(photos: all, productId: p.id, start: start)
                } else if editCtx != nil { Task { await openOwnerEditor(p, pres: pres) } } else { askAbout(p) }
            } label: {
                CachedImage(urlString: cover) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "bag").foregroundStyle(Color.brand)
                }
                .frame(width: cardSide, height: cardSide)
                .background(Color.paleSage)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .photoZoomSource(id: "product-\(entryId(p, pres))", in: productZoom)
            .accessibilityLabel(pres.map { "\(p.name), \($0.label)" } ?? p.name)
            .overlay(alignment: .topTrailing) {
                Button {
                    guard !justDragged else { return }
                    if editCtx != nil { Task { await openOwnerEditor(p, pres: pres) } } else { askAbout(p) }
                } label: {
                    Group {
                        if openingProductId == p.id { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: editCtx != nil ? "pencil" : "bubble.left.and.text.bubble.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brand)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(Color.surface, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(editCtx != nil ? "Editar \(p.name)" : "Preguntar por \(p.name)")
            }
            // Nombre y precio bajo la foto (Keyla, 23 Nov 2026).
            Text(p.name).font(BT.caption1).foregroundStyle(Color.ink).lineLimit(1)
            if let pres {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let price = pres.price {
                        Text(Self.soles(price)).font(BT.footnoteBold).foregroundStyle(Color.brand)
                    }
                    if !pres.label.isEmpty {
                        Text(pres.label).font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.8)
            } else {
                priceLabel(p)
            }
        }
        .frame(width: cardSide, alignment: .leading)
        .contextMenu {
            if editCtx != nil {
                Button(role: .destructive) { productToRemove = p } label: { Label("Quitar producto", systemImage: "trash") }
            }
        }
    }

    private func archiveFromPanel(_ p: FincasProduct) async {
        guard let ctx = editCtx else { return }
        do {
            try await FincasAuth.archiveProduct(farmId: ctx.businessId, productId: p.id)
            products.removeAll { $0.id == p.id }
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: ctx.businessId)
        } catch {
            productRemoveError = error.localizedDescription
        }
    }

    private func productRow(_ p: FincasProduct) -> some View {
        let shown = (p.presentations ?? []).filter { $0.visible != false }
        let photos = productPhotos(p)
        return HStack(alignment: .top, spacing: 12) {
            // La foto abre el mismo visor de pantalla completa que las demás fotos.
            Button {
                if !photos.isEmpty { productViewer = ProductPhotoSet(photos: photos, productId: p.id) }
            } label: {
                CachedImage(urlString: p.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "bag").foregroundStyle(Color.brand)
                }
                .frame(width: 64, height: 64)
                .background(Color.paleSage)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .photoZoomSource(id: "product-\(p.id)", in: productZoom)
            .disabled(photos.isEmpty)
            .accessibilityLabel("Ver fotos de \(p.name)")
            Button { askAbout(p) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(p.name).font(BT.footnoteBold).foregroundStyle(Color.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                            .frame(width: 32, height: 32)
                            .background(Color.sageTint, in: Circle())
                    }
                    ForEach(shown) { pr in
                        HStack {
                            Text(pr.label).font(BT.caption1).foregroundStyle(Color.inkMuted)
                            Spacer()
                            if let price = pr.price {
                                Text(String(format: "S/ %.2f", price)).font(BT.footnoteBold).foregroundStyle(Color.brand)
                            }
                        }
                    }
                    Text("Toca para preguntar").font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preguntar por \(p.name)")
        }
        .padding(12)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 14))
    }

    struct ProductPhotoSet: Identifiable { let id = UUID(); let photos: [String]; var productId: String = ""; var start: Int = 0 }

    /// Fotos de todos los productos, en el orden de las tarjetas y sin repetir.
    private var allProductPhotos: [String] {
        var out: [String] = []
        for e in productEntries {
            // Una foto por tarjeta, la misma que se ve en el panel (Keyla, 24 Nov
            // 2026): antes salían también la portada y las demás fotos del producto.
            if let u = presCover(e.product, e.pres), !u.isEmpty, !out.contains(u) { out.append(u) }
        }
        return out
    }
    @State private var productViewer: ProductPhotoSet? = nil
    @State private var productShownId: String? = nil
    @State private var ownerEditRoute: FincasProductRoute? = nil
    @State private var openingProductId: String? = nil

    /// El editor necesita la versión del dueño (stock, estado, fotos): se pide a
    /// la tienda y se abre el mismo "Editar producto" de Negocio > Productos.
    private func openOwnerEditor(_ p: FincasProduct, pres: FincasProduct.Presentation? = nil) async {
        guard let ctx = editCtx, openingProductId == nil else { return }
        openingProductId = p.id
        defer { openingProductId = nil }
        if let page = try? await FincasAuth.products(farmId: ctx.businessId, offset: 0, limit: 50),
           let mine = page.items.first(where: { $0.id == p.id }) {
            ownerEditRoute = FincasProductRoute(farmId: ctx.businessId, product: mine, focusPresentationId: pres?.id)
        } else {
            productRemoveError = "No pudimos abrir el producto. Revisa tu conexión."
        }
    }

    private func entryId(_ p: FincasProduct, _ pr: FincasProduct.Presentation?) -> String {
        pr.map { "\(p.id)-\($0.id)" } ?? p.id
    }

    /// La tarjeta a la que pertenece una foto: primero la de su presentación,
    /// si no, la primera tarjeta de su producto.
    private func entryFor(photo url: String) -> String? {
        if let e = productEntries.first(where: { presCover($0.product, $0.pres) == url }) { return e.id }
        return productEntries.first(where: { productPhotos($0.product).contains(url) })?.id
    }
    /// Las fotos de un producto crecen desde su miniatura y vuelven a ella (iOS 18+).
    @Namespace private var productZoom

    /// Todas las fotos del producto, sin repetir: portada y las de cada presentación.
    private func productPhotos(_ p: FincasProduct) -> [String] {
        var out: [String] = []
        var all: [String?] = [p.coverUrl]
        for pr in p.presentations ?? [] {
            all += (pr.photos ?? []).map { Optional($0.url) }
            all.append(pr.photoUrl)
        }
        for u in all { if let u, !u.isEmpty, !out.contains(u) { out.append(u) } }
        return out
    }

    private func loadProducts() async {
        productsState = .loading
        do {
            let page = try await APIClient.shared.fetchSpotProducts(spotId: place.id.uuidString.lowercased())
            products = page.items
            productsState = page.linked == false ? .notLinked : .loaded
            // Con productos, la ficha abre en Productos; sin ellos, en Información.
            // Sin productos abre en Fotos (Keyla, 24 Nov 2026).
            if products.isEmpty && !userPickedTab && tab == .productos { tab = .fotos }
            openFocusedProductViewer()
        } catch {
            dlog("🛍️ [PlaceProducts] \(error)")
            products = []
            if !userPickedTab && tab == .productos { tab = .fotos }
            // Integración apagada (404) o sin dueño: se muestra como "aún no muestra productos".
            productsState = .notLinked
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            // La categoría va justo bajo el nombre (Keyla, 23 Nov 2026).
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.system(.title3).weight(.bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                if let cat = place.categoryName {
                    HStack(spacing: 6) {
                        Image(systemName: CategoryIcon.symbol(for: cat))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brand)
                            .accessibilityHidden(true)
                        Text(cat)
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)

            // Sin local físico no hay botón verde (Keyla, 22 Nov 2026): se pregunta
            // con la burbuja de cada producto o en Información.
            if !actionOpensChat {
            Button {
                guard !justDragged else { return }
                Haptic.light()
                if actionOpensChat { openBusinessChat() } else { onNavigate() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: actionIcon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(actionTitle)
                        .font(BT.footnoteBold)
                }
                .foregroundStyle(Color.inkInverse)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color.brand))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("\(actionTitle): \(place.name)")
            }

            if showsClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.sageTint))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Cerrar")
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Tab bar

    // Ligera a propósito: las fotos son las protagonistas, no la navegación.
    // Sin iconos, sin conteo en la etiqueta — el número vive en el contenido
    // de cada pestaña, no compitiendo aquí arriba.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { t in
                Button {
                    guard !justDragged else { return }
                    Haptic.select()
                    tab = t
                    userPickedTab = true
                } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tab == t ? Color.brand : Color.inkMuted)
                        Rectangle()
                            .fill(tab == t ? Color.brand : Color.clear)
                            .frame(height: 1.5)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                // VoiceOver dice cuál pestaña está elegida (y las pruebas lo leen).
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Fotos

    /// Mismo tamaño que las miniaturas para no romper la fila, y primero: es la
    /// acción, no una foto más.
    /// Al elegir la ubicación de un negocio no se añaden fotos (Keyla, 21 Nov 2026):
    /// sin la tarjeta ni su hueco en la cuadrícula.
    // Solo el dueño del negocio sube fotos aquí (Keyla, 23 Nov 2026: "I'm not
    // Citizen"). Antes también podía quien había recomendado el lugar.
    private var canAddPhoto: Bool { (!startOnPhotos && editCtx != nil) || isRecommending }
    /// Abierto desde "Recomendar un lugar": invita a subir fotos de una vez.
    @Environment(\.recommendPhotosPlaceId) private var recommendPlaceId
    private var isRecommending: Bool {
        recommendPlaceId?.lowercased() == place.id.uuidString.lowercased()
    }

    @ViewBuilder
    private var addPhotoTile: some View {
        if let ctx = editCtx {
            // Dueño en Mi negocio: una sola "Añadir foto", y sus fotos detrás.
            BusinessAddPhotoTile(ctx: ctx)
        } else if isRecommending {
            // Recomendar: la misma tarjeta del dueño, directo al selector de fotos.
            RecommendAddPhotoTile(spotId: place.id.uuidString.lowercased(), side: cardSide, height: photoRowHeight)
        } else if canAddPhoto, let mine = myBuddyRecommendation {
            Button {
                Haptic.medium()
                guard !isOpeningEditor else { return }
                isOpeningEditor = true
                Task {
                    // El editor necesita el APIJourney completo (tripId incluido,
                    // que publishJourney manda); la galería solo trae su id.
                    let journey = try? await APIClient.shared.fetchJourney(id: mine.journeyId)
                    await MainActor.run {
                        isOpeningEditor = false
                        editingJourney = journey
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.surface)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    if isOpeningEditor {
                        ProgressView().tint(Color.inkMuted)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(Color.brand)
                            Text("Añadir foto")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                .frame(width: cardSide, height: photoRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func deletePhoto(_ photo: GalleryPhoto) {
        guard photo.isDeletable, !isDeletingPhoto else { return }
        photoPendingDeletion = nil
        isDeletingPhoto = true
        Task {
            do {
                // El libro local también se toca: sigue siendo lo que se sube al
                // publicar, así que una página que quede en disco volvería.
                if let clientPageId = photo.clientPageId, let uuid = UUID(uuidString: clientPageId) {
                    try await APIClient.shared.deleteJourneyPage(journeyId: photo.journeyId, clientPageId: clientPageId)
                    await MainActor.run { MemoirPersistence.shared.removePage(id: uuid, journeyId: photo.journeyId) }
                } else if let pageIndex = photo.pageIndex {
                    // Foto anterior a client_page_id: no queda otra que el índice.
                    try await APIClient.shared.deleteJourneyPage(journeyId: photo.journeyId, pageIndex: pageIndex)
                    await MainActor.run { MemoirPersistence.shared.removePublishedPage(at: pageIndex, journeyId: photo.journeyId) }
                }
                gallery = try? await APIClient.shared.fetchSpotGallery(spotId: place.id.uuidString)
                await MainActor.run {
                    Haptic.success()
                    // Solo esta foto. Su URL ya no va a aparecer en ninguna
                    // lista, pero la ruta en Storage se recicla —page_N.jpg con
                    // upsert—, así que dejarla cacheada haría que una futura
                    // foto en ese mismo índice se pintara con esta.
                    print("🗑️ [deletePhoto] borrada \(photo.url)")
                    if let url = URL(string: photo.url) { ImageCache.shared.remove(url) }
                    // El Home y el perfil muestran estas mismas fotos y no
                    // tienen forma de enterarse solos: sin este aviso la foto
                    // borrada seguía ahí hasta el próximo arranque.
                    NotificationCenter.default.post(name: .placePhotosChanged, object: photo.journeyId)
                }
            } catch {
                print("❌ [deletePhoto] journey=\(photo.journeyId) page=\(photo.clientPageId ?? photo.pageIndex.map(String.init) ?? "?"): \(error)")
            }
            await MainActor.run { isDeletingPhoto = false }
        }
    }

    @ViewBuilder
    private var fotosTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoadingGallery {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else if allPhotos.isEmpty {
                if canAddPhoto {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            addPhotoTile
                            if let ctx = editCtx { BusinessLocalPhotos(ctx: ctx, onOpen: openPhoto, zoom: photoZoom) }
                        }
                        .padding(.horizontal, 20)
                    }
                } else {
                    emptyState(icon: "photo.on.rectangle.angled", text: "Todavía no hay fotos de este lugar")
                }
            } else if expanded {
                // Pantalla completa: cuadrícula de 3 columnas con TODAS las
                // fotos, sin carrusel lateral (Keyla, 20 Nov 2026).
                ScrollViewReader { proxy in
                // Mismo tamaño de foto abierto y cerrado (Keyla, 23 Nov 2026).
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardSide), spacing: 8, alignment: .top), count: 3), alignment: .leading, spacing: 8) {
                    if canAddPhoto {
                        Color.clear.frame(width: cardSide, height: photoRowHeight).overlay(addPhotoTile)
                    }
                    ForEach(ownerUrls, id: \.self) { url in
                        Button { openPhoto(url) } label: {
                            Color.clear.frame(width: cardSide, height: photoRowHeight)
                                .overlay(CachedImage(urlString: url) { img in img.resizable().scaledToFill() }
                                         placeholder: { Rectangle().fill(Color.sandLight) })
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .photoZoomSource(id: url, in: photoZoom)
                        }
                        .buttonStyle(.plain)
                        .id(url)
                    }
                    ForEach(galleryPhotos.filter { !ownerUrls.contains($0.url) }) { photo in
                        Button {
                            zoomUrl = photo.url; visorFoto = VisorFotoInicio(indice: allPhotos.firstIndex(of: photo.url) ?? 0)
                        } label: {
                            Color.clear.frame(width: cardSide, height: photoRowHeight)
                                .overlay(CachedImage(urlString: photo.url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Rectangle().fill(Color.sandLight) })
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .photoZoomSource(id: photo.url, in: photoZoom)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Foto del lugar")
                        .accessibilityIdentifier("placePhoto")
                        .id(photo.url)
                        .contextMenu {
                            if photo.isMine, photo.isDeletable {
                                Button(role: .destructive) { photoPendingDeletion = photo } label: {
                                    Label("Eliminar foto", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
                .onChange(of: zoomUrl) { _, url in
                    // La miniatura de la foto que se ve, en pantalla (Keyla, 21 Nov 2026).
                    guard visorFoto != nil, let url else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(url, anchor: .center) }
                }
                }
            } else {
                // Sin "Ver todas": tocar cualquier foto abre el visor, y ahí
                // se recorren TODAS (no solo las de esta fila).
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        addPhotoTile
                        if let ctx = editCtx { BusinessLocalPhotos(ctx: ctx, side: cardSide, height: photoRowHeight, onOpen: openPhoto, zoom: photoZoom) }
                        else { OwnerPhotosRow(spotId: place.id.uuidString.lowercased(), side: cardSide, height: photoRowHeight, onOpen: openPhoto, zoom: photoZoom) }

                        ForEach(galleryPhotos) { photo in
                            Button {
                                guard !justDragged else { return }
                                zoomUrl = photo.url; visorFoto = VisorFotoInicio(indice: allPhotos.firstIndex(of: photo.url) ?? 0)
                            } label: {
                                CachedImage(urlString: photo.url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(Color.sandLight)
                                }
                                .frame(width: cardSide, height: photoRowHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .photoZoomSource(id: photo.url, in: photoZoom)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Foto del lugar")
                            .accessibilityIdentifier("placePhoto")
                            .id(photo.url)
                            // Solo sobre las propias: el menú de una foto ajena
                            // no tendría ninguna acción que ofrecer. El
                            // long-press y no un botón visible porque borrar es
                            // excepcional y no debe competir con mirar.
                            .contextMenu {
                                if photo.isMine, photo.isDeletable {
                                    Button(role: .destructive) {
                                        photoPendingDeletion = photo
                                    } label: {
                                        Label("Eliminar foto", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: zoomUrl) { _, url in
                    // La miniatura de la foto que se ve, en pantalla (Keyla, 21 Nov 2026).
                    guard visorFoto != nil, let url else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(url, anchor: .center) }
                }
                }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    // MARK: Info

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Aún no hay horario, precios ni contacto guardados: no se muestran
            // filas "Por confirmar". Si el lugar tiene negocio, la acción es
            // preguntarle, con el mismo estilo de fila (Keyla, 20 Nov 2026).
            if let ctx = editCtx {
                BusinessPanelAbout(ctx: ctx)
                CoverageEditor(ctx: ctx).padding(.top, 8)
            } else if productsState == .loaded {
                askBusinessButton
            } else if place.description.isEmpty {
                Text("Aún no hay información de este lugar.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                    .padding(.vertical, 6)
            }

            if editCtx == nil { CoverageRow(spotId: place.id.uuidString.lowercased()) }

            if !place.description.isEmpty {
                Text(place.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
            }

            Divider()

            if HomeRowsView.showsBuddyTools {
            if place.isCollected {
                Label("Ya desbloqueaste el recuerdo de este lugar", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.teal)
            } else {
                Label("Aquí desbloqueas un recuerdo", systemImage: "sparkles")
                    .font(.system(size: 13)).foregroundStyle(Color.sand)
            }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Buddies

    @ViewBuilder
    private var buddiesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if destinationId == nil {
                emptyState(icon: "person.2", text: "No pudimos ubicar los buddies de este lugar")
            } else if isLoadingBuddies {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else if buddies.isEmpty {
                emptyState(icon: "person.2", text: "Todavía no hay buddies en este destino")
            } else {
                ForEach(Array(buddies.enumerated()), id: \.offset) { i, buddy in
                    if i > 0 { Divider().padding(.leading, 66) }
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            CachedImage(urlString: buddy.avatarUrl) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.sandLight)
                                    .overlay(Text(buddy.initial).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink))
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())

                            if buddy.isAvailable == true {
                                Circle().fill(Color.onlineGreen).frame(width: 11, height: 11)
                                    .overlay(Circle().strokeBorder(Color.surface, lineWidth: 2))
                            }
                        }
                        Text(buddy.fullName ?? "Buddy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.horizontal, 40)
    }
}

/// "Ver todas" desde la pestaña Fotos — grid simple de TODAS las fotos ya
/// cargadas (no vuelve a pedirlas al server). Tocar una la abre en grande.
struct PlaceFullGallerySheet: View {
    let placeName: String
    let photos: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var visorFoto: VisorFotoInicio? = nil
    @Namespace private var photoZoom
    @State private var zoomIndex = 0
    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { i, url in
                        // La celda la define un cuadrado vacío y la foto va
                        // ENCIMA, recortada a él. Con la foto como celda,
                        // scaledToFill la dejaba medir lo que quisiera y cada
                        // una se desbordaba sobre sus vecinas.
                        Color.sandLight
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                CachedImage(urlString: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.sandLight
                                }
                            }
                            .clipped()
                            .contentShape(Rectangle())
                            .photoZoomSource(id: i, in: photoZoom)
                            .onTapGesture { zoomIndex = i; visorFoto = VisorFotoInicio(indice: i) }
                    }
                }
            }
            .navigationTitle(placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolbarBackButton { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $visorFoto) { inicio in
            PlacePhotoViewer(photos: photos, inicial: inicio.indice, systemDismiss: PhotoZoom.systemAvailable,
                             onShowing: { zoomIndex = $0 })
                .photoZoomDestination(id: zoomIndex, in: photoZoom)
        }
    }
}

/// Con qué foto se abre el visor.
struct VisorFotoInicio: Identifiable {
    let indice: Int
    var id: Int { indice }
}

/// Visor de fotos a pantalla completa. Mismo paginador VERTICAL que el feed
/// del Home: tres fotos, un gesto = una foto, y el ciclo es aritmético
/// (módulo), así que después de la última viene la primera, sin fin.
/// La foto se ve ENTERA (scaledToFit): acá se mira el lugar, no se decora.
struct PlacePhotoViewer: View {
    // Mismo comportamiento que el visor de trips (Keyla, 21 Nov 2026: "homogenized
    // behavior"): deslizar de lado cambia de foto (ya no hacia arriba/abajo),
    // toque izquierda/derecha, pellizcar o doble toque para el zoom, deslizar
    // hacia abajo cierra, miniaturas abajo y la X arriba.
    let photos: [String]
    let inicial: Int

    @Environment(\.dismiss) private var dismiss
    @State private var current: Int
    @State private var drag: CGSize = .zero
    @State private var fading = false
    @State private var zoomed = false
    /// true con transición nativa de zoom (iOS 18+): el sistema cierra hacia abajo.
    var systemDismiss = false
    /// Avisa qué foto se ve: al cerrar vuelve a SU miniatura.
    var onShowing: (Int) -> Void = { _ in }

    /// Datos de la foto que se ve, arriba (Keyla, 23 Nov 2026: en productos,
    /// nombre, precio y tamaño, como el autor y el lugar en una publicación).
    var caption: ((Int) -> (title: String, detail: String?)?)? = nil
    /// Arrastre propio, pero al cerrar vuelve con zoom a la miniatura.
    var zoomsBack = false

    init(photos: [String], inicial: Int, systemDismiss: Bool = false, zoomsBack: Bool = false, onShowing: @escaping (Int) -> Void = { _ in },
         caption: ((Int) -> (title: String, detail: String?)?)? = nil) {
        self.zoomsBack = zoomsBack
        self.photos = photos
        self.inicial = inicial
        self.systemDismiss = systemDismiss
        self.onShowing = onShowing
        self.caption = caption
        _current = State(initialValue: photos.indices.contains(inicial) ? inicial : 0)
    }

    private var backdrop: Double { fading ? 0 : PhotoDismissPhysics.backdrop(forDrag: drag.height) }
    private var shrink: CGFloat { PhotoDismissPhysics.scale(forDrag: drag.height) }
    private var chrome: Double { zoomed || fading ? 0 : max(0, 1 - Double(max(drag.height, 0)) / 150) }

    private var overlayBars: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if photos.count > 1 { thumbStrip }
        }
        .opacity(chrome)
        .allowsHitTesting(!zoomed)
        .animation(.easeInOut(duration: 0.2), value: zoomed)
    }

    private func prefetchAround(_ n: Int) {
        let near = [n + 1, n - 1].filter { photos.indices.contains($0) }
        ImagePrefetcher.prefetch(near.map { photos[$0] })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backdrop).ignoresSafeArea()
            pager.offset(drag).scaleEffect(shrink)
            overlayBars
        }
        .statusBarHidden()
        .presentationBackground(.clear)
        .simultaneousGesture(closeDrag)
        .onChange(of: current) { _, n in prefetchAround(n); onShowing(n) }
        .accessibilityAction(named: "Siguiente foto") { step(1) }
        .accessibilityAction(named: "Foto anterior") { step(-1) }
    }

    private var pager: some View {
        TabView(selection: $current) {
            ForEach(Array(photos.enumerated()), id: \.offset) { i, url in
                ZoomablePhoto(urlString: url,
                              onZoomChange: { zoomed = $0 },
                              onTap: { x in step(x < 0.5 ? -1 : 1) })
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    /// La foto sigue al dedo, se achica y el fondo se aclara; al soltar, cierra
    /// por distancia o por un deslizar rápido, o vuelve a su lugar (Keyla, 21 Nov 2026).
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { v in
                guard !zoomed, !systemDismiss, v.translation.height > 0,
                      abs(v.translation.height) > abs(v.translation.width) || drag != .zero else { return }
                drag = v.translation
            }
            .onEnded { v in
                guard !zoomed, !systemDismiss, drag != .zero else { return }
                if PhotoDismissPhysics.shouldDismiss(dy: v.translation.height, predictedDy: v.predictedEndTranslation.height) {
                    closeSmoothly()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { drag = .zero }
                }
            }
    }

    private func closeSmoothly() {
        // Con miniatura de origen: la transición de zoom lleva la foto desde
        // donde está el dedo hasta su miniatura, sin bajar primero (Keyla, 25 Nov 2026).
        if systemDismiss || zoomsBack { dismiss(); return }
        withAnimation(.easeOut(duration: 0.22)) { drag.height += 260; fading = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    private func step(_ d: Int) {
        let n = current + d
        guard photos.indices.contains(n) else { if d > 0 { closeSmoothly() }; return }
        Haptic.light()
        withAnimation(.easeInOut(duration: 0.25)) { current = n }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if let info = caption?(current) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    let count = photos.count > 1 ? "\(current + 1) de \(photos.count)" : nil
                    let line = [info.detail, count].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            } else if photos.count > 1 {
                Text("\(current + 1) de \(photos.count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { closeSmoothly() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private var thumbStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { i, url in
                        CachedImage(urlString: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.white.opacity(0.1) }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(i == current ? Color.white : .clear, lineWidth: 2))
                        .opacity(i == current ? 1 : 0.55)
                        .id(i)
                        .onTapGesture { Haptic.light(); withAnimation { current = i } }
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 12)
            }
            .onChange(of: current) { _, n in withAnimation { proxy.scrollTo(n, anchor: .center) } }
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }
}

/// Rectángulo lat/lng para el mapa estilo Airbnb.
struct SpotBounds {
    let minLat: Double, minLng: Double, maxLat: Double, maxLng: Double
    var truncated = false

    init(minLat: Double, minLng: Double, maxLat: Double, maxLng: Double, truncated: Bool = false) {
        self.minLat = minLat; self.minLng = minLng
        self.maxLat = maxLat; self.maxLng = maxLng
        self.truncated = truncated
    }

    /// La región visible, agrandada `scale` veces alrededor de su centro.
    init(region: MKCoordinateRegion, scale: Double) {
        let halfLat = region.span.latitudeDelta  * scale / 2
        let halfLng = region.span.longitudeDelta * scale / 2
        self.init(minLat: region.center.latitude  - halfLat, minLng: region.center.longitude - halfLng,
                  maxLat: region.center.latitude  + halfLat, maxLng: region.center.longitude + halfLng)
    }

    func contains(_ o: SpotBounds) -> Bool {
        o.minLat >= minLat && o.maxLat <= maxLat && o.minLng >= minLng && o.maxLng <= maxLng
    }
}


// MARK: – Preguntar al negocio (chat viajero ↔ negocio, Keyla 20 Nov 2026)

/// Qué abrir: el viajero llega desde un lugar (spotId) con una tarjeta; el
/// negocio llega desde su bandeja con el id de la conversación.
struct BusinessChatTarget: Identifiable, Hashable {
    var id: String { conversationId ?? spotId ?? UUID().uuidString }
    var spotId: String? = nil
    var conversationId: String? = nil
    var title: String
    var card: BizCard? = nil
}

struct BusinessChatView: View {
    let target: BusinessChatTarget
    @Environment(\.dismiss) private var dismiss
    @State private var conversationId: String? = nil
    @State private var messages: [BizMessage] = []
    @State private var side = "traveler"
    @State private var pendingCard: BizCard? = nil
    @State private var text = ""
    @State private var sending = false
    @State private var errorText: String? = nil
    @State private var loading = true
    @State private var blocked = false
    @State private var blockedByMe = false
    @State private var confirmBlock = false
    @State private var noticeText: String? = nil
    /// Perfil del visitante (lado negocio) y foto de la tarjeta a pantalla completa (Keyla, 25 Nov 2026).
    @State private var travelerId: String? = nil
    @State private var showProfile = false
    @State private var cardPhoto: BizCard? = nil
    @Namespace private var cardZoom
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if loading {
                                ProgressView().tint(Color.brand).padding(.top, 40)
                            } else if messages.isEmpty {
                                Text(side == "traveler"
                                     ? "Escribe tu pregunta. El negocio te responderá aquí."
                                     : "Aún no hay mensajes.")
                                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 40).padding(.horizontal, Spacing.xl)
                            }
                            ForEach(messages) { m in
                                bubble(m).id(m.id)
                            }
                        }
                        .padding(.horizontal, Spacing.edge).padding(.vertical, Spacing.md)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
            .background(Color.canvas)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showProfile) {
                if let travelerId { TravelerProfileView(travelerId: travelerId, previewName: target.title) }
            }
            // El mismo visor de los productos: nombre, precio y tamaño arriba,
            // deslizar hacia abajo cierra (Keyla, 25 Nov 2026).
            .fullScreenCover(item: Binding(get: { cardPhoto.flatMap { c in c.imageUrl.map { PhotoURL(url: $0, card: c) } } },
                                           set: { if $0 == nil { cardPhoto = nil } })) { p in
                PlacePhotoViewer(photos: [p.url], inicial: 0, systemDismiss: false, zoomsBack: PhotoZoom.systemAvailable, caption: { _ in
                    let detail = [p.card.price, p.card.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    return (p.card.title, detail.isEmpty ? nil : detail)
                })
                // Crece desde la miniatura de la tarjeta y vuelve a ella al cerrar.
                .photoZoomDestination(id: p.url, in: cardZoom)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ToolbarBackButton { dismiss() } }
                if side == "business", travelerId != nil {
                    ToolbarItem(placement: .principal) {
                        Button { showProfile = true } label: {
                            Text(target.title).font(.headline).foregroundStyle(Color.ink)
                        }
                        .accessibilityHint("Ver perfil")
                    }
                }
                // Reportar y bloquear (App Store 1.2, contenido de usuarios).
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Menu("Reportar") {
                            ForEach(APIClient.bizReportReasons, id: \.code) { r in
                                Button(r.label) { Task { await report(r.code) } }
                            }
                        }
                        if !blocked {
                            Button(role: .destructive) { confirmBlock = true } label: {
                                Label("Bloquear", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(conversationId == nil)
                    .accessibilityLabel("Más opciones")
                }
            }
            .alert(side == "traveler" ? "¿Bloquear a este negocio?" : "¿Bloquear a esta persona?", isPresented: $confirmBlock) {
                Button("Cancelar", role: .cancel) {}
                Button("Bloquear", role: .destructive) { Task { await block() } }
            } message: {
                Text("Ya no podrán escribirse en esta conversación y desaparecerá de tu lista.")
            }
        }
        .task { await open() }
        .task(id: conversationId) {
            // Mientras la pantalla está abierta se revisan respuestas nuevas.
            while !Task.isCancelled, conversationId != nil {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await reload()
            }
        }
    }

    // MARK: Burbujas

    @ViewBuilder
    private func bubble(_ m: BizMessage) -> some View {
        let mine = m.senderRole == side
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if let card = m.card { cardView(card) }
            Text(m.body)
                .font(.system(size: 16))
                .foregroundStyle(mine ? Color.inkInverse : Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(mine ? Color.brand : Color.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 48)
    }

    private func cardView(_ c: BizCard) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: c.imageUrl.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: {
                Image(systemName: c.kind == "product" ? "bag" : "storefront").foregroundStyle(Color.brand)
            }
            .frame(width: 48, height: 48)
            .background(Color.paleSage)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .photoZoomSource(id: c.imageUrl ?? "", in: cardZoom)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.kind == "product" ? "Pregunta sobre este producto" : "Consulta sobre este lugar")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
                Text(c.title).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(2)
                if let line = [c.subtitle, c.price].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line).font(BT.caption1).foregroundStyle(Color.brand)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.hairline, lineWidth: 1))
        // Toda la tarjeta abre la foto a pantalla completa (Keyla, 25 Nov 2026).
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if c.imageUrl != nil { cardPhoto = c } }
        .accessibilityAddTraits(c.imageUrl == nil ? [] : .isButton)
    }

    // MARK: Escribir

    @ViewBuilder
    private var composer: some View {
        if blocked {
            VStack(spacing: 6) {
                if let noticeText { Text(noticeText).font(BT.caption1).foregroundStyle(Color.brand) }
                Text(blockedByMe ? "Bloqueaste esta conversación." : "Esta conversación ya no recibe mensajes.")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.edge).padding(.vertical, 16)
            .background(Color.canvas)
        } else {
            writer
        }
    }

    private var writer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pendingCard {
                HStack(spacing: 8) {
                    cardView(pendingCard)
                    Button { self.pendingCard = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.inkMuted)
                            .frame(width: 32, height: 32).background(Color.sageTint, in: Circle())
                    }
                    .accessibilityLabel("Quitar tarjeta")
                }
            }
            if let noticeText { Text(noticeText).font(BT.caption1).foregroundStyle(Color.brand) }
            if let errorText { Text(errorText).font(BT.caption1).foregroundStyle(Color.errorRed) }
            HStack(spacing: 8) {
                TextField(side == "traveler" ? "Escribe tu pregunta…" : "Escribe tu respuesta…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .font(BT.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
                Button { Task { await send() } } label: {
                    Group {
                        if sending { ProgressView().tint(Color.inkInverse) }
                        else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) }
                    }
                    .foregroundStyle(Color.inkInverse)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Color.brand : Color.inkMuted.opacity(0.4), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Enviar")
            }
        }
        .padding(.horizontal, Spacing.edge).padding(.vertical, 10)
        .background(Color.canvas)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && conversationId != nil
    }

    // MARK: Datos

    private func open() async {
        pendingCard = target.card
        do {
            if let id = target.conversationId {
                conversationId = id
            } else if let spotId = target.spotId {
                conversationId = try await APIClient.shared.startBusinessChat(spotId: spotId).id
            }
            await reload()
            // Si ya se mandó una tarjeta igual, no se repite.
            if let c = pendingCard, messages.contains(where: { $0.card == c }) { pendingCard = nil }
            focused = true
        } catch {
            errorText = message(for: error)
        }
        loading = false
    }

    private func reload() async {
        guard let id = conversationId,
              let thread = try? await APIClient.shared.businessChatMessages(conversationId: id) else { return }
        side = thread.side
        if let t = thread.conversation?.travelerId { travelerId = t }
        blocked = thread.blocked ?? false
        blockedByMe = thread.blockedByMe ?? false
        if thread.messages != messages { messages = thread.messages }
    }

    private func report(_ reason: String) async {
        guard let id = conversationId else { return }
        errorText = nil
        do {
            try await APIClient.shared.reportBusinessChat(conversationId: id, reason: reason)
            noticeText = "Gracias. Revisaremos este reporte."
            Haptic.success()
        } catch {
            errorText = "No pudimos enviar el reporte. Intenta de nuevo."
        }
    }

    private func block() async {
        guard let id = conversationId else { return }
        errorText = nil
        do {
            try await APIClient.shared.blockBusinessChat(conversationId: id)
            blocked = true; blockedByMe = true
            focused = false
            Haptic.success()
        } catch {
            errorText = "No pudimos bloquear. Intenta de nuevo."
        }
    }

    private func send() async {
        guard let id = conversationId else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        errorText = nil
        defer { sending = false }
        do {
            let m = try await APIClient.shared.sendBusinessChat(conversationId: id, body: body, card: pendingCard)
            messages.append(m)
            text = ""
            pendingCard = nil
            Haptic.success()
        } catch {
            errorText = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        // Mensajes del servidor en español (p. ej. "Este es tu negocio"); los técnicos no se muestran.
        if case APIError.server(_, let msg) = error, !msg.isEmpty,
           !["Unknown error", "Route not found", "Not found", "Unauthorized", "Error interno"].contains(msg) { return msg }
        return "No pudimos enviar. Revisa tu conexión e intenta de nuevo."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


/// Mientras el visor de productos está abierto, la fila (o la cuadrícula) se
/// mueve sin animación hasta la tarjeta de la foto que se ve, para que al
/// cerrar la foto vuelva a su miniatura (Keyla, 23 Nov 2026).
private struct FollowProductViewer: ViewModifier {
    let shownId: String?
    let active: Bool
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: shownId) { _, id in
                guard active, let id else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}


/// Una presentación de un producto en la fila "Productos locales" de Inicio.
struct LocalProductTile: Identifiable {
    let id: String
    let card: APIPlaceCard
    let product: FincasProduct
    let pres: FincasProduct.Presentation?
}

/// Cara de la tarjeta de producto del panel (foto cuadrada, nombre, precio y
/// tamaño). Inicio la usa para que el producto se vea igual en los dos lugares.
struct ProductCardFace: View {
    let product: FincasProduct
    let pres: FincasProduct.Presentation?
    var side: CGFloat = 114

    private var cover: String? {
        guard let pr = pres else { return product.coverUrl }
        let own = pr.photos?.first?.url ?? pr.photoUrl
        return (own?.isEmpty == false ? own : nil) ?? product.coverUrl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedImage(urlString: cover) { img in img.resizable().scaledToFill() }
                placeholder: { Image(systemName: "bag").foregroundStyle(Color.brand) }
                .frame(width: side, height: side)
                .background(Color.paleSage)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(product.name).font(BT.caption1).foregroundStyle(Color.ink).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let price = pres?.price ?? (product.presentations ?? []).filter({ $0.visible != false }).compactMap(\.price).min() {
                    Text(PlaceGuideDetailSheet.soles(price)).font(BT.footnoteBold).foregroundStyle(Color.brand)
                }
                if let label = pres?.label, !label.isEmpty {
                    Text(label).font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: side, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}


/// Producto elegido en la fila "Productos locales" de Inicio: el panel del lugar
/// lo muestra primero. Se consume una vez al abrir el panel.
enum ProductFocus {
    private static var pending: (spotId: String, entryId: String, at: Date)?
    static func set(spotId: String, productId: String, presentationId: String?) {
        pending = (spotId.lowercased(), presentationId.map { "\(productId)-\($0)" } ?? productId, Date())
    }
    /// Solo vale unos segundos: si el lugar se abre por otro camino más tarde, no aplica.
    static func take() -> String? {
        defer { pending = nil }
        guard let p = pending, Date().timeIntervalSince(p.at) < 10 else { return nil }
        return p.entryId
    }
}

private struct PhotoURL: Identifiable { let url: String; let card: BizCard; var id: String { url } }


// MARK: - Recomendar con fotos (sin editor)

private struct RecommendPhotosPlaceIdKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// Lugar abierto desde "Recomendar un lugar" (Keyla, 25 Nov 2026).
    var recommendPhotosPlaceId: String? {
        get { self[RecommendPhotosPlaceIdKey.self] }
        set { self[RecommendPhotosPlaceIdKey.self] = newValue }
    }
}

/// "Añadir foto" para quien recomienda: la tarjeta punteada del dueño
/// (DashedAddTile) que abre el selector de fotos. Al elegir, se crea la
/// recomendación (o se reusa la que ya tiene) y se suben las fotos en segundo
/// plano con el aviso de subida.
struct RecommendAddPhotoTile: View {
    let spotId: String
    var side: CGFloat = 115
    var height: CGFloat = 115
    @State private var items: [PhotosPickerItem] = []
    @State private var working = false

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: 10, matching: .images) {
            DashedAddTile(title: "Añadir foto", loading: working, side: side)
                .frame(width: side, height: height)
        }
        .buttonStyle(.plain)
        .disabled(working)
        .onChange(of: items) { _, new in
            guard !new.isEmpty else { return }
            working = true
            Task {
                var images: [UIImage] = []
                for item in new {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { images.append(img) }
                }
                do {
                    let journey = try await APIClient.shared.createJourney(
                        destinationId: nil, placeId: nil, spotId: spotId, lat: nil, lng: nil, attachToTrip: false)
                    let pages = images.compactMap { MemoirPersistence.shared.photoPage($0, journeyId: journey.id) }
                    var all = MemoirPersistence.shared.load(journeyId: journey.id)
                    all.append(contentsOf: pages)
                    MemoirPersistence.shared.save(all, journeyId: journey.id)
                    await MainActor.run { items = []; working = false }
                    try? await APIClient.shared.publishJourney(journeyId: journey.id, tripId: journey.tripId, pages: pages)
                    await MainActor.run {
                        Haptic.success()
                        NotificationCenter.default.post(name: .journeyPublished, object: journey.id)
                    }
                } catch {
                    await MainActor.run { items = []; working = false }
                }
            }
        }
        .accessibilityLabel("Añadir foto")
    }
}
