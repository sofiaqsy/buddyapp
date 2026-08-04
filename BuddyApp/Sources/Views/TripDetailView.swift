import SwiftUI
import MapKit

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

    init(route: Route, match: APIMatch? = nil, journey: APIJourney? = nil, unreadCount: Int = 0, destinationId: String? = nil, focusPlaceId: String? = nil) {
        self.route = route
        self.match = match
        self.journey = journey
        self.unreadCount = unreadCount
        self.destinationId = destinationId
        self.focusPlaceId = focusPlaceId
        // Si el destino no tiene spots curados, centrar el mapa en las coords explícitas
        // desde el inicio — sin esperar el delay de fitMap().
        if route.places.isEmpty, let center = route.explicitCenter {
            print("🗺️ [TripDetailView.init] places=0 explicitCenter=(\(center.latitude),\(center.longitude)) → camera centrada en destino")
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )))
        } else {
            print("🗺️ [TripDetailView.init] places=\(route.places.count) centerLat=\(route.centerLat.map{String($0)} ?? "nil") → camera=.automatic")
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
    private var livePlaces: [Place] { routeStore.route.places }
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

        // Foco explícito (se abrió este mapa desde la tarjeta de UN lugar):
        // seleccionarlo y centrar ahí en vez de esperar el fitMap() genérico,
        // que encuadraría TODOS los pines del destino.
        if let focusPlaceId, let match = livePlaces.first(where: { $0.id.uuidString.caseInsensitiveCompare(focusPlaceId) == .orderedSame }) {
            await MainActor.run {
                withAnimation(.easeInOut) { selectedPlace = match }
                withAnimation(.easeInOut(duration: 0.6)) {
                    camera = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    ))
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fitMap() }
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

    private func loadMore() {
        guard hasMorePlaces else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            visibleCount = min(visibleCount + pageSize, livePlaces.count)
        }
    }

    private let sheetHeight: CGFloat = 265
    private let contentHeight: CGFloat = 160
    /// El mapa hace full-bleed (ignoresSafeArea), así que el panel queda anclado al
    /// fondo absoluto y la tab bar flotante lo tapa. Subimos el contenido esta cantidad
    /// (tab bar + home indicator) y extendemos el glass por debajo, detrás de la tab bar.
    private let bottomClearance: CGFloat = 38

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                mapView
                    .ignoresSafeArea()

                backAndShareBar
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                bottomSection(geo: geo)
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
            ForEach(displayedPlaces.sorted { !$0.featured && $1.featured }) { place in
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
            UserAnnotation()
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
            .frame(width: 44)
            .padding(.trailing, 16)
            .padding(.bottom, sheetHeight + bottomClearance + 42)
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
            Button("Google Maps") { openInGoogleMaps() }
            Button("Waze") { openInWaze() }
            Button("Apple Maps") { openInAppleMaps() }
            Button("Cancelar", role: .cancel) { navigationTarget = nil }
        }
    }

    // MARK: – Navegación externa (Google Maps / Waze / Apple Maps)

    /// Mismo criterio que Waze: esquema propio primero, web de respaldo.
    ///
    /// El universal link de Google Maps sí conserva los parámetros al saltar,
    /// así que aquí no había el fallo de Waze — pero sí compartía el riesgo del
    /// locale, y `comgooglemaps://` ahorra el rebote por el navegador.
    private func openInGoogleMaps() {
        guard let p = navigationTarget else {
            print("🧭 [ComoLlegar] googleMaps — navigationTarget=nil, no se abre nada")
            return
        }
        let ll = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"),
                        p.latitude, p.longitude)
        print("🧭 [ComoLlegar] googleMaps → place=\(p.name) ll=\(ll)")

        let nativa = URL(string: "comgooglemaps://?daddr=\(ll)&directionsmode=driving")!
        UIApplication.shared.open(nativa) { ok in
            if ok {
                print("🧭 [ComoLlegar] googleMaps ✅ abierto con esquema nativo")
                return
            }
            let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(ll)&travelmode=driving")!
            print("🧭 [ComoLlegar] googleMaps — sin app instalada, abriendo web")
            UIApplication.shared.open(web) { ok2 in
                print(ok2 ? "🧭 [ComoLlegar] googleMaps ✅ abierto en web" : "🧭 [ComoLlegar] googleMaps ❌ open falló")
            }
        }
    }

    /// Waze: primero su esquema propio, y el universal link solo como respaldo.
    ///
    /// Con `https://waze.com/ul?...` la app abría pero SIN destino. El universal
    /// link pasa antes por el navegador —o por el resolutor de enlaces de iOS—, y
    /// en ese salto Waze recibe el arranque pero pierde los parámetros; el
    /// resultado es Waze en el mapa, sin ruta, que es justo lo que se veía.
    /// `waze://` va directo al proceso y llega con `ll` y `navigate` intactos.
    ///
    /// `open()` no necesita LSApplicationQueriesSchemes —eso solo lo exige
    /// `canOpenURL`—, así que si Waze no está instalado la llamada devuelve
    /// false y ahí sí cae al enlace web, que ofrece instalarlo.
    ///
    /// Coordenadas con `%.6f` y locale POSIX: son ~11 cm de precisión, de sobra
    /// para un local, y sobre todo evitan que un dispositivo con locale español
    /// escriba "-12,0584" con coma y parta el parámetro en dos.
    private func openInWaze() {
        guard let p = navigationTarget else {
            print("🧭 [ComoLlegar] waze — navigationTarget=nil, no se abre nada")
            return
        }
        let ll = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"),
                        p.latitude, p.longitude)
        print("🧭 [ComoLlegar] waze → place=\(p.name) ll=\(ll)")

        let nativa = URL(string: "waze://?ll=\(ll)&navigate=yes")!
        UIApplication.shared.open(nativa) { ok in
            if ok {
                print("🧭 [ComoLlegar] waze ✅ abierto con esquema nativo")
                return
            }
            let web = URL(string: "https://waze.com/ul?ll=\(ll)&navigate=yes")!
            print("🧭 [ComoLlegar] waze — sin app instalada, abriendo web: \(web.absoluteString)")
            UIApplication.shared.open(web) { ok2 in
                print(ok2 ? "🧭 [ComoLlegar] waze ✅ abierto en web" : "🧭 [ComoLlegar] waze ❌ open falló")
            }
        }
    }

    /// Apple Maps va por MKMapItem y no por URL.
    ///
    /// La URL mezclaba `daddr` con `q`, y Apple ignora `q` cuando hay destino:
    /// el lugar se abría con las coordenadas por título ("-12.0464, -77.0428")
    /// en vez de su nombre. MKMapItem lleva el nombre en el propio objeto, así
    /// que Mapas muestra "El encanto" y ya arranca en modo indicaciones.
    private func openInAppleMaps() {
        guard let p = navigationTarget else {
            print("🧭 [ComoLlegar] appleMaps — navigationTarget=nil, no se abre nada")
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordinate))
        item.name = p.name
        print("🧭 [ComoLlegar] appleMaps → place=\(p.name) lat=\(p.latitude) lng=\(p.longitude)")
        let ok = item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
        print(ok ? "🧭 [ComoLlegar] appleMaps ✅ abierto" : "🧭 [ComoLlegar] appleMaps ❌ open falló")
    }

    // MARK: – Bottom panel

    @ViewBuilder
    private func bottomSection(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if let place = selectedPlace {
                // Mismo panel, contenido reemplazado — nada se levanta encima
                // del mapa. Antes esto abría un .sheet modal; se sentía como
                // una interrupción en vez de una respuesta a tocar el lugar.
                PlaceGuideDetailSheet(
                    place: place,
                    destinationId: resolvedDestinationId,
                    buddyPresenceText: buddyPresenceText,
                    onNavigate: { navigationTarget = place },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = nil } }
                )
            } else {
            // Presencia humana — el corazón de Buddy, antes que los lugares
            if let presence = buddyPresenceText {
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

                    // — Fila accionable estilo Apple Maps
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
            } else {
                Text("Recomendado por buddies")
                    .font(BT.title2)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }

            cardScroll
            }
        }
        // Glass más alto: el contenido (top-aligned) sube sobre la tab bar y el
        // glass sobrante queda detrás de ella → panel flush, sin hueco de mapa.
        // Alto SIEMPRE el mismo (sheetHeight+bottomClearance) — el detalle del
        // lugar se acomoda dentro de este espacio, no lo agranda.
        .frame(width: geo.size.width, height: sheetHeight + bottomClearance, alignment: .top)
        .glassPanel()
        .animation(.easeInOut(duration: 0.25), value: selectedPlace?.id)
    }

    // MARK: – Card scroll

    private var cardScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy → el onAppear de "Ver más" solo dispara al deslizar hasta el final
            LazyHStack(spacing: 10) {
                ForEach(Array(displayedPlaces.enumerated()), id: \.element.id) { i, place in
                    Button {
                        Haptic.select()
                        withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = place }
                        withAnimation(.easeInOut(duration: 0.5)) {
                            camera = .region(MKCoordinateRegion(
                                center: place.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                            ))
                        }
                    } label: {
                        PlacePhotoCard(place: place, index: i)
                    }
                    .buttonStyle(.pressable)
                }

                // Al deslizar hasta aquí se revelan los siguientes 10 (rail + mapa)
                if hasMorePlaces { loadMoreCard }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .frame(height: contentHeight)
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
    private func fitMap() {
        // Encuadra los lugares cargados (primer lote en la carga inicial)
        let coords = displayedPlaces.map(\.coordinate)
        print("🗺️ [fitMap] places=\(livePlaces.count) displayed=\(displayedPlaces.count) route.center=\(route.centerLat.map{String($0)} ?? "nil") routeStore.center=\(routeStore.route.centerLat.map{String($0)} ?? "nil")")
        if coords.isEmpty {
            // Sin spots: centrar en la coordenada explícita. Preferir `route` (prop del view)
            // sobre `routeStore.route` porque este puede ser .placeholder si onChange dispara
            // antes de que termine el fetch.
            let center = route.explicitCenter ?? routeStore.route.explicitCenter
            print("🗺️ [fitMap] sin places → center=\(center.map { "(\($0.latitude),\($0.longitude))" } ?? "NIL — mapa no se mueve")")
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

        let minLat = coords.map(\.latitude).min()!
        let maxLat = coords.map(\.latitude).max()!
        let minLon = coords.map(\.longitude).min()!
        let maxLon = coords.map(\.longitude).max()!

        // 1° lat ≈ 111 km — radius as cap so we never zoom out past the zone
        let radiusKm  = Double(routeStore.route.radiusMeters ?? 5000) / 1000.0
        let maxDeg    = (radiusKm / 111.0) * 2.4   // full diameter + 20 % padding

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
                Image(systemName: "mappin.and.ellipse")
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

    /// El icono del catálogo antes que el del enum: un hotel se ve como una cama
    /// y no como una columna griega. El enum queda de respaldo para los lugares
    /// que aún no tienen categoría curada.
    private var glyph: String { place.categoryIcon ?? place.category.symbol }

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
                    .overlay(Circle().strokeBorder(Color.teal.opacity(isSelected ? 0.9 : 0.3),
                                                   lineWidth: isSelected ? 2 : 1.25))
                    .shadow(color: .black.opacity(0.18), radius: isSelected ? 8 : 3, y: 1.5)
                Image(systemName: glyph)
                    .font(.system(size: isSelected ? 17 : 14, weight: .semibold))
                    .foregroundStyle(Color.teal)
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

struct PlacePhotoCard: View {
    let place: Place
    let index: Int

    private let palettes: [[Color]] = [
        [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
        [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
        [Color(hex: "4A3D35"), Color(hex: "7A6558")],
        [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                // Photo or gradient fallback
                CachedImage(urlString: place.coverUrl) { img in
                    img.resizable().scaledToFill()
                        .frame(width: 145, height: 90)
                        .clipped()
                } placeholder: {
                    gradientFallback
                        .frame(width: 145, height: 90)
                }
                .frame(width: 145, height: 90)
                .clipped()

                // Scrim + emoji overlay
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)

                if place.isCollected {
                    Color.teal.opacity(0.7).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
                }

                // Top de la comunidad — mismo eje que el marker featured
                if place.featured {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 8, weight: .bold))
                        Text("Top").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.teal))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

            }
            .frame(height: 90)

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.system(size: 12, weight: .bold)).foregroundStyle(.primary)
                Text(place.description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Label(place.isCollected ? "Visitado" : "Por visitar",
                      systemImage: place.isCollected ? "checkmark.circle.fill" : "location.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(place.isCollected ? Color.teal : Color.sand)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(width: 145)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .glassRounded(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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
    let onNavigate: () -> Void
    /// Embebido en el panel del mapa (no como sheet): @Environment(\.dismiss)
    /// no tiene nada que cerrar ahí, así que quién lo contiene decide qué
    /// significa "cerrar" (volver a mostrar la lista).
    let onClose: () -> Void

    init(place: Place, destinationId: String?, buddyPresenceText: String?,
         onNavigate: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.place = place
        self.destinationId = destinationId
        self.buddyPresenceText = buddyPresenceText
        self.onNavigate = onNavigate
        self.onClose = onClose
        _galleryVM = StateObject(wrappedValue: SpotGalleryViewModel(spotId: place.id.uuidString))
    }

    private enum Tab: String, CaseIterable {
        case fotos = "Fotos", info = "Info", buddies = "Buddies"
        var icon: String {
            switch self {
            case .fotos:   return "photo.on.rectangle"
            case .info:    return "info.circle"
            case .buddies: return "person.2"
            }
        }
    }
    @State private var tab: Tab = .fotos

    @StateObject private var galleryVM: SpotGalleryViewModel
    @State private var buddies: [APIPlaceBuddy] = []
    @State private var isLoadingBuddies = true
    @State private var showFullGallery = false

    @State private var photoPendingDeletion: GalleryPhoto? = nil
    @State private var isDeletingPhoto = false
    @State private var deleteFailed = false

    /// Mi propia recomendación de este lugar, si soy buddy aprobado. La resuelve
    /// el ViewModel mirando TODAS las páginas cargadas, no solo la primera.
    private var myBuddyRecommendation: APIPlaceVisit? { galleryVM.myVisit }

    @State private var editingJourney: APIJourney? = nil
    @State private var isOpeningEditor = false

    var body: some View {
        // Mismo espacio que ocupaba la lista de tarjetas (~265pt) — nada
        // aquí puede darse el lujo de respirar como en una hoja aparte.
        VStack(alignment: .leading, spacing: 0) {
            header
            if let buddyPresenceText {
                HStack(spacing: 6) {
                    Circle().fill(Color.onlineGreen).frame(width: 6, height: 6)
                    Text(buddyPresenceText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 3)
            }

            tabBar
                .padding(.top, 14)

            ScrollView {
                switch tab {
                case .fotos:   fotosTab
                case .info:    infoTab
                case .buddies: buddiesTab
                }
            }
        }
        .padding(.top, 10)
        .task {
            // La galería la pide el ViewModel: si el lugar ya se abrió antes,
            // pinta lo cacheado sin tocar la red.
            galleryVM.loadFirstPageIfNeeded()
            buddies = await fetchBuddiesIfPossible() ?? []
            isLoadingBuddies = false
        }
        .sheet(isPresented: $showFullGallery) {
            // El VM entero y no un array de URLs: la hoja pagina igual que la
            // fila —una galería de 500 fotos se abre igual de rápido— y como
            // recibe GalleryPhoto tiene la identidad de cada página, así que
            // desde "Ver todas" también se puede borrar. Antes solo se podían
            // borrar las 12 de la fila.
            PlaceFullGallerySheet(placeName: place.name, vm: galleryVM) { photo in
                photoPendingDeletion = photo
            }
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
        .alert("No se pudo eliminar la foto", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Verifica tu conexión e inténtalo de nuevo.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
            // Se publicó una foto nueva: la primera página cacheada quedó vieja.
            galleryVM.refresh()
        }
    }

    private func fetchBuddiesIfPossible() async -> [APIPlaceBuddy]? {
        guard let destinationId else { return nil }
        return try? await APIClient.shared.fetchDestinationBuddies(id: destinationId)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(place.name)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)

            Button {
                Haptic.light()
                onNavigate()
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.inkInverse)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.brand))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cómo llegar a \(place.name)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Tab bar

    // Ligera a propósito: las fotos son las protagonistas, no la navegación.
    // Sin iconos, sin conteo en la etiqueta — el número vive en el contenido
    // de cada pestaña, no compitiendo aquí arriba.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    Haptic.select()
                    tab = t
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
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Fotos

    /// Mismo tamaño que las miniaturas para no romper la fila, y primero: es la
    /// acción, no una foto más.
    @ViewBuilder
    private var addPhotoTile: some View {
        if let mine = myBuddyRecommendation {
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
                .frame(width: 115, height: 115)
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
                await MainActor.run {
                    // Se quita de la lista en vez de refetchear la galería: con
                    // paginación, recargar volvería a la primera página y el
                    // usuario perdería el sitio donde venía desplazando.
                    galleryVM.removeLocally(photo)
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
                // Antes esto solo se imprimía: la foto seguía ahí y el usuario
                // no tenía forma de saber que el borrado no ocurrió.
                await MainActor.run { deleteFailed = true }
            }
            await MainActor.run { isDeletingPhoto = false }
        }
    }

    @ViewBuilder
    private var fotosTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if galleryVM.isLoadingFirstPage {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else if galleryVM.photos.isEmpty {
                if myBuddyRecommendation != nil {
                    HStack { addPhotoTile; Spacer() }.padding(.horizontal, 20)
                } else {
                    emptyState(icon: "photo.on.rectangle.angled", text: "Todavía no hay fotos de este lugar")
                }
            } else {
                // El total del lugar, no el de lo cargado: con paginación
                // "Ver todas" tiene que ofrecerse desde la primera página,
                // aunque acá solo haya 20 de 500.
                if galleryVM.totalPhotos > 6 {
                    HStack {
                        Spacer()
                        Button { showFullGallery = true } label: {
                            HStack(spacing: 2) {
                                Text("Ver todas").font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(Color.brand)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    // LazyHStack y no HStack: el normal construye TODAS las
                    // celdas al aparecer, así que cada foto de la lista arranca
                    // su descarga aunque esté a diez pantallas de distancia. Con
                    // 20 se notaba poco; con 500 es la diferencia entre decenas
                    // de megas y unos pocos.
                    LazyHStack(spacing: 8) {
                        addPhotoTile

                        ForEach(galleryVM.photos) { photo in
                            Button { showFullGallery = true } label: {
                                CachedImage(urlString: photo.url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(Color.sandLight)
                                }
                                .frame(width: 115, height: 115)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
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
                            .onAppear { galleryVM.photoAppeared(photo) }
                        }

                        if galleryVM.hasMore {
                            ProgressView()
                                .frame(width: 60, height: 115)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: Info

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            // La categoría curada del catálogo, no la derivada de place_type.
            // Y solo si existe: antes, un lugar sin clasificar caía en el
            // `default` del mapeo y se anunciaba como "Cultura" — un hotel decía
            // ser cultura. Es mejor no decir nada que decir algo falso, así que
            // sin categoría la fila simplemente no aparece.
            if let name = place.categoryName {
                Label(name, systemImage: place.categoryIcon ?? "mappin.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }

            if !place.description.isEmpty {
                Text(place.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Buddies

    @ViewBuilder
    /// Los buddies del destino, en fila horizontal.
    ///
    /// Antes era una lista vertical con divisores, y esa forma dice "registro":
    /// se lee de arriba abajo, una entrada por renglón, como una tabla. Estos no
    /// son registros — son las personas que están ahí, y en el mapa la pregunta
    /// es "¿quién hay?", no "¿quiénes son, en orden?". La fila responde eso de un
    /// vistazo: caras grandes, todas al mismo nivel, sin jerarquía entre ellas.
    ///
    /// Además la hoja del lugar es baja (~265pt para las tres pestañas). En
    /// vertical entraban dos buddies y medio y el resto quedaba fuera de cuadro
    /// sin nada que lo insinuara; en horizontal el que asoma en el borde derecho
    /// dice solo que hay más.
    private var buddiesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if destinationId == nil {
                emptyState(icon: "person.2", text: "No pudimos ubicar los buddies de este lugar")
            } else if isLoadingBuddies {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else if buddies.isEmpty {
                emptyState(icon: "person.2", text: "Todavía no hay buddies en este destino")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Spacing.lg) {
                        ForEach(Array(buddies.enumerated()), id: \.offset) { _, buddy in
                            // Solo navegable si el servidor mandó a quién: sin id
                            // no hay perfil que abrir, y una cara que no responde
                            // al toque es peor que una que claramente no lo pide.
                            if let id = buddy.travelerId {
                                NavigationLink(value: TravelerProfileRoute(
                                    travelerId: id,
                                    previewName: buddy.fullName,
                                    previewAvatarUrl: buddy.avatarUrl)) {
                                    buddyAvatar(buddy)
                                }
                                .buttonStyle(.plain)
                            } else {
                                buddyAvatar(buddy)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.vertical, Spacing.md)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// Cara + nombre. El ancho fijo es lo que mantiene la fila pareja: sin él,
    /// "Leo Leonardo" ensancha su columna y los círculos dejan de estar a paso
    /// regular, que es justo lo que hace legible una fila de caras.
    private func buddyAvatar(_ buddy: APIPlaceBuddy) -> some View {
        VStack(spacing: Spacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                CachedImage(urlString: buddy.avatarUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.sandLight)
                        .overlay(Text(buddy.initial)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.ink))
                }
                .frame(width: 82, height: 82)
                .clipShape(Circle())

                // El aro del color de fondo separa el punto del avatar: sobre una
                // foto clara, verde contra verde se perdía.
                if buddy.isAvailable == true {
                    Circle().fill(Color.onlineGreen)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.surface, lineWidth: 3))
                }
            }

            Text(buddy.fullName ?? "Buddy")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 92)
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

/// "Ver todas" desde la pestaña Fotos.
///
/// Comparte el ViewModel con la fila en vez de recibir una copia de las URLs:
/// abrirla no vuelve a pedir nada —lo ya paginado está—, y seguir desplazando
/// acá trae las páginas siguientes, que quedan también para la fila al cerrar.
/// Como recibe `GalleryPhoto` y no `String`, cada foto conserva su identidad y
/// se puede borrar desde aquí; antes solo se podían borrar las de la fila.
struct PlaceFullGallerySheet: View {
    let placeName: String
    @ObservedObject var vm: SpotGalleryViewModel
    let onDelete: (GalleryPhoto) -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(vm.photos) { photo in
                        CachedImage(urlString: photo.url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Color.sandLight)
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .contextMenu {
                            if photo.isMine, photo.isDeletable {
                                Button(role: .destructive) {
                                    dismiss()
                                    onDelete(photo)
                                } label: {
                                    Label("Eliminar foto", systemImage: "trash")
                                }
                            }
                        }
                        // Mismo gancho que la fila: el VM decide si toca pedir
                        // la siguiente página y qué precargar.
                        .onAppear { vm.photoAppeared(photo) }
                    }
                }

                if vm.isLoadingMore {
                    ProgressView().padding(.vertical, Spacing.lg)
                }
            }
            .navigationTitle(placeName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { vm.refresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
